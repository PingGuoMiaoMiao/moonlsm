# moonlsm 磁盘格式规范 v1

> 状态：**已冻结（frozen）**。v1 发布后，本文件描述的字节布局不得在不 bump 版本号的前提下改动。
> 最后更新：对应 `moon.mod` version 0.1.0

本文档是**契约**，不是说明。实现必须服从本文档；如果实现与文档冲突，先改文档、再改实现、并在 CHANGELOG 里记一笔。

---

## 0. 通用约定

| 项目 | 约定 |
|---|---|
| 字节序 | 所有定长整数**小端序（little-endian）** |
| 变长整数 | LEB128（无符号），记作 `varint32` / `varint64` |
| 校验和 | **CRC32C**（Castagnoli 多项式 `0x1EDC6F41`，反射形式 `0x82F63B78`），4 字节 LE |
| 字符串 | `varint32 length` + `length` 字节原始数据（**不是** UTF-8 语义，key 可以是任意二进制） |
| 空值 | `length = 0` 与「不存在」是两回事，必须区分 |
| 文件命名 | `%06d` 十进制补零，编号单调递增，**永不复用** |

### 0.1 为什么是 CRC32C 而不是 CRC32

CRC32C 有硬件指令（SSE4.2 `crc32`、ARMv8 `crc32c`）。在 x86 上吞吐是软件 CRC32 的 5–10 倍，而 LSM 的 WAL 是热路径。Go 标准库、LevelDB、RocksDB 也都选它。

### 0.2 为什么所有整数小端

x86 / ARM 都是小端，读路径上少一次字节翻转。RocksDB 在 big-endian 平台上有专门的转换层，那是它们要付的代价；我们只支持小端平台，省掉这层复杂度，并在 `open()` 时检查（见 §5）。

---

## 1. 目录布局

```
<db_path>/
├── CURRENT                  # 文本文件，内容是当前 MANIFEST 的文件名 + "\n"
├── MANIFEST-000007          # 版本快照
├── wal/
│   ├── 000008.wal           # 活跃 WAL
│   └── 000005.wal           # 待清理的旧 WAL
└── sst/
    ├── 000004.sst
    └── 000006.sst
```

文件编号空间**全局共享**：WAL、SST、MANIFEST 从同一个单调递增计数器取号。这样任何两个文件不会撞名，恢复时也只需比较编号大小。

---

## 2. WAL 格式（`wal/<n>.wal`）

### 2.1 文件头（8 字节）

| 偏移 | 长度 | 字段 | 值 |
|---|---|---|---|
| 0 | 4 | magic | `"MWAL"`（`0x4D 0x57 0x41 0x4C`） |
| 4 | 2 | version | `0x0001` |
| 6 | 2 | reserved | 全 0 |

### 2.2 记录帧

一条逻辑记录 = 一帧，**不跨帧拆分**（见 ADR-0002 的取舍说明）。

```
+-------------+-------------+--------+---------------------+
| crc32c (4B) | length(varint32) | type(1B) | payload (length B) |
+-------------+-------------+--------+---------------------+
```

- `crc32c`：对 **`type` + `payload`** 计算，覆盖 `length` 之外的整帧。注意 `length` 自身不参与校验——如果 `length` 被写坏，我们会因为「读不满 length 字节」而判定为尾部截断，行为同样是停止重放，所以不必额外校验。
- `length`：payload 字节数，**不含** `type`。
- `type`：`0x01` = 完整记录（本版本只有这一种；`0x00` 与 `0x02` 保留给未来的「分片首段/续段」）。

### 2.3 payload 布局

| 字段 | 编码 |
|---|---|
| `seq` | `varint64` |
| `op` | 1 字节：`0x00` = Put，`0x01` = Delete |
| `key` | `varint32 len` + bytes |
| `value` | `varint32 len` + bytes（`op = Delete` 时**整段省略**，不是写 0 长度） |

### 2.4 恢复算法（必须按此实现）

```
seek 到文件头之后
last_good = 文件头结束位置
loop:
  读 4 字节 crc      → 读不满 4 字节: 跳到 truncate
  读 varint32 length → 读不满 / length > MAX_RECORD(64 MiB): 跳到 truncate
  读 1 + length 字节 → 读不满: 跳到 truncate
  校验 crc32c(type+payload) ≠ 记录的 crc → 跳到 truncate
  last_good = 当前文件位置
  解析并应用记录
truncate:
  把文件 ftruncate 到 last_good，fsync
  如果 last_good == 文件头结束位置 且 文件非空 → 整个 WAL 没有一条可用记录，正常（说明崩溃发生在第一条写入之前）
```

