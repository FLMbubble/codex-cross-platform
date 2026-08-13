#!/bin/bash
# codex-auto-sync.sh — 自动监控并双向合并同步 Codex session（多会话）
#
# 用法:
#   ./codex-auto-sync.sh start [间隔秒数]   # 启动守护（默认 5 秒）
#   ./codex-auto-sync.sh stop                # 停止守护
#   ./codex-auto-sync.sh status              # 查看状态
#   ./codex-auto-sync.sh once                # 执行一次同步（不启动守护）


SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/codex-sync-common.sh"

PID_FILE="/tmp/codex-auto-sync.pid"
LOG_FILE="${CODEX_SYNC_LOG_FILE:-/tmp/codex-auto-sync.log}"
STATE_DIR="$(cd "$(dirname "$0")" && pwd)/sync-state"
MERGE_SCRIPT="$SCRIPT_DIR/codex-merge.py"
REGISTER_SCRIPT="$SCRIPT_DIR/codex-thread-register.py"

mkdir -p "$STATE_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# 计算文件的 md5（兼容 macOS / Linux）
file_md5() {
    [ -f "$1" ] && md5 -q "$1" 2>/dev/null || md5sum "$1" 2>/dev/null | cut -d' ' -f1 || echo "MISSING"
}

# 远程文件 md5
remote_md5() {
    local rel="$1"
    run_timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=3 -o ServerAliveCountMax=2 "$REMOTE_HOST" \
        "if [ -f ~/$rel ]; then md5sum ~/$rel 2>/dev/null | cut -d' ' -f1 || echo MISSING; else echo MISSING; fi" 2>/dev/null
}

# 同步单个会话
sync_one_session() {
    local sid="$1" rel="$2"
    local local_file="${CODEX_HOME:-$HOME/.codex}/${rel}"
    local remote_file=".codex/${rel}"
    local state_dir="$STATE_DIR/${sid}"
    local remote_cache="/tmp/codex-sync-${sid}-remote.jsonl"
    local merged_output="/tmp/codex-sync-${sid}-merged.jsonl"

    [ ! -f "$local_file" ] && return 0

    # 本地文件修改时间
    local local_mtime
    local_mtime=$(stat -f %m "$local_file" 2>/dev/null || stat -c %Y "$local_file" 2>/dev/null || echo 0)

    # 上次同步时间（推送成功后记录的时间戳）
    local last_sync
    last_sync=$(cat "$state_dir/sync_time" 2>/dev/null || echo 0)

    # 如果本地没有修改（mtime <= 上次同步时间），跳过，不需要 SSH
    if [ "$local_mtime" -le "$last_sync" ] 2>/dev/null; then
        return 0
    fi

    local local_hash
    local_hash=$(file_md5 "$local_file")

    log "[$sid] 本地有修改 (mtime=$(date -r "$local_mtime" '+%H:%M:%S' 2>/dev/null), sync_time=$(date -r "$last_sync" '+%H:%M:%S' 2>/dev/null || echo none))"

    # 查远程 md5（仅在本地有修改时才 SSH）
    local remote_hash
    remote_hash=$(remote_md5 "$rel") || remote_hash="MISSING"

    # 本地和远程已一致（远程已有最新内容）
    if [ "$local_hash" = "$remote_hash" ]; then
        mkdir -p "$state_dir"
        echo "$local_mtime" > "$state_dir/sync_time"
        echo "$local_hash" > "$state_dir/local_md5"
        return 0
    fi

    # 远程缺失或内容不同 → 拉取远程文件做三方合并
    if [ "$remote_hash" = "MISSING" ]; then
        : > "$remote_cache"
    else
        run_timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=3 -o ServerAliveCountMax=2 "$REMOTE_HOST" "cat ~/$remote_file" > "$remote_cache" 2>/dev/null
    fi

    local merge_result
    merge_result=$(python3 "$MERGE_SCRIPT" "$local_file" "$remote_cache" "$merged_output" 2>>"$LOG_FILE")

    case "$merge_result" in
        NO_REMOTE_NEW|MERGED:*)
            if [ "$merge_result" = "NO_REMOTE_NEW" ]; then
                log "[$sid] 推送本地 → 远程"
            else
                log "[$sid] 合并: $merge_result"
                cp "$merged_output" "$local_file"
            fi
            local push_file="$local_file"
            [ "$merge_result" != "NO_REMOTE_NEW" ] && push_file="$merged_output"
            ensure_remote_dir "$rel"
            run_timeout 60 scp -q -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=3 "$push_file" "$REMOTE_HOST:~/$remote_file" 2>>"$LOG_FILE"
            run_timeout 30 scp -q -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=3 "$REGISTER_SCRIPT" "$REMOTE_HOST:~/.codex/codex-thread-register.py" 2>>"$LOG_FILE"
            run_timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=3 -o ServerAliveCountMax=2 "$REMOTE_HOST" "python3 ~/.codex/codex-thread-register.py ~/$remote_file ~/.codex/state_5.sqlite" 2>>"$LOG_FILE"
            # 记录同步时间 = 当前本地文件 mtime
            local new_mtime
            new_mtime=$(stat -f %m "$local_file" 2>/dev/null || stat -c %Y "$local_file" 2>/dev/null || echo 0)
            echo "$new_mtime" > "$state_dir/sync_time"
            echo "$local_hash" > "$state_dir/local_md5"
            ;;
        NO_LOCAL_NEW)
            log "[$sid] 拉取远程 → 本地"
            cp "$merged_output" "$local_file"
            local new_mtime
            new_mtime=$(stat -f %m "$local_file" 2>/dev/null || stat -c %Y "$local_file" 2>/dev/null || echo 0)
            echo "$new_mtime" > "$state_dir/sync_time"
            ;;
        *)
            log "[$sid] 合并失败: $merge_result"
            ;;
    esac
}

