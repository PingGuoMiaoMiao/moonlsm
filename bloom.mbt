///|
/// 极简 Bloom filter：用双哈希模拟 k 个独立哈希。
/// 作用是在查 SST 之前先排除「肯定不在」的文件，把读放大压下来。
///
/// **三个实现选择，都是量过才定的**（见 ADR-0008）：
///
/// 1. **位图在内存里也按位打包**（`Array[Byte]`），不是一个 bool 一字节。
///    早先用 `Array[Bool]`，10 bit/key 的 filter 在内存里膨胀 8 倍：
///    100 万条数据的 77 个 SST 要占 10 MiB，打包后 1.25 MiB。
///    顺带 `encode` / `decode` 从「逐位重排」变成「整段拷贝」。
///
/// 2. **一次哈希出两个值**，而不是两个种子各跑一遍 FNV。
///    `h2` 由 `h1` 过一次 splitmix 终混得到 —— 6 条整数指令，
///    而第二遍 FNV 要遍历整条 key。Kirsch–Mitzenmacher 证明这样构造的
///    双哈希与 k 个独立哈希的误判率同阶。
///
/// 3. **取模换成乘法**（fastrange）。`%` 在 `UInt64` 上是真除法，
///    约 20 个周期；一次未命中要探 77 个文件 × 7 个位置 = 539 次除法，
///    约 3.6 µs，而引擎侧点查总共才 10 µs 量级。

///|
/// 每个元素分配多少位。10 bit 配 7 个哈希，理论误判率 0.82%。
/// 实测见 `bloom_wbtest.mbt` 与 `docs/engineering/BENCHMARK.md`。
const BLOOM_BITS_PER_KEY : Int = 10

///|
/// 哈希个数。最优值是 `bits_per_key * ln2`，10 bit 对应 6.93，取 7。
const BLOOM_K : Int = 7

///|
/// 位图在内存里就是打包好的字节，与磁盘布局一一对应。
/// `num_bits` 单独存一份：末尾那个字节的高位可能没用满，
/// 探测时只能落在 `[0, num_bits)` 内。
pub struct BloomFilter {
  bits : Array[Byte]
  num_bits : Int
  k : Int
}

///|
/// FNV-1a 64 位。
fn fnv1a(data : Bytes, seed : UInt64) -> UInt64 {
  let mut h = seed
  for i in 0..<data.length() {
    h = h ^ data[i].to_uint64()
    h = h * 0x100000001B3UL
  }
  h
}

///|
/// splitmix64 的终混函数：把 `h` 打散成另一个雪崩良好的 64 位值。
/// 只用来从 `h1` 派生 `h2`，不参与 key 的遍历。
fn mix64(x : UInt64) -> UInt64 {
  let mut h = x
  h = h ^ (h >> 33)
  h = h * 0xFF51AFD7ED558CCDUL
  h = h ^ (h >> 33)
  h = h * 0xC4CEB9FE1A85EC53UL
  h = h ^ (h >> 33)
  h
}

///|
/// 由一条 key 算出双哈希对 `(h1, h2)`。
///
/// **单独暴露出来是为了让调用方复用**：一次点查要探 N 个 SST 的 filter，
/// 而这 N 次用的是同一条 key。把哈希提到循环外面，N 次变 1 次。
///
/// **FNV-1a 出来必须再过一遍 `mix64`。** 这不是保险，是必需的：
/// FNV-1a 最后一步是 `(h ^ byte) * prime`，末字节只影响乘数的低 8 位，
/// 高位几乎不随它变化。实测「10000 条只差末几位的 key」直接取高 32 位，
/// 只落进约 1000 个不同位置（理论值 9516），误判率因此只有理论值的一半。
/// 换成低位也有同样的隐患，正确做法是先做一次完整雪崩。
pub fn bloom_hashes(key : Bytes) -> (UInt64, UInt64) {
  let h = mix64(fnv1a(key, 0xCBF29CE484222325UL))
  (h, mix64(h ^ 0x9E3779B97F4A7C15UL))
}

