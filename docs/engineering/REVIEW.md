# 验收对照：9 项要求逐条自查

> 这份文件把验收指南的 9 条要求逐条拆开，每条回答三个问题：
> **现状是什么、别人怎么自己验一遍、证据在哪个文件里。**
>
> 所有命令都在仓库根目录执行，不需要额外准备。最后有一节「一条命令全过」。

## 0. 一览

| # | 要求 | 状态 | 一句话证据 |
|---|---|:---:|---|
| 1 | MoonBit 主要语言，`moonc >= 0.10.16` | ✅ | 全部实现 10 298 行 `.mbt`；`moonc v0.10.18`，CI 有阻断检查 |
| 2 | 仓库公开、提交记录清晰 | ✅ | `PingGuoMiaoMiao/moonlsm` PUBLIC，43 个 Conventional Commits，10 篇 ADR |
| 3 | 结构清晰、核心功能可完成 | ✅ | 15 个库文件按「编码 / 存储 / 组织 / 调度」四层拆分，见 §3 |
| 4 | README 说明目标/安装/使用/示例，可复现 | ✅ | 273 行、10 节，每条命令都贴了期望输出 |
| 5 | CI 覆盖检查、构建、测试 | ✅ | 3 个 job：工具链门禁 + 3 OS × (check, test) + 4 组构建 |
| 6 | 至少一个可运行示例 | ✅ | `examples/basic`，`moon run examples/basic` 四步输出 |
| 7 | 完整测试覆盖核心功能路径 | ✅ | **215 条**，16 个测试文件，逐模块对应 |
| 8 | 发布到 mooncakes.io | ✅ | `PingGuoMiaoMiao/moonlsm@0.3.1` |
| 9 | OSI 认可的开源许可证 | ✅ | MIT（`LICENSE`，GitHub 识别为 `MIT License`） |

---

## 1. 以 MoonBit 为主要实现语言，`moonc >= 0.10.16`

**实现语言：全部 MoonBit。** 仓库里 10 298 行 `.mbt`：

| 部分 | 行数 | 说明 |
|---|---:|---|
| 库（根包） | 5 135 | 存储引擎本体，无任何非 MoonBit 实现 |
| 测试（`*_wbtest.mbt`） | 4 366 | 与库同语言，同一次 `moon test` 运行 |
| CLI / 示例 / 基准 | 797 | `cmd/dbcli`、`examples/basic`、`benches/moon` |

仓库里另有 1 595 行 Python，全在 `benches/python/` 下，**只做测试驱动**
（随机对拍、崩溃注入、基准跑分、只读 A/B），不参与构建、不实现任何存储逻辑。
`moon build` 不会碰它们 —— 这一点可以直接验证：删掉 `benches/python/` 后 `moon build` 照常成功。

**编译器版本：`moonc v0.10.18`**（2026-10-28，`moon 0.1.20261028`）。

```bash
moonc -v          # v0.10.18+6c83a7f62 (2026-10-28)
cat .moon-version # 0.1.20261028
```

**为什么 0.10.16 这条线是真的分界。** 从那一版起 `Int` 是 64 位、`Int32` 才是 32 位。
本库所有「本来就是 32 位」的字段都显式标注成 `Int32` ——
`write_varint32` / `write_fixed32` / `write_fixed16` / `varint32_len`、
块内偏移、`num_restarts`、各处的长度计数，共 **197 处**。
这不是为了迎合 formatter，而是把原来隐式的 32 位假设写成类型：
在这些位置用 64 位整数，超范围时会静默截断，而磁盘格式只给它们 4 个字节。

旧编译器看到这些标注会直接报「类型不存在」，所以这条要求在本项目里不是形式问题。
CI 第一步就是 `检查 moonc ≥ 0.10.16（阻断）`，低于要求直接失败并打印升级方式。

> 升级到 0.10.18 的过程记在 [`CHANGELOG.md`](../CHANGELOG.md) 的 `[0.3.1]` 段，
> 手动安装三步（CLI 本体 / core 标准库 / `moon bundle`）记在
> [`CONTRIBUTING.md`](../CONTRIBUTING.md) 的工具链一节 ——
> 新版 core 不再随 CLI 分发，这一步最容易漏。

