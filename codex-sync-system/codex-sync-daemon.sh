#!/bin/bash
# codex-sync-daemon.sh — Codex session 双向自动同步守护进程（多会话）
#
# 设计为 launchd 服务运行（沙箱外，完整文件系统权限）。
# 自动发现所有本地会话，监控变化并同步到远程。
#
# 用法:
#   ./codex-sync-daemon.sh              # 前台运行（launchd 调用）
#   ./codex-sync-daemon.sh install      # 安装 launchd 服务（开机自启）
#   ./codex-sync-daemon.sh uninstall    # 卸载
#   ./codex-sync-daemon.sh status       # 查看状态
#   ./codex-sync-daemon.sh once         # 单次同步


SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../codex-sync-common.sh"

POLL_INTERVAL="${CODEX_SYNC_INTERVAL:-5}"
STATE_DIR="${CODEX_SYNC_STATE_DIR:-$(cd "$(dirname "$0")" && pwd)/../sync-state}"
LOG_FILE="${CODEX_SYNC_LOG_FILE:-$HOME/.codex/sync-daemon.log}"
MERGE_SCRIPT="$SCRIPT_DIR/codex-sync-merge.py"
REGISTER_SCRIPT="$SCRIPT_DIR/../codex-thread-register.py"

PLIST_LABEL="com.codex.session-sync"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/codex-sync-daemon.sh"

mkdir -p "$STATE_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

file_md5() {
    [ -f "$1" ] && md5 -q "$1" 2>/dev/null || md5sum "$1" 2>/dev/null | cut -d' ' -f1 || echo "MISSING"
}

remote_md5() {
    local rel="$1"
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" \
        "if [ -f ~/$rel ]; then md5sum ~/$rel 2>/dev/null | cut -d' ' -f1 || echo MISSING; else echo MISSING; fi" 2>/dev/null
}

push_to_remote() {
    local file="$1" rel="$2"
    ensure_remote_dir "$rel"
    scp -q -o BatchMode=yes "$file" "$REMOTE_HOST:~/.codex/${rel}" 2>/dev/null
}

update_remote_thread() {
    local rel="$1"
    scp -q -o BatchMode=yes "$REGISTER_SCRIPT" "$REMOTE_HOST:~/.codex/codex-thread-register.py" 2>/dev/null
    ssh -o BatchMode=yes "$REMOTE_HOST" \
        "python3 ~/.codex/codex-thread-register.py ~/.codex/${rel} ~/.codex/state_5.sqlite" 2>/dev/null
}

sync_one_session() {
    local sid="$1" rel="$2"
    local local_file="${CODEX_HOME:-$HOME/.codex}/${rel}"
    local state_dir="$STATE_DIR/${sid}"
    local remote_cache="/tmp/codex-sync-${sid}-remote.jsonl"
    local merged_output="/tmp/codex-sync-${sid}-merged.jsonl"

    local local_hash remote_hash
    local_hash=$(file_md5 "$local_file")
    remote_hash=$(remote_md5 "$rel")

    [ "$local_hash" = "MISSING" ] && return 0

    local last_local last_remote
    last_local=$(cat "$state_dir/local_md5" 2>/dev/null || echo "none")
    last_remote=$(cat "$state_dir/remote_md5" 2>/dev/null || echo "none")

    [ "$local_hash" = "$last_local" ] && [ "$remote_hash" = "$last_remote" ] && return 0

    if [ "$local_hash" = "$remote_hash" ]; then
        mkdir -p "$state_dir"
        echo "$local_hash" > "$state_dir/local_md5"
        echo "$remote_hash" > "$state_dir/remote_md5"
        return 0
    fi

    log "[$sid] 变化: local=$local_hash remote=$remote_hash"

    ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_HOST" "cat ~/.codex/${rel}" > "$remote_cache" 2>/dev/null

    local merge_result
    merge_result=$(python3 "$MERGE_SCRIPT" "$local_file" "$remote_cache" "$merged_output" 2>>"$LOG_FILE")

    case "$merge_result" in
        NO_REMOTE_NEW)
            log "[$sid] 推送本地 → 远程"
            push_to_remote "$local_file" "$rel"
            update_remote_thread "$rel"
            ;;
        NO_LOCAL_NEW)
            log "[$sid] 拉取远程 → 本地"
            cp "$merged_output" "$local_file"
            ;;
        MERGED:*)
            log "[$sid] 合并: $merge_result"
            cp "$merged_output" "$local_file"
            push_to_remote "$local_file" "$rel"
            update_remote_thread "$rel"
            ;;
        *)
            log "[$sid] 合并失败: $merge_result"
            ;;
    esac

    mkdir -p "$state_dir"
    echo "$(file_md5 "$local_file")" > "$state_dir/local_md5"
    echo "$(remote_md5 "$rel")" > "$state_dir/remote_md5"
}

do_sync_all() {
    discover_local_sessions | while IFS='|' read -r sid rel; do
        [ -n "$sid" ] && sync_one_session "$sid" "$rel"
    done
}

run_daemon() {
    log "=== 同步守护启动 (间隔 ${POLL_INTERVAL}s, 多会话) ==="
    while true; do
        do_sync_all 2>> "$LOG_FILE"
        sleep "$POLL_INTERVAL"
    done
}

install_launchd() {
    mkdir -p "$(dirname "$PLIST_PATH")"
    cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>CODEX_SYNC_INTERVAL</key>
        <string>${POLL_INTERVAL}</string>
    </dict>
</dict>
</plist>
PLIST
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load "$PLIST_PATH" 2>/dev/null
    echo "✓ launchd 服务已安装: $PLIST_LABEL"
    echo "  日志: tail -f $LOG_FILE"
    echo "  状态: $0 status"
}

uninstall_launchd() {
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "✓ 已卸载 launchd 服务"
}

show_status() {
    echo "=== Codex Session 同步守护（多会话）==="
    if launchctl list "$PLIST_LABEL" &>/dev/null; then
        pid=$(launchctl list "$PLIST_LABEL" 2>/dev/null | grep "PID" | sed "s/.*= //;s/;//" || echo "?")
        echo "  服务状态: 运行中 (PID: ${pid:-?})"
    else
        echo "  服务状态: 未安装/未运行"
    fi
    echo ""
    echo "  会话状态:"
    discover_local_sessions | while IFS='|' read -r sid rel; do
        [ -z "$sid" ] && continue
        local_file="${CODEX_HOME:-$HOME/.codex}/${rel}"
        L=$(file_md5 "$local_file")
        R=$(remote_md5 "$rel")
        if [ "$L" = "$R" ]; then
            status="✓ 同步"
        elif [ "$R" = "MISSING" ]; then
            status="远程缺失"
        else
            status="⚠ 不同"
        fi
        printf "  %-40s %s\n" "$sid" "$status"
    done
    echo ""
    echo "  最近日志:"
    tail -5 "$LOG_FILE" 2>/dev/null || echo "    (无日志)"
}

case "${1:-daemon}" in
    daemon)
        run_daemon
        ;;
    install)
        install_launchd
        ;;
    uninstall)
        uninstall_launchd
        ;;
    status)
        show_status
        ;;
    once)
        do_sync_all 2>> "$LOG_FILE"
        echo "✓ 单次同步完成"
        tail -3 "$LOG_FILE" 2>/dev/null
        ;;
    *)
        echo "Usage: $0 {daemon|install|uninstall|status|once}"
        exit 1
        ;;
esac
