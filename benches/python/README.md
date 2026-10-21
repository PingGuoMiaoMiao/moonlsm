# LSM 存储引擎 · 测试脚手架

这个目录里是**测试工具**，不是引擎实现。引擎用这三把尺子量自己。

```
benches/python/
├── README.md            ← 你在这里
├── crash_test.py        ← 崩溃一致性（kill -9），比赛 demo 的核心镜头
├── model_check.py       ← 正确性对拍（和内存 dict 比）
├── probe_persistence.py ← 探测引擎是否已支持持久化（决定要不要跑崩溃测试）
├── bench.py             ← 性能基准（输出可直接贴 PPT 的表格）
├── dbcli_launch.py      ← 数据目录/环境变量的唯一来源，三个脚本共用
├── mock_dbcli.py        ← 假的实现，只用来验证上面三个脚本本身有效
└── REFERENCES.md        ← 跨语言同类实现调研
```

---

## 一、先理解：kill -9 到底在测什么

这是最容易搞错的地方，也是你能在答辩时讲出深度的地方。

**kill -9 测的不是「数据不丢」，是「契约不破」。**

WAL 的 durability 契约只有三条：

1. **已返回 ok 的写入，重启后必须能读到，值完全正确**（这是 fsync 的意义）
2. **还没返回 ok 的写入，允许丢失**
3. **但「丢失」只能是整条不见，绝不能读出半个值**（torn write）

第 3 条是很多人漏掉的。WAL 末尾经常会有写了一半的记录——如果你的恢复逻辑直接 `json.parse` 整行，遇到半条就 panic，数据库就再也起不来了。正确做法是：**校验记录完整性（长度前缀或 CRC），不完整就截断到最后一条完整记录**。

### kill -9 测不到什么（重要）

kill -9 只杀进程，**不清 OS 页缓存**。所以如果你的代码 `write()` 了但没 `fsync()`，数据其实还在内核缓存里，重启照样读得到——**kill -9 测不出「忘了 fsync」这个 bug**。

要测 fsync，得用更狠的手段：

| 手段 | 能测出什么 | 怎么做 |
|---|---|---|
| `kill -9` | 进程内缓冲丢失、恢复逻辑是否健壮 | 本目录的 `crash_test.py` |
| **WAL 尾部截断** | torn write 处理 | 手动 `truncate -s -37 wal.log` 再启动 |
| **VM 强制断电** | fsync 是否真的生效 | 虚拟机里 `virsh destroy`，或 Docker `kill -9` 容器 + 清 page cache |
| `fsync` 计数注入 | 是否漏调 fsync | 在 WAL 层加计数器，每次 flush 断言 +1 |

比赛 demo 用 kill -9 就够震撼了；但**答辩时主动说出「kill -9 测不到 fsync，我还做了截断注入」**，这是加分项。

---

## 二、你要实现的接口：dbcli 协议

三个脚本都通过 stdin/stdout 和你的引擎通信，一行一个 JSON。

**为什么用子进程 + JSON 而不是直接链库？** 因为 kill -9 必须杀一个独立进程，链接在同一进程里没法测崩溃。

### 请求 / 响应

| 请求 | 响应 | 说明 |
|---|---|---|
| `{"op":"put","k":"a","v":"1"}` | `{"ok":true,"seq":1}` | 单条写 |
| `{"op":"putmany","items":[["a","1"],["b","2"]],"sync":true}` | `{"ok":true,"seq":2}` | 批量写；`sync:true` 表示返回前必须 fsync |
| `{"op":"get","k":"a"}` | `{"ok":true,"v":"1"}` 或 `{"ok":true,"v":null}` | 读，不存在返回 null |
| `{"op":"del","k":"a"}` | `{"ok":true,"seq":3}` | 删（写墓碑） |
| `{"op":"scan","start":"a","end":"z","limit":100}` | `{"ok":true,"items":[["a","1"]]}` | 左闭右开，按 key 升序 |
| `{"op":"flush"}` | `{"ok":true}` | 刷盘（含 fsync） |
| `{"op":"stats"}` | `{"ok":true,"live_keys":10,"wal_bytes":1024}` | 可选，用于展示 |
| `{"op":"close"}` | `{"ok":true}` | 优雅退出 |

**关键约束：`sync:true` 的响应必须在 fsync 返回之后才发出。** 这是整个测试的地基——ack 的语义就是「已经落盘」。

### MoonBit 侧骨架

