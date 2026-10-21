///|
/// CRC32C（Castagnoli）校验和。
///
/// 为什么是 CRC32C 而不是 CRC32：它有硬件指令（x86 SSE4.2 的 `crc32`、
/// ARMv8 的 `crc32c`），吞吐是软件 CRC32 的 5–10 倍，而 WAL 是热路径。
/// LevelDB / RocksDB / Go 标准库也都选它（见 format.md §0.1）。
///
/// 多项式 `0x1EDC6F41`，反射形式 `0x82F63B78`。
///
/// **实现用查表法**：逐位算法每次要循环 8 轮，热路径上慢一个数量级。
/// 表在模块初始化时构建一次（256 项），之后每次校验只做
/// 「异或 + 查表 + 移位」三步。
///
/// 状态用 `UInt64` 而不是 `Int`：`Int` 是 32 位有符号，
/// `0xFFFFFFFF` 这个掩码在 `Int` 里根本写不出来（超出正数范围），
/// 用它做位运算会绕进符号位。`UInt64` 干净得多，代价可以忽略。

///|
/// 反射多项式。命名带 `_POLY` 后缀是为了和「查表用的数组」区分开。
const CRC32C_POLY : UInt64 = 0x82F63B78UL

///|
/// 构建 256 项查表。只在模块初始化时跑一次。
fn build_crc32c_table() -> Array[UInt64] {
  let table : Array[UInt64] = []
  for i in 0..<256 {
    let mut c = i.to_uint64()
    for _ in 0..<8 {
      if (c & 1UL) != 0UL {
        c = (c >> 1) ^ CRC32C_POLY
      } else {
        c = c >> 1
      }
    }
    table.push(c & 0xFFFFFFFFUL)
  }
  table
}

///|
/// 查表。顶层 `let` 会在模块初始化时执行一次 `build_crc32c_table()`。
let crc32c_table : Array[UInt64] = build_crc32c_table()

///|
/// 计算一段字节的 CRC32C，返回值在 `[0, 0xFFFFFFFF]` 范围内。
///
/// 标准校验向量：`crc32c("123456789") == 0xE3069283`，
/// `crc32c("") == 0`。这两条在测试里硬编码断言 —— 它们是
/// 「我的实现和别人能互通」的唯一证据。
pub fn crc32c(data : Bytes) -> UInt64 {
  let table = crc32c_table
  let mut c = 0xFFFFFFFFUL
  for i in 0..<data.length() {
    let idx = ((c ^ data[i].to_uint64()) & 0xFFUL).to_int()
    c = (c >> 8) ^ table[idx]
  }
  (c ^ 0xFFFFFFFFUL) & 0xFFFFFFFFUL
}
