-- 1010_r35rr_deposit_review.sql
-- Release 35 part RR (docs/changes/2026-11-08-r35-deposit-review.md). The owner, November 8: "fleet va needs to check before and
-- after photos of vehicles for damage and then report findings to finance va who double checks it before either billing for
-- damage or releasing deposit. there is a list of stuff they need to check for before releasing deposits: fuel, km, tickets,
-- damage, late return, cleaning. it should be checked by fleet and then checked by finance after." And: "the finance va needs to
-- check manually for 407 charges before releasing deposits and ... check every jurisdiction for parking tickets prior to
-- releasing deposits. smooth workflow for both with links to everything that needs to be visited, on a set schedule, 2-3 times
-- a week."
--
--   1. Program settings: the review on (deposit_review_required), the sweep days (Mon, Wed, Fri), the toll operator's lookup link
--      and the ticket lookup places with their official links (deposit_review_ticket_places, editable by the Admin), and the
--      claim page of the plan sold with a rental (accident_plan_claim_url).
--   2. The review of each returned booking with a deposit (deposit_reviews, made when the booking is returned): seven items
--      (fuel, km, damage, late return, cleaning, tickets, tolls). Fleet signs each first (ok, or an issue with the amount, a
--      note and the return photos it shows), then Finance double-checks each; Finance's tolls item is the toll operator check
--      and its tickets item needs every place checked (deposit_review_ticket_checks: none found, or the ticket, which is logged
--      in Tolls and tickets through 0021's app.log_toll_ticket and matched to the booking there). Each item shows the facts
--      the site already has (the readings of 0910, the return report, the late time, the tolls and tickets on the car).
--   3. The deposit guard of 0155 counts an unfinished review as a blocker: no part of the deposit is released until Fleet and
--      Finance signed every item, unless an Admin releases with the reason (deposit_overrides, audited). Billing stays 0750's
--      charge after the return and 0155's damage charge.
--   4. The sweep: on each sweep day (from 6:00 Toronto) one Finance To do lists every plate returned since the last sweep and
--      every booking still inside the toll and ticket window, with a digest line; the page lists them with the links.
--   5. Finance countdowns on every booking: the deposit hold's authorization expiry (and when the automatic re-authorization
--      of 0750 runs, 24 hours before), the deposit return promised to the renter (deposits.release_due_on: 7 business days after
--      the return, deposit_release_business_days of the rental terms; with no check-in recorded, deposit_release_reminder_days
--      after the return), and the renter's next rental payment on a weekly, biweekly or monthly plan (0330), overdue once
--      passed. Alerts to Finance at 48 and 24 hours (0462's staff alerts: normal tier, so the quiet hours, the dedupe and the
--      burst merge apply) and lines in the Finance morning digest.
--   6. Finance staff opt in to Sales as field staff do (0931): the Sales path, then the Sales function.
--   7. The accident card of a booking with the plan sold with the rental: the renter's own plan policy number (entered by staff
--      on the booking when it was not captured at purchase) and the provider's claim page, never a CarmaCars policy.
-- No applied migration is edited.
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

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '1010: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists deposit_review_required boolean not null default true,
  add column if not exists deposit_review_sweep_days text not null default 'mon,wed,fri'
    check (deposit_review_sweep_days ~ '^(mon|tue|wed|thu|fri|sat|sun)(,(mon|tue|wed|thu|fri|sat|sun))*$'),
  add column if not exists deposit_review_toll_url text not null default 'https://www.407etr.com/'
    check (deposit_review_toll_url ~ '^https://'),
  add column if not exists deposit_review_ticket_places jsonb not null default '[
    {"key": "toronto", "name": "Toronto", "url": "https://www.toronto.ca/services-payments/tickets-fines-penalties/parking-violations/pay-your-parking-violation/"},
    {"key": "mississauga", "name": "Mississauga", "url": "https://www.mississauga.ca/?p=111330"},
    {"key": "brampton", "name": "Brampton", "url": "https://www.brampton.ca/EN/residents/Parking/Pages/Parking-Ticket-Payment-FAQ.aspx"},
    {"key": "vaughan", "name": "Vaughan", "url": "https://www.vaughan.ca/"},
    {"key": "markham", "name": "Markham", "url": "https://www.markham.ca/permits-licences-taxes/parking/pay-parking-ticket"},
    {"key": "richmond_hill", "name": "Richmond Hill", "url": "https://www.richmondhill.ca/"},
    {"key": "oakville", "name": "Oakville", "url": "https://www.oakville.ca/"},
    {"key": "burlington", "name": "Burlington", "url": "https://www.burlington.ca/"},
    {"key": "hamilton", "name": "Hamilton", "url": "https://www.hamilton.ca/"},
    {"key": "pickering", "name": "Durham Region: Pickering", "url": "https://www.pickering.ca/"},
    {"key": "ajax", "name": "Durham Region: Ajax", "url": "https://www.ajax.ca/"},
    {"key": "whitby", "name": "Durham Region: Whitby", "url": "https://www.whitby.ca/"},
    {"key": "oshawa", "name": "Durham Region: Oshawa", "url": "https://www.oshawa.ca/"},
    {"key": "barrie", "name": "Barrie", "url": "https://www.barrie.ca/"},
    {"key": "peel_cameras", "name": "Peel Region cameras (speed and red light)", "url": "https://www.peelregion.ca/"},
    {"key": "york_cameras", "name": "York Region cameras (speed and red light)", "url": "https://www.york.ca/"},
    {"key": "ontario_cameras", "name": "Ontario cameras (speed and red light, provincial)", "url": "https://www.ontario.ca/page/check-status-traffic-tickets-and-fines-online-or-request-meeting-resolve-your-case"}
  ]'::jsonb check (jsonb_typeof(deposit_review_ticket_places) = 'array'),
  add column if not exists accident_plan_claim_url text default 'https://www.rentalcover.com/en-us/claim/start';
comment on column program_settings.deposit_review_required is 'Deposit review (1010): each returned booking with a deposit gets the two-step review (Fleet, then Finance); no part of the deposit is released before both signed every item, unless an Admin gives the reason.';
comment on column program_settings.deposit_review_sweep_days is 'Deposit review (1010): the days of the Finance sweep To do, comma separated (mon,wed,fri).';
comment on column program_settings.deposit_review_toll_url is 'Deposit review (1010): where Finance checks the toll highway charges of a plate before a deposit is released.';
comment on column program_settings.deposit_review_ticket_places is 'Deposit review (1010): the places Finance checks for tickets before a deposit is released, each {key, name, url} with its official lookup link. A new place applies to the reviews made after the change.';
comment on column program_settings.accident_plan_claim_url is 'Accident card (1010): the claim page of the plan sold with a rental, shown instead of any CarmaCars policy.';

