#!/usr/bin/env bash
#
# db-clonio.sh — Pull the live database to local with anonymized PII.
#
# The safe counterpart of db-sync.sh: instead of a raw mysqldump it runs Clonio,
# which reads the live database row by row and applies the per-column strategies
# from a .cloning.yaml before writing into the local database. Raw rows travel
# through the SSH tunnel into the Clonio process, but are never written to disk
# unanonymized.
#
# Requirements:
#   - clonio on the PATH (https://github.com/clonio-dev/clonio-cli)
#   - SSH access to the production server (Laravel Forge / Cloud).
#   - A .cloning.yaml in the project, and a `local` connection in clonio.json.
#   - Local DB credentials are read from .env automatically (by Clonio).
#
# Usage:
#   bash scripts/db-clonio.sh forge@example.test
#   bash scripts/db-clonio.sh forge@example.test --config=production.cloning.yaml
#   bash scripts/db-clonio.sh forge@example.test --dry-run
#
# Production credentials are read from the remote .env and registered as a
# temporary Clonio connection, which is deleted again when the script exits —
# they are never stored in clonio.json between runs.

set -euo pipefail

# The script lives in a shared scripts/ directory, so the project is wherever it
# is invoked from, not where the script itself sits. Override with --project=PATH.
PROJECT_ROOT="$PWD"

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
    echo ""
    echo "Usage: bash db-clonio.sh [user@host] [OPTIONS]"
    echo ""
    echo "Positional:"
    echo "  user@host             SSH user and host (e.g. forge@example.test)"
    echo ""
    echo "Optional:"
    echo "  --config=PATH         Cloning config (default: production.cloning.yaml)"
    echo "  --target=NAME         Target connection from clonio.json (default: local)"
    echo "  --skip-tables=LIST    Comma-separated tables to exclude (default: caches,"
    echo "                        queues, sessions and other tables that are pure PII)"
    echo "  --db-name=NAME        Remote database name (overrides remote .env)"
    echo "  --db-user=USER        Remote DB username (overrides remote .env)"
    echo "  --db-pass=PASS        Remote DB password (overrides remote .env)"
    echo "  --db-host=HOST        Remote DB host as seen from the server (default: 127.0.0.1)"
    echo "  --db-port=PORT        Remote DB port as seen from the server (default: 3306)"
    echo "  --project=PATH        Local project root holding .env (default: current directory)"
    echo "  --remote-env=PATH     Path to .env on the server (default: ~/HOST/.env)"
    echo "  --ssh-host=HOST       Hostname or IP of the production server"
    echo "  --ssh-user=USER       SSH username (e.g. forge)"
    echo "  --ssh-port=PORT       SSH port (default: 22)"
    echo "  --ssh-key=PATH        Path to SSH private key (default: SSH agent)"
    echo "  --tunnel-port=PORT    Local port for the SSH tunnel (default: 13306)"
    echo "  --dry-run             Validate the config and count rows, transfer nothing"
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
CLONING_CONFIG="production.cloning.yaml"
TARGET="local"
TUNNEL_PORT="13306"
DRY_RUN=""

# Tables that hold nothing but PII, caches or queue state. They are excluded from
# the config as well; passing them here too means a table that is accidentally
# added to the config later still cannot slip through unnoticed.
SKIP_TABLES="cache,cache_locks,failed_jobs,invoice_email_events,job_batches,jobs,passkeys,password_reset_tokens,sessions,team_invitations"