---

## 2. GitHub 仓库公开、提交记录清晰

```bash
gh repo view PingGuoMiaoMiao/moonlsm --json visibility
# {"visibility":"PUBLIC", ...}
```

- 地址：<https://github.com/PingGuoMiaoMiao/moonlsm>
- 提交数：43，全部使用 Conventional Commits（`feat` / `fix` / `docs` / `perf` /
  `test` / `chore` / `release` / `refactor`），类型一眼能看出改了什么
- 每个非平凡决策一篇 ADR（`docs/adr/`，共 10 篇），记录**当时否决了什么**，
  不只是「最后选了什么」
- 每次发布都有对应的 `release:` 提交；**0.3.1 起发布即打 annotated tag**
  （`v0.3.1`，tag 名与 `moon.mod` 的 `version` 一致）。
  0.1.0–0.3.0 没有 tag，原因写在 `CHANGELOG.md` 的 `[0.3.1]` 段：
  那几次发布没有留 commit，事后补打只能猜，猜错的 tag 比没有更糟

```bash
git log --oneline | head -20
ls docs/adr/
```

---

## 3. 源代码结构清晰、能完成声明的核心功能

库本身是扁平的 15 个文件，按**职责分层**而不是按技术分层 —— 每层只依赖它下面那层：

| 层 | 文件 | 职责 |
|---|---|---|
| 编码 | `varint.mbt` `crc32c.mbt` `types.mbt` `error.mbt` | 变长整数、定长小端、校验和、`Bytes` 比较 |
| 块 | `block.mbt` `bloom.mbt` `sstable.mbt` | 前缀压缩 block、布隆过滤器、SST 读写 |
| 内存 | `memtable.mbt` `iter.mbt` | 有序内存表、归并迭代器 |
| 日志 | `wal.mbt` `manifest.mbt` | 预写日志、版本清单（原子切换） |
| 组织 | `compact.mbt` `storage.mbt` `fs_native.mbt` | 三层归并、存储抽象、native 文件系统 |
| 门面 | `db.mbt` | `open` / `put` / `get` / `delete` / `scan` / `close` |

**声明的核心功能，逐条都有实现和测试**：

- 单键读写：`put` / `get` / `delete`（删除写墓碑，不是物理删除）
- 范围扫描：`scan(start, end, limit)`，跨 memtable + 多层 SST 归并
- 持久化：`put` 返回即代表 `fsync` 成功（断电不丢已确认数据）
- 崩溃恢复：`CURRENT` → `MANIFEST` → 各层 SST → 重放 WAL，截断写坏一半的尾部帧
- 自动归并：L0 攒够 4 个文件触发、L1 超 1 MiB 下沉
- 完整性校验：data / index / filter block 的 CRC32C（格式 v2）
- 空间回收：`compact` 时丢弃被覆盖版本与墓碑

不做的部分写在 README 的「明确不做」一节（无事务、无 SQL、无多进程并发写）。

---

## 4. README：目标、安装、使用、示例，且可复现

| 要求 | 位置 | 内容 |
|---|---|---|
| 项目目标 | README「为什么存在」 | 一句话定位 + 与 SQLite / moonkv / 内存 Map 的对照 |
| 安装方式 | README「快速开始」+ CONTRIBUTING | `moon add` / 环境要求 `moonc >= 0.10.16` / 手动装工具链三步 |
| 使用方法 | README「API」 | 完整调用序列，含 `raise` 的处理方式 |
| 示例 | README「快速开始」+ `examples/basic` | 管道喂 JSON 的十秒演示，和可编译的最小示例 |
| 可复现 | 每条命令都贴期望输出 | 输出是从真实运行里粘的，不是手写 |

中英双份（`README.md` / `README.en.md`），mooncakes 文档页用精简版 `README.mbt.md`。

---

## 5. 持续集成覆盖检查、构建、测试

`.github/workflows/ci.yml`，三个 job：

