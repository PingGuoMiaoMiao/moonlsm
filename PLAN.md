# moonlsm · 模块拆分与三周交付计划

> 目标：用 MoonBit 实现一个能扛 20 轮 kill -9 的嵌入式 LSM 引擎，4–10k 行，可发布到 mooncakes。
> 测试脚手架：`benches/python/`（三个测试脚本 + 协议 + 跨语言参考调研）
> 磁盘格式契约：[`docs/design/format.md`](docs/design/format.md)
> 架构决策：[`docs/adr/`](docs/adr/)
> **方法论与流程图：[`docs/engineering/PROCESS.md`](docs/engineering/PROCESS.md)**
>
> 本文只管「哪天做什么」。要问「为什么这样排」「什么算做完」「从项目到产品怎么走」，看 PROCESS.md。

---

## 0. 参考谁（先定这个，否则会走弯路）

| 用途 | 项目 | 怎么用 |
|---|---|---|
| **主模板：学结构与顺序** | **mini-lsm**（skyzh） | 按它的周/章顺序推进，每章先读再写。有 starter code 和测试 |
| **查代码细节** | **goleveldb**（syndtr） | LevelDB 的 Go 移植，结构 1:1；GC 模型接近 MoonBit，比读 C++ 省力 |
| **对标工程质量** | **Pebble**（CockroachDB） | 能跑之后，翻 `*_test.go` 补边界用例 |
| **查文件格式** | **LevelDB 源码** | SSTable / MANIFEST 格式以它为准 |
| 不要参考 | RocksDB、sled | RocksDB 太大；sled 长期 beta，可靠性有争议 |

### mini-lsm 的哪些东西不能抄

它是 Rust，下面这些是语言特有的，照搬会走偏：

| mini-lsm | MoonBit 里 |
|---|---|
| `Arc<MemTable>`、`Arc<RwLock<T>>` | **不需要**，GC 直接共享 |
| `Send + Sync`、生命周期标注 | **不存在**，删掉 |
| `crossbeam_skiplist` | 自己写跳表，或先用有序数组 |
| `bytes::Bytes` 零拷贝切片 | `Bytes` + 偏移量模拟 |
| 多层泛型 + trait bound | MoonBit trait 更轻，别照搬抽象层次 |

**能抄的**：数据结构、SSTable 布局、compaction 算法、测试设计、章节顺序。

---

## 1. 目录结构

`moon new` 生成的是「根目录即库包」，所以所有库代码平铺在根目录，`cmd/` 下是子包。

```
moonlsm/
├── moon.mod                 # 模块元信息（name/version/license）
├── moon.pkg                 # 库包配置（依赖写这里）
├── LICENSE                  # MIT
├── README.md                # 仓库首页（首屏六块）
├── README.mbt.md            # 会被 mooncakes 当文档页渲染
│
├── docs/
│   ├── README.md            # 文档索引
│   ├── design/format.md     # ✅ 已写：WAL/SST/MANIFEST 字节布局（已冻结）
│   └── adr/                 # ✅ 已写：0001 单包 / 0002 WAL格式 / 0003 崩溃契约
│
├── types.mbt                # ✅ 已写：Key/Value/Entry/Op/WalRecord/KvPair
├── error.mbt                # ✅ 已写：LsmError（Io/Corruption/Closed）
├── bloom.mbt                # ✅ 已写：BloomFilter（10 bit/key, k=7）
│
├── memtable.mbt             # 内存有序表
├── block.mbt                # SSTable 的 block 编解码
├── sstable.mbt              # SST 文件读写 + 索引 + bloom
├── iter.mbt                 # 归并迭代器（memtable + 多层 SST）
├── wal.mbt                  # 预写日志（长度前缀 + CRC）
├── manifest.mbt             # 版本管理（哪些 SST 属于哪一层）
├── compaction.mbt           # 分层合并
├── db.mbt                   # 对外 API（open/put/get/delete/scan/close）
│
├── *_test.mbt               # 黑盒测试（走公开 API）
├── *_wbtest.mbt             # 白盒测试（测内部不变量）
│
├── cmd/
│   └── dbcli/               # ✅ 已写：测试协议入口（给 benches/python 的三个脚本用）
│       ├── moon.pkg
│       └── main.mbt         # 当前是内存 Map 占位，等 db.mbt 完成后换成真 Db
│
└── benches/python/          # ✅ 已迁入：崩溃测试 / 对拍 / 基准 + 跨语言参考调研
    ├── README.md            # dbcli 的 8 命令协议定义
    ├── crash_test.py        # kill -9 崩溃一致性测试
    ├── model_check.py       # 用内存 dict 当标准答案对拍
    ├── bench.py             # 吞吐 / 延迟 / 空间放大
    ├── mock_dbcli.py        # 假实现（含 --no-sync 故障注入开关）
    └── REFERENCES.md        # LevelDB/Pebble/mini-lsm 等跨语言实现调研
```

