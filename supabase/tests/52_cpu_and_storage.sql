-- 52: the audit log keeps what changed (0074): an UPDATE keeps the changed columns only, an UPDATE that changes
-- nothing (or only updated_at or snapshot_at) is not logged, a value over 4 KB is kept as its md5 and size, INSERT and
-- DELETE keep the whole row, the redacted tables log no values, the two noisy tables are left out, money tables keep
-- before and after; pg_cron's run history purge; the cron tick's question to the database (server_jobs_due).
-- Fixtures start with "zz".
select test.suite('52 cpu and storage');

create table public.zz_audit_probe (id integer primary key, note text, amount_cents bigint, big text, updated_at timestamptz default now(), snapshot_at timestamptz);
create trigger audit_zz_audit_probe after insert or update or delete on public.zz_audit_probe for each row execute function app.audit_row();
create table public.zz_audit_secret (id integer primary key, secret text, updated_at timestamptz default now());
create trigger audit_zz_audit_secret after insert or update or delete on public.zz_audit_secret for each row execute function app.audit_row('redact');

create or replace function test.zz_n(p_table text) returns bigint language sql stable as $$ select count(*) from audit_log where entity_table = p_table $$;
create or replace function test.zz_last(p_table text) returns audit_log language sql stable as $$
  select * from audit_log where entity_table = p_table order by id desc limit 1 $$;

-- INSERT: the whole row
insert into zz_audit_probe (id, note, amount_cents) values (1, 'first', 1000);
select test.eq('AU an insert keeps the whole row',
  (select (after ->> 'note') || '/' || (after ->> 'amount_cents') || '/' || (after ? 'updated_at') || '/' || (before is null) from test.zz_last('zz_audit_probe')),
  'first/1000/true/true');

-- UPDATE: the changed columns only
update zz_audit_probe set amount_cents = 1500, updated_at = now() + interval '1 second' where id = 1;
select test.eq('AU an update keeps only what changed, before and after',
  (select (select string_agg(k, ',' order by k) from jsonb_object_keys(after) k) || ' | ' || (before ->> 'amount_cents') || ' -> ' || (after ->> 'amount_cents')
     || ' | ' || (before ? 'note') from test.zz_last('zz_audit_probe')),
  'amount_cents,updated_at | 1000 -> 1500 | false');
select test.eq('AU the record is still named', (select entity_id || '/' || action from test.zz_last('zz_audit_probe')), '1/UPDATE');

-- no-op updates are not logged
do $$ declare n0 bigint := test.zz_n('zz_audit_probe'); begin
  update zz_audit_probe set note = note where id = 1;
  perform test.eq('AU an update that changes nothing is not logged', test.zz_n('zz_audit_probe'), n0);
  update zz_audit_probe set updated_at = now() + interval '1 minute', snapshot_at = now() where id = 1;
  perform test.eq('AU an update of updated_at or snapshot_at alone is not logged', test.zz_n('zz_audit_probe'), n0);
  update zz_audit_probe set note = 'second', updated_at = now() + interval '2 minutes' where id = 1;
  perform test.eq('AU a real change with its stamp is logged once', test.zz_n('zz_audit_probe'), n0 + 1);
end $$;

-- a value over 4 KB: its md5 and size
update zz_audit_probe set big = repeat('x', 5000) where id = 1;
select test.eq('AU a value over 4 KB is kept as its md5 and size',
  (select (after -> 'big' ->> 'md5') = md5(to_jsonb(repeat('x', 5000))::text) and (after -> 'big' ->> 'bytes')::integer = 5002
          and (after -> 'big' ->> 'omitted') is not null and before -> 'big' = 'null'::jsonb from test.zz_last('zz_audit_probe')), true);
update zz_audit_probe set note = 'third' where id = 1;
select test.eq('AU an unchanged large value is not repeated', (select (after ? 'big') || '/' || (after ->> 'note') from test.zz_last('zz_audit_probe')), 'false/third');

-- DELETE: the whole row (large values compacted)
delete from zz_audit_probe where id = 1;
select test.eq('AU a delete keeps the whole row before',
  (select (before ->> 'note') || '/' || (before ->> 'amount_cents') || '/' || (before -> 'big' ? 'md5') || '/' || (after is null) from test.zz_last('zz_audit_probe')),
  'third/1500/true/true');

-- redacted tables: the change, no values; no-ops skipped there too
insert into zz_audit_secret (id, secret) values (1, 'pm_123');
update zz_audit_secret set secret = 'pm_456' where id = 1;
update zz_audit_secret set secret = secret where id = 1;
select test.eq('AU a redacted table logs each change without values',
  (select count(*) || '/' || bool_and(before is null and after is null) from audit_log where entity_table = 'zz_audit_secret'), '2/true');

drop table zz_audit_probe;
drop table zz_audit_secret;

-- money tables keep before and after, as the test in 03 expects
update fee_defaults set amount_cents = amount_cents + 1 where fee_type_code = 'cleaning';
select test.eq('AU a money change still has before and after',
  (select ((after ->> 'amount_cents')::bigint - (before ->> 'amount_cents')::bigint)::text from audit_log
    where entity_table = 'fee_defaults' and action = 'UPDATE' order by id desc limit 1), '1');
update fee_defaults set amount_cents = amount_cents - 1 where fee_type_code = 'cleaning';

-- the email catalogue's refresh no longer fills the log with identical rows
do $$ declare n0 bigint := test.zz_n('notification_catalogue'); v_code text := (select code from notification_catalogue order by code limit 1); begin
  update notification_catalogue set template_html = template_html where code = v_code;
  perform test.eq('AU rewriting a catalogue entry unchanged is not logged', test.zz_n('notification_catalogue'), n0);
end $$;

-- the two noisy tables are left out, and attach_audit leaves them out again
select test.eq('AU guide_reads and app_events have no audit trigger',
  (select count(*) from pg_trigger where tgname in ('audit_guide_reads', 'audit_app_events')), 0::bigint);
select test.eq('AU attach_audit would leave them out again',
  (select pg_get_functiondef('app.attach_audit()'::regprocedure) ~ '''guide_reads'', ''app_events'''), true);
select test.eq('AU bookings, payments, owners, owner agreements, payouts, users and roles stay audited',
  (select count(*) from unnest(array['bookings', 'payments', 'owners', 'owner_agreements', 'owner_payouts', 'users', 'user_roles']) t
    where to_regclass('public.' || t) is not null
      and exists (select 1 from pg_trigger g where g.tgrelid = ('public.' || t)::regclass and g.tgname = 'audit_' || t)),
  (select count(*) from unnest(array['bookings', 'payments', 'owners', 'owner_agreements', 'owner_payouts', 'users', 'user_roles']) t
    where to_regclass('public.' || t) is not null));

-- pg_cron's run history
select test.eq('CR the run history purge runs without pg_cron too', app.job_cron_history_purge(), 'no pg_cron');

-- the cron tick's question
select test.eq('JD server_jobs_due answers listing and seo as booleans',
  (select jsonb_typeof(d -> 'listing') || '/' || jsonb_typeof(d -> 'seo') from (select public.server_jobs_due() d) x), 'boolean/boolean');
select test.eq('JD only the service role may ask',
  has_function_privilege('anon', 'public.server_jobs_due()', 'execute') or has_function_privilege('authenticated', 'public.server_jobs_due()', 'execute')
  or has_function_privilege('authenticated', 'app.server_jobs_due()', 'execute'), false);
select test.eq('JD the service role may', has_function_privilege('service_role', 'public.server_jobs_due()', 'execute'), true);
