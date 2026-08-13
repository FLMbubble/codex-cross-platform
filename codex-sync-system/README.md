# Codex 同步守护（launchd 版）

这是 launchd 服务版的同步守护进程，安装后开机自启、崩溃自动重启。

完整文档见项目根目录 [README.md](../README.md)。

## 安装

```bash
cd ~/Documents/project/codex-cross-platform/codex-sync-system
./codex-sync-daemon.sh install
```

## 命令

```bash
./codex-sync-daemon.sh install      # 安装 launchd 服务
./codex-sync-daemon.sh uninstall    # 卸载
./codex-sync-daemon.sh status       # 查看状态
./codex-sync-daemon.sh once         # 单次同步
```

日志：`tail -f ~/.codex/sync-daemon.log`
