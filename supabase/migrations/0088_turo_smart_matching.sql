-- 0088_turo_smart_matching.sql
-- The owner, October 21, 2026 (docs/changes/2026-10-21-turo-smart-matching.md): "I want this to be smart enough to
-- match the names to the cars by itself, I don't want to be finicking with it every single time."
--   A. No setup per car. Every active real car (not a sample) is a candidate for Turo's emails; a car no longer needs
--      a "name on Turo" (it stays as an optional override). The Worker scores every candidate (web/src/features/turo/
--      match.ts): Turo car ids in the email's links and images, VIN, plate, year, make, model with its aliases (C-Class
--      for a C 300), trim and colour words, the trip already on a car, the guest's trips, a car busy then.
--   B. Learning: every match, automatic or confirmed by staff, stores what the email called the car on that car
--      (turo_identities: the Turo car id, the exact Turo name), so the next email for that car matches at once by its
--      id. A Turo car id is one car's: staff confirming moves it, an automatic match never takes it from another car.
--      Learning a Turo car id resolves the emails still waiting with the same id (app.turo_review_relearn).
--   C. Still unclear after scoring and the model's pick between the short list: "Which car is this?" with the best
--      guesses first (Calendar sync, To do); the answer teaches B.
--   D. Backfill: the emails waiting for a car are matched again by the Worker (app.turo_rematch_due, the cron gate's
--      "turo") whenever the fleet or what was learned changes, and the learned ids resolve them in the database.
--   E. The guest: their name as Turo shows it, and their phone or email when the email includes them (never guessed),
--      kept on the Turo trip and on one contact record per guest (leads, kind turo_guest, source turo: matched by
--      phone, then email, then name and trip). Never a renter account, never an email or text sent by itself, never a
--      marketing list (a check refuses marketing consent on these records): transactional contact about their trip
--      only (CASL, and Turo's rules on taking guests off the platform). Shown on the Turo trip in Calendar sync, the
--      car's calendar block (staff only; exports to other platforms still say only "Booked"), Live chat names, and the
--      phone matching of a call (a lead with that phone). The privacy policy says so.
-- No applied migration is edited.

-- ================================================================ 1. tables and columns
create table turo_identities (
  id            uuid primary key default gen_random_uuid(),
  vehicle_id    uuid not null references vehicles (id) on delete cascade,
  kind          text not null check (kind in ('turo_car_id', 'name')),
  value         text not null check (length(value) between 3 and 120),
  norm          text generated always as (case when kind = 'name' then btrim(regexp_replace(lower(value), '[^a-z0-9]+', ' ', 'g')) else value end) stored,
  source        text not null check (source in ('auto', 'staff')),
  hits          integer not null default 1,
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  created_by    uuid references users (id),
  check (kind <> 'turo_car_id' or value ~ '^\d{3,12}$')
);
create unique index turo_identities_one_car on turo_identities (value) where kind = 'turo_car_id';
create unique index turo_identities_name on turo_identities (vehicle_id, norm) where kind = 'name';
create index turo_identities_vehicle on turo_identities (vehicle_id);
comment on table turo_identities is 'Turo by email (0088): what Turo''s emails call each car, learned from every match (automatic or confirmed by staff): its Turo car id (one car each) and the exact Turo name. The next email with that id matches at once.';

alter table turo_inbound_emails
  add column if not exists turo_car_ids text[] check (cardinality(turo_car_ids) <= 10),
  add column if not exists car_name     text check (length(car_name) <= 120),
  add column if not exists candidates   jsonb check (jsonb_typeof(candidates) = 'array'),
  add column if not exists match_why    text check (length(match_why) <= 300),
  add column if not exists guest_name   text check (length(guest_name) <= 60),
  add column if not exists guest_phone  text check (guest_phone ~ '^\+\d{8,15}$'),
  add column if not exists guest_email  text check (length(guest_email) <= 200),
  add column if not exists rematched_at timestamptz;
alter table turo_inbound_emails drop constraint if exists turo_inbound_emails_method_check;
alter table turo_inbound_emails add constraint turo_inbound_emails_method_check check (method in ('rules', 'ai', 'none', 'staff', 'learned'));
comment on column turo_inbound_emails.candidates is 'Turo by email (0088): the best guesses for the car (vehicle_id, score, reasons), best first, for the model and the "Which car is this?" pop-up.';
comment on column turo_inbound_emails.guest_phone is 'Turo by email (0088): the guest''s phone when the email shows it (never a masked one). Cleared with the excerpt once the email is handled; it stays on the trip.';

alter table turo_calendar_trips
  add column if not exists guest_name  text check (length(guest_name) <= 60),
  add column if not exists guest_phone text check (guest_phone ~ '^\+\d{8,15}$'),
  add column if not exists guest_email text check (length(guest_email) <= 200),
  add column if not exists lead_id     uuid references leads (id) on delete set null;
comment on column turo_calendar_trips.guest_name is 'Turo by email (0088): the guest''s name as Turo''s email shows it (often a first name and an initial).';

alter table leads drop constraint if exists leads_kind_check;
alter table leads add constraint leads_kind_check check (kind in ('owner_program', 'contact', 'insurer', 'launch_notice', 'other', 'chat', 'sample_car', 'turo_guest'));
alter table leads drop constraint if exists leads_check;
alter table leads add constraint leads_check check (email is not null or phone is not null or kind = 'turo_guest');
alter table leads add constraint leads_turo_guest_no_marketing check (kind <> 'turo_guest' or not consent_marketing);
create index if not exists leads_turo_guest_idx on leads (kind) where kind = 'turo_guest';

do $$
begin
  execute 'alter table turo_identities enable row level security';
  execute 'create policy admin_all on turo_identities for all to authenticated using (app.is_admin()) with check (app.is_admin())';
  execute 'revoke all on turo_identities from anon, authenticated';
end $$;

-- ================================================================ 2. helpers
-- "+14165550199" from what an email shows; null when it is not a phone number.
create or replace function app.turo_phone(p text) returns text
language sql immutable as $$
  select case
    when d ~ '^[2-9][0-9]{9}$' then '+1' || d
    when d ~ '^1[2-9][0-9]{9}$' then '+' || d
    when btrim(coalesce(p, '')) like '+%' and length(d) between 8 and 15 then '+' || d
  end
  from (select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') as d) x
$$;
-- "416-555-0199" for a North American number, else as stored.
create or replace function app.turo_phone_words(p text) returns text
language sql immutable as $$
  select case when p ~ '^\+1\d{10}$' then substr(p, 3, 3) || '-' || substr(p, 6, 3) || '-' || substr(p, 9, 4) else p end
$$;
create or replace function app.turo_name_norm(p text) returns text
language sql immutable as $$ select btrim(regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]+', ' ', 'g')) $$;

create or replace function app.turo_guest_note() returns text
language sql immutable as $$
  select 'Turo guest: details from Turo''s trip email, used only to contact them about that trip. Never add them to a marketing list or send promotions (CASL, and Turo''s rules on taking guests off the platform).'::text
$$;

-- The cars Turo's emails may be about: every active real car, and any car someone linked by hand or that was learned.
create or replace function app.turo_candidate(v vehicles) returns boolean
language sql stable security definer set search_path = public, app as $$
  select v.retired_at is null and v.status::text not in ('exited', 'total_loss', 'declined')
     and (not v.is_sample or exists (select 1 from turo_vehicle_links l where l.vehicle_id = v.id)
          or exists (select 1 from turo_identities i where i.vehicle_id = v.id and i.source = 'staff'))
$$;

-- When what the matcher knows last changed (cars, learned names and ids, the typed overrides): emails waiting for a car
-- are matched again after it.
create or replace function app.turo_fleet_changed_at() returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select greatest((select max(last_seen_at) from turo_identities), (select max(updated_at) from turo_vehicle_links),
                  (select max(v.updated_at) from vehicles v where app.turo_candidate(v)), '2000-01-01'::timestamptz)
$$;

-- ================================================================ 3. the matcher's keys (the Worker, service role)
create or replace function app.turo_match_keys() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with day as (select app.local_midnight(app.local_date(now())) as t0)
  select jsonb_build_object(
    'enabled', s.turo_email_enabled, 'forwarders', s.turo_email_forwarders, 'address', s.turo_email_address,
    'ai_ok', s.turo_email_ai and (select coalesce(sum(c.units), 0) from provider_calls c, day where c.unit = 'neurons' and c.created_at >= day.t0) < s.chat_ai_total_daily_neurons,
    'cars', coalesce((select jsonb_agg(jsonb_build_object('vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'listing_name', l.listing_name,
                        'turo_vehicle_id', l.turo_vehicle_id, 'plate', v.plate, 'vin', v.vin, 'make', v.make, 'model', v.model, 'year', v.year,
                        'trim', v.trim, 'colour', v.colour,
                        'identities', coalesce((select jsonb_agg(jsonb_build_object('kind', i.kind, 'value', i.value, 'source', i.source) order by i.last_seen_at desc)
                                                  from turo_identities i where i.vehicle_id = v.id), '[]'::jsonb),
                        'busy', coalesce((select jsonb_agg(jsonb_build_array(x.s, x.e, x.t)) from (
                                   select t.starts_at s, t.ends_at e, t.trip_id t from turo_calendar_trips t
                                    where t.vehicle_id = v.id and t.status = 'booked' and t.ends_at > now() - interval '7 days'
                                   union all
                                   select b.pickup_at, b.return_at, null from bookings b
                                    where b.vehicle_id = v.id and b.status in ('confirmed', 'on_rent') and b.return_at > now() - interval '7 days'
                                   limit 60) x), '[]'::jsonb)) order by v.year desc nulls last)
                       from vehicles v left join turo_vehicle_links l on l.vehicle_id = v.id
                      where app.turo_candidate(v)), '[]'::jsonb),
    -- the trips we know: a change or extension email without the car finds it by its trip
    'trips', coalesce((select jsonb_agg(jsonb_build_object('trip_id', t.trip_id, 'vehicle_id', t.vehicle_id, 'guest_first_name', t.guest_first_name,
                         'starts_at', t.starts_at, 'ends_at', t.ends_at))
                        from turo_calendar_trips t where t.updated_at > now() - interval '180 days' or t.ends_at > now() - interval '30 days'), '[]'::jsonb))
    from (select (app.settings()).*) s
$$;

-- ================================================================ 4. learning
-- What an email called the car, stored on the car. p_source: auto (a match) or staff (a person chose the car).
-- A Turo car id belongs to one car: staff moves it, an automatic match never takes it from another car.
create or replace function app.turo_learn(p_vehicle uuid, p_ids text[], p_name text, p_source text, p_by uuid default null,
                                          p_relearn boolean default true, p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_id text;
  v_n integer := 0;
  i turo_identities;
  v_name text := left(nullif(btrim(coalesce(p_name, '')), ''), 120);
begin
  if p_vehicle is null or not exists (select 1 from vehicles where id = p_vehicle) then return 0; end if;
  foreach v_id in array coalesce(p_ids, '{}'::text[]) loop
    continue when v_id !~ '^\d{3,12}$';
    select * into i from turo_identities where kind = 'turo_car_id' and value = v_id for update;
    if i.id is null then
      insert into turo_identities (vehicle_id, kind, value, source, created_by, first_seen_at, last_seen_at)
      values (p_vehicle, 'turo_car_id', v_id, p_source, p_by, p_now, p_now);
      v_n := v_n + 1;
    elsif i.vehicle_id = p_vehicle then
      update turo_identities set hits = hits + 1, last_seen_at = p_now, source = case when p_source = 'staff' then 'staff' else source end where id = i.id;
    elsif p_source = 'staff' then
      update turo_identities set vehicle_id = p_vehicle, source = 'staff', hits = 1, last_seen_at = p_now, created_by = p_by where id = i.id;
      insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
      values (p_by, 'UPDATE', 'turo_identities', i.id, jsonb_build_object('vehicle_id', i.vehicle_id), jsonb_build_object('vehicle_id', p_vehicle, 'turo_car_id', v_id));
      v_n := v_n + 1;
    end if;
    i := null;
  end loop;
  if v_name is not null and length(app.turo_name_norm(v_name)) >= 3 then
    insert into turo_identities as x (vehicle_id, kind, value, source, created_by, first_seen_at, last_seen_at)
    values (p_vehicle, 'name', v_name, p_source, p_by, p_now, p_now)
    on conflict (vehicle_id, norm) where kind = 'name'
    do update set hits = x.hits + 1, last_seen_at = p_now, source = case when excluded.source = 'staff' then 'staff' else x.source end;
  end if;
  if p_relearn then perform app.turo_review_relearn(p_now); end if;
  return v_n;
end $$;

-- An email waiting for its car, with the car now known (the Worker's match, the model, a learned id or a person):
-- the trip is applied with what the email said, the email is done, its task closes and the car learns from it.
create or replace function app.turo_email_set_car(p_email uuid, p_vehicle uuid, p_method text, p_by uuid default null, p_why text default null,
                                                  p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  e turo_inbound_emails;
  r jsonb;
  v_status text;
begin
  select * into e from turo_inbound_emails where id = p_email for update;
  if e.id is null then raise exception 'That email is not found' using errcode = 'P0002'; end if;
  if e.status <> 'review' then raise exception 'That email is no longer waiting' using errcode = 'P0002'; end if;
  if not exists (select 1 from vehicles where id = p_vehicle) then raise exception 'Car not found' using errcode = 'P0002'; end if;
  r := app.turo_trip_apply(jsonb_build_object('kind', e.kind, 'trip_id', e.trip_id, 'vehicle_id', p_vehicle, 'starts_at', e.starts_at, 'ends_at', e.ends_at,
         'guest_first_name', e.guest_first_name, 'sent_at', e.sent_at, 'source', 'email'), p_now);
  -- what the email called the car is learned even when the trip itself still needs a person (a date missing)
  perform app.turo_learn(p_vehicle, e.turo_car_ids, e.car_name, case when p_method = 'staff' then 'staff' else 'auto' end, p_by, false, p_now);
  if r ->> 'status' = 'applied' then
    v_status := case when p_method = 'staff' then 'resolved' else 'applied' end;
    update turo_inbound_emails set status = v_status, vehicle_id = p_vehicle, turo_trip = (r ->> 'trip')::uuid, method = p_method,
           resolved_by = p_by, resolved_at = case when p_method = 'staff' then p_now end, excerpt = null, reason = null,
           match_why = left(coalesce(p_why, match_why), 300),
           audit = left(case p_method when 'staff' then 'Car chosen by staff. ' when 'learned' then 'Matched by a Turo car id learned since. ' when 'ai' then 'Car picked by the assistant. ' else 'Matched again. ' end || (r ->> 'audit'), 300)
     where id = e.id returning * into e;
    perform app.turo_trip_guest((r ->> 'trip')::uuid, e.guest_name, e.guest_phone, e.guest_email, e.guest_first_name);
    update turo_inbound_emails set guest_phone = null, guest_email = null where id = e.id;
    update tasks set status = 'done', completed_at = p_now, completed_by = p_by,
           completion_note = case when p_method = 'staff' then 'Car chosen on Calendar sync' else 'Matched automatically' end
     where id = e.task_id and status in ('open', 'in_progress', 'waiting');
    return jsonb_build_object('status', v_status, 'audit', e.audit, 'trip', r ->> 'trip', 'vehicle_id', p_vehicle);
  end if;
  -- the car is known but the trip still needs a person (a date or the trip number): it waits, with the car
  update turo_inbound_emails set vehicle_id = p_vehicle, reason = left(coalesce(r ->> 'reason', reason), 300), match_why = left(coalesce(p_why, match_why), 300)
   where id = e.id;
  return jsonb_build_object('status', 'review', 'reason', r ->> 'reason', 'vehicle_id', p_vehicle);
end $$;

-- Emails waiting for their car whose Turo car id is now known (or whose trip is now on a car): resolved at once.
create or replace function app.turo_review_relearn(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  x record;
  v_n integer := 0;
begin
  for x in
    select e.id, coalesce(
             (select min(i.vehicle_id::text)::uuid from turo_identities i where i.kind = 'turo_car_id' and i.value = any (e.turo_car_ids)
               having count(distinct i.vehicle_id) = 1),
             (select t.vehicle_id from turo_calendar_trips t where t.trip_id = upper(e.trip_id) and e.kind in ('changed', 'extended'))) as vehicle
      from turo_inbound_emails e
     where e.status = 'review' and e.vehicle_id is null and e.kind in ('booked', 'changed', 'extended')
     order by e.received_at
  loop
    continue when x.vehicle is null;
    perform app.turo_email_set_car(x.id, x.vehicle, 'learned', null, 'a Turo car id or trip learned since', p_now);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- ================================================================ 5. the guest: on the trip and one contact record
-- The guest's details on the trip (only what the email showed: a later email adds, never erases), and their contact
-- record: a lead of kind turo_guest matched by phone, then email, then name on the same trip. Never a renter account,
-- never a message sent, never marketing.
create or replace function app.turo_trip_guest(p_trip uuid, p_name text, p_phone text, p_email text, p_first text default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  t turo_calendar_trips;
  l leads;
  v_phone text := app.turo_phone(p_phone);
  v_email text := lower(nullif(btrim(coalesce(p_email, '')), ''));
  v_name text := left(nullif(btrim(coalesce(p_name, p_first, '')), ''), 60);
begin
  if p_trip is null then return null; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_email := null; end if;
  update turo_calendar_trips set guest_name = case when v_name is not null and length(v_name) >= length(coalesce(guest_name, '')) then v_name else guest_name end,
         guest_phone = coalesce(v_phone, guest_phone), guest_email = coalesce(v_email, guest_email)
   where id = p_trip returning * into t;
  if t.id is null or coalesce(t.guest_name, t.guest_phone, t.guest_email) is null then return null; end if;
  if t.lead_id is not null then select * into l from leads where id = t.lead_id; end if;
  if l.id is null and t.guest_phone is not null then
    select * into l from leads where kind = 'turo_guest' and app.turo_phone(phone) = t.guest_phone order by created_at desc limit 1;
  end if;
  if l.id is null and t.guest_email is not null then
    select * into l from leads where kind = 'turo_guest' and lower(email) = t.guest_email order by created_at desc limit 1;
  end if;
  if l.id is null and t.guest_name is not null then
    select * into l from leads where kind = 'turo_guest' and payload -> 'trips' ? t.trip_id and app.turo_name_norm(name) = app.turo_name_norm(t.guest_name) limit 1;
  end if;
  if l.id is null then
    insert into leads (kind, name, email, phone, message, payload, source, status, consent_marketing)
    values ('turo_guest', t.guest_name, t.guest_email, t.guest_phone, app.turo_guest_note(),
            jsonb_build_object('trips', jsonb_build_array(t.trip_id), 'vehicles', jsonb_build_array(t.vehicle_id), 'last_trip_end', t.ends_at), 'turo', 'new', false)
    returning * into l;
  else
    update leads set name = case when t.guest_name is not null and length(t.guest_name) >= length(coalesce(name, '')) then t.guest_name else name end,
           phone = coalesce(phone, t.guest_phone), email = coalesce(email, t.guest_email), message = app.turo_guest_note(),
           payload = payload || jsonb_build_object(
             'trips', (select jsonb_agg(distinct x) from jsonb_array_elements(coalesce(payload -> 'trips', '[]'::jsonb) || jsonb_build_array(t.trip_id)) x),
             'vehicles', (select jsonb_agg(distinct x) from jsonb_array_elements(coalesce(payload -> 'vehicles', '[]'::jsonb) || jsonb_build_array(t.vehicle_id)) x),
             'last_trip_end', greatest(nullif(payload ->> 'last_trip_end', '')::timestamptz, t.ends_at))
     where id = l.id returning * into l;
  end if;
  update turo_calendar_trips set lead_id = l.id where id = t.id and lead_id is distinct from l.id;
  -- the block on the car shows the guest (staff only; other platforms' exports say "Booked")
  perform app.turo_feed_refresh(t.vehicle_id);
  return l.id;
end $$;

-- A Turo guest by phone (for the phone line and Live chat): their name, trip and car.
create or replace function app.turo_guest_by_phone(p_number text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('lead_id', l.id, 'name', coalesce(l.name, t.guest_name), 'trip_id', t.trip_id, 'vehicle_id', t.vehicle_id,
           'vehicle', app.vehicle_name(t.vehicle_id), 'starts_at', t.starts_at, 'ends_at', t.ends_at, 'note', app.turo_guest_note())
    from leads l left join lateral (select * from turo_calendar_trips t where t.lead_id = l.id order by t.starts_at desc nulls last limit 1) t on true
   where l.kind = 'turo_guest' and app.turo_phone(p_number) is not null and app.turo_phone(l.phone) = app.turo_phone(p_number)
   order by l.updated_at desc limit 1
$$;

-- The block: "Turo trip 48211907 · Ayesha K. · 416-555-0199".
create or replace function app.turo_feed_refresh(p_vehicle uuid, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_feed uuid := app.turo_email_feed(p_vehicle);
begin
  return app.calendar_feed_apply(v_feed, coalesce((
    select jsonb_agg(jsonb_build_object('uid', 'turo:' || t.trip_id,
             'summary', left(case when t.trip_id ~ '^M-' then 'Turo trip (added by hand)' else 'Turo trip ' || t.trip_id end
                             || coalesce(' · ' || coalesce(t.guest_name, t.guest_first_name), '') || coalesce(' · ' || app.turo_phone_words(t.guest_phone), ''), 250),
             'starts_at', t.starts_at, 'ends_at', t.ends_at, 'all_day', false) order by t.starts_at)
      from turo_calendar_trips t where t.vehicle_id = p_vehicle and t.status = 'booked' and t.ends_at > p_now - interval '30 days'), '[]'::jsonb),
    '{}'::jsonb, p_now);
end $$;

-- ================================================================ 6. one email (from the Worker)
-- p: message_id, sent_at, envelope_from, subject, from_turo, kind, trip_id, vehicle_id, starts_at, ends_at,
-- guest_first_name, guest_name, guest_phone, guest_email, vehicle_hint, car_name, turo_car_ids (list), candidates
-- (list), match_why, missing (list), method, excerpt, neurons; or kind forwarding_confirmation with code and url.
create or replace function app.turo_email_receive(p jsonb, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_mid text := left(nullif(btrim(coalesce(p ->> 'message_id', '')), ''), 300);
  v_kind text := coalesce(nullif(p ->> 'kind', ''), 'other');
  v_from text := regexp_replace(lower(left(coalesce(p ->> 'envelope_from', ''), 200)), '\+[^@]*@', '@');
  v_status text;
  v_reason text;
  v_audit text;
  r jsonb := '{}'::jsonb;
  e turo_inbound_emails;
  v_missing text[] := array(select x from jsonb_array_elements_text(coalesce(p -> 'missing', '[]'::jsonb)) x);
  v_ok_forwarder boolean;
  v_ids text[] := array(select x from jsonb_array_elements_text(case when jsonb_typeof(p -> 'turo_car_ids') = 'array' then p -> 'turo_car_ids' else '[]'::jsonb end) x where x ~ '^\d{3,12}$' limit 10);
  v_vehicle uuid := nullif(p ->> 'vehicle_id', '')::uuid;
  v_phone text := app.turo_phone(p ->> 'guest_phone');
  v_email text := case when lower(btrim(coalesce(p ->> 'guest_email', ''))) ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then left(lower(btrim(p ->> 'guest_email')), 200) end;
  v_known uuid;
begin
  if v_mid is not null and exists (select 1 from turo_inbound_emails where message_id = v_mid) then
    return jsonb_build_object('status', 'duplicate');
  end if;
  -- housekeeping on the way: the log after turo_email_keep_days, a review excerpt (and the guest's contact on it) after
  -- 14 days, Turo guests' contact records 24 months after their last trip
  delete from turo_inbound_emails where received_at < p_now - make_interval(days => ps.turo_email_keep_days);
  update turo_inbound_emails set excerpt = null, guest_phone = null, guest_email = null
   where (excerpt is not null or guest_phone is not null or guest_email is not null) and received_at < p_now - interval '14 days';
  delete from leads l where l.kind = 'turo_guest' and coalesce(nullif(l.payload ->> 'last_trip_end', '')::timestamptz, l.created_at) < p_now - interval '24 months'
     and not exists (select 1 from turo_calendar_trips t where t.lead_id = l.id and t.ends_at > p_now - interval '24 months');
  if v_kind = 'forwarding_confirmation' then
    insert into turo_inbound_emails (received_at, message_id, sent_at, envelope_from, subject, kind, status, method, confirmation_code, confirmation_url, audit)
    values (p_now, v_mid, nullif(p ->> 'sent_at', '')::timestamptz, v_from, left(p ->> 'subject', 200), 'forwarding_confirmation', 'notice', 'none',
            p ->> 'code', nullif(p ->> 'url', ''), 'Gmail forwarding confirmation: shown to the Admins on Calendar sync')
    returning * into e;
    return jsonb_build_object('status', 'notice', 'id', e.id);
  end if;
  -- a car not among the candidates (retired since, a sample) is not taken
  if v_vehicle is not null and not exists (select 1 from vehicles v where v.id = v_vehicle) then v_vehicle := null; end if;
  -- the car of a change, an extension or a cancellation is the trip's own when the email does not name it
  if v_vehicle is null and v_kind in ('changed', 'extended') and nullif(p ->> 'trip_id', '') is not null then
    select vehicle_id into v_known from turo_calendar_trips where trip_id = upper(btrim(p ->> 'trip_id'));
    if v_known is not null then v_missing := array_remove(v_missing, 'car'); end if;
  end if;
  v_ok_forwarder := v_from = '' or v_from = any (select lower(btrim(x)) from unnest(string_to_array(ps.turo_email_forwarders, ',')) x);
  if not ps.turo_email_enabled then
    v_status := 'ignored'; v_reason := 'Turo by email is turned off in Program settings';
  elsif not v_ok_forwarder then
    v_status := 'ignored'; v_kind := 'not_turo'; v_reason := 'Not forwarded by an allowed mailbox (Program settings, Turo by email)';
  elsif not coalesce((p ->> 'from_turo')::boolean, false) then
    v_status := 'ignored'; v_kind := 'not_turo'; v_reason := 'Not an email from Turo';
  elsif v_kind = 'request' then
    v_status := 'ignored'; v_reason := 'A trip request waiting for your answer on Turo: nothing is blocked until it is booked';
  elsif v_kind not in ('booked', 'changed', 'extended', 'cancelled') then
    v_status := 'ignored'; v_kind := 'other'; v_reason := 'Not about a trip (news, payouts, reviews)';
  elsif cardinality(v_missing) > 0 and not (v_kind = 'cancelled' and v_missing = array['car']) then
    v_status := 'review';
    v_reason := case when v_missing = array['car'] then 'Which car: ' || coalesce(nullif(p ->> 'match_why', ''), 'no car matches the email') else 'Could not read: ' || array_to_string(v_missing, ', ') end;
  else
    r := app.turo_trip_apply(jsonb_build_object('kind', v_kind, 'trip_id', p ->> 'trip_id', 'vehicle_id', v_vehicle, 'starts_at', p ->> 'starts_at',
           'ends_at', p ->> 'ends_at', 'guest_first_name', p ->> 'guest_first_name', 'sent_at', p ->> 'sent_at', 'source', 'email'), p_now);
    v_status := r ->> 'status'; v_reason := r ->> 'reason'; v_audit := r ->> 'audit';
  end if;
  insert into turo_inbound_emails (received_at, message_id, sent_at, envelope_from, subject, kind, status, method, trip_id, vehicle_id, starts_at, ends_at,
                                   guest_first_name, vehicle_hint, reason, audit, excerpt, turo_trip, turo_car_ids, car_name, candidates, match_why,
                                   guest_name, guest_phone, guest_email)
  values (p_now, v_mid, nullif(p ->> 'sent_at', '')::timestamptz, v_from, left(p ->> 'subject', 200), v_kind, v_status,
          case when p ->> 'method' in ('rules', 'ai', 'none') then p ->> 'method' else 'rules' end,
          left(nullif(p ->> 'trip_id', ''), 40), coalesce((r ->> 'vehicle_id')::uuid, v_vehicle),
          nullif(p ->> 'starts_at', '')::timestamptz, nullif(p ->> 'ends_at', '')::timestamptz, left(nullif(p ->> 'guest_first_name', ''), 40),
          left(nullif(p ->> 'vehicle_hint', ''), 120), left(v_reason, 300),
          left(coalesce(v_audit, initcap(v_kind) || case when v_status = 'review' then ': waiting for a person' else ': ' || coalesce(lower(v_reason), 'nothing to do') end), 300),
          case when v_status = 'review' then left(p ->> 'excerpt', 800) end, (r ->> 'trip')::uuid,
          case when cardinality(v_ids) > 0 then v_ids end, left(nullif(btrim(p ->> 'car_name'), ''), 120),
          case when jsonb_typeof(p -> 'candidates') = 'array' and jsonb_array_length(p -> 'candidates') > 0 then
            (select jsonb_agg(jsonb_build_object('vehicle_id', c ->> 'vehicle_id', 'score', (c ->> 'score')::numeric,
                     'why', coalesce(c -> 'why', '[]'::jsonb)) order by n)
               from jsonb_array_elements(p -> 'candidates') with ordinality y(c, n)
              where n <= 6 and (c ->> 'vehicle_id') ~ '^[0-9a-f-]{36}$' and exists (select 1 from vehicles v where v.id = (c ->> 'vehicle_id')::uuid)) end,
          left(nullif(p ->> 'match_why', ''), 300),
          left(nullif(btrim(p ->> 'guest_name'), ''), 60),
          case when v_status in ('review', 'applied') then v_phone end, case when v_status in ('review', 'applied') then v_email end)
  returning * into e;
  if v_status = 'applied' and (r ->> 'vehicle_id') is not null then
    -- learn what the email called the car (id and exact Turo name), and keep the guest on the trip
    perform app.turo_learn((r ->> 'vehicle_id')::uuid, v_ids, nullif(btrim(p ->> 'car_name'), ''), 'auto', null, true, p_now);
    if v_kind <> 'cancelled' then
      perform app.turo_trip_guest((r ->> 'trip')::uuid, e.guest_name, e.guest_phone, e.guest_email, e.guest_first_name);
    end if;
    update turo_inbound_emails set guest_phone = null, guest_email = null where id = e.id and (guest_phone is not null or guest_email is not null);
  end if;
  if v_status = 'review' then
    update turo_inbound_emails set task_id = app.raise_task(p_type => 'turo_email_review',
        p_title => left(format('%s: %s', case when v_missing = array['car'] then 'Which car is this? Turo email' else 'Turo email to check' end, coalesce(e.subject, 'no subject')), 200),
        p_detail => format('%s. Open Calendar sync: %s', v_reason, case when v_missing = array['car'] then 'choose the car in "Which car is this?" (one click; it is remembered for next time).'
                                                                         else 'check the trip on Turo, then add it there (Add a Turo trip) or dismiss the email.' end),
        p_vehicle => e.vehicle_id, p_related_table => 'turo_inbound_emails', p_related_id => e.id, p_dedupe => 'turo_email:' || e.id)
     where id = e.id;
  end if;
  if (p ->> 'neurons') ~ '^\d+$' and (p ->> 'neurons')::integer > 0 then
    insert into provider_calls (provider, purpose, ok, units, unit, created_at)
    values ('workers-ai', 'turo_email', true, (p ->> 'neurons')::integer, 'neurons', p_now);
  end if;
  return jsonb_build_object('status', v_status, 'reason', v_reason, 'audit', e.audit, 'id', e.id);
end $$;

-- ================================================================ 7. matching again (the backfill; the Worker's job)
-- Emails waiting for their car, matched again when the fleet or what was learned changed since their last try.
-- first: never matched again before (the model may help once).
create or replace function app.turo_rematch_due(p_limit integer default 20, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_changed timestamptz := app.turo_fleet_changed_at();
  v jsonb;
begin
  with due as (
    select e.id, e.rematched_at is null as first from turo_inbound_emails e
     where e.status = 'review' and e.vehicle_id is null and e.kind in ('booked', 'changed', 'extended')
       and (e.rematched_at is null or e.rematched_at < v_changed)
     order by e.received_at limit greatest(coalesce(p_limit, 20), 1) for update skip locked),
  upd as (update turo_inbound_emails e set rematched_at = p_now from due where e.id = due.id returning e.*, due.first)
  select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'first', u.first, 'subject', u.subject, 'kind', u.kind, 'trip_id', u.trip_id,
           'starts_at', u.starts_at, 'ends_at', u.ends_at, 'guest_first_name', u.guest_first_name, 'vehicle_hint', u.vehicle_hint,
           'car_name', u.car_name, 'turo_car_ids', coalesce(to_jsonb(u.turo_car_ids), '[]'::jsonb), 'excerpt', u.excerpt, 'sent_at', u.sent_at)), '[]'::jsonb)
    into v from upd u;
  return v;
end $$;

-- The Worker's answer for one: the car (rules or the model) or the new best guesses.
create or replace function app.turo_rematch_result(p jsonb, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  e turo_inbound_emails;
  v_vehicle uuid := nullif(p ->> 'vehicle_id', '')::uuid;
begin
  select * into e from turo_inbound_emails where id = (p ->> 'id')::uuid and status = 'review' and vehicle_id is null;
  if e.id is null then return jsonb_build_object('status', 'gone'); end if;
  update turo_inbound_emails set
         candidates = case when jsonb_typeof(p -> 'candidates') = 'array' then
           (select jsonb_agg(jsonb_build_object('vehicle_id', c ->> 'vehicle_id', 'score', (c ->> 'score')::numeric, 'why', coalesce(c -> 'why', '[]'::jsonb)) order by n)
              from jsonb_array_elements(p -> 'candidates') with ordinality y(c, n)
             where n <= 6 and (c ->> 'vehicle_id') ~ '^[0-9a-f-]{36}$' and exists (select 1 from vehicles v where v.id = (c ->> 'vehicle_id')::uuid)) else candidates end,
         match_why = left(coalesce(nullif(p ->> 'why', ''), match_why), 300),
         car_name = coalesce(car_name, left(nullif(btrim(p ->> 'car_name'), ''), 120)),
         reason = case when v_vehicle is null and reason like 'Which car:%' and nullif(p ->> 'why', '') is not null then left('Which car: ' || (p ->> 'why'), 300) else reason end
   where id = e.id;
  if (p ->> 'neurons') ~ '^\d+$' and (p ->> 'neurons')::integer > 0 then
    insert into provider_calls (provider, purpose, ok, units, unit, created_at) values ('workers-ai', 'turo_email', true, (p ->> 'neurons')::integer, 'neurons', p_now);
  end if;
  if v_vehicle is null or not exists (select 1 from vehicles where id = v_vehicle) then return jsonb_build_object('status', 'review'); end if;
  return app.turo_email_set_car(e.id, v_vehicle, case when p ->> 'method' = 'ai' then 'ai' else 'rules' end, null, p ->> 'why', p_now);
end $$;

-- The cron gate (0076, 0077): the five-minute tick runs the rematch only when an email waits for it.
alter function app.server_jobs_due() rename to server_jobs_due_pre0088;
create or replace function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_changed timestamptz := app.turo_fleet_changed_at();
begin
  return app.server_jobs_due_pre0088() || jsonb_build_object('turo', exists (select 1 from turo_inbound_emails e
           where e.status = 'review' and e.vehicle_id is null and e.kind in ('booked', 'changed', 'extended') and (e.rematched_at is null or e.rematched_at < v_changed)));
end $$;

-- ================================================================ 8. Calendar sync: the page and its actions
alter function app.calendar_sync_read(uuid, jsonb) rename to calendar_sync_read_pre0088;
create or replace function app.calendar_sync_read(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.calendar_sync_read_pre0088(p_by, p);
begin
  -- each car: what was learned about it, and its trips with the guest
  v := jsonb_set(v, '{cars}', coalesce((
    select jsonb_agg(x.car || jsonb_build_object('turo', (x.car -> 'turo') || jsonb_build_object(
             'candidate', (select app.turo_candidate(vv) from vehicles vv where vv.id = (x.car ->> 'id')::uuid),
             'identities', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'value', i.value, 'source', i.source, 'hits', i.hits,
                                      'last_seen_at', i.last_seen_at) order by i.kind desc, i.last_seen_at desc)
                                       from turo_identities i where i.vehicle_id = (x.car ->> 'id')::uuid), '[]'::jsonb),
             'trips', coalesce((select jsonb_agg(tr || jsonb_build_object('guest_name', t.guest_name, 'guest_phone', t.guest_phone, 'guest_email', t.guest_email))
                                  from jsonb_array_elements(x.car -> 'turo' -> 'trips') tr join turo_calendar_trips t on t.id = (tr ->> 'id')::uuid), '[]'::jsonb)))
             order by x.n)
      from jsonb_array_elements(v -> 'cars') with ordinality x(car, n)), '[]'::jsonb));
  -- the emails to check: "Which car is this?" with the best guesses first (then every other candidate car)
  v := jsonb_set(v, '{turo,review}', coalesce((
    select jsonb_agg(jsonb_build_object('id', e.id, 'received_at', e.received_at, 'subject', e.subject, 'kind', e.kind, 'reason', e.reason,
             'trip_id', e.trip_id, 'vehicle_id', e.vehicle_id, 'vehicle', app.vehicle_name(e.vehicle_id), 'vehicle_hint', coalesce(e.car_name, e.vehicle_hint),
             'starts_at', e.starts_at, 'ends_at', e.ends_at, 'guest_first_name', e.guest_first_name, 'guest_name', e.guest_name, 'excerpt', e.excerpt,
             'turo_car_ids', coalesce(to_jsonb(e.turo_car_ids), '[]'::jsonb),
             -- only the car is unclear: one click answers it
             'pick', e.vehicle_id is null and e.kind in ('booked', 'changed', 'extended') and e.reason like 'Which car:%',
             'guesses', coalesce((select jsonb_agg(jsonb_build_object('vehicle_id', vv.id, 'name', app.vehicle_name(vv.id), 'year', vv.year, 'colour', vv.colour,
                                    'plate_end', right(regexp_replace(coalesce(vv.plate, ''), '[^A-Za-z0-9]', '', 'g'), 3), 'score', c ->> 'score',
                                    'why', c -> 'why') order by n)
                                   from jsonb_array_elements(coalesce(e.candidates, '[]'::jsonb)) with ordinality y(c, n)
                                   join vehicles vv on vv.id = (c ->> 'vehicle_id')::uuid), '[]'::jsonb)) order by e.received_at)
      from turo_inbound_emails e where e.status = 'review'), '[]'::jsonb));
  return jsonb_set(v, '{turo}', (v -> 'turo') || jsonb_build_object(
    'guest_note', app.turo_guest_note(),
    'candidates', coalesce((select jsonb_agg(jsonb_build_object('id', vv.id, 'name', app.vehicle_name(vv.id), 'colour', vv.colour,
                              'plate_end', right(regexp_replace(coalesce(vv.plate, ''), '[^A-Za-z0-9]', '', 'g'), 3)) order by vv.make, vv.model, vv.year)
                             from vehicles vv where app.turo_candidate(vv)), '[]'::jsonb),
    'learned', (select count(*) from turo_identities)));
end $$;

alter function app.calendar_sync_do(uuid, text, jsonb) rename to calendar_sync_do_pre0088;
create or replace function app.calendar_sync_do(p_by uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb;
  e turo_inbound_emails;
  i turo_identities;
begin
  perform app.assert_calendar_staff(p_by);
  case p_name
  when 'turo_review_pick' then
    -- "Which car is this?": the trip is applied, the email checked, and the car learns what Turo calls it
    r := app.turo_email_set_car((p ->> 'id')::uuid, (p ->> 'vehicle')::uuid, 'staff', p_by, 'chosen by staff');
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'UPDATE', 'turo_inbound_emails', (p ->> 'id')::uuid, jsonb_build_object('car_chosen', p ->> 'vehicle', 'result', r ->> 'status'));
    perform app.turo_review_relearn();
    return r;
  when 'turo_identity_remove' then
    delete from turo_identities where id = (p ->> 'id')::uuid returning * into i;
    if i.id is null then raise exception 'Already removed' using errcode = 'P0002'; end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before)
    values (p_by, 'DELETE', 'turo_identities', i.id, jsonb_build_object('vehicle_id', i.vehicle_id, 'kind', i.kind, 'value', i.value));
    return jsonb_build_object('removed', true);
  when 'turo_trip_add' then
    -- an email resolved by hand teaches the car too
    select * into e from turo_inbound_emails where id = nullif(p ->> 'email', '')::uuid and status = 'review';
    r := app.calendar_sync_do_pre0088(p_by, p_name, p);
    if e.id is not null then
      perform app.turo_learn((p ->> 'vehicle')::uuid, e.turo_car_ids, e.car_name, 'staff', p_by, true);
      perform app.turo_trip_guest((r ->> 'trip')::uuid, e.guest_name, e.guest_phone, e.guest_email, e.guest_first_name);
      update turo_inbound_emails set guest_phone = null, guest_email = null where id = e.id;
    end if;
    return r;
  when 'turo_review_dismiss' then
    r := app.calendar_sync_do_pre0088(p_by, p_name, p);
    update turo_inbound_emails set guest_phone = null, guest_email = null where id = (p ->> 'id')::uuid;
    return r;
  else
    return app.calendar_sync_do_pre0088(p_by, p_name, p);
  end case;
end $$;

-- ================================================================ 9. To do, the door
alter function app.admin_todo(uuid) rename to admin_todo_pre0088;
create or replace function app.admin_todo(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.admin_todo_pre0088(p_admin);
  v_first uuid := (select id from turo_inbound_emails where status = 'review' and vehicle_id is null and reason like 'Which car:%' order by received_at limit 1);
begin
  return jsonb_set(v, '{items}', coalesce((select jsonb_agg(case when i ->> 'key' = 'turo_emails'
      then i || jsonb_build_object('label', case when v_first is not null then 'Turo emails: which car is this?' else 'Turo emails to check' end,
                                   'button', case when v_first is not null then 'Choose the car' else 'Check them' end,
                                   'href', case when v_first is not null then '/admin/calendar-sync?pick=' || v_first || '#turo-review' else '/admin/calendar-sync#turo-review' end)
      else i end order by n) from jsonb_array_elements(v -> 'items') with ordinality x(i, n)), '[]'::jsonb));
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0088;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if p_call in ('va_do', 'admin_do', 'ops_do') and p_name in ('turo_review_pick', 'turo_identity_remove', 'turo_trip_add', 'turo_review_dismiss') then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.calendar_sync_do(p_user, p_name, p_ - '_va');
  end if;
  return app.door_pre0088(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 10. Live chat names: a Turo guest who writes or calls
-- A chat whose phone or email is a Turo guest's shows "Priya Shah (Turo guest)" when no other name is known.
create or replace function app.visitor_chat_name(c chat_conversations) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(nullif(c.name, ''), (select r.legal_name from renters r where r.id = c.renter_id),
    (select l.name || ' (Turo guest)' from leads l where l.kind = 'turo_guest' and l.name is not null
        and ((c.phone is not null and app.turo_phone(l.phone) = app.turo_phone(c.phone)) or (c.email is not null and lower(l.email) = lower(c.email)))
      order by l.updated_at desc limit 1),
    (select app.visitor_who(s) from visitor_sessions s where s.id = c.session_id), 'Visitor')
$$;

-- ================================================================ 11. the server's calls (service role)
create or replace function public.turo_rematch_due(p_limit integer default 20) returns jsonb
language sql security definer set search_path = public, app as $$ select app.turo_rematch_due(p_limit) $$;
create or replace function public.turo_rematch_result(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.turo_rematch_result(p) $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and (p.proname like '%\_pre0088' or p.proname = any (array[
              'turo_phone', 'turo_phone_words', 'turo_name_norm', 'turo_guest_note', 'turo_candidate', 'turo_fleet_changed_at', 'turo_match_keys', 'turo_learn',
              'turo_email_set_car', 'turo_review_relearn', 'turo_trip_guest', 'turo_guest_by_phone', 'turo_feed_refresh', 'turo_email_receive',
              'turo_rematch_due', 'turo_rematch_result', 'server_jobs_due', 'calendar_sync_read', 'calendar_sync_do', 'admin_todo', 'door', 'visitor_chat_name'])))
        or (n.nspname = 'public' and p.proname = any (array['turo_rematch_due', 'turo_rematch_result']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- Each renamed function keeps its privileges; the function in its place gets the same.
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('door_pre0088', 'door'), ('admin_todo_pre0088', 'admin_todo'), ('server_jobs_due_pre0088', 'server_jobs_due'),
                          ('calendar_sync_read_pre0088', 'calendar_sync_read'), ('calendar_sync_do_pre0088', 'calendar_sync_do')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    foreach g in array array['anon', 'authenticated'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

-- ================================================================ 12. the privacy policy: guests of other platforms
update site_content_blocks
   set body = replace(body,
     '| Live chat: the conversation and the page you were on, and your name, email or phone if you give them | To answer you and follow up on your request |',
     '| Live chat: the conversation and the page you were on, and your name, email or phone if you give them | To answer you and follow up on your request |
| Trips booked through another platform (such as Turo): the name, and the phone or email if the platform gives them to us, of the guest who booked one of our cars there | To manage that trip with the guest, never for marketing |')
 where block_key = 'legal.privacy' and body like '%| Live chat: the conversation and the page you were on%' and body not like '%Trips booked through another platform%';
update site_content_blocks
   set body = replace(body, '| Marketing contact details | Until you unsubscribe |',
     '| Details of guests who booked through another platform | 24 months after their last trip |
| Marketing contact details | Until you unsubscribe |')
 where block_key = 'legal.privacy' and body like '%| Marketing contact details | Until you unsubscribe |%' and body not like '%booked through another platform | 24 months%';

-- ================================================================ 13. backfill
-- Emails already waiting for their car: the ids learned and the trips known resolve them now; the Worker matches the
-- rest again on its next tick (rematched_at is empty for all of them).
update turo_inbound_emails set rematched_at = null where status = 'review';
update turo_inbound_emails set reason = 'Which car: ' || coalesce(vehicle_hint, 'no car matches the email')
 where status = 'review' and vehicle_id is null and reason = 'Could not read: car';
do $$ begin perform app.turo_review_relearn(); end $$;
-- the overrides typed before 0088 are learned too (staff typed them)
insert into turo_identities (vehicle_id, kind, value, source, created_by)
select l.vehicle_id, 'turo_car_id', l.turo_vehicle_id, 'staff', l.created_by from turo_vehicle_links l
 where l.turo_vehicle_id is not null and length(l.turo_vehicle_id) >= 3
on conflict do nothing;

-- ================================================================ 14. the guides for this release
create or replace function app.guide_release_0088(p_portal text, p_slug text, p_kind text, p_after text, p_base_md text, p_title text, p_blurb text,
                                                  p_md text, p_html text) returns text
language sql security definer set search_path = public, app as $$
  select app.guide_release_section(p_portal, p_slug, p_kind, p_after, p_base_md, p_title, p_blurb, p_md, p_html)
$$;
revoke all on function app.guide_release_0088(text, text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function app.guide_release_0088(text, text, text, text, text, text, text, text, text) to service_role;

-- GUIDES 0088 START (generated by supabase/seed/0088_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_0088('admin', 'calendar-sync-with-turo-and-other-platforms', 'chapter', 'calendars', 'A car rented on Turo, Getaround or another site must never be booked twice. Turo has no calendar link, so Turo works by email: Turo''s trip emails block the car here, and you block our bookings on Turo by hand. Getaround, Google Calendar and other sites work through calendar links (iCal), both ways.

## Set up Turo by email (once)

Turo emails rent@carmacars.ca for every trip booked, changed, extended or cancelled. One Gmail filter forwards those emails to trips@in.carmacars.ca, and each one blocks the car here within a minute.

1. In Gmail (rent@carmacars.ca): Settings, See all settings, Forwarding and POP/IMAP. Press Add a forwarding address and type trips@in.carmacars.ca.
2. Gmail sends a confirmation code to that address. Open **Cars** > **Calendar sync**: the code shows under "Turo by email" (and To do shows "Gmail forwarding to confirm"). Type it in Gmail and press Verify. Leave forwarding itself off: only the filter forwards.
3. In Gmail, in the search box, show the search options. From: turo.com. Press Create filter, tick Forward it to: trips@in.carmacars.ca, and press Create filter.
4. On Calendar sync, for each car on Turo, press **This car is on Turo**, type its name exactly as Turo''s emails show it (for example Mercedes-Benz GLC 2021) and press **Save**. The Turo car number (the number at the end of its Turo page address) is optional; the plate and VIN are matched too.

## Turo trips on the calendar

1. A trip booked on Turo becomes an "External booking" block on the car, with the turnaround before and after it. The car cannot be requested, offered or booked here for those times.
2. A changed or extended trip moves its block; a cancelled trip frees the car. An older email never undoes a newer one.
3. Each car lists its Turo trips: the dates, the Turo trip number and the guest''s first name. Press Cancelled if Turo cancelled a trip and its email did not come.
4. **Add a Turo trip**: the trip start and end (Toronto time), and the Turo trip number if you have it. Use it for a trip whose email did not come.
5. Only what the email says is kept: the car, the dates, the trip number and the guest''s first name. The email itself is never stored.

## Turo emails to check

When the reader is not sure (which car, the dates or the trip number), the email waits under "Turo emails to check", with a Fleet task and a line on To do.

1. Read what was found and the short excerpt (no email addresses, phone numbers or links). Check the trip on Turo.
2. Press **Add as a Turo trip**, choose the car, check the dates and press **Add this trip**. The email is checked and the task closes.
3. Not a trip (a request, a message)? Press **Dismiss**.

## Block our bookings on Turo (Done on Turo)

Turo cannot read our calendar. Each car on Turo lists, under "Block on Turo", the CarmaCars bookings not yet blocked there.

1. Open the car''s calendar on Turo and block the dates shown (the turnaround is included).
2. Press **Done on Turo**. The booking leaves the list.
3. If the booking''s dates change, it comes back with the old dates to free first. A booking cancelled here shows the dates to free on Turo: free them, then press Freed on Turo.

## Getaround, Google Calendar and other calendar links

**Cars** > **Calendar sync**, for a platform that gives a calendar (iCal) link.

1. Copy the car''s calendar link on the platform (look for "Export calendar" or "iCal"). On Calendar sync, open **Add a calendar link**, choose Getaround, Google Calendar or Other, paste the link and press **Add the link**.
2. The link is read at once and then every 10 minutes; **Sync now** reads it at once. Each trip becomes an "External booking" block with the turnaround.
3. Send our bookings there: press **Copy** next to "For Getaround" (or "For Google Calendar", or "For any other platform") under "This car''s CarmaCars calendar" and paste it into the platform''s calendar import. It shows only "Booked" times: no names, numbers or prices.
4. If a link was shared by mistake, press **Make a new link**. The old one stops working at once: paste the new one into every platform again.

## Double bookings

If a trip on Turo or another platform overlaps a confirmed CarmaCars booking of the same car, we tell you at once.

- An urgent Fleet task "Double booking: on Turo and CC-1042", a line on To do and an email to Fleet and the Admins.
- Calendar sync lists it at the top with both trips. Move, swap or cancel one of the two. The task closes by itself once they no longer overlap.
- An offer or a booking awaiting payment over a trip on another platform raises a task for customer service: its payment would be refused, so withdraw the offer or change the dates.

## A link that stops working

A platform answers an error when a link is reset or removed. After 3 failed reads in a row (a Program setting) Fleet gets a task and an email, and To do shows "Calendar links not working". The trips already read stay on the calendar. Copy the link from the platform again, remove the old one and add the new one.

> Good to know: A block from another platform can be removed from the calendar like any block; calendar sync will not put it back. In Program settings, "Calendar sync" and "Turo by email": on or off, how often links are read, the inbound address, the mailboxes allowed to forward (rent@carmacars.ca) and how long the email log is kept (90 days).
', 'Calendar sync with Turo and other platforms', 'Turo by email (set up once, cars found by themselves, "Which car is this?", the guest, Done on Turo), calendar links for other platforms, clashes.',
  'A car rented on Turo, Getaround or another site must never be booked twice. Turo has no calendar link, so Turo works by email: Turo''s trip emails block the car here, and you block our bookings on Turo by hand. Getaround, Google Calendar and other sites work through calendar links (iCal), both ways.

## Set up Turo by email (once)

Turo emails rent@carmacars.ca for every trip booked, changed, extended or cancelled. One Gmail filter forwards those emails to trips@in.carmacars.ca, and each one blocks the car here within a minute.

1. In Gmail (rent@carmacars.ca): Settings, See all settings, Forwarding and POP/IMAP. Press Add a forwarding address and type trips@in.carmacars.ca.
2. Gmail sends a confirmation code to that address. Open **Cars** > **Calendar sync**: the code shows under "Turo by email" (and To do shows "Gmail forwarding to confirm"). Type it in Gmail and press Verify. Leave forwarding itself off: only the filter forwards.
3. In Gmail, in the search box, show the search options. From: turo.com. Press Create filter, tick Forward it to: trips@in.carmacars.ca, and press Create filter.
4. Nothing to set up per car. Every active car (not the sample cars) is matched by itself: see the next task.

## How Turo emails find their car (automatic)

Each Turo email is matched to one of our cars by itself. You never type a car''s name on Turo.

- The reader looks at the Turo car number in the email''s links and pictures, the VIN, the plate, the year, make and model (C-Class finds a C 300, Model3 a Model 3, 3 Series a 330i), trim and colour words, the trip already on a car, and whether a car is already busy at those dates.
- A clear winner is applied at once. When two cars are close (two black 2021 Jettas), the assistant picks between them only if the email tells them apart; otherwise the email waits as "Which car is this?".
- Every match teaches the car what Turo calls it (its Turo car number and the name in Turo''s emails), so the next email for that car matches at once. Each car on Calendar sync shows what it learned; press Forget next to one that is wrong.
- Rarely needed: **Type its name on Turo (optional)** on a car whose Turo name the reader cannot place. The Turo car number there is optional too.

## Turo trips on the calendar

1. A trip booked on Turo becomes an "External booking" block on the car, with the turnaround before and after it. The car cannot be requested, offered or booked here for those times.
2. A changed or extended trip moves its block; a cancelled trip frees the car. An older email never undoes a newer one.
3. Each car lists its Turo trips: the dates, the Turo trip number, the guest''s name as Turo shows it and their phone when the email includes it (press Call). The car''s calendar block shows them too. Press Cancelled if Turo cancelled a trip and its email did not come.
4. **Add a Turo trip**: the trip start and end (Toronto time), and the Turo trip number if you have it. Use it for a trip whose email did not come.
5. Only what the email says is kept: the car, the dates, the trip number, and the guest''s name, phone and email when Turo shows them (a hidden or masked number is never taken). The email itself is never stored.
6. Each guest gets one contact record (source Turo), so a Turo guest who calls our line or writes in Live chat is recognised by their phone. Contact them only about their trip: never add them to a marketing list or send promotions (Canada''s anti-spam law and Turo''s rules on taking guests off the platform). Nothing is sent to them by itself.

## Which car is this? (Turo emails to check)

Only an email the reader cannot be sure about waits under "Turo emails to check", with a Fleet task and a line on To do.

1. To do shows "Turo emails: which car is this?". Press **Choose the car**, or **Which car is this?** on the email in Calendar sync.
2. The pop-up shows what Turo calls the car and the trip, then our best guesses first (with colour and the plate''s last 3). Press the right car. Not among them? Choose it under Another car and press This car.
3. The trip is added and blocks the car, the task closes, and the car remembers what Turo called it: the next email for it matches by itself. Other emails waiting with the same Turo car number are matched at once.
4. Something else is missing (the dates or the trip number)? Check the trip on Turo, press **Add as a Turo trip**, choose the car, check the dates and press **Add this trip**. Not a trip (a request, a message)? Press **Dismiss**.

## Block our bookings on Turo (Done on Turo)

Turo cannot read our calendar. Each car on Turo lists, under "Block on Turo", the CarmaCars bookings not yet blocked there.

1. Open the car''s calendar on Turo and block the dates shown (the turnaround is included).
2. Press **Done on Turo**. The booking leaves the list.
3. If the booking''s dates change, it comes back with the old dates to free first. A booking cancelled here shows the dates to free on Turo: free them, then press Freed on Turo.

## Getaround, Google Calendar and other calendar links

**Cars** > **Calendar sync**, for a platform that gives a calendar (iCal) link.

1. Copy the car''s calendar link on the platform (look for "Export calendar" or "iCal"). On Calendar sync, open **Add a calendar link**, choose Getaround, Google Calendar or Other, paste the link and press **Add the link**.
2. The link is read at once and then every 10 minutes; **Sync now** reads it at once. Each trip becomes an "External booking" block with the turnaround.
3. Send our bookings there: press **Copy** next to "For Getaround" (or "For Google Calendar", or "For any other platform") under "This car''s CarmaCars calendar" and paste it into the platform''s calendar import. It shows only "Booked" times: no names, numbers or prices.
4. If a link was shared by mistake, press **Make a new link**. The old one stops working at once: paste the new one into every platform again.

## Double bookings

If a trip on Turo or another platform overlaps a confirmed CarmaCars booking of the same car, we tell you at once.

- An urgent Fleet task "Double booking: on Turo and CC-1042", a line on To do and an email to Fleet and the Admins.
- Calendar sync lists it at the top with both trips. Move, swap or cancel one of the two. The task closes by itself once they no longer overlap.
- An offer or a booking awaiting payment over a trip on another platform raises a task for customer service: its payment would be refused, so withdraw the offer or change the dates.

## A link that stops working

A platform answers an error when a link is reset or removed. After 3 failed reads in a row (a Program setting) Fleet gets a task and an email, and To do shows "Calendar links not working". The trips already read stay on the calendar. Copy the link from the platform again, remove the old one and add the new one.

> Good to know: A block from another platform can be removed from the calendar like any block; calendar sync will not put it back. In Program settings, "Calendar sync" and "Turo by email": on or off, how often links are read, the inbound address, the mailboxes allowed to forward (rent@carmacars.ca) and how long the email log is kept (90 days).
',
  '<p class="gd-p">A car rented on Turo, Getaround or another site must never be booked twice. Turo has no calendar link, so Turo works by email: Turo&#39;s trip emails block the car here, and you block our bookings on Turo by hand. Getaround, Google Calendar and other sites work through calendar links (iCal), both ways.</p><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-set-up-turo-by-email-once" data-gd-task><h2 class="gd-h2">Set up Turo by email (once)</h2><p class="gd-p">Turo emails rent@carmacars.ca for every trip booked, changed, extended or cancelled. One Gmail filter forwards those emails to trips@in.carmacars.ca, and each one blocks the car here within a minute.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">In Gmail (rent@carmacars.ca): Settings, See all settings, Forwarding and POP/IMAP. Press Add a forwarding address and type trips@in.carmacars.ca.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Gmail sends a confirmation code to that address. Open <b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Calendar sync</b>: the code shows under &quot;Turo by email&quot; (and To do shows &quot;Gmail forwarding to confirm&quot;). Type it in Gmail and press Verify. Leave forwarding itself off: only the filter forwards.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">In Gmail, in the search box, show the search options. From: turo.com. Press Create filter, tick Forward it to: trips@in.carmacars.ca, and press Create filter.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Nothing to set up per car. Every active car (not the sample cars) is matched by itself: see the next task.</div></li></ol></div></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-how-turo-emails-find-their-car-automatic" data-gd-task><h2 class="gd-h2">How Turo emails find their car (automatic)</h2><p class="gd-p">Each Turo email is matched to one of our cars by itself. You never type a car&#39;s name on Turo.</p><ul class="gd-ul"><li>The reader looks at the Turo car number in the email&#39;s links and pictures, the VIN, the plate, the year, make and model (C-Class finds a C 300, Model3 a Model 3, 3 Series a 330i), trim and colour words, the trip already on a car, and whether a car is already busy at those dates.</li><li>A clear winner is applied at once. When two cars are close (two black 2021 Jettas), the assistant picks between them only if the email tells them apart; otherwise the email waits as &quot;Which car is this?&quot;.</li><li>Every match teaches the car what Turo calls it (its Turo car number and the name in Turo&#39;s emails), so the next email for that car matches at once. Each car on Calendar sync shows what it learned; press Forget next to one that is wrong.</li><li>Rarely needed: <b class="gd-ui">Type its name on Turo (optional)</b> on a car whose Turo name the reader cannot place. The Turo car number there is optional too.</li></ul></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-turo-trips-on-the-calendar" data-gd-task><h2 class="gd-h2">Turo trips on the calendar</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A trip booked on Turo becomes an &quot;External booking&quot; block on the car, with the turnaround before and after it. The car cannot be requested, offered or booked here for those times.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A changed or extended trip moves its block; a cancelled trip frees the car. An older email never undoes a newer one.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each car lists its Turo trips: the dates, the Turo trip number, the guest&#39;s name as Turo shows it and their phone when the email includes it (press Call). The car&#39;s calendar block shows them too. Press Cancelled if Turo cancelled a trip and its email did not come.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Add a Turo trip</b>: the trip start and end (Toronto time), and the Turo trip number if you have it. Use it for a trip whose email did not come.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Only what the email says is kept: the car, the dates, the trip number, and the guest&#39;s name, phone and email when Turo shows them (a hidden or masked number is never taken). The email itself is never stored.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Each guest gets one contact record (source Turo), so a Turo guest who calls our line or writes in Live chat is recognised by their phone. Contact them only about their trip: never add them to a marketing list or send promotions (Canada&#39;s anti-spam law and Turo&#39;s rules on taking guests off the platform). Nothing is sent to them by itself.</div></li></ol></div></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-which-car-is-this-turo-emails-to-check" data-gd-task><h2 class="gd-h2">Which car is this? (Turo emails to check)</h2><p class="gd-p">Only an email the reader cannot be sure about waits under &quot;Turo emails to check&quot;, with a Fleet task and a line on To do.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">To do shows &quot;Turo emails: which car is this?&quot;. Press <b class="gd-ui">Choose the car</b>, or <b class="gd-ui">Which car is this?</b> on the email in Calendar sync.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The pop-up shows what Turo calls the car and the trip, then our best guesses first (with colour and the plate&#39;s last 3). Press the right car. Not among them? Choose it under Another car and press This car.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The trip is added and blocks the car, the task closes, and the car remembers what Turo called it: the next email for it matches by itself. Other emails waiting with the same Turo car number are matched at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Something else is missing (the dates or the trip number)? Check the trip on Turo, press <b class="gd-ui">Add as a Turo trip</b>, choose the car, check the dates and press <b class="gd-ui">Add this trip</b>. Not a trip (a request, a message)? Press <b class="gd-ui">Dismiss</b>.</div></li></ol></div></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-block-our-bookings-on-turo-done-on-turo" data-gd-task><h2 class="gd-h2">Block our bookings on Turo (Done on Turo)</h2><p class="gd-p">Turo cannot read our calendar. Each car on Turo lists, under &quot;Block on Turo&quot;, the CarmaCars bookings not yet blocked there.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the car&#39;s calendar on Turo and block the dates shown (the turnaround is included).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Done on Turo</b>. The booking leaves the list.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">If the booking&#39;s dates change, it comes back with the old dates to free first. A booking cancelled here shows the dates to free on Turo: free them, then press Freed on Turo.</div></li></ol></div></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-getaround-google-calendar-and-other-calendar-links" data-gd-task><h2 class="gd-h2">Getaround, Google Calendar and other calendar links</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Calendar sync</b>, for a platform that gives a calendar (iCal) link.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Copy the car&#39;s calendar link on the platform (look for &quot;Export calendar&quot; or &quot;iCal&quot;). On Calendar sync, open <b class="gd-ui">Add a calendar link</b>, choose Getaround, Google Calendar or Other, paste the link and press <b class="gd-ui">Add the link</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The link is read at once and then every 10 minutes; <b class="gd-ui">Sync now</b> reads it at once. Each trip becomes an &quot;External booking&quot; block with the turnaround.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Send our bookings there: press <b class="gd-ui">Copy</b> next to &quot;For Getaround&quot; (or &quot;For Google Calendar&quot;, or &quot;For any other platform&quot;) under &quot;This car&#39;s CarmaCars calendar&quot; and paste it into the platform&#39;s calendar import. It shows only &quot;Booked&quot; times: no names, numbers or prices.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">If a link was shared by mistake, press <b class="gd-ui">Make a new link</b>. The old one stops working at once: paste the new one into every platform again.</div></li></ol></div></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-double-bookings" data-gd-task><h2 class="gd-h2">Double bookings</h2><p class="gd-p">If a trip on Turo or another platform overlaps a confirmed CarmaCars booking of the same car, we tell you at once.</p><ul class="gd-ul"><li>An urgent Fleet task &quot;Double booking: on Turo and CC-1042&quot;, a line on To do and an email to Fleet and the Admins.</li><li>Calendar sync lists it at the top with both trips. Move, swap or cancel one of the two. The task closes by itself once they no longer overlap.</li><li>An offer or a booking awaiting payment over a trip on another platform raises a task for customer service: its payment would be refused, so withdraw the offer or change the dates.</li></ul></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-a-link-that-stops-working" data-gd-task><h2 class="gd-h2">A link that stops working</h2><p class="gd-p">A platform answers an error when a link is reset or removed. After 3 failed reads in a row (a Program setting) Fleet gets a task and an email, and To do shows &quot;Calendar links not working&quot;. The trips already read stay on the calendar. Copy the link from the platform again, remove the old one and add the new one.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A block from another platform can be removed from the calendar like any block; calendar sync will not put it back. In Program settings, &quot;Calendar sync&quot; and &quot;Turo by email&quot;: on or off, how often links are read, the inbound address, the mailboxes allowed to forward (rent@carmacars.ca) and how long the email log is kept (90 days).</div></aside></section>');
select app.guide_release_0088('va', 'fleet', 'chapter', 'finance', 'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

1. Handovers and returns without a job are listed first. Every booking needs one.
2. Press **Schedule**: choose the kind, car, when, place, field staff and instructions.
3. Jobs, next three days: each with its field staff and whether they acknowledged it.
4. Change a job with **Assign**, **Reassign**, **Move** or **Cancel**.

![](/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg "desktop; size: 1230 1180; address: carmacars.ca/va/fleet; pins: 1 15.4 10.4, 2 78.9 12.7, 3 11.4 68.6, 4 78.9 83.9")

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate listing stops publishing until you decide.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Rates and kilometres

From a listing, press **The car and its rates**, or open the car from Field jobs.

1. Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.
2. Keep **Use the defaults** for the kilometres, or choose **Custom for this car**.
3. Check What renters pay under the fields, then press **Save the rates**. Rates, kilometres and deposit save together.

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. Press **Cover the plate**. Check the suggested box; **Suggest the plate** asks again.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: Publishing waits until every public photo is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. Turo has no calendar link: Turo''s trip emails come in by themselves and block the car with the turnaround. For each car on Turo, press **This car is on Turo**, type its name exactly as Turo''s emails show it and press **Save**.
2. Under "Turo emails to check", an email the reader was not sure about: check the trip on Turo, then **Add as a Turo trip** (choose the car, check the dates) or **Dismiss**. A trip whose email did not come: **Add a Turo trip** on the car.
3. Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car''s Turo calendar, then press **Done on Turo**. Dates that changed or a booking cancelled here show the dates to free on Turo.
4. Getaround, Google Calendar or another platform with a calendar (iCal) link: open **Add a calendar link**, choose the platform, paste it and press **Add the link**. Copy the car''s CarmaCars link for that platform with **Copy** and paste it into the platform''s calendar import.
5. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.
', 'Fleet', 'Field jobs, daily checks, photo reviews, similar cars and listings.',
  'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

1. Handovers and returns without a job are listed first. Every booking needs one.
2. Press **Schedule**: choose the kind, car, when, place, field staff and instructions.
3. Jobs, next three days: each with its field staff and whether they acknowledged it.
4. Change a job with **Assign**, **Reassign**, **Move** or **Cancel**.

![](/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg "desktop; size: 1230 1180; address: carmacars.ca/va/fleet; pins: 1 15.4 10.4, 2 78.9 12.7, 3 11.4 68.6, 4 78.9 83.9")

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate listing stops publishing until you decide.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Rates and kilometres

From a listing, press **The car and its rates**, or open the car from Field jobs.

1. Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.
2. Keep **Use the defaults** for the kilometres, or choose **Custom for this car**.
3. Check What renters pay under the fields, then press **Save the rates**. Rates, kilometres and deposit save together.

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. Press **Cover the plate**. Check the suggested box; **Suggest the plate** asks again.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: Publishing waits until every public photo is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. Turo has no calendar link: Turo''s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.
2. An email the reader cannot place waits as "Which car is this?": press **Which car is this?** and press the right car (best guesses first). It is remembered for that car''s next emails. If the dates or trip number are missing: **Add as a Turo trip** (choose the car, check the dates) or **Dismiss**. A trip whose email did not come: **Add a Turo trip** on the car.
3. Each Turo trip shows the guest''s name and phone when Turo''s email includes them. Contact a Turo guest only about their trip, never with promotions.
4. Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car''s Turo calendar, then press **Done on Turo**. Dates that changed or a booking cancelled here show the dates to free on Turo.
5. Getaround, Google Calendar or another platform with a calendar (iCal) link: open **Add a calendar link**, choose the platform, paste it and press **Add the link**. Copy the car''s CarmaCars link for that platform with **Copy** and paste it into the platform''s calendar import.
6. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.
',
  '<p class="gd-p">You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.</p><p class="gd-p">Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.</p><section class="gd-task" id="fleet-schedule-field-jobs" data-gd-task><h2 class="gd-h2">Schedule field jobs</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Handovers and returns without a job are listed first. Every booking needs one.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Schedule</b>: choose the kind, car, when, place, field staff and instructions.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Jobs, next three days: each with its field staff and whether they acknowledged it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Change a job with <b class="gd-ui">Assign</b>, <b class="gd-ui">Reassign</b>, <b class="gd-ui">Move</b> or <b class="gd-ui">Cancel</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/fleet</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/1180"><img src="/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg" alt="" loading="lazy" decoding="async" width="1230" height="1180"><span class="gd-pin" style="left:15.4%;top:10.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:78.9%;top:12.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:11.4%;top:68.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:78.9%;top:83.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="fleet-daily-checks" data-gd-task><h2 class="gd-h2">Daily checks</h2><p class="gd-p">Twice a day: the opening check by 9:00 and the closing check by 18:00.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Daily checks</b> and choose <b class="gd-ui">Opening check</b> or <b class="gd-ui">Closing check</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line shows what was found. Tick OK, or Problem with a note.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the opening check</b> (or <b class="gd-ui">Save the closing check</b>). You can save it again.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/checks</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/820"><img src="/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg" alt="" loading="lazy" decoding="async" width="1230" height="820"><span class="gd-pin" style="left:6.5%;top:15.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:44.7%;top:42%" aria-hidden="true">2</span><span class="gd-pin" style="left:64.2%;top:94%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-photo-reviews-after-a-return" data-gd-task><h2 class="gd-h2">Photo reviews after a return</h2><p class="gd-p">After each return, the field photo set waits under <b class="gd-ui">Photo reviews</b>. Compare it with the pickup set. Press <b class="gd-ui">Review done</b>, or <b class="gd-ui">Ask for a re-shoot</b> if a photo is missing or unclear.</p></section><section class="gd-task" id="fleet-similar-cars" data-gd-task><h2 class="gd-h2">Similar cars</h2><p class="gd-p">A possible duplicate listing stops publishing until you decide.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Compare the permit, the plate and the photos.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Not a duplicate</b> with a note when they are different cars, or <b class="gd-ui">Same car</b> when they are.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/similar-cars</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/460"><img src="/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg" alt="" loading="lazy" decoding="async" width="1230" height="460"><span class="gd-pin" style="left:23.6%;top:30.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.8%;top:30.4%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-rates-and-kilometres" data-gd-task><h2 class="gd-h2">Rates and kilometres</h2><p class="gd-p">From a listing, press <b class="gd-ui">The car and its rates</b>, or open the car from Field jobs.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Keep <b class="gd-ui">Use the defaults</b> for the kilometres, or choose <b class="gd-ui">Custom for this car</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check What renters pay under the fields, then press <b class="gd-ui">Save the rates</b>. Rates, kilometres and deposit save together.</div></li></ol></div></section><section class="gd-task" id="fleet-listings-and-covering-plates" data-gd-task><h2 class="gd-h2">Listings and covering plates</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Listings</b>. A draft waiting shows Needs review. Open it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/listings</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/340"><img src="/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="340"><span class="gd-pin" style="left:54.5%;top:49.1%" aria-hidden="true">1</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Cover the plate</b>. Check the suggested box; <b class="gd-ui">Suggest the plate</b> asks again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Drag over a plate to draw a box; drag a box to move it, its corner to resize it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Choose <b class="gd-ui">A CarmaCars plate</b>, <b class="gd-ui">Pixelation</b> or <b class="gd-ui">Blur</b>, then <b class="gd-ui">Save the covered photo</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">No plate in the shot? <b class="gd-ui">No plate visible on this photo</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/776"><img src="/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg" alt="" loading="lazy" decoding="async" width="390" height="776"><span class="gd-pin" style="left:52.6%;top:78.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:50%;top:43.8%" aria-hidden="true">4</span><span class="gd-pin" style="left:61.5%;top:62.1%" aria-hidden="true">5</span><span class="gd-pin" style="left:43.1%;top:92.3%" aria-hidden="true">6</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Publishing waits until every public photo is covered or marked. The covered photo replaces the public one; the original is kept privately.</div></aside></section><section class="gd-task" id="fleet-calendar-sync-with-turo-and-other-platforms" data-gd-task><h2 class="gd-h2">Calendar sync with Turo and other platforms</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Calendar sync</b>: a car listed on Turo or Getaround must never be booked twice.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turo has no calendar link: Turo&#39;s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">An email the reader cannot place waits as &quot;Which car is this?&quot;: press <b class="gd-ui">Which car is this?</b> and press the right car (best guesses first). It is remembered for that car&#39;s next emails. If the dates or trip number are missing: <b class="gd-ui">Add as a Turo trip</b> (choose the car, check the dates) or <b class="gd-ui">Dismiss</b>. A trip whose email did not come: <b class="gd-ui">Add a Turo trip</b> on the car.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each Turo trip shows the guest&#39;s name and phone when Turo&#39;s email includes them. Contact a Turo guest only about their trip, never with promotions.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Turo cannot read our calendar: under &quot;Block on Turo&quot;, block each CarmaCars booking on the car&#39;s Turo calendar, then press <b class="gd-ui">Done on Turo</b>. Dates that changed or a booking cancelled here show the dates to free on Turo.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Getaround, Google Calendar or another platform with a calendar (iCal) link: open <b class="gd-ui">Add a calendar link</b>, choose the platform, paste it and press <b class="gd-ui">Add the link</b>. Copy the car&#39;s CarmaCars link for that platform with <b class="gd-ui">Copy</b> and paste it into the platform&#39;s calendar import.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.</div></li></ol></div></section>');
-- GUIDES 0088 END
