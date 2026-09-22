# Codex Cross-Platform — 本地云 + 多端会话同步

把本地 Mac 当作 Codex "云端" app-server，远程服务器的 Codex 会话通过 SSH 隧道走本地 API；同时支持 rollout 文件级别的增量同步，确保多端 `codex resume` 可互相恢复会话。

## 架构

```
本地 Mac（云服务器）
├── codex app-server (ws://0.0.0.0:8421)
├── Chrome 扩展 / CLI（直连 127.0.0.1:8421）
│
│  SSH 反向隧道 (-R 8421:127.0.0.1:8421)  × N 台远程
│
远程服务器 A          远程服务器 B
├── VSCode 扩展       ├── Codex CLI
└── Codex CLI         └── (会话存储在本地 ~/.codex/)
```

**两种同步模式可独立或组合使用：**

| 模式 | 脚本 | 原理 | 适用场景 |
|------|------|------|----------|
| 本地云 | `codex-local-cloud.sh` | WebSocket 常连接，远程 codex 走隧道调用本地 app-server | 实时会话，远程无需配 API key |
| 文件同步 | `codex-auto-sync.sh` | 增量推送/拉取 rollout 文件 + thread 注册 | 离线同步，历史会话迁移 |

## 前置条件

### SSH 免密登录（必须）

所有远程操作使用 `BatchMode=yes`，必须配置免密登录：

```bash
ssh -o BatchMode=yes <user>@<host> 'echo OK'
# 输出 OK 则已配置，否则：
ssh-copy-id <user>@<host>
```

### 远程环境

远程服务器只需：SSH 可达 + `python3` + 已安装 Codex CLI。

---

## 一、添加需要同步的远端服务器

### 方式 A：命令行添加

```bash
cd ~/Documents/project/codex-cross-platform

# 添加服务器（名称 | 地址 | 用户名）
./codex-local-cloud.sh add dev-vm 172.29.102.24 Jshen
./codex-local-cloud.sh add luban 10.152.52.7 luban

# 列出已配置的服务器
./codex-local-cloud.sh list

# 移除
./codex-local-cloud.sh remove dev-vm
```

### 方式 B：直接编辑配置文件

配置文件 `codex-cloud-servers.conf`，每行一个服务器：

```
# 格式: name|host|user|enabled
#   enabled: yes/no（no 时不会被自动连接）
dev-vm|172.29.102.24|Jshen|yes
luban|10.152.52.7|luban|yes
laptop|192.168.1.100||no
```

---

## 二、让远端 Codex 会话走端口转发调用本地 API

### 启动本地 app-server + 隧道

```bash
cd ~/Documents/project/codex-cross-platform

# 启动：自动启动 app-server + 连接所有启用的服务器
./codex-local-cloud.sh start

# 只连接指定服务器
./codex-local-cloud.sh start tunnel luban

# 查看状态
./codex-local-cloud.sh status

# 查看连接信息
./codex-local-cloud.sh connect

# 停止
./codex-local-cloud.sh stop
```

脚本会自动完成：
1. 在本地启动 `codex app-server`（自动选择空闲端口 8421-8521）
2. 建立 SSH 反向隧道（远程 `127.0.0.1:8421` → 本地 app-server）
3. 推送 token 和端口到远程，生成 `~/codex-connect.sh`
4. 验证远程 healthz=200 和 codex 可用性

### 在远程服务器上连接

脚本自动在远程生成 `~/codex-connect.sh`，直接运行即可：

```bash
# 在远程服务器上
bash ~/codex-connect.sh
```

该脚本内容为：
```bash
#!/bin/bash
export PATH="$HOME/.local/bin:$PATH"
export CODEX_WS_TOKEN=<token>
exec codex --remote ws://127.0.0.1:<port> \
  --remote-auth-token-env CODEX_WS_TOKEN \
  -c history_mode="legacy" "$@"
```

### 在远程 VSCode 中使用

脚本会自动在远程 `~/.codex/config.toml` 中设置 `history_mode = "legacy"`。
在 VSCode `settings.json` 中添加：

```json
{
  "codex.remoteAppServer": "ws://127.0.0.1:8421",
  "codex.remoteAuthTokenEnv": "CODEX_WS_TOKEN"
}
```

