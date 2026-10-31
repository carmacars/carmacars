-- 0220: IndexNow sends the changed pages first, on their own back-off, and the sweep stays inside the crawl scope
-- (docs/changes/2026-11-03-indexnow-changed-pages-first.md, docs/changes/2026-11-03-crawl-scope.md).
--
-- Why nothing was sent (Settings > Search: 133 addresses waiting, 0 sent in 7 days): the changed pages (a car, a landing
-- page, a guide) and the sweep of the vehicle and place pages (0097, 0124) shared one back-off. The sweep sent batches of
-- 10,000 machine-made addresses until Bing answered 429 TooManyRequests; with no Retry-After that held everything until
-- 00:05 the next day, and the first batch of the new day was refused again (live: the last 429 at 00:05:24, back-off to the
-- next midnight, sweep at place file 314). The 133 real pages never had a turn.
--
-- 1. The changed pages (indexnow_queue) have their own back-off (indexnow_sweep.q_*): a 429 waits its Retry-After, else
--    1 hour, doubling to at most 24 hours; a 403 or 422 waits until tomorrow; another failure 10 minutes. The sweep's
--    back-off and daily ceiling no longer hold them back, and theirs no longer holds back the sweep... except that:
-- 2. The sweep waits while changed pages are waiting (they go first, alone), and after a 429 without Retry-After it waits
--    one more day for each 429 in a row (at most a week).
-- 3. The sweep sends the priority list only, within the crawl scope (web/src/lib/edge/crawl-scope.ts: no place page, no
--    page below the trim, no search term, for sale, detailing or body shop tree), then waits 7 days for its next round.
-- 4. The five-minute tick runs the search job when the changed pages may go out, or the sweep may (2 and 3).
-- 5. Settings > Search shows the last answer and the back-off of each.
-- 6. The tick also says whether the month's Worker CPU time is at 70% of its allowance or more (cpu_guard), for the
--    Worker's crawler guard.
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

alter table indexnow_sweep
  add column if not exists q_backoff_until timestamptz,
  add column if not exists q_backoff_s integer not null default 0,
  add column if not exists q_last_status integer,
  add column if not exists q_last_error text,
  add column if not exists q_last_at timestamptz,
  add column if not exists streak_429 integer not null default 0,
  add column if not exists next_round_at timestamptz;
comment on column indexnow_sweep.q_backoff_until is 'The changed pages (indexnow_queue) wait until then after a refusal (0220); their own, apart from the sweep''s backoff_until.';
comment on column indexnow_sweep.streak_429 is 'The sweep''s 429 answers in a row (0220): each adds a day to the wait, at most a week.';
comment on column indexnow_sweep.next_round_at is 'The sweep''s next round of the priority list starts then (0220: a round a week).';

-- the crawl scope, as web/src/lib/edge/crawl-scope.ts says it (keep the two in step)
create or replace function app.crawl_scope_ok(p_path text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_path is not null
     and p_path !~ '^/(t|buy)(/|$)'
     and p_path !~ '^/cars/[^/]+/[^/]+/[^/]+/[^/]+/[^/]+'
     and p_path !~ '^/(car-rental|detailing|body-shop)/[^/]+/[^/]+'
     and p_path !~ '^/places/.'
     and (p_path !~ '^/car-rental/[^/]+$' or exists (select 1 from seo_pages s where app.seo_page_path(s.slug) = p_path and s.is_active))
$$;

-- whether the changed pages may be sent now
create or replace function app.indexnow_queue_ready() returns boolean
language sql stable security definer set search_path = public, app as $$
  select (app.settings()).indexnow_enabled
     and not coalesce((select q_backoff_until > now() from indexnow_sweep limit 1), false)
     and exists (select 1 from indexnow_queue q where q.sent_at is null and q.attempts < 5)
$$;

-- ================================================================ 1. the changed pages: their own claim limit and back-off
-- server_seo_claim's IndexNow part (0104's wrapper, renamed pre0133 by 0133): at most 500 a run, the queue's back-off only
create or replace function app.server_seo_claim_pre0133(p_worker text, p_limit integer default 3) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c jsonb := app.server_seo_claim_pre0104(p_worker, p_limit);
  ps program_settings := app.settings();
  w indexnow_sweep;
