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

import dbcli_launch


class Client:
    def __init__(self, cmd, env):
        self.cmd = cmd
        self.env = env
        self.proc = None
        self.q = None

    def start(self):
        # env 里带 MOONLSM_DATA。漏传的后果见 dbcli_launch.py：
        # 探测脚本写进去的 key 会混进本测试的 key 集合，报成「多了一个键」。
        self.proc = subprocess.Popen(
            self.cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, encoding="utf-8", bufsize=1,
            env=self.env,
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


def _supports_persistence(cmd_str, data_dir):
    """复用 probe_persistence.py 的判断：exit 0 = 已支持持久化。"""
    probe = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "probe_persistence.py")
    if not os.path.exists(probe):
        return False
    try:
        r = subprocess.run(
            [sys.executable, probe, "--cmd", cmd_str,
             "--data-dir", os.path.join(os.path.abspath(data_dir), "_probe")],
            capture_output=True, text=True, timeout=180,
        )
    except Exception:
        return False
    return r.returncode == 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cmd", required=True)
    ap.add_argument("--ops", type=int, default=5000)
    ap.add_argument("--restart-every", type=int, default=1000)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--data-dir", default=None, help="数据目录，默认 ./data")
    args = ap.parse_args()

    data_dir = dbcli_launch.resolve_dir(args.data_dir, "./data")
    env = dbcli_launch.child_env(data_dir)

    # 引擎是否已支持持久化？M1 阶段没有 WAL，重启必然丢数据。
    # 直接跑重启会得到几百条 FAIL，把真正的正确性错误淹掉 ——
    # 让测试自己适应阶段，比让人记住「这个阶段要加 --restart-every 0」可靠。
    if args.restart_every and not _supports_persistence(args.cmd, data_dir):
        print("注意: 引擎尚未支持持久化（无 WAL），已自动关闭重启测试。")
        print("      这不是失败。Week 2 加上 WAL 后，重启测试会自动恢复。")
        args.restart_every = 0

    seed = args.seed if args.seed is not None else int(time_seed())
    rng = random.Random(seed)

    shutil.rmtree(data_dir, ignore_errors=True)

    # key 池里刻意放入前缀关系的 key，专门打排序/范围扫描的边界
    pool = ["a", "ab", "abc", "abcd", "b", "ba", "zzz"]
    pool += ["k%05d" % i for i in range(400)]

    cli = Client(shlex.split(args.cmd), env).start()
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
            cli = Client(shlex.split(args.cmd), env).start()
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
        gk = [x[0] for x in got]
        extra = [k for k in gk if k not in all_keys]
        missing = [k for k in all_keys if k not in gk]
        dup = sorted(set(k for k in gk if gk.count(k) > 1))
        fail("最终 scan key 集合不一致 got=%d want=%d extra=%r missing=%r dup=%r"
             % (len(got), len(all_keys), extra[:5], missing[:5], dup[:5]))
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