///|
/// 第 `i` 个探测位置。
///
/// `h1 + i * h2` 是双哈希；`(x & 0xFFFFFFFF) * n >> 32` 是 fastrange ——
/// 把 32 位无符号值均匀映射到 `[0, n)`，等价于 `x * n / 2^32`，
/// 但只用一次乘法而不是一次除法。`n <= 2^24` 时乘积不超过 2^56，不会溢出。
fn probe_index(h1 : UInt64, h2 : UInt64, i : Int, n : UInt64) -> Int {
  let x = h1 + i.to_uint64() * h2
  (((x & 0xFFFFFFFFUL) * n) >> 32).to_int()
}

///|
/// `expected` 是预期元素个数，按默认参数（10 bit / 7 哈希）建 filter。
pub fn BloomFilter::new(expected : Int) -> BloomFilter {
  BloomFilter::new_with(expected, BLOOM_BITS_PER_KEY, BLOOM_K)
}

///|
/// 显式指定每个元素的位数与哈希个数。给调参和测试用。
///
/// 生产路径只用 `new`；`new_with` 存在的意义是让「为什么是 10 bit」
/// 这个问题能用一组可复现的对照实验回答，而不是引用一句经验值。
pub fn BloomFilter::new_with(
  expected : Int,
  bits_per_key : Int,
  k : Int,
) -> BloomFilter {
  let bpk = if bits_per_key < 1 { 1 } else { bits_per_key }
  let kk = if k < 1 { 1 } else { k }
  // 下限 640 位（80 字节）：空文件或极小文件也留一个能用的 filter，
  // 否则 n=0 时取模无意义。
  let raw = if expected < 64 { 640 } else { expected * bpk }
  // 向上取整到整字节，让内存表示与磁盘表示完全一致
  let num_bits = ((raw + 7) / 8) * 8
  { bits: Array::make(num_bits / 8, (0 : Byte)), num_bits, k: kk }
}

///|
fn BloomFilter::set_bit(self : BloomFilter, idx : Int) -> Unit {
  let byte_idx = idx / 8
  let mask = 1 << (idx % 8)
  self.bits[byte_idx] = (self.bits[byte_idx].to_int() | mask).to_byte()
}

///|
fn BloomFilter::get_bit(self : BloomFilter, idx : Int) -> Bool {
  let byte_idx = idx / 8
  let mask = 1 << (idx % 8)
  (self.bits[byte_idx].to_int() & mask) != 0
}

///|
pub fn BloomFilter::put(self : BloomFilter, key : Bytes) -> Unit {
  let (h1, h2) = bloom_hashes(key)
  self.put_hashes(h1, h2)
}

///|
/// 用预算好的哈希写入。与 `put` 等价，省一次哈希。
pub fn BloomFilter::put_hashes(
  self : BloomFilter,
  h1 : UInt64,
  h2 : UInt64,
) -> Unit {
  let n = self.num_bits.to_uint64()
  for i in 0..<self.k {
    self.set_bit(probe_index(h1, h2, i, n))
  }
}

///|
/// 返回 false 表示「一定不在」；返回 true 表示「可能在」。
pub fn BloomFilter::may_contain(self : BloomFilter, key : Bytes) -> Bool {
  let (h1, h2) = bloom_hashes(key)
  self.may_contain_hashes(h1, h2)
}

///|
/// 用预算好的哈希查询。一次点查探 N 个 SST 时，哈希只需算一次。
pub fn BloomFilter::may_contain_hashes(
  self : BloomFilter,
  h1 : UInt64,
  h2 : UInt64,
) -> Bool {
  let n = self.num_bits.to_uint64()
  for i in 0..<self.k {
    if !self.get_bit(probe_index(h1, h2, i, n)) {
      return false
    }
  }
  true
}

///|
/// 位图总位数。给调参与统计用 —— 它决定了 filter 的空间开销。
pub fn BloomFilter::num_bits(self : BloomFilter) -> Int {
  self.num_bits
}

///|
/// 哈希个数。
pub fn BloomFilter::k(self : BloomFilter) -> Int {
  self.k
}

