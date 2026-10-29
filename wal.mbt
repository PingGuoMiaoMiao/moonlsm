///|
/// WAL（预写日志）的帧编码与恢复。
///
/// 磁盘布局见 `docs/design/format.md` §2：
/// ```
/// 文件头: [magic "MWAL":4][version:u16 LE][reserved:u16]
/// 帧:     [crc32c:4][length:varint32][type:1][payload:length]
/// payload:[seq:varint64][op:1][key:varint32+bytes][value:varint32+bytes]
/// ```
///
/// **这一层决定「崩溃后能不能启动」。** 所以它对坏数据的态度和别处相反：
/// 读到任何异常一律**停止重放并截断**，绝不抛错、绝不 panic（ADR-0003 不变量 I3）。
/// 理由很实际：一次断电在 WAL 尾部留下半条记录是**正常现象**，
/// 不是数据损坏。把它当错误处理，等于「断电一次就再也打不开数据库」。
///
/// 关键取舍：CRC 只覆盖 `type + payload`，不覆盖 `length` 字段。
/// 如果 `length` 被写坏，我们会因为「读不满 length 字节」而判定为尾部截断，
/// 行为同样是停止重放 —— 所以不必额外校验它，省 4 字节。
///
/// 和 `sstable.mbt` 一样，这一层只处理 `Bytes`，不碰文件系统。
/// 真正的 `write` / `fsync` / `ftruncate` 在边界层做。

///|
const WAL_MAGIC : Bytes = b"MWAL"

///|
pub const WAL_VERSION : Int32 = 1

///|
pub const WAL_HEADER_SIZE : Int32 = 8

///|
/// 单帧 payload 上限（64 MiB）。
///
/// 必须有这个上限：`length` 是磁盘上读来的，一个坏值（比如 0x7FFFFFFF）
/// 会让恢复过程尝试分配 2 GB 内存，直接 OOM。这不是理论风险，
/// 是「尾部有半条记录」时最容易踩到的一种表现。
pub const WAL_MAX_RECORD : Int32 = 64 * 1024 * 1024

///|
/// 帧类型：完整记录。`0x00` / `0x02` 保留给未来的分片首段/续段。
const FRAME_FULL : Int32 = 0x01

///|
/// payload 里的操作码。
const OP_PUT : Int32 = 0x00

///|
const OP_DELETE : Int32 = 0x01

///|
/// 写 WAL。当前产出的是完整文件字节，落盘由边界层负责。
pub struct WalWriter {
  out : Buffer
}

///|
/// 新建一个 WAL，写入 8 字节文件头。
pub fn WalWriter::new() -> WalWriter {
  let b = Buffer::Buffer()
  b.write_bytes(WAL_MAGIC[:])
  write_fixed16(b, WAL_VERSION)
  // reserved 全 0
  write_fixed16(b, 0)
  { out: b, }
}

///|
/// 已写入的字节数（含文件头）。
pub fn WalWriter::size(self : WalWriter) -> Int32 {
  self.out.length()
}

///|
/// 追加一条记录。一条逻辑记录 = 一帧，**不跨帧拆分**（ADR-0002）。
///
/// 不拆分意味着单条记录不能超过 `WAL_MAX_RECORD`。v1 接受这个限制：
/// 拆帧需要引入「首段/续段/尾段」三态和「重放中途又崩溃」的处理，
/// 复杂度换来的收益（支持 64 MiB 以上的单条写入）不成比例。
pub fn WalWriter::append(self : WalWriter, rec : WalRecord) -> Unit {
  let payload = Buffer::Buffer()
  write_varint64(payload, rec.seq)
  match rec.op {
    Put(k, v) => {
      payload.write_byte(OP_PUT.to_byte())
      write_varint32(payload, k.length())
      payload.write_bytes(k[:])
      write_varint32(payload, v.length())
      payload.write_bytes(v[:])
    }
    Delete(k) => {
      // 删除**整段省略 value**，不是写一个 0 长度 ——
      // 省字节，也让「Delete 帧比 Put 帧短」成为一个可断言的性质
      payload.write_byte(OP_DELETE.to_byte())
      write_varint32(payload, k.length())
      payload.write_bytes(k[:])
    }
  }
  let body_bytes = payload.to_bytes()
  // CRC 覆盖 type + payload，这样「type 被改坏」也能被发现
  let body = Buffer::Buffer()
  body.write_byte(FRAME_FULL.to_byte())
  body.write_bytes(body_bytes[:])
  let all = body.to_bytes()
  write_fixed32u(self.out, crc32c(all))
  write_varint32(self.out, body_bytes.length())
  self.out.write_bytes(all[:])
}

///|
/// 取出完整文件字节。
pub fn WalWriter::to_bytes(self : WalWriter) -> Bytes {
  self.out.to_bytes()
}

///|
/// 恢复结果。
pub struct WalReplay {
  records : Array[WalRecord]
  /// 最后一个**完整好帧**的结束位置。落盘层要 `ftruncate` 到这里。
  ///
  /// 为什么要截断而不是「忽略尾部坏数据继续用」：
  /// 下次追加会写在坏帧后面，那段坏字节永远留在文件中间，
  /// 以后每次恢复都会在同一处停下，后面的数据永远读不到。
  good_bytes : Int32
  /// 是否发现尾部损坏（需要截断）。
  truncated : Bool
  /// 文件头是否合法。false 表示这不是一个 WAL 文件。
  header_ok : Bool
}

///|
/// 记录条数。
pub fn WalReplay::len(self : WalReplay) -> Int32 {
  self.records.length()
}

