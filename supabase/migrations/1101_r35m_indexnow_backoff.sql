-- 1101_r35m_indexnow_backoff.sql
-- Release 35, part M (docs/changes/2026-11-08-r35-seo-depth.md, section E). Settings > Search showed the changed pages
-- rate limited (429) and the sweep's last answer a 502: a 5xx waited a fixed 10 minutes and the same 10,000 addresses
-- went again, so Bing kept failing on the same large request.
--   1. Smaller batches: the sweep sends at most indexnow_sweep_batch addresses a request (1,000 by default, was 10,000)
--      and the changed pages at most indexnow_queue_batch (100, was up to 500). Both are Program settings.
--   2. Back-off on 5xx and on no answer (status 0): 10 minutes, doubling with each failure in a row, at most 6 hours,
--      for the sweep (streak_5xx) and for the changed pages (q_backoff_s doubling). A 429 keeps its rules (Retry-After,
--      else 1104's and 0220's waits). A 2xx resets the streaks.
--   3. Resume: a sweep held back by a 5xx or a failed claim starts again now, from its cursor, with the smaller batches.
-- No applied migration is edited.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter table program_settings
  add column if not exists indexnow_sweep_batch integer not null default 1000 check (indexnow_sweep_batch between 50 and 10000),
  add column if not exists indexnow_queue_batch integer not null default 100 check (indexnow_queue_batch between 1 and 500);
comment on column program_settings.indexnow_sweep_batch is 'IndexNow (1101): the most addresses the sweep sends in one request (Bing answered 502 to 10,000).';
comment on column program_settings.indexnow_queue_batch is 'IndexNow (1101): the most changed pages sent in one request.';
alter table indexnow_sweep add column if not exists streak_5xx integer not null default 0;
comment on column indexnow_sweep.streak_5xx is 'The sweep''s 5xx or unanswered requests in a row (1101): the wait doubles with each, from 10 minutes to at most 6 hours.';

-- the wait after a 5xx or no answer, the n-th in a row (1 is the first)
create or replace function app.indexnow_5xx_wait(p_n integer) returns integer
language sql immutable as $$ select least(600 * (2 ^ least(greatest(p_n, 1) - 1, 10))::integer, 21600) $$;

-- 1. the sweep's claim: at most indexnow_sweep_batch
alter function app.server_indexnow_claim(integer) rename to server_indexnow_claim_pre1101;
create function app.server_indexnow_claim(p_limit integer) returns jsonb
language sql security definer set search_path = public, app as $$
  select app.server_indexnow_claim_pre1101(least(coalesce(p_limit, 10000), (app.settings()).indexnow_sweep_batch))
$$;
select pg_temp.copy_grants('app.server_indexnow_claim(integer)'::regprocedure, 'app.server_indexnow_claim_pre1101(integer)'::regprocedure);

-- the changed pages' claim: at most indexnow_queue_batch
alter function app.server_seo_claim(text, integer) rename to server_seo_claim_pre1101;
create function app.server_seo_claim(p_worker text, p_limit integer default 3) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare c jsonb := app.server_seo_claim_pre1101(p_worker, p_limit);
begin
  if c #> '{indexnow,paths}' is null or jsonb_typeof(c #> '{indexnow,paths}') <> 'array' then return c; end if;
  return jsonb_set(c, '{indexnow,paths}', coalesce((select jsonb_agg(x order by n) from jsonb_array_elements(c #> '{indexnow,paths}') with ordinality e(x, n)
                                                    where n <= (app.settings()).indexnow_queue_batch), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.server_seo_claim(text, integer)'::regprocedure, 'app.server_seo_claim_pre1101(text, integer)'::regprocedure);

-- 2. the sweep's answer: 5xx and no answer back off, doubling
alter function app.server_indexnow_report(jsonb) rename to server_indexnow_report_pre1101;
create function app.server_indexnow_report(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_status integer := coalesce((p ->> 'status')::integer, 0);
  w jsonb := app.server_indexnow_report_pre1101(p);
  v_n integer;
  v_wait integer;
begin
  if v_status between 200 and 299 then
    update indexnow_sweep set streak_5xx = 0 where id;
  elsif v_status = 0 or v_status >= 500 then
    update indexnow_sweep set streak_5xx = streak_5xx + 1 where id returning streak_5xx into v_n;
    v_wait := app.indexnow_5xx_wait(v_n);
    update indexnow_sweep set backoff_s = v_wait, backoff_until = now() + make_interval(secs => v_wait) where id;
  end if;
  return (select to_jsonb(x) from indexnow_sweep x limit 1);
end $$;
select pg_temp.copy_grants('app.server_indexnow_report(jsonb)'::regprocedure, 'app.server_indexnow_report_pre1101(jsonb)'::regprocedure);

-- the changed pages' answer: 5xx and no answer double the queue's wait (0220 waited 10 minutes each time)
alter function app.server_indexnow_sent(jsonb) rename to server_indexnow_sent_pre1101;
create function app.server_indexnow_sent(p jsonb) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_status integer := coalesce((p ->> 'status')::integer, 0);
  v_prev integer := coalesce((select case when q_last_status = 0 or q_last_status >= 500 then q_backoff_s end from indexnow_sweep limit 1), 0);
  n integer := app.server_indexnow_sent_pre1101(p);
  v_wait integer;
begin
  if v_status = 0 or v_status >= 500 then
    v_wait := least(greatest(600, v_prev * 2), 21600);
    update indexnow_sweep set q_backoff_s = v_wait, q_backoff_until = now() + make_interval(secs => v_wait) where id;
  end if;
  return n;
end $$;
select pg_temp.copy_grants('app.server_indexnow_sent(jsonb)'::regprocedure, 'app.server_indexnow_sent_pre1101(jsonb)'::regprocedure);

revoke all on function app.indexnow_5xx_wait(integer) from public, anon, authenticated;
grant execute on function app.indexnow_5xx_wait(integer) to service_role;

-- 3. resume: a sweep held back by a 5xx or a failed claim goes on now, from its cursor
update indexnow_sweep set backoff_until = null, backoff_s = 0, streak_5xx = 0
 where (last_status = 0 or last_status >= 500) and backoff_until is not null;
update indexnow_sweep set q_backoff_until = null, q_backoff_s = 0
 where (q_last_status = 0 or q_last_status >= 500) and q_backoff_until is not null;
