///|
/// MANIFEST：数据库的「版本快照」——记录每一层有哪些 SST、当前活跃的 WAL 编号、
/// 以及下一个可用的文件编号。
///
/// 磁盘布局见 `docs/design/format.md` §4：
/// ```
/// | magic "MMAN":4 | version:u16 | reserved:u16 |
/// | last_seq         varint64 |
/// | log_number       varint64 |
/// | next_file_number varint64 |
/// | num_levels       varint32 |
/// | for each level:  count varint32
/// |   for each sst: number varint64, file_size varint64,
/// |                smallest (varint32 + bytes), largest (varint32 + bytes) |
/// | crc32c of everything above:4 |
/// ```
///
/// **为什么是全量快照而不是增量 log**（ADR-0002 同一思路）：
/// 增量 log 要处理「重放到一半又崩溃」，那是一个完整的状态机；
/// 而全量快照只有「读成功」和「读失败」两种结果。
/// 元信息本身很小（1 万个 SST 也才 400 KB），切换频率是分钟级，
/// 用全量快照换掉一整类 bug 非常划算。
///
/// 和 `wal.mbt` / `sstable.mbt` 一样，这一层**只处理 `Bytes`，不碰文件系统**。
/// 原子替换（CURRENT 的 rename 序列）由 `db.mbt` 通过 `Storage` 完成。
///
/// 与 WAL 相反，MANIFEST 对坏数据的态度是**拒绝**：
/// WAL 尾部的半条记录是断电常态，可以截断；而 MANIFEST 读不懂就意味着
/// 「不知道数据布局」，硬猜会静默丢数据。所以 `decode_manifest` 返回 `None`，
/// 由上层决定「试下一个 MANIFEST」还是「拒绝启动」。

///|
const MANIFEST_MAGIC : Bytes = b"MMAN"

///|
pub const MANIFEST_VERSION : Int = 1

///|
/// 文件头 8 字节 + CRC 4 字节。低于这个长度连空快照都装不下。
const MANIFEST_MIN_SIZE : Int = 12

///|
/// 层数上限。**必须有一个上限**：`num_levels` 是磁盘上读来的，
/// 一个坏值（比如 0x7FFFFFFF）会让解码尝试分配几十 GB 的数组。
/// 真要用到 64 层，说明分层比例设计得离谱，那时再改这个常量。
const MANIFEST_MAX_LEVELS : Int = 64

///|
/// 单层 SST 数量上限，同理防止坏数据导致的巨额分配。
const MANIFEST_MAX_SSTS_PER_LEVEL : Int = 1 << 20

///|
/// key 长度上限（16 MiB）。key 是任意二进制，但一个 16 MiB 的 key
/// 本身就已经是设计错误了。
const MANIFEST_MAX_KEY : Int = 16 * 1024 * 1024

///|
/// 一个 SST 的元信息。**不含内容**——内容在 `sst/<n>.sst` 里。
///
/// `smallest` / `largest` 是这一层做「要不要读这个文件」判断的依据：
/// 没有它们就只能打开每个文件问一遍，读放大会变成 O(文件数)。
pub struct SstMeta {
  number : UInt64
  file_size : UInt64
  smallest : Bytes
  largest : Bytes
}

///|
pub fn SstMeta::new(
  number : UInt64,
  file_size : UInt64,
  smallest : Bytes,
  largest : Bytes,
) -> SstMeta {
  { number, file_size, smallest, largest }
}

///|
/// 版本快照。`levels[0]` 是 L0。
///
/// **L0 的 SST 之间 key 范围可以重叠**（它们各自来自不同时刻的 memtable），
/// 所以 L0 必须全部扫；L1 及以下由 compaction 保证同层不重叠，
/// 因此可以按 `smallest`/`largest` 二分定位。
/// 这个差异是 `Version::overlaps` 存在的唯一理由。
pub struct Version {
  mut last_seq : UInt64
  /// 当前活跃 WAL 的编号。恢复时重放 `wal/<log_number>.wal`。
  mut log_number : UInt64
  /// 下一个可用的文件编号。WAL、SST、MANIFEST 共用这一个编号空间，
  /// 所以任何两个文件不会撞名，恢复时只需比较编号大小。
  mut next_file_number : UInt64
  levels : Array[Array[SstMeta]]
}

///|
/// 新建一个空版本。`log_number` / `next_file_number` 从 1 开始，
/// 0 留给「还没有任何文件」这个状态。
pub fn Version::new() -> Version {
  {
    last_seq: 0UL,
    log_number: 1UL,
    next_file_number: 2UL,
    levels: [[]],
  }
}

///|
/// 带头部字段构造。`Db` 每次写 MANIFEST 都用它，
/// 因为这三个字段总是「一起从当前状态推出来」的。
///
/// 不给 `last_seq` / `log_number` 加 `mut`：它们只有在
/// 「生成一份新快照」时才会变，而不是在快照上原地改。
/// 快照应该是不可变的 —— 可变快照是并发 bug 的温床。
pub fn Version::with_header(
  last_seq : UInt64,
  log_number : UInt64,
  next_file_number : UInt64,
) -> Version {
  {
    last_seq,
    log_number,
    next_file_number,
    levels: [[]],
  }
}

