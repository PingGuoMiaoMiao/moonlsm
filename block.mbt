///|
/// data block 的编码与解码：前缀压缩 + restart point。
///
/// 磁盘布局见 `docs/design/format.md` §3.2：
/// ```
/// entry: [type:1][seq:varint64][shared:v32][non_shared:v32][value_len:v32][key_delta][value]
/// 尾部:  [restart_offset:u32 LE] * n  [num_restarts:u32 LE]  [crc32c:u32 LE]
/// ```
///
/// 末尾 4 字节 CRC 是**格式版本 2** 引入的（ADR-0010）。版本 1 的 block
/// 没有这个字段，靠 `decode_block_v1` 读 —— 升级不能炸掉老库。
///
/// **为什么值得做前缀压缩**：SST 里的 key 通常高度相似（`user:1000`、
/// `user:1001`……），前缀压缩能把 key 部分压掉一半以上。而 restart point
/// 是为了让「二分查找」成为可能 —— 压缩后第 i 条不能独立解码，
/// 必须先解第 i-1 条；每 16 条插一个「完整 key」的锚点，
/// 查找时最多只解码 16 条。这是空间与查找速度的经典折中。

///|
/// 每 16 条 entry 一个 restart point（格式规范 §3.2，与 LevelDB 一致）。
const RESTART_INTERVAL : Int32 = 16

///|
/// data block 的目标大小。超过它就切下一块（切点必须落在 entry 边界）。
/// 4 KiB 是 LevelDB / RocksDB 的默认值，也是「一次读放大」与
/// 「索引条目数」之间的平衡点。
pub const BLOCK_TARGET_SIZE : Int32 = 4096

///|
/// block 尾部 CRC 的长度（v2 起）。校验范围是**它之前的所有字节** ——
/// entry 区、restart 数组、`num_restarts` 全在里面。
///
/// 只保护 entry 区是不够的：`num_restarts` 被改成一个仍然能通过边界检查的值时，
/// 读端会把 entry 区当 restart 数组读，得到一个「结构合法但内容错乱」的 block。
pub const BLOCK_CRC_SIZE : Int32 = 4

///|
/// 解码过程中间态：比 `Entry` 多一个 `next`，
/// 因为解码是流式的，必须知道下一条从哪开始。
/// 不直接复用 `Entry` 是因为 `Entry` 是对外契约，不该混进游标信息。
priv struct DecodedEntry {
  key : Bytes
  value : Bytes
  seq : UInt64
  deleted : Bool
  next : Int32
}

///|
/// 两个 Bytes 的公共前缀长度。
fn common_prefix_len(a : Bytes, b : Bytes) -> Int32 {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  let mut i = 0
  while i < n && a[i] == b[i] {
    i = i + 1
  }
  i
}

///|
/// 按 key 升序逐条追加，最后 `finish()` 出完整 block 字节。
///
/// 使用契约：`add` 的 key 必须**严格升序**。违反会直接抛 `Corruption`，
/// 而不是静默写出一个坏 block —— 排序错了说明上层归并逻辑有 bug，
/// 让它早点炸比让它写进磁盘好。
pub struct BlockBuilder {
  mut buf : Buffer
  mut restarts : Array[Int32]
  mut counter : Int32
  mut last_key : Bytes
  mut count : Int32
}

///|
/// 新建一个空 block。初始就带一个 restart 点 0，
/// 保证第一个 entry 一定可以独立解码。
pub fn BlockBuilder::new() -> BlockBuilder {
  { buf: Buffer::Buffer(), restarts: [0], counter: 0, last_key: b"", count: 0, }
}

///|
/// 已追加的条目数。
pub fn BlockBuilder::entry_count(self : BlockBuilder) -> Int32 {
  self.count
}

///|
/// 最后一条的 key（也就是这个 block 的最大 key）。
/// SST 写索引时需要它作为 `last_key`；空 block 返回空 key。
pub fn BlockBuilder::last_key(self : BlockBuilder) -> Bytes {
  self.last_key
}

///|
/// 是否一条都没写。
pub fn BlockBuilder::is_empty(self : BlockBuilder) -> Bool {
  self.count == 0
}

///|
/// 估算编码后的字节数（含 restart 数组、计数与 CRC），用于判断是否该切块。
/// 估算而不是精确值：restart 数组长度依赖 counter，这里按当前状态算，
/// 差几个字节不影响「是否超过 4 KiB」的判断。
pub fn BlockBuilder::estimated_size(self : BlockBuilder) -> Int32 {
  self.buf.length() + self.restarts.length() * 4 + 8
}

///|
/// 是否已经达到切块阈值。
pub fn BlockBuilder::should_finish(self : BlockBuilder) -> Bool {
  self.estimated_size() >= BLOCK_TARGET_SIZE
}

