///|
/// Compaction：把上层文件归并到下层，顺手把同一个 key 的多个版本压成一条。
///
/// ## 为什么需要它
///
/// 没有 compaction 时，每次 flush 都往 L0 加一个文件，而 L0 的 SST
/// 之间**范围可以重叠**（它们来自不同时刻的 memtable）。所以读一个 key
/// 要依次问遍所有 L0 文件 —— 读放大是 O(文件数)，而文件数只增不减。
///
/// 归并之后：上层清空，下层的文件**互不重叠**，读一个 key 在每一层
/// 最多只需要打开一个文件（配合 bloom filter 通常连打开都不需要）。
///
/// ## 归并的正确性依据
///
/// 同 key 有多条记录时取 **`seq` 最大**的那条，而不是「按输入顺序」。
/// 这一点由 `MergeIterator` 保证，也是 ADR-0003 的不变量之一：
/// 文件编号只在 L0 内能当序用，一旦跨层就不能靠顺序判断新旧。
///
/// ## 层数与触发条件
///
/// ```
/// L0（memtable 刷出来的，可重叠）  --个数 >= 4-->  L1
/// L1（不重叠）                    --字节 >= 1MiB--> L2
/// L2（不重叠，最底层，不再下沉）
/// ```
///
/// 三层而不是两层，是因为「墓碑能不能丢」取决于「还有没有更下层」。
/// 只有一层下层时，丢墓碑的判定退化成「恒为真」，代码里那条判定就
/// 永远不会被证伪；有了 L2，`is_bottom_level` 才是一个真正起作用的分支。
///
/// ## 墓碑什么时候可以丢
///
/// 墓碑的作用是遮蔽「更下层里的旧值」。所以它只有在**写进最底层**时
/// 才能丢：那次归并的输入已经包含了「所有可能藏着这个 key 旧值的文件」
/// （上层全部 + 下层与之重叠的全部），旧值在归并中就被淘汰了，
/// 墓碑再留着也没有东西可遮。
///
/// 写进非最底层时**必须留着**：下面还有层，那层里可能有一个更旧的版本，
/// 靠这个墓碑压着。丢了它，删掉的数据就会复活。
///
/// 详见 ADR-0007。

///|
/// 层数。L0 / L1 / L2，`NUM_LEVELS - 1` 是最底层。
pub const NUM_LEVELS : Int32 = 3

///|
/// L0 的 SST 个数达到这个值就归并到 L1。
///
/// 太小（比如 2）会让每次 flush 都跟着一次 compaction，写放大明显；
/// 太大则读放大上升。4 是 LevelDB 的默认值附近，且在 v1 的测试规模下
/// 不会频繁触发 —— 让 compaction 成为「可观测的偶发事件」比
/// 「一直在后台跑」更容易在测试里定位问题。
pub const L0_COMPACT_TRIGGER : Int32 = 4

///|
/// L1 的容量上限。超过就把 L1 整个并进 L2。
///
/// 1 MiB 是刻意选小的：v1 的定位是「能跑、能测、能讲清楚」，
/// 而不是「扛住生产流量」。这个值小到让 L1 → L2 在测试里真的会发生
/// （否则那条路径永远只有代码没有验证），大到不会每次 flush 都触发。
pub const LEVEL1_TARGET_BYTES : UInt64 = 1UL << 20

///|
/// 相邻层的容量倍数。L1 = 1 MiB、L2 = 10 MiB。
///
/// 10 是 LevelDB 的默认 fanout。它决定了写放大：每份数据从 L1 走到
/// 最底层，大约要被重写 `层数 - 1` 次。
const LEVEL_FANOUT : UInt64 = 10UL

///|
/// 归并输出的单个 SST 的目标大小。
///
/// 单个文件太大：一次读要解出整个文件（v1 的 `SstReader` 是全量加载）。
/// 太小：文件数暴涨，L1 的二分查找收益被文件打开开销吃掉。
const COMPACT_TARGET_SST : Int32 = 1 << 20

///|
/// 第 `lv` 层的容量上限。L0 返回 0 —— 它按文件个数触发，不看字节数。
pub fn level_target_bytes(lv : Int32) -> UInt64 {
  if lv <= 0 {
    return 0UL
  }
  let mut t = LEVEL1_TARGET_BYTES
  let mut i = 1
  while i < lv {
    t = t * LEVEL_FANOUT
    i = i + 1
  }
  t
}

///|
/// 最底层不再往下沉 —— 它的数据要等到被覆盖写或删除才会消失。
pub fn is_bottom_level(lv : Int32) -> Bool {
  lv == NUM_LEVELS - 1
}

