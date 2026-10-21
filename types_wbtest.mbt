///|
/// 基础类型的不变量测试。
///
/// 这些类型目前没有逻辑，但它们的**形状**是契约的一部分：
/// WAL 帧、SST 记录、scan 返回值都建立在这几个类型上。
/// 这里把形状固定住，避免以后随手加字段时破坏 `docs/design/format.md` 的对应关系。
test "Op: 只有 Put 与 Delete 两种写入，Delete 是墓碑而非移除" {
  let put : Op = Put(b"k", b"v")
  let del : Op = Delete(b"k")
  // Delete 只携带 key —— 墓碑不需要 value，
  // 这一点对应 format.md §2.3「op = Delete 时 value 整段省略」
  let del_key = match del {
    Put(_, _) => b""
    Delete(k) => k
  }
  assert_eq(compare_bytes(del_key, b"k"), 0)
  let put_pair = match put {
    Put(k, v) => (k, v)
    Delete(_) => (b"", b"")
  }
  assert_eq(compare_bytes(put_pair.0, b"k"), 0)
  assert_eq(compare_bytes(put_pair.1, b"v"), 0)
}

///|
test "WalRecord: 每条记录都带全局单调 seq" {
  let r : WalRecord = { seq: 42UL, op: Put(b"a", b"1"), }
  assert_eq(r.seq, 42UL)
  // seq 必须是 64 位。UInt32 在 100 万写入/秒的压测下 70 分钟就回绕，
  // 而回绕会让「同 key 取最大 seq」的新旧判断彻底失效，
  // 表现为旧值覆盖新值 —— 是最难查的一类 bug。
  let beyond_u32 : UInt64 = 4294967296UL
  assert_true(beyond_u32 > 4294967295UL)
  let r2 : WalRecord = { seq: beyond_u32, op: Delete(b"x"), }
  assert_eq(r2.seq, beyond_u32)
}

///|
test "KvPair: 是 scan 结果的最小单元，key 与 value 都可为空" {
  let p : KvPair = { key: b"", value: b"", }
  assert_eq(p.key.length(), 0)
  assert_eq(p.value.length(), 0)
  // 空 value 与「不存在」必须能区分：前者是 KvPair 存在但 value 长度 0，
  // 后者是 get 返回 None。见 format.md §0「空值」一行。
  let q : KvPair = { key: b"k", value: b"", }
  assert_eq(q.value.length(), 0)
  assert_eq(compare_bytes(q.key, b"k"), 0)
}

///|
test "LsmError: 三种错误可区分，且都携带足够上下文" {
  let io : LsmError = Io("wal/000008.wal: 偏移 4096 处写失败")
  let corrupt : LsmError = Corruption("MANIFEST 的 magic 不匹配")
  let closed : LsmError = Closed
  let kind = match io {
    Io(_) => 1
    Corruption(_) => 2
    Closed => 3
  }
  let kind2 = match corrupt {
    Io(_) => 1
    Corruption(_) => 2
    Closed => 3
  }
  let kind3 = match closed {
    Io(_) => 1
    Corruption(_) => 2
    Closed => 3
  }
  assert_eq(kind, 1)
  assert_eq(kind2, 2)
  assert_eq(kind3, 3)
}