| job | 矩阵 | 内容 | 阻断 |
|---|---|---|:---:|
| `工具链与格式` | ubuntu | `moonc >= 0.10.16` 检查、版本对比、`moon fmt --check` | 版本检查阻断；格式仅告警 |
| `检查与测试` | ubuntu / macOS / **Windows** | `moon check --deny-warn`、`moon test` | ✅ |
| `构建` | 4 组：wasm-gc 根包、js 根包、native 全模块 × ubuntu/macOS | `moon build --target <t>` | ✅ |

另有一份 `.github/workflows/crash.yml`：native release 构建后跑 `crash_test.py`
（子进程随机 `kill` 后重启，核对已 ack 的数据是否还在），只在 `main` 与手动触发时跑。

**三个设计取舍值得说明**（都写在 workflow 的注释里）：

- **Windows 也跑 check + test**：存储引擎最容易出平台 bug 的地方正是路径分隔符、
  文件锁、`rename` 语义，而这些在 Linux 上测不出来
- **wasm-gc / js 只构建根包**：证明核心数据结构没有偷偷依赖 native 特性；
  `cmd/dbcli` 用 `extern "C"` 读 stdin，本来就不该在这些后端上跑
- **格式检查只告警**：官方 CDN 只提供 `latest`（带版本号的路径实测 403），
  CI 装不了指定版本，工具链会漂移。格式规则变化不是正确性问题，
  让它阻断等于让「上游发版」变成「主干变红」

```bash
gh run list --limit 5
```

---

## 6. 至少一个可运行示例

`examples/basic/main.mbt`，一个独立可执行包（不是文档里的伪代码）：

```bash
moon run examples/basic
```

```
已打开 ./example_data
写入 user:1 -> alice，seq = 1
读回 user:1 = alice
批量写入 user:2..4 并 sync 完成
扫描 [user:, user;) 得到 4 条：
  user:1 = alice
  user:2 = user-2
  user:3 = user-3
  user:4 = user-4
删除 user:2 后 get 返回 None
已关闭。重新运行这个示例，上面这些 key 仍然读得到。
```

**再运行一次**，第 3 行的「读回 user:1」依然成立 —— 这是这个引擎和内存 `Map` 的唯一区别，
也是示例要演的重点。数据落在 `./example_data`，可以直接看 `CURRENT` / `MANIFEST-*` /
`wal/` / `sst/` 这些文件。

另有一个协议式示例：`cmd/dbcli`，从 stdin 读 JSON 行、往 stdout 写 JSON 行，
方便用任何语言驱动（`benches/python/` 下的对拍与崩溃测试就是这么驱动的）。

---

## 7. 完整测试覆盖核心功能路径

**215 条**（`moon test` 一次跑完），16 个测试文件，**逐模块一一对应**：

| 测试文件 | 条数 | 覆盖什么 |
|---|---:|---|
| `varint_wbtest.mbt` | 7 | LEB128 往返、边界值、非法输入 |
| `crc32c_wbtest.mbt` | 4 | 标准向量、空输入、单字节差异 |
| `types_wbtest.mbt` | 4 | `Bytes` 二进制比较（不能按长度优先） |
| `block_wbtest.mbt` | 14 | 前缀压缩编解码、restart 点、**任意单字节损坏必被 CRC 拦下**、v1 兼容 |
| `bloom_wbtest.mbt` | 14 | 无假阴性、假阳性率、**任意单字节损坏必被拦下**、v1 兼容 |
| `sstable_wbtest.mbt` | 23 | 读写往返、点查、范围扫描、v1 老文件仍可读、不认识的版本必须拒绝、**游标惰性与逐条一致** |
| `memtable_wbtest.mbt` | 10 | 有序性、覆盖写、墓碑、内存估算 |
| `iter_wbtest.mbt` | 7 | 归并顺序、同 key 取高 seq、边界 |
| `wal_wbtest.mbt` | 10 | 帧格式、截断恢复、半条帧丢弃、CRC |
| `manifest_wbtest.mbt` | 22 | 原子切换、层不变量、L0 允许重叠、崩溃点 |
| `compact_wbtest.mbt` | 15 | 三层归并、墓碑回收、范围正确性 |
| `storage_wbtest.mbt` | 16 | 抽象层契约（含内存实现，让非 native 后端也能测） |
| `fs_native_wbtest.mbt` | 18 | 真实文件系统：常开句柄、覆盖写、改名、删除、跨实例隔离 |
| `db_wbtest.mbt` | 35 | 端到端：开关库、重启恢复、扫描、归并触发 |
| `corruption_wbtest.mbt` | 9 | **损坏注入 fuzz**：逐字节翻转，断言「必须发现」且漏检位置被钉死 |
| `cmd/dbcli/esc_wbtest.mbt` | 7 | JSON 字符串转义 |

