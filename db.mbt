///|
/// M2 阶段的数据库：WAL + memtable + 若干 SST，全部通过 `Storage` 落盘。
///
/// 写入顺序（**这个顺序是崩溃契约 C1 的全部内容**）：
///
/// ```
/// 分配 seq → 追加 WAL 帧 → fsync WAL → 写 memtable → 可能刷盘
/// ```
///
/// 三个关键点：
///
/// 1. **先 WAL 后 memtable**。反过来的话，进程在两者之间死掉，
///    内存里的数据会消失而 WAL 里没有记录，重启后这条写入凭空消失。
/// 2. **fsync 成功之后才能对外返回 seq**。fsync 失败就抛错，
///    调用方拿不到 ack，也就不会认为写成功了。
/// 3. **刷盘时先让 SST 落盘，再清 WAL**。中间崩溃只会导致 WAL 被重放一次，
///    而重放是幂等的（同样的 seq、同样的值），不会产生错误结果。
///
/// 读路径的新旧顺序：`memtable` → `ssts[0]` → `ssts[1]` → …
/// 越靠前越新。注意这只是**短路优化的依据**，正确性依据永远是 `seq` ——
/// 归并时用 `seq` 判断新旧，而不是数组下标。
///
/// 写入 API 分成两组，对应两种 fsync 粒度：
///
/// - `put` / `delete`：写 + fsync，返回即持久。适合单条写。
/// - `put_deferred` / `delete_deferred` + `sync`：批量追加后一次 fsync。
///   适合 `putmany`，把 N 次刷盘压成 1 次（组提交）。
///
/// 两组都满足 C1：**ack 发出之前 fsync 一定已经成功**。区别只在
/// 「一批里 fsync 几次」，不在「要不要 fsync」。
///
/// 但两组的**失败可见性不同**，这是批量的固有代价：
/// `put` 把 fsync 放在改 memtable 之前，失败时写入完全不可见；
/// `put_deferred` 做不到（写第一条时还不知道最后的 sync 会不会成功），
/// 所以 `sync` 失败时那批数据会留在内存里可读、但没有 ack、断电必丢。
pub struct Db[S] {
  storage : S
  mem : MemTable
  /// 从新到旧。
  ssts : Array[SstReader]
  /// memtable 字节阈值，超过就自动刷盘。
  mem_limit : Int
  mut seq : UInt64
  mut flush_count : Int
  /// 下一个可用的 SST 编号。恢复时从已有文件的最大编号推出来。
  mut next_sst : Int
  /// 每次写入是否立刻 fsync。关掉它是为了压测「不落盘能跑多快」，
  /// **默认必须是 true**——关掉就等于放弃了 C1。
  sync_on_write : Bool
  /// `put_deferred` 攒下来的 WAL 帧，等 `sync()` 时一次性写出。
  ///
  /// 为什么要攒：真文件系统上每次 `fopen`/`fclose` 约 5.9 ms（Windows 实测），
  /// 逐帧打开写一次的话，200 条的批次要 1.2 秒，其中 99% 是开关文件的开销。
  /// 攒起来一次写，同样的批次降到 6 ms。
  ///
  /// **只用于 deferred 路径。** `put`/`delete` 仍然逐帧立即写 WAL ——
  /// 单条写的语义是「返回即持久」，把帧留在内存里会让「优雅重启也丢数据」，
  /// 那是比慢严重得多的问题。
  ///
  /// 不需要 `mut`：`Array` 是引用类型，`push`/`clear` 改的是它指向的内容，
  /// 不是字段本身。
  pending : Array[Bytes]
  mut wal_bytes : Int
  mut closed : Bool
}

///|
/// WAL 文件名。v1 只用一个 WAL，刷盘时清空而不是轮转。
///
/// 固定名字（不带编号）是有意的：轮转要处理「两个 WAL 同时存在时按什么
/// 顺序重放」，而刷盘时 SST 已经持久化，WAL 清空是安全的。
/// 等 compaction 引入后台任务、需要并发写多代 WAL 时再改。
pub const WAL_FILE : String = "WAL-000001"

///|
const SST_PREFIX : String = "SST-"

