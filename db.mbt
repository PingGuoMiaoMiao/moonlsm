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
  /// 从新到旧。带上编号是因为 compaction 需要知道「要删哪个文件」。
  ssts : Array[LoadedSst]
  /// memtable 字节阈值，超过就自动刷盘。
  mem_limit : Int
  mut seq : UInt64
  mut flush_count : Int
  /// 版本快照：每层有哪些 SST、活跃 WAL 编号、下一个可用文件编号。
  /// 它是**唯一**的文件编号来源 —— 不要再单独维护计数器。
  mut version : Version
  /// 当前 MANIFEST 的文件名（如 `MANIFEST-000007`）。空串表示还没写过。
  mut current_manifest : String
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
/// 一个已加载的 SST。编号来自文件名，`reader` 是解析后的内容。
///
/// 之所以不只用 `SstReader`：compaction 要把「被归并掉的文件」从内存视图里
/// 摘掉，而 `SstReader` 本身不记得自己叫什么。
pub struct LoadedSst {
  num : UInt64
  reader : SstReader
}

///|
/// 磁盘布局（`docs/design/format.md` §1）：
///
/// ```
/// <db_path>/
/// ├── CURRENT              # 文本，内容是当前 MANIFEST 的文件名 + "\n"
/// ├── MANIFEST-000007      # 版本快照
/// ├── wal/
/// │   └── 000008.wal       # 活跃 WAL
/// └── sst/
///     └── 000004.sst
/// ```
///
/// **文件编号全局共享**：WAL、SST、MANIFEST 从同一个单调递增计数器取号
/// （存在 MANIFEST 的 `next_file_number` 里）。这样任何两个文件不会撞名，
/// 恢复时也只需比较编号大小。
///
/// 早期版本用的是根目录扁平的 `WAL-000001` / `SST-000001`，两个独立计数器。
/// 那种布局在引入 WAL 轮转（每次 flush 换一个新 WAL）之后就不成立了：
/// 两个计数器会各自撞上对方已经用过的号。
pub const WAL_DIR : String = "wal"

///|
pub const SST_DIR : String = "sst"

///|
pub const CURRENT_FILE : String = "CURRENT"

///|
const CURRENT_TMP : String = "CURRENT.tmp"

///|
const MANIFEST_PREFIX : String = "MANIFEST-"

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
    version: Version::new(),
    current_manifest: "",
    sync_on_write,
    pending: [],
    wal_bytes: 0,
    closed: false,
  }
  db.recover()
  db
}

