-- 0021_tolls_statements.sql
-- Part A: tolls, tickets and damages after a rental. Intake (one at a time or a toll operator's
-- statement in bulk), matching to whoever had the car with the evidence, and acting on the match:
-- charging the renter (Deposit first, then the Card on File, through the statement functions of
-- 0020), billing or forwarding to the Owner, logging against a member of staff, disputing,
-- naming the renter to the authority. Damage found after a rental follows the same matching and
-- is billed through 0020's assessment.
-- Part B: owner statements (coverage gaps fixed, reissue, issue, payout record, per-vehicle
-- lines with the booking behind each number) and CarmaCars' own monthly statements per vehicle,
-- per owner and in total, with reconciliation, CSV exports and a monthly draft job.
-- Sources: docs/blueprint/10-tolls-tickets-damages.md, 11-statements-and-reports.md, operating
-- procedures 5, 9, 11 and the monthly close, owner and renter billing specifications, the payment
-- set-up chart of accounts. Relies on 0001 to 0020 only (not on 0022).

-- ================================================================ 1. settings and the chart of accounts
alter table program_settings
  add column if not exists toll_boundary_margin_minutes integer not null default 30
    check (toll_boundary_margin_minutes between 0 and 1440),
  add column if not exists toll_unmatched_business_days integer not null default 2
    check (toll_unmatched_business_days between 0 and 60),
  add column if not exists toll_charge_business_days integer not null default 3
    check (toll_charge_business_days between 0 and 60),
  add column if not exists toll_due_soon_days integer not null default 5
    check (toll_due_soon_days between 0 and 60),
  add column if not exists company_statement_draft_days_before_payout integer not null default 5
    check (company_statement_draft_days_before_payout between 0 and 27);

-- The accounts of the payment set-up document (section 6), plus three cost accounts for what an
-- Admin enters by hand (5100 to 5200, to confirm with the accountant).
create table gl_accounts (
  code          text primary key check (code ~ '^[0-9]{4}$'),
  name          text not null,
  account_type  text not null check (account_type in ('asset', 'liability', 'revenue', 'expense', 'per_accountant')),
  note          text
);
insert into gl_accounts (code, name, account_type, note) values
  ('1010', 'Operating bank', 'asset', null),
  ('1020', 'Card processor clearing', 'asset', null),
  ('1200', 'Owner receivables', 'asset', null),
  ('1210', 'Renter receivables', 'asset', null),
  ('2100', 'Renter deposits held', 'liability', null),
  ('2110', 'Collected for Owners', 'liability', null),
  ('2120', 'Prepaid last month''s Insurance Fee', 'liability', null),
  ('2130', 'Referral kickbacks payable', 'liability', null),
  ('2140', 'Claim funds held', 'liability', null),
  ('2150', 'Pass-through clearing', 'liability', null),
  ('2200', 'HST collected', 'liability', null),
  ('2210', 'HST paid', 'asset', null),
  ('2300', 'Investor capital', 'per_accountant', null),
  ('4000', 'Revenue Share', 'revenue', null),
  ('4010', 'Owner fee revenue', 'revenue', null),
  ('4020', 'Owner Late Fees', 'revenue', null),
  ('4100', 'Renter service fees', 'revenue', null),
  ('4110', 'Coverage sold', 'revenue', null),
  ('4120', 'Administration fees', 'revenue', null),
  ('4130', 'Interest', 'revenue', null),
  ('4140', 'Claim surplus', 'revenue', null),
  ('5000', 'Processing fees', 'expense', null),
  ('5010', 'Investor returns', 'per_accountant', null),
  ('5100', 'Vehicle costs absorbed', 'expense', 'added in 0021: repairs and other vehicle costs CarmaCars bears'),
  ('5110', 'Tolls and tickets absorbed', 'expense', 'added in 0021: notices CarmaCars pays (staff use)'),
  ('5200', 'Operating costs entered', 'expense', 'added in 0021: costs the platform does not hold, entered by an Admin');

alter table fee_types add column if not exists gl_account text references gl_accounts (code);

-- The account a charge type posts to, from its class and code. A new charge type gets one by default.
create or replace function app.default_gl_account(p_code text, p_class revenue_class) returns text
language sql immutable as $$
  select case
    when p_code = 'deposit' then '2100'
    when p_class = 'owner_revenue' then '2110'
    when p_class = 'booking_expense' then '2130'
    when p_class = 'pass_through' then '2150'
    when p_class = 'claim_funds' then '2140'
    when p_code = 'coverage_sold' then '4110'
    when p_code in ('toll_admin_fee', 'ticket_admin_fee', 'admin_fee_claim', 'admin_fee_other', 'lost_key_fee', 'declined_payment') then '4120'
    when p_code = 'interest' then '4130'
    when p_class = 'company_only' then '4100'
  end
$$;
update fee_types set gl_account = app.default_gl_account(code, revenue_class) where gl_account is null;

create or replace function app.fee_type_gl_default() returns trigger
language plpgsql as $$
begin
  new.gl_account := coalesce(new.gl_account, app.default_gl_account(new.code, new.revenue_class));
  return new;
end $$;
create trigger fee_types_gl_default before insert or update on fee_types for each row execute function app.fee_type_gl_default();

-- Accounts for the amounts that are not charge lines.
create table gl_account_map (
  source      text not null check (source in ('owner_invoice_line', 'payout', 'statement')),
  item        text not null,
  gl_account  text not null references gl_accounts (code),
  primary key (source, item)
);
insert into gl_account_map (source, item, gl_account) values
  ('owner_invoice_line', 'install_fee', '4010'), ('owner_invoice_line', 'first_month_insurance', '4010'),
  ('owner_invoice_line', 'insurance_fee', '4010'), ('owner_invoice_line', 'tracker_fee', '4010'),
  ('owner_invoice_line', 'prepaid_credit', '4010'), ('owner_invoice_line', 'adjustment', '4010'),
  ('owner_invoice_line', 'last_month_insurance', '2120'), ('owner_invoice_line', 'late_fee', '4020'),
  ('payout', 'owner_statement', '2110'), ('payout', 'turo_only_statement', '2110'), ('payout', 'prepaid_refund', '2120'),
  ('payout', 'total_loss_balance', '2140'), ('payout', 'claim_profit', '2140'), ('payout', 'kickback_payroll', '2130'),
  ('payout', 'investor_return', '5010'), ('payout', 'investor_redemption', '2300'), ('payout', 'other', '1010'),
  ('statement', 'revenue_share', '4000'), ('statement', 'owner_share', '2110'), ('statement', 'hst_collected', '2200'),
  ('statement', 'hst_paid', '2210'), ('statement', 'processing_fees', '5000'), ('statement', 'claim_surplus', '4140'),
  ('statement', 'investor_returns', '5010'), ('statement', 'deposits_held', '2100'), ('statement', 'cash', '1010'),
  ('statement', 'company_paid_tolls', '5110');

-- ================================================================ 2. toll intake
-- Transponders and plates over time, so a statement keyed by a transponder or an old plate still
-- finds the car.
create table vehicle_transponders (
  id                 uuid primary key default gen_random_uuid(),
  vehicle_id         uuid not null references vehicles (id),
  transponder_number text not null check (btrim(transponder_number) <> ''),
  from_date          date not null,
  to_date            date,
  note               text,
  created_by         uuid references users (id),
  created_at         timestamptz not null default now(),
  check (to_date is null or to_date >= from_date),
  exclude using gist ((upper(transponder_number)) with =, (daterange(from_date, to_date, '[]')) with &&)
);
create index vehicle_transponders_vehicle_idx on vehicle_transponders (vehicle_id);

create table vehicle_plate_history (
  id          uuid primary key default gen_random_uuid(),
  vehicle_id  uuid not null references vehicles (id),
  plate       text not null check (btrim(plate) <> ''),
  from_date   date not null,
  to_date     date,
  note        text,
  created_by  uuid references users (id),
  created_at  timestamptz not null default now(),
  check (to_date is null or to_date >= from_date),
  exclude using gist ((upper(plate)) with =, (daterange(from_date, to_date, '[]')) with &&)
);
create index vehicle_plate_history_vehicle_idx on vehicle_plate_history (vehicle_id);