///|
/// 打开（或新建）数据库。`mem_limit` 是 memtable 的字节阈值。
///
/// 每次都立刻 fsync。要关掉它（只用于压测）用 `Db::open_with`。
pub fn[S : Storage] Db::open(
  storage : S,
  mem_limit : Int,
) -> Db[S] raise LsmError {
  Db::open_with(storage, mem_limit, true)
}

///|
/// 同 `Db::open`，但可以关掉每次写入的 fsync。
///
/// `sync_on_write = false` 时**崩溃会丢已确认的数据**，只应该用于
/// 性能对比实验。所有正确性测试都必须用 true。
pub fn[S : Storage] Db::open_with(
  storage : S,
  mem_limit : Int,
  sync_on_write : Bool,
) -> Db[S] raise LsmError {
  Storage::prepare(storage)
  let db : Db[S] = {
    storage,
    mem: MemTable::new(mem_limit),
    ssts: [],
    mem_limit,
    seq: 0UL,
    flush_count: 0,
    next_sst: 1,
    sync_on_write,
    pending: [],
    wal_bytes: 0,
    closed: false,
  }
  db.recover()
  db
}

///|
/// 从磁盘恢复。顺序是 **先 SST 后 WAL**：SST 提供基线，WAL 覆盖在其上。
///
/// 反过来（先 WAL 后 SST）会出错：SST 里的条目 seq 更小，但插到 memtable
/// 前面之后 `get` 会先命中 memtable，表面上「碰巧对了」；一旦 memtable
/// 里没有那个 key，就会读到 SST 的旧值。这种错在测试里极难复现。
fn[S : Storage] Db::recover(self : Db[S]) -> Unit raise LsmError {
  let mut max_seq = 0UL
  // list_files 按字节序排序，配合零填充的编号，就是编号升序 = 从旧到新。
  // 依次插到数组最前面，得到「从新到旧」。
  for name in Storage::list_files(self.storage, SST_PREFIX) {
    let raw = match Storage::read_file(self.storage, name) {
      Some(b) => b
      None => raise LsmError::io("SST 文件在读的瞬间消失了：\{name}")
    }
    let r = match open_sst(raw) {
      Some(r) => r
      None =>
        raise LsmError::corruption(
          "SST 打不开（文件损坏或版本不兼容）：\{name}",
        )
    }
    let num = parse_sst_number(name)
    if num >= self.next_sst {
      self.next_sst = num + 1
    }
    for e in r.entries() {
      if e.seq > max_seq {
        max_seq = e.seq
      }
    }
    self.ssts.insert(0, r)
  }
  let wal = match Storage::read_file(self.storage, WAL_FILE) {
    Some(b) => b
    None => {
      // 新库。立刻把文件头写下去，而不是等到第一次 put——
      // 否则「目录里有 SST 但没有 WAL」这种状态会一直存在到第一次写入。
      let empty = empty_wal_bytes()
      Storage::write_file(self.storage, WAL_FILE, empty)
      Storage::sync_file(self.storage, WAL_FILE)
      empty
    }
  }
  self.wal_bytes = wal.length()
  let rep = recover_wal(wal)
  if !rep.header_ok() {
    // 文件头都不对，整份 WAL 没有可用内容。重建一个空的，
    // 而不是让数据库起不来——WAL 是「未确认写入的暂存区」，
    // 丢掉它最坏的情况是丢最后一次未刷盘的写入，比拒绝启动好。
    let empty = empty_wal_bytes()
    Storage::write_file(self.storage, WAL_FILE, empty)
    Storage::sync_file(self.storage, WAL_FILE)
    self.wal_bytes = empty.length()
  } else if rep.is_truncated() {
    // 尾部有半条记录 —— 这是断电的常态，不是数据损坏。
    // 把 WAL 重写成「只有完整好帧」的版本。
    //
    // 不用 ftruncate：Windows 的 CRT 里没有这个符号（只有 `_chsize`），
    // 而重写一个 WAL 的成本只是「文件多大就写多少」，且只在崩溃后发生一次。
    let good = take_prefix(wal, rep.good_bytes())
    Storage::write_file(self.storage, WAL_FILE, good)
    Storage::sync_file(self.storage, WAL_FILE)
    self.wal_bytes = good.length()
  }
  for rec in rep.records() {
    self.mem.apply(rec)
    if rec.seq > max_seq {
      max_seq = rec.seq
    }
  }
  self.seq = max_seq
}

