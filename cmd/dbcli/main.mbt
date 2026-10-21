///|
/// dbcli：把引擎暴露成「一行 JSON 一条命令」的子进程，
/// 供 benches/python 下的三个测试脚本驱动。
///
/// 之所以要独立进程而不是直接链库：kill -9 必须能杀掉一个独立进程，
/// 同进程内没法测崩溃。
///
/// 当前是**占位实现**：用内存 Map 代替真正的 Db，
/// 目的是先把协议打通，让 model_check 能跑起来。
/// 等 db.mbt 完成后，把 store 换成 @moonlsm.Db 即可。
///
/// 协议见 benches/python/README.md。
///
/// 本文件只依赖 moonbitlang/core/json、moonbitlang/core/encoding/utf8
/// 与 PingGuoMiaoMiao/moonlsm。
///
/// 用 Int 而不是 Int：`moon fmt` 在 0.1.20261016 起会把 `Int` 规范化成
/// `Int`。写 `Int` 时新旧两版 formatter 都不改动，是个稳定的不动点。
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
fn ok_seq(seq : Int) -> String {
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
fn err(msg : String) -> String {
  "{\"ok\":false,\"err\":\"" + esc(msg) + "\"}"
}

///|
struct Cli {
  store : Map[String, String]
  mut seq : Int
}

///|
fn Cli::new() -> Cli {
  { store: Map([]), seq: 0, }
}

///|
fn Cli::bump(self : Cli) -> Int {
  self.seq = self.seq + 1
  self.seq
}

///|
fn Cli::handle(self : Cli, req : Json) -> String {
  let op = fstr(req, "op")
  match op {
    "put" => {
      let k = fstr(req, "k")
      let v = fstr(req, "v")
      self.store.set(k, v)
      ok_seq(self.bump())
    }
    "get" => {
      let k = fstr(req, "k")
      ok_value(self.store.get(k))
    }
    "del" => {
      let k = fstr(req, "k")
      self.store.remove(k)
      ok_seq(self.bump())
    }
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
                      self.store.set(k, v)
                    }
                  None => ()
                }
              }
            None => ()
          }
        None => ()
      }
      ok_seq(self.bump())
    }
    "scan" => {
      let start = fstr(req, "start")
      let end = fstr(req, "end")
      let keys : Array[String] = []
      for k, _ in self.store {
        // 必须用字节序比较：String::compare 按长度优先，
        // 直接拿它做范围判断会把 "k00001" 这类长 key 漏掉。
        if @moonlsm.compare_strings(k, start) >= 0 &&
          @moonlsm.compare_strings(k, end) < 0 {
          keys.push(k)
        }
      }
      keys.sort_by(fn(a, b) { @moonlsm.compare_strings(a, b) })
      let limit = match jget(req, "limit") {
        Some(v) =>
          match as_num(v) {
            Some(n) => n.to_int()
            None => 100
          }
        None => 100
      }
      let mut body = ""
      let mut i = 0
      for k in keys {
        if i >= limit {
          break
        }
        if i > 0 {
          body = body + ","
        }
        let v = match self.store.get(k) {
          Some(x) => x
          None => ""
        }
        body = body + "[\"" + esc(k) + "\",\"" + esc(v) + "\"]"
        i = i + 1
      }
      "{\"ok\":true,\"items\":[" + body + "]}"
    }
    "flush" => ok_unit()
    "stats" =>
      "{\"ok\":true,\"live_keys\":" +
      self.store.length().to_string() +
      ",\"wal_bytes\":0}"
    "close" => ok_unit()
    _ => err("unknown op: " + op)
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
        let resp = cli.handle(@json.parse(line)) catch { _ => err("bad json") }
        println(resp)
        ignore(c_fflush(0))
      }
    }
  }
}