**关键点**：CRC 不匹配一律视为「尾部损坏」，直接截断到最后一个好帧，**不报错、不 panic**。理由见 ADR-0003：崩溃后必须能启动，这是嵌入式引擎的第一属性。

### 2.5 重放过滤

WAL 里可能有已经被 flush 进 SST 的记录。恢复时用 `MANIFEST.last_seq` 过滤：只重放 `seq > last_seq` 的记录。这依赖「flush 的顺序必须是：写 SST → fsync SST → 更新 MANIFEST → fsync MANIFEST → 才能清理 WAL」这条不变量。

---

## 3. SSTable 格式（`sst/<n>.sst`）

### 3.1 整体布局

```
+--------------------------+  offset 0
| data block 0             |
| data block 1             |
| ...                      |
+--------------------------+
| filter block             |
+--------------------------+
| index block              |
+--------------------------+
| footer (48 B)            |  ← 固定在文件末尾
+--------------------------+  EOF
```

读端流程：读末尾 48 字节 footer → 校验 magic 与 footer CRC → 用 index 定位 data block → 用 filter 快速否定。

### 3.2 data block

采用 **前缀压缩 + restart point**（与 LevelDB 同构，便于对照调试）。

```
entry_0:  type(1B) seq(varint64) shared(varint32) non_shared(varint32) value_len(varint32) key_delta[non_shared] value[value_len]
entry_1:  ...
...
+-----------------------------------+
| restart_offset[0]   (uint32 LE)   |   ← 每个 restart 点的字节偏移
| restart_offset[1]   (uint32 LE)   |
| ...                               |
+-----------------------------------+
| num_restarts        (uint32 LE)   |
+-----------------------------------+
```

- `type`：`0x00` = 正常值，`0x01` = **墓碑**（该 key 已删除）。
  - **不能用 `value_len == 0` 表示删除。** 那样无法区分「写入空字符串」和「删除这个 key」，会导致两种数据错误：一是删除被当成写入空值（删除失效），二是空值被当成删除（数据凭空消失）。这是 LSM 实现里最常见的静默 bug 之一，有专门的回归测试（`memtable_wbtest.mbt` 与 `block_wbtest.mbt` 各一条「墓碑与空 value 必须可区分」）。
  - 1 字节的开销在 4 KiB block 里可以忽略，换取的是语义无歧义。
- `seq`：这条记录的写入序号，`varint64`。**v1 修订时新增，见 §3.2.1。**
- `shared`：与**上一个 key** 的公共前缀长度。restart 点的 `shared` 恒为 0。
- `non_shared`：本条 key 去掉前缀后的长度。
- restart 间隔：**16 条**一条 restart point。
- 一个 data block 的目标大小：**4 KiB**（未压缩，见 §3.6）。超了就切下一块，且切点必须落在 entry 边界。
- block 内部 key 严格升序，**不允许重复 key**（同一 key 的多版本在 compaction 阶段已被折叠）。

查找算法：对 restart 数组二分 → 从该 restart 点线性扫描到下一个 restart 点。最坏 16 次 entry 解码。

### 3.2.1 为什么 entry 里必须带 `seq`（v1 修订）

初版规范只把 `seq` 放在 WAL payload 和 footer 的 `smallest_seq` 里，data block 的 entry 不带 `seq`。这个设计**在实现 compaction 时会立刻崩塌**，原因有两条：

1. **compaction 归并时必须知道谁更新。** 归并 N 个输入 SST 时，同一个 key 会出现多次。要挑出最新的一条，就必须逐条比较 `seq`。仅靠「文件编号大的更新」只在 L0 成立；一旦 compaction 输出到 L1、L1 内部有多个重叠文件，文件编号与 seq 顺序就没有保证关系了。
2. **快照读需要它。** 没有 `seq`，就没法回答「这个 key 在 seq=1000 时是什么值」。footer 里一个 `smallest_seq` 只能表达整个文件的下界，表达不了「文件内部每条各自的序号」。

