# bwssh — Bitwarden CLI SSH 管理工具

通过 Bitwarden CLI 直接从密码库取出主机名、用户名、SSH 私钥并完成登录，**无需本地 Desktop App，无需维护 `~/.ssh/config`，跨机器开箱即用**。

---

## 依赖

| 工具 | 用途 | 安装 |
|---|---|---|
| `bw` | Bitwarden CLI | `brew install bitwarden-cli` / `npm i -g @bitwarden/cli` |
| `jq` | JSON 解析 | `brew install jq` / `apt install jq` |
| `fzf` | 交互式模糊选择，**仅 `bwssh`（无参数）和 `bwssh -k`（无参数）时需要** | `brew install fzf` / `apt install fzf` |

> [!TIP]
> 如果你习惯直接输名字（`bwssh prod-web-01`），可以不装 fzf。

---

## 安装

```bash
# macOS / Linux 通用
curl -o ~/.local/bin/bwssh https://your-host/bwssh   # 或手动复制脚本
chmod +x ~/.local/bin/bwssh

# 确保 ~/.local/bin 在 PATH 中（加入 ~/.zshrc）
export PATH="$HOME/.local/bin:$PATH"
```

---

## 在 Bitwarden 中存储 SSH 条目

所有 SSH 条目需放在同一个 **Bitwarden 文件夹**中（默认文件夹名为 `SSH`）。脚本只会列出和搜索这个文件夹内的条目，不会误拿其他密码。

每台服务器创建一个 **Login** 类型条目，字段约定如下：

| Bitwarden 字段 | 填写内容 | 示例 |
|---|---|---|
| **Folder** | 文件夹（必须） | `SSH` |
| **Name** | 服务器别名（用于搜索） | `prod-web-01` |
| **Username** | SSH 登录用户名 | `ubuntu` / `root` |
| **URI** | 主机 IP 或域名 | `10.0.0.1` / `myserver.com` |
| **Notes** | SSH 私钥全文（PEM 格式） | `-----BEGIN OPENSSH PRIVATE KEY-----` … |
| Custom Field `port` | SSH 端口（非 22 时填写） | `2222` |

> [!TIP]
> 私钥存在 **Notes** 字段，直接粘贴 `cat ~/.ssh/id_ed25519` 的输出即可。
> 条目 Name 建议使用英文小写加连字符，方便命令行直接输入。

如果你的文件夹名不是 `SSH`，可通过环境变量覆盖：

```bash
export BWSSH_FOLDER="Servers"   # 写入 ~/.zshrc 永久生效
```

---


## 使用方法

### 直接按名称连接（最常用）

```bash
bwssh prod-web-01
```

脚本会自动从 Bitwarden 取出该条目的 Host、Username、私钥，建立连接。

### 交互式选择（需要 fzf）

```bash
bwssh
```

列出所有满足条件的 SSH 条目，通过 fzf 模糊搜索选择目标服务器：

```
🔐 SSH > prod
  prod-web-01            ubuntu@10.0.0.1
  prod-db-01             postgres@10.0.0.2
  prod-redis             root@10.0.0.3
```

### 列出所有 SSH 条目

```bash
bwssh --list
# 或
bwssh -l
```

输出示例：

```
NAME                           USER            HOST
──────────────────────────────────────────────────────────────────────
prod-web-01                    ubuntu          10.0.0.1
prod-db-01                     postgres        10.0.0.2
staging-api                    deploy          staging.myapp.com
```

### 仅注入 Key 到 ssh-agent

> [!NOTE]
> `--add-key` **不是生成新 Key**，而是将 Bitwarden 中已存储的私钥注入本机 ssh-agent 内存，
> 让其他不经过 `bwssh` 的工具（git、rsync、scp 等）也能使用这把 Key。

```bash
bwssh --add-key prod-web-01
# 或
bwssh -k prod-web-01

# 不带参数时弹出 fzf 选择
bwssh -k
```

注入后的效果：

```
bwssh -k prod-web-01
    ↓
ssh-agent 内存中有了这把 key（ssh-add -L 可验证）
    ↓
git / rsync / scp / ssh ... 都能直接用，无需再经过 bwssh
```

**典型使用场景：**

| 场景 | 操作 |
|---|---|
| git push 到需要 SSH 认证的远程仓库 | `bwssh -k github` → `git push` |
| rsync / scp 传输文件 | `bwssh -k prod-web-01` → `rsync -av ...` |
| SSH Agent Forwarding（登录后跳转内网机器） | `bwssh -k bastion` → `ssh -A bastion` |
| 同一 session 内多次操作同一台机器 | 注入一次，后续 `ssh user@host` 直接走 agent |

注入的 Key 仅存在于**内存**中，重启或 `ssh-agent` 退出后自动消失。可用 `ssh-add -D` 手动清除所有已注入的 Key。

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

| 选项 | 适合场景 |
|---|---|
| 15 分钟（默认） | 高安全要求 |
| 4 小时 | 日常工作 |
| 永不超时 | 专用跳板机 |

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
> **私钥从不持久化到磁盘。** 脚本流程：
> 1. 从 Bitwarden 内存中取出私钥文本
> 2. 写入 `mktemp` 创建的临时文件（权限 600）
> 3. `exec ssh` 使用该文件建立连接
> 4. Shell 退出时 `trap` 自动删除临时文件（包括 `Ctrl+C` / 异常退出）

