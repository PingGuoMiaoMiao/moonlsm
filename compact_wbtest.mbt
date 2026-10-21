///|
/// Compaction 测试。
///
/// 这一层的测试有个特有的陷阱：**key 必须按轮次错开**。
///
/// 第一版里辅助函数写的是 `tag + pad6(i)`，每轮都写同一批 key，
/// 于是「4 轮 × 10 条 = 40 条数据」实际是「10 个 key 的 4 个版本」。
/// 断言 `get(k) == "r0-..."` 拿到 `"r3-..."` 报错，看起来像「归并按
/// 文件顺序而不是 seq 判断新旧」，其实只是测试自己写错了。
///
/// 所以这里的 key 是 `tag + pad_num(round * n + i)`，第几轮的 key
/// 落在第几个区间，互不重叠；需要「同一个 key 的多个版本」时，
/// 才刻意复用同一个 key（见「同 key 跨 4 个 SST」那条）。
///
/// 另一类容易漏的断言是「值对不对」。只断言 `get(k) is Some(...)`
/// 抓不到「key 还在但值是旧的」—— 而那正是归并排序写错时的症状。
/// `assert_rounds` 逐条比 value。

///|
/// 第 `round` 轮的第 `i` 个 key。
fn round_key(tag : String, n : Int, round : Int, i : Int) -> String {
  tag + pad_num((round * n + i).to_uint64())
}

///|
/// 与 `round_key` 配套的 value。把轮次写进值里，才能一眼看出读到的是哪一轮。
fn round_val(ver : String, tag : String, n : Int, round : Int, i : Int) -> String {
  ver + "r" + round.to_string() + "-" + round_key(tag, n, round, i)
}

///|
/// 写一轮数据（不 flush）。`ver` 用来区分「同一段 key 的第几次重写」。
fn[S : Storage] put_round_v(
  db : Db[S],
  tag : String,
  n : Int,
  round : Int,
  ver : String,
) -> Unit raise LsmError {
  for i in 0..<n {
    let k = round_key(tag, n, round, i)
    ignore(db.put(kb(k), kb(round_val(ver, tag, n, round, i))))
  }
}

///|
fn[S : Storage] put_round(
  db : Db[S],
  tag : String,
  n : Int,
  round : Int,
) -> Unit raise LsmError {
  put_round_v(db, tag, n, round, "")
}

///|
/// 写一轮数据并 flush。每调用一次，L0 多一个 SST。
fn[S : Storage] fill_round(
  db : Db[S],
  tag : String,
  n : Int,
  round : Int,
) -> Unit raise LsmError {
  put_round(db, tag, n, round)
  db.flush()
}

///|
/// 逐轮逐条校验 key 和 value。
///
/// 这里的 `raise` 不带 `LsmError`：`assert_eq` 失败抛的是 `Error`，
/// 而 `db.get` 本身不抛错。写成 `raise LsmError` 会把断言失败
/// 变成「错误类型不匹配」的编译错，而不是测试红。
fn[S] assert_rounds_v(
  db : Db[S],
  tag : String,
  n : Int,
  rounds : Int,
  ver : String,
) -> Unit raise {
  for round in 0..<rounds {
    for i in 0..<n {
      let k = round_key(tag, n, round, i)
      assert_eq(db.get(kb(k)), expect_bytes(Some(round_val(ver, tag, n, round, i))))
    }
  }
}

///|
fn[S] assert_rounds(
  db : Db[S],
  tag : String,
  n : Int,
  rounds : Int,
) -> Unit raise {
  assert_rounds_v(db, tag, n, rounds, "")
}

///|
/// L1 里各文件的编号，顺序与 `version` 一致（按 smallest 升序）。
fn[S] l1_numbers(db : Db[S]) -> Array[UInt64] {
  let out : Array[UInt64] = []
  for m in db.version.level(1) {
    out.push(m.number)
  }
  out
}

///|
/// 某个 key 在**所有**已加载 SST 里有多少条记录（含墓碑）。
///
/// 用 `get` 判断「删掉了」是不够的：`get` 只看第一个命中的文件，
/// 旧值可能还躺在更深层的文件里，只是被上层墓碑挡住了。
/// 要验证「数据真的被物理清掉」，必须直接数条目。
fn[S] count_entries(db : Db[S], key : Bytes) -> Int raise LsmError {
  let mut n = 0
  for s in db.ssts {
    for e in s.reader.entries() {
      if e.key == key {
        n = n + 1
      }
    }
  }
  n
}

