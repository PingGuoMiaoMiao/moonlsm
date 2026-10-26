///|
/// data block 编解码测试。
///
/// 这里的测试分四类，对应四种不同的失败模式：
/// 1. **往返**（编码→解码→逐条比对）：抓编解码不对称。
/// 2. **逐字节/结构**（restart 数组、长度字段）：抓「自洽但不合规」。
/// 3. **语义**（墓碑 vs 空值、查找边界）：抓静默数据错误。
/// 4. **健壮性**（乱序输入、截断输入）：抓「坏数据导致 panic」。
///
/// 只做第 1 类是不够的 —— 编码器和解码器可以一起错，
/// 往返测试照样全绿（varint 的续位 bug 就是这么被抓出来的）。

///|
/// 确定性 PRNG（xorshift64）。测试必须可复现：随机失败没法调试，
/// 所以种子固定、算法固定，任何机器上跑出同一串 key。
priv struct TestRng {
  mut state : UInt64
}

///|
fn TestRng::new(seed : UInt64) -> TestRng {
  { state: if seed == 0UL { 0x2545F4914F6CDD1DUL } else { seed }, }
}

///|
fn TestRng::next(self : TestRng) -> UInt64 {
  let mut x = self.state
  x = x ^ (x << 13)
  x = x ^ (x >> 7)
  x = x ^ (x << 17)
  self.state = x
  x
}

///|
fn TestRng::below(self : TestRng, n : Int) -> Int {
  (self.next() % n.to_uint64()).to_int()
}

///|
/// 十进制左补零到 6 位。补零是关键：这样字符串的**字节序**与数值序一致，
/// 否则 `"user:10" < "user:9"`，测试数据本身就不是升序的。
fn pad6(n : Int) -> String {
  let s = n.to_string()
  let mut out = ""
  for _ in 0..<(6 - s.length()) {
    out = out + "0"
  }
  out + s
}

///|
fn mk(k : String, v : String, seq : UInt64) -> Entry {
  { key: @utf8.encode(k), value: @utf8.encode(v), seq, deleted: false, }
}

///|
/// 断言解码成功，失败时直接让测试红。用哨兵值满足类型检查 ——
/// `assert_true(false)` 一定会 raise，哨兵永远不会被用到。
fn must_decode(raw : Bytes) -> Block raise {
  match decode_block(raw) {
    Some(b) => b
    None => {
      assert_true(false)
      { data: b"", restarts: [0], limit: 0, }
    }
  }
}

///|
/// 用字节序比较而不是 `assert_eq`：`Bytes` 的 `Show` 输出在长 key 上很难读，
/// 而这里真正要断言的是「字节内容相同」，用 `compare_bytes == 0` 语义更准确。
fn assert_entry_eq(got : Entry, want : Entry) -> Unit raise {
  assert_eq(compare_bytes(got.key, want.key), 0)
  assert_eq(compare_bytes(got.value, want.value), 0)
  assert_eq(got.seq, want.seq)
  assert_eq(got.deleted, want.deleted)
}

///|
/// 插入排序（按字节序）。1000 条以内够用，且不依赖任何库函数，
/// 避免「排序实现本身有 bug 导致测试数据乱序」这种自我欺骗。
fn sort_bytes(keys : Array[Bytes]) -> Unit {
  let n = keys.length()
  for i in 1..<n {
    let cur = keys[i]
    let mut j = i
    while j > 0 && compare_bytes(keys[j - 1], cur) > 0 {
      keys[j] = keys[j - 1]
      j = j - 1
    }
    keys[j] = cur
  }
}

