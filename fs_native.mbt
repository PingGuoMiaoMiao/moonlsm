// 本文件只在 native 后端编译（见 moon.pkg 的 targets 配置）。
// wasm-gc / js 没有 libc，`extern "C"` 到 fopen 会直接链接失败。
//
// 平台差异全部收在这个文件里，核心逻辑一行平台判断都没有。
// 两个真实的坑，都是链接期才暴露的：
//
//   1. `fsync` 在 Windows 的 CRT 里**不存在**，只有 `_commit`。
//      直接声明 `fsync` 会在 link 阶段报 LNK2019。
//   2. `ftruncate` 同理（Windows 只有 `_chsize`），
//      而且 `_mkdir` 只接 1 个参数、POSIX 的 `mkdir` 接 2 个。
//
// MoonBit 的条件编译属性是 `#cfg(platform = "windows")`——
// 注意是 `platform`（操作系统），不是 `target`（native / wasm-gc / js）。
// 两个 key 都存在，用错 `target` 会得到一个永远不成立的谓词，
// 症状是「函数未定义」而不是「链接失败」，比链接错误更难查。

///|
/// String 转 C 字符串（补 NUL）。所有路径与模式串都走这里。
fn cstr(s : String) -> Bytes {
  let b = Buffer::Buffer()
  b.write_bytes(@utf8.encode(s)[:])
  b.write_byte((0).to_byte())
  b.to_bytes()
}

// ---------------------------------------------------------------------------
// stdio
// ---------------------------------------------------------------------------

///|
#borrow(path, mode)
extern "C" fn c_fopen(path : Bytes, mode : Bytes) -> UInt64 = "fopen"

///|
#borrow(ptr)
extern "C" fn c_fwrite(
  ptr : Bytes,
  size : Int32,
  n : Int32,
  f : UInt64,
) -> UInt64 = "fwrite"

///|
#borrow(ptr)
extern "C" fn c_fread(
  ptr : Bytes,
  size : Int32,
  n : Int32,
  f : UInt64,
) -> UInt64 = "fread"

///|
extern "C" fn c_fflush(f : UInt64) -> Int32 = "fflush"

///|
extern "C" fn c_fclose(f : UInt64) -> Int32 = "fclose"

///|
extern "C" fn c_fileno(f : UInt64) -> Int32 = "fileno"

// 64 位定位。Windows 上 `long` 是 32 位，`fseek` 只能定位到 2 GiB；
// POSIX 上 `fseeko` 的 `off_t` 是 64 位。两边函数名不同，必须分开声明。

///|
#cfg(platform="windows")
extern "C" fn c_seek(f : UInt64, off : Int64, whence : Int32) -> Int32 = "_fseeki64"

///|
#cfg(platform="windows")
extern "C" fn c_tell(f : UInt64) -> Int64 = "_ftelli64"

///|
#cfg(not(platform="windows"))
extern "C" fn c_seek(f : UInt64, off : Int64, whence : Int32) -> Int32 = "fseeko"

///|
#cfg(not(platform="windows"))
extern "C" fn c_tell(f : UInt64) -> Int64 = "ftello"

// ---------------------------------------------------------------------------
// 持久化：C1 的唯一实现点
// ---------------------------------------------------------------------------

///|
#cfg(platform="windows")
extern "C" fn c_sync_fd(fd : Int32) -> Int32 = "_commit"

///|
#cfg(not(platform="windows"))
extern "C" fn c_sync_fd(fd : Int32) -> Int32 = "fsync"

// ---------------------------------------------------------------------------
// 目录与文件管理
// ---------------------------------------------------------------------------

///|
#cfg(platform="windows")
#borrow(p)
extern "C" fn c_mkdir_win(p : Bytes) -> Int32 = "_mkdir"

///|
#cfg(not(platform="windows"))
#borrow(p)
extern "C" fn c_mkdir_posix(p : Bytes, mode : Int32) -> Int32 = "mkdir"

///|
#cfg(platform="windows")
fn mkdir_at(p : Bytes) -> Int32 {
  c_mkdir_win(p)
}

