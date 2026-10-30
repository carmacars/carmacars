-- 0196_flat_monthly_owner_pay.sql: a flat monthly payment per car for the owner. SCHEMA_MARKER 0196.
-- Record: docs/changes/2026-10-30-flat-monthly-owner-pay.md. The owner, October 30, 2026: "Some cohosts don't care for
-- monthly splits or paying us for insurance; they just want a monthly payment per car. We need a way to reflect that."
--
-- 1. vehicle_owner_arrangements: per car, a flat monthly payment (the amount a month, from a date, to an optional last
--    day), kept as history: a change ends the period in force the day before and starts a new one; a period that has
--    not started is cancelled, never deleted. No period on a day: the car's revenue share terms apply, as before.
--    Set by an Admin from the car's owner terms (app.car_pay_set). A change never reaches a month whose owner statement
--    is approved or paid, so an approved statement never changes.
-- 2. The rentals: a booking part that counts on a day of a flat period (its counts_on, the day it ends) stays with
--    CarmaCars: the split's company share is 100% (company_share_bps 10000, owner payout 0), so the company accounts
--    and reports keep the whole rental, and a later refund or extra charge on it never reaches the owner. A Turo trip
--    ending on such a day likewise (its terms' share kept in turo_trips.terms_share_bps, put back if the period goes).
-- 3. Booking expenses on such a booking are not passed to the owner, unless an Admin marks the expense "charge to
--    owner": it then becomes an owner cost (owner_deductions kind booking_expense) on the statement of that booking.
--    The owner costs CarmaCars records on the owner's account (tickets, tolls, damage shortfalls of the owner's own use,
--    agreed costs) stay as they are: they are the owner's own costs, whatever the pay arrangement.
-- 4. The payment: each month of a period is an owner credit (kind flat_monthly) on the statement of that month, a
--    "Flat monthly payment" line, part months by the day (the days of the period inside the month, within the car's
--    Enrollment Date and Exit Date). Worked out again on each build of a draft; settled with the statement like any
--    credit. The rental lines of the car show the booking with no Owner Revenue and no Revenue Share.
-- 5. Fees: no Insurance Fee or Tracker Fee for the days of a flat period (a month all flat has no monthly invoice; a
--    part month is billed for the other days only).
-- 6. Reads: the car's terms (Admin and owner portal) carry "pay"; the booking's owner deductions carry the flat period
--    and "charge to owner"; the owner's booking rows list only the expenses charged to them on a flat car.
-- 7. The door, privileges, the guides.
-- No earlier migration is edited. Functions it changes are wrapped (renamed _pre0196) or replaced with the same signature.
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
create table vehicle_owner_arrangements (
  id              uuid primary key default gen_random_uuid(),
  vehicle_id      uuid not null references vehicles (id),
  owner_id        uuid not null references owners (id),
  kind            text not null default 'flat_monthly' check (kind in ('flat_monthly')),
  monthly_cents   bigint not null check (monthly_cents > 0),
  starts_on       date not null,
  ends_on         date,
  reason          text,
  created_by      uuid references users (id),
  created_at      timestamptz not null default now(),
  ended_by        uuid references users (id),
  ended_at        timestamptz,
  ended_reason    text,
  cancelled_by    uuid references users (id),
  cancelled_at    timestamptz,
  cancelled_reason text,
  check (ends_on is null or ends_on >= starts_on)
);
create index vehicle_owner_arrangements_vehicle_idx on vehicle_owner_arrangements (vehicle_id, starts_on);
create index vehicle_owner_arrangements_owner_idx on vehicle_owner_arrangements (owner_id);
comment on table vehicle_owner_arrangements is 'How the owner of a car is paid, by period (0196): a flat monthly payment (monthly_cents, from starts_on to ends_on, both counted). No period on a day: the revenue share terms. Ended or cancelled, never deleted.';
alter table vehicle_owner_arrangements enable row level security;
revoke all on vehicle_owner_arrangements from anon, authenticated;
grant select, insert, update on vehicle_owner_arrangements to service_role;
create policy admin_all on vehicle_owner_arrangements for select to authenticated using (app.is_admin());
create trigger audit_vehicle_owner_arrangements after insert or update or delete on vehicle_owner_arrangements for each row execute function app.audit_row();

-- one period at a time per car
create or replace function app.voa_no_overlap() returns trigger
language plpgsql as $$
begin
  if new.cancelled_at is null and exists (
       select 1 from vehicle_owner_arrangements x
        where x.vehicle_id = new.vehicle_id and x.id <> new.id and x.cancelled_at is null
          and x.starts_on <= coalesce(new.ends_on, 'infinity'::date) and coalesce(x.ends_on, 'infinity'::date) >= new.starts_on) then
    raise exception 'This car already has a flat monthly payment for some of those days' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger vehicle_owner_arrangements_no_overlap before insert or update on vehicle_owner_arrangements
  for each row execute function app.voa_no_overlap();

alter table booking_splits add column if not exists flat_arrangement_id uuid references vehicle_owner_arrangements (id);
comment on column booking_splits.flat_arrangement_id is 'The flat monthly payment period this part counts in (0196): CarmaCars keeps the whole rental (company share 100%).';
alter table turo_trips add column if not exists flat_arrangement_id uuid references vehicle_owner_arrangements (id),
  add column if not exists terms_share_bps integer;
comment on column turo_trips.terms_share_bps is 'The revenue share of the terms, kept while the trip counts in a flat monthly payment period (0196) and put back if it no longer does';

alter table owner_credits add column if not exists flat_arrangement_id uuid references vehicle_owner_arrangements (id),
  add column if not exists flat_month date;
alter table owner_credits drop constraint if exists owner_credits_kind_check;
alter table owner_credits add constraint owner_credits_kind_check check (kind in ('later_rental_revenue', 'correction', 'staff_commission_adjustment', 'flat_monthly'));
alter table owner_credits drop constraint if exists owner_credits_flat_check;
alter table owner_credits add constraint owner_credits_flat_check check (kind <> 'flat_monthly' or (flat_arrangement_id is not null and flat_month is not null));
create unique index owner_credits_flat_once on owner_credits (flat_arrangement_id, flat_month) where kind = 'flat_monthly' and status <> 'waived';
comment on column owner_credits.flat_month is 'A flat monthly payment (0196): the month it pays (first day)';

alter table booking_owner_expenses add column if not exists charge_to_owner boolean not null default false,
  add column if not exists charge_set_by uuid references users (id),
  add column if not exists charge_set_at timestamptz;
comment on column booking_owner_expenses.charge_to_owner is 'On a car paid a flat monthly payment (0196): an Admin charges this expense to the owner (an owner cost on the statement). Otherwise CarmaCars bears it.';
alter table owner_deductions add column if not exists booking_owner_expense_id uuid references booking_owner_expenses (id);
alter table owner_deductions drop constraint if exists owner_deductions_kind_check;
alter table owner_deductions add constraint owner_deductions_kind_check check (kind in ('plate_renewal', 'owner_booking_toll', 'owner_booking_ticket',
  'lender_handover_cost', 'claim_shortfall', 'owner_booking_deductible', 'retransfer_fee', 'refund_share', 'chargeback_share', 'kickback_reversal',
  'agreed_in_writing', 'staff_commission_adjustment', 'maintenance', 'booking_expense'));

alter table owner_statement_lines drop constraint if exists owner_statement_lines_line_type_check;
alter table owner_statement_lines add constraint owner_statement_lines_line_type_check check (line_type in (
  'rental', 'turo_trip', 'withheld', 'fees_deducted', 'owner_cost', 'refund_or_chargeback',
  'arrears_moved', 'kickback_earned', 'hst_on_payout', 'balance_brought_forward', 'later_revenue', 'flat_payment'));
alter table owner_statement_lines add column if not exists flat_arrangement_id uuid references vehicle_owner_arrangements (id);
alter table owner_statement_vehicles add column if not exists flat_payment_cents bigint not null default 0;
alter table owner_statements add column if not exists flat_payment_cents bigint not null default 0;
comment on column owner_statement_vehicles.flat_payment_cents is 'The flat monthly payment of the car on this statement (0196), part of credits_cents';

-- ================================================================ 2. helpers
create or replace function app.flat_arrangement_on(p_vehicle uuid, p_on date) returns vehicle_owner_arrangements
language sql stable security definer set search_path = public, app as $$
  select * from vehicle_owner_arrangements a
   where a.vehicle_id = p_vehicle and a.cancelled_at is null and a.starts_on <= p_on and (a.ends_on is null or a.ends_on >= p_on)
   order by a.starts_on desc limit 1
$$;

create or replace function app.flat_day(p_on date) returns text
language sql immutable as $$ select to_char(p_on, 'Mon FMDD, YYYY') $$;

-- The days of a period between two dates, within the car's Enrollment Date and Exit Date.
create or replace function app.flat_window(a vehicle_owner_arrangements, p_from date, p_to date, out d_from date, out d_to date, out days integer)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
begin
  select * into v from vehicles where id = a.vehicle_id;
  d_from := greatest(a.starts_on, p_from, coalesce(v.enrollment_date, a.starts_on));
  d_to := least(coalesce(a.ends_on, 'infinity'::date), p_to, coalesce(app.vehicle_fee_end(a.vehicle_id), 'infinity'::date));
  days := case when a.id is null or a.cancelled_at is not null or d_to < d_from then 0 else (d_to - d_from) + 1 end;
end $$;

create or replace function app.flat_days(p_vehicle uuid, p_from date, p_to date) returns integer
language sql stable security definer set search_path = public, app as $$
  select coalesce(sum((app.flat_window(a, p_from, p_to)).days), 0)::integer
    from vehicle_owner_arrangements a where a.vehicle_id = p_vehicle and a.cancelled_at is null
$$;

-- The last day of the owner's latest approved or paid statement: no change reaches it.
create or replace function app.flat_lock_through(p_owner uuid) returns date
language sql stable security definer set search_path = public, app as $$
  select (max(statement_month) + interval '1 month - 1 day')::date from owner_statements where owner_id = p_owner and status in ('approved', 'paid')
$$;

create or replace function app.flat_month_line(a vehicle_owner_arrangements, p_month date, out cents bigint, out description text)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_m date := app.month_start(p_month);
  v_dim integer := app.days_in_month(v_m);
  w record;
begin
  select * into w from app.flat_window(a, v_m, (v_m + interval '1 month - 1 day')::date);
  cents := case when w.days > 0 then public.calc_prorated_fee(a.monthly_cents, w.days, v_dim) else 0 end;
  description := format('Flat monthly payment, %s: %s a month', to_char(v_m, 'FMMonth YYYY'), app.fmt_money(a.monthly_cents))
    || case when w.days > 0 and w.days < v_dim then format(', %s of %s days (%s to %s)', w.days, v_dim, app.flat_day(w.d_from), app.flat_day(w.d_to)) else '' end;
end $$;

-- An open credit or deduction no longer due: deleted, or waived when a statement line points at it.
create or replace function app.flat_drop_credit(p_id uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from owner_statement_lines l where l.owner_credit_id = p_id) then
    update owner_credits set status = 'waived' where id = p_id and status = 'open';
  else
    delete from owner_credits where id = p_id and status = 'open';
  end if;
end $$;
create or replace function app.flat_drop_deduction(p_id uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from owner_statement_lines l where l.owner_deduction_id = p_id) then
    update owner_deductions set status = 'waived' where id = p_id and status = 'open';
  else
    delete from owner_deductions where id = p_id and status = 'open';
  end if;
end $$;

-- The flat payment credits of an owner, every month up to p_month: added, brought up to date, or dropped when no
-- longer due. A credit already on an approved statement is never touched.
create or replace function app.flat_credits_sync(p_owner uuid, p_month date) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_month date := app.month_start(p_month);
  c owner_credits;
  a vehicle_owner_arrangements;
  m date;
  x record;
begin
  for c in select * from owner_credits where owner_id = p_owner and kind = 'flat_monthly' and status = 'open' loop
    select * into a from vehicle_owner_arrangements where id = c.flat_arrangement_id;
    if a.cancelled_at is not null or c.flat_month > v_month or (app.flat_month_line(a, c.flat_month)).cents <= 0 then
      perform app.flat_drop_credit(c.id);
    end if;
  end loop;
  for a in select y.* from vehicle_owner_arrangements y join vehicles v on v.id = y.vehicle_id
            where y.owner_id = p_owner and v.owner_id = p_owner and y.cancelled_at is null and y.starts_on <= (v_month + interval '1 month - 1 day')::date
  loop
    m := app.month_start(a.starts_on);
    while m <= v_month and (a.ends_on is null or m <= a.ends_on) loop
      select * into x from app.flat_month_line(a, m);
      select * into c from owner_credits where flat_arrangement_id = a.id and flat_month = m and kind = 'flat_monthly' and status <> 'waived';
      if c.id is null then
        if x.cents > 0 then
          insert into owner_credits (owner_id, vehicle_id, kind, description, amount_cents, incurred_on, flat_arrangement_id, flat_month)
          values (p_owner, a.vehicle_id, 'flat_monthly', x.description, x.cents, m, a.id, m);
        end if;
      elsif c.status = 'open' and (c.amount_cents <> x.cents or c.description <> x.description) then
        update owner_credits set amount_cents = x.cents, description = x.description where id = c.id;
      end if;
      m := (m + interval '1 month')::date;
    end loop;
  end loop;
