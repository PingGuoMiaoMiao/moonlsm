#!/usr/bin/env python3
"""性能基准 —— 输出一张能直接贴进 README / 答辩 PPT 的表格。

测四件事：
  1. 写吞吐（顺序 key vs 随机 key）——LSM 的优势区，必须明显快
  2. 读延迟 P50/P95/P99（命中 / 未命中）——LSM 的劣势区，要诚实展示
  3. 范围扫描吞吐
  4. 空间放大（磁盘占用 / 原始数据量）——compaction 策略的直接体现

用法：
  python bench.py --cmd "python mock_dbcli.py --path ./data" --n 200000
  python bench.py --cmd "../../_build/native/release/build/cmd/dbcli/dbcli.exe" --n 100000

（真实现的 dbcli 没有 `--path`，数据目录走 `MOONLSM_DATA`，由 dbcli_launch.py 注入）
"""

import argparse
import json
import os
import queue
import random
import shlex
import shutil
import subprocess
import sys
import threading
import time


class Client:
    def __init__(self, cmd):
        self.cmd = cmd
        self.proc = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, encoding="utf-8", bufsize=1,
        )
        self.q = queue.Queue()

        def _r(stream):
            try:
                for line in stream:
                    self.q.put(line)
            except Exception:
                pass

        threading.Thread(target=_r, args=(self.proc.stdout,), daemon=True).start()

    def call(self, req, timeout=120):
        self.proc.stdin.write(json.dumps(req, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()
        try:
            return json.loads(self.q.get(timeout=timeout))
        except queue.Empty:
            raise RuntimeError("超时: %s" % req.get("op"))

    def stop(self):
        try:
            self.call({"op": "close"}, timeout=10)
        except Exception:
            pass
        try:
            self.proc.kill()
            self.proc.wait(timeout=10)
        except Exception:
            pass


def dir_size(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total


def pct(sorted_list, p):
    if not sorted_list:
        return 0.0
    idx = min(len(sorted_list) - 1, int(len(sorted_list) * p / 100.0))
    return sorted_list[idx]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cmd", required=True)
    ap.add_argument("--data-dir", default="./data")
    ap.add_argument("--n", type=int, default=200000, help="写入条数")
    ap.add_argument("--batch", type=int, default=1000)
    ap.add_argument("--value-size", type=int, default=100)
    ap.add_argument("--reads", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    data_dir = os.path.abspath(args.data_dir)
    shutil.rmtree(data_dir, ignore_errors=True)
    os.makedirs(data_dir, exist_ok=True)

    cli = Client(shlex.split(args.cmd))
    payload_bytes = 0

    # ---- 1. 顺序写 ----
    print("写入 %d 条（顺序 key）..." % args.n)
    t0 = time.perf_counter()
    for start in range(0, args.n, args.batch):
        items = []
        for i in range(start, min(start + args.batch, args.n)):
            k = "key%010d" % i
            v = k + "|" + ("v" * args.value_size)
            items.append([k, v])
            payload_bytes += len(k) + len(v)
        cli.call({"op": "putmany", "items": items, "sync": False})
    cli.call({"op": "flush"})
    seq_secs = time.perf_counter() - t0
    seq_tp = args.n / seq_secs

    # ---- 2. 随机写 ----
    print("写入 %d 条（随机 key，覆盖写）..." % args.n)
    t0 = time.perf_counter()
    for _ in range(args.n // args.batch):
        items = []
        for _ in range(args.batch):
            i = rng.randrange(args.n)
            k = "key%010d" % i
            v = k + "|" + ("w" * args.value_size)
            items.append([k, v])
            payload_bytes += len(k) + len(v)
        cli.call({"op": "putmany", "items": items, "sync": False})
    cli.call({"op": "flush"})
    rnd_secs = time.perf_counter() - t0
    rnd_tp = args.n / rnd_secs

    # ---- 3. 读延迟 ----
    print("随机读 %d 次..." % args.reads)
    hit_lat = []
    for _ in range(args.reads):
        i = rng.randrange(args.n)
        k = "key%010d" % i
        t = time.perf_counter()
        cli.call({"op": "get", "k": k})
        hit_lat.append((time.perf_counter() - t) * 1000)

    miss_lat = []
    for _ in range(args.reads // 4):
        k = "miss%010d" % rng.randrange(10 ** 9)
        t = time.perf_counter()
        cli.call({"op": "get", "k": k})
        miss_lat.append((time.perf_counter() - t) * 1000)

    hit_lat.sort()
    miss_lat.sort()

    # ---- 4. 范围扫描 ----
    print("范围扫描 100 次...")
    t0 = time.perf_counter()
    rows = 0
    for _ in range(100):
        s = rng.randrange(max(1, args.n - 1000))
        start_k = "key%010d" % s
        end_k = "key%010d" % (s + 500)
        resp = cli.call({"op": "scan", "start": start_k, "end": end_k, "limit": 500})
        rows += len(resp.get("items") or [])
    scan_secs = time.perf_counter() - t0

    # ---- 5. 空间放大 ----
    cli.call({"op": "flush"})
    disk = dir_size(data_dir)
    amp = disk / payload_bytes if payload_bytes else 0

    cli.stop()

    print("\n| 指标 | 数值 |")
    print("|---|---|")
    print("| 顺序写吞吐 | %.0f ops/s (%.2f MB/s) |"
          % (seq_tp, args.n * (args.value_size + 15) / seq_secs / 1e6))
    print("| 随机写吞吐 | %.0f ops/s (%.2f MB/s) |"
          % (rnd_tp, args.n * (args.value_size + 15) / rnd_secs / 1e6))
    print("| 读延迟 P50 (命中) | %.3f ms |" % pct(hit_lat, 50))
    print("| 读延迟 P95 (命中) | %.3f ms |" % pct(hit_lat, 95))
    print("| 读延迟 P99 (命中) | %.3f ms |" % pct(hit_lat, 99))
    print("| 读延迟 P50 (未命中) | %.3f ms |" % pct(miss_lat, 50))
    print("| 范围扫描 | %.0f rows/s |" % (rows / scan_secs if scan_secs else 0))
    print("| 磁盘占用 | %.1f MB |" % (disk / 1e6))
    print("| 空间放大 | %.2fx |" % amp)
    print("\n提示：空间放大 > 2x 说明 compaction 没做干净；")
    print("      P99 远高于 P50 说明某个层级缺少 bloom filter 或索引。")


if __name__ == "__main__":
    main()
