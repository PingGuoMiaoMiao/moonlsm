///|
/// 极简 Bloom filter：用双哈希模拟 k 个独立哈希。
/// 作用是在查 SST 之前先排除「肯定不在」的文件，把读放大压下来。
pub struct BloomFilter {
  bits : Array[Bool]
  k : Int
}

///|
fn fnv1a(data : Bytes, seed : UInt64) -> UInt64 {
  let mut h = seed
  for i in 0..<data.length() {
    h = h ^ data[i].to_uint64()
    h = h * 0x100000001B3UL
  }
  h
}

///|
/// expected 是预期元素个数。每元素 10 bit、7 个哈希，
/// 误判率大约 1%，够用且实现简单。
pub fn BloomFilter::new(expected : Int) -> BloomFilter {
  let m = if expected < 64 { 640 } else { expected * 10 }
  { bits: Array::make(m, false), k: 7, }
}

///|
pub fn BloomFilter::put(self : BloomFilter, key : Bytes) -> Unit {
  let h1 = fnv1a(key, 0xCBF29CE484222325UL)
  let h2 = fnv1a(key, 0x9E3779B97F4A7C15UL)
  let n = self.bits.length().to_uint64()
  for i in 0..<self.k {
    let idx = ((h1 + i.to_uint64() * h2) % n).to_int()
    self.bits[idx] = true
  }
}

///|
/// 返回 false 表示「一定不在」；返回 true 表示「可能在」。
pub fn BloomFilter::may_contain(self : BloomFilter, key : Bytes) -> Bool {
  let h1 = fnv1a(key, 0xCBF29CE484222325UL)
  let h2 = fnv1a(key, 0x9E3779B97F4A7C15UL)
  let n = self.bits.length().to_uint64()
  for i in 0..<self.k {
    let idx = ((h1 + i.to_uint64() * h2) % n).to_int()
    if !self.bits[idx] {
      return false
    }
  }
  true
}

///|
/// 编码成格式规范 §3.3 的字节布局：
/// `k(1B) | num_bits(varint32) | bits[ceil(num_bits/8)]`
///
/// 位图按位打包（低位在前），而不是一个 bool 一字节 ——
/// 后者会让 filter 膨胀 8 倍，直接吃掉 bloom 的全部收益。
pub fn BloomFilter::encode(self : BloomFilter) -> Bytes {
  let out = Buffer::Buffer()
  out.write_byte(self.k.to_byte())
  let nbits = self.bits.length()
  write_varint32(out, nbits)
  let nbytes = (nbits + 7) / 8
  for i in 0..<nbytes {
    let mut b = 0
    for j in 0..<8 {
      let idx = i * 8 + j
      if idx < nbits && self.bits[idx] {
        b = b | (1 << j)
      }
    }
    out.write_byte(b.to_byte())
  }
  out.to_bytes()
}

///|
/// 从字节解码 filter。结构不一致时返回 `None`。
///
/// 这里**校验得比较严**（k 的范围、位图长度必须与 num_bits 精确匹配）：
/// filter 读错不会直接导致数据错误，但会让「假阴性」出现 ——
/// 而假阴性意味着「数据明明在，却查不到」，这是 LSM 里最不可接受的错误。
/// 宁可判定文件损坏、拒绝打开，也不要拿着一个半信半疑的 filter 去过滤。
pub fn decode_bloom(data : Bytes) -> BloomFilter? {
  if data.length() < 2 {
    return None
  }
  let k = data[0].to_int()
  if k < 1 || k > 30 {
    return None
  }
  let (nbits, body_start) = match read_varint32(data, 1, data.length()) {
    Some(pair) => pair
    None => return None
  }
  // 上限 1 << 24 位 = 2 MiB 位图，足够 130 万 key，超过这个数说明数据坏了
  if nbits < 1 || nbits > 1 << 24 {
    return None
  }
  let nbytes = (nbits + 7) / 8
  if body_start + nbytes != data.length() {
    return None
  }
  let bits = Array::make(nbits, false)
  for i in 0..<nbits {
    let byte = data[body_start + i / 8].to_int()
    bits[i] = (byte & (1 << (i % 8))) != 0
  }
  Some({ bits, k, })
}