///|
#cfg(not(platform="windows"))
fn mkdir_at(p : Bytes) -> Int32 {
  c_mkdir_posix(p, 0x1FF)
}

///|
#cfg(not(platform="windows"))
#borrow(a, b)
extern "C" fn c_rename_posix(a : Bytes, b : Bytes) -> Int32 = "rename"

// Windows 的 `rename` 在目标已存在时**直接失败**（POSIX 是原子覆盖）。
// CURRENT 的切换每次都是「新名字覆盖旧名字」，所以这里必须用
// MoveFileExA + MOVEFILE_REPLACE_EXISTING，否则第二次 flush 之后
// 数据库就再也启动不了了。
//
// 顺带解决持久性：MOVEFILE_WRITE_THROUGH (0x8) 会等改名真正落盘才返回，
// 等价于 POSIX 那边对目录做 fsync。

///|
#cfg(platform="windows")
#borrow(a, b)
extern "C" fn c_move_win(a : Bytes, b : Bytes, flags : Int32) -> Int32 = "MoveFileExA"

///|
/// 统一成「返回 0 = 成功」。
///
/// 两个平台的约定是**相反**的：POSIX `rename` 返回 0 表示成功，
/// Windows `MoveFileExA` 返回**非 0** 表示成功。直接透传返回值，
/// 调用方的 `!= 0` 判断在 Windows 上就完全颠倒了——
/// 表现为「改名成功时报错、失败时静默通过」，是最难查的那类 bug。
/// 所以归一化必须在 `rename_at` 内部完成，不能泄漏给调用方。
#cfg(platform="windows")
fn rename_at(from : Bytes, to : Bytes) -> Int32 {
  if c_move_win(from, to, 0x1 | 0x8) != 0 {
    0
  } else {
    -1
  }
}

///|
#cfg(not(platform="windows"))
fn rename_at(from : Bytes, to : Bytes) -> Int32 {
  c_rename_posix(from, to)
}

///|
#borrow(p)
extern "C" fn c_remove(p : Bytes) -> Int32 = "remove"

// 目录 fsync：rename 只保证「原子」，不保证「持久」。
// 要把 CURRENT 的切换变成崩溃后可见的事实，必须 fsync 所在目录。
// Windows 上目录不是文件句柄，`_commit` 对目录无效，所以只做 POSIX。

///|
#cfg(not(platform="windows"))
#borrow(p)
extern "C" fn c_open(p : Bytes, flags : Int32, mode : Int32) -> Int32 = "open"

///|
#cfg(not(platform="windows"))
extern "C" fn c_close(fd : Int32) -> Int32 = "close"

// ---------------------------------------------------------------------------
// 读写辅助
//
// 这两个函数**故意不 raise**，而是返回 (数据, 错误信息)。
// 用 raise 的写法更顺，但会让调用方在抛错前拿不到机会关闭句柄——
// 出错路径上泄漏 fd，长跑进程里迟早把描述符耗尽，而且这种 bug
// 只在「一直失败」的场景下出现，测试很难覆盖到。
// 先收尾、再抛错，是这一层唯一正确的顺序。
// ---------------------------------------------------------------------------

///|
/// 从当前已打开的文件读全部内容。错误信息为空串表示成功。
fn read_all_from(f : UInt64, what : String) -> (Bytes, String) {
  // SEEK_END = 2, SEEK_SET = 0
  if c_seek(f, 0L, 2) != 0 {
    return (b"", "读取失败：定位到末尾 (\{what})")
  }
  let n = c_tell(f)
  if c_seek(f, 0L, 0) != 0 {
    return (b"", "读取失败：回到开头 (\{what})")
  }
  if n <= 0L {
    return (b"", "")
  }
  let size = n.to_int()
  let buf = Bytes::makei(size, fn(_i) { (0).to_byte() })
  let got = c_fread(buf, 1, size, f)
  if got.to_int() != size {
    let msg = "读取失败：只读到 \{got.to_int()} / \{size} 字节 (\{what})"
    return (b"", msg)
  }
  (buf, "")
}

