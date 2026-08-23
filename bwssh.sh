#!/usr/bin/env bash
# bwssh — SSH via Bitwarden CLI
# Uses `bw serve` (local REST API) for fast lookups after first run.
#
# Usage:
#   bwssh                  # fuzzy-pick (requires fzf)
#   bwssh prod-web-01      # connect directly by item name
#   bwssh --list           # list all SSH items
#   bwssh --add-key NAME   # inject key into ssh-agent only
#   bwssh --stop           # stop background bw serve
#   bwssh --sync           # force vault sync + restart server
#
# Item schema in Bitwarden (Login type):
#   Name     = server alias  (e.g. "prod-web-01")
#   Username = SSH user      (e.g. "ubuntu")
#   Password = SSH password  (optional, used for password authentication)
#   URI      = hostname/IP   (e.g. "10.0.0.1" or "ssh://10.0.0.1:2222")
#   Notes    = private key PEM (optional, contains "PRIVATE KEY")
#   Custom field "port" = SSH port (optional, default 22)
#
# Identification criteria (any of the following):
#   1. Belongs to the Bitwarden folder specified by $BWSSH_FOLDER (default: "SSH")
#   2. Notes field contains "PRIVATE KEY"
#   3. URI starts with "ssh://"
#   4. Contains custom field "port" or "ssh"

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

err()  { echo -e "${RED}[bwssh] $*${RESET}" >&2; }
info() { echo -e "${CYAN}[bwssh] $*${RESET}" >&2; }
ok()   { echo -e "${GREEN}[bwssh] $*${RESET}" >&2; }

# ─── Config ───────────────────────────────────────────────────────────────────
BW_SESSION_CACHE="${HOME}/.bw_session"
BW_SERVE_PORT="${BW_SERVE_PORT:-8087}"
BW_SERVE_HOST="127.0.0.1"
BW_SERVE_URL="http://${BW_SERVE_HOST}:${BW_SERVE_PORT}"
BW_SERVE_PID_FILE="${HOME}/.bw_serve.pid"
BW_SERVE_LOG="/tmp/bw_serve.log"
BWSSH_FOLDER="${BWSSH_FOLDER:-SSH}"

# ─── Session Management ───────────────────────────────────────────────────────
bw_save_session() {
    echo "$BW_SESSION" > "$BW_SESSION_CACHE"
    chmod 600 "$BW_SESSION_CACHE"
}

bw_do_unlock() {
    info "Vault is locked or session expired. Please unlock:"
    export BW_SESSION=$(bw unlock --raw)
    bw_save_session
    ok "Vault unlocked."
}

bw_ensure_session() {
    if [ -n "${BW_SESSION:-}" ]; then
        local status
        status=$(bw status --session "$BW_SESSION" 2>/dev/null | jq -r '.status // empty' 2>/dev/null || true)
        [ "$status" = "unlocked" ] && return 0
    fi

    if [ -f "$BW_SESSION_CACHE" ]; then
        local cached
        cached=$(cat "$BW_SESSION_CACHE")
        if [ -n "$cached" ]; then
            export BW_SESSION="$cached"
            local status
            status=$(bw status --session "$BW_SESSION" 2>/dev/null | jq -r '.status // empty' 2>/dev/null || true)
            [ "$status" = "unlocked" ] && return 0
        fi
    fi

    bw_do_unlock
}

# ─── bw serve (fast local API) ────────────────────────────────────────────────
bw_serve_running() {
    local status_json
    status_json=$(curl -sf --max-time 1 "${BW_SERVE_URL}/status" 2>/dev/null) || return 1
    local vault_status
    vault_status=$(echo "$status_json" | jq -r '.data.template.status // .data.status // .data.data.status // empty' 2>/dev/null || true)
    [ "$vault_status" = "unlocked" ]
}