除单元测试外还有两个外部验证（需要 Python，CI 里跑）：

```bash
cd benches/python
python model_check.py --cmd ../../_build/native/release/build/cmd/dbcli/dbcli.exe --ops 2000
python crash_test.py --rounds 10
```

- `model_check`：随机 2000 步与内存模型对拍，中途重启 2 次，**0 错**
- `crash_test`：子进程随机被杀后重启，核对已 ack 的数据 —— **10/10 轮，丢失 0、半条 0**

三后端都跑：native **215**、wasm-gc 根包 **190**、js 根包 **190**。
差的 25 条正好是「非 native 就跑不了」的那两组：
`fs_native_wbtest.mbt` 的 18 条（测的是真实文件系统）+
`cmd/dbcli/esc_wbtest.mbt` 的 7 条（`--target ... .` 只测根包，不含 cmd 子包）。

---

## 8. 发布到 mooncakes.io

```bash
moon add PingGuoMiaoMiao/moonlsm     # 解析到 0.3.1
```

- 页面：<https://mooncakes.io/docs/PingGuoMiaoMiao/moonlsm>
- 发布历史在 `CHANGELOG.md`，每次发布都有对应的 `release:` 提交

**发布后做过三重验证**，不是看到 `200 OK` 就算完：

1. 临时模块里 `moon add`，确认解析到目标版本
2. 解包 `.zip`，确认关键符号、`moon.mod` 的 `version`、`docs/adr/` 都在包内
3. 打开 mooncakes 文档页，确认源码链接指向该版本

---

## 9. OSI 认可的开源许可证

**MIT**（`LICENSE`，GitHub 识别为 `MIT License`，OSI 认可）。

**关于参考与移植**：本项目是**独立实现**，没有移植任何项目的代码。
设计上参考了 LSM 的公开文献与几个成熟实现的公开文档
（LevelDB / RocksDB / Pebble / mini-lsm），这些项目都是 BSD 或 Apache 2.0，
允许阅读与学习设计。仓库里没有引入它们的源码片段，也没有复制测试用例。

具体的「读了什么、用来做什么」列在 `benches/python/REFERENCES.md`，
包括哪些结论被后来的实测推翻了（例如「moonkv 写吞吐更高」这条预测，
在 0.2.2 之后被同场 A/B 推翻，文档里保留了更正记录）。

---

## 附：一条命令全过

```bash
moonc -v                                   # v0.10.18（需 >= 0.10.16）
moon check --deny-warn                     # 零警告
moon test                                  # 215 / 215
moon test --target wasm-gc .               # 190 / 190
moon test --target js .                    # 190 / 190
moon build --target native --release       # dbcli + examples
moon fmt --check                           # 格式一致
moon run examples/basic                    # 四步输出，二次运行数据仍在
```

## 已知不足

写在 README 的「能力矩阵 / 局限」一节，这里只列最影响使用的三条：

1. **`Db::scan` 是「整段读进数组再归并」**，不是流式游标 —— 大范围扫描会把结果全量驻留内存，
   这是范围扫描慢一个数量级的根因
2. **SST footer 的 `smallest_seq` 没有 CRC**（8 字节）。48 字节固定 footer 里没有位置再塞校验和，
   逐字节翻转 fuzz 的 185 个位置里有 8 个漏在这里；它只用于快照读下界，不参与数据定位
3. **单进程独占**：没有文件锁协商，两个进程同时打开同一目录会互相踩

这三条都记在 `PLAN.md` 的「还欠什么」里，有明确的归属版本，不是含糊的「暂不支持」。
