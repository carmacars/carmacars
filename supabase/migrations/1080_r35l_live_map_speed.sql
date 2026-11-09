-- 1080_r35l_live_map_speed.sql
-- Release 35, part L (docs/changes/2026-11-08-r35-live-map-speed-stripe-link.md, section 1): Today > Visitors drew the map
-- with no data. /api/staff/live-map took about 25 seconds, then answered 503 "The map could not be read": the read
-- (admin_read live_map, and va_read live_map for customer service and Sales) ran past the statement timeout. Measured on a
-- test database with 20,000 visits, 200,000 visit events, 3,000 renters, 3,000 leads and 8,000 games: 46.7 seconds.
--   - 31 seconds: app.person_tags (0470), the roles on each of up to 500 pins. Each call compared every renter, owner,
--     partner and investor by a lowered email or a normalized phone (a sequential scan of each table with a function on
--     every row, about 65 ms a pin). Now each match is its own lookup on an expression index (below), the same answer.
--   - 13.5 seconds: the JIT compiler. The base read (0242) is one statement whose estimated cost (a sequential scan of
--     contact_captures for each lead) passed the JIT thresholds, so PostgreSQL compiled 434 functions before running a
--     2-second query. The map's functions run with jit off, and the lead's capture is found by an index.
--   - the rest: the KPI tiles' counts (bookings by booked_at and confirmed_at, payments by processed_at) had no index.
-- Each layer stands alone: p.part = 'kpi', 'pins' or 'fleet' reads one layer (the website reads the three at once,
-- 1080's web change), and a layer that fails is left out and named in "failed" instead of failing the whole map. The
-- roles on the pins (0470's layer) fail alone too ("roles"). No applied migration is edited. SCHEMA_MARKER 1080.

-- ================================================================ indexes
-- the lead's capture (0242: the browser and renter of a form sent)
create index if not exists contact_captures_lead_idx on contact_captures (lead_id, last_at desc) where lead_id is not null;
-- a renter's latest visit (0242: previous renters back on the site, the visit and position of a renter's pin)
create index if not exists visitor_sessions_renter_seen_idx on visitor_sessions (renter_id, last_seen_at desc) where renter_id is not null;
-- the KPI tiles
create index if not exists bookings_booked_at_idx on bookings (booked_at);
create index if not exists bookings_confirmed_at_idx on bookings (confirmed_at) where confirmed_at is not null;
create index if not exists payments_processed_ok_idx on payments (processed_at) where status = 'succeeded';
-- app.person_tags: a person by a lowered email or a normalized phone (app.phone_e164 is immutable)
create index if not exists renters_email_key_idx on renters ((lower(btrim(coalesce(email, '')))));
create index if not exists renters_phone_key_idx on renters ((app.phone_e164(mobile)));
create index if not exists owners_email_key_idx on owners ((lower(btrim(coalesce(email, '')))));
create index if not exists owners_phone_key_idx on owners ((app.phone_e164(phone)));
create index if not exists partners_email_key_idx on partners ((lower(btrim(coalesce(email, '')))));
create index if not exists partners_phone_key_idx on partners ((app.phone_e164(phone)));
create index if not exists investors_email_key_idx on investors ((lower(btrim(coalesce(email, '')))));
create index if not exists investors_phone_key_idx on investors ((app.phone_e164(phone)));
create index if not exists leads_owner_program_email_idx on leads ((lower(btrim(coalesce(email, ''))))) where kind = 'owner_program';

-- ================================================================ what a person is to us (0470), by index
create or replace function app.person_tags(p_user uuid, p_renter uuid, p_email text, p_phone text) returns jsonb
language plpgsql stable security definer set search_path = public, app set jit = off as $$
declare
  v_ren renters;
  v_user uuid;
  v_emails text[];
  v_phones text[];
  v_owner uuid;
  v_roles text[] := '{}';
  v_renter uuid;
begin
  if p_renter is not null then select * into v_ren from renters where id = p_renter; end if;
  v_user := coalesce(p_user, v_ren.user_id);
  v_emails := array(select distinct e from unnest(array[lower(btrim(coalesce(p_email, ''))), lower(btrim(coalesce(v_ren.email, '')))]) e where e <> '');
  v_phones := array(select distinct x from unnest(array[app.phone_e164(p_phone), app.phone_e164(v_ren.mobile)]) x where x is not null);

  -- the same matches as 0470, each one a lookup of its own index
  select o.id into v_owner from owners o
   where o.id in (select x.id from owners x where v_user is not null and x.user_id = v_user
                  union all select x.id from owners x where lower(btrim(coalesce(x.email, ''))) = any (v_emails)
                  union all select x.id from owners x where app.phone_e164(x.phone) = any (v_phones))
   order by (o.user_id is not distinct from v_user) desc, (o.status = 'active') desc, o.created_at limit 1;
  if v_owner is not null or exists (select 1 from leads l where l.kind = 'owner_program' and lower(btrim(coalesce(l.email, ''))) = any (v_emails)) then
    v_roles := array_append(v_roles, 'owner');
  end if;
  if (v_owner is not null and exists (select 1 from partners pa where pa.owner_id = v_owner))
     or exists (select 1 from partners pa where lower(btrim(coalesce(pa.email, ''))) = any (v_emails))
     or exists (select 1 from partners pa where app.phone_e164(pa.phone) = any (v_phones)) then
    v_roles := array_append(v_roles, 'partner');
  end if;
  if (v_user is not null and exists (select 1 from investors i where i.user_id = v_user))
     or exists (select 1 from investors i where lower(btrim(coalesce(i.email, ''))) = any (v_emails))
     or exists (select 1 from investors i where app.phone_e164(i.phone) = any (v_phones)) then
    v_roles := array_append(v_roles, 'investor');
  end if;
  if v_user is not null and exists (select 1 from user_roles ur where ur.user_id = v_user and ur.role in ('admin', 'va', 'field')) then
    v_roles := array_append(v_roles, 'staff');
  end if;
  select r.id into v_renter from renters r
   where r.merged_into is null
     and r.id in (select x.id from renters x where x.id = p_renter
                  union all select x.id from renters x where v_user is not null and x.user_id = v_user
                  union all select x.id from renters x where lower(btrim(coalesce(x.email, ''))) = any (v_emails)
                  union all select x.id from renters x where app.phone_e164(x.mobile) = any (v_phones))
   order by (r.id = p_renter) desc nulls last, r.created_at limit 1;
  if v_renter is not null and (cardinality(v_roles) = 0 or exists (select 1 from bookings b where b.renter_id = v_renter and b.booking_type <> 'owner'
                                                                     and b.status not in ('cancelled', 'declined', 'expired'))) then
    v_roles := array_append(v_roles, 'renter');
  end if;
  return jsonb_build_object('roles', to_jsonb(v_roles), 'owner_id', v_owner);
end $$;

-- The same answer for many people at once (the map's up to 500 pins): one statement of joins instead of 500 calls (a
-- call costs about a millisecond in planning alone). p: [{user, renter, email, phone}], the answer in the same order.
create or replace function app.person_tags_many(p jsonb) returns jsonb
language sql stable security definer set search_path = public, app set jit = off as $$
  with i as (
    select t.n, nullif(t.x ->> 'user', '')::uuid as p_user, nullif(t.x ->> 'renter', '')::uuid as p_renter, t.x ->> 'email' as p_email, t.x ->> 'phone' as p_phone
      from jsonb_array_elements(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) with ordinality t(x, n)),
  a as materialized (
    select i.n, i.p_renter, coalesce(i.p_user, r.user_id) as v_user,
           array(select distinct e from unnest(array[lower(btrim(coalesce(i.p_email, ''))), lower(btrim(coalesce(r.email, '')))]) e where e <> '') as v_emails,
           array(select distinct y from unnest(array[app.phone_e164(i.p_phone), app.phone_e164(r.mobile)]) y where y is not null) as v_phones
      from i left join renters r on i.p_renter is not null and r.id = i.p_renter),
  ae as materialized (select a.n, e from a cross join lateral unnest(a.v_emails) e),
  ap as materialized (select a.n, ph from a cross join lateral unnest(a.v_phones) ph),
  -- the owners row: by user, email or phone; the user's own first, then an active one, then the oldest
  oc as (select a.n, o.id from a join owners o on o.user_id = a.v_user
         union select ae.n, o.id from ae join owners o on lower(btrim(coalesce(o.email, ''))) = ae.e
         union select ap.n, o.id from ap join owners o on app.phone_e164(o.phone) = ap.ph),
  ow as (select distinct on (oc.n) oc.n, o.id from oc join owners o on o.id = oc.id join a on a.n = oc.n
          order by oc.n, (o.user_id is not distinct from a.v_user) desc, (o.status = 'active') desc, o.created_at),
  lo as (select distinct ae.n from ae join leads l on l.kind = 'owner_program' and lower(btrim(coalesce(l.email, ''))) = ae.e),
  pa as (select ow.n from ow join partners x on x.owner_id = ow.id
         union select ae.n from ae join partners x on lower(btrim(coalesce(x.email, ''))) = ae.e
         union select ap.n from ap join partners x on app.phone_e164(x.phone) = ap.ph),
  iv as (select a.n from a join investors x on x.user_id = a.v_user
         union select ae.n from ae join investors x on lower(btrim(coalesce(x.email, ''))) = ae.e
         union select ap.n from ap join investors x on app.phone_e164(x.phone) = ap.ph),
  st as (select distinct a.n from a join user_roles ur on ur.user_id = a.v_user and ur.role in ('admin', 'va', 'field')),
  -- the renters row: the one given first, then the oldest
  rc as (select a.n, x.id from a join renters x on x.id = a.p_renter
         union select a.n, x.id from a join renters x on x.user_id = a.v_user
         union select ae.n, x.id from ae join renters x on lower(btrim(coalesce(x.email, ''))) = ae.e
         union select ap.n, x.id from ap join renters x on app.phone_e164(x.mobile) = ap.ph),
  rw as (select distinct on (rc.n) rc.n, r.id from rc join renters r on r.id = rc.id and r.merged_into is null join a on a.n = rc.n
          order by rc.n, (r.id = a.p_renter) desc nulls last, r.created_at),
  z as (select a.n, ow.id as owner_id, rw.id as renter_id,
               array_remove(array[case when ow.id is not null or lo.n is not null then 'owner' end, case when pa.n is not null then 'partner' end,
                                  case when iv.n is not null then 'investor' end, case when st.n is not null then 'staff' end]::text[], null) as roles0
          from a left join ow on ow.n = a.n left join lo on lo.n = a.n left join pa on pa.n = a.n left join iv on iv.n = a.n left join st on st.n = a.n
          left join rw on rw.n = a.n)
  select coalesce(jsonb_agg(jsonb_build_object('roles', to_jsonb(z.roles0 || case when z.renter_id is not null and (cardinality(z.roles0) = 0
                                  or exists (select 1 from bookings bk where bk.renter_id = z.renter_id and bk.booking_type <> 'owner' and bk.status not in ('cancelled', 'declined', 'expired')))
                                  then array['renter'] else '{}'::text[] end), 'owner_id', z.owner_id) order by z.n), '[]'::jsonb)
    from z
$$;

-- ================================================================ a car's photo for the map (0242's, once per car)
-- The cover of app.vehicle_studio_photos (0073) alone: the same first photo, without the seven others (an eighth of the work).
create or replace function app.vehicle_studio_cover(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
           'path', '/sample-photos/studio/' || app.studio_shape(v.id) || '/' || app.studio_paint(v.colour) || '/' || s.k || '/'
                   || replace(left(btrim(regexp_replace(upper(coalesce(v.model, 'car')), '[^A-Z0-9 &.-]+', ' ', 'g')), 24), ' ', '%20') || '.svg',
           'alt', left(format('Representative studio image of a %s %s like the %s, %s', app.studio_paint(v.colour), app.sample_body_label(app.sample_body_key(v.id)),
                              concat_ws(' ', case when not v.year_approximate then v.year::text end, v.make, v.model), s.view), 200),
           'width', 1800, 'height', 1200, 'shot', s.shot, 'label', coalesce(st.label, s.view), 'is_cover', true, 'sample', true, 'studio', true)
    from vehicles v
    cross join (values ('lead', 'front_left', 'front three-quarter view')) s(k, shot, view)
    left join listing_shot_types st on st.code = s.shot
   where v.id = p_vehicle
