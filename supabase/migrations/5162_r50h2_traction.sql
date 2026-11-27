-- 5162_r50h2_traction.sql
-- Release 50 hotfix 2 (the owner): the investor deck and the investor portal show monthly active users (website and app)
-- and the days rented each month, with a metric model that is the same for every business, so the Almash builds use it
-- later with their own measures (merch: items customized; phones: phones purchased).
--   1. traction_metrics: the measures a business shows (business, code, label, unit, order, on). CarmaCars: mau_web,
--      mau_app, days_rented. Another business adds its own rows (for example ('merch', 'items_customized', 'Items
--      customized', 'items')) and fills traction_monthly from its own job.
--   2. traction_monthly: one value per business, measure and month. CarmaCars' values are worked out by
--      app.traction_refresh (at most once an hour, from the visitor history job): distinct browsers with a visit in the
--      month on the website and in the app (visitor_sessions.via, new: the app shell marks its beacon), and the rented
--      days of real bookings (handed over, returned or closed; test bookings left out), each booking's days split over the
--      months they fall in. A month already stored keeps its value once the visits behind it are deleted (90 days).
--   3. investor_read / admin_read 'deck_traction': the last 12 months of each measure, for the deck and the portal.
-- Visitors are counted from the site's own first-party beacon, sessions with an exclude_reason (bots, staff) left out as
-- in 0118's visitor numbers. It is a floor, and the deck says so.
-- No applied migration is edited: app.track_ingest, app.job_visitor_history and app.door are wrapped.
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1 and 2. the model
create table traction_metrics (
  business    text not null default 'carmacars' check (business ~ '^[a-z][a-z0-9_]{1,30}$'),
  code        text not null check (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  label       text not null check (length(label) between 2 and 80),
  unit        text not null check (length(unit) between 1 and 30),
  note        text check (length(note) <= 300),
  sort_order  integer not null default 100,
  active      boolean not null default true,
  primary key (business, code)
);
comment on table traction_metrics is 'Traction (5162): the monthly measures a business shows investors, the same model for every Almash business (CarmaCars: website and app monthly active users, days rented; merch: items customized; phones: phones purchased).';

create table traction_monthly (
  business    text not null,
  code        text not null,
  month       date not null check (extract(day from month) = 1),
  value       numeric not null check (value >= 0),
  updated_at  timestamptz not null default now(),
  primary key (business, code, month),
  foreign key (business, code) references traction_metrics (business, code) on delete cascade
);
comment on table traction_monthly is 'Traction (5162): one value per business, measure and month (the first of the month). CarmaCars is filled by app.traction_refresh; another business fills its own.';

do $$
declare t text;
begin
  foreach t in array array['traction_metrics', 'traction_monthly'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from public, anon, authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('grant select on %I to authenticated', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
end $$;

insert into traction_metrics (business, code, label, unit, note, sort_order) values
  ('carmacars', 'mau_web', 'Monthly active users, website', 'people', 'Distinct browsers with a visit in the month, counted by the site''s own beacon, with bots and staff left out (the same filter as the visitor numbers): a floor.', 10),
  ('carmacars', 'mau_app', 'Monthly active users, app', 'people', 'Distinct devices that opened the iPhone or Android app in the month.', 20),
  ('carmacars', 'days_rented', 'Days rented', 'days', 'Rented days of real bookings (on rent, returned or closed), from the actual handover to the actual return (the booked times when one is not recorded), each split over the months it falls in.', 30)
on conflict (business, code) do nothing;

-- ================================================================ the app's visits
alter table visitor_sessions add column if not exists via text not null default 'web' check (via in ('web', 'app'));
comment on column visitor_sessions.via is 'Traction (5162): web, or app when the iPhone or Android app''s shell sent the beacon (app: "1").';
create index if not exists visitor_sessions_started_via on visitor_sessions (started_at, via);

-- the beacon of the app marks its session; everything else (the rate limit, public_rate_check, included) is the original's
alter function app.track_ingest(jsonb, jsonb) rename to track_ingest_pre5162;
create function app.track_ingest(p jsonb, p_geo jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v jsonb := app.track_ingest_pre5162(p, p_geo);
begin
  -- public_rate_check: applied by the original above
  if coalesce(p ->> 'app', '') = '1' and coalesce(p ->> 'sid', '') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    update visitor_sessions set via = 'app' where id = (p ->> 'sid')::uuid and via <> 'app';
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.track_ingest(jsonb, jsonb)'::regprocedure, 'app.track_ingest_pre5162(jsonb, jsonb)'::regprocedure);

-- ================================================================ CarmaCars' values
create function app.traction_refresh(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_first date := date_trunc('month', coalesce((select min(started_at) from visitor_sessions), p_now) at time zone 'America/Toronto')::date;
  v_this date := date_trunc('month', p_now at time zone 'America/Toronto')::date;
  v_n integer := 0;
begin
  -- visits: the months whose visits are all still kept (the first month kept may be partly deleted: only when nothing is stored for it)
  insert into traction_monthly (business, code, month, value)
  select 'carmacars', 'mau_' || x.via, x.m, x.n from (
    select s.via, date_trunc('month', s.started_at at time zone 'America/Toronto')::date m, count(distinct s.visitor_id) n
      from visitor_sessions s where s.started_at >= (v_first::timestamp at time zone 'America/Toronto') and s.exclude_reason is null group by 1, 2) x
   where x.m > v_first or not exists (select 1 from traction_monthly t where t.business = 'carmacars' and t.code = 'mau_' || x.via and t.month = x.m)
  on conflict (business, code, month) do update set value = excluded.value, updated_at = now() where traction_monthly.value is distinct from excluded.value;
  get diagnostics v_n = row_count;
  -- rented days: each real booking's time on rent, split over the Toronto months (to now for a car still out)
  insert into traction_monthly (business, code, month, value)
  select 'carmacars', 'days_rented', m.m, round(sum(extract(epoch from least(b.e, m.m_end) - greatest(b.s, m.m_start)) / 86400.0)::numeric, 1)
    -- the actual handover and return (bookings.handed_over_at, checked_in_at, 0005), else the booked times
    from (select coalesce(x.handed_over_at, x.pickup_at) s,
                 case when x.status::text = 'on_rent' then greatest(least(coalesce(x.checked_in_at, x.return_at), p_now), coalesce(x.handed_over_at, x.pickup_at))
                      else greatest(coalesce(x.checked_in_at, x.return_at), coalesce(x.handed_over_at, x.pickup_at)) end e
            from bookings x where x.status::text in ('on_rent', 'returned', 'closed') and coalesce(x.handed_over_at, x.pickup_at) <= p_now and not app.booking_is_test(x.id)) b
    join lateral (select g::date m, (g at time zone 'America/Toronto') m_start, ((g + interval '1 month') at time zone 'America/Toronto') m_end
                    from generate_series(date_trunc('month', b.s at time zone 'America/Toronto'), date_trunc('month', b.e at time zone 'America/Toronto'), interval '1 month') g) m
      on b.e > m.m_start and b.s < m.m_end
   where m.m <= v_this
   group by m.m
  on conflict (business, code, month) do update set value = excluded.value, updated_at = now() where traction_monthly.value is distinct from excluded.value;
  return v_n;
end $$;

alter function app.job_visitor_history(timestamptz, integer) rename to job_visitor_history_pre5162;
create function app.job_visitor_history(p_now timestamptz default now(), p_limit integer default 300) returns text
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v text := app.job_visitor_history_pre5162(p_now, p_limit);
begin
  -- the traction figures at most once an hour
  if not exists (select 1 from traction_monthly where business = 'carmacars' and updated_at > p_now - interval '1 hour')
     or not exists (select 1 from traction_monthly where business = 'carmacars') then
    perform app.traction_refresh(p_now);
    -- a run that changed nothing still counts as the hour's run
    update traction_monthly set updated_at = p_now
     where business = 'carmacars' and code = 'days_rented' and month = (select max(month) from traction_monthly where business = 'carmacars' and code = 'days_rented');
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.job_visitor_history(timestamptz, integer)'::regprocedure, 'app.job_visitor_history_pre5162(timestamptz, integer)'::regprocedure);

-- ================================================================ 3. the deck and the portal
create function app.deck_traction(p_business text default 'carmacars', p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('business', p_business, 'metrics', coalesce(jsonb_agg(jsonb_build_object('code', m.code, 'label', m.label, 'unit', m.unit, 'note', m.note,
      'months', coalesce((select jsonb_agg(jsonb_build_object('month', t.month, 'value', t.value) order by t.month)
                           from traction_monthly t where t.business = m.business and t.code = m.code
                            and t.month > (date_trunc('month', p_now at time zone 'America/Toronto') - interval '12 months')::date), '[]'::jsonb))
      order by m.sort_order, m.code), '[]'::jsonb))
    from traction_metrics m where m.business = p_business and m.active
$$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5162;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_call in ('investor_read', 'admin_read') and p_name = 'deck_traction' then
    perform app.door_begin(p_user, p_aal);
    -- an investor reads it whenever they are an investor (the portal); the deck page itself keeps its own switch
    if not app.user_is_admin(p_user) then perform app.investor_of(p_user); end if;
    return app.deck_traction('carmacars', now());
  end if;
  return app.door_pre5162(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5162(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['traction_refresh', 'deck_traction', 'job_visitor_history_pre5162', 'track_ingest_pre5162', 'door_pre5162']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