///|
/// 打开数据库：读 CURRENT → 读 MANIFEST → 加载 SST → 重放 WAL。
///
/// 顺序是 **先 SST 后 WAL**：SST 提供基线，WAL 覆盖在其上。
///
/// 反过来（先 WAL 后 SST）会出错：SST 里的条目 seq 更小，但插到 memtable
/// 前面之后 `get` 会先命中 memtable，表面上「碰巧对了」；一旦 memtable
/// 里没有那个 key，就会读到 SST 的旧值。这种错在测试里极难复现。
fn[S : Storage] Db::recover(self : Db[S]) -> Unit raise LsmError {
  self.load_version()
  let mut max_seq = self.version.last_seq
  // 加载 SST，顺序必须让 `self.ssts[0]` 是最新的文件 —— `get` 靠这个
  // 顺序做短路，顺序反了就会读到旧值。
  //
  // 正确的顺序是「层号升序（L0 最新）+ 层内编号降序」：
  // L0 的 SST 来自更晚的 memtable，所以整个 L0 都比 L1 新；
  // 同层内编号越大越新。依次 push 正好得到「从新到旧」。
  for lv in 0..<self.version.level_count() {
    let files = self.version.level(lv)
    let mut i = files.length()
    while i > 0 {
      i = i - 1
      let meta = files[i]
      let path = sst_path(meta.number)
      let raw = match Storage::read_file(self.storage, path) {
        Some(b) => b
        None =>
          raise LsmError::corruption(
            "MANIFEST 里登记了 \{path}，但文件不存在（元信息与实际不一致）",
          )
      }
      let r = match open_sst(raw) {
        Some(r) => r
        None =>
          raise LsmError::corruption(
            "SST 打不开（文件损坏或版本不兼容）：\{path}",
          )
      }
      for e in r.entries() {
        if e.seq > max_seq {
          max_seq = e.seq
        }
      }
      self.ssts.push({ num: meta.number, reader: r })
    }
  }
  let wpath = self.wal_name()
  let wal = match Storage::read_file(self.storage, wpath) {
    Some(b) => b
    None => {
      // MANIFEST 指向的 WAL 不存在。可能是被人删了，也可能是初始化
      // 写到一半崩了。建一个空的：WAL 只是「未刷盘写入的暂存区」，
      // 而 SST 里的数据已经登记在 MANIFEST 里，不会因此丢。
      // 真正会丢的是「还没 flush 的写入」—— 那种情况下本来也没有 ack。
      let empty = empty_wal_bytes()
      Storage::write_file(self.storage, wpath, empty)
      Storage::sync_file(self.storage, wpath)
      empty
    }
  }
  self.wal_bytes = wal.length()
  let rep = recover_wal(wal)
  if !rep.header_ok() {
    // 文件头都不对，整份 WAL 没有可用内容。重建一个空的，
    // 而不是让数据库起不来 —— WAL 是「未确认写入的暂存区」，
    // 丢掉它最坏的情况是丢最后一次未刷盘的写入，比拒绝启动好。
    let empty = empty_wal_bytes()
    Storage::write_file(self.storage, wpath, empty)
    Storage::sync_file(self.storage, wpath)
    self.wal_bytes = empty.length()
  } else if rep.is_truncated() {
    // 尾部有半条记录 —— 这是断电的常态，不是数据损坏。
    // 把 WAL 重写成「只有完整好帧」的版本。
    //
    // 不用 ftruncate：Windows 的 CRT 里没有这个符号（只有 `_chsize`），
    // 而重写一个 WAL 的成本只是「文件多大就写多少」，且只在崩溃后发生一次。
    let good = take_prefix(wal, rep.good_bytes())
    Storage::write_file(self.storage, wpath, good)
    Storage::sync_file(self.storage, wpath)
    self.wal_bytes = good.length()
  }
  for rec in rep.records() {
    self.mem.apply(rec)
    if rec.seq > max_seq {
      max_seq = rec.seq
    }
  }
  self.seq = max_seq
  // 编号比 log_number 小的 WAL 都是历史遗留：它们的数据已经进了 SST，
  // MANIFEST 也不会再引用它们。删掉，否则目录会一直涨。
  for name in Storage::list_files(self.storage, WAL_DIR) {
    match parse_number_prefix(name) {
      Some(n) =>
        if n < self.version.log_number {
          Storage::remove_file(self.storage, WAL_DIR + "/" + name)
        }
      None => ()
    }
  }
}

///|
/// 读 CURRENT → 读 MANIFEST，把版本快照装进 `self.version`。
///
/// 三种情形：
/// - **CURRENT 存在且指向的 MANIFEST 能解码** → 正常恢复
/// - **CURRENT 不存在，且目录里没有任何数据文件** → 全新的库，初始化
/// - **其他** → `Corruption`，拒绝启动
///
/// 最后一条是刻意「不宽容」的：WAL 尾部的半条记录可以截断（那是断电常态），
/// 但「不知道数据布局」时硬猜会**静默丢数据**。宁可拒绝启动让人来看。
fn[S : Storage] Db::load_version(self : Db[S]) -> Unit raise LsmError {
  let cur = Storage::read_file(self.storage, CURRENT_FILE)
  match cur {
    None =>
      if self.has_any_data_file() {
        raise LsmError::corruption(
          "CURRENT 缺失，但目录里已有数据文件。无法推断布局，拒绝启动。",
        )
      } else {
        self.init_fresh()
      }
    Some(raw) =>
      match parse_current(@utf8.decode_lossy(raw)) {
        None => raise LsmError::corruption("CURRENT 内容无法解析")
        Some(name) => {
          self.version = self.read_manifest(name)
          self.current_manifest = name
        }
      }
  }
  // 目录里可能残留孤儿文件（崩溃在「写完 SST」和「写 MANIFEST」之间）。
  // 编号必须跳过它们，否则下一次 flush 会覆盖一个已经存在的文件 ——
  // 虽然孤儿没被引用、覆盖它无害，但「文件名和内容不对应」会让
  // 排查问题时彻底失去方向。
  self.bump_file_number_past_existing()
}