**为什么单包多文件而不是多包？**
MoonBit 的包边界会限制可见性，而 LSM 的模块之间耦合很紧（compaction 要同时看到 memtable 和 sstable 的内部结构）。单包多文件省掉大量 `pub` 和 import 摩擦。等稳定后再按需拆包。
完整论证见 [`docs/adr/0001-single-package.md`](docs/adr/0001-single-package.md)。

---

## 2. 模块拆分

依赖方向是单向的，从下往上：

```
types / error / bloom          （无依赖）
        ↑
      block → sstable
        ↑        ↑
     memtable  manifest
        ↑        ↑
        └── iter ┘
             ↑
            wal
             ↑
        compaction
             ↑
            db
```

| 文件 | 职责 | 关键数据结构 | 测试点 |
|---|---|---|---|
| `types.mbt` | 基础类型 | `Entry{key,value,seq}`、`Op` | — |
| `error.mbt` | 统一错误 | `LsmError{Io,Corruption,Closed}` | — |
| `bloom.mbt` | 读放大优化 | `BloomFilter{bits,k}` | 无误判漏（false negative 为 0） |
| `memtable.mbt` | 内存写缓冲 | 跳表 / 有序数组 + `size` 阈值 | 覆盖写、墓碑、有序遍历、超限触发 flush |
| `block.mbt` | SST 的最小单元 | `Block{data, restart_points}` | 前缀压缩编解码往返、坏数据不 panic |
| `sstable.mbt` | 磁盘文件 | `Sst{path, index, bloom, first,last}` | 写入后读回一致、跨 block 边界、大 value |
| `iter.mbt` | 归并多路有序流 | `MergeIter`（按 seq 取最新） | 同 key 多版本只出最新、墓碑被吞掉 |
| `wal.mbt` | 崩溃恢复 | `WalRecord{seq,op}` + 长度前缀 + CRC | 截断尾部能启动、fsync 后才 ack |
| `manifest.mbt` | 版本管理 | `Version{levels: Array[Array[SstMeta]]}` | 重启后层信息正确、原子切换 |
| `compaction.mbt` | 合并 | `Compaction{inputs, outputs}` | 墓碑在最底层才丢、合并期间读不阻塞 |
| `db.mbt` | 对外 API | `Db{mem, imm, version, wal, opts}` | 全部集成测试 |

### 核心类型（已编译验证）

```moonbit
type Key = Bytes
type Value = Bytes

pub struct Entry {
  key : Key
  value : Value
  seq : UInt64
  deleted : Bool     // 墓碑标记，不能用「value 长度 0」代替
}

pub enum Op {
  Put(Key, Value)
  Delete(Key)
}

pub suberror LsmError {
  Io(String)
  Corruption(String)
  Closed
}
```

> 注意：`typealias` 在 0.9 已废弃，用 `type Alias = Type`。`pub struct` 的字段默认不可变，需要改的字段加 `mut`。
>
> `deleted : Bool` 是踩过一次坑之后补上的：最初只有 `key/value/seq`，想用「value 长度为 0」表示删除，
> 但这样无法区分「写入空字符串」和「删除这个 key」——删除会失效，或者空值会凭空消失。
> 现在 `Op::to_entry` 是唯一的转换入口，墓碑语义只在一处定义。

