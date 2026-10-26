// NativeStorage 的测试。只在 native 后端编译（见 moon.pkg 的 targets）。
//
// 单独成文件是因为 `NativeStorage` 本身只在 native 上存在：
// 非 native 后端里 fs_native.mbt 整个文件都不编译，
// 把这两组测试混在一起会让 wasm-gc / js 的 `moon test` 直接编译失败。

// ---------------------------------------------------------------------------
// NativeStorage：真文件系统
// ---------------------------------------------------------------------------

///|
/// 测试用数据目录。每个用例前清空，避免互相污染。
///
/// 用固定名字而不是随机名，是因为失败时能直接去目录里看现场；
/// 随机名虽然「更干净」，但排查时只会留下一堆看不懂的目录。
fn fresh_dir(tag : String) -> NativeStorage raise LsmError {
  let dir = ".moonlsm_test/" + tag
  let st = NativeStorage::new(dir)
  Storage::prepare(st)
  // 清掉上一轮残留。子目录也要清 —— 新布局把 SST / WAL 放进
  // `sst/` 和 `wal/`，只清根目录会让上一个用例的数据被下一个用例读到，
  // 表现为「恢复时读到了本不该存在的 SST」这种极其困惑的失败。
  for name in Storage::list_files(st, "") {
    Storage::remove_file(st, name)
  }
  for dir in ["sst", "log.bin"] {
    for name in Storage::list_files(st, dir) {
      Storage::remove_file(st, dir + "/" + name)
    }
  }
  st
}

///|
test "storage: NativeStorage 写读往返" {
  let st = fresh_dir("rw")
  assert_true(Storage::read_file(st, "a.txt") is None)
  Storage::write_file(st, "a.txt", bytes_of_str("hello"))
  match Storage::read_file(st, "a.txt") {
    Some(v) => assert_eq(str_of_bytes(v), "hello")
    None => fail("a.txt 应存在")
  }
  assert_true(Storage::file_size(st, "a.txt") is Some(5))
  assert_true(Storage::file_size(st, "nope.txt") is None)
}

///|
test "storage: NativeStorage 空文件与二进制内容" {
  let st = fresh_dir("bin")
  Storage::write_file(st, "empty", b"")
  match Storage::read_file(st, "empty") {
    Some(v) => assert_eq(v.length(), 0)
    None => fail("空文件应能读出")
  }
  // 含 0x00 的内容：文本模式下会被截断，二进制模式不会
  let raw : Array[Byte] = [0, 1, 2, 255, 0, 128]
  Storage::write_file(st, "bin", Bytes::from_array(raw[:]))
  match Storage::read_file(st, "bin") {
    Some(v) => {
      assert_eq(v.length(), 6)
      assert_eq(v[3].to_int(), 255)
      assert_eq(v[5].to_int(), 128)
    }
    None => fail("bin 应存在")
  }
}

///|
test "storage: NativeStorage append 与 file_size 一致" {
  let st = fresh_dir("append")
  Storage::write_file(st, "log.bin", bytes_of_str("AAA"))
  Storage::append_file(st, "log.bin", bytes_of_str("BBB"))
  Storage::append_file(st, "log.bin", bytes_of_str("CC"))
  assert_true(Storage::file_size(st, "log.bin") is Some(8))
  match Storage::read_file(st, "log.bin") {
    Some(v) => assert_eq(str_of_bytes(v), "AAABBBCC")
    None => fail("wal 应存在")
  }
}

///|
test "storage: NativeStorage append_frames 与逐次 append 结果完全一致" {
  // append_frames 存在的唯一理由是省掉重复的 fopen/fclose，
  // 所以它必须**在语义上和循环调用 append_file 完全等价**。
  // 这条测试就是那个等价性断言：同样的输入，两条路径产出同样的字节。
  let a = fresh_dir("frames_loop")
  let b = fresh_dir("frames_batch")
  let chunks : Array[Bytes] = [
    bytes_of_str("AAA"), bytes_of_str(""), bytes_of_str("BB"),
    bytes_of_str("CCCC"),
  ]
  Storage::write_file(a, "log.bin", bytes_of_str("HEAD"))
  Storage::write_file(b, "log.bin", bytes_of_str("HEAD"))
  for c in chunks {
    Storage::append_file(a, "log.bin", c)
  }
  Storage::append_frames(b, "log.bin", chunks)
  let ra = match Storage::read_file(a, "log.bin") {
    Some(v) => v
    None => fail("a/wal 应存在")
  }
  let rb = match Storage::read_file(b, "log.bin") {
    Some(v) => v
    None => fail("b/wal 应存在")
  }
  assert_eq(str_of_bytes(ra), str_of_bytes(rb))
  assert_eq(str_of_bytes(rb), "HEADAAABBCCCC")
  // 空批次不能创建文件，也不能改动已有内容（HEAD+AAA+BB+CCCC = 13）
  Storage::append_frames(b, "log.bin", [])
  assert_true(Storage::file_size(b, "log.bin") is Some(13))
}