///|
/// 某个编号的文件还在不在 `sst/` 目录里。
fn sst_exists(st : MemStorage, num : UInt64) -> Bool raise LsmError {
  let want = pad_num(num) + ".sst"
  for name in Storage::list_files(st, SST_DIR) {
    if name == want {
      return true
    }
  }
  false
}

///|
test "compact: L0 达到阈值自动归并 —— L0 清空、L1 不重叠、数据不丢" {
  let db = open_mem(1 << 20)
  // 4 轮 flush = 4 个 L0 文件，第 4 次 flush 末尾触发归并
  for r in 0..<4 {
    fill_round(db, "k", 10, r)
    if r < 3 {
      // 还没到阈值，L0 应该攒着
      assert_eq(db.level_sst_count(0), r + 1)
      assert_eq(db.level_sst_count(1), 0)
    }
  }
  assert_eq(db.level_sst_count(0), 0)
  assert_true(db.level_sst_count(1) >= 1)
  // 归并之后版本仍然自洽：L1 同层严格递增且不重叠
  assert_true(db.check_version_invariants())
  assert_rounds(db, "k", 10, 4)
}

///|
test "compact: 同 key 跨 4 个 SST 时取 seq 最大的那条" {
  let db = open_mem(1 << 20)
  // 刻意写同一个 key 的 4 个版本，每个版本一个 SST。
  // 归并若按文件顺序（而不是 seq）判断新旧，这里读到的是 v0。
  for r in 0..<4 {
    ignore(db.put(kb("hot"), kb("v" + r.to_string())))
    db.flush()
  }
  assert_eq(db.level_sst_count(0), 0)
  assert_eq(db.get(kb("hot")), expect_bytes(Some("v3")))
  // 归并后只剩一条记录，不是 4 条
  let mut n = 0
  for s in db.ssts {
    for e in s.reader.entries() {
      if e.key == kb("hot") {
        n = n + 1
      }
    }
  }
  assert_eq(n, 1)
}

///|
test "compact: 墓碑写进非最底层时必须留着，能压住更下层的旧值" {
  let db = open_mem(1 << 20)
  ignore(db.put(kb("gone"), kb("v0")))
  ignore(db.put(kb("keep"), kb("k0")))
  db.flush()
  ignore(db.delete(kb("gone")))
  db.flush()
  // 再补两轮凑够阈值
  fill_round(db, "f", 5, 0)
  fill_round(db, "f", 5, 1)
  assert_eq(db.level_sst_count(0), 0)
  // 读不到
  assert_eq(db.get(kb("gone")), expect_bytes(None))
  assert_eq(db.get(kb("keep")), expect_bytes(Some("k0")))
  // 但墓碑本身必须还在 —— 这一轮的输出进了 L1，而 L1 下面还有 L2，
  // 那里可能藏着 "gone" 的更旧版本，全靠这个墓碑压着。
  // 丢了它，删掉的数据就会在下次下沉时复活。
  assert_eq(count_entries(db, kb("gone")), 1)
}

///|
test "compact: 删除后重写 —— 归并后读到的是重写的值" {
  let db = open_mem(1 << 20)
  ignore(db.put(kb("phoenix"), kb("v0")))
  db.flush()
  ignore(db.delete(kb("phoenix")))
  db.flush()
  ignore(db.put(kb("phoenix"), kb("v2")))
  db.flush()
  fill_round(db, "f", 5, 0)
  assert_eq(db.level_sst_count(0), 0)
  // 墓碑 seq 比 v2 小，所以 v2 胜出。归并只留 seq 最大的那条。
  assert_eq(db.get(kb("phoenix")), expect_bytes(Some("v2")))
}