///|
/// 追加一条。key 必须严格大于上一条。
pub fn BlockBuilder::add(
  self : BlockBuilder,
  entry : Entry,
) -> Unit raise LsmError {
  if self.count > 0 && compare_bytes(self.last_key, entry.key) >= 0 {
    raise LsmError::corruption(
      "block: key 必须严格升序，上一条不小于本条（说明上层排序有 bug）",
    )
  }
  let shared = if self.counter < RESTART_INTERVAL {
    common_prefix_len(self.last_key, entry.key)
  } else {
    // 达到间隔：这条成为新的 restart 点，前缀必须从零开始
    self.restarts.push(self.buf.length())
    self.counter = 0
    0
  }
  self.counter = self.counter + 1
  self.buf.write_byte((if entry.deleted { 1 } else { 0 }).to_byte())
  write_varint64(self.buf, entry.seq)
  write_varint32(self.buf, shared)
  write_varint32(self.buf, entry.key.length() - shared)
  write_varint32(self.buf, entry.value.length())
  self.buf.write_bytes(entry.key[shared:])
  self.buf.write_bytes(entry.value[:])
  self.last_key = entry.key
  self.count = self.count + 1
}

///|
/// 产出完整 block 字节（entry 区 + restart 数组 + 计数 + CRC）。
///
/// 每次调用都基于当前状态重新拼装，**不修改 builder 自身**，
/// 所以可以在不 `reset` 的情况下多次调用（拿到的内容相同）。
pub fn BlockBuilder::finish(self : BlockBuilder) -> Bytes {
  self.assemble(true)
}

///|
/// 产出**格式版本 1** 的 block 字节（没有尾部 CRC）。
///
/// 存在的唯一理由是兼容性测试：要证明「读到 v1 的老文件仍然能正确打开」，
/// 就必须能造出 v1 的字节。生产路径永远不会调用它 ——
/// `SstWriter` 写的一律是 v2。
fn BlockBuilder::finish_v1(self : BlockBuilder) -> Bytes {
  self.assemble(false)
}

