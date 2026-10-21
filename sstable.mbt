///|
/// SSTable 的写入与读取：`data block* | filter block | index block | footer(48)`
///
/// 磁盘布局见 `docs/design/format.md` §3.1。
///
/// **这一层只处理 `Bytes`，不碰文件系统。** 这不是偷懒，是有意的分层：
/// - 核心（memtable / block / sstable）保持 backend 无关，
///   CI 会在 wasm-gc / js 上编译它，证明没有偷偷依赖 native 特性
/// - 文件 IO 放在边界层（`fs` / dbcli），换平台或换存储介质只改那一层
/// - 测试不需要临时目录、不需要清理、不会因为 Windows 文件锁而随机失败
///
/// 代价是一次性把整个 SST 放进内存。对 v1 的规模（几十 MB）可以接受，
/// 后面引入 mmap 或分块读时，只需替换 `SstReader` 的取字节方式。

///|
/// footer 固定 48 字节（§3.5）。
pub const SST_FOOTER_SIZE : Int = 48

///|
/// 当前支持的 SST 版本。读到更大的版本必须拒绝打开（§5.2）。
pub const SST_VERSION : Int = 1

///|
/// 文件末尾的魔数 `"MSST"`。
const SST_MAGIC : Bytes = b"MSST"

///|
/// 解析出来的 footer。
pub struct SstFooter {
  filter_offset : Int
  filter_size : Int
  index_offset : Int
  index_size : Int
  smallest_seq : UInt64
  version : Int
}

///|
/// 比较 `data[pos..]` 处的若干字节是否等于 `want`。
fn bytes_match(data : Bytes, pos : Int, want : Bytes) -> Bool {
  if pos < 0 || pos + want.length() > data.length() {
    return false
  }
  for i in 0..<want.length() {
    if data[pos + i] != want[i] {
      return false
    }
  }
  true
}

///|
/// 读一个 u64 偏移并降级成 `Int`。
/// 超过 `Int` 能表示的范围就判定为损坏 —— 宁可拒绝打开，
/// 也不要截断成一个看似合理的小偏移去读错位置。
fn read_offset(data : Bytes, pos : Int) -> Int? {
  match read_fixed64(data, pos) {
    Some(v) => if v > 0x7FFFFFFFUL { None } else { Some(v.to_int()) }
    None => None
  }
}

///|
/// 解码索引条目里的 block handle：`offset(varint64) + size(varint64)`。
fn decode_handle(v : Bytes) -> (Int, Int)? {
  let (off, p1) = match read_varint64(v, 0, v.length()) {
    Some(pair) => pair
    None => return None
  }
  let (size, _) = match read_varint64(v, p1, v.length()) {
    Some(pair) => pair
    None => return None
  }
  if off > 0x7FFFFFFFUL || size > 0x7FFFFFFFUL {
    return None
  }
  Some((off.to_int(), size.to_int()))
}

///|
/// 编码一个 block handle。
fn encode_handle(offset : Int, size : Int) -> Bytes {
  let b = Buffer::Buffer()
  write_varint64(b, offset.to_uint64())
  write_varint64(b, size.to_uint64())
  b.to_bytes()
}

///|
/// 逐条追加、最后 `finish()` 出整个 SST 字节。
///
/// 使用契约：`add` 的 key 必须**严格升序**（与 `BlockBuilder` 一致）。
/// SST 内部按 key 有序，这是「二分查 index」和「归并 compaction」的前提。
///
/// **已知取舍**：`keys` 把所有 key 留在内存里，因为 bloom 需要在
/// `finish` 时知道元素个数才能定位图大小。1 万条 × 10 字节 = 100 KB，
/// 可以接受；到百万级需要改成「两遍写」或「可增长的 bloom」。
/// 这条记在 `PLAN.md` 的技术债里，不是忘了。
pub struct SstWriter {
  out : Buffer
  block : BlockBuilder
  index : BlockBuilder
  mut count : Int
  mut block_count : Int
  mut smallest_seq : UInt64
  keys : Array[Bytes]
}

///|
pub fn SstWriter::new() -> SstWriter {
  {
    out: Buffer::Buffer(),
    block: BlockBuilder::new(),
    index: BlockBuilder::new(),
    count: 0,
    block_count: 0,
    smallest_seq: 0xFFFFFFFFFFFFFFFFUL,
    keys: [],
  }
}

///|
/// 已写入的条目数。
pub fn SstWriter::entry_count(self : SstWriter) -> Int {
  self.count
}

///|
/// 已封盘的 data block 数。
pub fn SstWriter::block_count(self : SstWriter) -> Int {
  self.block_count
}