///|
/// 读 CURRENT 指向的那份 MANIFEST。
///
/// **读不懂就拒绝启动，不退回旧版本。**
///
/// 早期版本这里实现了「退回编号次大的 MANIFEST」的兜底。删掉它是因为
/// 想清楚了一件事：退回旧 MANIFEST 会**丢掉已经 ack 的数据**。
///
/// 具体地：`flush` 把数据写进新 SST、把新 SST 登记进新 MANIFEST，
/// 然后删掉旧 WAL（那批写入在返回 ack 时就已 fsync 过）。此时若退回
/// 旧 MANIFEST，它不认识那个新 SST，于是那批**已经承诺不丢**的数据
/// 变得不可见 —— 直接违反契约 C1。
///
/// 拒绝启动则完全不同：数据一个字节都没少，只是需要人来判断。
/// 所有文件都还在目录里，可以人工检查、可以写工具从 SST 重建 MANIFEST。
///
/// 这和 `wal.mbt` 对坏数据的态度差异是刻意的：WAL 尾部的半条记录是
/// **断电常态**，截断它不损失任何已 ack 的数据；而 MANIFEST 读不懂意味着
/// 「不知道哪些数据是有效的」，这时任何自动决策都可能丢数据。
fn[S : Storage] Db::read_manifest(self : Db[S], name : String) -> Version raise LsmError {
  let raw = match Storage::read_file(self.storage, name) {
    Some(b) => b
    None =>
      raise LsmError::corruption(
        "CURRENT 指向的 MANIFEST 不存在：\{name}",
      )
  }
  let v = match decode_manifest(raw) {
    Some(v) => v
    None =>
      raise LsmError::corruption(
        "MANIFEST 解码失败（magic/version/CRC/结构）：\{name}",
      )
  }
  if !v.check_invariants() {
    raise LsmError::corruption(
      "MANIFEST 语义不合法（层重叠或编号越界）：\{name}",
    )
  }
  v
}

///|
/// 目录里是否已经有数据文件（用来区分「全新库」和「元信息丢了」）。
fn[S : Storage] Db::has_any_data_file(self : Db[S]) -> Bool raise LsmError {
  if Storage::list_files(self.storage, SST_DIR).length() > 0 {
    return true
  }
  if Storage::list_files(self.storage, WAL_DIR).length() > 0 {
    return true
  }
  for f in Storage::list_files(self.storage, "") {
    if has_prefix(f, MANIFEST_PREFIX) {
      return true
    }
  }
  false
}

///|
/// 全新的库：建活跃 WAL，写第一份 MANIFEST 和 CURRENT。
fn[S : Storage] Db::init_fresh(self : Db[S]) -> Unit raise LsmError {
  // Version::new() 给的是 log_number=1、next_file_number=2。
  let empty = empty_wal_bytes()
  let wp = wal_path(1UL)
  Storage::write_file(self.storage, wp, empty)
  Storage::sync_file(self.storage, wp)
  self.wal_bytes = empty.length()
  self.persist_version()
}