///|
fn[S] Db::ensure_open(self : Db[S]) -> Unit raise LsmError {
  if self.closed {
    raise LsmError::closed()
  }
}

///|
/// 当前最大 seq。每次写入自增，跨 memtable 与 SST 全局单调。
pub fn[S] Db::last_seq(self : Db[S]) -> UInt64 {
  self.seq
}

///|
pub fn[S] Db::sst_count(self : Db[S]) -> Int {
  self.ssts.length()
}

///|
pub fn[S] Db::flush_count(self : Db[S]) -> Int {
  self.flush_count
}

///|
/// 当前 WAL 文件字节数（含文件头）。`stats` 命令用它。
pub fn[S] Db::wal_bytes(self : Db[S]) -> Int {
  self.wal_bytes
}

///|
/// memtable 里的条目数（含墓碑）。`stats` 命令用它区分
/// 「内存里有多少条」和「已经刷到 SST 的有多少条」。
pub fn[S] Db::mem_entry_count(self : Db[S]) -> Int {
  self.mem.to_entries().length()
}

///|
/// 写。返回本次写入的 seq —— 返回即代表**已持久**（`sync_on_write = true` 时）。
///
/// 顺序是 `追加帧 → fsync → 改 memtable`，**fsync 在 memtable 之前**。
/// 这不是随手写的：fsync 失败时这条写入必须「完全不可见」，
/// 否则会出现「读得到、但断电就消失」的脏读 —— 比直接报错严重得多。
pub fn[S : Storage] Db::put(
  self : Db[S],
  key : Bytes,
  value : Bytes,
) -> UInt64 raise LsmError {
  self.ensure_open()
  self.seq = self.seq + 1UL
  let rec = WalRecord::new(self.seq, Op::Put(key, value))
  self.append_wal_frame(rec)
  if self.sync_on_write {
    self.sync()
  }
  // 只有 WAL 落盘之后才动 memtable。反过来写的话，
  // 「memtable 有、WAL 没有」这种状态一旦崩溃，这条写入就凭空消失了。
  self.mem.apply(rec)
  self.maybe_flush()
  self.seq
}

///|
/// 写，但**不 fsync**。返回的 seq 不代表已持久。
///
/// 这是组提交（group commit）的一半。另一半是 `sync()`。
///
/// 为什么需要它：`putmany` 一批 200 条，如果每条都 fsync，
/// 在 Windows 的 `_commit` 上就是 200 次真实刷盘（实测约 2.3 秒一批）。
/// 而契约 C1 只要求「**返回 ack 之前** fsync 成功」，从没要求每条一次。
/// 正确用法：
///
/// ```
/// for item in batch { db.put_deferred(k, v) }   // 只追加，不刷盘
/// db.sync()                                     // 一次刷盘
/// // ← 到这里才能返回 ok
/// ```
///
/// 安全性说明：中途如果 memtable 满了触发 flush，flush 会把 SST 落盘
/// 并清空 WAL —— 那批数据已经通过 SST 持久化，不会因为「还没 sync」而丢。
///
/// **与 `put` 的可见性差异（有意为之）**：这里没法在写第一条时预知
/// 后面的 `sync()` 会不会成功，所以条目先进 memtable。万一 `sync()` 失败，
/// 这批数据会**留在内存里可读，但没有 ack、断电必丢**。
/// 调用方拿到错误后应当丢弃这批数据并重新打开数据库，不要继续读。
/// 单条写没有这个问题 —— `put` 把 fsync 放在 memtable 之前。
pub fn[S : Storage] Db::put_deferred(
  self : Db[S],
  key : Bytes,
  value : Bytes,
) -> UInt64 raise LsmError {
  self.ensure_open()
  self.seq = self.seq + 1UL
  let rec = WalRecord::new(self.seq, Op::Put(key, value))
  // 只攒帧，不碰文件。真正写盘发生在 sync() 里，一批只打开一次文件。
  self.buffer_wal_frame(rec)
  self.mem.apply(rec)
  self.maybe_flush()
  self.seq
}

///|
/// 删。写墓碑，不是移除条目。
///
/// 与 `put` 一样，fsync 在 memtable 之前：删失败时旧值必须仍然可读，
/// 而不是「删了一半」。
pub fn[S : Storage] Db::delete(
  self : Db[S],
  key : Bytes,
) -> UInt64 raise LsmError {
  self.ensure_open()
  self.seq = self.seq + 1UL
  let rec = WalRecord::new(self.seq, Op::Delete(key))
  self.append_wal_frame(rec)
  if self.sync_on_write {
    self.sync()
  }
  self.mem.apply(rec)
  self.maybe_flush()
  self.seq
}

