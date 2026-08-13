#!/bin/bash
# codex-sync-common.sh — Codex 会话同步共享函数库
# 被 codex-session-sync.sh / codex-auto-sync.sh / codex-sync-daemon.sh source 使用

# 远程主机
REMOTE_HOST="${CODEX_SYNC_REMOTE:-172.29.102.24}"
# 远程 codex 数据目录
REMOTE_CODEX_HOME="${REMOTE_CODEX_HOME:-\$HOME/.codex}"

# 发现本地所有会话 rollout 文件
# 输出格式: <session_id> <relative_path>  每行一个，按修改时间倒序
discover_local_sessions() {
    local codex_home="${CODEX_HOME:-$HOME/.codex}"
    find "$codex_home/sessions" -name 'rollout-*.jsonl' -type f 2>/dev/null \
        | while read -r f; do
            local rel="${f#$codex_home/}"
            # 从文件名提取 UUID: rollout-YYYY-MM-DDTHH-MM-SS-<UUID>.jsonl
            local base="${f##*/}"
            local uuid
            uuid=$(echo "$base" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
            echo "$uuid|$rel"
        done
}

# 获取最新修改的会话
# 输出: <session_id> <relative_path>
latest_local_session() {
    local codex_home="${CODEX_HOME:-$HOME/.codex}"
    local latest
    latest=$(find "$codex_home/sessions" -name 'rollout-*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1)
    if [ -z "$latest" ]; then
        # macOS find 不支持 -printf
        latest=$(ls -t "$codex_home"/sessions/????/??/??/rollout-*.jsonl 2>/dev/null | head -1)
    fi
    [ -z "$latest" ] && return 1

    local f
    if echo "$latest" | grep -q ' '; then
        f=$(echo "$latest" | cut -d' ' -f2-)
    else
        f="$latest"
    fi
    local rel="${f#$codex_home/}"
    local base="${f##*/}"
    local uuid
    uuid=$(echo "$base" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
    echo "$uuid|$rel"
}

# 从 rollout 文件提取 session_meta 的 JSON（取 session_meta 行）
# 参数: $1 = rollout 文件路径
extract_session_meta_json() {
    local file="$1"
    [ -f "$file" ] || return 1
    python3 -c "
import json, sys
with open('$file') as f:
    for line in f:
        try:
            d = json.loads(line)
            if d.get('type') == 'session_meta':
                print(json.dumps(d.get('payload', {}), ensure_ascii=False))
                break
        except:
            pass
" 2>/dev/null
}

# 从 session_meta JSON 提取字段
# 参数: $1 = json, $2 = 字段名
meta_get() {
    local json="$1" field="$2"
    echo "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$field',''))" 2>/dev/null
}

# 从 rollout 路径计算 sessions/ 下的相对路径
# 参数: $1 = rollout 文件绝对路径
rollout_rel_path() {
    local f="$1"
    local codex_home="${CODEX_HOME:-$HOME/.codex}"
    echo "${f#$codex_home/}"
}

# 确保 sessions 目录在远程存在（从相对路径提取目录）
# 参数: $1 = 相对路径 (如 sessions/2026/08/03/rollout-xxx.jsonl)
ensure_remote_dir() {
    local rel="$1"
    local dir="${rel%/*}"
    run_timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=3 -o ServerAliveCountMax=2 "$REMOTE_HOST" "mkdir -p ~/.codex/$dir" 2>/dev/null
}

# macOS 没有 timeout 命令，用 perl 实现超时
# 用法: run_timeout <秒数> <命令...>
run_timeout() {
    local secs="$1"; shift
    (
        "$@" &
        local pid=$!
        ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null ) &
        local watcher=$!
        wait "$pid" 2>/dev/null
        local code=$?
        kill "$watcher" 2>/dev/null
        exit $code
    )
}
