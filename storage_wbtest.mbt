// 存储后端的测试。
//
// 本文件只测 MemStorage —— 语义与断电模型，三个后端都能跑。
// NativeStorage 的测试在 fs_native_wbtest.mbt，只在 native 后端编译。
//
// 断电测试是这一层的核心价值：它把「已确认的写入必不丢」从一句文档
// 变成一条可执行断言，而且不依赖 kill -9。

///|
fn bytes_of_str(s : String) -> Bytes {
  @utf8.encode(s)
}

///|
fn str_of_bytes(b : Bytes) -> String {
  @utf8.decode_lossy(b)
}

///|
/// 断言一段代码抛出 `LsmError`。
///
/// 显式列出三个构造器而不是写 `_`：`catch { _ => }` 会吞掉任何错误
/// （包括编程错误引发的 abort），让测试在应该崩的地方安静通过。
fn raises_lsm(f : () -> Unit raise LsmError) -> Bool {
  let mut raised = false
  let _ = f() catch {
    LsmError::Io(_) => raised = true
    LsmError::Corruption(_) => raised = true
    LsmError::Closed => raised = true
  }
  raised
}

// ---------------------------------------------------------------------------
// MemStorage：基本语义
// ---------------------------------------------------------------------------

///|
test "storage: MemStorage 写读往返，不存在的文件返回 None" {
  let st = MemStorage::new()
  assert_true(Storage::read_file(st, "nope") is None)
  Storage::write_file(st, "a", bytes_of_str("hello"))
  let got = Storage::read_file(st, "a")
  assert_true(got is Some(_))
  match got {
    Some(v) => assert_eq(str_of_bytes(v), "hello")
    None => fail("unreachable")
  }
  assert_true(Storage::file_size(st, "a") is Some(5))
  assert_true(Storage::file_size(st, "nope") is None)
}

///|
test "storage: append 是追加而不是覆盖" {
  let st = MemStorage::new()
  Storage::write_file(st, "wal", bytes_of_str("AAA"))
  Storage::append_file(st, "wal", bytes_of_str("BBB"))
  Storage::append_file(st, "wal", bytes_of_str(""))
  match Storage::read_file(st, "wal") {
    Some(v) => assert_eq(str_of_bytes(v), "AAABBB")
    None => fail("wal 应存在")
  }
}

///|
test "storage: rename 后旧名消失、新名可读" {
  let st = MemStorage::new()
  Storage::write_file(st, "CURRENT.tmp", bytes_of_str("MANIFEST-7"))
  Storage::rename_file(st, "CURRENT.tmp", "CURRENT")
  assert_true(Storage::read_file(st, "CURRENT.tmp") is None)
  match Storage::read_file(st, "CURRENT") {
    Some(v) => assert_eq(str_of_bytes(v), "MANIFEST-7")
    None => fail("CURRENT 应存在")
  }
}

///|
test "storage: rename 源不存在要报错，而不是静默成功" {
  let st = MemStorage::new()
  // 静默成功会让「CURRENT 没切过去」变成「CURRENT 不见了」，
  // 后者在恢复时表现为「数据目录是空的」，比报错难查得多。
  assert_true(
    raises_lsm(fn() raise LsmError {
      Storage::rename_file(st, "ghost", "CURRENT")
    }),
  )
}

///|
test "storage: remove 不存在的文件不报错" {
  let st = MemStorage::new()
  // 恢复路径会重复清理同一批文件，重复删除必须幂等
  Storage::remove_file(st, "ghost")
  Storage::remove_file(st, "ghost")
  assert_true(true)
}

///|
test "storage: list_files 按前缀过滤并按字节序排序" {
  let st = MemStorage::new()
  Storage::write_file(st, "SST-3", b"")
  Storage::write_file(st, "SST-1", b"")
  Storage::write_file(st, "SST-2", b"")
  Storage::write_file(st, "WAL-1", b"")
  let ssts = Storage::list_files(st, "SST-")
  assert_eq(ssts.length(), 3)
  assert_eq(ssts[0], "SST-1")
  assert_eq(ssts[1], "SST-2")
  assert_eq(ssts[2], "SST-3")
  assert_eq(Storage::list_files(st, "WAL-").length(), 1)
  assert_eq(Storage::list_files(st, "NOPE").length(), 0)
}

// ---------------------------------------------------------------------------
// MemStorage：断电模型
// ---------------------------------------------------------------------------

///|
test "storage: 未 sync 的写入在断电后消失" {
  let st = MemStorage::new()
  Storage::append_file(st, "WAL-1", bytes_of_str("frame1"))
  // 没调 sync_file —— 这一帧只在 OS 缓冲里
  st.power_loss()
  assert_true(Storage::read_file(st, "WAL-1") is None)
}

///|
test "storage: sync 之后的写入在断电后仍在（C1）" {
  let st = MemStorage::new()
  Storage::append_file(st, "WAL-1", bytes_of_str("frame1"))
  Storage::sync_file(st, "WAL-1")
  st.power_loss()
  match Storage::read_file(st, "WAL-1") {
    Some(v) => assert_eq(str_of_bytes(v), "frame1")
    None => fail("已 fsync 的帧必须存活")
  }
}

