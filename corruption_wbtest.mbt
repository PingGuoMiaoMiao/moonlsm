///|
/// 损坏注入测试：把「磁盘上的字节被人改坏 / 被截断」这件事真的做出来，
/// 验证引擎的反应符合文档里承诺的那张表。
///
/// ## 为什么必须单独测这一层
///
/// 崩溃测试（`crash_test.py`）杀进程但不改字节 —— 它验证的是「写到一半断电」，
/// 而不是「文件被人用十六进制编辑器改坏了」。这两件事的失败模式完全不同：
///
/// - 断电：尾部不完整，**前缀一定是对的** → 可以安全截断
/// - 改坏：可能只有中间某个字节不对，**前缀是对的但后面不可信** → 不能猜
///
/// ## 三条处理策略（对应 `docs/design/format.md` §5.2）
///
/// | 坏在哪 | 策略 | 理由 |
/// |---|---|---|
/// | WAL 尾部 / 中间 | 截断到最后一个完整帧 | WAL 是「未刷盘的暂存区」，丢它最多丢未 ack 的写入 |
/// | WAL 文件头 / 版本 | 重建空 WAL | 同上，且 SST 里的数据已经由 MANIFEST 保证 |
/// | MANIFEST / SST | **拒绝启动** | 这些是「已 ack 数据」的唯一载体，猜错就是静默丢数据 |
///
/// 最后一条与 ADR-0006 是同一个判据：**任何自动决策都不能丢已经承诺不丢的数据**。

///|
/// 用来「写坏一个字节」的字节值。
///
/// 不用 `'Z'.to_byte()`：这个工具链里 `Char` 没有 `to_byte`。
/// 从 `@utf8.encode` 里取第 0 个字节是唯一不需要猜 API 的写法。
fn bad_byte() -> Byte {
  @utf8.encode("Z")[0]
}

///|
/// 截取前 `n` 字节，返回新的一份。
fn cut_to(b : Bytes, n : Int) -> Bytes {
  b[:n].to_owned()
}

///|
/// 把第 `at` 个字节换成 `value`，返回新的一份。
///
/// 名字不用 `flip` / `poke`：白盒测试的顶层标识符在整个包里共享，
/// `manifest_wbtest.mbt` 已经有一个 `flip`，重名直接编译失败。
fn corrupt_at(b : Bytes, at : Int, value : Byte) -> Bytes {
  let buf = Buffer::Buffer()
  buf.write_bytes(b[:at])
  buf.write_byte(value)
  buf.write_bytes(b[at + 1:])
  buf.to_bytes()
}

///|
/// 跑一个「应该失败」的打开动作，把错误信息取出来。
///
/// 只断言 `raises_lsm(...) == true` 太弱了：拒绝启动时必须告诉人
/// **哪个文件**坏了，否则面对一个几百 MB 的目录无从下手。
fn failure_message(f : () -> Unit raise LsmError) -> String {
  try {
    f()
    "<没有报错，但预期应该报错>"
  } catch {
    err => err.message()
  }
}

///|
/// 把 `n` 条记录编成一个完整 WAL（含文件头）。
fn wal_of(n : Int) -> Bytes {
  let buf = Buffer::Buffer()
  buf.write_bytes(empty_wal_bytes()[:])
  for i in 0..<n {
    let rec = WalRecord::new(
      (i + 1).to_uint64(),
      Op::Put(kb("k" + i.to_string()), kb("v" + i.to_string())),
    )
    buf.write_bytes(encode_frame(rec)[:])
  }
  buf.to_bytes()
}

///|
test "corruption: SST 被截断 → 拒绝启动，且错误信息里带文件名" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put(kb("a"), kb("1")))
  ignore(db.put(kb("b"), kb("2")))
  db.flush()
  let num = db.version.level(0)[0].number
  let p = sst_path(num)
  let raw = match Storage::read_file(st, p) {
    Some(b) => b
    None => fail("刚 flush 出来的 SST 读不到")
  }
  // 砍掉最后 10 字节：footer 不完整。
  // 必须用 `plant` 而不是 `write_file`：后者只改「当前视图」，
  // 紧接着的 `power_loss()` 会用 durable 那份把它盖回去，注入等于没做。
  MemStorage::plant(st, p, cut_to(raw, raw.length() - 10))
  st.power_loss()
  let msg = failure_message(fn() raise LsmError { ignore(Db::open(st, 1 << 20)) })
  // 必须点名是哪个文件。只说「数据损坏」等于没说。
  assert_true(msg.has_prefix("Corruption: "))
  assert_true(msg.contains(p))
}

