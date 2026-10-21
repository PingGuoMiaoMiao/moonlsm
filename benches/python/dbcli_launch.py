#!/usr/bin/env python3
"""dbcli 启动参数的唯一来源 —— 三个驱动脚本都必须经过这里。

## 为什么需要这个文件

dbcli 的数据目录来自环境变量 `MOONLSM_DATA`，**不是命令行参数**。
原因见 `cmd/dbcli/main.mbt`：那个进程的 stdin/stdout 全被 JSON 协议占满了，
再塞一个 `--path` 进去只会让所有驱动脚本的引号转义更复杂。

代价是：每个 `subprocess.Popen` 都必须显式把这个环境变量传下去。
只要有一处漏传，dbcli 就退回默认的 `.moonlsm_data`（相对当前工作目录），
于是「探测脚本写进去的 key」和「对拍脚本自己的 key」混在同一个库里。

这个 bug 的实际症状非常难查：`model_check.py` 最后会报

    FAIL: 最终 scan key 集合不一致 got=161 want=160 extra=['probe:persistence']

看起来像是引擎多返回了一个键（排序错？墓碑没生效？重复数据？），
实际上是探测脚本往同一个目录里写了一条 `probe:persistence`。
排查方向会被完全带偏 —— 所以这里只留一个函数，让「漏传」在结构上不可能发生。

## 三个使用方

    probe_persistence.py  探测引擎是否已支持持久化（exit 0/1/2）
    crash_test.py         kill -9 崩溃一致性测试
    model_check.py        与内存 dict 对拍

`model_check.py` 会以子进程方式调 `probe_persistence.py`，
两者各自解析 `--data-dir`，因此也要各自构造 env（不能只在外层设一次）。
"""

import os


ENV_VAR = "MOONLSM_DATA"


def resolve_dir(explicit, default):
    """决定本次测试用哪个数据目录。

    **刻意不读环境变量里的 `MOONLSM_DATA`。**
    原因：`crash_test.py` 每轮开始都会 `shutil.rmtree` 数据目录。
    如果允许它继承外部环境变量，用户一旦 `export MOONLSM_DATA=~/我的数据`
    再跑崩溃测试，真实数据就被删了。数据目录必须由脚本自己决定，
    环境变量只作为**输出**（传给子进程），绝不作为输入。
    """
    return os.path.abspath(explicit or default)


def child_env(data_dir):
    """构造传给 dbcli 子进程的环境变量。

    必须是 `dict(os.environ)` 的副本而不是 `{"MOONLSM_DATA": ...}`：
    在 Windows 上丢掉 PATH / SystemRoot 之类的变量会让子进程直接起不来。
    """
    env = dict(os.environ)
    env[ENV_VAR] = os.path.abspath(data_dir)
    return env