///|
/// 取某一层的 SST 列表。层不存在时返回空数组而不是 panic ——
/// 「这一层还没有文件」是正常状态，不是错误。
pub fn Version::level(self : Version, idx : Int) -> Array[SstMeta] {
  if idx < 0 || idx >= self.levels.length() {
    return []
  }
  self.levels[idx]
}

///|
/// 层数。
pub fn Version::level_count(self : Version) -> Int {
  self.levels.length()
}

///|
/// 全部 SST 总数。
pub fn Version::total_ssts(self : Version) -> Int {
  let mut n = 0
  for lv in self.levels {
    n = n + lv.length()
  }
  n
}

///|
/// 某一层所有 SST 的字节数之和。
///
/// 归并触发条件用它，而不是「文件个数」—— 除了 L0。原因：
/// L0 的文件大小由 memtable 上限决定，个数就能代表体量；而 L1 及以下
/// 的文件是按 `COMPACT_TARGET_SST` 切的，个数多只说明数据多，
/// 真正决定「这层该不该往下沉」的是总字节数。
pub fn Version::level_bytes(self : Version, idx : Int) -> UInt64 {
  let mut total = 0UL
  for m in self.level(idx) {
    total = total + m.file_size
  }
  total
}

///|
/// 从编号空间里取一个新编号。
pub fn Version::alloc_file_number(self : Version) -> UInt64 {
  let n = self.next_file_number
  self.next_file_number = n + 1UL
  n
}

///|
/// 把某一层的 SST 列表整体换掉。compaction 用它。
///
/// 传入的数组会被复制一份：调用方后面可能还要改动自己的数组，
/// 如果这里直接持有引用，「版本快照」就不再是快照了。
pub fn Version::set_level(self : Version, idx : Int, ssts : Array[SstMeta]) -> Unit {
  while self.levels.length() <= idx {
    self.levels.push([])
  }
  let copy : Array[SstMeta] = []
  for s in ssts {
    copy.push(s)
  }
  self.levels[idx] = copy
}

///|
/// 往某一层追加一个 SST。flush 用它把新刷出的文件挂到 L0。
///
/// 追加到 L0 的顺序就是「从旧到新」—— 所以 `Db` 加载时要**倒序**遍历，
/// 才能让 `get` 的短路优化先看到最新的文件。
pub fn Version::push_to_level(self : Version, idx : Int, meta : SstMeta) -> Unit {
  while self.levels.length() <= idx {
    self.levels.push([])
  }
  self.levels[idx].push(meta)
}

// ---------------------------------------------------------------------------
// 编码
// ---------------------------------------------------------------------------

///|
/// 把一个版本序列化成完整文件字节（含文件头和 CRC）。
///
/// 一次性产出全部内容，不做流式写：快照本身只有几百 KB，
/// 而「流式写一半崩了」又要引入一套部分写入的恢复逻辑。
pub fn encode_manifest(v : Version) -> Bytes {
  let b = Buffer::Buffer()
  b.write_bytes(MANIFEST_MAGIC[:])
  write_fixed16(b, MANIFEST_VERSION)
  write_fixed16(b, 0) // reserved，必须写 0，留给未来的对齐或标志位
  write_varint64(b, v.last_seq)
  write_varint64(b, v.log_number)
  write_varint64(b, v.next_file_number)
  write_varint32(b, v.levels.length())
  for lv in v.levels {
    write_varint32(b, lv.length())
    for s in lv {
      write_varint64(b, s.number)
      write_varint64(b, s.file_size)
      write_varint32(b, s.smallest.length())
      b.write_bytes(s.smallest[:])
      write_varint32(b, s.largest.length())
      b.write_bytes(s.largest[:])
    }
  }
  let body = b.to_bytes()
  // CRC 覆盖「除自己以外的全部字节」，包括 magic 和 version。
  // 只覆盖 payload 的话，一个被写坏的 version 字段会被当成合法文件读进去。
  let sum = crc32c(body)
  let out = Buffer::Buffer()
  out.write_bytes(body[:])
  write_fixed32u(out, sum)
  out.to_bytes()
}

// ---------------------------------------------------------------------------
// 解码
// ---------------------------------------------------------------------------