begin
  select * into w from indexnow_sweep;
  if c -> 'indexnow' is null then return c; end if;
  if w.q_backoff_until > now() then
    return jsonb_set(c, '{indexnow,paths}', '[]'::jsonb) || jsonb_build_object('indexnow_wait', w.q_backoff_until);
  end if;
  return jsonb_set(c, '{indexnow,paths}', coalesce((select jsonb_agg(x order by n) from jsonb_array_elements_text(c #> '{indexnow,paths}') with ordinality e(x, n)
                                                    where n <= least(500, ps.indexnow_batch) and app.crawl_scope_ok(x)), '[]'::jsonb));
end $$;

-- the answer for the changed pages: their rows, and the queue's own back-off (never the sweep's)
create or replace function app.server_indexnow_sent(p jsonb) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_status integer := coalesce((p ->> 'status')::integer, 0);
  v_ok boolean := v_status between 200 and 299;
  v_retry integer := nullif(p ->> 'retry_after', '')::integer;
  v_tomorrow integer := greatest(60, extract(epoch from (((now() at time zone 'America/Toronto')::date + 1 + time '00:05') at time zone 'America/Toronto') - now())::integer);
  w indexnow_sweep;
  v_wait integer;
  n integer;
begin
  update indexnow_queue set attempts = attempts + case when v_status = 429 then 0 else 1 end, last_status = v_status, last_error = left(p ->> 'error', 300),
         sent_at = case when v_ok then now() else sent_at end
   where path = any (array(select jsonb_array_elements_text(coalesce(p -> 'paths', '[]'::jsonb))));
  get diagnostics n = row_count;
  select * into w from indexnow_sweep for update;
  if v_ok then
    update indexnow_sweep set q_backoff_until = null, q_backoff_s = 0, q_last_status = v_status, q_last_error = null, q_last_at = now(),
           sent_today = case when day < (now() at time zone 'America/Toronto')::date then 0 else sent_today end + n,
           day = (now() at time zone 'America/Toronto')::date, updated_at = now()
     where id;
  else
    v_wait := case when v_status = 429 then case when v_retry > 0 then least(v_retry, 172800) else least(greatest(3600, coalesce(w.q_backoff_s, 0) * 2), 86400) end
                   when v_status in (403, 422) then v_tomorrow
                   else 600 end;
    update indexnow_sweep set q_backoff_s = v_wait, q_backoff_until = now() + make_interval(secs => v_wait), q_last_status = v_status,
           q_last_error = left(p ->> 'error', 300), q_last_at = now(), updated_at = now()
     where id;
  end if;
  return n;
end $$;

-- ================================================================ 2 and 3. the sweep: after the changed pages, inside the scope, a round a week
alter function app.server_indexnow_claim(integer) rename to server_indexnow_claim_pre0220;
create function app.server_indexnow_claim(p_limit integer) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  w indexnow_sweep;
  c jsonb;
  v_in jsonb;
