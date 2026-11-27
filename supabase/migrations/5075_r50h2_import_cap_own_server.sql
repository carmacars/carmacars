-- 5075 (R50 hotfix 2, CI doctor, Nov 27; hotfix-notes/ci-root-cause-2026-11-27.md): the catalog import stops at its size cap.
-- What went wrong: the scheduled catalog workflow failed every day since Nov 22 (runs 45038360990 to 45870496977) with
-- "The import would bring the database to 7425 MB, over the cap of 6144 MB". The cap (db_cap_pro_mb, 0104) is the
-- Supabase Pro plan's 8 GB less headroom. The database has run on our own server since the VPS cutover (0194: an OVHcloud
-- VPS-4, about 200 GB NVMe, 28% used on Nov 27), so the plan's cap no longer applies. Its failure also made self-heal
-- fail every run ("cron_failed:catalog").
-- Now: the standard cap is 16 GB (16,384 MB) and the database allowance of Settings > Usage 16 GB, about 8% of the server
-- disk, so the database, two base backups and the WAL stay well under half of it. A value an Admin changed is kept (only
-- the old defaults move). The import caps follow by themselves (app.program_settings_db_cap, 0104).
alter table program_settings alter column db_cap_pro_mb set default 16384;
update program_settings set db_cap_pro_mb = 16384 where id = (app.settings()).id and db_cap_pro_mb = 6144;
comment on column program_settings.db_cap_pro_mb is 'The standard import size cap (MB, 0104; 16,384 since 5075: our own server''s disk, not the Supabase Pro plan).';
update usage_services set included = 17179869184 where service = 'supabase_db' and included = 8589934592;
