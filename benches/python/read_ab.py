"""临时脚本：在**同一份数据的两个副本**上做只读 A/B，隔离写阶段的影响。

存在的理由：20 万条那组基准是「先写后读」跑在同一个进程里，
两版二进制的读延迟差了近 40%，但读路径一行没改。要判断这 40%
是真的还是写阶段留下的状态（句柄表 / 页缓存），只能在同样的数据上
单独跑读 —— 这个脚本就是那个对照。

它**不复制、不删除任何目录**：两份副本由调用方先准备好，
脚本只负责各开一个 dbcli 进程发同样的读请求。
（早先版本在脚本里 rmtree，被工作区的删除保护拦下了 —— 拦得对，
压测脚本不该顺手删目录。）

跑法：
  python _read_ab.py <base.exe> <base_dir> <new.exe> <new_dir>
"""

import random
import statistics
import sys
import time

import bench
import dbcli_launch


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * p))]


def run_one(exe, data_dir, keys):
    cli = bench.Client([exe], dbcli_launch.child_env(data_dir))
    # 预热：让页缓存先热起来，不然第一次读全是冷启动
    for k in keys[:200]:
        cli.call({"op": "get", "key": k})
    lat = []
    for k in keys:
        t0 = time.perf_counter()
        cli.call({"op": "get", "key": k})
        lat.append((time.perf_counter() - t0) * 1000.0)
    cli.stop()
    return lat


def main():
    base_exe, base_dir, new_exe, new_dir = sys.argv[1:5]
    rng = random.Random(42)
    hits = ["key%010d" % rng.randrange(200000) for _ in range(20000)]
    misses = ["absent%08d" % rng.randrange(1000000) for _ in range(20000)]
    for label, keys in (("命中  ", hits), ("未命中", misses)):
        b = run_one(base_exe, base_dir, keys)
        n = run_one(new_exe, new_dir, keys)
        print("%s P50 base=%.3f new=%.3f | P99 base=%.3f new=%.3f | 均值 base=%.3f new=%.3f"
              % (label, pct(b, 0.5), pct(n, 0.5), pct(b, 0.99), pct(n, 0.99),
                 statistics.mean(b), statistics.mean(n)))


if __name__ == "__main__":
    main()