---

## 3. 对外 API

只暴露 6 个方法，其余全是内部实现。**边界越窄，验收越容易过。**

```moonbit
pub struct Db { ... }

pub fn open(path : String, opts : Options) -> Db raise LsmError
pub fn put(self : Db, key : Key, value : Value) -> Unit raise LsmError
pub fn get(self : Db, key : Key) -> Value? raise LsmError
pub fn delete(self : Db, key : Key) -> Unit raise LsmError
pub fn scan(self : Db, start : Key, end : Key, limit : Int) -> Array[KvPair] raise LsmError
pub fn close(self : Db) -> Unit raise LsmError

/// 测试专用：强制刷盘并 fsync。生产代码不该暴露，但 dbcli 需要。
pub fn fsync(self : Db) -> Unit raise LsmError
```

`Options` 至少要有：`memtable_limit`、`level_ratio`、`bloom_bits_per_key`、`sync_on_write`。

**关键设计**：`put` 默认不 fsync（快），`fsync` 单独暴露。dbcli 的 `sync:true` 就是调它。这样性能测试和崩溃测试能分开跑。

---

## 4. 三周任务

### Week 1：能跑起来（MemTable → SST → 读写路径）

对应 mini-lsm Week 1。**目标：`put/get/scan` 在内存 + 单个 SST 上正确工作，不要求崩溃恢复。**

| 天 | 任务 | 验收 | 状态 |
|---|---|---|---|
| D1 | `memtable.mbt`：有序表 + put/get/iter | `moon test` 覆盖写、墓碑用例通过 | ✅ 完成 |
| D2 | `varint.mbt` + `block.mbt`：前缀压缩 + restart point 编解码 | 往返测试 1000 组随机 key 通过 | ✅ 完成（含逐字节黄金向量） |
| D3 | `sstable.mbt`：写 SST（data block + index block + footer） | 写 1 万条后能读回 | ✅ 完成（含 filter block） |
| D4 | `sstable.mbt`：读 SST + 二分查 index | 随机读 1000 次全对 | ✅ 完成（与 D3 一并交付） |
| D5 | `bloom.mbt` 接入 SST，写时生成、读时先查 | 不存在的 key 能跳过文件 | ✅ 完成 |
| D6 | `iter.mbt`：memtable + 单 SST 的归并 | 同 key 多版本只返回最新 | ✅ 完成（含差分测试） |
| D7 | `db.mbt` 串起来（无 WAL、无 compaction） | `model_check.py` 能跑到 500 步不报错 | ✅ 完成（2000 步 × 3 seed 零错误） |

D2 的实际交付比原计划多一个文件：`varint.mbt`。原因是 varint 是 WAL / block /
MANIFEST 三处格式的共用底座，混在 `block.mbt` 里会让「WAL 编码错」和
「block 编码错」这两类问题纠缠在一起。单独成文件后，D3 写 SST 和 Week 2 写 WAL
都直接复用它。

D3 与 D4 合并交付：写与读的接口一旦确定，分两次提交反而会让「写完不能读」
这个中间状态停留更久。`SstReader` 的 `get` / `entries` 与 `SstWriter` 同一次提交，
测试也是同一次跑通的。

**Week 1 实际收尾状态**：`put / get / delete / scan / flush` 全部打通，
`moon test` 61 条全绿，`model_check.py` 2000 步 × 3 个 seed 零错误，
CLI 手工驱动验证过「flush → 删除 → 再 flush → 读不到」这条跨 SST 的墓碑路径。
缺口只有一个但很关键：**没有 WAL，进程退出数据就丢**。这正是 Week 2 第一件事。

**Week 1 结束时的状态**：数据只在内存和一个 SST 里，重启就丢。这是正常的。

### Week 2：能活下来（WAL + compaction + MANIFEST）

对应 mini-lsm Week 2。**目标：kill -9 不丢已确认数据，数据量涨了能自动合并。**

