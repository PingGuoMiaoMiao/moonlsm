#!/usr/bin/env python3
"""持久化能力探测 —— 给 CI 用的「是否该跑崩溃测试」开关。

背景：
  M0/M1 阶段 dbcli 还是内存 Map 占位，重启必然丢数据。
  这时跑 crash_test.py 只会得到一片 FAIL，把真正的失败淹掉。
  与其让 CI 红着、大家习惯性忽略，不如显式探测：

      exit 0  -> 已支持持久化，可以跑 crash_test.py
      exit 1  -> 尚未支持持久化，跳过崩溃测试（不是错误）
      exit 2  -> 命令本身起不来，这是真错误

用法：
  python probe_persistence.py --cmd "../../_build/native/debug/build/cmd/dbcli/dbcli.exe --path ./data"

在 CI 里的用法：
  if python probe_persistence.py --cmd "$CMD"; then
    python crash_test.py --cmd "$CMD" --rounds 5
  else
    echo "::notice::引擎尚未支持持久化，跳过崩溃测试"
  fi
"""

import argparse
import json
import os
import queue
import shlex
import shutil
import subprocess
import sys
import threading


PROBE_KEY = "probe:persistence"
PROBE_VALUE = "hello-after-restart"


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
    try:
        proc.stdin.write(json.dumps(req, ensure_ascii=False) + "\n")
        proc.stdin.flush()
    except Exception as e:
        return {"ok": False, "err": "write failed: %s" % e}
    try:
        line = q.get(timeout=timeout)
    except queue.Empty:
        return {"ok": False, "err": "timeout"}
    try:
        return json.loads(line)
    except json.JSONDecodeError:
        return {"ok": False, "err": "bad response: " + line[:80]}


def stop_proc(proc):
    try:
        if proc.stdin:
            proc.stdin.close()
    except Exception:
        pass
    try:
        proc.wait(timeout=10)
    except Exception:
        try:
            proc.kill()
            proc.wait(timeout=5)
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cmd", required=True, help="启动 dbcli 的命令（用引号包起来）")
    ap.add_argument("--data-dir", default="./probe-data")
    args = ap.parse_args()

    cmd = shlex.split(args.cmd)
    data_dir = os.path.abspath(args.data_dir)

    # 每次探测都从干净目录开始，避免上一次的残留造成假阳性
    shutil.rmtree(data_dir, ignore_errors=True)
    os.makedirs(data_dir, exist_ok=True)

    # ---- 第一次启动：写入一条并确认 ----
    try:
        proc, q = start_proc(cmd)
    except Exception as e:
        print("FAIL: 无法启动 dbcli: %s" % e)
        return 2

    resp = send(proc, q, {"op": "put", "k": PROBE_KEY, "v": PROBE_VALUE, "sync": True})
    if not resp.get("ok"):
        print("FAIL: 写入被拒绝: %s" % resp.get("err"))
        stop_proc(proc)
        return 2

    send(proc, q, {"op": "flush"})
    send(proc, q, {"op": "close"})
    stop_proc(proc)

    # ---- 第二次启动：看数据还在不在 ----
    try:
        proc2, q2 = start_proc(cmd)
    except Exception as e:
        print("FAIL: 重启失败: %s" % e)
        return 2

    resp = send(proc2, q2, {"op": "get", "k": PROBE_KEY})
    got = resp.get("v")
    send(proc2, q2, {"op": "close"})
    stop_proc(proc2)

    if got == PROBE_VALUE:
        print("OK: 重启后数据仍在 —— 引擎已支持持久化。")
        return 0

    if got is None:
        print("SKIP: 重启后数据丢失 —— 引擎尚未支持持久化（当前为内存占位实现）。")
    else:
        print("WARN: 重启后数据被改变 —— 期望 %r，实际 %r。"
              % (PROBE_VALUE, got[:40]))
        print("      这可能是编码问题，不一定是没持久化。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
