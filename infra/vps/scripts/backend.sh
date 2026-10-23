#!/usr/bin/env bash
# Prints where Supabase is: the DB_BACKEND environment variable (the repository variable) when set, else the committed
# infra/vps/backend, else supabase. With "health": whether vps-health runs on its schedule (backend vps, or
# VPS_HEALTH / infra/vps/health "on").
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
line() { { grep -v '^[[:space:]]*#' "$1" 2>/dev/null || true; } | tr -d '[:space:]'; }
b="${DB_BACKEND:-}"; [ -n "$b" ] || b=$(line "$D/backend"); b="${b:-supabase}"
case "$b" in supabase|vps) ;; *) echo "unknown backend $b" >&2; exit 1 ;; esac
if [ "${1:-}" = health ]; then
  h="${VPS_HEALTH:-}"; [ -n "$h" ] || h=$(line "$D/health")
  if [ "$b" = vps ] || [ "$h" = on ]; then echo on; else echo off; fi
else
  echo "$b"
fi