-- Column mapping saved per toll operator and header row (the server parses the file).
create table toll_import_profiles (
  id               uuid primary key default gen_random_uuid(),
  operator         text not null,
  name             text not null,
  header_signature text not null,                     -- the header row, normalised, as the server sees it
  mapping          jsonb not null,                    -- target field -> source column
  date_format      text,
  timezone         text not null default 'America/Toronto',
  amount_unit      text not null default 'dollars' check (amount_unit in ('dollars', 'cents')),
  last_used_at     timestamptz,
  created_by       uuid references users (id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (operator, header_signature)
);
create trigger toll_import_profiles_updated before update on toll_import_profiles for each row execute function app.set_updated_at();

create sequence toll_import_batch_number_seq start 1001;
create table toll_import_batches (
  id                uuid primary key default gen_random_uuid(),
  batch_number      text not null unique default ('TB-' || nextval('toll_import_batch_number_seq')),
  operator          text not null,                    -- the authority on every row
  kind              text not null default 'toll_invoice',
  statement_number  text,
  statement_date    date,
  due_on            date,
  total_cents       bigint check (total_cents >= 0),  -- the statement's own total
  row_count         integer not null default 0,
  imported_count    integer not null default 0,
  duplicate_count   integer not null default 0,
  invalid_count     integer not null default 0,
  rows_total_cents  bigint not null default 0,        -- total of the rows imported
  difference_cents  bigint,                           -- rows given less the statement total
  difference_confirmed boolean not null default false,
  document_id       uuid references documents (id),
  profile_id        uuid references toll_import_profiles (id),
  results           jsonb not null default '[]'::jsonb,
  imported_by       uuid references users (id),
  created_at        timestamptz not null default now()
);

alter table toll_tickets
  add column if not exists time_unknown boolean not null default false,
  add column if not exists note text,
  add column if not exists external_ref text,
  add column if not exists transponder text,
  add column if not exists statement_number text,
  add column if not exists import_batch_id uuid references toll_import_batches (id),
  add column if not exists import_row_no integer,
  add column if not exists toll_group_id uuid,
  add column if not exists vehicle_found_by text check (vehicle_found_by in ('vehicle', 'plate', 'plate_history', 'registration', 'transponder')),
  add column if not exists match_confidence text check (match_confidence in ('high', 'medium', 'low', 'none')),
  add column if not exists match_evidence jsonb,
  add column if not exists matched_how text check (matched_how in ('auto', 'confirmed', 'manual')),
  add column if not exists payment_reference text,
  add column if not exists ocr_raw jsonb,
  add column if not exists booking_statement_id uuid references booking_statements (id),
  add column if not exists charged_at timestamptz,
  add column if not exists charged_by uuid references users (id),
  add column if not exists dispute_reason text,
  add column if not exists disputed_at timestamptz,
  add column if not exists named_at timestamptz,
  add column if not exists named_by uuid references users (id),
  add column if not exists forwarded_at timestamptz,
  add column if not exists closed_reason text,
  add column if not exists closed_at timestamptz;
create index if not exists toll_tickets_dedupe_idx on toll_tickets (upper(plate), occurred_at, amount_cents);
create index if not exists toll_tickets_batch_idx on toll_tickets (import_batch_id);

-- Normalised plate: upper case, letters and digits only.
create or replace function app.norm_plate(p text) returns text
language sql immutable as $$ select nullif(upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')), '') $$;

-- Which vehicle a plate or transponder belonged to on a date: transponder, plate history,
-- registrations, then the current plate.
create or replace function app.resolve_toll_vehicle(p_plate text, p_transponder text, p_on date)
returns table (vehicle_id uuid, found_by text)
language sql stable security definer set search_path = public, app as $$
  select x.vehicle_id, x.found_by from (
    select t.vehicle_id, 'transponder'::text as found_by, 1 as rank
      from vehicle_transponders t
     where p_transponder is not null and upper(btrim(t.transponder_number)) = upper(btrim(p_transponder))
       and t.from_date <= p_on and (t.to_date is null or t.to_date >= p_on)
    union all
    select h.vehicle_id, 'plate_history', 2 from vehicle_plate_history h
     where app.norm_plate(h.plate) = app.norm_plate(p_plate) and h.from_date <= p_on and (h.to_date is null or h.to_date >= p_on)
    union all
    select r.vehicle_id, 'registration', 3 from vehicle_registrations r
     where app.norm_plate(r.plate) = app.norm_plate(p_plate) and r.registered_on <= p_on
       and (r.retransferred_on is null or r.retransferred_on > p_on)
    union all
    select v.id, 'plate', 4 from vehicles v
     where app.norm_plate(v.plate) = app.norm_plate(p_plate)
       and not exists (select 1 from vehicle_plate_history h2
                        where app.norm_plate(h2.plate) = app.norm_plate(p_plate) and h2.vehicle_id <> v.id
                          and h2.from_date <= p_on and (h2.to_date is null or h2.to_date >= p_on))) x
   order by x.rank limit 1
$$;

-- ================================================================ 3. matching
-- Everyone who could have had the car at that moment (or that Toronto day, when the notice gives
-- no time), ranked, with the evidence, and the decision:
--   auto     exactly one clear candidate, not within the boundary margin of its window
--   review   one candidate near a boundary, several candidates, a time not stated, or a booking
--            confirmed but never handed over
--   unmatched nobody on record, with the reason
-- A rental runs from the handover (else pickup) to Check-in, so a late return and an extension
-- are covered; a swapped booking is on each car for its own part.
create or replace function app.match_toll_candidates(p_vehicle uuid, p_at timestamptz, p_time_unknown boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  v_margin integer;
  v_day date := app.local_date(p_at);
  v_from timestamptz;
  v_to timestamptz;
  v_c jsonb := '[]'::jsonb;
  v_real jsonb;
  v_n integer;
  v_pending integer;
  r record;
  v_depth numeric;
  v_near boolean;
  v_conf text;
  v_decision text;
  v_reason text;
  v_best jsonb;
  v_kinds text;
begin
  v_margin := (app.settings(v_day)).toll_boundary_margin_minutes;
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then
    return jsonb_build_object('vehicle_id', p_vehicle, 'at', p_at, 'time_unknown', p_time_unknown, 'margin_minutes', v_margin,
                              'candidates', '[]'::jsonb, 'decision', 'unmatched', 'confidence', 'none', 'suggested', null,
                              'reason', 'The plate is not on any vehicle in the fleet');
  end if;
  if p_time_unknown then
    v_from := app.local_midnight(v_day); v_to := app.local_midnight(v_day + 1);
  else
    v_from := p_at; v_to := p_at;
  end if;

  -- bookings actually on rent on this car (each car's part of a swapped booking)
  for r in
    with sw as (
      select s.booking_id, s.from_vehicle_id, s.to_vehicle_id, s.swapped_at,
             row_number() over (partition by s.booking_id order by s.swapped_at, s.id) as n,
             lead(s.swapped_at) over (partition by s.booking_id order by s.swapped_at, s.id) as next_at
        from booking_vehicle_swaps s
       where s.booking_id in (select x.booking_id from booking_vehicle_swaps x where p_vehicle in (x.from_vehicle_id, x.to_vehicle_id))),
    base as (
      select b.*, coalesce(b.handed_over_at, b.pickup_at) as start_at,
             case when b.status = 'on_rent' then coalesce(b.checked_in_at, 'infinity'::timestamptz)
                  else coalesce(b.checked_in_at, b.return_at) end as end_at
        from bookings b
       where b.status in ('on_rent', 'returned', 'closed')
         and (b.vehicle_id = p_vehicle or b.id in (select booking_id from sw))),
    seg as (
      select bs.id, bs.vehicle_id as seg_vehicle, bs.start_at as seg_start, bs.end_at as seg_end, false as swapped
        from base bs where not exists (select 1 from sw where sw.booking_id = bs.id)
      union all
      select bs.id, sw.from_vehicle_id, bs.start_at, least(sw.swapped_at, bs.end_at), false
        from base bs join sw on sw.booking_id = bs.id and sw.n = 1
      union all
      select bs.id, sw.to_vehicle_id, sw.swapped_at, coalesce(least(sw.next_at, bs.end_at), bs.end_at), true
        from base bs join sw on sw.booking_id = bs.id)
    select b.id as booking_id, b.booking_number, b.booking_type, b.status::text as status, b.owner_id, b.return_at, b.checked_in_at,
           split_part(btrim(rn.legal_name), ' ', 1) as first_name, sg.seg_start, sg.seg_end, sg.swapped,
           exists (select 1 from booking_extensions e where e.booking_id = b.id and e.status = 'confirmed') as extended
      from seg sg join base b on b.id = sg.id left join renters rn on rn.id = b.renter_id
     where sg.seg_vehicle = p_vehicle and sg.seg_start < sg.seg_end
       and (case when p_time_unknown then sg.seg_start < v_to and sg.seg_end > v_from
                 else sg.seg_start <= p_at and p_at < sg.seg_end end)
  loop
    v_depth := case when p_time_unknown then null
                    when r.seg_end = 'infinity'::timestamptz then extract(epoch from p_at - r.seg_start) / 60
                    else least(extract(epoch from p_at - r.seg_start), extract(epoch from r.seg_end - p_at)) / 60 end;
    v_c := v_c || jsonb_build_object(
      'kind', case when r.booking_type = 'owner' then 'owner_booking' else 'renter' end,
      'booking_id', r.booking_id, 'booking_number', r.booking_number,
      'renter_first_name', case when r.booking_type = 'owner' then null else r.first_name end,
      'owner_id', r.owner_id, 'booking_status', r.status,
      'window_start', r.seg_start, 'window_end', case when r.seg_end = 'infinity'::timestamptz then null else r.seg_end end,
      'minutes_from_start', case when p_time_unknown then null else round(extract(epoch from p_at - r.seg_start) / 60) end,
      'minutes_to_end', case when p_time_unknown or r.seg_end = 'infinity'::timestamptz then null else round(extract(epoch from r.seg_end - p_at) / 60) end,
      'position_pct', case when p_time_unknown or r.seg_end = 'infinity'::timestamptz then null
                           else round(100 * extract(epoch from p_at - r.seg_start) / nullif(extract(epoch from r.seg_end - r.seg_start), 0)) end,
      'depth_minutes', round(v_depth),
      'near_boundary', coalesce(v_depth < v_margin, false),
      'late_return', r.checked_in_at is not null and r.checked_in_at > r.return_at and p_at > r.return_at,
      'extended', r.extended, 'swapped', r.swapped, 'still_on_rent', r.status = 'on_rent', 'not_handed_over', false);
  end loop;

  -- a booking confirmed for that time but never handed over: low confidence, never automatic
  for r in select b.id, b.booking_number, b.booking_type, b.owner_id, b.pickup_at, b.return_at, split_part(btrim(rn.legal_name), ' ', 1) as first_name
             from bookings b left join renters rn on rn.id = b.renter_id
            where b.vehicle_id = p_vehicle and b.status in ('confirmed', 'pending_payment') and b.handed_over_at is null
              and b.pickup_at < greatest(v_to, p_at + interval '1 microsecond') and b.return_at > v_from
  loop
    v_c := v_c || jsonb_build_object('kind', case when r.booking_type = 'owner' then 'owner_booking' else 'renter' end,
      'booking_id', r.id, 'booking_number', r.booking_number, 'renter_first_name', case when r.booking_type = 'owner' then null else r.first_name end,
      'owner_id', r.owner_id, 'window_start', r.pickup_at, 'window_end', r.return_at, 'near_boundary', false,
      'not_handed_over', true, 'reason', 'Booked for that time but never handed over');
  end loop;

  -- staff moves (0020)
  for r in select m.id, m.staff_user_id, u.full_name, m.purpose, m.started_at, m.ended_at, m.booking_id, m.field_job_id
             from vehicle_moves m left join users u on u.id = m.staff_user_id
            where m.vehicle_id = p_vehicle
              and (case when p_time_unknown then m.started_at < v_to and coalesce(m.ended_at, 'infinity'::timestamptz) > v_from
                        else m.started_at <= p_at and p_at < coalesce(m.ended_at, 'infinity'::timestamptz) end)
  loop
    v_depth := case when p_time_unknown then null
                    when r.ended_at is null then extract(epoch from p_at - r.started_at) / 60
                    else least(extract(epoch from p_at - r.started_at), extract(epoch from r.ended_at - p_at)) / 60 end;
    v_c := v_c || jsonb_build_object('kind', 'staff', 'staff_user_id', r.staff_user_id, 'staff_name', r.full_name, 'purpose', r.purpose,
      'move_id', r.id, 'booking_id', r.booking_id, 'field_job_id', r.field_job_id, 'window_start', r.started_at, 'window_end', r.ended_at,
      'minutes_from_start', case when p_time_unknown then null else round(extract(epoch from p_at - r.started_at) / 60) end,
      'depth_minutes', round(v_depth), 'near_boundary', coalesce(v_depth < v_margin, false), 'not_handed_over', false);
  end loop;

  -- the Owner: a Turo-Only car, an owner-use block, a Self-Managed car outside a CarmaCars rental,
  -- before the Enrollment Date or after the Exit Date
  if v.management_mode = 'turo_only' then
    v_c := v_c || jsonb_build_object('kind', 'turo_only', 'owner_id', v.owner_id, 'near_boundary', false, 'not_handed_over', false,
      'reason', 'Turo-Only car', 'turo_trip_ref', (select t.turo_trip_ref from turo_trips t where t.vehicle_id = p_vehicle
                                                     and t.starts_at <= v_to and t.ends_at >= v_from order by t.starts_at limit 1));
  elsif v.enrollment_date is null or v_day < v.enrollment_date or (app.vehicle_fee_end(v.id) is not null and v_day > app.vehicle_fee_end(v.id)) then
    v_c := v_c || jsonb_build_object('kind', 'owner_outside_program', 'owner_id', v.owner_id, 'near_boundary', false, 'not_handed_over', false,
      'reason', case when v.enrollment_date is null or v_day < v.enrollment_date then 'Before the Enrollment Date' else 'After the Exit Date' end);
  else
    for r in select k.id, k.reason, k.starts_at, k.ends_at from vehicle_calendar_blocks k
              where k.vehicle_id = p_vehicle and k.reason in ('owner_unavailable', 'turo_owner_use')
                and k.starts_at < greatest(v_to, p_at + interval '1 microsecond') and coalesce(k.ends_at, 'infinity'::timestamptz) > v_from
    loop
      v_c := v_c || jsonb_build_object('kind', 'owner_outside_program', 'owner_id', v.owner_id, 'block_id', r.id, 'window_start', r.starts_at,
        'window_end', r.ends_at, 'near_boundary', false, 'not_handed_over', false, 'reason', 'The Owner had the car (calendar block: ' || r.reason || ')');
    end loop;
    if v.management_mode = 'self_managed' and jsonb_array_length(v_c) = 0 then
      v_c := v_c || jsonb_build_object('kind', 'owner_outside_program', 'owner_id', v.owner_id, 'near_boundary', false, 'not_handed_over', false,
        'reason', 'Self-Managed car outside a CarmaCars rental');
    end if;
  end if;

  select coalesce(jsonb_agg(c order by (c ->> 'not_handed_over')::boolean, coalesce((c ->> 'depth_minutes')::numeric, 1e9) desc), '[]'::jsonb)
    into v_c from jsonb_array_elements(v_c) c;
  select coalesce(jsonb_agg(c), '[]'::jsonb) into v_real from jsonb_array_elements(v_c) c where not (c ->> 'not_handed_over')::boolean;
  v_n := jsonb_array_length(v_real);
  v_pending := jsonb_array_length(v_c) - v_n;
  select string_agg(c ->> 'kind', ',' order by c ->> 'kind') into v_kinds from jsonb_array_elements(v_real) c;

  if v_n = 0 and v_pending = 0 then
    v_decision := 'unmatched'; v_conf := 'none';
    v_reason := 'The car was in the program and not on a booking, a staff move or an owner block at that time';
  elsif v_n = 1 and v_pending = 0 then
    v_best := v_real -> 0;
    v_near := coalesce((v_best ->> 'near_boundary')::boolean, false);
    v_conf := case when p_time_unknown or v_near then 'medium' else 'high' end;
    v_decision := case when v_conf = 'high' then 'auto' else 'review' end;
    v_reason := case when p_time_unknown then 'Time not stated: one party had the car that day'
                     when v_near then format('Within %s minutes of the start or end of the window', v_margin)
                     else 'One clear candidate' end;
  elsif v_n = 2 and v_pending = 0 and v_kinds = 'renter,staff' and not p_time_unknown then
    v_best := v_real -> 0;
    v_conf := 'medium'; v_decision := 'review';
    v_reason := 'A staff move touches the rental (a delivery or collection leg): confirm with the tracker';
  else
    v_best := case when v_n > 0 then v_real -> 0 else v_c -> 0 end;
    v_conf := 'low'; v_decision := 'review';
    v_reason := case when v_n = 0 then 'A booking was confirmed for that time but never handed over'
                     when p_time_unknown then 'Time not stated and more than one party had the car that day'
                     else 'More than one party had the car at that time' end;
  end if;
  return jsonb_build_object('vehicle_id', p_vehicle, 'plate', v.plate, 'at', p_at, 'time_unknown', p_time_unknown,
    'margin_minutes', v_margin, 'candidates', v_c, 'decision', v_decision, 'confidence', v_conf,
    'suggested', v_best, 'reason', v_reason);
end $$;

-- The same for a logged notice: finds the car by vehicle, transponder or plate at that date.
create or replace function app.match_toll_candidates(p_ticket uuid)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  t toll_tickets;
  v_vehicle uuid;
begin
  select * into t from toll_tickets where id = p_ticket;
  if t.id is null then raise exception 'Toll or ticket % not found', p_ticket; end if;
  v_vehicle := coalesce(t.vehicle_id, (select r.vehicle_id from app.resolve_toll_vehicle(t.plate, t.transponder, app.local_date(t.occurred_at)) r));
  return app.match_toll_candidates(v_vehicle, t.occurred_at, t.time_unknown);
end $$;

-- 0009's single answer, now read from the ranked candidates (existing callers unchanged).
create or replace function app.match_toll_ticket(p_vehicle uuid, p_at timestamptz)
returns table (matched_to text, booking_id uuid, owner_id uuid)
language plpgsql stable security definer set search_path = public, app as $$
declare
  m jsonb := app.match_toll_candidates(p_vehicle, p_at, false);
  c jsonb := m -> 'suggested';
begin
  if m ->> 'decision' = 'unmatched' or c is null or jsonb_typeof(c) = 'null' then
    return query select 'unmatched'::text, null::uuid, null::uuid;
    return;
  end if;
  return query select c ->> 'kind', case when c ->> 'kind' in ('renter', 'owner_booking') then (c ->> 'booking_id')::uuid end,
                      (c ->> 'owner_id')::uuid;
end $$;

-- 0009's administration fee, now through 0020's fee resolution (booking term, vehicle override,
-- class default, general default). Owners and staff are never charged one.
create or replace function app.toll_ticket_admin_fee(p_kind text, p_matched_to text, p_booking uuid)
returns bigint language plpgsql stable security definer set search_path = public, app as $$
declare
  v_code text := case when p_kind = 'toll_invoice' then 'toll_admin_fee' else 'ticket_admin_fee' end;
  v bigint;
begin
  if p_matched_to <> 'renter' then return 0; end if;
  if p_booking is not null then
    select f.amount_cents into v from app.booking_fee_term(p_booking, v_code) f;
  end if;
  if v is null then
    select d.amount_cents into v from fee_defaults d
     where d.fee_type_code = v_code and d.vehicle_class is null and d.effective_from <= app.today()
       and (d.effective_to is null or d.effective_to > app.today())
     order by d.effective_from desc limit 1;
  end if;
  return coalesce(v, 0);
end $$;

-- Put a candidate on the notice as its match.
create or replace function app.apply_toll_match(p_ticket uuid, p_candidate jsonb, p_by uuid, p_how text, p_confidence text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  k text := p_candidate ->> 'kind';
  b bookings;
begin
  if k not in ('renter', 'owner_booking', 'staff', 'turo_only', 'owner_outside_program') then
    raise exception 'Unknown match "%"', k using errcode = '22023';
  end if;
  if k in ('renter', 'owner_booking') then
    select * into b from bookings where id = (p_candidate ->> 'booking_id')::uuid;
    if b.id is null then raise exception 'Choose the booking' using errcode = '22023'; end if;
    if (k = 'owner_booking') <> (b.booking_type = 'owner') then
      raise exception 'Booking % is %an Owner Booking', b.booking_number, case when b.booking_type = 'owner' then '' else 'not ' end using errcode = '22023';
    end if;
  end if;
  if k = 'staff' and (p_candidate ->> 'staff_user_id') is null then
    raise exception 'Name the member of staff' using errcode = '22023';
  end if;
  update toll_tickets
     set matched_to = k,
         booking_id = case when k in ('renter', 'owner_booking') then b.id end,
         owner_id = case when k in ('renter', 'owner_booking') then b.owner_id
                         when k in ('turo_only', 'owner_outside_program') then coalesce((p_candidate ->> 'owner_id')::uuid,
                              (select v.owner_id from vehicles v where v.id = toll_tickets.vehicle_id)) end,
         staff_user_id = case when k = 'staff' then (p_candidate ->> 'staff_user_id')::uuid end,
         vehicle_id = coalesce(vehicle_id, b.vehicle_id),
         admin_fee_cents = 0,
         matched_by = p_by, matched_at = now(), matched_how = p_how,
         match_confidence = coalesce(p_confidence, match_confidence),
         tracker_proof_document_id = coalesce((p_candidate ->> 'tracker_proof_document_id')::uuid, tracker_proof_document_id),
         status = 'matched'
   where id = p_ticket;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Matched'
   where related_table = 'toll_tickets' and related_id = p_ticket and task_type in ('match_toll', 'review_toll_match', 'toll_unmatched')
     and status in ('open', 'in_progress', 'waiting');
end $$;

-- Run the matcher on a notice still waiting: store the evidence, match it when clear, otherwise
-- queue it for Finance (to match, or to review).
create or replace function app.run_toll_match(p_ticket uuid, p_by uuid default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  t toll_tickets;
  m jsonb;
  r record;
begin
  select * into t from toll_tickets where id = p_ticket for update;
  if t.id is null then raise exception 'Toll or ticket % not found', p_ticket; end if;
  if t.status <> 'logged' then return t.match_evidence; end if;
  if t.vehicle_id is null then
    select * into r from app.resolve_toll_vehicle(t.plate, t.transponder, app.local_date(t.occurred_at));
    if r.vehicle_id is not null then
      update toll_tickets set vehicle_id = r.vehicle_id, vehicle_found_by = r.found_by where id = p_ticket;
      t.vehicle_id := r.vehicle_id;
    end if;
  end if;
  m := app.match_toll_candidates(t.vehicle_id, t.occurred_at, t.time_unknown);
  update toll_tickets set match_evidence = m, match_confidence = m ->> 'confidence' where id = p_ticket;
  if m ->> 'decision' = 'auto' then
    perform app.apply_toll_match(p_ticket, m -> 'suggested', null, 'auto', 'high');
  elsif m ->> 'decision' = 'review' then
    perform app.raise_task(p_type => 'review_toll_match',
        p_title => format('Confirm who had plate %s on %s', t.plate, to_char(t.occurred_at at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI')),
        p_detail => (m ->> 'reason') || '. Candidates: ' || jsonb_array_length(m -> 'candidates'),
        p_vehicle => t.vehicle_id, p_related_table => 'toll_tickets', p_related_id => p_ticket,
        p_due_at => app.local_midnight(coalesce(t.charge_by, app.today()) + 1), p_dedupe => 'review_toll_match:' || p_ticket, p_created_by => p_by);
  else
    perform app.raise_task(p_type => 'match_toll',
        p_title => format('No match for plate %s on %s', t.plate, to_char(t.occurred_at at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI')),
        p_detail => m ->> 'reason', p_vehicle => t.vehicle_id, p_related_table => 'toll_tickets', p_related_id => p_ticket,
        p_due_at => app.local_midnight(coalesce(t.charge_by, app.today()) + 1), p_dedupe => 'match_toll:' || p_ticket, p_created_by => p_by);
  end if;
  return m;
end $$;

-- ================================================================ 4. intake: one notice, or a statement in bulk
-- One row in: validated, checked for duplicates, inserted and matched. p_row: kind, authority,
-- notice_number, external_ref, plate, transponder, occurred_at (with a zone, or Toronto wall
-- clock), time_unknown, place (or entry and exit), amount_cents, due_on, received_on,
-- document_id, note, statement_number, row_no, ocr_raw. Returns result imported, duplicate or
-- invalid with the reason.
create or replace function app.toll_intake_row(p_row jsonb, p_by uuid, p_batch uuid default null, p_import_unknown boolean default false)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  x jsonb := coalesce(p_row, '{}'::jsonb);
  v_kind text := coalesce(nullif(x ->> 'kind', ''), 'toll_invoice');
  v_auth text := nullif(btrim(x ->> 'authority'), '');
  v_notice text := nullif(btrim(x ->> 'notice_number'), '');
  v_plate text := app.norm_plate(x ->> 'plate');
  v_tag text := nullif(btrim(x ->> 'transponder'), '');
  v_at timestamptz;
  v_amount bigint;
  v_received date := coalesce((x ->> 'received_on')::date, app.today());
  v_set program_settings := app.settings();
  r record;
  v_id uuid;
  v_dup uuid;
  m jsonb;
  v_row integer := (x ->> 'row_no')::integer;
begin
  if v_kind not in ('toll_invoice', 'ticket', 'camera_offence', 'parking', 'fine', 'tow', 'impound') then
    return jsonb_build_object('row_no', v_row, 'result', 'invalid', 'reason', format('Unknown kind "%s"', v_kind));
  end if;
  if v_auth is null then
    return jsonb_build_object('row_no', v_row, 'result', 'invalid', 'reason', 'Who issued it is missing');
  end if;
  if v_plate is null and v_tag is null then
    return jsonb_build_object('row_no', v_row, 'result', 'invalid', 'reason', 'Plate or transponder is missing');
  end if;
  if v_kind <> 'toll_invoice' and v_notice is null then
    return jsonb_build_object('row_no', v_row, 'result', 'invalid', 'reason', 'The notice number is missing');
  end if;
  begin
    v_at := case when (x ->> 'occurred_at') ~ '(Z|[+-][0-9]{2}(:?[0-9]{2})?)$' then (x ->> 'occurred_at')::timestamptz
                 else (x ->> 'occurred_at')::timestamp at time zone 'America/Toronto' end;
  exception when others then v_at := null;
  end;
  if v_at is null then
    return jsonb_build_object('row_no', v_row, 'result', 'invalid', 'reason', 'Unreadable date and time');
  end if;
  if v_at > now() then
    return jsonb_build_object('row_no', v_row, 'result', 'invalid', 'reason', 'The date and time are in the future');
  end if;
  begin
    v_amount := (x ->> 'amount_cents')::bigint;
  exception when others then v_amount := null;
  end;
  if v_amount is null or v_amount < 0 then
    return jsonb_build_object('row_no', v_row, 'result', 'invalid', 'reason', 'Unreadable amount');
  end if;

  -- duplicates: the same authority and notice number, or the same plate, time and amount
  select id into v_dup from toll_tickets
   where (v_notice is not null and authority = v_auth and notice_number = v_notice)
      or (v_plate is not null and app.norm_plate(plate) = v_plate and occurred_at = v_at and amount_cents = v_amount)
   limit 1;
  if v_dup is not null then
    return jsonb_build_object('row_no', v_row, 'result', 'duplicate', 'reason', 'Already logged', 'toll_ticket_id', v_dup);
  end if;

  select * into r from app.resolve_toll_vehicle(v_plate, v_tag, app.local_date(v_at));
  if r.vehicle_id is null and not p_import_unknown then
    return jsonb_build_object('row_no', v_row, 'result', 'invalid', 'reason', 'Plate or transponder not in the fleet (not ours)');
  end if;

  insert into toll_tickets (kind, notice_number, authority, plate, vehicle_id, occurred_at, place, amount_cents, due_on, received_on,
      charge_by, document_id, time_unknown, note, external_ref, transponder, statement_number, import_batch_id, import_row_no,
      vehicle_found_by, ocr_raw, created_by)
  values (v_kind, v_notice, v_auth, coalesce(v_plate, upper(v_tag)), r.vehicle_id, v_at,
      coalesce(nullif(x ->> 'place', ''), nullif(concat_ws(' to ', nullif(x ->> 'entry', ''), nullif(x ->> 'exit', '')), '')),
      v_amount, (x ->> 'due_on')::date, v_received, app.add_business_days(v_received, v_set.toll_charge_business_days),
      (x ->> 'document_id')::uuid, coalesce((x ->> 'time_unknown')::boolean, false), x ->> 'note', nullif(x ->> 'external_ref', ''),
      v_tag, nullif(x ->> 'statement_number', ''), p_batch, v_row, r.found_by, x -> 'ocr_raw', p_by)
  returning id into v_id;
  m := app.run_toll_match(v_id, p_by);
  perform app.emit_event('staff_toll_ticket_logged', 'toll_ticket', v_id,
    jsonb_build_object('notice_type', v_kind, 'vehicle_plate', coalesce(v_plate, v_tag), 'notice_amount_cents', v_amount,
                       'notice_due_date', x ->> 'due_on', 'match_summary', m ->> 'reason', 'match_decision', m ->> 'decision',
                       'import_batch_id', p_batch),
    'staff_toll_ticket_logged:' || v_id || ':logged');
  return jsonb_build_object('row_no', v_row, 'result', 'imported', 'toll_ticket_id', v_id, 'decision', m ->> 'decision',
                            'confidence', m ->> 'confidence', 'matched_to', (select matched_to from toll_tickets where id = v_id));
end $$;

-- Single entry ("Save and match"). Refuses a duplicate or an invalid row with the reason.
create or replace function app.log_toll_ticket(p jsonb, p_by uuid)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  res jsonb;
begin
  if not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin logs a toll or ticket' using errcode = '42501';
  end if;
  res := app.toll_intake_row(p, p_by, null, coalesce((p ->> 'not_ours_ok')::boolean, false));
  if res ->> 'result' = 'duplicate' then
    raise exception 'This notice is already logged (%)', res ->> 'toll_ticket_id' using errcode = '23505';
  elsif res ->> 'result' = 'invalid' then
    raise exception '%', res ->> 'reason' using errcode = '22023';
  end if;
  return (res ->> 'toll_ticket_id')::uuid;
end $$;

-- Save (or update) a column-mapping profile for an operator's header row.
create or replace function app.save_toll_import_profile(p jsonb, p_by uuid)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  if not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin manages import profiles' using errcode = '42501';
  end if;
  if p ->> 'operator' is null or p ->> 'header_signature' is null or p -> 'mapping' is null then
    raise exception 'A profile needs the operator, the header row and the mapping' using errcode = '22023';
  end if;
  insert into toll_import_profiles (operator, name, header_signature, mapping, date_format, timezone, amount_unit, created_by)
  values (p ->> 'operator', coalesce(p ->> 'name', p ->> 'operator'), p ->> 'header_signature', p -> 'mapping', p ->> 'date_format',
          coalesce(p ->> 'timezone', 'America/Toronto'), coalesce(p ->> 'amount_unit', 'dollars'), p_by)
  on conflict (operator, header_signature) do update
     set mapping = excluded.mapping, name = excluded.name, date_format = excluded.date_format,
         timezone = excluded.timezone, amount_unit = excluded.amount_unit
  returning id into v_id;
  return v_id;
end $$;

-- The profile for a header row seen before (applied automatically by the import screen).
create or replace function app.find_toll_import_profile(p_operator text, p_header_signature text)
returns toll_import_profiles language sql stable security definer set search_path = public, app as $$
  select * from toll_import_profiles where operator = p_operator and header_signature = p_header_signature
$$;

-- Bulk import of a parsed statement. p: operator, kind, statement_number, statement_date, due_on,
-- total_cents, document_id, profile_id, import_unknown, rows [ {row_no, plate | transponder,
-- occurred_at, time_unknown, amount_cents, notice_number, external_ref, place, entry, exit} ].
-- Each row is validated and de-duplicated on its own (also against earlier rows of the same file).
-- Returns the batch, the counts, the per-row results and the difference with the statement total.
create or replace function app.import_toll_batch(p jsonb, p_by uuid)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_batch uuid;
  x jsonb;
  res jsonb;
  v_results jsonb := '[]'::jsonb;
  n_imp integer := 0; n_dup integer := 0; n_bad integer := 0; n integer := 0;
  v_given bigint := 0;
  v_imported bigint := 0;
  v_amt bigint;
begin
  if not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin imports a toll statement' using errcode = '42501';
  end if;
  if coalesce(btrim(p ->> 'operator'), '') = '' then
    raise exception 'Name the toll operator' using errcode = '22023';
  end if;
  if jsonb_typeof(p -> 'rows') is distinct from 'array' then
    raise exception 'No rows to import' using errcode = '22023';
  end if;
  insert into toll_import_batches (operator, kind, statement_number, statement_date, due_on, total_cents, document_id, profile_id, imported_by)
  values (btrim(p ->> 'operator'), coalesce(p ->> 'kind', 'toll_invoice'), p ->> 'statement_number', (p ->> 'statement_date')::date,
          (p ->> 'due_on')::date, (p ->> 'total_cents')::bigint, (p ->> 'document_id')::uuid, (p ->> 'profile_id')::uuid, p_by)
  returning id into v_batch;
  if p ->> 'profile_id' is not null then
    update toll_import_profiles set last_used_at = now() where id = (p ->> 'profile_id')::uuid;
  end if;
  for x in select * from jsonb_array_elements(p -> 'rows') loop
    n := n + 1;
    begin v_amt := (x ->> 'amount_cents')::bigint; exception when others then v_amt := null; end;
    v_given := v_given + coalesce(v_amt, 0);
    res := app.toll_intake_row(
      x || jsonb_build_object('kind', coalesce(p ->> 'kind', 'toll_invoice'), 'authority', btrim(p ->> 'operator'),
                              'statement_number', p ->> 'statement_number', 'due_on', coalesce(x ->> 'due_on', p ->> 'due_on'),
                              'document_id', coalesce(x ->> 'document_id', p ->> 'document_id'), 'row_no', coalesce((x ->> 'row_no')::integer, n)),
      p_by, v_batch, coalesce((p ->> 'import_unknown')::boolean, false));
    v_results := v_results || res;
    if res ->> 'result' = 'imported' then
      n_imp := n_imp + 1; v_imported := v_imported + v_amt;
    elsif res ->> 'result' = 'duplicate' then n_dup := n_dup + 1;
    else n_bad := n_bad + 1;
    end if;
  end loop;
  update toll_import_batches
     set row_count = n, imported_count = n_imp, duplicate_count = n_dup, invalid_count = n_bad, rows_total_cents = v_imported,
         difference_cents = case when total_cents is not null then v_given - total_cents end,
         difference_confirmed = coalesce((p ->> 'confirm_difference')::boolean, false), results = v_results
   where id = v_batch;
  return jsonb_build_object('batch_id', v_batch, 'rows', n, 'imported', n_imp, 'duplicates', n_dup, 'invalid', n_bad,
    'rows_total_cents', v_given, 'imported_total_cents', v_imported,
    'statement_total_cents', (p ->> 'total_cents')::bigint,
    'difference_cents', case when p ->> 'total_cents' is not null then v_given - (p ->> 'total_cents')::bigint end,
    'matched', (select jsonb_object_agg(k, c) from (select coalesce(t.matched_to, 'unmatched') as k, count(*) as c
                  from toll_tickets t where t.import_batch_id = v_batch group by 1) s),
    'results', v_results);
end $$;

-- ================================================================ 5. confirming matches
-- Confirm a match. p_choice: null (the stored suggestion or the automatic match), {"index": n}
-- (a candidate), or a manual choice {kind, booking_id, staff_user_id, owner_id}. A renter match
-- below high confidence needs the tracker proof (tracker_proof_document_id in p_choice or on the row).
create or replace function app.confirm_toll_match(p_ticket uuid, p_by uuid, p_choice jsonb default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  t toll_tickets;
  c jsonb;
  v_how text := 'confirmed';
  v_conf text;
begin
  if not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin confirms a match' using errcode = '42501';
  end if;
  select * into t from toll_tickets where id = p_ticket for update;
  if t.id is null then raise exception 'Toll or ticket % not found', p_ticket; end if;
  if t.status not in ('logged', 'matched') then
    raise exception 'This notice is already %', t.status using errcode = '23514';
  end if;
  if p_choice is null and t.status = 'matched' then
    update toll_tickets set matched_by = p_by, matched_at = now(), matched_how = 'confirmed' where id = p_ticket;
    return;
  end if;
  v_conf := t.match_confidence;
  if p_choice is null then
    c := t.match_evidence -> 'suggested';
  elsif p_choice ? 'index' then
    c := t.match_evidence -> 'candidates' -> ((p_choice ->> 'index')::integer);
  else
    c := p_choice; v_how := 'manual'; v_conf := 'low';
    if c ->> 'kind' in ('renter', 'owner_booking') and not exists (
         select 1 from bookings b where b.id = (c ->> 'booking_id')::uuid
            and (b.vehicle_id = t.vehicle_id or exists (select 1 from booking_vehicle_swaps s where s.booking_id = b.id
                                                          and t.vehicle_id in (s.from_vehicle_id, s.to_vehicle_id)))) then
      raise exception 'That booking was not on this vehicle' using errcode = '22023';
    end if;
  end if;
  if c is null or jsonb_typeof(c) = 'null' then
    raise exception 'There is no candidate to confirm: choose who had the car' using errcode = '22023';
  end if;
  c := c || jsonb_strip_nulls(jsonb_build_object('tracker_proof_document_id', p_choice ->> 'tracker_proof_document_id'));
  if coalesce((c ->> 'not_handed_over')::boolean, false) then
    raise exception 'That booking was never handed over: choose another party' using errcode = '23514';
  end if;
  if c ->> 'kind' = 'renter' and coalesce(v_conf, 'low') <> 'high'
     and coalesce(c ->> 'tracker_proof_document_id', t.tracker_proof_document_id::text) is null then
    raise exception 'A renter match below high confidence needs the tracker proof attached' using errcode = '23514';
  end if;
  perform app.apply_toll_match(p_ticket, c, p_by, v_how, v_conf);
end $$;

-- Bulk confirm: rows matched automatically, or with a high-confidence suggestion. Anything else
-- is skipped with the reason.
create or replace function app.bulk_confirm_toll_matches(p_ids uuid[], p_by uuid)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  t toll_tickets;
  v_out jsonb := '[]'::jsonb;
  v_id uuid;
begin
  if not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin confirms matches' using errcode = '42501';
  end if;
  foreach v_id in array p_ids loop
    select * into t from toll_tickets where id = v_id;
    if t.id is null then
      v_out := v_out || jsonb_build_object('id', v_id, 'result', 'skipped', 'reason', 'not found');
    elsif t.match_confidence is distinct from 'high' then
      v_out := v_out || jsonb_build_object('id', v_id, 'result', 'skipped', 'reason', 'not a clear match: confirm it on its own');
    elsif t.status not in ('logged', 'matched') then
      v_out := v_out || jsonb_build_object('id', v_id, 'result', 'skipped', 'reason', 'already ' || t.status);
    else
      perform app.confirm_toll_match(v_id, p_by, null);
      v_out := v_out || jsonb_build_object('id', v_id, 'result', 'confirmed');
    end if;
  end loop;
  return v_out;
end $$;

-- ================================================================ 6. acting on a match
-- After the return, new lines go on a statement through 0020: a later-charge statement once the
-- Check-in statement exists (the issued one is never rewritten), then the Deposit if it still
-- holds money, otherwise a pending charge on the Card on File. Before that, the lines wait for
-- the Check-in statement. Returns the statement (or null) and what moved.
create or replace function app.charge_after_rental(p_booking uuid, p_by uuid, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_stmt uuid;
  v_settle jsonb;
begin
  select * into b from bookings where id = p_booking;
  if b.status in ('returned', 'closed') and exists (select 1 from booking_statements s where s.booking_id = p_booking and s.kind = 'check_in') then
    v_stmt := app.issue_booking_statement(p_booking, p_by, p_now);
    v_settle := app.settle_deposit(p_booking, p_by, '{}'::jsonb, p_now);
    return jsonb_build_object('statement_id', v_stmt, 'settlement', v_settle);
  end if;
  return jsonb_build_object('statement_id', null, 'settlement', null, 'waiting_for', 'the Check-in statement');
end $$;

-- Charge renter matches: one pass-through line per notice and the administration fee (one per
-- toll statement and booking; one per ticket), from the booking's fee terms or the defaults.
-- Groups (booking and statement) are charged one at a time; a group that fails is reported and
-- left as it was. The renter is told with the notice and the statement (renter_extra_charge).
create or replace function app.charge_toll_ticket(p_ids uuid[], p_by uuid, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  g record;
  t record;
  b bookings;
  d deposits;
  v_out jsonb := '[]'::jsonb;
  v_fee_code text;
  v_amount_code text;
  v_fee bigint;
  v_line uuid;
  v_fee_line uuid;
  v_first boolean;
  v_res jsonb;
  v_stmt uuid;
  v_from text;
  v_total bigint;
  v_msg text;
begin
  if not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin charges a toll or ticket' using errcode = '42501';
  end if;
  for g in
    select tt.booking_id, case when tt.kind = 'toll_invoice' then coalesce(tt.import_batch_id, tt.id) else tt.id end as grp,
           array_agg(tt.id order by tt.occurred_at, tt.id) as ids, min(tt.kind) as kind
      from toll_tickets tt where tt.id = any (p_ids)
     group by 1, 2
  loop
    begin
      if g.booking_id is null then
        raise exception 'Not matched to a renter''s booking' using errcode = '23514';
      end if;
      select * into b from bookings where id = g.booking_id;
      v_amount_code := case when g.kind = 'toll_invoice' then 'toll_amount' else 'ticket_amount' end;
      v_fee_code := case when g.kind = 'toll_invoice' then 'toll_admin_fee' else 'ticket_admin_fee' end;
      v_fee := app.toll_ticket_admin_fee(g.kind, 'renter', g.booking_id);
      v_first := true; v_total := 0;
      for t in select * from toll_tickets where id = any (g.ids) order by occurred_at, id for update loop
        if t.matched_to <> 'renter' or t.status <> 'matched' then
          raise exception 'Notice % is % / %: only a confirmed renter match is charged', coalesce(t.notice_number, t.id::text), t.matched_to, t.status
            using errcode = '23514';
        end if;
        if t.document_id is null then
          raise exception 'Notice % has no document: a renter is charged only with the notice attached', coalesce(t.notice_number, t.id::text)
            using errcode = '23514';
        end if;
        if t.amount_line_item_id is not null then
          raise exception 'Notice % is already charged', coalesce(t.notice_number, t.id::text) using errcode = '23514';
        end if;
        insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents,
                                        revenue_class, stage, supporting_document_id, toll_ticket_id, assessment_key, supporting_refs, created_by)
        select g.booking_id, v_amount_code,
               format('%s %s, %s%s', initcap(replace(t.kind, '_', ' ')), coalesce(t.notice_number, t.external_ref, ''),
                      to_char(t.occurred_at at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), coalesce(', ' || t.place, '')),
               1, t.amount_cents, t.amount_cents, f.hst_applies,
               case when f.hst_applies then public.calc_hst(t.amount_cents, b.hst_bps) else 0 end,
               f.revenue_class, 'after_return', t.document_id, t.id, 'toll:' || t.id,
               jsonb_build_object('toll_ticket_id', t.id, 'notice_document_id', t.document_id, 'match_confidence', t.match_confidence,
                                  'tracker_proof_document_id', t.tracker_proof_document_id), p_by
          from fee_types f where f.code = v_amount_code
        returning id into v_line;
        v_fee_line := null;
        if v_first and v_fee > 0 then
          insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents,
                                          revenue_class, stage, supporting_document_id, toll_ticket_id, assessment_key, supporting_refs, created_by)
          select g.booking_id, v_fee_code, f.label, 1, v_fee, v_fee, f.hst_applies,
                 case when f.hst_applies then public.calc_hst(v_fee, b.hst_bps) else 0 end,
                 f.revenue_class, 'after_return', t.document_id, t.id, 'toll_fee:' || g.grp,
                 jsonb_build_object('toll_ticket_ids', to_jsonb(g.ids), 'notice_document_id', t.document_id), p_by
            from fee_types f where f.code = v_fee_code
          returning id into v_fee_line;
        end if;
        update toll_tickets
           set amount_line_item_id = v_line, fee_line_item_id = v_fee_line,
               admin_fee_cents = case when v_first then v_fee else 0 end,
               toll_group_id = case when array_length(g.ids, 1) > 1 then g.grp end,
               charged_at = p_now, charged_by = p_by, status = 'charged'
         where id = t.id;
        v_total := v_total + t.amount_cents + case when v_first then v_fee else 0 end;
        v_first := false;
      end loop;

      v_res := app.charge_after_rental(g.booking_id, p_by, p_now);
      v_stmt := (v_res ->> 'statement_id')::uuid;
      if v_stmt is not null then
        -- where the money came from: the Deposit, or the card for what it did not cover
        v_from := case when exists (select 1 from booking_line_items li join payments p on p.id = li.payment_id
                                     where li.toll_ticket_id = any (g.ids) and p.purpose <> 'deposit') then 'card_on_file' else 'deposit' end;
      else
        select * into d from deposits where booking_id = g.booking_id;
        v_from := case when d.id is not null and d.status in ('held', 'captured')
                            and d.amount_cents - d.applied_cents - d.released_cents > 0 then 'deposit' else 'card_on_file' end;
      end if;
      update toll_tickets set charged_from = v_from, booking_statement_id = v_stmt,
                              notified_at = case when v_stmt is not null then p_now end
       where id = any (g.ids);
      if v_stmt is not null then
        perform app.emit_event('renter_extra_charge', 'booking_statement', v_stmt,
          jsonb_build_object('booking_id', g.booking_id, 'booking_number', b.booking_number, 'renter_id', b.renter_id,
                             'charge_kind', g.kind, 'toll_ticket_ids', to_jsonb(g.ids),
                             'document_ids', (select jsonb_agg(document_id) from toll_tickets where id = any (g.ids)),
                             'amount_cents', v_total - v_fee, 'admin_fee_cents', v_fee,
                             'total_cents', (select charges_cents + hst_cents from booking_statements where id = v_stmt),
                             'charged_from', v_from, 'statement_id', v_stmt),
          'renter_extra_charge:' || v_stmt || ':toll');
      end if;
      v_out := v_out || jsonb_build_object('booking_id', g.booking_id, 'ids', to_jsonb(g.ids), 'result', 'charged',
                                           'statement_id', v_stmt, 'charged_from', v_from, 'admin_fee_cents', v_fee,
                                           'server_actions', coalesce(v_res -> 'settlement' -> 'server_actions', '[]'::jsonb));
    exception when others then
      get stacked diagnostics v_msg = message_text;
      v_out := v_out || jsonb_build_object('booking_id', g.booking_id, 'ids', to_jsonb(g.ids), 'result', 'failed', 'reason', v_msg);
    end;
  end loop;
  return v_out;
end $$;

-- The Owner had the car: an Owner Booking is a deduction at cost on the next statement (no fee);
-- outside the program or a Turo-Only car, the notice is forwarded.
create or replace function app.bill_toll_to_owner(p_id uuid, p_by uuid)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  t toll_tickets;
  v_ded uuid;
begin
  if not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin bills a notice to an Owner' using errcode = '42501';
  end if;
  select * into t from toll_tickets where id = p_id for update;
  if t.id is null then raise exception 'Toll or ticket % not found', p_id; end if;
  if t.status <> 'matched' then raise exception 'Confirm the match first (the notice is %)', t.status using errcode = '23514'; end if;
  if t.matched_to = 'owner_booking' then
    if t.amount_cents > 0 then
      insert into owner_deductions (owner_id, vehicle_id, kind, description, amount_cents, incurred_on, booking_id, receipt_document_id, created_by)
      values (t.owner_id, t.vehicle_id, case when t.kind = 'toll_invoice' then 'owner_booking_toll' else 'owner_booking_ticket' end,
              format('%s %s on Owner Booking %s, %s', initcap(replace(t.kind, '_', ' ')), coalesce(t.notice_number, t.external_ref, ''),
                     (select booking_number from bookings where id = t.booking_id), to_char(t.occurred_at at time zone 'America/Toronto', 'YYYY-MM-DD')),
              t.amount_cents, app.local_date(t.occurred_at), t.booking_id, t.document_id, p_by)
      returning id into v_ded;
    end if;
    update toll_tickets set owner_deduction_id = v_ded, status = 'billed_to_owner', admin_fee_cents = 0, notified_at = now() where id = p_id;
    perform app.emit_event('owner_toll_ticket', 'toll_ticket', p_id,
      jsonb_build_object('owner_id', t.owner_id, 'is_forwarded', false, 'owner_deduction_id', v_ded, 'amount_cents', t.amount_cents,
                         'document_id', t.document_id), 'owner_toll_ticket:' || p_id || ':billed');
  elsif t.matched_to in ('owner_outside_program', 'turo_only') then
    update toll_tickets set status = 'forwarded_to_owner', forwarded_at = now(), notified_at = now() where id = p_id;
    perform app.emit_event('owner_toll_ticket', 'toll_ticket', p_id,
      jsonb_build_object('owner_id', t.owner_id, 'is_forwarded', true, 'amount_cents', t.amount_cents, 'document_id', t.document_id),
      'owner_toll_ticket:' || p_id || ':forwarded');
  else
    raise exception 'This notice is matched to %, not to the Owner', t.matched_to using errcode = '23514';
  end if;
  return v_ded;
end $$;

-- CarmaCars staff had the car: CarmaCars pays, logged against the staff member.
create or replace function app.mark_toll_company_paid(p_id uuid, p_by uuid, p_reference text default null, p_paid_at timestamptz default now(),
                                                      p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  t toll_tickets;
begin
  if not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin records a company-paid notice' using errcode = '42501';
  end if;
  select * into t from toll_tickets where id = p_id for update;
  if t.matched_to <> 'staff' or t.status <> 'matched' then
    raise exception 'Only a confirmed staff match is paid by CarmaCars' using errcode = '23514';
  end if;
  update toll_tickets set status = 'company_paid', paid_by_company_at = p_paid_at, payment_reference = coalesce(p_reference, payment_reference),
                          note = coalesce(p_note, note)
   where id = p_id;
end $$;

-- CarmaCars paid the authority (a renter's notice is paid on their behalf; pass-through out).
create or replace function app.record_toll_authority_payment(p_id uuid, p_by uuid, p_reference text, p_paid_at timestamptz default now())
returns void language plpgsql security definer set search_path = public, app as $$
begin
  if not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin records a payment to the authority' using errcode = '42501';
  end if;
  update toll_tickets set paid_by_company_at = p_paid_at, payment_reference = p_reference where id = p_id;
  if not found then raise exception 'Toll or ticket % not found', p_id; end if;
end $$;

create or replace function app.dispute_toll_ticket(p_id uuid, p_by uuid, p_reason text)
returns void language plpgsql security definer set search_path = public, app as $$
begin
  if not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin disputes a notice' using errcode = '42501';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then raise exception 'Give the reason for the dispute' using errcode = '22023'; end if;
  update toll_tickets set status = 'disputed', dispute_reason = p_reason, disputed_at = now()
   where id = p_id and status not in ('closed', 'company_paid');
  if not found then raise exception 'This notice cannot be disputed now' using errcode = '23514'; end if;
end $$;

-- An Admin names the renter to the authority (the letter is generated by the app).
create or replace function app.name_renter_to_authority(p_id uuid, p_admin uuid, p_letter_document uuid default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  t toll_tickets;
begin
  if not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin names a renter to the authority' using errcode = '42501';
  end if;
  select * into t from toll_tickets where id = p_id for update;
  if t.matched_to <> 'renter' or t.booking_id is null then
    raise exception 'Only a notice matched to a renter can be transferred to them' using errcode = '23514';
  end if;
  update toll_tickets set status = 'named_to_authority', named_at = now(), named_by = p_admin where id = p_id;
  perform app.emit_event('renter_named_to_authority', 'toll_ticket', p_id,
    jsonb_build_object('booking_id', t.booking_id, 'document_id', t.document_id, 'letter_document_id', p_letter_document),
    'renter_named_to_authority:' || p_id || ':named');
end $$;

-- Not our vehicle, a court summons handled elsewhere, a duplicate from the authority: closed with the reason.
create or replace function app.close_toll_ticket(p_id uuid, p_by uuid, p_reason text)
returns void language plpgsql security definer set search_path = public, app as $$
begin
  if not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin closes a notice' using errcode = '42501';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then raise exception 'Give the reason' using errcode = '22023'; end if;
  update toll_tickets set status = 'closed', closed_reason = p_reason, closed_at = now() where id = p_id and status <> 'charged';
  if not found then raise exception 'A charged notice is corrected by voiding its line, not closed' using errcode = '23514'; end if;
  update tasks set status = 'cancelled', completed_at = now(), completed_by = p_by, completion_note = p_reason
   where related_table = 'toll_tickets' and related_id = p_id and status in ('open', 'in_progress', 'waiting');
end $$;

-- ================================================================ 7. damage found after a rental
create sequence damage_intake_number_seq start 1001;
create table damage_intakes (
  id                 uuid primary key default gen_random_uuid(),
  intake_number      text not null unique default ('DI-' || nextval('damage_intake_number_seq')),
  vehicle_id         uuid not null references vehicles (id),
  found_at           timestamptz not null,
  occurred_at        timestamptz,                   -- when known
  window_from        timestamptz,                   -- when not: between the clean report and the finding
  window_to          timestamptz,
  location           text not null,
  description        text not null,
  photos             jsonb not null default '[]'::jsonb,
  before_report_id   uuid references condition_reports (id),   -- last report without the damage
  after_report_id    uuid references condition_reports (id),   -- first report with it
  cost_kind          text check (cost_kind in ('repair_estimate', 'repair_invoice')),
  cost_cents         bigint check (cost_cents >= 0),
  cost_document_id   uuid references documents (id),
  shop_name          text,
  match_confidence   text check (match_confidence in ('high', 'medium', 'low', 'none')),
  match_evidence     jsonb,
  matched_to         text not null default 'unmatched' check (matched_to in (
                       'unmatched', 'renter', 'owner_booking', 'staff', 'owner_outside_program', 'turo_only')),
  booking_id         uuid references bookings (id),
  staff_user_id      uuid references users (id),
  matched_by         uuid references users (id),
  matched_at         timestamptz,
  incident_id        uuid references incidents (id),
  route              text check (route in ('at_cost', 'claim', 'owner_deductible', 'owner_repairs', 'company', 'turo', 'waiting')),
  statement_id       uuid references booking_statements (id),
  company_expense_id uuid,
  status             text not null default 'logged' check (status in ('logged', 'matched', 'billed', 'closed')),
  created_by         uuid references users (id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (matched_to not in ('renter', 'owner_booking') or booking_id is not null),
  check (matched_to <> 'staff' or staff_user_id is not null),
  check (window_to is null or window_from is null or window_to >= window_from)
);
create index damage_intakes_vehicle_idx on damage_intakes (vehicle_id, found_at);
create trigger damage_intakes_updated before update on damage_intakes for each row execute function app.set_updated_at();

-- Who could have caused it. With a time: the same matcher as tolls. Without: every rental and staff
-- move that overlaps the window between the clean report and the finding; the pickup and return
-- reports of one booking on either side make it a clear match.
create or replace function app.match_damage_candidates(p_intake uuid)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  di damage_intakes;
  v_from timestamptz;
  v_to timestamptz;
  v_c jsonb := '[]'::jsonb;
  r record;
  v_n integer;
  v_best jsonb;
  v_conf text;
  v_before condition_reports;
  v_after condition_reports;
begin
  select * into di from damage_intakes where id = p_intake;
  if di.id is null then raise exception 'Damage intake % not found', p_intake; end if;
  if di.occurred_at is not null then
    return app.match_toll_candidates(di.vehicle_id, di.occurred_at, false);
  end if;
  select * into v_before from condition_reports where id = di.before_report_id;
  select * into v_after from condition_reports where id = di.after_report_id;
  v_from := coalesce(di.window_from, v_before.completed_at, v_before.created_at, di.found_at - interval '1 day');
  v_to := coalesce(di.window_to, v_after.completed_at, v_after.created_at, di.found_at);
  for r in select b.id, b.booking_number, b.booking_type, b.owner_id, coalesce(b.handed_over_at, b.pickup_at) as s,
                  coalesce(b.checked_in_at, case when b.status = 'on_rent' then 'infinity'::timestamptz else b.return_at end) as e,
                  split_part(btrim(rn.legal_name), ' ', 1) as first_name
             from bookings b left join renters rn on rn.id = b.renter_id
            where b.vehicle_id = di.vehicle_id and b.status in ('on_rent', 'returned', 'closed')
              and coalesce(b.handed_over_at, b.pickup_at) < v_to
              and coalesce(b.checked_in_at, case when b.status = 'on_rent' then 'infinity'::timestamptz else b.return_at end) > v_from
  loop
    v_c := v_c || jsonb_build_object('kind', case when r.booking_type = 'owner' then 'owner_booking' else 'renter' end,
      'booking_id', r.id, 'booking_number', r.booking_number, 'renter_first_name', case when r.booking_type = 'owner' then null else r.first_name end,
      'owner_id', r.owner_id, 'window_start', r.s, 'window_end', case when r.e = 'infinity'::timestamptz then null else r.e end,
      'reports_bracket', v_before.booking_id = r.id and v_before.kind = 'pickup' and v_after.booking_id = r.id and v_after.kind = 'return',
      'not_handed_over', false);
  end loop;
  for r in select m.id, m.staff_user_id, u.full_name, m.purpose, m.started_at, m.ended_at
             from vehicle_moves m left join users u on u.id = m.staff_user_id
            where m.vehicle_id = di.vehicle_id and m.started_at < v_to and coalesce(m.ended_at, 'infinity'::timestamptz) > v_from
  loop
    v_c := v_c || jsonb_build_object('kind', 'staff', 'staff_user_id', r.staff_user_id, 'staff_name', r.full_name, 'purpose', r.purpose,
      'move_id', r.id, 'window_start', r.started_at, 'window_end', r.ended_at, 'not_handed_over', false);
  end loop;
  v_n := jsonb_array_length(v_c);
  if v_n = 0 then
    return jsonb_build_object('vehicle_id', di.vehicle_id, 'window_from', v_from, 'window_to', v_to, 'candidates', v_c,
      'decision', 'unmatched', 'confidence', 'none', 'suggested', null,
      'reason', 'No rental or staff move between the clean report and the finding');
  end if;
  select c into v_best from jsonb_array_elements(v_c) c order by coalesce((c ->> 'reports_bracket')::boolean, false) desc limit 1;
  v_conf := case when v_n = 1 and coalesce((v_best ->> 'reports_bracket')::boolean, false) then 'high'
                 when v_n = 1 then 'medium' else 'low' end;
  return jsonb_build_object('vehicle_id', di.vehicle_id, 'window_from', v_from, 'window_to', v_to, 'candidates', v_c,
    'decision', case when v_conf = 'high' then 'auto' else 'review' end, 'confidence', v_conf, 'suggested', v_best,
    'reason', case when v_conf = 'high' then 'The pickup and return reports of one booking bracket the damage'
                   when v_n = 1 then 'One party had the car in the window; the reports do not bracket it'
                   else 'More than one party had the car in the window' end);
end $$;

create or replace function app.apply_damage_match(p_intake uuid, p_candidate jsonb, p_by uuid, p_confidence text)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  k text := p_candidate ->> 'kind';
begin
  if k not in ('renter', 'owner_booking', 'staff', 'owner_outside_program', 'turo_only') then
    raise exception 'Unknown match "%"', k using errcode = '22023';
  end if;
  update damage_intakes
     set matched_to = k,
         booking_id = case when k in ('renter', 'owner_booking') then (p_candidate ->> 'booking_id')::uuid end,
         staff_user_id = case when k = 'staff' then (p_candidate ->> 'staff_user_id')::uuid end,
         matched_by = p_by, matched_at = now(), match_confidence = coalesce(p_confidence, match_confidence), status = 'matched'
   where id = p_intake;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Matched'
   where related_table = 'damage_intakes' and related_id = p_intake and status in ('open', 'in_progress', 'waiting');
end $$;

-- Damage found after a rental: logged with its photos, the reports either side and the estimate
-- or invoice, then matched. p: vehicle_id, found_at, occurred_at or window_from / window_to,
-- location, description, photos, before_report_id, after_report_id, cost_kind, cost_cents,
-- cost_document_id, shop_name.
create or replace function app.log_damage(p jsonb, p_by uuid)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
  m jsonb;
begin
  if not (app.user_runs_finance(p_by) or app.user_runs_fleet(p_by)) then
    raise exception 'Fleet, Finance or an Admin logs damage' using errcode = '42501';
  end if;
  if p ->> 'vehicle_id' is null or coalesce(p ->> 'location', '') = '' or coalesce(p ->> 'description', '') = '' then
    raise exception 'Give the vehicle and describe the damage: where it is and what it is' using errcode = '22023';
  end if;
  insert into damage_intakes (vehicle_id, found_at, occurred_at, window_from, window_to, location, description, photos,
      before_report_id, after_report_id, cost_kind, cost_cents, cost_document_id, shop_name, created_by)
  values ((p ->> 'vehicle_id')::uuid, coalesce((p ->> 'found_at')::timestamptz, now()), (p ->> 'occurred_at')::timestamptz,
      (p ->> 'window_from')::timestamptz, (p ->> 'window_to')::timestamptz, p ->> 'location', p ->> 'description',
      coalesce(p -> 'photos', '[]'::jsonb), (p ->> 'before_report_id')::uuid, (p ->> 'after_report_id')::uuid,
      p ->> 'cost_kind', (p ->> 'cost_cents')::bigint, (p ->> 'cost_document_id')::uuid, p ->> 'shop_name', p_by)
  returning id into v_id;
  m := app.match_damage_candidates(v_id);
  update damage_intakes set match_evidence = m, match_confidence = m ->> 'confidence' where id = v_id;
  if m ->> 'decision' = 'auto' then
    perform app.apply_damage_match(v_id, m -> 'suggested', null, 'high');
  else
    perform app.raise_task(p_type => 'review_damage_match', p_title => 'Confirm who had the car when the damage happened',
        p_detail => m ->> 'reason', p_vehicle => (p ->> 'vehicle_id')::uuid, p_related_table => 'damage_intakes', p_related_id => v_id,
        p_dedupe => 'review_damage_match:' || v_id, p_created_by => p_by);
  end if;
  return v_id;
end $$;

create or replace function app.confirm_damage_match(p_intake uuid, p_by uuid, p_choice jsonb default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  di damage_intakes;
  c jsonb;
begin
  if not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin confirms a damage match' using errcode = '42501';
  end if;
  select * into di from damage_intakes where id = p_intake for update;
  if di.status not in ('logged', 'matched') then raise exception 'This damage is already %', di.status using errcode = '23514'; end if;
  c := case when p_choice is null then di.match_evidence -> 'suggested'
            when p_choice ? 'index' then di.match_evidence -> 'candidates' -> ((p_choice ->> 'index')::integer)
            else p_choice end;
  if c is null or jsonb_typeof(c) = 'null' then raise exception 'Choose who had the car' using errcode = '22023'; end if;
  perform app.apply_damage_match(p_intake, c, p_by, case when p_choice is null or p_choice ? 'index' then di.match_confidence else 'low' end);
end $$;

-- Bill matched damage (an Admin: any damage line is an escalation). The incident is opened with
-- 0020's functions (record_late_damage on the booking's return report, otherwise open_incident),
-- the estimate or invoice is its cost, and the lines come from 0020's assessment, which applies
-- the threshold rule: at cost plus the administration fee under the deductible, otherwise a claim
-- with the deductible and the claim fee. An Owner Booking: nothing under the deductible; the
-- deductible as an owner deduction when a claim is made. Staff or nobody: CarmaCars bears it.
create or replace function app.bill_damage(p_intake uuid, p_admin uuid, p_now timestamptz default now(), p_override_reason text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  di damage_intakes;
  b bookings;
  cl claims;
  v_inc uuid;
  v_res jsonb;
  v_route text;
  v_exp uuid;
  v_stmt uuid;
  v_ret condition_reports;
begin
  if not app.user_is_admin(p_admin) then
    raise exception 'An Admin bills damage' using errcode = '42501';
  end if;
  select * into di from damage_intakes where id = p_intake for update;
  if di.id is null then raise exception 'Damage intake % not found', p_intake; end if;
  if di.status <> 'matched' then raise exception 'Confirm who had the car first' using errcode = '23514'; end if;
  if di.cost_cents is null or di.cost_document_id is null or di.cost_kind is null then
    raise exception 'Attach the estimate or invoice with its amount first' using errcode = '23514';
  end if;
  if di.booking_id is not null then select * into b from bookings where id = di.booking_id; end if;

  -- the incident
  v_inc := di.incident_id;
  if v_inc is null then
    if b.id is not null then
      select * into v_ret from condition_reports where booking_id = b.id and kind = 'return';
    end if;
    if b.id is not null and b.status in ('returned', 'closed') and v_ret.id is not null and di.after_report_id = v_ret.id then
      v_inc := app.record_late_damage(b.id, p_admin, jsonb_build_object('location', di.location, 'description', di.description,
                                       'photos', di.photos, 'report_to_renter', true), p_now, p_override_reason);
    else
      v_inc := app.open_incident('damage_found_later', di.vehicle_id, p_admin,
                 jsonb_build_object('description', format('Damage found %s: %s, %s', to_char(di.found_at at time zone 'America/Toronto', 'YYYY-MM-DD'),
                                                          di.location, di.description),
                                    'occurred_at', coalesce(di.occurred_at, di.window_to, di.found_at), 'drivable', true),
                 b.id, 'staff', p_now);
    end if;
    if di.matched_to = 'staff' then update incidents set staff_user_id = di.staff_user_id where id = v_inc; end if;
    insert into incident_costs (incident_id, kind, description, amount_cents, shop_name, approved_shop, document_id, created_by)
    values (v_inc, di.cost_kind, di.description, di.cost_cents, di.shop_name, true, di.cost_document_id, p_admin);
    update damage_intakes set incident_id = v_inc where id = p_intake;
  end if;

  if di.matched_to in ('renter', 'owner_booking') then
    if b.status not in ('returned', 'closed') then
      raise exception 'Booking % is still on rent: the damage is assessed at Check-in', b.booking_number using errcode = '23514';
    end if;
    perform app.assess_check_in(b.id, '{}'::jsonb, p_admin);
    select * into cl from claims where incident_id = v_inc;
    if di.matched_to = 'owner_booking' then
      v_route := case when cl.path = 'fleet_policy' then 'owner_deductible' else 'owner_repairs' end;
    else
      v_route := case when cl.path = 'fleet_policy' and not cl.denied_for_renter_breach then 'claim' else 'at_cost' end;
      v_res := app.charge_after_rental(b.id, p_admin, p_now);
      v_stmt := (v_res ->> 'statement_id')::uuid;
      if v_stmt is not null then
        perform app.emit_event('renter_extra_charge', 'booking_statement', v_stmt,
          jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'renter_id', b.renter_id, 'charge_kind', 'damage',
                             'incident_id', v_inc, 'damage_intake_id', p_intake, 'document_ids', jsonb_build_array(di.cost_document_id),
                             'total_cents', (select charges_cents + hst_cents from booking_statements where id = v_stmt), 'statement_id', v_stmt),
          'renter_extra_charge:' || v_stmt || ':damage');
      end if;
    end if;
  elsif di.matched_to = 'turo_only' then
    v_route := 'turo';
  elsif di.matched_to = 'owner_outside_program' then
    v_route := 'owner_repairs';
  else
    -- staff or nobody: CarmaCars bears the repair, noted against the staff member when known
    insert into company_expenses (expense_on, category, description, amount_cents, vehicle_id, staff_user_id, document_id, created_by)
    values (app.local_date(p_now), 'repair_absorbed', format('Damage %s: %s', di.intake_number, di.description), di.cost_cents,
            di.vehicle_id, di.staff_user_id, di.cost_document_id, p_admin)
    returning id into v_exp;
    v_route := 'company';
    update incidents set status = 'closed', closed_by = p_admin, closed_at = p_now where id = v_inc;
  end if;
  update damage_intakes set route = v_route, statement_id = v_stmt, company_expense_id = v_exp, status = 'billed' where id = p_intake;
  return jsonb_build_object('intake_id', p_intake, 'incident_id', v_inc, 'route', v_route, 'claim_id', cl.id, 'statement_id', v_stmt,
                            'company_expense_id', v_exp, 'charge', v_res);
end $$;

-- ================================================================ 8. company expenses (entered by hand)
create table company_expense_categories (
  code        text primary key,
  label       text not null,
  gl_account  text not null references gl_accounts (code),
  is_active   boolean not null default true
);
insert into company_expense_categories (code, label, gl_account) values
  ('repair_absorbed', 'Repair or vehicle cost CarmaCars bears', '5100'),
  ('toll_ticket_absorbed', 'Toll or ticket CarmaCars bears', '5110'),
  ('fleet_insurance', 'Fleet insurance premium', '5200'),
  ('tracker_service', 'Tracker service', '5200'),
  ('staff', 'Staff and contractors', '5200'),
  ('marketing', 'Marketing', '5200'),
  ('software', 'Software and services', '5200'),
  ('processing_fees', 'Processing fees not recorded on a payment', '5000'),
  ('other', 'Other', '5200');

create table company_expenses (
  id            uuid primary key default gen_random_uuid(),
  expense_on    date not null,
  category      text not null references company_expense_categories (code),
  description   text not null,
  amount_cents  bigint not null check (amount_cents > 0),     -- before HST
  hst_cents     bigint not null default 0 check (hst_cents >= 0),
  vehicle_id    uuid references vehicles (id),
  owner_id      uuid references owners (id),
  staff_user_id uuid references users (id),                   -- the staff member it is noted against
  document_id   uuid references documents (id),
  voided_at     timestamptz,
  void_reason   text,
  created_by    uuid references users (id),
  created_at    timestamptz not null default now(),
  check ((voided_at is null) = (void_reason is null))
);
create index company_expenses_month_idx on company_expenses (expense_on);
alter table damage_intakes add constraint damage_intakes_expense_fk foreign key (company_expense_id) references company_expenses (id);

-- A month that is final does not take new or changed expenses: they go in the current month.
create or replace function app.company_expense_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from company_statements s where s.statement_month = app.month_start(new.expense_on) and s.status = 'final')
     or (tg_op = 'UPDATE' and exists (select 1 from company_statements s where s.statement_month = app.month_start(old.expense_on) and s.status = 'final')) then
    raise exception 'The company statement for % is final: enter the expense in the current month', to_char(new.expense_on, 'YYYY-MM')
      using errcode = '23514';
  end if;
  return new;
end $$;

-- ================================================================ 9. work queues for tolls and damage
-- Every open notice in one list with its bucket and age; the four buckets the owner asked for.
create view toll_work_queue with (security_barrier = true) as
  select t.id, t.kind, t.authority, t.notice_number, t.external_ref, t.plate, t.vehicle_id, v.fleet_number,
         t.occurred_at, t.time_unknown, t.amount_cents, t.admin_fee_cents, t.received_on, t.due_on, t.charge_by,
         t.matched_to, t.booking_id, b.booking_number, t.match_confidence, t.match_evidence ->> 'reason' as match_reason,
         t.status, t.charged_from, t.notified_at, t.import_batch_id,
         case when t.status = 'logged' and coalesce(t.match_confidence, 'none') = 'none' then 'unmatched'
              when t.status = 'logged' then 'needs_review'
              when t.status = 'matched' and t.matched_to = 'renter' then 'matched_not_charged'
              when t.status = 'matched' and t.matched_to in ('owner_booking', 'owner_outside_program', 'turo_only') then 'matched_not_billed'
              when t.status = 'matched' and t.matched_to = 'staff' then 'matched_staff'
              when t.status = 'charged' and t.notified_at is null then 'charged_not_notified'
              when t.status = 'disputed' then 'disputed'
         end as bucket,
         app.today() - t.received_on as age_days,
         case when app.today() - t.received_on <= 2 then '0-2 days' when app.today() - t.received_on <= 7 then '3-7 days'
              when app.today() - t.received_on <= 30 then '8-30 days' else 'over 30 days' end as age_band,
         (t.due_on is not null and t.due_on <= app.today() + (app.settings()).toll_due_soon_days and t.paid_by_company_at is null) as due_soon,
         (t.charge_by is not null and t.charge_by < app.today() and t.status in ('logged', 'matched')) as past_charge_by
    from toll_tickets t
    left join vehicles v on v.id = t.vehicle_id
    left join bookings b on b.id = t.booking_id
   where (t.status in ('logged', 'matched', 'disputed') or (t.status = 'charged' and t.notified_at is null))
     and (app.is_admin() or app.va_has('finance', 'fleet'));

create view toll_work_queue_summary with (security_barrier = true) as
  select bucket, age_band, count(*) as notices, sum(amount_cents) as amount_cents, min(received_on) as oldest_received_on
    from toll_work_queue group by bucket, age_band;

create view damage_work_queue with (security_barrier = true) as
  select d.id, d.intake_number, d.vehicle_id, v.fleet_number, d.found_at, d.location, d.description, d.cost_cents,
         d.matched_to, d.booking_id, b.booking_number, d.match_confidence, d.match_evidence ->> 'reason' as match_reason, d.status,
         case when d.status = 'logged' and coalesce(d.match_confidence, 'none') = 'none' then 'unmatched'
              when d.status = 'logged' then 'needs_review'
              when d.status = 'matched' and d.cost_document_id is null then 'needs_estimate'
              when d.status = 'matched' then 'ready_to_bill' end as bucket,
         app.today() - app.local_date(d.created_at) as age_days
    from damage_intakes d left join vehicles v on v.id = d.vehicle_id left join bookings b on b.id = d.booking_id
   where d.status in ('logged', 'matched') and (app.is_admin() or app.va_has('finance', 'fleet'));

-- Daily from 06:00: notices still without a match after the set number of business days raise the
-- staff event and an Admin task (procedure 11: escalate when there is no match).
create or replace function app.job_toll_watch(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date := app.local_date(p_now);
  v_run uuid;
  v_n integer := 0;
  t record;
begin
  if app.local_hour(p_now) < 6 then return 'not_due'; end if;
  v_run := app.job_claim('toll-watch', v_day::text);
  if v_run is null then return 'already_run'; end if;
  begin
    for t in select tt.* from toll_tickets tt
              where tt.status = 'logged'
                and app.add_business_days(tt.received_on, (app.settings(v_day)).toll_unmatched_business_days) <= v_day
    loop
      perform app.raise_task(p_type => 'toll_unmatched',
          p_title => format('Notice for plate %s still unmatched since %s', t.plate, t.received_on),
          p_detail => coalesce(t.match_evidence ->> 'reason', 'not matched'), p_vehicle => t.vehicle_id,
          p_related_table => 'toll_tickets', p_related_id => t.id, p_dedupe => 'toll_unmatched:' || t.id,
          p_escalation_reason => 'no match after the set business days');
      perform app.emit_event('staff_toll_ticket_unmatched', 'toll_ticket', t.id,
        jsonb_build_object('notice_type', t.kind, 'vehicle_plate', t.plate, 'notice_amount_cents', t.amount_cents,
                           'received_on', t.received_on, 'notice_due_date', t.due_on, 'match_summary', t.match_evidence ->> 'reason'),
        'staff_toll_ticket_unmatched:' || t.id || ':' || t.received_on);
      v_n := v_n + 1;
    end loop;
    perform app.job_succeed(v_run, jsonb_build_object('day', v_day, 'unmatched', v_n));
    return 'succeeded';
  exception when others then
    perform app.job_fail(v_run, sqlerrm);
    return 'failed';
  end;
end $$;

-- ================================================================ 10. owner statements: coverage, credits, reissue
-- Gaps found in app.build_owner_statement() (0007) and fixed below:
--   1. a vehicle in the program with no activity had no block: every vehicle enrolled during the
--      month now gets one, even at zero, so the Owner sees every car every month;
--   2. a charge to the renter that raises Owner Revenue after the rental was paid out (mileage
--      overage or late extra days billed later by 0020) was never paid to the Owner: it is now an
--      Owner credit (owner_credits, kind later_rental_revenue) on the next statement;
--   3. a statement could not be corrected once approved: a versioned reissue (void and rebuild)
--      is added while its payout has not been sent;
--   4. no function recorded the statement as issued or the payout as paid.
alter table owner_statements
  add column if not exists version integer not null default 1,
  add column if not exists supersedes_statement_id uuid references owner_statements (id),
  add column if not exists credits_cents bigint not null default 0,
  add column if not exists voided_at timestamptz,
  add column if not exists voided_by uuid references users (id),
  add column if not exists void_reason text;
alter table owner_statements drop constraint if exists owner_statements_owner_id_statement_month_key;
create unique index owner_statements_one_live on owner_statements (owner_id, statement_month) where status <> 'void';
alter table owner_statement_vehicles add column if not exists credits_cents bigint not null default 0;

create table owner_credits (
  id                 uuid primary key default gen_random_uuid(),
  owner_id           uuid not null references owners (id),
  vehicle_id         uuid references vehicles (id),
  booking_id         uuid references bookings (id),
  kind               text not null check (kind in ('later_rental_revenue', 'correction')),
  description        text not null,
  amount_cents       bigint not null check (amount_cents > 0),
  incurred_on        date not null,
  status             text not null default 'open' check (status in ('open', 'credited', 'waived')),
  owner_statement_id uuid references owner_statements (id),
  created_by         uuid references users (id),
  created_at         timestamptz not null default now()
);
create index owner_credits_owner_idx on owner_credits (owner_id, status);

alter table owner_statement_lines add column if not exists owner_credit_id uuid references owner_credits (id);
alter table owner_statement_lines drop constraint if exists owner_statement_lines_line_type_check;
alter table owner_statement_lines add constraint owner_statement_lines_line_type_check check (line_type in (
  'rental', 'turo_trip', 'withheld', 'fees_deducted', 'owner_cost', 'refund_or_chargeback',
  'arrears_moved', 'kickback_earned', 'hst_on_payout', 'balance_brought_forward', 'later_revenue'));

-- a reissue gives back what the voided statement had deducted from an invoice
insert into status_transitions (entity, from_status, to_status, note)
select 'owner_invoice', f, 'in_arrears', 'the statement that deducted it was reissued'
  from unnest(array['deducted', 'partially_deducted']) f
 where not exists (select 1 from status_transitions x where x.entity = 'owner_invoice' and x.from_status = f and x.to_status = 'in_arrears');

-- Owner Revenue raised after the booking was paid out: the difference becomes an Owner credit,
-- once every Owner Revenue line is collected. The kickback and the Revenue Share percentage stay
-- as they were on the paid split. Returns the credit, or null.
create or replace function app.sync_later_owner_revenue(p_booking uuid)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  s booking_splits;
  b bookings;
  v_rental bigint; v_mileage bigint; v_ref_rental bigint; v_ref_mileage bigint; v_chargeback bigint; v_uncollected bigint;
  v_pay bigint; v_ded bigint; v_cred bigint; v_delta bigint;
  v_id uuid;
begin
  select * into s from booking_splits where booking_id = p_booking;
  if s.booking_id is null or s.owner_statement_id is null then return null; end if;
  select * into b from bookings where id = p_booking;
  select coalesce(sum(li.amount_cents) filter (where li.charge_type in ('rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'late_return_extra_days')), 0),
         coalesce(sum(li.amount_cents) filter (where li.charge_type = 'mileage_overage'), 0),
         coalesce(sum(li.amount_cents) filter (where li.revenue_class = 'owner_revenue' and not exists (
             select 1 from payments p where p.id = li.payment_id and p.status = 'succeeded')), 0)
    into v_rental, v_mileage, v_uncollected
    from booking_line_items li where li.booking_id = p_booking and li.voided_at is null and li.charged_to_renter;
  if v_uncollected <> 0 then return null; end if;
  select coalesce(sum(ra.amount_cents) filter (where li.charge_type in ('rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'late_return_extra_days')), 0),
         coalesce(sum(ra.amount_cents) filter (where li.charge_type = 'mileage_overage'), 0)
    into v_ref_rental, v_ref_mileage
    from refund_allocations ra join refunds r on r.id = ra.refund_id and r.status in ('approved', 'processing', 'paid')
    join booking_line_items li on li.id = ra.line_item_id
   where li.booking_id = p_booking and li.voided_at is null;
  select coalesce(sum(owner_revenue_reversed_cents) filter (where status = 'lost'), 0) into v_chargeback from disputes where booking_id = p_booking;
  select x.owner_payout_cents into v_pay
    from public.calc_split(greatest(v_rental - v_ref_rental - v_chargeback, 0), v_mileage - v_ref_mileage, s.kickback_cents, s.company_share_bps) x;
  select coalesce(sum(amount_cents), 0) into v_ded from owner_deductions
   where booking_id = p_booking and kind in ('refund_share', 'chargeback_share') and status <> 'waived';
  select coalesce(sum(amount_cents), 0) into v_cred from owner_credits
   where booking_id = p_booking and kind = 'later_rental_revenue' and status <> 'waived';
  v_delta := v_pay - (s.owner_payout_cents - v_ded + v_cred);
  if v_delta > 0 then
    insert into owner_credits (owner_id, vehicle_id, booking_id, kind, description, amount_cents, incurred_on)
    values (s.owner_id, s.vehicle_id, p_booking, 'later_rental_revenue',
            format('Booking %s: Owner''s share of charges billed after it was paid out', b.booking_number), v_delta, app.today())
    returning id into v_id;
  end if;
  return v_id;
end $$;

-- Build (or rebuild while it is a draft) one Owner's statement for a month. 0007's builder with the
-- four gaps above fixed; everything else is unchanged.
create or replace function app.build_owner_statement(p_owner uuid, p_month date, p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v_month date := app.month_start(p_month);
  v_month_end date := (app.month_start(p_month) + interval '1 month - 1 day')::date;
  o owners;
  v_id uuid;
  v_status text;
  r record; inv record; other record;
  v_rev bigint; v_share bigint; v_withheld bigint; v_net bigint; v_avail bigint;
  v_take bigint; v_fee_part bigint; v_late_part bigint; v_need bigint;
  v_fees bigint; v_late bigint; v_costs bigint; v_refunds bigint;
  v_moved bigint := 0;
  v_kick bigint; v_hst bigint := 0; v_total bigint; v_payable bigint; v_net_all bigint;
  v_credits bigint; v_credits_all bigint := 0;
  v_prev owner_statements;
begin
  select * into o from owners where id = p_owner;
  if not found then raise exception 'Owner % not found', p_owner; end if;

  select id, status into v_id, v_status from owner_statements where owner_id = p_owner and statement_month = v_month and status <> 'void';
  if v_id is not null and v_status <> 'draft' then
    raise exception 'The % statement for this Owner is already %', to_char(v_month, 'YYYY-MM'), v_status using errcode = '23514';
  end if;
  if v_id is null then
    select * into v_prev from owner_statements where owner_id = p_owner and statement_month = v_month and status = 'void'
     order by version desc limit 1;
    insert into owner_statements (owner_id, statement_month, payout_date, built_by, version, supersedes_statement_id)
    values (p_owner, v_month, app.payout_date(v_month), p_by, coalesce(v_prev.version, 0) + 1, v_prev.id) returning id into v_id;
  else
    delete from owner_statement_lines where owner_statement_id = v_id;
    delete from owner_statement_vehicles where owner_statement_id = v_id;
    update owner_statements set built_at = now(), built_by = p_by, payout_date = app.payout_date(v_month) where id = v_id;
  end if;

  -- bring every finished booking's split up to date first
  -- (its own vehicles' bookings, and bookings on other vehicles whose renter this Owner referred)
  for r in select b.id from bookings b
            where (b.owner_id = p_owner or b.referrer_owner_id = p_owner) and b.booking_type <> 'owner'
              and b.status in ('returned', 'closed', 'cancelled', 'no_show')
              and not exists (select 1 from booking_splits s where s.booking_id = b.id and s.owner_statement_id is not null)
  loop
    perform app.compute_booking_split(r.id);
  end loop;
  -- Owner Revenue raised on bookings already paid out (gap 2)
  for r in select s.booking_id from booking_splits s join bookings b on b.id = s.booking_id
            where s.owner_id = p_owner and s.owner_statement_id is not null and b.status in ('returned', 'closed')
  loop
    perform app.sync_later_owner_revenue(r.booking_id);
  end loop;

  -- one block per vehicle with anything to show
  for r in
    select v.id as vehicle_id
      from vehicles v
     where v.owner_id = p_owner
       and (exists (select 1 from booking_splits s where s.vehicle_id = v.id and s.owner_id = p_owner
                      and s.owner_statement_id is null and s.payout_month <= v_month and s.status <> 'reversed' and s.uncollected_cents = 0)
         or exists (select 1 from turo_trips t where t.vehicle_id = v.id and t.owner_statement_id is null and t.statement_month <= v_month and t.received_at is not null)
         or exists (select 1 from owner_invoices i where i.vehicle_id = v.id and i.status in ('in_arrears', 'partially_deducted'))
         or exists (select 1 from owner_deductions d where d.vehicle_id = v.id and d.owner_id = p_owner and d.status = 'open' and d.incurred_on <= v_month_end)
         or exists (select 1 from owner_credits c where c.vehicle_id = v.id and c.owner_id = p_owner and c.status = 'open' and c.incurred_on <= v_month_end)
         -- every vehicle in the program during the month, even with nothing to show (gap 1)
         or (v.enrollment_date is not null and v.enrollment_date <= v_month_end
             and (app.vehicle_fee_end(v.id) is null or app.vehicle_fee_end(v.id) >= v_month)))
     order by v.fleet_number nulls last, v.created_at, v.id
  loop
    -- each rental ended (and each cancellation that kept part of the rental charge)
    insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, booking_id, starts_on, ends_on,
        rental_charge_cents, mileage_overage_cents, refunds_cents, chargebacks_cents, kickback_cents,
        owner_revenue_cents, revenue_share_cents, amount_cents)
    select v_id, r.vehicle_id, 'rental', 'Booking ' || b.booking_number, b.id,
           app.local_date(b.pickup_at), s.counts_on,
           s.rental_charge_cents, s.mileage_overage_cents, s.refunded_cents, s.chargeback_cents, s.kickback_cents,
           s.owner_revenue_cents, s.company_share_cents, s.owner_payout_cents
      from booking_splits s join bookings b on b.id = s.booking_id
     where s.vehicle_id = r.vehicle_id and s.owner_id = p_owner and s.owner_statement_id is null
       and s.payout_month <= v_month and s.status <> 'reversed' and s.uncollected_cents = 0
     order by s.counts_on, b.booking_number;

    -- each Turo trip: the split applies to the Turo Payout
    insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, turo_trip_id, starts_on, ends_on,
        turo_gross_cents, turo_fees_cents, owner_revenue_cents, revenue_share_cents, amount_cents)
    select v_id, r.vehicle_id, 'turo_trip', 'Turo trip ' || t.turo_trip_ref, t.id,
           app.local_date(t.starts_at), app.local_date(t.ends_at),
           t.gross_cents, t.turo_fees_cents, t.net_payout_cents, t.revenue_share_cents, t.owner_payout_cents
      from turo_trips t
     where t.vehicle_id = r.vehicle_id and t.owner_statement_id is null and t.statement_month <= v_month and t.received_at is not null;

    select coalesce(sum(owner_revenue_cents), 0), coalesce(sum(revenue_share_cents), 0), coalesce(sum(amount_cents), 0)
      into v_rev, v_share, v_net
      from owner_statement_lines where owner_statement_id = v_id and vehicle_id = r.vehicle_id and line_type in ('rental', 'turo_trip');

    -- Owner Revenue in dispute is withheld from the payout
    select coalesce(sum(least(s.withheld_cents, s.owner_payout_cents)), 0) into v_withheld
      from booking_splits s
     where s.vehicle_id = r.vehicle_id and s.owner_id = p_owner and s.owner_statement_id is null
       and s.payout_month <= v_month and s.status <> 'reversed' and s.uncollected_cents = 0 and s.withheld_cents > 0;
    if v_withheld > 0 then
      insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, amount_cents)
      values (v_id, r.vehicle_id, 'withheld', 'Owner Revenue in dispute, withheld', -v_withheld);
      v_net := v_net - v_withheld;
    end if;

    -- unpaid Fees and Late Fees after a failed retry: from this vehicle's revenue
    v_avail := greatest(v_net, 0);
    v_fees := 0; v_late := 0;
    for inv in select * from owner_invoices i
                where i.vehicle_id = r.vehicle_id and i.status in ('in_arrears', 'partially_deducted') and i.balance_cents > 0
                order by i.billing_date, i.invoice_number
    loop
      v_take := least(inv.balance_cents, v_avail);
      if v_take > 0 then
        -- Fees (with HST) are settled before the Late Fee
        v_fee_part := least(v_take, greatest(inv.fees_cents + inv.hst_cents - inv.paid_cents - inv.deducted_cents, 0));
        v_late_part := v_take - v_fee_part;
        insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_invoice_id,
            fee_cents, late_fee_cents, amount_cents)
        values (v_id, r.vehicle_id, 'fees_deducted', 'Invoice ' || inv.invoice_number, inv.id, v_fee_part, v_late_part, -v_take);
        v_fees := v_fees + v_fee_part; v_late := v_late + v_late_part;
        v_avail := v_avail - v_take;
      end if;
    end loop;

    -- Owner costs CarmaCars paid, and the Owner's share of an earlier refund or chargeback
    insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_deduction_id, booking_id, amount_cents)
    select v_id, r.vehicle_id,
           case when d.kind in ('refund_share', 'chargeback_share') then 'refund_or_chargeback' else 'owner_cost' end,
           d.description, d.id, d.booking_id, -d.amount_cents
      from owner_deductions d
     where d.vehicle_id = r.vehicle_id and d.owner_id = p_owner and d.status = 'open' and d.incurred_on <= v_month_end;
    select coalesce(-sum(amount_cents) filter (where line_type = 'owner_cost'), 0),
           coalesce(-sum(amount_cents) filter (where line_type = 'refund_or_chargeback'), 0)
      into v_costs, v_refunds
      from owner_statement_lines where owner_statement_id = v_id and vehicle_id = r.vehicle_id;

    -- Owner credits: Owner Revenue billed after the booking was paid out
    insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_credit_id, booking_id, amount_cents)
    select v_id, r.vehicle_id, 'later_revenue', c.description, c.id, c.booking_id, c.amount_cents
      from owner_credits c
     where c.vehicle_id = r.vehicle_id and c.owner_id = p_owner and c.status = 'open' and c.incurred_on <= v_month_end;
    select coalesce(sum(amount_cents), 0) into v_credits
      from owner_statement_lines where owner_statement_id = v_id and vehicle_id = r.vehicle_id and line_type = 'later_revenue';
    v_credits_all := v_credits_all + v_credits;

    insert into owner_statement_vehicles (owner_statement_id, vehicle_id, owner_revenue_cents, revenue_share_cents,
        withheld_cents, net_earnings_cents, fees_deducted_cents, late_fees_deducted_cents,
        owner_costs_deducted_cents, refund_chargeback_deducted_cents, credits_cents, payable_cents)
    values (v_id, r.vehicle_id, v_rev, v_share, v_withheld, v_net, v_fees, v_late, v_costs, v_refunds, v_credits,
            v_net - v_fees - v_late - v_costs - v_refunds + v_credits);
  end loop;

  -- deductions not tied to a vehicle (a reversed kickback, an agreed amount)
  insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_deduction_id, booking_id, amount_cents)
  select v_id, null, 'owner_cost', d.description, d.id, d.booking_id, -d.amount_cents
    from owner_deductions d
   where d.vehicle_id is null and d.owner_id = p_owner and d.status = 'open' and d.incurred_on <= v_month_end;

  -- Balance still left: a debt payable on demand, deducted from the Owner's other vehicles
  for inv in select i.*, i.balance_cents - coalesce((select -sum(l.amount_cents) from owner_statement_lines l
                                  where l.owner_statement_id = v_id and l.owner_invoice_id = i.id), 0) as still_owed
               from owner_invoices i
              where i.owner_id = p_owner and i.status in ('in_arrears', 'partially_deducted') and i.balance_cents > 0
              order by i.billing_date, i.invoice_number
  loop
    v_need := inv.still_owed;
    for other in select sv.vehicle_id,
                        sv.payable_cents - coalesce((select sum(-l.amount_cents) from owner_statement_lines l
                            where l.owner_statement_id = v_id and l.line_type = 'arrears_moved' and l.vehicle_id = sv.vehicle_id), 0) as free
                   from owner_statement_vehicles sv
                  where sv.owner_statement_id = v_id and sv.vehicle_id <> inv.vehicle_id
                  order by sv.payable_cents desc
    loop
      exit when v_need <= 0;
      v_take := least(v_need, greatest(other.free, 0));
      if v_take > 0 then
        insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_invoice_id, from_vehicle_id, amount_cents)
        values (v_id, other.vehicle_id, 'arrears_moved', 'Arrears on invoice ' || inv.invoice_number, inv.id, inv.vehicle_id, -v_take);
        v_moved := v_moved + v_take;
        v_need := v_need - v_take;
      end if;
    end loop;
  end loop;

  -- Referral Kickbacks this Owner earned: paid with the next payout
  insert into owner_statement_lines (owner_statement_id, line_type, description, referral_kickback_id, booking_id,
      rental_charge_cents, amount_cents)
  select v_id, 'kickback_earned', 'Referral Kickback, booking ' || b.booking_number, k.id, k.booking_id, k.base_cents, k.amount_cents
    from referral_kickbacks k join bookings b on b.id = k.booking_id
   where k.referrer_owner_id = p_owner and k.status = 'earned' and k.owner_statement_id is null and k.earned_on <= v_month_end;
  select coalesce(sum(amount_cents), 0) into v_kick
    from owner_statement_lines where owner_statement_id = v_id and line_type = 'kickback_earned';

  select coalesce(sum(payable_cents), 0), coalesce(sum(net_earnings_cents), 0) into v_payable, v_net_all
    from owner_statement_vehicles where owner_statement_id = v_id;
  v_payable := v_payable - coalesce((select sum(-amount_cents) from owner_statement_lines
                                      where owner_statement_id = v_id and vehicle_id is null and line_type = 'owner_cost'), 0);

  -- HST is added only when the Owner's HST number is on file
  if o.hst_number is not null and btrim(o.hst_number) <> '' and v_net_all + v_credits_all > 0 then
    v_hst := public.calc_hst(v_net_all + v_credits_all, (app.settings(v_month)).hst_bps);
    insert into owner_statement_lines (owner_statement_id, line_type, description, amount_cents)
    values (v_id, 'hst_on_payout', 'HST on payout, registration ' || o.hst_number, v_hst);
  end if;
  if o.balance_carried_forward_cents <> 0 then
    insert into owner_statement_lines (owner_statement_id, line_type, description, amount_cents)
    values (v_id, 'balance_brought_forward', 'Balance brought forward', o.balance_carried_forward_cents);
  end if;

  v_total := v_payable - v_moved + v_kick + v_hst + o.balance_carried_forward_cents;

  update owner_statements st
     set owner_revenue_cents = coalesce((select sum(owner_revenue_cents) from owner_statement_vehicles where owner_statement_id = v_id), 0),
         revenue_share_cents = coalesce((select sum(revenue_share_cents) from owner_statement_vehicles where owner_statement_id = v_id), 0),
         net_earnings_cents = v_net_all,
         deductions_cents = coalesce((select sum(fees_deducted_cents + late_fees_deducted_cents + owner_costs_deducted_cents + refund_chargeback_deducted_cents)
                                        from owner_statement_vehicles where owner_statement_id = v_id), 0),
         vehicles_payable_cents = v_payable,
         credits_cents = v_credits_all,
         arrears_moved_cents = v_moved,
         kickbacks_earned_cents = v_kick,
         hst_on_payout_cents = v_hst,
         balance_brought_forward_cents = o.balance_carried_forward_cents,
         payout_cents = greatest(v_total, 0),
         balance_carried_forward_cents = least(v_total, 0),
         is_final = not exists (select 1 from vehicles v where v.owner_id = p_owner and v.status not in ('exited', 'total_loss', 'declined'))
   where st.id = v_id;
  return v_id;
end $$;

-- An Admin approves the run (0007's function; credits are now applied too).
create or replace function app.approve_owner_statement(p_statement uuid, p_admin uuid)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  st owner_statements;
  l record;
  v_payout uuid;
begin
  if not exists (select 1 from user_roles where user_id = p_admin and role = 'admin') then
    raise exception 'Only an Admin approves a payout run' using errcode = '42501';
  end if;
  select * into st from owner_statements where id = p_statement for update;
  if st.status <> 'draft' then
    raise exception 'Statement % is already %', st.statement_number, st.status using errcode = '23514';
  end if;

  for l in select owner_invoice_id, sum(-amount_cents) as taken
             from owner_statement_lines
            where owner_statement_id = p_statement and owner_invoice_id is not null
              and line_type in ('fees_deducted', 'arrears_moved')
            group by owner_invoice_id
  loop
    update owner_invoices
       set deducted_cents = deducted_cents + l.taken,
           status = case when balance_cents - l.taken <= 0 then 'deducted' else 'partially_deducted' end
     where id = l.owner_invoice_id;
  end loop;

  update owner_deductions d set status = 'deducted', owner_statement_id = p_statement
    from owner_statement_lines sl where sl.owner_statement_id = p_statement and sl.owner_deduction_id = d.id;
  update owner_credits c set status = 'credited', owner_statement_id = p_statement
    from owner_statement_lines sl where sl.owner_statement_id = p_statement and sl.owner_credit_id = c.id;
  update referral_kickbacks k set owner_statement_id = p_statement
    from owner_statement_lines sl where sl.owner_statement_id = p_statement and sl.referral_kickback_id = k.id;
  update booking_splits s set owner_statement_id = p_statement, status = case when s.status = 'provisional' then 'final' else s.status end
    from owner_statement_lines sl where sl.owner_statement_id = p_statement and sl.line_type = 'rental' and sl.booking_id = s.booking_id;
  update turo_trips t set owner_statement_id = p_statement
    from owner_statement_lines sl where sl.owner_statement_id = p_statement and sl.turo_trip_id = t.id;
  update owners set balance_carried_forward_cents = st.balance_carried_forward_cents where id = st.owner_id;

  update owner_statements set status = 'approved', approved_by = p_admin, approved_at = now() where id = p_statement;

  if st.payout_cents > 0 then
    insert into payouts (payee_type, owner_id, kind, owner_statement_id, amount_cents, hst_cents, method,
                         scheduled_for, status, prepared_by, approved_by, approved_at)
    select 'owner', st.owner_id,
           case when not exists (select 1 from vehicles v where v.owner_id = st.owner_id and v.management_mode <> 'turo_only')
                then 'turo_only_statement' else 'owner_statement' end,
           p_statement, st.payout_cents, st.hst_on_payout_cents, o.payout_method,
           st.payout_date, 'approved', st.built_by, p_admin, now()
      from owners o where o.id = st.owner_id
    returning id into v_payout;
  else
    -- nothing to transfer: kickbacks earned were set against what the Owner owes
    update referral_kickbacks set status = 'paid', paid_at = now()
     where owner_statement_id = p_statement and status = 'earned';
  end if;
  return v_payout;
end $$;



-- Reissue an approved statement as a corrected version: the old one is voided and everything it
-- applied is given back (deductions, credits, kickbacks, splits, Turo trips, invoice deductions,
-- the Owner's balance), its payout is cancelled, and a new draft (version + 1) is built from the
-- source records as they are now. Only while the payout has not been sent: after that a
-- correction is a line on the next statement.
create or replace function app.reissue_owner_statement(p_statement uuid, p_admin uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  st owner_statements;
  l record;
  v_new uuid;
begin
  if not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin reissues a statement' using errcode = '42501';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then raise exception 'Give the reason for the correction' using errcode = '22023'; end if;
  select * into st from owner_statements where id = p_statement for update;
  if st.id is null then raise exception 'Statement % not found', p_statement; end if;
  if st.status = 'draft' then raise exception 'A draft is corrected by rebuilding it' using errcode = '23514'; end if;
  if st.status <> 'approved' or exists (select 1 from payouts p where p.owner_statement_id = p_statement and p.status in ('sent', 'paid')) then
    raise exception 'Statement % is already paid out: put the correction on the next statement', st.statement_number using errcode = '23514';
  end if;
  update payouts set status = 'cancelled', failure_reason = 'statement reissued: ' || p_reason
   where owner_statement_id = p_statement and status not in ('cancelled', 'paid', 'sent');
  for l in select owner_invoice_id, sum(-amount_cents) as taken from owner_statement_lines
            where owner_statement_id = p_statement and owner_invoice_id is not null and line_type in ('fees_deducted', 'arrears_moved')
            group by owner_invoice_id
  loop
    update owner_invoices
       set deducted_cents = deducted_cents - l.taken,
           status = case when deducted_cents - l.taken > 0 then 'partially_deducted' else 'in_arrears' end
     where id = l.owner_invoice_id;
  end loop;
  update owner_deductions set status = 'open', owner_statement_id = null where owner_statement_id = p_statement and status = 'deducted';
  update owner_credits set status = 'open', owner_statement_id = null where owner_statement_id = p_statement and status = 'credited';
  update referral_kickbacks set owner_statement_id = null, status = case when status = 'paid' then 'earned' else status end,
                                paid_at = case when status = 'paid' then null else paid_at end
   where owner_statement_id = p_statement and status in ('earned', 'paid');
  -- credits for later revenue on these bookings are worked out again with the fresh split
  update owner_credits set status = 'waived'
   where kind = 'later_rental_revenue' and status = 'open'
     and booking_id in (select booking_id from booking_splits where owner_statement_id = p_statement);
  update booking_splits set owner_statement_id = null where owner_statement_id = p_statement;
  update turo_trips set owner_statement_id = null where owner_statement_id = p_statement;
  update owners set balance_carried_forward_cents = st.balance_brought_forward_cents where id = st.owner_id;
  update owner_statements set status = 'void', voided_at = now(), voided_by = p_admin, void_reason = p_reason where id = p_statement;
  v_new := app.build_owner_statement(st.owner_id, st.statement_month, p_admin);
  return v_new;
end $$;

-- The statement PDF has been rendered and is sent to the Owner (T26). Approved or paid only.
create or replace function app.issue_owner_statement(p_statement uuid, p_by uuid, p_document uuid default null, p_now timestamptz default now())
returns void language plpgsql security definer set search_path = public, app as $$
declare
  st owner_statements;
begin
  if not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin issues a statement' using errcode = '42501';
  end if;
  select * into st from owner_statements where id = p_statement for update;
  if st.status not in ('approved', 'paid') then
    raise exception 'Statement % is %: only an approved statement is sent', st.statement_number, st.status using errcode = '23514';
  end if;
  update owner_statements set sent_at = coalesce(sent_at, p_now), document_id = coalesce(p_document, document_id) where id = p_statement;
  perform app.emit_event('owner_statement_ready', 'owner_statement', p_statement,
    jsonb_build_object('owner_id', st.owner_id, 'statement_month', st.statement_month, 'payout_cents', st.payout_cents,
                       'payout_date', st.payout_date, 'version', st.version, 'document_id', coalesce(p_document, st.document_id)),
    'owner_statement_ready:' || p_statement || ':v' || st.version);
end $$;

-- An Admin records the bank transfer of a statement's payout: sent, then paid, with the reference.
create or replace function app.record_owner_payout(p_statement uuid, p_admin uuid, p_reference text, p_paid_at timestamptz default now())
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  p payouts;
begin
  if not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin records a payout as paid' using errcode = '42501';
  end if;
  if btrim(coalesce(p_reference, '')) = '' then raise exception 'Give the bank reference' using errcode = '22023'; end if;
  select * into p from payouts where owner_statement_id = p_statement and status not in ('cancelled', 'failed') for update;
  if p.id is null then raise exception 'This statement has no payout to record' using errcode = '23514'; end if;
  if p.status = 'paid' then return p.id; end if;
  if p.status not in ('approved', 'sent') then
    raise exception 'The payout is %: an Admin approves it first', p.status using errcode = '23514';
  end if;
  if p.status = 'approved' then update payouts set status = 'sent', reference = p_reference where id = p.id; end if;
  update payouts set status = 'paid', paid_at = p_paid_at, reference = p_reference where id = p.id;
  return p.id;
end $$;

-- The owner portal's statement: every vehicle block with each line and the booking behind it.
-- Staff with Finance or an Admin see any statement; the Owner sees their own once approved.
create or replace function app.owner_statement_breakdown(p_statement uuid, p_by uuid)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  st owner_statements;
begin
  select * into st from owner_statements where id = p_statement;
  if st.id is null then raise exception 'Statement % not found', p_statement; end if;
  if not (app.user_runs_finance(p_by)
          or (st.status in ('approved', 'paid') and exists (select 1 from owners o where o.id = st.owner_id and o.user_id = p_by))) then
    raise exception 'This statement is not available to you' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'statement_id', st.id, 'statement_number', st.statement_number, 'statement_month', st.statement_month, 'version', st.version,
    'status', st.status, 'payout_date', st.payout_date, 'payout_cents', st.payout_cents,
    'balance_carried_forward_cents', st.balance_carried_forward_cents, 'is_final', st.is_final,
    'vehicles', (select coalesce(jsonb_agg(jsonb_build_object(
        'vehicle_id', sv.vehicle_id, 'fleet_number', v.fleet_number, 'plate', v.plate, 'vehicle', v.year || ' ' || v.make || ' ' || v.model,
        'management_mode', v.management_mode, 'owner_revenue_cents', sv.owner_revenue_cents, 'revenue_share_cents', sv.revenue_share_cents,
        'net_earnings_cents', sv.net_earnings_cents, 'fees_deducted_cents', sv.fees_deducted_cents, 'late_fees_deducted_cents', sv.late_fees_deducted_cents,
        'owner_costs_deducted_cents', sv.owner_costs_deducted_cents, 'refund_chargeback_deducted_cents', sv.refund_chargeback_deducted_cents,
        'credits_cents', sv.credits_cents, 'payable_cents', sv.payable_cents,
        'lines', (select coalesce(jsonb_agg(jsonb_build_object('line_type', l.line_type, 'description', l.description, 'booking_id', l.booking_id,
                    'booking_number', bk.booking_number, 'starts_on', l.starts_on, 'ends_on', l.ends_on, 'rental_charge_cents', l.rental_charge_cents,
                    'mileage_overage_cents', l.mileage_overage_cents, 'refunds_cents', l.refunds_cents, 'chargebacks_cents', l.chargebacks_cents,
                    'kickback_cents', l.kickback_cents, 'owner_revenue_cents', l.owner_revenue_cents, 'revenue_share_cents', l.revenue_share_cents,
                    'fee_cents', l.fee_cents, 'late_fee_cents', l.late_fee_cents, 'amount_cents', l.amount_cents)
                    order by l.starts_on nulls last, l.line_type, l.id), '[]'::jsonb)
                    from owner_statement_lines l left join bookings bk on bk.id = l.booking_id
                   where l.owner_statement_id = st.id and l.vehicle_id = sv.vehicle_id))
        order by v.fleet_number nulls last, v.id), '[]'::jsonb)
        from owner_statement_vehicles sv join vehicles v on v.id = sv.vehicle_id where sv.owner_statement_id = st.id),
    'owner_lines', (select coalesce(jsonb_agg(jsonb_build_object('line_type', l.line_type, 'description', l.description, 'booking_number', bk.booking_number,
                     'from_vehicle_id', l.from_vehicle_id, 'amount_cents', l.amount_cents) order by l.line_type, l.id), '[]'::jsonb)
                     from owner_statement_lines l left join bookings bk on bk.id = l.booking_id
                    where l.owner_statement_id = st.id and l.vehicle_id is null));
end $$;

-- The same lines as a view, for staff reports and the owner portal (approved statements only for an Owner).
create view owner_statement_vehicle_lines with (security_barrier = true) as
  select s.id as statement_id, s.statement_number, s.owner_id, s.statement_month, s.version, s.status,
         l.vehicle_id, v.fleet_number, v.plate, l.line_type, l.description, l.booking_id, bk.booking_number,
         l.starts_on, l.ends_on, l.rental_charge_cents, l.mileage_overage_cents, l.refunds_cents, l.chargebacks_cents,
         l.kickback_cents, l.owner_revenue_cents, l.revenue_share_cents, l.fee_cents, l.late_fee_cents, l.amount_cents
    from owner_statement_lines l
    join owner_statements s on s.id = l.owner_statement_id
    left join vehicles v on v.id = l.vehicle_id
    left join bookings bk on bk.id = l.booking_id
   where app.is_admin() or app.va_has('finance') or (app.is_my_owner(s.owner_id) and s.status in ('approved', 'paid'));

-- ================================================================ 11. CarmaCars' own monthly statements
-- One statement per month, the month a rental ends (the owner statements' month). Basis:
--   earned  rentals, their charges and owner fees by the month they count in (a later-charge
--           statement counts in the month it is issued); the default for revenue columns
--   cash    payments, refunds and payouts by the day the money moved (cash_* columns, refunds)
--   point in time  deposits held and claim balances, as at the build
-- Lines at three levels (vehicle, owner, total) with the same columns; the owner level adds the
-- statement payout and deductions; the total adds investor returns, costs not tied to a vehicle
-- and payments not tied to anything.
create table company_statements (
  id            uuid primary key default gen_random_uuid(),
  statement_month date not null unique check (extract(day from statement_month) = 1),
  status        text not null default 'draft' check (status in ('draft', 'final')),
  version       integer not null default 1,
  basis_note    text not null default 'Earned by the month a rental ends; cash columns by the day money moved; deposits and claim balances as at the build',
  checks        jsonb not null default '[]'::jsonb,
  ties_ok       boolean not null default false,
  tie_problems  text,
  built_by      uuid references users (id),
  built_at      timestamptz not null default now(),
  finalized_by  uuid references users (id),
  finalized_at  timestamptz,
  document_id   uuid references documents (id),
  check (status <> 'final' or (ties_ok and finalized_by is not null))
);

create table company_statement_lines (
  id              uuid primary key default gen_random_uuid(),
  statement_id    uuid not null references company_statements (id) on delete cascade,
  level           text not null check (level in ('vehicle', 'owner', 'total')),
  vehicle_id      uuid references vehicles (id),
  owner_id        uuid references owners (id),
  label           text,
  management_mode text,
  billing_case    text,
  days_in_program numeric(9,2) not null default 0,
  days_available  numeric(9,2) not null default 0,
  days_rented     numeric(9,2) not null default 0,
  owner_days      numeric(9,2) not null default 0,
  utilization_bps integer not null default 0,
  rentals_ended   integer not null default 0,
  billable_days   integer not null default 0,
  rental_revenue_cents     bigint not null default 0,  -- Rental Charge after discounts, refunds and chargebacks, with extra days
  mileage_cents            bigint not null default 0,
  kickbacks_cents          bigint not null default 0,
  owner_revenue_cents      bigint not null default 0,
  revenue_share_cents      bigint not null default 0,  -- CarmaCars' share of rentals (4000)
  owner_share_out_cents    bigint not null default 0,  -- the Owners' share of rentals (2110)
  discounts_cents          bigint not null default 0,
  discounts_owner_cents    bigint not null default 0,  -- the part the Owner bore (the split's proportion)
  discounts_company_cents  bigint not null default 0,
  company_fees_cents       bigint not null default 0,  -- company-only renter fees, net of refunds
  company_fees_by_type     jsonb not null default '{}'::jsonb,
  turo_gross_cents         bigint not null default 0,
  turo_fees_cents          bigint not null default 0,
  turo_revenue_share_cents bigint not null default 0,
  turo_extras_cents        bigint not null default 0,
  turo_owner_cents         bigint not null default 0,
  insurance_fees_cents     bigint not null default 0,  -- billed, net of prepaid credits (4010)
  tracker_fees_cents       bigint not null default 0,
  install_fees_cents       bigint not null default 0,
  other_owner_fees_cents   bigint not null default 0,
  prepaid_last_month_cents bigint not null default 0,  -- billed into 2120, not revenue
  owner_fees_hst_cents     bigint not null default 0,
  owner_fees_collected_cents bigint not null default 0,
  owner_fees_deducted_cents  bigint not null default 0,
  owner_fees_outstanding_cents bigint not null default 0,
  late_fees_cents          bigint not null default 0,  -- Owner Late Fees (4020)
  insurer_billed_cents     bigint not null default 0,
  insurer_collected_cents  bigint not null default 0,
  refunds_cents            bigint not null default 0,  -- refunds paid in the month (cash)
  chargebacks_cents        bigint not null default 0,
  uncollected_cents        bigint not null default 0,
  pass_through_in_cents    bigint not null default 0,  -- tolls, tickets, key cost, damage at cost charged (2150)
  pass_through_out_cents   bigint not null default 0,  -- notices CarmaCars paid to the authority in the month
  company_paid_tolls_cents bigint not null default 0,  -- of which CarmaCars bears (staff use) (5110)
  claim_money_in_cents     bigint not null default 0,
  repairs_out_cents        bigint not null default 0,
  claim_balance_cents      bigint not null default 0,  -- open claims, in less out, as at the build (2140)
  claim_surplus_cents      bigint not null default 0,  -- claims settled in the month: CarmaCars' result (4140)
  deposits_held_cents      bigint not null default 0,  -- liability as at the build (2100)
  hst_collected_cents      bigint not null default 0,  -- renter lines and owner fees (2200)
  hst_refunded_cents       bigint not null default 0,
  hst_paid_cents           bigint not null default 0,  -- on payouts to registered Owners and on costs (2210)
  processing_fees_cents    bigint not null default 0,
  expenses_cents           bigint not null default 0,
  investor_returns_cents   bigint not null default 0,
  owner_payout_cents       bigint not null default 0,  -- owner level: the month's statement payout
  owner_deductions_cents   bigint not null default 0,
  kickbacks_earned_cents   bigint not null default 0,  -- owner level: kickbacks this Owner earned
  cash_collected_cents     bigint not null default 0,
  cash_refunded_cents      bigint not null default 0,
  cash_paid_out_cents      bigint not null default 0,
  company_net_cents        bigint not null default 0,  -- contribution before costs the platform does not hold
  avg_daily_rate_cents     bigint not null default 0,
  revpad_cents             bigint not null default 0,  -- rental revenue per available day
  check ((level = 'vehicle') = (vehicle_id is not null)),
  check (level <> 'total' or owner_id is null)
);
create index company_statement_lines_statement_idx on company_statement_lines (statement_id, level);

create trigger company_expenses_guard before insert or update on company_expenses
  for each row execute function app.company_expense_guard();

-- Days of a month covered by a set of ranges.
create or replace function app.multirange_days(p tstzmultirange) returns numeric
language sql immutable as $$
  select round(coalesce(sum(extract(epoch from upper(r) - lower(r))), 0) / 86400, 2) from unnest(coalesce(p, '{}'::tstzmultirange)) r
$$;

-- Days in the program, blocked, rented (renters and Turo trips) and with the Owner, for one vehicle and month.
create or replace function app.vehicle_month_days(p_vehicle uuid, p_month date)
returns table (in_program numeric, blocked numeric, rented numeric, owner_days numeric)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  m0 date := app.month_start(p_month);
  m1 date := (app.month_start(p_month) + interval '1 month')::date;
  t0 timestamptz;
  t1 timestamptz;
  w tstzmultirange;
  v_end date;
begin
  select * into v from vehicles where id = p_vehicle;
  v_end := app.vehicle_fee_end(p_vehicle);
  if v.enrollment_date is null or v.enrollment_date >= m1 or (v_end is not null and v_end < m0) then
    return query select 0::numeric, 0::numeric, 0::numeric, 0::numeric; return;
  end if;
  t0 := app.local_midnight(greatest(m0, v.enrollment_date));
  t1 := app.local_midnight(least(m1, coalesce(v_end + 1, m1)));
  w := tstzmultirange(tstzrange(t0, t1, '[)'));
  return query select
    (least(m1, coalesce(v_end + 1, m1)) - greatest(m0, v.enrollment_date))::numeric,
    app.multirange_days((select range_agg(tstzrange(k.starts_at, greatest(k.starts_at, coalesce(k.ends_at, t1)), '[)')) from vehicle_calendar_blocks k
                          where k.vehicle_id = p_vehicle and k.reason in ('service', 'repair', 'owner_unavailable', 'exit', 'turo_owner_use')
                            and k.starts_at < t1 and coalesce(k.ends_at, t1) > t0) * w),
    app.multirange_days((select range_agg(x.r) from (
        select tstzrange(coalesce(b.handed_over_at, b.pickup_at),
                         greatest(coalesce(b.handed_over_at, b.pickup_at), coalesce(b.checked_in_at, case when b.status = 'on_rent' then t1 else b.return_at end)), '[)') as r
          from bookings b where b.vehicle_id = p_vehicle and b.booking_type <> 'owner' and b.status in ('on_rent', 'returned', 'closed')
           and coalesce(b.handed_over_at, b.pickup_at) < t1
        union all
        select tstzrange(t.starts_at, t.ends_at, '[)') from turo_trips t where t.vehicle_id = p_vehicle and t.starts_at < t1 and t.ends_at > t0) x) * w),
    app.multirange_days((select range_agg(tstzrange(coalesce(b.handed_over_at, b.pickup_at),
                         greatest(coalesce(b.handed_over_at, b.pickup_at), coalesce(b.checked_in_at, case when b.status = 'on_rent' then t1 else b.return_at end)), '[)'))
          from bookings b where b.vehicle_id = p_vehicle and b.booking_type = 'owner' and b.status in ('on_rent', 'returned', 'closed')
           and coalesce(b.handed_over_at, b.pickup_at) < t1) * w);
end $$;

-- Renter charge lines that count in a month, net of refunds allocated to them.
create or replace function app.company_month_lines(p_month date)
returns table (line_id uuid, vehicle_id uuid, owner_id uuid, booking_id uuid, charge_type text, revenue_class revenue_class,
               amount_cents bigint, hst_cents bigint, refunded_cents bigint, refunded_hst_cents bigint, net_cents bigint, company_share_bps integer)
language sql stable security definer set search_path = public, app as $$
  select l.id, bk.vehicle_id, bk.owner_id, bk.id, l.charge_type, l.revenue_class, l.amount_cents, l.hst_cents,
         coalesce(ra.amt, 0), coalesce(ra.hst, 0), l.amount_cents - coalesce(ra.amt, 0), coalesce(spl.company_share_bps, bk.company_share_bps)
    from booking_line_items l
    join bookings bk on bk.id = l.booking_id
    left join booking_statements bs on bs.id = l.statement_id
    left join booking_splits spl on spl.booking_id = l.booking_id
    left join lateral (select sum(a.amount_cents) as amt, sum(a.hst_cents) as hst from refund_allocations a
                         join refunds r on r.id = a.refund_id and r.status in ('approved', 'processing', 'paid')
                        where a.line_item_id = l.id) ra on true
   where l.voided_at is null and l.charged_to_renter and bk.booking_type <> 'owner'
     and coalesce(case when bs.kind = 'later_charge' then app.month_start(app.local_date(bs.issued_at)) end, spl.payout_month,
                  case when bk.status in ('returned', 'closed') then app.month_start(app.local_date(coalesce(bk.checked_in_at, bk.return_at))) end)
         = app.month_start(p_month)
$$;

-- The money columns, for the sums of the owner and total levels and for the exports.
create or replace function app.company_statement_sum_columns() returns text[]
language sql stable as $$
  select array_agg(column_name::text order by ordinal_position) from information_schema.columns
   where table_schema = 'public' and table_name = 'company_statement_lines'
     and data_type in ('bigint', 'numeric', 'integer')
     and column_name not in ('utilization_bps', 'avg_daily_rate_cents', 'revpad_cents')
$$;

-- Build (or rebuild while it is a draft) CarmaCars' statement for a month, with the reconciliation.
create or replace function app.build_company_statement(p_month date, p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  m0 date := app.month_start(p_month);
  m1 date := (app.month_start(p_month) + interval '1 month')::date;
  t0 timestamptz := app.local_midnight(app.month_start(p_month));
  t1 timestamptz := app.local_midnight((app.month_start(p_month) + interval '1 month')::date);
  v_id uuid;
  v_status text;
  v_cols text[] := app.company_statement_sum_columns();
  v_sums text;
  v_checks jsonb := '[]'::jsonb;
  v_problems text[] := '{}';
  c record;
  v_a bigint; v_b bigint; v_n bigint;
begin
  if p_by is not null and not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin builds the company statement' using errcode = '42501';
  end if;
  select id, status into v_id, v_status from company_statements where statement_month = m0 for update;
  if v_status = 'final' then
    raise exception 'The company statement for % is final', to_char(m0, 'YYYY-MM') using errcode = '23514';
  end if;
  if v_id is null then
    insert into company_statements (statement_month, built_by) values (m0, p_by) returning id into v_id;
  else
    delete from company_statement_lines where statement_id = v_id;
    update company_statements set built_at = now(), built_by = p_by, version = version + 1 where id = v_id;
  end if;

  -- ---- vehicle level
  insert into company_statement_lines (statement_id, level, vehicle_id, owner_id, label, management_mode, billing_case,
      days_in_program, days_available, days_rented, owner_days, rentals_ended, billable_days,
      rental_revenue_cents, mileage_cents, kickbacks_cents, owner_revenue_cents, revenue_share_cents, owner_share_out_cents,
      discounts_cents, discounts_owner_cents, discounts_company_cents, company_fees_cents, company_fees_by_type,
      turo_gross_cents, turo_fees_cents, turo_revenue_share_cents, turo_extras_cents, turo_owner_cents,
      insurance_fees_cents, tracker_fees_cents, install_fees_cents, other_owner_fees_cents, prepaid_last_month_cents,
      owner_fees_hst_cents, owner_fees_collected_cents, owner_fees_deducted_cents, owner_fees_outstanding_cents, late_fees_cents,
      insurer_billed_cents, insurer_collected_cents, refunds_cents, chargebacks_cents, uncollected_cents,
      pass_through_in_cents, pass_through_out_cents, company_paid_tolls_cents,
      claim_money_in_cents, repairs_out_cents, claim_balance_cents, claim_surplus_cents, deposits_held_cents,
      hst_collected_cents, hst_refunded_cents, hst_paid_cents, processing_fees_cents, expenses_cents,
      cash_collected_cents, cash_refunded_cents)
  with lines as (select * from app.company_month_lines(m0)),
  veh as (
    select v.id, v.owner_id, coalesce(v.fleet_number, v.plate) as label, v.management_mode::text as mode, v.billing_case
      from vehicles v
     where (v.enrollment_date is not null and v.enrollment_date < m1 and coalesce(app.vehicle_fee_end(v.id), m0) >= m0)
        or v.id in (select s.vehicle_id from booking_splits s where s.payout_month = m0)
        or v.id in (select l.vehicle_id from lines l)
        or v.id in (select t.vehicle_id from turo_trips t where t.statement_month = m0)
        or v.id in (select e.vehicle_id from company_expenses e where e.expense_on >= m0 and e.expense_on < m1 and e.voided_at is null and e.vehicle_id is not null)
        or v.id in (select tt.vehicle_id from toll_tickets tt where tt.paid_by_company_at >= t0 and tt.paid_by_company_at < t1 and tt.vehicle_id is not null)
        or v.id in (select bk.vehicle_id from payments p join bookings bk on bk.id = p.booking_id
                     where p.status = 'succeeded' and p.processed_at >= t0 and p.processed_at < t1))
  select v_id, 'vehicle', veh.id, veh.owner_id, veh.label, veh.mode, veh.billing_case,
         d.in_program, greatest(d.in_program - d.blocked, 0), d.rented, d.owner_days, s.rentals, s.bdays,
         s.rental, s.mileage, s.kick, s.orev, s.share, s.opay,
         ln.disc, ln.disc_owner, ln.disc - ln.disc_owner, ln.fees,
         coalesce((select jsonb_object_agg(y.charge_type, y.amt) from (select l.charge_type, sum(l.net_cents) as amt from lines l
                    where l.vehicle_id = veh.id and l.revenue_class = 'company_only' group by l.charge_type) y), '{}'::jsonb),
         tr.gross, tr.fees, tr.share, tr.extras, tr.owner,
         oi.insurance, oi.tracker, oi.install, oi.other, oi.prepaid, oi.hst, oi.paid, oi.deducted, oi.outstanding, oi.late,
         ins.billed, ins.collected, rf.refunds, s.chargebacks, s.uncollected,
         ln.pass_in, tl.paid_out, tl.company_paid,
         cl.money_in, cl.repairs_out, cl.balance, cl.surplus, dp.held,
         ln.hst + oi.hst, ln.hst_ref, ex.hst, pf.fees, ex.amount,
         cash.collected, cash.refunded
    from veh
    cross join lateral app.vehicle_month_days(veh.id, m0) d
    cross join lateral (
      select count(*) filter (where b.status in ('returned', 'closed')) as rentals,
             coalesce(sum(b.billable_days) filter (where b.status in ('returned', 'closed')), 0)::integer as bdays,
             coalesce(sum(sp.rental_charge_cents), 0) as rental, coalesce(sum(sp.mileage_overage_cents), 0) as mileage,
             coalesce(sum(sp.kickback_cents), 0) as kick, coalesce(sum(sp.owner_revenue_cents), 0) as orev,
             coalesce(sum(sp.company_share_cents), 0) as share, coalesce(sum(sp.owner_payout_cents), 0) as opay,
             coalesce(sum(sp.chargeback_cents), 0) as chargebacks, coalesce(sum(sp.uncollected_cents), 0) as uncollected
        from booking_splits sp join bookings b on b.id = sp.booking_id
       where sp.vehicle_id = veh.id and sp.payout_month = m0 and sp.status <> 'reversed') s
    cross join lateral (
      select coalesce(sum(l.net_cents) filter (where l.revenue_class = 'company_only'), 0) as fees,
             coalesce(sum(l.net_cents) filter (where l.revenue_class = 'pass_through'), 0) as pass_in,
             coalesce(sum(l.hst_cents), 0) as hst, coalesce(sum(l.refunded_hst_cents), 0) as hst_ref,
             coalesce(-sum(l.amount_cents) filter (where l.charge_type in ('non_refundable_discount', 'staff_discount', 'promo_discount')), 0) as disc,
             coalesce(sum(public.calc_bps(-l.amount_cents, 10000 - coalesce(l.company_share_bps, 0)))
                        filter (where l.charge_type in ('non_refundable_discount', 'staff_discount', 'promo_discount')), 0) as disc_owner
        from lines l where l.vehicle_id = veh.id) ln
    cross join lateral (
      select coalesce(sum(t.gross_cents), 0) as gross, coalesce(sum(t.turo_fees_cents), 0) as fees,
             coalesce(sum(t.revenue_share_cents), 0) as share, coalesce(sum(t.company_extras_cents), 0) as extras,
             coalesce(sum(t.owner_payout_cents), 0) as owner
        from turo_trips t where t.vehicle_id = veh.id and t.statement_month = m0 and t.received_at is not null) tr
    cross join lateral (
      select coalesce(sum(il.amount_cents) filter (where il.kind in ('insurance_fee', 'first_month_insurance', 'prepaid_credit')), 0) as insurance,
             coalesce(sum(il.amount_cents) filter (where il.kind = 'tracker_fee'), 0) as tracker,
             coalesce(sum(il.amount_cents) filter (where il.kind = 'install_fee'), 0) as install,
             coalesce(sum(il.amount_cents) filter (where il.kind = 'adjustment'), 0) as other,
             coalesce(sum(il.amount_cents) filter (where il.kind = 'last_month_insurance'), 0) as prepaid,
             coalesce(sum(il.amount_cents) filter (where il.kind = 'late_fee'), 0) as late,
             coalesce((select sum(i.hst_cents) from owner_invoices i where i.vehicle_id = veh.id and i.status not in ('draft', 'void')
                         and ((i.kind = 'monthly' and i.period_month = m0) or (i.kind <> 'monthly' and i.billing_date >= m0 and i.billing_date < m1))), 0) as hst,
             coalesce((select sum(i.paid_cents) from owner_invoices i where i.vehicle_id = veh.id and i.status not in ('draft', 'void')
                         and ((i.kind = 'monthly' and i.period_month = m0) or (i.kind <> 'monthly' and i.billing_date >= m0 and i.billing_date < m1))), 0) as paid,
             coalesce((select sum(i.deducted_cents) from owner_invoices i where i.vehicle_id = veh.id and i.status not in ('draft', 'void')
                         and ((i.kind = 'monthly' and i.period_month = m0) or (i.kind <> 'monthly' and i.billing_date >= m0 and i.billing_date < m1))), 0) as deducted,
             coalesce((select sum(i.balance_cents) from owner_invoices i where i.vehicle_id = veh.id and i.status not in ('draft', 'void')
                         and ((i.kind = 'monthly' and i.period_month = m0) or (i.kind <> 'monthly' and i.billing_date >= m0 and i.billing_date < m1))), 0) as outstanding
        from owner_invoice_lines il join owner_invoices i on i.id = il.owner_invoice_id
       where i.vehicle_id = veh.id and i.status not in ('draft', 'void')
         and ((i.kind = 'monthly' and i.period_month = m0) or (i.kind <> 'monthly' and i.billing_date >= m0 and i.billing_date < m1))) oi
    cross join lateral (
      select coalesce(sum(ii.total_cents), 0) as billed, coalesce(sum(ii.paid_cents), 0) as collected
        from insurer_invoices ii join bookings b on b.id = ii.booking_id
       where b.vehicle_id = veh.id and ii.status <> 'draft' and ii.sent_at >= t0 and ii.sent_at < t1) ins
    cross join lateral (
      select coalesce(sum(r.amount_cents), 0) as refunds from refunds r join bookings b on b.id = r.booking_id
       where b.vehicle_id = veh.id and r.status = 'paid' and r.paid_at >= t0 and r.paid_at < t1) rf
    cross join lateral (
      select coalesce(sum(tt.amount_cents), 0) as paid_out, coalesce(sum(tt.amount_cents) filter (where tt.status = 'company_paid'), 0) as company_paid
        from toll_tickets tt where tt.vehicle_id = veh.id and tt.paid_by_company_at >= t0 and tt.paid_by_company_at < t1) tl
    cross join lateral (
      select coalesce(sum(e.amount_cents) filter (where e.direction = 'in' and e.entry_date >= m0 and e.entry_date < m1), 0) as money_in,
             coalesce(sum(e.amount_cents) filter (where e.direction = 'out' and e.entry_date >= m0 and e.entry_date < m1
                                                    and e.kind in ('repair', 'policy_deductible', 'towing', 'storage', 'appraisal', 'other_claim_cost')), 0) as repairs_out,
             coalesce(sum(case when e.direction = 'in' then e.amount_cents else -e.amount_cents end)
                        filter (where cm.status not in ('closed', 'withdrawn')), 0) as balance,
             coalesce((select sum(c2.company_result_cents) from claims c2 where c2.vehicle_id = veh.id and c2.settled_at >= t0 and c2.settled_at < t1), 0) as surplus
        from claims cm left join claim_ledger_entries e on e.claim_id = cm.id
       where cm.vehicle_id = veh.id) cl
    cross join lateral (
      select coalesce(sum(greatest(case when dd.method = 'charged' then dd.amount_cents else dd.captured_cents end - dd.applied_cents - dd.released_cents, 0)), 0) as held
        from deposits dd join bookings b on b.id = dd.booking_id
       where b.vehicle_id = veh.id and dd.status in ('held', 'captured')) dp
    cross join lateral (
      select coalesce(sum(e.amount_cents), 0) as amount, coalesce(sum(e.hst_cents), 0) as hst
        from company_expenses e where e.vehicle_id = veh.id and e.voided_at is null and e.expense_on >= m0 and e.expense_on < m1) ex
    cross join lateral (
      select coalesce(sum(pd.processor_fee_cents), 0) as fees
        from payments p join payment_processor_details pd on pd.payment_id = p.id
        left join bookings b on b.id = p.booking_id left join owner_invoices i on i.id = p.owner_invoice_id
       where coalesce(b.vehicle_id, i.vehicle_id) = veh.id and p.processed_at >= t0 and p.processed_at < t1) pf
    cross join lateral (
      select coalesce(sum(p.amount_cents) filter (where p.kind in ('charge', 'capture')), 0) as collected,
             coalesce(sum(p.amount_cents) filter (where p.kind = 'refund'), 0) as refunded
        from payments p left join bookings b on b.id = p.booking_id left join owner_invoices i on i.id = p.owner_invoice_id
       where coalesce(b.vehicle_id, i.vehicle_id) = veh.id and p.status = 'succeeded' and p.processed_at >= t0 and p.processed_at < t1) cash;

  -- ---- owner level: the vehicles summed, plus what belongs to the Owner as a whole
  select string_agg(format('coalesce(sum(l.%1$I), 0)', col), ', ') into v_sums from unnest(v_cols) col;
  execute format($f$
    insert into company_statement_lines (statement_id, level, owner_id, label, %1$s)
    select $1, 'owner', o.id, o.legal_name, %2$s
      from owners o left join company_statement_lines l on l.statement_id = $1 and l.level = 'vehicle' and l.owner_id = o.id
     where o.id in (select owner_id from company_statement_lines where statement_id = $1 and level = 'vehicle')
        or o.id in (select owner_id from owner_statements where statement_month = $2 and status <> 'void')
        or o.id in (select owner_id from payouts where owner_id is not null and status = 'paid' and paid_at >= $3 and paid_at < $4)
        or o.id in (select owner_id from company_expenses where owner_id is not null and vehicle_id is null and voided_at is null
                      and expense_on >= $2 and expense_on < $5)
     group by o.id, o.legal_name$f$, array_to_string(v_cols, ', '), v_sums)
  using v_id, m0, t0, t1, m1;
  update company_statement_lines l
     set owner_payout_cents = coalesce(st.payout_cents, 0), owner_deductions_cents = coalesce(st.deductions_cents, 0),
         kickbacks_earned_cents = coalesce(st.kickbacks_earned_cents, 0),
         hst_paid_cents = l.hst_paid_cents + coalesce(st.hst_on_payout_cents, 0) + coalesce(oe.hst, 0),
         expenses_cents = l.expenses_cents + coalesce(oe.amount, 0),
         cash_paid_out_cents = coalesce((select sum(p.amount_cents) from payouts p where p.owner_id = l.owner_id and p.status = 'paid'
                                           and p.paid_at >= t0 and p.paid_at < t1), 0)
    from (select o.id from owners o) oo
    left join owner_statements st on st.owner_id = oo.id and st.statement_month = m0 and st.status <> 'void'
    left join lateral (select sum(e.amount_cents) as amount, sum(e.hst_cents) as hst from company_expenses e
                        where e.owner_id = oo.id and e.vehicle_id is null and e.voided_at is null and e.expense_on >= m0 and e.expense_on < m1) oe on true
   where l.statement_id = v_id and l.level = 'owner' and l.owner_id = oo.id;

  -- ---- total: the owners summed, plus what belongs to no Owner
  execute format($f$
    insert into company_statement_lines (statement_id, level, label, %1$s)
    select $1, 'total', 'Total', %2$s from company_statement_lines l where l.statement_id = $1 and l.level = 'owner'$f$,
    array_to_string(v_cols, ', '), v_sums)
  using v_id;
  update company_statement_lines l
     set investor_returns_cents = coalesce((select sum(r.return_cents) from investment_returns r where r.return_month = m0), 0),
         expenses_cents = l.expenses_cents + coalesce((select sum(e.amount_cents) from company_expenses e where e.vehicle_id is null and e.owner_id is null
                                                        and e.voided_at is null and e.expense_on >= m0 and e.expense_on < m1), 0),
         hst_paid_cents = l.hst_paid_cents + coalesce((select sum(e.hst_cents) from company_expenses e where e.vehicle_id is null and e.owner_id is null
                                                        and e.voided_at is null and e.expense_on >= m0 and e.expense_on < m1), 0),
         cash_paid_out_cents = l.cash_paid_out_cents + coalesce((select sum(p.amount_cents) from payouts p where p.payee_type <> 'owner' and p.status = 'paid'
                                                                   and p.paid_at >= t0 and p.paid_at < t1), 0),
         cash_collected_cents = l.cash_collected_cents + coalesce((select sum(p.amount_cents) from payments p
                                   where p.status = 'succeeded' and p.kind in ('charge', 'capture') and p.processed_at >= t0 and p.processed_at < t1
                                     and p.booking_id is null and p.owner_invoice_id is null), 0)
   where l.statement_id = v_id and l.level = 'total';

  -- ---- derived figures on every line
  update company_statement_lines l
     set company_fees_by_type = case when l.level = 'vehicle' then l.company_fees_by_type else coalesce((
           select jsonb_object_agg(k, s) from (select e.key as k, sum(e.value::bigint) as s
             from company_statement_lines x, jsonb_each_text(x.company_fees_by_type) e
            where x.statement_id = v_id and x.level = 'vehicle' and (l.level = 'total' or x.owner_id = l.owner_id) group by e.key) z), '{}'::jsonb) end,
         company_net_cents = l.revenue_share_cents + l.turo_revenue_share_cents + l.turo_extras_cents + l.company_fees_cents
                           + l.insurance_fees_cents + l.tracker_fees_cents + l.install_fees_cents + l.other_owner_fees_cents + l.late_fees_cents
                           + l.claim_surplus_cents - l.processing_fees_cents - l.company_paid_tolls_cents - l.expenses_cents - l.investor_returns_cents,
         utilization_bps = case when l.days_available > 0 then round(l.days_rented / l.days_available * 10000) else 0 end,
         avg_daily_rate_cents = case when l.billable_days > 0 then round(l.rental_revenue_cents::numeric / l.billable_days) else 0 end,
         revpad_cents = case when l.days_available > 0 then round(l.rental_revenue_cents / l.days_available) else 0 end
   where l.statement_id = v_id;

  -- ---- reconciliation
  -- 1 and 2: vehicles sum to owners, owners sum to the total (columns the owner and total levels do not add to)
  for c in select unnest(array['rental_revenue_cents', 'revenue_share_cents', 'owner_share_out_cents', 'company_fees_cents',
                               'pass_through_in_cents', 'insurance_fees_cents', 'late_fees_cents', 'refunds_cents', 'turo_revenue_share_cents']) as col
  loop
    execute format('select coalesce(sum(%1$I) filter (where level = ''vehicle''), 0), coalesce(sum(%1$I) filter (where level = ''owner''), 0),
                           coalesce(sum(%1$I) filter (where level = ''total''), 0) from company_statement_lines where statement_id = $1', c.col)
      into v_a, v_b, v_n using v_id;
    v_checks := v_checks || jsonb_build_object('check', 'vehicles_owners_total:' || c.col, 'vehicles', v_a, 'owners', v_b, 'total', v_n,
                                               'difference_cents', greatest(abs(v_a - v_b), abs(v_b - v_n)), 'ok', v_a = v_b and v_b = v_n);
    if not (v_a = v_b and v_b = v_n) then
      v_problems := v_problems || format('%s: vehicles %s, owners %s, total %s', c.col, v_a, v_b, v_n);
    end if;
  end loop;
  -- 3: the total against the source tables directly
  select coalesce(sum(rental_charge_cents), 0) into v_a from booking_splits where payout_month = m0 and status <> 'reversed';
  select rental_revenue_cents into v_b from company_statement_lines where statement_id = v_id and level = 'total';
  v_checks := v_checks || jsonb_build_object('check', 'rental_revenue_against_splits', 'expected', v_a, 'got', v_b, 'difference_cents', v_b - v_a, 'ok', v_a = v_b);
  if v_a <> v_b then v_problems := v_problems || format('rental revenue: splits %s, statement %s (difference %s)', v_a, v_b, v_b - v_a); end if;
  select coalesce(sum(net_cents) filter (where revenue_class = 'company_only'), 0) into v_a from app.company_month_lines(m0);
  select company_fees_cents into v_b from company_statement_lines where statement_id = v_id and level = 'total';
  v_checks := v_checks || jsonb_build_object('check', 'company_fees_against_lines', 'expected', v_a, 'got', v_b, 'difference_cents', v_b - v_a, 'ok', v_a = v_b);
  if v_a <> v_b then v_problems := v_problems || format('company fees: lines %s, statement %s (difference %s)', v_a, v_b, v_b - v_a); end if;
  -- 4: money in: every payment of the month is tied to a vehicle's booking or invoice
  select coalesce(sum(amount_cents), 0), count(*) into v_a, v_n from payments
   where status = 'succeeded' and kind in ('charge', 'capture') and processed_at >= t0 and processed_at < t1;
  select coalesce(sum(cash_collected_cents), 0) into v_b from company_statement_lines where statement_id = v_id and level = 'vehicle';
  v_checks := v_checks || jsonb_build_object('check', 'payments_against_vehicles', 'expected', v_a, 'got', v_b, 'difference_cents', v_a - v_b, 'ok', v_a = v_b);
  if v_a <> v_b then
    v_problems := v_problems || format('payments: %s collected in the month, %s tied to a vehicle; %s not tied to a booking or an owner invoice', v_a, v_b, v_a - v_b);
  end if;
  -- 5: refunds approved and paid against the refund payments made
  select coalesce(sum(amount_cents), 0) into v_a from refunds where status = 'paid' and paid_at >= t0 and paid_at < t1;
  select coalesce(sum(amount_cents), 0) into v_b from payments
   where status = 'succeeded' and kind = 'refund' and purpose <> 'deposit' and processed_at >= t0 and processed_at < t1;
  v_checks := v_checks || jsonb_build_object('check', 'refunds_against_refund_payments', 'expected', v_a, 'got', v_b, 'difference_cents', v_a - v_b, 'ok', v_a = v_b);
  if v_a <> v_b then v_problems := v_problems || format('refunds: %s recorded as paid, %s refunded by the processor (difference %s)', v_a, v_b, v_a - v_b); end if;
  -- 6: owner payouts paid in the month against their statements, and against the owner level
  select coalesce(sum(p.amount_cents), 0), coalesce(sum(st.payout_cents), 0) into v_a, v_b
    from payouts p join owner_statements st on st.id = p.owner_statement_id
   where p.status = 'paid' and p.paid_at >= t0 and p.paid_at < t1;
  v_checks := v_checks || jsonb_build_object('check', 'statement_payouts', 'expected', v_b, 'got', v_a, 'difference_cents', v_a - v_b, 'ok', v_a = v_b);
  if v_a <> v_b then v_problems := v_problems || format('owner payouts: %s paid, statements say %s (difference %s)', v_a, v_b, v_a - v_b); end if;
  select coalesce(sum(amount_cents), 0) into v_a from payouts where payee_type = 'owner' and status = 'paid' and paid_at >= t0 and paid_at < t1;
  select coalesce(sum(cash_paid_out_cents), 0) into v_b from company_statement_lines where statement_id = v_id and level = 'owner';
  v_checks := v_checks || jsonb_build_object('check', 'owner_payouts_against_owners', 'expected', v_a, 'got', v_b, 'difference_cents', v_a - v_b, 'ok', v_a = v_b);
  if v_a <> v_b then v_problems := v_problems || format('payouts to Owners: %s paid, %s on the owner lines', v_a, v_b); end if;

  update company_statements
     set checks = v_checks, ties_ok = cardinality(v_problems) = 0,
         tie_problems = case when cardinality(v_problems) > 0 then array_to_string(v_problems, '; ') end
   where id = v_id;
  if cardinality(v_problems) > 0 then
    perform app.raise_task(p_type => 'company_statement_tie',
        p_title => format('The %s company statement does not reconcile', to_char(m0, 'FMMonth YYYY')),
        p_detail => array_to_string(v_problems, '; '), p_related_table => 'company_statements', p_related_id => v_id,
        p_dedupe => 'company_statement_tie:' || v_id, p_created_by => p_by);
  else
    update tasks set status = 'done', completed_at = now(), completion_note = 'Reconciles after a rebuild'
     where related_table = 'company_statements' and related_id = v_id and task_type = 'company_statement_tie'
       and status in ('open', 'in_progress', 'waiting');
  end if;
  return v_id;
end $$;

-- An Admin freezes the month. It is rebuilt first; a failed tie blocks it and names the difference
-- (the build itself records the failure on the draft and raises the Admin task).
create or replace function app.finalize_company_statement(p_month date, p_admin uuid)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  cs company_statements;
  v_id uuid;
begin
  if not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin finalizes the company statement' using errcode = '42501';
  end if;
  select * into cs from company_statements where statement_month = app.month_start(p_month);
  if cs.status = 'final' then return cs.id; end if;
  v_id := app.build_company_statement(p_month, p_admin);
  select * into cs from company_statements where id = v_id;
  if not cs.ties_ok then
    raise exception 'The company statement for % does not reconcile: %', to_char(cs.statement_month, 'YYYY-MM'), cs.tie_problems
      using errcode = '23514';
  end if;
  update company_statements set status = 'final', finalized_by = p_admin, finalized_at = now() where id = v_id;
  update tasks set status = 'done', completed_at = now(), completed_by = p_admin, completion_note = 'Finalized'
   where related_table = 'company_statements' and related_id = v_id and status in ('open', 'in_progress', 'waiting');
  perform app.emit_event('staff_monthly_statements_ready', 'company_statement', v_id,
    jsonb_build_object('statement_month', cs.statement_month), 'staff_monthly_statements_ready:' || v_id || ':final');
  return v_id;
end $$;

-- Lines with last month and the year to date beside them.
create view company_statement_report with (security_barrier = true) as
  select s.statement_month, s.status as statement_status, l.*,
         p.rental_revenue_cents as prev_rental_revenue_cents, p.company_net_cents as prev_company_net_cents,
         l.rental_revenue_cents - coalesce(p.rental_revenue_cents, 0) as mom_rental_revenue_change_cents,
         l.company_net_cents - coalesce(p.company_net_cents, 0) as mom_company_net_change_cents,
         y.ytd_rental_revenue_cents, y.ytd_revenue_share_cents, y.ytd_company_fees_cents, y.ytd_company_net_cents, y.ytd_days_rented
    from company_statement_lines l
    join company_statements s on s.id = l.statement_id
    left join lateral (
      select l2.rental_revenue_cents, l2.company_net_cents from company_statement_lines l2 join company_statements s2 on s2.id = l2.statement_id
       where s2.statement_month = (s.statement_month - interval '1 month')::date and l2.level = l.level
         and l2.vehicle_id is not distinct from l.vehicle_id and l2.owner_id is not distinct from l.owner_id limit 1) p on true
    left join lateral (
      select sum(l3.rental_revenue_cents) as ytd_rental_revenue_cents, sum(l3.revenue_share_cents) as ytd_revenue_share_cents,
             sum(l3.company_fees_cents) as ytd_company_fees_cents, sum(l3.company_net_cents) as ytd_company_net_cents,
             sum(l3.days_rented) as ytd_days_rented
        from company_statement_lines l3 join company_statements s3 on s3.id = l3.statement_id
       where s3.statement_month >= date_trunc('year', s.statement_month)::date and s3.statement_month <= s.statement_month
         and l3.level = l.level and l3.vehicle_id is not distinct from l.vehicle_id and l3.owner_id is not distinct from l.owner_id) y on true
   where app.is_admin() or app.va_has('finance');
create view company_statement_vehicles with (security_barrier = true) as select * from company_statement_report where level = 'vehicle';
create view company_statement_owners with (security_barrier = true) as select * from company_statement_report where level = 'owner';
create view company_statement_totals with (security_barrier = true) as select * from company_statement_report where level = 'total';

-- The lines of one level for a month (the server's report screens).
create or replace function app.company_statement_rows(p_month date, p_level text default 'total')
returns setof company_statement_lines language sql stable security definer set search_path = public, app as $$
  select l.* from company_statement_lines l join company_statements s on s.id = l.statement_id
   where s.statement_month = app.month_start(p_month) and l.level = p_level
   order by l.label nulls last, l.id
$$;

-- ================================================================ 12. CSV exports
create or replace function app.csv_field(p text) returns text
language sql immutable as $$
  select case when p is null then '' when p ~ '[",\r\n]' then '"' || replace(p, '"', '""') || '"' else p end
$$;

-- One level of a month's company statement: one row per line, every column but the ids.
create or replace function app.company_statement_csv(p_month date, p_level text default 'vehicle')
returns text language plpgsql stable security definer set search_path = public, app as $$
declare
  v_cols text[];
  v_out text;
begin
  select array_agg(column_name::text order by ordinal_position) into v_cols from information_schema.columns
   where table_schema = 'public' and table_name = 'company_statement_lines' and column_name not in ('id', 'statement_id');
  select string_agg(app.csv_field(c), ',' order by o) into v_out from unnest(v_cols) with ordinality u(c, o);
  v_out := 'statement_month,' || v_out;
  select v_out || coalesce(string_agg(chr(10) || r.line, '' order by r.label nulls last, r.id), '') into v_out
    from (select l.id, l.label, to_char(s.statement_month, 'YYYY-MM') || ',' ||
                 (select string_agg(app.csv_field(to_jsonb(l) ->> c), ',' order by o) from unnest(v_cols) with ordinality u(c, o)) as line
            from company_statement_lines l join company_statements s on s.id = l.statement_id
           where s.statement_month = app.month_start(p_month) and l.level = p_level) r;
  return v_out;
end $$;

-- One owner statement: every line with its vehicle and booking.
create or replace function app.owner_statement_csv(p_statement uuid)
returns text language sql stable security definer set search_path = public, app as $$
  select 'statement_number,statement_month,version,vehicle,plate,line_type,description,booking_number,starts_on,ends_on,'
      || 'rental_charge_cents,mileage_overage_cents,refunds_cents,chargebacks_cents,kickback_cents,owner_revenue_cents,'
      || 'revenue_share_cents,fee_cents,late_fee_cents,amount_cents'
      || coalesce((select string_agg(chr(10) || concat_ws(',', app.csv_field(s.statement_number), to_char(s.statement_month, 'YYYY-MM'), s.version,
                 app.csv_field(v.fleet_number), app.csv_field(v.plate), l.line_type, app.csv_field(l.description), app.csv_field(bk.booking_number),
                 coalesce(l.starts_on::text, ''), coalesce(l.ends_on::text, ''), coalesce(l.rental_charge_cents::text, ''),
                 coalesce(l.mileage_overage_cents::text, ''), coalesce(l.refunds_cents::text, ''), coalesce(l.chargebacks_cents::text, ''),
                 coalesce(l.kickback_cents::text, ''), coalesce(l.owner_revenue_cents::text, ''), coalesce(l.revenue_share_cents::text, ''),
                 coalesce(l.fee_cents::text, ''), coalesce(l.late_fee_cents::text, ''), l.amount_cents),
                 '' order by v.fleet_number nulls last, l.starts_on nulls last, l.line_type, l.id)
            from owner_statement_lines l join owner_statements s on s.id = l.owner_statement_id
            left join vehicles v on v.id = l.vehicle_id left join bookings bk on bk.id = l.booking_id
           where l.owner_statement_id = p_statement), '')
$$;

-- Ledger style: one row per account and vehicle for the month (signed: positive is money the
-- account received), from the statement's vehicle lines, plus the rows that belong to no vehicle.
create or replace function app.company_ledger_csv(p_month date)
returns text language sql stable security definer set search_path = public, app as $$
  with st as (select * from company_statements where statement_month = app.month_start(p_month)),
  rows as (
    select x.account, coalesce(l.label, '') as vehicle, coalesce(o.legal_name, '') as owner, x.item, x.amount
      from company_statement_lines l join st on st.id = l.statement_id left join owners o on o.id = l.owner_id
      cross join lateral (values
        ('4000', 'Revenue Share on rentals and Turo trips', l.revenue_share_cents + l.turo_revenue_share_cents),
        ('2110', 'Owner share of rentals and Turo trips', l.owner_share_out_cents + l.turo_owner_cents),
        ('2150', 'Pass-through charged to renters', l.pass_through_in_cents),
        ('2150', 'Pass-through paid to authorities', -l.pass_through_out_cents),
        ('5110', 'Tolls and tickets CarmaCars bears', -l.company_paid_tolls_cents),
        ('4010', 'Owner fees billed', l.insurance_fees_cents + l.tracker_fees_cents + l.install_fees_cents + l.other_owner_fees_cents),
        ('2120', 'Prepaid last month billed', l.prepaid_last_month_cents),
        ('4020', 'Owner Late Fees', l.late_fees_cents),
        ('2200', 'HST collected less refunded', l.hst_collected_cents - l.hst_refunded_cents),
        ('2140', 'Claim money in', l.claim_money_in_cents),
        ('2140', 'Claim repairs and costs out', -l.repairs_out_cents),
        ('4140', 'Claim result', l.claim_surplus_cents),
        ('5000', 'Processing fees', -l.processing_fees_cents),
        ('1010', 'Refunds paid', -l.refunds_cents)) x(account, item, amount)
     where l.level = 'vehicle' and x.amount <> 0
    union all
    select f.gl_account, coalesce(l.label, ''), coalesce(o.legal_name, ''), 'Renter fees: ' || e.key, e.value::bigint
      from company_statement_lines l join st on st.id = l.statement_id left join owners o on o.id = l.owner_id
      cross join lateral jsonb_each_text(l.company_fees_by_type) e join fee_types f on f.code = e.key
     where l.level = 'vehicle' and e.value::bigint <> 0
    union all
    select c.gl_account, coalesce(v.fleet_number, ''), coalesce(o.legal_name, ''), 'Expense: ' || c.label || ', ' || e.description, -e.amount_cents
      from company_expenses e join company_expense_categories c on c.code = e.category
      left join vehicles v on v.id = e.vehicle_id left join owners o on o.id = coalesce(e.owner_id, v.owner_id)
     where e.voided_at is null and e.expense_on >= app.month_start(p_month) and e.expense_on < (app.month_start(p_month) + interval '1 month')::date
    union all
    select '5010', '', '', 'Investor returns', -l.investor_returns_cents
      from company_statement_lines l join st on st.id = l.statement_id where l.level = 'total' and l.investor_returns_cents <> 0
    union all
    select '2210', '', coalesce(o.legal_name, ''), 'HST on payout', -l.hst_paid_cents
      from company_statement_lines l join st on st.id = l.statement_id left join owners o on o.id = l.owner_id
     where l.level = 'owner' and l.hst_paid_cents <> 0)
  select 'month,account,account_name,vehicle,owner,item,amount_cents'
      || coalesce((select string_agg(chr(10) || concat_ws(',', to_char(app.month_start(p_month), 'YYYY-MM'), r.account, app.csv_field(g.name),
                 app.csv_field(r.vehicle), app.csv_field(r.owner), app.csv_field(r.item), r.amount), ''
                 order by r.account, r.vehicle, r.item)
            from rows r join gl_accounts g on g.code = r.account), '')
$$;

-- ================================================================ 13. scheduled job: the company statement draft
-- On the day the owner statements are drafted (the set number of days before the payout date),
-- from 06:00: draft last month's company statement and ask an Admin to review it; a failed tie
-- raises its own task. pg_cron schedule below (0015 pattern).
create or replace function app.job_company_statement_draft(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date := app.local_date(p_now);
  v_month date := (app.month_start(app.local_date(p_now)) - interval '1 month')::date;
  v_run uuid;
  v_id uuid;
  cs company_statements;
begin
  if v_day <> app.payout_date(v_month) - (app.settings(v_day)).company_statement_draft_days_before_payout or app.local_hour(p_now) < 6 then
    return 'not_due';
  end if;
  v_run := app.job_claim('company-statement-draft', to_char(v_month, 'YYYY-MM'));
  if v_run is null then return 'already_run'; end if;
  begin
    if exists (select 1 from company_statements where statement_month = v_month and status = 'final') then
      perform app.job_succeed(v_run, jsonb_build_object('statement_month', v_month, 'skipped', 'final'));
      return 'succeeded';
    end if;
    v_id := app.build_company_statement(v_month, null);
    select * into cs from company_statements where id = v_id;
    perform app.raise_task(p_type => 'review_company_statement',
        p_title => format('Review the %s company statement', to_char(v_month, 'FMMonth YYYY')),
        p_detail => case when cs.ties_ok then 'The draft reconciles. Finalize it once the owner statements are approved.'
                         else 'The draft does not reconcile: ' || cs.tie_problems end,
        p_related_table => 'company_statements', p_related_id => v_id, p_dedupe => 'review_company_statement:' || v_id);
    perform app.job_succeed(v_run, jsonb_build_object('statement_month', v_month, 'company_statement_id', v_id, 'ties_ok', cs.ties_ok));
    return 'succeeded';
  exception when others then
    perform app.job_fail(v_run, sqlerrm);
    return 'failed';
  end;
end $$;

do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron is not available here: no jobs scheduled';
    return;
  end if;
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise warning 'pg_cron could not be created in this database (%): no jobs scheduled', sqlerrm;
    return;
  end;
  perform cron.schedule('carmacars-toll-watch',        '18 * * * *', 'select app.job_toll_watch()');
  perform cron.schedule('carmacars-company-statement', '20 * * * *', 'select app.job_company_statement_draft()');
end $$;

-- ================================================================ 14. task rules
insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('match_toll', 'finance', 'Match a toll or ticket', 'high', 'business_days', 3, 11, null,
   'Nobody was on record for the notice. Find who had the car (tracker history, staff moves, owner use) and match it.'),
  ('review_toll_match', 'finance', 'Confirm who had the car for a toll or ticket', 'normal', 'business_days', 1, 11, null,
   'The matcher found a candidate near a boundary, several candidates, or a notice without a time. Confirm one.'),
  ('toll_unmatched', 'admin', 'Toll or ticket still unmatched', 'high', 'business_days', 1, 11, null,
   'No match after the set number of business days: an Admin decides.'),
  ('review_damage_match', 'finance', 'Confirm who had the car when damage happened', 'high', 'business_days', 1, 5, null,
   'Damage found after a rental: confirm the booking, staff move or owner use, then an Admin bills it.'),
  ('review_company_statement', 'admin', 'Review the company statement', 'normal', 'business_days', 3, null, null,
   'The monthly company statement is drafted. Check it and finalize it.'),
  ('company_statement_tie', 'admin', 'Company statement does not reconcile', 'urgent', 'business_days', 1, null, null,
   'A reconciliation check failed. Correct the source records and rebuild.')
on conflict (task_type) do nothing;

-- ================================================================ 15. row-level security
do $$
declare
  t text;
begin
  foreach t in array array['gl_accounts', 'gl_account_map', 'vehicle_transponders', 'vehicle_plate_history', 'toll_import_profiles',
                           'toll_import_batches', 'damage_intakes', 'company_expense_categories', 'company_expenses', 'owner_credits',
                           'company_statements', 'company_statement_lines'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy admin_all on public.%I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
end $$;

-- reference data: staff read the chart and the categories
create policy staff_read on gl_accounts for select to authenticated using (app.is_va());
create policy staff_read on gl_account_map for select to authenticated using (app.va_has('finance'));
create policy staff_read on company_expense_categories for select to authenticated using (app.va_has('finance'));
-- transponders and plates: Fleet keeps them; Finance reads them (matching)
create policy va_read on vehicle_transponders for select to authenticated using (app.va_has('finance', 'fleet'));
create policy fleet_insert on vehicle_transponders for insert to authenticated with check (app.va_has('fleet'));
create policy fleet_update on vehicle_transponders for update to authenticated using (app.va_has('fleet')) with check (app.va_has('fleet'));
create policy va_read on vehicle_plate_history for select to authenticated using (app.va_has('finance', 'fleet'));
create policy fleet_insert on vehicle_plate_history for insert to authenticated with check (app.va_has('fleet'));
create policy fleet_update on vehicle_plate_history for update to authenticated using (app.va_has('fleet')) with check (app.va_has('fleet'));
-- imports: Finance (the matrix row "Tolls and tickets": Finance RW, Fleet R)
create policy finance_read on toll_import_profiles for select to authenticated using (app.va_has('finance'));
create policy finance_insert on toll_import_profiles for insert to authenticated with check (app.va_has('finance'));
create policy finance_update on toll_import_profiles for update to authenticated using (app.va_has('finance')) with check (app.va_has('finance'));
create policy va_read on toll_import_batches for select to authenticated using (app.va_has('finance', 'fleet'));
-- damage: Fleet and Finance read; written by the server's functions
create policy va_read on damage_intakes for select to authenticated using (app.va_has('finance', 'fleet'));
-- company money: Finance reads; enters expenses
create policy finance_read on company_expenses for select to authenticated using (app.va_has('finance'));
create policy finance_insert on company_expenses for insert to authenticated with check (app.va_has('finance'));
create policy finance_update on company_expenses for update to authenticated using (app.va_has('finance')) with check (app.va_has('finance'));
create policy finance_read on company_statements for select to authenticated using (app.va_has('finance'));
create policy finance_read on company_statement_lines for select to authenticated using (app.va_has('finance'));
-- Owner credits: like deductions (Finance reads; the Owner reads their own)
create policy finance_read on owner_credits for select to authenticated using (app.va_has('finance'));
create policy owner_read on owner_credits for select to authenticated using (app.is_my_owner(owner_id));

-- ================================================================ 16. privileges
revoke all on gl_accounts, gl_account_map, vehicle_transponders, vehicle_plate_history, toll_import_profiles, toll_import_batches,
  damage_intakes, company_expense_categories, company_expenses, owner_credits, company_statements, company_statement_lines,
  toll_work_queue, toll_work_queue_summary, damage_work_queue, owner_statement_vehicle_lines, company_statement_report,
  company_statement_vehicles, company_statement_owners, company_statement_totals
  from anon, authenticated;
grant select, insert, update on gl_accounts, gl_account_map, vehicle_transponders, vehicle_plate_history, toll_import_profiles,
  company_expense_categories, company_expenses to authenticated;
grant select on toll_import_batches, damage_intakes, owner_credits, company_statements, company_statement_lines,
  toll_work_queue, toll_work_queue_summary, damage_work_queue, owner_statement_vehicle_lines, company_statement_report,
  company_statement_vehicles, company_statement_owners, company_statement_totals to authenticated;
grant all on gl_accounts, gl_account_map, vehicle_transponders, vehicle_plate_history, toll_import_profiles, toll_import_batches,
  damage_intakes, company_expense_categories, company_expenses, owner_credits, company_statements, company_statement_lines,
  toll_work_queue, toll_work_queue_summary, damage_work_queue, owner_statement_vehicle_lines, company_statement_report,
  company_statement_vehicles, company_statement_owners, company_statement_totals to service_role;
grant usage on sequence toll_import_batch_number_seq, damage_intake_number_seq to service_role;

-- Functions: every function of this migration is closed, then opened to the server.
do $$
declare
  f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array[
              'default_gl_account', 'fee_type_gl_default', 'norm_plate', 'resolve_toll_vehicle', 'match_toll_candidates',
              'match_toll_ticket', 'toll_ticket_admin_fee', 'apply_toll_match', 'run_toll_match', 'toll_intake_row', 'log_toll_ticket',
              'save_toll_import_profile', 'find_toll_import_profile', 'import_toll_batch', 'confirm_toll_match', 'bulk_confirm_toll_matches',
              'charge_after_rental', 'charge_toll_ticket', 'bill_toll_to_owner', 'mark_toll_company_paid', 'record_toll_authority_payment',
              'dispute_toll_ticket', 'name_renter_to_authority', 'close_toll_ticket', 'match_damage_candidates', 'apply_damage_match',
              'log_damage', 'confirm_damage_match', 'bill_damage', 'company_expense_guard', 'job_toll_watch', 'sync_later_owner_revenue',
              'build_owner_statement', 'approve_owner_statement', 'reissue_owner_statement', 'issue_owner_statement', 'record_owner_payout',
              'owner_statement_breakdown', 'multirange_days', 'vehicle_month_days', 'company_month_lines', 'company_statement_sum_columns',
              'build_company_statement', 'finalize_company_statement', 'company_statement_rows', 'csv_field', 'company_statement_csv',
              'owner_statement_csv', 'company_ledger_csv', 'job_company_statement_draft'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
grant execute on all functions in schema app to service_role;
-- pure helpers a browser may use
grant execute on function app.norm_plate(text), app.csv_field(text), app.multirange_days(tstzmultirange) to authenticated;

-- ================================================================ 17. audit
do $$ begin perform app.attach_audit(); end $$;
