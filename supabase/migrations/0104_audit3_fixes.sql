-- 0104: the fixes of the live audit of October 22, 2026 (docs/changes/2026-10-22-audit3-fixes.md).
--   1. Site health: a page check with no HTTP status (pg_net "Failure when receiving data from the peer") is a failed
--      check with its reason. It stopped the uptime job every minute from 17:36 UTC (null "ok"); each probe is now
--      recorded on its own, and a probe older than 15 minutes is dropped whatever happened to it.
--   2. IndexNow: a 429 pauses the whole queue until the next day (or the Retry-After time) without spending the
--      addresses' attempts; the queue sends at most the batch size and the day's room; the five-minute tick runs the
--      sweep when it has work; the 128 queued addresses start again.
--   3. Partner cars: one search title and heading each (the trim, then the colour, the car code or a short word).
--   4. Sample cars are never featured; the fleet list puts real cars first (the page, FleetBrowser).
--   5. Gearbox words keep their capitals ("Automatic (CVT)"); colours in capitals are written in proper case.
--   6. A car waiting for its trim has the address year-make-model (301 from the old one) and moves again when the trim
--      is picked.
--   7. (code) Every Workers AI call goes through the usage guard.
--   8. The budget alarm at 70% for the Worker's requests and CPU.
--   9. (code) Admin To do groups repeating lines.
--  10. A possible duplicate flag whose condition no longer holds is removed by the check itself.
--  11. The import size caps follow the database plan (Admin setting db_plan, Pro by default).
-- Functions it changes are wrapped (renamed _pre0104) or replaced whole where noted.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;
create function pg_temp.service_only(p regprocedure) returns void
language plpgsql as $$
begin
  execute format('revoke all on function %s from public, anon, authenticated', p);
  execute format('grant execute on function %s to service_role', p);
end $$;

-- ================================================================ 1. site health
-- a check result is ok only when it says so: a missing answer counts as a failure
alter function app.uptime_record(text, boolean, integer, integer, text, timestamptz, boolean) rename to uptime_record_pre0104;
create function app.uptime_record(p_key text, p_ok boolean, p_http integer default null, p_ms integer default null,
                                  p_detail text default null, p_now timestamptz default now(), p_waiting boolean default false) returns text
language sql security definer set search_path = public, app as $$
  select app.uptime_record_pre0104(p_key, coalesce(p_ok, false), p_http, p_ms, coalesce(p_detail, case when p_ok is null then 'No answer' end), p_now, coalesce(p_waiting, false))
$$;
select pg_temp.copy_grants('app.uptime_record(text, boolean, integer, integer, text, timestamptz, boolean)'::regprocedure,
                           'app.uptime_record_pre0104(text, boolean, integer, integer, text, timestamptz, boolean)'::regprocedure);

