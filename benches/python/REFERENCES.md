# LSM 存储引擎 · 跨语言实现参考

> 目的：搞清楚「别人做到什么程度」，决定你该学什么、对标什么、以及比赛里怎么讲。
> 调研时间：2026-10-20

---

## 一、先回答一个隐含问题

你可能会想：**别的语言里 LSM 已经这么成熟了，我再写一个还有价值吗？**

有，但要摆正定位：

| 维度 | 现实 |
|---|---|
| 技术新颖性 | **零**。LSM 是 1996 年的论文，LevelDB 是 2011 年的代码，设计完全公开 |
| 生态价值 | **高**。MoonBit 生态里没有任何 LSM 实现（只有 Bitcask 风格的 `moonkv`） |
| 评委会怎么看 | 他们知道 RocksDB 存在。**他们要看的不是「你发明了什么」，而是「你在 MoonBit 里实现得对不对、好不好」** |
| 你的真实优势 | 从零实现意味着你能控制每一个细节，能把崩溃测试做得比 `moonkv` 完整，能讲清楚每个设计取舍 |

所以策略是：**不追求功能对齐 RocksDB，追求「小而正确 + 崩溃测试完备 + 有 MoonBit 特色」**。一个 6k 行、测试齐全、能扛 kill -9 的引擎，比一个 3 万行、跑不起来的「RocksDB 复刻」强得多。

---

## 二、各语言代表实现

### C++

| 项目 | 定位 | 规模 | 适合拿来做什么 |
|---|---|---|---|
| **LevelDB**（Google, 2011） | LSM 的「教科书实现」，RocksDB 的前身 | 小，核心代码一天能读完 | **通读源码的首选**。MemTable（跳表）、SSTable 格式、MANIFEST、compaction 全在里面，没有多余抽象 |
| **RocksDB**（Facebook, 2012-） | 工业级增强版：Column Family、事务、多种 compaction、prefix bloom | 很大 | **查设计，不要通读**。遇到具体问题去 wiki 查对应章节 |
| **Speedb** | RocksDB 分支，主打降低写放大 | 中 | 看它怎么优化 compaction |
| **TerarkDB**（字节） | 可搜索压缩 | 中 | 看压缩与 LSM 的结合 |

### Go

| 项目 | 定位 | 特点 | 适合拿来做什么 |
|---|---|---|---|
| **Pebble**（CockroachDB） | RocksDB 兼容的纯 Go 实现，production ready | 比 RocksDB 小得多；L0 sublevels、range deletion tombstone、table-level bloom filter；代码可读性好 | **最佳「工程化参考」**。想知道生产级 LSM 该有哪些测试和边界处理，看它 |
| **Badger**（Dgraph） | LSM + 分离式 Value Log（WiscKey 风格） | 大 value 不进 LSM，只存指针，显著降写放大；自带 value log GC | **看「KV 分离」这条路**，以及它踩过的坑（见第四节） |
| **goleveldb**（syndtr） | LevelDB 的 Go 移植 | 代码结构几乎 1:1 对应 C++ 版 | **想快速理解 LevelDB 结构，读 Go 版比读 C++ 快** |

### Rust

| 项目 | 定位 | 特点 | 适合拿来做什么 |
|---|---|---|---|
| **mini-lsm**（skyzh） | **三周教程**，从零写一个 LSM | Week1：MemTable / SST / 读写路径 / bloom filter；Week2：compaction（tiered + leveled）/ MANIFEST / WAL；Week3：MVCC / 事务 / SSI | **强烈推荐，这是最好的起点**。结构清晰，正好对应你要做的模块划分 |
| **sled** | 嵌入式 KV，API 友好 | 长期 beta；作者自己说过「如果可靠性是主要诉求，用 SQLite」 | 看 API 设计，别学实现 |
| **fjall** | LSM + value-log 分离，K.I.S.S 路线 | 活跃维护，代码比 sled 简洁 | 看「简化版 LSM」怎么砍功能 |
| **redb** | **B+ 树**，不是 LSM | 纯 Rust 嵌入式 KV | 作为对照组：讲清楚「为什么选 LSM 不选 B+ 树」 |

### Java / 其他