///|
/// 已置位的 bit 数。只用于测试与统计。
pub fn BloomFilter::popcount(self : BloomFilter) -> Int {
  let mut total = 0
  for b in self.bits {
    let v = b.to_int()
    for j in 0..<8 {
      if (v & (1 << j)) != 0 {
        total = total + 1
      }
    }
  }
  total
}

///|
/// 编码成格式规范 §3.3 的字节布局（v2）：
/// `k(1B) | num_bits(varint32) | bits[num_bits/8] | crc32c(4B)`
///
/// 因为内存里已经是打包好的位图，这里只做整段拷贝，
/// 不再逐位重排 —— 早先的实现每 8 个 bool 要跑一轮内层循环。
///
/// 尾部 CRC 是 v2 加的（ADR-0010）。理由不是「顺手统一」：
/// filter 没有 CRC 时，一个坏掉的位图会让 `may_contain` 返回 **false**，
/// 于是「数据明明在，却查不到」—— 这是唯一一种会**主动丢数据**的损坏方向，
/// 比报错难查得多。fuzz 也证实了：加 CRC 之前，整个 filter 区域 80 个位置
/// 全部漏检。
pub fn BloomFilter::encode(self : BloomFilter) -> Bytes {
  self.encode_with(true)
}

///|
/// 产出**格式版本 1** 的 filter 字节（没有尾部 CRC）。
///
/// 只被 `SstWriter` 的 v1 写入路径用到 —— 那条路径存在的唯一目的是
/// 让兼容性测试能造出老文件，见 `sstable_wbtest.mbt`。
fn BloomFilter::encode_v1(self : BloomFilter) -> Bytes {
  self.encode_with(false)
}

///|
fn BloomFilter::encode_with(self : BloomFilter, with_crc : Bool) -> Bytes {
  let body = Buffer::Buffer()
  body.write_byte(self.k.to_byte())
  write_varint32(body, self.num_bits)
  body.write_bytes(Bytes::from_array(self.bits[:])[:])
  let raw = body.to_bytes()
  if !with_crc {
    return raw
  }
  let out = Buffer::Buffer()
  out.write_bytes(raw[:])
  write_fixed32u(out, crc32c(raw))
  out.to_bytes()
}

///|
/// 从字节解码 filter（**格式版本 2**，尾部带 CRC）。结构不一致或 CRC 不符时返回 `None`。
///
/// 这里**校验得比较严**（k 的范围、位图长度必须与 num_bits 精确匹配）：
/// filter 读错不会直接导致数据错误，但会让「假阴性」出现 ——
/// 而假阴性意味着「数据明明在，却查不到」，这是 LSM 里最不可接受的错误。
/// 宁可判定文件损坏、拒绝打开，也不要拿着一个半信半疑的 filter 去过滤。
pub fn decode_bloom(data : Bytes) -> BloomFilter? {
  if data.length() < 2 + 4 {
    return None
  }
  let body_len = data.length() - 4
  let want = match read_fixed32u(data, body_len) {
    Some(v) => v
    None => return None
  }
  if crc32c(data[:body_len].to_owned()) != want {
    return None
  }
  parse_bloom(data, body_len)
}

///|
/// 解码**格式版本 1** 的 filter（没有尾部 CRC）。只在读 v1 文件时走这里。
pub fn decode_bloom_v1(data : Bytes) -> BloomFilter? {
  parse_bloom(data, data.length())
}

///|
/// `end` 指向 filter 结构结束的位置：v2 传 `n - 4`（跳过 CRC），v1 传 `n`。
fn parse_bloom(data : Bytes, end : Int) -> BloomFilter? {
  if end < 2 {
    return None
  }
  let k = data[0].to_int()
  if k < 1 || k > 30 {
    return None
  }
  let (nbits, body_start) = match read_varint32(data, 1, end) {
    Some(pair) => pair
    None => return None
  }
  // 上限 1 << 24 位 = 2 MiB 位图，足够 130 万 key，超过这个数说明数据坏了
  if nbits < 1 || nbits > 1 << 24 {
    return None
  }
  let nbytes = (nbits + 7) / 8
  if body_start + nbytes != end {
    return None
  }
  Some({
    bits: data[body_start:body_start + nbytes].to_array(),
    num_bits: nbits,
    k,
  })
}
