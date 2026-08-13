#!/bin/bash
# codex-cloud-server.sh — 把远程服务器当作 Codex "云端"，本地和远程都连同一个 app-server
#
# 架构:
#   远程 $REMOTE_HOST  ←  codex app-server (ws://0.0.0.0:8419)
#       ↑                          ↑
#       │ 本地直连                  │ 本机直连
#       │                          │
#   本地 Chrome 扩展            远程 VSCode Codex 扩展
#   (codex --remote ws://...)   (codex --remote ws://127.0.0.1:8419)
#
# 两端共享同一个 session，对话内容实时同步。
#
# 用法:
#   ./codex-cloud-server.sh start     # 在远程启动 app-server
#   ./codex-cloud-server.sh stop      # 停止远程 app-server
#   ./codex-cloud-server.sh status    # 查看运行状态和连接信息
#   ./codex-cloud-server.sh connect   # 打印本地连接命令
#   ./codex-cloud-server.sh sync-session  # 把本地当前 session 推到远程 app-server

source "$(cd "$(dirname "$0")" && pwd)/codex-sync-common.sh"
REMOTE_USER="Jshen"
PORT=8419
SESSION_ID="019fc76e-3949-7ab1-a96d-621151461c6b"
SESSION_REL="sessions/2026/08/03/rollout-2026-08-03T19-41-57-${SESSION_ID}.jsonl"

case "${1:-status}" in
  start)
    echo ">>> Starting app-server on remote..."
    ssh "$REMOTE_HOST" 'export PATH=$HOME/.local/bin:$PATH
      # 如果已在运行则跳过
      if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:'"$PORT"'/healthz 2>/dev/null | grep -q 200; then
        echo "  app-server already running"
      else
        # 生成 token
        TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(32))")
        echo "$TOKEN" > ~/.codex/ws-token
        chmod 600 ~/.codex/ws-token

        # 同步 session 文件（如果不存在）
        mkdir -p ~/.codex/sessions/2026/08/03/

        nohup codex app-server \
          --listen "ws://0.0.0.0:'"$PORT"'" \
          --ws-auth capability-token \
          --ws-token-file ~/.codex/ws-token \
          > ~/.codex/app-server.log 2>&1 &
        echo $! > ~/.codex/app-server.pid
        sleep 3
        echo "  started, PID=$(cat ~/.codex/app-server.pid)"
      fi
      echo "  health: $(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:'"$PORT"'/healthz)"
      echo "  token:  $(cat ~/.codex/ws-token)"
    '
    echo ""
    echo "✓ app-server running on $REMOTE_HOST:$PORT"
    echo ""
    echo "$0 connect"
    ;;
  stop)
    echo ">>> Stopping app-server on remote..."
    ssh "$REMOTE_HOST" '
      PID=$(cat ~/.codex/app-server.pid 2>/dev/null)
      if [ -n "$PID" ]; then
        kill $PID 2>/dev/null && echo "  stopped PID=$PID"
        rm -f ~/.codex/app-server.pid
      else
        pkill -f "app-server.*8419" 2>/dev/null && echo "  stopped" || echo "  not running"
      fi
    '
    ;;
  status)
    echo "=== Remote app-server ==="
    ssh "$REMOTE_HOST" 'curl -s -o /dev/null -w "  health: %{http_code}\n" http://127.0.0.1:'"$PORT"'/healthz 2>/dev/null || echo "  status: DOWN"'
    echo "=== Local → Remote ==="
    curl -s -o /dev/null -w "  health: %{http_code}\n" --max-time 5 http://"$REMOTE_HOST":"$PORT"/healthz 2>/dev/null || echo "  status: UNREACHABLE"
    echo "=== Token ==="
    ssh "$REMOTE_HOST" 'echo "  token: $(cat ~/.codex/ws-token 2>/dev/null || echo none)"'
    ;;
  connect)
    TOKEN=$(ssh "$REMOTE_HOST" 'cat ~/.codex/ws-token 2>/dev/null')
    echo "═══════════════════════════════════════════════════"
    echo "  Codex Cloud Server Connection Info"
    echo "═══════════════════════════════════════════════════"
    echo ""
    echo "  Server:  ws://$REMOTE_HOST:$PORT"
    echo "  Token:   $TOKEN"
    echo "  Session: $SESSION_ID"
    echo ""
    echo "─── 远程 VSCode 终端 ───"
    echo "  export CODEX_WS_TOKEN=$TOKEN"
    echo "  codex --remote ws://127.0.0.1:$PORT --remote-auth-token-env CODEX_WS_TOKEN \\"
    echo "    resume $SESSION_ID"
    echo ""
    echo "─── 本地终端 ───"
    echo "  export CODEX_WS_TOKEN=$TOKEN"
    echo "  codex --remote ws://$REMOTE_HOST:$PORT --remote-auth-token-env CODEX_WS_TOKEN \\"
    echo "    resume $SESSION_ID"
    echo ""
    echo "─── 远程 VSCode Codex 扩展设置 ───"
    echo "  在 VSCode settings.json 中添加:"
    echo '  "codex.remoteAppServer": "ws://127.0.0.1:'"$PORT"'",'
    echo '  "codex.remoteAuthTokenEnv": "CODEX_WS_TOKEN"'
    echo ""
    ;;
  sync-session)
    echo ">>> Pushing local session to remote..."
    /Users/didi/Documents/Codex/2026-08-03/du-q/outputs/codex-session-sync.sh push
    ;;
  *)
    echo "Usage: $0 {start|stop|status|connect|sync-session}"
    exit 1
    ;;
esac
