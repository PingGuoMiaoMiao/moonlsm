# 更新日志

本文件记录 moonlsm 的所有重要变更。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本 2.0.0](https://semver.org/lang/zh-CN/)。

> **关于 0.x 版本**：在 1.0.0 之前，MINOR 版本可能包含破坏性变更。
> 每次破坏性变更都会在下方明确标注 **BREAKING**，并给出迁移说明。
> 磁盘格式的变更额外要求 bump `docs/design/format.md` 里对应结构的 `version` 字段。

---

## [Unreleased]

### 新增

**磁盘格式底座（Week 1 D1）**

- `varint.mbt`：LEB128 变长整数 + 小端定长整数的读写原语
  - WAL / data block / MANIFEST 三处格式共用，所以单独成文件、单独测试：
    varint 有错时三种格式会同时坏，且症状互相掩盖（表现为 CRC 校验失败）
  - 所有 `read_*` 在越界或编码非法时返回 `None` 而不抛错 ——
    同一个 `None` 在 WAL 恢复里是「尾部截断，可容忍」，
    在 block 解析里是「数据损坏，必须报错」，这个判断不该由底层做
- `block.mbt`：SST data block 的前缀压缩 + restart point 编解码
  - `BlockBuilder`：按 key 严格升序追加，每 16 条一个 restart 点，
    `finish()` 产出「entry 区 + restart 数组 + 计数」
  - `Block`：restart 数组二分 + 局部线性扫描，最坏解 16 条 entry
  - 结构损坏返回 `None` 而不是 panic；乱序/重复 key 直接抛 `Corruption`
  - 前缀压缩实测：1000 条共享前缀的 11 字节 key，体积比同长度随机 key 小 15% 以上

**SSTable（Week 1 D3）**

- `sstable.mbt`：`data block* | filter block | index block | footer(48)` 的写与读
  - `SstWriter`：按 key 升序追加，块满 4 KiB 自动封盘并在索引里记
    `last_key -> (offset, size)`；`finish()` 生成 filter、index、footer
  - `SstReader`：`open_sst` 校验长度 → magic → version → 区域边界，
    任一失败返回 `None`；`get` 走 bloom 否定 → index seek → block 二分
  - **只处理 `Bytes`，不碰文件系统**。核心保持 backend 无关，
    CI 在 wasm-gc / js 上编译它即可证明；文件 IO 留给边界层
- `bloom.mbt`：补 `encode` / `decode_bloom`，实现 §3.3 的位图编码
  （按位打包，不是一个 bool 一字节 —— 后者会让 filter 膨胀 8 倍）
- `block.mbt`：新增 `seek`（下界查找，index 依赖它）与 `last_key` 访问器
  - 二分逻辑抽成 `restart_index_for`，`get` 与 `seek` 共用。
    写两份的话，某天只改其中一份就会得到「精确查找对、下界查找错」

**读写路径（Week 1 D6+D7）**

- `iter.mbt`：k 路归并迭代器
  - 同 key 取 `seq` 最大的一条（**不按来源顺序**，否则 compaction 之后会读错）
  - 墓碑参与归并但由上层过滤 —— 直接丢弃墓碑会让底层旧值「复活」
  - 输出严格按 key 升序
- `db.mbt`：`Db` = memtable + 若干 SST，读路径 `memtable → ssts[0] → …`
  - `put` / `delete` / `get` / `scan`（左闭右开）/ `flush`
  - `flush` 的顺序是「写 SST → **立刻读回校验** → 才清空 memtable」，
    中间失败绝不清 memtable
  - memtable 超过阈值自动 flush
- `cmd/dbcli`：从内存 Map 占位换成真正的 `@moonlsm.Db`
  - `stats` 增加 `ssts` / `flushes` / `mem_entries`；`live_keys` 改为真扫一遍
    （memtable 的墓碑和 SST 的旧值都不能计入）
  - JSON 解析失败与引擎报错分开报，否则 Corruption 会被误报成 bad json

**测试**

- `varint_wbtest.mbt`：7 条，含**逐字节黄金向量**（不只是往返）
- `block_wbtest.mbt`：12 条，含完整 block 的黄金向量、1000 条随机 key 往返、
  restart 结构、二分查找边界、墓碑语义、乱序拒绝、结构损坏
- `sstable_wbtest.mbt`：10 条，含 1 万条写回、跨 block、64 KiB 大 value、
  bloom 无假阴性、坏文件不 panic、footer 区域首尾相接
- `iter_wbtest.mbt`：7 条，含随机多来源与参考实现对拍
- `db_wbtest.mbt`：9 条，含 2000 步随机操作与 `Map` 参考模型对拍
  （mem_limit 设成 300 字节，确保真的发生几十次 flush）

实测（1 万条 `key:%06d -> value:<i>`）：SST 187 KB / 44 个 data block /
filter 12.5 KB / index 613 B / 平均每条 19 字节。
`model_check.py` 2000 步 × seed 1/7/11 全部零错误。

### 变更

- `model_check.py` 现在会先探测引擎是否支持持久化，不支持时**自动关闭重启测试**
  并打印说明。默认 `--restart-every 1000` 在没有 WAL 的阶段必然产生几百条假 FAIL，
  把真正的正确性错误淹掉。Week 2 加上 WAL 后，重启测试会自动恢复，不需要改脚本
- **磁盘格式修订（v1 发布前）**：data block 的 entry 增加 `seq`（`varint64`）。
  初版规范只在 footer 放 `smallest_seq`，实现 compaction 时会立刻崩塌 ——
  归并多个 SST 时无法判断同一 key 哪条更新（文件编号只在 L0 能当序用），
  快照读也无法定位单个 key 的版本。详见 `docs/design/format.md` §3.2.1。
  由于 v1 尚未发布（还没有 SST 写入器），不涉及格式迁移

### 缺陷修复

- `write_varint32` / `write_varint64` 编码时**漏置续位 `0x80`**：
  128 被写成 `00 01`，解码端读到第一个没有续位的字节就停下，得到 0。
  这是「只做往返测试」抓不到的错误类型 —— 往返能过是因为编码器和解码器错得一致；
  被 `varint_wbtest.mbt` 的逐字节黄金向量抓到
- `block` 解码重建 key 时误用 `prev_key[:]`（整个上一条 key）而不是
  `prev_key[:shared]`：`aab` 被解成 `aaab`，且 `get` 全部落空。
  被 1000 条往返测试抓到

### 计划中（v0.2.0 · Week 2）

- `wal.mbt`：§2 的帧格式 + CRC32C + 恢复时截断尾部坏帧
- `manifest.mbt`：§4 的全量快照 + CURRENT 原子 rename
- `fs.mbt`：边界层的文件读写与 fsync（核心仍只处理 Bytes）
- `compact.mbt`：L0 → L1 的归并 compaction，输出后清理输入
- `db.mbt` 接入 `open(path)` / `close()`，进程重启不丢数据

### 已知技术债

- `SstWriter` 把所有 key 留在内存里建 bloom（需要预先知道元素个数）。
  1 万条约 100 KB，可以接受；到百万级要改成两遍写或可增长的 bloom
- `Db::scan` 与 `SstReader::entries` 会一次性解出所有 SST 的全部条目。
  小规模正确且简单，但读放大会随 SST 变大线性增长。
  改成惰性的 block 级迭代器是 v1.1 的事（接口不变）
- 没有 compaction，SST 数量只增不减，读路径的 SST 扫描是 O(文件数)

---

## [0.1.0] - 2026-10-21

首个可运行版本。**不含持久化**：dbcli 仍是内存 Map 占位，重启即丢数据。

### 新增

**核心数据结构**

- `types.mbt`：`Key` / `Value` / `Entry` / `Op` / `WalRecord` / `KvPair`
  - `Entry` 带 `deleted : Bool` 墓碑标记。**不能用「value 长度为 0」表示删除** ——
    那样无法区分「写入空字符串」和「删除这个 key」，会导致删除失效或空值消失
  - `Op::to_entry` 是「外部意图 → 内部条目」的唯一转换入口，墓碑语义只在一处定义
- `error.mbt`：`LsmError`（`Io` / `Corruption` / `Closed`）+ 三个便捷构造器
- `bloom.mbt`：Bloom Filter，10 bit/key、k=7、FNV-1a 双哈希
- `memtable.mbt`：有序数组 + 二分查找的内存写缓冲
  - `insert` / `put` / `delete` / `apply(WalRecord)` 四条写入路径
  - `compare_bytes` 返回值严格规范化为 `-1 / 0 / 1`，调用方可安全写 `== -1`
  - `compare_strings` 把 UTF-8 编码细节收进库内，避免调用方误用 `String::compare`

**测试基础设施**

- `cmd/dbcli`：stdin/stdout 行 JSON 协议，8 个命令（put / putmany / get / del / scan / flush / stats / close）
  - 每行响应后强制 flush stdout，避免管道模式全缓冲导致测试脚本死等
  - scan 端点比较使用字节序（`compare_strings`），不用 `String::compare`
  - JSON 提取层（`jget` / `as_str` / `as_arr` / `as_num`）一律返回 `Option`，不做隐式类型转换
- `benches/python/crash_test.py`：kill -9 崩溃一致性测试，区分「已确认」与「未确认」写入
- `benches/python/model_check.py`：以内存 dict 为标准答案的随机对拍
- `benches/python/bench.py`：顺序/随机写吞吐、读延迟 P50/P95/P99、范围扫描、空间放大
- `benches/python/mock_dbcli.py`：带故障注入开关（`--no-sync`）的假实现，用于自测测试脚本本身
- `benches/python/probe_persistence.py`：探测当前构建是否已支持持久化
  - `exit 0` 支持 / `exit 1` 未支持（跳过崩溃测试）/ `exit 2` dbcli 起不来（真错误）
  - 存在的理由：M0/M1 阶段跑崩溃测试必然全红，让 CI 习惯性红着比没有 CI 更危险

**文档**

- `docs/design/format.md`：磁盘格式规范 v1（WAL / SSTable / MANIFEST / CURRENT），**已冻结**
  - data block 每条记录带 1 字节 `type`（`0x00` 值 / `0x01` 墓碑）
- `docs/adr/0001-single-package.md`：单包多文件而非按模块拆包
- `docs/adr/0002-wal-format.md`：WAL 一条记录一帧；MANIFEST 用全量快照
- `docs/adr/0003-crash-contract.md`：崩溃一致性契约 C1–C5 与测试分层 L1–L4
- `docs/engineering/PROCESS.md`：命名考究、参考对象分层、GIV 开发模型、设计模型与 8 张流程图、项目→产品四阶段演进
- `docs/engineering/ACCEPTANCE.md`：验收手册 —— 这个库要干什么、四类契约、五关验收、8 个参考库位置、发布前清单
- `benches/python/REFERENCES.md`：LevelDB / Pebble / Badger / mini-lsm 等跨语言实现调研
- `PLAN.md`：模块拆分、三周排期、风险止损

**工程基础设施**

- `.moon-version`：记录项目开发与验证所用的工具链版本（`0.1.20260827`）。
  **它锁不住 CI** —— 官方 CDN 只提供 `latest` 的二进制，带版本号的路径一律 403
- `.github/actions/setup-moonbit`：跨平台安装 MoonBit CLI 的 composite action
- `.github/workflows/ci.yml`：格式检查（告警）+ 三平台 `check --deny-warn` / `test`（阻断）+ 多后端构建
- `.github/workflows/crash.yml`：崩溃一致性测试，PR 上需打 `crash-test` 标签才跑
- `.githooks/pre-commit`：提交前跑 `check --deny-warn` 与 `fmt`
- issue forms（bug / feature）+ PR 模板 + `SECURITY.md` + `CONTRIBUTING.md`

**缺陷修复**

- `cmd/dbcli` 的 `read_line` 原来逐字节 `Int::unsafe_to_char` 拼接字符串，
  等于假设输入是 Latin-1。中文（3 字节 UTF-8）会被拆成三个字符产出乱码。
  改为按字节累积 + 一次性 `@utf8.decode_lossy`，中文键值可正常往返

### 已验证

- `moon check --deny-warn`：**零警告**通过
- `moon test`：16 个测试通过
  - 含墓碑回归测试「墓碑与空 value 必须可区分」
  - 含字节序回归测试「按字节序而非长度优先」
- `model_check.py --ops 400`：seed = 1 / 2 / 3 / 5 / 7 / 11 全部 PASS，0 错误
- `mock_dbcli.py --no-sync`：能稳定复现「已确认写入丢失」，证明测试脚手架本身有效
- `probe_persistence.py`：对内存占位实现返回 1，对 `mock_dbcli.py` 返回 0

### 已知限制

- **无持久化**：dbcli 用内存 Map 占位，`--restart-every` 与 `crash_test.py` 尚不适用
- **无 WAL / 无 compaction / 无 MANIFEST**：格式规范已定义，代码未实现
- **`kill -9` 测不出「忘了 fsync」**：只杀进程不清页缓存。当前测试层级为 L2，
  完整覆盖需 L3（WAL 尾部截断注入）与 L4（VM 断电），见 ADR-0003
- **单线程**：无并发读写，无 group commit
- **仅小端平台**：`open()` 会检测端序，非小端直接拒绝
- **工具链版本漂移**：官方 CDN 只提供 `latest`，带版本号的二进制路径全部 403，
  因此无法在 CI 里锁定版本。`0.1.20261016` 的 `moon fmt` 会把 `Int` 重写成 `Int32`，
  而本项目验证版本 `0.1.20260827` 里**根本没有 `Int32` 这个类型**，所以代码只能写 `Int`。
  后果：
  - CI 的格式检查会产生 diff，因此设为**告警不阻断**（格式由本地 pre-commit hook 保证）
  - `check --deny-warn` 在新版工具链下可能因 `Int` 的废弃警告失败——届时需要整体升级
  - **升级不可逆**：旧版本已无法下载，升级前务必确认新版本下能编译
  - 升级步骤见 `CONTRIBUTING.md`「工具链版本：能记录，但锁不住」

### 许可证

MIT。已发布的 0.1.0 对获取者永久有效；若将来因企业用户需求改用带专利条款的许可证，
只会影响之后发布的版本，不会回溯。详见 `docs/engineering/PROCESS.md` §1.4。

---

## 版本号怎么定

| 变更类型 | 版本位 | 例子 |
|---|---|---|
| 破坏性 API 变更、磁盘格式不兼容 | MAJOR（0.x 期间为 MINOR） | 改 `put` 签名、改 WAL 帧布局 |
| 新增向后兼容的功能 | MINOR | 加 `scan` 的反向遍历、加 compaction 策略选项 |
| 修 bug、文档、性能优化 | PATCH | 修 CRC 计算、改 README、优化 bloom 哈希 |

**磁盘格式与库版本的关系**：库版本 MINOR 升级时，磁盘格式可能不变（新增 API 而已）。
判断兼容性请看 `docs/design/format.md` 里的 `version` 字段，不要看库版本号。