///|
pub fn WalReplay::is_truncated(self : WalReplay) -> Bool {
  self.truncated
}

///|
pub fn WalReplay::header_ok(self : WalReplay) -> Bool {
  self.header_ok
}

///|
pub fn WalReplay::good_bytes(self : WalReplay) -> Int32 {
  self.good_bytes
}

///|
pub fn WalReplay::records(self : WalReplay) -> Array[WalRecord] {
  self.records
}

///|
/// 解一帧的 payload。任何结构不符都返回 `None`。
fn decode_payload(data : Bytes, start : Int32, len : Int32) -> WalRecord? {
  let end = start + len
  let (seq, p1) = match read_varint64(data, start, end) {
    Some(pair) => pair
    None => return None
  }
  if p1 >= end {
    return None
  }
  let op_byte = data[p1].to_int()
  let mut p = p1 + 1
  let (klen, p2) = match read_varint32(data, p, end) {
    Some(pair) => pair
    None => return None
  }
  p = p2
  if klen < 0 || p + klen > end {
    return None
  }
  let key = data[p:p + klen].to_owned()
  p = p + klen
  if op_byte == OP_PUT {
    let (vlen, p3) = match read_varint32(data, p, end) {
      Some(pair) => pair
      None => return None
    }
    p = p3
    if vlen < 0 || p + vlen > end {
      return None
    }
    let value = data[p:p + vlen].to_owned()
    p = p + vlen
    // payload 必须**正好**用完：多出字节说明声明长度和内容不一致
    if p != end {
      return None
    }
    Some(WalRecord::new(seq, Op::Put(key, value)))
  } else if op_byte == OP_DELETE {
    if p != end {
      return None
    }
    Some(WalRecord::new(seq, Op::Delete(key)))
  } else {
    None
  }
}

///|
/// 恢复 WAL。**永不抛错、永不 panic**，坏数据只会让重放提前结束。
///
/// 按 format.md §2.4 的顺序实现：读 crc → 读 length → 读 type+payload →
/// 校验 crc → 应用。任何一步失败就跳到 truncate。
pub fn recover_wal(data : Bytes) -> WalReplay {
  let records : Array[WalRecord] = []
  let n = data.length()
  if n < WAL_HEADER_SIZE {
    // 连文件头都没写全：不是 WAL，但也不必报错（可能是崩溃在初始化阶段）
    return { records, good_bytes: 0, truncated: n > 0, header_ok: false, }
  }
  if !bytes_match(data, 0, WAL_MAGIC) {
    return { records, good_bytes: 0, truncated: false, header_ok: false, }
  }
  let version = match read_fixed16(data, 4) {
    Some(v) => v
    None =>
      return { records, good_bytes: 0, truncated: false, header_ok: false, }
  }
  if version != WAL_VERSION {
    // 不认识的版本：拒绝重放，但也不猜。上层据此拒绝打开（§5.2）
    return { records, good_bytes: 0, truncated: false, header_ok: false, }
  }
  let mut pos = WAL_HEADER_SIZE
  let mut good = pos
  while true {
    if pos + 4 > n {
      break
    }
    let crc = match read_fixed32u(data, pos) {
      Some(v) => v
      None => break
    }
    let mut p = pos + 4
    let len = match read_varint32(data, p, n) {
      Some(pair) => pair
      None => break
    }
    let (payload_len, after_len) = len
    p = after_len
    if payload_len < 0 || payload_len > WAL_MAX_RECORD {
      break
    }
    // type(1) + payload(len) 必须都还在文件里
    if p + 1 + payload_len > n {
      break
    }
    if data[p].to_int() != FRAME_FULL {
      break
    }
    let body = data[p:p + 1 + payload_len]
    if crc32c(body.to_owned()) != crc {
      // CRC 不匹配一律视为尾部损坏，不报错、不 panic（ADR-0003）
      break
    }
    let rec = match decode_payload(data, p + 1, payload_len) {
      Some(r) => r
      None => break
    }
    records.push(rec)
    pos = p + 1 + payload_len
    good = pos
  }
  { records, good_bytes: good, truncated: good < n, header_ok: true, }
}

///|
/// 把重放结果灌进 memtable，只应用 `seq > min_seq` 的记录。
///
/// `min_seq` 来自 MANIFEST 的 `last_seq`：WAL 里可能有已经刷进 SST 的记录，
/// 重复应用不会错（值一样），但会浪费内存、也会让 `seq` 判断变复杂。
/// 返回实际应用的条数。
pub fn WalReplay::replay_into(
  self : WalReplay,
  mem : MemTable,
  min_seq : UInt64,
) -> Int32 {
  let mut applied = 0
  for rec in self.records {
    if rec.seq > min_seq {
      mem.apply(rec)
      applied = applied + 1
    }
  }
  applied
}

///|
/// 编码**单帧**，不含 8 字节文件头。
///
/// 追加写 WAL 时用：文件头只在创建时写一次，之后的每一次 `put` 都只是
/// 往文件尾追加一帧。如果每次都调 `WalWriter::new()` 再整体写出，
/// 文件头会被反复追加，恢复时第一帧就会解错。
pub fn encode_frame(rec : WalRecord) -> Bytes {
  let w = WalWriter::new()
  w.append(rec)
  let all = w.to_bytes()
  let out = Buffer::Buffer()
  out.write_bytes(all[WAL_HEADER_SIZE:])
  out.to_bytes()
}

///|
/// 空 WAL 的文件字节（只有文件头）。创建新 WAL 时用。
pub fn empty_wal_bytes() -> Bytes {
  WalWriter::new().to_bytes()
}
