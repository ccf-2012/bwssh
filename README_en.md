# bwssh — Bitwarden CLI SSH Connection Manager

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25.svg)](https://www.gnu.org/software/bash/)
[![Bitwarden](https://img.shields.io/badge/Bitwarden-CLI-175DDC.svg)](https://bitwarden.com)

[**中文文档 (Chinese)**](README.md) | **English**

---
with **bwssh** you can just type `bwssh lax9929` to reach and login to your host. all the credential saved in your self-hosted vaultwarden, no `~/.ssh/lax9929.key`, no `~/.ssh/config`.

if you have too many hosts and forget the host name, just type `bwssh` and a `fzf` menu pop up, you can navigate and press enter to connect. everything stay in terminal.

you can also `bwssh lax9929 "uptime"` to excute some command.

---

## Features

- **Private Key & Password Support**: Prioritizes SSH private keys stored in vault notes; falls back to password authentication automatically via native `SSH_ASKPASS`.
- **Smart Item Detection**: Supports folder isolation (default `SSH` folder) as well as automatic recognition by private key content, `ssh://` URI scheme, or custom `port`/`ssh` fields.
- **Lightning Fast**: Powered by a background `bw serve` local REST cache, avoiding sluggish vault decryptions on repeated runs.
- **Zero Disk Footprint & Strict Security**: Ephemeral private keys (`mktemp` mode 0600) and askpass scripts (mode 0700) are used strictly in-memory / temporary storage and immediately shredded upon connection exit (`trap ... EXIT INT TERM`).
- **Cross-Terminal Session Sharing**: Session token cached in `~/.bw_session` (mode 0600); unlock once and use across all open terminal windows.
- **Interactive Fuzzy Search**: Interactive selection powered by `fzf` when no server name is provided.
- **SSH-Agent Key Loading**: Supports injecting keys directly into `ssh-agent` with `--add-key`.
- **Direct Command Execution**: Run remote commands seamlessly, e.g., `bwssh my-server "uptime"`.

---

## Dependencies

| Tool | Purpose | Installation |
|---|---|---|
| `bw` | Bitwarden CLI | `brew install bitwarden-cli` / `npm i -g @bitwarden/cli` |
| `jq` | JSON parser | `brew install jq` / `apt install jq` |
| `fzf` | Interactive fuzzy picker *(optional)* | `brew install fzf` / `apt install fzf` |

> [!NOTE]
> `fzf` is optional. If not installed, you can still connect directly by name (`bwssh <server-name>`) or list servers with `bwssh --list`.

---

## Installation

#### 1. Download the script and grant executable permissions

```bash
mkdir -p ~/.local/bin && curl -fsSL https://raw.githubusercontent.com/ccf-2012/bwssh/main/bwssh.sh -o ~/.local/bin/bwssh && chmod +x ~/.local/bin/bwssh
```

#### 2. Ensure `~/.local/bin` is in your `PATH`

Add this to your `~/.zshrc` or `~/.bashrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

#### 3. Log in to Bitwarden for the first time

```bash
# Official Bitwarden cloud:
bw login

# If using self-hosted Vaultwarden, configure server first:
# bw config server https://vault.example.com
# bw login
```

---

## Storing SSH Entries in Bitwarden

Create a **Login** item in your Bitwarden vault using the following schema:

| Bitwarden Field | Content | Example / Description |
|---|---|---|
| **Folder** | Vault Folder *(recommended)* | `SSH` (default folder used for filtering) |
| **Name** | Server alias *(used for search)* | `prod-web-01` |
| **Username** | SSH login user | `ubuntu` or `root` |
| **Password** | SSH login password *(optional)* | Used for password authentication if no private key is present |
| **URI** | Host IP, domain, or SSH URI | `10.0.0.1`, `myserver.com`, or `ssh://10.0.0.1:2222` |
| **Notes** or Hidden Field `key` | Full SSH private key in PEM format *(optional)* | `-----BEGIN OPENSSH PRIVATE KEY-----` … |
| Custom Field `port` | SSH port number *(optional)* | `2222` (useful when non-standard port isn't specified in URI) |

> [!TIP]
> - **Private Key Auth (Two methods supported)**:
>   - **Method A (Recommended for privacy)**: Add a **Hidden** custom field under Custom Fields / Additional Options named `key` or `private_key` (masked with dots in the UI).
>   - **Method B (Quick & direct)**: Paste the complete private key directly into the **Notes** field.
>   - *The script checks custom fields first, falling back to Notes if not set.*
> - **Password Auth**: Enter the password in the **Password** field and leave the private key / Notes blank.
> - **URI Formats**: Supports standard IP/domain (`10.0.0.1`), port-attached (`10.0.0.1:2222`), bracketed IPv6 (`[2001:db8::1]:2222`), or protocol URIs (`ssh://user@10.0.0.1:2222`).
> - **Custom User in URI**: If the URI includes a username (`ssh://deploy@10.0.0.1`), it overrides or supplies the default username.

### Entry Identification Criteria

When listing, searching, or picking items, `bwssh` identifies an entry as an SSH host if **any** of the following conditions are met:
1. Belongs to the `BWSSH_FOLDER` folder (default: `SSH`).
2. **OR** the **Notes** or **custom field** contains `PRIVATE KEY`.
3. **OR** contains a custom field named `key`, `private_key`, `ssh_key`, `port`, or `ssh`.
4. **OR** any **URI** begins with `ssh://`.

To customize the default folder name, set:
```bash
export BWSSH_FOLDER="Servers"   # in ~/.zshrc or ~/.bashrc
```

---

## Usage

### Connect by Server Name (Most Common)

```bash
bwssh prod-web-01
```

Retrieves host details, username, and key/password from Bitwarden and opens the SSH session immediately.

### Execute Remote Command Directly

```bash
bwssh prod-web-01 "uptime && uname -a"
```

### Interactive Fuzzy Picker (Requires `fzf`)

```bash
bwssh
```

Brings up an interactive fuzzy-find menu across all vault SSH items:

```text
🔐 SSH > prod
  prod-web-01                  ubuntu       10.0.0.1             [key]
  prod-db-01                   postgres     10.0.0.2             [pass]
  prod-redis                   root         10.0.0.3             [key]
```

### List All SSH Entries

```bash
bwssh --list
# or
bwssh -l
```

Example output:

```text
NAME                         USER         HOST                   AUTH
────────────────────────────────────────────────────────────────────────
prod-web-01                  ubuntu       10.0.0.1               [key]
prod-db-01                   postgres     10.0.0.2               [pass]
staging-api                  deploy       staging.myapp.com      [key]
```

### Add Key to `ssh-agent` Without Connecting

```bash
bwssh --add-key prod-web-01
# or
bwssh -k prod-web-01
```

Injects the private key into your running `ssh-agent` session for agent forwarding or external scripts.

### Sync Cloud Vault (When entries or passwords change)

When you modify or create servers via the Bitwarden web vault or mobile app, sync your local cache:

```bash
bwssh --sync
# or
bwssh -s
```

> ⚡ **Seamless Sync**: Synchronizes with Bitwarden cloud and refreshes the local background daemon without manual restarts.

### Stop Background Daemon

```bash
bwssh --stop
```

Terminates the local `bw serve` process listening on the local port.

---

## Session Management

### How It Works

```text
First Run
  ↓ Prompt for Master Password
  ↓ Generate BW_SESSION Token
  ↓ Save to ~/.bw_session (chmod 600)

Subsequent Runs
  ↓ Read ~/.bw_session
  ↓ Validate Token status
  ↓ Valid   → Connect directly without prompting
    Expired → Prompt to unlock
```

### Session Timeout

By default, Bitwarden sessions expire after **15 minutes of inactivity**. You can configure this in the Bitwarden Web Vault:
**Settings → Security → Session timeout**.

### Cross-Terminal Sharing & Native `bw` CLI Integration

The Bitwarden CLI does not persist session tokens across different terminal tabs by default. `bwssh` solves this by safely keeping the active token in `~/.bw_session` (chmod `600`).

To let your regular `bw` commands (`bw list`, `bw get`, etc.) and new terminal tabs **automatically reuse this session**, add this alias to `~/.zshrc` or `~/.bashrc`:

```bash
# Automatically share the session unlocked by bwssh across all terminals
alias bw='BW_SESSION="$(cat ~/.bw_session 2>/dev/null)" bw'
```

Benefits:
- Unlock once in any terminal via `bwssh`; all subsequent `bwssh` and `bw` calls in any tab will stay unlocked.
- If you manually `export BW_SESSION=...`, `bwssh` will recognize and update the cache file automatically.

### Manual Session Reset

```bash
# When token expires, running bwssh automatically triggers unlock
bwssh prod-web-01

# Or wipe cache manually to force re-authentication
rm ~/.bw_session && bwssh
```

---

## Security

> [!IMPORTANT]
> **Private keys and passwords are NEVER persisted to disk.**
> - **Private Key Auth**: Written to a temporary file via `mktemp` (mode `0600`). As soon as SSH exits or is interrupted, the file is shredded via shell `trap`.
> - **Password Auth**: Uses OpenSSH's native `SSH_ASKPASS` in an isolated directory (mode `0700`), destroying the password buffer immediately upon execution.
> - **Signal Handlers**: All temporary credentials are safely purged on `EXIT`, `SIGINT` (Ctrl+C), or `SIGTERM`.

| Security Feature | Implementation |
|---|---|
| Zero Disk Footprint | Credentials reside only in encrypted Bitwarden storage and ephemeral memory |
| Auto Cleanup | `trap "rm -rf ..."` guarantees immediate destruction of temporary credentials |
| Cache Isolation | `~/.bw_session` is restricted to `0600` (readable only by the current user) |
| Strict Key Binding | Enforces `IdentitiesOnly=yes` in private key mode to avoid leaking agent keys |

---

## Environment Variables

| Variable | Description | Default / Example |
|---|---|---|
| `BW_SESSION` | Explicit Bitwarden session token | `export BW_SESSION=xxxxx` |
| `BWSSH_FOLDER` | Bitwarden folder name for SSH items | Default: `SSH` (`export BWSSH_FOLDER="Servers"`) |
| `BW_SERVE_PORT` | Port for local `bw serve` REST daemon | Default: `8087` (`export BW_SERVE_PORT=18087`) |
| `BWSSH_OPTS` | Additional arguments passed directly to `ssh` | `export BWSSH_OPTS="-v"` |

**Example: Port Forwarding via `BWSSH_OPTS`**

```bash
BWSSH_OPTS="-L 8080:localhost:8080" bwssh prod-web-01
```

---

## Headless / Remote Machine Usage

`bwssh` does **not** depend on the Bitwarden Desktop App, electron, or a GUI. It runs natively on servers, jump hosts, or cloud VMs.

### Minimal Setup on Linux (Without Node.js / npm)

Install standalone `bw` binary and `jq`:

```bash
# 1. Download standalone bw CLI binary
curl -fsSL "https://github.com/bitwarden/clients/releases/latest/download/bw-linux-amd64.zip" -o /tmp/bw.zip
unzip /tmp/bw.zip -d ~/.local/bin/ && chmod +x ~/.local/bin/bw

# 2. Install jq
# Debian / Ubuntu:
sudo apt-get install -y jq
# RHEL / CentOS:
sudo yum install -y jq

# 3. Log in once
bw login
```

You can now use `bwssh` directly on the server without installing `fzf`.

---

## License

This project is licensed under the [MIT License](LICENSE).