alter table bookings add column if not exists plan_policy_number text check (plan_policy_number is null or length(plan_policy_number) between 3 and 80);
comment on column bookings.plan_policy_number is 'The renter''s own policy number of the plan sold with this rental (1010), entered by staff when it was not captured at purchase; printed on the accident card.';

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('deposit_review_fleet', 'fleet', 'Check a returned car before its deposit is released', 'high', 'business_days', 1,
   'Compare the pickup and return photos angle by angle and sign each item: fuel, km, damage, late return, cleaning, tickets, tolls (1010).'),
  ('deposit_review_finance', 'finance', 'Double-check a deposit review', 'high', 'business_days', 1,
   'Fleet signed every item. Double-check each, check the toll operator and every ticket place, then bill or release the deposit (1010).'),
  ('deposit_review_sweep', 'finance', 'Deposit check sweep', 'high', 'business_days', 1,
   'Every plate returned since the last sweep and every booking still inside the toll and ticket window: check the toll operator and each ticket place (1010).')
on conflict (task_type) do nothing;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('finance_hold_expiring', 'Deposit hold expires within 48 hours', 'Money', '{admin,on_duty:finance}', 'normal', 'payments', true, false,
   'At 48 and 24 hours before the deposit hold''s authorization expires (1010). The automatic re-authorization runs 24 hours before.', 46),
  ('finance_deposit_return_due', 'Deposit return due within 48 hours', 'Money', '{admin,on_duty:finance}', 'normal', 'payments', true, false,
   'At 48 and 24 hours before the deposit return promised to the renter (1010).', 47),
  ('finance_payment_due', 'Rental payment due within 48 hours, or overdue', 'Money', '{admin,on_duty:finance}', 'normal', 'payments', true, false,
   'At 48 and 24 hours before the renter''s next payment on a weekly, biweekly or monthly plan, and once it is overdue (1010).', 48)
on conflict (rule) do nothing;

