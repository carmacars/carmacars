-- 1303_r35a_rideshare_docs.sql
-- Release 35, part A (helper A), task 7 (docs/changes/2026-11-11-r35a-request-offers.md). The owner: a rideshare documents
-- request in the renter portal, deliberately low-key (on the booking page under a "More" menu): the renter picks the
-- platforms (Uber, Lyft, DoorDash, Uber Eats, Instacart, other) and the platform makes the documents those platforms ask for
-- (a copy of the rental agreement, a proof of insurance and coverage letter, and a vehicle registration and ownership letter
-- on the company letterhead naming only the company, 18122211 Canada Inc., never the car's owner); staff are notified.
--   1. rideshare_doc_requests: each request (the platforms, any other platform named), on a booking of the renter's that is
--      booked (waiting for payment, confirmed or on rent); not on an owner's own trip.
--   2. public.server_rideshare_docs_request (the renter asks; the same platforms within 10 minutes are one request): logged on
--      the booking and a staff alert (rideshare_docs_requested: the Admins, customer service and Fleet on duty).
--   3. public.server_rideshare_docs (the renter, or staff): the requests and the letters' facts: the company (Program
--      settings: legal name, address, phone, email), the car (year, make, model, colour, plate, VIN), the rental (number,
--      dates, the renter and the drivers), the coverage (app.accident_card: the option and its proof) and the fleet policy
--      (fleet_insurance_policies: insurer, policy number, dates, named insured), and the signed agreement document.
--   4. app.rideshare_docs_staff (ops_read rideshare_docs): the same for the booking page of every staff function.
-- The letters are rendered by the web app from these facts (printable pages); nothing here stores a file.
-- No applied migration is edited.
set local check_function_bodies = off;

create table rideshare_doc_requests (
  id             uuid primary key default gen_random_uuid(),
  booking_id     uuid not null references bookings(id) on delete cascade,
  renter_id      uuid references renters(id) on delete set null,
  platforms      text[] not null check (cardinality(platforms) between 1 and 6
                   and platforms <@ array['uber', 'lyft', 'doordash', 'uber_eats', 'instacart', 'other']),
  other_platform text check (other_platform is null or length(btrim(other_platform)) between 2 and 80),
  requested_by   uuid references users(id) on delete set null,
  created_at     timestamptz not null default now(),
  check (('other' = any (platforms)) = (other_platform is not null))
);
comment on table rideshare_doc_requests is 'A renter''s request for the documents rideshare and delivery platforms ask for (1303): the platforms picked; the letters are made from the booking''s facts (public.server_rideshare_docs) and name only the company.';
create index rideshare_doc_requests_booking on rideshare_doc_requests (booking_id, created_at desc);
alter table rideshare_doc_requests enable row level security;
create policy admin_read on rideshare_doc_requests for select to authenticated using (app.is_admin());
revoke all on rideshare_doc_requests from anon, authenticated;
grant select on rideshare_doc_requests to authenticated;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('rideshare_docs_requested', 'Rideshare documents asked for', 'Bookings', '{admin,on_duty:cs,on_duty:fleet}', 'normal', 'documents', true, false,
   'A renter asked for the documents a rideshare or delivery platform needs (1303). The portal made them; check the booking if the platform asks us anything.', 58)
on conflict (rule) do nothing;

create function app.rideshare_platform_label(p text) returns text language sql immutable as $$
  select case p when 'uber' then 'Uber' when 'lyft' then 'Lyft' when 'doordash' then 'DoorDash' when 'uber_eats' then 'Uber Eats'
                when 'instacart' then 'Instacart' when 'other' then 'Other' else p end
$$;

create function app.rideshare_docs_open(b bookings) returns boolean language sql stable as $$
  select b.booking_type <> 'owner' and b.status::text in ('pending_payment', 'confirmed', 'on_rent')
$$;