```moonbit
// cmd/dbcli/main.mbt
fn main {
  let db = @lsm.open("data")!          // 你的引擎
  let stdin = @io.stdin()
  while true {
    let line = stdin.read_line()!
    if line == "" { break }
    let req = @json.parse(line)!
    let resp = match req {
      { "op": "put", "k": k, "v": v, .. } => {
        db.put(k, v)!
        { "ok": true, "seq": db.seq() }
      }
      { "op": "putmany", "items": items, "sync": sync, .. } => {
        for item in items { db.put(item[0], item[1])! }
        if sync { db.fsync()! }         // ← 必须在返回前
        { "ok": true, "seq": db.seq() }
      }
      { "op": "get", "k": k, .. } =>
        { "ok": true, "v": db.get(k)! }
      { "op": "del", "k": k, .. } => {
        db.delete(k)!
        { "ok": true, "seq": db.seq() }
      }
      { "op": "scan", "start": s, "end": e, "limit": l, .. } =>
        { "ok": true, "items": db.scan(s, e, l)! }
      { "op": "flush", .. } => { db.fsync()!; { "ok": true } }
      { "op": "close", .. } => { db.close()!; break { "ok": true } }
      _ => { "ok": false, "err": "unknown op" }
    }
    println(@json.stringify(resp))
    @io.stdout().flush()                 // ← 不 flush 脚本会卡住
  }
}
```

> 上面是结构示意，具体 API 按你实际用的 `moonbitlang/core` / `moonbitlang/async` 调整。
> **最容易踩的坑：stdout 不 flush，测试脚本会一直等。**

---

## 三、跑起来

先把 mock 跑通，确认环境没问题：

```bash
# 正确性
python model_check.py --cmd "python mock_dbcli.py --path ./data" --ops 1200 --restart-every 400

# 崩溃一致性
python crash_test.py --cmd "python mock_dbcli.py --path ./data" --rounds 3

# 性能
python bench.py --cmd "python mock_dbcli.py --path ./data" --n 20000 --reads 2000
```

然后把 `--cmd` 换成你的实现（在项目根目录构建，在本目录运行）：

```bash
# 在仓库根目录
moon build --target native --release

# 回到 benches/python
python crash_test.py --cmd "../../_build/native/release/build/cmd/dbcli/dbcli.exe" --rounds 10
```

### 数据目录怎么传给 dbcli（一个真实的坑）

`dbcli` **不接受 `--path` 参数**，数据目录走环境变量 `MOONLSM_DATA`。
原因是那个进程的 stdin/stdout 已经被 JSON 协议占满了，再加命令行参数只会让
所有驱动脚本的引号转义变复杂。

代价是每个 `subprocess.Popen` 都必须显式把环境变量传下去。只要漏一处，
dbcli 就退回默认的 `.moonlsm_data`，于是不同测试的数据混在同一个库里。
实际症状极其难查 —— `model_check.py` 会报：

```
FAIL: 最终 scan key 集合不一致 got=161 want=160 extra=['probe:persistence']
```

看起来像引擎多返回了一个键（排序错？墓碑没生效？），其实是探测脚本写进去的那条。

**所以三个脚本都不自己拼 env，统一走 `dbcli_launch.py`**：

```python
import dbcli_launch
data_dir = dbcli_launch.resolve_dir(args.data_dir, "./data")
env      = dbcli_launch.child_env(data_dir)
subprocess.Popen(cmd, ..., env=env)
```

`resolve_dir` 刻意**不读**外部的 `MOONLSM_DATA`：`crash_test.py` 每轮会
`rmtree` 数据目录，一旦继承外部变量就可能删掉真实数据。环境变量在这里只作为
**输出**（传给子进程），绝不作为输入。

### 验证测试脚本本身有效（可选，但建议做一次）

mock 带了一个「忘了 fsync」的开关，用它确认 crash_test 真能抓到问题：

```bash
python crash_test.py --cmd "python mock_dbcli.py --path ./data --no-sync" --rounds 5
# 期望：部分轮次 FAIL，报「已确认的写入丢失」
```

> 注意：这种 bug 是**概率性**的，可能前几轮侥幸通过。所以 `--rounds` 至少 5，正式验收建议 20。

---

## 四、四层测试矩阵

