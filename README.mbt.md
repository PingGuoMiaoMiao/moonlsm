# PingGuoMiaoMiao/moonlsm

**MoonBit 生态里的嵌入式 LSM 存储引擎。**

> 社区项目，非 MoonBit 官方出品。

MoonBit 现有的 KV 存储都是 Bitcask 风格（追加文件 + 全量内存索引），内存随数据线性增长，没有分层合并。moonlsm 补的是 **LSM-tree**（memtable + SSTable + compaction）这块空白。

## 状态

WIP。已实现 `MemTable`、`BloomFilter`；WAL / SSTable / compaction / 对外 API 开发中。

## 设计

```
put(k, v)
   ├─→ WAL（顺序追加，崩溃后重放）
   └─→ MemTable（内存有序表）
          └─ flush ─→ L0 SSTable ─→ L1 ─→ L2 ...
```

读路径：MemTable → L0 → L1 → L2，每层先查 Bloom filter 跳过无关文件。

## 示例（设计稿）

```moonbit nocheck
let db = @moonlsm.open("data")!
db.put(b"key", b"value")!
let v = db.get(b"key")!
db.close()!
```

## 完整文档

设计文档、能力矩阵、崩溃测试方案、路线图都在 GitHub 仓库：

**https://github.com/PingGuoMiaoMiao/moonlsm**

## License

MIT
