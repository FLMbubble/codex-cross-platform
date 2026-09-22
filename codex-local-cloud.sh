#!/bin/bash
# codex-local-cloud.sh — 把本地 Mac 当作 Codex "云端" app-server（多服务器版）
#
# 架构:
#
#   本地 Mac（云服务器）
#   ├── codex app-server (ws://0.0.0.0:8421)
#   ├── Chrome 扩展 / CLI（直连 127.0.0.1:8421）
#   │
#   │  SSH 反向隧道 (-R 8421:127.0.0.1:8421)  × N 台远程
#   │  或 WebSocket 直连 (ws://<本机IP>:8421)
#   │
#   远程服务器 A          远程服务器 B          远程服务器 C
#   ├── VSCode 扩展       ├── VSCode 扩展       ├── Codex CLI
#   └── Codex CLI         └── Codex CLI
#
# 用法:
#   ./codex-local-cloud.sh start [tunnel|direct] [server...]  启动 (默认 tunnel, 连所有服务器)
#   ./codex-local-cloud.sh stop                               停止 app-server 和所有隧道
#   ./codex-local-cloud.sh status                              查看运行状态
#   ./codex-local-cloud.sh connect [server]                   打印连接信息
#   ./codex-local-cloud.sh push-session                        推送本地最新会话
#   ./codex-local-cloud.sh logs                                查看 app-server 日志
#   ./codex-local-cloud.sh add <name> <host> [user]            添加远程服务器
#   ./codex-local-cloud.sh remove <name>                       移除远程服务器
#   ./codex-local-cloud.sh list                                列出已配置的服务器
#   ./codex-local-cloud.sh restart [tunnel|direct] [server...] 重启

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/codex-sync-common.sh"

# --- 配置 ---
PORT="${CODEX_CLOUD_PORT:-8421}"
CODEX_BIN="${CODEX_CLOUD_BIN:-}"

