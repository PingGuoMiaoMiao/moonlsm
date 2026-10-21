///|
test "compare_bytes: 前缀与长度" {
  assert_eq(compare_bytes(b"a", b"a"), 0)
  assert_eq(compare_bytes(b"a", b"ab"), -1)
  assert_eq(compare_bytes(b"ab", b"a"), 1)
  assert_eq(compare_bytes(b"abc", b"abd"), -1)
  assert_eq(compare_bytes(b"", b"a"), -1)
}

///|
test "memtable: 乱序写入后按 key 升序" {
  let mt = MemTable::new(1024)
  mt.put(b"c", b"3", 1UL)
  mt.put(b"a", b"1", 2UL)
  mt.put(b"b", b"2", 3UL)
  let keys = mt.to_entries().map(fn(e) { e.key })
  assert_eq(keys.length(), 3)
  assert_eq(compare_bytes(keys[0], b"a"), 0)
  assert_eq(compare_bytes(keys[1], b"b"), 0)
  assert_eq(compare_bytes(keys[2], b"c"), 0)
}

///|
test "memtable: 同一个 key 后写覆盖先写" {
  let mt = MemTable::new(1024)
  mt.put(b"k", b"old", 1UL)
  mt.put(b"k", b"new", 2UL)
  assert_eq(mt.to_entries().length(), 1)
  assert_eq(mt.get(b"k").unwrap().value, b"new")
  assert_eq(mt.get(b"k").unwrap().seq, 2UL)
}

///|
test "memtable: 查不到返回 None" {
  let mt = MemTable::new(1024)
  mt.put(b"b", b"2", 1UL)
  assert_true(mt.get(b"a") is None)
  assert_true(mt.get(b"c") is None)
  assert_true(mt.get(b"bb") is None)
}

///|
/// 这条测试守的是一个真实踩过的坑：
/// `String::compare` 按长度优先，"k9" 会排在 "k10" 后面，
/// 拿它做 scan 的端点判断会漏掉长 key。
/// `compare_strings` 必须给出真正的字节序。
test "compare_strings: 按字节序而非长度优先" {
  // 长度优先的话这里会返回 > 0（"k9" 更短，被排在前面）
  assert_eq(compare_strings("k9", "k10"), 1)
  assert_eq(compare_strings("k10", "k9"), -1)
  // 前缀关系：短的更小
  assert_eq(compare_strings("k", "k00001"), -1)
  assert_eq(compare_strings("k00001", "k"), 1)
  // 相等
  assert_eq(compare_strings("abc", "abc"), 0)
  // 与 compare_bytes 对同一份 UTF-8 编码结果一致
  assert_eq(
    compare_strings("键", "值"),
    compare_bytes(b"\xe9\x94\xae", b"\xe5\x80\xbc"),
  )
}

///|
test "memtable: 超过阈值后 is_full 为真" {
  let mt = MemTable::new(20)
  assert_false(mt.is_full())
  mt.put(b"key", b"0123456789", 1UL)
  assert_true(mt.is_full())
}

///|
/// 这条测试守的是 LSM 里最经典的一个静默数据错误：
/// 用「value 长度为 0」表示删除，就再也分不清
/// 「写入了空字符串」和「删除了这个 key」。
test "memtable: 墓碑与空 value 必须可区分" {
  let mt = MemTable::new(1024)
  // 写入一个空 value —— 这是合法数据，读出来应该是 Some(空)
  mt.put(b"empty", b"", 1UL)
  let e = mt.get(b"empty").unwrap()
  assert_eq(e.value.length(), 0)
  assert_false(e.deleted)

  // 删除一个 key —— 墓碑，读出来应该是 Some 但 deleted = true
  mt.delete(b"gone", 2UL)
  let d = mt.get(b"gone").unwrap()
  assert_eq(d.value.length(), 0)
  assert_true(d.deleted)

  // 两者长度都是 0，但语义完全不同。deleted 标记是唯一的区分依据。
  assert_false(e.deleted == d.deleted)
}

///|
test "memtable: 删除后再写入，墓碑被覆盖" {
  let mt = MemTable::new(1024)
  mt.put(b"k", b"v1", 1UL)
  mt.delete(b"k", 2UL)
  assert_true(mt.get(b"k").unwrap().deleted)
  mt.put(b"k", b"v3", 3UL)
  let e = mt.get(b"k").unwrap()
  assert_false(e.deleted)
  assert_eq(compare_bytes(e.value, b"v3"), 0)
  assert_eq(e.seq, 3UL)
  // 同一个 key 始终只占一个槽位
  assert_eq(mt.to_entries().length(), 1)
}

///|
test "memtable: 按 WAL 记录重放" {
  let mt = MemTable::new(1024)
  mt.apply(WalRecord::new(1UL, Put(b"a", b"1")))
  mt.apply(WalRecord::new(2UL, Put(b"b", b"2")))
  mt.apply(WalRecord::new(3UL, Delete(b"a")))
  assert_eq(mt.to_entries().length(), 2)
  assert_true(mt.get(b"a").unwrap().deleted)
  assert_false(mt.get(b"b").unwrap().deleted)
}

///|
test "entry: 转成对外 KvPair 时只保留 key 与 value" {
  let e = Op::Put(b"k", b"v").to_entry(7UL)
  let p = e.to_pair()
  assert_eq(compare_bytes(p.key, b"k"), 0)
  assert_eq(compare_bytes(p.value, b"v"), 0)
}
