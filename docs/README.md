# 文档索引

本目录区分三类文档，职责不同，**不要混着写**：

| 目录 | 性质 | 改它的时机 |
|---|---|---|
| `design/` | **契约**：系统「是什么」 | 实现服从文档。要改先改文档，再改实现 |
| `adr/` | **决策记录**：为什么是现在这样 | 只追加，不改历史。决策变了就开新 ADR 取代旧的 |
| `engineering/` | **过程**：怎么把它做出来 | 随方法论与阶段变化更新 |
| `submission/` | **对外材料**：申报书与演示 | 只在申报/答辩时更新，与代码解耦 |

---

## design/ —— 规范

| 文档 | 内容 | 状态 |
|---|---|---|
| [format.md](design/format.md) | 磁盘格式规范 v1：WAL / SSTable / MANIFEST / CURRENT 的字节布局、恢复算法、版本演进规则 | 已冻结 |

**「已冻结」的含义**：v1 发布后，这些字节布局不得在不 bump `version` 字段的前提下改动。任何格式变更必须同步更新本文档与 CHANGELOG。

---

## engineering/ —— 过程与方法

| 文档 | 内容 |
|---|---|
| [ACCEPTANCE.md](engineering/ACCEPTANCE.md) | **验收手册**：这个库要干什么、四类契约、五关验收（命令 + 期望输出 + 失败含义）、8 个参考库位置、发布前检查清单 |
| [REVIEW.md](engineering/REVIEW.md) | **评审对照**：比赛验收 9 项要求逐条自查 —— 现状、怎么自己验一遍、证据在哪个文件 |
| [PROCESS.md](engineering/PROCESS.md) | 仓库命名考究、参考对象分层、GIV 开发模型、设计模型与 8 张流程图、项目→产品四阶段演进、度量与门禁定义 |
| [BENCHMARK.md](engineering/BENCHMARK.md) | **性能基准**：主表、组提交量化、SQLite 对照、四处已知瓶颈、测量方法的局限 |
| [DEMO.md](engineering/DEMO.md) | **90 秒演示方案**：分镜、逐字稿、录制前检查、追问应答 |
| [prompter.html](engineering/prompter.html) | 提词器（单文件网页）：大字号逐字稿 + 计时 + 每段预算，录制时照着念 |

两份文档的分工：
- **不知道「做完是什么样」** → 看 ACCEPTANCE
- **不知道「为什么这样组织开发」** → 看 PROCESS

与 `PLAN.md` 的分工：`PLAN.md` 是**排期表**（哪天做什么），`PROCESS.md` 是**方法论**（为什么这样排、什么算做完）。

---

## submission/ —— 对外材料

| 文档 | 内容 |
|---|---|
| [APPLICATION.md](submission/APPLICATION.md) | **申报书正文**：痛点 / 边界 / API / 测试策略 / 里程碑，一页篇幅 |
| [application.html](submission/application.html) | 排版源文件（A4 打印样式），改完用无头 Chrome 重新出 PDF |
| [application.pdf](submission/application.pdf) | 提交用成品，A4 单页 |

重新生成 PDF：

```bash
"/c/Program Files/Google/Chrome/Application/chrome.exe" --headless --disable-gpu \
  --no-pdf-header-footer --print-to-pdf=application.pdf application.html
```

**字号 8.7pt 是实测出来的上限**：再大 0.05pt 就会溢到第二页。改内容后务必重新确认页数，
「一页」是这份材料的硬约束——评审一天看几十份，翻页就是掉分。

---

## adr/ —— 架构决策记录

| 编号 | 标题 | 一句话结论 |
|---|---|---|
| [0001](adr/0001-single-package.md) | 单包多文件，不按模块拆包 | API 边界靠「不写 `pub`」守，不靠包边界守 |
| [0002](adr/0002-wal-format.md) | WAL 一条记录一帧，MANIFEST 用全量快照 | WAL 的日志性是本质需求，MANIFEST 的日志性是历史包袱 |
| [0003](adr/0003-crash-contract.md) | 崩溃一致性契约 | `kill -9` 测不出「忘了 fsync」；承诺已确认必不丢，未确认允许丢 |
| [0004](adr/0004-storage-abstraction.md) | 存储后端抽象 | 把平台差异关进一个文件，崩溃语义才能在 `moon test` 里断言 |
| [0005](adr/0005-group-commit.md) | 组提交 | 一批只 fsync 一次，把 39× 的持久化代价压到 1.40× |
| [0006](adr/0006-refuse-to-open-on-bad-manifest.md) | 坏 MANIFEST 拒绝启动 | 回退旧版本会静默丢掉已 ack 的数据，宁可不启动 |
| [0007](adr/0007-compaction-levels-and-tombstones.md) | 三层归并、墓碑只在最底层丢 | 只有目标层是底层时才丢墓碑，否则删掉的数据会复活 |
| [0008](adr/0008-bloom-layout-and-file-range-pruning.md) | bloom 布局与文件级剪枝 | 参数本来就最优，错的是「一次未命中要探 77 个文件」 |
| [0009](adr/0009-cached-wal-handle.md) | 常开一个追加句柄 | 单条 `put` 的成本全在「每条写开关两次文件」上，不在 `fsync` 上 |
| [0010](adr/0010-block-and-filter-crc.md) | block / filter 加 CRC，格式升到 v2 | filter 坏了会**主动丢数据**；校验必须在打开时做，因为 `get` 无法表达「读不懂」 |
| [0011](adr/0011-lazy-scan-cursor.md) | 范围扫描改成块级惰性游标 | `limit` 只在归并之后生效，等于「取 10 条也要解 10 万条」；剪枝必须前置到归并器之外 |

### 读 ADR 的正确姿势

每条 ADR 的 **「备选方案」** 一节和「决策」同样重要。它记录了我们考虑过但否决的路，以及否决的具体理由。评审时如果只看到「我们选了 A」，会怀疑是不是没想到 B；看到「我们选了 A，因为 B 会在 X 场景下失败」，才是工程判断的证据。

### 新增 ADR 的规则

1. 编号连续，四位补零：`0004-xxx.md`
2. 必须包含：状态 / 日期 / 背景 / 决策 / 理由 / 后果 / 备选方案
3. 「后果」必须**同时写正面和负面**。只写优点的 ADR 是宣传材料，不是决策记录
4. 「备选方案」至少写 2 个，且必须写清否决理由
5. 决策被推翻时，旧 ADR 状态改为 `已被 ADR-XXXX 取代`，**不删除**

---

## 与其他文档的关系

```
README.md              用户视角：这是什么、怎么用、能做什么不能做什么
PLAN.md                排期视角：模块拆分、三周排期、风险止损
docs/engineering/*.md  过程视角：命名考究、开发模型、流程图、演进路线
docs/design/*.md       实现视角：字节级契约
docs/adr/*.md          决策视角：为什么这样而不那样
CHANGELOG.md           时间视角：每个版本改了什么
```

如果 README 与 design 冲突，以 **design** 为准（README 是给用户的摘要，可能滞后）。
如果 design 与代码冲突，以 **design** 为准，并视为代码 bug。
如果 PROCESS.md 的流程图与代码冲突，**以代码为准并立刻改图**——流程图滞后比没有更糟。
