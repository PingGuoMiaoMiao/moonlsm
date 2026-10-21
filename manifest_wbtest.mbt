///|
/// MANIFEST 编解码测试。
///
/// 这一层的测试重点是**坏数据**，不是好数据。往返测试只能证明
/// 「编码器和解码器错得一致」，而 MANIFEST 读错的后果是
/// 「按错误的布局去读 SST」——数据看起来在，但读到的是错的。
///
/// 所以下面每一组坏数据都是**手工构造**的，不是随机翻转比特：
/// 随机翻转大概率被 CRC 挡住，反而测不到 CRC 之后那些结构检查。

///|
/// 把 `b` 的第 `at` 字节换成 `value`，返回**新的一份**。
///
/// `Bytes` 在这个工具链上没有 `op_set`，也不该有：WAL / SST / MANIFEST
/// 里读出来的字节序列是「已经落盘的事实」，原地改它只会制造
/// 「校验时是好的、用的时候是坏的」这种最难查的 bug。
/// 要坏数据就显式造一份坏的。
fn flip(b : Bytes, at : Int, value : Byte) -> Bytes {
  let buf = Buffer::Buffer()
  buf.write_bytes(b[:at])
  buf.write_byte(value)
  buf.write_bytes(b[at + 1:])
  buf.to_bytes()
}

///|
fn mk_sst(n : UInt64, size : UInt64, lo : String, hi : String) -> SstMeta {
  SstMeta::new(n, size, bytes_of_str(lo), bytes_of_str(hi))
}

///|
fn sample_version() -> Version {
  let v = Version::with_header(42UL, 7UL, 12UL)
  // L0：两个范围重叠的文件（L0 允许重叠）
  v.set_level(0, [mk_sst(3UL, 100UL, "a", "m"), mk_sst(5UL, 200UL, "d", "z")])
  // L1：范围严格不重叠
  v.set_level(1, [mk_sst(9UL, 300UL, "aa", "bb"), mk_sst(10UL, 400UL, "cc", "dd")])
  v
}

///|
test "manifest: 往返编解码" {
  let v = sample_version()
  let raw = encode_manifest(v)
  let got = match decode_manifest(raw) {
    Some(x) => x
    None => fail("应能解码")
  }
  assert_eq(got.last_seq, 42UL)
  assert_eq(got.log_number, 7UL)
  assert_eq(got.next_file_number, 12UL)
  assert_eq(got.level_count(), 2)
  assert_eq(got.level(0).length(), 2)
  assert_eq(got.level(1).length(), 2)
  let s = got.level(1)[0]
  assert_eq(s.number, 9UL)
  assert_eq(s.file_size, 300UL)
  assert_eq(str_of_bytes(s.smallest), "aa")
  assert_eq(str_of_bytes(s.largest), "bb")
  assert_eq(got.total_ssts(), 4)
}

///|
test "manifest: 空版本也能往返（刚建的库）" {
  let raw = encode_manifest(Version::new())
  let got = match decode_manifest(raw) {
    Some(x) => x
    None => fail("空版本应能解码")
  }
  assert_eq(got.last_seq, 0UL)
  assert_eq(got.level_count(), 1)
  assert_eq(got.total_ssts(), 0)
  assert_true(got.check_invariants())
}

///|
test "manifest: 编码是确定性的（同样的版本产出同样的字节）" {
  // 不确定的编码会让「内容没变却写了新 MANIFEST」，进而让
  // 每次 compaction 都触发一次无意义的文件切换。
  let a = encode_manifest(sample_version())
  let b = encode_manifest(sample_version())
  assert_eq(a.length(), b.length())
  for i in 0..<a.length() {
    assert_eq(a[i], b[i])
  }
}

///|
test "manifest: 长度不足时返回 None，不 panic" {
  assert_true(decode_manifest(b"") is None)
  assert_true(decode_manifest(b"MMAN") is None)
  assert_true(decode_manifest(b"MMAN\x01\x00\x00\x00") is None)
  // 只差 CRC 一个字节
  let raw = encode_manifest(Version::new())
  assert_true(decode_manifest(raw[:raw.length() - 1].to_owned()) is None)
}

///|
test "manifest: magic 不对时返回 None" {
  let raw = encode_manifest(Version::new())
  assert_true(decode_manifest(flip(raw, 0, (88).to_byte())) is None)
}

///|
test "manifest: version 不对时返回 None（未来格式不会被误读）" {
  let raw = encode_manifest(Version::new())
  // version 在偏移 4，小端 u16
  assert_true(decode_manifest(flip(raw, 4, (99).to_byte())) is None)
}

///|
test "manifest: CRC 不匹配时返回 None" {
  let raw = encode_manifest(sample_version())
  // 改一个 payload 字节，不动 CRC
  let at20 = raw[20].to_int() ^ 0xFF
  assert_true(decode_manifest(flip(raw, 20, at20.to_byte())) is None)
  // 改 CRC 本身
  let n = raw.length()
  let last = raw[n - 1].to_int() ^ 0x01
  assert_true(decode_manifest(flip(raw, n - 1, last.to_byte())) is None)
}

///|
test "manifest: 尾部有多余字节时返回 None（格式理解不一致就别猜）" {
  let raw = encode_manifest(Version::new())
  let b = Buffer::Buffer()
  b.write_bytes(raw[:])
  b.write_byte(0x00)
  assert_true(decode_manifest(b.to_bytes()) is None)
}