///|
/// 写完整段数据。错误信息为空串表示成功。
fn write_all_to(f : UInt64, data : Bytes, what : String) -> String {
  if data.length() == 0 {
    return ""
  }
  let n = c_fwrite(data, 1, data.length(), f)
  if n.to_int() != data.length() {
    return "写入失败：只写了 \{n.to_int()} / \{data.length()} 字节 (\{what})"
  }
  ""
}

///|
/// 常开的追加句柄。只记 `name` 和 `FILE*`：模式永远是 `"ab"`，
/// 因为只有追加路径需要它（见 `NativeStorage::handle_for`）。
struct AppendHandle {
  name : String
  f : UInt64
}

///|
/// 文件系统后端。
///
/// **追加路径保持一个常开句柄**（ADR-0009）。同场 A/B：单条 `put`
/// 56–64 → 384–399 ops/s（约 6.3×）。
///
/// 成本在「每条写开关两次文件」上：这台机器上 `fopen`+写+`fclose` 要 7.10 ms，
/// `fopen`+`fsync`+`fclose` 要 1.62 ms，两步连起来 9.97 ms（500 次 × 3 轮中位数）。
/// 常开句柄把两次开关压成零，只剩「同一个句柄上 `fflush` + `fsync`」的 2.03 ms。
///
/// 只缓存**一个**句柄，不做句柄表：
/// - 写路径上真正反复打开的只有活跃 WAL；SST / MANIFEST 是一次成型文件，
///   缓存它们只是增加「什么时候失效」的状态。
/// - 一个句柄的失效规则简单到可以逐条列出来（`write_file` / `rename_file` /
///   `remove_file` 全部先关），不会出现「表里某个条目忘了失效」的漏洞。
///
/// 失效是**无条件**的，不判断文件名是否相同：这三个操作都很少发生，
/// 多关一次的代价只是一次 `fopen`，而漏关一次的代价是 Windows 上
/// 「删不掉 / 改不了名」——那种 bug 只在特定平台特定顺序下出现。
///
/// 语义没有任何变化：`append_*` 仍然不隐含 fsync，`sync_file` 仍然是
/// C1 的唯一实现点。`fflush` 在每次追加后立刻调用，所以「另开句柄读」
/// 看到的仍然是已写入的全部字节。
pub struct NativeStorage {
  root : String
  /// 常开的追加句柄，最多一个。`None` 表示当前没有缓存。
  mut handle : AppendHandle?
}

///|
/// `root` 是数据目录。传空串表示当前目录。
/// 所有文件路径都是 `root + "/" + name`，Windows 也接受 `/` 作为分隔符。
pub fn NativeStorage::new(root : String) -> NativeStorage {
  { root, handle: None, }
}

///|
/// 关掉常开句柄。没有缓存时是空操作。
///
/// 调用时机由内部逻辑决定（写覆盖 / 改名 / 删除前）；外部只在
/// 「确定不再写这个目录」时调用，比如测试收尾、进程退出前。
/// 不调用也不会丢数据 —— 未 fsync 的数据在 OS 页缓存里，
/// 而句柄本身由 OS 在进程退出时回收。
pub fn NativeStorage::close(self : NativeStorage) -> Unit {
  self.close_handle()
}

///|
fn NativeStorage::close_handle(self : NativeStorage) -> Unit {
  match self.handle {
    Some(h) => {
      ignore(c_fclose(h.f))
      self.handle = None
    }
    None => ()
  }
}

///|
/// 取 `name` 的追加句柄：命中缓存直接返回，否则关旧开新。
fn NativeStorage::handle_for(
  self : NativeStorage,
  name : String,
) -> UInt64 raise LsmError {
  let cached = match self.handle {
    Some(h) => if h.name == name { Some(h.f) } else { None }
    None => None
  }
  match cached {
    Some(f) => f
    None => {
      // 换文件（或还没有缓存）：先关旧的再开新的。
      // 顺序不能反 —— 反了就是两个句柄同时开着，Windows 上第一个
      // 会一直占着文件，直到进程退出。
      self.close_handle()
      let f = self.open_or_fail(name, "ab")
      self.handle = Some({ name, f, })
      f
    }
  }
}

