-- 0640: owner agreements for every special deal (Release 31, "Owner agreements"). SCHEMA_MARKER 0641 (with the guides of 0641).
-- Record: docs/changes/2026-11-07-r31-owner-agreements.md. No applied migration is edited; the functions it changes are
-- wrapped (renamed with the suffix _pre0640) or replaced with the same signature. No amount, rate or person is written
-- here: every supplier's numbers are entered in Admin (Admin > an owner > Terms > Fleet lease).
--
-- 1. Fleet lease (a supplier's corporation leases many cars to the Company):
--      owner_fleet_lease_terms   per supplier, dated: the Regular and Troubled Rates (the default lease a month for each
--                                car of that tier), the Claim Profit Share, the Early and Later Write-Off Shares, the
--                                Write-Off Period (months) and the Notice Period (days). Changed after the supplier signed:
--                                the new row waits for the supplier's signature of the new agreement.
--      owner_upkeep_split        per supplier and cost type (engine, transmission, shocks, ...): who pays it.
--      vehicle_owner_arrangements kind fleet_lease with the car's tier (0196's flat monthly mechanics: CarmaCars keeps
--                                the rentals, no Fees, a credit a month on the owner statement, part months by the day).
--                                The tier is set once, when the car is onboarded, and never changes (an Admin corrects a
--                                data-entry mistake, with the reason). No fee of any kind: no owner invoice or debit is
--                                ever made for a fleet lease car (a guard on owner_invoices, the monthly run, the debits).
--      In arrears: a car's first payment is on the first Payout Date at least one full month after its delivery and
--      covers every month up to then; after that each month is paid on the Payout Date after it. The statement line
--      shows the calculation (rate x days / days in the month).
--      Claims: the Claim Profit Share of a settled repair claim, and the write-off rule of a total loss (any lender
--      first, then the Early or Later Write-Off Share by the months in service), as credits on the supplier's statement.
--      Upkeep costs: app.fleet_upkeep_cost bills the supplier's cost types to the supplier (an owner deduction); r29's
--      repair costs (vehicle_repair_costs, when that table exists) get a cost type and bill the same way.
-- 2. The agreement set: owner_agreements.variant fleet_lease (Fleet Supplier Lease Agreement); the owner's pay model is
--    fleet_lease when every car is on a fleet lease. The facts carry the lease terms, the upkeep table, each car's tier,
--    rate and delivery date, and (for the standard set) the shareholder flag and the onboarding costs and how they are paid.
-- 3. The Referral Override Agreement: signed by the referrer of an owner referral link (0543) in the owner portal, like the
--    partner agreement (sign_requests doc_type referral_agreement, countersigned at once).
-- 4. Admin > Owners > Agreements: each owner's required agreements, sent, signed or missing, and Send (the email
--    owner_agreement_to_sign with the link).
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

-- ================================================================ 1. records
create table owner_fleet_lease_terms (
  id                  uuid primary key default gen_random_uuid(),
  owner_id            uuid not null references owners (id),
  regular_cents       bigint not null check (regular_cents > 0),
  troubled_cents      bigint not null check (troubled_cents > 0),
  claim_profit_bps    integer not null check (claim_profit_bps between 0 and 10000),
  early_writeoff_bps  integer not null check (early_writeoff_bps between 0 and 10000),
  writeoff_months     integer not null check (writeoff_months between 1 and 240),
  later_writeoff_bps  integer not null check (later_writeoff_bps between 0 and 10000),
  notice_days         integer not null check (notice_days between 1 and 365),
  effective_from      date not null,
  effective_to        date,
  awaiting_signature  boolean not null default false,
  note                text check (char_length(note) <= 500),
  created_by          uuid references users (id) on delete set null,
  created_at          timestamptz not null default now(),
  check (effective_to is null or effective_to > effective_from)
);
create index owner_fleet_lease_terms_owner on owner_fleet_lease_terms (owner_id, effective_from desc);
alter table owner_fleet_lease_terms enable row level security;
create policy admin_all on owner_fleet_lease_terms for select to authenticated using (app.is_admin());
create trigger audit_owner_fleet_lease_terms after insert or update or delete on owner_fleet_lease_terms for each row execute function app.audit_row();
comment on table owner_fleet_lease_terms is 'A fleet supplier''s lease terms (0640), dated: the lease a month per car by tier (the default for every car of that tier), the claim profit share, the write-off rule and the notice. Entered in Admin. awaiting_signature: entered after the supplier signed; in force once the supplier signs the new agreement.';