bw_start_serve() {
    info "Starting bw serve on port ${BW_SERVE_PORT} (one-time, ~2s)..."

    # Kill stale process if any
    if [ -f "$BW_SERVE_PID_FILE" ]; then
        local old_pid
        old_pid=$(cat "$BW_SERVE_PID_FILE" 2>/dev/null || true)
        [ -n "$old_pid" ] && kill "$old_pid" 2>/dev/null || true
        sleep 0.3
    fi

    BW_SESSION="$BW_SESSION" bw --session "$BW_SESSION" serve \
        --hostname "$BW_SERVE_HOST" \
        --port "$BW_SERVE_PORT" \
        >"$BW_SERVE_LOG" 2>&1 &
    echo $! > "$BW_SERVE_PID_FILE"

    # Wait up to 5s for server to be ready
    local i=0
    while [ $i -lt 25 ]; do
        sleep 0.2
        bw_serve_running && { ok "bw serve ready."; return 0; }
        i=$((i + 1))
    done

    err "bw serve failed to start or vault locked. Check log: $BW_SERVE_LOG"
    return 1
}

bw_ensure_serve() {
    bw_serve_running && return 0
    bw_start_serve
}

# HTTP GET to bw serve
bw_api() {
    local path="$1"
    local response

    response=$(curl -s --max-time 10 "${BW_SERVE_URL}/${path}" 2>/dev/null) || true

    if [ -z "$response" ]; then
        err "Failed to reach local bw serve (${BW_SERVE_URL})."
        err "Try running 'bwssh --stop' to restart it."
        exit 1
    fi

    local success
    success=$(echo "$response" | jq -r '.success // false' 2>/dev/null || echo "false")
    if [ "$success" != "true" ]; then
        local msg
        msg=$(echo "$response" | jq -r '.message // "API error"' 2>/dev/null || echo "API error")
        err "Bitwarden API error: $msg"
        exit 1
    fi

    # bw serve wraps response: {"success":true,"data":{...}}
    echo "$response" | jq '.data'
}

# ─── Item Fetching ────────────────────────────────────────────────────────────
bw_get_folder_id() {
    local folder_name="$1"
    [ -z "$folder_name" ] && return 0
    local folders
    folders=$(bw_api "list/object/folders" 2>/dev/null || true)
    if [ -n "$folders" ] && [ "$folders" != "null" ]; then
        echo "$folders" | jq -r --arg f "$folder_name" '
            [ .data[] | select(.name == $f or (.name | ascii_downcase) == ($f | ascii_downcase)) ] |
            first | .id // empty
        ' 2>/dev/null || true
    fi
}

