#!/usr/bin/env bash
# The backup bucket's settings for the vps-backup workflow: each BACKUP_* value from its repository secret when that
# is set, else from the vault (deploy_backup_s3_endpoint, deploy_backup_s3_region, deploy_backup_s3_bucket,
# deploy_backup_s3_access_key_id, deploy_backup_s3_secret_access_key, deploy_backup_walg_key): first the vault of the
# live backend (repository variable DB_BACKEND: the hosted project until the cutover), then the other one (vps-copy
# copies the vault to the server). Values are masked and exported to the job (GITHUB_ENV); never printed.
# Env: VPS_SSH_KEY, SUPABASE_ACCESS_TOKEN, SUPABASE_PROJECT_REF; LIVE_BACKEND (vars.DB_BACKEND, default supabase).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SB="$ROOT/scripts/deploy/sb.sh"
live="${LIVE_BACKEND:-supabase}"; [ "$live" = vps ] || live=supabase
other=vps; [ "$live" = vps ] && other=supabase
from_vault() { # vault name -> value from the first backend that has it
  local b v
  for b in "$live" "$other"; do
    if [ "$b" = supabase ] && { [ -z "${SUPABASE_ACCESS_TOKEN:-}" ] || [ -z "${SUPABASE_PROJECT_REF:-}" ]; }; then continue; fi
    v=$(DB_BACKEND="$b" "$SB" vault "$1" 2>/dev/null || true)
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
}
missing=()
for pair in S3_ENDPOINT:s3_endpoint S3_REGION:s3_region S3_BUCKET:s3_bucket S3_ACCESS_KEY_ID:s3_access_key_id S3_SECRET_ACCESS_KEY:s3_secret_access_key WALG_KEY:walg_key; do
  var="BACKUP_${pair%%:*}"; name="deploy_backup_${pair##*:}"
  val="${!var:-}"; src=secret
  if [ -z "$val" ]; then val=$(from_vault "$name"); src=vault; fi
  if [ -z "$val" ]; then missing+=("$var ($name)"); continue; fi
  if [ "$var" = BACKUP_S3_ENDPOINT ] && [[ "$val" != http*://* ]]; then val="https://$val"; fi
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$val" >&2; fi
  export "$var=$val"
  if [ -n "${GITHUB_ENV:-}" ]; then d="EOF_$(openssl rand -hex 8)"; printf '%s<<%s\n%s\n%s\n' "$var" "$d" "$val" "$d" >> "$GITHUB_ENV"; fi
  echo "[backup-env] $var from the $src"
done
# the logical backup's age keys (backup.sh, restore-test.sh), when not given: before the copy the server's vault is empty
for pair in BACKUP_AGE_RECIPIENT:backup_age_recipient BACKUP_AGE_IDENTITY:backup_age_identity; do
  var="${pair%%:*}"; [ -n "${!var:-}" ] && continue
  val=$(from_vault "${pair##*:}")
  [ -n "$val" ] || continue
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$val" >&2; fi
  if [ -n "${GITHUB_ENV:-}" ]; then d="EOF_$(openssl rand -hex 8)"; printf '%s<<%s\n%s\n%s\n' "$var" "$d" "$val" "$d" >> "$GITHUB_ENV"; fi
  echo "[backup-env] $var from the vault"
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "[backup-env] missing: ${missing[*]}" >&2
  exit 1
fi
