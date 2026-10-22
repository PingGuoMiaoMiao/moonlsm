///|
/// SSTable 读写测试。
///
/// D3 的验收标准是「写 1 万条后能读回」。但只测这一条不够 ——
/// 1 万条全部落在同一个 data block 里也能通过。所以这里额外强制
/// `block_count() > 1`，确保真的跨了 block 边界。

///|
fn must_open(raw : Bytes) -> SstReader {
  match open_sst(raw) {
    Some(r) => r
    None => panic()
  }
}

///|
/// 写 `n` 条 `key:%06d -> value:<i>` 并返回原始字节。
fn build_sst(n : Int) -> Bytes raise {
  let w = SstWriter::new()
  for i in 0..<n {
    w.add(mk("key:" + pad6(i), "value:" + i.to_string(), (i + 1).to_uint64()))
  }
  w.finish()
}

///|
test "sst: 空 SST 可打开且查不到任何 key" {
  let raw = SstWriter::new().finish()
  let r = must_open(raw)
  assert_eq(r.block_count(), 0)
  assert_eq(r.entries().length(), 0)
  assert_true(r.get(@utf8.encode("anything")) is None)
  // 空 SST 的 smallest_seq 必须是 0，不能是未初始化的 0xFFFF...
  assert_eq(r.footer().smallest_seq, 0UL)
}

///|
test "sst: 写 1 万条后全部读回一致（D3 验收）" {
  let raw = build_sst(10000)
  let r = must_open(raw)
  let got = r.entries()
  assert_eq(got.length(), 10000)
  for i in 0..<10000 {
    let want_key = @utf8.encode("key:" + pad6(i))
    assert_eq(compare_bytes(got[i].key, want_key), 0)
    assert_eq(
      compare_bytes(got[i].value, @utf8.encode("value:" + i.to_string())),
      0,
    )
    assert_eq(got[i].seq, (i + 1).to_uint64())
    assert_eq(got[i].deleted, false)
  }
}

///|
test "sst: 1 万条会切出多个 data block（否则跨块路径根本没被测到）" {
  let r = must_open(build_sst(10000))
  assert_true(r.block_count() > 1)
}

///|
test "sst: 逐条 get 命中（含跨 block 边界的 key）" {
  let r = must_open(build_sst(3000))
  for i in 0..<3000 {
    let key = @utf8.encode("key:" + pad6(i))
    match r.get(key) {
      Some(e) => {
        assert_eq(compare_bytes(e.key, key), 0)
        assert_eq(
          compare_bytes(e.value, @utf8.encode("value:" + i.to_string())),
          0,
        )
      }
      None => assert_true(false)
    }
  }
  // 不存在：比最小 key 小、比最大 key 大、落在中间
  assert_true(r.get(@utf8.encode("a")) is None)
  assert_true(r.get(@utf8.encode("z")) is None)
  assert_true(r.get(@utf8.encode("key:0000000")) is None)
  assert_true(r.get(@utf8.encode("key:")) is None)
}

///|
test "sst: bloom 过滤器不允许假阴性" {
  // 假阴性 = 「数据明明写了，filter 说不存在」= 数据丢失。
  // 这是 bloom 唯一不可接受的错误方向，必须逐个 key 验证。
  let n = 2000
  let raw = build_sst(n)
  let r = must_open(raw)
  for i in 0..<n {
    let key = @utf8.encode("key:" + pad6(i))
    match r.get(key) {
      Some(_) => ()
      None => assert_true(false)
    }
  }
}

///|
test "sst: footer 各区域首尾相接" {
  let raw = build_sst(500)
  let r = must_open(raw)
  let f = r.footer()
  // 布局必须是 data* | filter | index | footer，不能有缝隙也不能重叠
  assert_eq(f.index_offset, f.filter_offset + f.filter_size)
  assert_eq(f.index_offset + f.index_size + SST_FOOTER_SIZE, raw.length())
  assert_eq(f.version, 1)
  assert_eq(f.smallest_seq, 1UL)
}

///|
test "sst: 大 value 往返（64 KiB）" {
  // 一条 entry 远大于目标 block 大小，验证「切块点必须落在 entry 边界」
  // 这条规则 —— 否则大 value 会被硬切开，读回来就是坏的
  let big = Buffer::Buffer()
  for i in 0..<65536 {
    big.write_byte((i % 251).to_byte())
  }
  let w = SstWriter::new()
  w.add({
    key: @utf8.encode("a"),
    value: big.to_bytes(),
    seq: 1UL,
    deleted: false,
  })
  w.add(mk("b", "small", 2UL))
  let r = must_open(w.finish())
  match r.get(@utf8.encode("a")) {
    Some(e) => {
      assert_eq(e.value.length(), 65536)
      assert_eq(e.value[0].to_int(), 0)
      assert_eq(e.value[65535].to_int(), 65535 % 251)
    }
    None => assert_true(false)
  }
  match r.get(@utf8.encode("b")) {
    Some(e) => assert_eq(compare_bytes(e.value, @utf8.encode("small")), 0)
    None => assert_true(false)
  }
}