///|
/// 反序列化。任何结构问题都返回 `None`，不抛错也不 panic。
///
/// 校验顺序刻意从「最便宜、最能早退」开始：
/// 长度 → magic → version → **CRC** → 逐字段解析。
///
/// CRC 放在解析之前是关键：如果先解析再校验，一份随机垃圾数据会先
/// 让解析器分配一堆数组、走一堆分支，最后才发现「这是垃圾」。
/// 先校验的话，坏数据在 4 次整数比较内就被否掉。
pub fn decode_manifest(data : Bytes) -> Version? {
  let n = data.length()
  if n < MANIFEST_MIN_SIZE {
    return None
  }
  if !bytes_match(data, 0, MANIFEST_MAGIC) {
    return None
  }
  let ver = match read_fixed16(data, 4) {
    Some(v) => v
    None => return None
  }
  if ver != MANIFEST_VERSION {
    return None
  }
  // CRC 存在最后 4 字节
  let want = match read_fixed32u(data, n - 4) {
    Some(v) => v
    None => return None
  }
  if crc32c(data[:n - 4].to_owned()) != want {
    return None
  }

  // 从第 8 字节开始逐字段解析。limit 传 n-4，把 CRC 排除在可读范围外 ——
  // 否则一个「长度字段写大了」的坏数据会把 CRC 当成 payload 吃进去。
  let limit = n - 4
  let mut pos = 8
  let last_seq = match read_varint64(data, pos, limit) {
    Some(p) => {
      pos = p.1
      p.0
    }
    None => return None
  }
  let log_number = match read_varint64(data, pos, limit) {
    Some(p) => {
      pos = p.1
      p.0
    }
    None => return None
  }
  let next_file_number = match read_varint64(data, pos, limit) {
    Some(p) => {
      pos = p.1
      p.0
    }
    None => return None
  }
  let num_levels = match read_varint32(data, pos, limit) {
    Some(p) => {
      pos = p.1
      p.0
    }
    None => return None
  }
  if num_levels < 0 || num_levels > MANIFEST_MAX_LEVELS {
    return None
  }
  let levels : Array[Array[SstMeta]] = []
  for _ in 0..<num_levels {
    let count = match read_varint32(data, pos, limit) {
      Some(p) => {
        pos = p.1
        p.0
      }
      None => return None
    }
    if count < 0 || count > MANIFEST_MAX_SSTS_PER_LEVEL {
      return None
    }
    let lv : Array[SstMeta] = []
    for _ in 0..<count {
      let number = match read_varint64(data, pos, limit) {
        Some(p) => {
          pos = p.1
          p.0
        }
        None => return None
      }
      let file_size = match read_varint64(data, pos, limit) {
        Some(p) => {
          pos = p.1
          p.0
        }
        None => return None
      }
      let smallest = match read_key(data, pos, limit) {
        Some(p) => {
          pos = p.1
          p.0
        }
        None => return None
      }
      let largest = match read_key(data, pos, limit) {
        Some(p) => {
          pos = p.1
          p.0
        }
        None => return None
      }
      // smallest 必须 <= largest。反过来说「这个文件覆盖的 key 范围是空的」，
      // 那它不可能由写入路径产生 —— 只可能是元信息坏了。
      // 这里不查的话，后面按范围做二分查找会静默漏掉数据。
      if compare_bytes(smallest, largest) > 0 {
        return None
      }
      lv.push(SstMeta::new(number, file_size, smallest, largest))
    }
    levels.push(lv)
  }
  // 尾部必须正好用完：多余的字节说明这份快照和解析器对格式的理解不一致，
  // 继续读下去就是在猜。
  if pos != limit {
    return None
  }
  Some({
    last_seq,
    log_number,
    next_file_number,
    levels,
  })
}

///|
/// 读一个「长度前缀 + 内容」的 key。返回 `(key, 新位置)`。
fn read_key(data : Bytes, pos : Int, limit : Int) -> (Bytes, Int)? {
  let len = match read_varint32(data, pos, limit) {
    Some(p) => p
    None => return None
  }
  let n = len.0
  if n < 0 || n > MANIFEST_MAX_KEY {
    return None
  }
  let start = len.1
  if start + n > limit {
    return None
  }
  Some((data[start:start + n].to_owned(), start + n))
}

// ---------------------------------------------------------------------------
// 语义校验
// ---------------------------------------------------------------------------

///|
/// 检查版本快照的语义不变量。`decode_manifest` 只保证「结构读得通」，
/// 这里检查「这些内容合不合理」。
///
/// 分成两步是因为职责不同：结构错误只能拒绝，语义错误还可以尝试
/// 退回上一个 MANIFEST。而且把语义检查放在解码里会让解码变慢，
/// 而解码每次启动都要跑。
///
/// 检查的三条：
/// 1. `log_number < next_file_number` —— 活跃 WAL 的编号必须在编号空间内
/// 2. L1 及以下**同层不重叠** —— 否则二分查找会漏数据
/// 3. L1 及以下同层按 `smallest` 升序 —— 二分查找的前提
///
/// **L0 不检查重叠**：L0 的 SST 来自不同时刻的 memtable，范围天然可以重叠。
/// 把它们也要求不重叠，等于要求「memtable 的 key 范围互不相交」，
/// 这在真实负载下不可能成立。
pub fn Version::check_invariants(self : Version) -> Bool {
  if self.log_number >= self.next_file_number {
    return false
  }
  if self.levels.length() == 0 {
    return false
  }
  let mut idx = 1
  while idx < self.levels.length() {
    let lv = self.levels[idx]
    let mut i = 1
    while i < lv.length() {
      let prev = lv[i - 1]
      let cur = lv[i]
      // 必须严格递增且不重叠：prev.largest < cur.smallest
      if compare_bytes(prev.smallest, cur.smallest) >= 0 {
        return false
      }
      if compare_bytes(prev.largest, cur.smallest) >= 0 {
        return false
      }
      i = i + 1
    }
    idx = idx + 1
  }
  true
}