$$;

-- the car's cover photo, else its first sample photo (app.vehicle_sample_photos, 0073: the uploaded samples, else the studio)
create or replace function app.live_map_car_photo(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce((select jsonb_build_object('path', ph.processed_path, 'variants', ph.variants, 'alt', ph.alt_text, 'sample', false)
                     from vehicle_photos ph where ph.vehicle_id = p_vehicle and ph.is_cover and ph.is_public and ph.status = 'approved' and ph.replaced_at is null
                      and ph.processed_path is not null limit 1),
                  -- only for a car with no cover photo
                  (select (case when jsonb_array_length(coalesce(q.x, '[]'::jsonb)) = 0 or (q.x -> 0) ? 'builtin' then app.vehicle_studio_cover(p_vehicle) else q.x -> 0 end)
                            || jsonb_build_object('sample', true)
                     from (select app.vehicle_sample_photos_pre0073(p_vehicle) as x) q))
$$;

-- ================================================================ the read (0242's, by layer; the same answer)
create or replace function app.live_map_pre0283(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app set jit = off as $$
declare
  ps program_settings := app.settings();
  v_live interval := make_interval(mins => ps.visitor_live_minutes);
  v_since timestamptz := now() - interval '30 days';
  v_day date := app.local_date(now());
  v_month date := date_trunc('month', v_day)::date;
  v_week date := date_trunc('week', v_day)::date;
  v_cap integer := least(greatest(coalesce((p ->> 'limit')::integer, 500), 1), 500);
  -- only these people (renter or browser ids): one person's pins, and the tests
  v_who uuid[] := case when jsonb_typeof(p -> 'who') = 'array' then array(select x::uuid from jsonb_array_elements_text(p -> 'who') x) end;
  -- 1080: one layer (kpi, pins or fleet), or all three when not named
  v_part text := nullif(p ->> 'part', '');
  v_failed text[] := '{}';
  v_kpi jsonb;
  v_pins jsonb;
  v_fleet jsonb;
  v_out jsonb;
begin
  perform app.assert_admin(p_by);
  if v_part is not null and v_part not in ('kpi', 'pins', 'fleet') then raise exception 'A layer of the map is kpi, pins or fleet' using errcode = '22023'; end if;
  v_out := jsonb_build_object('at', now(), 'days', 30, 'cap', v_cap, 'live_minutes', ps.visitor_live_minutes,
    -- home base: the delivery origin of Program settings (app.delivery_origin, 0027); null when not set
    'hq', app.delivery_origin());

  -- ---------------------------------------------------------------- the KPI tiles
  if v_part is null or v_part = 'kpi' then
    begin
      select jsonb_build_object(
      'active_now', (select count(*) from visitor_sessions s where s.last_seen_at > now() - v_live and s.ended_at is null and s.exclude_reason is null),
      'requests_today', (select count(*) from bookings b where b.booked_at >= app.local_midnight(v_day) and b.booking_type <> 'owner'),
      -- the same hours of yesterday, for the change under the number
      'requests_yesterday', (select count(*) from bookings b where b.booked_at >= app.local_midnight(v_day - 1) and b.booked_at < now() - interval '1 day' and b.booking_type <> 'owner'),
      'bookings_week', (select count(*) from bookings b where b.confirmed_at >= app.local_midnight(v_week) and b.booking_type <> 'owner'),
      'on_rent_now', (select count(*) from bookings b where b.status = 'on_rent' and b.booking_type <> 'owner'),
      'collected_month_cents', coalesce((select sum(case when x.kind = 'refund' then -x.amount_cents else x.amount_cents end) from payments x
                                           where x.status = 'succeeded' and x.kind in ('charge', 'capture', 'refund') and x.processed_at >= app.local_midnight(v_month)), 0)) into v_kpi;
      v_out := v_out || jsonb_build_object('kpi', v_kpi);
    exception when others then
      v_failed := v_failed || 'kpi'::text;
      raise log 'live map: the KPI tiles could not be read: %', sqlerrm;
    end;
  end if;

  -- ---------------------------------------------------------------- the pins (people), with the cars they looked at
  if v_part is null or v_part = 'pins' then
    begin
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
           -- 1080: the prize's words are written for the pins kept only (below)
           null::text, gp.id::text
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
  c3 as (select * from c2 where v_who is null or c2.who_renter = any (v_who) or c2.visitor_id = any (v_who)),
  -- a time ahead (a booking made for later) counts as now
  g as (select k, array_agg(distinct type) as types, max(least(at, now())) as last_at from c3 group by k),
  d0 as (select distinct on (c3.k) c3.* from c3 order by c3.k, c3.rank, c3.at desc),
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
  cars as materialized (
    select v.id, v.car_code, app.vehicle_name(v.id) as name,
           (select rc.daily_rate_cents from rate_cards rc where rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())
             order by rc.effective_from desc limit 1) as daily_cents,
           app.live_map_car_photo(v.id) as photo
      from vehicles v
     where v.id in (select car_id from pins where car_id is not null)
  )
      select jsonb_build_object(
    'totals', coalesce((select jsonb_object_agg(type, n) from (select d0.type, count(*) as n from d0 group by d0.type) t), '{}'::jsonb),
    'pins', coalesce((select jsonb_agg(jsonb_build_object(
        'id', md5(pins.k), 'type', pins.type, 'types', pins.types, 'at', pins.last_at, 'detail', case when pins.type = 'game' then (select case when gc.id is not null then 'Claimed ' else 'Played ' end || coalesce(nullif(app.game_prize_label(g.prize), ''), replace(g.game, '_', ' '))
                                                                       from game_plays g left join game_claims gc on gc.play_id = g.id where g.id = pins.ref::uuid) else pins.detail end,
        'booking_number', pins.booking_number,
        'pickup_at', (select b.pickup_at from bookings b where pins.booking_number is not null and b.booking_number = pins.booking_number),
        'return_at', (select b.return_at from bookings b where pins.booking_number is not null and b.booking_number = pins.booking_number),
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
        order by pins.rank, pins.last_at desc) from pins), '[]'::jsonb))
      into v_pins;
      v_out := v_out || v_pins;
    exception when others then
      v_failed := v_failed || 'pins'::text;
      raise log 'live map: the pins could not be read: %', sqlerrm;
    end;
  end if;

  -- ---------------------------------------------------------------- the fleet layer
  if v_part is null or v_part = 'fleet' then
    begin
      select coalesce((select jsonb_agg(jsonb_build_object('vehicle_id', vp.vehicle_id, 'code', vp.car_code, 'name', vp.name, 'lat', vp.lat, 'lng', vp.lon,
                         'heading', vp.heading, 'speed', vp.speed, 'status', vp.status, 'updated_at', vp.updated_at,
                         'photo', app.live_map_car_photo(vp.vehicle_id)) order by vp.car_code)
                       from app.vehicle_positions vp), '[]'::jsonb) into v_fleet;
      v_out := v_out || jsonb_build_object('fleet', v_fleet);
    exception when others then
      v_failed := v_failed || 'fleet'::text;
      raise log 'live map: the fleet layer could not be read: %', sqlerrm;
    end;
  end if;
  return v_out || jsonb_build_object('failed', to_jsonb(v_failed));
end $$;

-- ================================================================ the layers above it: jit off, and the roles fail alone
alter function app.live_map_pre0400(uuid, jsonb) set jit = off;
alter function app.live_map_pre0470(uuid, jsonb) set jit = off;
create or replace function app.live_map(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app set jit = off as $$
declare
  v jsonb := app.live_map_pre0470(p_by, p);
  v_pins jsonb;
  v_tags jsonb;
begin
  if v is null then return v; end if;
  -- one layer: only its own keys (the layers below may add the others, empty)
  v := case p ->> 'part' when 'kpi' then v - 'pins' - 'totals' - 'fleet' when 'fleet' then v - 'pins' - 'totals' - 'kpi' when 'pins' then v - 'kpi' - 'fleet' else v end;
  if not (v ? 'pins') then return v; end if;
  begin
    -- the roles of every pin in one statement (app.person_tags_many), in the pins' order
    v_tags := app.person_tags_many((select jsonb_agg(jsonb_build_object('user', s.user_id, 'renter', nullif(t.x ->> 'renter_id', ''), 'email', t.x ->> 'email', 'phone', t.x ->> 'phone') order by t.n)
                                      from jsonb_array_elements(coalesce(v -> 'pins', '[]'::jsonb)) with ordinality t(x, n)
                                      left join visitor_sessions s on s.id = nullif(t.x ->> 'session_id', '')::uuid));
    select coalesce(jsonb_agg(t.x || coalesce(v_tags -> (t.n - 1)::integer, '{}'::jsonb) order by t.n), '[]'::jsonb) into v_pins
      from jsonb_array_elements(coalesce(v -> 'pins', '[]'::jsonb)) with ordinality t(x, n);
    return jsonb_set(v, '{pins}', v_pins);
  exception when others then
    raise log 'live map: the roles could not be read: %', sqlerrm;
    return v || jsonb_build_object('failed', coalesce(v -> 'failed', '[]'::jsonb) || '["roles"]'::jsonb);
  end;
end $$;
alter function app.staff_live_map(uuid, jsonb) set jit = off;
alter function app.live_visitors(uuid, jsonb) set jit = off;
alter function app.captured_contacts(uuid, jsonb) set jit = off;

-- ================================================================ privileges
revoke all on function app.live_map_car_photo(uuid), app.vehicle_studio_cover(uuid), app.person_tags_many(jsonb) from public, anon, authenticated;
grant execute on function app.live_map_car_photo(uuid), app.vehicle_studio_cover(uuid), app.person_tags_many(jsonb) to service_role;