end $$;

-- Turo trips not paid out yet: CarmaCars keeps a trip ending on a flat day; the terms' share comes back otherwise.
create or replace function app.flat_turo_sync(p_owner uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  update turo_trips t
     set revenue_share_bps = t.terms_share_bps, revenue_share_cents = public.calc_bps(t.gross_cents - t.turo_fees_cents, t.terms_share_bps),
         terms_share_bps = null, flat_arrangement_id = null
   where t.owner_statement_id is null and t.flat_arrangement_id is not null
     and t.vehicle_id in (select id from vehicles where owner_id = p_owner)
     and (app.flat_arrangement_on(t.vehicle_id, app.local_date(t.ends_at))).id is distinct from t.flat_arrangement_id;
  update turo_trips t
     set terms_share_bps = t.revenue_share_bps, revenue_share_bps = 10000, revenue_share_cents = t.gross_cents - t.turo_fees_cents,
         flat_arrangement_id = (app.flat_arrangement_on(t.vehicle_id, app.local_date(t.ends_at))).id
   where t.vehicle_id in (select id from vehicles where owner_id = p_owner) and t.owner_statement_id is null and t.flat_arrangement_id is null
     and (app.flat_arrangement_on(t.vehicle_id, app.local_date(t.ends_at))).id is not null;
end $$;

-- A booking on a flat car: the expenses an Admin charged to the owner are owner costs on the statement of the booking.
create or replace function app.flat_expense_sync(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  s booking_splits;
  d owner_deductions;
  e booking_owner_expenses;
begin
  if exists (select 1 from booking_splits x where x.booking_id = p_booking and x.owner_statement_id is not null) then return; end if;
  select * into b from bookings where id = p_booking;
  select * into s from booking_splits x where x.booking_id = p_booking and x.flat_arrangement_id is not null
   order by (x.vehicle_id = b.vehicle_id) desc, x.segment_starts_at nulls last limit 1;
  for d in select * from owner_deductions where booking_id = p_booking and kind = 'booking_expense' and status = 'open' loop
    select * into e from booking_owner_expenses where id = d.booking_owner_expense_id;
    if s.booking_id is null or e.id is null or e.voided_at is not null or not e.charge_to_owner then
      perform app.flat_drop_deduction(d.id);
    end if;
  end loop;
  if s.booking_id is null then return; end if;
  for e in select * from booking_owner_expenses where booking_id = p_booking and voided_at is null and charge_to_owner order by created_at, id loop
    select * into d from owner_deductions where booking_owner_expense_id = e.id and status <> 'waived';
    if d.id is null then
      insert into owner_deductions (owner_id, vehicle_id, kind, description, amount_cents, incurred_on, booking_id, booking_owner_expense_id)
      values (s.owner_id, s.vehicle_id, 'booking_expense',
              format('Booking %s: %s %s charged to you: %s', b.booking_number, app.owner_expense_label(e.category), app.fmt_money(e.amount_cents), e.reason),
              e.amount_cents, coalesce(s.counts_on, app.today()), p_booking, e.id);
    elsif d.status = 'open' then
      update owner_deductions set owner_id = s.owner_id, vehicle_id = s.vehicle_id, incurred_on = coalesce(s.counts_on, app.today()) where id = d.id;
    end if;
  end loop;
end $$;

-- Whether a booking counts on a flat day (its split says, or the arrangement on the day it ends).
create or replace function app.booking_flat(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select bool_or(s.flat_arrangement_id is not null) from booking_splits s where s.booking_id = p_booking),
                  (select (app.flat_arrangement_on(b.vehicle_id, app.local_date(coalesce(b.checked_in_at, b.return_at)))).id is not null from bookings b where b.id = p_booking),
                  false)
$$;

-- ================================================================ 3. the split: CarmaCars keeps a rental counted on a flat day
alter function app.compute_booking_split(uuid) rename to compute_booking_split_pre0196;
create function app.compute_booking_split(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  s booking_splits;
  a vehicle_owner_arrangements;
begin
  perform app.compute_booking_split_pre0196(p_booking);
  select * into b from bookings where id = p_booking;
  for s in select * from booking_splits x where x.booking_id = p_booking and x.owner_statement_id is null loop
    a := app.flat_arrangement_on(s.vehicle_id, coalesce(s.counts_on, app.local_date(coalesce(b.checked_in_at, b.return_at))));
    if a.id is not null and a.owner_id = s.owner_id then
      update booking_splits
         set owner_revenue_cents = owner_revenue_cents + owner_expense_cents, owner_expense_cents = 0, booking_share_override = false,
             company_share_bps = 10000, company_share_cents = owner_revenue_cents + owner_expense_cents, owner_payout_cents = 0, flat_arrangement_id = a.id
       where booking_id = p_booking and vehicle_id = s.vehicle_id;
    elsif s.flat_arrangement_id is not null then
      update booking_splits set flat_arrangement_id = null where booking_id = p_booking and vehicle_id = s.vehicle_id;
    end if;
  end loop;
  perform app.flat_expense_sync(p_booking);
end $$;
select pg_temp.copy_grants('app.compute_booking_split(uuid)'::regprocedure, 'app.compute_booking_split_pre0196(uuid)'::regprocedure);

-- ================================================================ 4. the statement
alter function app.build_owner_statement(uuid, date, uuid) rename to build_owner_statement_pre0196;
create function app.build_owner_statement(p_owner uuid, p_month date, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_has boolean := exists (select 1 from vehicle_owner_arrangements a where a.owner_id = p_owner)
                   or exists (select 1 from owner_credits c where c.owner_id = p_owner and c.kind = 'flat_monthly' and c.status = 'open');
  v_id uuid;
begin
  if v_has and coalesce((select kind from owners where id = p_owner), 'program') <> 'company' then
    perform app.flat_turo_sync(p_owner);
    perform app.flat_credits_sync(p_owner, p_month);
  end if;
  v_id := app.build_owner_statement_pre0196(p_owner, p_month, p_by);
  if v_id is null or not v_has then return v_id; end if;
  update owner_statement_lines l set line_type = 'flat_payment', flat_arrangement_id = c.flat_arrangement_id
    from owner_credits c where l.owner_statement_id = v_id and l.owner_credit_id = c.id and c.kind = 'flat_monthly';
  update owner_statement_lines l
     set owner_revenue_cents = 0, revenue_share_cents = 0, flat_arrangement_id = s.flat_arrangement_id,
         description = l.description || '; flat monthly payment: CarmaCars keeps the rental'
    from booking_splits s
   where l.owner_statement_id = v_id and l.line_type = 'rental' and s.booking_id = l.booking_id and s.vehicle_id = l.vehicle_id and s.flat_arrangement_id is not null;
  update owner_statement_lines l
     set owner_revenue_cents = 0, revenue_share_cents = 0, flat_arrangement_id = t.flat_arrangement_id,
         description = l.description || '; flat monthly payment: CarmaCars keeps the trip'
    from turo_trips t
   where l.owner_statement_id = v_id and l.line_type = 'turo_trip' and t.id = l.turo_trip_id and t.flat_arrangement_id is not null;
  update owner_statement_vehicles sv
     set owner_revenue_cents = coalesce((select sum(l.owner_revenue_cents) from owner_statement_lines l where l.owner_statement_id = v_id and l.vehicle_id = sv.vehicle_id and l.line_type in ('rental', 'turo_trip')), 0),
         revenue_share_cents = coalesce((select sum(l.revenue_share_cents) from owner_statement_lines l where l.owner_statement_id = v_id and l.vehicle_id = sv.vehicle_id and l.line_type in ('rental', 'turo_trip')), 0),
         flat_payment_cents = coalesce((select sum(l.amount_cents) from owner_statement_lines l where l.owner_statement_id = v_id and l.vehicle_id = sv.vehicle_id and l.line_type = 'flat_payment'), 0)
   where sv.owner_statement_id = v_id;
  update owner_statements st
     set owner_revenue_cents = coalesce((select sum(owner_revenue_cents) from owner_statement_vehicles where owner_statement_id = v_id), 0),
         revenue_share_cents = coalesce((select sum(revenue_share_cents) from owner_statement_vehicles where owner_statement_id = v_id), 0),
         flat_payment_cents = coalesce((select sum(flat_payment_cents) from owner_statement_vehicles where owner_statement_id = v_id), 0)
   where st.id = v_id;
  return v_id;
end $$;
select pg_temp.copy_grants('app.build_owner_statement(uuid, date, uuid)'::regprocedure, 'app.build_owner_statement_pre0196(uuid, date, uuid)'::regprocedure);

-- the statement's breakdown (Admin preview and the PDF): each car's flat payment
alter function app.owner_statement_breakdown(uuid, uuid) rename to owner_statement_breakdown_pre0196;
create function app.owner_statement_breakdown(p_statement uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.owner_statement_breakdown_pre0196(p_statement, p_by);
begin
  if r is null or jsonb_typeof(r -> 'vehicles') <> 'array' then return r; end if;
  return jsonb_set(r, '{vehicles}', coalesce((
    select jsonb_agg(x || jsonb_build_object('flat_payment_cents', coalesce(sv.flat_payment_cents, 0)) order by o.n)
      from jsonb_array_elements(r -> 'vehicles') with ordinality o(x, n)
      left join owner_statement_vehicles sv on sv.owner_statement_id = p_statement and sv.vehicle_id = (o.x ->> 'vehicle_id')::uuid), '[]'::jsonb))
    || jsonb_build_object('flat_payment_cents', (select flat_payment_cents from owner_statements where id = p_statement));
end $$;
select pg_temp.copy_grants('app.owner_statement_breakdown(uuid, uuid)'::regprocedure, 'app.owner_statement_breakdown_pre0196(uuid, uuid)'::regprocedure);

-- ================================================================ 5. fees: none for the flat days
alter function app.generate_owner_invoice(uuid, date, uuid) rename to generate_owner_invoice_pre0196;
create function app.generate_owner_invoice(p_vehicle uuid, p_month date, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_month date := app.month_start(p_month);
  v_start date;
  v_end date;
  v_all integer;
  v_flat integer;
  v_id uuid;
  v_hst integer := (app.settings(v_month)).hst_bps;
  v_ins bigint;
  v_credit bigint;
  v_cut bigint;
  l record;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null or v.enrollment_date is null then return app.generate_owner_invoice_pre0196(p_vehicle, p_month, p_by); end if;
  v_start := greatest(v_month, v.enrollment_date);
  v_end := least((v_month + interval '1 month - 1 day')::date, coalesce(app.vehicle_fee_end(p_vehicle), 'infinity'::date));
  v_all := (v_end - v_start) + 1;
  v_flat := case when v_all > 0 then app.flat_days(p_vehicle, v_start, v_end) else 0 end;
  if v_flat <= 0 then return app.generate_owner_invoice_pre0196(p_vehicle, p_month, p_by); end if;
  if v_flat >= v_all then return null; end if;   -- every day on a flat monthly payment: no fees
  v_id := app.generate_owner_invoice_pre0196(p_vehicle, p_month, p_by);
  if v_id is null then return null; end if;
  update owner_invoice_lines
     set amount_cents = round(amount_cents::numeric * (v_all - v_flat) / v_all)::bigint,
         hst_cents = public.calc_hst(round(amount_cents::numeric * (v_all - v_flat) / v_all)::bigint, v_hst),
         description = description || format('; none for the %s days on a flat monthly payment', v_flat)
   where owner_invoice_id = v_id and kind in ('insurance_fee', 'tracker_fee');
  -- a prepaid month applied never exceeds the Insurance Fee billed
  select coalesce(sum(amount_cents), 0) into v_ins from owner_invoice_lines where owner_invoice_id = v_id and kind = 'insurance_fee';
  select coalesce(-sum(amount_cents), 0) into v_credit from owner_invoice_lines where owner_invoice_id = v_id and kind = 'prepaid_credit';
  if v_credit > v_ins then
    v_cut := v_credit - v_ins;
    for l in select * from owner_invoice_lines where owner_invoice_id = v_id and kind = 'prepaid_credit' order by amount_cents loop
      exit when v_cut <= 0;
      update owner_invoice_lines set amount_cents = amount_cents + least(v_cut, -amount_cents),
             hst_cents = -public.calc_hst(-(amount_cents + least(v_cut, -amount_cents)), v_hst)
       where id = l.id;
      update vehicle_prepaids set applied_cents = applied_cents - least(v_cut, -l.amount_cents) where id = l.vehicle_prepaid_id;
      v_cut := v_cut - least(v_cut, -l.amount_cents);
    end loop;
  end if;
  return v_id;
end $$;
select pg_temp.copy_grants('app.generate_owner_invoice(uuid, date, uuid)'::regprocedure, 'app.generate_owner_invoice_pre0196(uuid, date, uuid)'::regprocedure);

-- ================================================================ 6. set it: the car's owner terms (Admin)
-- p: vehicle_id, arrangement (flat_monthly | revenue_share), monthly_cents, from, until (optional, the last day), reason,
-- preview (nothing saved). A new setting replaces everything from its date on.
create or replace function app.car_pay_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  o owners;
  v_kind text := coalesce(nullif(p ->> 'arrangement', ''), 'flat_monthly');
  v_from date;
  v_until date;
  v_amount bigint;
  v_reason text := btrim(coalesce(p ->> 'reason', ''));
  v_lock date;
  v_cur vehicle_owner_arrangements;
  v_steps text[] := '{}';
  v_inv jsonb;
  r record;
begin
  perform app.assert_admin(p_by);
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  select * into o from owners where id = v.owner_id;
  if v.supply_type <> 'program_owner' or v.is_shareholder_owned or coalesce(o.kind, 'program') <> 'program' then
    raise exception 'A flat monthly payment is for a program owner''s car (not a shareholder''s, a partner''s or a company car)' using errcode = '22023';
  end if;
  if v_kind not in ('flat_monthly', 'revenue_share') then raise exception 'Choose revenue share or flat monthly payment' using errcode = '22023'; end if;
  begin
    v_from := nullif(p ->> 'from', '')::date;
    v_until := nullif(p ->> 'until', '')::date;
  exception when others then raise exception 'Give the dates as YYYY-MM-DD' using errcode = '22023';
  end;
  if v_from is null then raise exception 'Choose the date it starts' using errcode = '22023'; end if;
  v_lock := app.flat_lock_through(v.owner_id);
  if v_lock is not null and v_from <= v_lock then
    raise exception 'The owner statement up to % is approved and stays as it is: choose % or later', app.flat_day(v_lock), app.flat_day(v_lock + 1) using errcode = '23514';
  end if;
  if v_kind = 'flat_monthly' then
    if (p ->> 'monthly_cents') is null or (p ->> 'monthly_cents') !~ '^\d{1,9}$' or (p ->> 'monthly_cents')::bigint <= 0 then
      raise exception 'Enter the amount a month, more than $0.00' using errcode = '22023';
    end if;
    v_amount := (p ->> 'monthly_cents')::bigint;
    if v_until is not null and v_until < v_from then raise exception 'The last day is on or after the first' using errcode = '22023'; end if;
  else
    v_until := null;
    v_cur := app.flat_arrangement_on(v.id, v_from);
    if v_cur.id is null and not exists (select 1 from vehicle_owner_arrangements x where x.vehicle_id = v.id and x.cancelled_at is null and x.starts_on >= v_from) then
      raise exception 'This car is on revenue share from that date already' using errcode = '23514';
    end if;
  end if;
  if length(v_reason) < 3 then raise exception 'Write the reason (kept in the history)' using errcode = '22023'; end if;

  v_steps := v_steps || case when v_kind = 'flat_monthly'
    then format('From %s%s CarmaCars pays the owner %s a month for this car, part months by the day, on the monthly owner statement.',
                app.flat_day(v_from), coalesce(' to ' || app.flat_day(v_until), ''), app.fmt_money(v_amount))
    else format('From %s the owner is paid by revenue share again, at the car''s terms (%s), and the monthly Fees apply.', app.flat_day(v_from),
                coalesce(trim(to_char((app.vehicle_terms(v.id, v_from)).revenue_share_bps / 100.0, 'FM990.99')) || '%', 'the terms in force')) end;
  if v_kind = 'flat_monthly' then
    v_steps := v_steps || 'No revenue share and no Insurance Fee or Tracker Fee for those days: rentals ending on them stay with CarmaCars.'::text
                       || 'Booking expenses of those rentals are not passed to the owner unless an Admin marks one "Charge to the owner".'::text;
  end if;
  if exists (select 1 from vehicle_owner_arrangements x where x.vehicle_id = v.id and x.cancelled_at is null and x.starts_on >= v_from) then
    v_steps := v_steps || 'A flat payment set from this date or later is replaced.'::text;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('invoice_number', i.invoice_number, 'period_month', i.period_month, 'status', i.status) order by i.period_month), '[]'::jsonb)
    into v_inv from owner_invoices i
   where i.vehicle_id = v.id and i.kind = 'monthly' and i.status not in ('void', 'draft')
     and (i.period_month + interval '1 month - 1 day')::date >= v_from and (v_until is null or i.period_month <= v_until);
  if jsonb_array_length(v_inv) > 0 then
    v_steps := v_steps || format('Monthly invoices already issued for these days stay as they are: %s. Void or credit them if the Fees should go.',
                                 (select string_agg(x ->> 'invoice_number', ', ') from jsonb_array_elements(v_inv) x));
  end if;
  if coalesce((p ->> 'preview')::boolean, false) then
    return jsonb_build_object('done', false, 'steps', to_jsonb(v_steps), 'invoices', v_inv, 'earliest', v_lock + 1);
  end if;

  update vehicle_owner_arrangements set cancelled_at = now(), cancelled_by = p_by, cancelled_reason = 'Replaced: ' || left(v_reason, 480)
   where vehicle_id = v.id and cancelled_at is null and starts_on >= v_from;
  update vehicle_owner_arrangements set ends_on = v_from - 1, ended_at = now(), ended_by = p_by, ended_reason = left(v_reason, 500)
   where vehicle_id = v.id and cancelled_at is null and starts_on < v_from and (ends_on is null or ends_on >= v_from);
  if v_kind = 'flat_monthly' then
    insert into vehicle_owner_arrangements (vehicle_id, owner_id, monthly_cents, starts_on, ends_on, reason, created_by)
    values (v.id, v.owner_id, v_amount, v_from, v_until, left(v_reason, 500), p_by);
  end if;
  -- the finished rentals not paid out yet follow at once (the booking pages, the month to date)
  for r in select distinct s.booking_id from booking_splits s where s.vehicle_id = v.id and s.owner_statement_id is null loop
    perform app.compute_booking_split(r.booking_id);
  end loop;
  return jsonb_build_object('done', true, 'steps', to_jsonb(v_steps), 'invoices', v_inv);
end $$;

-- The car's terms (Admin and the owner portal): how the owner is paid, now, next and over time.
alter function app.ct_car(uuid, boolean) rename to ct_car_pre0196;
create function app.ct_car(p_vehicle uuid, p_admin boolean) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.ct_car_pre0196(p_vehicle, p_admin);
  v vehicles;
  v_today date := app.today();
  a vehicle_owner_arrangements;
  n vehicle_owner_arrangements;
  v_lock date;
begin
  if r is null then return r; end if;
  select * into v from vehicles where id = p_vehicle;
  a := app.flat_arrangement_on(p_vehicle, v_today);
  select * into n from vehicle_owner_arrangements x where x.vehicle_id = p_vehicle and x.cancelled_at is null and x.starts_on > v_today order by x.starts_on limit 1;
  v_lock := app.flat_lock_through(v.owner_id);
  return r || jsonb_build_object('pay', jsonb_build_object(
    'arrangement', case when a.id is not null then 'flat_monthly' else 'revenue_share' end,
    'monthly_cents', a.monthly_cents, 'since', a.starts_on, 'until', a.ends_on,
    'next', case when n.id is not null then jsonb_build_object('arrangement', 'flat_monthly', 'monthly_cents', n.monthly_cents, 'from', n.starts_on, 'until', n.ends_on)
                 when a.ends_on is not null then jsonb_build_object('arrangement', 'revenue_share', 'from', a.ends_on + 1) end,
    'periods', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'monthly_cents', x.monthly_cents, 'from', x.starts_on, 'to', x.ends_on,
                  'current', x.starts_on <= v_today and (x.ends_on is null or x.ends_on >= v_today), 'future', x.starts_on > v_today,
                  'reason', case when p_admin then x.reason end, 'ended_reason', case when p_admin then x.ended_reason end,
                  'by', case when p_admin then (select u.full_name from users u where u.id = x.created_by) end, 'at', x.created_at)
                  order by x.starts_on desc), '[]'::jsonb)
                  from vehicle_owner_arrangements x where x.vehicle_id = p_vehicle and x.cancelled_at is null),
    'may_set', p_admin and v.supply_type = 'program_owner' and not v.is_shareholder_owned and v.status not in ('declined', 'exited', 'total_loss')
               and coalesce((select o.kind from owners o where o.id = v.owner_id), 'program') = 'program',
    'earliest', case when p_admin then v_lock + 1 end));
