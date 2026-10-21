# ADR-0004：存储后端抽象 —— 把平台差异关进一个文件

- **状态**：已接受（Accepted）
- **日期**：2026-10-21
- **决策者**：PingGuoMiaoMiao
- **影响范围**：`storage.mbt`、`fs_native.mbt`、`db.mbt`、`cmd/dbcli`、全部崩溃测试

---

## 背景（Context）

Week 2 要做的第一件事是「真落盘」：WAL 写到文件、SST 写到文件、CURRENT 原子切换。
在写第一行 `fopen` 之前，有两个问题必须先解决，否则后面每一步都在还债。

### 问题一：崩溃契约测不了

ADR-0003 承诺了 C1「已确认的写入必不丢」，并把测试分成 L1–L4 四层。其中：

- L2 = `kill -9`，能测「进程死了数据还在」
- L3/L4 = 断电、掉电，才能测「忘了 fsync」

问题在于 **`kill -9` 根本测不出「忘了 fsync」**：进程被杀时，OS 页缓存里的数据还在，
下次读文件照样能读到。也就是说，一个 `fwrite` 之后从不 `fsync` 的实现，
可以通过全部 `kill -9` 测试，然后在第一次真断电时丢掉已 ack 的写入。

L3/L4 需要虚拟机断电或块设备故障注入，成本高、不可在 CI 里跑、更不能在
wasm-gc / js 后端跑。于是「我们承诺 C1」这句话在 CI 里实际上**没有任何证据**。

### 问题二：三个平台的 `fsync` 名字不一样

第一次写 `extern "C" fn fsync(...)` 就撞墙了。实测结论（Windows + MSVC UCRT）：

| 能力 | POSIX | Windows (MSVC UCRT) | 结果 |
|---|---|---|---|
| 刷盘 | `fsync(fd)` | `_commit(fd)` | 符号名不同 |
| 截断 | `ftruncate(fd, len)` | `_chsize(fd, len)` | 符号名不同 |
| 建目录 | `mkdir(path, mode)` | `_mkdir(path)` | 名字**和**参数个数都不同 |
| 定位 | `fseeko` / `ftello` | `_fseeki64` / `_ftelli64` | 名字不同，`long` 宽度不同 |
| 改名 | `rename`（0 = 成功） | `MoveFileExA`（**非 0 = 成功**） | 名字不同，**返回值约定相反** |

直接声明 POSIX 名字的后果是 `link` 阶段报 `LNK2019: unresolved external symbol fsync`。
这不是运行期错误，是构建直接失败。

而且**不能靠加 C 文件绕开**：实测本工具链（`moon 0.1.20260827`）的 `moon.pkg` / `moon.mod`
都**不支持** `link` / `stub-cc` / `cc-flags` 之类的配置（写进去报 `Unexpected key 'link' found`），
包目录下的 `.c` 文件也不会被自动编译。所以「写个 shim.c 包一层」这条路是断的。

---

## 决策（Decision）

### 1. 引擎只依赖 `Storage` trait，不直接碰 IO

```moonbit
pub trait Storage {
  fn prepare(Self) -> Unit raise LsmError
  fn read_file(Self, String) -> Bytes? raise LsmError
  fn write_file(Self, String, Bytes) -> Unit raise LsmError
  fn append_file(Self, String, Bytes) -> Unit raise LsmError
  fn sync_file(Self, String) -> Unit raise LsmError
  fn rename_file(Self, String, String) -> Unit raise LsmError
  fn remove_file(Self, String) -> Unit raise LsmError
  fn file_size(Self, String) -> Int? raise LsmError
  fn list_files(Self, String) -> Array[String] raise LsmError
}
```

`append_file` 与 `sync_file` **刻意分开**。合成一个 `append_and_sync` 会锁死
「批量提交时写 N 条、sync 1 次」这个优化，而那正是 WAL 最重要的性能手段。

### 2. `MemStorage` 用「双影子」模拟断电

```moonbit
pub struct MemStorage {
  files : Map[String, Bytes]      // 当前视图（含未落盘）
  durable : Map[String, Bytes]    // 已 fsync 的内容
  ...
}
```

- `sync_file(name)` 把 `files[name]` 拷进 `durable[name]`
- `power_loss()` 把所有「只在 `files` 里」的文件删掉，再把 `durable` 覆盖回去

于是 C1 变成一条**确定性的、进程内的、三个后端都能跑**的断言：

```moonbit
st.append_file("WAL-1", frame)
st.sync_file("WAL-1")
st.power_loss()
// WAL-1 必须还在，且内容完全一致
```

这个模型刻意比真磁盘**更严格**：真磁盘上未 fsync 的页*可能*会幸存（OS 迟早会写下去），
这里一律当作「不会」。只允许更悲观的崩溃，测试就不会假阳性。

它还顺带解锁了两个原来很难测的场景：

- **fsync 失败**：`set_fail_sync(true)`，验证「fsync 没成功就不许 ack」
- **构造任意磁盘状态**：`plant(name, data)` 直接摆出「WAL 尾部有半条记录」

### 3. 平台差异全部收在 `fs_native.mbt`

用 `#cfg(platform = "windows")` / `#cfg(not(platform = "windows"))` 声明两套同名函数，
在**声明层**分开，调用方看到的永远是「0 = 成功」这一种约定。

