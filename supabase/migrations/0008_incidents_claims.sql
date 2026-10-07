-- 0008_incidents_claims.sql
-- Incidents (late return, accident, theft, damage, breakdown), damage costing, claims with a
-- per-claim ledger, total-loss settlements and the shareholder 90/10 split.
-- Sources: renter spec section 1 (damage rows); owner spec section 7; procedures 8, 9 and 10.

-- ---------------------------------------------------------------- pure rules
-- Loss of use: the daily rate per day out of service, at most 30 days. Part of the Damage cost.
create or replace function public.calc_loss_of_use(p_daily_rate_cents bigint, p_days_out integer, p_max_days integer default 30)
returns bigint language sql immutable as $$
  select p_daily_rate_cents * least(greatest(p_days_out, 0), p_max_days)
$$;

-- What the driver is billed for Damage.
--   under the deductible : actual cost plus the $50 administration fee; no claim
--   deductible or more   : the $2,500 deductible plus the $75 administration fee; a fleet policy claim.
--                          Loss of use is not added on top.
--   Owner Booking        : under: the Owner repairs it at their own cost (nothing billed);
--                          claim: the $2,500 deductible, no administration fee.
create or replace function public.calc_damage_billing(
  p_damage_cost_cents bigint, p_is_owner_booking boolean default false,
  p_deductible_cents bigint default 250000,
  p_admin_fee_other_cents bigint default 5000, p_admin_fee_claim_cents bigint default 7500)
returns table (path text, damage_billed_cents bigint, deductible_billed_cents bigint, admin_fee_cents bigint)
language sql immutable as $$
  select case when p_damage_cost_cents >= p_deductible_cents then 'fleet_policy' else 'at_cost' end,
         case when p_damage_cost_cents >= p_deductible_cents or p_is_owner_booking then 0 else p_damage_cost_cents end,
         case when p_damage_cost_cents >= p_deductible_cents then p_deductible_cents else 0 end,
         case when p_is_owner_booking or p_damage_cost_cents <= 0 then 0
              when p_damage_cost_cents >= p_deductible_cents then p_admin_fee_claim_cents
              else p_admin_fee_other_cents end
$$;

-- The result of one claim once all money is in (owner spec section 7).
--   third-party Owner : any balance belongs to CarmaCars; a shortfall is the Owner's (unless CarmaCars caused it)
--   shareholder       : profit and shortfall both split 90/10 (p_owner_share_bps)
-- owner_cents is negative when the Owner owes a shortfall.
create or replace function public.calc_claim_result(
  p_money_in_cents bigint, p_repair_cents bigint, p_policy_deductible_cents bigint, p_claim_costs_cents bigint,
  p_is_shareholder boolean, p_owner_share_bps integer default 9000, p_caused_by_company boolean default false)
returns table (result_cents bigint, owner_cents bigint, company_cents bigint)
language sql immutable as $$
  select r,
         case when p_is_shareholder then public.calc_bps(r, p_owner_share_bps)
              when r < 0 and not p_caused_by_company then r
              else 0 end,
         case when p_is_shareholder then r - public.calc_bps(r, p_owner_share_bps)
              when r < 0 and not p_caused_by_company then 0
              else r end
    from (select p_money_in_cents - p_repair_cents - p_policy_deductible_cents - p_claim_costs_cents as r) x
$$;

-- Total loss or unrecovered theft: the settlement pays the lender first, then amounts the
-- Owner owes CarmaCars, then the Owner.
create or replace function public.calc_total_loss(p_settlement_cents bigint, p_lender_due_cents bigint, p_owner_owes_cents bigint)
returns table (lender_cents bigint, company_cents bigint, owner_cents bigint)
language sql immutable as $$
  select l, c, p_settlement_cents - l - c
    from (select l, least(greatest(p_owner_owes_cents, 0), p_settlement_cents - l) as c
            from (select least(greatest(p_lender_due_cents, 0), p_settlement_cents) as l) a) b
$$;

-- ---------------------------------------------------------------- incidents
create sequence incident_number_seq start 1001;
create sequence claim_number_seq start 1001;