///|
test "compact: 输入文件在归并后被删除，只剩新文件" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  // 3 轮 flush —— 低于阈值，不会自动归并，这样才观察得到「归并前」
  for r in 0..<3 {
    fill_round(db, "k", 10, r)
  }
  assert_eq(db.level_sst_count(0), 3)
  let inputs = l1_numbers(db) // L1 还是空的，这里只是占位
  assert_eq(inputs.length(), 0)
  let before : Array[UInt64] = []
  for m in db.version.level(0) {
    before.push(m.number)
  }
  assert_eq(before.length(), 3)
  for num in before {
    assert_true(sst_exists(st, num))
  }
  db.compact_l0()
  // 输入文件必须被删掉：CURRENT 已经指向新 MANIFEST，旧文件没人引用
  for num in before {
    assert_false(sst_exists(st, num))
  }
  // 新文件存在，且数量与 L1 登记的一致
  let outs = l1_numbers(db)
  assert_true(outs.length() >= 1)
  assert_eq(outs.length(), db.level_sst_count(1))
  for num in outs {
    assert_true(sst_exists(st, num))
  }
  // 目录里只剩新文件
  assert_eq(Storage::list_files(st, SST_DIR).length(), outs.length())
  assert_rounds(db, "k", 10, 3)
}

///|
test "compact: 归并后断电重启，数据与层信息都还在" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  for r in 0..<4 {
    fill_round(db, "k", 10, r)
  }
  assert_eq(db.level_sst_count(0), 0)
  let l1_before = l1_numbers(db)
  // 进程崩溃：memtable 全丢，只剩磁盘上的 SST + MANIFEST
  st.power_loss()
  let db2 = Db::open(st, 1 << 20)
  assert_eq(db2.level_sst_count(0), 0)
  assert_eq(db2.level_sst_count(1), l1_before.length())
  assert_true(db2.check_version_invariants())
  let l1_after = l1_numbers(db2)
  assert_eq(l1_after.length(), l1_before.length())
  for i in 0..<l1_before.length() {
    assert_eq(l1_after[i], l1_before[i])
  }
  assert_rounds(db2, "k", 10, 4)
}

///|
test "compact: 第二次归并只碰范围重叠的文件" {
  let db = open_mem(1 << 20)
  // 第一段 a：L1 = [A]
  for r in 0..<4 {
    fill_round(db, "a", 10, r)
  }
  let after_a = l1_numbers(db)
  assert_eq(after_a.length(), 1)
  // 第二段 z：与 A 完全不相交 → A 原封不动，只新增一个文件
  for r in 0..<4 {
    fill_round(db, "z", 10, r)
  }
  let after_z = l1_numbers(db)
  assert_eq(after_z.length(), 2)
  assert_eq(after_z[0], after_a[0]) // 按 smallest 升序，a 段在前
  // 第三段 m：夹在中间 → L1 = [A, M, Z]
  for r in 0..<4 {
    fill_round(db, "m", 10, r)
  }
  let after_m = l1_numbers(db)
  assert_eq(after_m.length(), 3)
  assert_eq(after_m[0], after_a[0])
  assert_eq(after_m[2], after_z[1])
  let m_num = after_m[1]
  // 第四段：重写 m 段（与 M 的范围完全重叠）→ 只替换 M，A 和 Z 不动。
  // 这条是「归并只碰重叠文件」的核心断言：如果实现图省事把所有 L1
  // 文件都并进去，A 和 Z 的编号会变，这里就会红。
  for r in 0..<4 {
    put_round_v(db, "m", 10, r, "v2")
    db.flush()
  }
  let after_m2 = l1_numbers(db)
  assert_eq(after_m2.length(), 3)
  assert_eq(after_m2[0], after_a[0])
  assert_eq(after_m2[2], after_z[1])
  assert_true(after_m2[1] != m_num)
  assert_true(db.check_version_invariants())
  // 重写后的值生效，a / z 两段也没被弄坏
  assert_rounds_v(db, "m", 10, 4, "v2")
  assert_rounds(db, "a", 10, 4)
  assert_rounds(db, "z", 10, 4)
}

///|
test "compact: 归并后 scan 仍然全局有序且过滤墓碑" {
  let db = open_mem(1 << 20)
  for r in 0..<4 {
    fill_round(db, "k", 10, r)
  }
  // 删掉 3 条（第 0 轮的 3 个 key），再补一轮把墓碑也并进去
  for i in 0..<3 {
    ignore(db.delete(kb(round_key("k", 10, 0, i))))
  }
  db.flush()
  // 这次 flush 让 L0 又到 1，还没到阈值，墓碑在 memtable 里。
  // 再补 3 轮触发归并，让墓碑真正经过一次 compaction。
  for r in 0..<3 {
    fill_round(db, "q", 5, r)
  }
  assert_eq(db.level_sst_count(0), 0)
  let got = db.scan(kb(""), kb("zzzzzz"), 1000)
  // 40 条 k 段 - 3 条删除 + 15 条 q 段（3 轮 × 5 条）
  assert_eq(got.length(), 40 - 3 + 15)
  let mut prev = kb("")
  for p in got {
    // 严格递增：既验证有序，也验证没有重复
    assert_true(compare_bytes(prev, p.key) < 0)
    prev = p.key
    assert_true(pk(p) != round_key("k", 10, 0, 0))
    assert_true(pk(p) != round_key("k", 10, 0, 1))
    assert_true(pk(p) != round_key("k", 10, 0, 2))
  }
}