///|
/// **格式黄金向量**：把三条 entry 的完整字节序列钉死。
///
/// 这个测试的意义不是「验证代码正确」，而是「验证格式没被改动」。
/// 任何人（包括未来的我）在没意识到后果的情况下改了字段顺序、
/// 加了字段、换了编码，这个测试会立刻红，并打印出逐字节差异。
/// 格式是契约：改它必须 bump version、改 format.md、记 CHANGELOG，
/// 不能顺手改掉。
test "block: 编码字节逐字节符合格式规范（黄金向量）" {
  let b = BlockBuilder::new()
  b.add(mk("aaa", "1", 1UL))
  b.add(mk("aab", "22", 2UL))
  b.add(mk("aac", "333", 3UL))
  let want = bytes_of([
    // entry 0: type=0(值) seq=1 shared=0 non_shared=3 value_len=1 "aaa" "1"
    0x00, 0x01, 0x00, 0x03, 0x01, 0x61, 0x61, 0x61, 0x31,
    // entry 1: type=0 seq=2 shared=2("aa") non_shared=1("b") value_len=2 "b" "22"
     0x00, 0x02, 0x02, 0x01, 0x02, 0x62, 0x32, 0x32,
    // entry 2: type=0 seq=3 shared=2("aa") non_shared=1("c") value_len=3 "c" "333"
     0x00, 0x03, 0x02, 0x01, 0x03, 0x63, 0x33, 0x33, 0x33,
    // restart_offset[0] = 0（u32 LE）
     0x00, 0x00, 0x00, 0x00,
    // num_restarts = 1（u32 LE）
     0x01, 0x00, 0x00, 0x00,
  ])
  let got = b.finish()
  // 前 34 字节是 v1 就有的内容，必须逐字节一致
  assert_bytes_eq(got[:want.length()].to_owned(), want)
  // 后面 4 字节是 v2 新增的 CRC32C，覆盖前面全部 34 字节
  assert_eq(got.length(), want.length() + BLOCK_CRC_SIZE)
  let crc = match read_fixed32u(got, want.length()) {
    Some(v) => v
    None => 0UL
  }
  assert_eq(crc, crc32c(want))
}

///|
test "block: 空 block 可解码且查不到任何 key" {
  let raw = BlockBuilder::new().finish()
  // restarts[0] = 0 与 num_restarts = 1 共 8 字节，v2 再加 4 字节 CRC
  assert_eq(raw.length(), 8 + BLOCK_CRC_SIZE)
  let blk = must_decode(raw)
  assert_eq(blk.num_restarts(), 1)
  assert_eq(blk.entries().length(), 0)
  assert_true(blk.get(@utf8.encode("a")) is None)
}

///|
test "block: 1000 条递增 key 往返逐条一致" {
  let b = BlockBuilder::new()
  let expect : Array[Entry] = []
  for i in 0..<1000 {
    let e = mk("user:" + pad6(i), "v" + i.to_string(), i.to_uint64() + 1UL)
    b.add(e)
    expect.push(e)
  }
  let blk = must_decode(b.finish())
  let got = blk.entries()
  assert_eq(got.length(), expect.length())
  for i in 0..<expect.length() {
    assert_entry_eq(got[i], expect[i])
  }
}

///|
test "block: restart 点每 16 条一个" {
  let b = BlockBuilder::new()
  for i in 0..<1000 {
    b.add(mk("user:" + pad6(i), "v", i.to_uint64()))
  }
  let blk = must_decode(b.finish())
  // 0, 16, 32, ..., 992 → 63 个
  assert_eq(blk.num_restarts(), 63)
}

///|
test "block: 不足 16 条时只有一个 restart 点" {
  let b = BlockBuilder::new()
  for i in 0..<16 {
    b.add(mk("k" + pad6(i), "v", i.to_uint64()))
  }
  assert_eq(must_decode(b.finish()).num_restarts(), 1)
  // 第 17 条触发第二个 restart
  b.add(mk("k" + pad6(16), "v", 16UL))
  assert_eq(must_decode(b.finish()).num_restarts(), 2)
}

///|
test "block: 前缀压缩显著减少体积（同长度 key 对比）" {
  // A 组：1000 条共享 "user:" 前缀的 11 字节 key
  let a = BlockBuilder::new()
  for i in 0..<1000 {
    a.add(mk("user:" + pad6(i), "v", 1UL))
  }
  let size_a = a.finish().length()

  // B 组：1000 条同样 11 字节、但几乎无公共前缀的随机 key
  let rng = TestRng::new(42UL)
  let keys : Array[Bytes] = []
  for _ in 0..<1000 {
    let kb = Buffer::Buffer()
    for _ in 0..<11 {
      kb.write_byte(rng.below(256).to_byte())
    }
    keys.push(kb.to_bytes())
  }
  sort_bytes(keys)
  let b = BlockBuilder::new()
  let mut prev : Bytes = b""
  for k in keys {
    if compare_bytes(prev, k) != 0 {
      b.add({ key: k, value: @utf8.encode("v"), seq: 1UL, deleted: false, })
      prev = k
    }
  }
  let size_b = b.finish().length()

  // 如果前缀压缩没生效，两组体积应该接近。要求 A 至少比 B 小 15%。
  assert_true(size_a * 100 < size_b * 85)
}