**代价**：每条 entry 多 1–3 字节（`seq < 2^14` 时 2 字节）。一条 entry 通常 30–50 字节，开销约 5%。

**为什么存绝对值而不是相对 `smallest_seq` 的差值**：block 是按 key 升序追加的，`seq` 在 block 内**不单调**（先写 z 再写 a，block 里 a 在前但 seq 更大）。差值编码要求基准值在追加前就已知，而 `smallest_seq` 要等 block 关掉才能确定 —— 中间可能出现负差值。绝对值没有这个耦合，且 varint 本身已经把常见的小 seq 压到 2 字节，差值省不了多少。**宁可多 1 字节，也不要引入「基准值必须在写入前确定」这条隐含约束。**

> 这次修订正是 G2 门禁（格式冻结）存在的意义：问题在写第一行 block 代码时就被发现，返工成本是一段文档 + 一个字段；如果等 compaction 写完再发现，要重写编码器、解码器、所有往返测试和已经产生的测试数据文件。

### 3.3 filter block（Bloom）

```
| k (1B) | num_bits (varint32) | bits[ceil(num_bits/8)] |
```

- 默认 `bits_per_key = 10`，`k = 7`（由 `k = round(bits_per_key * ln2)` 得出）。
- 哈希：**双哈希构造** —— `h1 = FNV-1a 32(key)`，`h2 = FNV-1a 32(key 反转)`，第 i 个探测位置 `= (h1 + i * h2) % num_bits`。
- 语义是**允许假阳性、禁止假阴性**：`may_contain` 返回 false 时，key **一定不在**这个 SST 里。这条不变量有专门的测试（`bloom_wbtest.mbt`）。
- 一个 SST 只有一个 filter block（不按 data block 分段）。这是相对 LevelDB 的简化，代价是大 SST 的 filter 精度略降，收益是实现简单、格式少一层。

### 3.4 index block

index block **就是一个 §3.2 编码的 data block**，不另立格式。每条的含义：

| 字段 | 含义 |
|---|---|
| `key` | 该 data block 的**最大 key**（`last_key`） |
| `value` | `offset(varint64) + size(varint64)`，即该 data block 在文件中的位置与长度 |
| `type` | 恒为 `0x00`。索引条目不是键值数据，不存在墓碑 |
| `seq` | 恒为 `0UL`。索引条目不带版本 |

查找时找**第一个 `key >= 目标 key`** 的条目，它指向的 block 就是可能包含目标的那一块。
注意这是 `seek`（下界）语义，不是 `get`（精确匹配）语义。

**为什么复用而不是另立格式**：多一个格式就多一个编码器、一个解码器、一套往返测试、
一类「两处编码不一致」的 bug。代价是每条多 2 字节（`type` + `seq`）。
索引条目数 = data block 数（4 KiB 一块，100 万条数据大约 1 万个块），
2 字节 × 1 万 = 20 KB，相对于 SST 本身（几十 MB）可以忽略。
**用 20 KB 换掉一整类 bug，划算。**

> 顺带解释了为什么 §3.2 的 `type` 必须是独立的字节，而不能用「`value` 长度为 0」表示删除：
> 如果靠长度推断语义，索引条目（`value` 是 8–16 字节的 handle）与数据条目
> 就没法共用同一个解码器了。

读出来后整体驻留内存（一个 SST 的索引通常几百字节到几 KB）。

### 3.5 footer（固定 48 字节）

| 偏移 | 长度 | 字段 |
|---|---|---|
| 0 | 8 | `filter_offset`（uint64 LE） |
| 8 | 8 | `filter_size`（uint64 LE） |
| 16 | 8 | `index_offset`（uint64 LE） |
| 24 | 8 | `index_size`（uint64 LE） |
| 32 | 8 | `smallest_seq`（uint64 LE，本文件包含的最小 seq，用于快照读） |
| 40 | 4 | `version`（uint32 LE，= 1） |
| 44 | 4 | `magic`（`"MSST"`，`0x4D 0x53 0x53 0x54`） |

**footer 自身不做 CRC**。理由：footer 被写坏时 `magic` 校验基本必然失败（4 字节固定值），而 data block 的完整性由上层 `verify` 命令单独负责。为 footer 再加一个 CRC 字段会把 48 字节撑到 52，破坏对齐，收益不划算。这是有意识的取舍，不是遗漏。

