<!--
提交前请把不适用的部分删掉。评审人会按 CONTRIBUTING.md 的清单逐条看。
-->

## 这个 PR 做了什么

<!-- 一两句话说清。如果是修 bug，说清「原来错在哪」。 -->

## 为什么这样做

<!-- 有其他方案吗？为什么没选？涉及取舍的，考虑开一条 ADR。 -->

## 相关 issue

<!-- Closes #123 / Refs #456 -->

---

## 自查清单

### 通用

- [ ] `moon check --deny-warn` 通过（零警告）
- [ ] `moon test` 全绿
- [ ] `moon fmt` 已跑，提交里没有格式化噪音
- [ ] 新增的公开 API 有 `///|` 文档注释
- [ ] 代码里没有 `panic`（尤其是恢复路径）
- [ ] 没有注释掉的死代码
- [ ] commit message 符合 Conventional Commits

### 如果改动了持久化 / 格式

- [ ] `docs/design/format.md` 已同步更新
- [ ] 不兼容旧格式时，bump 了对应的 `version` 字段
- [ ] `CHANGELOG.md` 的 Unreleased 段落已记录（不兼容的标 **BREAKING**）
- [ ] 所有 `length` / `offset` 字段都是「先校验再使用」，不是「先分配再读」
- [ ] 新增的「删除文件」动作符合不变量 I2（先写后删），并注明了前置条件

### 如果改动了崩溃路径

<!-- 触及 WAL / MANIFEST / fsync 顺序的改动，这几条必须填 -->

- [ ] 说明影响 ADR-0003 的哪条不变量（I1 / I2 / I3）
- [ ] 附上 `python crash_test.py --rounds 5` 的输出
- [ ] 给 PR 打了 `crash-test` 标签（否则崩溃 workflow 不会跑）

### 如果改动了架构决策

- [ ] 新增了 ADR（旧 ADR 只改状态为「已被 ADR-XXXX 取代」，不删不改内容）

---

## 测试说明

<!--
跑了什么、覆盖了什么场景、有什么没覆盖到。
「只跑了 moon test」也是有效信息，说明清楚比空着好。
-->

## 截图 / 数据

<!--
性能相关的改动必须附前后对比（python bench.py 的输出）。
没有前后数据就不要说「更快了」。
-->