///|
/// 数据目录路径，测试和错误信息里要用。
pub fn NativeStorage::root(self : NativeStorage) -> String {
  self.root
}

///|
fn NativeStorage::path(self : NativeStorage, name : String) -> Bytes {
  if self.root == "" {
    cstr(name)
  } else {
    cstr(self.root + "/" + name)
  }
}

///|
fn NativeStorage::dir(self : NativeStorage) -> Bytes {
  if self.root == "" {
    cstr(".")
  } else {
    cstr(self.root)
  }
}

///|
/// 打开失败一律当作 IO 错误。需要区分「不存在」的调用方自己先探一次。
fn NativeStorage::open_or_fail(
  self : NativeStorage,
  name : String,
  mode : String,
) -> UInt64 raise LsmError {
  let f = c_fopen(self.path(name), cstr(mode))
  if f == 0UL {
    raise LsmError::io("打开文件失败 (\{name}, mode=\{mode})")
  }
  f
}

///|
/// 把 stdio 缓冲推到 OS。CLI 每输出一行就要调一次——管道下的 stdout
/// 是块缓冲的，不推的话驱动脚本读不到输出。
///
/// ⚠️ **不要在别处再声明一次 `fflush`**。
///
/// 同一个 C 符号被两处不同签名的 `extern "C"` 声明时，编译器只会保留
/// 其中一个原型。如果其中一处写的是 `Int`（32 位），而库内按 `UInt64`
/// 传 `FILE*`，指针会在调用点被截断成 32 位——症状是 `fflush` 内部
/// 段错误，而崩溃点跟调用方看起来毫无关系。
///
/// 这个 bug 真的发生过：`cmd/dbcli` 自己声明了一份
/// `extern "C" fn fflush(Int) -> Int`，结果整个 CLI 一启动就
/// `0xc0000005`，排查了很久才定位到「两个签名不一致」。
/// 统一从这里出去，就只有一个声明点了。
pub fn flush_stdio() -> Unit {
  ignore(c_fflush(0UL))
}

///|
/// 目录 fsync。POSIX 专用；Windows 上是空操作（见文件头的说明）。
///
/// 条件编译只能加在**条目**（函数、let）上，不能加在语句块上，
/// 所以这里拆成两个同名的 `sync_dir_at`，而不是在函数体里写 `#cfg`。
fn NativeStorage::sync_dir(self : NativeStorage) -> Unit {
  sync_dir_at(self.dir())
}

///|
#cfg(platform="windows")
fn sync_dir_at(_dir : Bytes) -> Unit {

}

///|
#cfg(not(platform="windows"))
fn sync_dir_at(dir : Bytes) -> Unit {
  // O_RDONLY = 0。目录只能以只读打开，fsync 它才会把 rename 落盘。
  let fd = c_open(dir, 0, 0)
  if fd >= 0 {
    ignore(c_sync_fd(fd))
    ignore(c_close(fd))
  }
}

///|
/// 显式声明「trait 方法同时作为 `NativeStorage` 的普通方法可用」。
/// 理由见 `storage.mbt` 里 `MemStorage` 那处同样的声明。
pub extend NativeStorage with Storage::{
  list_files,
  rename_file,
  append_frames,
  prepare,
  write_file,
  append_file,
  file_size,
  read_file,
  remove_file,
  sync_file,
}

///|
/// 建目录。
///
/// `mkdir` 只建一级，父目录不存在就失败（Windows 返回 ENOENT，POSIX 同理）。
/// 测试目录是 `.moonlsm_test/rw` 这种两级路径，所以必须逐级创建。
///
/// 每一级的返回值都忽略：目录已存在时 mkdir 必然返回 -1，
/// 这不算错误。真正的失败（比如权限不足）会在后续写入时暴露。
pub impl Storage for NativeStorage with fn prepare(self) -> Unit raise LsmError {
  if self.root == "" {
    return
  }
  mkdir_chain(self.root)
  // 子目录也要建：`list_files` 依赖运行时的 `moonbit_read_dir_ffi`，
  // 它在 opendir 失败时返回 NULL，到 MoonBit 侧就是一个空指针的
  // FixedArray —— 访问会直接段错误，不是可捕获的错误。
  // 所以「目录一定存在」必须在这一层保证。
  mkdir_chain(self.root + "/" + SST_DIR)
  mkdir_chain(self.root + "/" + WAL_DIR)
}

