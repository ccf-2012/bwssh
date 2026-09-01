# bwssh — Bitwarden CLI SSH 管理工具

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25.svg)](https://www.gnu.org/software/bash/)
[![Bitwarden](https://img.shields.io/badge/Bitwarden-CLI-175DDC.svg)](https://bitwarden.com)

**中文** | [**English**](README_en.md)

---

通过调用 Bitwarden CLI 管理 SSH 登录，一条 `bwssh` 命令从密码库取出主机名、用户名、**SSH 私钥或密码**并完成自动登录，**无需本地 Desktop App，无需维护 `~/.ssh/config`，跨机器开箱即用**。

---

## 特性

- 🔑 **支持私钥与密码登录**：优先私钥登录，无私钥时自动填充密码。
- 🔍 **条目识别**：支持按文件夹隔离（默认 `SSH` 文件夹），也支持按私钥、`ssh://` URI、自定义端口字段混合自动识别。
- 🚀 **快速响应**：基于 `bw serve` 本地轻量缓存与后台 API。
- 🛡️ **内存与会话安全**：凭据与临时 Key / AskPass 脚本均严格隔离，连接结束即刻自动销毁清理。

---

## 依赖

| 工具 | 用途 | 安装 |
|---|---|---|
| `bw` | Bitwarden CLI | `brew install bitwarden-cli` / `npm i -g @bitwarden/cli` |
| `jq` | JSON 解析 | `brew install jq` / `apt install jq` |
| `fzf` | 交互式模糊选择| `brew install fzf` / `apt install fzf` |


---

## 安装

#### 1. 下载脚本并赋予权限

```bash
mkdir -p ~/.local/bin && curl -fsSL https://raw.githubusercontent.com/ccf-2012/bwssh/main/bwssh.sh -o ~/.local/bin/bwssh && chmod +x ~/.local/bin/bwssh
```

#### 2. 加入环境变量，确保路径在 PATH 中（加入 ~/.zshrc 或 ~/.bashrc）
```sh 
export PATH="$HOME/.local/bin:$PATH"
```

---

## 在 Bitwarden 中存储 SSH 条目

为服务器创建一个 **Login** 类型条目，字段约定如下：

| Bitwarden 字段 | 填写内容 | 说明 / 示例 |
|---|---|---|
| **Folder** | 文件夹（推荐） | `SSH`（默认推荐归类至 `SSH` 文件夹） |
| **Name** | 服务器别名（用于搜索） | `prod-web-01` |
| **Username** | SSH 登录用户名 | `ubuntu` / `root` |
| **Password** | SSH 登录密码（可选） | 密码认证时填写；若有私钥则优先使用私钥 |
| **URI** | 主机 IP 或域名 | `10.0.0.1` / `myserver.com` / `ssh://10.0.0.1:2222` |
| **Notes** | SSH 私钥全文（PEM 格式，可选） | `-----BEGIN OPENSSH PRIVATE KEY-----` … |
| Custom Field `port` | SSH 端口（可选） | `2222`（非 22 且 URI 中未带端口时填写） |

> [!TIP]
> - **私钥登录**：直接将私钥全文粘贴到 **Notes** 字段。
> - **密码登录**：填写 **Password** 字段，Notes 留空即可。
> - **URI 格式**：支持标准 IP/域名（`10.0.0.1`）或协议 URI（`ssh://user@10.0.0.1:2222`），脚本会自动提取并解析。

### SSH 条目识别规则

`bwssh` 在执行 `--list`、交互选择或搜索时，会按以下特征自动匹配 SSH 条目：
1. 条目属于 `BWSSH_FOLDER` 文件夹（默认为 `SSH` 文件夹）；
2. **或** 条目的 **Notes** 包含 `PRIVATE KEY`；
3. **或** 条目的 **URI** 以 `ssh://` 开头；
4. **或** 条目包含名为 `port` 或 `ssh` 的自定义字段。

> 如需更换默认文件夹名称，可在 shell 配置文件中设置：
> ```bash
> export BWSSH_FOLDER="Servers"   # 写入 ~/.zshrc
> ```

---

## 使用方法

### 直接按名称连接（最常用）

```bash
bwssh prod-web-01
```

脚本会自动从 Bitwarden 取出该条目的 Host、Username、私钥/密码，建立连接。

### 直接执行远程命令

```bash
bwssh prod-web-01 "uptime && uname -a"
```

### 仅将私钥注入到 ssh-agent（不直接连接）

```bash
bwssh --add-key prod-web-01
# 或简写
bwssh -k prod-web-01
```

### 交互式选择（需要 fzf）

```bash
bwssh
```

列出所有满足条件的 SSH 条目，通过 fzf 模糊搜索选择目标服务器：

```
🔐 SSH > prod
  prod-web-01                  ubuntu       10.0.0.1             [key]
  prod-db-01                   postgres     10.0.0.2             [pass]
  prod-redis                   root         10.0.0.3             [key]
```

### 列出所有 SSH 条目

```bash
bwssh --list
# 或
bwssh -l
```

输出示例：

```
NAME                         USER         HOST                   AUTH
────────────────────────────────────────────────────────────────────────
prod-web-01                  ubuntu       10.0.0.1               [key]
prod-db-01                   postgres     10.0.0.2               [pass]
staging-api                  deploy       staging.myapp.com      [key]
```


### 同步云端最新数据（密码/条目变更时刷新）

当你在 Bitwarden 网页端或 App 新增、修改了服务器密码或 Key 时，直接执行同步命令：

```bash
bwssh --sync
# 或简写
bwssh -s
```

> ⚡ **无缝同步**：直接通过后台服务的 REST API 在内存中热更新最新条目，无需重启服务。

### 停止本地后台服务

```bash
bwssh --stop
```

---

## Session 管理

### 工作机制

```
首次运行
  ↓ 输入 Master Password
  ↓ 获取 BW_SESSION Token
  ↓ 写入 ~/.bw_session（权限 600）

后续运行
  ↓ 读取 ~/.bw_session
  ↓ 校验 Token 是否有效
  ↓ 有效 → 直接使用，无需输密码
     失效 → 重新 unlock
```

### Session Token 有效期

Bitwarden 默认 session **15 分钟无操作后过期**。可在 Bitwarden 网页后台调整：
**Settings → Security → Session timeout**

### 跨终端共享与原生 `bw` 命令联动

由于 Bitwarden 官方 CLI 默认不跨终端持久化 Session，`bwssh` 使用 `~/.bw_session`（权限 600）维护有效会话。

为了让系统里的所有原生 `bw` 命令（`bw list`、`bw get` 等）以及新开终端**自动共享该 Session**，只需在 `~/.zshrc`（或 `~/.bashrc`）中加入：

```bash
# 自动复用 bwssh 维护的 session，无需重复输入主密码
alias bw='BW_SESSION="$(cat ~/.bw_session 2>/dev/null)" bw'
```

配置后效果：
- 任意终端执行 `bwssh` 解锁一次，其余所有终端的 `bwssh` 和 `bw` 命令均自动处于已解锁状态。
- 如果在终端中通过 `export BW_SESSION=...` 手动解锁，`bwssh` 也会自动同步捕获并存入缓存。

### 手动刷新 Session

```bash
# Token 过期时，直接再次运行 bwssh 会自动重新 unlock
bwssh prod-web-01

# 或手动清除缓存强制重新登录
rm ~/.bw_session && bwssh
```

---

## 安全说明

> [!IMPORTANT]
> **私钥与密码均从不持久化到磁盘。**
> - **私钥登录**：通过 `mktemp` 创建临时私钥（权限 600），连接建立后通过 `trap` 立即自动删除。
> - **密码登录**：通过 OpenSSH 原生 AskPass 机制在独立隔离目录（权限 700）提供密码流，执行后即刻自动销毁。
> - **异常保障**：Shell 遇到 `Ctrl+C`、断开连接或报错退出时，`trap ... EXIT INT TERM` 均会确保临时凭据彻底清除。

| 安全项 | 说明 |
|---|---|
| 凭据不落盘 | 仅存在于 Bitwarden 加密库和内存中 |
| 临时凭据自动清理 | `trap "rm -rf ..."` 保证所有临时文件自动销毁 |
| Session 缓存隔离 | `~/.bw_session` 权限 600，仅当前用户可读 |
| `IdentitiesOnly yes` | 私钥模式下仅使用指定 Key，不尝试多余的 agent Key |

---

## 环境变量

| 变量 | 说明 | 默认值 / 示例 |
|---|---|---|
| `BW_SESSION` | 手动指定 Bitwarden session token | `export BW_SESSION=xxxxx` |
| `BWSSH_FOLDER` | 指定 SSH 条目所在的 Bitwarden 文件夹名 | 默认 `SSH`，如 `export BWSSH_FOLDER="Servers"` |
| `BW_SERVE_PORT` | `bw serve` 本地 API 监听端口（防冲突） | 默认 `8087`，如 `export BW_SERVE_PORT=18087` |
| `BWSSH_OPTS` | 追加额外的 SSH 参数 | `export BWSSH_OPTS="-v"` |

**端口转发示例：**

```bash
BWSSH_OPTS="-L 8080:localhost:8080" bwssh prod-web-01
```

---

## 在远程机器上使用

此工具 **不依赖 Bitwarden Desktop App**，可在任意 Linux/macOS 机器上运行。

### 最小安装

在受限环境或临时跳板机上，只需安装 `bw` 和 `jq`，**可以不装 fzf**（不交互选择，直接输入名字）。

**安装 `bw`：**

```bash
# macOS
brew install bitwarden-cli

# Linux (下载独立二进制，无需 Node.js / npm)
curl -L "https://github.com/bitwarden/clients/releases/latest/download/bw-linux-amd64.zip" -o /tmp/bw.zip
unzip /tmp/bw.zip -d ~/.local/bin/ && chmod +x ~/.local/bin/bw
```





