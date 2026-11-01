-- 0352_fleet_trending.sql
-- /cars opens on "Trending" (docs/changes/2026-11-06-fleet-trending.md).
--
-- The owner, November 1, 2026: the default sort, "Our order" (0126: featured, then the daily rate), put plain cars first.
-- Now every car on the site has a trending score, worked out once an hour by app.job_fleet_trending (pg_cron), never per
-- request:
--   score = views x w.views + photos looked through x w.photos + prices seen x w.quotes + booking requests x w.requests
--         + offers x w.offers + bookings x w.bookings      (each over the last trending_days, 14 by default)
--         + w.premium for a premium, luxury or exotic car + w.real_photos with real photos
--         - w.no_photos with sample photos only - w.not_bookable when it cannot be booked in the next 7 days
-- The weights are Program settings (fleet_trending_weights, Settings > Program), as are the days and how many cars get
-- the small "Hot" badge (fleet_hot_count, 4; 0 turns it off). An Admin pins a car to the top (vehicle_listings.pinned_rank,
-- 1 first; Admin > Cars > the car), which replaces the manual featured order of the fleet page.
-- Only the website's read (public.fleet) follows this order. app.public_fleet, which the search pages' snapshots read, is
-- unchanged, so an hourly change of score never rewrites a landing page or its sitemap date (0126).

alter table program_settings
  add column if not exists fleet_trending_weights jsonb not null default
    '{"views": 1, "photos": 0.5, "quotes": 2, "requests": 8, "offers": 10, "bookings": 15, "premium": 25, "real_photos": 15, "no_photos": 40, "not_bookable": 30}'::jsonb,
  add column if not exists fleet_trending_days integer not null default 14 check (fleet_trending_days between 1 and 90),
  add column if not exists fleet_hot_count integer not null default 4 check (fleet_hot_count between 0 and 12);
comment on column program_settings.fleet_trending_weights is 'The fleet''s Trending order (0352): the weight of each signal over fleet_trending_days (views, photos looked through, prices seen, requests, offers, bookings) and the boosts (premium, real_photos) and penalties (no_photos, not_bookable).';
comment on column program_settings.fleet_trending_days is 'The fleet''s Trending order (0352): the days of signals counted (14).';
comment on column program_settings.fleet_hot_count is 'The fleet''s Trending order (0352): how many cars at the top carry the small Hot badge (4; 0: none).';

alter table vehicle_listings add column if not exists pinned_rank smallint check (pinned_rank between 1 and 99);
-- the scores live in their own table: the hourly job never touches vehicle_listings (whose triggers refresh the cached
-- rows, the partner CRM and the copy)
create table if not exists app.fleet_trend (
  vehicle_id uuid primary key references vehicles (id) on delete cascade,
  score numeric(10, 2) not null default 0,
  at timestamptz not null default now()
);
comment on table app.fleet_trend is 'The Trending score of each car on the site (0352), worked out hourly by app.job_fleet_trending.';
revoke all on app.fleet_trend from public, anon, authenticated;
comment on column vehicle_listings.pinned_rank is 'An Admin''s pin to the top of the fleet (0352): 1 first; null: by the Trending score.';

-- The score of every listed car from the signals of the last days (one statement; the signals are read per car once).
create or replace function app.fleet_trending_scores(p_now timestamptz default now()) returns table (vehicle_id uuid, score numeric)
language sql stable security definer set search_path = public, app as $$
  with s as (select (app.settings()).fleet_trending_weights w, (app.settings()).fleet_trending_days d),
  cars as (select l.vehicle_id, v.class::text cls from vehicle_listings l join vehicles v on v.id = l.vehicle_id
            where l.status = 'published' and v.management_mode <> 'turo_only' and v.retired_at is null),
  interest as (select i.vehicle_id, sum(i.views) views, sum(i.quotes) quotes from vehicle_interest_daily i, s
                where i.day > app.local_date(p_now) - s.d group by i.vehicle_id),
  photos as (select e.vehicle_id, count(*) n from visitor_events e, s where e.kind = 'photos' and e.vehicle_id is not null
               and e.at > p_now - make_interval(days => s.d) group by e.vehicle_id),
  bk as (select b.vehicle_id,
                count(*) requests,
                count(*) filter (where b.status::text in ('offered', 'pending_payment', 'confirmed', 'on_rent', 'returned', 'completed')) offers,
                count(*) filter (where b.status::text in ('confirmed', 'on_rent', 'returned', 'completed')) bookings
           from bookings b, s where b.created_at > p_now - make_interval(days => s.d) and b.booking_type::text not in ('owner', 'placeholder')
          group by b.vehicle_id),
  busy as (select b.vehicle_id, sum(extract(epoch from (least(b.return_at, p_now + interval '7 days') - greatest(b.pickup_at, p_now)))) secs
             from bookings b where b.status::text in ('pending_payment', 'confirmed', 'on_rent') and b.return_at > p_now and b.pickup_at < p_now + interval '7 days'
            group by b.vehicle_id)
  select c.vehicle_id, round((
      coalesce(i.views, 0) * coalesce((s.w ->> 'views')::numeric, 0)
    + coalesce(p.n, 0) * coalesce((s.w ->> 'photos')::numeric, 0)
    + coalesce(i.quotes, 0) * coalesce((s.w ->> 'quotes')::numeric, 0)
    + coalesce(b.requests, 0) * coalesce((s.w ->> 'requests')::numeric, 0)
    + coalesce(b.offers, 0) * coalesce((s.w ->> 'offers')::numeric, 0)
    + coalesce(b.bookings, 0) * coalesce((s.w ->> 'bookings')::numeric, 0)
    + case when c.cls in ('premium', 'luxury', 'exotic') then coalesce((s.w ->> 'premium')::numeric, 0) else 0 end
    + case when app.vehicle_uses_sample_photos(c.vehicle_id) then -coalesce((s.w ->> 'no_photos')::numeric, 0) else coalesce((s.w ->> 'real_photos')::numeric, 0) end
    - case when coalesce(k.secs, 0) >= 6.5 * 86400 then coalesce((s.w ->> 'not_bookable')::numeric, 0) else 0 end)::numeric, 2)
    from cars c cross join s
    left join interest i on i.vehicle_id = c.vehicle_id left join photos p on p.vehicle_id = c.vehicle_id
    left join bk b on b.vehicle_id = c.vehicle_id left join busy k on k.vehicle_id = c.vehicle_id