///|
/// 逐级建目录，**保留原有的路径形态**。
///
/// 不能用「按 `/` 切开再拼接」的写法：那样会把开头的 `/` 丢掉，
/// `/tmp/x` 会变成 `tmp/x`，于是目录建到了当前目录下，
/// 而后续的 `fopen("/tmp/x/...")` 仍然指向不存在的地方。
/// 症状是「第一次打开就段错误」，排查时完全看不出跟路径有关。
///
/// 所以这里改成「在每个分隔符处截一个前缀」，前缀天然带着开头的 `/`
/// 和 Windows 的盘符。
fn mkdir_chain(path : String) -> Unit {
  let b = @utf8.encode(path)
  for i in 1..<b.length() {
    // '/' = 47, '\\' = 92。Windows 上两种分隔符都要认
    if b[i].to_int() == 47 || b[i].to_int() == 92 {
      let prefix = @utf8.decode_lossy(take_prefix(b, i))
      if prefix.length() > 0 {
        ignore(mkdir_at(cstr(prefix)))
      }
    }
  }
  ignore(mkdir_at(cstr(path)))
}

///|
pub impl Storage for NativeStorage with fn read_file(self, name) -> Bytes? raise LsmError {
  let f = c_fopen(self.path(name), cstr("rb"))
  if f == 0UL {
    // 打不开就是「不存在」。真正的权限错误会在后面的读操作上暴露，
    // 这一层不替调用方猜原因。
    return None
  }
  let (data, err) = read_all_from(f, name)
  ignore(c_fclose(f))
  if err != "" {
    raise LsmError::io(err)
  }
  Some(data)
}

///|
pub impl Storage for NativeStorage with fn write_file(self, name, data) -> Unit raise LsmError {
  // 覆盖写会截断文件，而截断与「另一个还开着的句柄」混用是不可推理的：
  // 那个句柄的追加位置、CRT 缓存的文件长度都可能停在旧值上。
  // 与其论证「`ab` 模式下每次写都会重新定位到末尾所以没事」，
  // 不如直接关掉 —— 一次 fopen 换掉一整类平台相关的疑虑。
  self.close_handle()
  let f = self.open_or_fail(name, "wb")
  let err = write_all_to(f, data, name)
  // fflush 把 stdio 缓冲交给 OS；是否真正落盘由 sync_file 决定。
  // 两个动作分开，是因为批量提交时调用方要能「写 N 条、sync 1 次」。
  ignore(c_fflush(f))
  ignore(c_fclose(f))
  if err != "" {
    raise LsmError::io(err)
  }
}

///|
pub impl Storage for NativeStorage with fn append_file(self, name, data) -> Unit raise LsmError {
  let f = self.handle_for(name)
  let err = write_all_to(f, data, name)
  // 常开句柄意味着数据会跨调用留在 stdio 缓冲里。这里必须立刻 fflush：
  // 不刷的话，另开句柄的 `read_file` 看不到刚写的字节，而恢复路径正是
  // 「写完 WAL 立刻读回来」的。
  ignore(c_fflush(f))
  if err != "" {
    // 写失败之后句柄的内部状态不可信（部分写入 + 错误标志），
    // 关掉让下一次重开，而不是带着错误标志继续用。
    self.close_handle()
    raise LsmError::io(err)
  }
}

