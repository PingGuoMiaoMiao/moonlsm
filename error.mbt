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

///|
/// 人类可读的错误描述。CLI 与日志用它，而不是自己 match 一遍——
/// 错误类型的构造器将来会增加，散落各处的 match 会漏。
pub fn LsmError::message(self : LsmError) -> String {
  match self {
    Io(m) => "Io: " + m
    Corruption(m) => "Corruption: " + m
    Closed => "Closed: 数据库已关闭"
  }
}
