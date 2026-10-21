///|
/// varint 与定长整数的编解码测试。
///
/// 这一层的测试标准比别处高：**必须逐字节比对已知编码**，
/// 而不只是「编码后再解码能还原」。原因很实际 ——
/// 往返测试只能证明「我的编码器和我的解码器互相自洽」，
/// 两边同时写错（比如都用大端）也能通过。
/// 只有拿规范里的字节序列硬比对，才能证明「我的实现符合格式规范」，
/// 也就才能和 LevelDB / RocksDB / 别的语言实现互通。

///|
/// 把一串整数当字节拼起来，用于构造期望的字节序列。
fn bytes_of(xs : Array[Int]) -> Bytes {
  let b = Buffer::Buffer()
  for x in xs {
    b.write_byte(x.to_byte())
  }
  b.to_bytes()
}

///|
/// 逐字节比较并给出位置信息。直接用 `assert_eq` 比较两个 Bytes 时，
/// 失败信息只会显示两个 `b"..."`，在长序列上很难看出差在第几个字节。
fn assert_bytes_eq(got : Bytes, want : Bytes) -> Unit raise {
  assert_eq(got.length(), want.length())
  for i in 0..<want.length() {
    assert_eq(got[i], want[i])
  }
}

///|
test "varint32: 已知编码逐字节符合规范" {
  // 期望值来自 LEB128 定义，不是「我跑出来是什么就是什么」
  let cases : Array[(Int, Array[Int])] = [
    (0, [0x00]),
    (1, [0x01]),
    (127, [0x7F]),
    (128, [0x80, 0x01]),
    (129, [0x81, 0x01]),
    (300, [0xAC, 0x02]),
    (16383, [0xFF, 0x7F]),
    (16384, [0x80, 0x80, 0x01]),
    (2097152, [0x80, 0x80, 0x80, 0x01]),
    (2147483647, [0xFF, 0xFF, 0xFF, 0xFF, 0x07]),
  ]
  for c in cases {
    let (value, want) = c
    let buf = Buffer::Buffer()
    write_varint32(buf, value)
    assert_bytes_eq(buf.to_bytes(), bytes_of(want))
  }
}

///|
test "varint32: 边界值往返且 varint32_len 与实际长度一致" {
  let values : Array[Int] = [
    0, 1, 2, 126, 127, 128, 129, 255, 256, 300, 16382, 16383, 16384, 16385, 2097151,
    2097152, 268435455, 268435456, 2147483647,
  ]
  for v in values {
    let buf = Buffer::Buffer()
    write_varint32(buf, v)
    let data = buf.to_bytes()
    // 长度函数与实际编码长度必须一致，否则 block 大小估算会偏
    assert_eq(varint32_len(v), data.length())
    match read_varint32(data, 0, data.length()) {
      Some((got, next)) => {
        assert_eq(got, v)
        assert_eq(next, data.length())
      }
      None => assert_true(false)
    }
  }
}

///|
test "varint32: 截断与溢出必须返回 None 而不是瞎猜" {
  // 只有续位、没有终止字节
  assert_true(read_varint32(bytes_of([0x80]), 0, 1) is None)
  // 6 个字节全是续位，超过 5 字节上限
  assert_true(
    read_varint32(bytes_of([0x80, 0x80, 0x80, 0x80, 0x80, 0x01]), 0, 6) is None,
  )
  // 第 5 字节超出 32 位有符号范围（0x0F > 0x07）
  assert_true(
    read_varint32(bytes_of([0xFF, 0xFF, 0xFF, 0xFF, 0x0F]), 0, 5) is None,
  )
  // limit 卡在中间：后面的字节不属于本区域，不能读
  assert_true(read_varint32(bytes_of([0x80, 0x01]), 0, 1) is None)
  // 起点越界
  assert_true(read_varint32(bytes_of([0x01]), 1, 1) is None)
}

///|
test "varint64: 覆盖 32 位以上" {
  let values : Array[UInt64] = [
    0UL, 1UL, 127UL, 128UL, 16383UL, 16384UL, 4294967295UL, 4294967296UL, 1099511627776UL,
    18446744073709551615UL,
  ]
  for v in values {
    let buf = Buffer::Buffer()
    write_varint64(buf, v)
    let data = buf.to_bytes()
    match read_varint64(data, 0, data.length()) {
      Some((got, next)) => {
        assert_eq(got, v)
        assert_eq(next, data.length())
      }
      None => assert_true(false)
    }
  }
}

///|
test "varint64: 超长编码返回 None" {
  // 11 个续位字节，超过 UInt64 的 10 字节上限
  assert_true(
    read_varint64(
      bytes_of([
        0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01,
      ]),
      0,
      11,
    )
    is None,
  )
  // 第 10 字节只剩 1 位有效，0x02 越界
  assert_true(
    read_varint64(
      bytes_of([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x02]),
      0,
      10,
    )
    is None,
  )
}

///|
test "fixed32: 小端序与往返" {
  let buf = Buffer::Buffer()
  write_fixed32(buf, 0x01020304)
  // 小端：低字节在前
  assert_bytes_eq(buf.to_bytes(), bytes_of([0x04, 0x03, 0x02, 0x01]))
  let data = buf.to_bytes()
  match read_fixed32(data, 0) {
    Some(v) => assert_eq(v, 0x01020304)
    None => assert_true(false)
  }
}

///|
test "fixed32: 越界返回 None" {
  let data = bytes_of([0x01, 0x02, 0x03])
  assert_true(read_fixed32(data, 0) is None)
  assert_true(read_fixed32(data, -1) is None)
  let full = bytes_of([0x01, 0x02, 0x03, 0x04])
  assert_true(read_fixed32(full, 1) is None)
  match read_fixed32(full, 0) {
    Some(_) => assert_true(true)
    None => assert_true(false)
  }
}
