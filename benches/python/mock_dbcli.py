#!/usr/bin/env python3
"""Mock DB CLI —— 只用来验证测试脚本本身是否有效，不是交付物。

它实现了一份「正确但极简」的持久化 KV（追加 WAL + 内存 dict），
刻意暴露两个开关，用来证明测试脚本能抓到对应的 bug：

  --no-sync        flush 时不 fsync  -> crash_test 应该报「已确认数据丢失」
  --corrupt-tail N 启动时截掉 WAL 末尾 N 字节 -> 模拟 torn write，
                   正确的实现应该丢弃不完整记录并正常启动

协议：stdin/stdout 每行一个 JSON，见 README.md。
"""

import argparse
import json
import os
import sys


class MockDB:
    def __init__(self, path, do_sync=True, corrupt_tail=0):
        self.path = path
        self.do_sync = do_sync
        self.data = {}
        self.seq = 0
        os.makedirs(path, exist_ok=True)
        self.wal = os.path.join(path, "wal.jsonl")

        if corrupt_tail > 0 and os.path.exists(self.wal):
            size = os.path.getsize(self.wal)
            cut = min(corrupt_tail, size)
            with open(self.wal, "r+b") as f:
                f.truncate(size - cut)

        self._replay()
        # 正确实现用行缓冲（每次 write 即落盘）；
        # --no-sync 故意用 1MB 大缓冲，让数据滞留进程内，kill 后必丢
        buf = 1 if do_sync else 1024 * 1024
        self.f = open(self.wal, "a", encoding="utf-8", buffering=buf)

    def _replay(self):
        if not os.path.exists(self.wal):
            return
        with open(self.wal, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    # WAL 末尾被截断 -> 丢弃这条不完整记录，继续启动
                    continue
                self.seq = max(self.seq, rec.get("seq", 0))
                if rec["op"] == "put":
                    self.data[rec["k"]] = rec["v"]
                elif rec["op"] == "del":
                    self.data.pop(rec["k"], None)

    def _append(self, rec):
        self.f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        # do_sync=False 时连 flush 都不做，数据留在进程缓冲里，
        # 被 kill -9 就会丢 —— 用来验证 crash_test 能抓到这种 bug
        if self.do_sync:
            self.f.flush()
            os.fsync(self.f.fileno())

    def put(self, k, v):
        self.seq += 1
        self._append({"op": "put", "k": k, "v": v, "seq": self.seq})
        self.data[k] = v
        return self.seq

    def delete(self, k):
        self.seq += 1
        self._append({"op": "del", "k": k, "seq": self.seq})
        self.data.pop(k, None)
        return self.seq

    def get(self, k):
        return self.data.get(k)

    def scan(self, start, end, limit=100):
        keys = sorted(x for x in self.data if start <= x < end)
        return [[k, self.data[k]] for k in keys[:limit]]

    def putmany(self, items):
        for k, v in items:
            self.seq += 1
            self._append({"op": "put", "k": k, "v": v, "seq": self.seq})
            self.data[k] = v
        return self.seq

    def flush(self):
        if self.do_sync:
            self.f.flush()
            os.fsync(self.f.fileno())
        return True

    def close(self):
        try:
            if self.do_sync:
                self.f.flush()
                os.fsync(self.f.fileno())
            self.f.close()
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--path", required=True)
    ap.add_argument("--no-sync", action="store_true")
    ap.add_argument("--corrupt-tail", type=int, default=0)
    args = ap.parse_args()

    db = MockDB(args.path, do_sync=not args.no_sync, corrupt_tail=args.corrupt_tail)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            print(json.dumps({"ok": False, "err": "bad json"}), flush=True)
            continue

        op = req.get("op")
        try:
            if op == "put":
                print(json.dumps({"ok": True, "seq": db.put(req["k"], req["v"])}), flush=True)
            elif op == "get":
                print(json.dumps({"ok": True, "v": db.get(req["k"])}), flush=True)
            elif op == "del":
                print(json.dumps({"ok": True, "seq": db.delete(req["k"])}), flush=True)
            elif op == "putmany":
                items = [(x[0], x[1]) for x in req["items"]]
                seq = db.putmany(items)
                if req.get("sync"):
                    db.flush()
                print(json.dumps({"ok": True, "seq": seq}), flush=True)
            elif op == "scan":
                items = db.scan(req["start"], req["end"], req.get("limit", 100))
                print(json.dumps({"ok": True, "items": items}), flush=True)
            elif op == "flush":
                db.flush()
                print(json.dumps({"ok": True}), flush=True)
            elif op == "stats":
                print(json.dumps({
                    "ok": True,
                    "live_keys": len(db.data),
                    "wal_bytes": os.path.getsize(db.wal) if os.path.exists(db.wal) else 0,
                }), flush=True)
            elif op == "close":
                db.close()
                print(json.dumps({"ok": True}), flush=True)
                return
            else:
                print(json.dumps({"ok": False, "err": "unknown op"}), flush=True)
        except Exception as e:
            print(json.dumps({"ok": False, "err": str(e)}), flush=True)


if __name__ == "__main__":
    main()
