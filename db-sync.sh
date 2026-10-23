#!/usr/bin/env bash
#
# db-sync.sh — Sync the database between the live server and your local environment.
#
# Pulls live → local by default; pass --push to send local → live.
#
# Requirements:
#   - SSH access to the production server (Laravel Forge / Cloud).
#   - mysqldump available locally and on the server.
#   - Local DB credentials are read from .env automatically.
#
# Usage:
#   bash scripts/db-sync.sh forge@example.test
#   bash scripts/db-sync.sh forge@example.test mysite
#   bash scripts/db-sync.sh --ssh-host=example.test --ssh-user=forge
#   bash scripts/db-sync.sh forge@example.test --push
#   bash scripts/db-sync.sh forge@example.test --add-drop-database
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
    echo "  user@host             SSH user and host (e.g. forge@example.test)"
    echo "  db-name               Remote database name (default: project folder name)"
    echo ""
    echo "Required (if not using positional args):"
    echo "  --ssh-host=HOST       Hostname or IP of the production server"
    echo "  --ssh-user=USER       SSH username (e.g. forge)"
    echo "  --db-name=NAME        Remote database name"
    echo ""
    echo "Direction:"
    echo "  --pull, --from-live   Copy the live database to local (default)"
    echo "  --push, --to-live     Copy the local database to live (DESTRUCTIVE)"
    echo ""
    echo "Optional:"
    echo "  --db-user=USER        Remote DB username (overrides remote .env)"
    echo "  --db-pass=PASS        Remote DB password (overrides remote .env)"
    echo "  --db-host=HOST        Remote DB host as seen from the server (overrides remote .env)"
    echo "  --db-port=PORT        Remote DB port (overrides remote .env)"
    echo "  --project=PATH        Local project root holding .env (default: current directory)"
    echo "  --remote-env=PATH     Path to .env on the server, or to the site directory; relative"
    echo "                        to the home directory (default: ~/HOST/.env, else the only"
    echo "                        ~/*/.env with database settings)"
    echo "  --ssh-port=PORT       SSH port (default: 22)"
    echo "  --ssh-key=PATH        Path to SSH private key (default: SSH agent)"
    echo "  --add-drop-database   Dump with --add-drop-database --databases, so the target"
    echo "                        database is dropped and recreated before the import"
    echo "  -y, --yes             Skip the confirmation prompt (pull only)"
    echo "  --force-push          Skip the confirmation prompt when pushing to live"
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
FORCE_PUSH=""
DIRECTION="pull"
ADD_DROP_DATABASE=""

for arg in "$@"; do
    case "$arg" in
        --push|--to-live)   DIRECTION="push" ;;
        --pull|--from-live) DIRECTION="pull" ;;
        --force-push)       FORCE_PUSH="1" ;;
        --add-drop-database) ADD_DROP_DATABASE="1" ;;
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

if [[ -z "$PROD_SSH_HOST" || -z "$PROD_SSH_USER" ]]; then
    echo "Error: SSH host and SSH user are required."
    usage
    exit 1
fi

# ── Build SSH options ────────────────────────────────────────────────────────

# accept-new, niet no: een onbekende host wordt zonder vragen toegevoegd, maar een
# veranderde hostkey blijft een harde fout. Met "no" zou een omgeleide verbinding
# stilzwijgend geaccepteerd worden, en daar gaan wel de productie-credentials overheen.
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -p "$PROD_SSH_PORT")
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
              -e 's/^"//' -e 's/"$//' || true
}

# Every file the lookup prints is preceded by a marker line with its path, so the
# output can hold several .env files and the run shows which one it used.
ENV_MARKER="# db-sync-env: "

# A relative path is taken from the home directory, and a path to the site directory
# gets its .env added, so --remote-env=example.test is enough. The ~ is left for the
# remote shell to expand.
if [[ -n "$REMOTE_ENV_PATH" ]]; then
    [[ "$REMOTE_ENV_PATH" == /* || "$REMOTE_ENV_PATH" == "~"* ]] || REMOTE_ENV_PATH="~/$REMOTE_ENV_PATH"
    [[ "$REMOTE_ENV_PATH" == */.env ]] || REMOTE_ENV_PATH="${REMOTE_ENV_PATH%/}/.env"