///|
/// 第 `lv` 层该不该归并。
///
/// **纯策略函数，不做任何 IO。** 单独抽出来是为了能用任意数字做单测：
/// 「L1 超过 1 MiB 就下沉」这条规则如果用真数据测，得先写 1 MiB，
/// 而验证边界（`>=` 还是 `>`）要写两个 1 MiB 的库。
pub fn should_compact_level(
  lv : Int32,
  sst_count : Int32,
  bytes : UInt64,
) -> Bool {
  // 最底层没有下层可去；越界的层号一律不归并（宁可不做，也不要越界写）
  if lv < 0 || lv >= NUM_LEVELS - 1 {
    return false
  }
  if lv == 0 {
    // L0 看个数：文件大小由 memtable 上限决定，个数就代表体量
    return sst_count >= L0_COMPACT_TRIGGER
  }
  // L1 及以下看字节数
  bytes >= level_target_bytes(lv)
}

///|
/// 检查每一层，该归并就归并。在 `flush` 末尾调用。
///
/// 顺序是从上往下：先把 L0 并进 L1，再判断 L1 是不是又满了。
/// 反过来（先看 L1）会让刚被 L0 推下来的数据多等一轮 flush 才下沉。
pub fn[S : Storage] Db::maybe_compact(self : Db[S]) -> Unit raise LsmError {
  for lv in 0..<(NUM_LEVELS - 1) {
    if should_compact_level(
        lv,
        self.version.level(lv).length(),
        self.version.level_bytes(lv),
      ) {
      self.compact_level(lv)
    }
  }
}

///|
/// 把 L0 全部 + 与 L0 范围重叠的 L1 文件，归并成新的 L1。
///
/// 保留这个名字是因为它是最常用的入口（测试也直接调它）。
pub fn[S : Storage] Db::compact_l0(self : Db[S]) -> Unit raise LsmError {
  self.compact_level(0)
}

///|
/// 把第 `src` 层的全部文件，连同第 `src + 1` 层里与之范围重叠的文件，
/// 归并成新的 `src + 1` 层文件。
///
/// 顺序（每一步的崩溃点都有明确恢复路径）：
///
/// ```
/// 1. 算出 src 层覆盖的 key 范围，找出 dst 层里与之重叠的文件
/// 2. 读入全部输入条目 → 归并（同 key 取 seq 最大）→ 到最底层时丢墓碑
/// 3. 按大小切成若干 SST，逐个写盘 + fsync
/// 4. 更新 version：src 清空、dst = 未参与的文件 + 新文件
/// 5. persist_version()   ← 原子点
/// 6. 删除输入文件
/// 7. 重建内存里的 ssts 视图
/// ```
///
/// 5 之前崩溃：CURRENT 仍指向旧 MANIFEST，输入文件都还在 → 数据完好，
/// 新写的 SST 是孤儿（`bump_file_number_past_existing` 会跳过它们的编号）。
/// 5 之后崩溃：新 MANIFEST 只引用新文件，输入文件成了垃圾，
/// 但它们不影响恢复，下次启动会被忽略（后续可加孤儿清理）。
///
/// **第 6 步必须在第 5 步之后。** 提前删输入文件的话，一旦 5 失败，
/// 旧 MANIFEST 引用的文件已经没了 —— 数据库直接打不开。
pub fn[S : Storage] Db::compact_level(
  self : Db[S],
  src : Int32,
) -> Unit raise LsmError {
  self.ensure_open()
  if src < 0 || src >= NUM_LEVELS - 1 {
    return
  }
  let dst = src + 1
  let upper = self.version.level(src)
  if upper.length() == 0 {
    return
  }
  // L0 只有一个文件时没什么可归并的（也就没有「压成一条」的收益）。
  // L1 及以下不同：一个文件也可能因为「这层超预算」被推下去，
  // 所以只在 src == 0 时要求至少两个。
  if src == 0 && upper.length() < 2 {
    return
  }

  // ---- 1. src 层的 key 范围 + dst 层里与之重叠的文件 ----
  let mut lo = upper[0].smallest
  let mut hi = upper[0].largest
  for m in upper {
    if compare_bytes(m.smallest, lo) < 0 {
      lo = m.smallest
    }
    if compare_bytes(m.largest, hi) > 0 {
      hi = m.largest
    }
  }
  let lower = self.version.level(dst)
  let overlap : Array[SstMeta] = []
  for m in lower {
    // 区间相交的判定：不是「完全在左」也不是「完全在右」。
    // 注意「首尾相接」（largest == lo）不算重叠 —— 区间是闭的，
    // 但两个文件分别拥有各自的端点 key，合起来仍是严格递增。
    let entirely_left = compare_bytes(m.largest, lo) < 0
    let entirely_right = compare_bytes(m.smallest, hi) > 0
    if !entirely_left && !entirely_right {
      overlap.push(m)
    }
  }

  // ---- 2. 读入 + 归并 ----
  let inputs : Array[SstMeta] = []
  for m in upper {
    inputs.push(m)
  }
  for m in overlap {
    inputs.push(m)
  }
  let sources : Array[Array[Entry]] = []
  for m in inputs {
    // 从已加载的 reader 取，不重新读盘：这些文件本来就在内存里
    sources.push(self.find_reader(m.number).entries())
  }
  let merged_all = MergeIterator::new(sources).collect()
  // 只有写进最底层才能丢墓碑。理由见文件头「墓碑什么时候可以丢」。
  let drop_tombstones = is_bottom_level(dst)
  let merged : Array[Entry] = []
  for e in merged_all {
    if !(drop_tombstones && e.deleted) {
      merged.push(e)
    }
  }

  // ---- 3. 按大小切成若干 SST 并写盘 ----
  let outs : Array[SstMeta] = []
  let out_readers : Array[LoadedSst] = []
  // `merged` 可能为空：所有输入都是墓碑，且这次写的是最底层 ——
  // 那是「这批 key 真的没了」，不该产出文件，但**照样要走完后面几步**
  // 把输入文件清掉。提前 return 会让这批墓碑永远留在 L0 里，
  // 每次 flush 都重试一遍归并。
  let mut i = 0
  while i < merged.length() {
    let w = SstWriter::new()
    let first_key = merged[i].key
    let mut last_key = first_key
    let mut bytes = 0
    // `bytes == 0` 保证每个文件至少有一条 —— 否则遇到超大条目
    // 会产出空 SST，而空 SST 的 footer 里 smallest/largest 没有意义
    while i < merged.length() && (bytes == 0 || bytes < COMPACT_TARGET_SST) {
      let e = merged[i]
      w.add(e)
      bytes = bytes + e.key.length() + e.value.length()
      last_key = e.key
      i = i + 1
    }
    let raw = w.finish()
    let num = self.version.alloc_file_number()
    let p = sst_path(num)
    Storage::write_file(self.storage, p, raw)
    Storage::sync_file(self.storage, p)
    let reader = match open_sst(raw) {
      Some(r) => r
      None =>
        raise LsmError::corruption(
          "compaction: 刚写出的 SST 无法打开（写读不一致）：\{p}",
        )
    }
    outs.push(SstMeta::new(num, raw.length().to_uint64(), first_key, last_key))
    out_readers.push({ num, reader, })
  }

  // ---- 4. 更新 version ----
  //
  // v1 每次都取**整层**（L0 的文件互相重叠，取一部分没有意义；
  // L1 及以下整层一起下沉，写放大是 O(整层)，但这一层的上限就是
  // `level_target_bytes`，不会失控）。所以 src 层直接清空。
  //
  // 若将来改成「L1 只取一个文件往下沉」，这里要改成过滤掉被取走的那些，
  // 同时上面的 `sources` / `inputs` 也要跟着改 —— 两处必须一致，
  // 否则「文件还在 version 里但内存视图里没了」。
  let new_upper : Array[SstMeta] = []
  let new_lower : Array[SstMeta] = []
  for m in lower {
    if !contains_meta(overlap, m.number) {
      new_lower.push(m)
    }
  }
  for m in outs {
    new_lower.push(m)
  }
  // 必须按 smallest 升序：下层的二分查找和 `check_invariants` 都依赖它
  new_lower.sort_by(fn(a, b) { compare_bytes(a.smallest, b.smallest) })
  self.version.set_level(src, new_upper)
  self.version.set_level(dst, new_lower)
  self.version.last_seq = self.seq

  // ---- 5. 原子切换 ----
  self.persist_version()

  // ---- 6. 删输入文件（必须在 5 之后）----
  for m in inputs {
    Storage::remove_file(self.storage, sst_path(m.number)) catch {
      Io(_) => ()
      Corruption(_) => ()
      Closed => ()
    }
  }

  // ---- 7. 重建内存视图 ----
  self.reload_sst_view(out_readers)
}

