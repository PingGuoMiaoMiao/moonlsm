///|
/// 键与值统一用 Bytes，避免 String 的 UTF-8 假设。
/// 别名而不是新类型：MoonBit 没有隐式转换，包一层会带来大量样板。
type Key = Bytes

///|
type Value = Bytes

///|
/// 一条内部记录。seq 是全局单调递增序号，
/// 用于判断同一 key 的新旧（越大越新）。
///
/// `deleted` 是墓碑标记。**不能**用「value 长度为 0」表示删除 ——
/// 那样就无法区分「写入了空字符串」和「删除了这个 key」，
/// 是 LSM 实现里最常见的一个静默数据错误。
/// 对应磁盘格式里 data block 每条记录前的 1 字节 `type`（见 format.md §3.2）。
pub struct Entry {
  key : Key
  value : Value
  seq : UInt64
  deleted : Bool
}

///|
/// 写入操作。删除不是「移除」，而是写一条墓碑。
pub enum Op {
  Put(Key, Value)
  Delete(Key)
}

///|
/// 把一条写入操作转成 memtable 条目。
/// `Delete` 生成的条目 value 为空，且 `deleted = true`。
pub fn Op::to_entry(self : Op, seq : UInt64) -> Entry {
  match self {
    Put(k, v) => { key: k, value: v, seq, deleted: false, }
    Delete(k) => { key: k, value: b"", seq, deleted: true, }
  }
}

///|
/// 一条 WAL 记录：操作 + 序号。
/// WAL 里存的是操作而不是条目，因为操作更小（Delete 不带 value）。
pub struct WalRecord {
  seq : UInt64
  op : Op
}

///|
/// 构造一条 WAL 记录。WAL 编码与恢复解码都走这里，
/// 保证「写进去的」和「读出来的」是同一个类型。
pub fn WalRecord::new(seq : UInt64, op : Op) -> WalRecord {
  { seq, op, }
}

///|
/// 重放时把 WAL 记录还原成 memtable 条目。
pub fn WalRecord::to_entry(self : WalRecord) -> Entry {
  self.op.to_entry(self.seq)
}

///|
/// 对外返回的一条键值。scan 的返回单元。
///
/// 与 `Entry` 的区别：没有 seq、没有 deleted —— 对外部使用者来说
/// 多版本和墓碑都是实现细节，不该暴露。
pub struct KvPair {
  key : Key
  value : Value
}

///|
/// 直接构造一条键值。
///
/// 跨包不能写结构体字面量（`KvPair` 是只读类型），而 CLI 的 JSON 拼装、
/// 下游的单元测试都需要「凭空造一条」的能力。`Entry::to_pair` 不够用：
/// 它要求先有一个 `Entry`，而 `Entry` 带 `seq` 和墓碑标记，
/// 对使用者来说是多余的。
pub fn KvPair::new(key : Key, value : Value) -> KvPair {
  { key, value, }
}

///|
/// 把内部条目转成对外键值。
/// **调用方必须先过滤掉 `deleted = true` 的条目**，否则墓碑会泄漏出去。
pub fn Entry::to_pair(self : Entry) -> KvPair {
  { key: self.key, value: self.value, }
}
