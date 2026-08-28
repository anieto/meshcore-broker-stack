#!/usr/bin/env bash
#
# Backs up broker/analyzer state, then updates CoreScope and the broker to
# their latest versions. Run by hand on the VPS, or from cron.
#
# If a `livemap` service is defined in docker-compose.yml (optional —
# see livemap/.env.example), its own backup archive is swept into
# BACKUP_DIR too, and it's updated/health-checked alongside the other
# two. Deployments that don't run livemap skip this silently.
#
# Usage:
#   ./backup-and-update.sh                # backup, then update both services
#   ./backup-and-update.sh --backup-only  # just the backup step
#   ./backup-and-update.sh --update-only  # skip backup, just update
#
# Also exports the meshtexas-repeaters D1 database (via a throwaway
# `wrangler` Docker container, since this box has no Node install) into
# BACKUP_DIR alongside the other backups. No-ops until scripts/.env has
# CLOUDFLARE_API_TOKEN set — see scripts/.env.example.
#
# Env overrides:
#   BACKUP_DIR       where backups are written (default: /opt/backups)
#   RETENTION_DAYS   how long to keep backups (default: 7)
#
# Push notifications via ntfy: see scripts/.env.example. No-ops until
# scripts/.env has NTFY_TOKEN set.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-/opt/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
HEALTH_TIMEOUT_TRIES=24   # 24 * 5s = 120s

cd "$PROJECT_DIR"

# ntfy notify() helper (no-op until NTFY_TOKEN is set in scripts/.env).
. "$SCRIPT_DIR/notify.sh"

# Deliberately not shell-sourcing .env (same reasoning as notify.sh) —
# just pull out the one var this script needs.
CLOUDFLARE_API_TOKEN=""
if [ -f "$SCRIPT_DIR/.env" ]; then
  CLOUDFLARE_API_TOKEN="$(sed -n 's/^CLOUDFLARE_API_TOKEN=//p' "$SCRIPT_DIR/.env" | tail -n1)"
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# True if the named service exists in docker-compose.yml — lets the
# optional livemap steps no-op cleanly on deployments that don't run it.
service_defined() {
  docker compose config --services 2>/dev/null | grep -qx "$1"
}

do_backup() {
  mkdir -p "$BACKUP_DIR"

  log "Backing up CoreScope database..."
  local corescope_id
  corescope_id="$(docker compose ps -q corescope)"
  if [ -n "$corescope_id" ]; then
    if ! docker cp "$corescope_id:/app/data/meshcore.db" "$BACKUP_DIR/corescope-$TIMESTAMP.db"; then
      log "ERROR: CoreScope database backup failed"
      notify "Backup failed" 5 "rotating_light,floppy_disk" \
        "CoreScope database backup failed on $(hostname). Check backup log."
      exit 1
    fi
  else
    log "WARNING: corescope container not running, skipping database backup"
  fi

  log "Backing up broker abuse-detection database..."
  local broker_id
  broker_id="$(docker compose ps -q broker)"
  if [ -n "$broker_id" ]; then
    if ! docker cp "$broker_id:/data/abuse-detection.db" "$BACKUP_DIR/broker-abuse-$TIMESTAMP.db" 2>/dev/null; then
      log "NOTE: no abuse-detection.db yet — fine if abuse enforcement has never triggered"
    fi
  else
    log "WARNING: broker container not running, skipping abuse-detection backup"
  fi

  log "Backing up corescope/config.json..."
  if ! cp corescope/config.json "$BACKUP_DIR/config-$TIMESTAMP.json"; then
    log "ERROR: config.json backup failed"
    notify "Backup failed" 5 "rotating_light,floppy_disk" \
      "corescope/config.json backup failed on $(hostname). Check backup log."
    exit 1
  fi

  if service_defined livemap; then
    log "Backing up livemap state..."
    # livemap writes its own timestamped .tar.gz archives to ./livemap/backup
    # on its own interval (BACKUP_INTERVAL_SECONDS) — just grab the latest
    # one rather than duplicating its backup logic here.
    local latest_livemap_backup
    latest_livemap_backup="$(ls -t livemap/backup/*.tar.gz 2>/dev/null | head -n1 || true)"
    if [ -n "$latest_livemap_backup" ]; then
      cp "$latest_livemap_backup" "$BACKUP_DIR/livemap-$TIMESTAMP.tar.gz"
    else
      log "NOTE: no livemap backup archive yet — fine if BACKUP_ENABLED was just turned on or livemap was just deployed"
    fi
  fi

  log "Backing up meshtexas-repeaters D1 database..."
  if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    log "NOTE: CLOUDFLARE_API_TOKEN not set in scripts/.env — skipping D1 export"
  elif ! docker run --rm \
    -e CLOUDFLARE_API_TOKEN="$CLOUDFLARE_API_TOKEN" \
    -e CLOUDFLARE_ACCOUNT_ID="e472a5fc5a46bc27f25d7fe343cd58e8" \
    -v "$BACKUP_DIR:/backup" \
    node:22-alpine \
    npx --yes wrangler@4.112.0 d1 export meshtexas-repeaters --remote --output "/backup/meshtexas-repeaters-$TIMESTAMP.sql"; then
    log "ERROR: meshtexas-repeaters D1 export failed"
    notify "Backup failed" 5 "rotating_light,floppy_disk" \
      "meshtexas-repeaters D1 export failed on $(hostname). Check backup log."
    exit 1
  fi

  log "Pruning backups older than $RETENTION_DAYS days..."
  find "$BACKUP_DIR" -type f -mtime "+$RETENTION_DAYS" -delete

  log "Backup complete: $BACKUP_DIR"
}