///|
test "block: get 命中全部 key，越界与不存在的 key 返回 None" {
  let b = BlockBuilder::new()
  for i in 0..<300 {
    b.add(mk("k" + pad6(i), "v" + i.to_string(), (i + 1).to_uint64()))
  }
  let blk = must_decode(b.finish())
  for i in 0..<300 {
    match blk.get(@utf8.encode("k" + pad6(i))) {
      Some(e) => {
        assert_eq(compare_bytes(e.value, @utf8.encode("v" + i.to_string())), 0)
        assert_eq(e.seq, (i + 1).to_uint64())
        assert_eq(e.deleted, false)
      }
      None => assert_true(false)
    }
  }
  // 小于最小 key
  assert_true(blk.get(@utf8.encode("a")) is None)
  // 大于最大 key
  assert_true(blk.get(@utf8.encode("z")) is None)
  // 落在两个 key 之间
  assert_true(blk.get(@utf8.encode("k000000x")) is None)
  // 前缀相同但更长
  assert_true(blk.get(@utf8.encode("k0000000")) is None)
}

///|
test "block: 墓碑与空 value 必须可区分" {
  let b = BlockBuilder::new()
  // a 是删除（墓碑），b 是写入空字符串 —— 两者 value 长度都是 0
  b.add({ key: @utf8.encode("a"), value: b"", seq: 1UL, deleted: true, })
  b.add({ key: @utf8.encode("b"), value: b"", seq: 2UL, deleted: false, })
  let blk = must_decode(b.finish())
  match blk.get(@utf8.encode("a")) {
    Some(e) => {
      assert_eq(e.deleted, true)
      assert_eq(e.value.length(), 0)
    }
    None => assert_true(false)
  }
  match blk.get(@utf8.encode("b")) {
    Some(e) => {
      assert_eq(e.deleted, false)
      assert_eq(e.value.length(), 0)
    }
    None => assert_true(false)
  }
}

///|
test "block: 任意二进制 key 往返（含 0x00 与 0xFF）" {
  // 已按字节序升序：[00] < [00,00] < [00,FF] < [FF] < [FF,00]
  let keys : Array[Bytes] = [
    bytes_of([0x00]),
    bytes_of([0x00, 0x00]),
    bytes_of([0x00, 0xFF]),
    bytes_of([0xFF]),
    bytes_of([0xFF, 0x00]),
  ]
  let b = BlockBuilder::new()
  for i in 0..<keys.length() {
    b.add({
      key: keys[i],
      value: bytes_of([i]),
      seq: (i + 1).to_uint64(),
      deleted: false,
    })
  }
  let blk = must_decode(b.finish())
  for i in 0..<keys.length() {
    match blk.get(keys[i]) {
      Some(e) => {
        assert_eq(compare_bytes(e.key, keys[i]), 0)
        assert_eq(compare_bytes(e.value, bytes_of([i])), 0)
      }
      None => assert_true(false)
    }
  }
}

///|
test "block: 乱序或重复 key 直接报错，不写出坏 block" {
  let b = BlockBuilder::new()
  b.add(mk("b", "1", 1UL))
  let mut rejected = false
  b.add(mk("a", "2", 2UL)) catch {
    _ => rejected = true
  }
  assert_true(rejected)
  // 重复 key 也不行：格式规定 block 内严格升序、不允许重复
  let mut rejected_dup = false
  b.add(mk("b", "3", 3UL)) catch {
    _ => rejected_dup = true
  }
  assert_true(rejected_dup)
}