///|
test "compact: L0 只有一个文件时不归并" {
  let db = open_mem(1 << 20)
  fill_round(db, "k", 5, 0)
  assert_eq(db.level_sst_count(0), 1)
  db.compact_l0()
  // 一个文件没什么可归并的，原样留着 —— 不能变成「归并出一个空 L1」
  assert_eq(db.level_sst_count(0), 1)
  assert_eq(db.level_sst_count(1), 0)
  assert_eq(db.sst_count(), 1)
  assert_rounds(db, "k", 5, 1)
}

///|
test "compact: 连续多轮写入下 L0 始终低于阈值" {
  let db = open_mem(1 << 20)
  for r in 0..<12 {
    fill_round(db, "k", 10, r)
    assert_true(db.level_sst_count(0) < L0_COMPACT_TRIGGER)
    assert_true(db.check_version_invariants())
  }
  // 12 轮里触发了 3 次归并
  assert_true(db.level_sst_count(1) >= 1)
  assert_rounds(db, "k", 10, 12)
  // 归并没有把数据弄重复：条目数恰好等于写入的 key 数
  let got = db.scan(kb(""), kb("zzzzzz"), 10000)
  assert_eq(got.length(), 120)
}

// ---------------------------------------------------------------------------
// D6：分层触发 + 墓碑只在最底层丢弃
// ---------------------------------------------------------------------------

///|
test "compact: 触发条件 —— L0 看个数、L1 看字节、最底层不再下沉" {
  // L0：个数到 4 才触发，跟字节数无关
  assert_false(should_compact_level(0, 3, 1UL << 30))
  assert_true(should_compact_level(0, 4, 0UL))
  // L1：字节数到 1 MiB 才触发，边界是 `>=`（正好等于也触发）
  assert_false(should_compact_level(1, 1, LEVEL1_TARGET_BYTES - 1UL))
  assert_true(should_compact_level(1, 1, LEVEL1_TARGET_BYTES))
  // 最底层（L2）无论多大都不往下沉
  assert_false(should_compact_level(2, 1000, 1UL << 40))
  // 越界层号一律不归并 —— 宁可不做，也不要越界写
  assert_false(should_compact_level(-1, 1000, 1UL << 40))
  assert_false(should_compact_level(3, 1000, 1UL << 40))
  // 容量按 fanout 倍增：L1 = 1 MiB、L2 = 10 MiB
  assert_eq(level_target_bytes(0), 0UL)
  assert_eq(level_target_bytes(1), 1UL << 20)
  assert_eq(level_target_bytes(2), 10UL << 20)
  // 最底层只有一个
  assert_false(is_bottom_level(0))
  assert_false(is_bottom_level(1))
  assert_true(is_bottom_level(2))
}

///|
test "compact: 墓碑写进最底层时被丢弃 —— 数据真的消失，不只是读不到" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put(kb("gone"), kb("v0")))
  ignore(db.put(kb("keep"), kb("k0")))
  db.flush()
  ignore(db.delete(kb("gone")))
  db.flush()
  fill_round(db, "f", 5, 0)
  fill_round(db, "f", 5, 1)
  // 这一轮 L0 → L1：L1 不是最底层，墓碑必须留着
  assert_eq(db.level_sst_count(0), 0)
  assert_eq(count_entries(db, kb("gone")), 1)
  // L1 → L2：写进最底层，墓碑可以丢
  db.compact_level(1)
  assert_eq(db.level_sst_count(1), 0)
  assert_true(db.level_sst_count(2) >= 1)
  // 物理上一条都不剩 —— 这是「丢墓碑」与「只是被挡住」的区别
  assert_eq(count_entries(db, kb("gone")), 0)
  assert_eq(db.get(kb("gone")), expect_bytes(None))
  // 别的 key 不能跟着一起没
  assert_eq(count_entries(db, kb("keep")), 1)
  assert_eq(db.get(kb("keep")), expect_bytes(Some("k0")))
  assert_rounds(db, "f", 5, 2)
  // 重启后依然读不到：不是靠内存里残留的状态「碰巧」对
  st.power_loss()
  let db2 = Db::open(st, 1 << 20)
  assert_eq(db2.get(kb("gone")), expect_bytes(None))
  assert_eq(db2.get(kb("keep")), expect_bytes(Some("k0")))
  assert_eq(count_entries(db2, kb("gone")), 0)
}

