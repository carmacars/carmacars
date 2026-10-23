#!/usr/bin/env bash
# One-liners for workflow steps that work on both backends (DB_BACKEND=supabase|vps, scripts/deploy/lib.sh), run as
# a command so a step's own shell options stay as they were. Values that are secret are masked before they are
# printed (the mask goes to stderr).
#
#   sb.sh backend                 supabase or vps
#   sb.sh url                     the Supabase API base this runner reaches (<ref>.supabase.co, or the SSH tunnel)
#   sb.sh public-url              the address the site and browsers use
#   sb.sh storage-url             <url>/storage/v1
#   sb.sh service-key | anon-key  the API keys
#   sb.sh vault NAME              a vault secret's value (empty when missing)
#   sb.sh sql "QUERY"             the rows of the last statement as JSON (like the Management API's database/query)
#   sb.sh sql-file FILE           the same, with the SQL in a file
#   sb.sh db-url                  a Postgres URL (hosted: session pooler, needs SUPABASE_DB_PASSWORD; vps: the tunnel)
#   sb.sh sql-api-url             for the node scripts: pg-meta's /query through the tunnel (vps), empty on supabase
#   sb.sh auth-config-file PATH   vps: writes the server's Auth settings (config/auth shape) to PATH and prints PATH;
#                                 supabase: prints nothing (the scripts read the Management API)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
cmd="${1:-}"; shift || true
case "$cmd" in
  backend) echo "$DB_BACKEND" ;;
  url) echo "$SB_URL" ;;
  public-url) echo "$SB_PUBLIC_URL" ;;
  storage-url) echo "$SB_URL/storage/v1" ;;
  service-key) sb_keys; printf '%s\n' "$SB_SERVICE_KEY" ;;
  anon-key) sb_keys; printf '%s\n' "$SB_ANON_KEY" ;;
  vault) v=$(vault_get "${1:?vault NAME}"); mask "$v"; printf '%s\n' "$v" ;;
  sql) sbq "${1:?sql QUERY}" ;;
  sql-file) sbq_file "${1:?sql-file FILE}" ;;
  db-url) sb_db_url; echo ;;
  sql-api-url) echo "${SQL_API_URL:-}" ;;
  auth-config-file)
    if [ "$DB_BACKEND" = vps ]; then ( umask 077; sb_auth_get > "${1:?auth-config-file PATH}" ); echo "$1"; fi ;;
  *) echo "usage: sb.sh backend|url|public-url|storage-url|service-key|anon-key|vault NAME|sql QUERY|sql-file FILE|db-url|sql-api-url|auth-config-file PATH" >&2; exit 2 ;;
esac