create table incidents (
  id              uuid primary key default gen_random_uuid(),
  incident_number text not null unique default ('IN-' || nextval('incident_number_seq')),
  kind            text not null check (kind in (
                    'late_return', 'non_return', 'accident', 'theft', 'vandalism', 'damage_at_return',
                    'damage_found_later', 'breakdown', 'tracker_tampering', 'impound', 'other')),
  vehicle_id      uuid not null references vehicles (id),
  booking_id      uuid references bookings (id),
  driver_id       uuid references drivers (id),
  staff_user_id   uuid references users (id),            -- when CarmaCars staff had the car
  occurred_at     timestamptz,
  reported_at     timestamptz not null default now(),
  place           text,
  description     text,
  other_party     jsonb,
  police_report_number text,
  anyone_hurt     boolean,
  drivable        boolean,
  breakdown_cause text check (breakdown_cause in ('mechanical', 'lockout', 'out_of_fuel_or_charge', 'flat_battery', 'tire_damage', 'stuck', 'other')),
  renter_at_fault boolean,                               -- breakdown: decides who pays the call-out
  rental_ended    boolean not null default false,        -- not drivable: the rental ends, no replacement, no refund
  renter_report_due_at timestamptz,                      -- written report, photos and keys within 48 hours
  renter_report_received_at timestamptz,
  owner_notified_at timestamptz,                         -- T17
  broker_notified_at timestamptz,                        -- the same day
  reported_stolen_at timestamptz,                        -- an Admin's decision
  status          text not null default 'open'
                  check (status in ('open', 'assessing', 'billed', 'claim_open', 'closed')),
  opened_by       uuid references users (id),            -- Fleet opens
  closed_by       uuid references users (id),
  closed_at       timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index incidents_booking_idx on incidents (booking_id);
create index incidents_vehicle_idx on incidents (vehicle_id, reported_at desc);
create index incidents_open_idx on incidents (status) where status <> 'closed';
create trigger incidents_updated before update on incidents for each row execute function app.set_updated_at();

-- Timeline: every call, message, command and decision, with its time (procedure 8 "Record").
create table incident_events (
  id          uuid primary key default gen_random_uuid(),
  incident_id uuid not null references incidents (id) on delete cascade,
  occurred_at timestamptz not null default now(),
  kind        text not null check (kind in ('call', 'message', 'tracker_check', 'tracker_command', 'decision',
                                            'police', 'roadside', 'tow', 'repossession', 'note')),
  detail      text not null,
  message_id  uuid references messages (id),
  tracker_command_id uuid references tracker_commands (id),
  document_id uuid references documents (id),
  actor_user_id uuid references users (id),
  created_at  timestamptz not null default now()
);
create index incident_events_incident_idx on incident_events (incident_id, occurred_at);
create trigger incident_events_append_only before update or delete on incident_events
  for each row execute function app.forbid_change();

-- The parts of a Damage cost: repair + towing + storage + loss of use (and other claim costs).
create table incident_costs (
  id           uuid primary key default gen_random_uuid(),
  incident_id  uuid not null references incidents (id) on delete cascade,
  kind         text not null check (kind in ('repair_estimate', 'repair_invoice', 'towing', 'storage', 'loss_of_use',
                                             'appraisal', 'roadside_callout', 'recovery', 'key_replacement', 'other')),
  description  text,
  amount_cents bigint not null check (amount_cents >= 0),   -- as invoiced
  hst_cents    bigint not null default 0,                    -- HST shown on the invoice (already inside amount_cents when included)
  days         integer,                                      -- loss of use
  shop_name    text,
  approved_shop boolean,
  document_id  uuid references documents (id),
  superseded   boolean not null default false,               -- an estimate replaced by the invoice
  created_by   uuid references users (id),
  created_at   timestamptz not null default now(),
  check (kind <> 'loss_of_use' or (days is not null and days between 0 and 30)),
  check (kind not in ('repair_estimate', 'repair_invoice') or approved_shop is not null)
);
create index incident_costs_incident_idx on incident_costs (incident_id);

create or replace function app.incident_damage_cost(p_incident uuid) returns bigint
language sql stable security definer set search_path = public, app as $$
  select coalesce(sum(amount_cents), 0)::bigint from incident_costs
   where incident_id = p_incident and not superseded
     and kind in ('repair_estimate', 'repair_invoice', 'towing', 'storage', 'loss_of_use')
$$;

alter table booking_line_items add constraint booking_line_items_incident_fk
  foreign key (incident_id) references incidents (id);
alter table tracker_commands add constraint tracker_commands_incident_fk
  foreign key (incident_id) references incidents (id);
alter table documents add column incident_id uuid references incidents (id);
alter table condition_report_damages add column incident_id uuid references incidents (id);

-- ---------------------------------------------------------------- claims
-- One row per damage event that moves money, each with its own ledger. Claim money never
-- sits on the Owner's account.
create table claims (
  id               uuid primary key default gen_random_uuid(),
  claim_number     text not null unique default ('CL-' || nextval('claim_number_seq')),
  incident_id      uuid not null unique references incidents (id),
  vehicle_id       uuid not null references vehicles (id),
  owner_id         uuid not null references owners (id),
  booking_id       uuid references bookings (id),
  path             text not null check (path in ('at_cost', 'fleet_policy', 'total_loss', 'turo')),
  is_owner_booking boolean not null default false,
  is_shareholder_vehicle boolean not null default false,   -- snapshot: 90/10 on profit and on shortfall
  owner_share_bps  integer not null default 0 check (owner_share_bps between 0 and 10000),
  damage_cost_cents bigint not null default 0,             -- the total that chose the path
  deductible_billed_cents bigint not null default 0,
  admin_fee_cents  bigint not null default 0,
  loss_of_use_days integer check (loss_of_use_days between 0 and 30),
  insurer_claim_ref text,
  broker_notified_at timestamptz,
  denied_reason    text,
  denied_for_renter_breach boolean not null default false, -- Admin bills the full cost
  caused_by_company boolean not null default false,        -- a shortfall CarmaCars caused is not the Owner's
  status           text not null default 'opened' check (status in (
                     'opened', 'submitted', 'accepted', 'denied', 'in_repair', 'repaired', 'settling',
                     'total_loss', 'settlement_received', 'distributed', 'closed', 'withdrawn')),
  -- ledger totals, kept by trigger
  money_in_cents   bigint not null default 0,              -- insurer and renter (or Owner) payments
  repair_cents     bigint not null default 0,
  policy_deductible_cents bigint not null default 0,
  claim_costs_cents bigint not null default 0,             -- towing, storage, appraisal
  -- result, set when the claim is settled
  result_cents     bigint,                                 -- Claim Profit (negative = shortfall)
  owner_result_cents bigint,
  company_result_cents bigint,
  settled_at       timestamptz,
  settled_by       uuid references users (id),
  second_approved_by uuid references users (id),           -- shareholder vehicles: both Principals
  -- total loss or unrecovered theft
  insurer_decision_on date,                                -- Fees stop on this date
  settlement_cents bigint,
  settlement_cleared_on date,
  lender_due_cents bigint,
  owner_owes_cents bigint,
  lender_paid_cents bigint,
  company_setoff_cents bigint,
  owner_balance_cents bigint,
  owner_balance_due_by date,                               -- 10 business days after cleared funds
  opened_by        uuid references users (id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (not is_shareholder_vehicle or owner_share_bps > 0),
  check (status <> 'denied' or denied_reason is not null)
);
create index claims_vehicle_idx on claims (vehicle_id);
create index claims_owner_idx on claims (owner_id);
create index claims_open_idx on claims (status) where status not in ('closed', 'withdrawn');
create trigger claims_updated before update on claims for each row execute function app.set_updated_at();

create table claim_ledger_entries (
  id           uuid primary key default gen_random_uuid(),
  claim_id     uuid not null references claims (id),
  entry_date   date not null default app.today(),
  kind         text not null check (kind in (
                 -- money in
                 'insurer_payment', 'renter_deductible', 'renter_at_cost', 'renter_coverage_payment',
                 'owner_deductible', 'owner_shortfall_payment', 'settlement',
                 -- costs
                 'repair', 'policy_deductible', 'towing', 'storage', 'appraisal', 'other_claim_cost',
                 -- distribution of the result
                 'lender_payment', 'company_setoff', 'owner_balance', 'owner_profit_share', 'company_surplus')),
  direction    text generated always as (
                 case when kind in ('insurer_payment', 'renter_deductible', 'renter_at_cost', 'renter_coverage_payment',
                                    'owner_deductible', 'owner_shortfall_payment', 'settlement') then 'in' else 'out' end) stored,
  amount_cents bigint not null check (amount_cents > 0),
  description  text,
  payment_id   uuid references payments (id),            -- money in from the renter or Owner
  line_item_id uuid references booking_line_items (id),
  payout_id    uuid references payouts (id),             -- money out to the Owner
  document_id  uuid references documents (id),           -- invoice, remittance or receipt
  created_by   uuid references users (id),
  created_at   timestamptz not null default now()
);
create index claim_ledger_entries_claim_idx on claim_ledger_entries (claim_id, entry_date);
-- a ledger is corrected by a new entry, never by rewriting one
create trigger claim_ledger_append_only before update or delete on claim_ledger_entries
  for each row execute function app.forbid_change();

create or replace function app.claim_ledger_recalc() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  update claims c set
    money_in_cents = coalesce((select sum(amount_cents) from claim_ledger_entries e where e.claim_id = c.id
        and e.kind in ('insurer_payment', 'renter_deductible', 'renter_at_cost', 'renter_coverage_payment', 'owner_deductible')), 0),
    repair_cents = coalesce((select sum(amount_cents) from claim_ledger_entries e where e.claim_id = c.id and e.kind = 'repair'), 0),
    policy_deductible_cents = coalesce((select sum(amount_cents) from claim_ledger_entries e where e.claim_id = c.id and e.kind = 'policy_deductible'), 0),
    claim_costs_cents = coalesce((select sum(amount_cents) from claim_ledger_entries e where e.claim_id = c.id
        and e.kind in ('towing', 'storage', 'appraisal', 'other_claim_cost')), 0)
  where c.id = new.claim_id;
  return null;
end $$;
create trigger claim_ledger_recalc after insert on claim_ledger_entries
  for each row execute function app.claim_ledger_recalc();

alter table payouts add constraint payouts_claim_fk foreign key (claim_id) references claims (id);
alter table documents add column claim_id uuid references claims (id);

-- Open the claim record for an incident from its costed Damage. Chooses the path by the $2,500 rule.
create or replace function app.open_claim(p_incident uuid, p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  i incidents;
  v vehicles;
  b bookings;
  v_cost bigint := app.incident_damage_cost(p_incident);
  v_set program_settings := app.settings();
  d record;
  v_id uuid;
begin
  select * into i from incidents where id = p_incident;
  select * into v from vehicles where id = i.vehicle_id;
  if i.booking_id is not null then select * into b from bookings where id = i.booking_id; end if;
  if v.management_mode = 'turo_only' then
    insert into claims (incident_id, vehicle_id, owner_id, path, damage_cost_cents, opened_by)
    values (p_incident, v.id, v.owner_id, 'turo', v_cost, p_by) returning id into v_id;   -- Turo's terms govern
    return v_id;
  end if;
  select * into d from public.calc_damage_billing(v_cost, coalesce(b.booking_type = 'owner', false),
      coalesce(b.deductible_cents, v_set.deductible_cents),
      coalesce((select amount_cents from public.effective_fee('admin_fee_other', v.id)), 5000),
      coalesce((select amount_cents from public.effective_fee('admin_fee_claim', v.id)), 7500));
  insert into claims (incident_id, vehicle_id, owner_id, booking_id, path, is_owner_booking, is_shareholder_vehicle,
      owner_share_bps, damage_cost_cents, deductible_billed_cents, admin_fee_cents, loss_of_use_days, opened_by)
  values (p_incident, v.id, v.owner_id, i.booking_id, d.path, coalesce(b.booking_type = 'owner', false), v.is_shareholder_owned,
      case when v.is_shareholder_owned then 10000 - v_set.shareholder_company_share_bps else 0 end,
      v_cost, d.deductible_billed_cents, d.admin_fee_cents,
      (select sum(days) from incident_costs where incident_id = p_incident and kind = 'loss_of_use' and not superseded), p_by)
  returning id into v_id;
  update incidents set status = case when d.path = 'fleet_policy' then 'claim_open' else 'assessing' end where id = p_incident;
  return v_id;
end $$;

-- Settle a repair claim once all money is in and costs are known.
--   third-party vehicle: surplus stays with CarmaCars; a shortfall is billed to the Owner as an Owner cost.
--   shareholder vehicle: 90/10 both ways; paying it needs both Principals.
create or replace function app.settle_claim(p_claim uuid, p_admin uuid, p_second_admin uuid default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  c claims;
  r record;
begin
  select * into c from claims where id = p_claim for update;
  if c.path not in ('at_cost', 'fleet_policy') then
    raise exception 'Claim % follows the % process, not a repair settlement', c.claim_number, c.path using errcode = '23514';
  end if;
  if c.result_cents is not null then
    raise exception 'Claim % is already settled', c.claim_number using errcode = '23514';
  end if;
  if not exists (select 1 from user_roles where user_id = p_admin and role = 'admin') then
    raise exception 'Only an Admin settles a claim' using errcode = '42501';
  end if;
  if c.is_shareholder_vehicle and (p_second_admin is null or p_second_admin = p_admin
       or not exists (select 1 from user_roles where user_id = p_second_admin and role = 'admin')) then
    raise exception 'A shareholder vehicle''s claim needs both Principals'' approval' using errcode = '42501';
  end if;

  select * into r from public.calc_claim_result(c.money_in_cents, c.repair_cents, c.policy_deductible_cents,
      c.claim_costs_cents, c.is_shareholder_vehicle, c.owner_share_bps, c.caused_by_company);

  update claims set result_cents = r.result_cents, owner_result_cents = r.owner_cents, company_result_cents = r.company_cents,
         settled_at = now(), settled_by = p_admin, second_approved_by = p_second_admin
   where id = p_claim;

  if r.company_cents > 0 then
    insert into claim_ledger_entries (claim_id, kind, amount_cents, description, created_by)
    values (p_claim, 'company_surplus', r.company_cents, 'Balance after repair and claim costs', p_admin);
  end if;
  if r.owner_cents > 0 then
    -- Claim Profit, owning shareholder's share
    with p as (
      insert into payouts (payee_type, owner_id, kind, claim_id, amount_cents, scheduled_for, status,
                           prepared_by, approved_by, approved_at, second_approved_by, requires_both_principals)
      values ('owner', c.owner_id, 'claim_profit', p_claim, r.owner_cents, app.today(), 'approved',
              p_admin, p_admin, now(), p_second_admin, true)
      returning id)
    insert into claim_ledger_entries (claim_id, kind, amount_cents, description, payout_id, created_by)
    select p_claim, 'owner_profit_share', r.owner_cents, 'Claim Profit, Owner Share', p.id, p_admin from p;
  elsif r.owner_cents < 0 then
    -- shortfall: billed as an Owner cost, with receipts
    insert into owner_deductions (owner_id, vehicle_id, kind, description, amount_cents, incurred_on, booking_id, created_by)
    values (c.owner_id, c.vehicle_id, 'claim_shortfall', format('Claim %s: shortfall after claim money', c.claim_number),
            -r.owner_cents, app.today(), c.booking_id, p_admin);
  end if;
end $$;

-- Record a total-loss settlement and how it is paid out (Title Agreement 9.1).
create or replace function app.record_total_loss_settlement(
  p_claim uuid, p_settlement_cents bigint, p_cleared_on date, p_lender_due_cents bigint, p_admin uuid)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  c claims;
  v_owes bigint;
  r record;
begin
  select * into c from claims where id = p_claim for update;
  if c.path <> 'total_loss' then
    raise exception 'Claim % is not a total loss', c.claim_number using errcode = '23514';
  end if;
  if not exists (select 1 from user_roles where user_id = p_admin and role = 'admin') then
    raise exception 'Only an Admin records a settlement' using errcode = '42501';
  end if;
  -- what the Owner owes CarmaCars: unpaid invoices, open deductions and any debt carried forward
  select coalesce((select sum(balance_cents) from owner_invoices where owner_id = c.owner_id
                    and status in ('issued', 'processing', 'failed', 'retry_processing', 'in_arrears', 'partially_deducted')), 0)
       + coalesce((select sum(amount_cents) from owner_deductions where owner_id = c.owner_id and status = 'open'), 0)
       + coalesce((select -least(balance_carried_forward_cents, 0) from owners where id = c.owner_id), 0)
    into v_owes;
  select * into r from public.calc_total_loss(p_settlement_cents, p_lender_due_cents, v_owes);
  update claims set settlement_cents = p_settlement_cents, settlement_cleared_on = p_cleared_on,
         lender_due_cents = p_lender_due_cents, owner_owes_cents = v_owes,
         lender_paid_cents = r.lender_cents, company_setoff_cents = r.company_cents, owner_balance_cents = r.owner_cents,
         owner_balance_due_by = app.add_business_days(p_cleared_on, (app.settings()).total_loss_balance_business_days),
         settled_by = p_admin, settled_at = now()
   where id = p_claim;
  insert into claim_ledger_entries (claim_id, entry_date, kind, amount_cents, description, created_by)
  values (p_claim, p_cleared_on, 'settlement', p_settlement_cents, 'Total-loss settlement, held for the Owner', p_admin);
end $$;

-- A total loss ends the Program for the vehicle: Fees stop on the date of the Insurer's decision.
create or replace function app.claim_total_loss_effects() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.insurer_decision_on is not null and new.insurer_decision_on is distinct from old.insurer_decision_on
     and new.path = 'total_loss' then
    update vehicles set total_loss_decided_on = new.insurer_decision_on where id = new.vehicle_id;
  end if;
  return null;
end $$;
create trigger claims_total_loss_effects after update of insurer_decision_on on claims
  for each row execute function app.claim_total_loss_effects();
