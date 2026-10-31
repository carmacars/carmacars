-- 0242: the Live map (docs/changes/2026-11-04-live-map.md). The owner, Release 24: a dashboard for a TV or monitor in the
-- office with a map of the Greater Toronto Area and its surroundings, a pin per lead (game player, unfinished form, form
-- sent, request, booking, renter on rent, previous renter, visitor on the site now) with who they are, their score and
-- signals and the car they looked at last. SCHEMA_MARKER 0242.
--
-- 1. visitor_sessions.geo_lat, geo_lng: where the visit came from, as Cloudflare places the visitor's network (the beacon's
--    request.cf latitude and longitude), rounded to 0.01 degree (about 1 km) by the Worker and again here. Recorded from now
--    on by app.track_ingest; never typed by anyone, never more precise than that, kept as long as the visit
--    (visitor_sessions_keep_days). Game plays, unfinished forms and enquiries are placed through the visitor's visits
--    (they all carry the browser's visitor_id), so they need no column of their own.
-- 2. places_city_name_idx: a city's centre by its name (the GeoNames places of 0095), for a renter's home city or a visit's
--    city when no coordinates were recorded. No geocoding service is called.
-- 3. tracker_status.heading_deg and app.vehicle_positions: the seam for the fleet layer. The view lists each car's last
--    tracker position (installed device, position reported in the last 7 days); it is empty until CarmaCars' trackers
--    report. The tracker service will fill tracker_status (heading included); nothing here ingests positions.
-- 4. app.live_map(p_by, p): everything the map shows in one read (Admins only, admin_read live_map through the door):
--    the KPI tiles, the pins (last 30 days plus what is current, one per person, at most 500), the cars they looked at with
--    a photo and price, and the fleet positions. No per-pin round trips; the website keeps the answer 20 seconds.
-- No applied migration is edited.

-- ================================================================ 1. where a visit came from
alter table visitor_sessions
  add column if not exists geo_lat numeric(5, 2) check (geo_lat between -90 and 90),
  add column if not exists geo_lng numeric(5, 2) check (geo_lng between -180 and 180);
comment on column visitor_sessions.geo_lat is 'Live map (0242): the approximate latitude of the visitor''s network (Cloudflare''s request.cf), rounded to 0.01 degree (about 1 km). Never a typed address.';
comment on column visitor_sessions.geo_lng is 'Live map (0242): the approximate longitude of the visitor''s network (Cloudflare''s request.cf), rounded to 0.01 degree (about 1 km).';
create index if not exists visitor_sessions_geo_idx on visitor_sessions (visitor_id, last_seen_at desc) where geo_lat is not null;

-- a number from the beacon, rounded to 2 decimals; null when it is not a number in range
create or replace function app.geo_round(p text, p_max numeric) returns numeric
language sql immutable as $$
  select case when p ~ '^-?[0-9]{1,3}(\.[0-9]+)?$' and abs(p::numeric) <= p_max then round(p::numeric, 2) end
$$;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0242: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.patch_fn('app.track_ingest(jsonb, jsonb)'::regprocedure,
  $o$insert into visitor_sessions (id, visitor_id, user_id, renter_id, known_name, known_email, identified_by, consent, city, region, country, device,$o$,
  $n$insert into visitor_sessions (id, visitor_id, user_id, renter_id, known_name, known_email, identified_by, consent, city, region, country, geo_lat, geo_lng, device,$n$);
select pg_temp.patch_fn('app.track_ingest(jsonb, jsonb)'::regprocedure,
  $o$left(nullif(p_geo ->> 'city', ''), 80), left(nullif(p_geo ->> 'region', ''), 80), left(nullif(p_geo ->> 'country', ''), 2),$o$,
  $n$left(nullif(p_geo ->> 'city', ''), 80), left(nullif(p_geo ->> 'region', ''), 80), left(nullif(p_geo ->> 'country', ''), 2),
            app.geo_round(p_geo ->> 'lat', 90), app.geo_round(p_geo ->> 'lon', 180),$n$);

-- ================================================================ 2. a city's centre by its name
create index if not exists places_city_name_idx on places (lower(name)) where kind = 5;

-- ================================================================ 3. the fleet layer's seam
alter table tracker_status add column if not exists heading_deg smallint check (heading_deg between 0 and 359);
comment on column tracker_status.heading_deg is 'Live map (0242): the direction the car is moving, 0 to 359 degrees from north, as the tracker reports it.';

create or replace view app.vehicle_positions as
  select v.id as vehicle_id, v.car_code, app.vehicle_name(v.id) as name,
         ts.latitude::float8 as lat, ts.longitude::float8 as lon, ts.heading_deg as heading, ts.speed_kmh::float8 as speed,
         case when exists (select 1 from bookings b where b.vehicle_id = v.id and b.status = 'on_rent') or v.status = 'on_rent' then 'on_rent'
              when v.status in ('available', 'ready_to_list') then 'available' else 'in_service' end as status,
         ts.reported_at as updated_at
    from tracker_devices d
    join tracker_status ts on ts.tracker_device_id = d.id
    join vehicles v on v.id = d.vehicle_id
   where d.status = 'installed' and ts.latitude is not null and ts.longitude is not null
     and v.retired_at is null and not coalesce(v.is_sample, false)
     and ts.reported_at > now() - interval '7 days';
comment on view app.vehicle_positions is 'Live map (0242): each car''s last tracker position, for the fleet layer. Empty until the trackers report.';
revoke all on app.vehicle_positions from public, anon, authenticated;
grant select on app.vehicle_positions to service_role;

-- ================================================================ 4. the read
-- Types, most advanced first (one pin per person, the most advanced wins; the others are listed on the pin):
--   on_rent (renter on rent now), booking (confirmed, not started), request (requested, offered, held or awaiting payment;
--   last 30 days), lead (a form sent: contact, chat, phone, sample car, owner program; last 30 days), draft (contact details
--   typed into a form not sent; last 30 days), game (a discount game played; last 30 days), previous (a past renter back on
--   the site or returned in the last 30 days), session (a visitor on the site now).
create or replace function app.live_map(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_live interval := make_interval(mins => ps.visitor_live_minutes);
  v_since timestamptz := now() - interval '30 days';
  v_day date := app.local_date(now());
  v_month date := date_trunc('month', v_day)::date;
  v_week date := date_trunc('week', v_day)::date;
  v_cap integer := least(greatest(coalesce((p ->> 'limit')::integer, 500), 1), 500);
  v_out jsonb;
begin
  perform app.assert_admin(p_by);
  with c0 as (
    -- renters on rent now
    select 'on_rent'::text as type, 1 as rank, coalesce(b.handed_over_at, b.pickup_at) as at, b.renter_id, null::uuid as visitor_id,
           null::uuid as session_id, null::text as name, null::text as email, null::text as phone, b.vehicle_id, b.booking_number,
           'Due back ' || to_char(b.return_at at time zone 'America/Toronto', 'Mon FMDD, FMHH12:MI am') as detail, b.id::text as ref
      from bookings b where b.status = 'on_rent' and b.booking_type <> 'owner'
    union all
    -- confirmed bookings not started
    select 'booking', 2, coalesce(b.confirmed_at, b.booked_at), b.renter_id, null, null, null, null, null, b.vehicle_id, b.booking_number,
           'Pickup ' || to_char(b.pickup_at at time zone 'America/Toronto', 'Mon FMDD, FMHH12:MI am'), b.id::text
      from bookings b where b.status = 'confirmed' and b.booking_type <> 'owner' and b.return_at > now()
    union all
    -- requests and offers in progress
    select 'request', 3, b.booked_at, b.renter_id, null, null, null, null, null, b.vehicle_id, b.booking_number,
           case b.status when 'requested' then 'Requested' when 'offered' then 'Offer sent' when 'tentative' then 'Held' else 'Awaiting payment' end
             || ', pickup ' || to_char(b.pickup_at at time zone 'America/Toronto', 'Mon FMDD'), b.id::text
      from bookings b where b.status in ('requested', 'offered', 'tentative', 'pending_payment') and b.booking_type <> 'owner' and b.booked_at > v_since
    union all
    -- forms sent (enquiries)
    select 'lead', 4, l.created_at, cc.renter_id, cc.visitor_id, null, l.name, l.email, l.phone, null, null,
           case l.kind when 'contact' then 'Contact form' when 'chat' then 'Live chat' when 'phone' then 'Phoned' when 'sample_car' then 'Asked about a car'
                       when 'owner_program' then 'Owner program' when 'launch_notice' then 'Launch notice' else 'Enquiry' end, l.id::text
      from leads l
      left join lateral (select x.visitor_id, x.renter_id from contact_captures x where x.lead_id = l.id order by x.last_at desc limit 1) cc on true
     where l.created_at > v_since and l.status not in ('spam', 'closed') and l.kind not in ('turo_guest', 'insurer')
    union all
    -- contact details typed into a form not sent
    select 'draft', 5, x.last_at, x.renter_id, x.visitor_id, null, x.name, x.email, x.phone, null, null,
           'Started the ' || app.capture_form_label(x.form) || coalesce(' (' || nullif(fd.step, '') || ')', ''), x.id::text
      from contact_captures x left join form_drafts fd on fd.id = x.draft_id
     where x.done_at is null and x.last_at > v_since and x.form <> 'game'
    union all
    -- discount games played (one per browser: the latest)
    select 'game', 6, coalesce(gp.claimed_at, gp.created_at), gc.renter_id, gp.visitor_id, gp.session_id, gc.first_name, gc.email, gc.phone, null, null,
           case when gc.id is not null then 'Claimed ' else 'Played ' end || coalesce(nullif(app.game_prize_label(gp.prize), ''), replace(gp.game, '_', ' ')), gp.id::text
      from (select distinct on (g.visitor_id) g.* from game_plays g where g.created_at > v_since order by g.visitor_id, g.created_at desc) gp
      left join game_claims gc on gc.play_id = gp.id
    union all
    -- past renters returned lately or back on the site
    select 'previous', 7, greatest(least(lb.return_at, now()), ls.last_seen_at), r.id, null, null, null, null, null, lb.vehicle_id, lb.booking_number,
           'Last rental ' || to_char(lb.return_at at time zone 'America/Toronto', 'Mon FMDD, YYYY'), r.id::text
      from renters r
      join lateral (select b.vehicle_id, b.booking_number, b.return_at from bookings b where b.renter_id = r.id and b.status in ('returned', 'closed')
                     and b.booking_type <> 'owner' order by b.return_at desc limit 1) lb on true
      left join lateral (select s.last_seen_at from visitor_sessions s where s.renter_id = r.id order by s.last_seen_at desc limit 1) ls on true
     where r.id in (select b.renter_id from bookings b where b.status in ('returned', 'closed') and b.return_at > v_since and b.return_at <= now()
                    union select s.renter_id from visitor_sessions s where s.renter_id is not null and s.last_seen_at > v_since)
    union all
    -- on the site now
    select 'session', 8, s.last_seen_at, s.renter_id, s.visitor_id, s.id, s.known_name, s.known_email, null, null, null,
           coalesce('On ' || nullif(s.current_path, ''), 'On the site'), s.id::text
      from visitor_sessions s
     where s.last_seen_at > now() - v_live and s.ended_at is null and s.exclude_reason is null
  ),
  -- one person: the renter when known (directly or through the browser's visits), else the browser, else the record
  c1 as (
    select c0.*, coalesce(c0.renter_id, vr.renter_id) as who_renter
      from c0 left join lateral (select s.renter_id from visitor_sessions s where c0.renter_id is null and c0.visitor_id is not null
                                   and s.visitor_id = c0.visitor_id and s.renter_id is not null order by s.started_at desc limit 1) vr on true
  ),
  c2 as (select c1.*, coalesce('r:' || c1.who_renter::text, 'v:' || c1.visitor_id::text, c1.type || ':' || c1.ref) as k from c1),
  g as (select k, array_agg(distinct type) as types, max(at) as last_at from c2 group by k),
  d0 as (select distinct on (c2.k) c2.* from c2 order by c2.k, c2.rank, c2.at desc),
  -- the cap: current first, then the newest
  d as (select d0.*, g.types, g.last_at from d0 join g using (k) order by d0.rank <= 2 desc, g.last_at desc limit v_cap),
  e as (
    select d.*, s.id as s_id, s.visitor_id as s_visitor, s.last_seen_at as s_seen, s.started_at as s_started, s.ended_at as s_ended,
           s.page_views, s.duration_s, s.cars_viewed, s.visit_number, s.score as s_score, s.score_reasons, s.current_vehicle_id, s.current_path,
           s.city as s_city, s.device, s.known_name as s_name, s.from_ad,
           geo.geo_lat, geo.geo_lng, r.legal_name as r_name, r.email as r_email, r.mobile as r_phone, r.city as r_city
      from d
      left join lateral (select x.* from (
          (select s1.* from visitor_sessions s1 where d.session_id is not null and s1.id = d.session_id)
          union all
          (select s2.* from visitor_sessions s2 where d.visitor_id is not null and s2.visitor_id = d.visitor_id and s2.started_at > v_since order by s2.started_at desc limit 1)
          union all
          (select s3.* from visitor_sessions s3 where d.who_renter is not null and s3.renter_id = d.who_renter and s3.last_seen_at > v_since order by s3.last_seen_at desc limit 1)
        ) x order by x.last_seen_at desc limit 1) s on true
      left join lateral (select y.geo_lat, y.geo_lng from (
          (select s4.geo_lat, s4.geo_lng, s4.last_seen_at from visitor_sessions s4 where s4.visitor_id = coalesce(s.visitor_id, d.visitor_id) and s4.geo_lat is not null
             and s4.last_seen_at > v_since order by s4.last_seen_at desc limit 1)
          union all
          (select s5.geo_lat, s5.geo_lng, s5.last_seen_at from visitor_sessions s5 where d.who_renter is not null and s5.renter_id = d.who_renter and s5.geo_lat is not null
             and s5.last_seen_at > v_since order by s5.last_seen_at desc limit 1)
        ) y order by y.last_seen_at desc limit 1) geo on true
      left join renters r on r.id = d.who_renter
  ),
  -- a city's centre for the pins with no recorded position: the renter's home city, else the visit's city (Ontario first)
  names as (select distinct lower(btrim(n)) as n from e cross join lateral (values (e.r_city), (e.s_city)) v(n)
             where e.geo_lat is null and nullif(btrim(n), '') is not null),
  city as (select distinct on (names.n) names.n, round(p.lat::numeric, 5)::float8 as lat, round(p.lng::numeric, 5)::float8 as lng
             from names join places p on lower(p.name) = names.n and p.kind = 5 and p.country = 'CA' and p.lat is not null
             order by names.n, (p.region_id = (select id from place_regions where code = 'CA-ON')) desc nulls last, p.population desc nulls last),
  pins as (
    select e.*, coalesce(e.vehicle_id, e.current_vehicle_id, e.cars_viewed[cardinality(e.cars_viewed)]) as car_id,
           case when e.geo_lat is not null then 'visit' when hc.n is not null then 'home_city' when vc.n is not null then 'visit_city' end as precision,
           coalesce(e.geo_lat::float8, hc.lat, vc.lat) as lat, coalesce(e.geo_lng::float8, hc.lng, vc.lng) as lng,
           (select count(*) from bookings b where e.who_renter is not null and b.renter_id = e.who_renter and b.status in ('returned', 'closed') and b.booking_type <> 'owner') as past,
           (select jsonb_build_object('played', true, 'claimed', bool_or(gp.claimed_at is not null)) from game_plays gp
             where coalesce(e.s_visitor, e.visitor_id) is not null and gp.visitor_id = coalesce(e.s_visitor, e.visitor_id) and gp.created_at > v_since having count(*) > 0) as game
      from e
      left join city hc on e.geo_lat is null and hc.n = lower(btrim(e.r_city))
      left join city vc on e.geo_lat is null and hc.n is null and vc.n = lower(btrim(e.s_city))
  ),
  cars as (
    select v.id, v.car_code, app.vehicle_name(v.id) as name,
           (select rc.daily_rate_cents from rate_cards rc where rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())
             order by rc.effective_from desc limit 1) as daily_cents,
           coalesce((select jsonb_build_object('path', ph.processed_path, 'variants', ph.variants, 'alt', ph.alt_text, 'sample', false)
                       from vehicle_photos ph where ph.vehicle_id = v.id and ph.is_cover and ph.is_public and ph.status = 'approved' and ph.replaced_at is null
                        and ph.processed_path is not null limit 1),
                    (app.vehicle_sample_photos(v.id) -> 0) || jsonb_build_object('sample', true)) as photo
      from vehicles v
     where v.id in (select car_id from pins where car_id is not null union select vehicle_id from app.vehicle_positions)
  )
  select jsonb_build_object(
    'at', now(), 'days', 30, 'cap', v_cap, 'live_minutes', ps.visitor_live_minutes,
    'kpi', jsonb_build_object(
      'active_now', (select count(*) from visitor_sessions s where s.last_seen_at > now() - v_live and s.ended_at is null and s.exclude_reason is null),
      'requests_today', (select count(*) from bookings b where b.booked_at >= app.local_midnight(v_day) and b.booking_type <> 'owner'),
      'bookings_week', (select count(*) from bookings b where b.confirmed_at >= app.local_midnight(v_week) and b.booking_type <> 'owner'),
      'on_rent_now', (select count(*) from bookings b where b.status = 'on_rent' and b.booking_type <> 'owner'),
      'collected_month_cents', coalesce((select sum(case when x.kind = 'refund' then -x.amount_cents else x.amount_cents end) from payments x
                                           where x.status = 'succeeded' and x.kind in ('charge', 'capture', 'refund') and x.processed_at >= app.local_midnight(v_month)), 0)),
    'totals', coalesce((select jsonb_object_agg(type, n) from (select d0.type, count(*) as n from d0 group by d0.type) t), '{}'::jsonb),
    'pins', coalesce((select jsonb_agg(jsonb_build_object(
        'id', md5(pins.k), 'type', pins.type, 'types', pins.types, 'at', pins.last_at, 'detail', pins.detail, 'booking_number', pins.booking_number,
        'renter_id', pins.who_renter, 'session_id', pins.s_id,
        'name', coalesce(nullif(btrim(pins.r_name), ''), nullif(btrim(pins.name), ''), nullif(btrim(pins.s_name), '')),
        'email', coalesce(pins.r_email, pins.email), 'phone', coalesce(pins.r_phone, pins.phone),
        'city', coalesce(nullif(btrim(pins.s_city), ''), nullif(btrim(pins.r_city), '')),
        'lat', pins.lat, 'lng', pins.lng, 'precision', pins.precision,
        'online', pins.s_seen > now() - v_live and pins.s_ended is null,
        'device', pins.device, 'from_ad', coalesce(pins.from_ad, false),
        'facts', jsonb_build_object('pages', coalesce(pins.page_views, 0),
                   'seconds', coalesce(pins.duration_s, greatest(0, extract(epoch from pins.s_seen - pins.s_started))::integer, 0),
                   'cars', coalesce(cardinality(array(select distinct unnest(pins.cars_viewed))), 0), 'visit', coalesce(pins.visit_number, 0),
                   'past', pins.past, 'game', coalesce((pins.game ->> 'played')::boolean, false), 'claimed', coalesce((pins.game ->> 'claimed')::boolean, false),
                   'live_score', pins.s_score, 'reasons', coalesce(pins.score_reasons, '[]'::jsonb)),
        'car', (select jsonb_build_object('id', cars.id, 'code', cars.car_code, 'name', cars.name, 'daily_cents', cars.daily_cents, 'photo', cars.photo,
                         'how', case when pins.vehicle_id is not null then pins.type else 'viewed' end)
                  from cars where cars.id = pins.car_id))
        order by pins.rank, pins.last_at desc) from pins), '[]'::jsonb),
    'fleet', coalesce((select jsonb_agg(jsonb_build_object('vehicle_id', vp.vehicle_id, 'code', vp.car_code, 'name', vp.name, 'lat', vp.lat, 'lng', vp.lon,
                         'heading', vp.heading, 'speed', vp.speed, 'status', vp.status, 'updated_at', vp.updated_at,
                         'photo', (select cars.photo from cars where cars.id = vp.vehicle_id)) order by vp.car_code)
                       from app.vehicle_positions vp), '[]'::jsonb))
    into v_out;
  return v_out;
end $$;
revoke all on function app.live_map(uuid, jsonb), app.geo_round(text, numeric) from public, anon, authenticated;
grant execute on function app.live_map(uuid, jsonb), app.geo_round(text, numeric) to service_role;

-- ================================================================ 5. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0242;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_read' and p_name = 'live_map' then
    perform app.door_begin(p_user, p_aal);
    return app.live_map(p_user, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre0242(p_user, p_aal, p_call, p_name, p);
end $$;
do $$
declare g text;
begin
  execute 'revoke all on function app.door(uuid, text, text, text, jsonb) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.door_pre0242(uuid, text, text, text, jsonb)'::regprocedure, 'execute') then
      execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g);
    end if;
  end loop;
  execute 'revoke all on function app.door_pre0242(uuid, text, text, text, jsonb) from public, anon, authenticated';
  execute 'grant execute on function app.door_pre0242(uuid, text, text, text, jsonb) to service_role';
end $$;