///|
/// 批量追加：**一次取句柄，N 次 fwrite**。
///
/// 这不是微优化，是量级差异。Windows 上实测单次 `fopen`+`fclose`
/// 约 5.9 ms（杀软实时扫描 / 句柄创建都算在内），而 `fwrite` 几百字节
/// 几乎免费。所以 200 条的批次：
///
/// ```
/// 循环 append_file : 200 × 5.9ms ≈ 1180 ms
/// append_frames    :   1 × 5.9ms + 200 × ~0 ≈    6 ms
/// ```
///
/// 实测从 1200ms 降到 6ms，两个数量级。
///
/// ADR-0009 之后「一次」可能降到零：活跃 WAL 的句柄是常开的，
/// 这一批直接复用它。
///
/// 出错时先关句柄再抛错，不留「带着错误标志」的缓存。
pub impl Storage for NativeStorage with fn append_frames(self, name, chunks) -> Unit raise LsmError {
  if chunks.length() == 0 {
    return
  }
  let f = self.handle_for(name)
  let mut err = ""
  for c in chunks {
    // 一旦出错就停：继续写只会产生更多垃圾，而且错误信息会被后面的覆盖
    if err == "" {
      err = write_all_to(f, c, name)
    }
  }
  ignore(c_fflush(f))
  if err != "" {
    self.close_handle()
    raise LsmError::io(err)
  }
}

///|
pub impl Storage for NativeStorage with fn sync_file(self, name) -> Unit raise LsmError {
  let cached = match self.handle {
    Some(h) => if h.name == name { Some(h.f) } else { None }
    None => None
  }
  match cached {
    Some(f) => {
      // 命中缓存：fflush + fsync 同一个 fd，不再 fopen/fclose。
      // 这是单条 `put` 从 13.2 ms 降到 ~1 ms 的那一刀。
      ignore(c_fflush(f))
      let fd = c_fileno(f)
      if fd < 0 {
        self.close_handle()
        raise LsmError::io("取文件描述符失败 (\{name})")
      }
      if c_sync_fd(fd) != 0 {
        // fsync 失败说明介质或句柄出了问题，不再复用这个句柄。
        self.close_handle()
        raise LsmError::io("fsync 失败 (\{name})")
      }
    }
    None => {
      // 没有缓存：沿用「打开 → fsync → 关闭」。
      // "rb+" 不截断、不创建：对一个还不存在的文件做 fsync 是逻辑错误，
      // 应该报错而不是悄悄建一个空文件出来。
      let f = self.open_or_fail(name, "rb+")
      let fd = c_fileno(f)
      if fd < 0 {
        ignore(c_fclose(f))
        raise LsmError::io("取文件描述符失败 (\{name})")
      }
      let rc = c_sync_fd(fd)
      ignore(c_fclose(f))
      if rc != 0 {
        raise LsmError::io("fsync 失败 (\{name})")
      }
    }
  }
}

///|
pub impl Storage for NativeStorage with fn rename_file(self, from, to) -> Unit raise LsmError {
  // Windows 不允许改名一个被自己打开的文件（sharing violation），
  // POSIX 允许但会让「改名后旧句柄继续写」变成一次静默的数据错乱。
  // 所以先关缓存，不管改的是不是缓存里的那个文件。
  self.close_handle()
  if rename_at(self.path(from), self.path(to)) != 0 {
    raise LsmError::io("改名失败 (\{from} -> \{to})")
  }
  // POSIX 上 rename 只是「原子」，不等于「持久」：断电后目录项可能回到
  // 旧状态，必须再 fsync 目录。Windows 上 MOVEFILE_WRITE_THROUGH 已经
  // 等落盘了，这里 sync_dir_at 是空操作。
  self.sync_dir()
}

///|
pub impl Storage for NativeStorage with fn remove_file(self, name) -> Unit raise LsmError {
  // 同 rename：Windows 上删不掉一个被打开的文件。
  // 这一步在 `flush` 里删旧 WAL 时一定会走到，而旧 WAL 正是缓存里的那个。
  self.close_handle()
  // 不存在不算错误：恢复路径会重复清理同一批文件。
  ignore(c_remove(self.path(name)))
}

///|
pub impl Storage for NativeStorage with fn file_size(self, name) -> Int32? raise LsmError {
  let f = c_fopen(self.path(name), cstr("rb"))
  if f == 0UL {
    return None
  }
  let ok = c_seek(f, 0L, 2) == 0
  let n = if ok { c_tell(f) } else { -1L }
  ignore(c_fclose(f))
  if !ok || n < 0L {
    return None
  }
  Some(n.to_int())
}

