#!/bin/bash
# codex-session-sync.sh — 本地 ↔ 远程 Codex session 同步（动态会话发现）
#
# 用法:
#   ./codex-session-sync.sh push [SESSION_ID]  # 本地 → 远程（默认同步最新会话）
#   ./codex-session-sync.sh pull [SESSION_ID]  # 远程 → 本地
#   ./codex-session-sync.sh sync [SESSION_ID]  # 按内容哈希比较，不同时提示
#   ./codex-session-sync.sh status [SESSION_ID]
#   ./codex-session-sync.sh list               # 列出所有本地会话
#
# 不指定 SESSION_ID 时自动使用最新修改的会话。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/codex-sync-common.sh"

REGISTER_SCRIPT="$SCRIPT_DIR/codex-thread-register.py"

# 解析会话：如果传了 SESSION_ID 参数就用它，否则取最新
resolve_session() {
    local explicit_id="${1:-}"
    if [ -n "$explicit_id" ]; then
        # 用 session_id 查找 rollout 文件
        local codex_home="${CODEX_HOME:-$HOME/.codex}"
        local found
        found=$(find "$codex_home/sessions" -name "rollout-*-${explicit_id}.jsonl" -type f 2>/dev/null | head -1)
        if [ -z "$found" ]; then
            echo "错误: 找不到会话 $explicit_id 的 rollout 文件" >&2
            echo "可用会话:" >&2
            discover_local_sessions >&2
            exit 1
        fi
        SESSION_ID="$explicit_id"
        SESSION_REL="${found#$codex_home/}"
    else
        local result
        result=$(latest_local_session) || {
            echo "错误: 本地无会话文件" >&2
            exit 1
        }
        SESSION_ID="${result%%|*}"
        SESSION_REL="${result##*|}"
    fi
    LOCAL_FILE="${CODEX_HOME:-$HOME/.codex}/${SESSION_REL}"
    REMOTE_FILE=".codex/${SESSION_REL}"
    TMP_PULL="/tmp/codex-session-pull-${SESSION_ID}.jsonl"
}

# --- helpers ---

local_md5() {
    if [ -f "$LOCAL_FILE" ]; then
        md5 -q "$LOCAL_FILE" 2>/dev/null || md5sum "$LOCAL_FILE" | cut -d' ' -f1
    else
        echo "MISSING"
    fi
}

remote_md5() {
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" \
        "if [ -f ~/$REMOTE_FILE ]; then md5sum ~/$REMOTE_FILE | cut -d' ' -f1; else echo MISSING; fi" 2>/dev/null
}

show_status() {
    local sz
    sz=$(wc -c < "$LOCAL_FILE" 2>/dev/null || echo 0)
    local rsz
    rsz=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" "wc -c < ~/$REMOTE_FILE" 2>/dev/null || echo 0)
    local L R
    L=$(local_md5)
    R=$(remote_md5)
    echo "  Session:  $SESSION_ID"
    echo "  Local :   ${sz} bytes  md5=$L"
    echo "  Remote:   ${rsz} bytes  md5=$R"
    if [ "$L" = "$R" ]; then
        echo "  Status:   IN SYNC ✓"
    else
        echo "  Status:   DIFFERENT ⚠"
    fi
}

# 在远程注册/更新 thread（确保 codex resume 可见）
register_remote_thread() {
    scp -q -o BatchMode=yes "$REGISTER_SCRIPT" "$REMOTE_HOST:~/.codex/codex-thread-register.py" 2>/dev/null
    ssh -o BatchMode=yes "$REMOTE_HOST" \
        "python3 ~/.codex/codex-thread-register.py ~/$REMOTE_FILE ~/.codex/state_5.sqlite" 2>/dev/null
}

do_push() {
    ensure_remote_dir "$SESSION_REL"
    scp -q -o BatchMode=yes "$LOCAL_FILE" "$REMOTE_HOST:~/$REMOTE_FILE"
    echo "  ✓ file pushed"
    register_remote_thread
    echo "✓ Push complete:"
    echo "  codex resume $SESSION_ID"
}

do_pull() {
    scp -q -o BatchMode=yes "$REMOTE_HOST:~/$REMOTE_FILE" "$TMP_PULL"
    echo "  ✓ pulled to $TMP_PULL"
    echo ""
    echo "在本地终端运行："
    echo "  cp $TMP_PULL $LOCAL_FILE"
    echo "  codex resume $SESSION_ID"
}

list_sessions() {
    echo "本地会话（按最新排序）:"
    local codex_home="${CODEX_HOME:-$HOME/.codex}"
    ls -t "$codex_home"/sessions/????/??/??/rollout-*.jsonl 2>/dev/null \
        | while read -r f; do
            local rel="${f#$codex_home/}"
            local base="${f##*/}"
            local uuid
            uuid=$(echo "$base" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
            local meta
            meta=$(extract_session_meta_json "$f")
            local cwd
            cwd=$(meta_get "$meta" "cwd")
            local provider
            provider=$(meta_get "$meta" "model_provider")
            local sz
            sz=$(wc -c < "$f" 2>/dev/null || echo "?")
            printf "  %-40s %8s bytes  cwd=%-50s provider=%s\n" "$uuid" "$sz" "$cwd" "$provider"
        done
}

# --- main ---

ACTION="${1:-status}"
shift || true

case "$ACTION" in
    list)
        list_sessions
        ;;
    status|push|pull|sync)
        resolve_session "${1:-}"
        echo ">>> $ACTION session: $SESSION_ID"
        echo "  path: $SESSION_REL"
        case "$ACTION" in
            status) show_status ;;
            push)   do_push ;;
            pull)   do_pull ;;
            sync)
                L=$(local_md5)
                R=$(remote_md5)
                if [ "$L" = "$R" ]; then
                    echo "  Already in sync ✓"
                elif [ "$R" = "MISSING" ]; then
                    echo "  Remote missing, pushing..."
                    do_push
                elif [ "$L" = "MISSING" ]; then
                    echo "  Local missing, pulling..."
                    do_pull
                else
                    echo "  Content differs!"
                    echo "  Local md5 : $L"
                    echo "  Remote md5: $R"
                    echo ""
                    echo "  ⚠ 请手动选择方向："
                    echo "    push  — 用本地覆盖远程"
                    echo "    pull  — 用远程覆盖本地"
                fi
                ;;
        esac
        ;;
    *)
        echo "Usage: $0 {push|pull|sync|status|list} [SESSION_ID]"
        echo ""
        echo "  不指定 SESSION_ID 时自动使用最新会话。"
        echo "  list 列出所有本地会话。"
        exit 1
        ;;
esac
