#!/usr/bin/env bash
# ==============================================================================
# GBrain + Arcane Docker Manager — Contabo Linux VM Bootstrap Script
#
# Run once as root on a fresh Ubuntu / Debian x86_64 VM:
#   sudo bash scripts/setup-vm-arcane.sh
#
# What it automates:
#   1. Syncs VM system clock via NTP (`timedatectl set-ntp true`)
#   2. Installs Docker Engine + Docker Compose plugin and enables `docker.service`
#   3. Deploys Arcane Manager (`ghcr.io/getarcaneapp/manager:latest`) in `/opt/arcane`
#      with auto-generated 32-byte `ENCRYPTION_KEY` and `JWT_SECRET`, mounting
#      `/opt/stacks:/opt/stacks` (`PROJECTS_DIRECTORY=/opt/stacks`)
#   4. Stages the GBrain production stack in `/opt/stacks/gbrain` and generates
#      `/opt/stacks/gbrain/.env` with cryptographic `GBRAIN_ADMIN_BOOTSTRAP_TOKEN`
#      and `POSTGRES_PASSWORD`
#   5. Installs nightly Dream + Backup cron jobs (`/etc/cron.d/gbrain-maintenance`)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCANE_DIR="/opt/arcane"
STACKS_DIR="/opt/stacks"
GBRAIN_STACK_DIR="${STACKS_DIR}/gbrain"

echo "==> [1/5] Setting Vietnam timezone (Asia/Ho_Chi_Minh, UTC+7) & synchronizing clock with NTP..."
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl set-timezone Asia/Ho_Chi_Minh || true
  timedatectl set-ntp true || true
  timedatectl status | grep -E "Local time|Time zone|System clock synchronized|NTP service" || true
fi

echo "==> [2/5] Installing / verifying Docker Engine & Docker Compose plugin..."
if ! command -v docker >/dev/null 2>&1; then
  echo "Installing Docker Engine..."
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker
docker compose version

echo "==> [3/5] Setting up Arcane Docker Manager in ${ARCANE_DIR}..."
mkdir -p "${ARCANE_DIR}" "${STACKS_DIR}"

if [[ -f "${SCRIPT_DIR}/arcane-compose.yml" ]]; then
  cp "${SCRIPT_DIR}/arcane-compose.yml" "${ARCANE_DIR}/compose.yaml"
elif [[ -f "${SCRIPT_DIR}/arcane-manager.compose.yml" ]]; then
  cp "${SCRIPT_DIR}/arcane-manager.compose.yml" "${ARCANE_DIR}/compose.yaml"
fi

if [[ ! -f "${ARCANE_DIR}/.env" ]]; then
  ENC_KEY="$(openssl rand -base64 32)"
  JWT_KEY="$(openssl rand -base64 32)"
  PUBLIC_IP="$(curl -4 -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || echo "localhost")"
  cat >"${ARCANE_DIR}/.env" <<EOF
# Arcane Docker Manager Secrets (Auto-generated)
ARCANE_BIND_IP=0.0.0.0
ARCANE_PORT=3552
ARCANE_APP_URL=http://${PUBLIC_IP}:3552
ARCANE_PUID=0
ARCANE_PGID=0
ENCRYPTION_KEY=${ENC_KEY}
JWT_SECRET=${JWT_KEY}
EOF
  chmod 600 "${ARCANE_DIR}/.env"
  echo "Created ${ARCANE_DIR}/.env with 32-byte ENCRYPTION_KEY and JWT_SECRET."
else
  echo "${ARCANE_DIR}/.env already exists — keeping existing Arcane keys."
fi

docker compose -f "${ARCANE_DIR}/compose.yaml" --env-file "${ARCANE_DIR}/.env" up -d

echo "==> [4/5] Staging GBrain stack into ${GBRAIN_STACK_DIR}..."
mkdir -p "${GBRAIN_STACK_DIR}/initdb" "${GBRAIN_STACK_DIR}/scripts"

if [[ "${SCRIPT_DIR}" != "${GBRAIN_STACK_DIR}" ]]; then
  if [[ -f "${SCRIPT_DIR}/compose.yaml" ]]; then
    cp "${SCRIPT_DIR}/compose.yaml" "${GBRAIN_STACK_DIR}/compose.yaml"
  elif [[ -f "${SCRIPT_DIR}/docker-compose.arcane.yml" ]]; then
    cp "${SCRIPT_DIR}/docker-compose.arcane.yml" "${GBRAIN_STACK_DIR}/compose.yaml"
  fi
  cp "${SCRIPT_DIR}/Dockerfile" "${GBRAIN_STACK_DIR}/Dockerfile"
  cp "${SCRIPT_DIR}/.dockerignore" "${GBRAIN_STACK_DIR}/.dockerignore"
  cp "${SCRIPT_DIR}/Caddyfile" "${GBRAIN_STACK_DIR}/Caddyfile"
  cp "${SCRIPT_DIR}/.env.production.example" "${GBRAIN_STACK_DIR}/.env.production.example"
  cp -r "${SCRIPT_DIR}/initdb/"* "${GBRAIN_STACK_DIR}/initdb/"
  cp -r "${SCRIPT_DIR}/scripts/"* "${GBRAIN_STACK_DIR}/scripts/"
  chmod +x "${GBRAIN_STACK_DIR}/scripts/"*.sh