-- ================================================================ 2. the review of each returned booking
create table deposit_reviews (
  booking_id      uuid primary key references bookings (id) on delete cascade,
  vehicle_id      uuid not null references vehicles (id),
  plate           text,
  returned_at     timestamptz,
  places          jsonb not null default '[]'::jsonb check (jsonb_typeof(places) = 'array'),
  fleet_done_at   timestamptz,
  finance_done_at timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
comment on table deposit_reviews is 'The two-step review of a returned booking before its deposit is released (1010): Fleet signs every item, then Finance. places: the ticket lookup places of Program settings when the review was made.';
create trigger deposit_reviews_updated before update on deposit_reviews for each row execute function app.set_updated_at();
create index deposit_reviews_open on deposit_reviews (returned_at) where finance_done_at is null;

create table deposit_review_items (
  id                   uuid primary key default gen_random_uuid(),
  booking_id           uuid not null references deposit_reviews (booking_id) on delete cascade,
  item                 text not null check (item in ('fuel', 'km', 'damage', 'late', 'cleaning', 'tickets', 'tolls')),
  fleet_result         text check (fleet_result in ('ok', 'issue')),
  fleet_amount_cents   bigint check (fleet_amount_cents >= 0),
  fleet_note           text,
  fleet_photos         integer[] not null default '{}',
  fleet_by             uuid references users (id),
  fleet_at             timestamptz,
  finance_result       text check (finance_result in ('ok', 'issue')),
  finance_amount_cents bigint check (finance_amount_cents >= 0),
  finance_note         text,
  finance_by           uuid references users (id),
  finance_at           timestamptz,
  unique (booking_id, item),
  check (fleet_result is distinct from 'issue' or fleet_note is not null),
  check (finance_result is distinct from 'issue' or finance_note is not null),
  check (finance_result is null or fleet_result is not null)
);
comment on table deposit_review_items is 'One item of a deposit review (1010): Fleet''s check first (ok, or an issue with the amount, a note and the return photo numbers), then Finance''s. Finance''s tolls item is the toll operator check.';

create table deposit_review_ticket_checks (
  id             uuid primary key default gen_random_uuid(),
  booking_id     uuid not null references deposit_reviews (booking_id) on delete cascade,
  place_key      text not null,
  place_name     text not null,
  url            text,
  result         text not null check (result in ('none_found', 'ticket')),
  toll_ticket_id uuid references toll_tickets (id),
  note           text,
  checked_by     uuid not null references users (id),
  checked_at     timestamptz not null default now(),
  unique (booking_id, place_key),
  check (result = 'none_found' or toll_ticket_id is not null)
);
comment on table deposit_review_ticket_checks is 'Finance''s ticket check of one place for one returned booking (1010): none found, or the ticket (logged in Tolls and tickets).';

create table deposit_review_sweeps (
  id         uuid primary key default gen_random_uuid(),
  run_on     date not null unique,
  since      timestamptz,
  task_id    uuid,
  plates     jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);
comment on table deposit_review_sweeps is 'Each Finance deposit check sweep (1010): the day, the returns since the previous sweep and the bookings still inside the toll and ticket window, by plate.';

do $$
declare t text;
begin
  foreach t in array array['deposit_reviews', 'deposit_review_items', 'deposit_review_ticket_checks', 'deposit_review_sweeps'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('create trigger audit_%s after insert or update or delete on %I for each row execute function app.audit_row()', t, t);
  end loop;
end $$;

create or replace function app.drr_items() returns text[]
language sql immutable as $$ select array['fuel', 'km', 'damage', 'late', 'cleaning', 'tickets', 'tolls'] $$;

create or replace function app.drr_item_label(p text) returns text
language sql immutable as $$
  select case p when 'fuel' then 'Fuel' when 'km' then 'Kilometres' when 'damage' then 'Damage' when 'late' then 'Late return'
                when 'cleaning' then 'Cleaning' when 'tickets' then 'Tickets' when 'tolls' then 'Highway tolls' else p end
$$;

-- a review for a returned booking with a deposit (never an Owner Booking or a placeholder)
create or replace function app.drr_ensure(p_booking uuid) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v vehicles;
  s program_settings := app.settings();
begin
  if not coalesce(s.deposit_review_required, false) then return false; end if;
  select * into b from bookings where id = p_booking;
  if b.id is null or b.booking_type = 'owner' or coalesce(b.is_placeholder, false) or coalesce(b.deposit_cents, 0) <= 0
     or b.status::text not in ('returned', 'closed') then return false; end if;
  if exists (select 1 from deposit_reviews r where r.booking_id = b.id) then return false; end if;
  select * into v from vehicles where id = b.vehicle_id;
  insert into deposit_reviews (booking_id, vehicle_id, plate, returned_at, places)
  values (b.id, b.vehicle_id, v.plate, coalesce(b.checked_in_at, b.return_at), coalesce(s.deposit_review_ticket_places, '[]'::jsonb));
  insert into deposit_review_items (booking_id, item) select b.id, x from unnest(app.drr_items()) x;
  perform app.raise_task(p_type => 'deposit_review_fleet', p_queue => 'fleet',
    p_title => left(format('%s (%s): check the return before the deposit is released', b.booking_number, coalesce(v.plate, app.vehicle_name(v.id))), 200),
    p_detail => 'Compare the pickup and return photos angle by angle, then sign fuel, km, damage, late return, cleaning, tickets and tolls. Finance double-checks after you.',
    p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_dedupe => 'deposit_review_fleet:' || b.id);
  return true;
end $$;

create or replace function app.drr_after_return() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status::text <> 'returned' then return null; end if;
  if tg_op = 'UPDATE' then
    if old.status = new.status then return null; end if;
  end if;
  begin
    perform app.drr_ensure(new.id);
  exception when others then
    raise warning 'deposit review: %', sqlerrm;   -- a review never stops a return
  end;
  return null;
end $$;
create trigger bookings_deposit_review after insert or update of status on bookings for each row execute function app.drr_after_return();

-- the counts: what is signed, what is left
create or replace function app.drr_state(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when r.booking_id is null then null else jsonb_build_object(
    'items', cardinality(app.drr_items()),
    'fleet_signed', (select count(*) from deposit_review_items i where i.booking_id = r.booking_id and i.fleet_result is not null),
    'finance_signed', (select count(*) from deposit_review_items i where i.booking_id = r.booking_id and i.finance_result is not null),
    'issues', (select count(*) from deposit_review_items i where i.booking_id = r.booking_id and 'issue' in (i.fleet_result, i.finance_result)),
    'places', jsonb_array_length(r.places),
    'places_checked', (select count(*) from deposit_review_ticket_checks c where c.booking_id = r.booking_id),
    'tickets_found', (select count(*) from deposit_review_ticket_checks c where c.booking_id = r.booking_id and c.result = 'ticket'),
    'fleet_done_at', r.fleet_done_at, 'finance_done_at', r.finance_done_at,
    'stage', case when r.finance_done_at is not null then 'done' when r.fleet_done_at is not null then 'finance' else 'fleet' end) end
    from (select 1) one left join deposit_reviews r on r.booking_id = p_booking
$$;

-- what the site already knows for each item, and the suggested result
create or replace function app.drr_facts(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  rd jsonb;
  v_from timestamptz;
  v_to timestamptz;
  v_late integer;
  v_clean text;
  v_damage jsonb;
  v_tickets jsonb;
  v_tolls jsonb;
  v_lines jsonb;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return '{}'::jsonb; end if;
  rd := app.handover_readings_view(p_booking);
  v_from := coalesce(b.handed_over_at, b.pickup_at);
  v_to := coalesce(b.checked_in_at, b.return_at);
  v_late := case when b.checked_in_at is not null and b.checked_in_at > b.return_at then floor(extract(epoch from b.checked_in_at - b.return_at) / 60)::integer else 0 end;
  select cr.cleanliness into v_clean from condition_reports cr where cr.booking_id = b.id and cr.kind = 'return' order by cr.performed_at desc limit 1;
  select coalesce(jsonb_agg(format('%s %s: %s', dm.label, dm.location, dm.description) order by dm.label), '[]'::jsonb) into v_damage
    from condition_report_damages dm join condition_reports cr on cr.id = dm.condition_report_id
   where cr.booking_id = b.id and cr.kind = 'return' and dm.is_new;
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'kind', t.kind, 'authority', t.authority, 'at', t.occurred_at, 'amount_cents', t.amount_cents, 'status', t.status) order by t.occurred_at), '[]'::jsonb)
    into v_tickets from toll_tickets t
   where t.kind <> 'toll_invoice' and (t.booking_id = b.id or (t.vehicle_id = b.vehicle_id and t.occurred_at between v_from and v_to));
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'authority', t.authority, 'at', t.occurred_at, 'amount_cents', t.amount_cents, 'status', t.status) order by t.occurred_at), '[]'::jsonb)
    into v_tolls from toll_tickets t
   where t.kind = 'toll_invoice' and (t.booking_id = b.id or (t.vehicle_id = b.vehicle_id and t.occurred_at between v_from and v_to));
  select coalesce(jsonb_object_agg(x.k, x.cents), '{}'::jsonb) into v_lines from (
    select case when li.assessment_key in ('fuel', 'recharging', 'fuel_service_fee') then 'fuel' when li.assessment_key = 'mileage_overage' then 'km'
                when li.charge_type ilike '%late%' or li.assessment_key ilike '%late%' then 'late' when li.charge_type ilike '%clean%' or li.assessment_key ilike '%clean%' then 'cleaning'
                when li.charge_type ilike 'damage%' or li.charge_type in ('deductible', 'loss_of_use') then 'damage' end as k,
           sum(li.amount_cents + li.hst_cents) as cents
      from booking_line_items li where li.booking_id = b.id and li.voided_at is null and li.amount_cents > 0 and li.stage in ('check_in', 'after_return')
     group by 1) x where x.k is not null;
  return jsonb_build_object(
    'fuel', jsonb_build_object('out_pct', rd -> 'fuel_out_pct', 'in_pct', rd -> 'fuel_in_pct', 'eighths_short', rd -> 'fuel_eighths_short', 'charged_cents', coalesce(v_lines -> 'fuel', '0'::jsonb),
                               'suggest', case when coalesce((rd ->> 'fuel_eighths_short')::integer, 0) > 0 then 'issue' else 'ok' end),
    'km', jsonb_build_object('out', rd -> 'km_out', 'in', rd -> 'km_in', 'driven', rd -> 'km_driven', 'allowance', rd -> 'km_allowance', 'over', rd -> 'km_over', 'charged_cents', coalesce(v_lines -> 'km', '0'::jsonb),
                             'suggest', case when coalesce((rd ->> 'km_over')::integer, 0) > 0 then 'issue' else 'ok' end),
    'damage', jsonb_build_object('new', v_damage, 'charged_cents', coalesce(v_lines -> 'damage', '0'::jsonb), 'suggest', case when jsonb_array_length(v_damage) > 0 then 'issue' else 'ok' end),
    'late', jsonb_build_object('minutes', v_late, 'due', b.return_at, 'back', b.checked_in_at, 'charged_cents', coalesce(v_lines -> 'late', '0'::jsonb), 'suggest', case when v_late > 0 then 'issue' else 'ok' end),
    'cleaning', jsonb_build_object('at_return', v_clean, 'charged_cents', coalesce(v_lines -> 'cleaning', '0'::jsonb), 'suggest', case when v_clean is not null and v_clean <> 'clean' then 'issue' else 'ok' end),
    'tickets', jsonb_build_object('on_car', v_tickets, 'suggest', case when jsonb_array_length(v_tickets) > 0 then 'issue' else 'ok' end),
    'tolls', jsonb_build_object('on_car', v_tolls, 'suggest', case when jsonb_array_length(v_tolls) > 0 then 'issue' else 'ok' end));
end $$;

create or replace function app.drr_booking(p jsonb) returns bookings
language sql stable security definer set search_path = public, app as $$
  select * from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) limit 1
$$;

