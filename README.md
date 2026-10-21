# moonlsm

**MoonBit 生态里的嵌入式 LSM 存储引擎。**

![CI](https://github.com/PingGuoMiaoMiao/moonlsm/actions/workflows/ci.yml/badge.svg)
![License](https://img.shields.io/badge/license-MIT-blue)
![Status](https://img.shields.io/badge/status-WIP-orange)

> 社区项目，非 MoonBit 官方出品。`moon` 前缀只是沿用社区命名惯例（moondb / moonrpc / moongql）。

---

## 为什么存在

MoonBit 生态里现有的 KV 存储都是 **Bitcask** 风格：一个追加文件 + 一份全量内存索引。数据量一大，内存就随数据线性增长，也没有分层合并。

真正的 **LSM-tree**（memtable + SSTable + compaction）在 MoonBit 里还是空白。

moonlsm 要做的，就是把这个空白补上——而且**把崩溃一致性测明白**，这是大多数个人实现最容易含糊过去的地方。

---

## 设计

```
put(k, v)
   ├─→ WAL（顺序追加，崩溃后重放）
   └─→ MemTable（内存有序表）
          └─ flush ─→ L0 SSTable
                        └─ compaction ─→ L1 → L2 ...
```

- **写**：先写 WAL，再进 MemTable。MemTable 满了整块刷成 L0 SSTable。
- **读**：MemTable → L0 → L1 → L2，每层先查 Bloom filter 跳过无关文件。
- **合并**：后台 compaction 逐层合并，丢弃被覆盖的旧值和已过期的墓碑。

详细字节布局见 [`docs/design/format.md`](docs/design/format.md)。

---

## 快速开始

```bash
moon check                        # 类型检查（零警告）
moon test                         # 单元测试
moon build --target native        # 构建 dbcli
```

十秒看到它在工作（管道喂 JSON）：

```bash
printf '%s\n' \
  '{"op":"put","k":"user:1","v":"alice","sync":true}' \
  '{"op":"get","k":"user:1"}' \
  '{"op":"scan","start":"user:","end":"user;","limit":10}' \
  | ./_build/native/debug/build/cmd/dbcli/dbcli.exe --path ./data
```

```
{"ok":true,"seq":1}
{"ok":true,"v":"alice"}
{"ok":true,"items":[["user:1","alice"]]}
```

> **当前进度：Week 1 完成。** 写 → memtable → 刷 SST → 归并读回这条路径已打通，
> `model_check.py` 2000 步对拍零错误。但**还没有 WAL**，进程退出数据就丢；
> 也还没有 compaction，SST 数量只增不减。Week 2 补这两块。
> 完整的验收步骤见 [`docs/engineering/ACCEPTANCE.md`](docs/engineering/ACCEPTANCE.md)。

---

## API（设计稿，尚未全部实现）

```moonbit
// 已经能用的（内存实例，无持久化）
let db = @moonlsm.Db::new(8 * 1024 * 1024)   // memtable 阈值
db.put(b"key", b"value")!                     // -> UInt64 (seq)
let v = db.get(b"key")                        // -> Bytes?，删除也是 None
db.delete(b"key")!
let rows = db.scan(b"a", b"z", 100)!          // [start, end)
db.flush()!                                   // memtable -> SST

// 还没做的（需要文件 IO 层与 WAL）
// @moonlsm.open("data")! / db.close()!
```

---

## 能力矩阵

| 能力 | 状态 |
|---|---|
| 点查 / 写入 / 删除 | ✅ 已实现（内存 + SST） |
| 范围扫描 | ✅ 已实现（左闭右开，多路归并） |
| SSTable 读写（前缀压缩 + restart point） | ✅ 已实现 |
| 索引 / Bloom filter / footer | ✅ 已实现 |
| WAL 崩溃恢复 | 设计中（Week 2） |
| 分层 compaction | 设计中（Week 2） |
| 持久化（进程重启不丢） | 未实现 —— 这是当前最大的缺口 |
| 内存有序表 | ✅ 已实现（有序数组，Week 3 视性能换跳表） |

### 明确不做

- **不做事务**（无 MVCC、无快照隔离）
- **不做压缩**（SSTable 明文存储）
- **不做加密、不做鉴权**（假定单进程独占目录）
- **不做分布式**（这是嵌入式库，不是数据库服务）

把「不做什么」写清楚，比列一堆「计划做什么」更有用。

---

## 测试

除了 `moon test`，还有一套**外部崩溃一致性测试**（Python 驱动，通过 `cmd/dbcli` 的行 JSON 协议对接）：

```bash
cd benches/python
python model_check.py --cmd "../../_build/native/debug/build/cmd/dbcli/dbcli.exe --path ./data" --ops 5000
python crash_test.py   --cmd "../../_build/native/debug/build/cmd/dbcli/dbcli.exe --path ./data" --rounds 20
python bench.py        --cmd "../../_build/native/debug/build/cmd/dbcli/dbcli.exe --path ./data" --n 200000
```

三个脚本分别验证：

| 脚本 | 验证什么 |
|---|---|
| `model_check.py` | 与内存 dict 逐条对拍，覆盖覆盖写 / 删除 / 墓碑 / 大 value / 前缀 key |
| `crash_test.py` | **kill -9 后，已确认的写入一条不丢，且绝不读出半个值** |
| `bench.py` | 写吞吐、读延迟分位、空间放大 |

> 注意：`kill -9` 只杀进程、不清 OS 页缓存，所以**它测不出「忘了 fsync」**。
> 真正验证 fsync 需要 WAL 尾部截断注入或虚拟机断电。详见 [`benches/python/README.md`](benches/python/README.md)。

---

## 路线图

| 版本 | 目标 |
|---|---|
| v0.1.0 | 比赛版：crash 20/20、model_check 5000 步 0 错、发布到 mooncakes |
| v0.2.0 | 可嵌入：API 冻结草案、examples 可跑、三后端构建通过 |
| v0.3.0 | 可观测：stats/metrics、bench 可复现 |
| v0.5.0 | API 冻结：语义化版本承诺、迁移指南 |
| v1.0.0 | 产品：多后端抽象、性能回归门禁、外部用户 |

开发模型（为什么用门禁式增量 V 模型，而不是纯瀑布）、命名考究、参考对象分层、
项目→产品四阶段演进，都在 [`docs/engineering/PROCESS.md`](docs/engineering/PROCESS.md)。

**「这个库要干什么、怎么验证它做对了」** 看
[`docs/engineering/ACCEPTANCE.md`](docs/engineering/ACCEPTANCE.md) —— 五关验收手册。

---

## 参考

| 用途 | 项目 |
|---|---|
| 主模板（通读） | [mini-lsm](https://github.com/skyzh/mini-lsm) |
| 查代码细节 | [goleveldb](https://github.com/syndtr/goleveldb) |
| 对标工程质量（只抄测试） | [Pebble](https://github.com/cockroachdb/pebble) |
| 查文件格式 | [LevelDB](https://github.com/google/leveldb) |
| 反面教材（三个真实 bug） | [Badger](https://github.com/dgraph-io/badger) |
| 同类竞品 | [moonkv](https://mooncakes.io/docs/wallll-wal6/moonkv) · [moonjournalkit](https://mooncakes.io/docs/Sxy11112/moonjournalkit) |

关键决策记录在 [`docs/adr/`](docs/adr/)，每层参考怎么用见
[`docs/engineering/PROCESS.md`](docs/engineering/PROCESS.md) §2。

## License

MIT —— 见 [LICENSE](LICENSE)。
