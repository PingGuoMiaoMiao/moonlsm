///|
/// Db 层测试：把 memtable、SST、归并三块串起来验证。
///
/// 重点是「跨层」的语义：flush 之后数据还在不在、删除能不能压住
/// 底层 SST 的旧值、多个 SST 同时存在时读的是不是最新的那条。

///|
/// 用内存后端开一个库。断电语义由 `MemStorage::power_loss` 提供，
/// 所以这一层可以在三个后端上跑，也不需要临时目录。
fn open_mem(mem_limit : Int32) -> Db[MemStorage] raise LsmError {
  Db::open(MemStorage::new(), mem_limit)
}

///|
fn kb(s : String) -> Bytes {
  @utf8.encode(s)
}

///|
fn vb(p : KvPair) -> String {
  @utf8.decode_lossy(p.value)
}

///|
fn pk(p : KvPair) -> String {
  @utf8.decode_lossy(p.key)
}

///|
/// 参考模型的 `String?` 转成引擎的 `Bytes?`，便于直接比对。
/// 这一版 core 没有 `Option::map`，手写一个。
fn expect_bytes(o : String?) -> Bytes? {
  match o {
    Some(s) => Some(@utf8.encode(s))
    None => None
  }
}

///|
test "db: put 后能读到，覆盖写读到最新值" {
  let db = open_mem(1 << 20)
  ignore(db.put(kb("a"), kb("1")))
  assert_eq(db.get(kb("a")), Some(kb("1")))
  ignore(db.put(kb("a"), kb("2")))
  assert_eq(db.get(kb("a")), Some(kb("2")))
  assert_true(db.get(kb("nope")) is None)
}

///|
test "db: 删除后读不到，但墓碑还在（不能真删条目）" {
  let db = open_mem(1 << 20)
  ignore(db.put(kb("a"), kb("1")))
  ignore(db.delete(kb("a")))
  assert_true(db.get(kb("a")) is None)
  // 墓碑必须留在 memtable 里，否则 flush 之后底层旧值会复活
  assert_eq(db.mem_entry_count(), 1)
}

///|
test "db: flush 之后数据仍然读得到" {
  let db = open_mem(1 << 20)
  for i in 0..<100 {
    ignore(db.put(kb("k" + pad6(i)), kb("v" + i.to_string())))
  }
  db.flush()
  assert_eq(db.sst_count(), 1)
  for i in 0..<100 {
    assert_eq(db.get(kb("k" + pad6(i))), Some(kb("v" + i.to_string())))
  }
}

///|
test "db: flush 之后覆盖写，读到的是新值" {
  let db = open_mem(1 << 20)
  ignore(db.put(kb("a"), kb("旧")))
  db.flush()
  ignore(db.put(kb("a"), kb("新")))
  assert_eq(db.get(kb("a")), Some(kb("新")))
  // 再刷一次，两个 SST 里各有一版 a，读最新的
  db.flush()
  assert_eq(db.sst_count(), 2)
  assert_eq(db.get(kb("a")), Some(kb("新")))
}

///|
test "db: flush 之后删除，旧值必须被墓碑压住" {
  // 这是「删除失效」最典型的触发路径：
  // 旧值在 SST 里，墓碑在 memtable 里，get 必须让墓碑赢。
  let db = open_mem(1 << 20)
  ignore(db.put(kb("a"), kb("v1")))
  ignore(db.put(kb("b"), kb("v2")))
  db.flush()
  ignore(db.delete(kb("a")))
  assert_true(db.get(kb("a")) is None)
  assert_eq(db.get(kb("b")), Some(kb("v2")))
  // 再把墓碑刷下去，跨两个 SST 依然是删除状态
  db.flush()
  assert_true(db.get(kb("a")) is None)
  assert_eq(db.get(kb("b")), Some(kb("v2")))
}

///|
test "db: scan 有序、左闭右开、过滤墓碑" {
  let db = open_mem(1 << 20)
  for i in 0..<10 {
    ignore(db.put(kb("k" + pad6(i)), kb("v" + i.to_string())))
  }
  ignore(db.delete(kb("k000003")))
  let got = db.scan(kb("k000002"), kb("k000006"), 100)
  // 期望 k2, k4, k5 —— k3 被删、k6 是开区间不含
  assert_eq(got.length(), 3)
  assert_eq(pk(got[0]), "k000002")
  assert_eq(pk(got[1]), "k000004")
  assert_eq(pk(got[2]), "k000005")
  assert_eq(vb(got[0]), "v2")
}