> 待定：v1.1 若引入 block 级 CRC，会在 data block 尾部加 4 字节 CRC 并 bump `version` 到 2。

### 3.6 关于压缩

**v1 不做块压缩。** 这是 ADR 里明确记下的决策，不是没时间做。理由：压缩会让「格式调试」和「崩溃一致性验证」两件事的难度同时翻倍，而评审关注的是 LSM 结构与崩溃语义，不是压缩比。`version` 字段的存在就是为了将来加压缩时能平滑升级。

---

## 4. MANIFEST 格式（`MANIFEST-<n>`）

采用**全量快照 + 原子替换**，而不是 LevelDB 的增量 log。取舍见 §4.4。

### 4.1 布局

```
| magic "MMAN" (4B) | version (2B) | reserved (2B) |
| last_seq        (varint64)   |
| log_number      (varint64)   |   ← 当前活跃 WAL 的编号
| next_file_number(varint64)   |
| num_levels      (varint32)   |
| for each level:                                 |
|   count (varint32)                              |
|   for each sst:                                 |
|     number     (varint64)                       |
|     file_size  (varint64)                       |
|     smallest   (varint32 len + bytes)           |
|     largest    (varint32 len + bytes)           |
| crc32c of everything above (4B)                 |
```

### 4.2 CURRENT 文件的原子切换

这是整个引擎里**唯一一处依赖文件系统 rename 原子性**的地方，必须严格按序：

```
1. 写 MANIFEST-<new> 的全部内容
2. fsync(MANIFEST-<new>)
3. 写 CURRENT.tmp，内容为 "MANIFEST-<new>\n"
4. fsync(CURRENT.tmp)
5. rename(CURRENT.tmp, CURRENT)     ← 原子点
6. fsync(<db_path> 目录)             ← 保证 rename 本身落盘
7. 删除旧 MANIFEST
```

任何一步之前崩溃，`CURRENT` 都还指向旧 MANIFEST，旧的 SST 和旧 WAL 都还在，因此一定能恢复到一致状态。**删除旧文件必须放在第 6 步之后**，这是「先写后删」原则。

### 4.3 恢复流程

```
读 CURRENT → 得到 manifest 文件名 → 读该 MANIFEST → 校验 magic/version/CRC
→ 得到 Version{levels, last_seq, log_number}
→ 重放 wal/<log_number>.wal 中 seq > last_seq 的记录
→ 删除编号 < log_number 的 WAL 文件（它们的数据已在 SST 里）
```

若 `CURRENT` 缺失或指向的文件不存在：**报 `LsmError::Corruption` 并拒绝打开**。这是唯一一个「拒绝启动」的场景——因为没有任何依据推断数据布局，硬猜会静默丢数据。

若 MANIFEST 的 CRC 失败：尝试同目录下编号次大的 MANIFEST；都没有才报 Corruption。这是「CURRENT 被写坏」的兜底路径。

### 4.4 为什么是全量快照而不是增量 log

| | 全量快照 | 增量 log（LevelDB） |
|---|---|---|
| 实现复杂度 | 低，一次序列化 | 高，要处理「重放到一半又崩溃」 |
| 写入量 | 每次切换写全部元信息 | 只写增量 |
| 恢复速度 | 快，一次解析 | 要重放全部历史 |
| 元信息规模 | SST 数量 × ~40 字节 | 同左 |

SST 元信息本身很小（1 万个 SST 也才 400 KB），而 compaction 触发的 MANIFEST 切换频率是分钟级甚至更低。用全量快照换掉「重放语义」这一整类 bug，非常划算。这是 ADR-0002 同一思路的延续：**优先选状态式（state-based），避免日志式（log-based）**，除非那个日志本身就是被测对象。

---

## 5. 平台与兼容性

### 5.1 打开时的检查

`open()` 必须先做以下检查，任一失败返回 `LsmError::Corruption` 并**不创建任何文件**：

1. 检测端序（写一个 `uint16 = 1` 看首字节），非小端则拒绝
2. `CURRENT` 存在性（若整个目录为空 → 视为新建库，走初始化路径）
3. MANIFEST 的 magic / version / CRC
4. 引用的 SST 文件全部存在，且大小与 MANIFEST 记录一致

### 5.2 版本演进规则