-- 0063's page result with a null status: "ok" was null. Now a failure with the reason pg_net gave.
create or replace function app.uptime_page_result(p_key text, p_status integer, p_headers jsonb, p_body text, p_timed_out boolean, p_error text,
                                                  p_ms integer, p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_site text := (select lower(value) from jsonb_each_text(coalesce(p_headers, '{}'::jsonb)) h(key, value) where lower(h.key) = 'x-carmacars-schema' limit 1);
  v_db text := app.schema_marker();
  v_answered boolean := coalesce(p_status between 200 and 399, false) and coalesce(p_timed_out, false) = false;
  v_health_bad boolean := p_key = 'health' and coalesce(p_body, '') !~ '"ok"\s*:\s*true';
begin
  if p_key = 'health' and p_status = 404 and coalesce(p_timed_out, false) = false and (v_site is null or v_site < v_db) then
    return app.uptime_record(p_key, true, p_status, p_ms,
      format('Waiting for the website deploy: the website (%s) is older than the database (%s), so /api/health is not there yet', coalesce(v_site, 'before 0063'), v_db),
      p_now, true);
  end if;
  return app.uptime_record(p_key, v_answered and not v_health_bad, p_status, p_ms,
    case when v_answered and v_health_bad then 'The health check answered without "ok": the site could not reach the database'
         else coalesce(app.uptime_page_detail(p_status, p_body, p_timed_out, p_error), 'No answer') end, p_now);
end $$;

-- 0063's job, replaced whole: each probe is recorded in its own block (one bad row never stops the others or the next
-- round), and a probe older than 15 minutes is dropped whatever happened to it.
create or replace function app.job_uptime(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  r record;
  v_id bigint;
  v_collected integer := 0;
  v_sent integer := 0;
  v_due boolean;
  v_net boolean := to_regclass('net._http_response') is not null;
  c uptime_checks;
  v_url text;
  v_err text;
begin
  if not ps.uptime_enabled then return 'off'; end if;
  -- 1. answers of the pages asked before
  if v_net then
    for r in execute $q$select p.request_id, p.check_key, p.sent_at, x.status_code, x.timed_out, x.error_msg, x.headers, left(x.content, 4000) as body, x.created
                          from uptime_probes p left join net._http_response x on x.id = p.request_id$q$ loop
      if r.created is null and r.sent_at > p_now - interval '3 minutes' then continue; end if;
      begin
        if r.created is null then
          perform app.uptime_record(r.check_key, false, null, null, 'No answer within 3 minutes', p_now);
        else
          perform app.uptime_page_result(r.check_key, r.status_code, r.headers, r.body, r.timed_out, r.error_msg,
            greatest(0, (extract(epoch from r.created - r.sent_at) * 1000)::integer), p_now);
        end if;
      exception when others then
        get stacked diagnostics v_err = message_text;
        begin
          perform app.uptime_record(r.check_key, false, r.status_code, null, left('The answer could not be read: ' || v_err, 300), p_now);
        exception when others then null;
        end;
      end;
      delete from uptime_probes where request_id = r.request_id;
      v_collected := v_collected + 1;
    end loop;
  end if;
  delete from uptime_probes where sent_at < p_now - interval '15 minutes';
  -- 2. time for the next round?
  v_due := not exists (select 1 from uptime_checks where kind = 'internal' and enabled and last_checked_at > p_now - make_interval(mins => ps.uptime_interval_minutes) + interval '30 seconds');
  if v_due then
    perform app.uptime_internal(p_now);
    if v_net then
      for c in select * from uptime_checks where kind = 'page' and enabled order by sort loop
        if exists (select 1 from uptime_probes p where p.check_key = c.key) then continue; end if;
        v_url := app.uptime_url(c.key);
        execute $q$select net.http_get(url := $1, headers := jsonb_build_object('User-Agent', 'CarmaCars site check', 'Cache-Control', 'no-cache'),
                                       timeout_milliseconds := 15000)$q$ into v_id using v_url;
        insert into uptime_probes (request_id, check_key, url, sent_at) values (v_id, c.key, v_url, p_now) on conflict do nothing;
        v_sent := v_sent + 1;
      end loop;
    end if;
    delete from uptime_results where at < p_now - make_interval(days => ps.uptime_keep_days);
  end if;
  -- 3. emails for real outages and recoveries (every minute, so the morning's held alerts go at 07:00)
  perform app.uptime_notify(p_now);
  if to_regclass('cron.job_run_details') is not null and app.local_hour(p_now) = 4 and extract(minute from p_now at time zone 'America/Toronto') < 5 then
    begin
      execute $q$delete from cron.job_run_details where end_time < $1 - interval '14 days'$q$ using p_now;
    exception when others then null;
    end;
  end if;
  return format('collected %s, asked %s', v_collected, v_sent);
end $$;

-- the probes stuck since 17:35 UTC (their answers can never be recorded by the old job)
delete from uptime_probes where sent_at < now() - interval '15 minutes';

-- ================================================================ 2. IndexNow
-- What a batch got. 2xx moves the cursor and counts. 429: the whole queue waits until the Retry-After time when the
-- engine gave one, else until 00:05 tomorrow (Toronto). 403 or 422 (the key refused) waits until tomorrow; anything else
-- 10 minutes. The cursor stays put on a failure. (0097's function, replaced whole.)
create or replace function app.server_indexnow_report(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_status integer := coalesce((p ->> 'status')::integer, 0);
  v_n integer := coalesce((p ->> 'count')::integer, 0);
  v_retry integer := nullif(p ->> 'retry_after', '')::integer;
  v_tomorrow integer := greatest(60, extract(epoch from (((now() at time zone 'America/Toronto')::date + 1 + time '00:05') at time zone 'America/Toronto') - now())::integer);
  w indexnow_sweep;
  v_wait integer;
begin
  select * into w from indexnow_sweep for update;
  if v_status between 200 and 299 then
    update indexnow_sweep set sent_today = case when day < (now() at time zone 'America/Toronto')::date then 0 else sent_today end + v_n,
           day = (now() at time zone 'America/Toronto')::date, backoff_s = 0, backoff_until = null, last_status = v_status, last_error = null,
           last_at = now(), updated_at = now(),
           file_i = case when p -> 'cursor' is not null then (p -> 'cursor' ->> 'file_i')::integer else file_i end,
           pos = case when p -> 'cursor' is not null then (p -> 'cursor' ->> 'pos')::bigint else pos end
     returning * into w;
    if (p ->> 'files') is not null and w.file_i >= (p ->> 'files')::integer then update indexnow_sweep set file_i = 0, pos = -1, rounds = rounds + 1 returning * into w; end if;
  else
    v_wait := case when v_status = 429 then case when v_retry > 0 then least(v_retry, 172800) else v_tomorrow end
                   when v_status in (403, 422) then v_tomorrow
                   else 600 end;
    update indexnow_sweep set backoff_s = v_wait, backoff_until = now() + make_interval(secs => v_wait), last_status = v_status, last_error = left(p ->> 'error', 300),
           last_at = now(), updated_at = now() returning * into w;
  end if;
  return to_jsonb(w);
end $$;

-- The changed addresses: a 429 (the engine's rate limit, nothing wrong with the address) spends no attempt; the whole
-- queue waits with the sweep. (0097's function, replaced whole.)
create or replace function app.server_indexnow_sent(p jsonb) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_status integer := coalesce((p ->> 'status')::integer, 0);
  v_ok boolean := v_status between 200 and 299;
  n integer;
begin
  update indexnow_queue set attempts = attempts + case when v_status = 429 then 0 else 1 end, last_status = v_status, last_error = left(p ->> 'error', 300),
         sent_at = case when v_ok then now() else sent_at end
   where path = any (array(select jsonb_array_elements_text(coalesce(p -> 'paths', '[]'::jsonb))));
  get diagnostics n = row_count;
  perform app.server_indexnow_report(jsonb_build_object('status', v_status, 'count', n, 'error', p ->> 'error', 'retry_after', p ->> 'retry_after'));
  return n;
end $$;

-- The search job's claim: no changed address while the queue waits, and at most the batch size and the day's room.
alter function app.server_seo_claim(text, integer) rename to server_seo_claim_pre0104;
create function app.server_seo_claim(p_worker text, p_limit integer default 3) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c jsonb := app.server_seo_claim_pre0104(p_worker, p_limit);
  ps program_settings := app.settings();
  w indexnow_sweep;
  v_room integer;
begin
  select * into w from indexnow_sweep;
  v_room := least(500, ps.indexnow_batch,
                  greatest(ps.indexnow_daily_max - case when w.day < (now() at time zone 'America/Toronto')::date then 0 else coalesce(w.sent_today, 0) end, 0));
  if c -> 'indexnow' is null then return c; end if;
  if w.backoff_until > now() or v_room <= 0 then
    return jsonb_set(c, '{indexnow,paths}', '[]'::jsonb) || jsonb_build_object('indexnow_wait', w.backoff_until);
  end if;
  return jsonb_set(c, '{indexnow,paths}', coalesce((select jsonb_agg(x order by n) from jsonb_array_elements(c #> '{indexnow,paths}') with ordinality e(x, n) where n <= v_room), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.server_seo_claim(text, integer)'::regprocedure, 'app.server_seo_claim_pre0104(text, integer)'::regprocedure);

-- The five-minute tick: the search job runs when IndexNow has work it may send now (the changed addresses, or the
-- sweep of the vehicle pages once the catalog has makes), never while the queue waits.
alter function app.server_jobs_due() rename to server_jobs_due_pre0104;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.server_jobs_due_pre0104();
  ps program_settings := app.settings();
  w indexnow_sweep;
  v_send boolean;
  v_seo boolean;
begin
  select * into w from indexnow_sweep;
  v_send := ps.indexnow_enabled and not coalesce(w.backoff_until > now(), false)
            and (w.day < (now() at time zone 'America/Toronto')::date or w.sent_today < ps.indexnow_daily_max);
  v_seo := exists (select 1 from car_copy c where c.status in ('pending', 'failed') and c.next_attempt_at <= now())
        or exists (select 1 from seo_pages p where p.is_active and p.status in ('pending', 'failed') and p.next_attempt_at <= now())
        or exists (select 1 from articles a where a.status in ('pending', 'failed') and a.next_attempt_at <= now())
        or exists (select 1 from seo_pages p where p.status = 'running' and p.locked_at < now() - interval '10 minutes')
        or exists (select 1 from articles a where a.status = 'running' and a.locked_at < now() - interval '10 minutes')
        or (v_send and exists (select 1 from indexnow_queue q where q.sent_at is null and q.attempts < 5))
        or (v_send and to_regclass('public.vehicle_catalog_makes') is not null and exists (select 1 from vehicle_catalog_makes));
  return v || jsonb_build_object('seo', v_seo);
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre0104()'::regprocedure);

-- every queued address starts again, and the queue may send at the next tick (to Bing's endpoint now, web/src/server/seo-job.ts)
update indexnow_queue set attempts = 0 where sent_at is null;
update indexnow_sweep set backoff_s = 0, backoff_until = null, updated_at = now() where backoff_until is not null;

-- ================================================================ 3 and 5. one title and heading per car; gearbox capitals
-- The tie breaker (0074): twins are the cars on the site with the same year, make and model (a partner car, named with
-- its trim: also the same trim; partner cars have no year yet, so a missing year matches a missing year). The mark is
-- the colour when no twin has it, else the car code, else a short word from the car.
create or replace function app.listing_seo_mark(p_vehicle uuid) returns text
language sql stable security definer set search_path = public, app as $$
  with me as (select v.* from vehicles v where v.id = p_vehicle),
       twins as (select o.* from vehicles o join vehicle_listings l on l.vehicle_id = o.id, me
                  where o.id <> me.id and l.status in ('published', 'paused') and not coalesce(o.is_sample, false)
                    and o.year is not distinct from me.year
                    and lower(btrim(o.make)) = lower(btrim(me.make)) and lower(btrim(o.model)) = lower(btrim(me.model))
                    and (me.supply_type::text is distinct from 'partner' or lower(btrim(coalesce(o.trim, ''))) = lower(btrim(coalesce(me.trim, '')))))
  select case
    when coalesce(me.is_sample, false) or not exists (select 1 from twins) then null
    when nullif(btrim(me.colour), '') is not null
         and not exists (select 1 from twins t where lower(btrim(t.colour)) = lower(btrim(me.colour))) then lower(btrim(me.colour))
    when nullif(btrim(me.car_code), '') is not null
         and not exists (select 1 from twins t where t.car_code = me.car_code) then btrim(me.car_code)
    else 'car ' || upper(left(md5(me.id::text), 4)) end
    from me
$$;

-- "automatic (cvt)" came from lower(transmission) in the plain copy (0061): the gearbox keeps its capitals
create or replace function app.gearbox_case(p text) returns text
language sql immutable as $$
  select regexp_replace(regexp_replace(p, '\mautomatic \(cvt\)', 'Automatic (CVT)', 'gi'), '\mautomatic \(dual-clutch\)', 'Automatic (dual-clutch)', 'gi')
$$;

-- The copy of one car, made right where it is: gearbox capitals, and the search title and heading with the car's mark
-- when it has twins. Fields a person locked are kept. Nothing else of the copy (its status, the AI rewrite due) changes.
create or replace function app.car_copy_touch_0104(p_vehicle uuid) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  cc car_copy;
  v vehicles;
  v_mark text := app.listing_seo_mark(p_vehicle);
  v_city text := coalesce((select nullif(btrim(city), '') from site_settings limit 1), 'Toronto');
  v_brand text := coalesce((select nullif(btrim(brand_name), '') from site_settings limit 1), 'CarmaCars');
  v_name text;
  v_sfx text;
  c jsonb;
  k text;
  t text;
begin
  select * into cc from car_copy where vehicle_id = p_vehicle for update;
  if cc.vehicle_id is null or cc.copy is null or cc.copy = '{}'::jsonb then return false; end if;
  select * into v from vehicles where id = p_vehicle;
  c := cc.copy;
  foreach k in array array['seo_title', 'meta_description', 'h1', 'intro'] loop
    if jsonb_typeof(c -> k) = 'string' and not (k = any (coalesce(cc.locked, '{}'))) then c := c || jsonb_build_object(k, app.gearbox_case(c ->> k)); end if;
  end loop;
  -- a partner car is named with its trim (several trims of one model), and never with a year that is not confirmed
  if v_mark is not null or v.supply_type::text = 'partner' then
    v_name := concat_ws(' ', case when coalesce(v.year_approximate, false) then null else v.year::text end, v.make, v.model,
                        case when v.supply_type::text = 'partner' or v_mark is not null then nullif(btrim(v.trim), '') end);
    v_sfx := coalesce(' (' || v_mark || ')', '');
    if not ('seo_title' = any (coalesce(cc.locked, '{}'))) then
      t := 'Rent a ' || v_name || ' in ' || v_city || v_sfx;
      if v_mark is null and length(t || ' | ' || v_brand) <= 60 then t := t || ' | ' || v_brand; end if;
      if length(t) > 60 then t := v_name || ' rental, ' || v_city || v_sfx; end if;
      if length(t) > 60 then t := left(v_name, greatest(60 - length(v_sfx), 10)) || v_sfx; end if;
      c := c || jsonb_build_object('seo_title', left(t, 60));
    end if;
    if not ('h1' = any (coalesce(cc.locked, '{}'))) then
      t := v_name || ' for rent in ' || v_city || v_sfx;
      if length(t) > 70 then t := v_name || v_sfx; end if;
      c := c || jsonb_build_object('h1', t);
    end if;
  end if;
  if c = cc.copy then return false; end if;
  update car_copy set copy = c where vehicle_id = p_vehicle;
  update vehicle_listings set headline = coalesce(c ->> 'h1', headline), seo_title = coalesce(c ->> 'seo_title', seo_title),
         seo_description = coalesce(c ->> 'meta_description', seo_description), description = coalesce(c ->> 'intro', description)
   where vehicle_id = p_vehicle
     and (headline, seo_title, seo_description, description) is distinct from
         (coalesce(c ->> 'h1', headline), coalesce(c ->> 'seo_title', seo_title), coalesce(c ->> 'meta_description', seo_description), coalesce(c ->> 'intro', description));
  return true;
end $$;
select pg_temp.service_only('app.car_copy_touch_0104(uuid)'::regprocedure);

-- every copy put live (plain or written) gets the same treatment
alter function app.car_copy_apply(uuid, jsonb, text, text) rename to car_copy_apply_pre0104;
create function app.car_copy_apply(p_vehicle uuid, p_copy jsonb, p_source text, p_facts_hash text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb := app.car_copy_apply_pre0104(p_vehicle, p_copy, p_source, p_facts_hash);
begin
  perform app.car_copy_touch_0104(p_vehicle);
  return r;
end $$;
select pg_temp.copy_grants('app.car_copy_apply(uuid, jsonb, text, text)'::regprocedure, 'app.car_copy_apply_pre0104(uuid, jsonb, text, text)'::regprocedure);

-- colours in capitals ("BLACK", from a VIN decode or typed) are written in proper case on every insert and update, as
-- make, model and trim are (0087)
create or replace function app.vehicle_colour_case() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  new.colour := app.car_name_case(new.colour, 'colour');
  return new;
end $$;
drop trigger if exists vehicles_a0_colour_case on vehicles;
create trigger vehicles_a0_colour_case before insert or update of colour on vehicles for each row execute function app.vehicle_colour_case();
select pg_temp.service_only('app.vehicle_colour_case()'::regprocedure);

do $$
declare r record;
begin
  for r in select v.id, v.colour, v.is_sample from vehicles v where app.car_name_case(v.colour, 'colour') is distinct from v.colour loop
    update vehicles set colour = colour where id = r.id;   -- the trigger writes the case
    if not coalesce(r.is_sample, false) then perform app.car_copy_again(r.id, 'colour case'); end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (null, 'colour_case', 'vehicles', r.id::text, jsonb_build_object('before', r.colour, 'note', 'Colour in capitals written in proper case (0104)'));
  end loop;
end $$;

-- ================================================================ 4. sample cars are never featured
create or replace function app.listing_sample_not_featured() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.is_featured and exists (select 1 from vehicles v where v.id = new.vehicle_id and coalesce(v.is_sample, false)) then new.is_featured := false; end if;
  return new;
end $$;
drop trigger if exists vehicle_listings_sample_not_featured on vehicle_listings;
create trigger vehicle_listings_sample_not_featured before insert or update of is_featured on vehicle_listings for each row execute function app.listing_sample_not_featured();
select pg_temp.service_only('app.listing_sample_not_featured()'::regprocedure);
update vehicle_listings l set is_featured = false from vehicles v where v.id = l.vehicle_id and coalesce(v.is_sample, false) and l.is_featured;

-- ================================================================ 6. a car waiting for its trim
-- Its address is year-make-model (the trim list left out); the old address answers 301. Picking the trim moves it again.
alter function app.vehicle_pick_trim(uuid, jsonb) rename to vehicle_pick_trim_pre0104;
create function app.vehicle_pick_trim(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb := app.vehicle_pick_trim_pre0104(p_by, p);
  v_slug text := app.listing_move_to_clean_slug((r ->> 'vehicle_id')::uuid);
begin
  return r || jsonb_build_object('slug', v_slug);
end $$;
select pg_temp.copy_grants('app.vehicle_pick_trim(uuid, jsonb)'::regprocedure, 'app.vehicle_pick_trim_pre0104(uuid, jsonb)'::regprocedure);

do $$
declare r record; v_new text;
begin
  for r in select v.id, l.slug from vehicles v join vehicle_listings l on l.vehicle_id = v.id
            where v.trim_candidates is not null and nullif(btrim(v.trim), '') is null and not coalesce(v.is_sample, false) and l.slug is not null loop
    v_new := app.listing_move_to_clean_slug(r.id);
    if v_new is distinct from r.slug then
      insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
      values (null, 'listing_slug_trim_wait', 'vehicles', r.id::text, jsonb_build_object('slug', r.slug), jsonb_build_object('slug', v_new));
    end if;
  end loop;
end $$;

-- the copy of every car on the site made right (after the colours and addresses above)
select count(*) filter (where app.car_copy_touch_0104(l.vehicle_id)) from vehicle_listings l join vehicles v on v.id = l.vehicle_id
 where l.status in ('published', 'paused') and not coalesce(v.is_sample, false);

-- ================================================================ 8. budget alarm at 70% (0097's Integration 1)
update usage_services set warn_bps = 7000 where service in ('workers_requests', 'workers_cpu');

-- ================================================================ 10. possible duplicates that no longer hold
-- The check removes the open flags of the kinds it compared that it did not find again (no person decided them, so they
-- are not marked cleared by anyone), and closes the car's duplicate task when no open flag that stops publishing is left (as 0040).
alter function app.check_listing_similarity(uuid, text) rename to check_listing_similarity_pre0104;
create function app.check_listing_similarity(p_vehicle uuid, p_what text default 'all') returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_kinds text[] := case p_what when 'vehicle' then array['vin', 'plate', 'specs'] when 'photo' then array['photo'] when 'copy' then array['copy']
                                else array['vin', 'plate', 'specs', 'photo', 'copy'] end;
  n integer;
  v_gone integer;
begin
  n := app.check_listing_similarity_pre0104(p_vehicle, p_what);
  if not (app.settings()).listing_similarity_enabled then return n; end if;
  with d as (delete from listing_similarity_flags f
              where f.vehicle_id = p_vehicle and f.status = 'open' and f.kind = any (v_kinds) and f.last_seen_at < now()
              returning f.id, f.kind, f.other_vehicle_id, f.detail),
       a as (insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
             select null, 'similarity_gone', 'listing_similarity_flags', d.id::text,
                    jsonb_build_object('kind', d.kind, 'other_vehicle_id', d.other_vehicle_id, 'detail', d.detail, 'note', 'No longer holds (0104)') from d returning 1)
  select count(*) into v_gone from a;
  if v_gone > 0 and not exists (select 1 from listing_similarity_flags f where f.vehicle_id = p_vehicle and f.status = 'open' and f.blocking) then
    update tasks set status = 'done', completed_at = now(), completion_note = 'Closed by itself: the possible duplicate no longer holds'
     where task_type = 'listing_similarity' and vehicle_id = p_vehicle and status in ('open', 'in_progress', 'waiting');
  end if;
  return (select count(*)::integer from listing_similarity_flags f where f.vehicle_id = p_vehicle and f.status = 'open' and f.blocking);
end $$;
select pg_temp.copy_grants('app.check_listing_similarity(uuid, text)'::regprocedure, 'app.check_listing_similarity_pre0104(uuid, text)'::regprocedure);

do $$
declare r record;
begin
  perform set_config('app.similarity_quiet', 'on', true);
  for r in select distinct f.vehicle_id from listing_similarity_flags f where f.status = 'open' loop
    perform app.check_listing_similarity(r.vehicle_id, 'all');
  end loop;
  perform set_config('app.similarity_quiet', '', true);
end $$;

-- ================================================================ 11. the import size caps follow the database plan
alter table program_settings
  add column if not exists db_plan text not null default 'pro' check (db_plan in ('free', 'pro')),
  add column if not exists db_cap_free_mb integer not null default 450 check (db_cap_free_mb between 100 and 100000),
  add column if not exists db_cap_pro_mb integer not null default 6144 check (db_cap_pro_mb between 100 and 100000);
comment on column program_settings.db_plan is 'The Supabase plan of the database (0104): free (500 MB) or pro (8 GB). The catalog and places imports keep the database under that plan''s cap. Postgres cannot read the plan, so it is set here.';
comment on column program_settings.db_cap_free_mb is 'Database size cap on the Free plan (MB, 0104): the imports stop before the database passes it. Free makes the database read only above 500 MB.';
comment on column program_settings.db_cap_pro_mb is 'Database size cap on the Pro plan (MB, 0104). Pro includes 8 GB.';

-- the two import caps (0095, 0097) are the plan's cap: set to it when the plan or its cap changes, never above it
create or replace function app.program_settings_db_cap() returns trigger
language plpgsql set search_path = public, app as $$
declare
  v_cap integer := case when new.db_plan = 'free' then new.db_cap_free_mb else new.db_cap_pro_mb end;
begin
  if tg_op = 'INSERT' or (new.db_plan, new.db_cap_free_mb, new.db_cap_pro_mb) is distinct from (old.db_plan, old.db_cap_free_mb, old.db_cap_pro_mb) then
    new.vpage_import_db_cap_mb := v_cap;
    new.place_db_cap_mb := v_cap;
  else
    new.vpage_import_db_cap_mb := least(new.vpage_import_db_cap_mb, v_cap);
    new.place_db_cap_mb := least(new.place_db_cap_mb, v_cap);
  end if;
  return new;
end $$;
drop trigger if exists program_settings_db_cap on program_settings;
create trigger program_settings_db_cap before insert or update on program_settings for each row execute function app.program_settings_db_cap();
-- and the usage guard's database allowance (Settings > Usage) follows the plan of the settings in force
create or replace function app.program_settings_db_allowance() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  update usage_services set included = case when (app.settings()).db_plan = 'free' then 524288000 else 8589934592 end
   where service = 'supabase_db' and included is distinct from case when (app.settings()).db_plan = 'free' then 524288000 else 8589934592 end;
  return null;
end $$;
drop trigger if exists program_settings_db_allowance on program_settings;
create trigger program_settings_db_allowance after insert or update of db_plan on program_settings for each statement execute function app.program_settings_db_allowance();
select pg_temp.service_only('app.program_settings_db_cap()'::regprocedure);
select pg_temp.service_only('app.program_settings_db_allowance()'::regprocedure);
update program_settings set db_plan = 'pro', db_cap_pro_mb = db_cap_pro_mb + 0;
update program_settings set vpage_import_db_cap_mb = case when db_plan = 'free' then db_cap_free_mb else db_cap_pro_mb end,
                            place_db_cap_mb = case when db_plan = 'free' then db_cap_free_mb else db_cap_pro_mb end;

-- ================================================================ privileges of the new helpers
select pg_temp.service_only('app.gearbox_case(text)'::regprocedure);
grant execute on function app.gearbox_case(text) to authenticated;
revoke all on function app.listing_seo_mark(uuid) from public, anon, authenticated;
grant execute on function app.listing_seo_mark(uuid) to service_role;

-- ================================================================ the guides
update guide_sections set
  body_md = replace(body_md, 'the cap the catalog import keeps under (6,144 MB by default)', 'the cap the catalog and places imports keep under: the cap of the Database plan (Pro, 6,144 MB, by default; Free, 450 MB)'),
  published_md = replace(published_md, 'the cap the catalog import keeps under (6,144 MB by default)', 'the cap the catalog and places imports keep under: the cap of the Database plan (Pro, 6,144 MB, by default; Free, 450 MB)'),
  published_html = replace(published_html, 'the cap the catalog import keeps under (6,144 MB by default)', 'the cap the catalog and places imports keep under: the cap of the Database plan (Pro, 6,144 MB, by default; Free, 450 MB)')
 where portal = 'admin' and slug = 'search-car-pages-landing-pages-and-guides';
update guide_sections set
  body_md = replace(body_md, '1. Each piece of work is its own line, marked', '1. Each piece of work is its own line (work of one kind for several cars is one line, such as Add real photos (72 cars); its button opens the list), marked'),
  published_md = replace(published_md, '1. Each piece of work is its own line, marked', '1. Each piece of work is its own line (work of one kind for several cars is one line, such as Add real photos (72 cars); its button opens the list), marked'),
  published_html = replace(published_html, 'Each piece of work is its own line, marked', 'Each piece of work is its own line (work of one kind for several cars is one line, such as Add real photos (72 cars); its button opens the list), marked')
 where portal = 'admin' and slug = 'getting-around-admin';
