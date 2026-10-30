# Server backups: less WAL, a weekly full backup (no migration)

The R2 backup bucket was at 8 GB of the free 10 GB, with about 2.5 GB of WAL a day and 7 nightly full backups.

- Postgres (`infra/vps/supabase/docker-compose.yml`, `defaults.env`): `wal_compression=lz4` (was `on`, pglz; the
  image is PostgreSQL 17) and `checkpoint_timeout=15min` (was the default 5). `max_wal_size` stays 4 GB (above the 2 GB
  the 15 minutes need). `archive_timeout` stays 5 minutes, so at most 5 minutes of changes can be lost, as before.
  Most WAL is the full page written the first time a page changes after each checkpoint: a third as many checkpoints
  and lz4 should bring the WAL to about a third to a half.
- wal-g (`infra/vps/bin/walg-base`, `bin/backup-configure`): a full backup once a week and a delta (changed pages
  only) the other six nights (`WALG_DELTA_MAX_STEPS=6`, added to the server's `walg.env` by the next nightly run).
  Kept: the newest 7 backups (`WALG_RETAIN_FULL`, now counting deltas) and the full they start from
  (`delete retain FIND_FULL`), with their WAL: point-in-time recovery over the last 7 to 13 days. Before: 7 full copies.
- The bucket report (`infra/vps/scripts/backup-retention.sh`, vps-ops `backup-report` / `apply-retention`) projects
  2 full backups + the deltas + WAL for kept + 7 days, and lists full and delta counts; apply-retention uses FIND_FULL.

## Manual steps on the server (the owner)

Nothing was run on the server. In a quiet hour, not during the 06:10 UTC base backup, follow `docs/backups.md`,
"Applying it on the server": check lz4 (`pg_config --configure`), install the files (vps-ops `reboot`, or copy and
`dc up -d db`), check `pg_settings` (wal_compression lz4, checkpoint_timeout 900 s, max_wal_size 4096 MB),
`pg_stat_archiver.failed_count` 0, reset `pg_stat_wal` and read it the next day; a week later run vps-ops
`backup-report`.

## Guides
No guide change: no screen changed.