| 场景 | 行为 |
|---|---|
| 读到 `version > 当前支持` | **拒绝打开**，报 Corruption 并说明需要升级 |
| 读到 `version < 当前支持` | 必须能读（向后兼容）。若不能，必须在 CHANGELOG 里写明并提供迁移工具 |
| 新增字段 | 只能追加到该结构的**末尾**，且旧字段偏移不变 |
| 删除字段 | 只能标记为 reserved 并跳过，不得让后续字段偏移变化 |

**永远不要**「猜一个未知版本怎么读」。宁可拒绝启动，也不要静默读出错误数据——后者是最坏的结果，因为它会污染用户的备份。

---

## 6. 待实现清单（v1 范围）

| 格式 | 状态 | 实现位置 |
|---|---|---|
| WAL 帧 + 恢复截断 | ⬜ 未实现 | — |
| data block 前缀压缩 | ✅ 完成 | `block.mbt` |
| index block | ✅ 完成 | `sstable.mbt` |
| filter block | ✅ 完成 | `bloom.mbt`（`encode` / `decode_bloom`） |
| footer | ✅ 完成 | `sstable.mbt` |
| MANIFEST + CURRENT 原子切换 | ⬜ 未实现 | — |

图例：✅ 完成 / 🟡 部分 / ⬜ 未实现

### data block 的完成标准

- [x] 编码字节与本文档 §3.2 逐字节一致（`block_wbtest.mbt` 的「黄金向量」测试）
- [x] 1000 条递增 key 往返逐条一致
- [x] restart 间隔为 16，restart 数组位置与计数正确
- [x] 前缀压缩确实生效（同长度随机 key 对比，体积至少小 15%）
- [x] `get` 二分查找命中全部 key，越界/不存在返回 `None`
- [x] `seek` 下界语义正确（index 查找依赖它）
- [x] 墓碑与空 value 可区分
- [x] 乱序/重复 key 直接报错，不写出坏 block
- [x] 结构损坏返回 `None`，不 panic

### SST 的完成标准

- [x] 写 1 万条后逐条读回一致（`sstable_wbtest.mbt`）
- [x] 1 万条切出多个 data block（否则跨块路径根本没被测到）
- [x] 大 value（64 KiB）不被硬切，往返正确
- [x] footer 各区域首尾相接、无缝隙无重叠
- [x] bloom 无假阴性（所有写过的 key 逐个验证）
- [x] 坏文件（短、magic 错、version 不支持、截断）一律返回 `None`
- [x] 墓碑写盘后仍可区分

实测规模（1 万条 `key:%06d -> value:<i>`）：SST 187 KB，44 个 data block，
filter 12.5 KB，index 613 B，平均每条 19 字节。前缀压缩把 key 部分的
6 字节公共前缀压掉了，这是 SST 总字节小于原始 KV 字节的原因。

---

## 附：格式速查（给实现者）

```
WAL 帧:    [crc32c:4][len:varint32][type:1][payload:len]
payload:   [seq:varint64][op:1][key:varint32+bytes][value:varint32+bytes]
SST:       data* | filter | index | footer(48)
data entry:[type:1][seq:v64][shared:v32][non_shared:v32][value_len:v32][key_delta][value]
           type: 0x00=值  0x01=墓碑
index 条目: 与 data entry 同格式；key = 该块 last_key
           value = offset(v64) + size(v64)；type 恒 0x00，seq 恒 0
filter:    k:1 num_bits:v32 bits[ceil(num_bits/8)]
footer:    filter_off:8 filter_sz:8 index_off:8 index_sz:8 min_seq:8 ver:4 "MSST":4
MANIFEST:  "MMAN":4 ver:2 rsvd:2 last_seq:v64 log_num:v64 next_num:v64
           num_levels:v32 [count:v32 [num:v64 size:v64 smallest:str largest:str]*]*
           crc32c:4
CURRENT:   文本，"MANIFEST-<n>\n"
```

### 两处 `type` 字节的区别（容易混）

| 位置 | 字段 | 取值 |
|---|---|---|
| WAL 帧头 | 帧类型 | `0x01` = 完整记录（v1 只有这一种） |
| data block 条目 | 条目类型 | `0x00` = 值，`0x01` = 墓碑 |

它们**语义完全不同**，只是碰巧都叫 `type`。WAL 的 `type` 描述「这一帧是否被拆分」，data block 的 `type` 描述「这个 key 是否被删除」。
