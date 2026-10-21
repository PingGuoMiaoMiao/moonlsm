///|
/// dbcli：把引擎暴露成「一行 JSON 一条命令」的子进程，
/// 供 benches/python 下的三个测试脚本驱动。
///
/// 之所以要独立进程而不是直接链库：kill -9 必须能杀掉一个独立进程，
/// 同进程内没法测崩溃。
///
/// 当前接的是真正的 `@moonlsm.Db`（memtable + SST + 归并），
/// 但**还没有 WAL**：进程退出数据就没了。崩溃一致性测试（crash_test.py）
/// 要等 Week 2 的 WAL 落地才有意义，`probe_persistence.py` 会探测这一点
/// 并让 CI 显式跳过，而不是假装通过。
///
/// 协议见 benches/python/README.md。
///
/// 本文件只依赖 moonbitlang/core/json、moonbitlang/core/encoding/utf8
/// 与 PingGuoMiaoMiao/moonlsm。
///
/// 全程用 `Int` 而不是 `Int32`：本项目验证的工具链 0.1.20260827 里
/// 根本没有 `Int32` 这个类型（它是新版才引入的）。
extern "C" fn c_getchar() -> Int = "getchar"

///|
/// 管道模式下 stdout 是全缓冲，不主动 flush 会让测试脚本一直等。
/// 传 0 等价于 C 的 fflush(NULL)，刷新全部输出流。
extern "C" fn c_fflush(stream : Int) -> Int = "fflush"

///|
/// 从 stdin 读一行（不含换行符）。EOF 返回 None。
///
/// **必须按字节累积，最后一次性 UTF-8 解码。**
/// 不能每读一个字节就转成 Char —— `getchar` 返回的是单个字节，
/// 把一个字节当 Char 等于假设 Latin-1，遇到中文（3 字节 UTF-8）
/// 会被拆成三个字符，产出乱码。
fn read_line() -> String? {
  let buf = Buffer::Buffer()
  let mut got_any = false
  while true {
    let c = c_getchar()
    if c < 0 {
      break
    }
    got_any = true
    if c == 10 {
      break
    }
    if c == 13 {
      continue
    }
    buf.write_byte(c.to_byte())
  }
  if got_any {
    // lossy：非法 UTF-8 不抛异常，替换成 U+FFFD。
    // 测试脚本只发合法 JSON，但 CLI 不该因为一个坏字节就崩掉。
    Some(@utf8.decode_lossy(buf.to_bytes()))
  } else {
    None
  }
}

///|
/// JSON 字符串转义。值里可能有引号或换行，不转义会产出非法 JSON。
fn esc(s : String) -> String {
  let mut out = ""
  for c in s {
    let piece = match c {
      '"' => "\\\""
      '\\' => "\\\\"
      '\n' => "\\n"
      '\r' => "\\r"
      '\t' => "\\t"
      _ => c.to_string()
    }
    out = out + piece
  }
  out
}

// ---------------------------------------------------------------------------
// JSON 提取层
//
// 这些函数一律返回 Option，不做隐式类型转换。协议里字段类型不对
// 就应该走默认值或报错，而不是靠 toString 猜一个出来。
// ---------------------------------------------------------------------------

///|
/// 从 Json 对象取字段。非对象、或字段缺失，都返回 None。
fn jget(j : Json, key : String) -> Json? {
  match j {
    Object(obj) => obj.get(key)
    _ => None
  }
}

///|
/// 取字符串。不是字符串就返回 None。
fn as_str(j : Json) -> String? {
  match j {
    String(s) => Some(s)
    _ => None
  }
}

///|
/// 取数组。不是数组就返回 None。
fn as_arr(j : Json) -> Array[Json]? {
  match j {
    Array(a) => Some(a)
    _ => None
  }
}

///|
/// 取数字。不是数字就返回 None。
/// `Number` 构造器还带一个 repr 字段（原始字面量），这里用 `..` 忽略。
fn as_num(j : Json) -> Double? {
  match j {
    Number(n, ..) => Some(n)
    _ => None
  }
}

///|
/// 取字符串字段，缺失或类型不对都返回空串。
fn fstr(j : Json, key : String) -> String {
  match jget(j, key) {
    Some(v) =>
      match as_str(v) {
        Some(s) => s
        None => ""
      }
    None => ""
  }
}

///|
fn ok_unit() -> String {
  "{\"ok\":true}"
}

///|
fn ok_seq(seq : UInt64) -> String {
  "{\"ok\":true,\"seq\":" + seq.to_string() + "}"
}

///|
fn ok_value(v : String?) -> String {
  match v {
    Some(s) => "{\"ok\":true,\"v\":\"" + esc(s) + "\"}"
    None => "{\"ok\":true,\"v\":null}"
  }
}

