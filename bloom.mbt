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