///|
/// 按 `version` 重建内存里的 SST 视图。
///
/// 顺序必须是「层号升序（L0 最新）+ 层内编号降序」—— `get` 靠
/// `self.ssts[0]` 是最新的文件来做短路（命中第一个就返回，不比较 seq），
/// 顺序反了就会读到旧值。
///
/// 这里**不手写「谁在前谁在后」**，而是照着 `version` 重排一遍：
/// 归并会同时改动两层，靠人工推理「新文件和幸存文件的相对位置」太容易错，
/// 而且错了之后测试多半还是绿的（范围不相交时两种顺序结果一样）。
/// 唯一的事实来源就是 `version` 本身。
fn[S] Db::reload_sst_view(
  self : Db[S],
  fresh : Array[LoadedSst],
) -> Unit raise LsmError {
  for f in fresh {
    self.ssts.push(f)
  }
  let next : Array[LoadedSst] = []
  for lv in 0..<self.version.level_count() {
    let files = self.version.level(lv)
    let mut i = files.length()
    while i > 0 {
      i = i - 1
      let num = files[i].number
      next.push({ num, reader: self.find_reader(num), })
    }
  }
  self.ssts.clear()
  for s in next {
    self.ssts.push(s)
  }
}

///|
/// 数组里有没有这个编号的 SST。
///
/// 线性扫描而不是用 Map：一个层的文件数是十几到几十个，
/// 而 Map 要为每次 compaction 重建一次。等 compaction 变成后台任务、
/// 层里出现几千个文件时再换成 Map。
fn contains_meta(metas : Array[SstMeta], num : UInt64) -> Bool {
  for m in metas {
    if m.number == num {
      return true
    }
  }
  false
}