///|
test "manifest: 层数超上限时返回 None（防止坏数据触发巨额分配）" {
  // 手工构造一份「CRC 正确、但 num_levels 是天文数字」的数据。
  // 这正是「CRC 挡住随机损坏」挡不住的情形：数据是**有意**写成这样的。
  let b = Buffer::Buffer()
  b.write_bytes(b"MMAN")
  write_fixed16(b, MANIFEST_VERSION)
  write_fixed16(b, 0)
  write_varint64(b, 0UL) // last_seq
  write_varint64(b, 1UL) // log_number
  write_varint64(b, 2UL) // next_file_number
  write_varint32(b, 1000000) // num_levels，远超上限
  let body = b.to_bytes()
  let out = Buffer::Buffer()
  out.write_bytes(body)
  write_fixed32u(out, crc32c(body))
  assert_true(decode_manifest(out.to_bytes()) is None)
}

///|
test "manifest: 单层 SST 数量超上限时返回 None" {
  let b = Buffer::Buffer()
  b.write_bytes(b"MMAN")
  write_fixed16(b, MANIFEST_VERSION)
  write_fixed16(b, 0)
  write_varint64(b, 0UL)
  write_varint64(b, 1UL)
  write_varint64(b, 2UL)
  write_varint32(b, 1) // 1 层
  write_varint32(b, 1 << 30) // 该层 SST 数量爆表
  let body = b.to_bytes()
  let out = Buffer::Buffer()
  out.write_bytes(body)
  write_fixed32u(out, crc32c(body))
  assert_true(decode_manifest(out.to_bytes()) is None)
}

///|
test "manifest: smallest > largest 时返回 None（不可能由写入路径产生）" {
  let v = Version::new()
  v.set_level(0, [mk_sst(3UL, 100UL, "zzz", "aaa")])
  // 编码不会拦它（编码器只管写），解码必须拦
  assert_true(decode_manifest(encode_manifest(v)) is None)
}

///|
test "manifest: 空 key 是合法的（库可能真的存过空 key）" {
  let v = Version::new()
  v.set_level(0, [mk_sst(3UL, 10UL, "", "")])
  let got = match decode_manifest(encode_manifest(v)) {
    Some(x) => x
    None => fail("空 key 应能解码")
  }
  assert_eq(got.level(0)[0].smallest.length(), 0)
  assert_eq(got.level(0)[0].largest.length(), 0)
}

// ---------------------------------------------------------------------------
// 语义不变量
// ---------------------------------------------------------------------------

///|
test "manifest: 合法版本的 check_invariants 为真" {
  assert_true(sample_version().check_invariants())
}

///|
test "manifest: log_number >= next_file_number 时违反不变量" {
  let v = Version::with_header(0UL, 10UL, 10UL)
  assert_true(!(v.check_invariants()))
}

///|
test "manifest: L1 同层重叠时违反不变量" {
  let v = Version::new()
  v.set_level(1, [mk_sst(3UL, 100UL, "a", "m"), mk_sst(4UL, 100UL, "k", "z")])
  assert_true(!(v.check_invariants()))
}

///|
test "manifest: L1 同层乱序时违反不变量" {
  let v = Version::new()
  v.set_level(1, [mk_sst(3UL, 100UL, "m", "z"), mk_sst(4UL, 100UL, "a", "d")])
  assert_true(!(v.check_invariants()))
}

///|
test "manifest: L0 允许重叠（来自不同时刻的 memtable）" {
  let v = Version::new()
  // 三个文件范围全部覆盖 "m"
  v.set_level(0, [
    mk_sst(3UL, 100UL, "a", "z"), mk_sst(4UL, 100UL, "b", "y"),
    mk_sst(5UL, 100UL, "m", "m"),
  ])
  assert_true(v.check_invariants())
}

///|
test "manifest: 相邻但不重叠的 L1 文件合法（largest < next.smallest）" {
  let v = Version::new()
  v.set_level(1, [mk_sst(3UL, 100UL, "a", "b"), mk_sst(4UL, 100UL, "c", "d")])
  assert_true(v.check_invariants())
}

// ---------------------------------------------------------------------------
// 编号分配
// ---------------------------------------------------------------------------

///|
test "manifest: 文件编号单调递增且不复用" {
  let v = Version::new()
  let a = v.alloc_file_number()
  let b = v.alloc_file_number()
  let c = v.alloc_file_number()
  assert_true(b > a)
  assert_true(c > b)
  // 编号必须严格大于已有的最大编号，否则会覆盖已有文件
  assert_true(a >= 2UL)
}

///|
test "manifest: set_level 复制数组，之后的改动不影响快照" {
  // 这条测试防的是一个很容易犯的错：把调用方的数组直接存进版本里。
  // 那样「版本快照」就不再是快照，compaction 之后再读会看到未来的状态。
  let v = Version::new()
  let src : Array[SstMeta] = [mk_sst(3UL, 100UL, "a", "b")]
  v.set_level(0, src)
  src.push(mk_sst(4UL, 100UL, "c", "d"))
  assert_eq(v.level(0).length(), 1)
}

///|
test "manifest: level 越界返回空数组而不是 panic" {
  let v = Version::new()
  assert_eq(v.level(99).length(), 0)
  assert_eq(v.level(-1).length(), 0)
}

///|
test "manifest: set_level 到不存在的层会自动补齐中间层" {
  let v = Version::new()
  v.set_level(2, [mk_sst(3UL, 100UL, "a", "b")])
  assert_eq(v.level_count(), 3)
  assert_eq(v.level(0).length(), 0)
  assert_eq(v.level(1).length(), 0)
  assert_eq(v.level(2).length(), 1)
  // 补齐后的版本仍要满足不变量
  assert_true(v.check_invariants())
}
