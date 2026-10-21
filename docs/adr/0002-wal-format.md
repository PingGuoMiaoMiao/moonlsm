# ADR-0002：WAL 一条记录一帧，MANIFEST 用全量快照

- **状态**：已接受（Accepted）
- **日期**：2026-10-21
- **决策者**：chendev
- **影响范围**：`wal.mbt`、`manifest.mbt`、`docs/design/format.md` §2 §4

---

## 背景（Context）

有两个必须落地的格式决策，它们看起来无关，其实源于同一条判断：**什么时候该用日志式（log-based），什么时候该用状态式（state-based）。**

### 决策点 1：WAL 里一条逻辑记录会不会跨帧

LevelDB 的 WAL 是 32 KiB 定长 block，一条记录如果超过 block 剩余空间，会被切成 `First` / `Middle` / `Last` 三种片段，跨 block 拼接。这样做的好处是 block 边界对齐、便于按 32 KiB 单位刷盘。

代价是恢复逻辑复杂：要维护「正在拼接的片段缓冲」，要处理 `First` 之后来了个 `First`（说明中间丢了片段）这种非法序列，还要判断「只有 `First` 没有 `Last`」时是截断还是 corruption。LevelDB 的这块代码（`log_reader.cc`）不到 200 行，但边界条件极多，是公认的 bug 温床。

我们的 value 上限是 `MAX_VALUE = 4 MiB`（见 `Options`），远小于常见 WAL 大小。**没有任何一条记录会因为太大而必须跨帧。**

### 决策点 2：MANIFEST 用增量 log 还是全量快照

LevelDB / RocksDB 的 MANIFEST 是 WAL 格式的增量 log：每次版本变更（新增 SST、compaction 完成）追加一条 `VersionEdit`，恢复时从头重放全部 edit 得到当前版本。

好处是写入量小。代价是：

- 恢复要重放全部历史，MANIFEST 会随 compaction 次数线性增长，需要定期「全量重写」压缩（LevelDB 里就是 `VersionSet::WriteSnapshot`）。
- 重放语义本身要正确：「重放到一半又崩溃」时，MANIFEST 尾部截断点必须与 WAL 的截断点语义一致，否则会出现「MANIFEST 认为某个 SST 存在，但 SST 没写完」的悬挂引用。
- 调试困难：出问题时需要人工重放一堆 edit 才能还原当时的状态。

---

## 决策（Decision）

### 1. WAL：一条记录一帧，禁止跨帧

帧格式：`[crc32c:4][length:varint32][type:1][payload]`，`type` 固定 `0x01`（完整记录），保留 `0x00`/`0x02` 给未来可能的 `First`/`Last`。

**约束**：单条 payload 上限 `MAX_RECORD = 64 MiB`。超过则 `put()` 直接返回 `LsmError::Io("value too large")`，不写入。

恢复时任何「读不满 / CRC 不对」都视为尾部损坏，截断到最后一条好帧，不报错。

### 2. MANIFEST：全量快照 + CURRENT 原子替换

每次版本变更写一个**全新的** `MANIFEST-<n>` 文件，包含完整的 `Version`（各层有哪些 SST、`last_seq`、`log_number`、`next_file_number`），然后用 `写 CURRENT.tmp → fsync → rename → fsync(dir)` 原子切换，最后删旧 MANIFEST。

不做增量 edit，不做重放。

---

## 理由（Rationale）

这两个决策共享同一条判据：

> **日志式的价值在于「只写增量、降低写放大」；但如果增量本身很小、频率很低，或者日志的重放语义会成为正确性风险，就应该改用状态式。**

- **WAL 必须用日志式**：它的全部意义就是「顺序追加、每写一条就要 fsync 一次」。写放大在这里不是缺点，是设计目标。
- **MANIFEST 不该用日志式**：SST 元信息每条约 40 字节，1 万个 SST 也才 400 KB；而 MANIFEST 切换频率是「每次 compaction 之后」，分钟级甚至更低。为了省这点写入量，引入一整套重放语义 + 定期压缩逻辑，投入产出比是负的。
- **WAL 不该跨帧**：跨帧唯一的收益是 block 对齐，而我们的记录本来就小。省下的这点对齐收益，换来的是 `First/Middle/Last` 状态机和它的全部边界 bug。

