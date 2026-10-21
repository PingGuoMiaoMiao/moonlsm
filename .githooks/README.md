# Git Hooks

## Pre-commit

提交前跑两项**快**检查：

1. `moon check --deny-warn` —— 类型检查，警告即失败
2. `moon fmt` —— 格式化，若产生 diff 则中止提交，让你 `git add` 后重提

耗时的检查（`moon test`、崩溃测试）**故意不放这里**。本地钩子一旦超过几秒，
就会被 `git commit --no-verify` 绕过，那时它等于不存在。这些交给 CI。

### 启用

```bash
chmod +x .githooks/pre-commit
git config core.hooksPath .githooks
```

### 为什么要手动启用

Git 出于安全考虑不会自动执行仓库里的钩子（否则 clone 一个仓库就可能执行任意代码）。
所以必须显式设置 `core.hooksPath`。这是每个贡献者的一次性动作，`CONTRIBUTING.md` 里也写了。

### 临时跳过

```bash
git commit --no-verify -m "..."
```

只在你确认 CI 会兜住的时候用。跳过钩子导致主干变红，比多等两秒的代价大得多。