///|
test "storage: NativeStorage append_frames 对不存在的文件会创建它" {
  // 与 "ab" 模式的语义保持一致：append 到不存在的文件等于新建。
  let st = fresh_dir("frames_new")
  Storage::append_frames(st, "log.bin", [bytes_of_str("X"), bytes_of_str("Y")])
  match Storage::read_file(st, "log.bin") {
    Some(v) => assert_eq(str_of_bytes(v), "XY")
    None => fail("wal 应被创建")
  }
}

///|
test "storage: NativeStorage sync 不改变内容，且能对不存在的文件报错" {
  let st = fresh_dir("sync")
  Storage::write_file(st, "log.bin", bytes_of_str("AAA"))
  Storage::sync_file(st, "log.bin")
  // sync 之后再读，内容必须一模一样
  match Storage::read_file(st, "log.bin") {
    Some(v) => assert_eq(str_of_bytes(v), "AAA")
    None => fail("wal 应存在")
  }
  // 对不存在的文件 fsync 是逻辑错误，必须报错——
  // 悄悄建一个空文件出来会污染目录，恢复时会当成「有个空的 WAL」
  assert_true(
    raises_lsm(fn() raise LsmError { Storage::sync_file(st, "ghost") }),
  )
}

///|
test "storage: NativeStorage rename 覆盖已有文件" {
  let st = fresh_dir("rename")
  Storage::write_file(st, "CURRENT", bytes_of_str("MANIFEST-1"))
  Storage::write_file(st, "CURRENT.tmp", bytes_of_str("MANIFEST-2"))
  Storage::rename_file(st, "CURRENT.tmp", "CURRENT")
  assert_true(Storage::read_file(st, "CURRENT.tmp") is None)
  match Storage::read_file(st, "CURRENT") {
    Some(v) => assert_eq(str_of_bytes(v), "MANIFEST-2")
    None => fail("CURRENT 应存在")
  }
}

///|
test "storage: NativeStorage rename 源不存在要报错" {
  let st = fresh_dir("rename_fail")
  assert_true(
    raises_lsm(fn() raise LsmError {
      Storage::rename_file(st, "ghost", "CURRENT")
    }),
  )
}

///|
test "storage: NativeStorage remove 幂等" {
  let st = fresh_dir("remove")
  Storage::write_file(st, "x", b"1")
  Storage::remove_file(st, "x")
  Storage::remove_file(st, "x")
  assert_true(Storage::read_file(st, "x") is None)
}

///|
test "storage: NativeStorage list_files 列子目录且不返回 . / .." {
  let st = fresh_dir("list")
  Storage::write_file(st, "sst/000002.sst", b"")
  Storage::write_file(st, "sst/000001.sst", b"")
  Storage::write_file(st, "wal/000003.wal", b"")
  Storage::write_file(st, "CURRENT", b"x")
  let ssts = Storage::list_files(st, "sst")
  assert_eq(ssts.length(), 2)
  assert_eq(ssts[0], "000001.sst")
  assert_eq(ssts[1], "000002.sst")
  assert_eq(Storage::list_files(st, "wal").length(), 1)
  // 真文件系统的 readdir 会返回 `.` / `..`，必须被过滤掉 ——
  // 否则解析编号会得到 0，`next_file_number` 就算错了
  for name in ssts {
    assert_true(name != "." && name != "..")
  }
  // 根目录只有 CURRENT（sst/ 和 wal/ 是目录，不算文件）
  let root = Storage::list_files(st, "")
  assert_eq(root.length(), 1)
  assert_eq(root[0], "CURRENT")
}

///|
test "storage: NativeStorage 大文件往返（跨 64 KiB 缓冲）" {
  let st = fresh_dir("big")
  let b = Buffer::Buffer()
  for i in 0..<10000 {
    b.write_bytes(bytes_of_str("key:\{i};")[:])
  }
  let data = b.to_bytes()
  Storage::write_file(st, "big", data)
  match Storage::read_file(st, "big") {
    Some(v) => {
      assert_eq(v.length(), data.length())
      // 逐字节比对，不只比长度：长度对而内容错是最难查的
      let mut diff = 0
      for i in 0..<data.length() {
        if v[i] != data[i] {
          diff = diff + 1
        }
      }
      assert_eq(diff, 0)
    }
    None => fail("big 应存在")
  }
}

// ---------------------------------------------------------------------------
// 常开句柄（ADR-0009）
//
// 这一组测的不是「快了多少」，而是「缓存了句柄之后，那些原本靠
// fopen/fclose 隐式保证的事情还成不成立」：
//   - 追加位置还对吗（截断 / 删除 / 改名之后）
//   - 另开句柄能读到刚写的字节吗（fflush 的可见性）
//   - 该报错的地方还报错吗（对不存在的文件 fsync）
// 每一条都对应一个「如果实现写错就会静默出错」的场景。
// ---------------------------------------------------------------------------