begin
  select * into w from indexnow_sweep for update;
  if not (app.settings()).indexnow_enabled then return app.server_indexnow_claim_pre0220(p_limit); end if;
  if exists (select 1 from indexnow_queue q where q.sent_at is null and q.attempts < 5) then
    return jsonb_build_object('paths', '[]'::jsonb, 'why', 'changed pages first');
  end if;
  if w.backoff_until > now() then return app.server_indexnow_claim_pre0220(p_limit); end if;
  if w.next_round_at > now() then
    return jsonb_build_object('paths', '[]'::jsonb, 'why', 'next round', 'until', w.next_round_at);
  end if;
  -- the priority list only: past it (the place and vehicle files are out of the crawl scope) the round is done
  if w.phase <> 'priority' then
    update indexnow_sweep set phase = 'priority', p_i = 0, p_pos = 0, file_i = 0, pos = -1, rounds = rounds + 1,
           next_round_at = now() + interval '7 days', updated_at = now() where id;
    return jsonb_build_object('paths', '[]'::jsonb, 'why', 'next round', 'until', now() + interval '7 days');
  end if;
  c := app.server_indexnow_claim_pre0220(p_limit);
  if coalesce(jsonb_array_length(c -> 'paths'), 0) = 0 then return c; end if;
  v_in := coalesce((select jsonb_agg(x order by n) from jsonb_array_elements_text(c -> 'paths') with ordinality e(x, n) where app.crawl_scope_ok(x)), '[]'::jsonb);
  if jsonb_array_length(v_in) = 0 then
    -- nothing of the batch is in the scope: the cursor moves past it now (no answer will come back to move it)
    update indexnow_sweep set phase = coalesce(c #>> '{cursor,phase}', phase), p_i = coalesce((c #>> '{cursor,p_i}')::integer, p_i),
           p_pos = coalesce((c #>> '{cursor,p_pos}')::bigint, p_pos), updated_at = now() where id;
    return jsonb_build_object('paths', '[]'::jsonb, 'why', 'nothing in the crawl scope', 'phase', c #>> '{cursor,phase}');
  end if;
  return jsonb_set(c, '{paths}', v_in);
end $$;
select pg_temp.copy_grants('app.server_indexnow_claim(integer)'::regprocedure, 'app.server_indexnow_claim_pre0220(integer)'::regprocedure);

alter function app.server_indexnow_report(jsonb) rename to server_indexnow_report_pre0220;
create function app.server_indexnow_report(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_status integer := coalesce((p ->> 'status')::integer, 0);
  v_retry integer := nullif(p ->> 'retry_after', '')::integer;
  w jsonb := app.server_indexnow_report_pre0220(p);
  v_streak integer;
begin
  if v_status between 200 and 299 then
    update indexnow_sweep set streak_429 = 0 where id;
  elsif v_status = 429 then
    update indexnow_sweep set streak_429 = streak_429 + 1 where id returning streak_429 into v_streak;
    -- no Retry-After: until tomorrow (0104), and one more day for each 429 in a row before it, at most a week
    if coalesce(v_retry, 0) <= 0 and v_streak > 1 then
      update indexnow_sweep set backoff_until = backoff_until + make_interval(days => least(v_streak - 1, 6)),
             backoff_s = backoff_s + least(v_streak - 1, 6) * 86400 where id;
    end if;
  end if;
  return (select to_jsonb(x) from indexnow_sweep x limit 1);
end $$;
select pg_temp.copy_grants('app.server_indexnow_report(jsonb)'::regprocedure, 'app.server_indexnow_report_pre0220(jsonb)'::regprocedure);

-- ================================================================ 4. the five-minute tick
alter function app.server_jobs_due() rename to server_jobs_due_pre0220;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.server_jobs_due_pre0220();
  ps program_settings := app.settings();
  w indexnow_sweep;
  v_seo boolean;
  v_cpu boolean;
begin
  select * into w from indexnow_sweep;
  v_seo := exists (select 1 from car_copy c where c.status in ('pending', 'failed') and c.next_attempt_at <= now())
        or exists (select 1 from seo_pages p where p.is_active and p.status in ('pending', 'failed') and p.next_attempt_at <= now())
        or exists (select 1 from articles a where a.status in ('pending', 'failed') and a.next_attempt_at <= now())
        or exists (select 1 from seo_pages p where p.status = 'running' and p.locked_at < now() - interval '10 minutes')
        or exists (select 1 from articles a where a.status = 'running' and a.locked_at < now() - interval '10 minutes')
        or app.indexnow_queue_ready()
        or (ps.indexnow_enabled and not exists (select 1 from indexnow_queue q where q.sent_at is null and q.attempts < 5)
            and not coalesce(w.backoff_until > now(), false) and not coalesce(w.next_round_at > now(), false)
            and (w.day < (now() at time zone 'America/Toronto')::date or w.sent_today < ps.indexnow_daily_max));
  -- R23: the month's Worker CPU time at 70% of the included allowance or more (the owner's choice): the Worker keeps
  -- crawlers off the catalog pages (web/src/lib/edge/bot-shield.ts cpuGuard)
  begin
    v_cpu := coalesce((app.usage_state('workers_cpu', now()) ->> 'share_bps')::integer >= 7000, false);
  exception when others then v_cpu := false;
  end;
  return v || jsonb_build_object('seo', v_seo, 'cpu_guard', v_cpu);
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre0220()'::regprocedure);

-- ================================================================ 5. Settings > Search
alter function app.seo_overview(uuid) rename to seo_overview_pre0220;
create function app.seo_overview(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.seo_overview_pre0220(p_admin);
  w indexnow_sweep;
begin
  select * into w from indexnow_sweep;
  if v ? 'indexnow' then
    v := jsonb_set(v, '{indexnow}', (v -> 'indexnow') || jsonb_build_object(
      'answer', jsonb_build_object('status', w.q_last_status, 'error', w.q_last_error, 'at', w.q_last_at, 'until', case when w.q_backoff_until > now() then w.q_backoff_until end),
      'sweep', jsonb_build_object('status', w.last_status, 'error', w.last_error, 'at', w.last_at, 'until', case when w.backoff_until > now() then w.backoff_until end,
                                  'next_round', case when w.next_round_at > now() then w.next_round_at end, 'streak_429', w.streak_429),
      'out_of_scope', (select count(*) from indexnow_queue q where q.sent_at is null and not app.crawl_scope_ok(q.path))));
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.seo_overview(uuid)'::regprocedure, 'app.seo_overview_pre0220(uuid)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('crawl_scope_ok', 'indexnow_queue_ready', 'server_indexnow_claim_pre0220', 'server_indexnow_report_pre0220',
                                                     'server_jobs_due_pre0220', 'seo_overview_pre0220') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- the changed pages may go out at the next tick; addresses of the queue outside the crawl scope are dropped (never sent)
update indexnow_sweep set q_backoff_until = null, q_backoff_s = 0 where id;
delete from indexnow_queue where sent_at is null and not app.crawl_scope_ok(path);
