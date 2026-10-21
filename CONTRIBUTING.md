# 贡献指南

感谢你愿意贡献。moonlsm 是一个**存储引擎**——它的 bug 会吃掉用户的数据。所以这里的流程比一般项目严一些，请先读完这份文档再提 PR。

---

## 目录

- [开发环境](#开发环境)
- [分支策略](#分支策略)
- [提交信息规范](#提交信息规范)
- [代码规范](#代码规范)
- [测试要求](#测试要求)
- [文档要求](#文档要求)
- [PR 评审清单](#pr-评审清单)
- [不要做的事](#不要做的事)

---

## 开发环境

### 必需

| 工具 | 版本 | 检查命令 |
|---|---|---|
| MoonBit | 见 [`.moon-version`](.moon-version)（当前 `0.1.20260827`）。CI 用 `latest`，两者格式规则不同，见下文 | `moon version --all` |
| Python | `>= 3.10` | `python --version` |

Python 只用于 `benches/python/` 下的测试脚本，不参与构建。运行库本身零依赖。

### 工具链版本：能记录，但锁不住

仓库根目录的 [`.moon-version`](.moon-version) 记录**本项目开发与验证所用的版本**。

```bash
cat .moon-version          # 项目验证版本
moon version --all         # 本地实际版本
```

**为什么记录而不是锁定**：官方 CDN 只提供 `latest` 的二进制。实测

```
https://cli.moonbitlang.com/binaries/0.1.20260827/moonbit-linux-x86_64.tar.gz  →  403
https://cli.moonbitlang.com/binaries/latest/moonbit-linux-x86_64.tar.gz        →  200
```

任何带版本号的路径都下不到，所以「在 CI 里安装指定版本」这件事**做不到**。CI 只能装 `latest`。

**这带来一个必须知道的差异**：

| 版本 | `Int32` 类型 | `moon fmt` 对 `Int` 的处理 |
|---|---|---|
| `0.1.20260827`（项目验证版本） | **不存在** | 保持 `Int` |
| `0.1.20261016`（当前 latest） | 存在 | 重写成 `Int32` |

所以本项目的代码统一写 `Int`——**因为旧版里没有 `Int32`**。CI 的 formatter 会想把它改成 `Int32`，这个差异不可能同时消除。

**应对方式**：

- **格式检查在 CI 里是告警，不阻断**。格式由本地 pre-commit hook 保证（用你自己的 formatter）
- **类型检查与测试在 CI 里是阻断的**，它们不随格式化规则变化
- CI 会打印版本对比，不一致时给 warning annotation

**升级工具链是一个独立任务，不是顺手做的事**：

1. 装新版本，`moon version --all` 确认
2. `moon fmt`，看它把什么改成了什么（当前预期是 `Int` → `Int32`）
3. 全局替换并修掉不兼容，`moon check --deny-warn` + `moon test` 全绿
4. 更新 `.moon-version`
5. 单独开 PR，commit 类型用 `chore(toolchain)`

⚠️ **升级是不可逆的**：旧版本已经无法从 CDN 下载，装上新版后回不去。升级前先确认现有代码在新版本下能编译。

不要在功能 PR 里顺手升级工具链——那会让 diff 里混进几百行格式变化，评审没法看。

### 首次配置

```bash
git clone https://github.com/PingGuoMiaoMiao/moonlsm
cd moonlsm

# 启用仓库自带的 git hook（会做 moon fmt 检查）
git config core.hooksPath .githooks

# 对照 .moon-version 看本地版本
moon version --all

# 验证环境
moon check --deny-warn   # 类型检查，零警告
moon test                # 跑单元测试
moon build --target native
```

### 常用命令

```bash
moon check                          # 类型检查（最快，改代码时高频用）
moon test                           # 单元测试
moon test --update                  # 更新快照测试
moon fmt                            # 格式化
moon build --target native          # 构建 native 目标（测试脚本需要）
moon build --target wasm-gc         # 构建 wasm 目标
```

---

## 分支策略

采用 **trunk-based development**，**不用 git flow**。

```
main ────●────●────●────●────●──→   始终可发布
          \        /
           ●──●──●                    短生命周期分支（≤ 3 天）
```

### 规则

- `main` 始终可发布。**不允许**在 `main` 上直接提交（除了文档错别字）
- 分支命名：`feat/xxx`、`fix/xxx`、`docs/xxx`、`refactor/xxx`、`test/xxx`
- 分支生命周期**不超过 3 天**。做不完就拆成多个小 PR
- 合并方式：**Squash merge**。一个 PR = 一个 commit，保持 `main` 的线性历史
- 合并前必须 rebase 到最新 `main`，不允许 merge commit

### 为什么不用 git flow

`develop` / `release` / `hotfix` 这一套是为「多版本并行维护 + 定期发版」设计的。moonlsm 是单人维护、连续发布，多一层 `develop` 只会让「哪个分支是真相」变模糊。trunk-based 的代价是需要 feature flag 来隐藏未完成功能——但我们没有这个问题，未完成的模块直接不 `pub` 就行。

---

## 提交信息规范

遵循 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/)。

```
<type>(<scope>): <subject>

<body>

<footer>
```

### type

| type | 用途 | 会进 CHANGELOG 吗 |
|---|---|---|
| `feat` | 新功能 | ✅ 新增 |
| `fix` | 修 bug | ✅ 修复 |
| `perf` | 性能优化 | ✅ 变更 |
| `refactor` | 重构（不改行为） | ❌ |
| `test` | 加测试 | ❌ |
| `docs` | 文档 | ❌ |
| `chore` | 构建、依赖、脚手架 | ❌ |
| `revert` | 回滚 | ✅ |

### scope

用文件名或模块名：`wal`、`sstable`、`memtable`、`bloom`、`dbcli`、`bench`、`ci`、`docs`

### 例子

```
feat(wal): 实现帧格式与恢复时的尾部截断

按 docs/design/format.md §2 实现 WAL 帧的编解码。
恢复时 CRC 不匹配一律截断到最后一条好帧，不 panic。

Closes #12
```

```
fix(dbcli): scan 端点比较改用字节序

String::compare 按长度优先，导致 "k00001" 这类长 key 被漏掉。
model_check 报 got=3 want=109。
```

### 破坏性变更

在 type 后加 `!`，并在 footer 写 `BREAKING CHANGE:`：

```
feat(format)!: WAL 帧增加 type 字段

BREAKING CHANGE: WAL 格式从 v1 升到 v2，旧的 WAL 文件无法直接读取。
迁移方法见 docs/design/format.md §5.2。
```

---

## 代码规范

### 语言

- 注释、文档、commit message：**中文**
- 标识符（变量、函数、类型）：**英文**
- 错误信息：**英文**（要进日志和异常栈，保持 ASCII）

### 文件头

每个 `.mbt` 文件顶部写一段 `///|` 文档注释，说明：

1. 这个文件负责什么
2. **它只依赖哪些文件**（用来守 ADR-0001 的依赖方向）
3. 有什么不显然的取舍

```moonbit
///|
/// WAL：预写日志。格式见 docs/design/format.md §2。
/// 本文件只依赖 types / error。
///
/// 一条记录一帧，不跨帧拆分（ADR-0002）。
/// 恢复时 CRC 失败一律视为尾部截断，不报错（ADR-0003 不变量 I3）。
```

### 命名

| 种类 | 风格 | 例子 |
|---|---|---|
| 类型 / struct / enum | PascalCase | `MemTable`、`LsmError` |
| 函数 / 变量 | snake_case | `compare_bytes`、`lower_bound` |
| 常量 | SCREAMING_SNAKE | `MAX_RECORD`、`BLOCK_SIZE` |
| 私有辅助函数 | snake_case，不 `pub` | `fn wal_crc(...)` |

### 错误处理

- **禁止 `panic`**。这是硬规则，尤其是恢复路径（ADR-0003 不变量 I3）
- 公开 API 用 `raise LsmError`，内部用 `Result` 或直接 `raise` 透传
- 错误信息要包含**足够的上下文**：哪个文件、哪个偏移、期望什么、实际什么

```moonbit
// 好
raise Io("wal/000008.wal: 偏移 4096 处 CRC 不匹配（期望 0x1a2b3c4d，实际 0x00000000）")

// 差
raise Io("crc error")
```

### 格式化

`moon fmt` 是唯一标准。pre-commit hook 会检查，格式不对直接拒绝提交。

---

## 测试要求

**没有测试的功能不算完成。** 这条没有例外。

### 三层测试

| 层 | 位置 | 什么时候必须加 |
|---|---|---|
| 单元测试 | `*_test.mbt`（黑盒，走公开 API） | 每个新公开函数 |
| 白盒测试 | `*_wbtest.mbt`（测内部不变量） | 涉及内部状态的逻辑（如 memtable 的 `bytes` 计数） |
| 集成测试 | `benches/python/*.py` | 改 `dbcli` 协议、改崩溃路径、改格式 |

### 崩溃相关的改动必须额外验证

任何触及 WAL / MANIFEST / fsync 顺序的改动，PR 里必须附：

1. `python crash_test.py --rounds 5` 的输出截图或日志
2. 说明这次改动影响 ADR-0003 的哪条不变量（I1 / I2 / I3），以及如何验证

**只跑 `kill -9` 是不够的**——它测不出「忘了 fsync」。原因见 ADR-0003。

### 测试命名

用中文描述行为，不用 `test1`、`test2`：

```moonbit
///|
test "memtable: 同一个 key 后写的覆盖先写的" {
  ...
}

///|
test "bloom: 不存在的 key 绝不误判为存在（假阴性为 0）" {
  ...
}
```

---

## 文档要求

### 改格式 = 必须改文档

任何触及磁盘字节布局的改动，必须同步更新 `docs/design/format.md`，且：

- 如果**不兼容**旧格式：bump 对应结构的 `version` 字段
- 在 `CHANGELOG.md` 标注 **BREAKING**
- 写清迁移方法（或明确写「不支持迁移」）

### 改架构决策 = 必须开新 ADR

`docs/adr/` 里的文件**只追加，不修改**。决策变了就开一条新 ADR，
并在旧 ADR 的状态里写 `已被 ADR-XXXX 取代`。

### ADR 的硬性要求

- 「后果」必须**同时写正面和负面**。只写优点的 ADR 是宣传材料
- 「备选方案」至少 2 个，每个都要写**否决理由**

---

## PR 评审清单

提交前自己先过一遍。评审人也会按这个清单看。

### 通用

- [ ] `moon check` 无错误，`moon fmt` 已跑
- [ ] `moon test` 全绿
- [ ] 新增公开 API 有文档注释（`///|`）
- [ ] 没有 `panic`
- [ ] 没有注释掉的死代码
- [ ] commit message 符合 Conventional Commits

### 存储 / 持久化相关（额外）

- [ ] 恢复路径上所有解析都返回 `Result`/`Option`，无 `panic`
- [ ] 所有 `length` / `offset` 字段**先校验再使用**，不先分配
- [ ] 长度上限来自代码常量，不来自文件内容
- [ ] 新增的「删除文件」动作符合 I2（先写后删），且写明了前置条件
- [ ] 若改动触及 fsync 顺序，附了 `crash_test.py` 输出

### 文档相关（额外）

- [ ] 改了格式 → `docs/design/format.md` 同步更新 + version bump
- [ ] 改了行为 → `CHANGELOG.md` 的 Unreleased 段落有记录
- [ ] 改了架构决策 → 新增 ADR，旧 ADR 状态更新为「已取代」

---

## 不要做的事

这些不是风格偏好，是会引入 bug 的实践：

### 1. 不要用 `String::compare` 比较 key

它按**长度优先**，不是字节序。`"k9"` 会排在 `"k10"` 后面。二进制 key 必须用 `compare_bytes`。
（这个坑已经踩过一次，见 `PLAN.md` §6）

### 2. 不要先按 `length` 分配再读

```
错误:  let buf = Array::new(capacity = length); 读 length 字节到 buf
正确:  检查 length <= 剩余字节数 && length <= MAX → 再分配
```

### 3. 不要在恢复路径上用 `unwrap` 语义

任何「这里不可能失败」的假设，在磁盘损坏面前都是错的。

### 4. 不要为了性能去掉 CRC

CRC32C 有硬件指令，开销远小于你想象。而少了它，位翻转就会静默变成数据错误。

### 5. 不要在没有基准数据的情况下「优化」

先 `python bench.py` 拿到数字，再改代码，再跑一次。没有前后对比的优化是猜测。

### 6. 不要把 `sync:true` 的实现「优化」成批量 fsync

这会违反契约 C1（已确认必不丢）。要做 group commit 需要先开新 ADR。

### 7. 不要在 PR 里顺手格式化无关文件

会让 diff 无法评审。格式化单独开一个 PR。

---

## 有问题？

- 设计层面的疑问 → 开 issue，标签 `question` 或 `design`
- 发现了 bug → 开 issue，附最小复现
- 发现安全漏洞 → **不要开 issue**，见 [SECURITY.md](SECURITY.md)
