#!/usr/bin/env bash
# bwssh — SSH via Bitwarden CLI
# Uses `bw serve` (local REST API) for fast lookups after first run.
#
# Usage:
#   bwssh                  # fuzzy-pick (requires fzf)
#   bwssh prod-web-01      # connect directly by item name
#   bwssh prod-web-01 "cmd"# run remote command directly
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
#   Custom field "key" / "private_key" / "ssh_key" = private key PEM (Hidden or Text)
#   Custom field "port" = SSH port (optional, default 22)
#
# Identification criteria (any of the following):
#   1. Belongs to the Bitwarden folder specified by $BWSSH_FOLDER (default: "SSH")
#   2. Notes or custom field contains "PRIVATE KEY"
#   3. Contains custom field "key", "private_key", "ssh_key", "id_rsa", "port", or "ssh"
#   4. URI starts with "ssh://"

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

err()  { echo -e "${RED}[bwssh] $*${RESET}" >&2; }
info() { echo -e "${CYAN}[bwssh] $*${RESET}" >&2; }
ok()   { echo -e "${GREEN}[bwssh] $*${RESET}" >&2; }

trim() {
    local s="${1:-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ─── Config ───────────────────────────────────────────────────────────────────
BW_SESSION_CACHE="${HOME}/.bw_session"
BW_SERVE_PORT="${BW_SERVE_PORT:-8087}"
BW_SERVE_HOST="127.0.0.1"
BW_SERVE_URL="http://${BW_SERVE_HOST}:${BW_SERVE_PORT}"
BW_SERVE_PID_FILE="${HOME}/.bw_serve.pid"
BW_SERVE_LOG="/tmp/bw_serve.log"
BWSSH_FOLDER="${BWSSH_FOLDER:-SSH}"

bw_check_dependencies() {
    local missing=()
    command -v bw &>/dev/null || missing+=("bw (Bitwarden CLI: brew install bitwarden-cli)")
    command -v jq &>/dev/null || missing+=("jq (JSON processor: brew install jq)")
    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing required dependencies:"
        for dep in "${missing[@]}"; do
            err "  - $dep"
        done
        exit 1
    fi
}

# ─── Session Management ───────────────────────────────────────────────────────
bw_save_session() {
    [ -z "${BW_SESSION:-}" ] && return 0
    echo "$BW_SESSION" > "$BW_SESSION_CACHE"
    chmod 600 "$BW_SESSION_CACHE"
}

bw_do_unlock() {
    info "Vault is locked or session expired. Please unlock:"
    local session
    if ! session=$(bw unlock --raw); then
        err "Failed to unlock vault."
        rm -f "$BW_SESSION_CACHE"
        exit 1
    fi
    session=$(trim "$session")
    if [ -z "$session" ]; then
        err "Failed to obtain Bitwarden session key."
        rm -f "$BW_SESSION_CACHE"
        exit 1
    fi
    export BW_SESSION="$session"
    bw_save_session
    ok "Vault unlocked."
}

bw_ensure_session() {
    # 1. Check existing BW_SESSION environment variable
    if [ -n "${BW_SESSION:-}" ]; then
        local status
        status=$(bw status --session "$BW_SESSION" 2>/dev/null | jq -r '.status // empty' 2>/dev/null || true)
        if [ "$status" = "unlocked" ]; then
            bw_save_session
            return 0
        fi
    fi

    # 2. Check cached session file
    if [ -f "$BW_SESSION_CACHE" ]; then
        local cached
        cached=$(cat "$BW_SESSION_CACHE" 2>/dev/null || true)
        cached=$(trim "$cached")
        if [ -n "$cached" ]; then
            export BW_SESSION="$cached"
            local status
            status=$(bw status --session "$BW_SESSION" 2>/dev/null | jq -r '.status // empty' 2>/dev/null || true)
            if [ "$status" = "unlocked" ]; then
                return 0
            fi
        fi
        # Session in cache is invalid or expired
        rm -f "$BW_SESSION_CACHE"
        unset BW_SESSION
    fi

    # 3. Check Bitwarden authentication status
    local auth_status
    auth_status=$(bw status 2>/dev/null | jq -r '.status // empty' 2>/dev/null || true)
    if [ "$auth_status" = "unauthenticated" ]; then
        err "You are not logged in to Bitwarden CLI."
        info "(If using self-hosted Vaultwarden, run 'bw config server <url>' first)"
        if [ -t 0 ]; then
            echo -ne "${CYAN}[bwssh] Would you like to log in now with 'bw login'? [Y/n] ${RESET}" >&2
            local ans
            read -r ans
            case "${ans:-y}" in
                [yY][eE][sS]|[yY])
                    if ! bw login; then
                        err "Bitwarden login failed."
                        exit 1
                    fi
                    ;;
                *)
                    info "Please log in first using: ${BOLD}bw login${RESET}"
                    exit 1
                    ;;
            esac
        else
            err "Please log in first using: ${BOLD}bw login${RESET}"
            exit 1
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
        rm -f "$BW_SERVE_PID_FILE"
        sleep 0.3
    fi

    # Kill any orphaned process listening on the port
    local port_pids
    port_pids=$(lsof -ti ":${BW_SERVE_PORT}" 2>/dev/null || true)
    if [ -n "$port_pids" ]; then
        kill $port_pids 2>/dev/null || true
        sleep 0.2
    fi

    # Truncate log file
    : > "$BW_SERVE_LOG"

    # Use --unhandled-rejections=warn so network/DNS errors do not crash bw serve
    NODE_OPTIONS="${NODE_OPTIONS:-} --unhandled-rejections=warn" \
    BW_SESSION="$BW_SESSION" bw --session "$BW_SESSION" serve \
        --hostname "$BW_SERVE_HOST" \
        --port "$BW_SERVE_PORT" \
        >"$BW_SERVE_LOG" 2>&1 &
    local srv_pid=$!
    echo "$srv_pid" > "$BW_SERVE_PID_FILE"

    # Wait up to 5s for server to be ready
    local i=0
    while [ $i -lt 25 ]; do
        sleep 0.2
        if bw_serve_running; then
            ok "bw serve ready."
            return 0
        fi
        # If server process died early, stop waiting immediately
        if ! kill -0 "$srv_pid" 2>/dev/null; then
            break
        fi
        i=$((i + 1))
    done

    err "bw serve failed to start or vault locked."
    if [ -f "$BW_SERVE_LOG" ] && [ -s "$BW_SERVE_LOG" ]; then
        local log_msg
        log_msg=$(trim "$(cat "$BW_SERVE_LOG")")
        [ -n "$log_msg" ] && err "Log: $log_msg"
    else
        err "Check log: $BW_SERVE_LOG"
    fi
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
        # Try to restart once if server died unexpectedly
        if ! bw_serve_running; then
            info "bw serve connection lost, attempting restart..."
            if bw_start_serve; then
                response=$(curl -s --max-time 10 "${BW_SERVE_URL}/${path}" 2>/dev/null) || true
            fi
        fi
    fi

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
    folders=$(bw_api "list/object/folders") || return 1
    if [ -n "$folders" ] && [ "$folders" != "null" ]; then
        echo "$folders" | jq -r --arg f "$folder_name" '
            [ .data[] | select(.name == $f or (.name | ascii_downcase) == ($f | ascii_downcase)) ] |
            first | .id // empty
        ' 2>/dev/null || true
    fi
}

