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
  // 清掉上一轮残留
  for name in Storage::list_files(st, "") {
    Storage::remove_file(st, name)
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
  Storage::write_file(st, "wal", bytes_of_str("AAA"))
  Storage::append_file(st, "wal", bytes_of_str("BBB"))
  Storage::append_file(st, "wal", bytes_of_str("CC"))
  assert_true(Storage::file_size(st, "wal") is Some(8))
  match Storage::read_file(st, "wal") {
    Some(v) => assert_eq(str_of_bytes(v), "AAABBBCC")
    None => fail("wal 应存在")
  }
}

///|
test "storage: NativeStorage sync 不改变内容，且能对不存在的文件报错" {
  let st = fresh_dir("sync")
  Storage::write_file(st, "wal", bytes_of_str("AAA"))
  Storage::sync_file(st, "wal")
  // sync 之后再读，内容必须一模一样
  match Storage::read_file(st, "wal") {
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
test "storage: NativeStorage list_files 能看到刚写的文件" {
  let st = fresh_dir("list")
  Storage::write_file(st, "SST-1", b"")
  Storage::write_file(st, "SST-2", b"")
  Storage::write_file(st, "WAL-1", b"")
  let ssts = Storage::list_files(st, "SST-")
  assert_eq(ssts.length(), 2)
  assert_eq(ssts[0], "SST-1")
  assert_eq(ssts[1], "SST-2")
  assert_eq(Storage::list_files(st, "WAL-").length(), 1)
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