create table owner_upkeep_split (
  owner_id   uuid not null references owners (id),
  cost_type  text not null check (cost_type in ('engine', 'transmission', 'shocks', 'rustproofing', 'refurbishment', 'tires', 'brakes', 'oil_change', 'ball_joints')),
  party      text not null check (party in ('supplier', 'company')),
  set_by     uuid references users (id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (owner_id, cost_type)
);
alter table owner_upkeep_split enable row level security;
create policy admin_all on owner_upkeep_split for select to authenticated using (app.is_admin());
create trigger audit_owner_upkeep_split after insert or update or delete on owner_upkeep_split for each row execute function app.audit_row();
comment on table owner_upkeep_split is 'Who pays each type of upkeep cost on a fleet supplier''s cars (0640): the supplier or the Company. The agreement''s Upkeep Table; repair costs of a supplier type are billed to the supplier.';

create or replace function app.upkeep_label(p_type text) returns text
language sql immutable as $$
  select case p_type when 'engine' then 'Engine' when 'transmission' then 'Transmission' when 'shocks' then 'Shocks and struts'
    when 'rustproofing' then 'Rustproofing' when 'refurbishment' then 'Refurbishment not part of a claim' when 'tires' then 'Tires'
    when 'brakes' then 'Brakes' when 'oil_change' then 'Oil changes' when 'ball_joints' then 'Ball joints' else p_type end
$$;

alter table vehicle_owner_arrangements drop constraint if exists vehicle_owner_arrangements_kind_check;
alter table vehicle_owner_arrangements add constraint vehicle_owner_arrangements_kind_check check (kind in ('flat_monthly', 'fleet_lease'));
alter table vehicle_owner_arrangements add column if not exists lease_tier text check (lease_tier in ('regular', 'troubled')),
  add column if not exists fleet_terms_id uuid references owner_fleet_lease_terms (id);
alter table vehicle_owner_arrangements add constraint vehicle_owner_arrangements_fleet_tier check (kind <> 'fleet_lease' or lease_tier is not null);
comment on column vehicle_owner_arrangements.lease_tier is 'A fleet lease car''s tier (0640): regular or troubled, set once when the car is onboarded. Only an Admin corrects a data-entry mistake (fleet_lease_tier_correct).';

alter table owner_agreements drop constraint if exists owner_agreements_variant_check;
alter table owner_agreements add constraint owner_agreements_variant_check check (variant in ('standard', 'flat_rate', 'fleet_lease'));
alter table program_settings add column if not exists fleet_lease_agreements_awaiting_lawyer boolean not null default true,
  add column if not exists referral_agreements_awaiting_lawyer boolean not null default true;
comment on column program_settings.fleet_lease_agreements_awaiting_lawyer is 'Fleet lease agreements awaiting lawyer OK (0640): on until the lawyer approves docs/source/v2_fleet_lease.md; Admin marks the agreement. Suppliers can sign either way.';
comment on column program_settings.referral_agreements_awaiting_lawyer is 'Referral Override agreements awaiting lawyer OK (0640): on until the lawyer approves docs/source/v2_referral_override.md.';

alter table owner_credits drop constraint if exists owner_credits_kind_check;
alter table owner_credits add constraint owner_credits_kind_check check (kind in ('later_rental_revenue', 'correction', 'staff_commission_adjustment', 'flat_monthly',
  'claim_profit_share', 'write_off_share'));
alter table owner_credits add column if not exists claim_id uuid references claims (id);
create unique index if not exists owner_credits_claim_once on owner_credits (claim_id, kind) where claim_id is not null and status <> 'waived';

alter table owner_deductions add column if not exists upkeep_cost_type text,
  add column if not exists upkeep_ref uuid;
comment on column owner_deductions.upkeep_ref is 'The repair cost (r29 vehicle_repair_costs) this upkeep deduction bills to a fleet supplier (0640)';

alter table claims add column if not exists fleet_terms_id uuid references owner_fleet_lease_terms (id),
  add column if not exists fleet_share_bps integer,
  add column if not exists fleet_service_months integer;

alter table owner_referral_links add column if not exists agreement_status text not null default 'not_sent' check (agreement_status in ('not_sent', 'sent', 'signed')),
  add column if not exists agreement_signed_at timestamptz,
  add column if not exists agreement_method text,
  add column if not exists agreement_document_id uuid references documents (id);

alter table sign_requests add column if not exists referral_link_id uuid references owner_referral_links (id);
alter table sign_requests drop constraint if exists sign_requests_doc_type_check;
alter table sign_requests add constraint sign_requests_doc_type_check
  check (doc_type in ('form_a', 'form_b', 'form_c', 'investment_agreement', 'staff_agreement', 'partner_agreement', 'referral_agreement'));
alter table sign_requests add constraint sign_requests_referral_link check (doc_type <> 'referral_agreement' or (owner_id is not null and referral_link_id is not null));

create table owner_agreement_sends (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null references owners (id),
  doc_key          text not null check (doc_key in ('packet', 'partner', 'referral')),
  referral_link_id uuid references owner_referral_links (id),
  to_address       text not null,
  outbox_id        uuid,
  sent_by          uuid references users (id) on delete set null,
  sent_at          timestamptz not null default now()
);
create index owner_agreement_sends_owner on owner_agreement_sends (owner_id, sent_at desc);
alter table owner_agreement_sends enable row level security;
create policy admin_all on owner_agreement_sends for select to authenticated using (app.is_admin());
create trigger audit_owner_agreement_sends after insert or update or delete on owner_agreement_sends for each row execute function app.audit_row();
comment on table owner_agreement_sends is 'Each Send on Admin > Owners > Agreements (0640): who was emailed which agreement to sign, and when.';

-- ================================================================ 2. the fleet lease terms
create or replace function app.fleet_terms_on(p_owner uuid, p_on date) returns owner_fleet_lease_terms
language sql stable security definer set search_path = public, app as $$
  select * from owner_fleet_lease_terms t
   where t.owner_id = p_owner and not t.awaiting_signature and t.effective_from <= p_on and (t.effective_to is null or t.effective_to > p_on)
   order by t.effective_from desc limit 1
$$;

-- The terms the supplier signs (or signed): the one waiting for a signature, else the latest in force or starting later.
create or replace function app.fleet_terms_current(p_owner uuid) returns owner_fleet_lease_terms
language sql stable security definer set search_path = public, app as $$
  select * from owner_fleet_lease_terms t where t.owner_id = p_owner and (t.effective_to is null or t.effective_to > app.today())
   order by t.awaiting_signature desc, t.effective_from desc limit 1
$$;

create or replace function app.fleet_rate(t owner_fleet_lease_terms, p_tier text) returns bigint
language sql immutable as $$ select case p_tier when 'troubled' then t.troubled_cents else t.regular_cents end $$;

-- A car's Delivery Date: the start of its first fleet lease period with this owner.
create or replace function app.fleet_delivered_on(p_vehicle uuid) returns date
language sql stable security definer set search_path = public, app as $$
  select min(a.starts_on) from vehicle_owner_arrangements a join vehicles v on v.id = a.vehicle_id and v.owner_id = a.owner_id
   where a.vehicle_id = p_vehicle and a.kind = 'fleet_lease' and a.cancelled_at is null
$$;

-- The first statement month whose Payout Date is at least one full month after delivery (payment in arrears).
create or replace function app.fleet_first_pay_month(p_delivered date) returns date
language plpgsql stable security definer set search_path = public, app as $$
declare m date := app.month_start(p_delivered);
begin
  if p_delivered is null then return null; end if;
  while app.payout_date(m) < (p_delivered + interval '1 month')::date loop m := (m + interval '1 month')::date; end loop;
  return m;
end $$;

-- the owner's pay model (0205) knows the fleet lease: fleet_lease when every car in the program is on one
create or replace function app.owner_pay_model(p_owner uuid) returns text
language sql stable security definer set search_path = public, app as $$
  with cars as (
    select v.id,
           exists (select 1 from vehicle_owner_arrangements a where a.vehicle_id = v.id and a.kind = 'fleet_lease' and a.cancelled_at is null and (a.ends_on is null or a.ends_on >= app.today())) as fleet,
           exists (select 1 from vehicle_owner_arrangements a where a.vehicle_id = v.id and a.kind = 'flat_monthly' and a.cancelled_at is null and (a.ends_on is null or a.ends_on >= app.today())) as flat
      from vehicles v
     where v.owner_id = p_owner and v.status not in ('exited', 'declined', 'total_loss') and coalesce(v.supply_type::text, 'program_owner') = 'program_owner')
  select case when count(*) = 0 then 'standard'
              when bool_and(fleet) then 'fleet_lease'
              when bool_and(flat or fleet) then 'flat_rate'
              else 'standard' end
    from cars
$$;

-- A fleet lease period: no Enrollment Date clamp (the lease runs from delivery, before the car is on the fleet policy).
create or replace function app.flat_window(a vehicle_owner_arrangements, p_from date, p_to date, out d_from date, out d_to date, out days integer)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
begin
  select * into v from vehicles where id = a.vehicle_id;
  d_from := greatest(a.starts_on, p_from, case when a.kind = 'fleet_lease' then a.starts_on else coalesce(v.enrollment_date, a.starts_on) end);
  d_to := least(coalesce(a.ends_on, 'infinity'::date), p_to, coalesce(app.vehicle_fee_end(a.vehicle_id), 'infinity'::date));
  days := case when a.id is null or a.cancelled_at is not null or d_to < d_from then 0 else (d_to - d_from) + 1 end;
end $$;

-- The statement line of a month: a fleet lease shows its tier and the calculation.
create or replace function app.flat_month_line(a vehicle_owner_arrangements, p_month date, out cents bigint, out description text)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_m date := app.month_start(p_month);
  v_dim integer := app.days_in_month(v_m);
  w record;
begin
  select * into w from app.flat_window(a, v_m, (v_m + interval '1 month - 1 day')::date);
  cents := case when w.days > 0 then public.calc_prorated_fee(a.monthly_cents, w.days, v_dim) else 0 end;
  if a.kind = 'fleet_lease' then
    description := format('Lease payment, %s, %s car: ', to_char(v_m, 'FMMonth YYYY'), initcap(a.lease_tier))
      || case when w.days > 0 and w.days < v_dim
              then format('%s a month x %s of %s days (%s to %s) = %s', app.fmt_money(a.monthly_cents), w.days, v_dim, app.flat_day(w.d_from), app.flat_day(w.d_to), app.fmt_money(cents))
              else format('%s a month, the whole month', app.fmt_money(a.monthly_cents)) end;
    return;
  end if;
  description := format('Flat monthly payment, %s: %s a month', to_char(v_m, 'FMMonth YYYY'), app.fmt_money(a.monthly_cents))
    || case when w.days > 0 and w.days < v_dim then format(', %s of %s days (%s to %s)', w.days, v_dim, app.flat_day(w.d_from), app.flat_day(w.d_to)) else '' end;
end $$;

-- In arrears: a fleet car's months wait for the first Payout Date one full month after delivery.
alter function app.flat_credits_sync(uuid, date) rename to flat_credits_sync_pre0640;
create function app.flat_credits_sync(p_owner uuid, p_month date) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_month date := app.month_start(p_month);
  c record;
begin
  perform app.flat_credits_sync_pre0640(p_owner, p_month);
  for c in select x.id from owner_credits x join vehicle_owner_arrangements a on a.id = x.flat_arrangement_id
            where x.owner_id = p_owner and x.kind = 'flat_monthly' and x.status = 'open' and a.kind = 'fleet_lease'
              and v_month < app.fleet_first_pay_month(app.fleet_delivered_on(a.vehicle_id)) loop
    perform app.flat_drop_credit(c.id);
  end loop;
end $$;
select pg_temp.copy_grants('app.flat_credits_sync(uuid, date)'::regprocedure, 'app.flat_credits_sync_pre0640(uuid, date)'::regprocedure);

-- Put a car on its tier from a date (internal): the 0196 period rules (never into an approved statement, later periods
-- replaced, the one in force ended the day before), then the unpaid rentals follow.
create or replace function app.fleet_apply(p_vehicle uuid, p_tier text, p_from date, p_reason text, p_by uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  t owner_fleet_lease_terms;
  v_lock date;
  v_id uuid;
  r record;
begin
  select * into v from vehicles where id = p_vehicle;
  t := app.fleet_terms_on(v.owner_id, p_from);
  if t.id is null then raise exception 'Enter this supplier''s lease terms first (Admin > the owner > Terms > Fleet lease)' using errcode = '23514'; end if;
  v_lock := app.flat_lock_through(v.owner_id);
  if v_lock is not null and p_from <= v_lock then
    raise exception 'The owner statement up to % is approved and stays as it is: choose % or later', app.flat_day(v_lock), app.flat_day(v_lock + 1) using errcode = '23514';
  end if;
  -- one change: the agreement set (0205) follows once, after the periods are replaced, not at each step
  perform set_config('app.fleet_apply', 'on', true);
  update vehicle_owner_arrangements set cancelled_at = now(), cancelled_by = p_by, cancelled_reason = 'Replaced: ' || left(p_reason, 480)
   where vehicle_id = v.id and cancelled_at is null and starts_on >= p_from;
  update vehicle_owner_arrangements set ends_on = p_from - 1, ended_at = now(), ended_by = p_by, ended_reason = left(p_reason, 500)
   where vehicle_id = v.id and cancelled_at is null and starts_on < p_from and (ends_on is null or ends_on >= p_from);
  insert into vehicle_owner_arrangements (vehicle_id, owner_id, kind, lease_tier, fleet_terms_id, monthly_cents, starts_on, reason, created_by)
  values (v.id, v.owner_id, 'fleet_lease', p_tier, t.id, app.fleet_rate(t, p_tier), p_from, left(p_reason, 500), p_by)
  returning id into v_id;
  perform set_config('app.fleet_apply', '', true);
  perform app.owner_agreement_set_sync(v.owner_id);
  for r in select distinct s.booking_id from booking_splits s where s.vehicle_id = v.id and s.owner_statement_id is null loop
    perform app.compute_booking_split(r.booking_id);
  end loop;
  return v_id;
end $$;

create or replace function app.owner_agreement_set_sync_trg() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if coalesce(current_setting('app.fleet_apply', true), '') = 'on' then return null; end if;
  perform app.owner_agreement_set_sync(coalesce(new.owner_id, old.owner_id));
  return null;
end $$;

-- Reprice every fleet car of a supplier from a date at the terms in force then (a new rate).
create or replace function app.fleet_reprice(p_owner uuid, p_from date, p_by uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  a vehicle_owner_arrangements;
  t owner_fleet_lease_terms := app.fleet_terms_on(p_owner, p_from);
  v_n integer := 0;
begin
  if t.id is null then return 0; end if;
  for a in select x.* from vehicle_owner_arrangements x join vehicles v on v.id = x.vehicle_id and v.owner_id = p_owner
            where x.owner_id = p_owner and x.kind = 'fleet_lease' and x.cancelled_at is null and (x.ends_on is null or x.ends_on >= p_from)
              and x.monthly_cents <> app.fleet_rate(t, x.lease_tier) loop
    perform app.fleet_apply(a.vehicle_id, a.lease_tier, greatest(p_from, a.starts_on), 'New lease rates', p_by);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Admin: the supplier's lease terms. p: owner_id, regular_cents, troubled_cents, claim_profit_bps, early_writeoff_bps,
-- writeoff_months, later_writeoff_bps, notice_days, from (default the first day of next month), note.
-- Before the supplier signed: in force from the date, the cars repriced. After: waits for the supplier's signature of
-- a new Fleet Supplier Lease Agreement, opened now.
create or replace function app.fleet_lease_terms_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  t owner_fleet_lease_terms;
  ea owner_agreements;
  v_from date;
  v_signed boolean;
  v_new uuid;
  k text;
begin
  perform app.assert_admin(p_by);
  select * into o from owners where id = nullif(p ->> 'owner_id', '')::uuid;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  foreach k in array array['regular_cents', 'troubled_cents', 'claim_profit_bps', 'early_writeoff_bps', 'writeoff_months', 'later_writeoff_bps', 'notice_days'] loop
    if coalesce(p ->> k, '') !~ '^\d{1,9}$' then
      raise exception 'Enter %', case k when 'regular_cents' then 'the Regular Rate' when 'troubled_cents' then 'the Troubled Rate' when 'claim_profit_bps' then 'the Claim Profit Share'
        when 'early_writeoff_bps' then 'the Early Write-Off Share' when 'writeoff_months' then 'the Write-Off Period in months' when 'later_writeoff_bps' then 'the Later Write-Off Share' else 'the Notice Period in days' end
        using errcode = '22023';
    end if;
  end loop;
  if (p ->> 'regular_cents')::bigint <= 0 or (p ->> 'troubled_cents')::bigint <= 0 then raise exception 'Each Lease Rate is more than $0.00' using errcode = '22023'; end if;
  if greatest((p ->> 'claim_profit_bps')::integer, (p ->> 'early_writeoff_bps')::integer, (p ->> 'later_writeoff_bps')::integer) > 10000 then
    raise exception 'A share is 0 to 100 percent' using errcode = '22023';
  end if;
  v_from := coalesce(nullif(p ->> 'from', '')::date, (app.month_start(app.today()) + interval '1 month')::date);
  select * into ea from owner_agreements where owner_id = o.id and kind = 'enrollment' and status in ('draft', 'sent', 'signed') order by created_at desc limit 1;
  v_signed := ea.id is not null and ea.status = 'signed' and ea.variant = 'fleet_lease';
  -- a change not signed yet replaces the one waiting
  delete from owner_fleet_lease_terms where owner_id = o.id and awaiting_signature
    and not exists (select 1 from vehicle_owner_arrangements a where a.fleet_terms_id = owner_fleet_lease_terms.id);
  if not v_signed then
    -- not signed yet: the terms from this date replace any set from it or later (the cars are repriced below)
    update owner_fleet_lease_terms set effective_to = v_from where owner_id = o.id and not awaiting_signature and effective_from < v_from and (effective_to is null or effective_to > v_from);
    update vehicle_owner_arrangements set fleet_terms_id = null
     where fleet_terms_id in (select x.id from owner_fleet_lease_terms x where x.owner_id = o.id and not x.awaiting_signature and x.effective_from >= v_from);
    delete from owner_fleet_lease_terms x where x.owner_id = o.id and not x.awaiting_signature and x.effective_from >= v_from;
  end if;
  insert into owner_fleet_lease_terms (owner_id, regular_cents, troubled_cents, claim_profit_bps, early_writeoff_bps, writeoff_months, later_writeoff_bps,
                                       notice_days, effective_from, awaiting_signature, note, created_by)
  values (o.id, (p ->> 'regular_cents')::bigint, (p ->> 'troubled_cents')::bigint, (p ->> 'claim_profit_bps')::integer, (p ->> 'early_writeoff_bps')::integer,
          (p ->> 'writeoff_months')::integer, (p ->> 'later_writeoff_bps')::integer, (p ->> 'notice_days')::integer, v_from, v_signed,
          nullif(left(btrim(coalesce(p ->> 'note', '')), 500), ''), p_by)
  returning * into t;
  if v_signed then
    -- the supplier signs the new agreement (0205's pattern): the signed one ends, a new one of the set opens
    update owner_agreements set status = 'ended', ended_at = now() where id = ea.id;
    insert into owner_agreements (owner_id, kind, agreement_number, status, variant, corporate_signatory_name, corporate_signatory_title)
    values (o.id, 'enrollment', 'EA-' || nextval('owner_agreement_number_seq'), 'draft', 'fleet_lease', ea.corporate_signatory_name, ea.corporate_signatory_title)
    returning id into v_new;
    update vehicle_schedules set owner_agreement_id = v_new where owner_agreement_id = ea.id and superseded_by is null;
    return jsonb_build_object('terms', to_jsonb(t), 'resign', true, 'agreement_id', v_new);
  end if;
  return jsonb_build_object('terms', to_jsonb(t), 'resign', false, 'repriced', app.fleet_reprice(o.id, v_from, p_by));
end $$;

-- The supplier signed the new agreement: the terms waiting for it apply from their date (today at the earliest).
create or replace function app.fleet_terms_signed_trg() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  t owner_fleet_lease_terms;
  v_from date;
begin
  if new.status = 'signed' and old.status is distinct from 'signed' and new.variant = 'fleet_lease' and new.kind = 'enrollment' then
    for t in select * from owner_fleet_lease_terms where owner_id = new.owner_id and awaiting_signature order by created_at loop
      v_from := greatest(t.effective_from, app.today());
      update owner_fleet_lease_terms set effective_to = v_from where owner_id = new.owner_id and not awaiting_signature and effective_from < v_from and (effective_to is null or effective_to > v_from);
      update owner_fleet_lease_terms set awaiting_signature = false, effective_from = v_from where id = t.id;
      perform app.fleet_reprice(new.owner_id, v_from, null);
    end loop;
  end if;
  return null;
end $$;
create trigger owner_agreements_fleet_terms_signed after update of status on owner_agreements
  for each row execute function app.fleet_terms_signed_trg();

-- The tier is fixed: set once when the car joins the lease (delivered_on, tier) and never changed. Staff put a car on
-- the lease; only an Admin corrects a tier entered by mistake (fleet_lease_tier_correct, with the reason).
-- p: vehicle_id, tier, delivered_on, reason, preview.
create or replace function app.fleet_car_check(p_vehicle uuid) returns vehicles
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  o owners;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  select * into o from owners where id = v.owner_id;
  if v.supply_type <> 'program_owner' or v.is_shareholder_owned or coalesce(o.kind, 'program') <> 'program' then
    raise exception 'A fleet lease is for a supplier''s car (not a shareholder''s, a partner''s or a company car)' using errcode = '22023';
  end if;
  return v;
end $$;

create or replace function app.fleet_lease_car_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_tier text := nullif(p ->> 'tier', '');
  v_reason text := coalesce(nullif(btrim(coalesce(p ->> 'reason', '')), ''), 'Delivered');
  v_from date;
  t owner_fleet_lease_terms;
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then raise exception 'Only staff put a car on the fleet lease' using errcode = '42501'; end if;
  v := app.fleet_car_check(nullif(p ->> 'vehicle_id', '')::uuid);
  if v_tier is null or v_tier not in ('regular', 'troubled') then raise exception 'Choose the car''s tier: Regular or Troubled' using errcode = '22023'; end if;
  if app.fleet_delivered_on(v.id) is not null then
    raise exception 'This car is on the lease already and its tier is fixed. An Admin corrects a tier entered by mistake' using errcode = '23514';
  end if;
  begin v_from := coalesce(nullif(p ->> 'delivered_on', '')::date, app.today());
  exception when others then raise exception 'Give the delivery date as YYYY-MM-DD' using errcode = '22023';
  end;
  if v_from > app.today() + 60 then raise exception 'The delivery date is at most 60 days ahead' using errcode = '22023'; end if;
  t := app.fleet_terms_on(v.owner_id, v_from);
  if t.id is null then raise exception 'Enter this supplier''s lease terms first (Admin > the owner > Terms > Fleet lease)' using errcode = '23514'; end if;
  if coalesce((p ->> 'preview')::boolean, false) then
    return jsonb_build_object('done', false, 'from', v_from, 'tier', v_tier, 'monthly_cents', app.fleet_rate(t, v_tier),
      'first_payout', app.payout_date(app.fleet_first_pay_month(v_from)));
  end if;
  perform app.fleet_apply(v.id, v_tier, v_from, v_reason, p_by);
  perform app.fleet_void_fee_invoices(v.id, p_by);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'fleet_lease_car_added', 'vehicles', v.id::text, jsonb_build_object('tier', v_tier, 'delivered_on', v_from, 'monthly_cents', app.fleet_rate(t, v_tier), 'reason', v_reason));
  return jsonb_build_object('done', true, 'from', v_from, 'tier', v_tier, 'monthly_cents', app.fleet_rate(t, v_tier));
end $$;

-- Admin only: a tier entered by mistake, corrected from the delivery (or, when a statement is approved, from the day
-- after it: an approved statement never changes). p: vehicle_id, tier, reason.
create or replace function app.fleet_lease_tier_correct(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_tier text := nullif(p ->> 'tier', '');
  v_reason text := btrim(coalesce(p ->> 'reason', ''));
  v_cur text;
  v_del date;
  v_from date;
  v_lock date;
begin
  perform app.assert_admin(p_by);
  v := app.fleet_car_check(nullif(p ->> 'vehicle_id', '')::uuid);
  v_del := app.fleet_delivered_on(v.id);
  if v_del is null then raise exception 'This car is not on the fleet lease' using errcode = '23514'; end if;
  if v_tier is null or v_tier not in ('regular', 'troubled') then raise exception 'Choose the correct tier: Regular or Troubled' using errcode = '22023'; end if;
  if length(v_reason) < 5 then raise exception 'Write what was entered by mistake (kept in the audit log)' using errcode = '22023'; end if;
  v_cur := (select a.lease_tier from vehicle_owner_arrangements a where a.vehicle_id = v.id and a.kind = 'fleet_lease' and a.cancelled_at is null order by a.starts_on desc limit 1);
  if v_cur = v_tier then raise exception 'This car''s tier is % already', initcap(v_tier) using errcode = '23514'; end if;
  v_lock := app.flat_lock_through(v.owner_id);
  v_from := greatest(v_del, coalesce(v_lock + 1, v_del));
  perform app.fleet_apply(v.id, v_tier, v_from, 'Corrected: ' || v_reason, p_by);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'fleet_lease_tier_corrected', 'vehicles', v.id::text, jsonb_build_object('tier', v_cur),
          jsonb_build_object('tier', v_tier, 'from', v_from, 'reason', v_reason));
  return jsonb_build_object('done', true, 'tier', v_tier, 'from', v_from, 'kept_before', case when v_from > v_del then v_from - 1 end);
end $$;

-- ================================================================ no fees: the supplier pays the Company nothing
-- A car on a fleet lease (or an owner whose every car is) never gets an owner invoice or a debit: no Insurance,
-- management, Tracker or Install Fee, no first and last month, no one-off charge. Upkeep costs the supplier pays come
-- off the lease payments (owner deductions), never by invoice.
create or replace function app.fleet_car(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from vehicle_owner_arrangements a join vehicles v on v.id = a.vehicle_id and v.owner_id = a.owner_id
                  where a.vehicle_id = p_vehicle and a.kind = 'fleet_lease' and a.cancelled_at is null)
$$;
create or replace function app.fleet_no_fees(p_owner uuid, p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select case when p_vehicle is not null then app.fleet_car(p_vehicle) else app.owner_pay_model(p_owner) = 'fleet_lease' end
$$;

create or replace function app.owner_invoice_fleet_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.kind = 'credit_note' or new.status = 'void' then return new; end if;
  if (tg_op = 'INSERT' or (old.status = 'draft' and new.status <> 'draft')) and app.fleet_no_fees(new.owner_id, new.vehicle_id) then
    raise exception 'This car is on a fleet lease: the supplier pays CarmaCars no fees (no Insurance, management, Tracker or Install Fee, no first and last month). Record an upkeep cost instead: it comes off the lease payments'
      using errcode = '23514';
  end if;
  return new;
end $$;
create trigger owner_invoices_fleet_guard before insert or update of status, kind, vehicle_id on owner_invoices
  for each row execute function app.owner_invoice_fleet_guard();

-- the monthly run passes a fleet car by
alter function app.generate_owner_invoice(uuid, date, uuid) rename to generate_owner_invoice_pre0640;
create function app.generate_owner_invoice(p_vehicle uuid, p_month date, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
begin
  if app.fleet_car(p_vehicle) then return null; end if;
  return app.generate_owner_invoice_pre0640(p_vehicle, p_month, p_by);
end $$;
select pg_temp.copy_grants('app.generate_owner_invoice(uuid, date, uuid)'::regprocedure, 'app.generate_owner_invoice_pre0640(uuid, date, uuid)'::regprocedure);

-- and no debit is ever taken from a supplier for one
alter function app.owner_debit_block(uuid) rename to owner_debit_block_pre0640;
create function app.owner_debit_block(p_invoice uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when exists (select 1 from owner_invoices i where i.id = p_invoice and i.kind <> 'credit_note' and app.fleet_no_fees(i.owner_id, i.vehicle_id))
              then 'the car is on a fleet lease: the supplier pays no fees'
              else app.owner_debit_block_pre0640(p_invoice) end
$$;
select pg_temp.copy_grants('app.owner_debit_block(uuid)'::regprocedure, 'app.owner_debit_block_pre0640(uuid)'::regprocedure);

-- a car joining the lease: its fee invoices not paid yet (drafts, or issued with nothing paid) are voided
create or replace function app.fleet_void_fee_invoices(p_vehicle uuid, p_by uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  i owner_invoices;
  n integer := 0;
  v_reason text := 'The car is on a fleet lease: the supplier pays no fees';
begin
  -- as owner_invoice_void (0067) does: the scheduled debits cancelled, a prepaid month released, the upfront link cleared
  for i in select * from owner_invoices where vehicle_id = p_vehicle and kind <> 'credit_note' and status in ('draft', 'issued', 'failed')
              and paid_cents = 0 and deducted_cents = 0 for update loop
    update owner_debit_attempts set status = 'canceled', skip_reason = 'invoice voided: ' || v_reason where owner_invoice_id = i.id and status = 'scheduled';
    update vehicle_prepaids pp set applied_cents = pp.applied_cents + l.amount_cents
      from owner_invoice_lines l where l.owner_invoice_id = i.id and l.kind = 'prepaid_credit' and l.vehicle_prepaid_id = pp.id;
    update owner_invoices set status = 'void', void_reason = v_reason, voided_at = now(), voided_by = p_by, debit_on = null where id = i.id;
    update vehicle_onboardings set upfront_invoice_id = null where upfront_invoice_id = i.id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (p_by, 'owner_invoice_void', 'owner_invoices', i.id::text, jsonb_build_object('status', i.status), jsonb_build_object('reason', v_reason));
    n := n + 1;
  end loop;
  return n;
end $$;

-- Add a car for a fleet lease owner: the tier is required, set once with the delivery date; no fee invoice is made.
-- p.fleet: {tier, delivered_on}.
alter function app.staff_add_owner_car(uuid, jsonb) rename to staff_add_owner_car_pre0640;
create function app.staff_add_owner_car(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid := nullif(p ->> 'owner_id', '')::uuid;
  v_fleet boolean := v_owner is not null and (app.fleet_terms_current(v_owner)).id is not null;
  v_tier text := nullif(p #>> '{fleet,tier}', '');
  v_out jsonb;
begin
  if not v_fleet then return app.staff_add_owner_car_pre0640(p_by, p); end if;
  if v_tier is null or v_tier not in ('regular', 'troubled') then
    raise exception 'This owner is on a fleet lease: choose the car''s tier (Regular or Troubled). It is set once and does not change' using errcode = '22023';
  end if;
  if p ? 'plan' then p := jsonb_set(p, '{plan,invoices}', '[]'::jsonb); end if;
  v_out := app.staff_add_owner_car_pre0640(p_by, p - 'fleet');
  perform app.fleet_lease_car_set(p_by, jsonb_build_object('vehicle_id', v_out ->> 'vehicle_id', 'tier', v_tier,
    'delivered_on', coalesce(nullif(p #>> '{fleet,delivered_on}', ''), app.today()::text), 'reason', 'Onboarded'));
  return v_out;
end $$;
select pg_temp.copy_grants('app.staff_add_owner_car(uuid, jsonb)'::regprocedure, 'app.staff_add_owner_car_pre0640(uuid, jsonb)'::regprocedure);

-- Admin: who pays each upkeep cost type. p: owner_id, split: {cost_type: supplier | company}.
create or replace function app.upkeep_split_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid := nullif(p ->> 'owner_id', '')::uuid;
  e record;
begin
  perform app.assert_admin(p_by);
  if not exists (select 1 from owners where id = v_owner) then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  for e in select key, value #>> '{}' as party from jsonb_each(coalesce(p -> 'split', '{}'::jsonb)) loop
    if e.party not in ('supplier', 'company') then raise exception 'Choose the supplier or the Company for %', app.upkeep_label(e.key) using errcode = '22023'; end if;
    insert into owner_upkeep_split (owner_id, cost_type, party, set_by) values (v_owner, e.key, e.party, p_by)
    on conflict (owner_id, cost_type) do update set party = excluded.party, set_by = excluded.set_by, updated_at = now();
  end loop;
  return coalesce((select jsonb_object_agg(cost_type, party) from owner_upkeep_split where owner_id = v_owner), '{}'::jsonb);
end $$;

create or replace function app.fleet_upkeep_party(p_vehicle uuid, p_type text) returns text
language sql stable security definer set search_path = public, app as $$
  select s.party from vehicles v join owner_upkeep_split s on s.owner_id = v.owner_id and s.cost_type = p_type
   where v.id = p_vehicle and exists (select 1 from vehicle_owner_arrangements a where a.vehicle_id = v.id and a.kind = 'fleet_lease' and a.cancelled_at is null)
$$;

-- Staff: an upkeep cost on a fleet car, billed to the party the Upkeep Table names. p: vehicle_id, cost_type,
-- amount_cents, hst_cents, description, incurred_on. The supplier's: an owner deduction on its statement; the Company's: nothing to bill.
create or replace function app.fleet_upkeep_cost(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_type text := nullif(p ->> 'cost_type', '');
  v_party text;
  v_id uuid;
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then raise exception 'Only staff record upkeep costs' using errcode = '42501'; end if;
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  v_party := app.fleet_upkeep_party(v.id, v_type);
  if v_party is null then raise exception 'This car is not on a fleet lease, or the Upkeep Table has no %: set it on the owner''s Terms tab', coalesce(app.upkeep_label(v_type), 'cost type') using errcode = '23514'; end if;
  if coalesce(p ->> 'amount_cents', '') !~ '^\d{1,9}$' or (p ->> 'amount_cents')::bigint <= 0 then raise exception 'Enter the amount' using errcode = '22023'; end if;
  if v_party = 'company' then return jsonb_build_object('party', 'company', 'billed', false); end if;
  insert into owner_deductions (owner_id, vehicle_id, kind, description, amount_cents, hst_cents, incurred_on, upkeep_cost_type, created_by)
  values (v.owner_id, v.id, 'maintenance', format('%s (the supplier''s under the Upkeep Table): %s', app.upkeep_label(v_type), left(btrim(coalesce(p ->> 'description', '')), 300)),
          (p ->> 'amount_cents')::bigint, coalesce(nullif(p ->> 'hst_cents', '')::bigint, 0), coalesce(nullif(p ->> 'incurred_on', '')::date, app.today()), v_type, p_by)
  returning id into v_id;
  return jsonb_build_object('party', 'supplier', 'billed', true, 'deduction_id', v_id);
end $$;

-- r29's repair costs (vehicle_repair_costs, when that release is in): a cost type, and the supplier's types billed to it
create or replace function app.fleet_repair_cost_bill() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_party text;
  v_owner uuid;
begin
  if new.voided_at is not null or new.cost_type is null or new.claim_id is not null or new.paid_by <> 'company' then
    delete from owner_deductions where upkeep_ref = new.id and status = 'open' and owner_statement_id is null;
    update owner_deductions set status = 'waived' where upkeep_ref = new.id and status = 'open';
    return null;
  end if;
  v_party := app.fleet_upkeep_party(new.vehicle_id, new.cost_type);
  if v_party is distinct from 'supplier' then
    delete from owner_deductions where upkeep_ref = new.id and status = 'open' and owner_statement_id is null;
    return null;
  end if;
  select owner_id into v_owner from vehicles where id = new.vehicle_id;
  if exists (select 1 from owner_deductions where upkeep_ref = new.id and status <> 'waived') then
    update owner_deductions set amount_cents = new.amount_cents, hst_cents = new.tax_cents, incurred_on = new.spent_on
     where upkeep_ref = new.id and status = 'open';
  else
    insert into owner_deductions (owner_id, vehicle_id, kind, description, amount_cents, hst_cents, incurred_on, upkeep_cost_type, upkeep_ref, created_by)
    values (v_owner, new.vehicle_id, 'maintenance', format('%s (the supplier''s under the Upkeep Table): %s', app.upkeep_label(new.cost_type), left(new.description, 300)),
            new.amount_cents, new.tax_cents, new.spent_on, new.cost_type, new.id, new.updated_by);
  end if;
  return null;
end $$;
do $$
begin
  if to_regclass('public.vehicle_repair_costs') is not null then
    execute 'alter table vehicle_repair_costs add column if not exists cost_type text check (cost_type in (''engine'', ''transmission'', ''shocks'', ''rustproofing'', ''refurbishment'', ''tires'', ''brakes'', ''oil_change'', ''ball_joints''))';
    execute 'drop trigger if exists vehicle_repair_costs_fleet_bill on vehicle_repair_costs';
    execute 'create trigger vehicle_repair_costs_fleet_bill after insert or update on vehicle_repair_costs for each row execute function app.fleet_repair_cost_bill()';
  end if;
end $$;

-- the repair cost form sends the cost type (0581's repair_cost_save, wrapped): the trigger above bills the supplier's
do $$
begin
  if to_regprocedure('app.repair_cost_save(uuid, jsonb)') is not null then
    execute 'alter function app.repair_cost_save(uuid, jsonb) rename to repair_cost_save_pre0640';
    execute $f$
      create function app.repair_cost_save(p_by uuid, p jsonb) returns jsonb
      language plpgsql security definer set search_path = public, app as $b$
      declare v jsonb := app.repair_cost_save_pre0640(p_by, p - 'cost_type');
      begin
        if p ? 'cost_type' then
          update vehicle_repair_costs set cost_type = nullif(p ->> 'cost_type', '') where id = (v ->> 'id')::uuid;
          v := v || jsonb_build_object('cost_type', nullif(p ->> 'cost_type', ''));
        end if;
        return v;
      end $b$ $f$;
    perform pg_temp.copy_grants('app.repair_cost_save(uuid, jsonb)'::regprocedure, 'app.repair_cost_save_pre0640(uuid, jsonb)'::regprocedure);
    execute 'revoke all on function app.repair_cost_save_pre0640(uuid, jsonb) from public, anon, authenticated';
  end if;
end $$;

-- ================================================================ 3. claims on a fleet lease car
create or replace function app.fleet_claim_terms(p_claim uuid) returns owner_fleet_lease_terms
language plpgsql stable security definer set search_path = public, app as $$
declare
  c claims;
  i incidents;
  v_on date;
  a vehicle_owner_arrangements;
begin
  select * into c from claims where id = p_claim;
  select * into i from incidents where id = c.incident_id;
  v_on := app.local_date(coalesce(i.occurred_at, i.reported_at));
  a := app.flat_arrangement_on(c.vehicle_id, v_on);
  if a.id is null or a.kind <> 'fleet_lease' or a.owner_id <> c.owner_id then return null; end if;
  return app.fleet_terms_on(c.owner_id, v_on);
end $$;

alter function app.settle_claim(uuid, uuid, uuid) rename to settle_claim_pre0640;
create function app.settle_claim(p_claim uuid, p_admin uuid, p_second_admin uuid default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  c claims;
  t owner_fleet_lease_terms;
  v_r bigint;
  v_sup bigint;
begin
  t := app.fleet_claim_terms(p_claim);
  if t.id is null then perform app.settle_claim_pre0640(p_claim, p_admin, p_second_admin); return; end if;
  select * into c from claims where id = p_claim for update;
  if c.path not in ('at_cost', 'fleet_policy') then
    raise exception 'Claim % follows the % process, not a repair settlement', c.claim_number, c.path using errcode = '23514';
  end if;
  if c.result_cents is not null then raise exception 'Claim % is already settled', c.claim_number using errcode = '23514'; end if;
  if not exists (select 1 from user_roles where user_id = p_admin and role = 'admin') then raise exception 'Only an Admin settles a claim' using errcode = '42501'; end if;
  -- Fleet Supplier Lease Agreement 5.3: the Claim Profit Share of a profit; a shortfall is the Company's
  v_r := c.money_in_cents - c.repair_cents - c.policy_deductible_cents - c.claim_costs_cents;
  v_sup := case when v_r > 0 then public.calc_bps(v_r, t.claim_profit_bps) else 0 end;
  update claims set result_cents = v_r, owner_result_cents = v_sup, company_result_cents = v_r - v_sup, owner_share_bps = t.claim_profit_bps,
         fleet_terms_id = t.id, fleet_share_bps = t.claim_profit_bps, settled_at = now(), settled_by = p_admin, second_approved_by = p_second_admin
   where id = p_claim;
  if v_r - v_sup > 0 then
    insert into claim_ledger_entries (claim_id, kind, amount_cents, description, created_by)
    values (p_claim, 'company_surplus', v_r - v_sup, 'Balance after repair, claim costs and the supplier''s Claim Profit Share', p_admin);
  end if;
  if v_sup > 0 then
    insert into claim_ledger_entries (claim_id, kind, amount_cents, description, created_by)
    values (p_claim, 'owner_profit_share', v_sup, 'Claim Profit Share, paid on the supplier''s statement', p_admin);
    insert into owner_credits (owner_id, vehicle_id, kind, description, amount_cents, incurred_on, claim_id, created_by)
    values (c.owner_id, c.vehicle_id, 'claim_profit_share',
            format('Claim %s: Claim Profit Share %s of %s = %s', c.claim_number, trim(to_char(t.claim_profit_bps / 100.0, 'FM990.99')) || '%', app.fmt_money(v_r), app.fmt_money(v_sup)),
            v_sup, app.today(), p_claim, p_admin);
  end if;
end $$;
select pg_temp.copy_grants('app.settle_claim(uuid, uuid, uuid)'::regprocedure, 'app.settle_claim_pre0640(uuid, uuid, uuid)'::regprocedure);

alter function app.record_total_loss_settlement(uuid, bigint, date, bigint, uuid) rename to record_total_loss_settlement_pre0640;
create function app.record_total_loss_settlement(p_claim uuid, p_settlement_cents bigint, p_cleared_on date, p_lender_due_cents bigint, p_admin uuid)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  c claims;
  i incidents;
  t owner_fleet_lease_terms;
  v_lender bigint;
  v_net bigint;
  v_months integer;
  v_bps integer;
  v_sup bigint;
  v_loss date;
  v_delivered date;
begin
  t := app.fleet_claim_terms(p_claim);
  if t.id is null then perform app.record_total_loss_settlement_pre0640(p_claim, p_settlement_cents, p_cleared_on, p_lender_due_cents, p_admin); return; end if;
  select * into c from claims where id = p_claim for update;
  if c.path <> 'total_loss' then raise exception 'Claim % is not a total loss', c.claim_number using errcode = '23514'; end if;
  if not exists (select 1 from user_roles where user_id = p_admin and role = 'admin') then raise exception 'Only an Admin records a settlement' using errcode = '42501'; end if;
  if c.settled_at is not null then raise exception 'Claim % is already settled', c.claim_number using errcode = '23514'; end if;
  select * into i from incidents where id = c.incident_id;
  -- Fleet Supplier Lease Agreement 5.4: any lender first; of the balance, the Early Write-Off Share under the Write-Off
  -- Period of months in service, the Later Write-Off Share after it; the Company keeps the rest
  v_lender := least(greatest(coalesce(p_lender_due_cents, 0), 0), p_settlement_cents);
  v_net := p_settlement_cents - v_lender;
  v_delivered := coalesce(app.fleet_delivered_on(c.vehicle_id), (select enrollment_date from vehicles where id = c.vehicle_id));
  v_loss := coalesce(app.local_date(i.occurred_at), c.insurer_decision_on, p_cleared_on);
  v_delivered := coalesce(v_delivered, v_loss);
  v_months := (extract(year from age(v_loss, v_delivered)) * 12 + extract(month from age(v_loss, v_delivered)))::integer;
  v_bps := case when v_months < t.writeoff_months then t.early_writeoff_bps else t.later_writeoff_bps end;
  v_sup := public.calc_bps(v_net, v_bps);
  update claims set settlement_cents = p_settlement_cents, settlement_cleared_on = p_cleared_on, lender_due_cents = p_lender_due_cents, owner_owes_cents = 0,
         lender_paid_cents = v_lender, company_setoff_cents = 0, owner_balance_cents = v_sup,
         owner_balance_due_by = app.add_business_days(p_cleared_on, (app.settings()).total_loss_balance_business_days),
         fleet_terms_id = t.id, fleet_share_bps = v_bps, fleet_service_months = v_months, owner_share_bps = v_bps,
         settled_by = p_admin, settled_at = now()
   where id = p_claim;
  insert into claim_ledger_entries (claim_id, entry_date, kind, amount_cents, description, created_by)
  values (p_claim, p_cleared_on, 'settlement', p_settlement_cents, 'Total-loss settlement of a fleet lease car', p_admin);
  if v_sup > 0 then
    insert into owner_credits (owner_id, vehicle_id, kind, description, amount_cents, incurred_on, claim_id, created_by)
    values (c.owner_id, c.vehicle_id, 'write_off_share',
            format('Claim %s: write-off settlement %s, less %s to the lender, %s months in service: %s of %s = %s', c.claim_number, app.fmt_money(p_settlement_cents),
                   app.fmt_money(v_lender), v_months, trim(to_char(v_bps / 100.0, 'FM990.99')) || '%', app.fmt_money(v_net), app.fmt_money(v_sup)),
            v_sup, p_cleared_on, p_claim, p_admin);
  end if;
end $$;
select pg_temp.copy_grants('app.record_total_loss_settlement(uuid, bigint, date, bigint, uuid)'::regprocedure, 'app.record_total_loss_settlement_pre0640(uuid, bigint, date, bigint, uuid)'::regprocedure);

-- ================================================================ 4. the facts the owner documents are built from
alter function app.owner_agreement_facts(uuid, uuid) rename to owner_agreement_facts_pre0640;
create function app.owner_agreement_facts(p_owner uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  f jsonb := app.owner_agreement_facts_pre0640(p_owner, p_by);
  t owner_fleet_lease_terms := app.fleet_terms_current(p_owner);
begin
  if f is null then return f; end if;
  return f || jsonb_build_object(
    'fleet_lease', case when t.id is not null then jsonb_build_object('regular_cents', t.regular_cents, 'troubled_cents', t.troubled_cents,
        'claim_profit_bps', t.claim_profit_bps, 'early_writeoff_bps', t.early_writeoff_bps, 'writeoff_months', t.writeoff_months,
        'later_writeoff_bps', t.later_writeoff_bps, 'notice_days', t.notice_days, 'effective_from', t.effective_from, 'awaiting_signature', t.awaiting_signature,
        'upkeep', coalesce((select jsonb_agg(jsonb_build_object('cost_type', s.cost_type, 'label', app.upkeep_label(s.cost_type), 'party', s.party) order by s.party desc, s.cost_type)
                            from owner_upkeep_split s where s.owner_id = p_owner), '[]'::jsonb)) end,
    'fleet_review', (app.settings()).fleet_lease_agreements_awaiting_lawyer,
    'schedules', coalesce((select jsonb_agg(x || jsonb_build_object(
        'lease_tier', fa.lease_tier, 'delivered_on', app.fleet_delivered_on((x ->> 'vehicle_id')::uuid),
        'monthly_cents', coalesce(to_jsonb(fa.monthly_cents), x -> 'monthly_cents'),
        'shareholder', coalesce(v.is_shareholder_owned, false),
        'shareholder_share_bps', case when v.is_shareholder_owned then (app.settings()).shareholder_company_share_bps end,
        'first_last_cents', vs.first_last_cents, 'one_off_fees', coalesce(vs.one_off_fees, '[]'::jsonb),
        'onboarding_by_payout', exists (select 1 from owner_invoices i where i.vehicle_id = v.id and i.kind = 'upfront' and i.collect_by = 'payout' and i.status <> 'void'))
        order by o.n)
      from jsonb_array_elements(f -> 'schedules') with ordinality o(x, n)
      left join vehicles v on v.id = (x ->> 'vehicle_id')::uuid
      left join vehicle_schedules vs on vs.id::text = x ->> 'id'
      left join lateral (select a.* from vehicle_owner_arrangements a where a.vehicle_id = v.id and a.kind = 'fleet_lease' and a.cancelled_at is null
                           and (a.ends_on is null or a.ends_on >= app.today()) order by (a.starts_on <= app.today()) desc, a.starts_on desc limit 1) fa on true), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.owner_agreement_facts(uuid, uuid)'::regprocedure, 'app.owner_agreement_facts_pre0640(uuid, uuid)'::regprocedure);

-- Admin: the fleet lease of a supplier (terms, history, cars by tier, the upkeep table)
create or replace function app.fleet_lease_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_owner uuid := nullif(p ->> 'owner', '')::uuid;
  t owner_fleet_lease_terms;
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then raise exception 'Only staff see the fleet lease' using errcode = '42501'; end if;
  t := app.fleet_terms_current(v_owner);
  return jsonb_build_object(
    'pay_model', app.owner_pay_model(v_owner),
    'terms', to_jsonb(t) - 'created_by',
    'history', coalesce((select jsonb_agg(to_jsonb(x) - 'created_by' order by x.created_at desc) from owner_fleet_lease_terms x where x.owner_id = v_owner), '[]'::jsonb),
    'upkeep', coalesce((select jsonb_agg(jsonb_build_object('cost_type', ct, 'label', app.upkeep_label(ct), 'party', s.party) order by n)
        from unnest(array['engine', 'transmission', 'shocks', 'rustproofing', 'refurbishment', 'tires', 'brakes', 'oil_change', 'ball_joints']) with ordinality u(ct, n)
        left join owner_upkeep_split s on s.owner_id = v_owner and s.cost_type = u.ct), '[]'::jsonb),
    'cars', coalesce((select jsonb_agg(jsonb_build_object('vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate,
        'delivered_on', app.fleet_delivered_on(v.id),
        'first_payout', app.payout_date(app.fleet_first_pay_month(app.fleet_delivered_on(v.id))),
        'tier', (app.flat_arrangement_on(v.id, app.today())).lease_tier,
        'monthly_cents', (app.flat_arrangement_on(v.id, app.today())).monthly_cents,
        'periods', coalesce((select jsonb_agg(jsonb_build_object('kind', a.kind, 'tier', a.lease_tier, 'monthly_cents', a.monthly_cents, 'starts_on', a.starts_on, 'ends_on', a.ends_on, 'reason', a.reason) order by a.starts_on)
                             from vehicle_owner_arrangements a where a.vehicle_id = v.id and a.cancelled_at is null), '[]'::jsonb)) order by v.fleet_number nulls last, v.created_at)
      from vehicles v where v.owner_id = v_owner and v.retired_at is null and coalesce(v.supply_type::text, 'program_owner') = 'program_owner'), '[]'::jsonb),
    'awaiting_lawyer', (app.settings()).fleet_lease_agreements_awaiting_lawyer);
end $$;

-- ================================================================ 5. the Referral Override Agreement
create or replace function app.referral_agreement_facts(p_link uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('owner_id', l.referrer_owner_id, 'link_id', l.id,
    'referrer', jsonb_build_object('legal_name', coalesce(ro.corporation_name, ro.legal_name), 'owner_type', ro.owner_type,
        'signer_name', case when ro.owner_type = 'corporation' then coalesce(ro.signing_officer_name, ro.legal_name) else ro.legal_name end,
        'signer_title', ro.signing_officer_title, 'email', ro.email, 'hst_number', ro.hst_number,
        'address', concat_ws(', ', nullif(ro.address_line1, ''), nullif(ro.city, ''), nullif(ro.province, ''), nullif(ro.postal_code, ''))),
    'referred', jsonb_build_object('legal_name', coalesce(fo.corporation_name, fo.legal_name)),
    'share_bps', l.share_bps, 'sees_cars', l.sees_cars, 'effective_from', l.effective_from, 'agreement_status', l.agreement_status,
    'payout_day', (select extract(day from app.payout_date(app.month_start(app.today())))::integer),
    'company', app.doc_company_brand())
    from owner_referral_links l join owners ro on ro.id = l.referrer_owner_id join owners fo on fo.id = l.referred_owner_id
   where l.id = p_link
$$;

-- the referrer's own links (the portal): the facts of one, or every open one to sign
create or replace function public.server_referral_agreement_facts(p_by uuid, p_link uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.referral_agreement_facts(l.id) from owner_referral_links l
   where l.id = p_link and l.referrer_owner_id = app.portal_owner_or_null(p_by) and l.share_bps > 0 and l.effective_to is null
$$;
create or replace function public.server_referral_agreements(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('link_id', l.id, 'referred', coalesce(fo.corporation_name, fo.legal_name), 'status', l.agreement_status,
           'signed_at', l.agreement_signed_at, 'document_id', l.agreement_document_id) order by l.created_at), '[]'::jsonb)
    from owner_referral_links l join owners fo on fo.id = l.referred_owner_id
   where l.referrer_owner_id = app.portal_owner_or_null(p_by) and l.share_bps > 0 and l.effective_to is null
$$;

create or replace function app.referral_agreement_open(p_by uuid, p_link uuid, p_sha256 text, p_path text, p_template_version text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid := app.portal_owner_id(p_by);
  l owner_referral_links;
  f jsonb;
  r sign_requests;
  v_doc uuid;
  v_req uuid;
begin
  select * into l from owner_referral_links where id = p_link for update;
  if l.id is null or l.referrer_owner_id is distinct from v_owner or l.effective_to is not null then
    raise exception 'Only the referrer signs this Referral Override Agreement' using errcode = '42501';
  end if;
  if l.agreement_status = 'signed' then raise exception 'This Referral Override Agreement is already signed' using errcode = '23514'; end if;
  if lower(coalesce(p_sha256, '')) !~ '^[0-9a-f]{64}$' or coalesce(p_path, '') !~ ('^owners/' || v_owner || '/') then
    raise exception 'The agreement document is missing' using errcode = '22023';
  end if;
  f := app.referral_agreement_facts(l.id);
  select * into r from sign_requests where referral_link_id = l.id and doc_type = 'referral_agreement' and status = 'sent' for update;
  if r.id is not null and r.document_sha256 = lower(p_sha256) then return to_jsonb(r); end if;
  if r.id is not null then
    update sign_requests set status = 'voided', voided_at = now(), voided_by = p_by, void_reason = 'The agreement was made again' where id = r.id;
    update signature_requests set status = 'voided' where id = r.signature_request_id;
  end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version, owner_id, uploaded_by)
  values ('other'::document_kind, 'Referral Override Agreement', 'agreements', p_path, 'application/pdf', lower(p_sha256), p_template_version, v_owner, p_by)
  returning id into v_doc;
  insert into signature_requests (document_id, provider, status, sent_at, created_by) values (v_doc, 'builtin', 'sent', now(), p_by) returning id into v_req;
  insert into sign_requests (doc_type, owner_id, referral_link_id, signer_user_id, signer_name, signer_email, signer_role, title, document_id, document_sha256,
                             template_version, signature_request_id, sent_by)
  values ('referral_agreement', v_owner, l.id, p_by, f #>> '{referrer,signer_name}', f #>> '{referrer,email}',
          case when f #>> '{referrer,owner_type}' = 'corporation' then 'owner_corporation' else 'owner_individual' end,
          'Referral Override Agreement, ' || (f #>> '{referred,legal_name}'), v_doc, lower(p_sha256), p_template_version, v_req, p_by)
  returning * into r;
  update owner_referral_links set agreement_status = 'sent' where id = l.id and agreement_status = 'not_sent';
  return to_jsonb(r);
end $$;
create or replace function public.referral_agreement_open(p_by uuid, p_link uuid, p_sha256 text, p_path text, p_template_version text) returns jsonb
language sql set search_path = public, app as $$ select app.referral_agreement_open(p_by, p_link, p_sha256, p_path, p_template_version) $$;

-- the key terms the referrer initials (web/src/features/signing/terms.ts)
create or replace function app.esign_doc_initials(p_kind text, p_ref text, p_doc_type text default null, p_generated boolean default false) returns text[]
language sql immutable as $$
  select case
    when p_kind = 'packet' and p_ref = 'enrollment' then array['own_insurance', 'fees_no_income', 'tracker_downtime']
    when p_kind = 'schedule_change' then array['schedule_terms']
    when p_kind = 'request' and p_doc_type = 'form_c' then array['read_warning', 'no_advice', 'bears_consequences']
    when p_kind = 'request' and p_doc_type = 'investment_agreement' then array['schedule_c']
    when p_kind = 'request' and p_doc_type = 'staff_agreement' and p_generated then array['staff_confidentiality', 'staff_rules', 'staff_ending']
    when p_kind = 'request' and p_doc_type = 'partner_agreement' then array['partner_money', 'partner_insurance', 'partner_ending']
    when p_kind = 'request' and p_doc_type = 'referral_agreement' then array['referral_override', 'referral_confidential', 'referral_ending']
    else '{}'::text[] end
$$;

-- signed: the Company countersigns at once (as the partner agreement), the link records it
alter function app.sign_request_sign(uuid, uuid, jsonb) rename to sign_request_sign_pre0640;
create function app.sign_request_sign(p_user uuid, p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.sign_request_sign_pre0640(p_user, p_id, p);
  r sign_requests;
begin
  select * into r from sign_requests where id = p_id;
  if r.doc_type = 'referral_agreement' then
    insert into signature_records (signature_request_id, signer_role, signer_name, signer_title, signer_email, status, signed_at, method,
                                   typed_name, consent_text, document_sha256)
    select r.signature_request_id, 'carmacars', coalesce(ps.signing_officer_name, ps.company_legal_name, ps.company_trade_name),
           coalesce(ps.signing_officer_title, 'for ' || coalesce(ps.company_legal_name, ps.company_trade_name)),
           ps.company_email, 'signed', now(), 'automatic', coalesce(ps.signing_officer_name, ps.company_legal_name, ps.company_trade_name),
           format('Countersigned for %s automatically when the referrer signed.', coalesce(ps.company_legal_name, ps.company_trade_name)), r.document_sha256
      from (select (app.settings()).*) ps;
    update owner_referral_links set agreement_status = 'signed', agreement_signed_at = r.signed_at, agreement_method = r.method, agreement_document_id = r.document_id
     where id = r.referral_link_id;
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.sign_request_sign(uuid, uuid, jsonb)'::regprocedure, 'app.sign_request_sign_pre0640(uuid, uuid, jsonb)'::regprocedure);

alter function app.sign_request_attach(uuid, text, text) rename to sign_request_attach_pre0640;
create function app.sign_request_attach(p_id uuid, p_path text, p_sha256 text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_doc uuid := app.sign_request_attach_pre0640(p_id, p_path, p_sha256);
  r sign_requests;
begin
  select * into r from sign_requests where id = p_id;
  if r.doc_type = 'referral_agreement' then update owner_referral_links set agreement_document_id = v_doc where id = r.referral_link_id; end if;
  return v_doc;
end $$;
select pg_temp.copy_grants('app.sign_request_attach(uuid, text, text)'::regprocedure, 'app.sign_request_attach_pre0640(uuid, text, text)'::regprocedure);

-- ================================================================ 6. Admin > Owners > Agreements
-- Each owner's required agreements: the program set of its pay model (with the Title-Holding and Lease Agreement when
-- a car is not Turo-Only, and an Additional Vehicle Schedule for a car added after signing), the partner agreement of a
-- partner, a Referral Override Agreement for each referral link it is paid on. Status: signed, sent (opened for
-- signature or emailed with Send), not sent, or missing (nothing to sign yet: the terms are not set).
create or replace function app.owner_agreements_checklist(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_owner uuid := nullif(p ->> 'owner', '')::uuid;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin sees the agreements checklist' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(row order by row ->> 'name') from (
    select jsonb_build_object('owner_id', o.id, 'name', coalesce(o.corporation_name, o.legal_name), 'email', o.email, 'has_login', o.user_id is not null,
      'pay_model', app.owner_pay_model(o.id),
      'last_sent_at', (select max(s.sent_at) from owner_agreement_sends s where s.owner_id = o.id),
      'items', (
        select coalesce(jsonb_agg(i order by i ->> 'order'), '[]'::jsonb) from (
          -- the program agreements
          select jsonb_build_object('order', '1', 'doc', 'packet', 'kind', a.kind,
                   'title', case when a.kind = 'title_holding' then 'Title-Holding and Lease Agreement'
                                 when a.variant = 'fleet_lease' then 'Fleet Supplier Lease Agreement'
                                 when a.variant = 'flat_rate' then 'Flat-Rate Vehicle Enrollment Agreement' else 'Vehicle Enrollment Agreement' end,
                   'number', a.agreement_number,
                   'status', case when a.status = 'signed' then 'signed'
                                  when a.status = 'sent' or exists (select 1 from owner_agreement_sends s where s.owner_id = o.id and s.doc_key = 'packet' and s.sent_at >= a.created_at) then 'sent'
                                  else 'not_sent' end,
                   'signed_at', (select max(vs.signed_at) from vehicle_schedules vs where vs.owner_agreement_id = a.id or vs.title_agreement_id = a.id),
                   'awaiting_lawyer', a.variant = 'fleet_lease' and (app.settings()).fleet_lease_agreements_awaiting_lawyer) as i
            from owner_agreements a
           where a.owner_id = o.id and a.status in ('draft', 'sent', 'signed')
             and (a.kind = 'enrollment' or exists (select 1 from vehicles v where v.owner_id = o.id and v.management_mode <> 'turo_only' and v.retired_at is null))
          union all
          -- cars added after the agreement was signed: their Additional Vehicle Schedule
          select jsonb_build_object('order', '2', 'doc', 'packet', 'kind', 'additional', 'title', 'Additional Vehicle Schedule',
                   'number', string_agg(vs.schedule_number, ', '), 'status',
                   case when exists (select 1 from owner_agreement_sends s where s.owner_id = o.id and s.doc_key = 'packet' and s.sent_at >= min(vs.created_at)) or bool_or(vs.signature_request_id is not null) then 'sent' else 'not_sent' end,
                   'awaiting_lawyer', false)
            from vehicle_schedules vs join owner_agreements a on a.id = vs.owner_agreement_id and a.status = 'signed'
           where a.owner_id = o.id and vs.is_additional and vs.signed_at is null and vs.superseded_by is null and vs.withdrawn_at is null
          having count(*) > 0
          union all
          -- an owner with cars and no agreement yet: missing until the terms are set
          select jsonb_build_object('order', '1', 'doc', 'packet', 'kind', 'enrollment', 'title',
                   case app.owner_pay_model(o.id) when 'fleet_lease' then 'Fleet Supplier Lease Agreement' when 'flat_rate' then 'Flat-Rate Vehicle Enrollment Agreement' else 'Vehicle Enrollment Agreement' end,
                   'status', 'missing', 'why', 'Set the terms of a car first: the agreement is made from them', 'awaiting_lawyer', false)
           where not exists (select 1 from owner_agreements a where a.owner_id = o.id and a.kind = 'enrollment' and a.status in ('draft', 'sent', 'signed'))
             and exists (select 1 from vehicles v where v.owner_id = o.id and v.retired_at is null and coalesce(v.supply_type::text, 'program_owner') = 'program_owner')
          union all
          select jsonb_build_object('order', '3', 'doc', 'partner', 'title', 'Partner agreement', 'number', r.partner_number,
                   'status', case r.agreement_status when 'signed' then 'signed' when 'sent' then 'sent'
                                  else case when exists (select 1 from owner_agreement_sends s where s.owner_id = o.id and s.doc_key = 'partner') then 'sent' else 'not_sent' end end,
                   'signed_at', r.agreement_signed_at, 'awaiting_lawyer', false)
            from partners r where r.owner_id = o.id
          union all
          select jsonb_build_object('order', '4', 'doc', 'referral', 'link_id', l.id, 'title', 'Referral Override Agreement',
                   'number', coalesce(fo.corporation_name, fo.legal_name),
                   'status', case l.agreement_status when 'signed' then 'signed' when 'sent' then 'sent'
                                  else case when exists (select 1 from owner_agreement_sends s where s.referral_link_id = l.id) then 'sent' else 'not_sent' end end,
                   'signed_at', l.agreement_signed_at, 'awaiting_lawyer', (app.settings()).referral_agreements_awaiting_lawyer)
            from owner_referral_links l join owners fo on fo.id = l.referred_owner_id
           where l.referrer_owner_id = o.id and l.share_bps > 0 and l.effective_to is null) x(i))
    ) as row
    from owners o
   where (v_owner is null or o.id = v_owner) and not coalesce(o.is_test, false) and o.status not in ('declined')
     and (exists (select 1 from vehicles v where v.owner_id = o.id and v.retired_at is null)
          or exists (select 1 from owner_referral_links l where l.referrer_owner_id = o.id and l.effective_to is null)
          or exists (select 1 from partners r where r.owner_id = o.id))) z), '[]'::jsonb);
end $$;

-- Send: the email with the link to sign. p: owner, doc (packet | partner | referral), link (a referral).
create or replace function app.owner_agreement_send(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  v_doc text := coalesce(nullif(p ->> 'doc', ''), 'packet');
  v_link uuid := nullif(p ->> 'link', '')::uuid;
  v_title text;
  v_note text;
  v_path text;
  v_out uuid;
  v_base text := rtrim(coalesce((app.settings()).notify_base_url, 'https://carmacars.ca'), '/');
  v_model text;
begin
  perform app.assert_admin(p_by);
  select * into o from owners where id = nullif(p ->> 'owner', '')::uuid;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  if nullif(btrim(coalesce(o.email, '')), '') is null then raise exception 'This owner has no email: add one on the owner''s page' using errcode = '23514'; end if;
  if o.user_id is null then raise exception 'This owner has no sign-in yet: press Invite on the Owners list first (the invitation leads to the same place)' using errcode = '23514'; end if;
  if v_doc = 'packet' then
    if not exists (select 1 from owner_agreements a where a.owner_id = o.id and a.status in ('draft', 'sent'))
       and not exists (select 1 from vehicle_schedules vs join owner_agreements a on a.id = vs.owner_agreement_id
                        where a.owner_id = o.id and vs.signed_at is null and vs.superseded_by is null and vs.withdrawn_at is null) then
      raise exception 'Nothing to sign: the agreements are signed, or the terms are not set yet' using errcode = '23514';
    end if;
    v_model := app.owner_pay_model(o.id);
    v_title := case when exists (select 1 from owner_agreements a where a.owner_id = o.id and a.kind = 'enrollment' and a.status in ('draft', 'sent'))
                    then case v_model when 'fleet_lease' then 'Fleet Supplier Lease Agreement' when 'flat_rate' then 'Flat-Rate Vehicle Enrollment Agreement' else 'Vehicle Enrollment Agreement' end
                    else 'Additional Vehicle Schedule' end;
    v_note := 'It is filled in from your cars and the terms we agreed, with the Title-Holding and Lease Agreement where your cars need it. You sign every document at once.';
    v_path := '/owner/sign';
  elsif v_doc = 'partner' then
    if not exists (select 1 from partners r where r.owner_id = o.id and r.agreement_status <> 'signed') then raise exception 'Nothing to sign: the partner agreement is signed' using errcode = '23514'; end if;
    v_title := 'Partner agreement'; v_note := 'It lists your cars and how you are paid.'; v_path := '/owner/partner-agreement';
  elsif v_doc = 'referral' then
    if not exists (select 1 from owner_referral_links l where l.id = v_link and l.referrer_owner_id = o.id and l.agreement_status <> 'signed' and l.effective_to is null) then
      raise exception 'Nothing to sign: that Referral Override Agreement is signed or the link has ended' using errcode = '23514';
    end if;
    v_title := 'Referral Override Agreement'; v_note := 'It sets out the override we pay you on the cars of the owner you referred, and what you can see of them.';
    v_path := '/owner/referral-agreement/' || v_link;
  else
    raise exception 'Choose the agreement to send' using errcode = '22023';
  end if;
  insert into notification_outbox (code, category, priority, audience, to_address, to_name, owner_id, entity, entity_id, payload, missing_variables, dedupe_key, status, send_after)
  values ('owner_agreement_to_sign', 'transactional', 2, 'owner', o.email, coalesce(o.corporation_name, o.legal_name), o.id, 'owner', o.id,
          jsonb_build_object('first_name', coalesce(nullif(o.first_name, ''), split_part(coalesce(o.signing_officer_name, o.legal_name), ' ', 1)),
                             'agreement_title', v_title, 'note', v_note, 'sign_url', v_base || v_path),
          '{}'::text[], 'owner_agreement_to_sign:' || o.id || ':' || v_doc || ':' || coalesce(v_link::text, '-') || ':' || extract(epoch from clock_timestamp())::bigint, 'queued', now())
  returning id into v_out;
  insert into owner_agreement_sends (owner_id, doc_key, referral_link_id, to_address, outbox_id, sent_by) values (o.id, v_doc, v_link, o.email, v_out, p_by);
  return jsonb_build_object('sent', true, 'to', o.email, 'title', v_title);
end $$;

-- ================================================================ 7. the door, privileges
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0640;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call = 'ops_read' and p_name in ('fleet_lease', 'owner_agreements_checklist'))
     or (p_call in ('ops_do', 'admin_do') and p_name in ('fleet_lease_terms_save', 'fleet_lease_car_set', 'fleet_lease_tier_correct', 'upkeep_split_save', 'fleet_upkeep_cost', 'owner_agreement_send')) then
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name
      when 'fleet_lease' then app.fleet_lease_read(p_user, p)
      when 'owner_agreements_checklist' then app.owner_agreements_checklist(p_user, p)
      when 'fleet_lease_terms_save' then app.fleet_lease_terms_save(p_user, p)
      when 'fleet_lease_car_set' then app.fleet_lease_car_set(p_user, p)
      when 'fleet_lease_tier_correct' then app.fleet_lease_tier_correct(p_user, p)
      when 'upkeep_split_save' then app.upkeep_split_save(p_user, p)
      when 'fleet_upkeep_cost' then app.fleet_upkeep_cost(p_user, p)
      else app.owner_agreement_send(p_user, p) end;
  end if;
  return app.door_pre0640(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0640(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['upkeep_label', 'fleet_terms_on', 'fleet_terms_current', 'fleet_rate', 'fleet_delivered_on', 'fleet_first_pay_month',
             'flat_credits_sync_pre0640', 'fleet_apply', 'fleet_reprice', 'fleet_lease_terms_save', 'fleet_terms_signed_trg', 'fleet_lease_car_set', 'upkeep_split_save', 'fleet_car_check', 'fleet_lease_tier_correct', 'fleet_car', 'fleet_no_fees',
             'owner_invoice_fleet_guard', 'generate_owner_invoice_pre0640', 'owner_debit_block_pre0640', 'fleet_void_fee_invoices', 'staff_add_owner_car_pre0640',
             'fleet_upkeep_party', 'fleet_upkeep_cost', 'fleet_repair_cost_bill', 'fleet_claim_terms', 'settle_claim_pre0640', 'record_total_loss_settlement_pre0640',
             'owner_agreement_facts_pre0640', 'fleet_lease_read', 'referral_agreement_facts', 'referral_agreement_open', 'sign_request_sign_pre0640',
             'sign_request_attach_pre0640', 'owner_agreements_checklist', 'owner_agreement_send', 'door_pre0640'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
revoke all on function public.server_referral_agreement_facts(uuid, uuid), public.server_referral_agreements(uuid), public.referral_agreement_open(uuid, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.server_referral_agreement_facts(uuid, uuid), public.server_referral_agreements(uuid), public.referral_agreement_open(uuid, uuid, text, text, text) to service_role;

-- CATALOGUE 0640 START (generated by supabase/seed/0640_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('owner_agreement_to_sign', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Please sign your {{agreement_title}}', 'It is ready in your owner portal. One signature, on screen.', 'When an Admin presses Send', 'An Admin presses Send on an owner''s line of the Agreements checklist (Admin > Owners > Agreements, migration 0640): the agreement that owner''s deal needs (the Vehicle Enrollment Agreement, the Flat-Rate or Fleet Supplier Lease Agreement with the Title-Holding and Lease Agreement, an Additional Vehicle Schedule, the Partner agreement or a Referral Override Agreement) is ready to read and sign in the owner portal. Sent again each time Send is pressed.', null, null, '[{"name":"agreement_title","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"note","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"sign_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_agreement_to_sign.html', 'templates/owner_agreement_to_sign.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0640 END
update notification_catalogue set emitted_by = 'app.owner_agreement_send (0640)' where code = 'owner_agreement_to_sign';

-- its short text (0096): the owner chose texts
insert into sms_templates (code, label, body, urgent, sort_order) values
  ('owner_agreement_to_sign', 'Owner agreement to sign', 'CarmaCars: your {{agreement_title}} is ready to sign in your owner portal: {{link}}', false, 100)
on conflict (code) do nothing;
