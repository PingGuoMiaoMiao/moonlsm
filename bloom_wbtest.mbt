///|
/// Bloom filter 的直接测试。
///
/// 之前 bloom 只被 sstable 的用例间接覆盖 —— 那只能证明「用起来没崩」，
/// 证明不了它真的在省 IO。这里补四类：
///
/// 1. **无假阴性**（唯一不可妥协的性质：数据在，就必须说「可能在」）
/// 2. **误判率**（说「可能在」的比例，决定它省了多少 IO）
/// 3. **位图打包**（内存表示与磁盘表示必须一致，否则 encode/decode 会错位）
/// 4. **坏数据拒绝**（宁可拒绝打开，也不能拿着可疑 filter 去过滤）

///|
fn make_keys(prefix : String, n : Int32) -> Array[Bytes] {
  let out : Array[Bytes] = []
  for i in 0..<n {
    out.push(@utf8.encode(prefix + pad6(i)))
  }
  out
}

///|
/// 用 `absent` 个不存在的 key 去问，返回「被误判为存在」的比例。
fn measure_fpr(
  filter : BloomFilter,
  absent_prefix : String,
  absent : Int32,
) -> Double {
  let mut false_positive = 0
  for k in make_keys(absent_prefix, absent) {
    if filter.may_contain(k) {
      false_positive = false_positive + 1
    }
  }
  false_positive.to_double() / absent.to_double()
}

///|
/// 写入的 key 一个都不能漏。这是 bloom 唯一「错了就丢数据」的性质。
test "bloom: 写入的 key 一定命中" {
  let keys = make_keys("present:", 5000)
  let f = BloomFilter::new(keys.length())
  for k in keys {
    f.put(k)
  }
  for k in keys {
    assert_true(f.may_contain(k))
  }
}

///|
/// 空 filter 对任何 key 都说「不在」。若这里返回 true，
/// 说明位图初始状态不是全 0（比如 `Array::make` 的默认值用错了）。
test "bloom: 空 filter 不误报" {
  let f = BloomFilter::new(1000)
  for k in make_keys("any:", 2000) {
    assert_false(f.may_contain(k))
  }
}

///|
/// 误判率必须真的落在设计值附近。
///
/// 10 bit/key + 7 哈希的理论值是 `(1-e^(-0.7))^7 ≈ 0.82%`。
/// 这里断言 `< 1.5%` 而不是 `< 0.82%`：key 集合是固定的，
/// 实测值本身是确定的，但留一倍余量，免得以后改哈希函数时
/// 因为 0.1% 的抖动就挂。
test "bloom: 10 bit/key 的误判率低于 1.5%" {
  let n = 10000
  let keys = make_keys("present:", n)
  let f = BloomFilter::new(n)
  for k in keys {
    f.put(k)
  }
  let fpr = measure_fpr(f, "absent:", 100000)
  // 真的量过：0.8% 左右。写成断言是为了它退化时能被发现。
  assert_true(fpr < 0.015)
}

///|
/// 位数越少，误判率越高 —— 确认「调 bits_per_key」这个旋钮真的有效。
/// 若两档测出一样的误判率，说明位图大小没跟着变（比如算错了 `num_bits`）。
test "bloom: 位数越多误判率越低" {
  let n = 5000
  let keys = make_keys("present:", n)
  let lean = BloomFilter::new_with(n, 4, 3)
  let rich = BloomFilter::new_with(n, 16, 11)
  for k in keys {
    lean.put(k)
    rich.put(k)
  }
  let lean_fpr = measure_fpr(lean, "absent:", 20000)
  let rich_fpr = measure_fpr(rich, "absent:", 20000)
  assert_true(lean_fpr > rich_fpr)
  // 4 bit 的理论值约 14.7%，16 bit 约 0.05%，差距应该是两个数量级
  assert_true(lean_fpr > 0.08)
  assert_true(rich_fpr < 0.005)
}

///|
/// 内存里的位图与磁盘上的位图必须是同一份字节。
/// 早先的实现内存用 `Array[Bool]`、磁盘按位打包，中间靠 encode 逐位重排，
/// 一旦某处差一位，读出来的 filter 就会「假阴性」。
test "bloom: 内存表示就是磁盘表示" {
  let f = BloomFilter::new_with(1000, 10, 7)
  for k in make_keys("k:", 1000) {
    f.put(k)
  }
  // num_bits 是 8 的倍数，位图字节数 = num_bits/8
  assert_eq(f.num_bits % 8, 0)
  let encoded = f.encode()
  // 1 字节 k + varint(num_bits) + 位图 + 4 字节 CRC（v2）
  let varint_len = if f.num_bits < 128 {
    1
  } else if f.num_bits < 16384 {
    2
  } else {
    3
  }
  assert_eq(encoded.length(), 1 + varint_len + f.num_bits / 8 + 4)
  // 编码出来的字节里，位图段与内存逐字节相同
  let body = encoded[1 + varint_len:]
  for i in 0..<(f.num_bits / 8) {
    assert_eq(body[i], f.bits[i])
  }
}