-- the requests and the letters' facts
create function app.rideshare_docs_facts(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  s program_settings := app.settings();
  v vehicles;
  pol fleet_insurance_policies;
  v_card jsonb;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return null; end if;
  select * into v from vehicles where id = b.vehicle_id;
  select * into pol from fleet_insurance_policies where is_current limit 1;
  v_card := app.accident_card(b.id);
  return jsonb_build_object(
    'open', app.rideshare_docs_open(b), 'booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status,
    'pickup_at', b.pickup_at, 'return_at', b.return_at, 'issued_at', now(),
    'company', jsonb_build_object('legal_name', s.company_legal_name, 'trade_name', s.company_trade_name, 'address', s.company_address,
                                  'phone', s.company_phone, 'email', s.company_email),
    'car', jsonb_build_object('year', v.year, 'make', v.make, 'model', v.model, 'colour', v.colour, 'plate', v.plate, 'vin', v.vin),
    'renter', (select r.legal_name from renters r where r.id = b.renter_id),
    'drivers', coalesce((select jsonb_agg(d.full_name order by bd.role <> 'renter', d.full_name) from booking_drivers bd join drivers d on d.id = bd.driver_id where bd.booking_id = b.id), '[]'::jsonb),
    'coverage', v_card -> 'coverage',
    'coverage_card', app.booking_coverage_card(b.id),
    'fleet_policy', case when pol.id is null then null else jsonb_build_object('insurer_name', pol.insurer_name, 'policy_number', pol.policy_number,
                      'effective_on', pol.effective_on, 'expires_on', pol.expires_on, 'named_insured', s.company_legal_name) end,
    'agreement_document_id', app.booking_contract_document(b.id),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'platforms', to_jsonb(q.platforms), 'other_platform', q.other_platform, 'created_at', q.created_at,
                                   'labels', (select jsonb_agg(case when x = 'other' then coalesce(q.other_platform, 'Other') else app.rideshare_platform_label(x) end) from unnest(q.platforms) x))
                                   order by q.created_at desc)
                           from rideshare_doc_requests q where q.booking_id = b.id), '[]'::jsonb));
end $$;

-- the renter asks: p {booking, platforms[], other?}
create function public.server_rideshare_docs_request(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_platforms text[];
  v_other text := nullif(btrim(coalesce(p ->> 'other', '')), '');
  q rideshare_doc_requests;
  v_labels text;
begin
  if p_by is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null or not app.is_booking_renter(b.id, p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  if not app.rideshare_docs_open(b) then raise exception 'Rideshare documents are made for a booked trip (from the offer you accepted until the return)' using errcode = '23514'; end if;
  select coalesce(array_agg(distinct x order by x), '{}') into v_platforms from jsonb_array_elements_text(coalesce(p -> 'platforms', '[]'::jsonb)) x;
  if cardinality(v_platforms) = 0 then raise exception 'Pick at least one platform' using errcode = '22023'; end if;
  if not v_platforms <@ array['uber', 'lyft', 'doordash', 'uber_eats', 'instacart', 'other'] then raise exception 'Pick the platforms from the list' using errcode = '22023'; end if;
  if 'other' = any (v_platforms) then
    if v_other is null or length(v_other) < 2 then raise exception 'Name the other platform' using errcode = '22023'; end if;
  else v_other := null; end if;
  -- the same request twice (a double tap, a reload): one request
  select * into q from rideshare_doc_requests where booking_id = b.id and platforms = v_platforms and other_platform is not distinct from v_other
     and created_at > now() - interval '10 minutes' order by created_at desc limit 1;
  if q.id is not null then return jsonb_build_object('id', q.id, 'again', true); end if;
  insert into rideshare_doc_requests (booking_id, renter_id, platforms, other_platform, requested_by)
  values (b.id, b.renter_id, v_platforms, left(v_other, 80), p_by) returning * into q;
  select string_agg(case when x = 'other' then v_other else app.rideshare_platform_label(x) end, ', ') into v_labels from unnest(v_platforms) x;
  perform app.log_booking_event(b.id, 'rideshare_docs', b.status::text, b.status::text, null,
    format('The renter made the rideshare documents for %s', v_labels), p_by, 'renter', jsonb_build_object('request_id', q.id, 'platforms', to_jsonb(v_platforms)));
  perform app.staff_alert('rideshare_docs_requested', 'booking', b.id, q.id::text,
    left(format('Rideshare documents: %s', app.sa_booking_line(b)), 200),
    left(format('For %s. The portal made the agreement copy, the coverage letter and the vehicle letter; check the booking if the platform asks us anything.', v_labels), 240),
    app.sa_booking_paths(b));
  return jsonb_build_object('id', q.id, 'again', false);
end $$;

create function public.server_rideshare_docs(p_by uuid, p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_by is null or not (app.is_booking_renter(p_booking, p_by) or app.user_is_staff(p_by)) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return app.rideshare_docs_facts(p_booking);
end $$;

-- staff: p {booking: id or number}
create function app.rideshare_docs_staff(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_id uuid;
begin
  if not app.user_is_staff(p_by) then raise exception 'Staff only' using errcode = '42501'; end if;
  select id into v_id from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if v_id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  return app.rideshare_docs_facts(v_id);
end $$;

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['rideshare_docs_facts', 'rideshare_docs_staff']))
        or (n.nspname = 'public' and p.proname = any (array['server_rideshare_docs_request', 'server_rideshare_docs']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
grant execute on function app.rideshare_platform_label(text), app.rideshare_docs_open(bookings) to authenticated, service_role;