///|
/// 引擎返回的是 `Bytes?`，转成 JSON 前必须 UTF-8 解码。
/// 用 lossy 而不是严格解码：CLI 不该因为一个坏字节就崩掉整个进程。
fn ok_bytes(v : Bytes?) -> String {
  match v {
    Some(b) => ok_value(Some(@utf8.decode_lossy(b)))
    None => ok_value(None)
  }
}

///|
fn err(msg : String) -> String {
  "{\"ok\":false,\"err\":\"" + esc(msg) + "\"}"
}

///|
/// CLI 状态就是引擎本身。这里刻意不留任何额外缓存 ——
/// 一旦 CLI 自己缓存了数据，测出来的就不是引擎的行为了。
struct Cli {
  db : @moonlsm.Db
}

///|
fn Cli::new() -> Cli {
  // 8 MiB 的 memtable 阈值：跑测试脚本时基本不会触发 flush，
  // 但 `flush` 命令可以手动触发，所以两条路径都测得到
  { db: @moonlsm.Db::new(8 * 1024 * 1024), }
}

///|
/// 处理一条请求。引擎错误（Io / Corruption / Closed）会向上抛，
/// 由 `dispatch` 统一转成 `{"ok":false,...}`，而不是在这里静默吞掉。
fn Cli::handle(self : Cli, req : Json) -> String raise @moonlsm.LsmError {
  let op = fstr(req, "op")
  match op {
    "put" => {
      let k = @utf8.encode(fstr(req, "k"))
      let v = @utf8.encode(fstr(req, "v"))
      ok_seq(self.db.put(k, v))
    }
    "get" => ok_bytes(self.db.get(@utf8.encode(fstr(req, "k"))))
    "del" => ok_seq(self.db.delete(@utf8.encode(fstr(req, "k"))))
    "putmany" => {
      match jget(req, "items") {
        Some(items_json) =>
          match as_arr(items_json) {
            Some(items) =>
              for item in items {
                match as_arr(item) {
                  Some(pair) =>
                    if pair.length() >= 2 {
                      let k = match as_str(pair[0]) {
                        Some(s) => s
                        None => ""
                      }
                      let v = match as_str(pair[1]) {
                        Some(s) => s
                        None => ""
                      }
                      ignore(self.db.put(@utf8.encode(k), @utf8.encode(v)))
                    }
                  None => ()
                }
              }
            None => ()
          }
        None => ()
      }
      // 一批写入只回一个 seq，取最后一个（也是最大的）
      ok_seq(self.db.last_seq())
    }
    "scan" => {
      // 左闭右开，与 model_check.py 的 `start <= x < end` 一致
      let start = @utf8.encode(fstr(req, "start"))
      let end = @utf8.encode(fstr(req, "end"))
      let limit = match jget(req, "limit") {
        Some(v) =>
          match as_num(v) {
            Some(n) => n.to_int()
            None => 100
          }
        None => 100
      }
      let items = self.db.scan(start, end, limit)
      let mut body = ""
      let mut first = true
      for p in items {
        if !first {
          body = body + ","
        }
        first = false
        body = body +
          "[\"" +
          esc(@utf8.decode_lossy(p.key)) +
          "\",\"" +
          esc(@utf8.decode_lossy(p.value)) +
          "\"]"
      }
      "{\"ok\":true,\"items\":[" + body + "]}"
    }
    "flush" => {
      self.db.flush()
      ok_unit()
    }
    "stats" => {
      // live_keys 需要真扫一遍：memtable 里的墓碑和 SST 里的旧值
      // 都不能计入。这比「memtable 条目数」慢，但它是唯一正确的口径。
      let live = self.db.scan(
        @utf8.encode(""),
        @utf8.encode("\u{10FFFF}"),
        100000000,
      )
      "{\"ok\":true,\"live_keys\":" +
      live.length().to_string() +
      ",\"wal_bytes\":0,\"ssts\":" +
      self.db.sst_count().to_string() +
      ",\"flushes\":" +
      self.db.flush_count().to_string() +
      ",\"mem_entries\":" +
      self.db.mem_entry_count().to_string() +
      "}"
    }
    "close" => ok_unit()
    _ => err("unknown op: " + op)
  }
}

///|
/// 一条输入行 → 一行输出。把「JSON 解析失败」和「引擎报错」分开报，
/// 否则引擎的 Corruption 会被误报成 bad json，排查时白走一大圈。
fn dispatch(cli : Cli, line : String) -> String {
  let req = @json.parse(line) catch { _ => return err("bad json") }
  cli.handle(req) catch {
    _ => err("engine error")
  }
}

///|
fn main {
  let cli = Cli::new()
  while true {
    match read_line() {
      None => break
      Some(line) => {
        if line.length() == 0 {
          continue
        }
        println(dispatch(cli, line))
        ignore(c_fflush(0))
      }
    }
  }
}