# detect_best_codex: auto-detect best codex binary
detect_best_codex() {
    if [ -n "$CODEX_BIN" ]; then return; fi
    local candidates=()
    [ -x "/Applications/ChatGPT.app/Contents/Resources/codex" ] && candidates+=("/Applications/ChatGPT.app/Contents/Resources/codex")
    local vscode_codex
    vscode_codex=$(ls ~/.vscode/extensions/openai.chatgpt-*/bin/*/codex 2>/dev/null | head -1)
    [ -n "$vscode_codex" ] && candidates+=("$vscode_codex")
    command -v codex >/dev/null 2>&1 && candidates+=("$(command -v codex)")
    [ -x "$HOME/.local/bin/codex" ] && candidates+=("$HOME/.local/bin/codex")
    local best="" best_ver=""
    for bin in "${candidates[@]}"; do
        local ver
        ver=$("$bin" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        if [ -n "$ver" ]; then
            if [ -z "$best_ver" ] || printf '%s\n%s\n' "$ver" "$best_ver" | sort -V | head -1 | grep -q "$best_ver"; then
                best="$bin"; best_ver="$ver"
            fi
        fi
    done
    CODEX_BIN="${best:-codex}"
}
TOKEN_FILE="${CODEX_HOME:-$HOME/.codex}/ws-token"
PID_FILE="${CODEX_HOME:-$HOME/.codex}/app-server.pid"
LOG_FILE="${CODEX_HOME:-$HOME/.codex}/app-server.log"
TUNNEL_DIR="/tmp/codex-cloud-tunnels"
SERVERS_FILE="${CODEX_CLOUD_SERVERS:-$SCRIPT_DIR/codex-cloud-servers.conf}"
mkdir -p "$TUNNEL_DIR"

# --- 辅助函数 ---

generate_token() {
    python3 -c "import secrets; print(secrets.token_hex(32))"
}

is_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null && {
        local h
        h=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://127.0.0.1:$PORT/healthz" 2>/dev/null || echo "000")
        [ "$h" = "200" ]
    }
}

health_check() {
    curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:$PORT/healthz" 2>/dev/null || echo "000"
}

get_local_ip() {
    ifconfig 2>/dev/null | grep "inet " | grep -v 127.0.0.1 | head -1 | awk '{print $2}' || echo "unknown"
}

# 查找空闲端口：检查端口是否被非 codex 进程监听
is_port_free() {
    local port="$1"
    # 检查是否有 LISTEN 状态的连接
    if lsof -i ":$port" -sTCP:LISTEN >/dev/null 2>&1; then
        return 1  # 端口被占用
    fi
    return 0  # 端口空闲
}

# 从指定端口开始找空闲端口
find_free_port() {
    local start_port="${1:-8421}"
    local max_port=$((start_port + 100))
    local port="$start_port"
    while [ "$port" -lt "$max_port" ]; do
        if is_port_free "$port"; then
            echo "$port"
            return 0
        fi
        port=$((port + 1))
    done
    echo ""
    return 1
}

# --- 服务器配置文件解析 ---
# 格式: name|host|user|enabled
# 空行和 # 开头的行跳过

load_servers() {
    if [ ! -f "$SERVERS_FILE" ]; then
        return 0
    fi
    grep -v '^#' "$SERVERS_FILE" 2>/dev/null | grep -v '^$' || true
}

server_exists() {
    local name="$1"
    load_servers | while IFS='|' read -r n h u e; do
        if [ "$n" = "$name" ]; then
            echo "yes"
            return
        fi
    done
}

get_server_host() {
    local name="$1"
    load_servers | while IFS='|' read -r n h u e; do
        if [ "$n" = "$name" ]; then
            echo "$h"
            return
        fi
    done
}

get_server_user() {
    local name="$1"
    load_servers | while IFS='|' read -r n h u e; do
        if [ "$n" = "$name" ]; then
            echo "$u"
            return
        fi
    done
}

# tunnel_running 改为接受 server name
tunnel_pid_file() {
    echo "$TUNNEL_DIR/tunnel-$1.pid"
}

tunnel_log_file() {
    echo "$TUNNEL_DIR/tunnel-$1.log"
}

tunnel_running() {
    local name="$1"
    local tf
    tf=$(tunnel_pid_file "$name")
    [ -f "$tf" ] && kill -0 "$(cat "$tf" 2>/dev/null)" 2>/dev/null
}

# 获取所有隧道中运行的服务器名
running_tunnels() {
    for tf in "$TUNNEL_DIR"/tunnel-*.pid; do
        [ -f "$tf" ] || continue
        local name
        name=$(basename "$tf" .pid | sed 's/tunnel-//')
        if kill -0 "$(cat "$tf" 2>/dev/null)" 2>/dev/null; then
            echo "$name"
        fi
    done
}

# 解析要连接的服务器列表
# 参数: 传入的 server name 列表（空 = 所有启用的）
resolve_servers() {
    local result=""
    if [ $# -eq 0 ]; then
        # 所有启用的服务器
        load_servers | while IFS='|' read -r name host user enabled; do
            [ "$enabled" != "no" ] && echo "$name"
        done
    else
        for name in "$@"; do
            if [ -n "$(server_exists "$name")" ]; then
                echo "$name"
            else
                echo "WARN: 服务器 '$name' 不在配置文件中，跳过" >&2
            fi
        done
    fi
}

# --- 主命令 ---

cmd_start() {
    local mode="${1:-tunnel}"
    shift || true
    local servers=("$@")

    # 启动 app-server
    if is_running; then
        echo "✓ app-server 已在运行 (PID $(cat "$PID_FILE"))"
        echo "  health: $(health_check)"
    else
        echo ">>> 启动本地 app-server..."

        # 自动寻找空闲端口（避免 VSCode 扩展占用冲突）
        if ! is_port_free "$PORT"; then
            local new_port
            new_port=$(find_free_port "$PORT")
            if [ -n "$new_port" ]; then
                echo "  ⚠ 端口 $PORT 被占用，自动切换到 $new_port"
                PORT="$new_port"
            else
                echo "  ✗ 在 $PORT~$((PORT+100)) 范围内未找到空闲端口"
                return 1
            fi
        fi

        mkdir -p "$(dirname "$LOG_FILE")"

        local token
        # 复用已有 token 或生成新的
        token=$(cat "$TOKEN_FILE" 2>/dev/null)
        if [ -z "$token" ]; then
            token=$(generate_token)
        fi
        echo "$token" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"

        detect_best_codex
        CODEX_VER_INFO=$("$CODEX_BIN" --version 2>/dev/null || echo unknown)
        echo "  codex: $CODEX_BIN ($CODEX_VER_INFO)"

        nohup "$CODEX_BIN" app-server \
            --listen "ws://0.0.0.0:$PORT" \
            --ws-auth capability-token \
            --ws-token-file "$TOKEN_FILE" \
            > "$LOG_FILE" 2>&1 &
        echo $! > "$PID_FILE"
        sleep 3

        local health
        health=$(health_check)
        if [ "$health" = "200" ]; then
            echo "✓ app-server 启动成功 (PID $(cat "$PID_FILE"))"
            echo "  端口: $PORT"
            echo "  health: $health"
        else
            echo "✗ app-server 启动失败 (health=$health)"
            echo "  日志: tail -20 $LOG_FILE"
            tail -20 "$LOG_FILE" 2>/dev/null
            # 清理：杀掉失败的 app-server 进程，释放端口
            echo "  >>> 清理残留进程..."
            local fail_pid
            fail_pid=$(cat "$PID_FILE" 2>/dev/null)
            if [ -n "$fail_pid" ]; then
                kill "$fail_pid" 2>/dev/null && echo "  ✓ 已杀掉 app-server (PID $fail_pid)"
                rm -f "$PID_FILE"
            fi
            # 杀掉占用该端口的 codex app-server 进程
            pkill -f "app-server.*$PORT" 2>/dev/null && echo "  ✓ 已清理占用端口 $PORT 的进程" || true
            sleep 1
            # 确认端口已释放
            if is_port_free "$PORT"; then
                echo "  ✓ 端口 $PORT 已释放"
            else
                echo "  ⚠ 端口 $PORT 仍被占用（可能是其他进程）"
            fi
            return 1
        fi
    fi

    # 建立隧道
    if [ "$mode" = "tunnel" ]; then
        setup_tunnels "${servers[@]}"
        # 隧道建立后自动推送 token 到所有远程服务器
        local active_servers=()
        if [ ${#servers[@]} -gt 0 ]; then
            active_servers=("${servers[@]}")
        else
            while IFS= read -r line; do
                active_servers+=("$line")
            done < <(resolve_servers)
        fi
        push_token_to_all "${active_servers[@]}"
    else
        echo ""
        echo "  直连模式: 远程需通过 ws://<本机IP>:$PORT 连接"
        echo "  本机 IP: $(get_local_ip)"
        # 直连模式也推送 token
        push_token_to_all "${servers[@]}"
    fi

    echo ""
    echo "=== 连接信息 ==="
    print_connect_info "$mode" "${servers[@]}"
}

setup_tunnels() {
    local servers=()
    if [ $# -eq 0 ]; then
        while IFS= read -r line; do
            servers+=("$line")
        done < <(resolve_servers)
    else
        servers=("$@")
    fi

    if [ ${#servers[@]} -eq 0 ]; then
        echo "⚠ 配置文件中没有启用的服务器"
        echo "  添加服务器: ./codex-local-cloud.sh add <name> <host> [user]"
        echo "  或使用 direct 模式: ./codex-local-cloud.sh start direct"
        return 1
    fi

    for name in "${servers[@]}"; do
        setup_one_tunnel "$name"
    done
}

setup_one_tunnel() {
    local name="$1"
    local host user

    if [ -z "$(server_exists "$name")" ]; then
        echo "  ✗ 服务器 '$name' 不存在，跳过"
        return 1
    fi
    host=$(get_server_host "$name")
    user=$(get_server_user "$name")
    [ -z "$user" ] && user="$USER"

    local ssh_target="${user}@${host}"
    local tf lf
    tf=$(tunnel_pid_file "$name")
    lf=$(tunnel_log_file "$name")

    if tunnel_running "$name"; then
        echo "  ✓ [$name] 隧道已在运行 (PID $(cat "$tf"))"
        return 0
    fi

    echo "  >>> [$name] 建立隧道 → $ssh_target"

    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$ssh_target" 'echo OK' >/dev/null 2>&1; then
        echo "  ✗ [$name] SSH 连接 $ssh_target 失败，跳过"
        return 1
    fi

    nohup ssh -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
        -o TCPKeepAlive=yes \
        -R "${PORT}:127.0.0.1:${PORT}" \
        -N "$ssh_target" \
        > "$lf" 2>&1 &
    echo $! > "$tf"
    disown
    sleep 2

    if tunnel_running "$name"; then
        echo "  ✓ [$name] 隧道已建立 (PID $(cat "$tf"))"
        # 验证远程端口可达
        if ssh -o BatchMode=yes -o ConnectTimeout=5 "$ssh_target" \
            'python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    s.connect(("127.0.0.1", '"$PORT"'))
    s.close()
except:
    pass
"' >/dev/null 2>&1; then
            echo "    远程端口验证: ✓ 可达"
        else
            echo "    远程端口验证: ⚠ 无法验证（可能需要 curl/wget）"
        fi
    else
        echo "  ✗ [$name] 隧道建立失败，查看日志: $lf"
        tail -3 "$lf" 2>/dev/null
    fi
}


# --- 推送 token 到远程服务器 ---

push_token_to_remote() {
    local name="$1"
    local host user ssh_target
    local token port

    token=$(cat "$TOKEN_FILE" 2>/dev/null)
    if [ -z "$token" ]; then
        echo "  ✗ [$name] token 文件为空，跳过"
        return 1
    fi
    port="$PORT"

    host=$(get_server_host "$name")
    user=$(get_server_user "$name")
    [ -z "$user" ] && user="$USER"
    ssh_target="${user}@${host}"

    echo "  >>> [$name] 推送 token (port=$port) → $ssh_target"

    # 通过 SSH 更新远程的 .bash_profile、codex-connect.sh，并验证连通性
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$ssh_target" bash -s "$token" "$port" << 'REMOTE_EOF'
        TOKEN="$1"
        PORT="$2"

        # 1. 更新 .bash_profile 中的 token 和端口
        if grep -q "CODEX_WS_TOKEN" ~/.bash_profile 2>/dev/null; then
            sed -i "/CODEX_WS_TOKEN/d" ~/.bash_profile
        fi
        echo "export CODEX_WS_TOKEN=${TOKEN}" >> ~/.bash_profile

        # 2. 更新 codex-connect.sh 连接脚本（带 PATH、token、端口）
        cat > ~/codex-connect.sh << CONN
#!/bin/bash
export PATH="\$HOME/.local/bin:\$PATH"
export CODEX_WS_TOKEN=${TOKEN}
exec codex --remote ws://127.0.0.1:${PORT} --remote-auth-token-env CODEX_WS_TOKEN -c history_mode="legacy" "\$@"
CONN
        chmod +x ~/codex-connect.sh

        # 3. 确保 codex 可用（创建符号链接如果不存在）
        if ! command -v codex >/dev/null 2>&1; then
            CODEX_BIN=$(ls ~/.vscode-server/extensions/openai.chatgpt-*/bin/*/codex 2>/dev/null | head -1)
            if [ -n "$CODEX_BIN" ]; then
                mkdir -p ~/.local/bin
                ln -sf "$CODEX_BIN" ~/.local/bin/codex
            fi
        fi

        # 4. 验证连通性
        export PATH="$HOME/.local/bin:$PATH"
        VERIFY_RESULT="FAIL"

        # 4a. TCP 端口连通性
        python3 -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    s.settimeout(5)
    s.connect(('127.0.0.1', ${PORT}))
    s.close()
    print('TCP_OK')
except Exception as e:
    print('TCP_FAIL: ' + str(e))
" 2>/dev/null | while read tcp_line; do
            case "$tcp_line" in
                TCP_OK) ;;
                *) echo "  ✗ [$name] TCP 验证失败: $tcp_line" ;;
            esac
        done

        # 4b. HTTP healthz 验证
        HEALTHZ=$(python3 -c "
import urllib.request, sys
try:
    req = urllib.request.Request('http://127.0.0.1:${PORT}/healthz')
    resp = urllib.request.urlopen(req, timeout=5)
    print('HTTP_' + str(resp.status))
    sys.exit(0)
except Exception as e:
    print('HTTP_FAIL: ' + str(e))
    sys.exit(1)
" 2>/dev/null)

        if [ "$HEALTHZ" = "HTTP_200" ]; then
            echo "  ✓ [$name] healthz=200, app-server 可达"
        else
            echo "  ⚠ [$name] healthz 验证: $HEALTHZ"
        fi

        # 4c. codex --version 验证
        CODEX_VER=$(codex --version 2>/dev/null)
        if [ -n "$CODEX_VER" ]; then
            echo "  ✓ [$name] codex 可用: $CODEX_VER"
        else
            echo "  ✗ [$name] codex 不可用"
        fi

        echo "  ✅ [$name] 全部配置完成 (port=${PORT}, token=${TOKEN:0:8}...)"
REMOTE_EOF

    if [ $? -eq 0 ]; then
        echo "  ✓ [$name] 推送+验证完成"
    else
        echo "  ✗ [$name] 推送失败"
        return 1
    fi
}

push_token_to_all() {
    local servers=("$@")
    if [ ${#servers[@]} -eq 0 ]; then
        while IFS= read -r line; do
            servers+=("$line")
        done < <(resolve_servers)
    fi

    if [ ${#servers[@]} -eq 0 ]; then
        return 0
    fi

    echo ">>> 推送 token 到远程服务器..."
    for name in "${servers[@]}"; do
        push_token_to_remote "$name"
    done
    echo ""
}

print_connect_info() {
    local mode="$1"
    shift
    local servers=("$@")
    local token
    token=$(cat "$TOKEN_FILE" 2>/dev/null || echo "<未生成>")

    echo "═══════════════════════════════════════════════════"
    echo "  Codex Local Cloud — 连接信息"
    echo "═══════════════════════════════════════════════════"
    echo ""
    echo "  Server:  ws://127.0.0.1:$PORT"
    echo "  Token:   ${token:0:16}...${token: -8}"
    echo ""

    local running_tns
    running_tns=$(running_tunnels)

    if [ "$mode" = "tunnel" ] && [ -n "$running_tns" ]; then
        # 列出所有隧道已建立的服务器
        while IFS= read -r name; do
            [ -z "$name" ] && continue
            local host user
            host=$(get_server_host "$name")
            user=$(get_server_user "$name")
            [ -z "$user" ] && user="$USER"
            echo "─── $name ($user@$host) ───"
            echo "  远程终端:"
            echo "    export CODEX_WS_TOKEN=$token"
            echo "    codex --remote ws://127.0.0.1:$PORT \\"
            echo "      --remote-auth-token-env CODEX_WS_TOKEN"
            echo "  远程 VSCode:"
            echo '    "codex.remoteAppServer": "ws://127.0.0.1:'"$PORT"'",'
            echo '    "codex.remoteAuthTokenEnv": "CODEX_WS_TOKEN"'
            echo ""
        done <<< "$running_tns"

        # 未建立隧道的服务器
        local all_servers
        all_servers=$(resolve_servers "${servers[@]}")
        while IFS= read -r name; do
            [ -z "$name" ] && continue
            if ! echo "$running_tns" | grep -qx "$name"; then
                echo "─── $name (隧道未建立) ───"
                echo "  直连: ws://$(get_local_ip):$PORT"
                echo ""
            fi
        done <<< "$all_servers"
    else
        local ip
        ip=$(get_local_ip)
        echo "─── 远程直连 ───"
        echo "  export CODEX_WS_TOKEN=$token"
        echo "  codex --remote ws://$ip:$PORT \\"
        echo "    --remote-auth-token-env CODEX_WS_TOKEN"
        echo ""
        echo "  远程 VSCode:"
        echo '    "codex.remoteAppServer": "ws://'"$ip"':'"$PORT"'",'
        echo '    "codex.remoteAuthTokenEnv": "CODEX_WS_TOKEN"'
        echo ""
    fi

    echo "─── 本地终端 ───"
    echo "  export CODEX_WS_TOKEN=$token"
    echo "  codex --remote ws://127.0.0.1:$PORT \\"
    echo "    --remote-auth-token-env CODEX_WS_TOKEN"
    echo ""
}

cmd_stop() {
    # 停止所有隧道
    local stopped_any=0
    for tf in "$TUNNEL_DIR"/tunnel-*.pid; do
        [ -f "$tf" ] || continue
        local name
        name=$(basename "$tf" .pid | sed 's/tunnel-//')
        local pid
        pid=$(cat "$tf" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            echo "✓ [$name] 隧道已停止 (PID $pid)"
            stopped_any=1
        fi
        rm -f "$tf"
    done
    [ "$stopped_any" = "0" ] && echo "  无运行中的隧道"

    # 停止 app-server
    if is_running; then
        kill "$(cat "$PID_FILE")" 2>/dev/null
        rm -f "$PID_FILE"
        sleep 1
        echo "✓ app-server 已停止"
    else
        echo "  app-server 未在运行"
    fi

    # 清理所有端口范围的残留 app-server 进程（8421-8521）
    pkill -f "app-server.*84[0-9][0-9]" 2>/dev/null && echo "✓ 已清理残留 app-server 进程" || true
    pkill -f "app-server.*85[0-9][0-9]" 2>/dev/null || true

    # 确认端口已释放
    for p in 8421 8422 8423 8424 8425 8426 8427 8428 8429 8430; do
        if ! is_port_free "$p"; then
            # 只清理 codex 启动的，不动 VSCode 的
            local stale_pid
            stale_pid=$(lsof -ti :"$p" -sTCP:LISTEN 2>/dev/null | head -1)
            if [ -n "$stale_pid" ]; then
                local cmd
                cmd=$(ps -p "$stale_pid" -o command= 2>/dev/null)
                if echo "$cmd" | grep -q "codex.*app-server" && ! echo "$cmd" | grep -q "code_mode_host"; then
                    kill "$stale_pid" 2>/dev/null && echo "✓ 已清理端口 $p 上的残留进程 (PID $stale_pid)"
                fi
            fi
        fi
    done
}

cmd_status() {
    echo "═══════════════════════════════════════════════════"
    echo "  Codex Local Cloud 状态"
    echo "═══════════════════════════════════════════════════"
    echo ""

    # app-server
    if is_running; then
        local health
        health=$(health_check)
        echo "  app-server:  运行中 (PID $(cat "$PID_FILE"), health=$health)"
        echo "  端口:        $PORT"
        echo "  token:       $(head -c 16 "$TOKEN_FILE" 2>/dev/null)...$(tail -c 8 "$TOKEN_FILE" 2>/dev/null)"
    else
        echo "  app-server:  未运行 ✗"
    fi
    echo ""

    # 配置的服务器
    local all_servers
    all_servers=$(load_servers)
    if [ -n "$all_servers" ]; then
        echo "  已配置的服务器:"
        echo "$all_servers" | while IFS='|' read -r name host user enabled; do
            local status="⚪"
            local ssh_target="${user}@${host}"
            if tunnel_running "$name"; then
                status="🟢 隧道运行中 (PID $(cat "$(tunnel_pid_file "$name")" 2>/dev/null))"
            elif [ "$enabled" = "no" ]; then
                status="⚫ 已禁用"
            else
                status="🔴 未连接"
            fi
            printf "    %-12s %-20s %-16s %s\n" "$name" "$ssh_target" "${enabled:-yes}" "$status"
        done
    else
        echo "  无配置的服务器 (添加: ./codex-local-cloud.sh add <name> <host> [user])"
    fi
    echo ""

    # 活跃会话
    echo "  本地活跃会话:"
    local now_epoch threshold
    now_epoch=$(date +%s)
    threshold=$((now_epoch - 30 * 60))
    discover_local_sessions | while IFS='|' read -r sid rel; do
        [ -z "$sid" ] && continue
        local lf="${CODEX_HOME:-$HOME/.codex}/${rel}"
        local mtime
        mtime=$(stat -f %m "$lf" 2>/dev/null || stat -c %Y "$lf" 2>/dev/null || echo 0)
        [ "$mtime" -lt "$threshold" ] && continue
        local mod_time
        mod_time=$(date -r "$mtime" '+%m-%d %H:%M' 2>/dev/null || echo "?")
        printf "    %-38s %s\n" "$sid" "$mod_time"
    done || echo "    （无活跃会话）"
}

cmd_push_session() {
    local result
    result=$(latest_local_session) || {
        echo "错误: 本地无会话文件"
        return 1
    }
    local sid="${result%%|*}"
    local rel="${result##*|}"
    local local_file="${CODEX_HOME:-$HOME/.codex}/${rel}"

    echo ">>> 推送会话 $sid 到 app-server..."
    echo "  文件: $local_file"

    local codex_home="${CODEX_HOME:-$HOME/.codex}"
    if [ "$codex_home" = "$HOME/.codex" ]; then
        echo "  ✓ 会话已在 ~/.codex/ 中，app-server 可直接访问"
    else
        local target_dir="$HOME/.codex/$(dirname "$rel")"
        mkdir -p "$target_dir"
        cp "$local_file" "$HOME/.codex/${rel}"
        echo "  ✓ 已复制到 ~/.codex/${rel}"
    fi

    python3 "$SCRIPT_DIR/codex-thread-register.py" \
        "$local_file" \
        "${CODEX_HOME:-$HOME/.codex}/state_5.sqlite" 2>&1 || true

    echo ""
    echo "✓ 会话已就绪，可通过 app-server resume"
    echo "  codex --remote ws://127.0.0.1:$PORT resume $sid"
}

cmd_logs() {
    if [ -f "$LOG_FILE" ]; then
        tail -f "$LOG_FILE"
    else
        echo "日志文件不存在: $LOG_FILE"
    fi
}

# --- 服务器管理命令 ---

cmd_add() {
    local name="$1" host="$2" user="${3:-}"
    [ -z "$name" ] || [ -z "$host" ] && {
        echo "用法: $0 add <name> <host> [user]"
        echo "示例: $0 add dev-vm <REMOTE_HOST> <USER>"
        return 1
    }

    # 检查是否已存在
    if [ -n "$(server_exists "$name")" ]; then
        echo "✗ 服务器 '$name' 已存在"
        echo "  如需修改请先 remove 再 add"
        return 1
    fi

    # 确保配置文件存在
    touch "$SERVERS_FILE"

    echo "${name}|${host}|${user}|yes" >> "$SERVERS_FILE"
    echo "✓ 已添加服务器 '$name'"
    echo "  名称:   $name"
    echo "  地址:   $host"
    echo "  用户:   ${user:-（默认 $USER）}"
    echo "  配置:   $SERVERS_FILE"
}

cmd_remove() {
    local name="$1"
    [ -z "$name" ] && {
        echo "用法: $0 remove <name>"
        return 1
    }

    if [ -z "$(server_exists "$name")" ]; then
        echo "✗ 服务器 '$name' 不存在"
        return 1
    fi

    # 停止该服务器的隧道
    local tf
    tf=$(tunnel_pid_file "$name")
    if [ -f "$tf" ]; then
        local pid
        pid=$(cat "$tf" 2>/dev/null)
        kill "$pid" 2>/dev/null || true
        rm -f "$tf"
    fi

    # 从配置文件中删除
    local tmp
    tmp=$(mktemp)
    grep -v "^${name}|" "$SERVERS_FILE" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$SERVERS_FILE"
    echo "✓ 已移除服务器 '$name'"
}

cmd_list() {
    local servers
    servers=$(load_servers)
    if [ -z "$servers" ]; then
        echo "未配置任何服务器"
        echo "添加: ./codex-local-cloud.sh add <name> <host> [user]"
        echo "配置文件: $SERVERS_FILE"
        return 0
    fi

    echo "已配置的服务器 (配置: $SERVERS_FILE)"
    echo ""
    printf "  %-12s %-24s %-16s %-8s %s\n" "名称" "地址" "用户" "状态" "隧道"
    echo "  ──────────── ──────────────────────── ──────────────── ──────── ──────────"

    echo "$servers" | while IFS='|' read -r name host user enabled; do
        local status="启用"
        [ "$enabled" = "no" ] && status="禁用"

        local tunnel_status="未连接"
        if tunnel_running "$name"; then
            tunnel_status="🟢 运行中"
        fi

        printf "  %-12s %-24s %-16s %-8s %s\n" "$name" "$host" "${user:-默认}" "$status" "$tunnel_status"
    done
}

# --- 入口 ---

case "${1:-status}" in
    start)
        cmd_start "${2:-tunnel}" "${@:3}"
        ;;
    stop)
        cmd_stop
        ;;
    status)
        cmd_status
        ;;
    connect)
        local_mode="tunnel"
        [ -z "$(running_tunnels)" ] && local_mode="direct"
        if [ "${2:-}" = "direct" ]; then local_mode="direct"; fi
        shift || true
        is_running && print_connect_info "$local_mode" "${@:1}" || echo "app-server 未运行，请先: ./codex-local-cloud.sh start"
        ;;
    push-session)
        cmd_push_session
        ;;
    logs)
        cmd_logs
        ;;
    restart)
        cmd_stop
        sleep 1
        shift || true
        cmd_start "${1:-tunnel}" "${@:2}"
        ;;
    add)
        cmd_add "${2:-}" "${3:-}" "${4:-}"
        ;;
    remove)
        cmd_remove "${2:-}"
        ;;
    list|servers)
        cmd_list
        ;;
    *)
        echo "Codex Local Cloud — 把本地 Mac 当作 Codex 云服务器（多服务器版）"
        echo ""
        echo "用法: $0 <命令> [参数]"
        echo ""
        echo "命令:"
        echo "  start [tunnel|direct] [server...]   启动 app-server (默认 tunnel, 连所有服务器)"
        echo "                                      指定 server 只连特定服务器"
        echo "  stop                                停止 app-server 和所有隧道"
        echo "  status                              查看运行状态和所有服务器"
        echo "  connect [direct] [server...]        打印连接信息"
        echo "  push-session                        推送本地最新会话到 app-server"
        echo "  logs                                查看 app-server 日志 (tail -f)"
        echo "  restart [tunnel|direct] [server...] 重启"
        echo ""
        echo "服务器管理:"
        echo "  add <name> <host> [user]           添加远程服务器"
        echo "  remove <name>                       移除远程服务器"
        echo "  list                                列出已配置的服务器"
        echo ""
        echo "模式:"
        echo "  tunnel  SSH 反向隧道: 远程 127.0.0.1:PORT → 本地 app-server"
        echo "  direct  远程直连: ws://<本机IP>:PORT"
        echo ""
        echo "配置文件: $SERVERS_FILE"
        echo "  格式: name|host|user|enabled"
        echo "  示例: dev-vm|<REMOTE_HOST>|<USER>|yes"
        echo ""
        echo "环境变量:"
        echo "  CODEX_CLOUD_PORT       端口 (默认 8421)"
        echo "  CODEX_CLOUD_BIN         codex 路径 (默认 codex)"
        echo "  CODEX_CLOUD_SERVERS     服务器配置文件路径"
        exit 1
        ;;
esac