# SSH items filter definition in jq:
# 1. Login type (.type == 1)
# 2. Match folder OR Notes has "PRIVATE KEY" OR URI starts with "ssh://" OR custom fields has "port"/"ssh"
SSH_ITEM_JQ_FILTER='
  def is_ssh_item($fid):
    .type == 1 and (
      ($fid != "" and $fid != null and .folderId == $fid) or
      (.notes != null and (.notes | test("PRIVATE KEY"))) or
      ([.login.uris[]?.uri // ""] | any(test("^ssh://"; "i"))) or
      ([.fields[]?.name // ""] | any(. == "port" or . == "ssh"))
    );
'

bw_list_ssh_items() {
    local folder_id
    folder_id=$(bw_get_folder_id "$BWSSH_FOLDER")
    bw_api "list/object/items" | jq -r --arg fid "$folder_id" "
        ${SSH_ITEM_JQ_FILTER}
        .data[] | select(is_ssh_item(\$fid)) |
        [
            .name,
            (.login.username // \"?\"),
            ((.login.uris[0].uri // \"?\") | sub(\"^[sS][sS][hH]://\"; \"\") | split(\"/\")[0] | split(\":\")[0] | split(\"@\")[-1]),
            (if (.notes != null and (.notes | test(\"PRIVATE KEY\"))) then \"key\" elif (.login.password != null and .login.password != \"\") then \"pass\" else \"none\" end)
        ] | @tsv
    "
}

bw_get_item() {
    local name="$1"
    local encoded="${name// /%20}"
    local folder_id
    folder_id=$(bw_get_folder_id "$BWSSH_FOLDER")
    bw_api "list/object/items?search=${encoded}" | jq -r --arg n "$name" --arg fid "$folder_id" "
        ${SSH_ITEM_JQ_FILTER}
        [ .data[] | select(is_ssh_item(\$fid)) |
          select(.name == \$n or (.name | ascii_downcase) == (\$n | ascii_downcase)) ] |
        first // empty
    "
}

# ─── SSH Connection ───────────────────────────────────────────────────────────
do_connect() {
    local item_name="$1"
    local add_key_only="${2:-false}"

    info "Fetching item: ${BOLD}${item_name}${RESET}"

    local item_json
    item_json=$(bw_get_item "$item_name")

    if [ -z "$item_json" ] || [ "$item_json" = "null" ]; then
        err "SSH item '${item_name}' not found."
        err "(Items must be in '${BWSSH_FOLDER}' folder, or have private key in Notes, or ssh:// URI)"
        err "Run 'bwssh --list' to see available items."
        exit 1
    fi

    local raw_uri raw_username raw_port private_key password
    raw_uri=$(echo "$item_json"      | jq -r '.login.uris[0].uri // empty')
    raw_username=$(echo "$item_json" | jq -r '.login.username // empty')
    raw_port=$(echo "$item_json"     | jq -r '
        if .fields then
            ([ .fields[] | select(.name == "port") | .value ] | first) // empty
        else empty end
    ' 2>/dev/null || true)
    private_key=$(echo "$item_json"  | jq -r '.notes // empty')
    password=$(echo "$item_json"     | jq -r '.login.password // empty')

    # Parse hostname, username, and port from raw_uri and fields
    local hostname=""
    local username="$raw_username"
    local port="$raw_port"

    # Strip ssh:// prefix if present
    local cleaned="${raw_uri#ssh://}"
    cleaned="${cleaned#SSH://}"
    cleaned="${cleaned%%/*}"

    # Extract username if not set and present in URI (user@host)
    if [[ "$cleaned" == *"@"* ]]; then
        local uri_user="${cleaned%%@*}"
        cleaned="${cleaned#*@}"
        [ -z "$username" ] && username="$uri_user"
    fi

    # Extract port if not set and present in URI (host:port)
    if [[ "$cleaned" == *":"* ]]; then
        local uri_port="${cleaned##*:}"
        cleaned="${cleaned%%:*}"
        [ -z "$port" ] && port="$uri_port"
    fi

    hostname="$cleaned"
    [ -z "$hostname" ] && { err "No URI/hostname in item '${item_name}'"; exit 1; }
    [ -z "$port"     ] && port="22"
    [ -z "$username" ] && username="${USER:-root}"

    # Determine authentication method (Key vs Password)
    local has_key=false
    local has_pass=false
    if [ -n "$private_key" ] && [[ "$private_key" == *"PRIVATE KEY"* ]]; then
        has_key=true
    fi
    if [ -n "$password" ]; then
        has_pass=true
    fi

    if [ "$has_key" = "false" ] && [ "$has_pass" = "false" ]; then
        err "No private key (Notes) or password found in item '${item_name}'."
        exit 1
    fi

    if [ "$add_key_only" = "true" ]; then
        if [ "$has_key" = "false" ]; then
            err "Item '${item_name}' uses password authentication; cannot add key to ssh-agent."
            exit 1
        fi
        local tmpkey
        tmpkey=$(mktemp)
        chmod 600 "$tmpkey"
        trap "rm -f '$tmpkey'" EXIT INT TERM
        printf '%s\n' "$private_key" > "$tmpkey"
        ssh-add "$tmpkey"
        ok "Key added to ssh-agent: ${username}@${hostname}:${port}"
        return 0
    fi

    local extra_args=()
    [ -n "${BWSSH_OPTS:-}" ] && read -ra extra_args <<< "$BWSSH_OPTS"

    if [ "$has_key" = "true" ]; then
        local tmpkey
        tmpkey=$(mktemp)
        chmod 600 "$tmpkey"
        trap "rm -f '$tmpkey'" EXIT INT TERM
        printf '%s\n' "$private_key" > "$tmpkey"

        ok "Connecting [key] → ${BOLD}${username}@${hostname}${RESET} (port ${port})"
        echo ""

        exec ssh \
            -i "$tmpkey" \
            -p "$port" \
            -o "StrictHostKeyChecking=accept-new" \
            -o "IdentitiesOnly=yes" \
            ${extra_args[@]+"${extra_args[@]}"} \
            "${username}@${hostname}"
    else
        # Password authentication using native SSH_ASKPASS
        local askpass_dir
        askpass_dir=$(mktemp -d /tmp/bwssh_askpass.XXXXXX)
        chmod 700 "$askpass_dir"
        local askpass_bin="${askpass_dir}/askpass.sh"
        local pass_file="${askpass_dir}/pass"

        printf '%s\n' "$password" > "$pass_file"
        chmod 600 "$pass_file"

        cat << 'EOF' > "$askpass_bin"
#!/bin/sh
cat "$(dirname "$0")/pass"
EOF
        chmod 700 "$askpass_bin"
        trap "rm -rf '$askpass_dir'" EXIT INT TERM

        ok "Connecting [password] → ${BOLD}${username}@${hostname}${RESET} (port ${port})"
        echo ""

        DISPLAY="${DISPLAY:-dummy:0}" \
        SSH_ASKPASS="$askpass_bin" \
        SSH_ASKPASS_REQUIRE="force" \
        exec ssh \
            -p "$port" \
            -o "StrictHostKeyChecking=accept-new" \
            -o "PubkeyAuthentication=no" \
            -o "PreferredAuthentications=password,keyboard-interactive" \
            ${extra_args[@]+"${extra_args[@]}"} \
            "${username}@${hostname}"
    fi
}

# ─── Interactive Picker ───────────────────────────────────────────────────────
pick_item_interactive() {
    if ! command -v fzf &>/dev/null; then
        err "fzf not found. Install: brew install fzf"
        err "Or use: bwssh <item-name>"
        exit 1
    fi

    info "Loading SSH items..."
    local items
    items=$(bw_list_ssh_items)

    if [ -z "$items" ]; then
        err "No SSH items found in vault."
        err "(Items must be in '${BWSSH_FOLDER}' folder, or have private key in Notes, or ssh:// URI)"
        exit 1
    fi

    local selected name
    selected=$(echo "$items" \
        | awk -F'\t' '{printf "%-28s %-12s %-20s [%s]\n", $1, $2, $3, $4}' \
        | fzf \
            --prompt="🔐 SSH > " \
            --header="Select a server (Bitwarden)" \
            --height=40% \
            --border \
            --reverse)

    name=$(echo "$selected" | awk '{print $1}' | xargs)
    echo "$name"
}

# ─── List Command ─────────────────────────────────────────────────────────────
cmd_list() {
    info "SSH items in vault (folder: ${BWSSH_FOLDER}):"
    echo ""
    printf "${BOLD}%-28s %-12s %-22s %-6s${RESET}\n" "NAME" "USER" "HOST" "AUTH"
    printf '%0.s─' {1..72}; echo
    bw_list_ssh_items | awk -F'\t' '{printf "%-28s %-12s %-22s [%s]\n", $1, $2, $3, $4}'
    echo ""
}

# ─── Stop Server ──────────────────────────────────────────────────────────────
cmd_stop() {
    if [ -f "$BW_SERVE_PID_FILE" ]; then
        local pid
        pid=$(cat "$BW_SERVE_PID_FILE")
        if kill "$pid" 2>/dev/null; then
            ok "bw serve (PID ${pid}) stopped."
        else
            info "bw serve was not running."
        fi
        rm -f "$BW_SERVE_PID_FILE"
    else
        info "No running bw serve found."
    fi
}

# ─── Sync ─────────────────────────────────────────────────────────────────────
cmd_sync() {
    info "Syncing vault..."
    bw sync --session "$BW_SESSION"
    ok "Synced. Restarting bw serve..."
    cmd_stop
    bw_start_serve
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-}"

    bw_ensure_session
    bw_ensure_serve

    case "$cmd" in
        --list|-l)
            cmd_list
            ;;
        --add-key|-k)
            shift
            local name="${1:-}"
            [ -z "$name" ] && name=$(pick_item_interactive)
            do_connect "$name" true
            ;;
        --stop)
            cmd_stop
            ;;
        --sync)
            cmd_sync
            ;;
        "")
            local name
            name=$(pick_item_interactive)
            [ -n "$name" ] && do_connect "$name" false
            ;;
        -*)
            err "Unknown option: $cmd"
            echo "Usage: bwssh [name | --list | --add-key [name] | --stop | --sync]"
            exit 1
            ;;
        *)
            do_connect "$cmd" false
            ;;
    esac
}

main "$@"