///|
test "sst: 墓碑写入磁盘后仍然可区分" {
  let w = SstWriter::new()
  w.add({ key: @utf8.encode("a"), value: b"", seq: 1UL, deleted: true, })
  w.add({ key: @utf8.encode("b"), value: b"", seq: 2UL, deleted: false, })
  let r = must_open(w.finish())
  match r.get(@utf8.encode("a")) {
    Some(e) => {
      assert_eq(e.deleted, true)
      assert_eq(e.value.length(), 0)
    }
    None => assert_true(false)
  }
  match r.get(@utf8.encode("b")) {
    Some(e) => assert_eq(e.deleted, false)
    None => assert_true(false)
  }
}

///|
test "sst: 坏文件一律返回 None 而不是 panic" {
  let raw = build_sst(200)
  // 太短
  assert_true(open_sst(b"") is None)
  assert_true(open_sst(bytes_of([0x01, 0x02, 0x03])) is None)
  // magic 被改坏（footer 最后 4 字节）
  let bad_magic = raw[:raw.length() - 4].to_owned()
  let bm = Buffer::Buffer()
  bm.write_bytes(bad_magic[:])
  bm.write_bytes(b"XXXX"[:])
  assert_true(open_sst(bm.to_bytes()) is None)
  // version 被改成不认识的 2
  let bad_ver = raw[:raw.length() - 8].to_owned()
  let bv = Buffer::Buffer()
  bv.write_bytes(bad_ver[:])
  write_fixed32(bv, 2)
  bv.write_bytes(b"MSST"[:])
  assert_true(open_sst(bv.to_bytes()) is None)
  // 文件被截断（footer 位置整体错位）
  assert_true(open_sst(raw[:raw.length() - 10].to_owned()) is None)
}

///|
test "sst: 索引 seek 语义是「第一个 last_key >= 目标」" {
  let r = must_open(build_sst(1000))
  // 索引里存的是每个 block 的最大 key。对任意目标，seek 出来的那个
  // block 必须真的包含目标 key（如果目标存在的话）。
  for i in 0..<1000 {
    let key = @utf8.encode("key:" + pad6(i))
    let idx = r.index.seek(key)
    assert_true(idx is Some(_))
    match idx {
      Some(e) => assert_true(compare_bytes(e.key, key) >= 0)
      None => assert_true(false)
    }
  }
  // 比所有 key 都大 → 没有条目满足 >=
  assert_true(r.index.seek(@utf8.encode("zzz")) is None)
}

///|
/// `scan_range` 与「`entries()` 之后再按区间筛」必须逐条一致。
///
/// 这是块级剪枝的守门人：剪枝的边界很容易写错一位 ——
/// 「第一个 last_key >= start 的块」写成 `>`、或者「last_key >= end 就停」
/// 写成 `>`，症状都是**悄悄少返回几条**，而调用方往往只看总数。
///
/// 所以这里不挑几个好看的区间，而是把 start / end 都扫过整个 key 空间，
/// 包括「落在块中间」「正好等于某个 key」「完全越界」「区间为空」四类。
test "sst: scan_range 与全量筛选逐条一致（含块边界）" {
  // 3000 条、每条约 25 字节 ≈ 75 KiB，按 4 KiB 一块会切出十几个块。
  // 只有几百条的话全落在一两个块里，块级剪枝根本不会被触发。
  let n = 3000
  let raw = build_sst(n)
  let r = must_open(raw)
  let all = r.entries()
  assert_eq(all.length(), n)
  // 确认真的跨了很多块，否则这条测试退化成「单块内筛选」
  assert_true(r.block_count() > 10)
  let keys : Array[String] = []
  for i in 0..<n {
    keys.push("key:" + pad6(i))
  }
  // 参照实现：直接筛
  let cases : Array[(String, String)] = [
    ("", "zzzzzz"),                       // 全量
    ("key:000000", "key:" + pad6(n)),     // 正好覆盖全部
    ("key:000010", "key:000020"),         // 块中间开始、块中间结束
    ("key:000015", "key:000016"),         // 只有一条
    ("key:000015", "key:000015"),         // 空区间（左闭右开）
    ("key:" + pad6(n - 1), "key:999999"), // 最后一条
    ("key:" + pad6(n), "key:999999"),     // 完全越界（右）
    ("aaaa", "bbbb"),                     // 完全越界（左）
    ("key:000000", "key:000001"),         // 第一条
    ("key:000100", "key:000100"),         // 空区间，落在块边界上
  ]
  for c in cases {
    let (s, e) = c
    let sb = @utf8.encode(s)
    let eb = @utf8.encode(e)
    let want : Array[Entry] = []
    for en in all {
      if compare_bytes(en.key, sb) >= 0 && compare_bytes(en.key, eb) < 0 {
        want.push(en)
      }
    }
    let got = r.scan_range(sb, eb)
    assert_eq(got.length(), want.length())
    for i in 0..<want.length() {
      assert_eq(got[i].key, want[i].key)
      assert_eq(got[i].value, want[i].value)
      assert_eq(got[i].seq, want[i].seq)
    }
  }
  // 逐条区间：start = 第 i 个 key，end = 第 i+1 个 key，必须恰好命中一条
  for i in 0..<(n - 1) {
    let got = r.scan_range(@utf8.encode(keys[i]), @utf8.encode(keys[i + 1]))
    assert_eq(got.length(), 1)
    assert_eq(got[0].key, @utf8.encode(keys[i]))
  }
}