///|
test "block: 结构损坏返回 None 而不是 panic" {
  // 太短，连 num_restarts 都放不下
  assert_true(decode_block(b"") is None)
  assert_true(decode_block(bytes_of([0x00, 0x00, 0x00])) is None)
  // num_restarts = 0，格式要求至少 1 个
  assert_true(decode_block(bytes_of([0x00, 0x00, 0x00, 0x00])) is None)
  // num_restarts 大到 restart 数组吃穿整个 block
  assert_true(decode_block(bytes_of([0xFF, 0xFF, 0xFF, 0x7F])) is None)
  // restart 偏移超出 entry 区
  assert_true(
    decode_block(bytes_of([0x08, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]))
    is None,
  )
}

///|
test "block: entry 区被截断时 entries() 报错而不是返回半截数据" {
  let b = BlockBuilder::new()
  for i in 0..<20 {
    b.add(mk("k" + pad6(i), "value" + i.to_string(), i.to_uint64()))
  }
  let raw = b.finish()
  // 砍掉最后 4 个字节（num_restarts 还在，但 restart 数组被截）
  let truncated = raw[:raw.length() - 4].to_owned()
  // 结构层能过（num_restarts 读的是原来的位置，现在读到的是 restart 数据），
  // 但内容层一定对不上 —— 这里只要求「不 panic、返回 None 或抛错」二者之一
  match decode_block(truncated) {
    None => assert_true(true)
    Some(blk) => {
      let mut failed = false
      try {
        let _ = blk.entries()
      } catch {
        _ => failed = true
      }
      // 如果没抛错，那说明解出来的条目数一定不对
      assert_true(failed || blk.entries().length() != 20)
    }
  }
}

///|
/// 把第 `at` 个字节换掉，返回新的一份。
///
/// `corruption_wbtest.mbt` 里有个同名的 `corrupt_at`，但那个文件有自己的
/// `bad_byte`；白盒测试的顶层标识符在整个包里共享，所以这里换个名字。
fn poke_block_byte(b : Bytes, at : Int) -> Bytes {
  let buf = Buffer::Buffer()
  buf.write_bytes(b[:at])
  buf.write_byte(if b[at] == 0x5A { 0x00 } else { 0x5A })
  buf.write_bytes(b[at + 1:])
  buf.to_bytes()
}

///|
/// **每一个**字节被改坏，`decode_block` 都必须返回 `None`。
///
/// 这是 block CRC 的最小证明：不是「改坏某处能发现」，而是「改坏任何一处都能发现」。
/// 之所以能这么断言，是因为 CRC 覆盖的是整个 block（entry 区 + restart 数组 +
/// `num_restarts`），没有留下任何不参与校验的字节。
test "block: 任意单字节损坏都会被 CRC 拦下" {
  let b = BlockBuilder::new()
  for i in 0..<40 {
    b.add(mk("key:" + pad6(i), "value" + i.to_string(), (i + 1).to_uint64()))
  }
  let raw = b.finish()
  assert_true(raw.length() > 100)
  for at in 0..<raw.length() {
    assert_true(decode_block(poke_block_byte(raw, at)) is None)
  }
}

///|
/// v1 格式（没有 CRC）的 block 必须还能解出来 —— 否则读老库会全线失败。
///
/// 顺带把「v1 与 v2 只差尾部 4 字节」这件事钉住：如果哪天有人在中间插字段，
/// 这个断言会红，提醒他这已经不是「加个校验」而是「换了格式」。
test "block: v1 格式（无 CRC）仍可解码，且与 v2 只差尾部 4 字节" {
  let b = BlockBuilder::new()
  for i in 0..<20 {
    b.add(mk("key:" + pad6(i), "value" + i.to_string(), (i + 1).to_uint64()))
  }
  let v1 = b.finish_v1()
  let v2 = b.finish()
  assert_eq(v2.length(), v1.length() + BLOCK_CRC_SIZE)
  assert_bytes_eq(v2[:v1.length()].to_owned(), v1)
  let blk = match decode_block_v1(v1) {
    Some(x) => x
    None => fail("v1 block 解不出来")
  }
  assert_eq(blk.entries().length(), 20)
  // 把 v2 的 CRC 摘掉之后，它和 v1 必须是同一份字节
  assert_true(decode_block(v1) is None)
}