///|
test "db: scan 跨 memtable 与多个 SST 仍然是全局有序的" {
  let db = open_mem(1 << 20)
  // 三轮：每轮写一批、刷一次，制造 3 个 SST + 1 个 memtable
  for round in 0..<3 {
    for i in 0..<20 {
      ignore(
        db.put(kb("k" + pad6(round * 20 + i)), kb("r" + round.to_string())),
      )
    }
    db.flush()
  }
  for i in 0..<5 {
    ignore(db.put(kb("k" + pad6(100 + i)), kb("tail")))
  }
  assert_eq(db.sst_count(), 3)
  let got = db.scan(kb(""), kb("zzzzzzzz"), 1000)
  assert_eq(got.length(), 65)
  for i in 1..<got.length() {
    assert_true(compare_bytes(got[i - 1].key, got[i].key) < 0)
  }
}

///|
test "db: memtable 写满会自动 flush" {
  let db = open_mem(512)
  for i in 0..<200 {
    ignore(db.put(kb("k" + pad6(i)), kb("value-" + i.to_string())))
  }
  assert_true(db.flush_count() > 0)
  // 自动 flush 不能丢数据
  for i in 0..<200 {
    assert_eq(db.get(kb("k" + pad6(i))), Some(kb("value-" + i.to_string())))
  }
}

///|
test "db: 差分测试 —— 2000 步随机操作与 Map 参考模型一致" {
  // 参考模型用最朴素的 Map：它是「正确答案」的定义，
  // 故意不共享任何实现细节，避免「两个同样的错误互相验证」。
  // mem_limit 故意设得很小（300 字节），让 2000 步里发生几十次 flush，
  // 否则整个测试只在 memtable 里跑，等于没测跨层
  let db = open_mem(300)
  let model : Map[String, String] = Map([])
  let rng = TestRng::new(777UL)
  let pool = 40
  for step in 0..<2000 {
    let k = "key" + pad6(rng.below(pool))
    if rng.below(4) == 0 {
      ignore(db.delete(kb(k)))
      model.remove(k)
    } else {
      let v = "v" + step.to_string()
      ignore(db.put(kb(k), kb(v)))
      model.set(k, v)
    }
    // 每 50 步抽查一遍，比最后一次性比对更容易定位出错的步数
    if step % 50 == 0 {
      for i in 0..<pool {
        let kk = "key" + pad6(i)
        assert_eq(db.get(kb(kk)), expect_bytes(model.get(kk)))
      }
    }
  }
  // 最终全量比对
  for i in 0..<pool {
    let kk = "key" + pad6(i)
    assert_eq(db.get(kb(kk)), expect_bytes(model.get(kk)))
  }
  // scan 也必须与参考模型一致
  let want : Array[String] = []
  for k, _ in model {
    want.push(k)
  }
  want.sort_by(fn(a, b) { compare_strings(a, b) })
  let got = db.scan(kb(""), kb("zzzz"), 1000)
  assert_eq(got.length(), want.length())
  for i in 0..<want.length() {
    assert_eq(pk(got[i]), want[i])
    assert_eq(vb(got[i]), model.get(want[i]).unwrap_or(""))
  }
  // 差分测试跑完，确认真的经历了多次 flush，否则等于只测了 memtable
  assert_true(db.flush_count() > 5)
}

// ---------------------------------------------------------------------------
// 持久化与崩溃恢复
//
// 这一组是 ADR-0003 里 C1「已确认的写入必不丢」的可执行版本。
//
// 为什么不用 kill -9：进程被杀时 OS 页缓存还在，下次读文件照样能读到。
// 一个从不 fsync 的实现可以通过全部 kill -9 测试，然后在第一次真断电时
// 丢掉已 ack 的写入。`MemStorage::power_loss()` 把「未落盘的内容」直接抹掉，
// 正好补上这个盲区，而且不依赖虚拟机、不依赖操作系统、三个后端都能跑。
// ---------------------------------------------------------------------------

///|
test "db: 未 flush 的写入在断电后从 WAL 恢复（C1）" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put(kb("a"), kb("1")))
  ignore(db.put(kb("b"), kb("2")))
  ignore(db.delete(kb("a")))
  // memtable 全丢，磁盘上只剩 WAL —— 这就是「进程崩溃」的样子
  st.power_loss()
  let db2 = Db::open(st, 1 << 20)
  // a 被删了，b 还在
  assert_true(db2.get(kb("a")) is None)
  assert_eq(db2.get(kb("b")), expect_bytes(Some("2")))
}

