#!/usr/bin/env python3
"""SQLite 参照基准 —— 给 moonlsm 的数字一个数量级上的锚点。

**这不是竞品对比。** SQLite 是成熟二十多年的 C 实现，带查询优化器和
几十种存储引擎细节；moonlsm 是一个 MoonBit 写的教学级 LSM。拿两者的
绝对数字分高下没有意义。

它存在的理由只有一个：**让「50k ops/s 算快还是算慢」有个参照**。
没有参照的性能数字，读者无法判断它是「不错」还是「慢得离谱」。

工作量必须与 `bench.py` 逐项对齐，否则数字不可比：

| 阶段 | moonlsm | 这里 |
|---|---|---|
| 顺序写 | `putmany` 一批 1000 条 | `executemany` 一个事务 1000 条 |
| 随机写 | 覆盖写同一批 key | 同左 |
| 点查 | `get` | `SELECT v WHERE k = ?` |
| 范围扫描 | `scan` 500 条 | `SELECT ... WHERE k >= ? AND k < ? LIMIT 500` |
| 空间 | 目录字节数 | 数据库文件字节数（含 -wal） |

用法：
  python bench_sqlite.py --n 200000 --batch 1000 --value-size 100
  python bench_sqlite.py --n 2000 --batch 1 --sync     # 对照 --batch 1 的 fsync 代价
"""

import argparse
import os
import random
import shutil
import sqlite3
import time


def pct(sorted_list, p):
    if not sorted_list:
        return 0.0
    idx = min(len(sorted_list) - 1, int(len(sorted_list) * p / 100.0))
    return sorted_list[idx]


def db_size(path):
    total = 0
    for suffix in ("", "-wal", "-shm"):
        try:
            total += os.path.getsize(path + suffix)
        except OSError:
            pass
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", default="./data_sqlite")
    ap.add_argument("--n", type=int, default=200000)
    ap.add_argument("--batch", type=int, default=1000)
    ap.add_argument("--value-size", type=int, default=100)
    ap.add_argument("--reads", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--sync", action="store_true",
                    help="synchronous=FULL（每次提交都 fsync）。默认 NORMAL")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    data_dir = os.path.abspath(args.data_dir)
    shutil.rmtree(data_dir, ignore_errors=True)
    os.makedirs(data_dir, exist_ok=True)
    path = os.path.join(data_dir, "bench.db")

    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode=WAL")
    # FULL = 每次 COMMIT 都 fsync；NORMAL = 只在 checkpoint 时 fsync。
    # 与 moonlsm 的 `sync:true` / `sync:false` 对应。
    conn.execute("PRAGMA synchronous=%s" % ("FULL" if args.sync else "NORMAL"))
    conn.execute("CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT) WITHOUT ROWID")

    payload = 0

    def key_of(i):
        return "key%010d" % i

    def val_of(i, tag):
        return key_of(i) + "|" + tag * args.value_size

    # ---- 1. 顺序写 ----
    t0 = time.perf_counter()
    for start in range(0, args.n, args.batch):
        rows = [(key_of(i), val_of(i, "v"))
                for i in range(start, min(start + args.batch, args.n))]
        conn.executemany("INSERT OR REPLACE INTO kv(k, v) VALUES (?, ?)", rows)
        conn.commit()
        payload += sum(len(k) + len(v) for k, v in rows)
    seq_secs = time.perf_counter() - t0

    # ---- 2. 随机写（覆盖写同一批 key）----
    t0 = time.perf_counter()
    for _ in range(args.n // args.batch):
        rows = []
        for _ in range(args.batch):
            i = rng.randrange(args.n)
            rows.append((key_of(i), val_of(i, "w")))
        conn.executemany("INSERT OR REPLACE INTO kv(k, v) VALUES (?, ?)", rows)
        conn.commit()
        payload += sum(len(k) + len(v) for k, v in rows)
    rnd_secs = time.perf_counter() - t0

    # ---- 3. 读延迟 ----
    hit = []
    for _ in range(args.reads):
        k = key_of(rng.randrange(args.n))
        t = time.perf_counter()
        conn.execute("SELECT v FROM kv WHERE k = ?", (k,)).fetchone()
        hit.append((time.perf_counter() - t) * 1000)
    miss = []
    for _ in range(args.reads // 4):
        k = "miss%010d" % rng.randrange(10 ** 9)
        t = time.perf_counter()
        conn.execute("SELECT v FROM kv WHERE k = ?", (k,)).fetchone()
        miss.append((time.perf_counter() - t) * 1000)
    hit.sort()
    miss.sort()

    # ---- 4. 范围扫描 ----
    t0 = time.perf_counter()
    rows = 0
    for _ in range(100):
        s = rng.randrange(max(1, args.n - 1000))
        cur = conn.execute(
            "SELECT k, v FROM kv WHERE k >= ? AND k < ? ORDER BY k LIMIT 500",
            (key_of(s), key_of(s + 500)),
        )
        rows += len(cur.fetchall())
    scan_secs = time.perf_counter() - t0

    # ---- 5. 空间 ----
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    disk = db_size(path)
    logical = args.n * (len(key_of(0)) * 2 + 1 + args.value_size)
    conn.close()

    print("\nSQLite | sync=%s | n=%d | batch=%d | value_size=%d"
          % (args.sync, args.n, args.batch, args.value_size))
    print("\n| 指标 | 数值 |")
    print("|---|---|")
    print("| 顺序写吞吐 | %.0f ops/s (%.2f MB/s) |"
          % (args.n / seq_secs, args.n * (args.value_size + 15) / seq_secs / 1e6))
    print("| 随机写吞吐 | %.0f ops/s (%.2f MB/s) |"
          % (args.n / rnd_secs, args.n * (args.value_size + 15) / rnd_secs / 1e6))
    print("| 读延迟 P50 (命中) | %.3f ms |" % pct(hit, 50))
    print("| 读延迟 P95 (命中) | %.3f ms |" % pct(hit, 95))
    print("| 读延迟 P99 (命中) | %.3f ms |" % pct(hit, 99))
    print("| 读延迟 P50 (未命中) | %.3f ms |" % pct(miss, 50))
    print("| 范围扫描 | %.0f rows/s |" % (rows / scan_secs if scan_secs else 0))
    print("| 磁盘占用 | %.1f MB |" % (disk / 1e6))
    print("| 逻辑数据量 | %.1f MB |" % (logical / 1e6))
    print("| 空间放大 | %.2fx |" % (disk / logical if logical else 0))


if __name__ == "__main__":
    main()