///|
test "corruption: SST 被清空 → 拒绝启动" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put(kb("a"), kb("1")))
  db.flush()
  let num = db.version.level(0)[0].number
  let p = sst_path(num)
  MemStorage::plant(st, p, Bytes::new(0))
  st.power_loss()
  let msg = failure_message(fn() raise LsmError { ignore(Db::open(st, 1 << 20)) })
  assert_true(msg.contains(p))
}

///|
test "corruption: SST 的 footer magic 被改坏 → 拒绝启动" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put(kb("a"), kb("1")))
  db.flush()
  let num = db.version.level(0)[0].number
  let p = sst_path(num)
  let raw = match Storage::read_file(st, p) {
    Some(b) => b
    None => fail("刚 flush 出来的 SST 读不到")
  }
  // footer 的最后 4 字节是 magic，改掉它
  MemStorage::plant(st, p, corrupt_at(raw, raw.length() - 1, bad_byte()))
  st.power_loss()
  let msg = failure_message(fn() raise LsmError { ignore(Db::open(st, 1 << 20)) })
  assert_true(msg.contains(p))
}

///|
test "corruption: MANIFEST 登记的 SST 文件不见了 → 拒绝启动" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put(kb("a"), kb("1")))
  db.flush()
  let num = db.version.level(0)[0].number
  // 只删文件、不动 MANIFEST：这是「有人手工删了 sst 目录里的东西」
  Storage::remove_file(st, sst_path(num))
  st.power_loss()
  let msg = failure_message(fn() raise LsmError { ignore(Db::open(st, 1 << 20)) })
  assert_true(msg.contains(sst_path(num)))
}

///|
test "corruption: WAL 中间一条记录 CRC 坏 → 截断到它之前，不 panic" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  let wal_name = db.wal_name()
  // 三条记录：k0 / k1 / k2。故意在**中间**那条上做手脚。
  let good = wal_of(3)
  let header = empty_wal_bytes().length()
  let f1 = encode_frame(
    WalRecord::new(1UL, Op::Put(kb("k0"), kb("v0"))),
  )
  // 第 2 帧的 payload 起始位置：文件头 + 第 1 帧 + 第 2 帧的 crc(4) + len(1) + type(1)
  let second_payload = header + f1.length() + 4 + 1 + 1
  MemStorage::plant(st, wal_name, corrupt_at(good, second_payload, bad_byte()))
  st.power_loss()
  let db2 = Db::open(st, 1 << 20)
  // 第 1 条还在
  assert_eq(db2.get(kb("k0")), expect_bytes(Some("v0")))
  // 第 2 条之后的全部丢失 —— 这是**有意**的行为，不是 bug：
  // CRC 不对说明「从这一条开始边界都不可信」，继续往后跳可能跳进垃圾。
  // 宁可停在一个确定的位置，也不要赌。
  assert_eq(db2.get(kb("k1")), expect_bytes(None))
  assert_eq(db2.get(kb("k2")), expect_bytes(None))
  // 截断后的 WAL 被重写：只剩文件头 + 第 1 帧
  assert_eq(db2.wal_bytes(), header + f1.length())
}

///|
test "corruption: WAL 某条记录的长度字段被写成超大值 → 截断，不越界读" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  let wal_name = db.wal_name()
  let good = wal_of(3)
  let header = empty_wal_bytes().length()
  // 第 1 帧的 length 是 varint32，紧跟在 crc(4) 之后。
  // 把它改成 0x7F（127）：文件里没有那么多字节，读端必须停下而不是越界。
  MemStorage::plant(st, wal_name, corrupt_at(good, header + 4, 0x7F))
  st.power_loss()
  let db2 = Db::open(st, 1 << 20)
  // 一条都读不出来，但库能打开（WAL 是暂存区，不该因为它起不来）
  assert_eq(db2.get(kb("k0")), expect_bytes(None))
  assert_eq(db2.wal_bytes(), header)
}

///|
test "corruption: WAL 整个文件被清空 → 重建空 WAL，SST 里的数据还在" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put(kb("in_sst"), kb("ok")))
  db.flush()
  // flush 之后数据在 SST 里，WAL 已经是新的一份（只有文件头）
  ignore(db.put(kb("in_wal"), kb("lost")))
  let wal_name = db.wal_name()
  MemStorage::plant(st, wal_name, Bytes::new(0))
  st.power_loss()
  let db2 = Db::open(st, 1 << 20)
  // SST 里的数据必须还在 —— 这才是「拒绝启动 / 重建 WAL」这条分界线的意义
  assert_eq(db2.get(kb("in_sst")), expect_bytes(Some("ok")))
  // WAL 里的丢了，但库能打开
  assert_eq(db2.get(kb("in_wal")), expect_bytes(None))
  assert_eq(db2.wal_bytes(), empty_wal_bytes().length())
}

