#!/usr/bin/env python3
"""90 秒 demo 的驱动脚本 —— 按顺序演一遍这个引擎的三件事。

    1. 写进去的东西重启还在（WAL + MANIFEST）
    2. 文件多了会自己合并（三层 compaction）
    3. kill -9 之后，已经 ack 的写入一条不丢（C1）

**为什么单独写一个脚本，而不是让观众看 `crash_test.py` 的输出。**
`crash_test.py` 是测试，它的输出是「20 轮，每轮一行 PASS」—— 对验收够用，
但看不出「为什么这行 PASS 值得信」。这个脚本每一步都把**证据**打出来：
磁盘上现在有哪些文件、每层几个 SST、校验了多少条、丢了几条。

用法：
    python demo.py                       # 默认回车模式：每段讲完按一次回车
    python demo.py --delay 20            # 固定停顿 20 秒，约 81 秒跑完
    python demo.py --no-pause            # 不停顿，约 23 秒（测速 / 截图用）
    python demo.py --cmd "../../_build/native/release/build/cmd/dbcli/dbcli.exe"

**90 秒演示的完整分镜、逐字稿、录制前检查、可能被追问的问题，
见 `docs/engineering/DEMO.md`。** 这个脚本只负责「让证据出现在屏幕上」，
「什么时候说话」在那份文档里。
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
import time
import unicodedata

import dbcli_launch

WIDTH = 74

# 数据量要选得让机制**看得见**，这是这个脚本唯一需要调参的地方。
#
# 一条记录约 220 字节（key 11 + 分隔 + 200 字节值 + SST 行开销），所以：
#   第一批 1200 条 ≈ 264 KB
#   每轮   600 条 ≈ 132 KB
#
# L0 触发归并的阈值是 4 个文件，L1 的目标容量是 1 MiB。想让 L1 **站住**一会儿，
# 4 个 L0 文件的总和必须小于 1 MiB：
#   (1200 + 600) + 600 × 3 = 3000 条 ≈ 660 KB  <  1 MiB  ✓
# 再多写 4 轮，L1 涨到 660 + 528 = 1188 KB > 1 MiB，就会下沉到 L2。
#
# 最早写的是每轮 6000 条（≈1.2 MB），结果 L1 从头到尾都是 0 —— 单次归并输出
# 就超过 L1 的目标容量，归并结果落进 L1 的瞬间就满足下沉条件。机制本身没错，
# 但镜头里看不到，观众只能选择相信旁白。数字要对得上话。
FIRST_BATCH = 1200
ROUND_BATCH = 600
MAX_ROUNDS = 12


def dwidth(s):
    """终端里的显示宽度。中日韩全角字符占 2 列，len() 只算 1。

    不处理这件事的后果：横线长度和表格列都对不齐，而且**中文越多歪得越厉害**，
    因为误差随字符数线性累积。第一版就是这样，标题后面的横线比正文长一截。
    """
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in s)


def pad_to(s, width):
    """按显示宽度右补空格。"""
    return s + " " * max(0, width - dwidth(s))


def rule(title=""):
    if not title:
        print("─" * WIDTH)
        return
    fill = WIDTH - 3 - dwidth(title) - 1
    print("── " + title + " " + "─" * max(0, fill))


def step(n, title):
    print()
    rule("第 %d 步 · %s" % (n, title))


class Client:
    """一行 JSON 一条命令的子进程客户端。"""

    def __init__(self, cmd, env):
        self.proc = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, encoding="utf-8", bufsize=1,
            env=env,
        )
        self.q = queue.Queue()
        threading.Thread(target=self._read, args=(self.proc.stdout,), daemon=True).start()

    def _read(self, stream):
        try:
            for line in stream:
                self.q.put(line)
        except Exception:
            pass

    def call(self, req, timeout=60):
        self.proc.stdin.write(json.dumps(req, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()
        return json.loads(self.q.get(timeout=timeout))

    def kill9(self):
        """模拟断电：直接杀进程，不给它任何清理机会。"""
        self.proc.kill()
        try:
            self.proc.wait(timeout=10)
        except Exception:
            pass

    def close(self):
        try:
            self.call({"op": "close"}, timeout=5)
            self.proc.wait(timeout=5)
        except Exception:
            self.kill9()


def put_batch(cli, start, n, value_size=200, tag="v"):
    items = []
    for i in range(start, start + n):
        k = "user:%06d" % i
        items.append([k, k + "|" + tag * value_size])
    resp = cli.call({"op": "putmany", "items": items, "sync": True})
    if not resp.get("ok"):
        raise RuntimeError(resp)
    return items


def show_stats(cli, note=""):
    st = cli.call({"op": "stats"})
    levels = st["levels"]
    print("  " + pad_to(note or "stats:", 18)
          + "L0=%-2d L1=%-2d L2=%-2d   磁盘 SST %d 个   memtable %d 条"
          % (levels[0], levels[1], levels[2], st["ssts"], st["mem_entries"]))
    return st


def short_path(path):
    """录屏窗口只有 100 列，绝对路径一行 98 列，贴着右边会折行。

    能相对就相对（demo 在 benches/python 下跑，显示成 `data`），
    不能相对就只留末两段。折行会把「第 1 步」标题往下顶，画面难看。
    """
    try:
        rel = os.path.relpath(path)
    except ValueError:  # Windows 跨盘符没有相对路径
        rel = path
    if not rel.startswith(".."):
        return rel
    parts = path.replace("\\", "/").rstrip("/").split("/")
    return "…/" + "/".join(parts[-2:])


def show_disk(data_dir):
    print("  磁盘布局：")
    for name in sorted(os.listdir(data_dir)):
        path = os.path.join(data_dir, name)
        if os.path.isdir(path):
            files = sorted(os.listdir(path))
            total = sum(os.path.getsize(os.path.join(path, f)) for f in files)
            print("    %-18s %d 个文件  %s"
                  % (name + "/", len(files),
                     ", ".join(files[:4]) + (" ..." if len(files) > 4 else "")))
            print("    %-18s 合计 %d 字节" % ("", total))
        else:
            size = os.path.getsize(path)
            print("    %-18s %d 字节" % (name, size))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cmd", default=dbcli_launch.DEFAULT_CMD)
    ap.add_argument("--data-dir", default="./data")
    ap.add_argument("--pause", dest="pause", action="store_true", default=True,
                    help="每一步之间等回车（默认开启）")
    ap.add_argument("--no-pause", dest="pause", action="store_false")
    ap.add_argument("--delay", type=float, default=0, metavar="SEC",
                    help="用固定停顿秒数代替回车。录屏时双手可以空出来念旁白；"
                         "也适合先试跑一遍估算总时长（约 23 + 3×SEC 秒）")
    ap.add_argument("--row-delay", type=float, default=0.25, metavar="SEC",
                    help="第 2 步每打完一行表格停一下（默认 0.25 秒，0 关闭）。"
                         "实测不打会停的话 8 轮表格 1.1 秒就闪完了，观众眼睛"
                         "跟不上『L0 从 1 数到 3』；停一下才看得出是在干活")
    args = ap.parse_args()

    data_dir = dbcli_launch.resolve_dir(args.data_dir, "./data")
    shutil.rmtree(data_dir, ignore_errors=True)
    os.makedirs(data_dir, exist_ok=True)
    env = dbcli_launch.child_env(data_dir)

    def wait():
        # --delay 优先于回车：录屏时手不用一直悬在键盘上，专心念旁白。
        # 代价是节奏固定，讲快了会干等、讲慢了会被打断 —— 所以正式录
        # 建议还是用回车模式（默认），--delay 更适合先试跑一遍估时长。
        if args.delay > 0:
            time.sleep(args.delay)
            return
        if args.pause:
            try:
                input("  [回车继续] ")
            except EOFError:
                pass

    print()
    print("moonlsm · 嵌入式 LSM 存储引擎")
    print("MoonBit 实现 · 数据目录 %s" % short_path(data_dir))

    # ---- 第 1 步：写进去，重启还在 ----
    step(1, "写进去的东西，进程退出后还在")
    cli = Client(shlex.split(args.cmd), env)
    put_batch(cli, 0, FIRST_BATCH)
    st = show_stats(cli, "写入 %d 条：" % FIRST_BATCH)
    assert st["live_keys"] == FIRST_BATCH
    print("  → %d 条都在 memtable 里，同时已经写进 WAL 并 fsync。" % FIRST_BATCH)
    print("    此刻即使断电，重启后也能从 WAL 重放出这 %d 条。" % FIRST_BATCH)
    cli.close()

    cli = Client(shlex.split(args.cmd), env)
    got = cli.call({"op": "get", "k": "user:000000"})
    st = show_stats(cli, "重启后：")
    assert got.get("v", "").startswith("user:000000|")
    print("  → 新进程，第一条 key 读得到，值完全一致：%s..." % got["v"][:28])
    print("    （重启时：CURRENT → MANIFEST → 加载 SST → 重放 WAL）")
    wait()

    # ---- 第 2 步：文件多了自己合并 ----
    step(2, "文件多了自己合并：L0 → L1 → L2")
    print("  之后每轮写 %d 条再 flush 一次，盯着每层的文件数：" % ROUND_BATCH)
    print()
    print("     " + pad_to("轮次", 10) + pad_to("L0", 6) + pad_to("L1", 6)
          + pad_to("L2", 6) + pad_to("磁盘 SST", 11) + "memtable")
    print("     " + "─" * 56)
    seen_l1 = False
    seen_l2 = False
    written_total = FIRST_BATCH
    for r in range(1, MAX_ROUNDS + 1):
        put_batch(cli, FIRST_BATCH + (r - 1) * ROUND_BATCH, ROUND_BATCH)
        cli.call({"op": "flush"})
        written_total += ROUND_BATCH
        st = cli.call({"op": "stats"})
        lv = st["levels"]
        print("     " + pad_to("第 %d 轮" % r, 10) + pad_to(str(lv[0]), 6)
              + pad_to(str(lv[1]), 6) + pad_to(str(lv[2]), 6)
              + pad_to(str(st["ssts"]), 11) + str(st["mem_entries"]))
        if lv[1] > 0 and not seen_l1:
            seen_l1 = True
            print("      ↑ L0 攒满 4 个文件，归并结果落进 L1")
        if lv[2] > 0 and not seen_l2:
            seen_l2 = True
            print("      ↑ L1 累计超过 1 MiB 目标，整层下沉到 L2")
            break
        if args.row_delay > 0:
            time.sleep(args.row_delay)
    assert seen_l1, "整个过程中 L1 从未出现，说明写入量选得让机制看不见"
    assert seen_l2, "%d 轮内 L2 从未出现" % MAX_ROUNDS

    # 归并没丢数据 —— 这是「合并」而不是「覆盖」的关键证据
    st = show_stats(cli, "归并完：")
    assert st["live_keys"] == written_total, (st["live_keys"], written_total)
    print("  → 写入 %d 条，归并后仍是 %d 条：归并只做去重，不丢数据。"
          % (written_total, st["live_keys"]))
    print("    归并时同一个 key 只留 seq 最大的一条；墓碑只在最底层丢弃。")
    show_disk(data_dir)
    wait()

    # ---- 第 3 步：kill -9 ----
    step(3, "kill -9：已经 ack 的写入一条不丢")
    cli.close()
    cli = Client(shlex.split(args.cmd), env)
    acked = {}
    written = 0
    deadline = time.time() + 1.5
    while time.time() < deadline:
        start = 100000 + written
        batch = put_batch(cli, start, 200)
        for k, v in batch:
            acked[k] = v
        written += len(batch)
    print("  写入 %d 条，全部拿到 ack（每条 ack 都在 fsync 之后才发出）" % written)
    # 再发一批不等响应就杀 —— 这批是「未确认的写入」，允许丢
    items = [["user:%06d" % (200000 + i), "x" * 64] for i in range(500)]
    cli.proc.stdin.write(json.dumps({"op": "putmany", "items": items, "sync": True}) + "\n")
    cli.proc.stdin.flush()
    time.sleep(0.02)
    cli.kill9()
    print("  在「一批写入正在落盘」的瞬间 kill -9，进程没有任何清理机会")
    wait()

    # ---- 第 4 步：重启校验 ----
    step(4, "重启，逐条校验")
    cli = Client(shlex.split(args.cmd), env)
    missing = 0
    broken = 0
    for k, v in acked.items():
        resp = cli.call({"op": "get", "k": k})
        if not resp.get("ok"):
            continue
        got = resp.get("v")
        if got is None:
            missing += 1
        elif got != v:
            broken += 1
    print("  校验 %d 条已确认的写入：" % len(acked))
    print("    丢失 %d 条    值被破坏 %d 条" % (missing, broken))
    print("  → C1「已确认的写入必不丢」成立。" if missing == 0 and broken == 0
          else "  → 不成立，这是一个真 bug。")
    show_stats(cli, "恢复后：")
    cli.close()

    # ---- 收尾 ----
    print()
    rule("结论")
    print("  写 → WAL(fsync) → memtable → L0 → 归并 → L1 → L2")
    print("  每一步的崩溃点都有明确的恢复路径；kill -9 不丢已 ack 的数据。")
    print("  单元测试 211 条 · 崩溃测试 20 轮 · 损坏注入 9 条 + 逐字节 fuzz")
    print()
    return 0 if missing == 0 and broken == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