end $$;
select pg_temp.copy_grants('app.ct_car(uuid, boolean)'::regprocedure, 'app.ct_car_pre0196(uuid, boolean)'::regprocedure);

-- ================================================================ 7. booking expenses on a flat car: "Charge to the owner" (Admin)
-- p: id (the expense), charge (true or false)
create or replace function app.booking_owner_expense_charge(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  e booking_owner_expenses;
  b bookings;
  v_charge boolean := coalesce(nullif(p ->> 'charge', '')::boolean, true);
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin charges a booking expense to the owner' using errcode = '42501'; end if;
  select * into e from booking_owner_expenses where id = nullif(p ->> 'id', '')::uuid;
  if e.id is null or e.voided_at is not null then raise exception 'That expense is not on the booking' using errcode = 'P0002'; end if;
  select * into b from bookings where id = e.booking_id;
  perform app.booking_owner_deduction_check(b);
  if e.charge_to_owner is distinct from v_charge then
    update booking_owner_expenses set charge_to_owner = v_charge, charge_set_by = p_by, charge_set_at = now() where id = e.id;
    insert into booking_events (booking_id, kind, note, details, actor_type, actor_user_id)
    values (b.id, 'owner_expense', format('%s %s %s', app.owner_expense_label(e.category), app.fmt_money(e.amount_cents),
                                          case when v_charge then 'charged to the owner (flat monthly payment car)' else 'no longer charged to the owner' end),
            jsonb_build_object('category', e.category, 'amount_cents', e.amount_cents, 'charge_to_owner', v_charge), 'staff', p_by);
    perform app.booking_owner_resplit(b.id);
  end if;
  return app.booking_owner_deductions_read(p_by, b);
end $$;

alter function app.booking_owner_deductions_read(uuid, bookings) rename to booking_owner_deductions_read_pre0196;
create function app.booking_owner_deductions_read(p_by uuid, b bookings) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.booking_owner_deductions_read_pre0196(p_by, b);
  a vehicle_owner_arrangements;
begin
  select x.* into a from vehicle_owner_arrangements x
   where x.id = coalesce((select s.flat_arrangement_id from booking_splits s where s.booking_id = b.id and s.flat_arrangement_id is not null limit 1),
                         (app.flat_arrangement_on(b.vehicle_id, app.local_date(coalesce(b.checked_in_at, b.return_at)))).id);
  r := jsonb_set(r, '{expenses}', coalesce((select jsonb_agg(x || jsonb_build_object('charge_to_owner', coalesce(e.charge_to_owner, false)) order by o.n)
                                             from jsonb_array_elements(r -> 'expenses') with ordinality o(x, n)
                                             left join booking_owner_expenses e on e.id = (o.x ->> 'id')::uuid), '[]'::jsonb));
  return r || jsonb_build_object('may_charge', app.user_is_admin(p_by),
    'flat', case when a.id is not null then jsonb_build_object('monthly_cents', a.monthly_cents, 'from', a.starts_on, 'until', a.ends_on) end);
end $$;
select pg_temp.copy_grants('app.booking_owner_deductions_read(uuid, bookings)'::regprocedure, 'app.booking_owner_deductions_read_pre0196(uuid, bookings)'::regprocedure);

-- The owner's bookings (0156): on a flat car only the expenses charged to the owner are listed.
create or replace function app.owner_portal_bookings(p_by uuid, p_from timestamptz default null, p_to timestamptz default null)
returns table (booking_id uuid, booking_number text, booking_type booking_type, status booking_status, vehicle_id uuid, vehicle_name text,
               pickup_at timestamptz, return_at timestamptz, rental_charge_cents bigint, renter_name text, renter_mobile text, owner_view text,
               owner_expenses jsonb, booking_share_bps integer)
language sql stable security definer set search_path = public, app as $$
  select b.id, case when x.v = 'unavailable' then null else b.booking_number end, b.booking_type, b.status, b.vehicle_id, app.vehicle_name(b.vehicle_id),
         b.pickup_at, b.return_at,
         case when x.v = 'full' then b.rental_charge_cents - b.discount_cents - b.staff_discount_cents - b.promo_discount_cents end,
         case when x.v <> 'unavailable' and (b.management_mode = 'self_managed' or b.booking_type = 'owner') then r.legal_name end,
         case when x.v <> 'unavailable' and (b.management_mode = 'self_managed' or b.booking_type = 'owner') then r.mobile end,
         x.v,
         case when x.v = 'full' then (select coalesce(jsonb_agg(jsonb_build_object('category', e.category, 'amount_cents', e.amount_cents, 'reason', e.reason,
                                        'receipt', e.receipt_ref is not null) order by e.created_at, e.id), '[]'::jsonb)
                                        from booking_owner_expenses e where e.booking_id = b.id and e.voided_at is null
                                         and (e.charge_to_owner or not app.booking_flat(b.id))) else '[]'::jsonb end,
         case when x.v = 'full' and not app.booking_flat(b.id) then (select o.company_share_bps from booking_owner_shares o where o.booking_id = b.id) end
    from bookings b join vehicles v on v.id = b.vehicle_id join renters r on r.id = b.renter_id
    cross join lateral (select app.booking_owner_view(b) as v) x
   where v.owner_id = app.portal_owner_id(p_by)
     and b.status::text not in ('requested', 'offered', 'tentative', 'expired', 'declined')
     and (p_from is null or b.return_at > p_from) and (p_to is null or b.pickup_at < p_to)
   order by b.pickup_at
$$;

-- ================================================================ 8. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0196;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_call = 'ops_do' and p_name in ('car_pay_set', 'booking_owner_expense_charge') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'car_pay_set' then app.car_pay_set(p_user, p_) else app.booking_owner_expense_charge(p_user, p_) end;
  end if;
  return app.door_pre0196(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0196(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 9. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['voa_no_overlap', 'flat_day', 'flat_arrangement_on', 'flat_window', 'flat_days', 'flat_lock_through', 'flat_month_line',
             'flat_drop_credit', 'flat_drop_deduction', 'flat_credits_sync', 'flat_turo_sync', 'flat_expense_sync', 'booking_flat', 'car_pay_set',
             'booking_owner_expense_charge', 'compute_booking_split_pre0196', 'build_owner_statement_pre0196', 'owner_statement_breakdown_pre0196',
             'generate_owner_invoice_pre0196', 'ct_car_pre0196', 'booking_owner_deductions_read_pre0196', 'door_pre0196'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 10. the guides
-- GUIDES 0196 START (generated by supabase/seed/0196_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('owner', 'fees-payments-and-payouts', 'chapter', 'bookings-and-your-own-use', 'Your fees are debited from your bank account on the 15th, after a notice. Your payout for the month before arrives on the 10th, with a statement.

## How your fees work

- Each car has two monthly fees: an insurance fee and a tracker fee. They are due every month, rented or not.
- The tracker fee starts the day the car''s tracker is installed. The tracker install fee has its own invoice.
- Before a car goes live you pay the first and last month amount we agreed with you (usually two months of the insurance fee, or the exact amount we agreed).
- Your amounts are the ones we agreed for each car, to the cent. Any other fee we agreed, for example a registration fee, comes on its own invoice with each line, its quantity and whether HST applies.
- Vehicles shows each car''s terms: the insurance fee and tracker fee a month and the Revenue Share, since when they apply, and any change coming. Open a car for its History: every period of terms and every notice we sent (Download the notice).
- Lower amounts apply from the date in our notice. A higher fee comes with 30 days'' written notice; a higher Revenue Share applies only if you sign an updated Vehicle Schedule. A month whose fee changes part way is billed per day at each amount.
- One invoice per car. Registry, inspection and appraisal costs are not billed by us unless we agreed to pay them for you; then they are on an invoice of their own.

An invoice we cancel shows Void with the reason, and the invoice that replaces it. Nothing is debited for a void invoice. Every invoice has Download PDF.

## The monthly debit, step by step

:::flow
Notice day | 10 days before: your invoices and one email with the total
The 15th | Each invoice is debited from your account
Cleared | The invoice shows Paid and you get a receipt
Insufficient funds? | A $50.00 Late Fee once, and the same amount tried again within 30 days
:::

- A debit is never more than its notice said. Each invoice shows "will be debited on" with the date.
- If your bank returns a debit for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.
- Returned for another reason (for example a closed account)? We do not try again and add no Late Fee. We pause your debit and email you: pay the invoice from its page, or set up a new account under Account > Banking.
- Returned again after the retry? The invoice is in arrears and we contact you.
- You can always pay an invoice by card from its page before the debit day.
- On your bank statement the debit shows our company''s legal name, operating as CarmaCars.

## Set up the automatic debit

Do this once. Without it, we email you on each notice day to set it up.

1. Open **Account** > **Banking**. Under Automatic debit of your fees, press **Set up pre-authorized debit**.
2. Read the agreement and press **Continue to my bank details**.
3. Enter your bank details and press **Save the bank account**. Banking then shows the account and the next debit.

![](/guides/img/owner-07-banking-desktop-52316739.jpg "desktop; size: 1440 752; address: carmacars.ca/owner/banking; pins: 1 96.2 36.8")

## Pay an invoice now

1. Open Invoices, then the invoice. It lists what it covers and the balance.
2. Choose Card (paid at once) and press **Pay $...**.
3. Or choose Pre-authorized debit (from a Canadian bank account, clears in 3 to 5 business days) and press **Authorize debit of $...**.
4. Prefer Interac e-Transfer? Send the amount to billing@carmacars.ca with the invoice number in the message.

![](/guides/img/owner-06-invoice-desktop-bba2c020.jpg "desktop; size: 1440 742; address: carmacars.ca/owner/invoices/INV-1050; pins: 2 6.9 52.6, 3 38.2 52.6, 4 11.5 80.5")

> Tip: Paid us by e-Transfer, cheque, cash or bank transfer? Once we record it, the invoice says "Paid by e-Transfer on" the date, you get a receipt by email, and the automatic debit does not take that amount. Paid part of it? The invoice shows Partly paid and only the rest is debited.

## Tell us where to pay you

1. Open **Account** > **Banking**. Under Where we pay you, choose Bank transfer or e-Transfer.
2. Fill in Account holder, Institution number, Transit number and Account number (or your e-Transfer email).
3. Press **Submit payout details**. For your security we confirm new details by phone before we use them.

![](/guides/img/owner-07-banking-desktop-87b2ffe3.jpg "desktop; size: 990 642; address: carmacars.ca/owner/banking; pins: 1 50.5 25.7, 2 90.9 45.5, 3 30.3 89.7")

## Statements and payouts

1. This month so far, at the top of Statements: the rentals finished this month, your Owner Revenue, the Revenue Share, fees and deductions and the expected payout, worked out live and marked Provisional. Rentals still under way are listed below it.
2. Statements: one a month, once approved by CarmaCars; the approved statement is the final one. Open one to see every booking, the revenue share, deductions and the payout.
3. Press **Download PDF** to keep a copy. We also email it to you with the PDF attached.
4. Payouts shows what was paid to you and when. Payouts are made on the 10th for the month before.

![](/guides/img/owner-09-statement-desktop-fc5f9ea5.jpg "desktop; size: 1440 792; address: carmacars.ca/owner/statements/380cc1bb-bfd5-4e55-8022-93a3b998ca74; pins: 2 16.0 30.6, 1 66.0 40.9")
', 'Fees, payments and payouts', 'How fees are billed, the monthly debit, paying an invoice, statements and payouts.',
  'Your fees are debited from your bank account on the 15th, after a notice. Your payout for the month before arrives on the 10th, with a statement.

## How your fees work

- Each car has two monthly fees: an insurance fee and a tracker fee. They are due every month, rented or not.
- The tracker fee starts the day the car''s tracker is installed. The tracker install fee has its own invoice.
- Before a car goes live you pay the first and last month amount we agreed with you (usually two months of the insurance fee, or the exact amount we agreed).
- Your amounts are the ones we agreed for each car, to the cent. Any other fee we agreed, for example a registration fee, comes on its own invoice with each line, its quantity and whether HST applies.
- Vehicles shows each car''s terms: the insurance fee and tracker fee a month and the Revenue Share, since when they apply, and any change coming. Open a car for its History: every period of terms and every notice we sent (Download the notice).
- Lower amounts apply from the date in our notice. A higher fee comes with 30 days'' written notice; a higher Revenue Share applies only if you sign an updated Vehicle Schedule. A month whose fee changes part way is billed per day at each amount.
- One invoice per car. Registry, inspection and appraisal costs are not billed by us unless we agreed to pay them for you; then they are on an invoice of their own.

An invoice we cancel shows Void with the reason, and the invoice that replaces it. Nothing is debited for a void invoice. Every invoice has Download PDF.

## The monthly debit, step by step

:::flow
Notice day | 10 days before: your invoices and one email with the total
The 15th | Each invoice is debited from your account
Cleared | The invoice shows Paid and you get a receipt
Insufficient funds? | A $50.00 Late Fee once, and the same amount tried again within 30 days
:::

- A debit is never more than its notice said. Each invoice shows "will be debited on" with the date.
- If your bank returns a debit for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.
- Returned for another reason (for example a closed account)? We do not try again and add no Late Fee. We pause your debit and email you: pay the invoice from its page, or set up a new account under Account > Banking.
- Returned again after the retry? The invoice is in arrears and we contact you.
- You can always pay an invoice by card from its page before the debit day.
- On your bank statement the debit shows our company''s legal name, operating as CarmaCars.

## Set up the automatic debit

Do this once. Without it, we email you on each notice day to set it up.

1. Open **Account** > **Banking**. Under Automatic debit of your fees, press **Set up pre-authorized debit**.
2. Read the agreement and press **Continue to my bank details**.
3. Enter your bank details and press **Save the bank account**. Banking then shows the account and the next debit.

![](/guides/img/owner-07-banking-desktop-52316739.jpg "desktop; size: 1440 752; address: carmacars.ca/owner/banking; pins: 1 96.2 36.8")

## Pay an invoice now

1. Open Invoices, then the invoice. It lists what it covers and the balance.
2. Choose Card (paid at once) and press **Pay $...**.
3. Or choose Pre-authorized debit (from a Canadian bank account, clears in 3 to 5 business days) and press **Authorize debit of $...**.
4. Prefer Interac e-Transfer? Send the amount to billing@carmacars.ca with the invoice number in the message.

![](/guides/img/owner-06-invoice-desktop-bba2c020.jpg "desktop; size: 1440 742; address: carmacars.ca/owner/invoices/INV-1050; pins: 2 6.9 52.6, 3 38.2 52.6, 4 11.5 80.5")

> Tip: Paid us by e-Transfer, cheque, cash or bank transfer? Once we record it, the invoice says "Paid by e-Transfer on" the date, you get a receipt by email, and the automatic debit does not take that amount. Paid part of it? The invoice shows Partly paid and only the rest is debited.

## Tell us where to pay you

1. Open **Account** > **Banking**. Under Where we pay you, choose Bank transfer or e-Transfer.
2. Fill in Account holder, Institution number, Transit number and Account number (or your e-Transfer email).
3. Press **Submit payout details**. For your security we confirm new details by phone before we use them.

![](/guides/img/owner-07-banking-desktop-87b2ffe3.jpg "desktop; size: 990 642; address: carmacars.ca/owner/banking; pins: 1 50.5 25.7, 2 90.9 45.5, 3 30.3 89.7")

## Statements and payouts

1. This month so far, at the top of Statements: the rentals finished this month, your Owner Revenue, the Revenue Share, fees and deductions and the expected payout, worked out live and marked Provisional. Rentals still under way are listed below it.
2. Statements: one a month, once approved by CarmaCars; the approved statement is the final one. Open one to see every booking, the revenue share, deductions and the payout.
3. Press **Download PDF** to keep a copy. We also email it to you with the PDF attached.
4. Payouts shows what was paid to you and when. Payouts are made on the 10th for the month before.

![](/guides/img/owner-09-statement-desktop-fc5f9ea5.jpg "desktop; size: 1440 792; address: carmacars.ca/owner/statements/380cc1bb-bfd5-4e55-8022-93a3b998ca74; pins: 2 16.0 30.6, 1 66.0 40.9")

> Good to know: Paid a flat monthly payment for a car? Its statement shows a Flat monthly payment line for the month (a part month by the day) instead of the Revenue Share. The car''s rentals are listed without amounts paid to you, as CarmaCars keeps them, and there is no insurance or tracker fee for it. A booking expense is taken off only when we charge it to you; it then shows as an owner cost with its reason. Vehicles shows the amount and since when.
',
  '<p class="gd-p">Your fees are debited from your bank account on the 15th, after a notice. Your payout for the month before arrives on the 10th, with a statement.</p><section class="gd-task" id="fees-payments-and-payouts-how-your-fees-work" data-gd-task><h2 class="gd-h2">How your fees work</h2><ul class="gd-ul"><li>Each car has two monthly fees: an insurance fee and a tracker fee. They are due every month, rented or not.</li><li>The tracker fee starts the day the car&#39;s tracker is installed. The tracker install fee has its own invoice.</li><li>Before a car goes live you pay the first and last month amount we agreed with you (usually two months of the insurance fee, or the exact amount we agreed).</li><li>Your amounts are the ones we agreed for each car, to the cent. Any other fee we agreed, for example a registration fee, comes on its own invoice with each line, its quantity and whether HST applies.</li><li>Vehicles shows each car&#39;s terms: the insurance fee and tracker fee a month and the Revenue Share, since when they apply, and any change coming. Open a car for its History: every period of terms and every notice we sent (Download the notice).</li><li>Lower amounts apply from the date in our notice. A higher fee comes with 30 days&#39; written notice; a higher Revenue Share applies only if you sign an updated Vehicle Schedule. A month whose fee changes part way is billed per day at each amount.</li><li>One invoice per car. Registry, inspection and appraisal costs are not billed by us unless we agreed to pay them for you; then they are on an invoice of their own.</li></ul><p class="gd-p">An invoice we cancel shows Void with the reason, and the invoice that replaces it. Nothing is debited for a void invoice. Every invoice has Download PDF.</p></section><section class="gd-task" id="fees-payments-and-payouts-the-monthly-debit-step-by-step" data-gd-task><h2 class="gd-h2">The monthly debit, step by step</h2><ol class="gd-flow"><li><b>1</b><span>Notice day</span><em>10 days before: your invoices and one email with the total</em></li><li><b>2</b><span>The 15th</span><em>Each invoice is debited from your account</em></li><li><b>3</b><span>Cleared</span><em>The invoice shows Paid and you get a receipt</em></li><li><b>4</b><span>Insufficient funds?</span><em>A $50.00 Late Fee once, and the same amount tried again within 30 days</em></li></ol><ul class="gd-ul"><li>A debit is never more than its notice said. Each invoice shows &quot;will be debited on&quot; with the date.</li><li>If your bank returns a debit for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.</li><li>Returned for another reason (for example a closed account)? We do not try again and add no Late Fee. We pause your debit and email you: pay the invoice from its page, or set up a new account under Account &gt; Banking.</li><li>Returned again after the retry? The invoice is in arrears and we contact you.</li><li>You can always pay an invoice by card from its page before the debit day.</li><li>On your bank statement the debit shows our company&#39;s legal name, operating as CarmaCars.</li></ul></section><section class="gd-task" id="fees-payments-and-payouts-set-up-the-automatic-debit" data-gd-task><h2 class="gd-h2">Set up the automatic debit</h2><p class="gd-p">Do this once. Without it, we email you on each notice day to set it up.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Account</b> &gt; <b class="gd-ui">Banking</b>. Under Automatic debit of your fees, press <b class="gd-ui">Set up pre-authorized debit</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read the agreement and press <b class="gd-ui">Continue to my bank details</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Enter your bank details and press <b class="gd-ui">Save the bank account</b>. Banking then shows the account and the next debit.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/banking</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/752"><img src="/guides/img/owner-07-banking-desktop-52316739.jpg" alt="" loading="lazy" decoding="async" width="1440" height="752"><span class="gd-pin" style="left:96.2%;top:36.8%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="fees-payments-and-payouts-pay-an-invoice-now" data-gd-task><h2 class="gd-h2">Pay an invoice now</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Invoices, then the invoice. It lists what it covers and the balance.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose Card (paid at once) and press <b class="gd-ui">Pay $...</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Or choose Pre-authorized debit (from a Canadian bank account, clears in 3 to 5 business days) and press <b class="gd-ui">Authorize debit of $...</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Prefer Interac e-Transfer? Send the amount to billing@carmacars.ca with the invoice number in the message.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/invoices/INV-1050</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/742"><img src="/guides/img/owner-06-invoice-desktop-bba2c020.jpg" alt="" loading="lazy" decoding="async" width="1440" height="742"><span class="gd-pin" style="left:6.9%;top:52.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:38.2%;top:52.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:11.5%;top:80.5%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Paid us by e-Transfer, cheque, cash or bank transfer? Once we record it, the invoice says &quot;Paid by e-Transfer on&quot; the date, you get a receipt by email, and the automatic debit does not take that amount. Paid part of it? The invoice shows Partly paid and only the rest is debited.</div></aside></section><section class="gd-task" id="fees-payments-and-payouts-tell-us-where-to-pay-you" data-gd-task><h2 class="gd-h2">Tell us where to pay you</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Account</b> &gt; <b class="gd-ui">Banking</b>. Under Where we pay you, choose Bank transfer or e-Transfer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in Account holder, Institution number, Transit number and Account number (or your e-Transfer email).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Submit payout details</b>. For your security we confirm new details by phone before we use them.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/banking</span></div><div class="gd-imgwrap" style="aspect-ratio:990/642"><img src="/guides/img/owner-07-banking-desktop-87b2ffe3.jpg" alt="" loading="lazy" decoding="async" width="990" height="642"><span class="gd-pin" style="left:50.5%;top:25.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:90.9%;top:45.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:30.3%;top:89.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fees-payments-and-payouts-statements-and-payouts" data-gd-task><h2 class="gd-h2">Statements and payouts</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">This month so far, at the top of Statements: the rentals finished this month, your Owner Revenue, the Revenue Share, fees and deductions and the expected payout, worked out live and marked Provisional. Rentals still under way are listed below it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Statements: one a month, once approved by CarmaCars; the approved statement is the final one. Open one to see every booking, the revenue share, deductions and the payout.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Download PDF</b> to keep a copy. We also email it to you with the PDF attached.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Payouts shows what was paid to you and when. Payouts are made on the 10th for the month before.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/statements/380cc1bb-bfd5-4e55-8022-93a3b998ca74</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/792"><img src="/guides/img/owner-09-statement-desktop-fc5f9ea5.jpg" alt="" loading="lazy" decoding="async" width="1440" height="792"><span class="gd-pin" style="left:16%;top:30.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:66%;top:40.9%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Paid a flat monthly payment for a car? Its statement shows a Flat monthly payment line for the month (a part month by the day) instead of the Revenue Share. The car&#39;s rentals are listed without amounts paid to you, as CarmaCars keeps them, and there is no insurance or tracker fee for it. A booking expense is taken off only when we charge it to you; it then shows as an owner cost with its reason. Vehicles shows the amount and since when.</div></aside></section>');
select app.guide_release_section('admin', 'owners-and-onboarding', 'chapter', 'chauffeur-service', 'Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.

## Applications

**People** > **Applications**. Every owner application, newest first.

1. The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.
2. Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.
3. Open an application to decide.

![](/guides/img/admin-33-applications-desktop-152f9e34.jpg "desktop; size: 1440 640; address: carmacars.ca/admin/applications; pins: 1 36.8 39.7, 2 48.6 53.1, 3 19.8 53.1")

## Decide on an application

One page holds everything: the owner, the car, the uploads, the four checks and the notes.

1. Check the driver''s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.
2. Press **Approve**. The step "Terms and first invoice" opens for each car, filled in with the owner''s negotiated terms (or the standard grid): Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and the first and last month amount (2 x the Insurance Fee unless you type an exact amount). Change any of them to the cent; with several cars, **Use these terms for every car** copies the first car''s numbers to the others.
3. Choose the invoices: First and last month, Registration fee (any exact amount), Tracker install (only once trackers are available) and Another invoice. For each one choose Send now, Save as draft or Already paid. Already paid asks how (e-Transfer, cash, cheque, bank transfer or other), the date and the reference: it is recorded like Record payment and the owner gets the receipt, not an invoice.
4. Press **Approve** at the bottom of the step. Nothing is set or sent before that. The owner becomes active, the documents open for one signature in their portal, only the invoices you chose are made, and the owner gets one email.
5. Missing something? Press **Ask for something**, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press **Send to the owner**. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.
6. Not a fit? Press **Decline**, write the Reason the owner reads, and press **Decline the application**. The owner is emailed for each car.

![](/guides/img/admin-34-application-desktop-98b64f92.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/applications/c324ef8d-ad00-4bcc-bf04-ca68628a26b4; pins: 1 72.9 67.1, 2 73.9 42.9, 3 84.7 42.9, 4 72.9 49.6")

The application has an Invoices tab: every invoice of its cars, drafts and voids included. An application staff entered for the owner says "Entered by staff" and who; approving it sends the owner the set-up email (review the details and sign) instead of the approval email.

> Tip: Notes on the page are for staff only: **Add note** keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.

## Add a car for an owner

**People** > **Add a car for an owner**, or **Add another car** on an owner''s page. The owner never has to fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line (Edit if something is wrong); no VIN at hand, add it by its plate with the year, make and model from the lists. Tap the colour, check the class, then the odometer, insurer and whether it is owned, financed or leased. Photos are optional: the listing shows sample photos until real ones are added. Upload the ownership permit, the insurance slip and the lender''s information if you have them.
3. Terms and first invoice: the same fields as Approve. For another car of the same owner they start from that owner''s terms, or their other car''s; change them for this car.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner (only then are you recorded as the one who brought the owner). How the owner signs: by email, or on paper.
5. Press **Add the car and set it up**. The owner gets one email: review the details, correct anything, and sign. An owner with no sign-in gets the link to choose a password in that same email.

Customer service and fleet assistants add cars the same way from their portal; theirs wait in Applications for you, with the terms and invoices they proposed already filled in. On an approved application staff entered, **Send the set-up email again** sends the owner the email with a fresh link.

## Owners

**People** > **Owners**. Every owner, with their cars and where onboarding stands.

1. Each owner shows their application, how many cars, and where onboarding stands.
2. **View as (owner portal)** shows their portal. **Send password link** helps them sign in.
3. Invite an owner on file: fill in Name and Email under Invite an owner, then press **Send invitation**.

![](/guides/img/admin-12-owners-desktop-3a54d505.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/owners; pins: 1 41.0 42.9, 2 37.4 49.3, 3 77.4 82.5")

The owner signs everything at once in their portal (Check and sign: the agreements, schedules and Forms A and B; the official registry forms are printed and signed in ink). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer''s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.

## Mark a car insured (Insurer confirmed)

A program owner''s car is handed over to a renter only once the insurer confirms in writing that it is on the fleet policy. Requests, offers and payment never wait for it.

1. Each car waiting for the insurer is a line on To do: "Insurer has not confirmed : mark it insured". It says Now when a booking picks the car up soon.
2. When the insurer''s email arrives, press **Mark insured**. The date is today; change it to the date of the insurer''s email if it was earlier. Add its subject as the Reference if you like, and press **Insurer confirmed**.
3. One email for several cars? Press **Mark several insured** on the line " cars wait for the insurer". Every waiting car is ticked: untick any car the insurer did not name, check the date, and confirm them all at once.
4. The same button is on the car: Overview (**Insurer confirmed**) and the Listing tab''s checklist, item "Not on the fleet insurance policy yet".

The car is then on the fleet policy from that date: it can be handed over, its Enrollment Date is that date, its fee terms start, and the owner gets the email "Written confirmation: your car is on the fleet policy". Its paperwork (agreements, registry visit, tracker) stays on its checklist until done. A car already listed and Available stays Available.

## Owners who paid another way, and the terms you agreed

Two lines on To do keep an owner''s money right without opening their page.

1. "Record the first and last month paid by ": their first and last month invoice was voided and nothing paid is recorded. Press **Record what they paid**, type the amount for each car (tax included), or one total for several cars, how and when it was paid and the reference. A draft first and last month invoice is kept or voided, your choice. Each car''s invoice is then marked paid, the owner gets the receipt and the two prepaid months count. Never for a shareholder.
2. "Enter the terms agreed with ": their cars still use the standard grid. Press **Enter the terms**: the Management fee (Revenue Share), the Insurance Fee, the Tracker Fee, the Install Fee and the first and last month are filled in from the grid. Type what you agreed for the owner, and open a car to give it its own. A car whose schedule is signed gets an updated schedule for the owner to sign.
3. Nothing to change? Press **Not needed** or **These are correct**: the line does not come back.

## A shareholder''s own car

On the owner''s page, each car has **Shareholder’s own car**.

1. A shareholder''s own car is split 90/10 (the share in Program settings) and pays no Insurance Fee, Tracker Fee, first and last month or tracker install.
2. Press **Shareholder’s own car**, say why (it is kept in the audit log) and confirm. Press it again to undo. Bookings already made keep their split.
3. A first and last month or a tracker install invoice is refused for such a car, from any screen.

## Cancellation refunds

**Settings** > **Program**: the refund for each cancellation tier.

| When the renter cancels | Refund (default) |
| --- | --- |
| Within 24 hours of booking, 48 hours or more before the start | 95% |
| 48 hours or more before the start | 75% |
| 24 to 48 hours before the start | 50% |
| Under 24 hours, or after the start | 0% |

## An owner''s page

Open an owner from Owners. Three tabs: Overview, Terms and Invoices. **Add another car** and **New invoice** sit under the name.

1. Cars and terms, at the top: each car''s Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and mode, with **Edit** and History (see An owner''s terms, car by car).
2. Upfront invoices: issue the first and last month amount agreed on each car''s terms, for each car whose terms are set.
3. Owner: address, sign-in, agreements, and what is still missing for the registry forms.
4. Statements and payouts for this owner.
5. Forms C and D, with a link to the review queue.
6. Further down: **View as (owner portal)**, **Send password link** and **Send a sign-in link to the owner portal**.

![](/guides/img/admin-13-owner-desktop-819a9f8b.jpg "desktop; size: 410 1030; address: carmacars.ca/admin/owners/50a834dc-270a-4c26-b79e-6396fa7bf2e1; pins: 1 24.6 4.4, 2 16.1 32.9, 3 31.5 73.2, 4 21.2 98.1")

## An owner''s terms, car by car

The table Cars and terms, at the top of an owner''s page and its Terms tab: each car''s Insurance Fee and Tracker Fee a month, management fee (Revenue Share), Install Fee and Management Mode, and since when they apply.

1. Press **Edit** on a car''s row. The row becomes fields: type the exact amounts (to the cent; the management fee in %). Before the Vehicle Schedule is signed you can also change the Install Fee, the Management Mode and the Onboarding Method.
2. Press **Review**. It lists each value before and after, and what happens to each one. Nothing is saved yet.
3. Not signed yet (or not approved yet): **Save** applies the numbers at once. An unsigned Vehicle Schedule is made again with them, so the owner signs these numbers; a car not approved yet keeps them for the Approve step.
4. Signed: a lower amount is in force from today, or the date you choose under Lower amounts from. No notice period is needed because it only lowers what the owner pays. A lower management fee does this while Settings > Program, Lower management % without owner signature, is on (the default); off, the owner signs an updated Vehicle Schedule first.
5. Signed: a higher Insurance Fee or Tracker Fee needs 30 days'' written notice (Enrollment Agreement 4.8). Choose the date under Higher amounts from (30 days ahead at the earliest) and write the Reason: the owner reads it.
6. Signed: a higher management fee (Revenue Share) needs the same notice and the owner''s signature. The owner is emailed the notice and an updated Vehicle Schedule to sign; it applies from the date once signed, or from the day they sign if that is later. Higher fees in the same change apply from the date by the notice either way.
7. Press **Confirm**. The owner is emailed the written notice, which is also a PDF in their portal and in the car''s History.

History, under each car, lists every period of terms (from, to, the amounts, and why: the Vehicle Schedule, a written notice, lowered) and every change with its notice. A change that has not started yet has Cancel (give the reason): the terms before it run on. An updated schedule waiting for the owner has Record signed on paper (with the date) and Withdraw it. One change at a time: cancel or finish the one waiting before making the next.

The same editor is on the car''s page (Records tab, Owner terms). The owner''s default terms (for cars whose terms are set later) and the first and last month invoice stay on the Terms tab.

> Good to know: Invoices follow the dates: a month whose Insurance Fee or Tracker Fee changes part way is billed per day at each rate. The Revenue Share of a rental is the one in force on the day it is booked.

## Change a signed car''s Management Mode

Managed, Self-Managed or Turo-Only, from a date, for a car whose Vehicle Schedule is signed. An Admin only.

1. Open the owner''s Cars and terms table (or the car''s page) and press **Change mode** on the car''s row.
2. Choose the **New Management Mode** and its Onboarding Method (the options that fit how the car is held), the date under **From**, and write the Reason: the owner reads it. Tick **The owner asked for this** only when it is their own request.
3. Press **Review**: it lists each value before and after (a Self-Managed car has no management fee; a Turo-Only car has no Fees and leaves the fleet insurance policy) and says whether the owner has to sign. Nothing is saved yet.
4. The owner asked and no amount goes up: no signature and no notice period. From today (or the date you chose) the car has the new mode, an updated Vehicle Schedule is issued with CarmaCars'' signature and the owner is emailed the notice.
5. Anything else (CarmaCars'' own decision, or a higher fee): the owner is emailed the notice and an updated Vehicle Schedule to sign, the date is at least 30 days away and the car stays as it is until it is signed. In History, **Record signed on paper** or **Withdraw it**.
6. A change dated ahead applies by itself on its date: the schedule is issued and the car moves. **Cancel** in History (give the reason) stops it and emails the owner that their terms stay as they are. The same email goes when a notice of a higher fee is cancelled.

> Good to know: A shareholder-owned car has fixed terms. A car whose schedule is not signed yet changes its mode in the terms editor, where it applies at once.

## Paid and signed

**People** > **Paid and signed**. What each owner still has to pay or sign, and how each item was done.

1. Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.
2. Open **Checklist and quick actions**. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.
3. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment**. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.
4. Signed on paper? Press **Record paper signature**. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.
5. The same checklist sits at the top of each owner''s page.
6. You rarely need to come here: an upfront or overdue owner invoice is a line on To do with **Record payment**, and an owner whose documents were sent two days ago or more and are not signed is a line with **Record paper signature**. Both pop-ups are the same forms, filled in.

A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows "Paid by e-Transfer on " in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner''s documents.

> Watch out: Recorded the wrong thing, or a cheque bounced? Press **Void** beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.

## Forms C and D

**People** > **Owner forms**. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.

1. Each row shows the owner, the form, the witnesses and when it was uploaded.
2. Press Open to read the photo or scan. Check each marked spot is signed or initialled.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg "desktop; size: 1440 470; address: carmacars.ca/admin/owner-forms; pins: 1 29.2 52.3, 2 57.6 52.3, 3 76.7 52.3")
', 'Owners and onboarding', 'Applications, the terms and first invoice, adding a car for an owner, an owner''s terms and invoices, paid and signed, and Forms C and D.',
  'Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.

## Applications

**People** > **Applications**. Every owner application, newest first.

1. The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.
2. Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.
3. Open an application to decide.

![](/guides/img/admin-33-applications-desktop-152f9e34.jpg "desktop; size: 1440 640; address: carmacars.ca/admin/applications; pins: 1 36.8 39.7, 2 48.6 53.1, 3 19.8 53.1")

## Decide on an application

One page holds everything: the owner, the car, the uploads, the four checks and the notes.

1. Check the driver''s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.
2. Press **Approve**. The step "Terms and first invoice" opens for each car, filled in with the owner''s negotiated terms (or the standard grid): Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and the first and last month amount (2 x the Insurance Fee unless you type an exact amount). Change any of them to the cent; with several cars, **Use these terms for every car** copies the first car''s numbers to the others.
3. Choose the invoices: First and last month, Registration fee (any exact amount), Tracker install (only once trackers are available) and Another invoice. For each one choose Send now, Save as draft or Already paid. Already paid asks how (e-Transfer, cash, cheque, bank transfer or other), the date and the reference: it is recorded like Record payment and the owner gets the receipt, not an invoice.
4. Press **Approve** at the bottom of the step. Nothing is set or sent before that. The owner becomes active, the documents open for one signature in their portal, only the invoices you chose are made, and the owner gets one email.
5. Missing something? Press **Ask for something**, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press **Send to the owner**. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.
6. Not a fit? Press **Decline**, write the Reason the owner reads, and press **Decline the application**. The owner is emailed for each car.

![](/guides/img/admin-34-application-desktop-98b64f92.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/applications/c324ef8d-ad00-4bcc-bf04-ca68628a26b4; pins: 1 72.9 67.1, 2 73.9 42.9, 3 84.7 42.9, 4 72.9 49.6")

The application has an Invoices tab: every invoice of its cars, drafts and voids included. An application staff entered for the owner says "Entered by staff" and who; approving it sends the owner the set-up email (review the details and sign) instead of the approval email.

> Tip: Notes on the page are for staff only: **Add note** keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.

## Add a car for an owner

**People** > **Add a car for an owner**, or **Add another car** on an owner''s page. The owner never has to fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line (Edit if something is wrong); no VIN at hand, add it by its plate with the year, make and model from the lists. Tap the colour, check the class, then the odometer, insurer and whether it is owned, financed or leased. Photos are optional: the listing shows sample photos until real ones are added. Upload the ownership permit, the insurance slip and the lender''s information if you have them.
3. Terms and first invoice: the same fields as Approve. For another car of the same owner they start from that owner''s terms, or their other car''s; change them for this car.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner (only then are you recorded as the one who brought the owner). How the owner signs: by email, or on paper.
5. Press **Add the car and set it up**. The owner gets one email: review the details, correct anything, and sign. An owner with no sign-in gets the link to choose a password in that same email.

Customer service and fleet assistants add cars the same way from their portal; theirs wait in Applications for you, with the terms and invoices they proposed already filled in. On an approved application staff entered, **Send the set-up email again** sends the owner the email with a fresh link.

## Owners

**People** > **Owners**. Every owner, with their cars and where onboarding stands.

1. Each owner shows their application, how many cars, and where onboarding stands.
2. **View as (owner portal)** shows their portal. **Send password link** helps them sign in.
3. Invite an owner on file: fill in Name and Email under Invite an owner, then press **Send invitation**.

![](/guides/img/admin-12-owners-desktop-3a54d505.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/owners; pins: 1 41.0 42.9, 2 37.4 49.3, 3 77.4 82.5")

The owner signs everything at once in their portal (Check and sign: the agreements, schedules and Forms A and B; the official registry forms are printed and signed in ink). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer''s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.

## Mark a car insured (Insurer confirmed)

A program owner''s car is handed over to a renter only once the insurer confirms in writing that it is on the fleet policy. Requests, offers and payment never wait for it.

1. Each car waiting for the insurer is a line on To do: "Insurer has not confirmed : mark it insured". It says Now when a booking picks the car up soon.
2. When the insurer''s email arrives, press **Mark insured**. The date is today; change it to the date of the insurer''s email if it was earlier. Add its subject as the Reference if you like, and press **Insurer confirmed**.
3. One email for several cars? Press **Mark several insured** on the line " cars wait for the insurer". Every waiting car is ticked: untick any car the insurer did not name, check the date, and confirm them all at once.
4. The same button is on the car: Overview (**Insurer confirmed**) and the Listing tab''s checklist, item "Not on the fleet insurance policy yet".

The car is then on the fleet policy from that date: it can be handed over, its Enrollment Date is that date, its fee terms start, and the owner gets the email "Written confirmation: your car is on the fleet policy". Its paperwork (agreements, registry visit, tracker) stays on its checklist until done. A car already listed and Available stays Available.

## Owners who paid another way, and the terms you agreed

Two lines on To do keep an owner''s money right without opening their page.

1. "Record the first and last month paid by ": their first and last month invoice was voided and nothing paid is recorded. Press **Record what they paid**, type the amount for each car (tax included), or one total for several cars, how and when it was paid and the reference. A draft first and last month invoice is kept or voided, your choice. Each car''s invoice is then marked paid, the owner gets the receipt and the two prepaid months count. Never for a shareholder.
2. "Enter the terms agreed with ": their cars still use the standard grid. Press **Enter the terms**: the Management fee (Revenue Share), the Insurance Fee, the Tracker Fee, the Install Fee and the first and last month are filled in from the grid. Type what you agreed for the owner, and open a car to give it its own. A car whose schedule is signed gets an updated schedule for the owner to sign.
3. Nothing to change? Press **Not needed** or **These are correct**: the line does not come back.

## A shareholder''s own car

On the owner''s page, each car has **Shareholder’s own car**.

1. A shareholder''s own car is split 90/10 (the share in Program settings) and pays no Insurance Fee, Tracker Fee, first and last month or tracker install.
2. Press **Shareholder’s own car**, say why (it is kept in the audit log) and confirm. Press it again to undo. Bookings already made keep their split.
3. A first and last month or a tracker install invoice is refused for such a car, from any screen.

## Cancellation refunds

**Settings** > **Program**: the refund for each cancellation tier.

| When the renter cancels | Refund (default) |
| --- | --- |
| Within 24 hours of booking, 48 hours or more before the start | 95% |
| 48 hours or more before the start | 75% |
| 24 to 48 hours before the start | 50% |
| Under 24 hours, or after the start | 0% |

## An owner''s page

Open an owner from Owners. Three tabs: Overview, Terms and Invoices. **Add another car** and **New invoice** sit under the name.

1. Cars and terms, at the top: each car''s Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and mode, with **Edit** and History (see An owner''s terms, car by car).
2. Upfront invoices: issue the first and last month amount agreed on each car''s terms, for each car whose terms are set.
3. Owner: address, sign-in, agreements, and what is still missing for the registry forms.
4. Statements and payouts for this owner.
5. Forms C and D, with a link to the review queue.
6. Further down: **View as (owner portal)**, **Send password link** and **Send a sign-in link to the owner portal**.

![](/guides/img/admin-13-owner-desktop-819a9f8b.jpg "desktop; size: 410 1030; address: carmacars.ca/admin/owners/50a834dc-270a-4c26-b79e-6396fa7bf2e1; pins: 1 24.6 4.4, 2 16.1 32.9, 3 31.5 73.2, 4 21.2 98.1")

## An owner''s terms, car by car

The table Cars and terms, at the top of an owner''s page and its Terms tab: each car''s Insurance Fee and Tracker Fee a month, management fee (Revenue Share), Install Fee and Management Mode, and since when they apply.

1. Press **Edit** on a car''s row. The row becomes fields: type the exact amounts (to the cent; the management fee in %). Before the Vehicle Schedule is signed you can also change the Install Fee, the Management Mode and the Onboarding Method.
2. Press **Review**. It lists each value before and after, and what happens to each one. Nothing is saved yet.
3. Not signed yet (or not approved yet): **Save** applies the numbers at once. An unsigned Vehicle Schedule is made again with them, so the owner signs these numbers; a car not approved yet keeps them for the Approve step.
4. Signed: a lower amount is in force from today, or the date you choose under Lower amounts from. No notice period is needed because it only lowers what the owner pays. A lower management fee does this while Settings > Program, Lower management % without owner signature, is on (the default); off, the owner signs an updated Vehicle Schedule first.
5. Signed: a higher Insurance Fee or Tracker Fee needs 30 days'' written notice (Enrollment Agreement 4.8). Choose the date under Higher amounts from (30 days ahead at the earliest) and write the Reason: the owner reads it.
6. Signed: a higher management fee (Revenue Share) needs the same notice and the owner''s signature. The owner is emailed the notice and an updated Vehicle Schedule to sign; it applies from the date once signed, or from the day they sign if that is later. Higher fees in the same change apply from the date by the notice either way.
7. Press **Confirm**. The owner is emailed the written notice, which is also a PDF in their portal and in the car''s History.

History, under each car, lists every period of terms (from, to, the amounts, and why: the Vehicle Schedule, a written notice, lowered) and every change with its notice. A change that has not started yet has Cancel (give the reason): the terms before it run on. An updated schedule waiting for the owner has Record signed on paper (with the date) and Withdraw it. One change at a time: cancel or finish the one waiting before making the next.

The same editor is on the car''s page (Records tab, Owner terms). The owner''s default terms (for cars whose terms are set later) and the first and last month invoice stay on the Terms tab.

> Good to know: Invoices follow the dates: a month whose Insurance Fee or Tracker Fee changes part way is billed per day at each rate. The Revenue Share of a rental is the one in force on the day it is booked.

## Pay an owner a flat monthly amount

Some owners want the same amount every month for a car instead of a revenue share and fees. An Admin only, car by car.

1. Open the owner''s Cars and terms table (or the car''s page) and press **Pay** on the car''s row.
2. Choose **Flat monthly payment**, type the **Amount a month** (for example 900.00), the date under **From** and, if it ends, the **Last day**. Write the Reason (kept in the history).
3. Press **Review**: it says what happens and lists any monthly invoice already issued for those days. Then press **Confirm**.
4. From that date the owner''s statement pays the amount every month (a part month by the day), with no revenue share and no Insurance Fee or Tracker Fee. Rentals ending on those days stay with CarmaCars, in the company figures.
5. Back to revenue share: press **Pay**, choose Revenue share and the date. The flat period ends the day before; every period stays in the list.

> Good to know: A month already on an approved owner statement never changes: a new date starts after it. A monthly invoice already issued for flat days stays: void or credit it. A booking expense on a flat car is CarmaCars'' own unless you press **Charge to the owner** beside it on the booking (an Admin only): it is then an owner cost on their statement. Owner costs recorded on the owner''s account (tickets, tolls, damage of their own use) are charged as before.

## Change a signed car''s Management Mode

Managed, Self-Managed or Turo-Only, from a date, for a car whose Vehicle Schedule is signed. An Admin only.

1. Open the owner''s Cars and terms table (or the car''s page) and press **Change mode** on the car''s row.
2. Choose the **New Management Mode** and its Onboarding Method (the options that fit how the car is held), the date under **From**, and write the Reason: the owner reads it. Tick **The owner asked for this** only when it is their own request.
3. Press **Review**: it lists each value before and after (a Self-Managed car has no management fee; a Turo-Only car has no Fees and leaves the fleet insurance policy) and says whether the owner has to sign. Nothing is saved yet.
4. The owner asked and no amount goes up: no signature and no notice period. From today (or the date you chose) the car has the new mode, an updated Vehicle Schedule is issued with CarmaCars'' signature and the owner is emailed the notice.
5. Anything else (CarmaCars'' own decision, or a higher fee): the owner is emailed the notice and an updated Vehicle Schedule to sign, the date is at least 30 days away and the car stays as it is until it is signed. In History, **Record signed on paper** or **Withdraw it**.
6. A change dated ahead applies by itself on its date: the schedule is issued and the car moves. **Cancel** in History (give the reason) stops it and emails the owner that their terms stay as they are. The same email goes when a notice of a higher fee is cancelled.

> Good to know: A shareholder-owned car has fixed terms. A car whose schedule is not signed yet changes its mode in the terms editor, where it applies at once.

## Paid and signed

**People** > **Paid and signed**. What each owner still has to pay or sign, and how each item was done.

1. Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.
2. Open **Checklist and quick actions**. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.
3. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment**. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.
4. Signed on paper? Press **Record paper signature**. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.
5. The same checklist sits at the top of each owner''s page.
6. You rarely need to come here: an upfront or overdue owner invoice is a line on To do with **Record payment**, and an owner whose documents were sent two days ago or more and are not signed is a line with **Record paper signature**. Both pop-ups are the same forms, filled in.

A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows "Paid by e-Transfer on " in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner''s documents.

> Watch out: Recorded the wrong thing, or a cheque bounced? Press **Void** beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.

## Forms C and D

**People** > **Owner forms**. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.

1. Each row shows the owner, the form, the witnesses and when it was uploaded.
2. Press Open to read the photo or scan. Check each marked spot is signed or initialled.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg "desktop; size: 1440 470; address: carmacars.ca/admin/owner-forms; pins: 1 29.2 52.3, 2 57.6 52.3, 3 76.7 52.3")
',
  '<p class="gd-p">Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.</p><section class="gd-task" id="owners-and-onboarding-applications" data-gd-task><h2 class="gd-h2">Applications</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Applications</b>. Every owner application, newest first.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open an application to decide.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/applications</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/admin-33-applications-desktop-152f9e34.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:36.8%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:48.6%;top:53.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:19.8%;top:53.1%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="owners-and-onboarding-decide-on-an-application" data-gd-task><h2 class="gd-h2">Decide on an application</h2><p class="gd-p">One page holds everything: the owner, the car, the uploads, the four checks and the notes.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Check the driver&#39;s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Approve</b>. The step &quot;Terms and first invoice&quot; opens for each car, filled in with the owner&#39;s negotiated terms (or the standard grid): Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and the first and last month amount (2 x the Insurance Fee unless you type an exact amount). Change any of them to the cent; with several cars, <b class="gd-ui">Use these terms for every car</b> copies the first car&#39;s numbers to the others.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose the invoices: First and last month, Registration fee (any exact amount), Tracker install (only once trackers are available) and Another invoice. For each one choose Send now, Save as draft or Already paid. Already paid asks how (e-Transfer, cash, cheque, bank transfer or other), the date and the reference: it is recorded like Record payment and the owner gets the receipt, not an invoice.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Approve</b> at the bottom of the step. Nothing is set or sent before that. The owner becomes active, the documents open for one signature in their portal, only the invoices you chose are made, and the owner gets one email.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Missing something? Press <b class="gd-ui">Ask for something</b>, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press <b class="gd-ui">Send to the owner</b>. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Not a fit? Press <b class="gd-ui">Decline</b>, write the Reason the owner reads, and press <b class="gd-ui">Decline the application</b>. The owner is emailed for each car.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/applications/c324ef8d-ad00-4bcc-bf04-ca68628a26b4</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/812"><img src="/guides/img/admin-34-application-desktop-98b64f92.jpg" alt="" loading="lazy" decoding="async" width="1440" height="812"><span class="gd-pin" style="left:72.9%;top:67.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:73.9%;top:42.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:84.7%;top:42.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:72.9%;top:49.6%" aria-hidden="true">4</span></div></div></figure></div><p class="gd-p">The application has an Invoices tab: every invoice of its cars, drafts and voids included. An application staff entered for the owner says &quot;Entered by staff&quot; and who; approving it sends the owner the set-up email (review the details and sign) instead of the approval email.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Notes on the page are for staff only: <b class="gd-ui">Add note</b> keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.</div></aside></section><section class="gd-task" id="owners-and-onboarding-add-a-car-for-an-owner" data-gd-task><h2 class="gd-h2">Add a car for an owner</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Add a car for an owner</b>, or <b class="gd-ui">Add another car</b> on an owner&#39;s page. The owner never has to fill in the application.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car: type the VIN. The car is looked up at once and shown in one line (Edit if something is wrong); no VIN at hand, add it by its plate with the year, make and model from the lists. Tap the colour, check the class, then the odometer, insurer and whether it is owned, financed or leased. Photos are optional: the listing shows sample photos until real ones are added. Upload the ownership permit, the insurance slip and the lender&#39;s information if you have them.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Terms and first invoice: the same fields as Approve. For another car of the same owner they start from that owner&#39;s terms, or their other car&#39;s; change them for this car.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Who sourced the owner: Entered for CarmaCars, or I sourced this owner (only then are you recorded as the one who brought the owner). How the owner signs: by email, or on paper.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Add the car and set it up</b>. The owner gets one email: review the details, correct anything, and sign. An owner with no sign-in gets the link to choose a password in that same email.</div></li></ol></div><p class="gd-p">Customer service and fleet assistants add cars the same way from their portal; theirs wait in Applications for you, with the terms and invoices they proposed already filled in. On an approved application staff entered, <b class="gd-ui">Send the set-up email again</b> sends the owner the email with a fresh link.</p></section><section class="gd-task" id="owners-and-onboarding-owners" data-gd-task><h2 class="gd-h2">Owners</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Owners</b>. Every owner, with their cars and where onboarding stands.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each owner shows their application, how many cars, and where onboarding stands.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">View as (owner portal)</b> shows their portal. <b class="gd-ui">Send password link</b> helps them sign in.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Invite an owner on file: fill in Name and Email under Invite an owner, then press <b class="gd-ui">Send invitation</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owners</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-12-owners-desktop-3a54d505.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:41%;top:42.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:37.4%;top:49.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:82.5%" aria-hidden="true">3</span></div></div></figure></div><p class="gd-p">The owner signs everything at once in their portal (Check and sign: the agreements, schedules and Forms A and B; the official registry forms are printed and signed in ink). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer&#39;s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.</p></section><section class="gd-task" id="owners-and-onboarding-mark-a-car-insured-insurer-confirmed" data-gd-task><h2 class="gd-h2">Mark a car insured (Insurer confirmed)</h2><p class="gd-p">A program owner&#39;s car is handed over to a renter only once the insurer confirms in writing that it is on the fleet policy. Requests, offers and payment never wait for it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each car waiting for the insurer is a line on To do: &quot;Insurer has not confirmed : mark it insured&quot;. It says Now when a booking picks the car up soon.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">When the insurer&#39;s email arrives, press <b class="gd-ui">Mark insured</b>. The date is today; change it to the date of the insurer&#39;s email if it was earlier. Add its subject as the Reference if you like, and press <b class="gd-ui">Insurer confirmed</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">One email for several cars? Press <b class="gd-ui">Mark several insured</b> on the line &quot; cars wait for the insurer&quot;. Every waiting car is ticked: untick any car the insurer did not name, check the date, and confirm them all at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The same button is on the car: Overview (<b class="gd-ui">Insurer confirmed</b>) and the Listing tab&#39;s checklist, item &quot;Not on the fleet insurance policy yet&quot;.</div></li></ol></div><p class="gd-p">The car is then on the fleet policy from that date: it can be handed over, its Enrollment Date is that date, its fee terms start, and the owner gets the email &quot;Written confirmation: your car is on the fleet policy&quot;. Its paperwork (agreements, registry visit, tracker) stays on its checklist until done. A car already listed and Available stays Available.</p></section><section class="gd-task" id="owners-and-onboarding-owners-who-paid-another-way-and-the-terms-you-agreed" data-gd-task><h2 class="gd-h2">Owners who paid another way, and the terms you agreed</h2><p class="gd-p">Two lines on To do keep an owner&#39;s money right without opening their page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">&quot;Record the first and last month paid by &quot;: their first and last month invoice was voided and nothing paid is recorded. Press <b class="gd-ui">Record what they paid</b>, type the amount for each car (tax included), or one total for several cars, how and when it was paid and the reference. A draft first and last month invoice is kept or voided, your choice. Each car&#39;s invoice is then marked paid, the owner gets the receipt and the two prepaid months count. Never for a shareholder.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">&quot;Enter the terms agreed with &quot;: their cars still use the standard grid. Press <b class="gd-ui">Enter the terms</b>: the Management fee (Revenue Share), the Insurance Fee, the Tracker Fee, the Install Fee and the first and last month are filled in from the grid. Type what you agreed for the owner, and open a car to give it its own. A car whose schedule is signed gets an updated schedule for the owner to sign.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Nothing to change? Press <b class="gd-ui">Not needed</b> or <b class="gd-ui">These are correct</b>: the line does not come back.</div></li></ol></div></section><section class="gd-task" id="owners-and-onboarding-a-shareholder-s-own-car" data-gd-task><h2 class="gd-h2">A shareholder&#39;s own car</h2><p class="gd-p">On the owner&#39;s page, each car has <b class="gd-ui">Shareholder’s own car</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A shareholder&#39;s own car is split 90/10 (the share in Program settings) and pays no Insurance Fee, Tracker Fee, first and last month or tracker install.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Shareholder’s own car</b>, say why (it is kept in the audit log) and confirm. Press it again to undo. Bookings already made keep their split.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A first and last month or a tracker install invoice is refused for such a car, from any screen.</div></li></ol></div></section><section class="gd-task" id="owners-and-onboarding-cancellation-refunds" data-gd-task><h2 class="gd-h2">Cancellation refunds</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>: the refund for each cancellation tier.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">When the renter cancels</th><th scope="col">Refund (default)</th></tr></thead><tbody><tr><td>Within 24 hours of booking, 48 hours or more before the start</td><td>95%</td></tr><tr><td>48 hours or more before the start</td><td>75%</td></tr><tr><td>24 to 48 hours before the start</td><td>50%</td></tr><tr><td>Under 24 hours, or after the start</td><td>0%</td></tr></tbody></table></div></section><section class="gd-task" id="owners-and-onboarding-an-owner-s-page" data-gd-task><h2 class="gd-h2">An owner&#39;s page</h2><p class="gd-p">Open an owner from Owners. Three tabs: Overview, Terms and Invoices. <b class="gd-ui">Add another car</b> and <b class="gd-ui">New invoice</b> sit under the name.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Cars and terms, at the top: each car&#39;s Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and mode, with <b class="gd-ui">Edit</b> and History (see An owner&#39;s terms, car by car).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Upfront invoices: issue the first and last month amount agreed on each car&#39;s terms, for each car whose terms are set.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Owner: address, sign-in, agreements, and what is still missing for the registry forms.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Statements and payouts for this owner.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Forms C and D, with a link to the review queue.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Further down: <b class="gd-ui">View as (owner portal)</b>, <b class="gd-ui">Send password link</b> and <b class="gd-ui">Send a sign-in link to the owner portal</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owners/50a834dc-270a-4c26-b79e-6396fa7bf2e1</span></div><div class="gd-imgwrap" style="aspect-ratio:410/1030"><img src="/guides/img/admin-13-owner-desktop-819a9f8b.jpg" alt="" loading="lazy" decoding="async" width="410" height="1030"><span class="gd-pin" style="left:24.6%;top:4.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:16.1%;top:32.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:31.5%;top:73.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:21.2%;top:98.1%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="owners-and-onboarding-an-owner-s-terms-car-by-car" data-gd-task><h2 class="gd-h2">An owner&#39;s terms, car by car</h2><p class="gd-p">The table Cars and terms, at the top of an owner&#39;s page and its Terms tab: each car&#39;s Insurance Fee and Tracker Fee a month, management fee (Revenue Share), Install Fee and Management Mode, and since when they apply.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Edit</b> on a car&#39;s row. The row becomes fields: type the exact amounts (to the cent; the management fee in %). Before the Vehicle Schedule is signed you can also change the Install Fee, the Management Mode and the Onboarding Method.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Review</b>. It lists each value before and after, and what happens to each one. Nothing is saved yet.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not signed yet (or not approved yet): <b class="gd-ui">Save</b> applies the numbers at once. An unsigned Vehicle Schedule is made again with them, so the owner signs these numbers; a car not approved yet keeps them for the Approve step.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Signed: a lower amount is in force from today, or the date you choose under Lower amounts from. No notice period is needed because it only lowers what the owner pays. A lower management fee does this while Settings &gt; Program, Lower management % without owner signature, is on (the default); off, the owner signs an updated Vehicle Schedule first.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Signed: a higher Insurance Fee or Tracker Fee needs 30 days&#39; written notice (Enrollment Agreement 4.8). Choose the date under Higher amounts from (30 days ahead at the earliest) and write the Reason: the owner reads it.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Signed: a higher management fee (Revenue Share) needs the same notice and the owner&#39;s signature. The owner is emailed the notice and an updated Vehicle Schedule to sign; it applies from the date once signed, or from the day they sign if that is later. Higher fees in the same change apply from the date by the notice either way.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Press <b class="gd-ui">Confirm</b>. The owner is emailed the written notice, which is also a PDF in their portal and in the car&#39;s History.</div></li></ol></div><p class="gd-p">History, under each car, lists every period of terms (from, to, the amounts, and why: the Vehicle Schedule, a written notice, lowered) and every change with its notice. A change that has not started yet has Cancel (give the reason): the terms before it run on. An updated schedule waiting for the owner has Record signed on paper (with the date) and Withdraw it. One change at a time: cancel or finish the one waiting before making the next.</p><p class="gd-p">The same editor is on the car&#39;s page (Records tab, Owner terms). The owner&#39;s default terms (for cars whose terms are set later) and the first and last month invoice stay on the Terms tab.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Invoices follow the dates: a month whose Insurance Fee or Tracker Fee changes part way is billed per day at each rate. The Revenue Share of a rental is the one in force on the day it is booked.</div></aside></section><section class="gd-task" id="owners-and-onboarding-pay-an-owner-a-flat-monthly-amount" data-gd-task><h2 class="gd-h2">Pay an owner a flat monthly amount</h2><p class="gd-p">Some owners want the same amount every month for a car instead of a revenue share and fees. An Admin only, car by car.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the owner&#39;s Cars and terms table (or the car&#39;s page) and press <b class="gd-ui">Pay</b> on the car&#39;s row.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose <b class="gd-ui">Flat monthly payment</b>, type the <b class="gd-ui">Amount a month</b> (for example 900.00), the date under <b class="gd-ui">From</b> and, if it ends, the <b class="gd-ui">Last day</b>. Write the Reason (kept in the history).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Review</b>: it says what happens and lists any monthly invoice already issued for those days. Then press <b class="gd-ui">Confirm</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">From that date the owner&#39;s statement pays the amount every month (a part month by the day), with no revenue share and no Insurance Fee or Tracker Fee. Rentals ending on those days stay with CarmaCars, in the company figures.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Back to revenue share: press <b class="gd-ui">Pay</b>, choose Revenue share and the date. The flat period ends the day before; every period stays in the list.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A month already on an approved owner statement never changes: a new date starts after it. A monthly invoice already issued for flat days stays: void or credit it. A booking expense on a flat car is CarmaCars&#39; own unless you press <b class="gd-ui">Charge to the owner</b> beside it on the booking (an Admin only): it is then an owner cost on their statement. Owner costs recorded on the owner&#39;s account (tickets, tolls, damage of their own use) are charged as before.</div></aside></section><section class="gd-task" id="owners-and-onboarding-change-a-signed-car-s-management-mode" data-gd-task><h2 class="gd-h2">Change a signed car&#39;s Management Mode</h2><p class="gd-p">Managed, Self-Managed or Turo-Only, from a date, for a car whose Vehicle Schedule is signed. An Admin only.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the owner&#39;s Cars and terms table (or the car&#39;s page) and press <b class="gd-ui">Change mode</b> on the car&#39;s row.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the <b class="gd-ui">New Management Mode</b> and its Onboarding Method (the options that fit how the car is held), the date under <b class="gd-ui">From</b>, and write the Reason: the owner reads it. Tick <b class="gd-ui">The owner asked for this</b> only when it is their own request.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Review</b>: it lists each value before and after (a Self-Managed car has no management fee; a Turo-Only car has no Fees and leaves the fleet insurance policy) and says whether the owner has to sign. Nothing is saved yet.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The owner asked and no amount goes up: no signature and no notice period. From today (or the date you chose) the car has the new mode, an updated Vehicle Schedule is issued with CarmaCars&#39; signature and the owner is emailed the notice.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Anything else (CarmaCars&#39; own decision, or a higher fee): the owner is emailed the notice and an updated Vehicle Schedule to sign, the date is at least 30 days away and the car stays as it is until it is signed. In History, <b class="gd-ui">Record signed on paper</b> or <b class="gd-ui">Withdraw it</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A change dated ahead applies by itself on its date: the schedule is issued and the car moves. <b class="gd-ui">Cancel</b> in History (give the reason) stops it and emails the owner that their terms stay as they are. The same email goes when a notice of a higher fee is cancelled.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A shareholder-owned car has fixed terms. A car whose schedule is not signed yet changes its mode in the terms editor, where it applies at once.</div></aside></section><section class="gd-task" id="owners-and-onboarding-paid-and-signed" data-gd-task><h2 class="gd-h2">Paid and signed</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Paid and signed</b>. What each owner still has to pay or sign, and how each item was done.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open <b class="gd-ui">Checklist and quick actions</b>. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Paid by e-Transfer, cheque, cash or bank transfer? Press <b class="gd-ui">Record payment</b>. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Signed on paper? Press <b class="gd-ui">Record paper signature</b>. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The same checklist sits at the top of each owner&#39;s page.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">You rarely need to come here: an upfront or overdue owner invoice is a line on To do with <b class="gd-ui">Record payment</b>, and an owner whose documents were sent two days ago or more and are not signed is a line with <b class="gd-ui">Record paper signature</b>. Both pop-ups are the same forms, filled in.</div></li></ol></div><p class="gd-p">A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows &quot;Paid by e-Transfer on &quot; in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner&#39;s documents.</p><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Recorded the wrong thing, or a cheque bounced? Press <b class="gd-ui">Void</b> beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.</div></aside></section><section class="gd-task" id="owners-and-onboarding-forms-c-and-d" data-gd-task><h2 class="gd-h2">Forms C and D</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Owner forms</b>. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each row shows the owner, the form, the witnesses and when it was uploaded.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the photo or scan. Check each marked spot is signed or initialled.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/470"><img src="/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg" alt="" loading="lazy" decoding="async" width="1440" height="470"><span class="gd-pin" style="left:29.2%;top:52.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:57.6%;top:52.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:52.3%" aria-hidden="true">3</span></div></div></figure></div></section>');
-- GUIDES 0196 END
