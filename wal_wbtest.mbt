///|
/// WAL 测试。
///
/// 这一层的测试标准和别处不同：**重点不是「正常路径对」，而是「坏数据不炸」**。
/// 所以一半用例是在人为制造损坏 —— 截断、翻转字节、改长度字段、改魔数。
/// 崩溃恢复的代码路径只有在这些输入下才会被真正执行。

///|
fn wal_with(n : Int) -> Bytes {
  let w = WalWriter::new()
  for i in 0..<n {
    w.append(
      WalRecord::new(
        (i + 1).to_uint64(),
        Op::Put(kb("k" + pad6(i)), kb("v" + i.to_string())),
      ),
    )
  }
  w.to_bytes()
}

///|
test "wal: 文件头字节符合规范" {
  let raw = WalWriter::new().to_bytes()
  assert_eq(raw.length(), WAL_HEADER_SIZE)
  assert_bytes_eq(
    raw,
    bytes_of([0x4D, 0x57, 0x41, 0x4C, 0x01, 0x00, 0x00, 0x00]),
  )
}

///|
test "wal: 帧字节逐字节符合规范（黄金向量）" {
  let w = WalWriter::new()
  w.append(WalRecord::new(1UL, Op::Put(kb("a"), kb("1"))))
  w.append(WalRecord::new(2UL, Op::Delete(kb("a"))))
  let want = bytes_of([
    // 文件头 "MWAL" + version 1 + reserved 0
    0x4D, 0x57, 0x41, 0x4C, 0x01, 0x00, 0x00, 0x00,
    // 帧 1: crc32c(type+payload) 小端
     0x72, 0x3C, 0x02, 0xB3,
    //       length=6 (不含 type)
     0x06,
    //       type=0x01(完整记录)
     0x01,
    //       payload: seq=1 op=0x00(Put) klen=1 'a' vlen=1 '1'
     0x01, 0x00, 0x01, 0x61, 0x01, 0x31,
    // 帧 2: crc
     0x70, 0x20, 0x4A, 0xE7,
    //       length=4
     0x04,
    //       type=0x01
     0x01,
    //       payload: seq=2 op=0x01(Delete) klen=1 'a' —— 没有 value 段
     0x02, 0x01, 0x01, 0x61,
  ])
  assert_bytes_eq(w.to_bytes(), want)
}

///|
test "wal: Delete 帧不含 value 段（比同 key 的 Put 帧短）" {
  let put = WalWriter::new()
  put.append(WalRecord::new(1UL, Op::Put(kb("key"), kb(""))))
  let del = WalWriter::new()
  del.append(WalRecord::new(1UL, Op::Delete(kb("key"))))
  // Put 的 value 长度 0 也要写一个 varint32 的 0，所以多 1 字节
  assert_eq(del.size(), put.size() - 1)
}

///|
test "wal: 多条记录往返一致（含空 value 与大 value）" {
  let big = Buffer::Buffer()
  for i in 0..<5000 {
    big.write_byte((i % 253).to_byte())
  }
  let w = WalWriter::new()
  let recs : Array[WalRecord] = [
    WalRecord::new(1UL, Op::Put(kb("a"), kb("1"))),
    WalRecord::new(2UL, Op::Put(kb("empty"), kb(""))),
    WalRecord::new(3UL, Op::Delete(kb("a"))),
    WalRecord::new(4UL, Op::Put(kb("big"), big.to_bytes())),
    WalRecord::new(5UL, Op::Put(kb("名字"), kb("张三"))),
  ]
  for r in recs {
    w.append(r)
  }
  let rep = recover_wal(w.to_bytes())
  assert_true(rep.header_ok())
  assert_eq(rep.len(), 5)
  assert_eq(rep.is_truncated(), false)
  for i in 0..<5 {
    let got = rep.records()[i]
    assert_eq(got.seq, recs[i].seq)
    match (got.op, recs[i].op) {
      (Put(gk, gv), Put(wk, wv)) => {
        assert_eq(compare_bytes(gk, wk), 0)
        assert_eq(compare_bytes(gv, wv), 0)
      }
      (Delete(gk), Delete(wk)) => assert_eq(compare_bytes(gk, wk), 0)
      _ => assert_true(false)
    }
  }
}