///|
test "storage: 常开句柄跨多次追加仍按顺序落盘" {
  let st = fresh_dir("cache_append")
  Storage::write_file(st, "log.bin", b"")
  for i in 0..<50 {
    Storage::append_file(st, "log.bin", bytes_of_str("f\{i};"))
  }
  // 另开句柄读：能读到全部 50 段，说明每次追加都 fflush 过
  match Storage::read_file(st, "log.bin") {
    Some(v) => {
      let s = str_of_bytes(v)
      assert_true(s.has_prefix("f0;f1;f2;"))
      assert_true(s.has_suffix("f49;"))
      assert_eq(v.length(), Storage::file_size(st, "log.bin").unwrap())
    }
    None => fail("log.bin 应存在")
  }
}

///|
test "storage: 覆盖写之后再追加，从新内容末尾开始（不留旧位置）" {
  let st = fresh_dir("cache_truncate")
  Storage::append_file(st, "w.bin", bytes_of_str("old-old-old"))
  // 覆盖写会关掉常开句柄；如果没关，追加位置会停在旧 EOF 之后，
  // 结果要么多出全零空洞，要么把旧内容尾巴接在新内容后面
  Storage::write_file(st, "w.bin", bytes_of_str("NEW"))
  Storage::append_file(st, "w.bin", bytes_of_str("tail"))
  match Storage::read_file(st, "w.bin") {
    Some(v) => assert_eq(str_of_bytes(v), "NEWtail")
    None => fail("w.bin 应存在")
  }
}

///|
test "storage: 删除后重建同名文件，读不到旧内容" {
  let st = fresh_dir("cache_remove")
  Storage::append_file(st, "w.bin", bytes_of_str("stale-stale-stale"))
  Storage::remove_file(st, "w.bin")
  Storage::append_file(st, "w.bin", bytes_of_str("fresh"))
  match Storage::read_file(st, "w.bin") {
    Some(v) => assert_eq(str_of_bytes(v), "fresh")
    None => fail("w.bin 应存在")
  }
}

///|
test "storage: 改名之后再追加写的是新名字" {
  // 这条在 Windows 上是硬要求：改名一个还开着的文件会直接失败。
  let st = fresh_dir("cache_rename")
  Storage::append_file(st, "a.bin", bytes_of_str("AAA"))
  Storage::rename_file(st, "a.bin", "b.bin")
  Storage::append_file(st, "b.bin", bytes_of_str("BBB"))
  assert_true(Storage::read_file(st, "a.bin") is None)
  match Storage::read_file(st, "b.bin") {
    Some(v) => assert_eq(str_of_bytes(v), "AAABBB")
    None => fail("b.bin 应存在")
  }
}

///|
test "storage: 显式 close 之后再追加仍然正常（自动重开）" {
  let st = fresh_dir("cache_close")
  Storage::append_file(st, "log.bin", bytes_of_str("one;"))
  st.close()
  Storage::append_file(st, "log.bin", bytes_of_str("two;"))
  match Storage::read_file(st, "log.bin") {
    Some(v) => assert_eq(str_of_bytes(v), "one;two;")
    None => fail("log.bin 应存在")
  }
}

///|
test "storage: 常开句柄不影响「对不存在的文件 fsync 要报错」" {
  // 缓存绝不能把「文件不存在」变成「静默成功」：
  // 那是恢复路径上区分「没写过」和「写坏了」的唯一信号。
  let st = fresh_dir("cache_sync_missing")
  let mut raised = false
  try {
    Storage::sync_file(st, "nope.bin")
  } catch {
    _ => raised = true
  }
  assert_true(raised)
  // 已经为别的文件缓存了句柄时，这条仍然要成立
  Storage::append_file(st, "log.bin", bytes_of_str("x"))
  let mut raised2 = false
  try {
    Storage::sync_file(st, "nope2.bin")
  } catch {
    _ => raised2 = true
  }
  assert_true(raised2)
}

///|
test "storage: 两个实例各自缓存句柄，互不干扰" {
  // 引擎正常只有一份 NativeStorage，但测试 / 工具里同时开两个实例很常见。
  // 缓存是**实例级**的，一个实例的追加不该被另一个实例的句柄挡住。
  let a = fresh_dir("cache_two")
  let b = NativeStorage::new(".moonlsm_test/cache_two")
  Storage::append_file(a, "log.bin", bytes_of_str("from-a;"))
  Storage::append_file(b, "log.bin", bytes_of_str("from-b;"))
  match Storage::read_file(a, "log.bin") {
    Some(v) => assert_eq(str_of_bytes(v), "from-a;from-b;")
    None => fail("log.bin 应存在")
  }
  a.close()
  b.close()
}