| 层 | 工具 | 通过标准 | 什么时候跑 |
|---|---|---|---|
| L1 正确性 | `model_check.py` | 0 错误，含 3 次重启 | 每次改代码 |
| L2 崩溃一致性 | `crash_test.py` | 20 轮全 PASS | 提交前 / 录 demo |
| L2b torn write | 手动截断 WAL | 能正常启动，不 panic | 提交前 |
| L3 性能 | `bench.py` | 有对比数据 | 写 README 时 |
| L4 长跑 | `bench.py --n 2000000` | 多轮 compaction 不崩、内存平稳 | 提交前 |

### L2b：手动制造 torn write

```bash
# 1. 正常写入并关闭
python mock_dbcli.py --path ./data <<< '{"op":"putmany","items":[["a","1"]],"sync":true}'

# 2. 把 WAL 尾巴切掉 37 字节（模拟断电时写了一半）
truncate -s -37 ./data/wal.jsonl

# 3. 重新打开，应该能正常启动（丢掉不完整记录），而不是崩溃
python mock_dbcli.py --path ./data <<< '{"op":"get","k":"a"}'
```

**你的实现如果在这一步 panic，就是硬伤。** 真实世界每天都在发生这种事。

### L3 性能要对比什么

`bench.py` 只给你自己的数字。要说服评委，得有对照：

| 对照对象 | 怎么拿 | 意义 |
|---|---|---|
| `moonkv`（Bitcask） | 用同样的 dbcli 协议包一层 | 证明 LSM 在写吞吐上的优势 |
| SQLite | `sqlite3` + 同样的 workload | 证明「顺序写 vs 原地更新」的差异 |
| RocksDB | 官方 `db_bench` | 作为上限参考，说明你离工业级还有多远 |

**诚实很重要。** LSM 的读延迟通常比 B+ 树差，空间放大也更大——主动说出来，再说你怎么优化的（bloom filter、分层大小比、 leveled vs tiered compaction），比只报好数字可信得多。

---

## 五、怎么把 kill -9 录成 demo（60–90 秒）

评委看几十个项目，能记住的只有画面。这个镜头值得单独设计：

```
[0:00] 终端左栏：启动 dbcli，开始写入，数字快速上涨
[0:08] 右栏：tail -f 显示 WAL 追加（证明是顺序写）
[0:20] 画外音："现在写入 100 万条，然后我直接 kill -9，不给它任何清理机会"
[0:24] kill -9 <pid>          ← 停顿 1 秒，让画面停住
[0:26] 重启，执行 verify
[0:30] 屏幕打印：
         已确认写入: 1,000,000
         恢复后校验: 1,000,000
         丢失: 0
         耗时: 0.42s
[0:40] 再放一次慢动作重放（0.25x）
[0:50] 切到 bench 表格，一句话总结
```

**要点：**
- 数字要大（100 万条），恢复要快（<1 秒），对比才强烈
- 一定要有「丢失 0」这一行，并且是**校验过**的，不是自己说的
- 录屏用 asciinema（可嵌入 README）或 OBS（画质好）

---

## 六、提交前的验收清单

- [ ] `model_check.py --ops 5000 --restart-every 1000` 全绿
- [ ] `crash_test.py --rounds 20` 全绿
- [ ] 手动截断 WAL 后能正常启动
- [ ] `bench.py --n 2000000` 跑完不崩，内存曲线平稳
- [ ] README 里有 benchmark 表格 + 对照数据
- [ ] 有在线 demo 或 GIF（kill -9 那段）
- [ ] 发布到 mooncakes.io，OSI 许可证，CI 绿
- [ ] 代码里能看到 MoonBit 的味道：ADT 表达 SSTable 记录、trait 抽象 compaction 策略、error 类型做 IO 失败

---

## 七、常见坑

| 现象 | 原因 | 修法 |
|---|---|---|
| 脚本卡住无响应 | 你的 dbcli 没 flush stdout | 每行输出后 `flush()` |
| `crash_test` 报大量 lost | `sync:true` 时没等 fsync 就返回 | 把 fsync 放在响应之前 |
| 重启后 panic | WAL 尾部半条记录没处理 | 长度前缀 / CRC，不完整就截断 |
| 读到旧值 | Memtable 和 SSTable 的查找顺序错了 | Memtable → L0（新到旧）→ L1 → L2 |
| 删了还能读到 | 墓碑没写，或 compaction 提前丢了墓碑 | 墓碑必须保留到最底层 compaction |
| 空间放大 5x+ | compaction 策略有问题 | 检查分层大小比（常见 10x）和触发条件 |
