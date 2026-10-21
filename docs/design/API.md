# API 冻结草案（v0.2.0）

> **状态：草案，尚未冻结。** 这份文档的作用是先把「打算承诺什么」写下来，
> 让 0.2 → 1.0 之间的每次改动都有个参照，而不是等到 1.0 才第一次讨论语义。
> 冻结动作发生在 v0.5.0；在那之前本文档里的任何一条都可以改，但**改要写理由**。

---

## 1. 冻结的是什么

冻结的对象是**签名 + 语义**，不是**文件格式**。

| 对象 | 是否冻结 | 说明 |
|---|---|---|
| 公开函数签名 | ✅ v1.0 起 | 改签名 = major |
| 语义承诺（见 §3） | ✅ v1.0 起 | 改语义 = major，即使签名没变 |
| 磁盘格式 | ❌ 不冻结 | 格式变就 bump 文件头 version 字段，并给迁移路径 |
| 观测 API 的**数值** | ❌ 不冻结 | `sst_count()` 返回几，随 compaction 策略变 |
| 性能数字 | ❌ 不冻结 | 只承诺「不出现数量级回归」，由 bench 门禁守 |

把格式排除在外是刻意的：LSM 的磁盘布局一旦承诺就再也优化不动了
（LevelDB 至今带着一堆无法回收的历史包袱）。而格式变了能不能安全读旧数据，
是**迁移问题**，由 `version` 字段解决，不需要靠冻结签名来保证。

---

## 2. 稳定性分级

公开符号按承诺强度分三级。第三级的符号存在，但**不属于 API 契约**。

### 2.1 稳定级（v1.0 起不再改）

```moonbit
Db::open(storage, mem_limit) -> Db[S] raise LsmError
Db::open_with(storage, mem_limit, sync_on_write) -> Db[S] raise LsmError

Db::put(key, value) -> UInt64 raise LsmError
Db::put_deferred(key, value) -> UInt64 raise LsmError
Db::delete(key) -> UInt64 raise LsmError
Db::delete_deferred(key) -> UInt64 raise LsmError
Db::sync() -> Unit raise LsmError
Db::flush() -> Unit raise LsmError

Db::get(key) -> Bytes?          // 不抛错
Db::scan(start, end, limit) -> Array[KvPair] raise LsmError
Db::close() -> Unit             // 不抛错
```

### 2.2 观测级（语义稳定，集合可能增减）

```moonbit
Db::sst_count() -> Int
Db::mem_entry_count() -> Int
Db::last_seq() -> UInt64
Db::flush_count() -> Int
Db::wal_bytes() -> Int
Db::level_count() -> Int
Db::level_sst_count(idx) -> Int
```

这些是给 `stats` 和运维看的。**承诺**：返回值一定是当前状态的真实读数，
不会为了「好看」而修饰。**不承诺**：某个具体数值、某个符号一直存在。

### 2.3 内部级（随时可删，别依赖）

```moonbit
Db::next_file_number() -> UInt64
Db::check_version_invariants() -> Bool
Db::wal_name() -> String
Db::manifest_name() -> String
```

这四个之所以 `pub`，是给测试和 dbcli 用的。跨包使用它们等于依赖实现细节。

---

## 3. 语义承诺

这一节是整份文档的核心。**签名相同而语义不同，是最难排查的一类破坏性变更**，
所以语义单独成节，且每一条都注明「为什么这么定」。

### 3.1 `put` 返回即已持久

`put` 返回后，这条写入在断电后仍然存在（`sync_on_write = true` 时）。

实现上的关键顺序是 **追加 WAL → fsync → 改 memtable**，fsync 在 memtable 之前。
反过来写的话，「memtable 有、WAL 没有」这个状态一旦崩溃，写入就凭空消失了。

> 注意 `sync_on_write = false` 会打破这条承诺。那个开关**只用于压测**，
> 所有正确性测试都必须用 `true`。它不是「更快模式」，是「会丢数据的模式」。

### 3.2 `put_deferred` 返回**不**代表持久

`put_deferred` 只把帧攒进缓冲，真正落盘发生在 `sync()`。契约 C1 要求的是
「**ack 发出之前** fsync 成功」，从没要求每条一次 fsync —— 这是组提交的全部理由。

代价是失败可见性变差，且**这是有意接受的**：写第一条时无法预知最后的
`sync()` 会不会成功，所以条目先进 memtable。万一 `sync()` 失败，这批数据
会留在内存里可读、但没有 ack、断电必丢。调用方拿到错误后应当丢弃这批数据
并重新打开数据库，不要继续读。

单条 `put` 没有这个问题，因为它的 fsync 在 memtable 之前。

### 3.3 `get` 的 `None` 合并了两种状态

`get` 返回 `None` 表示「不存在」**或**「已删除」。这两者对使用者没有区别，
墓碑是实现细节，不通过 API 泄漏。

这也是为什么 `get` 不返回 `Result`：读一个不存在的 key 不是错误。

### 3.4 `scan` 是左闭右开

`[start, end)`。用左闭右开而不是双闭，是因为双闭无法表达「扫到最大 key 之后」——
调用方得造一个「比所有 key 都大」的哨兵值，而 key 是任意二进制，没有这样的哨兵。