fi

if [[ -n "$REMOTE_ENV_PATH" ]]; then
    echo "  Reading remote .env from $PROD_SSH_USER@$PROD_SSH_HOST:$REMOTE_ENV_PATH..."
    REMOTE_ENV_LOOKUP="f=$REMOTE_ENV_PATH; if [ -f \"\$f\" ]; then echo \"$ENV_MARKER\$f\"; cat \"\$f\"; echo; fi"
else
    # The Forge convention is ~/SITE/.env, but SITE is the site's directory name,
    # which only matches the SSH host when you connect by domain. Connecting by IP
    # (or to a *.on-forge.com site) needs the ~/*/.env files in the home directory,
    # and one user can hold several sites, so all of them are fetched and picked below.
    echo "  Looking for the remote .env on $PROD_SSH_USER@$PROD_SSH_HOST..."
    REMOTE_ENV_LOOKUP="for f in ~/*/.env; do
        if [ -f \"\$f\" ]; then echo \"$ENV_MARKER\$f\"; cat \"\$f\"; echo; fi
    done"
fi

# -n keeps ssh from swallowing stdin, which the confirmation prompt still needs.
# Exit status 255 is ssh itself failing, as opposed to the remote command.
SSH_STATUS=0
REMOTE_ENV_OUTPUT="$(ssh -n "${SSH_OPTS[@]}" "$PROD_SSH_USER@$PROD_SSH_HOST" "$REMOTE_ENV_LOOKUP" 2>/dev/null)" || SSH_STATUS=$?
if [[ "$SSH_STATUS" == "255" ]]; then
    echo "Error: Could not connect to $PROD_SSH_USER@$PROD_SSH_HOST over SSH."
    exit 1
fi

# The contents of one file from the lookup output, by its path.
remote_env_file() {
    local path="$1"
    echo "$REMOTE_ENV_OUTPUT" | awk -v marker="$ENV_MARKER$path" -v prefix="$ENV_MARKER" '
        index($0, prefix) == 1 { inside = ($0 == marker); next }
        inside { print }'
}

REMOTE_ENV_PATHS=()
while IFS= read -r line; do
    REMOTE_ENV_PATHS+=("${line#"$ENV_MARKER"}")
done < <(echo "$REMOTE_ENV_OUTPUT" | grep -F "$ENV_MARKER" || true)

if [[ -n "$REMOTE_ENV_PATH" ]]; then
    if [[ ${#REMOTE_ENV_PATHS[@]} -eq 0 ]]; then
        echo "Error: $REMOTE_ENV_PATH not found on $PROD_SSH_HOST."
        exit 1
    fi
    REMOTE_ENV_PATH="${REMOTE_ENV_PATHS[0]}"
else
    # Pick the site directory named after the SSH host. Otherwise only the files that
    # configure a database count, narrowed to the requested database name if one was
    # given. A site without a database (a static site, or one on SQLite) is skipped.
    CANDIDATES=()
    for path in ${REMOTE_ENV_PATHS[@]+"${REMOTE_ENV_PATHS[@]}"}; do
        if [[ "$path" == */"$PROD_SSH_HOST"/.env ]]; then
            CANDIDATES=("$path")
            break
        fi
        content="$(remote_env_file "$path")"
        name="$(remote_env_value DB_DATABASE "$content")"
        [[ -z "$name" ]] && continue
        [[ -n "$PROD_DB_DATABASE" && "$name" != "$PROD_DB_DATABASE" ]] && continue
        CANDIDATES+=("$path")
    done

    if [[ ${#CANDIDATES[@]} -gt 1 ]]; then
        echo "Error: Several sites on $PROD_SSH_HOST configure a database:"
        printf '         %s\n' "${CANDIDATES[@]}"
        echo "       Pick one with --remote-env=PATH, or name the database as the second argument."
        exit 1
    fi
    REMOTE_ENV_PATH="${CANDIDATES[0]-}"
fi

REMOTE_ENV_CONTENT=""
if [[ -n "$REMOTE_ENV_PATH" ]]; then
    REMOTE_ENV_CONTENT="$(remote_env_file "$REMOTE_ENV_PATH")"
    echo "  Found $REMOTE_ENV_PATH"
    if [[ -z "$(remote_env_value DB_DATABASE "$REMOTE_ENV_CONTENT")" ]]; then
        echo "  Warning: $REMOTE_ENV_PATH has no DB_DATABASE, so the defaults below are guesses."
    fi
fi

if [[ -z "$REMOTE_ENV_CONTENT" ]]; then
    echo "  Warning: No remote .env with database settings${PROD_DB_DATABASE:+ for '$PROD_DB_DATABASE'} found. Falling back to flag values."
else
    # Use remote .env values as defaults (flags take precedence)
    [[ -z "$PROD_DB_DATABASE" ]] && PROD_DB_DATABASE="$(remote_env_value DB_DATABASE "$REMOTE_ENV_CONTENT")"
    [[ -z "$PROD_DB_USERNAME" ]] && PROD_DB_USERNAME="$(remote_env_value DB_USERNAME "$REMOTE_ENV_CONTENT")"
    [[ -z "$PROD_DB_PASSWORD" ]] && PROD_DB_PASSWORD="$(remote_env_value DB_PASSWORD "$REMOTE_ENV_CONTENT")"
    [[ -z "$PROD_DB_HOST" ]]     && PROD_DB_HOST="$(remote_env_value DB_HOST "$REMOTE_ENV_CONTENT")"
    [[ -z "$PROD_DB_PORT" ]]     && PROD_DB_PORT="$(remote_env_value DB_PORT "$REMOTE_ENV_CONTENT")"
fi

# Apply final fallbacks: flags win, then the remote .env, then these.
PROD_DB_HOST="${PROD_DB_HOST:-127.0.0.1}"
PROD_DB_PORT="${PROD_DB_PORT:-3306}"
PROD_DB_USERNAME="${PROD_DB_USERNAME:-$PROD_SSH_USER}"
PROD_DB_DATABASE="${PROD_DB_DATABASE:-$(basename "$PROJECT_ROOT" | tr '[:upper:]' '[:lower:]')}"

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
              -e 's/^"//' -e 's/"$//' || true
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

LOCAL_MYSQL_OPTS=(--host="$LOCAL_DB_HOST" --port="$LOCAL_DB_PORT" --user="$LOCAL_DB_USERNAME")

# Without --add-drop-database the dump has no CREATE DATABASE, and mysql refuses to
# import into a database that does not exist yet, as on a fresh checkout. Check it
# here, so a missing database or a broken local connection stops the run before
# anything goes over SSH. SHOW DATABASES LIKE would treat _ in the name as a wildcard.
CREATE_LOCAL_DATABASE=""
if [[ "$DIRECTION" == "pull" && -z "$ADD_DROP_DATABASE" ]]; then
    LOCAL_DB_EXISTS="$(MYSQL_PWD="$LOCAL_DB_PASSWORD" mysql "${LOCAL_MYSQL_OPTS[@]}" -N -B -e \
        "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '${LOCAL_DB_DATABASE//\'/\'\'}'")" || {
        echo "Error: Could not connect to the local database server at $LOCAL_DB_HOST:$LOCAL_DB_PORT."
        exit 1
    }
    if [[ "$LOCAL_DB_EXISTS" == "0" ]]; then
        CREATE_LOCAL_DATABASE="1"
    fi
fi

# ── Check the live database ──────────────────────────────────────────────────

# The remote command is a single string re-parsed by the remote shell, so every
# value interpolated into it has to be quoted for that shell.
REMOTE_CONN="--host=$(printf '%q' "$PROD_DB_HOST") \
    --port=$(printf '%q' "$PROD_DB_PORT") \
    --user=$(printf '%q' "$PROD_DB_USERNAME")"

REMOTE_PWD_PREFIX=""
if [[ -n "$PROD_DB_PASSWORD" ]]; then
    REMOTE_PWD_PREFIX="MYSQL_PWD=$(printf '%q' "$PROD_DB_PASSWORD") "
fi

# Wrong or missing live credentials would otherwise only show once the sync runs.
# Only a push with --add-drop-database may target a live database that is not there.
REMOTE_CHECK_TARGET=" $(printf '%q' "$PROD_DB_DATABASE")"
if [[ "$DIRECTION" == "push" && -n "$ADD_DROP_DATABASE" ]]; then
    REMOTE_CHECK_TARGET=""
fi

REMOTE_CHECK_ERROR="$(ssh -n "${SSH_OPTS[@]}" "$PROD_SSH_USER@$PROD_SSH_HOST" \
    "${REMOTE_PWD_PREFIX}mysql $REMOTE_CONN -N -B -e 'SELECT 1'$REMOTE_CHECK_TARGET 2>&1 >/dev/null")" || {
    echo "Error: Could not open live database '$PROD_DB_DATABASE' as '$PROD_DB_USERNAME' on $PROD_SSH_HOST:"
    echo "       $REMOTE_CHECK_ERROR"
    exit 1
}

# ── Confirmation prompt ──────────────────────────────────────────────────────

echo ""

if [[ "$DIRECTION" == "push" ]]; then
    echo "  Source: local $LOCAL_DB_DATABASE @ $LOCAL_DB_HOST:$LOCAL_DB_PORT"
    echo "  Target: LIVE  $PROD_DB_DATABASE @ $PROD_SSH_HOST (via SSH)"
    echo ""
    echo "  WARNING: This will OVERWRITE the LIVE database."
    if [[ -n "$ADD_DROP_DATABASE" ]]; then
        echo "  WARNING: Live database '$PROD_DB_DATABASE' is DROPPED and recreated first."
    fi
    echo ""

    # -y is deliberately not honoured here: pushing to live needs its own opt-in.
    if [[ -z "$FORCE_PUSH" ]]; then
        CONFIRM=""
        read -rp "  Type the live database name ($PROD_DB_DATABASE) to continue: " CONFIRM || true
        echo ""

        if [[ "$CONFIRM" != "$PROD_DB_DATABASE" ]]; then
            echo "Aborted."
            exit 0
        fi
    fi
else
    echo "  Live database : $PROD_DB_DATABASE @ $PROD_SSH_HOST (via SSH)"
    echo "  Local database: $LOCAL_DB_DATABASE @ $LOCAL_DB_HOST:$LOCAL_DB_PORT"
    echo ""
    if [[ -n "$CREATE_LOCAL_DATABASE" ]]; then
        # Asked rather than assumed: a typo in DB_DATABASE would otherwise quietly
        # leave a stray database behind.
        echo "  Local database '$LOCAL_DB_DATABASE' does not exist. It will be created and filled."
    else
        echo "  WARNING: This will OVERWRITE your local database."
    fi
    if [[ -n "$ADD_DROP_DATABASE" ]]; then
        echo "  WARNING: Local database '$LOCAL_DB_DATABASE' is DROPPED and recreated first."
    fi
    echo ""

    if [[ -z "$ASSUME_YES" ]]; then
        CONFIRM=""
        read -rp "  Proceed? [y/N] " CONFIRM || true
        echo ""

        if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
            echo "Aborted."
            exit 0
        fi
    fi
fi

# ── Build the commands ───────────────────────────────────────────────────────

# --add-drop-database only takes effect together with --databases, which also makes
# mysqldump emit the CREATE DATABASE and USE statements the DROP has to be followed by.
DUMP_DATABASE_OPTS=""
if [[ -n "$ADD_DROP_DATABASE" ]]; then
    DUMP_DATABASE_OPTS="--add-drop-database --databases"
fi

# Those statements carry the SOURCE database name, so an import into a target with a
# different name would recreate and fill the source name instead. Rewrite the three
# statements that mention it; the rest of the dump never names the database.
#
# mysqldump wraps the DROP in a versioned comment (/*!40000 DROP DATABASE ...*/;), so
# the lines are matched on the statement anywhere in the line, not at its start.
rewrite_database_name() {
    local from="$1" to="$2" bt='`'

    if [[ -z "$ADD_DROP_DATABASE" || "$from" == "$to" ]]; then
        cat
        return
    fi

    local from_pattern
    from_pattern="$(printf '%s' "$from" | sed -e 's/[][\\.*^$|&/]/\\&/g')"

    sed \
        -e "/DROP DATABASE IF EXISTS ${bt}${from_pattern}${bt}/s|${bt}${from_pattern}${bt}|${bt}${to}${bt}|" \
        -e "/CREATE DATABASE .*${bt}${from_pattern}${bt}/s|${bt}${from_pattern}${bt}|${bt}${to}${bt}|" \
        -e "/^USE ${bt}${from_pattern}${bt};/s|${bt}${from_pattern}${bt}|${bt}${to}${bt}|"
}

# A backtick in a database name would end the identifier the rewrite matches on.
if [[ -n "$ADD_DROP_DATABASE" && "$PROD_DB_DATABASE" != "$LOCAL_DB_DATABASE" ]]; then
    for name in "$PROD_DB_DATABASE" "$LOCAL_DB_DATABASE"; do
        if [[ "$name" == *'`'* ]]; then
            echo "Error: --add-drop-database cannot rename a database whose name contains a backtick."
            exit 1
        fi
    done
fi

REMOTE_DUMP_CMD="${REMOTE_PWD_PREFIX}mysqldump $REMOTE_CONN \
    --single-transaction \
    --no-tablespaces \
    --skip-lock-tables \
    $DUMP_DATABASE_OPTS \
    $(printf '%q' "$PROD_DB_DATABASE")"

# A dump that drops and recreates the database selects it itself, and naming it on the
# command line would fail while it does not exist yet.
REMOTE_IMPORT_TARGET=" $(printf '%q' "$PROD_DB_DATABASE")"
if [[ -n "$ADD_DROP_DATABASE" ]]; then
    REMOTE_IMPORT_TARGET=""
fi

REMOTE_IMPORT_CMD="${REMOTE_PWD_PREFIX}mysql $REMOTE_CONN$REMOTE_IMPORT_TARGET"

LOCAL_DUMP_OPTS=("${LOCAL_MYSQL_OPTS[@]}" --single-transaction --no-tablespaces --skip-lock-tables $DUMP_DATABASE_OPTS)

LOCAL_IMPORT_OPTS=("${LOCAL_MYSQL_OPTS[@]}")
if [[ -z "$ADD_DROP_DATABASE" ]]; then
    LOCAL_IMPORT_OPTS+=("$LOCAL_DB_DATABASE")
fi

# ── Run the sync ─────────────────────────────────────────────────────────────

if [[ "$DIRECTION" == "push" ]]; then
    echo "  Dumping local database and importing it on the live server..."
    echo ""

    # Without the check, set -e would stop on a failed pipe without saying so.
    if ! MYSQL_PWD="$LOCAL_DB_PASSWORD" mysqldump "${LOCAL_DUMP_OPTS[@]}" "$LOCAL_DB_DATABASE" \
        | rewrite_database_name "$LOCAL_DB_DATABASE" "$PROD_DB_DATABASE" \
        | ssh "${SSH_OPTS[@]}" "$PROD_SSH_USER@$PROD_SSH_HOST" "$REMOTE_IMPORT_CMD"; then
        echo ""
        echo "Error: The sync failed. Live database '$PROD_DB_DATABASE' may be partly updated."
        exit 1
    fi

    echo "  Done! Live database '$PROD_DB_DATABASE' has been updated."
    echo ""
else
    if [[ -n "$CREATE_LOCAL_DATABASE" ]]; then
        echo "  Creating local database '$LOCAL_DB_DATABASE'..."
        MYSQL_PWD="$LOCAL_DB_PASSWORD" mysql "${LOCAL_MYSQL_OPTS[@]}" \
            -e "CREATE DATABASE \`${LOCAL_DB_DATABASE//\`/\`\`}\`"
    fi

    echo "  Dumping live database via SSH..."
    echo ""

    if ! ssh "${SSH_OPTS[@]}" "$PROD_SSH_USER@$PROD_SSH_HOST" "$REMOTE_DUMP_CMD" \
        | rewrite_database_name "$PROD_DB_DATABASE" "$LOCAL_DB_DATABASE" \
        | MYSQL_PWD="$LOCAL_DB_PASSWORD" mysql "${LOCAL_IMPORT_OPTS[@]}"; then
        echo ""
        echo "Error: The sync failed. Local database '$LOCAL_DB_DATABASE' may be partly updated."
        exit 1
    fi

    echo "  Done! Local database '$LOCAL_DB_DATABASE' has been updated."
    echo ""
fi
