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
extern "C" fn c_fwrite(ptr : Bytes, size : Int, n : Int, f : UInt64) -> UInt64 = "fwrite"

///|
#borrow(ptr)
extern "C" fn c_fread(ptr : Bytes, size : Int, n : Int, f : UInt64) -> UInt64 = "fread"

///|
extern "C" fn c_fflush(f : UInt64) -> Int = "fflush"

///|
extern "C" fn c_fclose(f : UInt64) -> Int = "fclose"

///|
extern "C" fn c_fileno(f : UInt64) -> Int = "fileno"

// 64 位定位。Windows 上 `long` 是 32 位，`fseek` 只能定位到 2 GiB；
// POSIX 上 `fseeko` 的 `off_t` 是 64 位。两边函数名不同，必须分开声明。

///|
#cfg(platform="windows")
extern "C" fn c_seek(f : UInt64, off : Int64, whence : Int) -> Int = "_fseeki64"

///|
#cfg(platform="windows")
extern "C" fn c_tell(f : UInt64) -> Int64 = "_ftelli64"

///|
#cfg(not(platform="windows"))
extern "C" fn c_seek(f : UInt64, off : Int64, whence : Int) -> Int = "fseeko"

///|
#cfg(not(platform="windows"))
extern "C" fn c_tell(f : UInt64) -> Int64 = "ftello"

// ---------------------------------------------------------------------------
// 持久化：C1 的唯一实现点
// ---------------------------------------------------------------------------

///|
#cfg(platform="windows")
extern "C" fn c_sync_fd(fd : Int) -> Int = "_commit"

///|
#cfg(not(platform="windows"))
extern "C" fn c_sync_fd(fd : Int) -> Int = "fsync"

// ---------------------------------------------------------------------------
// 目录与文件管理
// ---------------------------------------------------------------------------

///|
#cfg(platform="windows")
#borrow(p)
extern "C" fn c_mkdir_win(p : Bytes) -> Int = "_mkdir"

///|
#cfg(not(platform="windows"))
#borrow(p)
extern "C" fn c_mkdir_posix(p : Bytes, mode : Int) -> Int = "mkdir"

///|
#cfg(platform="windows")
fn mkdir_at(p : Bytes) -> Int {
  c_mkdir_win(p)
}

///|
#cfg(not(platform="windows"))
fn mkdir_at(p : Bytes) -> Int {
  c_mkdir_posix(p, 0x1FF)
}

///|
#cfg(not(platform="windows"))
#borrow(a, b)
extern "C" fn c_rename_posix(a : Bytes, b : Bytes) -> Int = "rename"

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
extern "C" fn c_move_win(a : Bytes, b : Bytes, flags : Int) -> Int = "MoveFileExA"

///|
/// 统一成「返回 0 = 成功」。
///
/// 两个平台的约定是**相反**的：POSIX `rename` 返回 0 表示成功，
/// Windows `MoveFileExA` 返回**非 0** 表示成功。直接透传返回值，
/// 调用方的 `!= 0` 判断在 Windows 上就完全颠倒了——
/// 表现为「改名成功时报错、失败时静默通过」，是最难查的那类 bug。
/// 所以归一化必须在 `rename_at` 内部完成，不能泄漏给调用方。
#cfg(platform="windows")
fn rename_at(from : Bytes, to : Bytes) -> Int {
  if c_move_win(from, to, 0x1 | 0x8) != 0 {
    0
  } else {
    -1
  }
}

///|
#cfg(not(platform="windows"))
fn rename_at(from : Bytes, to : Bytes) -> Int {
  c_rename_posix(from, to)
}

///|
#borrow(p)
extern "C" fn c_remove(p : Bytes) -> Int = "remove"

// 目录 fsync：rename 只保证「原子」，不保证「持久」。
// 要把 CURRENT 的切换变成崩溃后可见的事实，必须 fsync 所在目录。
// Windows 上目录不是文件句柄，`_commit` 对目录无效，所以只做 POSIX。

///|
#cfg(not(platform="windows"))
#borrow(p)
extern "C" fn c_open(p : Bytes, flags : Int, mode : Int) -> Int = "open"

///|
#cfg(not(platform="windows"))
extern "C" fn c_close(fd : Int) -> Int = "close"

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
/// 文件系统后端。
///
/// 每次操作都 fopen / fclose，不保持常开句柄。这是有意的取舍：
/// 常开句柄要处理「多个 WAL / SST 同时打开」「close 时怎么保证顺序」
/// 这些状态问题，而现在这一层的目的是先把**语义**跑通。
/// 代价是每次追加有几次系统调用的开销，压测时会明显——
/// 见 CHANGELOG 的「已知技术债」，优化点是引入一个带缓冲的句柄表。
pub struct NativeStorage {
  root : String
}

///|
/// `root` 是数据目录。传空串表示当前目录。
/// 所有文件路径都是 `root + "/" + name`，Windows 也接受 `/` 作为分隔符。
pub fn NativeStorage::new(root : String) -> NativeStorage {
  { root, }
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
  let mut acc = ""
  for part in self.root.split("/") {
    let seg = part.to_owned()
    if seg == "" || seg == "." {
      continue
    }
    acc = if acc == "" { seg } else { acc + "/" + seg }
    ignore(mkdir_at(cstr(acc)))
  }
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
  let f = self.open_or_fail(name, "ab")
  let err = write_all_to(f, data, name)
  ignore(c_fflush(f))
  ignore(c_fclose(f))
  if err != "" {
    raise LsmError::io(err)
  }
}

///|
pub impl Storage for NativeStorage with fn sync_file(self, name) -> Unit raise LsmError {
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

///|
pub impl Storage for NativeStorage with fn rename_file(self, from, to) -> Unit raise LsmError {
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
  // 不存在不算错误：恢复路径会重复清理同一批文件。
  ignore(c_remove(self.path(name)))
}

///|
pub impl Storage for NativeStorage with fn file_size(self, name) -> Int? raise LsmError {
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
pub impl Storage for NativeStorage with fn list_files(self, prefix) -> Array[
  String,
] raise LsmError {
  // 没有可移植的 readdir：POSIX 是 opendir/readdir，Windows 是
  // FindFirstFile。这里用 MoonBit 运行时自带的实现（runtime/sync_io.c
  // 里的 moonbit_read_dir_ffi），它已经把两边都封好了。
  //
  // 前提：目录必须存在。运行时实现在 opendir 失败时返回 NULL，
  // 而这个 NULL 到了 MoonBit 侧就是一个空指针的 Array——访问它
  // 会直接段错误，不是可捕获的错误。所以这里先 prepare 一遍。
  Storage::prepare(self)
  let names = c_read_dir(self.dir())
  let out : Array[String] = []
  for i in 0..<names.length() {
    let s = @utf8.decode_lossy(names[i])
    if has_prefix(s, prefix) {
      out.push(s)
    }
  }
  out.sort_by(fn(a, b) { compare_strings(a, b) })
  out
}

///|
/// 运行时导出的目录列举。返回一个 MoonBit 的引用数组，
/// 布局与 `Array[Bytes]` 一致，所以可以直接声明成这个类型。
#borrow(path)
extern "C" fn c_read_dir(path : Bytes) -> FixedArray[Bytes] = "moonbit_read_dir_ffi"