for arg in "$@"; do
    case "$arg" in
        --config=*)      CLONING_CONFIG="${arg#*=}" ;;
        --target=*)      TARGET="${arg#*=}" ;;
        --skip-tables=*) SKIP_TABLES="${arg#*=}" ;;
        --ssh-host=*)    PROD_SSH_HOST="${arg#*=}" ;;
        --ssh-user=*)    PROD_SSH_USER="${arg#*=}" ;;
        --ssh-port=*)    PROD_SSH_PORT="${arg#*=}" ;;
        --ssh-key=*)     PROD_SSH_KEY="${arg#*=}" ;;
        --db-host=*)     PROD_DB_HOST="${arg#*=}" ;;
        --db-port=*)     PROD_DB_PORT="${arg#*=}" ;;
        --db-name=*)     PROD_DB_DATABASE="${arg#*=}" ;;
        --db-user=*)     PROD_DB_USERNAME="${arg#*=}" ;;
        --db-pass=*)     PROD_DB_PASSWORD="${arg#*=}" ;;
        --project=*)     PROJECT_ROOT="$(cd "${arg#*=}" && pwd)" ;;
        --remote-env=*)  REMOTE_ENV_PATH="${arg#*=}" ;;
        --tunnel-port=*) TUNNEL_PORT="${arg#*=}" ;;
        --dry-run)       DRY_RUN="1" ;;
        -h|--help)       usage; exit 0 ;;
        *@*)
            # Accept user@host as a positional argument
            PROD_SSH_USER="${arg%%@*}"
            PROD_SSH_HOST="${arg#*@}"
            ;;
        *)
            echo "Unknown option: $arg"; usage; exit 1
            ;;
    esac
done

if [[ -z "$PROD_SSH_HOST" || -z "$PROD_SSH_USER" ]]; then
    echo "Error: SSH host and SSH user are required."
    usage
    exit 1
fi

if ! command -v clonio >/dev/null 2>&1; then
    echo "Error: clonio is not on your PATH."
    echo "Install it from https://github.com/clonio-dev/clonio-cli/releases"
    exit 1
fi

# Clonio reads clonio.json and the config from the working directory, and needs
# APP_KEY from the project's .env to decrypt connection passwords.
cd "$PROJECT_ROOT"

if [[ ! -f "$CLONING_CONFIG" ]]; then
    echo "Error: cloning config '$CLONING_CONFIG' not found in $PROJECT_ROOT"
    echo "Generate a starting point with: clonio cloning:dump --connection <name>"
    exit 1
fi

# ── Build SSH options ────────────────────────────────────────────────────────

SSH_OPTS=(-o StrictHostKeyChecking=no -p "$PROD_SSH_PORT")
if [[ -n "$PROD_SSH_KEY" ]]; then
    PROD_SSH_KEY="${PROD_SSH_KEY/#\~/$HOME}"
    SSH_OPTS+=(-i "$PROD_SSH_KEY")
fi

# ── Read remote .env ─────────────────────────────────────────────────────────

echo ""

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

if [[ -n "$REMOTE_ENV_PATH" ]]; then
    echo "  Reading remote .env from $PROD_SSH_USER@$PROD_SSH_HOST:$REMOTE_ENV_PATH..."
    REMOTE_ENV_LOOKUP="cat $REMOTE_ENV_PATH"