///|
test "wal: 任意位置截断都不 panic，且只丢尾部" {
  // 这是 WAL 最重要的一条性质：断电可能发生在**任意字节**上。
  // 逐字节砍一遍，是唯一能覆盖「所有可能的断电时刻」的办法。
  let full = wal_with(5)
  for cut in 0..<=full.length() {
    let part = full[:cut].to_owned()
    let rep = recover_wal(part)
    // 不 panic 是隐含的（能跑到这里就说明没炸），这里断言的是语义：
    // 恢复出的记录数不超过 5，且 good_bytes 不会超过实际长度
    assert_true(rep.len() <= 5)
    assert_true(rep.good_bytes() <= cut)
    // 只要恢复出了 k 条，前 k 条就必须是完整正确的
    for i in 0..<rep.len() {
      assert_eq(rep.records()[i].seq, (i + 1).to_uint64())
    }
    // 只有刚好切在帧边界时才不该报截断
    if cut < full.length() {
      // 切在最后一个好帧之后，一定还有残留字节
      if rep.len() < 5 {
        assert_eq(rep.is_truncated(), rep.good_bytes() < cut)
      }
    }
  }
}

///|
test "wal: 中间帧 CRC 被改坏，只恢复到它之前" {
  let full = wal_with(5)
  // 第一帧从偏移 8 开始：crc(4) + length(1) + type(1) + payload。
  // 翻转偏移 16 的字节，落在第一帧 payload 里 —— CRC 必然对不上。
  let flipped = Buffer::Buffer()
  for i in 0..<full.length() {
    let v = if i == 16 { full[i].to_int() ^ 0xFF } else { full[i].to_int() }
    flipped.write_byte(v.to_byte())
  }
  let rep = recover_wal(flipped.to_bytes())
  assert_true(rep.is_truncated())
  // 第 1 帧坏了，后面全部丢；绝不能出现「半条记录被当成好记录」
  assert_eq(rep.len(), 0)
  assert_eq(rep.good_bytes(), WAL_HEADER_SIZE)
}

///|
test "wal: 魔数错或版本不认识时拒绝重放" {
  let raw = wal_with(3)
  // 改魔数
  let bad_magic = Buffer::Buffer()
  bad_magic.write_bytes(bytes_of([0x58, 0x57, 0x41, 0x4C])[:])
  bad_magic.write_bytes(raw[4:].to_owned()[:])
  let r1 = recover_wal(bad_magic.to_bytes())
  assert_eq(r1.header_ok(), false)
  assert_eq(r1.len(), 0)
  // 改版本号
  let bad_ver = Buffer::Buffer()
  bad_ver.write_bytes(raw[:4].to_owned()[:])
  write_fixed16(bad_ver, 2)
  bad_ver.write_bytes(raw[6:].to_owned()[:])
  let r2 = recover_wal(bad_ver.to_bytes())
  assert_eq(r2.header_ok(), false)
  assert_eq(r2.len(), 0)
}

///|
test "wal: length 字段被改成巨大值也不会 OOM 或 panic" {
  let raw = wal_with(2)
  // 第一帧的 length 在偏移 12（8 头 + 4 crc），改成 5 字节 varint 的极大值
  let b = Buffer::Buffer()
  b.write_bytes(raw[:12].to_owned()[:])
  // 0xFF 0xFF 0xFF 0xFF 0x07 = 2147483647
  b.write_bytes(bytes_of([0xFF, 0xFF, 0xFF, 0xFF, 0x07])[:])
  b.write_bytes(raw[13:].to_owned()[:])
  let rep = recover_wal(b.to_bytes())
  // 上限检查会让重放在这里停下，得到 0 条
  assert_eq(rep.len(), 0)
  assert_true(rep.is_truncated())
}

///|
test "wal: 空文件与只有文件头的文件" {
  let empty = recover_wal(b"")
  assert_eq(empty.header_ok(), false)
  assert_eq(empty.len(), 0)
  let header_only = recover_wal(WalWriter::new().to_bytes())
  assert_eq(header_only.header_ok(), true)
  assert_eq(header_only.len(), 0)
  // 只有文件头不算截断：这是一个合法的空 WAL
  assert_eq(header_only.is_truncated(), false)
}

///|
test "wal: replay_into 只应用 seq 大于 min_seq 的记录" {
  let w = WalWriter::new()
  for i in 0..<10 {
    w.append(
      WalRecord::new(
        (i + 1).to_uint64(),
        Op::Put(kb("k" + i.to_string()), kb("v")),
      ),
    )
  }
  let rep = recover_wal(w.to_bytes())
  assert_eq(rep.len(), 10)
  let mem = MemTable::new(1 << 20)
  // 前 6 条已经刷进 SST（min_seq = 6），只应重放 7..10
  let applied = rep.replay_into(mem, 6UL)
  assert_eq(applied, 4)
  assert_eq(mem.to_entries().length(), 4)
  assert_true(mem.get(kb("k0")) is None)
  assert_true(mem.get(kb("k6")) is Some(_))
}