端口需与本地 `codex-local-cloud.sh` 输出一致（脚本会自动推送实际端口）。

### 工作原理

- 远程 codex 客户端通过 SSH 隧道连接本地 app-server
- 所有模型请求由本地 app-server 处理（使用本地 API key / ChatGPT 登录）
- 会话数据存储在本地 `~/.codex/` 中
- 远程无需配置任何 API key 或 model provider

---

## 三、同步更新多端会话内容（文件同步模式）

当需要离线同步历史会话（而非实时连接）时，使用文件同步模式。

### 手动单会话操作

```bash
# 列出所有本地会话
./codex-session-sync.sh list

# 推送最新会话到远程
./codex-session-sync.sh push

# 推送指定会话
./codex-session-sync.sh push <session-id>

# 从远程拉取
./codex-session-sync.sh pull <session-id>

# 比较内容差异
./codex-session-sync.sh sync <session-id>
```

### 自动守护进程（增量同步）

```bash
# 单次同步活跃会话（最近 30 分钟修改的）
./codex-auto-sync.sh once

# 全量同步所有会话
./codex-auto-sync.sh once-all

# 启动守护进程（10 秒轮询）
./codex-auto-sync.sh start 10

# 停止
./codex-auto-sync.sh stop

# 查看状态
./codex-auto-sync.sh status
```

### 开机自启（launchd）

```bash
cd codex-sync-system
./codex-sync-daemon.sh install      # 安装为 macOS launchd 服务
./codex-sync-daemon.sh status       # 查看状态
./codex-sync-daemon.sh once         # 单次同步
./codex-sync-daemon.sh uninstall    # 卸载
```

日志：`tail -f ~/.codex/sync-daemon.log`

### 同步状态

同步状态存储在 `sync-state/`（不污染 `~/.codex`）：

```
sync-state/
  <session_id>/
    sync_time      ← 上次成功同步的 Unix 时间戳
    local_md5      ← 上次同步时的本地文件 md5
```

同步决策：文件修改时间 > sync_time → 需要推送；否则跳过（零 SSH 开销）。

---

## 文件说明

| 文件 | 作用 |
|------|------|
| `codex-local-cloud.sh` | 本地云模式：启动 app-server + SSH 隧道 + 多服务器管理 |
| `codex-sync-common.sh` | 共享函数库（会话发现、路径提取、SSH 超时） |
| `codex-session-sync.sh` | 手动单会话操作（push/pull/sync/status/list） |
| `codex-auto-sync.sh` | 自动守护进程（活跃过滤、增量同步、三方合并） |
| `codex-thread-register.py` | 从 rollout 提取元数据注册 thread（修复 `codex resume` 可见性） |
| `codex-merge.py` | 三方合并逻辑（找共同前缀，合并两端新增内容） |
| `codex-sync-system/` | launchd 守护进程（开机自启 + 崩溃重启） |
| `codex-cloud-servers.conf` | 远程服务器配置文件 |

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CODEX_CLOUD_PORT` | `8421` | app-server 起始端口 |
| `CODEX_CLOUD_BIN` | 自动检测 | codex 二进制路径 |
| `CODEX_CLOUD_SERVERS` | `<脚本目录>/codex-cloud-servers.conf` | 服务器配置文件 |
| `CODEX_SYNC_REMOTE` | `172.29.102.24` | 文件同步模式的远程地址 |
| `CODEX_SYNC_ACTIVE_MINUTES` | `30` | 活跃会话时间窗口（分钟） |
| `CODEX_SYNC_INTERVAL` | `5` | 守护进程轮询间隔（秒） |

## 已知问题

- **paginated_threads 不兼容**：本地 app-server 版本需 ≥ 远程客户端版本，否则 thread store 不支持 `paginated_threads` 操作。脚本通过 `experimental_thread_store="local"` + `history_mode="legacy"` 配置缓解。
- **VSCode 占用端口**：VSCode Codex 扩展可能占用 8421 端口，脚本自动切换到下一个空闲端口。
- **沙箱限制**：在 Codex 沙箱内启动的 app-server 会在 exec 结束后被终止，需在独立终端运行 `./codex-local-cloud.sh start`。