| 天 | 任务 | 验收 | 状态 |
|---|---|---|---|
| D1 | `crc32c.mbt` + `wal.mbt`：帧格式、恢复截断 | 任意位置截断都不 panic、只丢尾部 | ✅ |
| D2 | `storage.mbt` + `fs_native.mbt`：存储后端抽象与真落盘 | 断电语义在 `moon test` 里可断言 | ✅ |
| D3 | `manifest.mbt`：记录每层有哪些 SST，原子切换 | 重启后层信息正确 | ✅ |
| D4 | `db.mbt` 接入 `Storage`：WAL / SST 真落盘 | 进程重启数据还在 | ✅ |
| D4b | 组提交：`putmany` 一批只 fsync 一次 | 200 条批次 1200ms → 12ms | ✅ |
| D5 | `compact.mbt`：L0 → L1 的简单合并 | 合并后数据不丢、墓碑保留 | ✅ |
| D6 | 分层触发条件 + 墓碑只在最底层丢弃 | 「删除后重写」用例通过 | ✅ |
| D7 | 全链路联调 | `crash_test.py --rounds 20` 全绿 | ✅ |

D2 是计划外插进来的，但它其实**必须先做**：ADR-0003 承诺了 C1「已确认的写入必不丢」，
而 `kill -9` 根本测不出「忘了 fsync」（进程被杀时 OS 页缓存还在）。
没有 `MemStorage` 的双影子模型，C1 在 CI 里没有任何证据。
同时它把三个平台差异（`fsync`/`_commit`、`rename`/`MoveFileExA`、
返回值约定相反）一次性收进了一个文件。详见 `docs/adr/0004-storage-abstraction.md`。

D4b 也是计划外的，但它决定 demo 能不能成立。把 `db.mbt` 接上真落盘后，
`crash_test.py` 一轮只能写 200 条 —— 因为每条 `put` 都在单独 fsync，
而每次 `fopen`/`fclose` 在 Windows 上要 5.9ms。改成组提交后一轮能写 5 万条。
详见 `docs/adr/0005-group-commit.md`。

D3 顺带把磁盘布局切成了规范里的 `wal/<n>.wal` + `sst/<n>.sst` + 全局共享编号。
原来的扁平 `WAL-000001` / `SST-000001` 双计数器在引入 WAL 轮转（每次 flush
换一个新 WAL）之后就不成立了：两个计数器会各自撞上对方用过的号。

实现过程中推翻了一条自己写进 `format.md` 的设计：原本打算「MANIFEST 读不出来
就退回编号次大的那份」，写完发现这**会丢掉已经 ack 的数据**（那些数据在更新的
SST 里，旧 MANIFEST 不认识它），直接违反 C1。改成拒绝启动。见 ADR-0006。

**D7 比 D3/D5/D6 先达成，这不是跳步。** 持久化的正确性只依赖
「WAL 先落盘 + 恢复时先 SST 后 WAL」，与「SST 有几层」「层信息存在哪」无关。
所以 `crash_test.py` 在 D4 就能全绿，而 compaction 和 MANIFEST 解决的是
**可扩展性**（文件数不能无限涨）和**元信息可靠性**，不是「数据会不会丢」。这个区分在答辩时值得讲清楚：
先证明契约成立，再谈规模。

**D5 + D6 一起做，因为「墓碑能不能丢」决定了要不要第三层。**
最初打算只做 `L0 + L1`，但那样「目标层是不是最底层」恒为真 ——
这个判定永远不会被证伪，而它判错的后果是「删掉的数据复活」。
加了 L2 之后两条路径都能在测试里真实走到。详见 ADR-0007。

D6 同时改掉了一处「碰巧正确」的实现：归并后内存里 SST 的排列顺序。
原来是手工拼「幸存的老文件 + 新文件追加在后面」，在「归并只碰重叠文件」
的前提下两种顺序结果一样；但 `get` 靠 `ssts[0]` 是最新文件做短路、
**不比较 `seq`**，一旦放宽重叠判定就会静默读到旧值。现在改成照着
`version` 重排，与 `recover()` 用同一套规则，唯一事实来源是版本快照。

**Week 2 结束时的状态**：功能完整，可以开始录 demo 了。