///|
test "storage: sync 之后的追加若未再 sync，断电回退到上次 sync 的长度" {
  let st = MemStorage::new()
  Storage::append_file(st, "WAL-1", bytes_of_str("A"))
  Storage::sync_file(st, "WAL-1")
  Storage::append_file(st, "WAL-1", bytes_of_str("B"))
  Storage::sync_file(st, "WAL-1")
  Storage::append_file(st, "WAL-1", bytes_of_str("C"))
  // C 没 sync
  st.power_loss()
  match Storage::read_file(st, "WAL-1") {
    // 前缀一致性：恢复出来的必须是某个前缀，不能出现「AB 中间夹着 C」
    Some(v) => assert_eq(str_of_bytes(v), "AB")
    None => fail("WAL-1 应存在")
  }
}

///|
test "storage: append_frames 与逐次 append 结果完全一致" {
  // 内存后端的 append_frames 是一次性拼接，native 后端是一次 fopen，
  // 两种实现完全不同。这条测试保证它们**语义等价**——
  // 否则内存后端上跑绿的用例，换成真文件系统可能就不成立了。
  let a = MemStorage::new()
  let b = MemStorage::new()
  let chunks : Array[Bytes] = [
    bytes_of_str("AAA"), bytes_of_str(""), bytes_of_str("BB"),
    bytes_of_str("CCCC"),
  ]
  Storage::write_file(a, "WAL-1", bytes_of_str("HEAD"))
  Storage::write_file(b, "WAL-1", bytes_of_str("HEAD"))
  for c in chunks {
    Storage::append_file(a, "WAL-1", c)
  }
  Storage::append_frames(b, "WAL-1", chunks)
  let ra = match Storage::read_file(a, "WAL-1") {
    Some(v) => v
    None => fail("a 应存在")
  }
  let rb = match Storage::read_file(b, "WAL-1") {
    Some(v) => v
    None => fail("b 应存在")
  }
  assert_eq(str_of_bytes(ra), str_of_bytes(rb))
  assert_eq(str_of_bytes(rb), "HEADAAABBCCCC")
  // 空批次是空操作，连文件都不该创建
  Storage::append_frames(b, "ghost", [])
  assert_true(Storage::read_file(b, "ghost") is None)
}

///|
test "storage: append_frames 也遵守写入故障注入" {
  // 批量路径不能成为「绕过故障注入」的后门
  let st = MemStorage::new()
  st.set_fail_write(true)
  assert_true(
    raises_lsm(fn() raise LsmError {
      Storage::append_frames(st, "WAL-1", [bytes_of_str("X")])
    }),
  )
  st.set_fail_write(false)
  assert_true(Storage::read_file(st, "WAL-1") is None)
}

///|
test "storage: 批量写只 sync 一次，断电后整批都在" {
  let st = MemStorage::new()
  for i in 0..<10 {
    Storage::append_file(st, "WAL-1", bytes_of_str("r\{i};"))
  }
  assert_eq(st.syncs(), 0)
  Storage::sync_file(st, "WAL-1")
  assert_eq(st.syncs(), 1)
  st.power_loss()
  match Storage::read_file(st, "WAL-1") {
    Some(v) => assert_eq(str_of_bytes(v), "r0;r1;r2;r3;r4;r5;r6;r7;r8;r9;")
    None => fail("整批应存活")
  }
}

///|
test "storage: 断电不跨越 rename —— 新旧名字只会有一个存在" {
  let st = MemStorage::new()
  Storage::write_file(st, "CURRENT", bytes_of_str("MANIFEST-1"))
  Storage::write_file(st, "CURRENT.tmp", bytes_of_str("MANIFEST-2"))
  Storage::rename_file(st, "CURRENT.tmp", "CURRENT")
  st.power_loss()
  // rename 之后 fsync 目录（native 后端确实这么做），所以断电后
  // 看到的一定是新名字下的新内容，不会是「两个都没有」
  match Storage::read_file(st, "CURRENT") {
    Some(v) => assert_eq(str_of_bytes(v), "MANIFEST-2")
    None => fail("CURRENT 必须存在")
  }
  assert_true(Storage::read_file(st, "CURRENT.tmp") is None)
}

// ---------------------------------------------------------------------------
// MemStorage：故障注入
// ---------------------------------------------------------------------------

///|
test "storage: fsync 失败必须抛错，不能悄悄当成功" {
  let st = MemStorage::new()
  Storage::append_file(st, "WAL-1", bytes_of_str("frame1"))
  st.set_fail_sync(true)
  // 这条断言是 C1 的另一半：fsync 没成功就不能对外说「已持久」。
  // 如果这里静默通过，上层会照样 ack，断电就丢数据了。
  assert_true(
    raises_lsm(fn() raise LsmError { Storage::sync_file(st, "WAL-1") }),
  )
  assert_eq(st.syncs(), 0)
  st.set_fail_sync(false)
  st.power_loss()
  assert_true(Storage::read_file(st, "WAL-1") is None)
}

///|
test "storage: 写入失败必须抛错" {
  let st = MemStorage::new()
  st.set_fail_write(true)
  assert_true(
    raises_lsm(fn() raise LsmError { Storage::append_file(st, "WAL-1", b"x") }),
  )
  assert_true(
    raises_lsm(fn() raise LsmError { Storage::write_file(st, "SST-1", b"x") }),
  )
  assert_true(Storage::read_file(st, "WAL-1") is None)
}

///|
test "storage: plant 构造出的状态断电后不变" {
  let st = MemStorage::new()
  // 模拟「上次运行留下的磁盘状态」
  st.plant("WAL-1", bytes_of_str("old"))
  Storage::append_file(st, "WAL-1", bytes_of_str("-new"))
  st.power_loss()
  match Storage::read_file(st, "WAL-1") {
    Some(v) => assert_eq(str_of_bytes(v), "old")
    None => fail("plant 的内容必须存活")
  }
}