///|
/// 文件 key 区间的下界必须**真的**是下界。
///
/// 这条是整个范围判断的安全前提：`get` 现在会先用 `[lo, hi]` 排除文件，
/// 如果 `lo` 比真实最小 key 大，落在 `[真实最小, lo)` 里的 key 会被跳过 ——
/// 「数据明明在，却查不到」。所以这里逐个文件核对区间与全部条目的关系。
test "sst: 文件区间必须真实包住所有 entry" {
  for n in [1, 2, 17, 300, 3000] {
    let raw = build_sst(n)
    let r = must_open(raw)
    let rng = match r.range {
      Some(p) => p
      None => {
        assert_true(false)
        (b"", b"")
      }
    }
    let (lo, hi) = rng
    let all = r.entries()
    assert_eq(all.length(), n)
    for e in all {
      assert_true(compare_bytes(e.key, lo) >= 0)
      assert_true(compare_bytes(e.key, hi) <= 0)
    }
    // 而且必须紧贴首尾两条 —— 松了说明取错了来源（比如拿了首块的 last_key 当下界）
    assert_eq(all[0].key, lo)
    assert_eq(all[n - 1].key, hi)
  }
}

///|
/// 区间两端的 key 必须查得到。这是最容易写错的地方：
/// `hi` 用的是 `<=` 还是 `<`，差一个等号就丢一条。
test "sst: 区间端点的 key 都能查到" {
  let raw = build_sst(500)
  let r = must_open(raw)
  let (lo, hi) = match r.range {
    Some(p) => p
    None => {
      assert_true(false)
      (b"", b"")
    }
  }
  assert_true(r.get(lo) is Some(_))
  assert_true(r.get(hi) is Some(_))
}

///|
/// 区间外紧邻的 key 查不到 —— 反方向也要验，
/// 否则「范围判断恒为真」这种退化实现也能通过上面的测试。
test "sst: 区间外的 key 查不到" {
  let raw = build_sst(200)
  let r = must_open(raw)
  let (lo, hi) = match r.range {
    Some(p) => p
    None => {
      assert_true(false)
      (b"", b"")
    }
  }
  // 比下界小：`"key:00000"` 是 `"key:000000"` 的严格前缀，字典序更小
  let below = @utf8.encode("key:00000")
  assert_true(compare_bytes(below, lo) < 0)
  assert_true(r.get(below) is None)
  // 比上界大一条
  let above = @utf8.encode("key:99999" + "9")
  assert_true(compare_bytes(above, hi) > 0)
  assert_true(r.get(above) is None)
}

///|
/// 空文件拿不到区间，必须退化成「不判断」而不是「判断为不相交」。
/// 若这里返回 `Some` 并带一个空区间，任何 key 都会被排除。
test "sst: 空文件不启用范围判断" {
  let r = must_open(SstWriter::new().finish())
  assert_true(r.range is None)
  assert_true(r.get(@utf8.encode("x")) is None)
}

///|
/// 单条 entry 的文件，上下界是同一个 key。
test "sst: 单条 entry 的上下界相同" {
  let w = SstWriter::new()
  w.add(mk("only", "v", 1UL))
  let r = must_open(w.finish())
  let (lo, hi) = match r.range {
    Some(p) => p
    None => {
      assert_true(false)
      (b"", b"")
    }
  }
  assert_eq(lo, @utf8.encode("only"))
  assert_eq(hi, @utf8.encode("only"))
  assert_true(r.get(@utf8.encode("only")) is Some(_))
  assert_true(r.get(@utf8.encode("onl")) is None)
  assert_true(r.get(@utf8.encode("onlz")) is None)
}

///|
/// 区间完全在文件之外时，`scan_range` 直接返回空，连索引二分都不做。
test "sst: 区间不相交时 scan_range 返回空" {
  let r = must_open(build_sst(300))
  let empty = r.scan_range(@utf8.encode("aaa"), @utf8.encode("aab"))
  assert_eq(empty.length(), 0)
  let empty2 = r.scan_range(@utf8.encode("zzz"), @utf8.encode("zzz~"))
  assert_eq(empty2.length(), 0)
}
