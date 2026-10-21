///|
/// 存储后端抽象。
///
/// 引擎只依赖这个 trait，不直接碰任何 IO 原语。这不是为了「可插拔」这种
/// 架构洁癖，而是为了两件具体的事：
///
/// 1. **崩溃契约可以测**。C1「已确认的写入必不丢」要验证「fsync 之后
///    断电还在」，就必须能模拟断电。用真进程 + kill -9 只能测到「进程
///    死了数据还在」，测不出「忘了 fsync」——kill -9 不清 OS 页缓存。
///    `MemStorage` 维护「当前内容」和「已落盘内容」两份影子，
///    `power_loss()` 回滚到后者，于是断电语义可以在 `moon test` 里
///    确定性地跑，还能在 wasm-gc / js 后端上跑。
///
/// 2. **平台差异被关在一处**。`fsync` 在 POSIX 存在、Windows 没有
///    （只有 `_commit`）；`ftruncate` 同理。这两个符号名不同、
///    Windows 的 CRT 里根本没有 POSIX 那个名字，链接期就会失败。
///    差异全部收在 `fs_native.mbt`，核心逻辑一行平台判断都没有。
///
/// 所有名字都是**相对路径**，由后端自己决定根目录。
pub trait Storage {
  ///|
  /// 后端就绪（native 后端在这里建目录）。可重复调用。
  fn prepare(Self) -> Unit raise LsmError

  ///|
  /// 读整个文件。不存在返回 `None`，**不是错误**——
  /// 「文件不存在」和「读失败」在恢复路径上是两种完全不同的处理。
  fn read_file(Self, String) -> Bytes? raise LsmError

  ///|
  /// 覆盖写：先截断再写。用于 SST、MANIFEST 这类一次成型的文件。
  fn write_file(Self, String, Bytes) -> Unit raise LsmError

  ///|
  /// 追加写。用于 WAL——每帧追加，不重写已有内容。
  fn append_file(Self, String, Bytes) -> Unit raise LsmError

  ///|
  /// 批量追加：语义等价于对 `chunks` 里每一段依次调用 `append_file`，
  /// 但**只打开一次文件**。
  ///
  /// 为什么需要单独一个方法：真文件系统上 `fopen`/`fclose` 的开销远大于
  /// `fwrite`。在 Windows 上实测每次追加约 5.9 ms，而且与写入字节数几乎无关
  /// —— 一个 200 条的 `putmany` 因此要 1.2 秒，其中 99% 花在反复开关文件上。
  ///
  /// 注意：这个方法**不隐含 sync**，和 `append_file` 一样。
  fn append_frames(Self, String, Array[Bytes]) -> Unit raise LsmError

  ///|
  /// 把已写入的数据刷到持久介质。返回后，这些字节必须能在断电后存活。
  ///
  /// 这是 C1 的唯一实现点。注意 `append_file` **不隐含** sync：
  /// 批量提交时调用方可以选择一次 sync 覆盖多条记录。
  fn sync_file(Self, String) -> Unit raise LsmError

  ///|
  /// 同目录内原子改名。CURRENT 的原子切换靠它。
  fn rename_file(Self, String, String) -> Unit raise LsmError

  ///|
  /// 删除文件。文件不存在不算错误（恢复路径会重复清理）。
  fn remove_file(Self, String) -> Unit raise LsmError

  ///|
  /// 文件大小。不存在返回 `None`。
  fn file_size(Self, String) -> Int? raise LsmError

  ///|
  /// 列出所有以 `prefix` 开头的文件名。用于清理崩溃残留的孤儿文件。
  fn list_files(Self, String) -> Array[String] raise LsmError
}

///|
/// 内存后端。
///
/// 两份影子：`files` 是「当前内容」（含尚未落盘的），`durable` 是
/// 「已 fsync 的内容」。正常读写只看 `files`；`power_loss()` 把
/// `files` 回滚到 `durable`，于是「断电」变成一次确定性的内存操作。
///
/// 这个模型刻意比真磁盘更严格：真磁盘上未 fsync 的页**可能**会幸存
/// （OS 迟早会写下去），也可能不会。这里一律当作「不会」，
/// 也就是**只允许更悲观的崩溃**。测试因此不会假阳性。
pub struct MemStorage {
  files : Map[String, Bytes]
  durable : Map[String, Bytes]
  mut syncs : Int
  mut fail_sync : Bool
  mut fail_write : Bool
}

///|
pub fn MemStorage::new() -> MemStorage {
  {
    files: Map([]),
    durable: Map([]),
    syncs: 0,
    fail_sync: false,
    fail_write: false,
  }
}

///|
/// 已经发生的 `sync_file` 次数。用来断言「批量写只 sync 一次」这类行为。
pub fn MemStorage::syncs(self : MemStorage) -> Int {
  self.syncs
}

///|
/// 让下一次 `sync_file` 失败。用来测「fsync 失败时不能对外确认」。
pub fn MemStorage::set_fail_sync(self : MemStorage, v : Bool) -> Unit {
  self.fail_sync = v
}

///|
/// 让下一次 `append_file` / `write_file` 失败。
pub fn MemStorage::set_fail_write(self : MemStorage, v : Bool) -> Unit {
  self.fail_write = v
}

