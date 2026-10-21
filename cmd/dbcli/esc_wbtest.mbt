///|
test "esc 对纯 ASCII 应当原样返回" {
  assert_eq(esc("bad json"), "bad json")
}

///|
test "esc 应当转义引号与反斜杠" {
  assert_eq(esc("a\"b"), "a\\\"b")
  assert_eq(esc("a\\b"), "a\\\\b")
}
