# 更新日志

本文件记录 moonlsm 的所有重要变更。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本 2.0.0](https://semver.org/lang/zh-CN/)。

> **关于 0.x 版本**：在 1.0.0 之前，MINOR 版本可能包含破坏性变更。
> 每次破坏性变更都会在下方明确标注 **BREAKING**，并给出迁移说明。
> 磁盘格式的变更额外要求 bump `docs/design/format.md` 里对应结构的 `version` 字段。

---

## [0.3.0] - 2026-10-26

**磁盘格式版。** 给 SST 里的 data block、index block、filter block 各加了
4 字节尾部 CRC32C，`version` 从 1 升到 2（ADR-0010）。

这一版修的不是性能，是**正确性**：v1 的 SST 只有 footer 的 magic 和区域边界检查，
block 内部没有校验。一个落在 block 中间的字节翻转，结构仍然自洽，
会被静默接受 —— 读出来可能是原值，也可能是别的值，而引擎自己不知道。

代价早就量化过：把一个 173 字节的 SST 逐个位置翻转，42% 被拒绝、**58% 被静默接受**。
现在是 185 个位置里 **177 个被拒绝（95.7%）**，剩下 8 个全在 footer 的
`smallest_seq` 上（48 字节 footer 里没地方再塞一个 CRC，见 `format.md` §3.5）。

**BREAKING（磁盘格式）**：新写的 SST 一律是 `version = 2`。
读端同时认 1 和 2，**0.2.x 建的库不需要迁移工具**，直接能开；
这些老文件在下一次 compaction 之前仍然带着原来的盲区（CRC 是格式自带的，
老文件里没有）。降级到 0.2.x 读 0.3.0 写出的库则**不行** ——
`version > 当前支持` 会按 `format.md` §5.2 拒绝启动。

### 改动

- **data block / index block**：尾部加 `crc32c`，覆盖 entry 区 + restart 数组 +
  `num_restarts`。校验范围含结构区，因为 `num_restarts` 被改成「仍能通过边界检查
  的值」时，读端会把 entry 区当 restart 数组读，这种损坏结构检查永远抓不到
- **filter block**：尾部加 `crc32c`。filter 看起来只是加速用的，但位图被改坏时
  `may_contain` 会返回 `false`，于是引擎理直气壮地回答「没有这个 key」——
  这是整个存储栈里唯一一种会**主动丢数据**的损坏方向。加 CRC 之前，
  fuzz 显示 filter 区域 80 个位置**全部漏检**，是整份文件里最大的一块盲区
- **校验时机在打开时，不在读 key 时**：`Db::get` 返回 `Bytes?`，无法表达
  「这个块我读不懂」。有了 CRC 之后，读时才发现损坏就只能回答 `None`，
  也就是对用户撒谎说「没有」。`Db::open` 本来就要遍历每个 SST 的 `entries()`
  算 `max_seq`，顺路校验，任一 block 失败即拒绝启动
- **读端双版本**：`decode_block` / `decode_block_v1`、`decode_bloom` /
  `decode_bloom_v1`，按 footer 的 `version` 分派，判断收在
  `decode_block_ver` / `decode_bloom_ver` 两个函数里，不散在五个调用点
- **footer 仍然没有 CRC**，并且现在是唯一没被覆盖的地方。理由不是「不重要」，
  是「没地方」：读端从文件末尾倒推 48 字节定位 footer，这个常量不能随版本变，
  否则得先知道版本才能算 footer 在哪，而版本就在 footer 里

### 测试

211 条（+6），native 全绿；wasm-gc / js 根包全绿；三后端 `check` 零警告。

- `block_wbtest.mbt`「任意单字节损坏都会被 CRC 拦下」：逐字节改坏，
  `decode_block` 必须全返回 `None`
- `block_wbtest.mbt`「v1 格式（无 CRC）仍可解码，且与 v2 只差尾部 4 字节」
- `bloom_wbtest.mbt` 两条：同样的逐字节校验，以及 v1 filter 的兼容
- `sstable_wbtest.mbt`「v1 格式的老文件仍能打开且内容一致」：
  造一份 v1 SST，逐条比对 key / value / seq，点查与扫描也各走一遍
- `sstable_wbtest.mbt`「不认识的版本必须拒绝打开」：版本改成 3 必须被拒
- `corruption_wbtest.mbt` fuzz 改了断言方式：原来只断言「不 panic」，
  现在断言「**必须发现**」，并且把漏检位置的**范围**钉死
  （必须落在 footer 的 `smallest_seq` 区间）。以后谁删了某个 CRC，
  这条用例会红，并且直接指出漏在哪

### 文档

- 新增 `docs/adr/0010-block-and-filter-crc.md`，含「为什么校验在 open 时」
  和「为什么 footer 加不了」两条推导，以及 6 条否决过的备选方案
- `docs/design/format.md`：§3.2 / §3.3 补 CRC 布局，§3.5 重写 footer 那段
  （从「这是有意识的取舍」改成「这是唯一剩下的盲区，以及为什么修不了」），
  §5.2 版本演进表补 `1 → 2` 这个先例，§5.3 损坏处理总表重写，§6 待实现清单更新
- `docs/README.md`：ADR 表补上 0009 与 0010（0009 之前漏登记了）

---

## [0.2.2] - 2026-10-26

**写路径的性能版。** 0.2.1 之后单条 `put` 还是 76 ops/s（13.2 ms/条），
而 SQLite 是 498 ops/s —— 这个差距在 `BENCHMARK.md` 和申报书的「已知局限」
里挂了三天。

拆开量下来，钱花在「每条写开关两次文件」上：在这台机器上开一次关一次
就是 **7.10 ms**（500 次 × 3 轮中位数），而 `fsync` 只要 1.62 ms。
旧路径 9.97 ms = 7.10 + 1.62 + 残差，量级对得上。

这一版让 `NativeStorage` 常开一个追加句柄（ADR-0009）：**单条 `put`
76 → 390 ops/s（同场 6.3×）**，组提交那组 +42%。磁盘格式不变。

### 性能

**常开 WAL 句柄（ADR-0009）**

同场 A/B（改动前后的两个二进制交替跑，`--n 2000 --batch 1 --sync`）：

| 指标 | 改动前 | 改动后 |
|---|---:|---:|
| 顺序写（单条提交） | 56–64 ops/s（15.6–17.9 ms） | **384–399 ops/s**（2.5–2.6 ms） |
| 随机写（单条提交） | 80–83 ops/s | **475–476 ops/s** |
| 顺序写（20 万条 · 批 1000 · sync） | 21 359–23 008 ops/s | **30 410–31 402 ops/s**（+42%） |
| 随机写（同上） | 11 832–12 788 ops/s | **15 443–17 039 ops/s**（+37%） |

改动内容：

- 新增 `NativeStorage::handle_for`：命中缓存直接返回句柄，否则关旧开新；
- `append_file` / `append_frames` 复用它，每次追加后 `fflush`（另开句柄的
  `read_file` 要能立刻看到刚写的字节 —— 恢复路径正是这么用的）；
- `sync_file` 命中缓存时在同一个 fd 上 `fflush` + `fsync`，不再 `fopen("rb+")`；
- `write_file` / `rename_file` / `remove_file` **无条件**关掉缓存：截断、
  改名、删除与「还开着的句柄」混用，在 Windows 上是直接失败，在 POSIX 上
  是静默的数据错乱。多关一次的代价只是一次 `fopen`；
- 新增 `NativeStorage::close()`，给需要确定性释放的场合（测试收尾、工具）。
  `Db` 没有 `close()`，所以缓存句柄活到进程结束由 OS 回收 —— 一个句柄，
  不是泄漏累积。

**语义没变**：`append_*` 仍然不隐含 `fsync`，`sync_file` 仍是 C1 的唯一实现点。
`kill -9` 之后 WAL 里的字节一个不少（`fflush` 已把数据交给 OS，进程死不掉
页缓存），5 轮崩溃测试与 2000 步对拍全过。

### 测试

205 条（+7）。新增的 7 条测的不是「快了多少」，而是「缓存了句柄之后，
原本靠 `fopen`/`fclose` 隐式保证的事情还成不成立」：截断 / 删除 / 改名之后
的追加位置、`fflush` 的可见性、对不存在的文件 `fsync` 仍要报错。

### 文档

- `BENCHMARK.md` §2 重写：单条 `put` 的归因、A/B 数据、以及一条反证
  （关掉 `sync` 后两版一样快，说明追加路径的 `fopen` 本来就不贵）；
- 新增 §5.6：读延迟的 A/B 必须用「同一份数据的两个副本 + 只发读请求」
  单独做，否则写阶段的进程状态会污染结果（工具 `benches/python/read_ab.py`）；
- 更正 ADR-0005 留下的「一次 `fopen` 5.9 ms」：今天这台机器上是 7.10 ms
  （500 次 × 3 轮中位数），量级一致，之前写成 0.83 ms 是单轮小样本测错了；
- 新增 §3.5「与 moonkv 的对照」：补上计划里一直没做的那个对比。写了个
  适配器（`benches/moon/moonkv_cli/`）让 moonkv 跑同一套 `bench.py`，
  1 万条单条提交：moonlsm 482 ops/s（每条 fsync）对 moonkv 96 ops/s
  （只 `fflush`）。**预测是反的**，`REFERENCES.md` 里那句「写吞吐更高」
  已划掉并说明原因。

---

## [0.2.1] - 2026-10-25

**读路径的性能版。** 0.2.0 之后把点查量了一遍，发现 bloom 参数本来就是对的
（10 bit/key、k=7，实测误判率 0.830% 对理论 0.819%，k=6 在噪声内，k=8 起变差）——
错的是别的地方：一次未命中要探 77 个文件，每个文件算 2 遍 FNV 再做 7 次
`UInt64` 取模，光哈希就 3.6 µs，而整个点查才 10 µs。

这一版只改这条路径：**未命中 P50 −41%，范围扫描 3.6×**，写路径与磁盘格式不变。
单元测试 180 → 198（新增 12 条 bloom 直接测试 + 6 条文件区间测试）。

### 性能

**bloom 重写 + 文件级 key 区间剪枝（ADR-0008）**

100 万条数据的同场 A/B（`git worktree` 建两份二进制，背靠背跑）：

| 指标 | 改动前 | 改动后 |
|---|---:|---:|
| 命中 P50 | 0.067 ms | **0.053 ms**（−21%） |
| 未命中 P50 | 0.068 ms | **0.040 ms**（−41%） |
| 范围扫描 | 32 412 rows/s | **117 483 rows/s**（3.6×） |

改动内容：

- **位图在内存里也按位打包**。原来 `Array[Bool]` 一个 bit 占一字节，
  10 bit/key 的 filter 膨胀 8 倍；改成 `Array[Byte]` 后内存表示与磁盘表示
  完全一致，`encode` / `decode` 从「逐位重排」变成整段拷贝。
  100 万条 / 77 个文件：10 MiB → 1.25 MiB。
- **哈希只算一遍**。原来两个种子各跑一遍 FNV-1a；改成一遍 FNV + 一次
  splitmix 终混派生 `h2`（Kirsch–Mitzenmacher 双哈希）。
  再把哈希提到 `Db::get` 的循环外，77 个文件从 77 次哈希降到 1 次。
- **取模换 fastrange**。`(x & 0xFFFFFFFF) * n >> 32` 替代 `x % n`，
  一次未命中原本要 539 次 `UInt64` 真除法（约 3.6 µs）。
- **先用 key 区间排除文件，再问 bloom**。`SstReader` 新增 `range`，
  `hi` 取 index 最后一条、`lo` 取首块第一条。L2 内文件有序且不重叠，
  一次未命中在 77 个文件里 76 个能被两次 `memcmp` 排除。
  同一个判断也用在 `scan_range` 开头，区间不相交的文件直接跳过。

### 新增

- `benches/moon/bloom_probe`：bloom 误判率对照实验工具。
  扫 bits/key ∈ {4,6,8,10,12,16,20} 与 k ∈ {1..12}，同时输出
  「实际置位数 / 理论置位数」的分布诊断。**这个诊断抓到了一个真 bug**：
  直接取 FNV-1a 的高 32 位做探测位置，会让 10000 条 key 只落进约 1000 个
  位置（理论 9516），而误判率看起来只有理论值的一半 —— 像是「比理论还好」，
  实际是分布塌了。详见 ADR-0008。
- `bloom_wbtest.mbt`：12 条 bloom 直接测试。此前 bloom 只被 sstable 的用例
  间接覆盖，只能证明「用起来没崩」，证明不了它在省 IO。
- `sstable_wbtest.mbt` 加 6 条：文件区间必须真实包住所有 entry、
  端点 key 可查、区间外查不到、空文件不启用范围判断、单条 entry、区间不相交。
- `Block::first` / `Block::last`：取块的首尾条目。
  `last` 是 `seek` 做不到的（key 是任意二进制，没有「比所有 key 都大」的哨兵）。
- `docs/adr/0008-bloom-layout-and-file-range-pruning.md`。

### 修正

- **`BENCHMARK.md` 的组提交倍数从 1.09× 更正为 1.40×**。原来的 1.09× 是在
  机器状态更好时测的；同场 A/B 显示 `sync:true` 的代价是 1.40×。
  更重要的发现写进了「测量方法的局限」：**跨会话的数字不能互相比**，
  同样的代码隔一天再测，20 万条顺序写差 6%、`sync:true` 那组差 26%。
  所以本版起，凡是要下结论的对照一律用同场 A/B。

### 文档

- `docs/submission/`：一页申报书（`APPLICATION.md` + 排版源 `application.html`
  + 成品 `application.pdf`）。结构固定为 痛点 → 边界 → API → 测试策略 → 里程碑，
  A4 单页。字号 8.7pt 是实测上限，再大 0.05pt 就溢到第二页。
- `docs/README.md` 的 ADR 索引补齐到 0008 —— 此前只列到 0003，
  后五篇决策在索引里查不到。同时新增 `submission/` 一节的职责说明。

---

## [0.2.0] - 2026-10-21

**可嵌入。** 0.1.0 是一个「不含持久化」的可运行骨架；0.2.0 把持久化整条链路打通，
并补上让外部用户能真正用起来的三件事：可跑的示例、写下来的 API 契约、
以及三后端构建门禁。

这一版的核心不是「功能变多」，而是**把崩溃一致性测明白**：`kill -9` 20 轮
零丢失、5000 步随机对拍零错、9 条损坏注入 + 逐字节 fuzz 全部只报错不 panic。

### 新增

**示例与契约（本次发布新增）**

- `examples/basic`：可跑的最小示例，`moon run examples/basic` 直接出结果
  - 演示 put / get / put_deferred + sync / scan / delete / close 六件事
  - 每一步注释写清「为什么这么设计」，而不只是「这行在干什么」
- `docs/design/API.md`：API 冻结草案
  - 把公开符号分三级：稳定级 / 观测级 / 内部级，明确哪些**不**属于契约
  - 语义承诺单独成节（`put` 返回即持久、`get` 的 `None` 合并两种状态、
    `scan` 左闭右开、`flush` 幂等、`close` 只标记状态）
  - 冻结的是签名与语义，**磁盘格式不冻结** —— 格式一旦承诺就再也优化不动

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

**存储后端抽象（Week 2 D2）**

- `storage.mbt`：`Storage` trait + `MemStorage`
  - 引擎只依赖 trait，不直接碰任何 IO 原语。这不是「可插拔」的架构洁癖，
    而是为了让崩溃契约可测：`MemStorage` 维护「当前视图」与「已落盘」两份影子，
    `power_loss()` 回滚到后者，于是「已 fsync 的写入必不丢」变成一条
    **确定性的、进程内的、三个后端都能跑**的断言
  - `append_file` 与 `sync_file` 刻意分开：合成一个会锁死
    「写 N 条、sync 1 次」这个 WAL 最重要的性能手段
  - 故障注入：`set_fail_sync` / `set_fail_write` / `plant`
- `fs_native.mbt`：`NativeStorage`，真文件系统（仅 native 后端）
  - `fopen` / `fwrite` / `fflush` / `fsync` / `rename` / `remove` / `mkdir` / 目录列举
  - 平台差异全部用 `#cfg(platform = "windows")` 收在本文件内，
    核心逻辑一行平台判断都没有
  - 64 位定位（`_fseeki64` / `fseeko`）：Windows 的 `long` 是 32 位，
    `fseek` 只能到 2 GiB
- `docs/adr/0004-storage-abstraction.md`：决策记录，含三个平台坑的实测结论

**真落盘（Week 2 D4）**

- `db.mbt` 重写为 `Db[S]`：泛型 + 真 WAL + 真 SST，**进程重启数据还在**
  - 写入顺序 `分配 seq → 追加 WAL 帧 → fsync WAL → 写 memtable → 可能刷盘`，
    这是契约 C1 的全部内容
  - `flush` 顺序 `写 SST → fsync SST → 读回校验 → 才清 memtable 和 WAL`
  - `recover` 顺序 **先 SST 后 WAL**。反过来的话，SST 里的旧值会「碰巧」
    因为 memtable 短路而读对，一旦 memtable 里没有那个 key 就暴露 ——
    这种错在测试里极难复现
  - `sst_name` 六位零填充：`list_files` 按字节序排序，不填充会让
    `SST-10` 排在 `SST-9` 前面，恢复时新旧顺序整个反掉
  - WAL 尾部截断用**重写**而不是 `ftruncate`（Windows CRT 没有该符号）
  - trait 静态分发（`Db[S]` 泛型而非 trait object），无虚表开销
- `fs_native.mbt` 新增 `open_native(dir, mem_limit)`：非泛型跨包入口，
  让 `cmd/dbcli` 不必写 `Db[NativeStorage]` 的类型标注
- `cmd/dbcli` 接真引擎，数据目录来自环境变量 `MOONLSM_DATA`
  - 跨进程持久化手工验证通过：写入 → 重启 → 读回 → 目录里
    `SST-000001` + `WAL-000001` 都在

**组提交（Week 2 D4b）**

- `Storage::append_frames(name, chunks)`：一次 `fopen` + N 次 `fwrite`
  - 实测每次 `fopen`/`fclose` 在 Windows 上约 **5.9 ms**，且与写入字节数无关。
    200 条的批次因此要 1.2 秒，其中 99% 是开关文件的开销
  - `MemStorage` 实现为一次性拼接（循环 `append_file` 是 O(N²) 字节拷贝），
    与 `NativeStorage` 的语义等价性由两个后端各一条测试锁住
- `Db::put_deferred` / `delete_deferred` / `sync`：批量写路径
  - `put_deferred` 把帧攒进 `pending`，`sync()` 时一次 `append_frames` + 一次 fsync
  - `putmany(200)`：**1200 ms → 12 ms**；`crash_test` 单轮写入量 200 → 50000 条
  - C1 不变：ack 发出之前 fsync 一定已成功。变的只是「一批里 fsync 几次」
- `docs/adr/0005-group-commit.md`：决策记录，含「两条路径失败可见性不同」的说明

**MANIFEST 与目录布局（Week 2 D3）**

- `manifest.mbt`：版本快照的编解码
  - `Version{last_seq, log_number, next_file_number, levels}` + `SstMeta{number, file_size, smallest, largest}`
  - 全量快照而非增量 log：只有「读成功 / 读失败」两种结果，
    不需要「重放到一半又崩溃」那套状态机（ADR-0002 同一思路）
  - `decode_manifest` 的校验顺序是「长度 → magic → version → **CRC** → 逐字段」，
    CRC 放在解析之前：先解析的话，一份随机垃圾会让解析器分配一堆数组、
    走一堆分支，最后才发现「这是垃圾」
  - 坏数据防护：`num_levels` / 每层 SST 数 / key 长度都有上限。
    这些字段来自磁盘，一个坏值（`0x7FFFFFFF`）会让解码尝试分配几十 GB
  - 尾部必须**正好用完**：多余字节说明快照和解析器对格式的理解不一致，继续读就是在猜
  - `check_invariants()` 单独做语义校验（L1+ 同层不重叠且按 smallest 升序、
    `log_number < next_file_number`）。**L0 不检查重叠** ——
    它们来自不同时刻的 memtable，范围天然可以重叠
- **磁盘布局切换**：`wal/<n>.wal` + `sst/<n>.sst` + `MANIFEST-<n>` + `CURRENT`，
  文件编号**全局共享**（存在 MANIFEST 里）。
  原来的扁平 `WAL-000001` / `SST-000001` 用两个独立计数器，
  在引入 WAL 轮转后必然撞号
- `db.mbt` 接入 MANIFEST：`open` 读 CURRENT → 读 MANIFEST → 加载 SST → 重放 WAL
  - `flush` 变成「写 SST → 建新 WAL → 更新 version → 原子切 CURRENT → 删旧 WAL → 清 memtable」，
    每一步的崩溃点都有明确的恢复路径（见函数注释里的崩溃点分析）
  - WAL 轮转：每次 flush 换一个新的 `wal/<n>.wal`，旧的在 CURRENT 切换成功后删除
  - `bump_file_number_past_existing()`：打开时让 `next_file_number` 跳过目录里
    已存在的编号，避免覆盖崩溃遗留的孤儿 SST
- `storage.mbt` / `fs_native.mbt`：`list_files` 语义从「按名字前缀过滤」改为
  **「列某个子目录」**（返回 basename）。前缀过滤会把 `SST-1` 和 `SST-1.bak`
  一起捞出来，而目录列举天然只给真实存在的东西
  - `NativeStorage` 过滤掉 `.` / `..`，并跳过子目录 ——
    `readdir` 会把 `sst/` / `wal/` 也列出来，而契约是「这一层的**文件**」，
    两边语义必须一致，否则「内存后端跑绿的用例换真文件系统就红」
- `docs/adr/0006-refuse-to-open-on-bad-manifest.md`：**推翻**了 `format.md`
  原来的「MANIFEST 读不出来就退回次大编号」设计 —— 回退会丢掉已经 ack 的数据
  （那些数据在更新的 SST 里，旧 MANIFEST 不认识它），直接违反 C1。改为拒绝启动
- `docs/design/format.md` §4.3 重写：补上「拒绝启动的三种情形」和
  「为什么 MANIFEST 坏了不回退」的完整推导，并与 WAL 尾部截断做了对照

**归并 compaction（Week 2 D5 + D6）**

- `compact.mbt`：三层结构 `L0 → L1 → L2`，每层整层下沉
  - 触发条件拆成纯策略函数 `should_compact_level(lv, sst_count, bytes)`，
    不做任何 IO。这样边界（`>=` 还是 `>`、最底层要不要拦）能用任意数字单测，
    不必先写一个 1 MiB 的库
  - L0 按**文件个数**触发（4 个），L1 及以下按**字节数**触发（L1 = 1 MiB、
    L2 = 10 MiB）。L0 的文件大小由 memtable 上限决定，个数就代表体量；
    L1 的文件是按目标大小切的，个数多只说明数据多
  - `compact_level(src)` 把 `src` 层全部文件 + `src+1` 层与之范围重叠的文件
    归并进 `src+1`。`compact_l0()` 是 `compact_level(0)` 的别名
- **墓碑只在写进最底层时丢弃**（`is_bottom_level(dst)`）
  - 安全性依据：本次归并的输入已包含「所有可能藏着这个 key 旧值的文件」
    （上层全部 + 下层与之重叠的全部），旧值在归并中被淘汰，墓碑无物可遮。
    完整推导见 ADR-0007
  - 写进非最底层时**必须留着** —— 下面还有层，那里可能有更旧的版本。
    有一条专门的用例守这个断言（`count_entries(gone) == 1`）
  - 全是墓碑时 `merged` 为空，**不能提前 return**：那样这批墓碑会永远留在
    L0、每次 flush 重试一遍归并。正确做法是不产出文件但照常清空上层、切 CURRENT
- 为什么是三层而不是两层：只有两层时「目标层是不是最底层」恒为真，
  那个分支永远不会被证伪 —— 而它恰恰是判错后果最严重的分支
  （「删掉的数据复活」）。加了 L2 之后两条路径都能在测试里真实走到
- 内存视图重建改为 `reload_sst_view()`：按 `version` 重排（层号升序 +
  层内编号降序），与 `recover()` 同一套规则。原来是手工拼「幸存的老文件 +
  新文件追加在后面」，在 v1 下碰巧正确，但那是「归并只碰重叠文件」的副产品；
  一旦放宽重叠判定，`get` 会静默读到旧值（它靠 `ssts[0]` 是最新文件做短路，
  不比较 `seq`）
- `Version::level_bytes(lv)`：按层汇总字节数，供触发条件使用
- `docs/adr/0007-compaction-levels-and-tombstones.md`：三个决策的完整记录
  （三层、整层下沉、墓碑丢弃规则），含写放大代价与四个遗留问题

**损坏注入测试（Week 3 D2）**

- `corruption_wbtest.mbt`：9 条用例，把「磁盘上的字节坏了」按位置分类验证
  - WAL：中间某条 CRC 坏 / 长度字段被写坏 / 整个文件被清空 / 版本号不认识
  - SST：被截断 / 被清空 / footer magic 被改坏 / MANIFEST 登记的文件不见了
  - 拒绝启动的用例都断言**错误信息里带文件名** —— 只说「数据损坏」
    等于没说，面对几百 MB 的目录无从下手
  - 单字节翻转 fuzz：SST 里每一个字节逐个翻转，断言 `Db::open` 要么成功、
    要么报 `Corruption`，**绝不 panic、绝不越界读**（ADR-0003 不变量 I3）
- 注入必须用 `MemStorage::plant` 而不是 `Storage::write_file`：
  后者只改「当前视图」，紧接着的 `power_loss()` 会用 durable 那份盖回去，
  注入等于没做。第一版就是这么写的，四条用例全部「没有报错」
- `format.md` 新增 §5.3「损坏处理总表」：九种损坏位置，每类只有一个策略，
  判据始终是「任何自动决策都不能丢已经承诺不丢的数据」。
  同时把「没有 block CRC」的代价量化了 —— 173 字节的 SST 逐个位置翻转，
  **42% 被拒绝、58% 被静默接受**（这个数字进了测试注释，改 v1.1 时对照用）
- `format.md` §6 待实现清单更新：WAL 与 MANIFEST 已标完成，补上
  「data block 级 CRC（v1.1，会 bump `version` 到 2）」

**性能：scan 提速 47 倍 + 基准与参照（Week 3 D3/D4）**

- `SstReader::scan_range(start, end)`：用索引做**块级剪枝**，只解落在
  区间里的块。原来 `Db::scan` 对每个 SST 调 `entries()`，把整个文件解出来
  再筛，数据量一大 scan 就退化成 O(整个库)
  - 不接 `limit`：单看一个文件无法判断「前 N 条」是不是全局前 N 条，
    限制由调用方在归并之后施加
  - 块内过滤而不是块内二分：一个 block 只有 4 KiB / 一百多条，
    解出来再线性筛比再写一套「块内定位 + 向后遍历」简单得多
- CLI 两处 O(n²) 拼接：`items_json` 改用 `Buffer`（原来 500 条要拷十几 MB），
  `esc` 加「无需转义就直接返回原串」的快路径
  - **踩到的坑**：`Buffer::to_string()` 不是 UTF-8 解码，它把每个字节当成
    一个码位映射出去（`[` → `U+225B`），输出一串乱码。必须走
    `@utf8.decode_lossy(buf.to_bytes())`。单测抓不到、编译不报，
    只有端到端跑起来才看得见，所以把拼装抽成 `items_json` 并补了 5 条单测
- `KvPair::new`：跨包不能写结构体字面量（只读类型），而测试需要「凭空造一条」
- `benches/python/bench_sqlite.py`：同 workload 跑一遍 SQLite，作为
  数量级参照（不是竞品对比）
- `docs/engineering/BENCHMARK.md`：完整数据 + 每一处瓶颈的定位过程 +
  五条测量方法的局限（协议开销、`kill -9` 测不出漏 fsync、单次测量无中位数等）
- 实测（20 万条，value 100 字节）：范围扫描 **1 250 → 58 834 rows/s（47×）**，
  读 P50 0.081 → 0.060 ms，写吞吐基本不变
- 100 万条主表：顺序写 50 212 ops/s、随机写 12 724 ops/s、
  读 P50/P99 0.068/0.147 ms、空间放大 1.13×
- **组提交的量化**：批次 1000 时 `sync:true` 只慢 9%；批次 1 时顺序写从
  3 103 掉到 79 ops/s（39×）。SQLite 同条件下从 34 426 掉到 497 ops/s，
  量级一致 —— 这是 fsync 的物理成本，不是实现问题

### 变更

- `dbcli` 的 `stats` 增加 `levels` 字段（如 `[2,0,2]`），固定输出 `NUM_LEVELS` 个数字。
  归并是否正确光看 SST 总数看不出来 ——「L0 攒到 4 个」和「L1 只剩 2 个」
  这两个事实必须分开看。实测六轮 `putmany + flush` 的过程：
  `[1,0,0] → [2,0,0] → [3,0,0] → [0,0,2] → [1,0,2] → [2,0,2]`，
  第 4 轮 L0 满 4 个触发归并，L1 拿到 2 个文件后又因超过 1 MiB 直接沉到 L2
- README 的进度、API、能力矩阵更新到 Week 2 完成；CLI 示例的
  `--path ./data` 改为 `MOONLSM_DATA=./data`（`--path` 参数从来不存在）

- **`put` 与 `put_deferred` 的失败可见性有意不同**（详见 ADR-0005）：
  `put` 把 fsync 放在 memtable **之前**，fsync 失败时写入完全不可见；
  `put_deferred` 做不到（写第一条时无法预知最后的 `sync` 会不会成功），
  `sync` 失败时那批数据留在内存里可读、但无 ack、断电必丢。
  两条路径因此**不合并** —— 合并会悄悄丢掉「fsync 失败 ⇒ 完全不可见」这个性质
- `put_deferred` 不再逐帧写 WAL，帧留在内存里直到 `sync()`。
  好处是行为**确定**（不再是「取决于 OS 什么时候回写页缓存」），
  代价是崩溃后必然丢失 —— 本来就在「允许丢失」的范围内
- `benches/python` 三个脚本的数据目录统一由 `dbcli_launch.py` 提供。
  之前每个 `subprocess.Popen` 各自拼 env，漏一处 dbcli 就落回默认的
  `.moonlsm_data`，症状是 `model_check.py` 报
  `extra=['probe:persistence']` —— 看起来像引擎多返回了一个键，
  实际上是探测脚本写进了同一个库
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

三个**跨平台语义**问题，都是真跑起来才暴露的（详见 ADR-0004）：

- **`rename` 的返回值约定在 Windows 上是反的**。POSIX `rename` 返回 0 表示成功，
  Windows `MoveFileExA` 返回**非 0** 表示成功。最初直接透传返回值，
  症状是「改名成功时报错、失败时静默通过」—— CURRENT 切换会在 Windows 上彻底失效
- **Windows 的 `rename` 不能覆盖已存在文件**（POSIX 是原子覆盖）。
  CURRENT 每次切换都是「新名字覆盖旧名字」，用 `rename` 的话第二次 flush
  之后数据库就再也启动不了。改用 `MoveFileExA` + `MOVEFILE_REPLACE_EXISTING`，
  并加 `MOVEFILE_WRITE_THROUGH` 顺便解决持久性
- **`moonbit_read_dir_ffi` 返回 `FixedArray` 而不是 `Array`**。声明成 `Array[Bytes]`
  时，空目录能过、非空目录**直接段错误**（`0xc0000005`）
- `NativeStorage::prepare` 第一版只 `mkdir` 一次，而 `mkdir` 不建父目录，
  测试目录 `.moonlsm_test/rw` 拿到 `ENOENT`。改为逐级创建

`dbcli` 一启动就段错误（`0xc0000005`），排查耗时最长的一个：

- **同一个 C 符号被两处不同签名的 `extern "C"` 声明，指针在调用点被截断。**
  `cmd/dbcli` 自己声明了 `extern "C" fn fflush(Int) -> Int`，而库内按
  `UInt64` 传 `FILE*`；编译器只保留其中一个原型，于是 `FILE*` 被截成 32 位，
  `fflush` 内部解引用野指针
- 定位过程：`println` 打点被缓冲吞掉 → 换成带 `fflush` 的 `dbg()` →
  发现「`Db::open` 函数体根本没进去」→ 逐个排除（最小 main 正常、
  结构体包装正常、`read_line` 正常、非泛型入口仍崩）→
  最后靠「移除 dbcli 里的 `c_fflush` 调用」一次性解决
- 修法：库内提供 `pub fn flush_stdio()` 作为 `fflush` 的**唯一声明点**，
  dbcli 改调它。这类 bug 的教训不是「小心一点」，而是
  **同一个 C 符号只能有一个声明点**

### 计划中（v0.2.0 · Week 2 剩余）

- 孤儿 SST 回收：崩溃在「写完 SST」和「写 MANIFEST」之间会留下没人引用的文件
- compaction 从「整层下沉」改成「取一个文件下沉」，降低 L1 → L2 的写放大
- 崩溃测试从「5 轮手工验收」升级为 CI 门禁（G4）

### 已知技术债

- `SstWriter` 把所有 key 留在内存里建 bloom（需要预先知道元素个数）。
  1 万条约 100 KB，可以接受；到百万级要改成两遍写或可增长的 bloom
- `Db::scan` 与 `SstReader::entries` 会一次性解出所有 SST 的全部条目。
  小规模正确且简单，但读放大会随 SST 变大线性增长。
  改成惰性的 block 级迭代器是 v1.1 的事（接口不变）
- 没有 compaction，SST 数量只增不减，读路径的 SST 扫描是 O(文件数)
- `NativeStorage` 每次文件操作都 `fopen` / `fclose`，不保持常开句柄。
  批量路径已经用 `append_frames` 把「一批只开关一次」解决掉了
  （见 ADR-0005，200 条批次 1200ms → 12ms），但**单条 `put` 仍是每次
  开关文件两次**（一次 `append_file`、一次 `sync_file`），约 5.9 ms。
  彻底的解法是带缓冲的句柄表，代价是 fd 生命周期要显式管理
- `list_files` 依赖运行时的 `moonbit_read_dir_ffi`，它在 `opendir` 失败时
  返回 `NULL`，到了 MoonBit 侧就是一个空指针的 `FixedArray`——访问会段错误。
  目前靠「先 `prepare()` 保证目录存在」规避，长期应该换掉

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
