#!/usr/bin/env bash
#
# db-sync.sh — Pull the live database down to your local environment.
#
# Requirements:
#   - SSH access to the production server (Laravel Forge / Cloud).
#   - mysqldump available locally and on the server.
#   - Local DB credentials are read from .env automatically.
#
# Usage:
#   bash scripts/db-sync.sh forge@bandpage.com
#   bash scripts/db-sync.sh forge@bandpage.com bandpage
#   bash scripts/db-sync.sh --ssh-host=bandpage.com --ssh-user=forge
#
set -euo pipefail

# The script lives in a shared scripts/ directory, so the project is wherever it
# is invoked from, not where the script itself sits. Override with --project=PATH.
PROJECT_ROOT="$PWD"

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
    echo ""
    echo "Usage: bash db-sync.sh [user@host] [db-name] [OPTIONS]"
    echo ""
    echo "Positional:"
    echo "  user@host             SSH user and host (e.g. forge@bandpage.com)"
    echo "  db-name               Remote database name (default: project folder name)"
    echo ""
    echo "Required (if not using positional args):"
    echo "  --ssh-host=HOST       Hostname or IP of the production server"
    echo "  --ssh-user=USER       SSH username (e.g. forge)"
    echo "  --db-name=NAME        Remote database name"
    echo ""
    echo "Optional:"
    echo "  --db-user=USER        Remote DB username (overrides remote .env)"
    echo "  --db-pass=PASS        Remote DB password (overrides remote .env)"
    echo "  --db-host=HOST        Remote DB host as seen from the server (overrides remote .env)"
    echo "  --db-port=PORT        Remote DB port (overrides remote .env)"
    echo "  --project=PATH        Local project root holding .env (default: current directory)"
    echo "  --remote-env=PATH     Path to .env on the server (default: ~/HOST/.env)"
    echo "  --ssh-port=PORT       SSH port (default: 22)"
    echo "  --ssh-key=PATH        Path to SSH private key (default: SSH agent)"
    echo "  -y, --yes             Skip the confirmation prompt"
    echo "  -h, --help            Show this help message"
    echo ""
}

# ── Parse arguments ──────────────────────────────────────────────────────────

PROD_SSH_HOST=""
PROD_SSH_USER=""
PROD_SSH_PORT="22"
PROD_SSH_KEY=""
PROD_DB_HOST=""
PROD_DB_PORT=""
PROD_DB_DATABASE=""
PROD_DB_USERNAME=""
PROD_DB_PASSWORD=""
REMOTE_ENV_PATH=""
ASSUME_YES=""

for arg in "$@"; do
    case "$arg" in
        --ssh-host=*)  PROD_SSH_HOST="${arg#*=}" ;;
        --ssh-user=*)  PROD_SSH_USER="${arg#*=}" ;;
        --ssh-port=*)  PROD_SSH_PORT="${arg#*=}" ;;
        --ssh-key=*)   PROD_SSH_KEY="${arg#*=}" ;;
        --db-host=*)       PROD_DB_HOST="${arg#*=}" ;;
        --db-port=*)       PROD_DB_PORT="${arg#*=}" ;;
        --db-name=*)       PROD_DB_DATABASE="${arg#*=}" ;;
        --db-user=*)       PROD_DB_USERNAME="${arg#*=}" ;;
        --db-pass=*)       PROD_DB_PASSWORD="${arg#*=}" ;;
        --project=*)       PROJECT_ROOT="$(cd "${arg#*=}" && pwd)" ;;
        --remote-env=*)    REMOTE_ENV_PATH="${arg#*=}" ;;
        -y|--yes)          ASSUME_YES="1" ;;
        -h|--help)         usage; exit 0 ;;
        *@*)
            # Accept user@host as a positional argument
            PROD_SSH_USER="${arg%%@*}"
            PROD_SSH_HOST="${arg#*@}"
            ;;
        *)
            # Second plain argument is the database name
            if [[ -z "$PROD_DB_DATABASE" && "$arg" != --* ]]; then
                PROD_DB_DATABASE="$arg"
            else
                echo "Unknown option: $arg"; usage; exit 1
            fi
            ;;
    esac
done

# Default db-user to the SSH user
PROD_DB_USERNAME="${PROD_DB_USERNAME:-$PROD_SSH_USER}"

# Default db name to the lowercased project folder name
DEFAULT_DB_NAME="$(basename "$PROJECT_ROOT" | tr '[:upper:]' '[:lower:]')"
PROD_DB_DATABASE="${PROD_DB_DATABASE:-$DEFAULT_DB_NAME}"

if [[ -z "$PROD_SSH_HOST" || -z "$PROD_SSH_USER" ]]; then
    echo "Error: SSH host and SSH user are required."
    usage
    exit 1
fi

# ── Build SSH options ────────────────────────────────────────────────────────

SSH_OPTS=(-o StrictHostKeyChecking=no -p "$PROD_SSH_PORT")
if [[ -n "$PROD_SSH_KEY" ]]; then
    PROD_SSH_KEY="${PROD_SSH_KEY/#\~/$HOME}"
    SSH_OPTS+=(-i "$PROD_SSH_KEY")
fi

# ── Read remote .env ─────────────────────────────────────────────────────────

# Default Forge path: ~/HOST/.env (e.g. /home/forge/bandpage.com/.env)
REMOTE_ENV_PATH="${REMOTE_ENV_PATH:-~/$PROD_SSH_HOST/.env}"