///|
test "db: flush 之后断电，数据从 SST 恢复而不是 WAL" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put(kb("k1"), kb("v1")))
  db.flush()
  st.power_loss()
  let db2 = Db::open(st, 1 << 20)
  assert_eq(db2.get(kb("k1")), expect_bytes(Some("v1")))
  assert_eq(db2.sst_count(), 1)
  // flush 之后 WAL 被清空，只剩文件头
  assert_eq(db2.wal_bytes(), 8)
}

///|
test "db: flush 之后再写再断电，SST 与 WAL 的内容合并恢复" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put(kb("k1"), kb("old")))
  db.flush()
  ignore(db.put(kb("k1"), kb("new")))
  ignore(db.put(kb("k2"), kb("v2")))
  st.power_loss()
  let db2 = Db::open(st, 1 << 20)
  // k1 必须是新值：WAL 里的记录 seq 更大，归并时胜出
  assert_eq(db2.get(kb("k1")), expect_bytes(Some("new")))
  assert_eq(db2.get(kb("k2")), expect_bytes(Some("v2")))
}

///|
test "db: 重开后 seq 单调递增，SST 编号不被复用" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  let s1 = db.put(kb("a"), kb("1"))
  db.flush()
  st.power_loss()
  let db2 = Db::open(st, 1 << 20)
  let s2 = db2.put(kb("b"), kb("2"))
  // seq 必须严格更大：否则新写入在归并时会输给旧 SST 里的同 key 条目，
  // 表现为「写进去读不出来」
  assert_true(s2 > s1)
  db2.flush()
  // 编号从已有文件的最大值往后排，不能覆盖 SST-000001
  assert_eq(db2.sst_count(), 2)
  assert_eq(db2.get(kb("a")), expect_bytes(Some("1")))
  assert_eq(db2.get(kb("b")), expect_bytes(Some("2")))
}

///|
test "db: WAL 尾部有半条记录时，只丢那一条，其余完好（不 panic）" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put(kb("a"), kb("1")))
  ignore(db.put(kb("b"), kb("2")))
  let good_bytes = db.wal_bytes()
  // 手工接上半帧垃圾并让它落盘，模拟「写到一半断电」
  Storage::append_file(st, db.wal_name(), b"\x00\x00\x00\x00\x05\x01")
  Storage::sync_file(st, db.wal_name())
  st.power_loss()
  // 恢复过程不能 panic，只能丢尾部
  let db2 = Db::open(st, 1 << 20)
  assert_eq(db2.get(kb("a")), expect_bytes(Some("1")))
  assert_eq(db2.get(kb("b")), expect_bytes(Some("2")))
  // 坏尾巴被剪掉了：WAL 被重写成「只有完整好帧」的版本
  assert_eq(db2.wal_bytes(), good_bytes)
}

///|
test "db: WAL 文件头被改坏时重建空 WAL，而不是拒绝启动" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put(kb("a"), kb("1")))
  db.flush()
  // 把文件头改成垃圾
  Storage::write_file(st, db.wal_name(), b"XXXX\x01\x00\x00\x00")
  Storage::sync_file(st, db.wal_name())
  st.power_loss()
  // 不抛错，能起来；已 flush 的数据在 SST 里，不受影响
  let db2 = Db::open(st, 1 << 20)
  assert_eq(db2.get(kb("a")), expect_bytes(Some("1")))
  assert_eq(db2.wal_bytes(), 8)
}

///|
test "db: fsync 失败时 put 必须抛错，且数据不能进 memtable" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put(kb("a"), kb("1")))
  st.set_fail_sync(true)
  // 调用方拿不到 ack
  assert_true(
    raises_lsm(fn() raise LsmError { ignore(db.put(kb("b"), kb("2"))) }),
  )
  // 关键：失败的写入不能出现在 memtable 里。否则「读得到、没持久」，
  // 下次崩溃就凭空消失 —— 这比直接报错严重得多
  assert_true(db.get(kb("b")) is None)
  st.set_fail_sync(false)
  st.power_loss()
  let db2 = Db::open(st, 1 << 20)
  assert_true(db2.get(kb("b")) is None)
  assert_eq(db2.get(kb("a")), expect_bytes(Some("1")))
}

///|
test "db: 空目录开库不报错，且立刻写下 WAL 文件头" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  assert_eq(db.sst_count(), 0)
  assert_eq(db.last_seq(), 0UL)
  assert_eq(db.wal_bytes(), 8)
  assert_true(Storage::read_file(st, db.wal_name()) is Some(_))
}