一句话：**WAL 的日志性是本质需求，MANIFEST 的日志性是历史包袱。**

---

## 后果（Consequences）

### 正面

- WAL 恢复逻辑约 40 行可写完，且行为可穷举：要么整帧完整，要么在帧边界截断。
- MANIFEST 恢复 = 一次反序列化，没有「重放到一半」的中间态。
- 调试友好：任何时候 `cat` 一个 MANIFEST 就能看到完整的数据布局（配一个 `dump-manifest` 子命令）。
- 崩溃注入测试的用例集大幅缩小：只需要测「帧截断在任意字节位置」和「CURRENT 指向不存在的文件」两类。

### 负面

- **大 value 会浪费 WAL 空间**：一条 3 MiB 的 value 会独占一帧，前后不共享 block。但因为不做 value log 分离（见 `PLAN.md` §5），value 本来就和 key 一起写，这个浪费不额外产生。
- **MANIFEST 写入量随 SST 数量线性增长**：SST 数量上千后，每次切换要写几百 KB。以每分钟一次的频率算，年写入量约 200 GB 量级——但这是**顺序写 + 立即被覆盖**，对 SSD 寿命的影响远小于 compaction 本身的写放大。
- **`MAX_RECORD = 64 MiB` 是硬限制**：需要存更大的 value 时，要么改格式（bump version），要么引入 value log。当前明确不支持。

### 触发重新评估的条件

1. 单库 SST 数量稳定超过 **5 万个**，且 MANIFEST 切换成为可测量的写瓶颈
2. 出现真实的「单 value > 64 MiB」需求
3. 引入 value log 分离（WiscKey 风格），此时 WAL 只需存 key + value 指针，跨帧问题自然消失

---

## 备选方案（Alternatives）

### 方案 A：WAL 用 LevelDB 式 32 KiB block + 跨帧分片（否决）

优点：与 LevelDB 格式兼容，理论上可以直接读 LevelDB 的 WAL（虽然没人需要）。
否决理由：为一个用不到的能力（超大记录）引入一套状态机，是典型的前期过度设计。而且它和「崩溃后必须能启动」这条第一属性直接冲突——分片序列的非法状态判定比单帧 CRC 难得多。

### 方案 B：MANIFEST 用增量 VersionEdit log（否决）

优点：写入量小，与 RocksDB 生态一致，将来若要实现「在线备份/复制」可直接复用 edit 流。
否决理由：见上文 Rationale。另外 `WriteSnapshot` 的压缩逻辑本身又是一处容易出 bug 的地方，而它解决的问题（MANIFEST 膨胀）在我们的规模下不存在。

### 方案 C：不用 MANIFEST，每次 `open()` 扫描 `sst/` 目录重建版本（否决）

优点：实现最简单，没有 CURRENT 原子性问题。
否决理由：**无法区分「已提交的 SST」和「compaction 写到一半的孤儿 SST」**。目录扫描看到 10 个文件，其中 2 个是崩溃时正在写、内容不完整的，扫进去就是数据损坏。必须有一个独立的「提交点」记录，这正是 MANIFEST + CURRENT 的作用。这个方案在面试和评审里常被提出，但它是错的——把它写进 ADR 是为了留下「我们考虑过并且知道为什么不行」的证据。

### 方案 D：用 SQLite / 单文件 + 固定 header 存元信息（否决）

优点：原子性由 SQLite 保证，省掉 CURRENT/MANIFEST 两套机制。
否决理由：引入外部依赖，与「纯 MoonBit 实现」的项目定位冲突；且 SQLite 的写入路径本身会成为性能瓶颈，掩盖掉 LSM 的写吞吐优势。