⚠️ 这里有一个容易踩的坑：MoonBit 的条件编译有两个维度，名字很像但含义不同：

| 属性 | 维度 | 取值 |
|---|---|---|
| `#cfg(target = ...)` | **后端** | `native` / `wasm-gc` / `js` |
| `#cfg(platform = ...)` | **操作系统** | `windows` / `linux` / `macos` |

用错 `target` 去判断操作系统，会得到一个**永远不成立的谓词**：两个分支都被丢掉，
症状是「函数未定义」而不是「链接失败」，比链接错误难查得多。
`debug = true/false` 也是合法的 `#cfg` 谓词。

### 4. 按后端排除文件，而不是按平台

```moonbit
options(
  targets: {
    "fs_native.mbt": [ "native" ],
    "fs_native_wbtest.mbt": [ "native" ],
  },
)
```

wasm-gc / js 没有 libc，`extern "C"` 到 `fopen` 在链接期就失败。所以文件级排除，
让核心逻辑（`storage.mbt` / `block.mbt` / `wal.mbt` / `db.mbt`）在三个后端上都能编译——
这本身就是「核心不偷偷依赖 native」的机器可判定证明。

---

## 后果（Consequences）

### 好的

- **C1 从文档变成断言**，98 条测试里有 6 条是断电语义，且能在 wasm-gc / js 上跑
- **平台差异只在一个文件里**，核心逻辑零平台判断
- **核心可测性大幅提升**：注入 fsync 失败、构造任意磁盘状态都变成一行代码
- 发现并修掉了一个**真实的跨平台语义 bug**（见下）

### 代价

- 每次文件操作都 `fopen` / `fclose`，不保持常开句柄。压测时会明显慢。
  优化点是引入带缓冲的句柄表，但那是性能问题，不是正确性问题，放到 M3 之后。
- `Storage` 是个 trait，`Db` 需要泛型参数或 trait object。目前用泛型
  `Db[S : Storage]`，静态分发，没有虚表开销。
- Windows 上 `rename` 的返回值约定与 POSIX **相反**，必须归一化。
  这是本次实现中抓到的真实 bug，见下。

### 实现过程中抓到的三个真 bug

这三个都不是「写错一个字母」，而是**只有真跑起来才会暴露**的语义级问题：

1. **`rename` 返回值约定相反**
   POSIX `rename` 返回 0 表示成功；Windows `MoveFileExA` 返回**非 0** 表示成功。
   最初直接透传返回值，症状是「改名成功时报错、失败时静默通过」——
   CURRENT 切换会在 Windows 上彻底失效。修法是在 `rename_at` 内部归一化，
   绝不把平台约定泄漏给调用方。

2. **Windows 的 `rename` 不能覆盖已存在文件**
   POSIX 是原子覆盖，Windows 是直接失败。CURRENT 的每次切换都是「新名字覆盖旧名字」，
   用 `rename` 的话第二次 flush 之后数据库就再也启动不了。
   改用 `MoveFileExA` + `MOVEFILE_REPLACE_EXISTING`（`0x1`），
   并加上 `MOVEFILE_WRITE_THROUGH`（`0x8`）顺便解决持久性。

3. **`moonbit_read_dir_ffi` 返回的是 `FixedArray` 而不是 `Array`**
   声明成 `Array[Bytes]` 时，空目录能过、非空目录**直接段错误**（`0xc0000005`）。
   原因是可增长的 `Array` 与运行时分配的引用数组布局不同。
   改成 `FixedArray[Bytes]` 后正常。

另外 `mkdir` 不建父目录，`prepare()` 必须逐级创建——
第一版就因为这个在 `.moonlsm_test/rw` 上拿到 `ENOENT`。

---

## 备选方案（Alternatives）

### A. 写 C shim（`#ifdef _WIN32` 包一层）

最直觉的方案，但**当前工具链不支持**：`moon.pkg` / `moon.mod` 都没有
`link` / `stub-cc` 配置项，包目录下的 `.c` 不会被编译。实测报错：

```
Unexpected key 'link' found in moon.pkg.
Unexpected key 'link' found in moon.mod.
```

等工具链支持后可以重估。即便如此，`Storage` 抽象仍然应该保留——
它是崩溃测试的基础，不是为了绕开平台差异才存在的。

### B. 只用 POSIX，Windows 不保证

会让开发机（Windows）跑不了自己的数据库。不可接受。

### C. 直接硬编码 `fsync`，靠 CI 只跑 Linux

把问题扫到地毯下。CI 绿了，但 Windows 用户 `moon build` 直接失败，
而且崩溃契约仍然不可测。

### D. 不做 `Storage`，`Db` 里直接调 `fopen`

最短路径，但意味着：断电测试只能靠虚拟机、无法注入 fsync 失败、
平台差异散落在业务逻辑里。M3 做 compaction 时会把这些问题放大十倍。

---

## 参考

- 本文的平台实测结论来自 `moon 0.1.20260827` + Windows MSVC UCRT + Git Bash
- `#cfg` 的两个维度：`target`（后端）与 `platform`（操作系统）
- `docs/design/format.md` §3.5（CURRENT 的原子切换依赖本文的 `rename_file`）
- ADR-0003（崩溃一致性契约 C1–C5 与测试分层 L1–L4）