echo ""
echo "  Reading remote .env from $PROD_SSH_USER@$PROD_SSH_HOST:$REMOTE_ENV_PATH..."

remote_env_value() {
    local key="$1" content="$2"
    echo "$content" \
        | grep -E "^${key}=" \
        | head -1 \
        | cut -d'=' -f2- \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
              -e "s/^'//" -e "s/'$//" \
              -e 's/^"//' -e 's/"$//'
}

REMOTE_ENV_CONTENT="$(ssh "${SSH_OPTS[@]}" "$PROD_SSH_USER@$PROD_SSH_HOST" "cat $REMOTE_ENV_PATH" 2>/dev/null || true)"

if [[ -z "$REMOTE_ENV_CONTENT" ]]; then
    echo "  Warning: Could not read remote .env at $REMOTE_ENV_PATH. Falling back to flag values."
else
    # Use remote .env values as defaults (flags take precedence)
    [[ -z "$PROD_DB_DATABASE" ]] && PROD_DB_DATABASE="$(remote_env_value DB_DATABASE "$REMOTE_ENV_CONTENT")"
    [[ -z "$PROD_DB_USERNAME" ]] && PROD_DB_USERNAME="$(remote_env_value DB_USERNAME "$REMOTE_ENV_CONTENT")"
    [[ -z "$PROD_DB_PASSWORD" ]] && PROD_DB_PASSWORD="$(remote_env_value DB_PASSWORD "$REMOTE_ENV_CONTENT")"
    [[ -z "$PROD_DB_HOST" ]]     && PROD_DB_HOST="$(remote_env_value DB_HOST "$REMOTE_ENV_CONTENT")"
    [[ -z "$PROD_DB_PORT" ]]     && PROD_DB_PORT="$(remote_env_value DB_PORT "$REMOTE_ENV_CONTENT")"
fi

# Apply final fallbacks
PROD_DB_HOST="${PROD_DB_HOST:-127.0.0.1}"
PROD_DB_PORT="${PROD_DB_PORT:-3306}"

# ── Read local credentials from .env ─────────────────────────────────────────

LOCAL_ENV="$PROJECT_ROOT/.env"

if [[ ! -f "$LOCAL_ENV" ]]; then
    echo "Error: $LOCAL_ENV not found."
    exit 1
fi

env_value() {
    local key="$1"
    grep -E "^${key}=" "$LOCAL_ENV" \
        | head -1 \
        | cut -d'=' -f2- \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
              -e "s/^'//" -e "s/'$//" \
              -e 's/^"//' -e 's/"$//'
}

LOCAL_DB_HOST="$(env_value DB_HOST)"; LOCAL_DB_HOST="${LOCAL_DB_HOST:-127.0.0.1}"
LOCAL_DB_PORT="$(env_value DB_PORT)"; LOCAL_DB_PORT="${LOCAL_DB_PORT:-3306}"
LOCAL_DB_DATABASE="$(env_value DB_DATABASE)"
LOCAL_DB_USERNAME="$(env_value DB_USERNAME)"
LOCAL_DB_PASSWORD="$(env_value DB_PASSWORD)"

if [[ -z "$LOCAL_DB_DATABASE" || -z "$LOCAL_DB_USERNAME" ]]; then
    echo "Error: Missing DB_DATABASE or DB_USERNAME in $LOCAL_ENV."
    exit 1
fi

# ── Confirmation prompt ──────────────────────────────────────────────────────

echo ""
echo "  Live database : $PROD_DB_DATABASE @ $PROD_SSH_HOST (via SSH)"
echo "  Local database: $LOCAL_DB_DATABASE @ $LOCAL_DB_HOST:$LOCAL_DB_PORT"
echo ""
echo "  WARNING: This will OVERWRITE your local database."
echo ""

if [[ -z "$ASSUME_YES" ]]; then
    read -rp "  Proceed? [y/N] " CONFIRM
    echo ""

    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# ── Build remote mysqldump command ───────────────────────────────────────────

REMOTE_DUMP_CMD="mysqldump \
    --host=$PROD_DB_HOST \
    --port=$PROD_DB_PORT \
    --user=$PROD_DB_USERNAME \
    --single-transaction \
    --no-tablespaces \
    --skip-lock-tables"

if [[ -n "$PROD_DB_PASSWORD" ]]; then
    REMOTE_DUMP_CMD="MYSQL_PWD=$PROD_DB_PASSWORD $REMOTE_DUMP_CMD"
fi

REMOTE_DUMP_CMD="$REMOTE_DUMP_CMD $PROD_DB_DATABASE"

# ── Build local mysql import command ─────────────────────────────────────────

LOCAL_MYSQL_OPTS=(--host="$LOCAL_DB_HOST" --port="$LOCAL_DB_PORT" --user="$LOCAL_DB_USERNAME")

# ── Run the sync ─────────────────────────────────────────────────────────────

echo "  Dumping live database via SSH..."
echo ""

ssh "${SSH_OPTS[@]}" "$PROD_SSH_USER@$PROD_SSH_HOST" "$REMOTE_DUMP_CMD" \
    | MYSQL_PWD="$LOCAL_DB_PASSWORD" mysql "${LOCAL_MYSQL_OPTS[@]}" "$LOCAL_DB_DATABASE"

echo "  Done! Local database '$LOCAL_DB_DATABASE' has been updated."
echo ""
