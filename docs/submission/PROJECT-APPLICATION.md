# moonlsm 项目申报书

## 基本信息

- 项目名称：moonlsm —— MoonBit 生态的嵌入式 LSM 存储引擎
- 参赛者：PingGuoMiaoMiao
- 联系方式：<请填写手机号或邮箱>
- GitHub 仓库链接：https://github.com/PingGuoMiaoMiao/moonlsm
- 项目方向：MoonBit 存储引擎 / 数据基础设施
- 是否为移植项目：否

## 项目简介

moonlsm 为 MoonBit 生态补上一个缺失的地基：**真正带 SSTable 与 compaction 的 LSM-tree 存储引擎**。

MoonBit 目前已有的键值存储都是 Bitcask 风格——一个追加文件加一份全量内存索引，数据量一大内存就随数据线性增长，也没有分层合并；另一个包只做 WAL 分帧。这意味着任何需要持久化的 MoonBit 项目，都得自己从 WAL 写起。moonlsm 面向这些库作者与工具开发者，提供一个可以直接依赖的持久化内核。

（说明：这里的「嵌入式」是 *embedded database* 的语义——像 SQLite 那样**链接进宿主进程**，相对 client-server 而言；不是「跑在单片机 / MCU 上」。它依赖 libc 与带 `fsync` 语义的文件系统，这一点在 README 的「明确不做」里写明了。）

项目把重心放在**崩溃一致性**上，而不是功能数量：写入先落 WAL、`fsync` 成功之后才返回，进程被 `kill -9` 之后，已经确认的写入逐条读回来一条不丢。这条契约被拆成五层可验收的关卡和 198 条测试，而不是一句承诺。

当前版本 v0.2.0 已发布到 mooncakes，`native` / `wasm-gc` / `js` 三个后端分别构建通过，CI 在 Ubuntu / macOS / Windows 三平台全绿。

## 核心功能范围

- 提供「先落盘再回 ack」的写入路径：WAL 顺序追加 + `fsync`，ack 的语义是**已持久化**而不是「已进内存」；
- 提供 SSTable 读写，含前缀压缩、restart point、块内二分索引、Bloom filter 与 footer 校验；
- 提供三层 leveled compaction（L0 可重叠 → L1 / L2 不重叠），同一 key 只保留 seq 最大的一条，**墓碑只在最底层丢弃**；
- 提供 MANIFEST 版本快照 + CURRENT 原子切换的恢复路径，打开时按 CURRENT → MANIFEST → SST → 重放 WAL 顺序重建状态；
- 提供可插拔 `Storage` trait，`NativeStorage` 之外可换存储后端，`native` / `wasm-gc` / `js` 三后端分别构建；
- 提供组提交 `putmany`：一批写入只 `fsync` 一次，把「每条一次 fsync」的 39× 代价压到 1.40×；
- 提供范围扫描 `scan`（左闭右开），跨 memtable 与多层 SST 多路归并后全局有序，自动过滤墓碑；
- 提供文件级 key 区间剪枝与 Bloom filter 快速否定：一次未命中不再探全部 77 个文件；
- 提供 CLI `dbcli`（行 JSON 协议）与四套外部测试驱动：持久化探测、随机对拍、崩溃测试、性能基准；
- 提供崩溃契约 C1–C5（已确认必不丢 / 未确认可丢 / 绝不读半条 / 绝不静默丢 / 前缀一致），每条对应到具体测试；
- 提供 198 条单元测试（native）/ 180 条（`wasm-gc`、`js` 根包），另有 20 轮 `kill -9`、5000 步随机对拍、9 条损坏注入与逐字节 fuzz；
- 提供 8 篇 ADR、中英双语 README、磁盘格式契约（`docs/design/format.md`）、五关验收手册与基准报告；
- 提供 README 示例，覆盖建库读写、范围扫描、崩溃恢复验证与三后端构建。

## 移植或参考说明

- 原项目名称：无。本项目为原创实现，不是移植项目
- 参考对象（只参考设计思路与测试方法，不复制源码）：
  - https://github.com/google/leveldb —— 文件格式与整体架构
  - https://github.com/skyzh/mini-lsm —— 教学路径与章节划分
  - https://github.com/cockroachdb/pebble —— 测试工程化思路
  - https://github.com/syndtr/goleveldb —— 代码细节查证
- 原项目许可证：LevelDB（BSD-3-Clause）、mini-lsm（Apache-2.0）、Pebble（Apache-2.0）、goleveldb（BSD-2-Clause）
- 本项目许可证：MIT

本项目代码为 MoonBit 原创实现，**未直接复制上述项目的源码**；参考的是设计思路、文件格式与测试方法。
上游参考对象在 README 的「参考」一节逐条列明，各项目许可证如上。由于不存在源码复制，
本项目按 MIT 独立发布，不继承上游许可证；若后续引入上游代码，会按对应许可证要求标注。

与原项目相比，本项目做了以下简化和重新设计：

- 用 MoonBit 原生包结构、类型系统与 `test` 块组织代码，而不是复刻 C++ / Java 的工程结构；
- **层数从 LevelDB 的七层压到三层**。理由是：只有两层时「目标层是不是最底层」这个判定恒为真，永远不会被证伪，而它判错的后果是删掉的数据复活；加 L2 之后两条分支都能真实走到；
- 磁盘格式为 MoonBit 侧自定义（带版本字段与 magic），**不承诺与 LevelDB 文件格式兼容**，也不做 LevelDB 数据目录的直接读取；
- 新增组提交 `putmany`（ADR-0005），这是 LevelDB 没有暴露的接口，目的是把批写的 `fsync` 次数摊薄；
- 明确不做 SQL、事务与 MVCC、压缩、value log 分离、分布式——这五项每一项都能单独吃掉一周，v1 全部排除并写进 README 能力矩阵；
- 用 MoonBit 的 `error` 与 trait 改写异常、集合类型与继承层级，不引入服务发现机制；
- 以 MoonBit API 与行 JSON 协议为主要交付接口，方便接入 CLI、测试驱动与后续的可视化工具。

**当前已知不足**（同样写进文档，不掩饰）：

- 单条 `put` 只有 76 ops/s——Windows 上每次 `fopen` / `fclose` 约 5.9 ms，修法是缓存 WAL 文件句柄，属于 v1.1；
- 范围扫描比 SQLite 慢一个数量级，根因是 `Db::scan` 仍为「整段读进数组再归并」而非流式游标；
- SST 没有 block 级 CRC，逐字节翻转 fuzz 显示 173 个位置中 **42% 可发现、58% 被静默接受**——这个数字比一句「暂不支持」更能说明 v1.1 该先做什么。