fi

if [[ ! -f "${GBRAIN_STACK_DIR}/.env" ]]; then
  cp "${GBRAIN_STACK_DIR}/.env.production.example" "${GBRAIN_STACK_DIR}/.env"
  ADMIN_TOKEN="$(head -c 36 /dev/urandom | base64 | tr -d '+/=\n' | head -c 48)"
  PG_PASS="$(head -c 24 /dev/urandom | base64 | tr -d '+/=\n' | head -c 32)"
  sed -i.bak "s|CHANGE_ME_GENERATE_WITH_DEV_URANDOM_32_CHARS_MIN|${ADMIN_TOKEN}|g" "${GBRAIN_STACK_DIR}/.env"
  sed -i.bak "s|CHANGE_ME_STRONG_PG_PASSWORD|${PG_PASS}|g" "${GBRAIN_STACK_DIR}/.env"
  rm -f "${GBRAIN_STACK_DIR}/.env.bak"
  chmod 600 "${GBRAIN_STACK_DIR}/.env"
  echo "Created ${GBRAIN_STACK_DIR}/.env with auto-generated credentials:"
  echo "  GBRAIN_ADMIN_BOOTSTRAP_TOKEN=${ADMIN_TOKEN}"
else
  echo "${GBRAIN_STACK_DIR}/.env already exists — keeping existing values."
fi

echo "==> [5/5] Installing nightly maintenance & backup cron (/etc/cron.d/gbrain-maintenance in Vietnam Time UTC+7)..."
cat >/etc/cron.d/gbrain-maintenance <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
TZ=Asia/Ho_Chi_Minh
CRON_TZ=Asia/Ho_Chi_Minh
# Nightly 02:00 Vietnam Time (Asia/Ho_Chi_Minh, UTC+7): GBrain Dream Cycle (lint, backlinks, extract, embed stale, triage & synthesize)
0 2 * * * root docker exec gbrain-serve /usr/local/bin/gbrain-run dream >> /var/log/gbrain-dream.log 2>&1
# Nightly 03:15 Vietnam Time (Asia/Ho_Chi_Minh, UTC+7): Full 3-plane backup (Postgres dump + .gbrain config + Git bundle)
15 3 * * * root docker exec gbrain-serve /usr/local/bin/gbrain-backup >> /var/log/gbrain-backup.log 2>&1
# Weekly Mon 05:00 Vietnam Time (Asia/Ho_Chi_Minh, UTC+7): Health audit & stale vector drain (before 8AM VN business hours)
0 5 * * 1 root docker exec gbrain-serve /usr/local/bin/gbrain-run doctor --json >> /var/log/gbrain-doctor.log 2>&1 && docker exec gbrain-serve /usr/local/bin/gbrain-run embed --stale >> /var/log/gbrain-doctor.log 2>&1
EOF
chmod 644 /etc/cron.d/gbrain-maintenance
# Restart cron daemon so it immediately picks up the Asia/Ho_Chi_Minh system timezone
systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true

PUBLIC_IP="$(curl -4 -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || echo "<YOUR_VM_IP>")"
echo ""
echo "=============================================================================="
echo "Arcane + GBrain VM Bootstrap Complete!"
echo "------------------------------------------------------------------------------"
echo "1. Open Arcane UI in your browser:"
echo "     http://${PUBLIC_IP}:3552"
echo "   Default first-boot credentials (forced password change on first login):"
echo "     Username: arcane"
echo "     Password: arcane-admin"
echo ""
echo "2. Configure your GBrain .env (via Arcane UI -> Projects -> gbrain, or CLI):"
echo "     nano ${GBRAIN_STACK_DIR}/.env"
echo "   Set:"
echo "     GBRAIN_DOMAIN=\"gbrain.touchesai.com\""
echo "     ACME_EMAIL=\"you@touchesai.com\""
echo "     GBRAIN_PUBLIC_URL=\"https://gbrain.touchesai.com\""
echo "     OPENROUTER_API_KEY=\"sk-or-v1-...\""
echo ""
echo "3. Deploy GBrain (click 'Deploy / Up' in Arcane UI, or run via CLI):"
echo "     cd ${GBRAIN_STACK_DIR} && docker compose up -d --build"
echo "=============================================================================="

