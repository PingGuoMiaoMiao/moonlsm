#!/usr/bin/env python3
"""崩溃一致性测试（kill -9）—— 这个脚本就是比赛 demo 的核心镜头。

它验证的是 WAL 的 durability 契约：
  1. 已经返回 ok（已 fsync）的写入，重启后必须 100% 能读到，且值完全正确；
  2. 还没返回 ok 的写入，允许丢失；
  3. 但「丢失」只能是整条不见，绝不能读出半个值（torn write）。

用法：
  python crash_test.py --cmd "python mock_dbcli.py --path ./data"
  python crash_test.py --cmd "python mock_dbcli.py --path ./data --no-sync"   # 应该 FAIL

把 --cmd 换成你自己的 MoonBit 实现即可（在 benches/python 目录下运行）：
  python crash_test.py --cmd "../../_build/native/release/build/cmd/dbcli/dbcli.exe --path ./data"
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


def start_proc(cmd):
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        bufsize=1,
    )
    q = queue.Queue()

    def _reader(stream):
        try:
            for line in stream:
                q.put(line)
        except Exception:
            pass

    threading.Thread(target=_reader, args=(proc.stdout,), daemon=True).start()
    return proc, q


def send(proc, q, req, timeout=10.0):
    proc.stdin.write(json.dumps(req, ensure_ascii=False) + "\n")
    proc.stdin.flush()
    try:
        line = q.get(timeout=timeout)
    except queue.Empty:
        return {"ok": False, "err": "timeout"}
    try:
        return json.loads(line)
    except json.JSONDecodeError:
        return {"ok": False, "err": "bad response: " + line[:80]}


def send_noblock(proc, req):
    try:
        proc.stdin.write(json.dumps(req, ensure_ascii=False) + "\n")
        proc.stdin.flush()
    except Exception:
        pass


def hard_kill(proc):
    """Windows 上是 TerminateProcess，等价于 kill -9，不给进程任何清理机会。"""
    try:
        proc.kill()
    except Exception:
        pass
    try:
        proc.wait(timeout=10)
    except Exception:
        pass


def make_batch(rng, key_space, value_size, batch):
    items = []
    for _ in range(batch):
        k = "k%08d" % rng.randrange(key_space)
        v = k + "|" + ("v" * value_size)
        items.append([k, v])
    return items


def run_round(args, rng, round_no):
    data_dir = os.path.abspath(args.data_dir)
    shutil.rmtree(data_dir, ignore_errors=True)
    os.makedirs(data_dir, exist_ok=True)

    cmd = shlex.split(args.cmd)
    proc, q = start_proc(cmd)

    acked = {}
    pending = {}
    seconds = rng.uniform(args.min_seconds, args.max_seconds)
    deadline = time.time() + seconds
    writes = 0

    while time.time() < deadline:
        batch = make_batch(rng, args.key_space, args.value_size, args.batch)
        resp = send(proc, q, {"op": "putmany", "items": batch, "sync": True})
        if not resp.get("ok"):
            print("  ! 写入失败: %s" % resp.get("err"))
            break
        for k, v in batch:
            acked[k] = v
        writes += len(batch)

    # 故意发一批不等响应就杀，制造 in-flight 写入（考验 torn write 处理）
    batch = make_batch(rng, args.key_space, args.value_size, args.batch)
    send_noblock(proc, {"op": "putmany", "items": batch, "sync": True})
    pending = {k: v for k, v in batch}
    time.sleep(0.01)
    hard_kill(proc)

    # ---- 重启验证 ----
    proc2, q2 = start_proc(cmd)
    lost = []
    torn = []
    for k, v in acked.items():
        resp = send(proc2, q2, {"op": "get", "k": k})
        got = resp.get("v")
        if got != v:
            lost.append((k, got, v))
            if len(lost) >= 10:
                break

    for k, v in pending.items():
        resp = send(proc2, q2, {"op": "get", "k": k})
        got = resp.get("v")
        if got is not None and got != v:
            torn.append((k, got, v))
            if len(torn) >= 10:
                break

    send(proc2, q2, {"op": "close"})
    hard_kill(proc2)

    ok = not lost and not torn
    print("Round %d: %.1fs, 写入 %d 条, acked %d, 丢失 %d, 半条 %d  -> %s"
          % (round_no, seconds, writes, len(acked), len(lost), len(torn),
             "PASS" if ok else "FAIL"))

    if lost:
        print("  ! 已确认的写入丢失（WAL 没 fsync，或恢复逻辑漏了）:")
        for k, got, want in lost[:3]:
            print("    key=%s got=%r want=%r" % (k, (got or "")[:20], want[:20]))
    if torn:
        print("  ! 读出了不完整的值（torn write 没被截断处理）:")
        for k, got, want in torn[:3]:
            print("    key=%s got_len=%d want_len=%d" % (k, len(got or ""), len(want)))

    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cmd", required=True, help="启动 dbcli 的命令（用引号包起来）")
    ap.add_argument("--data-dir", default="./data")
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--batch", type=int, default=200)
    ap.add_argument("--key-space", type=int, default=20000)
    ap.add_argument("--value-size", type=int, default=200)
    ap.add_argument("--min-seconds", type=float, default=2.0)
    ap.add_argument("--max-seconds", type=float, default=5.0)
    ap.add_argument("--seed", type=int, default=None)
    args = ap.parse_args()

    seed = args.seed if args.seed is not None else int(time.time())
    rng = random.Random(seed)
    print("崩溃一致性测试 | seed=%d | %d 轮 | 每轮 %.1f-%.1fs\n"
          % (seed, args.rounds, args.min_seconds, args.max_seconds))

    results = []
    for i in range(1, args.rounds + 1):
        try:
            results.append(run_round(args, rng, i))
        except KeyboardInterrupt:
            print("\n中断")
            sys.exit(130)

    passed = sum(1 for r in results if r)
    print("\n汇总: %d/%d 轮通过" % (passed, len(results)))
    if passed != len(results):
        print("结论: FAIL —— 崩溃恢复不满足 durability 契约，不能拿去比赛。")
        sys.exit(1)
    print("结论: PASS —— 可以录 demo 了。")


if __name__ == "__main__":
    main()
