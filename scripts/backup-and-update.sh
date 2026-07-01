#!/usr/bin/env bash
#
# Backs up broker/analyzer state, then updates CoreScope and the broker to
# their latest versions. Run by hand on the VPS, or from cron.
#
# Usage:
#   ./backup-and-update.sh                # backup, then update both services
#   ./backup-and-update.sh --backup-only  # just the backup step
#   ./backup-and-update.sh --update-only  # skip backup, just update
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

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

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

  log "Update complete"
  notify "Update complete" 3 "white_check_mark,arrow_up" \
    "CoreScope and broker updated on $(hostname) — both healthy."
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