$$;

-- The hourly job: the scores into vehicle_listings (only rows whose score changed are written).
create or replace function app.job_fleet_trending() returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  insert into app.fleet_trend as t (vehicle_id, score, at)
  select x.vehicle_id, x.score, now() from app.fleet_trending_scores() x
  on conflict (vehicle_id) do update set score = excluded.score, at = excluded.at where t.score is distinct from excluded.score;
  get diagnostics n = row_count;
  delete from app.fleet_trend t where not exists (select 1 from vehicle_listings l where l.vehicle_id = t.vehicle_id and l.status = 'published');
  return n;
end $$;

-- The website's fleet in the Trending order: the pinned cars first (1 first), then the score, then 0126's order. Each
-- row says its place (trend_rank) and whether it carries the Hot badge (the first fleet_hot_count real cars with a score
-- above zero that are not pinned only for being pinned).
create or replace function app.public_fleet_trending(p_filters jsonb default '{}'::jsonb) returns setof jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare hot integer := (app.settings()).fleet_hot_count;
begin
  return query
  select q.r || jsonb_build_object('trend_rank', q.n, 'pinned', q.pinned_rank is not null,
                                   'hot', q.n <= hot and q.trend_score > 0 and not coalesce((q.r ->> 'is_sample')::boolean, false))
    from (select f.r, l.pinned_rank, coalesce(t.score, 0) trend_score,
                 row_number() over (order by l.pinned_rank nulls last, coalesce((f.r ->> 'is_sample')::boolean, false), coalesce(t.score, 0) desc, f.o) n
            from app.public_fleet(p_filters) with ordinality f(r, o)
            left join vehicle_listings l on l.vehicle_id = (f.r ->> 'vehicle_id')::uuid
            left join app.fleet_trend t on t.vehicle_id = (f.r ->> 'vehicle_id')::uuid) q
   order by q.n;
end $$;
grant execute on function app.public_fleet_trending(jsonb) to anon, authenticated, service_role;
revoke all on function app.fleet_trending_scores(timestamptz), app.job_fleet_trending() from public, anon, authenticated;
grant execute on function app.fleet_trending_scores(timestamptz), app.job_fleet_trending() to service_role;

create or replace function public.fleet(p_filters jsonb default '{}'::jsonb) returns setof jsonb
language sql stable security invoker set search_path = public, app as $$ select * from app.public_fleet_trending(p_filters) $$;
grant execute on function public.fleet(jsonb) to anon, authenticated, service_role;

-- An Admin pins a car to the top, or unpins it: {vehicle_id, rank (1 to 99, or null)}.
create or replace function app.fleet_pin(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := (p ->> 'vehicle_id')::uuid;
  v_rank integer := nullif(p ->> 'rank', '')::integer;
  l vehicle_listings;
begin
  perform app.assert_admin(p_by);
  select * into l from vehicle_listings where vehicle_id = v_id for update;
  if l.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  if v_rank is not null and v_rank not between 1 and 99 then raise exception 'Choose a place from 1 to 99' using errcode = '22023'; end if;
  update vehicle_listings set pinned_rank = v_rank where id = l.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'fleet_pin', 'vehicles', v_id::text, jsonb_build_object('pinned_rank', l.pinned_rank), jsonb_build_object('pinned_rank', v_rank));
  return jsonb_build_object('vehicle_id', v_id, 'pinned_rank', v_rank);
end $$;
revoke all on function app.fleet_pin(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.fleet_pin(uuid, jsonb) to service_role;

-- the door: ops_do fleet_pin (Admins)
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0352;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_do', 'admin_do') and p_name = 'fleet_pin' then
    perform app.door_begin(p_user, p_aal);
    return app.fleet_pin(p_user, p);
  end if;
  return app.door_pre0352(p_user, p_aal, p_call, p_name, p);
end $$;
do $$
declare g text;
begin
  execute 'revoke all on function app.door(uuid, text, text, text, jsonb) from public';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    execute format('revoke all on function app.door(uuid, text, text, text, jsonb) from %I', g);
    if has_function_privilege(g, 'app.door_pre0352(uuid, text, text, text, jsonb)', 'execute') then execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g); end if;
  end loop;
end $$;

-- the first scores now, then every hour
select app.job_fleet_trending();
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-fleet-trending', '23 * * * *', $q$select app.job_fleet_trending()$q$);
  end if;
end $$;