### Week 3：能拿奖（打磨 + 展示）

| 天 | 任务 | 验收 | 状态 |
|---|---|---|---|
| D1 | `crash_test.py --rounds 20` | 20/20 通过 | ✅（两个种子各 10 轮） |
| D2 | 损坏注入测试（截断 / 单字节翻转 / 文件缺失） | 不 panic，策略与 `format.md` §5.3 一致 | ✅ |
| D3 | `bench.py --n 1000000`，出对比表 | 有 vs moonkv / SQLite 的数据 | ✅（SQLite 已有，moonkv 未做） |
| D4 | 性能优化：bloom 调参、block size、compaction 策略 | 读放大或写放大有可量化改善 | ✅（bloom 重写 + 文件区间剪枝：未命中 −41%、扫描 3.6×，见 ADR-0008；block size 未调） |
| D5 | 文档：README（中英）、架构图、benchmark 表 | 别人能照着跑起来 | ✅（README.md + README.en.md，Mermaid 架构图） |
| D6 | 发布 mooncakes + CI + 在线 demo | `moon publish` 成功 | ✅（0.2.0 已上架，Server 200 OK；CI 三个 workflow） |
| D7 | 申报书 + 90 秒 demo 视频 | 提交 | 🟡（申报书一页 PDF 已成稿，见 `docs/submission/`；视频待录） |

D2 的产出不只是测试，还有一张**损坏处理总表**（`format.md` §5.3）：
按「坏在哪」分类，每类只有一个策略。判据始终是同一条 ——
任何自动决策都不能丢已经承诺不丢的数据。所以 WAL 坏了截断（它只是暂存区），
MANIFEST / SST 坏了拒绝启动（它们是已 ack 数据的唯一载体）。

同时把「没有 block CRC」这个取舍量化了：173 字节的 SST 逐个位置翻转，
42% 被拒绝、58% 被静默接受。这个数字比一句「暂不支持」有用得多。

D4 的结论和原计划不一样。计划里写的是「bloom 调参」，
但量下来发现**参数本来就是对的**（10 bit / 7 哈希，实测误判率 0.830%，
理论 0.819%），错的是别的地方：一次未命中要探 77 个文件。
所以改的是三件事 —— 位图打包、哈希只算一遍、先用 key 区间排除文件。
block size 没调：默认 4 KiB 与 LevelDB 一致，而扫描的瓶颈在
「把整层条目读进数组再归并」的架构上，不在块大小上，调它没有可解释的收益。

D7 的申报书按「一页」做，这是硬约束不是偏好：评审一天看几十份，翻页就是掉分。
结构固定为 痛点 → 边界 → API → 测试策略 → 里程碑，全部内容塞进 A4 单页
（字号 8.7pt 是实测上限，再大 0.05pt 就溢到第二页）。
**「边界清晰」比「功能多」更能过审**，所以「不做」那一栏和「做」同样具体，
并且带一句否决理由。数字一律取自 `BENCHMARK.md` 与 `ACCEPTANCE.md`，
不重新组织——材料里的每个数都要能在仓库里找到出处。

---

## 5. 关键选型（提前定，别中途改）

| 问题 | 建议 | 理由 |
|---|---|---|
| MemTable 用什么 | **先有序数组，后换跳表** | 数组能过所有正确性测试，先用它把逻辑跑通；跳表是性能优化，第 3 周再做 |
| key 比较 | 自己写 `compare_bytes`（逐字节 + 长度） | 别依赖 String，二进制 key 必须支持 |
| seq 作用 | 同 key 多版本取最大 seq | MVCC 的最小实现，也是墓碑判定的依据 |
| SST 是否压缩 | **不做** | 压缩会让格式调试难度翻倍，且不影响评审核心关注点 |
| compaction 策略 | **先 leveled，后考虑 tiered** | leveled 空间放大低、逻辑直观；tiered 写放大低但读放大高 |
| 是否做 MVCC/事务 | **Week 3 有余力再做** | 不是核心评分点，崩溃一致性才是 |
| 是否做 value log 分离 | **不做** | 这是 WiscKey 的优化，个人项目做不完，且会拖垮进度 |