///|
/// 追加一条。key 必须严格大于上一条。
pub fn SstWriter::add(self : SstWriter, entry : Entry) -> Unit raise LsmError {
  self.block.add(entry)
  self.keys.push(entry.key)
  self.count = self.count + 1
  if entry.seq < self.smallest_seq {
    self.smallest_seq = entry.seq
  }
  if self.block.should_finish() {
    self.flush_block()
  }
}

///|
/// 把当前 block 落进 `out`，并在索引里记一条 `last_key -> (offset, size)`。
fn SstWriter::flush_block(self : SstWriter) -> Unit raise LsmError {
  if self.block.is_empty() {
    return
  }
  let raw = self.block.finish()
  let offset = self.out.length()
  self.out.write_bytes(raw[:])
  // 注意顺序：last_key 必须在 reset 之前取
  self.index.add({
    key: self.block.last_key(),
    value: encode_handle(offset, raw.length()),
    seq: 0UL,
    deleted: false,
  })
  self.block.reset()
  self.block_count = self.block_count + 1
}

///|
/// 产出完整 SST 字节。
///
/// 顺序严格按 §3.1：data blocks → filter → index → footer。
/// filter 要等所有 key 都写完才能建（需要知道元素个数来定位图大小），
/// 所以它只能在 `finish` 里生成。
pub fn SstWriter::finish(self : SstWriter) -> Bytes raise LsmError {
  self.flush_block()
  let bloom = BloomFilter::new(self.keys.length())
  for k in self.keys {
    bloom.put(k)
  }
  let filter = bloom.encode()
  let filter_offset = self.out.length()
  self.out.write_bytes(filter[:])
  let index_raw = self.index.finish()
  let index_offset = self.out.length()
  self.out.write_bytes(index_raw[:])
  write_fixed64(self.out, filter_offset.to_uint64())
  write_fixed64(self.out, filter.length().to_uint64())
  write_fixed64(self.out, index_offset.to_uint64())
  write_fixed64(self.out, index_raw.length().to_uint64())
  // 空 SST 没有 seq，写 0 而不是 0xFFFF...，避免读端把「未初始化」当真实值
  write_fixed64(self.out, if self.count == 0 { 0UL } else { self.smallest_seq })
  write_fixed32(self.out, SST_VERSION)
  self.out.write_bytes(SST_MAGIC[:])
  self.out.to_bytes()
}

///|
/// 一个已打开的 SST。持有整个文件字节与解析好的 index / filter。
pub struct SstReader {
  data : Bytes
  footer : SstFooter
  index : Block
  bloom : BloomFilter
}

///|
/// 打开一个 SST。任何结构性问题返回 `None`，不 panic。
///
/// 校验顺序刻意从「最便宜、最能早退」开始：长度 → magic → version → 区域边界。
/// 先查 magic 再查 offset 很重要 —— 如果文件根本不是 SST，
/// 那些 offset 是垃圾值，拿它们做边界检查只是白算。
pub fn open_sst(data : Bytes) -> SstReader? {
  let n = data.length()
  if n < SST_FOOTER_SIZE {
    return None
  }
  let f = n - SST_FOOTER_SIZE
  if !bytes_match(data, f + 44, SST_MAGIC) {
    return None
  }
  let version = match read_fixed32(data, f + 40) {
    Some(v) => v
    None => return None
  }
  if version != SST_VERSION {
    // §5.2：读到不认识的版本必须拒绝打开，绝不猜怎么读
    return None
  }
  let filter_offset = match read_offset(data, f) {
    Some(v) => v
    None => return None
  }
  let filter_size = match read_offset(data, f + 8) {
    Some(v) => v
    None => return None
  }
  let index_offset = match read_offset(data, f + 16) {
    Some(v) => v
    None => return None
  }
  let index_size = match read_offset(data, f + 24) {
    Some(v) => v
    None => return None
  }
  let smallest_seq = match read_fixed64(data, f + 32) {
    Some(v) => v
    None => return None
  }
  // 两个区域都必须完整落在 footer 之前，且 filter 在 index 之前
  if filter_offset + filter_size > f || index_offset + index_size > f {
    return None
  }
  if index_offset < filter_offset + filter_size {
    return None
  }
  let filter_raw = data[filter_offset:filter_offset + filter_size].to_owned()
  let bloom = match decode_bloom(filter_raw) {
    Some(b) => b
    None => return None
  }
  let index_raw = data[index_offset:index_offset + index_size].to_owned()
  let index = match decode_block(index_raw) {
    Some(b) => b
    None => return None
  }
  Some({
    data,
    footer: {
      filter_offset,
      filter_size,
      index_offset,
      index_size,
      smallest_seq,
      version,
    },
    index,
    bloom,
  })
}

