#!/usr/bin/env bash
# ==============================================================================
# gbrain-run: Canonical unattended CLI wrapper
#
# Per AGENTS.md and docs/guides/cron-schedule.md#calling-gbrain-unattended:
#   1. Sets GBRAIN_HOME (never overrides HOME)
#   2. Loads /srv/gbrain/.gbrain/.env if present
#   3. Executes the compiled /usr/local/bin/gbrain binary directly
#   4. Preserves stdout for clean --json parsing and keeps stderr intact
# ==============================================================================
set -euo pipefail

export GBRAIN_HOME="${GBRAIN_HOME:-/srv/gbrain}"
ENV_FILE="${GBRAIN_HOME}/.gbrain/.env"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  set +a
fi

exec /usr/local/bin/gbrain "$@"

