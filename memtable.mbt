///|
/// 字节序比较：逐字节比，前缀相同时短的小。
/// 必须自己写 —— 不能依赖 String 的字典序，因为 key 是二进制。
///
/// **返回值恒为 -1 / 0 / 1**，不返回长度差值。
/// 这样调用方可以安全地写 `== -1` 判断，而不只是依赖符号。
pub fn compare_bytes(a : Bytes, b : Bytes) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = a[i].to_int()
    let y = b[i].to_int()
    if x < y {
      return -1
    }
    if x > y {
      return 1
    }
  }
  if a.length() < b.length() {
    -1
  } else if a.length() > b.length() {
    1
  } else {
    0
  }
}

///|
/// 字符串 key 的字节序比较。
///
/// 存在的意义：把 UTF-8 编码细节收在库内，调用方（dbcli / 测试）不用自己
/// 处理 Bytes 转换，也不会误用 `String::compare`（它按长度优先，不是字节序）。
pub fn compare_strings(a : String, b : String) -> Int {
  compare_bytes(@utf8.encode(a), @utf8.encode(b))
}

///|
/// 内存写缓冲。当前用「有序数组 + 二分」，够跑通全部正确性测试。
/// Week 3 若性能不够，再换成跳表（接口不变）。
pub struct MemTable {
  entries : Array[Entry]
  mut bytes : Int
  limit : Int
}

///|
pub fn MemTable::new(limit : Int) -> MemTable {
  { entries: [], bytes: 0, limit, }
}

///|
/// 第一个 >= key 的位置。
fn MemTable::lower_bound(self : MemTable, key : Key) -> Int {
  let mut lo = 0
  let mut hi = self.entries.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    if compare_bytes(self.entries[mid].key, key) < 0 {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  lo
}

///|
/// 插入一条已构造好的条目（可能是墓碑）。
/// WAL 重放走这条路径：`mt.insert(rec.to_entry())`。
///
/// 同一个 key 后写的覆盖先写的。**这里不做 seq 比较** ——
/// 调用方必须保证按 seq 升序插入（WAL 是追加写，天然有序）。
pub fn MemTable::insert(self : MemTable, entry : Entry) -> Unit {
  let idx = self.lower_bound(entry.key)
  if idx < self.entries.length() &&
    compare_bytes(self.entries[idx].key, entry.key) == 0 {
    let old = self.entries[idx]
    // 覆盖写只调整 value 部分的字节数：key 长度不变。
    self.bytes = self.bytes + entry.value.length() - old.value.length()
    self.entries[idx] = entry
  } else {
    self.entries.insert(idx, entry)
    // +16 是 seq(8) + deleted 标记 + 数组槽位的估算开销，
    // 只用于触发 flush 阈值，不要求精确。
    self.bytes = self.bytes + entry.key.length() + entry.value.length() + 16
  }
}

///|
/// 写入的便捷形式。走 `Op::Put` 而不是直接构造 Entry：
/// 所有写入都经过「外部意图 → 内部条目」这一层转换，
/// 墓碑语义只在 `Op::to_entry` 一处定义，不会出现两个地方各写一套。
pub fn MemTable::put(
  self : MemTable,
  key : Key,
  value : Value,
  seq : UInt64,
) -> Unit {
  self.insert(Op::Put(key, value).to_entry(seq))
}

///|
/// 删除的便捷形式。写一条墓碑，不真的移除条目 ——
/// 真的移除会让更底层的旧值「复活」。
pub fn MemTable::delete(self : MemTable, key : Key, seq : UInt64) -> Unit {
  self.insert(Op::Delete(key).to_entry(seq))
}

///|
/// 重放一条 WAL 记录。恢复路径的唯一入口。
pub fn MemTable::apply(self : MemTable, rec : WalRecord) -> Unit {
  self.insert(rec.to_entry())
}

///|
/// 读。返回 None 表示这个 memtable 里没有（不代表全局没有）。
pub fn MemTable::get(self : MemTable, key : Key) -> Entry? {
  let idx = self.lower_bound(key)
  if idx < self.entries.length() &&
    compare_bytes(self.entries[idx].key, key) == 0 {
    Some(self.entries[idx])
  } else {
    None
  }
}

///|
/// 是否该刷盘了。
pub fn MemTable::is_full(self : MemTable) -> Bool {
  self.bytes >= self.limit
}

///|
/// 按 key 升序导出，供刷盘和归并迭代使用。
pub fn MemTable::to_entries(self : MemTable) -> Array[Entry] {
  self.entries
}

///|
/// 清空。**只在 flush 成功后调用** ——
/// 先落盘、再清空，顺序反了就是丢数据。
pub fn MemTable::clear(self : MemTable) -> Unit {
  self.entries.clear()
  self.bytes = 0
}