///|
test "db: close 之后读写都报 Closed，而不是静默继续用" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  db.close()
  assert_true(
    raises_lsm(fn() raise LsmError { ignore(db.put(kb("a"), kb("1"))) }),
  )
  assert_true(raises_lsm(fn() raise LsmError { db.flush() }))
}

///|
test "db: 多次重启的累积状态正确" {
  let st = MemStorage::new()
  let mut round = 0
  while round < 5 {
    let db = Db::open(st, 1 << 20)
    ignore(db.put(kb("r\{round}"), kb("v\{round}")))
    if round % 2 == 0 {
      db.flush()
    }
    db.close()
    // 每一轮都「断电」，逼它从磁盘恢复
    st.power_loss()
    round = round + 1
  }
  let db = Db::open(st, 1 << 20)
  for i in 0..<5 {
    assert_eq(db.get(kb("r\{i}")), expect_bytes(Some("v\{i}")))
  }
}

// ---------------------------------------------------------------------------
// 组提交（group commit）
//
// 契约没变：ack 之前 fsync 必须成功。变的只是「一批里 fsync 几次」。
// 下面这组测试专门盯住「省掉的 fsync 有没有把 C1 一起省掉」。
// ---------------------------------------------------------------------------

///|
test "db: put_deferred 不 fsync —— 断电后整批丢失，符合预期" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  // 先落一条基线，确认库本身是好的
  ignore(db.put(kb("base"), kb("v")))
  let before = st.syncs()
  // 三条 deferred 写入：一条 fsync 都不该发生
  ignore(db.put_deferred(kb("a"), kb("1")))
  ignore(db.put_deferred(kb("b"), kb("2")))
  ignore(db.delete_deferred(kb("base")))
  assert_eq(st.syncs(), before)
  // 内存里读得到（还没 ack，允许）
  assert_eq(db.get(kb("a")), expect_bytes(Some("1")))
  // 断电：这些写入必须整体消失，而不是读出半个值
  st.power_loss()
  let db2 = Db::open(st, 1 << 20)
  assert_true(db2.get(kb("a")) is None)
  assert_true(db2.get(kb("b")) is None)
  // 基线那条是 put（已 fsync）写的，必须还在，且墓碑也丢了
  assert_eq(db2.get(kb("base")), expect_bytes(Some("v")))
}

///|
test "db: N 条 deferred + 1 次 sync，只 fsync 一次，且全部持久" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  let before = st.syncs()
  let n = 200
  for i in 0..<n {
    ignore(db.put_deferred(kb("k\{i}"), kb("v\{i}")))
  }
  // 关键断言：200 条写入只花了 0 次 fsync
  assert_eq(st.syncs(), before)
  db.sync()
  // 一次，不是 200 次
  assert_eq(st.syncs(), before + 1)
  st.power_loss()
  let db2 = Db::open(st, 1 << 20)
  for i in 0..<n {
    assert_eq(db2.get(kb("k\{i}")), expect_bytes(Some("v\{i}")))
  }
}

///|
test "db: 组提交中途触发 flush，已 flush 的部分仍然持久" {
  // mem_limit 设得很小，让 deferred 写入中途必定触发 flush。
  // 这验证的是「flush 已经通过 SST 落盘的数据，不会因为还没 sync 而丢」。
  let st = MemStorage::new()
  let db = Db::open(st, 1024)
  for i in 0..<60 {
    ignore(db.put_deferred(kb("k\{i}"), kb("payload-payload-payload")))
  }
  assert_true(db.sst_count() > 0)
  db.sync()
  st.power_loss()
  let db2 = Db::open(st, 1024)
  for i in 0..<60 {
    assert_eq(
      db2.get(kb("k\{i}")),
      expect_bytes(Some("payload-payload-payload")),
    )
  }
}

///|
test "db: 组提交时 sync 失败必须抛错，调用方拿不到 ack" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put_deferred(kb("a"), kb("1")))
  st.set_fail_sync(true)
  assert_true(raises_lsm(fn() raise LsmError { db.sync() }))
  st.set_fail_sync(false)
  // 没 sync 成功过，断电后必须丢
  st.power_loss()
  let db2 = Db::open(st, 1 << 20)
  assert_true(db2.get(kb("a")) is None)
}