///|
/// 拼装 block。`with_crc` 决定尾部是否带 CRC。
///
/// CRC 覆盖「拼装到 CRC 之前」的全部字节，而不是只覆盖 entry 区：
/// restart 数组与 `num_restarts` 同样是读端解析的依据，
/// 它们坏掉一样会让解码器读到错位置。
fn BlockBuilder::assemble(self : BlockBuilder, with_crc : Bool) -> Bytes {
  let body = Buffer::Buffer()
  body.write_bytes(self.buf.to_bytes()[:])
  for i in 0..<self.restarts.length() {
    write_fixed32(body, self.restarts[i])
  }
  write_fixed32(body, self.restarts.length())
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
/// 清空，复用同一个 builder 写下一个 block。
pub fn BlockBuilder::reset(self : BlockBuilder) -> Unit {
  self.buf = Buffer::Buffer()
  self.restarts = [0]
  self.counter = 0
  self.last_key = b""
  self.count = 0
}

///|
/// 一个已编码的 block。持有原始字节，按需解码。
pub struct Block {
  data : Bytes
  restarts : Array[Int32]
  /// entry 区的结束位置，也就是 restart 数组的起点。
  /// 所有解码都必须以它为硬边界，否则会把 restart 数组当 entry 读。
  limit : Int32
}

///|
/// 解析一个**格式版本 2** 的 block：先校验尾部 CRC，再解析结构。
///
/// 校验顺序是「CRC 在前，结构在后」，因为 CRC 是唯一的**内容**校验。
/// 先跑结构检查会让「结构碰巧仍然合法、内容已经错了」的损坏漏过去 ——
/// 那正是没有 CRC 时 58% 的静默接受是怎么来的。
///
/// 返回 `None` 的两种情形（CRC 不符 / 结构不合法）在读端是同一个后果：
/// 这个 block 不可信。调用方一律当损坏处理，不去猜。
pub fn decode_block(raw : Bytes) -> Block? {
  let n = raw.length()
  if n < BLOCK_CRC_SIZE + 4 {
    return None
  }
  let body_len = n - BLOCK_CRC_SIZE
  let want = match read_fixed32u(raw, body_len) {
    Some(v) => v
    None => return None
  }
  if crc32c(raw[:body_len].to_owned()) != want {
    return None
  }
  parse_block(raw, body_len)
}

///|
/// 解析一个**格式版本 1** 的 block（尾部没有 CRC，只有 `num_restarts`）。
///
/// 只在读 v1 文件时走这条路（ADR-0010）。它**不做任何内容校验** ——
/// 这正是 v1 的已知短板，保留它是为了能读老库，不是为了继续用。
pub fn decode_block_v1(raw : Bytes) -> Block? {
  parse_block(raw, raw.length())
}

///|
/// 结构解析：`end` 指向「`num_restarts` 字段结束」的位置。
/// v2 传 `n - 4`（跳过 CRC），v1 传 `n`。
///
/// 注意这里**只校验结构，不校验内容** —— entry 区的内容是惰性解码的，
/// 只有真正访问到坏 entry 时才会暴露。这是有意的：
/// 全量预解码会让「读一个 key」退化成「扫整个 block」，
/// 而 LSM 的读路径最忌讳这个。
/// v2 之所以还敢这么懒，是因为 CRC 已经在入口处把「内容被改坏」拦掉了。
fn parse_block(raw : Bytes, end : Int32) -> Block? {
  if end < 4 {
    return None
  }
  let num_restarts = match read_fixed32(raw, end - 4) {
    Some(v) => v
    None => return None
  }
  // 至少要有 1 个 restart，且 restart 数组不能吃掉整个 block
  if num_restarts < 1 {
    return None
  }
  let restarts_start = end - 4 - num_restarts * 4
  if restarts_start < 0 {
    return None
  }
  let restarts : Array[Int32] = []
  for i in 0..<num_restarts {
    let off = match read_fixed32(raw, restarts_start + i * 4) {
      Some(v) => v
      None => return None
    }
    if off < 0 || off > restarts_start {
      return None
    }
    restarts.push(off)
  }
  Some({ data: raw, restarts, limit: restarts_start, })
}

///|
/// restart 点个数。
pub fn Block::num_restarts(self : Block) -> Int32 {
  self.restarts.length()
}

///|
/// 从 `pos` 解一条 entry。`prev_key` 是上一条的完整 key（restart 点传 `b""`）。
///
/// 所有长度字段都做上界检查后再切片，避免越界 panic ——
/// 这条路径上输入来自磁盘，必须假设它是恶意的或损坏的。
fn Block::read_entry_at(
  self : Block,
  pos : Int32,
  prev_key : Bytes,
) -> DecodedEntry? {
  if pos < 0 || pos >= self.limit {
    return None
  }
  let ty = self.data[pos].to_int()
  if ty > 1 {
    return None
  }
  let mut p = pos + 1
  let seq = match read_varint64(self.data, p, self.limit) {
    Some((v, np)) => {
      p = np
      v
    }
    None => return None
  }
  let shared = match read_varint32(self.data, p, self.limit) {
    Some((v, np)) => {
      p = np
      v
    }
    None => return None
  }
  let non_shared = match read_varint32(self.data, p, self.limit) {
    Some((v, np)) => {
      p = np
      v
    }
    None => return None
  }
  let value_len = match read_varint32(self.data, p, self.limit) {
    Some((v, np)) => {
      p = np
      v
    }
    None => return None
  }
  // shared 不能超过上一个 key 的长度：超过了说明「要复制的前缀比源还长」
  if shared > prev_key.length() {
    return None
  }
  // 用「剩余长度」做减法而不是相加后比较，避免 Int 溢出
  let rest = self.limit - p
  if non_shared > rest || value_len > rest - non_shared {
    return None
  }
  let end = p + non_shared + value_len
  let key = if shared == 0 {
    self.data[p:p + non_shared].to_owned()
  } else {
    // 只复制 prev_key 的**前 shared 个字节**。写成 prev_key[:] 是这里
    // 最容易犯的错 —— 那样会把整个上一条 key 当公共前缀，解出来的 key 变长。
    let k = Buffer::Buffer()
    k.write_bytes(prev_key[:shared])
    k.write_bytes(self.data[p:p + non_shared])
    k.to_bytes()
  }
  Some({
    key,
    value: self.data[p + non_shared:end].to_owned(),
    seq,
    deleted: ty == 1,
    next: end,
  })
}

///|
/// 解出全部条目（按 key 升序）。用于全扫描、校验和测试。
///
/// 生产读路径**不该**走这里 —— 它会把整个 block 解完。
/// 单 key 查询请用 `get`。
pub fn Block::entries(self : Block) -> Array[Entry] raise LsmError {
  let out : Array[Entry] = []
  let mut pos = 0
  let mut prev : Bytes = b""
  while pos < self.limit {
    let e = match self.read_entry_at(pos, prev) {
      Some(e) => e
      None =>
        raise LsmError::corruption("block: entry 解码失败，偏移 \{pos}")
    }
    out.push({ key: e.key, value: e.value, seq: e.seq, deleted: e.deleted, })
    prev = e.key
    pos = e.next
  }
  out
}

///|
/// 取第 `idx` 个 restart 点的首 key。
/// restart 点的 `shared` 恒为 0，所以可以用空 key 作为 `prev_key`。
fn Block::restart_first_key(self : Block, idx : Int32) -> Bytes? {
  if idx < 0 || idx >= self.restarts.length() {
    return None
  }
  match self.read_entry_at(self.restarts[idx], b"") {
    Some(e) => Some(e.key)
    None => None
  }
}

///|
/// 二分定位：返回「最后一个首 key ≤ target」的 restart 点下标。
///
/// `get` 与 `seek` 共用这一段。**故意抽出来**：这是整个 block 里
/// 唯一一处二分逻辑，写两份的话，某天只改了其中一份就会得到
/// 「精确查找对、下界查找错」这种极难发现的偏差。
fn Block::restart_index_for(self : Block, target : Bytes) -> Int32? {
  let n = self.restarts.length()
  if n == 0 {
    return None
  }
  let mut lo = 0
  let mut hi = n - 1
  while lo < hi {
    let mid = (lo + hi + 1) / 2
    let mid_key = match self.restart_first_key(mid) {
      Some(k) => k
      None => return None
    }
    if compare_bytes(mid_key, target) <= 0 {
      lo = mid
    } else {
      hi = mid - 1
    }
  }
  Some(lo)
}

///|
/// 按 key 精确查找。
///
/// 两步：先在 restart 数组上二分（找最后一个首 key ≤ 目标的 restart 点），
/// 再从那里线性扫到下一个 restart 点。最坏解 16 条 entry。
///
/// 返回墓碑条目（`deleted = true`）时**不要当命中处理**——
/// 调用方必须看 `deleted` 字段，否则删除会失效。
pub fn Block::get(self : Block, key : Bytes) -> Entry? {
  let start = match self.restart_index_for(key) {
    Some(i) => i
    None => return None
  }
  let mut pos = self.restarts[start]
  let mut prev : Bytes = b""
  while pos < self.limit {
    let e = match self.read_entry_at(pos, prev) {
      Some(e) => e
      None => return None
    }
    let c = compare_bytes(e.key, key)
    if c == 0 {
      return Some({
        key: e.key,
        value: e.value,
        seq: e.seq,
        deleted: e.deleted,
      })
    }
    if c > 0 {
      // key 已经越过目标，后面只会更大
      return None
    }
    prev = e.key
    pos = e.next
  }
  None
}

///|
/// 下界查找：返回第一个 `key >= target` 的条目。
///
/// 这是 index block 需要的语义 —— 索引里存的是每个 data block 的
/// **最大 key**，找「第一个 ≥ 目标的 last_key」就等于找到「可能包含目标的块」。
/// 也用于 scan 的起始定位。
///
/// 与 `get` 的区别只在终点判断：`get` 遇到更大的 key 就返回 `None`，
/// `seek` 则把它返回出去。
pub fn Block::seek(self : Block, target : Bytes) -> Entry? {
  let start = match self.restart_index_for(target) {
    Some(i) => i
    None => return None
  }
  let mut pos = self.restarts[start]
  let mut prev : Bytes = b""
  while pos < self.limit {
    let e = match self.read_entry_at(pos, prev) {
      Some(e) => e
      None => return None
    }
    if compare_bytes(e.key, target) >= 0 {
      return Some({
        key: e.key,
        value: e.value,
        seq: e.seq,
        deleted: e.deleted,
      })
    }
    prev = e.key
    pos = e.next
  }
  None
}

///|
/// 最后一条 entry。空 block 返回 `None`。
///
/// 用于「文件的最大 key」这个边界：index 里存的是每块的 `last_key`，
/// 所以最后一个 index 条目的 key 就是整个文件的最大 key，
/// 但要拿到它就得能取 block 的最后一条 —— `seek` 做不到这件事
/// （key 是任意二进制，没有「比所有 key 都大」的哨兵值可传）。
pub fn Block::last(self : Block) -> Entry? {
  let n = self.restarts.length()
  if n == 0 {
    return None
  }
  // 从最后一个 restart 点开始走到底：restart 点的 entry 是完整 key，
  // 之后各条是前缀压缩的，必须逐条解出 prev_key。
  let mut pos = self.restarts[n - 1]
  let mut prev : Bytes = b""
  let mut found : Entry? = None
  while pos < self.limit {
    let e = match self.read_entry_at(pos, prev) {
      Some(e) => e
      None => return found
    }
    found = Some({ key: e.key, value: e.value, seq: e.seq, deleted: e.deleted, })
    prev = e.key
    pos = e.next
  }
  found
}

///|
/// 第一条 entry。空 block 返回 `None`。
///
/// 与 `seek(b"")` 的区别：`seek` 要跑一次 `restart_index_for` 的二分，
/// 而「第一条」根本不需要比较 —— 直接从第一个 restart 点解即可。
pub fn Block::first(self : Block) -> Entry? {
  if self.restarts.length() == 0 {
    return None
  }
  match self.read_entry_at(self.restarts[0], b"") {
    Some(e) =>
      Some({ key: e.key, value: e.value, seq: e.seq, deleted: e.deleted, })
    None => None
  }
}
