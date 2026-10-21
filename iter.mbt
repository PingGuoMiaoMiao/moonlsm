///|
/// k 路归并迭代器。
///
/// LSM 的读路径本质上是「把 N 个各自有序的来源合成一个有序流」。
/// 这里有三个**必须同时满足**的语义，任何一个错了都会产生静默数据错误：
///
/// 1. **同一个 key 只输出一次**，取 `seq` 最大的那条（新覆盖旧）。
///    只按来源顺序取（sources[0] 优先）在 compaction 之后就错了 ——
///    L1 的文件编号和 seq 顺序没有保证关系。
/// 2. **墓碑必须参与归并，但不能出现在结果里**。
///    如果直接丢掉墓碑，底下那层 SST 里的旧值就会「复活」。
///    正确做法是：先让墓碑赢下归并（压掉旧值），再由上层把它过滤掉。
/// 3. **输出严格按 key 升序**，否则上层的 scan 顺序和 SST 写入的
///    「key 严格升序」前提都会崩。
///
/// 实现是 O(k) 扫描每个 key（k = 来源数）。k 通常是个位数
/// （memtable + 几个 SST），堆优化的收益不值得多一层复杂度。
pub struct MergeIterator {
  sources : Array[Array[Entry]]
  /// 每个来源的当前下标。到达该来源末尾即为「已耗尽」。
  heads : Array[Int]
}

///|
/// 构造归并器。`sources` 里每个数组必须**各自已按 key 升序**。
///
/// 数组的先后顺序只用于「seq 相同时取谁」这种异常情况的兜底，
/// **不参与新旧判断** —— 新旧一律由 `seq` 决定。
pub fn MergeIterator::new(sources : Array[Array[Entry]]) -> MergeIterator {
  let heads : Array[Int] = []
  for _ in sources {
    heads.push(0)
  }
  { sources, heads, }
}

///|
/// 取下一个 key 的最新版本。
///
/// **返回的可能是墓碑**（`deleted = true`）。这是故意的：
/// 调用方需要知道「这个 key 在这里被删了」，才能正确地压制更底层的旧值。
/// 面向用户的 scan 必须自己过滤墓碑，`Db::scan` 就是这么做的。
pub fn MergeIterator::next(self : MergeIterator) -> Entry? {
  // 第一遍：找当前所有头部里最小的 key
  let mut smallest : Bytes? = None
  for i in 0..<self.sources.length() {
    if self.heads[i] < self.sources[i].length() {
      let k = self.sources[i][self.heads[i]].key
      smallest = match smallest {
        None => Some(k)
        Some(cur) => if compare_bytes(k, cur) < 0 { Some(k) } else { Some(cur) }
      }
    }
  }
  let target = match smallest {
    Some(k) => k
    None => return None
  }
  // 第二遍：在等于 target 的所有条目里挑 seq 最大的，并把它们全部推进一格。
  // 一次推进完是「去重」的关键 —— 否则同一个 key 会被输出多次。
  let mut best : Entry? = None
  for i in 0..<self.sources.length() {
    if self.heads[i] < self.sources[i].length() {
      let e = self.sources[i][self.heads[i]]
      if compare_bytes(e.key, target) == 0 {
        best = match best {
          None => Some(e)
          // 严格大于才替换：seq 相同时保留先出现的来源（调用方按从新到旧传入）
          Some(b) => if e.seq > b.seq { Some(e) } else { Some(b) }
        }
        self.heads[i] = self.heads[i] + 1
      }
    }
  }
  best
}

///|
/// 把归并结果全部取出（含墓碑）。测试与 compaction 用。
pub fn MergeIterator::collect(self : MergeIterator) -> Array[Entry] {
  let out : Array[Entry] = []
  while true {
    match self.next() {
      Some(e) => out.push(e)
      None => break
    }
  }
  out
}
