#!/usr/bin/env bash
#
# Tiny ntfy publisher, sourced by backup-and-update.sh.
#
# Reads ONLY the NTFY_* vars out of .env (same dir). It deliberately does not
# shell-source .env: other values there could contain spaces and would break
# a `source` under `set -e`. No-ops if NTFY_TOKEN is empty, so the script
# keeps working before ntfy is configured.
#
#   notify <title> <priority> <tags> <message>
# priority: 1 (min) .. 5 (max); tags: comma-separated ntfy emoji short-codes.

_notify_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
_notify_env="$_notify_dir/.env"
if [ -f "$_notify_env" ]; then
    NTFY_URL="$(sed -n 's/^NTFY_URL=//p'     "$_notify_env" | tail -n1)"
    NTFY_TOPIC="$(sed -n 's/^NTFY_TOPIC=//p' "$_notify_env" | tail -n1)"
    NTFY_TOKEN="$(sed -n 's/^NTFY_TOKEN=//p' "$_notify_env" | tail -n1)"
fi

notify() {
    [ -n "${NTFY_TOKEN:-}" ] || return 0   # not configured yet → silently skip
    curl -fsS -m 10 \
        -H "Authorization: Bearer ${NTFY_TOKEN}" \
        -H "Title: $1" -H "Priority: $2" -H "Tags: $3" \
        -d "$4" "${NTFY_URL:?NTFY_URL not set}/${NTFY_TOPIC:?NTFY_TOPIC not set}" \
        >/dev/null || true                 # never let a notify failure abort the caller
}