///|
test "db: 组提交与逐条 put 混用，seq 仍然严格单调" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  let s1 = db.put(kb("a"), kb("1"))
  let s2 = db.put_deferred(kb("b"), kb("2"))
  db.sync()
  let s3 = db.put(kb("c"), kb("3"))
  assert_true(s2 > s1)
  assert_true(s3 > s2)
  // 覆盖写：后写的必须赢
  ignore(db.put_deferred(kb("a"), kb("new")))
  db.sync()
  assert_eq(db.get(kb("a")), expect_bytes(Some("new")))
}

// ---------------------------------------------------------------------------
// MANIFEST 与目录布局（Week 2 D3）
//
// 这一组测试盯的是「元信息」而不是「数据」：层信息有没有正确落盘、
// 重启后能不能读回来、元信息坏了会怎样。
// ---------------------------------------------------------------------------

///|
test "manifest: 新库打开后写下 CURRENT / MANIFEST / WAL 三件套" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  // CURRENT 必须存在，且内容是 MANIFEST-<数字>\n
  let cur = match Storage::read_file(st, CURRENT_FILE) {
    Some(b) => @utf8.decode_lossy(b)
    None => fail("CURRENT 应存在")
  }
  assert_true(cur.has_suffix("\n"))
  assert_true(cur.has_prefix("MANIFEST-"))
  assert_eq(db.manifest_name() + "\n", cur)
  // MANIFEST 本体可读回
  assert_true(Storage::read_file(st, db.manifest_name()) is Some(_))
  // 活跃 WAL 是 wal/000001.wal
  assert_eq(db.wal_name(), "wal/000001.wal")
  assert_true(Storage::read_file(st, "wal/000001.wal") is Some(_))
  // 还没有 SST
  assert_eq(db.level_sst_count(0), 0)
  assert_eq(db.sst_count(), 0)
}

///|
test "manifest: flush 后层信息落盘，重启后能读回" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put(kb("a"), kb("1")))
  ignore(db.put(kb("b"), kb("2")))
  db.flush()
  assert_eq(db.level_sst_count(0), 1)
  let first_sst_count = db.level_sst_count(0)
  // 再 flush 一次，L0 应该有两个
  ignore(db.put(kb("c"), kb("3")))
  db.flush()
  assert_eq(db.level_sst_count(0), 2)
  // 断电 + 重开：层信息必须从 MANIFEST 读回来
  st.power_loss()
  let db2 = Db::open(st, 1 << 20)
  assert_eq(db2.level_count(), db2.level_count()) // 至少一层
  assert_true(db2.level_count() >= 1)
  assert_eq(db2.level_sst_count(0), 2)
  assert_eq(db2.sst_count(), 2)
  assert_true(first_sst_count == 1)
  assert_eq(db2.get(kb("a")), expect_bytes(Some("1")))
  assert_eq(db2.get(kb("b")), expect_bytes(Some("2")))
  assert_eq(db2.get(kb("c")), expect_bytes(Some("3")))
}

///|
test "manifest: flush 会轮转 WAL —— 旧 WAL 被删，新编号更大" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  let old_wal = db.wal_name()
  ignore(db.put(kb("a"), kb("1")))
  db.flush()
  let new_wal = db.wal_name()
  assert_true(old_wal != new_wal)
  // 旧 WAL 已被删除：它的数据已经进了 SST，MANIFEST 也不再引用它
  assert_true(Storage::read_file(st, old_wal) is None)
  // 新 WAL 存在且是空的（只有文件头）
  match Storage::read_file(st, new_wal) {
    Some(b) => assert_eq(b.length(), 8)
    None => fail("新 WAL 应存在")
  }
  assert_eq(Storage::list_files(st, WAL_DIR).length(), 1)
}

///|
test "manifest: flush 后只保留一份 MANIFEST（旧的在切换后被删）" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put(kb("a"), kb("1")))
  db.flush()
  ignore(db.put(kb("b"), kb("2")))
  db.flush()
  let mut manifests = 0
  for f in Storage::list_files(st, "") {
    if f.has_prefix("MANIFEST-") {
      manifests = manifests + 1
    }
  }
  // 先写后删：切换成功之后旧的那份就没用了
  assert_eq(manifests, 1)
  assert_true(Storage::read_file(st, db.manifest_name()) is Some(_))
}