# SSH items filter definition in jq:
# 1. Login type (.type == 1)
# 2. Match folder OR Notes/field has "PRIVATE KEY" OR custom key/port/ssh field OR URI starts with "ssh://"
SSH_ITEM_JQ_FILTER='
  def has_key_field:
    if .fields then
      ([ .fields[] | select(
        ((.name // "") | ascii_downcase | test("^(key|private_?key|ssh_?key|id_rsa)$")) or
        ((.value // "") | test("PRIVATE KEY"))
      ) ] | length > 0)
    else false end;

  def is_ssh_item($fid):
    .type == 1 and (
      ($fid != "" and $fid != null and .folderId == $fid) or
      (.notes != null and (.notes | test("PRIVATE KEY"))) or
      has_key_field or
      ([.login.uris[]?.uri // ""] | any(test("^ssh://"; "i"))) or
      ([.fields[]?.name // ""] | any(. as $n | ["port", "ssh", "key", "private_key", "ssh_key"] | any(. == ($n | ascii_downcase))))
    );

  def clean_host:
    sub("^\\s+"; "") | sub("\\s+$"; "") |
    sub("^[sS][sS][hH]://\\s*"; "") | split("/")[0] | split("@")[-1] |
    sub("^\\s+"; "") | sub("\\s+$"; "") |
    if test("^\\[[^\\]]+\\](:[0-9]+)?$") then
      capture("^\\[(?<h>[^\\]]+)\\]") | .h
    elif (contains(":") and (split(":") | length == 2)) then
      split(":")[0]
    else
      .
    end |
    sub("^\\s+"; "") | sub("\\s+$"; "");
'

bw_list_ssh_items() {
    local folder_id
    folder_id=$(bw_get_folder_id "$BWSSH_FOLDER") || return 1
    bw_api "list/object/items" | jq -r --arg fid "$folder_id" "
        ${SSH_ITEM_JQ_FILTER}
        .data[] | select(is_ssh_item(\$fid)) |
        [
            .name,
            (.login.username // \"?\"),
            ((.login.uris[0].uri // \"?\") | clean_host),
            (if ((.notes != null and (.notes | test(\"PRIVATE KEY\"))) or has_key_field) then \"key\" elif (.login.password != null and .login.password != \"\") then \"pass\" else \"none\" end)
        ] | @tsv
    "
}

bw_get_item() {
    local name="$1"
    local encoded="${name// /%20}"
    local folder_id
    folder_id=$(bw_get_folder_id "$BWSSH_FOLDER") || return 1
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
    shift 2 2>/dev/null || shift $#
    local remote_cmd=("$@")

    item_name=$(trim "$item_name")
    info "Fetching item: ${BOLD}${item_name}${RESET}"

    local item_json
    if ! item_json=$(bw_get_item "$item_name"); then
        exit 1
    fi

    if [ -z "$item_json" ] || [ "$item_json" = "null" ]; then
        err "SSH item '${item_name}' not found."
        err "(Items must be in '${BWSSH_FOLDER}' folder, or have private key in custom field / Notes, or ssh:// URI)"
        err "Run 'bwssh --list' to see available items."
        exit 1
    fi

    local raw_uri raw_username raw_port private_key password
    raw_uri=$(echo "$item_json"      | jq -r '.login.uris[0].uri // empty')
    raw_username=$(echo "$item_json" | jq -r '.login.username // empty')
    raw_port=$(echo "$item_json"     | jq -r '
        if .fields then
            ([ .fields[] | select((.name | ascii_downcase) == "port") | .value ] | first) // empty
        else empty end
    ' 2>/dev/null || true)
    # Check custom fields for private key first (Hidden or Text), then fallback to Notes
    private_key=$(echo "$item_json"  | jq -r '
        if .fields then
            ([ .fields[] | select((.name | ascii_downcase | test("^(key|private_?key|ssh_?key|id_rsa)$")) or (.value != null and (.value | test("PRIVATE KEY")))) | .value ] | first) // .notes // empty
        else
            .notes // empty
        end
    ' 2>/dev/null || true)
    password=$(echo "$item_json"     | jq -r '.login.password // empty')

    # Trim raw fields
    raw_uri=$(trim "$raw_uri")
    raw_username=$(trim "$raw_username")
    raw_port=$(trim "$raw_port")

    # Parse hostname, username, and port from raw_uri and fields
    local hostname=""
    local username="$raw_username"
    local port="$raw_port"

    # Strip ssh:// prefix if present
    local cleaned="$raw_uri"
    cleaned="${cleaned#ssh://}"
    cleaned="${cleaned#SSH://}"
    cleaned="${cleaned#ssh://}"
    cleaned=$(trim "$cleaned")
    cleaned="${cleaned%%/*}"
    cleaned=$(trim "$cleaned")

    # Extract username if not set and present in URI (user@host)
    if [[ "$cleaned" == *"@"* ]]; then
        local uri_user="${cleaned%%@*}"
        cleaned="${cleaned#*@}"
        cleaned=$(trim "$cleaned")
        [ -z "$username" ] && username="$(trim "$uri_user")"
    fi

    # Extract host and port (support IPv6, bracketed IPv6 with port, and host:port)
    if [[ "$cleaned" =~ ^\[([a-fA-F0-9:]+)\]:([0-9]+)$ ]]; then
        hostname="${BASH_REMATCH[1]}"
        [ -z "$port" ] && port="${BASH_REMATCH[2]}"
    elif [[ "$cleaned" =~ ^\[([a-fA-F0-9:]+)\]$ ]]; then
        hostname="${BASH_REMATCH[1]}"
    elif [[ "$cleaned" =~ ^([^:]+):([0-9]+)$ ]]; then
        hostname="${BASH_REMATCH[1]}"
        [ -z "$port" ] && port="${BASH_REMATCH[2]}"
    else
        hostname="$cleaned"
    fi

    hostname=$(trim "$hostname")
    port=$(trim "$port")
    username=$(trim "$username")

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
            "${username}@${hostname}" \
            ${remote_cmd[@]+"${remote_cmd[@]}"}
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
            -o "NumberOfPasswordPrompts=1" \
            ${extra_args[@]+"${extra_args[@]}"} \
            "${username}@${hostname}" \
            ${remote_cmd[@]+"${remote_cmd[@]}"}
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
    if ! items=$(bw_list_ssh_items); then
        exit 1
    fi

    if [ -z "$items" ]; then
        err "No SSH items found in vault."
        err "(Items must be in '${BWSSH_FOLDER}' folder, or have private key in custom field / Notes, or ssh:// URI)"
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
    local items
    if ! items=$(bw_list_ssh_items); then
        exit 1
    fi

    if [ -z "$items" ]; then
        info "No SSH items found in vault."
        return 0
    fi

    printf "${BOLD}%-28s %-12s %-22s %-6s${RESET}\n" "NAME" "USER" "HOST" "AUTH"
    printf '%0.s─' {1..72}; echo
    echo "$items" | awk -F'\t' '{printf "%-28s %-12s %-22s [%s]\n", $1, $2, $3, $4}'
    echo ""
}

# ─── Stop Server ──────────────────────────────────────────────────────────────
cmd_stop() {
    local stopped=false
    if [ -f "$BW_SERVE_PID_FILE" ]; then
        local pid
        pid=$(cat "$BW_SERVE_PID_FILE" 2>/dev/null || true)
        if [ -n "$pid" ] && kill "$pid" 2>/dev/null; then
            stopped=true
            ok "bw serve (PID ${pid}) stopped."
        fi
        rm -f "$BW_SERVE_PID_FILE"
    fi

    local port_pids
    port_pids=$(lsof -ti ":${BW_SERVE_PORT}" 2>/dev/null || true)
    if [ -n "$port_pids" ]; then
        kill $port_pids 2>/dev/null || true
        stopped=true
        ok "Killed process on port ${BW_SERVE_PORT}."
    fi

    if [ "$stopped" = "false" ]; then
        info "bw serve was not running."
    fi
}

# ─── Sync ─────────────────────────────────────────────────────────────────────
cmd_sync() {
    info "Syncing vault with Bitwarden cloud..."
    bw sync --session "$BW_SESSION"
    ok "Synced. Refreshing local server..."
    cmd_stop
    bw_start_serve
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-}"

    # Handle standalone commands that don't need active session/server
    case "$cmd" in
        --stop)
            cmd_stop
            return 0
            ;;
        --help|-h)
            echo "Usage: bwssh [name [command...]] | --list | --add-key [name] | --stop | --sync"
            return 0
            ;;
    esac

    bw_check_dependencies
    bw_ensure_session

    # Handle sync before starting serve
    case "$cmd" in
        --sync|-s)
            cmd_sync
            return 0
            ;;
    esac

    bw_ensure_serve

    case "$cmd" in
        --list|-l)
            cmd_list
            ;;
        --add-key|-k)
            shift
            local name="${1:-}"
            [ -z "$name" ] && name=$(pick_item_interactive)
            [ -n "$name" ] && do_connect "$name" true
            ;;
        "")
            local name
            name=$(pick_item_interactive)
            [ -n "$name" ] && do_connect "$name" false
            ;;
        -*)
            err "Unknown option: $cmd"
            echo "Usage: bwssh [name [command...]] | --list | --add-key [name] | --stop | --sync"
            exit 1
            ;;
        *)
            shift
            do_connect "$cmd" false "$@"
            ;;
    esac
}

main "$@"
