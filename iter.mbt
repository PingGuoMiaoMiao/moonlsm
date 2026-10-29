///|
/// 归并的一个来源。
///
/// 两种构造器对应两种真实来源，差别在于**数据在哪里**：
///
/// - `FromArray`：已经全在内存里、且已按 key 升序排好（memtable 的有序数组、
///   compaction 的输入）。取一条就是一次数组下标。
/// - `FromSst`：在磁盘文件的内存副本里，**按块惰性解码**。取一条可能要解一块。
///
/// 之所以要这层抽象，是因为 `Db::scan` 带 `limit`：要 10 条时，
/// 不该把整个区间的条目都解出来。而「只取需要的」这件事必须发生在来源一侧 ——
/// 归并层无法提前知道哪条会进前 10。
enum Source {
  FromArray(ArrayCursor)
  FromSst(SstCursor)
}

///|
/// 有序数组上的游标。`i` 是下一个待取位置。
priv struct ArrayCursor {
  arr : Array[Entry]
  mut i : Int32
}

///|
fn ArrayCursor::new(arr : Array[Entry]) -> ArrayCursor {
  { arr, i: 0, }
}

///|
/// 从第一个 `>= start` 的位置开始。
///
/// 区间扫描时用它跳过区间之前的所有条目 —— memtable 满时可能有几万条，
/// 而调用方只要 `[user:0100, user:0110)` 这十行。
fn ArrayCursor::new_from(arr : Array[Entry], start : Bytes) -> ArrayCursor {
  let mut lo = 0
  let mut hi = arr.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    if compare_bytes(arr[mid].key, start) < 0 {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  { arr, i: lo, }
}

///|
/// 看当前条目，不推进。`None` 表示这个来源已耗尽。
fn Source::peek(self : Source) -> Entry? {
  match self {
    FromArray(c) => if c.i < c.arr.length() { Some(c.arr[c.i]) } else { None }
    FromSst(c) => c.peek()
  }
}

///|
fn Source::advance(self : Source) -> Unit {
  match self {
    FromArray(c) => c.i = c.i + 1
    FromSst(c) => c.advance()
  }
}

///|
/// 这个来源在读的过程中出过错没有。
///
/// 只有 SST 来源会出错（解码失败）。数组来源不会 —— 它已经在内存里了。
fn Source::failed(self : Source) -> Bool {
  match self {
    FromArray(_) => false
    FromSst(c) => c.failed
  }
}

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
///
/// **来源是惰性推进的**（ADR-0011）：归并器只看每个来源的「当前头部」，
/// 不假设它们已经全在内存里。这让 `Db::scan` 的 `limit` 第一次真正生效 ——
/// 取够 N 条就停，后面那些块根本没被解出来。
pub struct MergeIterator {
  sources : Array[Source]
}

///|
/// 用「已经全在内存里的有序数组」构造归并器。compaction 与测试走这条。
///
/// 数组的先后顺序只用于「seq 相同时取谁」这种异常情况的兜底，
/// **不参与新旧判断** —— 新旧一律由 `seq` 决定。
pub fn MergeIterator::new(sources : Array[Array[Entry]]) -> MergeIterator {
  let out : Array[Source] = []
  for a in sources {
    out.push(FromArray(ArrayCursor::new(a)))
  }
  { sources: out, }
}

///|
/// 用任意来源构造。`Db::scan` 走这条（memtable 数组 + 若干 SST 游标）。
fn MergeIterator::from_sources(sources : Array[Source]) -> MergeIterator {
  { sources, }
}

///|
/// 是否有来源在读的过程中出错。
///
/// 归并器本身不抛错（`next` 是纯函数），错误只被记下来，
/// 由 `Db::scan` 在返回前检查并转成 `Corruption`。
/// **不能不管**：出错的那个来源会静默变成「空」，扫出来的结果就少了那部分数据。
fn MergeIterator::failed(self : MergeIterator) -> Bool {
  for s in self.sources {
    if s.failed() {
      return true
    }
  }
  false
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
    match self.sources[i].peek() {
      Some(e) =>
        smallest = match smallest {
          None => Some(e.key)
          Some(cur) =>
            if compare_bytes(e.key, cur) < 0 {
              Some(e.key)
            } else {
              Some(cur)
            }
        }
      None => ()
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
    match self.sources[i].peek() {
      Some(e) =>
        if compare_bytes(e.key, target) == 0 {
          best = match best {
            None => Some(e)
            // 严格大于才替换：seq 相同时保留先出现的来源（调用方按从新到旧传入）
            Some(b) => if e.seq > b.seq { Some(e) } else { Some(b) }
          }
          self.sources[i].advance()
        }
      None => ()
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
