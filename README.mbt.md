# PingGuoMiaoMiao/moonlsm

**MoonBit 生态里的嵌入式 LSM 存储引擎。**

> 社区项目，非 MoonBit 官方出品。

MoonBit 现有的 KV 存储都是 Bitcask 风格（追加文件 + 全量内存索引），内存随数据线性增长，没有分层合并。moonlsm 补的是 **LSM-tree**（memtable + SSTable + compaction）这块空白。

> 「嵌入式」指 *embedded database* —— 像 SQLite 那样**链接进宿主进程**，
> 不是跑在单片机 / MCU 上。它依赖 libc 与带 `fsync` 语义的文件系统。

## 状态

可用。`kill -9` 不丢已确认的写入（`crash_test.py --rounds 20` 全 20 轮通过），
205 条单元测试覆盖 WAL 截断恢复、MANIFEST 原子切换、三层归并、损坏注入。

## 设计

```
put(k, v)
   ├─→ WAL（顺序追加，fsync 成功后才回 ack）
   └─→ MemTable（内存有序数组）
          └─ flush ─→ L0 SSTable（可重叠）
                        └─ 满 4 个 ─→ L1（不重叠）
                                        └─ 超 1 MiB ─→ L2（最底层，墓碑在这里丢弃）
```

读路径：MemTable → L0 → L1 → L2，从新到旧命中即停，每层先查 Bloom filter 跳过无关文件。

三条路径的关键性质：

- **写**：fsync 在返回 ack 之前，且 fsync 在改 MemTable 之前 —— 失败时写入完全不可见，
  不会出现「读得到、断电就没」的脏读。
- **读**：命中第一个就返回，**不比较 seq**。所以内存里的文件顺序必须严格「新在前」，
  由 MANIFEST 的版本快照唯一决定。
- **归并**：同一 key 取 `seq` 最大的一条（不是按文件顺序）。墓碑只在写进最底层时丢弃 ——
  上层还有更旧版本时丢了会让数据复活。

## 示例

```moonbit
let db = @moonlsm.Db::open(@moonlsm.NativeStorage::new("./data"), 8 * 1024 * 1024)

let seq = db.put(b"key", b"value")   // 返回即代表已落盘（fsync 已成功）
let v = db.get(b"key")               // Bytes?，删除也是 None
let rows = db.scan(b"a", b"z", 100)  // [start, end)
db.flush()                           // memtable -> L0，必要时触发归并
db.close()
```

这些调用会 raise，所以要放在 `fn main raise { ... }` 里，或者自己处理 `LsmError`。

批量写走组提交，一批只 fsync 一次：

```moonbit
for i in 0..<200 {
  db.put_deferred(key(i), value(i)) |> ignore
}
db.sync()                            // 返回即代表整批已落盘
```

完整可跑的例子见仓库的 [`examples/basic/main.mbt`](https://github.com/PingGuoMiaoMiao/moonlsm/blob/main/examples/basic/main.mbt)。

## 性能（100 万条 · 每批 1000 · value 100 字节）

| 指标 | 数值 |
|---|---|
| 顺序写 | 55 658 ops/s |
| 随机写（覆盖写） | 12 699 ops/s |
| 读延迟 P50 / P99 | 0.053 / 0.111 ms |
| 范围扫描 | 117 483 rows/s |
| 空间放大 | 1.13× |

组提交让「每批一次 fsync」只比不同步慢 1.40×；把批次改成 1（每条都等 fsync）
则掉到 76 ops/s —— 39 倍差距。完整数据见仓库的
[`docs/engineering/BENCHMARK.md`](https://github.com/PingGuoMiaoMiao/moonlsm/blob/main/docs/engineering/BENCHMARK.md)。

## 完整文档

设计文档、能力矩阵、崩溃测试方案、路线图都在 GitHub 仓库：

**https://github.com/PingGuoMiaoMiao/moonlsm**

## License

MIT