| 项目 | 说明 |
|---|---|
| **HBase / Cassandra / ScyllaDB** | 都是 LSM，但**是分布式系统**，不是嵌入式引擎。看它们的 memtable flush 和 compaction 策略即可，别当嵌入式参考 |
| **RocksDB JNI / LevelDB Java port** | 绑定/移植，没有独立设计价值 |

### MoonBit（你的竞争对手）

| 包 | 下载 | 架构 | 差距 |
|---|---|---|---|
| `wallll-wal6/moonkv` | 33 | **Bitcask**：追加文件 + 全量内存索引 | 没有分层、没有 compaction、内存随数据线性增长 |
| `Sxy11112/moonjournalkit` | 23 | 只做 WAL 分帧与恢复 | 是组件，不是引擎 |
| `mizchi/bitx_wal` | 13 | 对象存储上的 WAL | 场景不同 |
| `uiicvb/moonsql` | 15 | 纯 MoonBit 嵌入式 SQL 引擎 | 缺可靠存储层 |
| `codeworm96/magpiedb` | 33 | 轻量 OLAP | 自述 "vibe coded"，工程度低 |

**结论：LSM 这一层是真空白。** 上面这些要么是 Bitcask，要么是组件，没有分层合并的完整实现。

---

## 三、演化谱系（理解设计传承）

```
1996  O'Neil 论文：LSM-Tree 提出
        │
2011  LevelDB (C++, Google)  ← 简化版 LSM，教学与工业的分水岭
        ├──────────────► goleveldb (Go 移植，结构 1:1)
        │
2012  RocksDB (C++, FB)      ← 工业级：CF / 事务 / 多种 compaction
        ├──────────────► Pebble (Go, CockroachDB)  ← 砍功能、重工程
        ├──────────────► Speedb / TerarkDB         ← 各自优化一个点
        │
2016  WiscKey 论文            ← KV 分离，降写放大
        ├──────────────► Badger (Go, Dgraph)
        └──────────────► fjall  (Rust)
        │
2023  mini-lsm (Rust 教程)    ← 把上面所有设计拆成三周作业
        │
2026  ??? (MoonBit)          ← 你要填的格子
```

看懂这条线，你就知道每个项目在解决什么问题：**LevelDB 解决「怎么实现」，RocksDB 解决「怎么上生产」，WiscKey 解决「写放大」，mini-lsm 解决「怎么教」**。

---

## 四、最值钱的部分：Badger 踩过的三个坑

这三个是真实的生产 bug，正好对应你要写的测试。**答辩时讲出来，比背架构图有用十倍。**

### 坑 1：compaction 选层错误 → 已删除的数据「复活」

- **现象**：`DropPrefix` 之后，删掉的数据又出现了
- **原因**：选 Lbase 时只看尺寸比例（快但不安全），可能把 L0 的新数据（含墓碑）压到**旧版本下面**，墓碑被埋掉，旧值重新可见
- **修复过程很有意思**：改成「扫描空层」保证安全 → 但性能崩了（每刷一次 L0 就烧掉一层，Lbase 塌缩到 L1 钉死，写放大 3x，生产慢 2.97 倍）→ 最终方案是**尺寸比例 + 安全钳制**（`baseLevel ≤ 首个非空层`）
- **对你的启示**：`model_check.py` 里「删除后重写」的用例就是冲着这个去的。**墓碑的可见性和 compaction 顺序强相关**，这是 LSM 最阴的 bug

### 坑 2：L0 背压用忙等 → 延迟被量化成 10ms

- **现象**：写入延迟总是 10–20ms 的整数倍
- **原因**：L0 满了以后用 `sleep(10ms)` 轮询等待
- **修复**：改成条件变量/信号量，恢复时间从 10ms 降到 ~80µs，吞吐 +16%（181k → 212k ops/s）
- **对你的启示**：`bench.py` 报 P99 时，如果看到奇怪的量化台阶，八成是忙等

### 坑 3：损坏的 SSTable 导致整个进程 panic

- **现象**：文件 footer 被清零 → 长度读出 0 → **空校验和 `0 == 0` 误判为通过** → 解析空索引越界 → panic → 进程终止
- **修复**：解析函数返回 `error` 而不是二次 panic；校验 `checksumLen / indexLen` 的范围；后台 goroutine 加 `recover()` 兜底
- **对你的启示**：`README.md` 里「手动截断 WAL」那个测试就是干这个的。**校验和通过 ≠ 数据有效**，还要校验长度字段本身

