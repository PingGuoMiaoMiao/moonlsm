#!/usr/bin/env python3
"""正确性对拍测试 —— 拿内存 dict 当标准答案，逐条比对。

覆盖的坑（这些是 LSM 最容易写错的地方）：
  - 覆盖写：同一个 key 写多次，读到的必须是最新值
  - 删除：删完要读不到
  - 删除后重写：墓碑必须被正确覆盖，不能"删了以后再也写不进去"
  - 大 value：超过一个 block 大小时，跨块边界不能出错
  - 前缀 key：a / ab / abc 这种，排序和范围扫描容易错
  - 重启持久化：关掉再打开，数据必须还在

用法：
  python model_check.py --cmd "python mock_dbcli.py --path ./data"
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


class Client:
    def __init__(self, cmd):
        self.cmd = cmd
        self.proc = None
        self.q = None

    def start(self):
        self.proc = subprocess.Popen(
            self.cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
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
        return self

    def call(self, req, timeout=15):
        self.proc.stdin.write(json.dumps(req, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()
        try:
            return json.loads(self.q.get(timeout=timeout))
        except queue.Empty:
            raise RuntimeError("响应超时: %s" % req.get("op"))

    def stop(self):
        if not self.proc:
            return
        try:
            self.call({"op": "close"}, timeout=5)
        except Exception:
            pass
        try:
            self.proc.kill()
            self.proc.wait(timeout=10)
        except Exception:
            pass
        self.proc = None


def gen_key(rng, pool):
    return rng.choice(pool)


def gen_value(rng, key, big=False):
    if big:
        return key + "|" + ("B" * rng.choice([4096, 8192, 16384]))
    return key + "|" + ("v" * rng.randint(0, 300))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cmd", required=True)
    ap.add_argument("--ops", type=int, default=5000)
    ap.add_argument("--restart-every", type=int, default=1000)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--data-dir", default="./data")
    args = ap.parse_args()

    seed = args.seed if args.seed is not None else int(time_seed())
    rng = random.Random(seed)

    shutil.rmtree(os.path.abspath(args.data_dir), ignore_errors=True)

    # key 池里刻意放入前缀关系的 key，专门打排序/范围扫描的边界
    pool = ["a", "ab", "abc", "abcd", "b", "ba", "zzz"]
    pool += ["k%05d" % i for i in range(400)]

    cli = Client(shlex.split(args.cmd)).start()
    model = {}
    errors = []
    restarts = 0

    def fail(msg):
        errors.append(msg)
        if len(errors) <= 5:
            print("  FAIL: " + msg)

    for step in range(1, args.ops + 1):
        r = rng.random()
        k = gen_key(rng, pool)

        if r < 0.45:
            v = gen_value(rng, k, big=(rng.random() < 0.01))
            resp = cli.call({"op": "put", "k": k, "v": v})
            if not resp.get("ok"):
                fail("put 失败 key=%s err=%s" % (k, resp.get("err")))
            model[k] = v

        elif r < 0.60:
            resp = cli.call({"op": "del", "k": k})
            if not resp.get("ok"):
                fail("del 失败 key=%s" % k)
            model.pop(k, None)

        elif r < 0.95:
            resp = cli.call({"op": "get", "k": k})
            got = resp.get("v")
            want = model.get(k)
            if got != want:
                fail("get 不一致 key=%s got=%r want=%r"
                     % (k, (got or "")[:30], (want or "")[:30]))

        else:
            start = gen_key(rng, pool)
            end = gen_key(rng, pool)
            if start > end:
                start, end = end, start
            limit = rng.choice([10, 50, 200])
            resp = cli.call({"op": "scan", "start": start, "end": end, "limit": limit})
            got = resp.get("items") or []
            want_keys = sorted(x for x in model if start <= x < end)[:limit]
            want = [[x, model[x]] for x in want_keys]
            if got != want:
                fail("scan 不一致 [%s,%s) got=%d want=%d"
                     % (start, end, len(got), len(want)))

        if args.restart_every and step % args.restart_every == 0:
            cli.stop()
            cli = Client(shlex.split(args.cmd)).start()
            restarts += 1
            # 重启后全量比对（抽样，避免太慢）
            sample = rng.sample(list(model.items()), min(200, len(model))) if model else []
            for kk, vv in sample:
                got = cli.call({"op": "get", "k": kk}).get("v")
                if got != vv:
                    fail("重启后丢失 key=%s" % kk)
            print("  重启 #%d @ step %d，抽样 %d 条校验" % (restarts, step, len(sample)))

    # 收尾全量比对
    all_keys = sorted(model)
    got = cli.call({"op": "scan", "start": "", "end": "\uffff", "limit": 100000}).get("items") or []
    if [x[0] for x in got] != all_keys:
        fail("最终 scan key 集合不一致 got=%d want=%d" % (len(got), len(all_keys)))
    for k in all_keys[:500]:
        if cli.call({"op": "get", "k": k}).get("v") != model[k]:
            fail("最终校验失败 key=%s" % k)
            break

    cli.stop()

    print("\n对拍完成 | seed=%d | %d 步 | 重启 %d 次 | 错误 %d"
          % (seed, args.ops, restarts, len(errors)))
    if errors:
        print("结论: FAIL —— 先修正确性，再谈性能。")
        sys.exit(1)
    print("结论: PASS —— 正确性对拍通过。")


def time_seed():
    import time
    return int(time.time())


if __name__ == "__main__":
    main()