///|
/// 模拟断电：所有未 sync 的改动消失，已 sync 的回到 sync 时的样子。
///
/// 注意顺序：先删掉「只在 files 里、durable 里没有」的文件（写了一半
/// 就断电，文件本身都不该存在），再把 durable 的内容覆盖回去。
pub fn MemStorage::power_loss(self : MemStorage) -> Unit {
  let names : Array[String] = []
  for k, _ in self.files {
    names.push(k)
  }
  for k in names {
    if self.durable.get(k) is None {
      ignore(self.files.remove(k))
    }
  }
  for k, v in self.durable {
    self.files.set(k, v)
  }
}

///|
/// 直接设定「磁盘上已有的内容」，同时写进两份影子。
///
/// 用于构造恢复场景：手工摆出「WAL 尾部有半条记录」「MANIFEST 指向
/// 不存在的 SST」这类状态，比用引擎自己写出这种状态可靠得多。
pub fn MemStorage::plant(
  self : MemStorage,
  name : String,
  data : Bytes,
) -> Unit {
  self.files.set(name, data)
  self.durable.set(name, data)
}

///|
/// 只改「已落盘内容」，不动当前视图。用于构造「磁盘上有一份旧数据，
/// 而当前视图是新的」这种不一致状态。
pub fn MemStorage::plant_durable(
  self : MemStorage,
  name : String,
  data : Bytes,
) -> Unit {
  self.durable.set(name, data)
}

///|
/// 当前所有文件名，测试断言用。
pub fn MemStorage::names(self : MemStorage) -> Array[String] {
  let out : Array[String] = []
  for k, _ in self.files {
    out.push(k)
  }
  out.sort_by(fn(a, b) { compare_strings(a, b) })
  out
}

///|
fn MemStorage::guard_write(
  self : MemStorage,
  name : String,
) -> Unit raise LsmError {
  if self.fail_write {
    raise LsmError::io("MemStorage: 注入的写入失败 (\{name})")
  }
}

///|
pub impl Storage for MemStorage with fn prepare(_self) -> Unit raise LsmError {

}

///|
pub impl Storage for MemStorage with fn read_file(self, name) -> Bytes? raise LsmError {
  self.files.get(name)
}

///|
pub impl Storage for MemStorage with fn write_file(self, name, data) -> Unit raise LsmError {
  self.guard_write(name)
  self.files.set(name, data)
}

///|
pub impl Storage for MemStorage with fn append_file(self, name, data) -> Unit raise LsmError {
  self.guard_write(name)
  let merged = match self.files.get(name) {
    Some(old) => {
      let b = Buffer::Buffer()
      b.write_bytes(old[:])
      b.write_bytes(data[:])
      b.to_bytes()
    }
    None => data
  }
  self.files.set(name, merged)
}

///|
/// 批量追加。内存后端没有「打开文件」的成本，所以这里刻意**退化成一次
/// 拼接**而不是循环调用 `append_file`：N 次追加 N 次拼接是 O(N²) 的字节拷贝，
/// 而先算总长再一次性写是 O(N)。
///
/// 语义必须与循环调用完全一致（同样的失败注入、同样的结果字节），
/// 否则内存后端上的测试就不能代表真文件系统的行为了。
pub impl Storage for MemStorage with fn append_frames(self, name, chunks) -> Unit raise LsmError {
  self.guard_write(name)
  if chunks.length() == 0 {
    return
  }
  let b = Buffer::Buffer()
  match self.files.get(name) {
    Some(old) => b.write_bytes(old[:])
    None => ()
  }
  for c in chunks {
    b.write_bytes(c[:])
  }
  self.files.set(name, b.to_bytes())
}

///|
pub impl Storage for MemStorage with fn sync_file(self, name) -> Unit raise LsmError {
  if self.fail_sync {
    raise LsmError::io("MemStorage: 注入的 fsync 失败 (\{name})")
  }
  self.syncs = self.syncs + 1
  match self.files.get(name) {
    Some(v) => self.durable.set(name, v)
    None => ignore(self.durable.remove(name))
  }
}

///|
/// 改名同时作用于两份影子：本模型假设调用方在 rename 之后会 fsync
/// 所在目录（native 后端确实这么做），所以 rename 本身是立即持久的。
pub impl Storage for MemStorage with fn rename_file(self, from, to) -> Unit raise LsmError {
  match self.files.get(from) {
    Some(v) => {
      self.files.set(to, v)
      ignore(self.files.remove(from))
      self.durable.set(to, v)
      ignore(self.durable.remove(from))
    }
    None => raise LsmError::io("MemStorage: 改名源不存在 (\{from})")
  }
}

///|
pub impl Storage for MemStorage with fn remove_file(self, name) -> Unit raise LsmError {
  ignore(self.files.remove(name))
  ignore(self.durable.remove(name))
}

///|
pub impl Storage for MemStorage with fn file_size(self, name) -> Int? raise LsmError {
  match self.files.get(name) {
    Some(v) => Some(v.length())
    None => None
  }
}

///|
pub impl Storage for MemStorage with fn list_files(self, prefix) -> Array[
  String,
] raise LsmError {
  let out : Array[String] = []
  for k, _ in self.files {
    if has_prefix(k, prefix) {
      out.push(k)
    }
  }
  out.sort_by(fn(a, b) { compare_strings(a, b) })
  out
}

///|
/// 前缀判断。不用 `String::has_prefix` 是因为需要它是纯字节语义，
/// 与 key 比较保持一致。
fn has_prefix(s : String, prefix : String) -> Bool {
  let sb = @utf8.encode(s)
  let pb = @utf8.encode(prefix)
  if pb.length() > sb.length() {
    return false
  }
  for i in 0..<pb.length() {
    if sb[i] != pb[i] {
      return false
    }
  }
  true
}