///|
test "corruption: WAL 版本号不认识 → 重建空 WAL，不猜格式" {
  let st = MemStorage::new()
  let db = Db::open(st, 1 << 20)
  ignore(db.put(kb("in_sst"), kb("ok")))
  db.flush()
  ignore(db.put(kb("in_wal"), kb("lost")))
  let wal_name = db.wal_name()
  let raw = match Storage::read_file(st, wal_name) {
    Some(b) => b
    None => fail("WAL 读不到")
  }
  // 版本号在 magic 之后（偏移 4），2 字节小端。改成 0x00FF。
  let bad = corrupt_at(raw, 4, 0xFF)
  MemStorage::plant(st, wal_name, corrupt_at(bad, 5, 0x00))
  st.power_loss()
  let db2 = Db::open(st, 1 << 20)
  assert_eq(db2.get(kb("in_sst")), expect_bytes(Some("ok")))
  assert_eq(db2.get(kb("in_wal")), expect_bytes(None))
  assert_eq(db2.wal_bytes(), empty_wal_bytes().length())
}

///|
/// 单字节翻转 fuzz：SST 里**任意**一个字节坏掉，`Db::open` 都必须
/// 「要么成功、要么报 Corruption」，绝不能 panic，也不能越界读。
///
/// 这条测的不是某一种损坏，而是一个不变量（ADR-0003 的 I3：
/// 恢复路径上遇到坏数据要降级，不能崩）。逐个位置试一遍是最省事的证明方式：
/// 手工构造「坏在第 37 字节」这种用例，永远只能覆盖到你想得到的地方。
///
/// **v2 起它还多管一件事：必须发现。** 加了 block / filter 的 CRC 之后
/// （ADR-0010），除了一处已知盲区，任何一个字节坏掉都必须让 `Db::open` 拒绝启动。
/// 剩下那处盲区是 footer 里的 `smallest_seq`（见下面的断言），
/// 所以这条用例不是「碰巧全绿」，而是把盲区的**位置**也钉住了。
test "corruption: SST 任意单字节损坏都不 panic（fuzz）" {
  // 先造一个正常的 SST 作为模板
  let st0 = MemStorage::new()
  let db0 = Db::open(st0, 1 << 20)
  ignore(db0.put(kb("k0"), kb("v0")))
  ignore(db0.put(kb("k1"), kb("v1")))
  db0.flush()
  let num = db0.version.level(0)[0].number
  let p = sst_path(num)
  let template = match Storage::read_file(st0, p) {
    Some(b) => b
    None => fail("模板 SST 读不到")
  }
  let cur = db0.manifest_name()
  let manifest = match Storage::read_file(st0, cur) {
    Some(b) => b
    None => fail("模板 MANIFEST 读不到")
  }
  let mut tried = 0
  let mut rejected = 0
  let missed : Array[Int] = []
  for at in 0..<template.length() {
    let st = MemStorage::new()
    // 摆出一个「完全合法、只有这个 SST 的这一个字节不对」的现场
    MemStorage::plant(st, CURRENT_FILE, kb(cur + "\n"))
    MemStorage::plant(st, cur, manifest)
    MemStorage::plant(st, p, corrupt_at(template, at, bad_byte()))
    tried = tried + 1
    let opened = try {
      let d = Db::open(st, 1 << 20)
      // 打开成功不代表读得到：读路径也不能崩
      ignore(d.get(kb("k0")))
      ignore(d.scan(kb(""), kb("zzzz"), 100))
      true
    } catch {
      err => {
        // 只允许 Corruption：Io 说明路径算错，Closed 说明状态机错了
        assert_true(err.message().has_prefix("Corruption: "))
        false
      }
    }
    if !opened {
      rejected = rejected + 1
    } else {
      missed.push(at)
    }
  }
  assert_true(tried > 0)
  assert_true(rejected > 0)
  // 漏检的位置只允许落在 footer 的 `smallest_seq` 里（48 字节 footer 的第 32..39 字节）。
  //
  // 为什么这 8 个字节保护不了：footer 被撑到 52 字节才能塞进自己的 CRC，
  // 而 48 是读端定位 footer 的硬约束 —— 读端从文件末尾倒推 48 字节，
  // 这个常量不能随版本变。要修只能把 `smallest_seq` 挪走或换掉，
  // 属于下一次格式变更（记在 format.md §5.3 的待办里）。
  //
  // 影响面：`smallest_seq` 只用于快照读的下界，不参与任何数据定位。
  // 改坏它的后果是「快照读的下界不准」，而不是「数据读不出来」或「读出错值」。
  let footer_at = template.length() - SST_FOOTER_SIZE
  for at in missed {
    assert_true(at >= footer_at + 32 && at < footer_at + 40)
  }
}