---

## 6. 与测试脚手架的对接

`cmd/dbcli` 必须实现 [`benches/python/README.md`](benches/python/README.md) 里的 8 个命令（put / putmany / get / del / scan / flush / stats / close）。最容易踩的坑：

1. **每行输出后必须 flush stdout**，否则 Python 脚本会一直等（管道模式下 stdout 是全缓冲）
2. **`sync:true` 的响应必须在 fsync 返回之后才发**，否则崩溃测试全废
3. **恢复时不要 panic**，坏数据走 `LsmError::Corruption` 并降级
4. **scan 的端点比较必须用字节序**，不能用 `String::compare`（它按长度优先，会漏掉长 key）

> 坑 4 是实际踩过的：`model_check.py` 报 `最终 scan key 集合不一致 got=3 want=109`，
> 根因就是 `String::compare` 的语义与字节序不同。现在已改用 `compare_bytes`。

联调顺序：

```bash
# 1. 先用 mock 确认脚本环境正常
cd benches/python && python mock_dbcli.py --path ./data   # 另开一个终端手测协议

# 2. 换成自己的实现（先跑小规模）
cd moonlsm && moon build --target native
cd benches/python && python model_check.py \
  --cmd "../../_build/native/debug/build/cmd/dbcli/dbcli.exe --path ./data" --ops 500

# 3. 逐级加压
python model_check.py --ops 5000 --restart-every 1000
python crash_test.py --rounds 20
python bench.py --n 1000000
```

当前进度：`model_check.py --ops 400` 在 seed = 1/2/3/5/7/11 下全部 PASS（0 错误）。
但 dbcli 仍是内存 Map 占位，`--restart-every` 与 `crash_test.py` 尚不适用。

---

## 7. 风险与止损

| 风险 | 概率 | 止损方案 |
|---|---|---|
| 三周做不完 compaction | 中 | 砍到「只做 L0→L1 两层」，仍能讲清原理 |
| WAL 恢复写不对 | 中 | 先只支持「追加写 + 全量重放」，不做 checkpoint |
| 性能比 moonkv 还差 | 低 | 如实报告，重点讲「内存不随数据线性增长」这个结构性优势 |
| MoonBit 语法踩坑太多 | 中 | 每个文件先写最小可编译版本，`moon check` 通过再加逻辑 |
| 时间不够 | 高 | **优先保 Week 1 + Week 2 的 WAL**，这两个决定「能不能交」 |

---

## 8. 里程碑进度

### M0 · 工程骨架（✅ 已完成）

- [x] 模块改名 `lsm` → `moonlsm`，`moon.mod` 补齐 license / keywords / repository
- [x] `README.md` 重写为真实文件（首屏六块 + 能力矩阵 + 明确不做什么）
- [x] `README.mbt.md` 精简为 mooncakes 文档页短版
- [x] 测试脚手架从工作区根目录迁入 `benches/python/`
- [x] `cmd/dbcli` 协议壳（8 命令 + 每行 flush），内存 Map 占位
- [x] `model_check.py` 在 6 个随机种子下 PASS
- [x] `docs/design/format.md`（已冻结）+ 3 条 ADR
- [ ] CHANGELOG / SECURITY / CONTRIBUTING
- [ ] GitHub Actions CI + crash workflow
- [ ] issue / PR 模板 + 首次 commit

### 下一步（Week 1 D1）

1. 清掉模板遗留的 `lsm.mbt` / `lsm_test.mbt`（占位代码）
2. 按 `docs/design/format.md` §3.2 写 `block.mbt`，前缀压缩编解码往返测试
3. `moon test` 全绿后进 `sstable.mbt`

> 提示：本机 MoonBit 版本 `0.1.20260827`。语法细节以 `moon check` 的报错为准，别信记忆——
> 比如 `typealias` 在这个版本已废弃，要用 `type Alias = Type`；
> `Map::new()` 也已废弃，要用 `Map([])`；`String::compare` 按长度优先，二进制 key 必须用 `compare_bytes`。
