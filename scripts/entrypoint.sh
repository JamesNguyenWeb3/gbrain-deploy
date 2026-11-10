#!/usr/bin/env bash
# ==============================================================================
# GBrain Production Entrypoint
#
# Supports three container roles sharing one image and persistent volume:
#   - serve     : HTTP MCP + OAuth 2.1 + Admin SPA server (runs init/migrations)
#   - worker    : Minions job supervisor (`gbrain jobs supervisor`)
#   - autopilot : Background maintenance daemon (`gbrain autopilot --no-worker`)
# ==============================================================================
set -euo pipefail

ROLE="${1:-serve}"
shift || true

export GBRAIN_HOME="${GBRAIN_HOME:-/srv/gbrain}"
export GBRAIN_REPO_PATH="${GBRAIN_REPO_PATH:-/srv/gbrain/brain}"
CONFIG_DIR="${GBRAIN_HOME}/.gbrain"
CONFIG_FILE="${CONFIG_DIR}/config.json"

mkdir -p "${CONFIG_DIR}" "${GBRAIN_REPO_PATH}" "${GBRAIN_HOME}/backups"
chmod 700 "${CONFIG_DIR}" || true

# Resolve Database URL (GBRAIN_DATABASE_URL takes precedence over DATABASE_URL)
DB_URL="${GBRAIN_DATABASE_URL:-${DATABASE_URL:-}}"
if [[ -z "${DB_URL}" ]]; then
  echo "[entrypoint] ERROR: GBRAIN_DATABASE_URL (or DATABASE_URL) is required in production." >&2
  exit 1
fi
export GBRAIN_DATABASE_URL="${DB_URL}"

# Wait for PostgreSQL to accept connections
echo "[entrypoint] Waiting for PostgreSQL to become ready..."
MAX_RETRIES="${GBRAIN_DB_WAIT_RETRIES:-30}"
RETRY=0
until pg_isready -d "${GBRAIN_DATABASE_URL}" >/dev/null 2>&1; do
  RETRY=$((RETRY + 1))
  if [[ "${RETRY}" -ge "${MAX_RETRIES}" ]]; then
    echo "[entrypoint] ERROR: PostgreSQL did not become ready after ${MAX_RETRIES} attempts." >&2
    exit 1
  fi
  sleep 2
done
echo "[entrypoint] PostgreSQL is accepting connections."

# Configure git identity for managed brain commits if not already set
if [[ -n "${GIT_AUTHOR_NAME:-}" ]]; then
  git config --global user.name "${GIT_AUTHOR_NAME}"
fi
if [[ -n "${GIT_AUTHOR_EMAIL:-}" ]]; then
  git config --global user.email "${GIT_AUTHOR_EMAIL}"
fi
git config --global --add safe.directory "${GBRAIN_REPO_PATH}" || true

# Initialize local git repo for brain checkout if empty
if [[ ! -d "${GBRAIN_REPO_PATH}/.git" ]]; then
  if [[ -n "${GBRAIN_GIT_REMOTE_URL:-}" ]]; then
    echo "[entrypoint] Cloning brain repository from ${GBRAIN_GIT_REMOTE_URL}..."
    git clone "${GBRAIN_GIT_REMOTE_URL}" "${GBRAIN_REPO_PATH}"
  else
    echo "[entrypoint] Initializing fresh Git repository in ${GBRAIN_REPO_PATH}..."
    git -C "${GBRAIN_REPO_PATH}" init -b main
  fi
fi

# ------------------------------------------------------------------------------
# First-boot initialization & schema migrations (owned by `serve` role)
# ------------------------------------------------------------------------------
if [[ "${ROLE}" == "serve" ]]; then
  # Ensure required extensions exist before init/migrations
  psql "${GBRAIN_DATABASE_URL}" -v ON_ERROR_STOP=1 -qc \
    "CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS pgcrypto;" \
    2>/dev/null || echo "[entrypoint] NOTE: Extension creation skipped (role may not be superuser; assuming extensions exist)."

  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "[entrypoint] No ${CONFIG_FILE} found — running first-boot gbrain init..."
    EMB_MODEL="${GBRAIN_EMBEDDING_MODEL:-openrouter:openai/text-embedding-3-small}"
    EMB_DIMS="${GBRAIN_EMBEDDING_DIMENSIONS:-1536}"
    EXP_MODEL="${GBRAIN_EXPANSION_MODEL:-openrouter:google/gemini-3-flash-preview}"
    CHAT_MODEL="${GBRAIN_CHAT_MODEL:-openrouter:anthropic/claude-sonnet-4.6}"
    SEARCH_MODE="${GBRAIN_SEARCH_MODE:-balanced}"

    /usr/local/bin/gbrain init \
      --non-interactive \
      --url "${GBRAIN_DATABASE_URL}" \
      --content-root "${GBRAIN_REPO_PATH}" \
      --embedding-model "${EMB_MODEL}" \
      --embedding-dimensions "${EMB_DIMS}" \
      --expansion-model "${EXP_MODEL}" \
      --chat-model "${CHAT_MODEL}" \
      --search-mode "${SEARCH_MODE}" \
      --skip-embed-check
  else
    echo "[entrypoint] Existing ${CONFIG_FILE} found — applying pending migrations..."
    /usr/local/bin/gbrain apply-migrations --yes --non-interactive --no-autopilot-install
  fi

  # Apply idempotent OpenRouter + System One (Jev) configuration if OPENROUTER_API_KEY is present
  if [[ -n "${OPENROUTER_API_KEY:-}" && "${GBRAIN_AUTO_CONFIGURE_OPENROUTER:-1}" == "1" ]]; then
    /usr/local/bin/gbrain-configure-openrouter
  fi
