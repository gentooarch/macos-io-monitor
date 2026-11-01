#!/bin/bash
#
# macOS Background Process I/O Monitor (fixed)
#
# 修复要点见文末 CHANGELOG。核心：
#   - 用 fs_usage 的 -t 自动超时，不再依赖 Ctrl+C
#   - 写操作正则基于实测名称：write/writev/WrData*/WrMeta*
#     （注意 fs_usage 会输出 WrMeta[AT1P] / WrData[AT3] 这类带方括号后缀的形式）
#   - write() 行只有 FD 没有路径，脚本用 open/close 事件维护
#     fd -> 路径 映射，把 write 归属到真实文件与目录
#   - 进程过滤为空时不再被 set -u 打崩
#   - fs_usage 的 stderr 单独落盘，不污染 RAW_LOG
#   - 自动生成按目录/文件聚合的报表（次数 + 字节数）
#
# 用法：
#   sudo bash mac-io-monitor.sh                  # 默认 60 秒，全系统
#   sudo bash mac-io-monitor.sh -d 30            # 采集 30 秒
#   sudo bash mac-io-monitor.sh -p Safari,mdworker  # 只监控指定进程
#

set -u

LOG_DIR="/tmp/macos-io-monitor"
DURATION=60
PROCESSES=()          # 空数组 = 监控全系统（安全的默认值）

usage() {
    sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while getopts ":d:p:h" opt; do
    case "$opt" in
        d) DURATION="$OPTARG" ;;
        p) IFS=',' read -r -a PROCESSES <<< "$OPTARG" ;;
        h) usage 0 ;;
        *) echo "未知选项，用 -h 查看用法" >&2; usage 1 ;;
    esac
done

# ---------- 权限与依赖检查 ----------
if [[ "${EUID}" -ne 0 ]]; then
    echo "需要 root 权限，请用：sudo bash $0 $*" >&2
    exit 1
fi

if ! command -v fs_usage >/dev/null 2>&1; then
    echo "找不到 fs_usage" >&2
    exit 1
fi

if ! [[ "$DURATION" =~ ^[1-9][0-9]*$ ]]; then
    echo "-d 必须是正整数秒，收到：$DURATION" >&2
    exit 1
fi

mkdir -p "$LOG_DIR"

TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
RAW_LOG="$LOG_DIR/fs_usage-$TIMESTAMP.log"
WRITE_LOG="$LOG_DIR/write-events-$TIMESTAMP.log"
SUMMARY="$LOG_DIR/write-paths-$TIMESTAMP.txt"
DIRSTAT="$LOG_DIR/write-dirs-$TIMESTAMP.txt"
ERR_LOG="$LOG_DIR/fs_usage-$TIMESTAMP.err"
META="$LOG_DIR/system-$TIMESTAMP.txt"

# ---------- 写操作判定（集中一处，避免多处正则漂移） ----------
# 实测 fs_usage 输出的写类操作名：
#   write, writev, pwrite, pwritev, fsync, ftruncate, sync
#   WrData[S], WrData[AT3], WrMeta[AT1P]
# 只取真正写磁盘数据的子集；元数据写也计入。
WRITE_AWK='
$2 ~ /^(write|writev|write_nocancel|pwrite|pwritev|pwrite_nocancel|WrData|WrMeta)/ { print }
'

echo "========================================"
echo " macOS Background I/O Monitor (fixed)"
echo "========================================"
echo "日志目录 : $LOG_DIR"
echo "采集时长 : ${DURATION}s"
echo "监控进程 : ${PROCESSES[*]:-（全系统）}"
echo "开始时间 : $(date)"
echo

# ---------- 记录元数据（只记有效信息，不再塞满 ps 全量） ----------
{
    echo "Start: $(date)"
    echo "Duration: ${DURATION}s"
    echo "Targets: ${PROCESSES[*]:-ALL}"
    echo "Uptime:"
    uptime
    echo
    echo "Match targets:"
    for p in ${PROCESSES[@]+"${PROCESSES[@]}"}; do
        if pgrep -x "$p" >/dev/null 2>&1; then
            echo "  $p: RUNNING ($(pgrep -x "$p" | tr '\n' ' '))"
        else
            echo "  $p: NOT RUNNING"
        fi
    done
} > "$META"

