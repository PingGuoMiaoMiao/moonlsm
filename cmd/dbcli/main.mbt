///|
/// dbcli：把引擎暴露成「一行 JSON 一条命令」的子进程，
/// 供 benches/python 下的三个测试脚本驱动。
///
/// 之所以要独立进程而不是直接链库：kill -9 必须能杀掉一个独立进程，
/// 同进程内没法测崩溃。
///
/// 当前接的是真正的 `@moonlsm.Db`：WAL + memtable + SST + 归并，
/// 全部通过 `@moonlsm.NativeStorage` 落到真文件系统。
/// 数据目录来自环境变量 `MOONLSM_DATA`（默认 `.moonlsm_data`）。
///
/// `putmany` 走组提交：一批只 fsync 一次，然后才回 ack。
/// 这是 C1（已确认的写入必不丢）与吞吐之间唯一正确的折中点 ——
/// 逐条 fsync 也满足 C1，但会把 200 条的批次拖成 200 次刷盘。
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
/// 取布尔值。不是布尔就返回 None。
///
/// 注意 `Json` 里的布尔是**两个无参构造器** `True` / `False`，
/// 不是 `Boolean(b)` —— 写成后者会得到「Json 没有构造器 Boolean」。
fn as_bool(j : Json) -> Bool? {
  match j {
    True => Some(true)
    False => Some(false)
    _ => None
  }
}

///|
/// 请求是否要求「返回前必须 fsync」。
///
/// **缺省为 true。** 协议里 `sync` 是可选字段，省略时必须按最安全的方式处理 ——
/// 一个忘了写 `sync:true` 的客户端不应该意外拿到「没落盘就 ack」的行为。
/// 只有显式写 `"sync": false` 才跳过 fsync，那是压测专用路径。
fn req_sync(j : Json) -> Bool {
  match jget(j, "sync") {
    Some(v) =>
      match as_bool(v) {
        Some(b) => b
        None => true
      }
    None => true
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
  db : @moonlsm.Db[@moonlsm.NativeStorage]
}

///|
fn Cli::new(dir : String) -> Cli? {
  // 8 MiB 的 memtable 阈值：跑测试脚本时基本不会触发 flush，
  // 但 `flush` 命令可以手动触发，所以两条路径都测得到。
  //
  // 真文件系统后端：dbcli 的存在意义就是让 `kill -9` 能杀掉一个独立进程，
  // 内存后端做不到这件事。
  //
  // 注意这个函数**不 raise**，而是返回 `Cli?`。看起来绕，但必须这样：
  // 「返回一个含泛型结构体字段的结构体」的 raising 函数在这个工具链上
  // 会在调用点段错误（0xc0000005），而且崩溃发生在进入函数体之前，
  // 打点也看不到。把 catch 收进函数内部、返回 Option，就绕开了。
  let db = @moonlsm.open_native(dir, 8 * 1024 * 1024) catch {
    e => {
      println(err("open failed: " + e.message()))
      return None
    }
  }
  Some({ db: db })
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
      // 单条写：put 内部已经「追加 + fsync」，不需要再 sync 一次
      if req_sync(req) {
        ok_seq(self.db.put(k, v))
      } else {
        ok_seq(self.db.put_deferred(k, v))
      }
    }
    "get" => ok_bytes(self.db.get(@utf8.encode(fstr(req, "k"))))
    "del" => {
      let k = @utf8.encode(fstr(req, "k"))
      if req_sync(req) {
        ok_seq(self.db.delete(k))
      } else {
        ok_seq(self.db.delete_deferred(k))
      }
    }
    "putmany" => {
      // 组提交：先全部追加到 WAL，最后一次 fsync，然后才回 ack。
      //
      // 之前这里是逐条 `db.put`，也就是 200 条 = 200 次 fsync。
      // 在 Windows 的 `_commit` 上实测约 2.3 秒一批，crash_test 一轮
      // 只能写 200 条 —— demo 里根本跑不到百万级。
      // 契约 C1 只要求「ack 之前 fsync 成功」，没要求每条一次。
      let want_sync = req_sync(req)
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
                      // 不逐条 fsync，末尾统一刷一次
                      ignore(self.db.put_deferred(@utf8.encode(k), @utf8.encode(v)))
                    }
                  None => ()
                }
              }
            None => ()
          }
        None => ()
      }
      // 这一行就是 C1：ack 在 fsync 之后
      if want_sync {
        self.db.sync()
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
      ",\"wal_bytes\":" +
      self.db.wal_bytes().to_string() +
      ",\"ssts\":" +
      self.db.sst_count().to_string() +
      ",\"flushes\":" +
      self.db.flush_count().to_string() +
      ",\"mem_entries\":" +
      self.db.mem_entry_count().to_string() +
      "}"
    }
    "close" => {
      self.db.close()
      ok_unit()
    }
    _ => err("unknown op: " + op)
  }
}

///|
/// 一条输入行 → 一行输出。把「JSON 解析失败」和「引擎报错」分开报，
/// 否则引擎的 Corruption 会被误报成 bad json，排查时白走一大圈。
fn dispatch(cli : Cli, line : String) -> String {
  let req = @json.parse(line) catch { _ => return err("bad json") }
  cli.handle(req) catch {
    e => err(e.message())
  }
}

///|
/// 打开失败就把原因打到 stdout 并返回 None。
/// 注意走 stdout 而不是 stderr：驱动脚本读的是 stdout 的行 JSON，
/// 错误也要以同样的格式出现，否则脚本只会看到「进程没输出」。
///|
fn main {
  // 数据目录：环境变量优先，默认当前目录下的 .moonlsm_data。
  // 用环境变量而不是命令行参数，是因为这个进程的 stdin/stdout
  // 全被 JSON 协议占用了，加参数解析只会让驱动脚本更复杂。
  let dir = match @env.get_env_var("MOONLSM_DATA") {
    Some(d) => d
    None => ".moonlsm_data"
  }
  let cli = match Cli::new(dir) {
    Some(c) => c
    None => return
  }
  while true {
    match read_line() {
      None => break
      Some(line) => {
        if line.length() == 0 {
          continue
        }
        println(dispatch(cli, line))
        @moonlsm.flush_stdio()
      }
    }
  }
}
