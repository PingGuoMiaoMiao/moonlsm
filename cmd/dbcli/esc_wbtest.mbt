///|
test "esc 对纯 ASCII 应当原样返回" {
  assert_eq(esc("bad json"), "bad json")
}

///|
test "esc 应当转义引号与反斜杠" {
  assert_eq(esc("a\"b"), "a\\\"b")
  assert_eq(esc("a\\b"), "a\\\\b")
}

///|
fn pair(k : String, v : String) -> @moonlsm.KvPair {
  @moonlsm.KvPair::new(@utf8.encode(k), @utf8.encode(v))
}

///|
test "items_json: 空结果输出空数组" {
  let empty : Array[@moonlsm.KvPair] = []
  assert_eq(items_json(empty), "[]")
}

///|
test "items_json: 单条与多条的分隔符" {
  assert_eq(items_json([pair("a", "1")]), "[[\"a\",\"1\"]]")
  assert_eq(
    items_json([pair("a", "1"), pair("b", "2")]),
    "[[\"a\",\"1\"],[\"b\",\"2\"]]",
  )
}

///|
test "items_json: 需要转义的字符不能破坏 JSON 结构" {
  // 引号 / 反斜杠 / 换行 —— 任何一处不转义，下游 json.loads 直接报错
  assert_eq(items_json([pair("q\"k", "v\\1")]), "[[\"q\\\"k\",\"v\\\\1\"]]")
  assert_eq(items_json([pair("a\nb", "c")]), "[[\"a\\nb\",\"c\"]]")
}

///|
test "items_json: 中文按 UTF-8 输出，不是逐字节映射" {
  // `Buffer::to_string()` 会把每个字节当成一个码位（0x5B → U+225B），
  // 输出一串乱码；必须 `@utf8.decode_lossy(buf.to_bytes())`。
  // 中文是多字节，这个用例专门守那条路径。
  let got = items_json([pair("用户:1", "爱丽丝")])
  assert_eq(got, "[[\"用户:1\",\"爱丽丝\"]]")
  // 逐字节比对，确认没有被二次编码
  assert_eq(@utf8.encode(got), @utf8.encode("[[\"用户:1\",\"爱丽丝\"]]"))
}

///|
test "items_json: 500 条仍然是合法 JSON 且不丢分隔符" {
  let items : Array[@moonlsm.KvPair] = []
  for i in 0..<500 {
    items.push(pair("key" + i.to_string(), "v" + i.to_string()))
  }
  let got = items_json(items)
  // 长度必须严格等于「外层 2 + 分隔符 499 + 每条 7 + key 长 + value 长」。
  // 少一个分隔符、少一个引号、或者把某条编码错了，长度都对不上。
  let mut want_len = 2 + (items.length() - 1)
  for p in items {
    // `["` + key + `","` + value + `"]` = 2 + 3 + 2
    want_len = want_len + 7 + p.key.length() + p.value.length()
  }
  assert_eq(got.length(), want_len)
  assert_true(got.has_prefix("[[\"key0\",\"v0\"],[\"key1\",\"v1\"]"))
  assert_true(got.has_suffix("[\"key499\",\"v499\"]]"))
}
