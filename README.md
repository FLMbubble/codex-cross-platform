# Codex 三端同步系统

本地 Mac ↔ 远程服务器的 Codex session 自动同步。支持多会话、增量同步、三方合并，确保远程 `codex resume` 能找到并恢复同步的会话。

## 架构

```
本地 Mac（同步中心）
├── Chrome 扩展（网页交互）         ─┐
├── Codex CLI（本地终端）           ─┤ 原生共享 ~/.codex/
│                                    ─┘ 无需配置
│
│  守护进程自动同步（活跃会话，增量推送）
│
远程服务器
└── VSCode Codex 扩展（远程代码）  ──→ ~/.codex/ on 远程（镜像）
```

**本地 Chrome 扩展和 Codex CLI 天然共享 `~/.codex/`**，无需同步。唯一需要同步的是 **本地 ↔ 远程**。

## 前置条件

### SSH 免密登录（必须）

所有同步操作通过 SSH 完成，且使用 `BatchMode=yes`（禁止交互式密码输入），因此**必须配置免密登录**，否则同步会直接失败。

检查是否已配置：

```bash
ssh -o BatchMode=yes <远程地址> 'echo OK'
```

如果输出 `OK` 则已配置。如果报 `Permission denied`，按以下步骤配置：

```bash
# 1. 生成密钥（已有可跳过）
ssh-keygen -t rsa -b 4096

# 2. 推送公钥到远程
ssh-copy-id Jshen@<远程地址>

# 3. 配置 ~/.ssh/config（推荐，简化命令）
cat >> ~/.ssh/config << CFG
Host <远程地址>
  HostName <远程地址>
  User Jshen
CFG

# 4. 验证
ssh -o BatchMode=yes <远程地址> 'echo OK'
```

### 远程环境

远程服务器**无需安装本项目**，只需要：
- SSH 免密可达
- 有 `python3`
- 有 `~/.codex/` 目录（codex 已安装即有）

## 配置

远程地址等通过环境变量配置，默认值在 `codex-sync-common.sh` 中定义：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CODEX_SYNC_REMOTE` | `172.29.102.24` | 远程服务器地址 |
| `CODEX_SYNC_ACTIVE_MINUTES` | `30` | 活跃会话时间窗口（分钟） |
| `CODEX_SYNC_INTERVAL` | `5` | 守护进程轮询间隔（秒） |
| `CODEX_SYNC_LOG_FILE` | `/tmp/codex-auto-sync.log` | 日志文件路径 |

切换远程服务器：

```bash
# 临时切换
CODEX_SYNC_REMOTE=192.168.1.100 ./codex-auto-sync.sh once

# 永久切换（写入 shell 配置）
export CODEX_SYNC_REMOTE=192.168.1.100
```

## 核心特性

- **动态会话发现**：自动扫描 `~/.codex/sessions/`，无需手动指定 session ID
- **活跃会话过滤**：只同步最近 30 分钟内修改的会话，避免全量推送浪费时间
- **增量同步**：通过记录同步时间与文件修改时间对比，本地无修改时零 SSH 开销跳过
- **三方合并**：本地和远程同时有新内容时自动合并，不丢失任何一端的对话
- **SSH 超时保护**：所有远程操作有超时包裹，网络异常不会卡死守护进程
- **正确的 thread 注册**：从 rollout 文件提取 `preview`/`model_provider`/`cwd` 等元数据，确保 `codex resume` picker 能发现会话

## 快速开始

```bash
cd ~/Documents/project/codex-cross-platform

# 查看活跃会话状态（秒出，不连远程）
./codex-auto-sync.sh status

# 同步活跃会话到远程
./codex-auto-sync.sh once

# 启动守护进程持续自动同步（10 秒轮询）
./codex-auto-sync.sh start 10