-- p: booking, side (fleet | finance), item, result (ok | issue), amount_cents, note, photos (return photo numbers, "3, 7")
create or replace function app.drr_sign(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings := app.drr_booking(p);
  r deposit_reviews;
  it deposit_review_items;
  v_side text := coalesce(p ->> 'side', '');
  v_item text := coalesce(p ->> 'item', '');
  v_result text := coalesce(p ->> 'result', '');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_photos integer[] := '{}';
  v_admin boolean := app.user_is_admin(p_user);
  v_state jsonb;
begin
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  select * into r from deposit_reviews where booking_id = b.id for update;
  if r.booking_id is null then raise exception 'This booking has no deposit review' using errcode = 'P0002'; end if;
  if v_side not in ('fleet', 'finance') then raise exception 'Say whose check this is: Fleet or Finance' using errcode = '22023'; end if;
  if v_side = 'fleet' and not (v_admin or app.user_va_has(p_user, 'fleet')) then raise exception 'Fleet or an Admin signs the Fleet check' using errcode = '42501'; end if;
  if v_side = 'finance' and not app.user_runs_finance(p_user) then raise exception 'Finance or an Admin signs the Finance check' using errcode = '42501'; end if;
  if not v_item = any (app.drr_items()) then raise exception 'Choose an item of the review' using errcode = '22023'; end if;
  if v_result not in ('ok', 'issue') then raise exception 'Choose OK or Issue' using errcode = '22023'; end if;
  if v_result = 'issue' and (v_note is null or length(v_note) < 3) then raise exception 'Say what the issue is' using errcode = '22023'; end if;
  if v_amount is not null and v_amount < 0 then raise exception 'The amount cannot be negative' using errcode = '22023'; end if;
  if coalesce(btrim(p ->> 'photos'), '') <> '' then
    if btrim(p ->> 'photos') !~ '^\d+(\s*,\s*\d+)*$' then raise exception 'Photos: the photo numbers of the return report, for example 3, 7' using errcode = '22023'; end if;
    select array_agg(distinct x::integer order by x::integer) into v_photos from regexp_split_to_table(btrim(p ->> 'photos'), '\s*,\s*') x;
    if exists (select 1 from unnest(v_photos) n where not exists (
                 select 1 from condition_report_photos ph join condition_reports cr on cr.id = ph.condition_report_id
                  where cr.booking_id = b.id and cr.kind = 'return' and ph.seq = n)) then
      raise exception 'A photo number is not on the return report' using errcode = '22023';
    end if;
  end if;
  select * into it from deposit_review_items where booking_id = b.id and item = v_item for update;
  if v_side = 'fleet' then
    if it.finance_result is not null then raise exception 'Finance already checked this item: ask Finance to change it' using errcode = '23514'; end if;
    update deposit_review_items set fleet_result = v_result, fleet_amount_cents = case when v_result = 'issue' then v_amount end, fleet_note = v_note,
           fleet_photos = coalesce(v_photos, '{}'), fleet_by = p_user, fleet_at = now()
     where id = it.id;
  else
    if it.fleet_result is null then raise exception 'Fleet checks this item first' using errcode = '23514'; end if;
    if not v_admin and it.fleet_by = p_user then raise exception 'Someone else double-checks your own Fleet check' using errcode = '23514'; end if;
    if v_item = 'tickets' and (select count(*) from deposit_review_ticket_checks c where c.booking_id = b.id) < jsonb_array_length(r.places) then
      raise exception 'Check every ticket place first (% of %)', (select count(*) from deposit_review_ticket_checks c where c.booking_id = b.id), jsonb_array_length(r.places) using errcode = '23514';
    end if;
    update deposit_review_items set finance_result = v_result, finance_amount_cents = case when v_result = 'issue' then v_amount end, finance_note = v_note,
           finance_by = p_user, finance_at = now()
     where id = it.id;
  end if;
  -- done for a side once every item is signed
  if r.fleet_done_at is null and not exists (select 1 from deposit_review_items i where i.booking_id = b.id and i.fleet_result is null) then
    update deposit_reviews set fleet_done_at = now() where booking_id = b.id;
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
      format('Fleet finished the deposit review: %s', coalesce((select string_agg(app.drr_item_label(i.item) || ' (' || i.fleet_note || ')', '; ' order by array_position(app.drr_items(), i.item))
                                                                from deposit_review_items i where i.booking_id = b.id and i.fleet_result = 'issue'), 'no issue')), p_user, 'staff',
      jsonb_build_object('deposit_review', 'fleet'));
    perform app.resolve_tasks(array['deposit_review_fleet'], b.id, p_user, 'Fleet signed every item');
    perform app.raise_task(p_type => 'deposit_review_finance', p_queue => 'finance',
      p_title => left(format('%s (%s): double-check the deposit review', b.booking_number, coalesce(r.plate, '')), 200),
      p_detail => 'Fleet signed every item. Double-check each, check the toll operator and every ticket place, then bill what is owed or release the deposit.',
      p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_dedupe => 'deposit_review_finance:' || b.id);
  end if;
  select * into r from deposit_reviews where booking_id = b.id;
  if r.fleet_done_at is not null and r.finance_done_at is null and not exists (select 1 from deposit_review_items i where i.booking_id = b.id and i.finance_result is null) then
    update deposit_reviews set finance_done_at = now() where booking_id = b.id;
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
      format('Finance finished the deposit review: %s', coalesce((select string_agg(app.drr_item_label(i.item) || ' (' || i.finance_note || ')', '; ' order by array_position(app.drr_items(), i.item))
                                                                  from deposit_review_items i where i.booking_id = b.id and i.finance_result = 'issue'), 'no issue')), p_user, 'staff',
      jsonb_build_object('deposit_review', 'finance'));
    perform app.resolve_tasks(array['deposit_review_finance'], b.id, p_user, 'Finance signed every item');
  end if;
  v_state := app.drr_state(b.id);
  return v_state || jsonb_build_object('item', v_item, 'side', v_side, 'result', v_result);
end $$;