///|
/// 往返：encode → decode 之后行为完全不变。
test "bloom: 编码解码往返后行为一致" {
  let keys = make_keys("rt:", 3000)
  let f = BloomFilter::new(keys.length())
  for k in keys {
    f.put(k)
  }
  let back = decode_bloom(f.encode()).unwrap()
  assert_eq(back.num_bits, f.num_bits)
  assert_eq(back.k, f.k)
  for k in keys {
    assert_true(back.may_contain(k))
  }
  // 误判率也应该一致（同一份位图，同一个哈希）
  let before = measure_fpr(f, "other:", 20000)
  let after = measure_fpr(back, "other:", 20000)
  assert_eq(before, after)
}

///|
/// 预算哈希的接口必须与现算的等价，否则 `Db::get` 的复用就是引入 bug。
test "bloom: put_hashes 与 put 等价" {
  let a = BloomFilter::new(1000)
  let b = BloomFilter::new(1000)
  for k in make_keys("eq:", 1000) {
    a.put(k)
    let (h1, h2) = bloom_hashes(k)
    b.put_hashes(h1, h2)
  }
  for k in make_keys("eq:", 1000) {
    assert_true(b.may_contain(k))
  }
  for k in make_keys("neq:", 1000) {
    assert_eq(a.may_contain(k), b.may_contain(k))
  }
}

///|
/// 参数退化要被夹住，不能出现「0 个哈希」或「0 位位图」这种无意义状态。
test "bloom: 参数下限被夹住" {
  let f = BloomFilter::new_with(0, 0, 0)
  assert_eq(f.k, 1)
  // expected < 64 时下限 640 位
  assert_eq(f.num_bits, 640)
  assert_false(f.may_contain(b"anything"))
}

///|
/// 位图长度与 num_bits 不符时拒绝解码。
/// 这种情况一旦放过，读端会按错误的 n 去取模，行为不可预测。
test "bloom: 位图长度不符时拒绝解码" {
  let f = BloomFilter::new_with(1000, 10, 7)
  let good = f.encode()
  // 砍掉最后一个字节
  assert_true(decode_bloom(good[:good.length() - 1].to_owned()) is None)
  // 多补一个字节
  let longer = Buffer::Buffer()
  longer.write_bytes(good[:])
  longer.write_byte((0 : Byte))
  assert_true(decode_bloom(longer.to_bytes()) is None)
}

///|
/// k 越界时拒绝解码。k=0 会让 `may_contain` 直接返回 true（永远不否定，
/// bloom 退化成摆设）；k 过大则会把位图迅速填满，误判率趋近 1。
test "bloom: k 越界时拒绝解码" {
  // k=0
  let zero = Buffer::Buffer()
  zero.write_byte((0 : Byte))
  write_varint32(zero, 640)
  for _ in 0..<80 {
    zero.write_byte((0 : Byte))
  }
  assert_true(decode_bloom(zero.to_bytes()) is None)
  // k=31
  let big = Buffer::Buffer()
  big.write_byte((31 : Byte))
  write_varint32(big, 640)
  for _ in 0..<80 {
    big.write_byte((0 : Byte))
  }
  assert_true(decode_bloom(big.to_bytes()) is None)
}

///|
/// 太短的数据连头部都放不下。
test "bloom: 过短数据拒绝解码" {
  assert_true(decode_bloom(b"") is None)
  assert_true(decode_bloom(b"\x07") is None)
}

///|
/// 全部位都置 1 时任何 key 都返回 true —— 这是误判率的上界，
/// 也说明 popcount 与探测用的是同一套位索引。
test "bloom: 位全满时全部命中" {
  let f = BloomFilter::new_with(64, 8, 4)
  // 反复写入大量 key 把位图填满
  for i in 0..<20000 {
    f.put(@utf8.encode("fill:" + i.to_string()))
  }
  assert_true(f.popcount() > f.num_bits * 7 / 10)
  for k in make_keys("never:", 500) {
    assert_true(f.may_contain(k))
  }
}

///|
/// **filter 的损坏方向最危险**：位图被改坏时 `may_contain` 会返回 `false`，
/// 于是「数据明明在，却查不到」—— 引擎会理直气壮地报「没有这个 key」。
/// 所以 filter 也必须逐个字节可检。
test "bloom: 任意单字节损坏都会被 CRC 拦下" {
  let f = BloomFilter::new_with(200, 10, 7)
  for k in make_keys("k:", 200) {
    f.put(k)
  }
  let raw = f.encode()
  for at in 0..<raw.length() {
    let buf = Buffer::Buffer()
    buf.write_bytes(raw[:at])
    buf.write_byte(if raw[at] == 0x5A { 0x00 } else { 0x5A })
    buf.write_bytes(raw[at + 1:])
    assert_true(decode_bloom(buf.to_bytes()) is None)
  }
}

///|
/// v1 的 filter（没有尾部 CRC）仍要能解，且与 v2 只差尾部 4 字节。
test "bloom: v1 格式（无 CRC）仍可解码" {
  let f = BloomFilter::new_with(100, 10, 7)
  for k in make_keys("k:", 100) {
    f.put(k)
  }
  let v2 = f.encode()
  let v1 = v2[:v2.length() - 4].to_owned()
  let back = match decode_bloom_v1(v1) {
    Some(b) => b
    None => fail("v1 filter 解不出来")
  }
  assert_eq(back.num_bits, f.num_bits)
  assert_eq(back.k, f.k)
  for k in make_keys("k:", 100) {
    assert_true(back.may_contain(k))
  }
  // 少了 CRC 的字节喂给 v2 解码器，必须被拒
  assert_true(decode_bloom(v1) is None)
}