else
  # Worker and autopilot wait until `serve` has written config.json and migrated schema
  echo "[entrypoint] Role '${ROLE}' waiting for ${CONFIG_FILE} to be initialized by 'serve'..."
  WAIT_CFG=0
  until [[ -f "${CONFIG_FILE}" ]]; do
    WAIT_CFG=$((WAIT_CFG + 1))
    if [[ "${WAIT_CFG}" -ge 60 ]]; then
      echo "[entrypoint] ERROR: Timed out waiting for ${CONFIG_FILE}." >&2
      exit 1
    fi
    sleep 2
  done
fi

# ------------------------------------------------------------------------------
# Dispatch container role
# ------------------------------------------------------------------------------
case "${ROLE}" in
  serve)
    PORT="${PORT:-3131}"
    BIND="${GBRAIN_BIND:-0.0.0.0}"
    TOKEN_TTL="${GBRAIN_OAUTH_TOKEN_TTL:-3600}"
    SURFACE="${GBRAIN_MCP_SURFACE:-full}"

    SERVE_ARGS=(
      serve
      --http
      --bind "${BIND}"
      --port "${PORT}"
      --token-ttl "${TOKEN_TTL}"
      --surface "${SURFACE}"
      --suppress-bootstrap-token
    )

    if [[ -n "${GBRAIN_PUBLIC_URL:-}" ]]; then
      SERVE_ARGS+=(--public-url "${GBRAIN_PUBLIC_URL}")
    fi
    if [[ "${GBRAIN_ENABLE_DCR:-0}" == "1" || "${GBRAIN_ENABLE_DCR:-false}" == "true" ]]; then
      SERVE_ARGS+=(--enable-dcr)
    fi
    if [[ "${GBRAIN_CLI_SOCKET:-1}" == "1" ]]; then
      SERVE_ARGS+=(--cli-socket)
    fi

    echo "[entrypoint] Starting GBrain HTTP MCP server on ${BIND}:${PORT}..."
    exec /usr/local/bin/gbrain "${SERVE_ARGS[@]}" "$@"
    ;;

  worker)
    CONCURRENCY="${GBRAIN_WORKER_CONCURRENCY:-2}"
    ISOLATION="${GBRAIN_JOB_ISOLATION:-process}"
    WORKER_ARGS=(
      jobs
      supervisor
      --concurrency "${CONCURRENCY}"
      --job-isolation "${ISOLATION}"
    )
    if [[ -n "${GBRAIN_WORKER_MAX_RSS_MB:-}" ]]; then
      WORKER_ARGS+=(--max-rss "${GBRAIN_WORKER_MAX_RSS_MB}")
    fi
    echo "[entrypoint] Starting GBrain Minions job supervisor (concurrency=${CONCURRENCY}, isolation=${ISOLATION})..."
    exec /usr/local/bin/gbrain "${WORKER_ARGS[@]}" "$@"
    ;;

  autopilot)
    INTERVAL="${GBRAIN_AUTOPILOT_INTERVAL:-300}"
    echo "[entrypoint] Starting GBrain Autopilot daemon (--no-worker, interval=${INTERVAL}s, repo=${GBRAIN_REPO_PATH})..."
    exec /usr/local/bin/gbrain autopilot \
      --no-worker \
      --repo "${GBRAIN_REPO_PATH}" \
      --interval "${INTERVAL}" \
      "$@"
    ;;

  *)
    # Allow running arbitrary commands (`docker compose exec gbrain gbrain-run doctor`)
    exec "${ROLE}" "$@"
    ;;
esac

