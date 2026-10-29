///|
/// CRC32C 测试。
///
/// 只测「同样的输入得到同样的输出」是没有意义的 —— 那样自造的
/// 任何算法都能通过。必须钉住**公开的标准校验向量**，
/// 才能证明这个实现能和 LevelDB / RocksDB / 别的语言互通。

///|
test "crc32c: 标准校验向量" {
  // CRC-32C 的通用 check 值：CRC32C("123456789") == 0xE3069283
  assert_eq(crc32c(b"123456789"), 0xE3069283UL)
  // 空输入恒为 0
  assert_eq(crc32c(b""), 0UL)
}

///|
test "crc32c: 单字节与递增序列的已知值" {
  // 由独立的 Python 参考实现算出（该实现通过了上面的 0xE3069283 校验）
  assert_eq(crc32c(b"a"), 0xC1D04330UL)
  assert_eq(crc32c(b"abc"), 0x364B3FB7UL)
  assert_eq(crc32c(b"hello world"), 0xC99465AAUL)
  assert_eq(crc32c(b"MWAL"), 0x9058F9A8UL)
  assert_eq(crc32c(b"MSST"), 0x8C81037DUL)
}

///|
test "crc32c: 单比特翻转必须改变校验和" {
  // 这是校验和存在的全部意义：任何一位变化都要被发现。
  // 8 字节 × 8 位 = 64 种单比特变化，一个都不能漏。
  let base : Array[Int32] = [0, 0, 0, 0, 0, 0, 0, 0]
  let good = crc32c(bytes_of(base))
  for i in 0..<8 {
    for bit in 0..<8 {
      let mutated : Array[Int32] = []
      for j in 0..<8 {
        mutated.push(if j == i { 1 << bit } else { 0 })
      }
      assert_true(crc32c(bytes_of(mutated)) != good)
    }
  }
}

///|
test "crc32c: 长输入不溢出、结果始终在 32 位内" {
  let big = Buffer::Buffer()
  for i in 0..<100000 {
    big.write_byte((i % 251).to_byte())
  }
  let v = crc32c(big.to_bytes())
  assert_true(v <= 0xFFFFFFFFUL)
  // 同样的输入必须得到同样的结果（无隐藏状态）
  assert_eq(crc32c(big.to_bytes()), v)
}
