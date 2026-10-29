///|
/// 归并迭代器测试。
///
/// 手写用例覆盖「墓碑压制」「同 key 取最新」这类容易想漏的语义；
/// 差分测试用参考实现对拍，覆盖手写用例想不到的组合。

///|
/// 参考实现：把所有条目摊平，按 (key 升序, seq 降序) 排序后
/// 每个 key 只留第一条。与归并迭代器的输出必须逐条相同。
///
/// 故意写得「笨」—— 它不需要快，只需要**一眼能看出是对的**。
/// 如果参考实现也用了归并逻辑，那就变成「两个同样的错误互相验证」。
fn reference_merge(sources : Array[Array[Entry]]) -> Array[Entry] {
  let all : Array[Entry] = []
  for s in sources {
    for e in s {
      all.push(e)
    }
  }
  all.sort_by(fn(a, b) {
    let c = compare_bytes(a.key, b.key)
    if c != 0 {
      return c
    }
    if a.seq > b.seq {
      -1
    } else if a.seq < b.seq {
      1
    } else {
      0
    }
  })
  let out : Array[Entry] = []
  let mut i = 0
  while i < all.length() {
    out.push(all[i])
    let k = all[i].key
    i = i + 1
    while i < all.length() && compare_bytes(all[i].key, k) == 0 {
      i = i + 1
    }
  }
  out
}

///|
fn e(k : String, v : String, seq : UInt64) -> Entry {
  { key: @utf8.encode(k), value: @utf8.encode(v), seq, deleted: false, }
}

///|
fn tomb(k : String, seq : UInt64) -> Entry {
  { key: @utf8.encode(k), value: b"", seq, deleted: true, }
}

///|
fn assert_entries_eq(got : Array[Entry], want : Array[Entry]) -> Unit raise {
  assert_eq(got.length(), want.length())
  for i in 0..<want.length() {
    assert_eq(compare_bytes(got[i].key, want[i].key), 0)
    assert_eq(compare_bytes(got[i].value, want[i].value), 0)
    assert_eq(got[i].seq, want[i].seq)
    assert_eq(got[i].deleted, want[i].deleted)
  }
}

///|
test "iter: 全部来源为空时立刻结束" {
  let empty : Array[Array[Entry]] = []
  let it = MergeIterator::new(empty)
  assert_true(it.next() is None)
  let two_empty : Array[Array[Entry]] = [[], []]
  let it2 = MergeIterator::new(two_empty)
  assert_true(it2.next() is None)
}

///|
test "iter: 单来源原样输出" {
  let src : Array[Entry] = [
    e("a", "1", 1UL),
    e("b", "2", 2UL),
    e("c", "3", 3UL),
  ]
  let it = MergeIterator::new([src])
  assert_entries_eq(it.collect(), src)
}

///|
test "iter: 同 key 多版本取 seq 最大的" {
  // 注意 sources[0] 反而是旧数据 —— 新旧必须由 seq 决定，
  // 不能由数组顺序决定。这正是 compaction 之后会出现的真实情况。
  let old : Array[Entry] = [e("a", "old", 1UL), e("c", "c1", 3UL)]
  let new : Array[Entry] = [e("a", "new", 9UL), e("b", "b2", 2UL)]
  let it = MergeIterator::new([old, new])
  let got = it.collect()
  assert_eq(got.length(), 3)
  assert_eq(compare_bytes(got[0].value, @utf8.encode("new")), 0)
  assert_eq(got[0].seq, 9UL)
}

///|
test "iter: 墓碑压住旧值，且墓碑本身要能被上层看到" {
  // 底层 SST 里 a 还有值，memtable 里 a 被删了。
  // 如果归并时直接丢掉墓碑，底层的旧值就会「复活」——
  // 这是 LSM 最经典的删除失效 bug。
  let sst : Array[Entry] = [e("a", "旧值", 1UL), e("b", "保留", 2UL)]
  let mem : Array[Entry] = [tomb("a", 10UL)]
  let got = MergeIterator::new([mem, sst]).collect()
  // a 只输出一条，是墓碑；b 原样输出
  assert_eq(got.length(), 2)
  assert_eq(compare_bytes(got[0].key, @utf8.encode("a")), 0)
  assert_eq(got[0].deleted, true)
  assert_eq(got[0].seq, 10UL)
  assert_eq(compare_bytes(got[1].key, @utf8.encode("b")), 0)
  assert_eq(got[1].deleted, false)
}

///|
test "iter: 三路交错合并后有序且无重复" {
  let s0 : Array[Entry] = [e("a", "0", 1UL), e("d", "0", 2UL), e("g", "0", 3UL)]
  let s1 : Array[Entry] = [e("b", "1", 4UL), e("e", "1", 5UL), e("h", "1", 6UL)]
  let s2 : Array[Entry] = [e("c", "2", 7UL), e("f", "2", 8UL), e("i", "2", 9UL)]
  let got = MergeIterator::new([s0, s1, s2]).collect()
  let want : Array[String] = ["a", "b", "c", "d", "e", "f", "g", "h", "i"]
  assert_eq(got.length(), want.length())
  for i in 0..<want.length() {
    assert_eq(compare_bytes(got[i].key, @utf8.encode(want[i])), 0)
  }
}

///|
test "iter: seq 相同时保留先出现的来源" {
  // 正常路径不该出现同 key 同 seq（seq 全局单调），
  // 但 WAL 重放重复、或手工构造数据时可能出现。定一个确定的行为比随机好。
  let s0 : Array[Entry] = [e("a", "first", 5UL)]
  let s1 : Array[Entry] = [e("a", "second", 5UL)]
  let got = MergeIterator::new([s0, s1]).collect()
  assert_eq(got.length(), 1)
  assert_eq(compare_bytes(got[0].value, @utf8.encode("first")), 0)
}

///|
test "iter: 差分测试 —— 随机多来源与参考实现逐条一致" {
  let rng = TestRng::new(2024UL)
  for round in 0..<20 {
    let nsrc = 1 + rng.below(4)
    let sources : Array[Array[Entry]] = []
    let mut seq = 1UL
    for _ in 0..<nsrc {
      let n = rng.below(40)
      let items : Array[Entry] = []
      // 每个来源内部严格升序：先取 n 个 key，排序，再去重
      let keys : Array[Int32] = []
      for _ in 0..<n {
        keys.push(rng.below(60))
      }
      keys.sort()
      let mut last = -1
      for k in keys {
        if k == last {
          continue
        }
        last = k
        let key = "k" + pad6(k)
        if rng.below(5) == 0 {
          items.push(tomb(key, seq))
        } else {
          items.push(
            e(key, "v" + round.to_string() + "_" + seq.to_string(), seq),
          )
        }
        seq = seq + 1UL
      }
      sources.push(items)
    }
    let got = MergeIterator::new(sources).collect()
    let want = reference_merge(sources)
    assert_entries_eq(got, want)
  }
}