-- p: booking, place (its key), result (none_found | ticket), and for a ticket: kind, amount_cents, occurred_at, notice_number, note
create or replace function app.drr_ticket_check(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings := app.drr_booking(p);
  r deposit_reviews;
  pl jsonb;
  c deposit_review_ticket_checks;
  v_result text := coalesce(p ->> 'result', '');
  v_toll uuid;
  v_kind text := coalesce(nullif(p ->> 'kind', ''), 'parking');
begin
  if not app.user_runs_finance(p_user) then raise exception 'Finance or an Admin checks the ticket places' using errcode = '42501'; end if;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  select * into r from deposit_reviews where booking_id = b.id for update;
  if r.booking_id is null then raise exception 'This booking has no deposit review' using errcode = 'P0002'; end if;
  select x into pl from jsonb_array_elements(r.places) x where x ->> 'key' = p ->> 'place';
  if pl is null then raise exception 'Choose a place of the review' using errcode = '22023'; end if;
  if v_result not in ('none_found', 'ticket') then raise exception 'Choose None found or A ticket' using errcode = '22023'; end if;
  select * into c from deposit_review_ticket_checks where booking_id = b.id and place_key = pl ->> 'key';
  if c.id is not null and c.result = 'ticket' then raise exception 'A ticket is already recorded for this place: change it in Tolls and tickets' using errcode = '23514'; end if;
  if v_result = 'ticket' then
    if v_kind not in ('parking', 'ticket', 'camera_offence', 'fine', 'tow', 'impound') then raise exception 'Choose the kind of ticket' using errcode = '22023'; end if;
    if nullif(p ->> 'amount_cents', '') is null or nullif(p ->> 'occurred_at', '') is null then raise exception 'Enter the amount and when it happened' using errcode = '22023'; end if;
    v_toll := app.log_toll_ticket(jsonb_strip_nulls(jsonb_build_object('kind', v_kind, 'authority', pl ->> 'name', 'notice_number', nullif(btrim(coalesce(p ->> 'notice_number', '')), ''),
      'plate', r.plate, 'occurred_at', p ->> 'occurred_at', 'amount_cents', (p ->> 'amount_cents')::bigint, 'received_on', app.local_date(now()),
      'note', concat_ws('. ', 'Found on the deposit review of ' || b.booking_number, nullif(btrim(coalesce(p ->> 'note', '')), '')))), p_user);
  end if;
  insert into deposit_review_ticket_checks (booking_id, place_key, place_name, url, result, toll_ticket_id, note, checked_by)
  values (b.id, pl ->> 'key', pl ->> 'name', pl ->> 'url', v_result, v_toll, nullif(btrim(coalesce(p ->> 'note', '')), ''), p_user)
  on conflict (booking_id, place_key) do update set result = excluded.result, toll_ticket_id = excluded.toll_ticket_id, note = excluded.note,
     checked_by = excluded.checked_by, checked_at = now();
  return app.drr_state(b.id) || jsonb_build_object('place', pl ->> 'key', 'result', v_result, 'toll_ticket_id', v_toll);
end $$;

-- ================================================================ 3. the deposit guard counts an unfinished review
alter function app.deposit_blockers(uuid) rename to deposit_blockers_pre1010;
create function app.deposit_blockers(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.deposit_blockers_pre1010(p_booking)
    || coalesce((select jsonb_build_array(jsonb_build_object('kind', 'review', 'label',
         case when r.fleet_done_at is null
              then format('The deposit review is not finished: Fleet checked %s of %s items', (st ->> 'fleet_signed'), (st ->> 'items'))
              else format('The deposit review is not finished: Finance checked %s of %s items and %s of %s ticket places',
                          (st ->> 'finance_signed'), (st ->> 'items'), (st ->> 'places_checked'), (st ->> 'places')) end))
       from deposit_reviews r cross join lateral (select app.drr_state(r.booking_id) st) x
      where r.booking_id = p_booking and r.finance_done_at is null and coalesce((app.settings()).deposit_review_required, false)), '[]'::jsonb)
$$;
select pg_temp.copy_grants('app.deposit_blockers(uuid)'::regprocedure, 'app.deposit_blockers_pre1010(uuid)'::regprocedure);

-- ================================================================ 5. the countdowns
create or replace function app.drr_level(p_at timestamptz, p_now timestamptz) returns text
language sql immutable as $$
  select case when p_at is null then null when p_at <= p_now + interval '24 hours' then 'red' when p_at <= p_now + interval '48 hours' then 'amber' else 'ok' end
$$;

create or replace function app.drr_countdowns(p_now timestamptz default now(), p_booking uuid default null)
returns table (booking_id uuid, booking_number text, status text, plate text, vehicle text, renter text,
               hold_expires_at timestamptz, reauth_at timestamptz, hold_cents bigint,
               return_due_at timestamptz, return_due_on date,
               pay_due_at timestamptz, pay_state text, pay_cents bigint, pay_plan text,
               soonest_at timestamptz)
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  x record;
  ps jsonb;
begin
  for x in
    select b.id, b.booking_number, b.status::text as status, v.plate, app.vehicle_name(v.id) as vehicle, rn.legal_name as renter,
           b.checked_in_at, b.return_at, b.pay_every,
           d.status as d_status, d.method as d_method, d.hold_expires_at, d.release_due_on, d.released_at,
           greatest(coalesce(d.amount_cents - d.applied_cents - d.released_cents, 0), 0) as d_left
      from bookings b join vehicles v on v.id = b.vehicle_id left join renters rn on rn.id = b.renter_id left join deposits d on d.booking_id = b.id
     where b.status::text in ('confirmed', 'on_rent', 'returned', 'closed') and b.booking_type <> 'owner' and not coalesce(b.is_placeholder, false)
       and (p_booking is null or b.id = p_booking)
       and ((d.method = 'card_hold' and d.status = 'held' and d.hold_expires_at is not null)
            or (b.status::text in ('returned', 'closed') and d.id is not null and d.status in ('held', 'captured') and d.released_at is null)
            or (b.status::text in ('confirmed', 'on_rent', 'returned') and (b.pay_every in ('weekly', 'biweekly', 'monthly')
                 or (b.pay_every is null and exists (select 1 from booking_periods bp where bp.booking_id = b.id and bp.status <> 'cancelled')))))
  loop
    booking_id := x.id; booking_number := x.booking_number; status := x.status; plate := x.plate; vehicle := x.vehicle; renter := x.renter;
    hold_expires_at := case when x.d_method = 'card_hold' and x.d_status = 'held' then x.hold_expires_at end;
    reauth_at := hold_expires_at - interval '24 hours';
    hold_cents := case when hold_expires_at is not null then x.d_left end;
    return_due_on := case when x.status in ('returned', 'closed') and x.d_status in ('held', 'captured') and x.released_at is null
                          then coalesce(x.release_due_on, app.add_business_days(app.local_date(coalesce(x.checked_in_at, x.return_at)), s.deposit_release_reminder_days)) end;
    return_due_at := case when return_due_on is not null then ((return_due_on + 1)::timestamp at time zone 'America/Toronto') - interval '1 minute' end;
    pay_due_at := null; pay_state := null; pay_cents := null; pay_plan := null;
    if x.status in ('confirmed', 'on_rent', 'returned') then
      ps := app.booking_pay_schedule(x.id, p_now);
      if ps ->> 'plan' in ('weekly', 'biweekly', 'monthly') and ps ->> 'state' in ('overdue', 'soon', 'upcoming') and ps -> 'next' is not null then
        pay_plan := ps ->> 'plan'; pay_state := ps ->> 'state';
        pay_due_at := case when ps ->> 'state' = 'overdue'
                           then (select min((y ->> 'due_at')::timestamptz) from jsonb_array_elements(ps -> 'schedule') y
                                  where (y ->> 'through_cents')::bigint > (ps ->> 'paid_cents')::bigint)
                           else (ps #>> '{next,due_at}')::timestamptz end;
        pay_cents := (ps #>> '{next,cents}')::bigint;
      end if;
    end if;
    soonest_at := least(hold_expires_at, return_due_at, pay_due_at);
    if soonest_at is not null then return next; end if;
  end loop;
end $$;

-- p: sort (soonest | hold | return | payment), booking (one booking only)
create or replace function app.drr_countdowns_view(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_sort text := coalesce(nullif(p ->> 'sort', ''), 'soonest');
  v_b uuid := (app.drr_booking(p)).id;
  v_now timestamptz := now();
begin
  if not app.user_runs_finance(p_user) then raise exception 'Finance or an Admin sees the countdowns' using errcode = '42501'; end if;
  if v_sort not in ('soonest', 'hold', 'return', 'payment') then v_sort := 'soonest'; end if;
  return jsonb_build_object('now', v_now, 'sort', v_sort, 'rows', coalesce((
    select jsonb_agg(to_jsonb(c) || jsonb_build_object(
             'hold_level', app.drr_level(c.hold_expires_at, v_now), 'return_level', app.drr_level(c.return_due_at, v_now),
             'pay_level', case when c.pay_state = 'overdue' then 'red' else app.drr_level(c.pay_due_at, v_now) end,
             'level', case when c.pay_state = 'overdue' then 'red' else app.drr_level(c.soonest_at, v_now) end,
             'reauth_running', c.reauth_at is not null and c.reauth_at <= v_now)
           order by case v_sort when 'hold' then c.hold_expires_at when 'return' then c.return_due_at when 'payment' then c.pay_due_at else c.soonest_at end nulls last, c.booking_number)
      from app.drr_countdowns(v_now, case when p ? 'booking' then coalesce(v_b, '00000000-0000-0000-0000-000000000000'::uuid) end) c), '[]'::jsonb));
end $$;

-- every quarter-hour: the 48 and 24 hour alerts; once a day the morning digest lines
create or replace function app.drr_alerts(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  c record;
  n integer := 0;
  v_day text := to_char(app.local_date(p_now), 'YYYY-MM-DD');
  v_holds integer; v_returns integer; v_pays integer; v_over integer;
  v_base text := rtrim(coalesce((app.settings()).notify_base_url, ''), '/');
  v_path text;
begin
  for c in select * from app.drr_countdowns(p_now) loop
    v_path := '/bookings/' || c.booking_number || '?tab=money';
    if c.hold_expires_at > p_now and c.hold_expires_at <= p_now + interval '48 hours' then
      perform app.staff_alert('finance_hold_expiring', 'booking', c.booking_id,
        'hold:' || case when c.hold_expires_at <= p_now + interval '24 hours' then '24' else '48' end || ':' || extract(epoch from c.hold_expires_at)::bigint,
        format('Deposit hold expires in %s hours: %s', ceil(extract(epoch from c.hold_expires_at - p_now) / 3600)::integer, c.booking_number),
        format('%s, %s. The hold of %s expires %s; the automatic re-authorization runs from %s.', coalesce(c.plate, c.vehicle), coalesce(c.renter, 'renter'),
               app.fmt_money(coalesce(c.hold_cents, 0)), app.fmt_at(c.hold_expires_at), app.fmt_at(c.reauth_at)),
        jsonb_build_object('path_admin', '/admin' || v_path, 'path_staff', '/staff' || v_path));
      n := n + 1;
    end if;
    if c.return_due_at > p_now and c.return_due_at <= p_now + interval '48 hours' then
      perform app.staff_alert('finance_deposit_return_due', 'booking', c.booking_id,
        'return:' || case when c.return_due_at <= p_now + interval '24 hours' then '24' else '48' end || ':' || c.return_due_on,
        format('Deposit return due %s: %s', to_char(c.return_due_on, 'FMMonth FMDD'), c.booking_number),
        format('%s, %s. The deposit return promised to the renter is due by the end of %s. Finish the deposit review, then bill or release.',
               coalesce(c.plate, c.vehicle), coalesce(c.renter, 'renter'), to_char(c.return_due_on, 'FMDay, FMMonth FMDD')),
        jsonb_build_object('path_admin', '/admin/bookings/' || c.booking_number || '/deposit-review', 'path_staff', '/staff/bookings/' || c.booking_number || '/deposit-review'));
      n := n + 1;
    end if;
    if c.pay_due_at is not null and (c.pay_state = 'overdue' or c.pay_due_at <= p_now + interval '48 hours') then
      perform app.staff_alert('finance_payment_due', 'booking', c.booking_id,
        'pay:' || case when c.pay_due_at <= p_now then 'overdue' when c.pay_due_at <= p_now + interval '24 hours' then '24' else '48' end || ':' || extract(epoch from c.pay_due_at)::bigint,
        case when c.pay_due_at <= p_now then format('Rental payment overdue: %s', c.booking_number)
             else format('Rental payment due in %s hours: %s', ceil(extract(epoch from c.pay_due_at - p_now) / 3600)::integer, c.booking_number) end,
        format('%s, %s. %s of the %s plan, due %s.', coalesce(c.plate, c.vehicle), coalesce(c.renter, 'renter'), app.fmt_money(coalesce(c.pay_cents, 0)), c.pay_plan, app.fmt_at(c.pay_due_at)),
        jsonb_build_object('path_admin', '/admin' || v_path, 'path_staff', '/staff' || v_path));
      n := n + 1;
    end if;
  end loop;
  -- the morning digest: one line each, from 5:00 Toronto
  if extract(hour from p_now at time zone 'America/Toronto') >= 5 then
    select count(*) filter (where cc.hold_expires_at > p_now and cc.hold_expires_at <= p_now + interval '48 hours'),
           count(*) filter (where cc.return_due_at <= p_now + interval '48 hours'),
           count(*) filter (where cc.pay_due_at > p_now and cc.pay_due_at <= p_now + interval '48 hours'),
           count(*) filter (where cc.pay_state = 'overdue')
      into v_holds, v_returns, v_pays, v_over from app.drr_countdowns(p_now) cc;
    insert into staff_digest_items (role, code, digest_slot, line, meta, url, dedupe_key)
    select ro.role, 'staff_expiry_watch', 'morning', l.line, l.meta, v_base || ro.base || '/money?tab=countdowns', 'drr:' || l.k || ':' || ro.role || ':' || v_day
      from (values ('admin', '/admin'), ('va_finance', '/staff')) ro(role, base)
     cross join (values
       ('holds', v_holds, format('%s deposit %s within 48 hours', v_holds, case when v_holds = 1 then 'hold expires' else 'holds expire' end), 'Re-authorized automatically 24 hours before; check the card on file'),
       ('returns', v_returns, format('%s deposit %s due back to the renter within 48 hours or late', v_returns, case when v_returns = 1 then 'is' else 'are' end), 'Finish the deposit review, then bill or release'),
       ('pays', v_pays, format('%s rental %s due within 48 hours', v_pays, case when v_pays = 1 then 'payment' else 'payments' end), 'Weekly, biweekly and monthly plans'),
       ('overdue', v_over, format('%s rental %s overdue', v_over, case when v_over = 1 then 'payment is' else 'payments are' end), 'Weekly, biweekly and monthly plans')) l(k, cnt, line, meta)
     where l.cnt > 0
    on conflict (dedupe_key) do nothing;
  end if;
  return n;
end $$;

-- ================================================================ 4. the sweep
create or replace function app.drr_sweep_rows(p_since timestamptz, p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('plate', y.plate, 'vehicle', y.vehicle, 'bookings', y.bookings) order by y.plate), '[]'::jsonb) from (
    select coalesce(r.plate, '(no plate)') as plate, min(app.vehicle_name(r.vehicle_id)) as vehicle,
           jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'returned_at', r.returned_at, 'new', p_since is null or r.returned_at > p_since,
                                        'in_window', app.local_date(r.returned_at) + (app.settings()).deposit_toll_window_days >= app.local_date(p_now),
                                        'stage', app.drr_state(r.booking_id) ->> 'stage') order by r.returned_at) as bookings
      from deposit_reviews r join bookings b on b.id = r.booking_id
     where (p_since is null or r.returned_at > p_since or app.local_date(r.returned_at) + (app.settings()).deposit_toll_window_days >= app.local_date(p_now)
            or r.finance_done_at is null)
       and r.returned_at <= p_now
     group by coalesce(r.plate, '(no plate)')) y
$$;

create or replace function app.drr_sweep(p_now timestamptz default now()) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_day date := app.local_date(p_now);
  v_dow text := (array['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'])[extract(isodow from p_now at time zone 'America/Toronto')::integer];
  v_since timestamptz;
  v_rows jsonb;
  v_task uuid;
  v_n integer;
  v_cars integer;
begin
  if not coalesce(s.deposit_review_required, false) then return null; end if;
  if not v_dow = any (string_to_array(s.deposit_review_sweep_days, ',')) then return null; end if;
  if extract(hour from p_now at time zone 'America/Toronto') < 6 then return null; end if;
  if exists (select 1 from deposit_review_sweeps w where w.run_on = v_day) then return null; end if;
  select max(w.created_at) into v_since from deposit_review_sweeps w;
  v_rows := app.drr_sweep_rows(v_since, p_now);
  v_cars := jsonb_array_length(v_rows);
  select coalesce(sum(jsonb_array_length(x -> 'bookings')), 0) into v_n from jsonb_array_elements(v_rows) x;
  if v_cars > 0 then
    v_task := app.raise_task(p_type => 'deposit_review_sweep', p_queue => 'finance',
      p_title => left(format('Deposit check sweep: %s %s, %s %s', v_cars, case when v_cars = 1 then 'car' else 'cars' end, v_n, case when v_n = 1 then 'booking' else 'bookings' end), 200),
      p_detail => left('Check the toll operator and every ticket place for each plate, on Money > Deposit reviews (the sweep). Plates: '
                       || (select string_agg(x ->> 'plate', ', ' order by x ->> 'plate') from jsonb_array_elements(v_rows) x), 2000),
      p_due_at => ((v_day + 1)::timestamp at time zone 'America/Toronto') - interval '1 minute', p_dedupe => 'deposit_review_sweep:' || v_day);
    insert into staff_digest_items (role, code, digest_slot, line, meta, url, dedupe_key)
    select ro.role, 'staff_expiry_watch', 'morning', format('Deposit check sweep today: %s %s to check for tolls and tickets', v_cars, case when v_cars = 1 then 'car' else 'cars' end),
           'Returns since the last sweep and bookings still inside the toll and ticket window', rtrim(coalesce(s.notify_base_url, ''), '/') || ro.path, 'drr_sweep:' || ro.role || ':' || v_day
      from (values ('admin', '/admin/deposit-reviews?view=sweep'), ('va_finance', '/staff/deposit-reviews?view=sweep')) ro(role, path)
    on conflict (dedupe_key) do nothing;
  end if;
  insert into deposit_review_sweeps (run_on, since, task_id, plates) values (v_day, v_since, v_task, v_rows);
  return v_task;
end $$;

alter function app.server_jobs_due() rename to server_jobs_due_pre1010;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  j jsonb := app.server_jobs_due_pre1010();
begin
  if extract(minute from now())::integer % 15 < 5 then
    begin
      perform app.drr_sweep(now());
      perform app.drr_alerts(now());
    exception when others then
      raise warning 'deposit review jobs: %', sqlerrm;
    end;
  end if;
  return j;
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre1010()'::regprocedure);

-- ================================================================ the screens
-- one booking's review: the items with their facts, the ticket places with their links, the toll link, the deposit
create or replace function app.drr_view(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings := app.drr_booking(p);
  r deposit_reviews;
  d deposits;
  s program_settings := app.settings();
  f jsonb;
  v_admin boolean := app.user_is_admin(p_user);
begin
  if not (v_admin or app.user_va_has(p_user, 'fleet', 'finance')) then raise exception 'Fleet, Finance or an Admin opens the deposit review' using errcode = '42501'; end if;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  select * into r from deposit_reviews where booking_id = b.id;
  select * into d from deposits where booking_id = b.id;
  f := app.drr_facts(b.id);
  return jsonb_build_object(
    'booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'vehicle', app.vehicle_name(b.vehicle_id), 'plate', (select v.plate from vehicles v where v.id = b.vehicle_id),
    'renter', (select rn.legal_name from renters rn where rn.id = b.renter_id), 'pickup_at', coalesce(b.handed_over_at, b.pickup_at), 'return_at', b.return_at, 'checked_in_at', b.checked_in_at,
    'exists', r.booking_id is not null, 'state', app.drr_state(b.id),
    'items', coalesce((select jsonb_agg(jsonb_build_object('item', i.item, 'label', app.drr_item_label(i.item), 'facts', f -> i.item,
                 'fleet', case when i.fleet_result is not null then jsonb_build_object('result', i.fleet_result, 'amount_cents', i.fleet_amount_cents, 'note', i.fleet_note, 'photos', to_jsonb(i.fleet_photos),
                                 'by', (select u.full_name from users u where u.id = i.fleet_by), 'at', i.fleet_at) end,
                 'finance', case when i.finance_result is not null then jsonb_build_object('result', i.finance_result, 'amount_cents', i.finance_amount_cents, 'note', i.finance_note,
                                 'by', (select u.full_name from users u where u.id = i.finance_by), 'at', i.finance_at) end,
                 'fleet_by_me', i.fleet_by = p_user) order by array_position(app.drr_items(), i.item))
               from deposit_review_items i where i.booking_id = b.id), '[]'::jsonb),
    'places', coalesce((select jsonb_agg(pl || jsonb_build_object('check', (select jsonb_build_object('result', c.result, 'note', c.note, 'toll_ticket_id', c.toll_ticket_id,
                                 'by', (select u.full_name from users u where u.id = c.checked_by), 'at', c.checked_at)
                               from deposit_review_ticket_checks c where c.booking_id = b.id and c.place_key = pl ->> 'key')) order by o)
               from jsonb_array_elements(r.places) with ordinality t(pl, o)), '[]'::jsonb),
    'toll_url', s.deposit_review_toll_url,
    'toll_window_ends_on', case when b.checked_in_at is not null then app.local_date(b.checked_in_at) + s.deposit_toll_window_days end,
    'deposit', case when d.id is not null then jsonb_build_object('status', d.status, 'method', d.method, 'amount_cents', d.amount_cents, 'held_back_cents', d.held_back_cents,
                 'released_cents', d.released_cents, 'applied_cents', d.applied_cents, 'release_due_on', d.release_due_on, 'hold_expires_at', d.hold_expires_at) end,
    'blockers', app.deposit_blockers(b.id),
    'may', jsonb_build_object('fleet', v_admin or app.user_va_has(p_user, 'fleet'), 'finance', app.user_runs_finance(p_user), 'admin', v_admin));
end $$;

-- the list: open reviews (p.view: fleet, finance, open, done, sweep), with the links of the sweep
create or replace function app.drr_list(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_view text := coalesce(nullif(p ->> 'view', ''), 'open');
  s program_settings := app.settings();
  w deposit_review_sweeps;
begin
  if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'fleet', 'finance')) then raise exception 'Fleet, Finance or an Admin opens the deposit reviews' using errcode = '42501'; end if;
  select * into w from deposit_review_sweeps order by run_on desc limit 1;
  return jsonb_build_object('view', v_view, 'toll_url', s.deposit_review_toll_url, 'places', s.deposit_review_ticket_places, 'sweep_days', s.deposit_review_sweep_days,
    'last_sweep', case when w.id is not null then jsonb_build_object('run_on', w.run_on, 'since', w.since, 'cars', jsonb_array_length(w.plates)) end,
    'sweep', case when v_view = 'sweep' then app.drr_sweep_rows((select max(x.created_at) from deposit_review_sweeps x where x.run_on < app.local_date(now())), now()) end,
    'rows', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'plate', r.plate, 'vehicle', app.vehicle_name(r.vehicle_id),
               'renter', (select rn.legal_name from renters rn where rn.id = b.renter_id), 'returned_at', r.returned_at, 'state', st,
               'in_window', app.local_date(r.returned_at) + s.deposit_toll_window_days >= app.local_date(now()),
               'deposit_status', (select d.status from deposits d where d.booking_id = b.id)) order by r.returned_at)
       from deposit_reviews r join bookings b on b.id = r.booking_id cross join lateral (select app.drr_state(r.booking_id) st) x
      where case v_view when 'fleet' then r.fleet_done_at is null when 'finance' then r.fleet_done_at is not null and r.finance_done_at is null
                        when 'done' then r.finance_done_at is not null and r.finance_done_at > now() - interval '30 days'
                        else r.finance_done_at is null end), '[]'::jsonb));