# 只同步活跃会话（最近 N 分钟内修改过的）
ACTIVE_MINUTES="${CODEX_SYNC_ACTIVE_MINUTES:-30}"

# 同步活跃会话
do_sync_all() {
    local now_epoch
    now_epoch=$(date +%s)
    local threshold=$((now_epoch - ACTIVE_MINUTES * 60))

    discover_local_sessions | while IFS='|' read -r sid rel; do
        [ -z "$sid" ] && continue
        local local_file="${CODEX_HOME:-$HOME/.codex}/${rel}"
        # 只处理最近修改的会话
        local mtime
        mtime=$(stat -f %m "$local_file" 2>/dev/null || stat -c %Y "$local_file" 2>/dev/null || echo 0)
        if [ "$mtime" -lt "$threshold" ]; then
            continue
        fi
        sync_one_session "$sid" "$rel" || true
    done || true
}

# 强制全量同步（用于 once 命令）
do_sync_all_force() {
    discover_local_sessions | while IFS='|' read -r sid rel; do
        [ -n "$sid" ] && sync_one_session "$sid" "$rel" || true
    done || true
}

run_daemon() {
    local interval="${1:-5}"
    echo $$ > "$PID_FILE"
    log "=== 守护启动 (间隔 ${interval}s, 多会话) ==="
    while true; do
        do_sync_all 2>> "$LOG_FILE"
        sleep "$interval"
    done
}

case "${1:-status}" in
    start)
        interval="${2:-5}"
        if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            echo "守护已在运行 (PID $(cat "$PID_FILE"))"
            exit 0
        fi
        nohup bash "$0" _daemon "$interval" > /dev/null 2>&1 &
        disown
        echo "✓ 守护已启动 (PID $!, 间隔 ${interval}s, 多会话)"
        echo "  日志: tail -f $LOG_FILE"
        echo "  停止: $0 stop"
        ;;
    _daemon)
        run_daemon "${2:-5}"
        ;;
    stop)
        if [ -f "$PID_FILE" ]; then
            kill "$(cat "$PID_FILE")" 2>/dev/null
            rm -f "$PID_FILE"
            log "=== 守护已停止 ==="
            echo "✓ 已停止"
        else
            echo "未运行"
        fi
        ;;
    once)
        do_sync_all 2>> "$LOG_FILE"
        echo "✓ 单次同步完成 (活跃会话, 最近${ACTIVE_MINUTES}分钟)"
        tail -5 "$LOG_FILE" 2>/dev/null
        ;;
    once-all)
        do_sync_all_force 2>> "$LOG_FILE"
        echo "✓ 全量同步完成"
        tail -5 "$LOG_FILE" 2>/dev/null
        ;;
    status)
        if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            echo "运行中 (PID $(cat "$PID_FILE"))"
        else
            echo "未运行"
        fi
        echo ""
        # 收集活跃会话（只查本地的，不连远程，秒出）
        now_epoch=$(date +%s)
        threshold=$((now_epoch - ACTIVE_MINUTES * 60))
        echo "活跃会话 (最近${ACTIVE_MINUTES}分钟):"
        discover_local_sessions | while IFS='|' read -r sid rel; do
            [ -z "$sid" ] && continue
            lf="${CODEX_HOME:-$HOME/.codex}/${rel}"
            mtime=$(stat -f %m "$lf" 2>/dev/null || stat -c %Y "$lf" 2>/dev/null || echo 0)
            [ "$mtime" -lt "$threshold" ] && continue
            L=$(file_md5 "$lf") || L="MISSING"
            mod_time=$(date -r "$mtime" '+%m-%d %H:%M' 2>/dev/null || date -d "@$mtime" '+%m-%d %H:%M' 2>/dev/null || echo "?")
            # 上次同步时间
            sync_time=$(cat "$STATE_DIR/${sid}/sync_time" 2>/dev/null || echo 0)
            if [ "$sync_time" = "0" ]; then
                sync_str="未同步"
                sync_flag="⚠"
            elif [ "$mtime" -gt "$sync_time" ] 2>/dev/null; then
                sync_str="同步于 $(date -r "$sync_time" '+%m-%d %H:%M' 2>/dev/null || echo "?")"
                sync_flag="⚠ 待推送"
            else
                sync_str="同步于 $(date -r "$sync_time" '+%m-%d %H:%M' 2>/dev/null || echo "?")"
                sync_flag="✓"
            fi
            printf "  %-38s 修改=%s  %s  %s\n" "$sid" "$mod_time" "$sync_str" "$sync_flag"
        done || true
        echo ""
        echo "最近日志:"
        tail -5 "$LOG_FILE" 2>/dev/null
        ;;
    *)
        echo "Usage: $0 {start [秒]|stop|status|once}"
        ;;
esac
