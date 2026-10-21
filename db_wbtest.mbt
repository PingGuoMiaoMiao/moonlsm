///|
/// Db 层测试：把 memtable、SST、归并三块串起来验证。
///
/// 重点是「跨层」的语义：flush 之后数据还在不在、删除能不能压住
/// 底层 SST 的旧值、多个 SST 同时存在时读的是不是最新的那条。

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
  let db = Db::new(1 << 20)
  ignore(db.put(kb("a"), kb("1")))
  assert_eq(db.get(kb("a")), Some(kb("1")))
  ignore(db.put(kb("a"), kb("2")))
  assert_eq(db.get(kb("a")), Some(kb("2")))
  assert_true(db.get(kb("nope")) is None)
}

///|
test "db: 删除后读不到，但墓碑还在（不能真删条目）" {
  let db = Db::new(1 << 20)
  ignore(db.put(kb("a"), kb("1")))
  ignore(db.delete(kb("a")))
  assert_true(db.get(kb("a")) is None)
  // 墓碑必须留在 memtable 里，否则 flush 之后底层旧值会复活
  assert_eq(db.mem_entry_count(), 1)
}

///|
test "db: flush 之后数据仍然读得到" {
  let db = Db::new(1 << 20)
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
  let db = Db::new(1 << 20)
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
  let db = Db::new(1 << 20)
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
  let db = Db::new(1 << 20)
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
  let db = Db::new(1 << 20)
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
  let db = Db::new(512)
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
  let db = Db::new(300)
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
