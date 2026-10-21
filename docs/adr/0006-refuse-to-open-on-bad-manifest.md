# ADR-0006：MANIFEST 读不出来就拒绝启动，不回退旧版本

- **状态**：已采纳（推翻了 `format.md` §4.3 的早期表述）
- **日期**：2026-10-20
- **相关**：ADR-0003（崩溃一致性契约 C1–C5）、`docs/design/format.md` §4

---

## 背景

`format.md` §4.3 最初写的是：

> 若 MANIFEST 的 CRC 失败：尝试同目录下编号次大的 MANIFEST；都没有才报 Corruption。
> 这是「CURRENT 被写坏」的兜底路径。

我照着这句话实现了 `read_manifest_with_fallback`：把 `CURRENT` 指向的那份
放进候选列表，再把目录里其他 `MANIFEST-*` 按名字追加进去，逐个尝试解码，
第一个通过的胜出。

写完测试之后它立刻失败了 —— 而且失败的原因比「代码有 bug」有意思得多。

---

## 发现：根本不存在「次大的那份」

`flush` 的实现是「写新 MANIFEST → fsync → 原子切换 CURRENT → **删掉旧 MANIFEST**」
（先写后删，`format.md` §4.2 第 7 步）。所以任何时刻目录里**只有一份** MANIFEST。

回退逻辑的候选列表永远只有一个元素，退无可退。测试里我手工把当前 MANIFEST
写成垃圾，期望「退到上一份」，结果拿到 `Corruption` —— 因为上一份已经被删了。

这暴露了规范和实现的矛盾：§4.2 要求「切换后删旧 MANIFEST」，
§4.3 又要求「失败时退到旧 MANIFEST」。两条不可能同时成立。

---

## 决策

**删掉回退，改为拒绝启动。** 同时把 §4.3 改写成现在的 §4.3.1。

`Db::open` 在以下三种情况报 `LsmError::Corruption`：

| 情形 | 判据 |
|---|---|
| `CURRENT` 缺失，但目录里已有数据文件 | 有 SST / WAL / MANIFEST 残留 |
| `CURRENT` 内容不是 `MANIFEST-<数字>` | 解析失败 |
| `CURRENT` 指向的 MANIFEST 读不出来 | 不存在 / magic / version / CRC / 语义不合法 |

「空目录」不算异常 —— 那是一个新库。

---

## 为什么回退是有害的（不是「不够优雅」）

回退会**丢掉已经 ack 的数据**，直接违反 C1。这不是理论推演：

```
1. put(a) → WAL fsync → 返回 ack        ← 已承诺不丢
2. put(b) → WAL fsync → 返回 ack        ← 已承诺不丢
3. flush：
   3a. 写 sst/000003.sst（含 a、b）+ fsync
   3b. 写 MANIFEST-000005（引用 000003）+ fsync
   3c. 切 CURRENT → MANIFEST-000005      ← 原子点
   3d. 删掉 wal/000001.wal               ← a、b 的唯一其他副本没了
4. MANIFEST-000005 因磁盘坏块读不出来
```

第 4 步回退到 flush 之前的 MANIFEST-000002，它不认识 `sst/000003.sst`。
于是 a 和 b 从数据库里消失 —— 而它们已经返回过 ack。

拒绝启动则完全不同：`sst/000003.sst` 和 `MANIFEST-000005` 都还在磁盘上，
一个字节都没少。人可以去看，可以写工具从 SST 重建 MANIFEST。
**「打不开」比「打开但少了数据」好得多。**

---

## 与 WAL 尾部截断的对照

这两个决定看起来矛盾：WAL 读到半条记录时静默截断，MANIFEST 读不懂却拒绝启动。
判据其实是同一条 —— **自动决策不能丢已经承诺不丢的数据**。

| | WAL 尾部半条记录 | MANIFEST 读不出来 |
|---|---|---|
| 性质 | 断电**常态**，每次崩溃都可能出现 | 磁盘坏块 / 人为误操作 |
| 半条记录被 ack 过吗 | 没有（ack 在 fsync 之后） | — |
| 截断/回退会丢已 ack 数据吗 | **不会** | **会** |
| 结论 | 静默处理 | 拒绝启动，交给人 |

如果哪天 WAL 的截断会丢掉已 ack 的记录，那也必须改成拒绝启动。

---

## 被否决的备选方案

### A. 保留最近 N 份 MANIFEST，回退到可用的那份

LevelDB / RocksDB 确实保留多份 MANIFEST。但它们的目的不是「坏了就退」，
而是「防止写到一半的新 MANIFEST 影响正在跑的实例」。

否决理由同上：退到旧 MANIFEST 依然会丢已 ack 数据。
保留多份只解决「候选列表为空」，不解决「回退本身有害」。

### B. 保留多份 + 只在「确认没丢数据」时回退

比如比较旧 MANIFEST 的 `next_file_number` 和目录里最大 SST 编号，
一致才回退。这个判断能做到正确，但它需要一套额外的「孤儿文件归属分析」，
而且一旦判断错了就是静默丢数据。收益（省一次人工介入）远小于风险。

### C. 从 SST 自动重建 MANIFEST

技术上可行（SST 自描述：footer 里有 index、每条 entry 有 seq）。
但这等于让引擎在「元信息不可信」的状态下做一次完整扫描 + 推断，
是 M3 之后才值得做的事。真要做，也应该是一个显式的离线工具
（`moonlsm-repair`），而不是 `open()` 里悄悄发生的副作用。

---

## 影响

- `Db::read_manifest_with_fallback` 删除，改为 `Db::read_manifest`
  （只读一份，失败即 Corruption）
- `Db::rewrite_current` 删除（原本用于「回退后修正 CURRENT」）
- `format.md` §4.3 重写为 §4.3 + §4.3.1，补上拒绝启动的完整清单和本节的理由
- 新增测试「MANIFEST 被写坏 → 拒绝启动」，替代原来的「退回上一份」
- **运维含义**：MANIFEST 损坏后数据库不会自动起来。这是有意的，
  但需要在 README 的故障排查里写明，否则用户会以为是 bug
