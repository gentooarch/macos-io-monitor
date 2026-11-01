#!/usr/bin/env python3
"""Aggregate fs_usage write activity by directory.

Maps fd-based write syscalls back to paths using the log's own open/close
records, then reports byte volume and event frequency per directory.
Unmapped writes (fd opened before capture started) are reported separately.

Usage: analyze-writes.py FS_USAGE_LOG [--depth N] [--top N]
"""
import argparse, collections, gzip, os, re, sys

SPLIT = re.compile(r"\s{2,}")
FD_RE = re.compile(r"\bF=(\d+)")
BYTES_RE = re.compile(r"\bB=0x([0-9a-fA-F]+)")
OPEN_OPS = ("open", "open_dprotected", "open_extended", "openat", "openbyid_np")
WRITE_OPS = ("write", "pwrite", "writev", "guarded_pwrite_np")
FLUSH_OPS = ("WrData", "PgOut")
META_OPS = ("mkdir", "mkdirat", "unlink", "unlinkat", "rename", "renameat", "rmdir")
HOME = os.path.expanduser("~")


def human(n):
    n = float(n)
    for unit in ("B", "K", "M", "G", "T"):
        if n < 1024 or unit == "T":
            return f"{n:.0f}B" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024


def fields(line):
    return SPLIT.split(line.strip())


def is_path(x):
    return x.startswith("/") and not x.startswith("/dev/")


def collapse(path):
    return "~" + path[len(HOME):] if HOME and path.startswith(HOME + "/") else path


def open_target(f, seen_paths):
    for x in f:
        if is_path(x):
            return x
    for x in f:
        if "/" in x and not x.startswith(("(", "D=", "B=")):
            cands = [p for p in seen_paths if p.endswith(x)]
            return max(cands, key=len) if cands else "<truncated>:" + x
    return None


def ts_seconds(ts):
    h, m, s = ts.split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--depth", type=int, default=6)
    ap.add_argument("--top", type=int, default=12)
    args = ap.parse_args()

    opener = gzip.open if args.log.endswith(".gz") else open
    with opener(args.log, "rt", errors="replace") as fh:
        lines = fh.read().splitlines()

    seen_paths = {x for line in lines for x in fields(line) if is_path(x)}
    fd_path, calls, files, flush, flush_files = {}, (collections.defaultdict(lambda: [0, 0])), \
        collections.defaultdict(lambda: [0, 0]), collections.defaultdict(lambda: [0, 0]), \
        collections.defaultdict(lambda: [0, 0])
    meta = collections.defaultdict(collections.Counter)
    orphan = collections.defaultdict(lambda: [0, 0])
    file_span, dir_rate = {}, collections.defaultdict(list)

    for line in lines:
        f = fields(line)
        if len(f) < 3 or not f[0][:2].isdigit() or ":" not in f[0]:
            continue
        op, proc = f[1].split()[0] if f[1] else "", f[-1]
        m = BYTES_RE.search(line)
        nbytes = int(m.group(1), 16) if m else None

        if op in OPEN_OPS:
            fd = FD_RE.search(f[2]) if len(f) > 2 else None
            if fd and len(f) > 3:
                fd_path[(proc, fd.group(1))] = open_target(f[3:], seen_paths) or "<unknown>"
            continue
        if op == "close":
            fd = FD_RE.search(f[2]) if len(f) > 2 else None
            if fd:
                fd_path.pop((proc, fd.group(1)), None)
            continue
        if op in META_OPS:
            path = next((x for x in f if is_path(x)), None)
            if path:
                meta[proc.rsplit(".", 1)[0]][os.path.dirname(collapse(path))] += 1
            continue

        if op in WRITE_OPS and nbytes is not None:
            fd = FD_RE.search(" ".join(f[1:3]))
            path = fd_path.get((proc, fd.group(1))) if fd else None
            if not path or path.startswith(("<unknown>", "<truncated>")):
                if path and path.startswith("<truncated>"):
                    orphan["(path truncated by fs_usage) " + path[12:60]][0] += nbytes
                    orphan["(path truncated by fs_usage) " + path[12:60]][1] += 1
                else:
                    orphan[f"{proc.rsplit('.', 1)[0]} fd={fd.group(1) if fd else 'pre-open'}"][0] += nbytes
                    orphan[f"{proc.rsplit('.', 1)[0]} fd={fd.group(1) if fd else 'pre-open'}"][1] += 1
                continue
            d = "/".join(collapse(path).split("/")[: args.depth + 1])
            calls[d][0] += nbytes
            calls[d][1] += 1
            files[collapse(path)][0] += nbytes
            files[collapse(path)][1] += 1
            t = ts_seconds(f[0])
            lo, hi = file_span.get(path, (t, t))
            file_span[path] = (min(lo, t), max(hi, t))
            dir_rate[d].append(t)

        elif op.startswith(FLUSH_OPS) and nbytes is not None:
            path = next((x for x in f if is_path(x)), None)
            if not path:
                continue
            d = "/".join(collapse(path).split("/")[: args.depth + 1])
            flush[d][0] += nbytes
            flush[d][1] += 1
            flush_files[collapse(path)][0] += nbytes
            flush_files[collapse(path)][1] += 1

    span = (min(file_span.values())[0], max(v[1] for v in file_span.values())) if file_span else (0, 0)
    dur = max(span[1] - span[0], 1)

    def table(title, tbl):
        rows = sorted(tbl.items(), key=lambda kv: kv[1][0], reverse=True)
        tb = sum(v[0] for v in tbl.values())
        tc = sum(v[1] for v in tbl.values())
        print(f"\n{title}\n  total {human(tb)} / {tc} events")
        print(f"  {'bytes':>8} {'share':>6} {'events':>7} {'ev/min':>7}  directory")
        for k, (b, c) in rows[: args.top]:
            print(f"  {human(b):>8} {b / tb * 100 if tb else 0:5.1f}% {c:7d} {c / dur * 60:7.1f}  {k}")

    table(f"write syscalls by directory (depth {args.depth})", calls)
    table("physical writes (WrData) by directory", flush)

    print(f"\ntop files by syscall bytes (window {dur:.0f}s)")
    print(f"  {'bytes':>8} {'events':>7} {'ev/min':>7} {'KB/s':>6}  file")
    for k, (b, c) in sorted(files.items(), key=lambda kv: kv[1][0], reverse=True)[: args.top]:
        print(f"  {human(b):>8} {c:7d} {c / dur * 60:7.1f} {b / dur / 1024:6.1f}  {k}")

    print("\ntop files by physical bytes")
    for k, (b, c) in sorted(flush_files.items(), key=lambda kv: kv[1][0], reverse=True)[: args.top]:
        print(f"  {human(b):>8} {c:7d} {c / dur * 60:7.1f} {b / dur / 1024:6.1f}  {k}")

    tb = sum(v[0] for v in orphan.values())
    tc = sum(v[1] for v in orphan.values())
    print(f"\nunattributed write syscalls (fd opened before capture): {tc} events, "
          f"{human(tb)} ({tb / dur / 1024:.1f} KB/s)")
    for k, (b, c) in sorted(orphan.items(), key=lambda kv: kv[1][0], reverse=True)[: args.top]:
        print(f"  {human(b):>8} {c:7d}  {k}")

    print("\nmetadata churn (mkdir/unlink/rename) top directories")
    for proc, ctr in sorted(meta.items(), key=lambda kv: -sum(kv[1].values()))[:5]:
        for d, n in ctr.most_common(3):
            print(f"  {n:4d}  {proc:32s} {d}")


if __name__ == "__main__":
    sys.exit(main())
