///|
/// 变长整数（LEB128）与定长小端整数的读写原语。
///
/// 这是 WAL、data block、MANIFEST 三处磁盘格式的共同底座，所以单独成文件、
/// 单独测试。一旦 varint 编解码有错，三种格式会同时坏，而且症状互相掩盖
/// （WAL 少读一个字节 → 后面全部错位 → 表现为「CRC 校验失败」），
/// 极难定位到根因。把它隔离出来，是让「坏」只可能发生在这一层。
///
/// **所有 `read_*` 在越界或编码非法时返回 `None`，不抛错。**
/// 为什么不在底层抛错：同一个 `None` 在上层有完全不同的含义 ——
/// WAL 恢复把它当「尾部截断，可以容忍」（ADR-0003 不变量 I3），
/// data block 解析把它当「数据损坏，必须报错」。
/// 底层不该替上层做这个判断。

///|
/// 写 `varint32`。**要求 `value >= 0`**。
///
/// 负数在 LEB128 里没有意义（格式规范 §0 明确规定是无符号变长整数），
/// 传负数是调用方的 bug，不是数据的问题，所以这里不静默截断成 0 ——
/// 静默截断会让「-1 变成 0」这种错误一路走到磁盘上。
pub fn write_varint32(buf : Buffer, value : Int) -> Unit {
  let mut x = value
  while x >= 0x80 {
    // 续位 0x80 必须置上：它表示「后面还有字节」。
    // 少了它就是最典型的 varint bug —— 128 会被写成 `00 01`，
    // 解码端读到第一个字节没有续位就停下，得到 0。
    buf.write_byte(((x & 0x7F) | 0x80).to_byte())
    x = x >> 7
  }
  buf.write_byte(x.to_byte())
}

///|
/// 写 `varint64`。
pub fn write_varint64(buf : Buffer, value : UInt64) -> Unit {
  let mut x = value
  while x >= 0x80UL {
    buf.write_byte(((x & 0x7FUL) | 0x80UL).to_int().to_byte())
    x = x >> 7
  }
  buf.write_byte(x.to_int().to_byte())
}

///|
/// 写 4 字节小端定长整数（格式规范 §0：所有定长整数小端序）。
pub fn write_fixed32(buf : Buffer, value : Int) -> Unit {
  buf.write_byte(((value >> 0) & 0xFF).to_byte())
  buf.write_byte(((value >> 8) & 0xFF).to_byte())
  buf.write_byte(((value >> 16) & 0xFF).to_byte())
  buf.write_byte(((value >> 24) & 0xFF).to_byte())
}

///|
/// 写 8 字节小端定长整数。footer 的 offset / size / seq 都用它。
pub fn write_fixed64(buf : Buffer, value : UInt64) -> Unit {
  for i in 0..<8 {
    buf.write_byte(((value >> (i * 8)) & 0xFFUL).to_int().to_byte())
  }
}

///|
/// `varint32` 编码后的字节数。用于估算 block 大小，不做实际写入。
pub fn varint32_len(value : Int) -> Int {
  let mut n = 1
  let mut x = value >> 7
  while x > 0 {
    n = n + 1
    x = x >> 7
  }
  n
}

///|
/// 从 `data[pos..limit]` 读一个 `varint32`，返回 `(值, 新位置)`。
///
/// `limit` 是硬边界而不是 `data.length()`：调用方传入的是一段逻辑区域
/// （比如 data block 的 entry 区，后面还跟着 restart 数组），
/// 越过 `limit` 就等于读到了别的结构，必须当越界处理。
pub fn read_varint32(data : Bytes, pos : Int, limit : Int) -> (Int, Int)? {
  let mut i = pos
  let mut shift = 0
  let mut result = 0
  while i < limit && shift <= 28 {
    let b = data[i].to_int()
    // 第 5 字节（shift = 28）只剩 3 位有效，再高就是溢出 32 位有符号范围
    if shift == 28 && (b & 0x7F) > 0x07 {
      return None
    }
    result = result | ((b & 0x7F) << shift)
    i = i + 1
    if (b & 0x80) == 0 {
      return Some((result, i))
    }
    shift = shift + 7
  }
  None
}

///|
/// 从 `data[pos..limit]` 读一个 `varint64`，返回 `(值, 新位置)`。
pub fn read_varint64(data : Bytes, pos : Int, limit : Int) -> (UInt64, Int)? {
  let mut i = pos
  let mut shift = 0
  let mut result = 0UL
  while i < limit && shift < 64 {
    let b = data[i]
    let low = b.to_uint64() & 0x7FUL
    // 第 10 字节（shift = 63）只剩 1 位有效
    if shift == 63 && low > 0x01UL {
      return None
    }
    result = result | (low << shift)
    i = i + 1
    if (b.to_int() & 0x80) == 0 {
      return Some((result, i))
    }
    shift = shift + 7
  }
  None
}

///|
/// 从 `data[pos..]` 读 8 字节小端定长整数。
pub fn read_fixed64(data : Bytes, pos : Int) -> UInt64? {
  if pos < 0 || pos + 8 > data.length() {
    return None
  }
  let mut v = 0UL
  for i in 0..<8 {
    v = v | (data[pos + i].to_uint64() << (i * 8))
  }
  Some(v)
}

///|
/// 从 `data[pos..]` 读 4 字节小端定长整数。
/// 不做 `limit` 参数：定长读取的长度是已知的，越界判断用 `pos + 4 > length()` 就够。
pub fn read_fixed32(data : Bytes, pos : Int) -> Int? {
  if pos < 0 || pos + 4 > data.length() {
    return None
  }
  let b0 = data[pos].to_int()
  let b1 = data[pos + 1].to_int()
  let b2 = data[pos + 2].to_int()
  let b3 = data[pos + 3].to_int()
  Some(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
}