///|
/// 删，但不 fsync。与 `put_deferred` 对称，同样要配合 `sync()` 使用。
pub fn[S : Storage] Db::delete_deferred(
  self : Db[S],
  key : Bytes,
) -> UInt64 raise LsmError {
  self.ensure_open()
  self.seq = self.seq + 1UL
  let rec = WalRecord::new(self.seq, Op::Delete(key))
  self.buffer_wal_frame(rec)
  self.mem.apply(rec)
  self.maybe_flush()
  self.seq
}

///|
/// 把 WAL 刷到稳定存储。**这是 C1 的最后一道闸门。**
///
/// 先把 `put_deferred` 攒下的帧一次性写出去（一次 `fopen`），再 fsync。
/// 失败一律抛出：fsync 没成功就不能让调用方以为写成功了。
///
/// 没有待写帧时调用它是安全的（代价 = 一次 fsync）。
pub fn[S : Storage] Db::sync(self : Db[S]) -> Unit raise LsmError {
  self.ensure_open()
  self.flush_pending()
  Storage::sync_file(self.storage, WAL_FILE)
}

///|
/// 把攒下的 WAL 帧一次性追加到文件。
///
/// 记账顺序：**先写盘成功，再更新 `wal_bytes` 和清空 `pending`**。
/// 反过来的话，写盘失败时帧已经从 `pending` 里消失，重试就永远写不进去了。
///
/// 如果 `append_frames` 写到一半失败，`pending` 会被保留，
/// 重试时已写成功的部分会被重复追加。这是可接受的：重放同样的 seq
/// 和同样的值是幂等的，不会产生错误结果。
fn[S : Storage] Db::flush_pending(self : Db[S]) -> Unit raise LsmError {
  if self.pending.length() == 0 {
    return
  }
  Storage::append_frames(self.storage, WAL_FILE, self.pending)
  let mut n = 0
  for f in self.pending {
    n = n + f.length()
  }
  self.wal_bytes = self.wal_bytes + n
  self.pending.clear()
}

///|
/// 立即追加一帧到 WAL（单条写路径），**不 fsync**。
///
/// 名字里刻意带 `_frame` 而不是 `append_wal`：后者容易被误读成
/// 「追加并落盘」。持久化只发生在 `sync()` 里，一个函数只做一件事。
fn[S : Storage] Db::append_wal_frame(
  self : Db[S],
  rec : WalRecord,
) -> Unit raise LsmError {
  let frame = encode_frame(rec)
  Storage::append_file(self.storage, WAL_FILE, frame)
  self.wal_bytes = self.wal_bytes + frame.length()
}

///|
/// 把一帧攒进 `pending`，等 `sync()` 时统一写出（批量写路径）。
fn[S] Db::buffer_wal_frame(self : Db[S], rec : WalRecord) -> Unit {
  self.pending.push(encode_frame(rec))
}

///|
fn[S : Storage] Db::maybe_flush(self : Db[S]) -> Unit raise LsmError {
  if self.mem.is_full() {
    self.flush()
  }
}