`limit` 是**上限**，不是精确条数：返回 `len < limit` 可能因为数据不够，
也可能因为实现提前收敛。反过来，**不会**返回超过 `limit` 条。

结果按 key 字节序升序，且已去除墓碑。

### 3.5 `flush` 是幂等的

memtable 为空时 `flush` 是 no-op，不产生 SST，不推进文件号。

这条看似琐碎，但它是 `close` 能安全地「不 flush」的前提 —— 调用方不需要
判断「现在 flush 会不会产生空文件」。

### 3.6 `close` 只标记状态

v1 不保持常开句柄，所以 `close` 不刷 memtable、不清 WAL、不释放任何资源，
只把 `closed` 置位。之后任何读写都抛 `LsmError::Closed`，**而不是静默继续用**。

数据安全性完全由 WAL 保证：不 `close` 直接退出进程也不丢已 ack 的写入。

> 这一条在 0.2.0 之前一直写错过（文档说「close 会刷 memtable」）。
> 写进契约的好处是：以后谁想改 `close` 的行为，必须先改这里。

### 3.7 错误分三类，处置方式不同

```moonbit
pub suberror LsmError {
  Io(String)          // 底层 IO 失败：磁盘满、权限、句柄失效
  Corruption(String)  // 数据损坏：校验失败、格式不认、文件缺失
  Closed              // 对已关闭的库做读写
}
```

| 变体 | 调用方该怎么做 |
|---|---|
| `Io` | 可以重试；重试仍失败则停止写入，但**不要删数据目录** |
| `Corruption` | 不要重试，不要自动修复。数据已经坏了，任何「自动修」都可能丢更多 |
| `Closed` | 编程错误，修代码 |

**恢复路径上遇到坏数据必须降级而不是 panic**（ADR-0003 不变量 I3）。
这条对所有 `Storage` 实现同样适用。

### 3.8 不承诺线程安全

当前实现是单线程无锁的。**不承诺**并发调用安全，也不承诺未来某个版本会加。
要加的话是 v0.5.0 之后的独立决策，届时会在本文档新增一节说明锁的粒度。

---

## 4. `Storage` trait 的契约

用户可以自己实现 `Storage`（比如接到对象存储、或者做一个故障注入后端）。
实现者必须满足：

| 方法 | 契约 |
|---|---|
| `prepare` | 可重复调用。已存在不算错 |
| `read_file` | 文件不存在返回 `None`，**不抛错**。「不存在」和「读失败」在恢复路径上是两种完全不同的处理 |
| `write_file` | 覆盖写，先截断。返回即代表持久（若实现有缓存，必须自己负责） |
| `append_file` | 追加，不重写已有内容 |
| `append_frames` | 语义等价于依次 `append_file`，但只打开一次文件。**不隐含 sync** |
| `sync` | 返回后已写入的字节必须能扛断电 |
| `list_files` | 按**字节序**排序返回。文件编号靠零填充保证字典序等于数值序 |

最容易写错的是 `list_files` 的排序契约：零填充不是美观问题，
`list_files` 按字节序排，不填充的话 `10` 会排在 `9` 前面，恢复时就会
把旧 MANIFEST 当成新的。

---

## 5. 版本演进规则

| 阶段 | 允许的改动 |
|---|---|
| 0.x（当前） | 任何改动。签名、语义、格式都可以变，但每次变要写进 CHANGELOG |
| 0.5.0 | 本文档去掉「草案」标记，语义节冻结 |
| 1.0.0 | 签名与语义冻结。破坏性改动必须 major |
| 1.x | 只增不改：新增函数、新增错误变体（用 `pub suberror` 的开放性质） |

关于错误变体：`LsmError` 是 `suberror`，意味着**新增变体不算破坏性变更**，
但调用方如果对 `LsmError` 写了穷尽 `match`，加变体后编译会失败。
这是有意的取舍 —— 宁可让调用方编译失败，也不要让新变体被静默归到
某个 `_ =>` 分支里。文档要求用 `LsmError::message()` 而不是自己 match。

---

## 6. 待定项

这些是 v0.5.0 之前必须给出结论的，现在还没定：

1. **`put_deferred` 失败后的库状态**：现在说「应当丢弃并重新打开」，
   但没提供 `Db::recover_from_failed_sync()` 之类的入口。要不要给？
2. **`scan` 的 `limit` 语义**：是否承诺「返回的恰好是字典序前 `limit` 条」？
   现在的实现是（多路归并取前 N），但文档没写死，因为块级剪枝下
   这个承诺有实现成本。
3. **迭代器**：`iter.mbt` 已经存在，但没进稳定级。`scan` 返回 `Array`
   意味着大范围扫描必须全量进内存。v0.5.0 要决定是否把 `Iter` 提为稳定 API。
4. **`Db` 的 `Drop`**：现在需要显式 `close()`。MoonBit 有没有可靠的
   析构钩子？没有的话「忘记 close」是不是就完全无害（当前看是无害的）。
5. **多后端下的 `open` 错误**：`Corruption` 里带的是文件名，不是路径。
   多后端时文件名可能不唯一，要不要改成带后端标识。
