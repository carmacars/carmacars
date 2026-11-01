#!/usr/bin/env bash
# Which nightly logical backups are kept (0320, docs/backups.md): the last BACKUP_KEEP_DAYS days (7) of nightly folders,
# plus the Sunday folder of each of the last BACKUP_KEEP_WEEKS weeks (4). The server's wal-g keeps point-in-time recovery
# for the last week on its own; this is the second, independent copy. Sourced by backup.sh; run directly it prints
# keep or drop for each stamp given (the unit test, web/src/lib/backup-keep.test.ts):
#   scripts/backup/keep.sh --now 2026-11-01T07:23Z --days 7 --weeks 4 2026-10-25T0723Z 2026-10-20T0723Z ...

# logical_keep <stamp YYYY-MM-DDTHHMMZ> <now epoch> <days> <weeks>: exit 0 to keep
logical_keep() {
  local stamp="$1" now="$2" days="$3" weeks="$4" day t age
  day="${stamp:0:10}"
  t=$(date -u -d "$day ${stamp:11:2}:${stamp:13:2}" +%s 2>/dev/null) || return 0   # not a stamp: never deleted
  age=$(( now - t ))
  [ "$age" -lt $(( days * 86400 )) ] && return 0
  [ "$(date -u -d "$day" +%u)" = 7 ] && [ "$age" -lt $(( weeks * 7 * 86400 )) ] && return 0
  return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  now=$(date -u +%s); days=7; weeks=4
  while [ $# -gt 0 ]; do
    case "$1" in
      --now) now=$(date -u -d "$2" +%s); shift 2 ;;
      --days) days="$2"; shift 2 ;;
      --weeks) weeks="$2"; shift 2 ;;
      *) if logical_keep "$1" "$now" "$days" "$weeks"; then echo "keep $1"; else echo "drop $1"; fi; shift ;;
    esac
  done
fi