///|
/// 把 `self.version` 落盘，并原子切换 CURRENT。
///
/// 严格按 `docs/design/format.md` §4.2 的顺序，每一步都不能换位：
///
/// ```
/// 1. 写 MANIFEST-<new> 全部内容
/// 2. fsync(MANIFEST-<new>)
/// 3. 写 CURRENT.tmp = "MANIFEST-<new>\n"
/// 4. fsync(CURRENT.tmp)
/// 5. rename(CURRENT.tmp, CURRENT)   ← 原子点
/// 6. fsync(目录)                    ← 在 rename_file 内部完成
/// 7. 删除旧 MANIFEST                ← 必须在 6 之后
/// ```
///
/// 任何一步之前崩溃，CURRENT 都还指向旧 MANIFEST，而旧的 SST / WAL 都还在，
/// 所以一定能恢复到一个一致的旧状态。**先写后删**是这条序列的全部意义。
fn[S : Storage] Db::persist_version(self : Db[S]) -> Unit raise LsmError {
  let num = self.version.alloc_file_number()
  let name = manifest_path(num)
  let raw = encode_manifest(self.version)
  Storage::write_file(self.storage, name, raw)
  Storage::sync_file(self.storage, name)
  let body = @utf8.encode(name + "\n")
  Storage::write_file(self.storage, CURRENT_TMP, body)
  Storage::sync_file(self.storage, CURRENT_TMP)
  Storage::rename_file(self.storage, CURRENT_TMP, CURRENT_FILE)
  let old = self.current_manifest
  self.current_manifest = name
  if old != "" && old != name {
    // 删失败不算错误：多留一个 MANIFEST 只是浪费几百字节，
    // 而「因为删不掉就报错」会让一次成功的 flush 看起来失败了。
    Storage::remove_file(self.storage, old) catch {
      Io(_) => ()
      Corruption(_) => ()
      Closed => ()
    }
  }
}

///|
/// 当前活跃 WAL 的路径（`wal/000008.wal`）。
pub fn[S] Db::wal_name(self : Db[S]) -> String {
  wal_path(self.version.log_number)
}

///|
/// 当前 MANIFEST 的名字（`MANIFEST-000007`）。空串表示还没写过。
pub fn[S] Db::manifest_name(self : Db[S]) -> String {
  self.current_manifest
}

///|
/// 按编号找已加载的 SST。找不到说明内存视图和 `version` 不一致 ——
/// 这是内部不变量的破坏，不是用户错误，所以直接报 Corruption。
fn[S] Db::find_reader(self : Db[S], num : UInt64) -> SstReader raise LsmError {
  for s in self.ssts {
    if s.num == num {
      return s.reader
    }
  }
  raise LsmError::corruption(
    "内部状态不一致：版本里引用了 sst/\{pad_num(num)}，但内存里没有加载它",
  )
}

///|
/// 版本快照是否满足全部语义不变量。测试用它确认归并之后 L1 仍不重叠。
pub fn[S] Db::check_version_invariants(self : Db[S]) -> Bool {
  self.version.check_invariants()
}

///|
/// 版本快照里有几层。
pub fn[S] Db::level_count(self : Db[S]) -> Int {
  self.version.level_count()
}

///|
/// 某一层有几个 SST。层不存在返回 0。
pub fn[S] Db::level_sst_count(self : Db[S], idx : Int) -> Int {
  self.version.level(idx).length()
}

///|
/// 版本快照里的 `next_file_number`。测试用它验证「编号不复用」。
pub fn[S] Db::next_file_number(self : Db[S]) -> UInt64 {
  self.version.next_file_number
}