///|
test "manifest: 文件编号全局共享且不复用" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  let n0 = db.next_file_number()
  ignore(db.put(kb("a"), kb("1")))
  db.flush()
  let n1 = db.next_file_number()
  // 一次 flush 消耗两个号（SST + 新 WAL），再加一个 MANIFEST 号
  assert_true(n1 > n0)
  assert_true(n1 - n0 >= 3UL)
  st.power_loss()
  let db2 = Db::open(st, 1 << 20)
  // 重启之后编号必须继续往上走，不能回到 n0 ——
  // 否则新写的 SST 会覆盖已有文件，表现为「重启后数据变了」
  assert_true(db2.next_file_number() >= n1)
  ignore(db2.put(kb("b"), kb("2")))
  db2.flush()
  assert_true(db2.next_file_number() > n1)
}

///|
test "manifest: CURRENT 缺失但目录里有数据 → 拒绝启动（Corruption）" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put(kb("a"), kb("1")))
  db.flush()
  // 只删 CURRENT，SST / WAL / MANIFEST 都还在
  Storage::remove_file(st, CURRENT_FILE)
  st.power_loss()
  // 硬猜布局会静默丢数据，所以这里必须拒绝
  assert_true(raises_lsm(fn() raise LsmError { ignore(Db::open(st, 1 << 20)) }))
}

///|
test "manifest: 空目录不算 Corruption —— 那是新库" {
  let st = MemStorage::new()
  // 从没打开过，什么都没有
  let db = Db::open(st, 1 << 20)
  assert_eq(db.sst_count(), 0)
  assert_eq(db.last_seq(), 0UL)
}

///|
test "manifest: MANIFEST 被写坏 → 拒绝启动（不回退，回退会丢已 ack 数据）" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put(kb("a"), kb("1")))
  db.flush()
  ignore(db.put(kb("b"), kb("2")))
  db.flush()
  let cur_manifest = db.manifest_name()
  // 把当前 MANIFEST 的内容改成垃圾（CRC 必然对不上）
  Storage::write_file(st, cur_manifest, b"GARBAGE-GARBAGE")
  Storage::sync_file(st, cur_manifest)
  st.power_loss()
  // 这里**必须**拒绝启动，而不是退回某个旧版本。
  //
  // 回退看起来「更友好」，但会静默丢掉一批已经返回过 ack 的写入：
  // 那些数据在新 SST 里，而旧 MANIFEST 不认识那个 SST。
  // 拒绝启动则一个字节都没少 —— 文件都还在，人可以介入。
  assert_true(raises_lsm(fn() raise LsmError { ignore(Db::open(st, 1 << 20)) }))
}

///|
test "manifest: CURRENT 内容是垃圾 → 拒绝启动" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put(kb("a"), kb("1")))
  db.flush()
  Storage::write_file(st, CURRENT_FILE, b"not-a-manifest\n")
  Storage::sync_file(st, CURRENT_FILE)
  st.power_loss()
  assert_true(raises_lsm(fn() raise LsmError { ignore(Db::open(st, 1 << 20)) }))
}

///|
test "manifest: 孤儿 SST 不影响恢复，且它的编号不会被复用" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put(kb("a"), kb("1")))
  db.flush()
  // 手工造一个「崩溃在写完 SST、还没写 MANIFEST」的现场：
  // 一个编号很大的 SST 文件，但 MANIFEST 里没登记它
  let orphan_num = db.next_file_number() + 50UL
  let w = SstWriter::new()
  w.add({ key: kb("ghost"), value: kb("boo"), seq: 9999UL, deleted: false, })
  Storage::write_file(st, sst_path(orphan_num), w.finish())
  Storage::sync_file(st, sst_path(orphan_num))
  st.power_loss()
  let db2 = Db::open(st, 1 << 20)
  // 孤儿不在 MANIFEST 里 → 不会被加载
  assert_eq(db2.sst_count(), 1)
  assert_true(db2.get(kb("ghost")) is None)
  assert_eq(db2.get(kb("a")), expect_bytes(Some("1")))
  // 编号必须跳过孤儿，否则下一次 flush 会覆盖一个已存在的文件
  assert_true(db2.next_file_number() > orphan_num)
}

///|
test "manifest: seq 跨重启单调（MANIFEST 里的 last_seq 起作用）" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  let s1 = db.put(kb("a"), kb("1"))
  db.flush()
  // flush 会把 last_seq 写进 MANIFEST；即使 SST 和 WAL 都不含这个 seq，
  // 重启后的新写入也必须比它大
  st.power_loss()
  let db2 = Db::open(st, 1 << 20)
  assert_true(db2.last_seq() >= s1)
  let s2 = db2.put(kb("b"), kb("2"))
  assert_true(s2 > s1)
}