# 停止守护
./codex-auto-sync.sh stop
```

## 命令参考

### codex-auto-sync.sh — 守护进程

| 命令 | 说明 |
|------|------|
| `start [秒]` | 启动后台守护进程，默认 10 秒轮询一次 |
| `stop` | 停止守护进程 |
| `status` | 查看守护状态 + 活跃会话的修改时间/同步时间（纯本地，秒出） |
| `once` | 同步活跃会话（最近 30 分钟修改的），执行一次后退出 |
| `once-all` | 全量同步所有会话（首次使用或需要补推历史会话时用） |

### codex-session-sync.sh — 单会话操作

| 命令 | 说明 |
|------|------|
| `list` | 列出所有本地会话（ID、大小、cwd、provider） |
| `push [ID]` | 推送会话到远程并注册 thread（默认用最新会话） |
| `pull [ID]` | 从远程拉取到本地 |
| `sync [ID]` | 比较哈希，不同时提示选择方向 |
| `status [ID]` | 查看单个会话的同步状态 |

### codex-sync-daemon.sh — launchd 服务（开机自启）

```bash
cd codex-sync-system

./codex-sync-daemon.sh install      # 安装为 macOS launchd 服务
./codex-sync-daemon.sh status       # 查看状态
./codex-sync-daemon.sh once         # 单次同步
./codex-sync-daemon.sh uninstall    # 卸载
```

日志：`tail -f ~/.codex/sync-daemon.log`

## 同步状态存储

同步状态存储在项目目录下的 `sync-state/`，不污染 `~/.codex`：

```
sync-state/
  <session_id>/
    sync_time      ← 上次成功推送的 Unix 时间戳
    local_md5      ← 上次推送时的本地文件 md5
```

同步决策逻辑：
- 文件修改时间 (mtime) > sync_time → 本地有新修改，需要推送
- mtime ≤ sync_time → 已同步，跳过（不发起任何 SSH）

`status` 命令显示效果：
```
活跃会话 (最近30分钟):
  019fcc4a-...  修改=08-12 17:10  同步于 08-12 17:12  ✓
  019ff4e5-...  修改=08-12 18:00  未同步              ⚠ 待推送
```

## 文件说明

| 文件 | 作用 |
|------|------|
| `codex-sync-common.sh` | 共享函数库（会话发现、路径提取、SSH 超时、远程地址配置） |
| `codex-thread-register.py` | 从 rollout 提取元数据并注册 thread（修复 preview/provider/cwd） |
| `codex-session-sync.sh` | 手动单会话操作（push/pull/sync/status/list） |
| `codex-auto-sync.sh` | 多会话守护进程（活跃过滤、增量同步、三方合并） |
| `codex-merge.py` | 三方合并逻辑（找共同前缀，合并两端新增内容） |
| `codex-sync-system/codex-sync-daemon.sh` | launchd 守护进程（开机自启 + 崩溃重启） |
| `codex-sync-system/codex-sync-merge.py` | 三方合并逻辑（daemon 版） |
| `codex-cloud-server.sh` | 远程 app-server 模式（可选，用 WebSocket 实时同步） |

## 已解决的问题

**`codex resume` 在远程找不到会话** — 旧脚本注册 thread 时 `preview` 为空且 `model_provider` 硬编码为 `custom`，导致被 resume picker 的 `WHERE preview <> '' AND model_provider IN (...)` 过滤掉。现从 rollout 文件正确提取所有元数据。

**守护进程被单会话失败杀死** — 移除 `set -e`，单个会话同步失败不影响其他会话。

**SSH 卡死导致守护进程无响应** — 所有 SSH/scp 调用用 `run_timeout` 包裹（纯 bash 实现，不依赖 `timeout` 命令）。

**全量同步太慢** — 改为只同步活跃会话（最近修改的），通过 sync_time vs mtime 对比跳过无变化的会话。

**远程目录不存在导致 scp 失败** — `ensure_remote_dir` 修正路径，自动创建 `~/.codex/sessions/` 子目录。