///|
/// 让 `next_file_number` 跳过目录里已经存在的编号。
fn[S : Storage] Db::bump_file_number_past_existing(
  self : Db[S],
) -> Unit raise LsmError {
  let mut max = 0UL
  for dir in [SST_DIR, WAL_DIR] {
    for name in Storage::list_files(self.storage, dir) {
      match parse_number_prefix(name) {
        Some(n) =>
          if n > max {
            max = n
          }
        None => ()
      }
    }
  }
  for f in Storage::list_files(self.storage, "") {
    if has_prefix(f, MANIFEST_PREFIX) {
      match parse_number_prefix(f[MANIFEST_PREFIX.length():].to_owned()) {
        Some(n) =>
          if n > max {
            max = n
          }
        None => ()
      }
    }
  }
  if self.version.next_file_number <= max {
    self.version.next_file_number = max + 1UL
  }
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
  Storage::sync_file(self.storage, self.wal_name())
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
  Storage::append_frames(self.storage, self.wal_name(), self.pending)
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
  Storage::append_file(self.storage, self.wal_name(), frame)
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
/// 把 memtable 刷成一个 SST，并推进版本。
///
/// 这是整个引擎里**唯一会改 MANIFEST 的地方**，也是唯一依赖
/// 文件系统 rename 原子性的地方。顺序一步都不能换：
///
/// ```
/// 1. 写 sst/<n>.sst → fsync        （数据先变成持久事实）
/// 2. 建 wal/<m>.wal 空文件 → fsync  （新 WAL 必须存在才能被 MANIFEST 引用）
/// 3. 更新 version（L0 加一项、log_number=m、last_seq）
/// 4. persist_version()             （写 MANIFEST + 原子切换 CURRENT）
/// 5. 删旧 WAL                      （CURRENT 已经不再指向它）
/// 6. 清 memtable / pending
/// ```
///
/// 崩溃点分析：
/// - 1 之前/之中崩：MANIFEST 仍指旧 WAL，旧 WAL 里有全部记录 → 重放能恢复；
///   半截的 SST 是孤儿，没人引用
/// - 1 之后、4 之前崩：同上，SST 是孤儿
/// - 4 之后崩：CURRENT 指向新 MANIFEST，它引用的 SST 已 fsync、
///   新 WAL 也已存在 → 恢复成功；旧 WAL 是垃圾，下次启动会被清掉
/// - 5 之后崩：与 4 之后等价
///
/// **memtable 只能在 4 成功之后清空。** 提前清空的话，
/// 「SST 写好了但 MANIFEST 没写」这种状态下崩溃，重启后 SST 无人引用，
/// 数据就真丢了。
pub fn[S : Storage] Db::flush(self : Db[S]) -> Unit raise LsmError {
  self.ensure_open()
  let entries = self.mem.to_entries()
  if entries.length() == 0 {
    return
  }
  let w = SstWriter::new()
  for e in entries {
    w.add(e)
  }
  let raw = w.finish()
  // 读回校验是廉价的：`open_sst` 会校验 magic / version / 区域边界，
  // 能在几微秒内发现「写出来的东西自己都打不开」这种灾难性 bug。
  let reader = match open_sst(raw) {
    Some(r) => r
    None =>
      raise LsmError::corruption(
        "flush: 刚写出的 SST 无法打开（写读不一致）",
      )
  }
  // 1. SST 先落盘
  let sst_num = self.version.alloc_file_number()
  let sp = sst_path(sst_num)
  Storage::write_file(self.storage, sp, raw)
  Storage::sync_file(self.storage, sp)
  // 2. 新 WAL 空文件先建好并落盘。必须在写 MANIFEST **之前** ——
  //    否则 MANIFEST 会引用一个还不存在的文件，崩溃后恢复直接失败。
  let new_log = self.version.alloc_file_number()
  let np = wal_path(new_log)
  let empty = empty_wal_bytes()
  Storage::write_file(self.storage, np, empty)
  Storage::sync_file(self.storage, np)
  // 3. 更新内存里的版本
  let old_log = self.version.log_number
  self.version.last_seq = self.seq
  self.version.push_to_level(
    0,
    SstMeta::new(
      sst_num,
      raw.length().to_uint64(),
      entries[0].key,
      entries[entries.length() - 1].key,
    ),
  )
  self.version.log_number = new_log
  // 4. 落盘并原子切换。失败就抛错，此时 memtable 原封不动
  self.persist_version()
  // 5. 旧 WAL 可以删了：CURRENT 已经指向新 MANIFEST，它只认 wal/<new_log>
  Storage::remove_file(self.storage, wal_path(old_log)) catch {
    Io(_) => ()
    Corruption(_) => ()
    Closed => ()
  }
  // 6. 内存状态收尾
  self.ssts.insert(0, { num: sst_num, reader })
  self.mem.clear()
  // `pending` 里的帧对应的记录全都在 memtable 里，也就全都进了刚落盘的
  // 这个 SST。SST 已经 fsync 过，所以这些帧可以安全丢弃 —— 不丢的话，
  // 下一次 sync() 会把它们追加到已经换新的 WAL 上，重放时虽然幂等，
  // 但 `wal_bytes` 会凭空变大，stats 看起来像有数据没刷盘。
  self.pending.clear()
  self.wal_bytes = empty.length()
  self.flush_count = self.flush_count + 1
  // 刷完之后看 L0 是不是该归并了。放在 flush 末尾而不是单独的后台线程：
  // v1 没有并发控制，后台 compaction 会和写入抢同一个 version，
  // 引入的锁比它能省下的延迟更值得担心。
  self.maybe_compact()
}

///|
/// 读。返回 `None` 表示「不存在」或「已删除」——
/// 对使用者来说这两种没有区别，墓碑是实现细节。
pub fn[S] Db::get(self : Db[S], key : Bytes) -> Bytes? {
  match self.mem.get(key) {
    Some(e) => return if e.deleted { None } else { Some(e.value) }
    None => ()
  }
  // 哈希只算一次，所有 SST 复用。100 万条数据在 L2 上约 77 个文件，
  // 让每个文件各算一遍 FNV 是 77 倍的无谓开销。
  let (h1, h2) = bloom_hashes(key)
  for s in self.ssts {
    match s.reader.get_hashed(key, h1, h2) {
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
  for s in self.ssts {
    // 用 `scan_range` 而不是 `entries()`：只解出落在 [start, end) 里的块。
    // 全量解出的话，扫 500 条也要付「整个文件」的解码成本，
    // 数据量一大 scan 就退化成 O(整个库)。
    sources.push(s.reader.scan_range(start, end))
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
///|
/// 六位零填充的编号。
///
/// 零填充是必须的：`list_files` 按**字节序**排序，不填充的话
/// `0000010.wal` 会排在 `0000009.wal` 前面，恢复时新旧顺序就反了。
/// 六位意味着上限 999999 个文件 —— 按每次 flush 一个算，
/// 单机每秒 flush 一次也要连续跑 11 天才会耗尽，够用。
fn pad_num(n : UInt64) -> String {
  let digits = n.to_string()
  let mut pad = ""
  for _ in 0..<(6 - digits.length()) {
    pad = pad + "0"
  }
  pad + digits
}

///|
/// `sst/000004.sst`
fn sst_path(n : UInt64) -> String {
  SST_DIR + "/" + pad_num(n) + ".sst"
}

///|
/// `wal/000008.wal`
fn wal_path(n : UInt64) -> String {
  WAL_DIR + "/" + pad_num(n) + ".wal"
}

///|
/// `MANIFEST-000007`
fn manifest_path(n : UInt64) -> String {
  MANIFEST_PREFIX + pad_num(n)
}

///|
/// 从 `000004.sst` 这类文件名里解析出开头的数字。
///
/// 只认开头连续的十进制数字，遇到其他字符就停 —— 所以
/// `000004.sst` 得到 4，`MANIFEST-000007` 要先去掉前缀。
/// 一个数字都没有则返回 `None`（调用方应当忽略这种文件，
/// 而不是把它当成编号 0）。
fn parse_number_prefix(name : String) -> UInt64? {
  let mut n = 0UL
  let mut digits = 0
  for c in name {
    let d = c.to_int() - '0'.to_int()
    if d < 0 || d > 9 {
      break
    }
    n = n * 10UL + d.to_uint64()
    digits = digits + 1
  }
  if digits == 0 {
    None
  } else {
    Some(n)
  }
}

///|
/// 解析 CURRENT 的内容：`"MANIFEST-000007\n"` → `"MANIFEST-000007"`。
///
/// 拒绝任何不是 `MANIFEST-<数字>` 的内容。CURRENT 是一个**约定**，
/// 不是「随便一个文件名」—— 放宽它只会让「CURRENT 被写坏」这种事故
/// 变成「打开了一个莫名其妙的文件」。
fn parse_current(text : String) -> String? {
  // 去掉尾部换行（Windows 上可能是 \r\n）
  let mut body = text
  while body.length() > 0 && body.has_suffix("\n") {
    body = body[:body.length() - 1].to_owned()
  }
  while body.length() > 0 && body.has_suffix("\r") {
    body = body[:body.length() - 1].to_owned()
  }
  if !has_prefix(body, MANIFEST_PREFIX) {
    return None
  }
  let rest = body[MANIFEST_PREFIX.length():].to_owned()
  match parse_number_prefix(rest) {
    Some(_) => Some(body)
    None => None
  }
}