# ---------- 采集 ----------
# -w 是 "wider output"，不是 write！必须配合 awk 做写过滤。
# -t 自动超时，保证无人值守也能收尾。
if [[ ${#PROCESSES[@]} -gt 0 ]]; then
    echo "开始采集（fs_usage -w -f filesys，过滤进程）..."
    fs_usage -w -f filesys -t "$DURATION" ${PROCESSES[@]+"${PROCESSES[@]}"} \
        > "$RAW_LOG" 2> "$ERR_LOG"
else
    echo "开始采集（fs_usage -w -f filesys，全系统）..."
    fs_usage -w -f filesys -t "$DURATION" \
        > "$RAW_LOG" 2> "$ERR_LOG"
fi
RC=$?

echo "采集结束（fs_usage 退出码 ${RC}）"

if [[ -s "$ERR_LOG" ]]; then
    echo
    echo "⚠ fs_usage 有错误输出："
    sed 's/^/    /' "$ERR_LOG"
fi

# ---------- 生成报表 ----------
# 注意：路径可能含空格，awk 不能用固定列号取路径。
# 用 sed 从行中裁出路径段（两个设备/路径字段之后、延迟浮点之前）。
awk "$WRITE_AWK" "$RAW_LOG" > "$WRITE_LOG"

awk "$WRITE_AWK" "$RAW_LOG" | sort -u > "$SUMMARY"

# 按目录聚合
#
# 重要实测结论（决定聚合正确性）：
#   - `write` / `writev` 行只有 F=<fd>，**没有路径**，无法直接归属目录。
#     即使写 200MB，fs_usage 也不会在 write 行给出路径；-f pathname 同样如此。
#   - 只有 `WrData[*]` / `WrMeta[*]` 行带完整路径。
#   - 归属办法：先用同一进程的 `open ... F=<fd> ... <path>` 建立 fd -> 路径 映射，
#     再把该进程的 write/writev 事件按 fd 归属到路径。
#   - `WrMeta[*]` 大量指向 /dev/disk3*（块设备元数据），非用户目录，需排除。
awk '
BEGIN { unresolved = 0; total = 0 }
function hex2num(s,   i, n, c) {
    if (substr(s, 1, 2) == "0x") s = substr(s, 3)
    n = 0
    for (i = 1; i <= length(s); i++) {
        c = index("0123456789abcdef", tolower(substr(s, i, 1))) - 1
        if (c < 0) break
        n = n * 16 + c
    }
    return n
}
function record(path, bytes,   dir) {
    if (path == "" || path ~ /^\/dev\//) return
    if (match(path, /\/[^\/]*$/)) {
        dir = substr(path, 1, RSTART - 1)
        if (dir == "") dir = "/"
    } else dir = path
    dcount[dir]++;  dbytes[dir] += bytes
    fcount[path]++; fbytes[path] += bytes
    total++
}
# 去掉 <SEEK>/[n] 之类前缀噪声
function cleanpath(p) {
    sub(/^\[[0-9]+\]/, "", p)     # openat 的 dirfd 前缀，如 [3]/../../System
    sub(/^[ \t]+/, "", p)
    return p
}
{
    proc = $NF
    # 取本行的 B= 字节数（十六进制）
    bytes = ""
    for (v = 1; v <= NF; v++) if ($v ~ /^B=/) { bytes = $v; sub(/^B=/, "", bytes) }
    b = (bytes == "") ? 0 : hex2num(bytes)

    # 取本行 fd。fs_usage 有两种写法：
    #   F=4        —— 常规
    #   [  2]      —— 对齐变体（会拆成 "[" 和 "2]" 两个字段）
    # 注意：open/openat 行有 (RWC_T_______) 标志列，其前一字段是 fd；
    #       write/close 行**没有**标志列，只能直接扫 F=。
    # 标志字符集不止 RWC_，实测还有 T/A/P/S 等，故用 [A-Z_]+ 宽松匹配。
    fd = ""
    fl = 0
    for (v = 1; v <= NF; v++) if ($v ~ /^\([A-Z_]+\)$/) { fl = v; break }
    if (fl > 1) {
        cand = $(fl - 1)
        if (cand ~ /^F=[0-9]+$/) { fd = cand; sub(/^F=/, "", fd) }
        else if (cand ~ /^[0-9]+\]$/) { fd = cand; sub(/\]$/, "", fd) }
    }
    if (fd == "")
        for (v = 1; v <= NF; v++) if ($v ~ /^F=[0-9]+$/) { fd = $v; sub(/^F=/, "", fd); break }

    # 1) close：解除映射，避免 fd 复用时串到旧路径
    if ($2 == "close") {
        if (fd != "") delete fdmap[proc, fd]
        next
    }

    # 2) open/openat：建立 fd -> 路径 映射
    if ($2 == "open" || $2 == "openat") {
        if (fd == "" || fl == 0) next
        # 路径 = 标志列之后、延迟浮点列之前的所有字段（可能含空格）
        path = ""
        for (u = fl + 1; u <= NF; u++) {
            if ($u ~ /^[0-9]+\.[0-9]+$/) break
            path = (path == "") ? $u : path " " $u
        }
        if (path == "") next
        path = cleanpath(path)
        if (path !~ /^\//) path = "/" path
        fdmap[proc, fd] = path
        next
    }

    # 3) WrData/WrMeta：行内自带路径
    if ($2 ~ /^Wr(Data|Meta)/) {
        path = ""; pi = 0
        for (v = 1; v <= NF; v++) if ($v ~ /^\//) { path = $v; pi = v }
        if (path == "") next
        for (u = pi + 1; u <= NF; u++) {
            if ($u ~ /^[0-9]+\.[0-9]+$/) break
            path = path " " $u
        }
        record(path, b)
        next
    }

    # 4) write/writev：只有 FD，靠 open 映射回路径
    if ($2 ~ /^(write|writev|write_nocancel)/) {
        if (fd == "") next
        if ((proc, fd) in fdmap) record(fdmap[proc, fd], b)
        else unresolved++
        next
    }
}
END {
    printf "%-7s  %-12s  %s\n", "COUNT", "BYTES", "DIRECTORY"
    for (d in dcount) printf "%-7d  %-12d  %s\n", dcount[d], dbytes[d], d | "sort -rn"
    close("sort -rn")
    print ""
    printf "%-7s  %-12s  %s\n", "COUNT", "BYTES", "FILE"
    for (f in fcount) printf "%-7d  %-12d  %s\n", fcount[f], fbytes[f], f | "sort -rn"
    close("sort -rn")
    print ""
    printf "合计归属事件: %d\n", total
    if (unresolved > 0)
        printf "⚠ 未能归属的写事件（fd 已关闭或进程已退出）: %d\n", unresolved
}
' "$RAW_LOG" > "$DIRSTAT"

echo
echo "========================================"
echo " 报表"
echo "========================================"
echo "原始事件 : $(wc -l < "$RAW_LOG" | tr -d ' ')"
echo "写事件   : $(wc -l < "$WRITE_LOG" | tr -d ' ')"
echo "唯一写行 : $(wc -l < "$SUMMARY" | tr -d ' ')"
echo

if [[ -s "$DIRSTAT" ]]; then
    cat "$DIRSTAT"
else
    echo "（本次未捕获到写事件）"
    echo "提示：若确实预期有写入，可延长 -d，或用 -p 指定更活跃的进程。"
fi

echo
echo "生成文件："
for f in "$RAW_LOG" "$WRITE_LOG" "$SUMMARY" "$DIRSTAT" "$META" "$ERR_LOG"; do
    [[ -e "$f" ]] && printf "  %10s  %s\n" "$(wc -c < "$f" | tr -d ' ')B" "$f"
done
echo
echo "结束时间: $(date)"

# ============================================================
# CHANGELOG (对比旧版)
# 1. -w 误解：旧版以为 -w 表示 write，实际是 "wider output"。
#    新版保留 -w 但明确靠 awk 过滤写操作。
# 2. 正则失效：旧版 WrData[A-Za-z]*$ 匹配不到 WrData[AT3] / WrMeta[AT1P]
#    （方括号不是字母）。新版改用前缀匹配 /^(...|WrData|WrMeta)/。
# 3. set -u + 空数组崩溃：新版用 ${PROCESSES[@]+"${PROCESSES[@]}"} 保护。
# 4. 无超时：新版使用 fs_usage -t "$DURATION"。
# 5. 2>&1 污染日志：新版 stderr 单独写入 .err 文件。
# 6. 无聚合：新版新增 write-dirs-*.txt，按目录/文件统计次数与字节数。
# 7. 元数据瘦身：不再把 ps -axo 全量 dump 进 system 文件。
# 8. 【关键】路径归属：write/writev 行只有 F=<fd> 没有路径（实测即使
#    写 200MB 也不带路径，-f pathname 同样如此）。新版通过解析
#    open/openat 建立 fd->路径 映射、遇 close 立即删除（fd 会被复用），
#    从而把 write 事件正确归属到文件与目录，并输出未归属计数。
# 9. fs_usage 的 fd 字段有两种写法 F=4 与 [  2]（后者会拆成两个字段），
#    新版按「标志列前一字段」稳健解析。
# 10. 标志列 (RWC_T_______) 字符集不止 RWC_，新版用 [A-Z_]+ 匹配。
# ============================================================
exit 0