# Database backups and restore

The live database is backed up every night, encrypted, kept 30 days, and a restore of each backup is tested the
same night. Free: GitHub Actions minutes and the Supabase Storage space the files take (a few MB each).

## What runs, and where things are

| What | Where |
| --- | --- |
| Workflow | `.github/workflows/backup.yml`: nightly at 07:23 UTC (backup and restore test), Mondays at 13:41 UTC (the weekly check); run by hand from Actions > backup > Run workflow (`backup` or `check`) |
| Scripts | `scripts/backup/backup.sh` (dump, encrypt, upload, keep 30 days), `scripts/backup/restore-test.sh` (download, decrypt, restore into a scratch PostgreSQL, compare every table) |
| What is in a backup | `pg_dump` 17, custom format, of the schemas `public`, `app`, `auth` (sign-in accounts), `storage` (the file records, not the files) and `supabase_migrations` (the migration history). Taken through the session pooler in one snapshot; every table's row count is read in that same snapshot |
| Files | Storage bucket `backups` (private), `nightly/<UTC stamp>/`: `carmacars-<stamp>.dump.age.part01` (and more parts above 45 MB, the free plan's 50 MB file limit), `manifest.json` (table names, row counts, sizes, checksums, versions; no data), `restore-report.json` (the restore test's result) |
| Encryption | age. The job encrypts to the public key in the vault secret `backup_age_recipient`. Only the private key, vault secret `backup_age_identity`, decrypts. The plain dump never leaves the runner |
| Kept | 30 days of folders; older ones are deleted by the nightly job |
| Results | `job_runs` rows `backup-nightly`, `backup-restore-test` and `backup-check` (a failed row shows on Admin > Today; inserted, never updated, so no email is sent), the run's summary in the Actions tab |
| Secrets | Only the three the deploy already uses: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`, `SUPABASE_DB_PASSWORD` |

**Keep a copy of the private key outside Supabase.** The key is in the vault of the same project the backups protect.
If the project itself were lost, so would the key. Copy it once into the company password manager:
Supabase dashboard > SQL editor:

```sql
select decrypted_secret from vault.decrypted_secrets where name = 'backup_age_identity';
```

Save the line that starts with `AGE-SECRET-KEY-` as "CarmaCars backup key". Never paste it in a chat, email or ticket.

**Not in the backup:** the uploaded files themselves (Storage buckets `documents`, `vehicle-public`, `vehicle-originals`,
...), the vault's secrets (they are encrypted with the project's own key; the deploy's `deploy_*` secrets are entered
again), the scheduled jobs (the deploy schedules them) and the Edge Functions (deployed from this repository).

## The tested restore (every night, and by hand)

`restore-test.sh` does, in order, and fails on any step:

1. downloads the newest folder (or the one named), checks the encrypted file's SHA-256 against the manifest;
2. decrypts with the private key from the vault, checks the dump's SHA-256;
3. starts a scratch PostgreSQL 17 from `initdb`, creates the roles and the `extensions` schema Supabase provides;
4. `pg_restore --no-owner`; errors about objects only Supabase has (its own schemas' extensions, roles, event
   triggers) are expected and counted; an error about a table or its data fails the test;
5. counts every table and compares with the manifest: every table must exist, and with counts from the dump's
   snapshot every count must be equal;
6. reads through the app's own functions (`app.settings()`, `app.today()`, the migrations, the policies).

By hand, on a computer with PostgreSQL 17 and age:

```bash
export SUPABASE_ACCESS_TOKEN=... SUPABASE_PROJECT_REF=...      # or BACKUP_AGE_IDENTITY_FILE=~/carmacars-backup-key.txt
scripts/backup/restore-test.sh --latest --keep                 # prints the scratch database's address at the end
```

## Restoring for real

Decide first what is being restored: the whole database after a loss (below), or a few rows someone deleted (restore
into a scratch database with `--keep`, then copy those rows across by hand with an Admin).

### 1. Get the files and decrypt

From the Supabase dashboard (Storage > `backups` > `nightly` > the date) download every `.part` file and
`manifest.json` into one folder, or use the API as `restore-test.sh` does. Then:

```bash
cat carmacars-<stamp>.dump.age.part* > carmacars.dump.age
sha256sum carmacars.dump.age                                    # = manifest.json encrypted.sha256
age --decrypt --identity carmacars-backup-key.txt --output carmacars.dump carmacars.dump.age
sha256sum carmacars.dump                                        # = manifest.json plain.sha256
```

### 2. Into a new Supabase project

1. Create the project (region Canada Central, the same PostgreSQL major version as `manifest.json` `server_version`).
2. In this repository's GitHub secrets, set `SUPABASE_PROJECT_REF` and `SUPABASE_DB_PASSWORD` to the new project's.
3. Restore the app's schemas, then the sign-in accounts and file records into the tables Supabase already made
   (connection string: dashboard > Connect > Session pooler):

```bash
DB="postgresql://postgres.<ref>:<password>@aws-1-ca-central-1.pooler.supabase.com:5432/postgres"
pg_restore --no-owner --schema=public --schema=app --schema=supabase_migrations --dbname="$DB" carmacars.dump
PGOPTIONS='-c session_replication_role=replica' pg_restore --no-owner --data-only --schema=auth --schema=storage --dbname="$DB" carmacars.dump
```

   Errors that an object "already exists" are expected (the extensions and the `public` schema exist on a new project).
4. Put the vault secrets back (`deploy_stripe_secret_key`, `deploy_stripe_publishable_key`, `deploy_resend_api_key`,
   `deploy_link_signing_key`, `deploy_payout_encryption_key`, `backup_age_recipient`, `backup_age_identity`; the
   deploy makes the others), then run Actions > ci > Run workflow with deploy. It applies only migrations newer than
   the backup, schedules the jobs, deploys the Edge Functions and points the Worker at the new project.
5. Run Actions > verify, then sign in as an Admin and check Admin > Today.

`deploy_payout_encryption_key` must be the old value: the owners' bank account numbers are encrypted with it.

### 3. Into a plain PostgreSQL (anywhere)

`restore-test.sh --dir <folder> --keep` with `BACKUP_AGE_IDENTITY_FILE`, or `RESTORE_PGURL` pointing at your server.

## Proof

The first runs and their results are in `docs/audit/2026-10-14-retest.md` (section "Backups").

## deploy-reports retention

The private bucket `deploy-reports` (verify reports and screenshots, guide screenshots, forms reports) is not a backup.
`scripts/backup/prune-reports.sh`, run by the backup workflow every night, keeps verify runs 3 days, the newest
`guides/<date>` and the newest 3 forms runs, and lists everything it keeps and removes. It removes only when
`PRUNE_REPORTS` is `'1'` in `.github/workflows/backup.yml`, or by hand with the `prune_now` input
(docs/changes/2026-10-21-cpu-and-storage.md).

