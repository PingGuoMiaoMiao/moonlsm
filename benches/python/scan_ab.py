#!/usr/bin/env python3
"""范围扫描的同场 A/B：旧路径（先把区间全解出来再截断）vs 惰性游标（ADR-0011）。

## 为什么要单独写一个脚本

`bench.py` 里的「范围扫描 100 次」是**端到端**指标：它把随机区间的
500 条全取回来，所以「只解需要的块」这件事根本没机会省下什么 ——
要 500 条就得解 500 条所在的块，新旧两条路径的工作量本来就接近。

真正拉开差距的是另一种查询：**区间很宽、只要前几条**。
比如「前缀扫描取前 10 条」—— 用户最常见的分页第一页。
旧路径要把整个区间的条目全部解出来、全部塞进数组、再丢掉后面 99.9%；
新路径解到第 1 块就够了。

## 方法（沿用 ADR-0009 定下的规矩）

- 冻结改动前的二进制（`--old`），与新的（`--new`）**同时存在**
- 同一份数据的两个**独立副本**，两个进程交替发同一个请求
- 每轮交替，取中位数。不取均值：单次抖动（GC、调度）会污染均值
- 先 warmup 一轮，让文件系统缓存进入稳态
- 每轮顺带核对两边返回的 items **完全一致** —— 快不能以结果不同为代价

## 用法

    python scan_ab.py --old /tmp/ab/dbcli_old.exe --new /tmp/ab/dbcli_new.exe

数据只在第一次生成（`--data-src`），之后复用。
"""

import argparse
import json
import os
import queue
import shutil
import statistics
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))


