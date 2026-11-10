#!/usr/bin/env bash
# ==============================================================================
# GBrain Production Backup Script
#
# Backs up all three stateful planes required for a full zero-loss restore
# (including the database-only belief ledger and OAuth client grants):
#   1. PostgreSQL database (`pg_dump --format=custom`)
#   2. GBrain home configuration (`/srv/gbrain/.gbrain`, excluding transient sockets/locks)
#   3. Managed Git brain repository bundle (`git bundle create`)
# ==============================================================================
set -euo pipefail

export GBRAIN_HOME="${GBRAIN_HOME:-/srv/gbrain}"
export GBRAIN_REPO_PATH="${GBRAIN_REPO_PATH:-/srv/gbrain/brain}"
BACKUP_ROOT="${GBRAIN_BACKUP_DIR:-${GBRAIN_HOME}/backups}"
RETENTION_DAYS="${GBRAIN_BACKUP_RETENTION_DAYS:-14}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK_DIR="${BACKUP_ROOT}/gbrain-backup-${TIMESTAMP}"
ARCHIVE_PATH="${BACKUP_ROOT}/gbrain-backup-${TIMESTAMP}.tar.gz"

DB_URL="${GBRAIN_DATABASE_URL:-${DATABASE_URL:-}}"
if [[ -z "${DB_URL}" ]]; then
  echo "[backup] ERROR: GBRAIN_DATABASE_URL is not set." >&2
  exit 1
fi

mkdir -p "${WORK_DIR}"

echo "[backup] 1/4 Dumping PostgreSQL database (custom format, compressed)..."
pg_dump "${DB_URL}" \
  --format=custom \
  --compress=6 \
  --no-owner \
  --no-privileges \
  --file="${WORK_DIR}/postgres.dump"

echo "[backup] 2/4 Archiving GBrain configuration directory (${GBRAIN_HOME}/.gbrain)..."
if [[ -d "${GBRAIN_HOME}/.gbrain" ]]; then
  tar -czf "${WORK_DIR}/gbrain-config.tar.gz" \
    --exclude='*.sock' \
    --exclude='*.lock' \
    --exclude='*.pid' \
    -C "${GBRAIN_HOME}" .gbrain
fi

echo "[backup] 3/4 Bundling managed Git repository (${GBRAIN_REPO_PATH})..."
if [[ -d "${GBRAIN_REPO_PATH}/.git" ]]; then
  if git -C "${GBRAIN_REPO_PATH}" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "${GBRAIN_REPO_PATH}" bundle create "${WORK_DIR}/brain-repo.bundle" --all
  fi
  tar -czf "${WORK_DIR}/brain-worktree.tar.gz" -C "$(dirname "${GBRAIN_REPO_PATH}")" "$(basename "${GBRAIN_REPO_PATH}")"
fi

echo "[backup] 4/4 Recording metadata and packaging ${ARCHIVE_PATH}..."
cat > "${WORK_DIR}/manifest.json" <<EOF
{
  "created_at": "${TIMESTAMP}",
  "gbrain_version": "$(/usr/local/bin/gbrain --version 2>/dev/null || echo unknown)",
  "gbrain_home": "${GBRAIN_HOME}",
  "repo_path": "${GBRAIN_REPO_PATH}"
}
EOF

tar -czf "${ARCHIVE_PATH}" -C "${BACKUP_ROOT}" "gbrain-backup-${TIMESTAMP}"
rm -rf "${WORK_DIR}"
chmod 600 "${ARCHIVE_PATH}"

# Prune backups older than RETENTION_DAYS
find "${BACKUP_ROOT}" -maxdepth 1 -type f -name 'gbrain-backup-*.tar.gz' -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true

echo "[backup] Backup complete: ${ARCHIVE_PATH} ($(du -h "${ARCHIVE_PATH}" | cut -f1))"

