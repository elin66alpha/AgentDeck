# 后端安装

[English](README.md) · [生产部署手册](../docs/handbook.md#production-deployment)

Relay 在所有后端操作系统上使用同一个 Node.js 服务和同一套 HTTP/SSE API。本目录的
脚本只负责各平台的依赖安装、进程管理、日志和可选 Cloudflare Tunnel。

## 前置要求

- Node.js 18 或更新版本。
- 后端至少安装一个支持的 CLI：Claude Code、Codex、Antigravity（`agy`）、
  OpenCode 或 Hermes。
- CLI 需要在后端主机上完成认证。当主机提供兼容的 `script` PTY 工具时，Relay 可以
  为 Claude、Codex 和 Agy 中转 OAuth 登录；OpenCode 和 Hermes 的密钥仍在主机管理。
- 只有正式 Cloudflare Tunnel 或 Quick Tunnel 模式需要 `cloudflared`。

## 安装

在仓库根目录运行一个命令：

| 后端系统 | 命令 | 服务管理 |
|---|---|---|
| Linux | `./backends/linux/setup.sh` | PM2 |
| macOS | `./backends/macos/setup.sh` | 当前用户 LaunchAgent |
| Windows | `.\backends\windows\setup.ps1` | 当前用户计划任务 |

安装脚本会按需创建 `server/.env`、安装服务端依赖、配置网络模式、启动服务并生成加密
凭证。然后在 app 中导入生成的 `.relay.png` 或 `.relay.json`，输入生成时设置的密码。

### 网络模式

1. **直连：** 使用自己可访问的地址。服务会绑定 `0.0.0.0`；公开暴露前必须在前面
   配置 HTTPS。
2. **正式 Cloudflare Tunnel：** 使用 Cloudflare zone 下的稳定域名，服务保持绑定
   `127.0.0.1`。
3. **Cloudflare Quick Tunnel：** 适合试用。重启后 `trycloudflare.com` 地址可能变化，
   地址变化时需要重新生成并导入凭证。

## 服务管理

### Linux

```bash
./backends/linux/status.sh
./backends/linux/start.sh
./backends/linux/stop.sh
./backends/linux/uninstall.sh
```

这些脚本封装 PM2，也可以继续直接使用 PM2 命令：

```bash
pm2 list
pm2 logs relay-server
pm2 restart relay-server --update-env
pm2 logs relay-tunnel
```

Linux 安装需要 PM2（`npm install -g pm2`）。进程名为 `relay-server`；隧道模式还会创建
`relay-tunnel`。日志位于 `~/.pm2/logs/`，文件名为 `relay-server-*.log` 和
`relay-tunnel-*.log`。`uninstall.sh` 只删除 PM2 进程，保留后端数据、令牌和凭证。
交互终端的 PTY 依赖会在 Linux 上本地编译，因此首次安装还需要 Python 3、
`make` 和 C++ 编译器（Debian/Ubuntu 可安装 `build-essential`）。

### macOS

```bash
./backends/macos/status.sh
./backends/macos/start.sh
./backends/macos/stop.sh
./backends/macos/uninstall.sh
```

LaunchAgent 位于 `~/Library/LaunchAgents`。日志在 `~/Library/Logs/Relay/` 下，文件名为
`backend.*.log` 和 `tunnel.*.log`。生成的服务 PATH 已包含常见 Homebrew 和用户 bin 路径。

### Windows

```powershell
.\backends\windows\status.ps1
.\backends\windows\start.ps1
.\backends\windows\stop.ps1
.\backends\windows\uninstall.ps1
```

日志和 PID 文件位于 `%LOCALAPPDATA%\Relay\logs\` 与
`%LOCALAPPDATA%\Relay\runtime\`。如果 PowerShell 阻止脚本执行，只为当前会话临时放开：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## 手动启动

开发或排障时可以绕过平台服务脚本：

```bash
cd server
npm install
cp .env.example .env
npm start
```

再用 `npm run credential` 单独生成凭证。配置项见 `server/.env.example`，生产加固见技术手册。