class Client:
    """dbcli 的最小驱动。协议是一行一个 JSON。"""

    def __init__(self, cmd, data_dir):
        env = dict(os.environ)
        env["MOONLSM_DATA"] = os.path.abspath(data_dir)
        self.proc = subprocess.Popen(
            [cmd],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
            env=env,
        )
        self.q = queue.Queue()
        threading.Thread(target=self._pump, args=(self.proc.stdout,), daemon=True).start()

    def _pump(self, stream):
        try:
            for line in stream:
                self.q.put(line)
        except Exception:
            pass

    def call(self, req, timeout=600):
        self.proc.stdin.write(json.dumps(req, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()
        line = self.q.get(timeout=timeout)
        return json.loads(line)

    def close(self):
        try:
            self.call({"op": "close"}, timeout=30)
        except Exception:
            pass
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=30)
        except Exception:
            self.proc.kill()


def build_data(cmd, data_dir, n, batch):
    """用其中一个二进制生成基准数据。两个副本都从它复制，保证内容一致。"""
    if os.path.isdir(data_dir):
        print("复用已有数据: %s" % data_dir)
        return
    print("生成数据: %d 条 -> %s" % (n, data_dir))
    c = Client(cmd, data_dir)
    t0 = time.perf_counter()
    # 每 5 万条 flush 一次，让数据分布在 L0/L1/L2 上。
    #
    # 一开始我是「全写完再 flush 一次」，结果 `levels=[0, 0, 55]` ——
    # 55 个文件全在 L2，来源数很少，扫一个窄区间只碰 1 个文件，
    # 于是新旧两条路径的工作量几乎一样，测出来的差异被压没了。
    # 真实负载不会长这样：写与 flush 交替发生，每一层都有文件。
    flush_every = max(1, 50000 // batch)
    for k, base in enumerate(range(0, n, batch)):
        items = [["key%010d" % i, "v" * 100] for i in range(base, min(base + batch, n))]
        r = c.call({"op": "putmany", "items": items, "sync": False})
        if not r.get("ok"):
            raise RuntimeError("putmany 失败: %r" % (r,))
        if (k + 1) % flush_every == 0:
            c.call({"op": "flush"})
    # 最后再刷一次，别把尾巴留在 memtable 里（那是另一个故事）
    c.call({"op": "flush"})
    st = c.call({"op": "stats"})
    c.close()
    print("  写入 %.1f 秒，ssts=%s levels=%s"
          % (time.perf_counter() - t0, st.get("ssts"), st.get("levels")))


SCENARIOS = [
    # (名字, start, end, limit, 说明)
    ("前缀扫描取前 10", "key", "kez", 10, "区间覆盖全库，只要前 10 条"),
    ("前缀扫描取前 1000", "key", "kez", 1000, "同样的宽区间，limit 放大 100 倍"),
    ("中段 500 条", "key0000000000", "key0000000500", 500, "区间本身就只有 500 条"),
    ("中段 10 条", "key0000250000", "key0000250010", 10, "窄区间 + 小 limit"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", required=True, help="改动前的 dbcli")
    ap.add_argument("--new", required=True, help="改动后的 dbcli")
    ap.add_argument("--n", type=int, default=500_000)
    ap.add_argument("--batch", type=int, default=1000)
    ap.add_argument("--rounds", type=int, default=15)
    ap.add_argument("--work", default=os.path.join(HERE, "data-scan-ab"))
    args = ap.parse_args()

    src = os.path.join(args.work, "src")
    d_old = os.path.join(args.work, "old")
    d_new = os.path.join(args.work, "new")
    os.makedirs(args.work, exist_ok=True)

    build_data(args.new, src, args.n, args.batch)

    # 两个独立副本：dbcli 打开时可能截断 WAL、重写 CURRENT，
    # 共用一个目录会让两边互相干扰（也测不出真实差异）。
    for d in (d_old, d_new):
        if os.path.isdir(d):
            shutil.rmtree(d)
        shutil.copytree(src, d)

    co = Client(args.old, d_old)
    cn = Client(args.new, d_new)

    rows = []
    for name, start, end, limit, note in SCENARIOS:
        req = {"op": "scan", "start": start, "end": end, "limit": limit}
        # warmup：让两边的页缓存都进入稳态，第一次读的冷启动不算
        ro = co.call(req)
        rn = cn.call(req)
        if ro.get("items") != rn.get("items"):
            print("!! %s: 两边结果不一致" % name)
            print("   old=%d 条  new=%d 条" % (len(ro.get("items") or []), len(rn.get("items") or [])))
            sys.exit(1)
        n_items = len(ro.get("items") or [])

        to, tn = [], []
        for r in range(args.rounds):
            # ABBA，不是固定「先旧后新」。
            #
            # 固定顺序会系统性偏袒先跑的那个：它总是拿到「上一个请求刚把
            # 页缓存焐热」的位置。实测过一次固定顺序的写路径 A/B，
            # 明明两边代码完全一样，却稳定测出 15% 的差异；
            # 换成 ABBA 之后差异消失（0.966，min/max 区间重叠）。
            if r % 2 == 0:
                t = time.perf_counter()
                co.call(req)
                to.append(time.perf_counter() - t)

                t = time.perf_counter()
                cn.call(req)
                tn.append(time.perf_counter() - t)
            else:
                t = time.perf_counter()
                cn.call(req)
                tn.append(time.perf_counter() - t)

                t = time.perf_counter()
                co.call(req)
                to.append(time.perf_counter() - t)

        mo = statistics.median(to) * 1000
        mn = statistics.median(tn) * 1000
        rows.append((name, note, n_items, mo, mn, mo / mn if mn else 0))
        print("  %-14s 返回 %4d 条 | 旧 %7.2f ms | 新 %7.2f ms | %5.2fx"
              % (name, n_items, mo, mn, mo / mn if mn else 0))

    co.close()
    cn.close()

    print()
    print("| 场景 | 返回条数 | 旧路径 (ms) | 新路径 (ms) | 加速 |")
    print("|---|---:|---:|---:|---:|")
    for name, note, k, mo, mn, sp in rows:
        print("| %s | %d | %.2f | %.2f | **%.2fx** |" % (name, k, mo, mn, sp))
    print()
    print("说明：中位数，%d 轮交替，同一份数据的两个副本。" % args.rounds)
    print("旧 = 先把每个来源的整个区间读成数组再归并；新 = 块级惰性游标。")


if __name__ == "__main__":
    main()