else
    # Same convention as db-sync.sh: ~/SITE/.env, falling back to the single
    # ~/*/.env in the home directory when connecting by IP.
    echo "  Looking for the remote .env on $PROD_SSH_USER@$PROD_SSH_HOST..."
    REMOTE_ENV_LOOKUP="for f in ~/$PROD_SSH_HOST/.env ~/*/.env; do
        if [ -f \"\$f\" ]; then echo \"# db-clonio-env: \$f\"; cat \"\$f\"; exit 0; fi
    done"
fi

REMOTE_ENV_CONTENT="$(ssh -n "${SSH_OPTS[@]}" "$PROD_SSH_USER@$PROD_SSH_HOST" "$REMOTE_ENV_LOOKUP" 2>/dev/null || true)"

REMOTE_ENV_FOUND="$(echo "$REMOTE_ENV_CONTENT" | grep -E '^# db-clonio-env: ' | head -1 | cut -d' ' -f3-)"
if [[ -n "$REMOTE_ENV_FOUND" ]]; then
    echo "  Found $REMOTE_ENV_FOUND"
fi

if [[ -z "$REMOTE_ENV_CONTENT" ]]; then
    echo "  Warning: Could not read a remote .env. Falling back to flag values."
else
    [[ -z "$PROD_DB_DATABASE" ]] && PROD_DB_DATABASE="$(remote_env_value DB_DATABASE "$REMOTE_ENV_CONTENT")"
    [[ -z "$PROD_DB_USERNAME" ]] && PROD_DB_USERNAME="$(remote_env_value DB_USERNAME "$REMOTE_ENV_CONTENT")"
    [[ -z "$PROD_DB_PASSWORD" ]] && PROD_DB_PASSWORD="$(remote_env_value DB_PASSWORD "$REMOTE_ENV_CONTENT")"
    [[ -z "$PROD_DB_HOST" ]]     && PROD_DB_HOST="$(remote_env_value DB_HOST "$REMOTE_ENV_CONTENT")"
    [[ -z "$PROD_DB_PORT" ]]     && PROD_DB_PORT="$(remote_env_value DB_PORT "$REMOTE_ENV_CONTENT")"
fi

PROD_DB_HOST="${PROD_DB_HOST:-127.0.0.1}"
PROD_DB_PORT="${PROD_DB_PORT:-3306}"
PROD_DB_USERNAME="${PROD_DB_USERNAME:-$PROD_SSH_USER}"
PROD_DB_DATABASE="${PROD_DB_DATABASE:-$(basename "$PROJECT_ROOT" | tr '[:upper:]' '[:lower:]')}"

echo ""
echo "  Source:  $PROD_DB_USERNAME@$PROD_DB_HOST:$PROD_DB_PORT/$PROD_DB_DATABASE (via SSH tunnel on port $TUNNEL_PORT)"
echo "  Target:  connection '$TARGET'"
echo "  Config:  $CLONING_CONFIG"
echo ""

# ── Open the tunnel and register a throwaway connection ──────────────────────

# Clonio has no SSH support of its own, so the production database is reached
# through a local port forward. The control socket lets the trap close the exact
# tunnel this script opened, without killing unrelated ssh processes.
TUNNEL_SOCKET="${TMPDIR:-/tmp}/db-clonio-$$.sock"
CONNECTION_NAME="clonio-tmp-source"

cleanup() {
    # The connection holds the production password (encrypted, but still) — it is
    # only meant to exist for the duration of this run.
    clonio connection:delete "$CONNECTION_NAME" --force >/dev/null 2>&1 || true

    if [[ -S "$TUNNEL_SOCKET" ]]; then
        ssh -S "$TUNNEL_SOCKET" -O exit "$PROD_SSH_USER@$PROD_SSH_HOST" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "  Opening SSH tunnel..."
ssh -fN -M -S "$TUNNEL_SOCKET" \
    -L "$TUNNEL_PORT:$PROD_DB_HOST:$PROD_DB_PORT" \
    "${SSH_OPTS[@]}" "$PROD_SSH_USER@$PROD_SSH_HOST"

# A leftover connection from an interrupted run would make connection:add fail.
clonio connection:delete "$CONNECTION_NAME" --force >/dev/null 2>&1 || true

clonio connection:add "$CONNECTION_NAME" \
    --type=mysql \
    --host=127.0.0.1 \
    --port="$TUNNEL_PORT" \
    --database="$PROD_DB_DATABASE" \
    --username="$PROD_DB_USERNAME" \
    --password="$PROD_DB_PASSWORD" \
    --production \
    --no-interaction >/dev/null

# ── Run ──────────────────────────────────────────────────────────────────────

# The config names its source connection, but this run uses the throwaway one,
# so the connection line is rewritten in a temporary copy. That copy lives in the
# project root because Clonio resolves paths relative to its working directory.
RUN_CONFIG=".db-clonio-run.cloning.yaml"
sed -e "s/^connection: .*/connection: $CONNECTION_NAME/" "$CLONING_CONFIG" > "$RUN_CONFIG"
trap 'rm -f "$PROJECT_ROOT/$RUN_CONFIG"; cleanup' EXIT

RUN_OPTS=(--target="$TARGET")
[[ -n "$SKIP_TABLES" ]] && RUN_OPTS+=(--skip-tables="$SKIP_TABLES")
[[ -n "$DRY_RUN" ]] && RUN_OPTS+=(--dry-run)

clonio cloning:run "$RUN_CONFIG" "${RUN_OPTS[@]}"