---

## 五、三周学习路径（建议）

| 周 | 做什么 | 产出 |
|---|---|---|
| W1 | 读 **mini-lsm Week 1**（MemTable / SST / 读写路径 / bloom filter），用 MoonBit 实现同样的模块 | 能跑通 put/get/scan 的最小引擎 |
| W2 | 读 **mini-lsm Week 2**（compaction / MANIFEST / WAL）+ 翻 **goleveldb** 的 `db_compaction.go` | 有 WAL、有 leveled compaction、能重启恢复 |
| W3 | 读 **Pebble** 的测试目录，对照补自己的边界用例；跑本目录的三个测试脚本 | 20 轮 crash test 全绿 + benchmark 表格 |

**不要做的事**：不要一开始读 RocksDB。它太大，会把你的时间吃光，而且它的抽象是为「支持所有场景」设计的，你不需要。

---

## 六、关键论文（答辩时能引用会加分）

| 论文 | 解决的问题 | 一句话 |
|---|---|---|
| O'Neil et al., **LSM-Tree**, 1996 | 原始设计 | 把随机写转成顺序写 |
| **WiscKey**, FAST'16 | 写放大 | KV 分离，大 value 单独存 |
| **Dostoevsky**, SIGMOD'18 | compaction 策略谱系 | 没有万能的策略，只有权衡（读/写/空间放大三角） |
| **Monkey**, SIGMOD'17 | 内存与 Bloom filter 调优 | 给定内存预算，怎么分配到各层最优 |
| **Endure**, VLDB'22 | 负载不确定下的调参 | 静态调参在真实负载下会退化 |

引用一两篇就够了，重点是说清楚**你的设计对应哪个权衡点**。

---

## 七、比赛里怎么用这些

### 对标策略（benchmark 表格怎么填）

| 对照组 | 怎么跑 | 想证明什么 |
|---|---|---|
| `moonkv`（Bitcask） | 用同一套 dbcli 协议包一层（已做，见 `benches/moon/moonkv_cli/`） | ~~写吞吐更高~~、内存不随数据线性增长 |
| SQLite | 同 workload | 顺序写 vs 原地更新的差异 |
| LevelDB / RocksDB | 官方 `db_bench` | 作为上限参考，诚实说明差距 |

> **实测修正**：原来这里预测 moonkv「写吞吐更高」，实际是反的 ——
> 同一套脚本、1 万条、单条提交下，moonlsm 482 ops/s（每条都 fsync）
> 对 moonkv 96 ops/s（只 fflush）。原因是 moonkv 每个 `put` 都开关一次文件，
> 而 `putmany` 在这边是组提交。完整对照见 `BENCHMARK.md` §3.5。
> **预测写在文档里，就该在测完之后回来改。**

**别装作能打赢 RocksDB。** 说「在 10 万条规模下达到 RocksDB 的 40%，但代码只有它的 1/10，且完整支持 kill -9 恢复」——这种表述评委更信。

### 许可证与学术诚信

- LevelDB / RocksDB / Pebble / Badger / mini-lsm 都是 **BSD 或 Apache 2.0**，可以看、可以学设计
- **但不能逐行翻译**。赛事明确写了：代码重复率 50% 以上取消资格
- 正确做法：**读设计 → 用自己的数据结构重写 → 在 README 里注明「参考了 X 的设计，但做了 Y 处不同」**
- 主动声明参考来源，比被评委发现更像「懂行」

### 答辩时的一句话定位

> 「MoonBit 生态里的 LevelDB——不是最快的，但是第一个把崩溃一致性测明白的。」

---

## 八、参考链接

- LevelDB: https://github.com/google/leveldb
- RocksDB wiki: https://github.com/facebook/rocksdb/wiki
- Pebble: https://github.com/cockroachdb/pebble
- Badger: https://github.com/dgraph-io/badger
- goleveldb: https://github.com/syndtr/goleveldb
- mini-lsm 课程: https://skyzh.github.io/mini-lsm
- fjall: https://fjall-rs.github.io/
- sled: https://github.com/spacejam/sled