///|
pub fn SstReader::footer(self : SstReader) -> SstFooter {
  self.footer
}

///|
/// data block 个数（等于索引条目数）。
pub fn SstReader::block_count(self : SstReader) -> Int raise LsmError {
  self.index.entries().length()
}

///|
/// 按 key 查找。命中墓碑时返回 `deleted = true` 的条目，
/// **调用方必须自己判断**（上层要知道「这里有一个删除」，而不是「查不到」）。
///
/// 三步：bloom 快速否定 → index 定位 block → block 内二分。
pub fn SstReader::get(self : SstReader, key : Bytes) -> Entry? {
  if !self.bloom.may_contain(key) {
    return None
  }
  let idx = match self.index.seek(key) {
    Some(e) => e
    None => return None
  }
  let (off, size) = match decode_handle(idx.value) {
    Some(p) => p
    None => return None
  }
  if off + size > self.data.length() {
    return None
  }
  let blk = match decode_block(self.data[off:off + size].to_owned()) {
    Some(b) => b
    None => return None
  }
  blk.get(key)
}

///|
/// 按 key 顺序解出全部条目。用于全扫描、校验与测试。
pub fn SstReader::entries(self : SstReader) -> Array[Entry] raise LsmError {
  let out : Array[Entry] = []
  for ie in self.index.entries() {
    let (off, size) = match decode_handle(ie.value) {
      Some(p) => p
      None =>
        raise LsmError::corruption(
          "sst: 索引条目里的 block handle 解码失败",
        )
    }
    if off + size > self.data.length() {
      raise LsmError::corruption("sst: data block 越界")
    }
    let blk = match decode_block(self.data[off:off + size].to_owned()) {
      Some(b) => b
      None => raise LsmError::corruption("sst: data block 解码失败")
    }
    for e in blk.entries() {
      out.push(e)
    }
  }
  out
}

///|
/// 只解出 `[start, end)` 区间里的条目，顺序与 `entries()` 一致。
///
/// **这是 `scan` 的性能关键。** `entries()` 会把整个文件解出来 ——
/// 一个 1 MiB 的 SST 大约 1 万条，扫 500 条也要付 1 万条的解码成本。
/// 数据量一大，`scan` 就退化成 O(整个库)，而调用方往往只要一小段。
///
/// 做法是拿索引做**块级剪枝**：索引里每条记录的是该 block 的 `last_key`，
/// 于是
///
/// - 二分找到第一个 `last_key >= start` 的 block —— 它之前的所有 block
///   最大 key 都小于 start，整块可以跳过
/// - 往后逐块解，块内逐条过滤（只有首尾两块可能部分越界）
/// - 遇到 `last_key >= end` 的 block，解完它就停 —— block 之间按 key
///   严格递增，后面每一块的 first_key 都更大，必然全部越界
///
/// 块内过滤而不是块内二分：一个 block 只有 4 KiB / 一百多条，
/// 解出来再线性筛比再写一套「块内定位 + 向后遍历」简单得多，
/// 而且这部分成本与块大小同阶，不是瓶颈。
///
/// **不接 `limit`**：单看一个文件，无法判断「前 N 条」是不是全局的前 N 条
/// （多路归并要跨文件比较）。限制由调用方在归并之后施加。
pub fn SstReader::scan_range(
  self : SstReader,
  start : Bytes,
  end : Bytes,
) -> Array[Entry] raise LsmError {
  let out : Array[Entry] = []
  let ies = self.index.entries()
  // 二分：第一个 last_key >= start 的 block
  let mut lo = 0
  let mut hi = ies.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    if compare_bytes(ies[mid].key, start) < 0 {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  let mut i = lo
  while i < ies.length() {
    let ie = ies[i]
    let (off, size) = match decode_handle(ie.value) {
      Some(p) => p
      None =>
        raise LsmError::corruption(
          "sst: 索引条目里的 block handle 解码失败",
        )
    }
    if off + size > self.data.length() {
      raise LsmError::corruption("sst: data block 越界")
    }
    let blk = match decode_block(self.data[off:off + size].to_owned()) {
      Some(b) => b
      None => raise LsmError::corruption("sst: data block 解码失败")
    }
    for e in blk.entries() {
      if compare_bytes(e.key, start) >= 0 && compare_bytes(e.key, end) < 0 {
        out.push(e)
      }
    }
    // 这一块的 last_key 已经 >= end，后面的块必然全部越界
    if compare_bytes(ie.key, end) >= 0 {
      break
    }
    i = i + 1
  }
  out
}
