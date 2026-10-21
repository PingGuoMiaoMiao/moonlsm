///|
/// M1 阶段的数据库：memtable + 若干 SST。
///
/// **这一版故意没有 WAL、没有 compaction、不落盘。**
/// 这不是半成品，是刻意切出的里程碑（见 `PLAN.md` Week 1）：
/// 先把「写 → 内存 → 刷盘 → 读回来」这条路径的正确性锁死，
/// 再在 Week 2 加崩溃恢复。如果两件事一起做，
/// 「读出来不对」到底是归并错了还是恢复错了，根本分不清。
///
/// 读路径的新旧顺序：`memtable` → `ssts[0]` → `ssts[1]` → …
/// 越靠前越新。注意这只是**短路优化的依据**，正确性依据永远是 `seq` ——
/// 归并时用 `seq` 判断新旧，而不是数组下标。
pub struct Db {
  mem : MemTable
  /// 从新到旧。
  ssts : Array[SstReader]
  mut seq : UInt64
  mut flush_count : Int
}

///|
/// 建一个内存库。`mem_limit` 是 memtable 的字节阈值，超过就自动刷盘。
pub fn Db::new(mem_limit : Int) -> Db {
  { mem: MemTable::new(mem_limit), ssts: [], seq: 0UL, flush_count: 0, }
}

///|
/// 当前最大 seq。每次写入自增，跨 memtable 与 SST 全局单调。
pub fn Db::last_seq(self : Db) -> UInt64 {
  self.seq
}

///|
pub fn Db::sst_count(self : Db) -> Int {
  self.ssts.length()
}

///|
pub fn Db::flush_count(self : Db) -> Int {
  self.flush_count
}

///|
/// memtable 里的条目数（含墓碑）。`stats` 命令用它区分
/// 「内存里有多少条」和「已经刷到 SST 的有多少条」。
pub fn Db::mem_entry_count(self : Db) -> Int {
  self.mem.to_entries().length()
}

///|
/// 写。返回本次写入的 seq。
pub fn Db::put(self : Db, key : Bytes, value : Bytes) -> UInt64 raise LsmError {
  self.seq = self.seq + 1UL
  self.mem.put(key, value, self.seq)
  self.maybe_flush()
  self.seq
}

///|
/// 删。写墓碑，不是移除条目。
pub fn Db::delete(self : Db, key : Bytes) -> UInt64 raise LsmError {
  self.seq = self.seq + 1UL
  self.mem.delete(key, self.seq)
  self.maybe_flush()
  self.seq
}

///|
fn Db::maybe_flush(self : Db) -> Unit raise LsmError {
  if self.mem.is_full() {
    self.flush()
  }
}

///|
/// 把 memtable 刷成一个 SST。
///
/// 顺序必须是：写 SST → **立刻读回校验** → 才清空 memtable。
/// 中间任何一步失败都不能清 memtable，否则数据就没了。
/// 这里的「读回校验」是廉价的：`open_sst` 会校验 magic / version /
/// 区域边界，能在几微秒内发现「写出来的东西自己都打不开」这种灾难性 bug。
pub fn Db::flush(self : Db) -> Unit raise LsmError {
  if self.mem.to_entries().length() == 0 {
    return
  }
  let w = SstWriter::new()
  for e in self.mem.to_entries() {
    w.add(e)
  }
  let raw = w.finish()
  let reader = match open_sst(raw) {
    Some(r) => r
    None =>
      raise LsmError::corruption(
        "flush: 刚写出的 SST 无法打开（写读不一致）",
      )
  }
  // 新 SST 插到最前面：它比已有的都新
  self.ssts.insert(0, reader)
  self.mem.clear()
  self.flush_count = self.flush_count + 1
}

///|
/// 读。返回 `None` 表示「不存在」或「已删除」——
/// 对使用者来说这两种没有区别，墓碑是实现细节。
pub fn Db::get(self : Db, key : Bytes) -> Bytes? {
  match self.mem.get(key) {
    Some(e) => return if e.deleted { None } else { Some(e.value) }
    None => ()
  }
  for r in self.ssts {
    match r.get(key) {
      Some(e) => return if e.deleted { None } else { Some(e.value) }
      None => ()
    }
  }
  None
}

///|
/// 范围扫描。`start` 闭、`end` 开（`[start, end)`），最多 `limit` 条。
///
/// 用左闭右开而不是双闭：双闭无法表达「扫到最大 key 之后」，
/// 调用方得造一个「比所有 key 都大」的哨兵值，而 key 是任意二进制，
/// 没有这样的哨兵。
pub fn Db::scan(
  self : Db,
  start : Bytes,
  end : Bytes,
  limit : Int,
) -> Array[KvPair] raise LsmError {
  let sources : Array[Array[Entry]] = []
  sources.push(self.mem.to_entries())
  for r in self.ssts {
    sources.push(r.entries())
  }
  let it = MergeIterator::new(sources)
  let out : Array[KvPair] = []
  while out.length() < limit {
    match it.next() {
      Some(e) => {
        // 墓碑必须在这里被吃掉，不能出现在结果里
        if e.deleted {
          continue
        }
        if compare_bytes(e.key, start) < 0 {
          continue
        }
        if compare_bytes(e.key, end) >= 0 {
          continue
        }
        out.push(e.to_pair())
      }
      None => break
    }
  }
  out
}