///|
/// 把 memtable 刷成一个 SST。
///
/// 顺序必须是：写 SST → fsync SST → **立刻读回校验** → 才清 memtable 和 WAL。
/// 中间任何一步失败都不能清 memtable，否则数据就没了。
/// 「读回校验」是廉价的：`open_sst` 会校验 magic / version / 区域边界，
/// 能在几微秒内发现「写出来的东西自己都打不开」这种灾难性 bug。
pub fn[S : Storage] Db::flush(self : Db[S]) -> Unit raise LsmError {
  self.ensure_open()
  if self.mem.to_entries().length() == 0 {
    return
  }
  let w = SstWriter::new()
  for e in self.mem.to_entries() {
    w.add(e)
  }
  let raw = w.finish()
  let reader = match open_sst(raw) {
    Some(r) => r
    None =>
      raise LsmError::corruption(
        "flush: 刚写出的 SST 无法打开（写读不一致）",
      )
  }
  let name = sst_name(self.next_sst)
  Storage::write_file(self.storage, name, raw)
  // SST 必须**先落盘**才能清 WAL。反过来的话，断电后 SST 文件可能是
  // 半截的（或者干脆不存在），而 WAL 已经清空 —— 数据就真丢了。
  Storage::sync_file(self.storage, name)
  // 新 SST 插到最前面：它比已有的都新
  self.ssts.insert(0, reader)
  self.next_sst = self.next_sst + 1
  let empty = empty_wal_bytes()
  Storage::write_file(self.storage, WAL_FILE, empty)
  Storage::sync_file(self.storage, WAL_FILE)
  self.wal_bytes = empty.length()
  self.mem.clear()
  // `pending` 里的帧对应的记录全都在 memtable 里，也就全都进了刚落盘的
  // 这个 SST。SST 已经 fsync 过，所以这些帧可以安全丢弃 —— 不丢的话，
  // 下一次 sync() 会把它们追加到已经清空的 WAL 上，重放时虽然幂等，
  // 但 `wal_bytes` 会凭空变大，stats 看起来像有数据没刷盘。
  self.pending.clear()
  self.flush_count = self.flush_count + 1
}

///|
/// 读。返回 `None` 表示「不存在」或「已删除」——
/// 对使用者来说这两种没有区别，墓碑是实现细节。
pub fn[S] Db::get(self : Db[S], key : Bytes) -> Bytes? {
  match self.mem.get(key) {
    Some(e) => return if e.deleted { None } else { Some(e.value) }
    None => ()
  }
  for r in self.ssts {
    match r.get(key) {
      Some(e) => return if e.deleted { None } else { Some(e.value) }
      None => ()
    }
  }
  None
}

///|
/// 范围扫描。`start` 闭、`end` 开（`[start, end)`），最多 `limit` 条。
///
/// 用左闭右开而不是双闭：双闭无法表达「扫到最大 key 之后」，
/// 调用方得造一个「比所有 key 都大」的哨兵值，而 key 是任意二进制，
/// 没有这样的哨兵。
pub fn[S] Db::scan(
  self : Db[S],
  start : Bytes,
  end : Bytes,
  limit : Int,
) -> Array[KvPair] raise LsmError {
  let sources : Array[Array[Entry]] = []
  sources.push(self.mem.to_entries())
  for r in self.ssts {
    sources.push(r.entries())
  }
  let it = MergeIterator::new(sources)
  let out : Array[KvPair] = []
  while out.length() < limit {
    match it.next() {
      Some(e) => {
        // 墓碑必须在这里被吃掉，不能出现在结果里
        if e.deleted {
          continue
        }
        if compare_bytes(e.key, start) < 0 {
          continue
        }
        if compare_bytes(e.key, end) >= 0 {
          continue
        }
        out.push(e.to_pair())
      }
      None => break
    }
  }
  out
}

///|
/// 关闭。v1 不保持常开句柄，所以这里只标记状态；
/// 关闭之后任何读写都抛 `Closed`，而不是静默继续用。
pub fn[S] Db::close(self : Db[S]) -> Unit {
  self.closed = true
}

///|
/// 截取前缀。`n` 越界时取全长（恢复路径上宁可多留不可少留）。
fn take_prefix(b : Bytes, n : Int) -> Bytes {
  let out = Buffer::Buffer()
  let end = if n > b.length() { b.length() } else { n }
  out.write_bytes(b[:end])
  out.to_bytes()
}

///|
/// `SST-000007` 这种名字。零填充是必须的：`list_files` 按**字节序**排序，
/// 不填充的话 `SST-10` 会排在 `SST-9` 前面，恢复时新旧顺序就反了。
fn sst_name(n : Int) -> String {
  let digits = n.to_string()
  let mut pad = ""
  for _ in 0..<(6 - digits.length()) {
    pad = pad + "0"
  }
  SST_PREFIX + pad + digits
}

///|
/// 从文件名解析编号。解析不出来返回 0（当作最旧），
/// 这样它不会把 `next_sst` 推到一个不合理的大值上。
fn parse_sst_number(name : String) -> Int {
  let body = name[4:]
  let mut n = 0
  for c in body {
    let d = c.to_int() - '0'.to_int()
    if d < 0 || d > 9 {
      return 0
    }
    n = n * 10 + d
  }
  n
}