wait_for_healthy() {
  local service="$1"
  local container_id
  container_id="$(docker compose ps -q "$service")"
  if [ -z "$container_id" ]; then
    log "ERROR: $service container did not start"
    return 1
  fi

  local status="unknown"
  for _ in $(seq 1 "$HEALTH_TIMEOUT_TRIES"); do
    status="$(docker inspect --format='{{.State.Health.Status}}' "$container_id" 2>/dev/null || echo "unknown")"
    if [ "$status" = "healthy" ]; then
      log "$service is healthy"
      return 0
    fi
    sleep 5
  done

  log "ERROR: $service did not report healthy in time (last status: $status)"
  return 1
}

do_update() {
  log "Updating CoreScope..."
  docker compose pull corescope
  docker compose up -d corescope
  if ! wait_for_healthy corescope; then
    notify "Update needs attention" 5 "rotating_light,arrow_up" \
      "CoreScope did not reach healthy after updating on $(hostname). Broker update skipped — check the box."
    exit 1
  fi

  log "Updating broker (rebuilds from latest upstream source)..."
  docker compose build --no-cache broker
  docker compose up -d broker
  if ! wait_for_healthy broker; then
    notify "Update needs attention" 5 "rotating_light,arrow_up" \
      "Broker did not reach healthy after updating on $(hostname). CoreScope was already updated — check the box."
    exit 1
  fi

  local updated="CoreScope and broker"
  if service_defined livemap; then
    log "Updating livemap..."
    docker compose pull livemap
    docker compose up -d livemap
    if ! wait_for_healthy livemap; then
      notify "Update needs attention" 5 "rotating_light,arrow_up" \
        "livemap did not reach healthy after updating on $(hostname). CoreScope and broker were already updated — check the box."
      exit 1
    fi
    updated="CoreScope, broker, and livemap"
  fi

  log "Update complete"
  notify "Update complete" 3 "white_check_mark,arrow_up" \
    "$updated updated on $(hostname) — all healthy."
}

case "${1:-}" in
  --backup-only)
    do_backup
    ;;
  --update-only)
    do_update
    ;;
  "")
    do_backup
    do_update
    ;;
  *)
    echo "Usage: $0 [--backup-only|--update-only]" >&2
    exit 1
    ;;
esac
