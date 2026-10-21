///|
/// 所有可能失败的地方都走这个错误类型。
/// 关键原则：恢复路径上遇到坏数据要「降级」而不是 panic（ADR-0003 不变量 I3）。
pub suberror LsmError {
  Io(String)
  Corruption(String)
  Closed
}

///|
/// 便捷构造。写 `raise LsmError::io("...")` 比 `raise Io("...")` 更明确，
/// 跨包调用时也不用写 `@moonlsm.Io(...)` 这种看不出语义的形式。
pub fn LsmError::io(msg : String) -> LsmError {
  Io(msg)
}

///|
pub fn LsmError::corruption(msg : String) -> LsmError {
  Corruption(msg)
}

///|
pub fn LsmError::closed() -> LsmError {
  Closed
}