end $$;

-- ================================================================ 6. Finance staff opt in to Sales (as field staff do, 0931)
create or replace function app.drr_sales_optin(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_on boolean := coalesce((p ->> 'on')::boolean, true);
begin
  if not app.user_va_has(p_user, 'finance') then raise exception 'Only Finance staff opt in to sales here' using errcode = '42501'; end if;
  if v_on then
    -- office staff sell remotely (the Sales path for remote work), unless a work mode is already set
    update staff_profiles set sales_opt_in_at = coalesce(sales_opt_in_at, now()), sales_work_mode = coalesce(sales_work_mode, 'remote') where user_id = p_user;
    insert into academy_enrollments (user_id, path_code, gate, lock_from, source, enrolled_by)
    values (p_user, app.fx_sales_path(p_user), true, now(), 'existing', p_user) on conflict (user_id, path_code) do nothing;
    perform app.fx_sales_grant(p_user);
  else
    update staff_profiles set functions = case when sales_opt_in_at is not null then array_remove(functions, 'sales') else functions end, sales_opt_in_at = null where user_id = p_user;
    delete from academy_enrollments where user_id = p_user and path_code in ('sales_in_person', 'sales_remote') and source = 'existing'
       and not exists (select 1 from staff_profiles sp where sp.user_id = p_user and 'sales' = any (sp.functions));
  end if;
  return app.fx_sales_state(p_user);
end $$;

-- ================================================================ 7. the accident card: the renter's plan policy and the provider's claim page
select pg_temp.patch_fn('app.accident_card(uuid)'::regprocedure,
  $o$      'plan_policy_number', case when v_kind = 'plan' then nullif(btrim(coalesce(s.accident_plan_policy_number, '')), '') end,
      'plan_claims_phone', case when v_kind = 'plan' then nullif(btrim(coalesce(s.accident_plan_claims_phone, '')), '') end,$o$,
  $n$      'plan_policy_number', case when v_kind = 'plan' then coalesce(nullif(btrim(coalesce(b.plan_policy_number, '')), ''), nullif(btrim(coalesce(cp.activation_ref, '')), '')) end,
      'plan_claims_phone', case when v_kind = 'plan' then nullif(btrim(coalesce(s.accident_plan_claims_phone, '')), '') end,
      'plan_claim_url', case when v_kind = 'plan' then nullif(btrim(coalesce(s.accident_plan_claim_url, '')), '') end,
      'plan_policy_entered', case when v_kind = 'plan' then nullif(btrim(coalesce(b.plan_policy_number, '')), '') is not null end,$n$);

-- p: booking, policy_number (empty clears it)
create or replace function app.plan_policy_set(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings := app.drr_booking(p);
  v text := nullif(btrim(coalesce(p ->> 'policy_number', '')), '');
begin
  if not (app.user_is_admin(p_user) or app.user_va_has(p_user)) then raise exception 'Staff enter the plan policy number' using errcode = '42501'; end if;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.coverage_option is distinct from 3 then raise exception 'This booking does not have the plan sold with the rental' using errcode = '23514'; end if;
  if v is not null and (length(v) < 3 or length(v) > 80) then raise exception 'The policy number is 3 to 80 characters' using errcode = '22023'; end if;
  update bookings set plan_policy_number = v where id = b.id;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    case when v is null then 'Plan policy number cleared' else 'Plan policy number entered: ' || v end, p_user, 'staff', jsonb_build_object('plan_policy_number', v));
  return jsonb_build_object('ok', true, 'policy_number', v);
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1010;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call = 'ops_do' and p_name in ('deposit_review_sign', 'deposit_review_ticket', 'plan_policy_set', 'finance_sales_optin'))
     or (p_call = 'ops_read' and p_name in ('deposit_review', 'deposit_reviews', 'finance_countdowns', 'finance_sales_state')) then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    p_ := p_ - '_va';
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'deposit_review_sign' then app.drr_sign(p_user, p_)
      when 'deposit_review_ticket' then app.drr_ticket_check(p_user, p_)
      when 'plan_policy_set' then app.plan_policy_set(p_user, p_)
      when 'finance_sales_optin' then app.drr_sales_optin(p_user, p_)
      when 'finance_sales_state' then case when app.user_va_has(p_user, 'finance') then app.fx_sales_state(p_user) end
      when 'deposit_review' then app.drr_view(p_user, p_)
      when 'deposit_reviews' then app.drr_list(p_user, p_)
      else app.drr_countdowns_view(p_user, p_) end;
  end if;
  return app.door_pre1010(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1010(uuid, text, text, text, jsonb)'::regprocedure);

-- the returned bookings already waiting for their deposit (the last 30 days): reviewed from now on
select app.drr_ensure(b.id) from bookings b join deposits d on d.booking_id = b.id
 where b.status::text = 'returned' and d.status in ('held', 'captured') and d.released_at is null and coalesce(b.checked_in_at, b.return_at) > now() - interval '30 days';

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and (p.proname like 'drr\_%' or p.proname in ('plan_policy_set', 'deposit_blockers_pre1010', 'server_jobs_due_pre1010', 'door_pre1010'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