///|
test "compact: 删除后重写 —— 到最底层也不复活、不丢" {
  let db = open_mem(1 << 20)
  ignore(db.put(kb("phoenix"), kb("v0")))
  db.flush()
  ignore(db.delete(kb("phoenix")))
  db.flush()
  ignore(db.put(kb("phoenix"), kb("v2")))
  db.flush()
  fill_round(db, "f", 5, 0)
  assert_eq(db.level_sst_count(0), 0)
  assert_eq(db.get(kb("phoenix")), expect_bytes(Some("v2")))
  db.compact_level(1)
  // 三个版本（v0 / 墓碑 / v2）归并后只剩 seq 最大的 v2。
  // 若「丢墓碑」写成了「见到墓碑就删 key」，这里会是 None；
  // 若丢墓碑时按文件顺序而不是 seq 判断，这里会是 v0。
  assert_eq(db.get(kb("phoenix")), expect_bytes(Some("v2")))
  assert_eq(count_entries(db, kb("phoenix")), 1)
}

///|
/// 造一个大约 `size` 字节的 value。倍增拼接再截断：
/// 逐次追加是 O(size²) 的字符串拷贝，4 KiB 要拷两百多次。
fn pad_to(seed : String, size : Int) -> String {
  let mut s = seed
  while s.length() < size {
    s = s + s
  }
  if s.length() > size {
    s = s[:size].to_owned()
  }
  s
}

///|
test "compact: L1 超过容量上限会自动下沉到 L2（端到端，真数据）" {
  // mem_limit 给 4 MiB：每轮 75 条 × 4 KiB ≈ 300 KiB，不会中途自动 flush，
  // 这样「一轮一个 SST」的结构才是确定的。
  let db = open_mem(4 << 20)
  let val = pad_to("x", 4096)
  assert_eq(val.length(), 4096)
  for r in 0..<4 {
    for i in 0..<75 {
      let k = round_key("b", 75, r, i)
      ignore(db.put(kb(k), @utf8.encode(val + k)))
    }
    db.flush()
  }
  // 4 × 75 × ~4 KiB ≈ 1.2 MiB > L1 上限 1 MiB → 第 4 次 flush 的末尾
  // 先做 L0 → L1，再发现 L1 超了，接着做 L1 → L2。一次 flush 两次归并。
  assert_eq(db.level_sst_count(0), 0)
  assert_eq(db.level_sst_count(1), 0)
  assert_true(db.level_sst_count(2) >= 1)
  assert_true(db.check_version_invariants())
  // 数据一条不丢
  for r in 0..<4 {
    for i in 0..<75 {
      let k = round_key("b", 75, r, i)
      assert_eq(db.get(kb(k)), expect_bytes(Some(val + k)))
    }
  }
}

///|
test "compact: 三层结构断电重启后完整恢复" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  for r in 0..<4 {
    fill_round(db, "k", 10, r)
  }
  db.compact_level(1)
  assert_eq(db.level_sst_count(0), 0)
  assert_eq(db.level_sst_count(1), 0)
  let l2_before : Array[UInt64] = []
  for m in db.version.level(2) {
    l2_before.push(m.number)
  }
  assert_true(l2_before.length() >= 1)
  st.power_loss()
  let db2 = Db::open(st, 1 << 20)
  assert_eq(db2.level_count(), 3)
  assert_eq(db2.level_sst_count(0), 0)
  assert_eq(db2.level_sst_count(1), 0)
  assert_eq(db2.level_sst_count(2), l2_before.length())
  assert_true(db2.check_version_invariants())
  assert_rounds(db2, "k", 10, 4)
}