///|
pub impl Storage for NativeStorage with fn list_files(self, dir) -> Array[
  String,
] raise LsmError {
  // 没有可移植的 readdir：POSIX 是 opendir/readdir，Windows 是
  // FindFirstFile。这里用 MoonBit 运行时自带的实现（runtime/sync_io.c
  // 里的 moonbit_read_dir_ffi），它已经把两边都封好了。
  //
  // 前提：目录必须存在。运行时实现在 opendir 失败时返回 NULL，
  // 而这个 NULL 到了 MoonBit 侧就是一个空指针的 FixedArray——访问它
  // 会直接段错误，不是可捕获的错误。
  //
  // 只靠「先 prepare」不够：prepare 自己也可能因为权限之类的原因失败。
  // 所以这里再用一次存在性检查兜底，宁可返回空列表也不要崩。
  Storage::prepare(self)
  let target = self.subdir(dir)
  if c_is_dir(target) != 1 {
    return []
  }
  let names = c_read_dir(target)
  let out : Array[String] = []
  for i in 0..<names.length() {
    // 真文件系统的 readdir 会返回 `.` / `..`，必须过滤掉。
    // 不过滤的话 `list_files("sst")` 会给出两个假名字，
    // 解析编号时得到 0，进而把 `next_file_number` 算错。
    let s = @utf8.decode_lossy(names[i])
    if s == "." || s == ".." {
      continue
    }
    // 跳过子目录。`readdir` 会把 `sst/` / `wal/` 也列出来，
    // 而 `Storage::list_files` 的契约是「这一层的**文件**」——
    // 内存后端只可能存文件，两边语义必须一致，否则
    // 「内存后端跑绿的用例换真文件系统就红」。
    if c_is_dir(self.entry_path(dir, s)) == 1 {
      continue
    }
    out.push(s)
  }
  out.sort_by(fn(a, b) { compare_strings(a, b) })
  out
}

///|
/// 某个目录里一个条目的完整路径。用来做「这是文件还是子目录」的判断。
fn NativeStorage::entry_path(
  self : NativeStorage,
  dir : String,
  name : String,
) -> Bytes {
  let rel = if dir == "" { name } else { dir + "/" + name }
  if self.root == "" {
    cstr(rel)
  } else {
    cstr(self.root + "/" + rel)
  }
}

///|
/// 子目录的完整路径。`dir == ""` 就是数据目录本身。
fn NativeStorage::subdir(self : NativeStorage, dir : String) -> Bytes {
  if dir == "" {
    return self.dir()
  }
  if self.root == "" {
    cstr(dir)
  } else {
    cstr(self.root + "/" + dir)
  }
}

///|
/// 运行时导出的目录列举。返回一个 MoonBit 的引用数组，
/// 布局与 `Array[Bytes]` 一致，所以可以直接声明成这个类型。
#borrow(path)
extern "C" fn c_read_dir(path : Bytes) -> FixedArray[Bytes] = "moonbit_read_dir_ffi"

///|
/// 目录存在性检查。同样是运行时导出：1 = 是目录，0 = 存在但不是目录，
/// -1 = 不存在或无法访问。用它给 `c_read_dir` 做前置守卫。
#borrow(p)
extern "C" fn c_is_dir(p : Bytes) -> Int32 = "moonbit_is_dir_ffi"

///|
/// 用 native 后端打开数据库。
///
/// 这是一个**非泛型**入口，专门给跨包调用方（`cmd/dbcli`）用。
/// 直接跨包调 `Db::open(storage, ...)` 会在进入函数体之前就段错误——
/// 泛型结构体按值跨包传递在这个工具链版本上不可靠。
/// 包一层非泛型函数把实例化点留在库内，就绕开了这个问题。
pub fn open_native(
  dir : String,
  mem_limit : Int32,
) -> Db[NativeStorage] raise LsmError {
  Db::open(NativeStorage::new(dir), mem_limit)
}