| 安全项 | 说明 |
|---|---|
| 私钥不落盘 | 仅存在于 Bitwarden 加密库和内存中 |
| 临时文件自动清理 | `trap "rm -f" EXIT INT TERM` 保证清理 |
| Session 缓存隔离 | `~/.bw_session` 权限 600，仅当前用户可读 |
| `IdentitiesOnly yes` | SSH 只使用指定 Key，不尝试其他 agent Key |

---

## 环境变量

| 变量 | 说明 | 示例 |
|---|---|---|
| `BW_SESSION` | 手动指定 Bitwarden session token | `export BW_SESSION=xxxxx` |
| `BWSSH_OPTS` | 追加额外的 SSH 参数 | `export BWSSH_OPTS="-v"` |

**端口转发示例：**

```bash
BWSSH_OPTS="-L 8080:localhost:8080" bwssh prod-web-01
```

---

## 在远程机器上使用

此工具 **不依赖 Bitwarden Desktop App**，可在任意 Linux/macOS 机器上运行。

### 最小安装（仅需 2 个工具）

在受限环境或临时跳板机上，只需安装 `bw` 和 `jq`，**无需 fzf**（放弃交互选择，改用直接输名字）。

| 工具 | 必须 | 说明 |
|---|---|---|
| `bw` | ✅ | Bitwarden CLI，核心依赖 |
| `jq` | ✅ | JSON 解析，必须 |
| `fzf` | ❌ 可选 | 只有裸跑 `bwssh` 无参数时才需要 |
| `curl` | ✅ 通常已有 | `bw serve` API 调用，大多数系统预装 |
| `npm` / Node.js | ❌ 可选 | 仅安装 `bw` 时需要，可用二进制包代替 |

**安装 `bw` 的几种方式（按复杂度排序）：**

```bash
# 方式一：直接下载二进制（最简单，无需 Node.js / npm）
# 从 https://github.com/bitwarden/clients/releases 找 bw-linux-*.zip
curl -L "https://github.com/bitwarden/clients/releases/latest/download/bw-linux-amd64.zip" \
    -o /tmp/bw.zip
unzip /tmp/bw.zip -d ~/.local/bin/
chmod +x ~/.local/bin/bw

# 方式二：npm（需要 Node.js）
npm install -g @bitwarden/cli

# 方式三：包管理器
brew install bitwarden-cli          # macOS
snap install bw                     # Linux (Snap)
```

**最小安装 `jq`：**

```bash
apt install jq          # Debian/Ubuntu
yum install jq          # CentOS/RHEL
brew install jq         # macOS
# 或直接下载静态二进制（无需 root）：
curl -L https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64 \
    -o ~/.local/bin/jq && chmod +x ~/.local/bin/jq
```

**完整流程：**

```bash
# 1. 安装 bw + jq（见上）
# 2. 复制脚本
curl -o ~/.local/bin/bwssh https://your-host/bwssh
chmod +x ~/.local/bin/bwssh

# 3. 首次登录
bw login

# 4. 使用（始终带名字，无需 fzf）
bwssh prod-db-01
```

---



## 故障排查

### `Item not found`

```bash
# 先确认条目名称拼写
bwssh --list

# bw 搜索区分大小写，名称需完全一致
bwssh "Prod-Web-01"   # 注意大小写
```

### `No private key (Notes) found`

条目的 **Notes** 字段为空。请在 Bitwarden 编辑该条目，将私钥全文粘贴到 Notes 字段：

```
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAA...（完整内容）
-----END OPENSSH PRIVATE KEY-----
```

### `ssh: connect to host ... port 22: Connection refused`

非标准端口时，在 Bitwarden 条目添加 Custom Field：
- Field Name: `port`
- Field Value: `2222`（实际端口号）

### `Vault is locked` 每次都提示

检查 `~/.bw_session` 是否存在且非空：

```bash
cat ~/.bw_session   # 应输出一长串 token
bw status           # 查看 vault 状态
```

若 token 已过期，直接运行 `bwssh` 会自动重新 unlock 并更新缓存。

---

## 本地生成的文件

脚本在本机会生成以下文件：

| 文件 | 权限 | 内容 | 生命周期 |
|---|---|---|---|
| `~/.bw_session` | `600` | Bitwarden session token | 持久，vault 重锁时自动更新 |
| `~/.bw_serve.pid` | 默认 | `bw serve` 后台进程的 PID | 持久，`--stop` 时删除 |
| `/tmp/bw_serve.log` | 默认 | `bw serve` 的 stdout/stderr | 持久（覆盖写入） |
| `/tmp/bwssh.XXXXXX` | `600` | 连接时的临时私钥文件 | 临时，SSH 断开或 Ctrl+C 后自动删除 |

> [!IMPORTANT]
> `~/.bw_session` 含有 Bitwarden session token，权限已设为 `600`（仅当前用户可读）。
> 私钥内容只写入 `/tmp/bwssh.XXXXXX`，通过 `trap` 在连接结束后自动删除，不会长期留存。

### 手动清理

```bash
# 清除所有 bwssh 生成的文件（会要求下次重新 unlock）
bwssh --stop
rm -f ~/.bw_session ~/.bw_serve.pid /tmp/bw_serve.log
```

---


