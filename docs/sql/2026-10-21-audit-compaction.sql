-- OPTIONAL, NOT APPLIED. A one-time compaction of the audit rows written before migration 0074
-- (docs/changes/2026-10-21-cpu-and-storage.md). The audit log is a legal record: run this only with the owner's
-- written approval, and only after the nightly backup of that day has been downloaded and kept outside the 30-day
-- rotation (docs/backups.md), so the full rows stay recoverable.
--
-- Measured on the live database on October 21, 2026 (read only): 23,258 rows written by the audit trigger, 152 MB of
-- before/after values; 13,429 of them are updates that changed nothing or only updated_at or snapshot_at; the rest
-- compacted the way 0074 writes new rows (changed columns only, values over 4 KB as md5 and size) hold 9.4 MB.
-- audit_log was 174 MB of the 500 MB plan; after this and a VACUUM FULL it would be about 15 MB.
--
-- Rows written by the functions themselves (view_as_start, guide_upkeep, owner_invoice_*, ...) are not touched.
-- Run in one transaction (the SQL editor, or psql -1). The append-only trigger is switched off for the transaction only.
begin;
set local statement_timeout = '15min';
alter table public.audit_log disable trigger audit_log_append_only;

-- 1. updates that changed nothing, or only updated_at or snapshot_at
delete from public.audit_log l
 where l.action = 'UPDATE' and l.before is not null and l.after is not null
   and not exists (select 1 from jsonb_each(l.after) n left join jsonb_each(l.before) o on o.key = n.key
                    where o.value is distinct from n.value and n.key <> all (app.audit_quiet_columns()));

-- 2. the remaining updates: the changed columns only, large values as md5 and size
update public.audit_log l
   set before = app.audit_compact(d.b), after = app.audit_compact(d.a)
  from (select x.id,
               (select jsonb_object_agg(n.key, o.value) from jsonb_each(x.after) n left join jsonb_each(x.before) o on o.key = n.key where o.value is distinct from n.value) b,
               (select jsonb_object_agg(n.key, n.value) from jsonb_each(x.after) n left join jsonb_each(x.before) o on o.key = n.key where o.value is distinct from n.value) a
          from public.audit_log x
         where x.action = 'UPDATE' and x.before is not null and x.after is not null) d
 where l.id = d.id;

-- 3. inserts and deletes: large values as md5 and size (the rest of the row unchanged)
update public.audit_log l set before = app.audit_compact(l.before), after = app.audit_compact(l.after)
 where l.action in ('INSERT', 'DELETE')
   and exists (select 1 from jsonb_each(coalesce(l.before, l.after)) e where octet_length(e.value::text) > 4096);

alter table public.audit_log enable trigger audit_log_append_only;
commit;

-- Then, outside the transaction, give the space back (locks audit_log for a few seconds):
-- vacuum full public.audit_log;
