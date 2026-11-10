#!/usr/bin/env bash
# ==============================================================================
# GBrain Production Restore Script
#
# Usage:
#   gbrain-restore /srv/gbrain/backups/gbrain-backup-YYYYMMDDTHHMMSSZ.tar.gz --yes
#
# After restoring a database backup, runs `gbrain doctor` including the
# `belief_ledger_coverage` and `embedding_width_consistency` checks.
# ==============================================================================
set -euo pipefail

ARCHIVE_PATH="${1:-}"
CONFIRM="${2:-}"

if [[ -z "${ARCHIVE_PATH}" || ! -f "${ARCHIVE_PATH}" ]]; then
  echo "Usage: gbrain-restore <path-to-backup.tar.gz> --yes" >&2
  exit 1
fi

if [[ "${CONFIRM}" != "--yes" ]]; then
  echo "[restore] Refusing to overwrite live brain without --yes confirmation." >&2
  echo "Run: gbrain-restore ${ARCHIVE_PATH} --yes" >&2
  exit 3
fi

export GBRAIN_HOME="${GBRAIN_HOME:-/srv/gbrain}"
export GBRAIN_REPO_PATH="${GBRAIN_REPO_PATH:-/srv/gbrain/brain}"
DB_URL="${GBRAIN_DATABASE_URL:-${DATABASE_URL:-}}"

if [[ -z "${DB_URL}" ]]; then
  echo "[restore] ERROR: GBRAIN_DATABASE_URL is not set." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "[restore] Extracting ${ARCHIVE_PATH}..."
tar -xzf "${ARCHIVE_PATH}" -C "${TMP_DIR}"
INNER_DIR="$(find "${TMP_DIR}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

if [[ -f "${INNER_DIR}/postgres.dump" ]]; then
  echo "[restore] 1/3 Restoring PostgreSQL database..."
  pg_restore \
    --dbname="${DB_URL}" \
    --clean \
    --if-exists \
    --no-owner \
    --no-privileges \
    "${INNER_DIR}/postgres.dump"
fi

if [[ -f "${INNER_DIR}/gbrain-config.tar.gz" ]]; then
  echo "[restore] 2/3 Restoring ${GBRAIN_HOME}/.gbrain configuration..."
  tar -xzf "${INNER_DIR}/gbrain-config.tar.gz" -C "${GBRAIN_HOME}"
  chmod 700 "${GBRAIN_HOME}/.gbrain" || true
fi

if [[ -f "${INNER_DIR}/brain-worktree.tar.gz" ]]; then
  echo "[restore] 3/3 Restoring managed Git checkout to ${GBRAIN_REPO_PATH}..."
  mkdir -p "$(dirname "${GBRAIN_REPO_PATH}")"
  tar -xzf "${INNER_DIR}/brain-worktree.tar.gz" -C "$(dirname "${GBRAIN_REPO_PATH}")"
fi

echo "[restore] Applying any pending schema migrations..."
/usr/local/bin/gbrain-run apply-migrations --yes --non-interactive --no-autopilot-install

echo "[restore] Running post-restore verification (including belief_ledger_coverage)..."
/usr/local/bin/gbrain-run doctor --only belief_ledger_coverage --json || true
/usr/local/bin/gbrain-run doctor

echo "[restore] Restore completed."

