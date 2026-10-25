-- 0163_insurer_rate_sheet.sql
-- An insurance-replacement rate sheet per insurer and car class, with its history, and the billing history of each insurer
-- (docs/changes/2026-10-25-insurer-rate-sheet.md). The owner, October 23, 2026: "build an insurance-replacement rate sheet
-- with billing history per car class per insurance company". Example: Allstate pays $65 a day for a 2024 Jetta (sedan).
--
-- 1. The sheet: insurer_rates, one row per insurer, class (vehicle_classes, the existing list) and start date: the daily
--    rate, optional weekly and monthly caps, a delivery and pickup allowance, a kilometre limit a day and a taxes note.
--    A row is never changed or deleted: a change is a new row from a date (the history), a rate ended is a row with no
--    daily rate. The rate on a day is the row with the latest start on or before it (the latest saved, for two the same day).
-- 2. A car's rate for an insurer: its pricing class first (vehicles.class), then its other classes in the list's order;
--    the first class with a rate wins (app.insurer_rate_for).
-- 3. Bookings billed to an insurer (0016, 0148): a trigger fills the daily rate authorized from the sheet for the car's
--    class on the pickup day when none is given, keeps the row used (insurer_rate_id) and the sheet's rate
--    (insurer_sheet_daily_rate_cents). A rate typed that differs from the sheet needs a reason (insurer_rate_reason; given
--    as rate_reason with Add a rental's insurance, or insurer_rate_reason with a booking's changes on the review screen).
--    A booking added before the sheet keeps its rate; one whose insurer, car or pickup day changes follows the sheet unless
--    its rate was set by hand with a reason.
-- 4. The insurer's share (app.booking_insurer_share, 0016) applies the booking's rate (else the sheet's), the row's weekly
--    and monthly caps, and its delivery and pickup allowance: on a booking split (the insurer pays the rental only) the
--    insurer also pays delivery and pickup up to the allowance; billed wholly to the insurer, delivery and pickup above it
--    are the renter's. Without a row nothing changes. The invoice (app.draft_insurer_invoice) says the rate and where it
--    came from, keeps the rate used, and prints the taxes note.
-- 5. Admin > Insurers: the sheet as a grid (insurers by classes; cards on a phone), each insurer's page with its rates and
--    their history and the billing history by class (bookings, days authorized and used, billed, paid, outstanding, the
--    average rate, days to pay; CSV), and the booking's Insurance replacement card with its invoices.
-- No applied migration is edited.

-- ================================================================ 1. the sheet
create table if not exists insurer_rates (
  id                       uuid primary key default gen_random_uuid(),
  insurer_id               uuid not null references insurers (id),
  class_code               text not null references vehicle_classes (code) on update cascade,
  effective_from           date not null,
  daily_rate_cents         bigint check (daily_rate_cents >= 0),
  weekly_cap_cents         bigint check (weekly_cap_cents > 0),
  monthly_cap_cents        bigint check (monthly_cap_cents > 0),
  delivery_allowance_cents bigint check (delivery_allowance_cents >= 0),
  km_per_day               integer check (km_per_day >= 0),
  taxes_note               text check (taxes_note is null or length(taxes_note) <= 300),
  note                     text check (note is null or length(note) <= 500),
  created_by               uuid references users (id),
  created_at               timestamptz not null default now(),
  check (daily_rate_cents is not null or (weekly_cap_cents is null and monthly_cap_cents is null and delivery_allowance_cents is null and km_per_day is null)),
  check (weekly_cap_cents is null or weekly_cap_cents >= daily_rate_cents),
  check (monthly_cap_cents is null or monthly_cap_cents >= daily_rate_cents)
);
create index if not exists insurer_rates_lookup_idx on insurer_rates (insurer_id, class_code, effective_from desc, created_at desc);
comment on table insurer_rates is 'The insurance-replacement rate sheet (0163): what an insurer pays a day for a car of a class, from a date. Append-only: a change is a new row; a row with no daily rate ends the rate.';
comment on column insurer_rates.weekly_cap_cents is 'The most the insurer pays for 7 days (each full week; a part week costs no more than a week).';
comment on column insurer_rates.monthly_cap_cents is 'The most the insurer pays for 30 days (each full 30 days; the rest at most a month).';
comment on column insurer_rates.delivery_allowance_cents is 'Delivery and pickup the insurer pays for one rental, at most.';
comment on column insurer_rates.km_per_day is 'The kilometres a day the insurer authorizes (shown to staff; the booking keeps its own allowance).';

alter table insurer_rates enable row level security;
revoke all on insurer_rates from anon, authenticated;
grant select on insurer_rates to authenticated;
grant select, insert on insurer_rates to service_role;
drop policy if exists admin_all on insurer_rates;
create policy admin_all on insurer_rates for select to authenticated using (app.is_admin());
drop policy if exists staff_read on insurer_rates;
create policy staff_read on insurer_rates for select to authenticated using (app.is_staff());
drop trigger if exists audit_insurer_rates on insurer_rates;
create trigger audit_insurer_rates after insert on insurer_rates for each row execute function app.audit_row();

create or replace function app.insurer_rates_append_only() returns trigger
language plpgsql as $$
begin
  raise exception 'A rate on the sheet is kept as it was saved: add a new rate from a date instead' using errcode = '42501';
end $$;
drop trigger if exists insurer_rates_append_only on insurer_rates;
create trigger insurer_rates_append_only before update or delete on insurer_rates
  for each row execute function app.insurer_rates_append_only();

-- the booking keeps the row it was rated from, the sheet's rate then, and why a rate typed differs
alter table bookings add column if not exists insurer_rate_id uuid references insurer_rates (id),
  add column if not exists insurer_sheet_daily_rate_cents bigint,
  add column if not exists insurer_rate_reason text;
comment on column bookings.insurer_rate_id is 'The rate sheet row (0163) the insurer''s daily rate, caps and allowance come from, if any.';
comment on column bookings.insurer_sheet_daily_rate_cents is 'The sheet''s daily rate for this car''s class on the pickup day (0163); insurer_authorized_daily_rate_cents differs from it only with insurer_rate_reason.';
comment on column bookings.insurer_rate_reason is 'Why the daily rate authorized differs from the insurer''s rate sheet (0163).';

-- the invoice keeps the rate it was drafted with
alter table insurer_invoices add column if not exists daily_rate_cents bigint,
  add column if not exists rate_source text check (rate_source in ('sheet', 'override', 'booking', 'none')),
  add column if not exists insurer_rate_id uuid references insurer_rates (id);
comment on column insurer_invoices.rate_source is 'Where the daily rate came from (0163): sheet (the rate sheet), override (typed with a reason), booking (typed, no sheet), none (no daily rate).';

-- ================================================================ 2. the rate on a day
create or replace function app.insurer_rate_at(p_insurer uuid, p_class text, p_on date) returns insurer_rates
language sql stable security definer set search_path = public, app as $$
  select r.* from insurer_rates r
   where r.insurer_id = p_insurer and r.class_code = p_class and r.effective_from <= p_on
   order by r.effective_from desc, r.created_at desc limit 1
$$;

-- A car's rate for an insurer on a day: its pricing class first, then its other classes in the list's order.
create or replace function app.insurer_rate_for(p_insurer uuid, p_vehicle uuid, p_on date) returns insurer_rates
language plpgsql stable security definer set search_path = public, app as $$
declare
  c text;
  r insurer_rates;
begin
  if p_insurer is null or p_vehicle is null then return null; end if;
  for c in
    select x.code from (
      select v.class::text as code, 0 as k, 0 as s from vehicles v where v.id = p_vehicle
      union all
      select l.class_code, 1, vc.sort_order from vehicle_class_links l join vehicle_classes vc on vc.code = l.class_code
       where l.vehicle_id = p_vehicle and vc.is_active) x
     order by x.k, x.s, x.code
  loop
    r := app.insurer_rate_at(p_insurer, c, coalesce(p_on, app.today()));
    if r.id is not null and r.daily_rate_cents is not null then return r; end if;
  end loop;
  return null;
end $$;

-- What a daily rate comes to for p_days days under the caps: each full week at most the weekly cap (a part week no
-- more than a week), each full 30 days at most the monthly cap (the rest no more than a month), never above rate x days.
create or replace function app.insurer_rate_amount(p_daily bigint, p_weekly bigint, p_monthly bigint, p_days integer) returns bigint
language sql immutable set search_path = public, app as $$
  with w as (
    select d, case when p_weekly is null then p_daily * d else (d / 7) * p_weekly + least((d % 7) * p_daily, p_weekly) end as amount
      from (select greatest(coalesce(p_days, 0), 0) as d) x)
  select case when p_daily is null or coalesce(p_days, 0) <= 0 then 0
              when p_monthly is null then least(p_daily * p_days, (select amount from w))
              else least(p_daily * p_days,
                         (p_days / 30) * p_monthly
                         + least(case when p_weekly is null then p_daily * (p_days % 30)
                                      else ((p_days % 30) / 7) * p_weekly + least(((p_days % 30) % 7) * p_daily, p_weekly) end, p_monthly)) end
$$;

-- ================================================================ 3. bookings billed to an insurer take the sheet's rate
create or replace function app.booking_insurer_rate_trg() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  r insurer_rates;
  v_reason text := nullif(btrim(coalesce(current_setting('app.insurer_rate_reason', true), '')), '');
  v_rate_changed boolean;
  v_context_changed boolean;
begin
  if new.bill_to = 'renter' or new.insurer_id is null or new.booking_type = 'owner' then
    new.insurer_rate_id := null; new.insurer_sheet_daily_rate_cents := null;
    if new.insurer_id is null then new.insurer_rate_reason := null; end if;
    return new;
  end if;
  r := app.insurer_rate_for(new.insurer_id, new.vehicle_id, app.local_date(new.pickup_at));
  v_rate_changed := tg_op = 'INSERT' or new.insurer_authorized_daily_rate_cents is distinct from old.insurer_authorized_daily_rate_cents;
  v_context_changed := tg_op = 'UPDATE' and (new.insurer_id is distinct from old.insurer_id or new.vehicle_id is distinct from old.vehicle_id
                         or new.bill_to is distinct from old.bill_to or app.local_date(new.pickup_at) is distinct from app.local_date(old.pickup_at));
  if r.id is null then
    -- no rate on the sheet for this car: the rate is whatever staff typed
    new.insurer_rate_id := null; new.insurer_sheet_daily_rate_cents := null;
    if v_rate_changed and v_reason is not null then new.insurer_rate_reason := v_reason; end if;
    return new;
  end if;
  new.insurer_rate_id := r.id;
  new.insurer_sheet_daily_rate_cents := r.daily_rate_cents;
  if new.insurer_authorized_daily_rate_cents is null then
    new.insurer_authorized_daily_rate_cents := r.daily_rate_cents;
    new.insurer_rate_reason := null;
  elsif v_rate_changed then
    if new.insurer_authorized_daily_rate_cents = r.daily_rate_cents then
      new.insurer_rate_reason := null;
    elsif v_reason is not null then
      new.insurer_rate_reason := v_reason;
    elsif tg_op = 'UPDATE' then
      raise exception 'The daily rate authorized (%) differs from % rate sheet for % (%): give the reason for the different rate, or leave it empty to take the sheet''s',
        app.fmt_money(new.insurer_authorized_daily_rate_cents), (select i.name || '''s' from insurers i where i.id = new.insurer_id),
        (select vc.label from vehicle_classes vc where vc.code = r.class_code), app.fmt_money(r.daily_rate_cents)
        using errcode = '22023';
    end if;
  elsif v_context_changed and old.insurer_rate_reason is null
        and (old.insurer_sheet_daily_rate_cents is null or old.insurer_authorized_daily_rate_cents is not distinct from old.insurer_sheet_daily_rate_cents)
        and (old.insurer_sheet_daily_rate_cents is not null or old.insurer_id is distinct from new.insurer_id or old.bill_to = 'renter') then
    -- the rate came from the sheet (or the insurer is new on the booking): it follows the sheet for the new insurer, car or day
    new.insurer_authorized_daily_rate_cents := r.daily_rate_cents;
  end if;
  return new;
end $$;
drop trigger if exists bookings_insurer_rate on bookings;
create trigger bookings_insurer_rate before insert or update of bill_to, insurer_id, vehicle_id, pickup_at, insurer_authorized_daily_rate_cents, booking_type on bookings
  for each row execute function app.booking_insurer_rate_trg();

-- Add a rental (0148): the reason for a rate that differs from the sheet comes as rate_reason.
alter function app.manual_rental_insurance(uuid, uuid, jsonb) rename to manual_rental_insurance_pre0163;
create or replace function app.manual_rental_insurance(p_by uuid, p_booking uuid, x jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform set_config('app.insurer_rate_reason', coalesce(btrim(x ->> 'rate_reason'), ''), true);
  perform app.manual_rental_insurance_pre0163(p_by, p_booking, x);
  perform set_config('app.insurer_rate_reason', '', true);
end $$;

-- Add a rental's check (0148) also gives each insurer's rate for this car on the pickup day.
alter function app.manual_rental_quote(uuid, jsonb) rename to manual_rental_quote_pre0163;
create or replace function app.manual_rental_quote(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_out jsonb := app.manual_rental_quote_pre0163(p_by, p);
  v_vehicle uuid;
  v_on date;
begin
  begin
    v_vehicle := nullif(p ->> 'vehicle_id', '')::uuid;
    v_on := coalesce(app.local_date(nullif(p ->> 'pickup_at', '')::timestamptz), app.today());
  exception when others then
    return v_out;
  end;
  return v_out || jsonb_build_object('insurer_rates', app.insurer_rates_for_car(v_vehicle, v_on));
end $$;

-- Each active insurer's rate for a car on a day (the form's prefill).
create or replace function app.insurer_rates_for_car(p_vehicle uuid, p_on date) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('insurer_id', i.id, 'insurer_name', i.name, 'rate_id', r.id, 'class_code', r.class_code,
           'class_label', (select vc.label from vehicle_classes vc where vc.code = r.class_code), 'effective_from', r.effective_from,
           'daily_rate_cents', r.daily_rate_cents, 'weekly_cap_cents', r.weekly_cap_cents, 'monthly_cap_cents', r.monthly_cap_cents,
           'delivery_allowance_cents', r.delivery_allowance_cents, 'km_per_day', r.km_per_day, 'taxes_note', r.taxes_note) order by i.name), '[]'::jsonb)
    from insurers i cross join lateral (select * from app.insurer_rate_for(i.id, p_vehicle, p_on)) r
   where i.is_active and r.id is not null
$$;

-- ================================================================ 4. the insurer's share and its invoice
-- Replaces 0016's (same rule, same result without a sheet row): the rate is the booking's, else the sheet's; the row's
-- caps and its delivery and pickup allowance apply.
create or replace function app.booking_insurer_share(p_booking uuid)
returns table (covered_days integer, rental_share_cents bigint, fees_share_cents bigint, share_cents bigint, hst_cents bigint)
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  r insurer_rates;
  v_rental bigint; v_rental_hst bigint; v_fees bigint; v_fees_hst bigint; v_dlv bigint; v_dlv_hst bigint;
  v_days integer; v_until_days integer;
  v_rate bigint; v_dlv_cov bigint; v_dlv_cov_hst bigint;
  v_r bigint; v_f bigint; v_h bigint;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.bill_to = 'renter' or b.booking_type = 'owner' then
    return query select 0, 0::bigint, 0::bigint, 0::bigint, 0::bigint;
    return;
  end if;
  select coalesce(sum(li.amount_cents) filter (where f.family = 'rental'), 0),
         coalesce(sum(li.hst_cents) filter (where f.family = 'rental'), 0),
         coalesce(sum(li.amount_cents) filter (where f.family <> 'rental'), 0),
         coalesce(sum(li.hst_cents) filter (where f.family <> 'rental'), 0),
         coalesce(sum(li.amount_cents) filter (where li.charge_type in ('delivery', 'pickup')), 0),
         coalesce(sum(li.hst_cents) filter (where li.charge_type in ('delivery', 'pickup')), 0)
    into v_rental, v_rental_hst, v_fees, v_fees_hst, v_dlv, v_dlv_hst
    from booking_line_items li join fee_types f on f.code = li.charge_type
   where li.booking_id = p_booking and li.voided_at is null and li.charged_to_renter and li.stage in ('booking', 'extension');

  v_days := b.billable_days;
  if b.insurer_authorized_until is not null then
    v_until_days := case when app.local_midnight(b.insurer_authorized_until + 1) <= b.pickup_at then 0
                         else public.calc_billable_days(b.pickup_at, app.local_midnight(b.insurer_authorized_until + 1)) end;
    v_days := least(v_days, v_until_days);
  end if;
  if b.insurer_authorized_days is not null then
    v_days := least(v_days, b.insurer_authorized_days);
  end if;

  if b.insurer_rate_id is not null then
    select * into r from insurer_rates where id = b.insurer_rate_id;
  elsif b.insurer_authorized_daily_rate_cents is null and b.insurer_id is not null then
    r := app.insurer_rate_for(b.insurer_id, b.vehicle_id, app.local_date(b.pickup_at));
  end if;
  v_rate := coalesce(b.insurer_authorized_daily_rate_cents, r.daily_rate_cents);

  v_r := case when v_rate is not null
              then least(greatest(v_rental, 0), app.insurer_rate_amount(v_rate, r.weekly_cap_cents, r.monthly_cap_cents, v_days))
              else public.calc_round(greatest(v_rental, 0)::numeric * v_days / b.billable_days) end;
  if r.delivery_allowance_cents is not null then
    v_dlv_cov := least(greatest(v_dlv, 0), r.delivery_allowance_cents);
    v_dlv_cov_hst := case when v_dlv > 0 then public.calc_round(greatest(v_dlv_hst, 0)::numeric * v_dlv_cov / v_dlv) else 0 end;
  end if;
  if b.bill_to = 'insurer' then
    v_f := case when v_dlv_cov is null then greatest(v_fees, 0) else greatest(v_fees - v_dlv, 0) + v_dlv_cov end;
    v_h := case when v_dlv_cov is null then greatest(v_fees_hst, 0) else greatest(v_fees_hst - v_dlv_hst, 0) + v_dlv_cov_hst end;
  else
    v_f := coalesce(v_dlv_cov, 0);
    v_h := coalesce(v_dlv_cov_hst, 0);
  end if;
  v_h := v_h + case when v_rental > 0 then public.calc_round(v_rental_hst::numeric * v_r / v_rental) else 0 end;
  return query select v_days, v_r, v_f, v_r + v_f, v_h;
end $$;

-- the rate a booking is billed at, where it comes from, and the sheet row
create or replace function app.booking_insurer_rate(b bookings, out daily_rate_cents bigint, out rate_source text, out rate insurer_rates)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if b.insurer_rate_id is not null then
    select * into rate from insurer_rates where id = b.insurer_rate_id;
  elsif b.insurer_authorized_daily_rate_cents is null and b.insurer_id is not null then
    rate := app.insurer_rate_for(b.insurer_id, b.vehicle_id, app.local_date(b.pickup_at));
  end if;
  daily_rate_cents := coalesce(b.insurer_authorized_daily_rate_cents, rate.daily_rate_cents);
  rate_source := case when daily_rate_cents is null then 'none'
                      when rate.id is not null and daily_rate_cents = rate.daily_rate_cents then 'sheet'
                      when rate.id is not null then 'override'
                      else 'booking' end;
end $$;

-- 0016's draft, then the rate written on it: "at $65.00 a day (Allstate rate sheet, Sedan)", the caps, the allowance and
-- the taxes note; the rate used is kept on the invoice.
alter function app.draft_insurer_invoice(uuid, uuid) rename to draft_insurer_invoice_pre0163;
create or replace function app.draft_insurer_invoice(p_booking uuid, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := app.draft_insurer_invoice_pre0163(p_booking, p_by);
  b bookings;
  x record;
  s record;
  v_desc text;
begin
  select * into b from bookings where id = p_booking;
  select * into x from app.booking_insurer_rate(b);
  select * into s from app.booking_insurer_share(p_booking);
  v_desc := format('Rental charge, booking %s, %s day(s) authorized', b.booking_number, s.covered_days)
    || case when x.daily_rate_cents is not null then ' at ' || app.fmt_money(x.daily_rate_cents) || ' a day' else '' end
    || case x.rate_source
         when 'sheet' then format(' (%s rate sheet, %s)', (select i.name from insurers i where i.id = b.insurer_id), (select vc.label from vehicle_classes vc where vc.code = (x.rate).class_code))
         when 'override' then ' (rate agreed for this claim)'
         else '' end
    || case when (x.rate).weekly_cap_cents is not null then ', at most ' || app.fmt_money((x.rate).weekly_cap_cents) || ' a week' else '' end
    || case when (x.rate).monthly_cap_cents is not null then ', at most ' || app.fmt_money((x.rate).monthly_cap_cents) || ' for 30 days' else '' end;
  update insurer_invoices ii
     set lines = (select coalesce(jsonb_agg(case when e.n = 1 then jsonb_set(e.l, '{description}', to_jsonb(v_desc))
                                                 when e.l ->> 'description' = 'Fees charged at booking' and b.bill_to = 'split' and (x.rate).delivery_allowance_cents is not null
                                                   then jsonb_set(e.l, '{description}', to_jsonb('Delivery and pickup, up to the allowance of ' || app.fmt_money((x.rate).delivery_allowance_cents)))
                                                 when e.l ->> 'description' = 'Fees charged at booking' and (x.rate).delivery_allowance_cents is not null
                                                   then jsonb_set(e.l, '{description}', to_jsonb('Fees charged at booking (delivery and pickup up to ' || app.fmt_money((x.rate).delivery_allowance_cents) || ')'))
                                                 else e.l end order by e.n), '[]'::jsonb)
                    from jsonb_array_elements(ii.lines) with ordinality e(l, n)),
         daily_rate_cents = x.daily_rate_cents, rate_source = x.rate_source, insurer_rate_id = (x.rate).id,
         notes = case when (x.rate).taxes_note is null or position((x.rate).taxes_note in coalesce(ii.notes, '')) > 0 then ii.notes
                      else concat_ws(E'\n', ii.notes, (x.rate).taxes_note) end
   where ii.id = v_id;
  return v_id;
end $$;

-- the invoice's PDF facts (0032) carry its note (the taxes note of the sheet)
alter function app.pdf_facts(text, text, uuid) rename to pdf_facts_pre0163;
create or replace function app.pdf_facts(p_kind text, p_key text, p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.pdf_facts_pre0163(p_kind, p_key, p_user);
begin
  if p_kind = 'insurer_invoice' and v is not null then
    v := v || jsonb_build_object('note', (select ii.notes from insurer_invoices ii where ii.id = app.file_key_id(p_key)),
                                 'daily_rate_cents', (select ii.daily_rate_cents from insurer_invoices ii where ii.id = app.file_key_id(p_key)));
  end if;
  return v;
end $$;

-- ================================================================ 5. Admin: the sheet, a rate saved, the billing history
-- The grid: each insurer by each class, the rate today and the next one already saved.
create or replace function app.insurer_rate_sheet(p_by uuid, p jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with cls as (select vc.code, vc.label, vc.sort_order from vehicle_classes vc where vc.is_active),
  cur as (
    select r.*
      from insurers i cross join cls c cross join lateral (select * from app.insurer_rate_at(i.id, c.code, app.today())) r
     where r.id is not null),
  nxt as (
    select distinct on (r.insurer_id, r.class_code) r.*
      from insurer_rates r where r.effective_from > app.today()
     order by r.insurer_id, r.class_code, r.effective_from, r.created_at desc)
  select jsonb_build_object('today', app.today(),
    'classes', coalesce((select jsonb_agg(jsonb_build_object('code', c.code, 'label', c.label) order by c.sort_order, c.code) from cls c), '[]'::jsonb),
    'insurers', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'is_active', i.is_active,
        'rates', coalesce((select jsonb_object_agg(c.code, jsonb_build_object(
              'now', (select to_jsonb(x) from cur x where x.insurer_id = i.id and x.class_code = c.code and x.daily_rate_cents is not null),
              'next', (select to_jsonb(n) from nxt n where n.insurer_id = i.id and n.class_code = c.code)))
            from cls c where exists (select 1 from insurer_rates r where r.insurer_id = i.id and r.class_code = c.code)), '{}'::jsonb),
        'open_bookings', (select count(*) from bookings b where b.insurer_id = i.id and b.bill_to <> 'renter' and b.status in ('requested', 'offered', 'pending_payment', 'confirmed', 'on_rent')),
        'billed_cents', (select coalesce(sum(ii.total_cents), 0) from insurer_invoices ii where ii.insurer_id = i.id and ii.status <> 'draft'),
        'outstanding_cents', (select coalesce(sum(ii.balance_cents), 0) from insurer_invoices ii where ii.insurer_id = i.id and ii.status in ('sent', 'part_paid')))
      order by i.is_active desc, i.name) from insurers i), '[]'::jsonb))
$$;

-- An Admin saves a rate for an insurer and a class from a date (today by default). Never a change of a row: a new one.
create or replace function app.insurer_rate_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_ins insurers;
  v_class vehicle_classes;
  v_from date;
  v_daily bigint; v_week bigint; v_month bigint; v_dlv bigint; v_km integer;
  v_taxes text; v_note text;
  cur insurer_rates;
  v_id uuid;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin changes the insurers'' rate sheet' using errcode = '42501'; end if;
  select * into v_ins from insurers where id::text = p ->> 'insurer_id';
  if v_ins.id is null then raise exception 'Choose the insurer' using errcode = '22023'; end if;
  select * into v_class from vehicle_classes where code = p ->> 'class_code' and is_active;
  if v_class.code is null then raise exception 'Choose the car class' using errcode = '22023'; end if;
  begin
    v_from := coalesce(nullif(p ->> 'effective_from', '')::date, app.today());
    v_daily := nullif(p ->> 'daily_rate_cents', '')::bigint;
    v_week := nullif(p ->> 'weekly_cap_cents', '')::bigint;
    v_month := nullif(p ->> 'monthly_cap_cents', '')::bigint;
    v_dlv := nullif(p ->> 'delivery_allowance_cents', '')::bigint;
    v_km := nullif(p ->> 'km_per_day', '')::numeric::integer;
  exception when others then
    raise exception 'Check the amounts and the date' using errcode = '22023';
  end;
  v_taxes := nullif(btrim(coalesce(p ->> 'taxes_note', '')), '');
  v_note := nullif(btrim(coalesce(p ->> 'note', '')), '');
  if v_from > app.today() + 730 then raise exception 'A rate starts within two years' using errcode = '22023'; end if;
  if v_from < app.today() - 366 then raise exception 'A rate cannot start more than a year ago' using errcode = '22023'; end if;
  if v_daily is null and coalesce((p ->> 'remove')::boolean, false) is not true then
    raise exception 'Type the daily rate (or remove the rate)' using errcode = '22023';
  end if;
  if v_daily is not null and v_daily <= 0 then raise exception 'The daily rate is more than $0' using errcode = '22023'; end if;
  if v_daily is null then v_week := null; v_month := null; v_dlv := null; v_km := null; end if;
  if v_week is not null and v_week < v_daily then raise exception 'The weekly cap is at least the daily rate' using errcode = '22023'; end if;
  if v_month is not null and v_month < v_daily then raise exception 'The monthly cap is at least the daily rate' using errcode = '22023'; end if;
  if v_month is not null and v_week is not null and v_month < v_week then raise exception 'The monthly cap is at least the weekly cap' using errcode = '22023'; end if;
  if v_dlv is not null and v_dlv < 0 then raise exception 'The delivery and pickup allowance cannot be negative' using errcode = '22023'; end if;
  if v_km is not null and (v_km < 0 or v_km > 5000) then raise exception 'The kilometres a day are 0 to 5,000' using errcode = '22023'; end if;
  if v_taxes is not null and length(v_taxes) > 300 then raise exception 'The taxes note is at most 300 characters' using errcode = '22023'; end if;
  cur := app.insurer_rate_at(v_ins.id, v_class.code, v_from);
  if cur.id is null and v_daily is null then raise exception 'There is no rate to remove' using errcode = '22023'; end if;
  if cur.id is not null and cur.daily_rate_cents is not distinct from v_daily and cur.weekly_cap_cents is not distinct from v_week
     and cur.monthly_cap_cents is not distinct from v_month and cur.delivery_allowance_cents is not distinct from v_dlv
     and cur.km_per_day is not distinct from v_km and cur.taxes_note is not distinct from v_taxes then
    raise exception 'Nothing changed: the sheet already says this from %', app.fmt_day(cur.effective_from) using errcode = '22023';
  end if;
  insert into insurer_rates (insurer_id, class_code, effective_from, daily_rate_cents, weekly_cap_cents, monthly_cap_cents,
                             delivery_allowance_cents, km_per_day, taxes_note, note, created_by)
  values (v_ins.id, v_class.code, v_from, v_daily, v_week, v_month, v_dlv, v_km, v_taxes, v_note, p_by)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'insurer', v_ins.name, 'class', v_class.label, 'effective_from', v_from, 'daily_rate_cents', v_daily);
end $$;

-- An insurer's page: its rates by class with their history, and its billing history by class and by booking, for
-- bookings picked up from p.from to p.to (both optional).
create or replace function app.insurer_billing(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_ins insurers;
  v_from date;
  v_to date;
begin
  select * into v_ins from insurers where id::text = p ->> 'insurer';
  if v_ins.id is null then return null; end if;
  begin
    v_from := nullif(p ->> 'from', '')::date;
    v_to := nullif(p ->> 'to', '')::date;
  exception when others then
    raise exception 'Check the dates' using errcode = '22023';
  end;
  return (
    with bk as (
      select b.id, b.booking_number, b.status, b.pickup_at, b.return_at, b.billable_days, b.bill_to, b.insurer_claim_number,
             b.insurer_authorized_days, b.insurer_rate_reason, b.insurer_sheet_daily_rate_cents, x.daily_rate_cents, x.rate_source,
             coalesce((x.rate).class_code, v.class::text) as class_code, app.vehicle_name(b.vehicle_id) as vehicle,
             (select rr.legal_name from renters rr where rr.id = b.renter_id) as renter, s.covered_days, s.share_cents + s.hst_cents as share_cents
        from bookings b join vehicles v on v.id = b.vehicle_id
        cross join lateral app.booking_insurer_rate(b) x
        cross join lateral app.booking_insurer_share(b.id) s
       where b.insurer_id = v_ins.id and b.bill_to <> 'renter' and b.status in ('confirmed', 'on_rent', 'returned', 'closed')
         and (v_from is null or app.local_date(b.pickup_at) >= v_from) and (v_to is null or app.local_date(b.pickup_at) <= v_to)),
    inv as (
      select ii.booking_id,
             coalesce(sum(ii.total_cents) filter (where ii.status <> 'draft'), 0) as billed_cents,
             coalesce(sum(ii.paid_cents), 0) as paid_cents,
             coalesce(sum(ii.balance_cents) filter (where ii.status in ('sent', 'part_paid')), 0) as outstanding_cents,
             coalesce(sum(ii.balance_cents) filter (where ii.status = 'written_off'), 0) as written_off_cents,
             coalesce(sum(ii.total_cents) filter (where ii.status = 'draft'), 0) as draft_cents,
             count(*) filter (where ii.status = 'paid' and ii.paid_at is not null and ii.sent_at is not null) as paid_count,
             sum(extract(epoch from ii.paid_at - ii.sent_at) / 86400.0) filter (where ii.status = 'paid' and ii.paid_at is not null and ii.sent_at is not null) as pay_days,
             jsonb_agg(jsonb_build_object('id', ii.id, 'invoice_number', ii.invoice_number, 'status', ii.status, 'total_cents', ii.total_cents,
                       'paid_cents', ii.paid_cents, 'balance_cents', ii.balance_cents, 'sent_at', ii.sent_at, 'paid_at', ii.paid_at) order by ii.created_at) as invoices
        from insurer_invoices ii where ii.insurer_id = v_ins.id group by ii.booking_id),
    br as (
      select bk.*, coalesce(bk.insurer_authorized_days, bk.covered_days) as days_authorized,
             coalesce(inv.billed_cents, 0) as billed_cents, coalesce(inv.paid_cents, 0) as paid_cents, coalesce(inv.outstanding_cents, 0) as outstanding_cents,
             coalesce(inv.written_off_cents, 0) as written_off_cents, coalesce(inv.draft_cents, 0) as draft_cents,
             coalesce(inv.paid_count, 0) as paid_count, inv.pay_days, coalesce(inv.invoices, '[]'::jsonb) as invoices,
             (select vc.label from vehicle_classes vc where vc.code = bk.class_code) as class_label
        from bk left join inv on inv.booking_id = bk.id),
    agg as (
      select r.class_code, max(r.class_label) as class_label, count(*) as bookings, sum(r.days_authorized) as days_authorized,
             sum(r.billable_days) as days_used, sum(r.covered_days) as days_covered,
             sum(r.billed_cents) as billed_cents, sum(r.paid_cents) as paid_cents, sum(r.outstanding_cents) as outstanding_cents,
             sum(r.written_off_cents) as written_off_cents,
             case when sum(r.covered_days) filter (where r.daily_rate_cents is not null) > 0
                  then round(sum(r.daily_rate_cents * r.covered_days) filter (where r.daily_rate_cents is not null)::numeric
                             / sum(r.covered_days) filter (where r.daily_rate_cents is not null))::bigint end as average_rate_cents,
             case when sum(r.paid_count) > 0 then round(sum(r.pay_days) / sum(r.paid_count), 1) end as days_to_pay
        from br r group by r.class_code)
    select jsonb_build_object(
      'insurer', jsonb_build_object('id', v_ins.id, 'name', v_ins.name, 'is_active', v_ins.is_active, 'billing_email', v_ins.billing_email,
                                    'billing_contact_name', v_ins.billing_contact_name, 'billing_phone', v_ins.billing_phone),
      'from', v_from, 'to', v_to, 'today', app.today(),
      'classes', coalesce((select jsonb_agg(jsonb_build_object('code', vc.code, 'label', vc.label) order by vc.sort_order, vc.code) from vehicle_classes vc where vc.is_active), '[]'::jsonb),
      'rates', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object(
                  'class_label', (select vc.label from vehicle_classes vc where vc.code = r.class_code),
                  'effective_to', (select min(n.effective_from) - 1 from insurer_rates n where n.insurer_id = r.insurer_id and n.class_code = r.class_code and n.effective_from > r.effective_from),
                  'replaced', exists (select 1 from insurer_rates n where n.insurer_id = r.insurer_id and n.class_code = r.class_code and n.effective_from = r.effective_from and n.created_at > r.created_at),
                  'current', r.id = (app.insurer_rate_at(r.insurer_id, r.class_code, app.today())).id,
                  'by', (select u.full_name from users u where u.id = r.created_by))
                order by (select vc.sort_order from vehicle_classes vc where vc.code = r.class_code), r.class_code, r.effective_from desc, r.created_at desc)
               from insurer_rates r where r.insurer_id = v_ins.id), '[]'::jsonb),
      'by_class', coalesce((select jsonb_agg(to_jsonb(a) order by a.class_label) from agg a), '[]'::jsonb),
      'bookings', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'booking_number', r.booking_number, 'status', r.status, 'pickup_at', r.pickup_at,
                    'return_at', r.return_at, 'class_code', r.class_code, 'class_label', r.class_label, 'vehicle', r.vehicle, 'renter', r.renter,
                    'claim_number', r.insurer_claim_number, 'bill_to', r.bill_to, 'days_authorized', r.days_authorized, 'days_used', r.billable_days,
                    'days_covered', r.covered_days, 'daily_rate_cents', r.daily_rate_cents, 'rate_source', r.rate_source,
                    'sheet_rate_cents', r.insurer_sheet_daily_rate_cents, 'rate_reason', r.insurer_rate_reason, 'share_cents', r.share_cents,
                    'billed_cents', r.billed_cents, 'paid_cents', r.paid_cents, 'outstanding_cents', r.outstanding_cents,
                    'written_off_cents', r.written_off_cents, 'draft_cents', r.draft_cents,
                    'days_to_pay', case when r.paid_count > 0 then round(r.pay_days / r.paid_count, 1) end, 'invoices', r.invoices)
                  order by r.pickup_at desc) from br r), '[]'::jsonb),
      'totals', (select jsonb_build_object('bookings', count(*), 'days_authorized', coalesce(sum(r.days_authorized), 0), 'days_used', coalesce(sum(r.billable_days), 0),
                    'days_covered', coalesce(sum(r.covered_days), 0), 'billed_cents', coalesce(sum(r.billed_cents), 0), 'paid_cents', coalesce(sum(r.paid_cents), 0),
                    'outstanding_cents', coalesce(sum(r.outstanding_cents), 0), 'written_off_cents', coalesce(sum(r.written_off_cents), 0),
                    'average_rate_cents', case when sum(r.covered_days) filter (where r.daily_rate_cents is not null) > 0
                       then round(sum(r.daily_rate_cents * r.covered_days) filter (where r.daily_rate_cents is not null)::numeric
                                  / sum(r.covered_days) filter (where r.daily_rate_cents is not null))::bigint end,
                    'days_to_pay', case when sum(r.paid_count) > 0 then round(sum(r.pay_days) / sum(r.paid_count), 1) end) from br r))
  );
end $$;

-- A booking's Insurance replacement card: the insurer, the rate and where it comes from, what the insurer pays, its invoices.
create or replace function app.booking_insurer_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  x record;
  s record;
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = p ->> 'booking' limit 1;
  if b.id is null then return null; end if;
  if b.bill_to = 'renter' or b.insurer_id is null then
    return jsonb_build_object('billed_to_insurer', false, 'rates', app.insurer_rates_for_car(b.vehicle_id, app.local_date(b.pickup_at)));
  end if;
  select * into x from app.booking_insurer_rate(b);
  select * into s from app.booking_insurer_share(b.id);
  return jsonb_build_object('billed_to_insurer', true, 'bill_to', b.bill_to,
    'insurer', (select jsonb_build_object('id', i.id, 'name', i.name) from insurers i where i.id = b.insurer_id),
    'claim_number', b.insurer_claim_number, 'authorized_days', b.insurer_authorized_days, 'authorized_until', b.insurer_authorized_until,
    'daily_rate_cents', x.daily_rate_cents, 'rate_source', x.rate_source, 'sheet_rate_cents', b.insurer_sheet_daily_rate_cents,
    'differs', b.insurer_sheet_daily_rate_cents is not null and b.insurer_authorized_daily_rate_cents is distinct from b.insurer_sheet_daily_rate_cents,
    'reason', b.insurer_rate_reason,
    'rate', case when (x.rate).id is not null then to_jsonb(x.rate) || jsonb_build_object('class_label', (select vc.label from vehicle_classes vc where vc.code = (x.rate).class_code)) end,
    'covered_days', s.covered_days, 'rental_share_cents', s.rental_share_cents, 'fees_share_cents', s.fees_share_cents,
    'share_cents', s.share_cents, 'hst_cents', s.hst_cents,
    'rates', app.insurer_rates_for_car(b.vehicle_id, app.local_date(b.pickup_at)),
    'invoices', coalesce((select jsonb_agg(jsonb_build_object('id', ii.id, 'invoice_number', ii.invoice_number, 'status', ii.status, 'total_cents', ii.total_cents,
                  'paid_cents', ii.paid_cents, 'balance_cents', ii.balance_cents, 'daily_rate_cents', ii.daily_rate_cents, 'rate_source', ii.rate_source,
                  'sent_at', ii.sent_at, 'paid_at', ii.paid_at) order by ii.created_at) from insurer_invoices ii where ii.booking_id = b.id), '[]'::jsonb));
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0163;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call = 'admin_read' and p_name in ('insurer_rate_sheet', 'insurer_billing', 'booking_insurer')) or (p_call = 'admin_do' and p_name = 'insurer_rate_set') then
    perform app.door_begin(p_user, p_aal);
    if not app.user_is_admin(p_user) then raise exception 'Only an Admin opens the insurers'' rates and billing' using errcode = '42501'; end if;
    p_ := p_ - '_va';
    return case p_name
      when 'insurer_rate_sheet' then app.insurer_rate_sheet(p_user, p_)
      when 'insurer_billing' then app.insurer_billing(p_user, p_)
      when 'booking_insurer' then app.booking_insurer_read(p_user, p_)
      else app.insurer_rate_set(p_user, p_) end;
  end if;
  -- a booking's changes (the review screen, an offer changed in place) may carry the reason for an insurer's rate that
  -- differs from its rate sheet: kept for the booking's trigger, not a change of its own
  if jsonb_typeof(p_ -> 'changes') = 'object' and (p_ -> 'changes') ? 'insurer_rate_reason' then
    perform set_config('app.insurer_rate_reason', coalesce(btrim(p_ #>> '{changes,insurer_rate_reason}'), ''), true);
    p := jsonb_set(p_, '{changes}', (p_ -> 'changes') - 'insurer_rate_reason');
  end if;
  return app.door_pre0163(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ privileges
-- the new functions: the server only; a wrapper keeps the grants of the function it wraps
do $$
declare
  f record;
  g text;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['insurer_rates_append_only', 'insurer_rate_at', 'insurer_rate_for', 'insurer_rate_amount',
              'booking_insurer_rate_trg', 'insurer_rates_for_car', 'booking_insurer_rate', 'insurer_rate_sheet', 'insurer_rate_set', 'insurer_billing',
              'booking_insurer_read'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  for f in
    select * from (values ('app.door(uuid, text, text, text, jsonb)', 'app.door_pre0163(uuid, text, text, text, jsonb)'),
                          ('app.manual_rental_insurance(uuid, uuid, jsonb)', 'app.manual_rental_insurance_pre0163(uuid, uuid, jsonb)'),
                          ('app.manual_rental_quote(uuid, jsonb)', 'app.manual_rental_quote_pre0163(uuid, jsonb)'),
                          ('app.draft_insurer_invoice(uuid, uuid)', 'app.draft_insurer_invoice_pre0163(uuid, uuid)'),
                          ('app.pdf_facts(text, text, uuid)', 'app.pdf_facts_pre0163(text, text, uuid)')) x(fn, pre)
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.fn);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, f.pre, 'execute') then execute format('grant execute on function %s to %I', f.fn, g); end if;
    end loop;
  end loop;
end $$;

-- ================================================================ the guides
-- GUIDES 0163 START (generated by supabase/seed/0163_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'getting-around-admin', 'chapter', 'start-here', 'Admin opens on To do: the day''s counts at the top, then what needs you now, most urgent first. The menu groups every screen into six groups: Today, Bookings, Cars, People, Money and Settings. The long groups come in labelled parts (for example People: Owners and partners, then Renters, staff and investors). Search finds any booking, car or person, and Ctrl+K jumps to any page.

## To do

Start every shift here. Each line says what to do and why, and its button opens a small pop-up that does it, already filled in. Nothing to remember and no menu to search.

1. Each piece of work is its own line (work of one kind for several cars is one line, such as Add real photos (72 cars); its button opens the list), marked Now, Today or When you can: a car the insurer has not confirmed, a car not on the site, a renter''s documents to check, a visitor waiting in live chat, a booking request, a change a renter asked for, an owner application, an owner invoice waiting for payment, the first and last month an owner paid after their invoices were voided, the terms agreed with an owner still on the standard grid, documents an owner has not signed, an official form to check, a plate to check, a car showing sample photos, and any task of the Admin.
2. Press the line''s button: Mark insured, Set rates and publish, Review documents, Record payment, Record what they paid, Enter the terms, Record paper signature, Checked: use for owners, Open the chat, and so on. A line you do not need has Not needed or These are correct. The pop-up is filled in; check it and confirm. The line disappears once the work is done.
3. Under the lines, the counts with one button each (failed payments, agreements to countersign, tolls, listings, insurance, staff commissions, prices typed by hand, sales claims, Turo emails). A count with nothing waiting moves to the bottom, under "more with nothing waiting".
4. While no assistant holds customer service, sales, finance or fleet (the live verification''s test accounts do not count), their tasks come to To do too, and so do their emails, to rent@carmacars.ca.
5. Beside the list (under it on a phone): today''s pickups (ready or not ready), today''s returns (due or late) and today''s chauffeur bookings, by time.
6. Press **Overview** for the money, fleet and queue figures, the alerts and the team''s sales for the month.
7. The dark band at the top counts the day, each count one tap from its page: requests waiting (with how long the oldest has waited, red past the reply target), pickups and returns today, payments to chase, deposits to settle, staff tasks open and alerts. A count that needs you now is red and says so.

![](/guides/img/admin-01-today-desktop-ea48309c.jpg "desktop; size: 1440 900; address: carmacars.ca/admin; pins: 1 22.6 31.6, 2 90.3 31.7, 3 18.4 90.2, 4 94.4 22.2")

## The menu

The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.

| Group | Pages |
| --- | --- |
| Today | To do, Overview, Staff tasks, Live visitors |
| Bookings | Trips: Requests, Bookings, Calendar, Add a rental, Chauffeur. Customers: Live chat, Renter leads, Reviews. Problems: Damage, Incidents and claims |
| Cars | Vehicles, Listings, Maintenance, Rates for many cars, Calendar sync, Similar cars, Retire or delete |
| Money | Owners: Owner invoices, Owner debits, Owner statements, Payouts. Renters: Payments by day, Payments and refunds, Tolls and tickets. Company: Company statements, Reconciliation, Expenses, Insurer invoices, Staff commissions |
| People | Owners and partners: Applications, Owners, Add a car for an owner, Partners, Owner forms, Paid and signed. Renters, staff and investors: Renters, Staff, Investors, Portals and view as |
| Settings | All settings. Website: Site, Vehicle pages, Sample photos, Add-ons, Discount games, Guides. Rules: Program, Forms, Maintenance, Emails. Records: Email log, Audit log |

![On a phone: press Menu (1), then a group (2), then the page (3).](/guides/img/admin-31-menu-phone-667dc2fd.jpg "phone; size: 390 715; pins: 1 10.3 28.7, 2 76.9 42.4, 3 76.9 48.3")

## Search

The search box sits at the top of the menu, on every page.

1. Type a booking number (CC-1042), a car code (CC-7F3A, on every car page and fleet card), a plate, a VIN, or a name or email address.
2. Press **Search** (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.
3. To go to a page instead, press Ctrl+K (Cmd+K on a Mac) or **Jump to a page** under the search box, type a few letters (Payouts, Program settings) and press Enter. The first line searches the records for what you typed.

![](/guides/img/admin-32-search-desktop-ca548a70.jpg "desktop; size: 1440 420; address: carmacars.ca/admin/search?q=CC-10057; pins: 1 7.4 45.2, 2 95.0 46.9")

## Keyboard shortcuts

Press g, then a letter. Press / to jump to the search box, and Ctrl+K to jump to any page.

| Keys | Opens | Keys | Opens |
| --- | --- | --- | --- |
| g t | To do | g v | Vehicles |
| g r | Requests | g l | Listings |
| g b | Bookings | g a | Applications |
| g c | Calendar | g o | Owners |
| g k | Staff tasks | g m | Payments and refunds |
| g s | All settings | / | Search |
| Ctrl K | Jump to a page | Esc | Close it |
', 'Getting around Admin', 'To do, the menu, search, keyboard shortcuts and your other portals.',
  'Admin opens on To do: the day''s counts at the top, then what needs you now, most urgent first. The menu groups every screen into six groups: Today, Bookings, Cars, People, Money and Settings. The long groups come in labelled parts (for example People: Owners and partners, then Renters, staff and investors). Search finds any booking, car or person, and Ctrl+K jumps to any page.

## To do

Start every shift here. Each line says what to do and why, and its button opens a small pop-up that does it, already filled in. Nothing to remember and no menu to search.

1. Each piece of work is its own line (work of one kind for several cars is one line, such as Add real photos (72 cars); its button opens the list), marked Now, Today or When you can: a car the insurer has not confirmed, a car not on the site, a renter''s documents to check, a visitor waiting in live chat, a booking request, a change a renter asked for, an owner application, an owner invoice waiting for payment, the first and last month an owner paid after their invoices were voided, the terms agreed with an owner still on the standard grid, documents an owner has not signed, an official form to check, a plate to check, a car showing sample photos, and any task of the Admin.
2. Press the line''s button: Mark insured, Set rates and publish, Review documents, Record payment, Record what they paid, Enter the terms, Record paper signature, Checked: use for owners, Open the chat, and so on. A line you do not need has Not needed or These are correct. The pop-up is filled in; check it and confirm. The line disappears once the work is done.
3. Under the lines, the counts with one button each (failed payments, agreements to countersign, tolls, listings, insurance, staff commissions, prices typed by hand, sales claims, Turo emails). A count with nothing waiting moves to the bottom, under "more with nothing waiting".
4. While no assistant holds customer service, sales, finance or fleet (the live verification''s test accounts do not count), their tasks come to To do too, and so do their emails, to rent@carmacars.ca.
5. Beside the list (under it on a phone): today''s pickups (ready or not ready), today''s returns (due or late) and today''s chauffeur bookings, by time.
6. Press **Overview** for the money, fleet and queue figures, the alerts and the team''s sales for the month.
7. The dark band at the top counts the day, each count one tap from its page: requests waiting (with how long the oldest has waited, red past the reply target), pickups and returns today, payments to chase, deposits to settle, staff tasks open and alerts. A count that needs you now is red and says so.

![](/guides/img/admin-01-today-desktop-ea48309c.jpg "desktop; size: 1440 900; address: carmacars.ca/admin; pins: 1 22.6 31.6, 2 90.3 31.7, 3 18.4 90.2, 4 94.4 22.2")

## The menu

The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.

| Group | Pages |
| --- | --- |
| Today | To do, Overview, Staff tasks, Live visitors |
| Bookings | Trips: Requests, Bookings, Calendar, Add a rental, Chauffeur. Customers: Live chat, Renter leads, Reviews. Problems: Damage, Incidents and claims |
| Cars | Vehicles, Listings, Maintenance, Rates for many cars, Calendar sync, Similar cars, Retire or delete |
| Money | Owners: Owner invoices, Owner debits, Owner statements, Payouts. Renters: Payments by day, Payments and refunds, Tolls and tickets. Company: Company statements, Reconciliation, Expenses, Insurer rates, Insurer invoices, Staff commissions |
| People | Owners and partners: Applications, Owners, Add a car for an owner, Partners, Owner forms, Paid and signed. Renters, staff and investors: Renters, Staff, Investors, Portals and view as |
| Settings | All settings. Website: Site, Vehicle pages, Sample photos, Add-ons, Discount games, Guides. Rules: Program, Forms, Maintenance, Emails. Records: Email log, Audit log |

![On a phone: press Menu (1), then a group (2), then the page (3).](/guides/img/admin-31-menu-phone-667dc2fd.jpg "phone; size: 390 715; pins: 1 10.3 28.7, 2 76.9 42.4, 3 76.9 48.3")

## Search

The search box sits at the top of the menu, on every page.

1. Type a booking number (CC-1042), a car code (CC-7F3A, on every car page and fleet card), a plate, a VIN, or a name or email address.
2. Press **Search** (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.
3. To go to a page instead, press Ctrl+K (Cmd+K on a Mac) or **Jump to a page** under the search box, type a few letters (Payouts, Program settings) and press Enter. The first line searches the records for what you typed.

![](/guides/img/admin-32-search-desktop-ca548a70.jpg "desktop; size: 1440 420; address: carmacars.ca/admin/search?q=CC-10057; pins: 1 7.4 45.2, 2 95.0 46.9")

## Keyboard shortcuts

Press g, then a letter. Press / to jump to the search box, and Ctrl+K to jump to any page.

| Keys | Opens | Keys | Opens |
| --- | --- | --- | --- |
| g t | To do | g v | Vehicles |
| g r | Requests | g l | Listings |
| g b | Bookings | g a | Applications |
| g c | Calendar | g o | Owners |
| g k | Staff tasks | g m | Payments and refunds |
| g s | All settings | / | Search |
| Ctrl K | Jump to a page | Esc | Close it |
',
  '<p class="gd-p">Admin opens on To do: the day&#39;s counts at the top, then what needs you now, most urgent first. The menu groups every screen into six groups: Today, Bookings, Cars, People, Money and Settings. The long groups come in labelled parts (for example People: Owners and partners, then Renters, staff and investors). Search finds any booking, car or person, and Ctrl+K jumps to any page.</p><section class="gd-task" id="getting-around-admin-to-do" data-gd-task><h2 class="gd-h2">To do</h2><p class="gd-p">Start every shift here. Each line says what to do and why, and its button opens a small pop-up that does it, already filled in. Nothing to remember and no menu to search.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each piece of work is its own line (work of one kind for several cars is one line, such as Add real photos (72 cars); its button opens the list), marked Now, Today or When you can: a car the insurer has not confirmed, a car not on the site, a renter&#39;s documents to check, a visitor waiting in live chat, a booking request, a change a renter asked for, an owner application, an owner invoice waiting for payment, the first and last month an owner paid after their invoices were voided, the terms agreed with an owner still on the standard grid, documents an owner has not signed, an official form to check, a plate to check, a car showing sample photos, and any task of the Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press the line&#39;s button: Mark insured, Set rates and publish, Review documents, Record payment, Record what they paid, Enter the terms, Record paper signature, Checked: use for owners, Open the chat, and so on. A line you do not need has Not needed or These are correct. The pop-up is filled in; check it and confirm. The line disappears once the work is done.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Under the lines, the counts with one button each (failed payments, agreements to countersign, tolls, listings, insurance, staff commissions, prices typed by hand, sales claims, Turo emails). A count with nothing waiting moves to the bottom, under &quot;more with nothing waiting&quot;.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">While no assistant holds customer service, sales, finance or fleet (the live verification&#39;s test accounts do not count), their tasks come to To do too, and so do their emails, to rent@carmacars.ca.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Beside the list (under it on a phone): today&#39;s pickups (ready or not ready), today&#39;s returns (due or late) and today&#39;s chauffeur bookings, by time.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Overview</b> for the money, fleet and queue figures, the alerts and the team&#39;s sales for the month.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">The dark band at the top counts the day, each count one tap from its page: requests waiting (with how long the oldest has waited, red past the reply target), pickups and returns today, payments to chase, deposits to settle, staff tasks open and alerts. A count that needs you now is red and says so.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-01-today-desktop-ea48309c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:22.6%;top:31.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:90.3%;top:31.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:18.4%;top:90.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:94.4%;top:22.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="getting-around-admin-the-menu" data-gd-task><h2 class="gd-h2">The menu</h2><p class="gd-p">The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Group</th><th scope="col">Pages</th></tr></thead><tbody><tr><td>Today</td><td>To do, Overview, Staff tasks, Live visitors</td></tr><tr><td>Bookings</td><td>Trips: Requests, Bookings, Calendar, Add a rental, Chauffeur. Customers: Live chat, Renter leads, Reviews. Problems: Damage, Incidents and claims</td></tr><tr><td>Cars</td><td>Vehicles, Listings, Maintenance, Rates for many cars, Calendar sync, Similar cars, Retire or delete</td></tr><tr><td>Money</td><td>Owners: Owner invoices, Owner debits, Owner statements, Payouts. Renters: Payments by day, Payments and refunds, Tolls and tickets. Company: Company statements, Reconciliation, Expenses, Insurer rates, Insurer invoices, Staff commissions</td></tr><tr><td>People</td><td>Owners and partners: Applications, Owners, Add a car for an owner, Partners, Owner forms, Paid and signed. Renters, staff and investors: Renters, Staff, Investors, Portals and view as</td></tr><tr><td>Settings</td><td>All settings. Website: Site, Vehicle pages, Sample photos, Add-ons, Discount games, Guides. Rules: Program, Forms, Maintenance, Emails. Records: Email log, Audit log</td></tr></tbody></table></div><div class="gd-figblock"><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/715"><img src="/guides/img/admin-31-menu-phone-667dc2fd.jpg" alt="On a phone: press Menu (1), then a group (2), then the page (3)." loading="lazy" decoding="async" width="390" height="715"><span class="gd-pin" style="left:10.3%;top:28.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:76.9%;top:42.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.9%;top:48.3%" aria-hidden="true">3</span></div></div><figcaption>On a phone: press Menu (1), then a group (2), then the page (3).</figcaption></figure></div></section><section class="gd-task" id="getting-around-admin-search" data-gd-task><h2 class="gd-h2">Search</h2><p class="gd-p">The search box sits at the top of the menu, on every page.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a booking number (CC-1042), a car code (CC-7F3A, on every car page and fleet card), a plate, a VIN, or a name or email address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Search</b> (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To go to a page instead, press Ctrl+K (Cmd+K on a Mac) or <b class="gd-ui">Jump to a page</b> under the search box, type a few letters (Payouts, Program settings) and press Enter. The first line searches the records for what you typed.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/search?q=CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/420"><img src="/guides/img/admin-32-search-desktop-ca548a70.jpg" alt="" loading="lazy" decoding="async" width="1440" height="420"><span class="gd-pin" style="left:7.4%;top:45.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:95%;top:46.9%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="getting-around-admin-keyboard-shortcuts" data-gd-task><h2 class="gd-h2">Keyboard shortcuts</h2><p class="gd-p">Press g, then a letter. Press / to jump to the search box, and Ctrl+K to jump to any page.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Keys</th><th scope="col">Opens</th><th scope="col">Keys</th><th scope="col">Opens</th></tr></thead><tbody><tr><td>g t</td><td>To do</td><td>g v</td><td>Vehicles</td></tr><tr><td>g r</td><td>Requests</td><td>g l</td><td>Listings</td></tr><tr><td>g b</td><td>Bookings</td><td>g a</td><td>Applications</td></tr><tr><td>g c</td><td>Calendar</td><td>g o</td><td>Owners</td></tr><tr><td>g k</td><td>Staff tasks</td><td>g m</td><td>Payments and refunds</td></tr><tr><td>g s</td><td>All settings</td><td>/</td><td>Search</td></tr><tr><td>Ctrl K</td><td>Jump to a page</td><td>Esc</td><td>Close it</td></tr></tbody></table></div></section>');
select app.guide_release_section('admin', 'partners-company-cars-and-rentals-added-by-hand', 'chapter', 'fleet-and-listings', 'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.

## Add a car

**Cars** > **Vehicles**, then **Add a car**. Start with the VIN: everything else about the car comes from it.

1. Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.
2. When the VIN fits several trims, the form asks which trim it is: press the one on the car''s papers or badge, or **Not sure** (Admin > Today asks again).
3. No VIN at hand? Press **No VIN at hand? Add the car by its plate** and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.
4. Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.
5. Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.
6. Choose who supplies it: **A program owner''s car** (choose the owner; the car starts its onboarding), **CarmaCars-owned (company fleet)** (no owner; all of its revenue is CarmaCars'') or **A partner rental company''s car** (choose the partner; leave the commission empty to use the partner''s).
7. The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car''s Rates tab. Press **Add the car**.

> Tip: The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car''s listing; a field you change is kept.

> Good to know: Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car''s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.

> Tip: A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.

The gearbox comes from the government''s fuel economy data for the model when it has one gearbox for it, or from the VIN when the VIN states it. Seats come from the VIN, or the usual number for the body (4 for a coupe or convertible, 5 for a sedan, SUV or hatchback). When either is not certain, Admin > Today shows **Confirm gearbox and seats**: press the gearbox and the number of seats, then **Save**. A car whose VIN fits several trims shows **Pick the trim** there: press the right one. Either way the title, description and search text are written again.

On a car''s page, **Who supplies the car** shows the supplier and the commission, and changes them. Vehicles filters by supply type.

## Partners

**People** > **Partners**. Partner rental companies whose cars we rent out on commission.

1. Press **Add a partner**: business and legal name, contacts, HST number, commission and insurance with its expiry date.
2. Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Staff tasks gets a reminder (Program settings sets how many days before).
3. Banking (Admins only): **Save the payout account** for the account we pay the partner into. The account number is stored encrypted. Press **Verify** once checked.
4. Portal: **Invite to the owner portal** gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.
5. Signed on paper? Press **Print the partner agreement**, then record the signed scan under Record a paper signature.

## A partner fleet on its own rates

Some partners send a price sheet of their own rates instead of sharing what the renter pays. 01 Motors works this way: its whole fleet is on the site, and staff manage its cars (it has no portal sign-in yet; add its email on the partner page and invite it later).

1. **People** > **Partners** > the partner. **Pricing** shows how it is paid: the renter pays the partner''s sheet rate plus the markup (10% unless you set another), rounded to the nearest dollar; CarmaCars keeps the markup plus its cut (20% of the sheet rate); the partner is owed the rest of its sheet rate. Press **Edit pricing** to change the markup, the cut or the basis for every car at once.
2. **Cars** lists each car with its sheet rates a day (1 to 2 days, 3 or more, 7 or more) and the renter''s rates. Press **Edit** on a car to change a negotiated rate, give that car its own markup or cut, mark it **Insurance included** or **No credit card needed**, or confirm its model year. The renter''s rates change at once.
3. The site shows these cars with their tiers (1 to 2 days, 3 to 6 days, 7 days or more) and "Guideline rates; final price confirmed after review". A car with insurance included needs no coverage choice from the renter (coverage option 4, confirmed by itself); a car with no credit card needed takes a debit card for the payment and the deposit. The deposit, the licence and identity checks and the ages stay the same.
4. The price sheet has no years, VINs or plates. Until you confirm the year, the site leaves it out and says "Year confirmed when you book"; an offer waits until the year is confirmed (Edit on the car, Model year). Add the plate and the VIN on the car''s page before its first handover.
5. Real photos: open the car (its name in Cars), **Photos**, and add them. Once approved they replace the eight studio stand-ins.

> Good to know: The partner''s monthly statement shows each rental at the sheet rate, the cut and the payout; never what the renter paid. A refund lowers the partner''s share in proportion; a discount CarmaCars gives comes out of the markup.

## A partner''s CRM (01 Motors'' GoHighLevel)

**Settings**, the **Partners** tile, then the partner (or **CRM link** on the partner''s page). Their CRM gets our cars, kept up to date, and their cars come to us.

1. Ask the partner for a Private Integration token and their location ID (the box **What 01 Motors gives us** on the page says exactly what to create and which scopes to tick). Paste both and press **Connect**. The token goes to the vault; the page only ever shows its last four characters.
2. Connect tests the link (their location, objects, products and pipelines) and runs the first sync. After that it runs by itself every 15 minutes, and within five minutes of a change to a car, a rate, a photo, a booking or a block. **Test connection** and **Run sync now** do it at once.
3. **What 01 Motors sees**: CarmaCars'' own cars and program owners'' cars that are on the site, with rates, the next 60 days and photos, as records of a "CarmaCars Vehicles" object in their CRM (or as products when their plan has no custom objects). Partner cars are never sent: not theirs, not another partner''s. Press **Change what we share** to leave out program owners'' cars, rates, availability or photos.
4. **Partner price**: the site''s rates, or the site''s rates less (or plus) a percentage, to the nearest dollar.
5. **Their cars coming in**: name the object in their CRM that holds their cars (Test connection lists them), or their feed address. Each of their cars is matched to their car here, or added as their partner car (it waits off the site unless you choose otherwise), with their rates as its sheet rates, their booked dates as calendar blocks and their photos for a car with none. A car that waits shows **Add as their car**, **Link** or **Set aside**.
6. **Leads both ways** (off until you turn it on): requests for their cars, and requests that came through their booking links, become contacts and opportunities in the pipeline stage you choose; an opportunity they move to the stage you name becomes a lead in **Leads**.
7. **Feed, widget and booking links**: a JSON or CSV feed and a widget for their GoHighLevel funnels and sites (copy the iframe), and booking links carmacars.ca/p/01-motors/<car> that mark the request as theirs for 30 days. **New key** ends the old feed and widget addresses at once.

> Good to know: A link that has failed for an hour shows on Admin > Today. Disconnect deletes the token from the vault; what is already in their CRM stays there.

## Add a rental by hand

**Bookings** > **Add a rental**. For phone, walk-in, Turo, partner and insurer bookings, the owner using their own car, and placeholders: a rental already agreed. To send an offer instead, use Send an offer.

1. Standing with the renter at pickup? Press **Start at pickup**: type the renter''s name and phone, choose the car, type the kilometres and the fuel, and press **Hold the car and finish later**. The pickup is now; the car is held for 2 hours (renewed while you work on it) and you get a task to finish the rental.
2. Nothing is required to save: the form is saved as a draft as you type (**Save draft** saves at once). Unfinished rentals, on Bookings and on this page, lists every draft with who started it, when, and what is still missing; Finish it opens it where it was left, on any device. Tick Hold the car while I finish to keep the car off the calendar while you type (2 hours, renewed as you save). Discard drops it and frees the car.
3. Quick start sets the usual choices in one tap: **Phone**, **Walk-in**, **Turo or another platform**, **Insurance replacement**, **Owner using own car** or **Placeholder**.
4. Choose the car and the dates. The calendar and the price are checked by themselves: clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
5. The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.
6. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
7. We deliver it, or we pick it up: pick the address from the suggestions and its distance from our location prices the delivery (shown under the address), as on Send an offer.
8. Check the price: every line of the price can be changed where it stands. Type a new amount in the line (the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the deposit, the kilometres a day); HST and the total follow. Add a line from the list or a charge of its own; Remove takes a fee off. The (i) beside each line says what it is and how it is worked out. One optional reason covers all the changes.
9. Any length: the dates may run past 30 days (up to the staff limit in Program settings, 730 days by default). From 30 days the rental charge is the monthly rate for each 30 days, and the monthly periods are listed. On the booking, Monthly periods shows each period: its share, and its own version of the agreement (CarmaCars'' and Blind Spot''s), sent to the renter to sign a few days before it starts (Program settings: long_rental_agreement_lead_days, 3 by default), with what is due for it on the renter''s Balance due. With Program settings, Charge the saved card for each period, on, that share is charged to the saved card when the agreement goes out (the renter gets the receipt; a declined or missing card gives Finance a task).
10. A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.
11. An owner''s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner''s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press **Insurer confirmed** once the insurer confirms it.
12. Insurer billed later (or the Insurance replacement quick start): choose the insurer (Not listed: type its name, and it is added to the list), the claim number, the adjuster, the days and the daily rate authorized, the provisional end, and whether the insurer pays everything or the rental only. The booking is billed to the insurer; the renter owes only what it does not cover.
13. The rent is paid by: e-Transfer or cash (received), card on file (charged when the renter signs), payment link, platform payout (Turo), insurer billed later, cheque, bank transfer, or unpaid. Paid in parts (some cash, some e-Transfer): press **Add another payment (paid in parts)** and type each amount. Then the deposit, its own way: card hold, cash, e-Transfer (with its reference and date) or no deposit.
14. Before you save checks it all in one box: the renter, the car, the days, the total, what was received and what is still to collect, the deposit and the agreement.
15. The rental agreement: Send it to sign online, or Already signed on paper (a task asks for the scan). The calendar: untick Blocks the car''s calendar for an insurance replacement with dates not known yet, with the reason.
16. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

> Tip: The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, **Verified in person** records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.

## Retire or delete a car

**Cars** > **Retire or delete**, or the car''s own page.

1. **Retire this car** takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. **Restore** brings it back.
2. **Delete this car** removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.
3. Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.
4. On the same page, **Delete all sample cars** deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.

## Sample cars on the site

**Cars** > **Vehicles**, or **Settings** > **Site**. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.

1. **Hide sample cars** asks first ("Hide all 20 sample cars from the site?"); press **Hide them** to take every sample car off the site at once, or **Keep them**. Nothing else stops it: not an enquiry, not an old request.
2. **Show sample cars** puts the 20 back, with their photos and rates. Ones that were deleted are made again.
3. On the site each one is marked "Example car". They never appear in search engines or the sitemap.
4. A request on a sample car is never a booking. When the person picks dates, the car page and the request form show a real car free for them (the same make and model first, else the same class and body at a similar price) with one tap to switch to it. If they keep the sample car, it becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car, naming the free real car.

> Tip: Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.

## Why a car is not on the site yet

**Cars** > **Vehicles**, the card Not on the site yet.

1. Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.
2. The same car is a line on To do with **Set rates and publish**. The car comes off both once it is on the site.
3. A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.

## Tolls when two rentals overlap

Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.
', 'Partners, company cars and rentals added by hand', 'Add a car, partners, add a rental, retire or delete a car, sample cars and tolls with two rentals.',
  'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.

## Add a car

**Cars** > **Vehicles**, then **Add a car**. Start with the VIN: everything else about the car comes from it.

1. Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.
2. When the VIN fits several trims, the form asks which trim it is: press the one on the car''s papers or badge, or **Not sure** (Admin > Today asks again).
3. No VIN at hand? Press **No VIN at hand? Add the car by its plate** and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.
4. Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.
5. Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.
6. Choose who supplies it: **A program owner''s car** (choose the owner; the car starts its onboarding), **CarmaCars-owned (company fleet)** (no owner; all of its revenue is CarmaCars'') or **A partner rental company''s car** (choose the partner; leave the commission empty to use the partner''s).
7. The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car''s Rates tab. Press **Add the car**.

> Tip: The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car''s listing; a field you change is kept.

> Good to know: Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car''s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.

> Tip: A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.

The gearbox comes from the government''s fuel economy data for the model when it has one gearbox for it, or from the VIN when the VIN states it. Seats come from the VIN, or the usual number for the body (4 for a coupe or convertible, 5 for a sedan, SUV or hatchback). When either is not certain, Admin > Today shows **Confirm gearbox and seats**: press the gearbox and the number of seats, then **Save**. A car whose VIN fits several trims shows **Pick the trim** there: press the right one. Either way the title, description and search text are written again.

On a car''s page, **Who supplies the car** shows the supplier and the commission, and changes them. Vehicles filters by supply type.

## Partners

**People** > **Partners**. Partner rental companies whose cars we rent out on commission.

1. Press **Add a partner**: business and legal name, contacts, HST number, commission and insurance with its expiry date.
2. Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Staff tasks gets a reminder (Program settings sets how many days before).
3. Banking (Admins only): **Save the payout account** for the account we pay the partner into. The account number is stored encrypted. Press **Verify** once checked.
4. Portal: **Invite to the owner portal** gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.
5. Signed on paper? Press **Print the partner agreement**, then record the signed scan under Record a paper signature.

## A partner fleet on its own rates

Some partners send a price sheet of their own rates instead of sharing what the renter pays. 01 Motors works this way: its whole fleet is on the site, and staff manage its cars (it has no portal sign-in yet; add its email on the partner page and invite it later).

1. **People** > **Partners** > the partner. **Pricing** shows how it is paid: the renter pays the partner''s sheet rate plus the markup (10% unless you set another), rounded to the nearest dollar; CarmaCars keeps the markup plus its cut (20% of the sheet rate); the partner is owed the rest of its sheet rate. Press **Edit pricing** to change the markup, the cut or the basis for every car at once.
2. **Cars** lists each car with its sheet rates a day (1 to 2 days, 3 or more, 7 or more) and the renter''s rates. Press **Edit** on a car to change a negotiated rate, give that car its own markup or cut, mark it **Insurance included** or **No credit card needed**, or confirm its model year. The renter''s rates change at once.
3. The site shows these cars with their tiers (1 to 2 days, 3 to 6 days, 7 days or more) and "Guideline rates; final price confirmed after review". A car with insurance included needs no coverage choice from the renter (coverage option 4, confirmed by itself); a car with no credit card needed takes a debit card for the payment and the deposit. The deposit, the licence and identity checks and the ages stay the same.
4. The price sheet has no years, VINs or plates. Until you confirm the year, the site leaves it out and says "Year confirmed when you book"; an offer waits until the year is confirmed (Edit on the car, Model year). Add the plate and the VIN on the car''s page before its first handover.
5. Real photos: open the car (its name in Cars), **Photos**, and add them. Once approved they replace the eight studio stand-ins.

> Good to know: The partner''s monthly statement shows each rental at the sheet rate, the cut and the payout; never what the renter paid. A refund lowers the partner''s share in proportion; a discount CarmaCars gives comes out of the markup.

## A partner''s CRM (01 Motors'' GoHighLevel)

**Settings**, the **Partners** tile, then the partner (or **CRM link** on the partner''s page). Their CRM gets our cars, kept up to date, and their cars come to us.

1. Ask the partner for a Private Integration token and their location ID (the box **What 01 Motors gives us** on the page says exactly what to create and which scopes to tick). Paste both and press **Connect**. The token goes to the vault; the page only ever shows its last four characters.
2. Connect tests the link (their location, objects, products and pipelines) and runs the first sync. After that it runs by itself every 15 minutes, and within five minutes of a change to a car, a rate, a photo, a booking or a block. **Test connection** and **Run sync now** do it at once.
3. **What 01 Motors sees**: CarmaCars'' own cars and program owners'' cars that are on the site, with rates, the next 60 days and photos, as records of a "CarmaCars Vehicles" object in their CRM (or as products when their plan has no custom objects). Partner cars are never sent: not theirs, not another partner''s. Press **Change what we share** to leave out program owners'' cars, rates, availability or photos.
4. **Partner price**: the site''s rates, or the site''s rates less (or plus) a percentage, to the nearest dollar.
5. **Their cars coming in**: name the object in their CRM that holds their cars (Test connection lists them), or their feed address. Each of their cars is matched to their car here, or added as their partner car (it waits off the site unless you choose otherwise), with their rates as its sheet rates, their booked dates as calendar blocks and their photos for a car with none. A car that waits shows **Add as their car**, **Link** or **Set aside**.
6. **Leads both ways** (off until you turn it on): requests for their cars, and requests that came through their booking links, become contacts and opportunities in the pipeline stage you choose; an opportunity they move to the stage you name becomes a lead in **Leads**.
7. **Feed, widget and booking links**: a JSON or CSV feed and a widget for their GoHighLevel funnels and sites (copy the iframe), and booking links carmacars.ca/p/01-motors/<car> that mark the request as theirs for 30 days. **New key** ends the old feed and widget addresses at once.

> Good to know: A link that has failed for an hour shows on Admin > Today. Disconnect deletes the token from the vault; what is already in their CRM stays there.

## Add a rental by hand

**Bookings** > **Add a rental**. For phone, walk-in, Turo, partner and insurer bookings, the owner using their own car, and placeholders: a rental already agreed. To send an offer instead, use Send an offer.

1. Standing with the renter at pickup? Press **Start at pickup**: type the renter''s name and phone, choose the car, type the kilometres and the fuel, and press **Hold the car and finish later**. The pickup is now; the car is held for 2 hours (renewed while you work on it) and you get a task to finish the rental.
2. Nothing is required to save: the form is saved as a draft as you type (**Save draft** saves at once). Unfinished rentals, on Bookings and on this page, lists every draft with who started it, when, and what is still missing; Finish it opens it where it was left, on any device. Tick Hold the car while I finish to keep the car off the calendar while you type (2 hours, renewed as you save). Discard drops it and frees the car.
3. Quick start sets the usual choices in one tap: **Phone**, **Walk-in**, **Turo or another platform**, **Insurance replacement**, **Owner using own car** or **Placeholder**.
4. Choose the car and the dates. The calendar and the price are checked by themselves: clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
5. The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.
6. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
7. We deliver it, or we pick it up: pick the address from the suggestions and its distance from our location prices the delivery (shown under the address), as on Send an offer.
8. Check the price: every line of the price can be changed where it stands. Type a new amount in the line (the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the deposit, the kilometres a day); HST and the total follow. Add a line from the list or a charge of its own; Remove takes a fee off. The (i) beside each line says what it is and how it is worked out. One optional reason covers all the changes.
9. Any length: the dates may run past 30 days (up to the staff limit in Program settings, 730 days by default). From 30 days the rental charge is the monthly rate for each 30 days, and the monthly periods are listed. On the booking, Monthly periods shows each period: its share, and its own version of the agreement (CarmaCars'' and Blind Spot''s), sent to the renter to sign a few days before it starts (Program settings: long_rental_agreement_lead_days, 3 by default), with what is due for it on the renter''s Balance due. With Program settings, Charge the saved card for each period, on, that share is charged to the saved card when the agreement goes out (the renter gets the receipt; a declined or missing card gives Finance a task).
10. A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.
11. An owner''s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner''s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press **Insurer confirmed** once the insurer confirms it.
12. Insurer billed later (or the Insurance replacement quick start): choose the insurer (Not listed: type its name, and it is added to the list), the claim number, the adjuster, the days and the daily rate authorized, the provisional end, and whether the insurer pays everything or the rental only. The booking is billed to the insurer; the renter owes only what it does not cover. The daily rate authorized is filled from the insurer''s rate sheet for the car (Insurance replacements: rates and billing); a different rate needs the reason.
13. The rent is paid by: e-Transfer or cash (received), card on file (charged when the renter signs), payment link, platform payout (Turo), insurer billed later, cheque, bank transfer, or unpaid. Paid in parts (some cash, some e-Transfer): press **Add another payment (paid in parts)** and type each amount. Then the deposit, its own way: card hold, cash, e-Transfer (with its reference and date) or no deposit.
14. Before you save checks it all in one box: the renter, the car, the days, the total, what was received and what is still to collect, the deposit and the agreement.
15. The rental agreement: Send it to sign online, or Already signed on paper (a task asks for the scan). The calendar: untick Blocks the car''s calendar for an insurance replacement with dates not known yet, with the reason.
16. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

> Tip: The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, **Verified in person** records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.

## Retire or delete a car

**Cars** > **Retire or delete**, or the car''s own page.

1. **Retire this car** takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. **Restore** brings it back.
2. **Delete this car** removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.
3. Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.
4. On the same page, **Delete all sample cars** deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.

## Sample cars on the site

**Cars** > **Vehicles**, or **Settings** > **Site**. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.

1. **Hide sample cars** asks first ("Hide all 20 sample cars from the site?"); press **Hide them** to take every sample car off the site at once, or **Keep them**. Nothing else stops it: not an enquiry, not an old request.
2. **Show sample cars** puts the 20 back, with their photos and rates. Ones that were deleted are made again.
3. On the site each one is marked "Example car". They never appear in search engines or the sitemap.
4. A request on a sample car is never a booking. When the person picks dates, the car page and the request form show a real car free for them (the same make and model first, else the same class and body at a similar price) with one tap to switch to it. If they keep the sample car, it becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car, naming the free real car.

> Tip: Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.

## Why a car is not on the site yet

**Cars** > **Vehicles**, the card Not on the site yet.

1. Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.
2. The same car is a line on To do with **Set rates and publish**. The car comes off both once it is on the site.
3. A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.

## Tolls when two rentals overlap

Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.
',
  '<p class="gd-p">A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.</p><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-car" data-gd-task><h2 class="gd-h2">Add a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then <b class="gd-ui">Add a car</b>. Start with the VIN: everything else about the car comes from it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">When the VIN fits several trims, the form asks which trim it is: press the one on the car&#39;s papers or badge, or <b class="gd-ui">Not sure</b> (Admin &gt; Today asks again).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">No VIN at hand? Press <b class="gd-ui">No VIN at hand? Add the car by its plate</b> and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Choose who supplies it: <b class="gd-ui">A program owner&#39;s car</b> (choose the owner; the car starts its onboarding), <b class="gd-ui">CarmaCars-owned (company fleet)</b> (no owner; all of its revenue is CarmaCars&#39;) or <b class="gd-ui">A partner rental company&#39;s car</b> (choose the partner; leave the commission empty to use the partner&#39;s).</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car&#39;s Rates tab. Press <b class="gd-ui">Add the car</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car&#39;s listing; a field you change is kept.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car&#39;s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.</div></aside><p class="gd-p">The gearbox comes from the government&#39;s fuel economy data for the model when it has one gearbox for it, or from the VIN when the VIN states it. Seats come from the VIN, or the usual number for the body (4 for a coupe or convertible, 5 for a sedan, SUV or hatchback). When either is not certain, Admin &gt; Today shows <b class="gd-ui">Confirm gearbox and seats</b>: press the gearbox and the number of seats, then <b class="gd-ui">Save</b>. A car whose VIN fits several trims shows <b class="gd-ui">Pick the trim</b> there: press the right one. Either way the title, description and search text are written again.</p><p class="gd-p">On a car&#39;s page, <b class="gd-ui">Who supplies the car</b> shows the supplier and the commission, and changes them. Vehicles filters by supply type.</p></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-partners" data-gd-task><h2 class="gd-h2">Partners</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Partners</b>. Partner rental companies whose cars we rent out on commission.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Add a partner</b>: business and legal name, contacts, HST number, commission and insurance with its expiry date.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Staff tasks gets a reminder (Program settings sets how many days before).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Banking (Admins only): <b class="gd-ui">Save the payout account</b> for the account we pay the partner into. The account number is stored encrypted. Press <b class="gd-ui">Verify</b> once checked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Portal: <b class="gd-ui">Invite to the owner portal</b> gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Signed on paper? Press <b class="gd-ui">Print the partner agreement</b>, then record the signed scan under Record a paper signature.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-a-partner-fleet-on-its-own-rates" data-gd-task><h2 class="gd-h2">A partner fleet on its own rates</h2><p class="gd-p">Some partners send a price sheet of their own rates instead of sharing what the renter pays. 01 Motors works this way: its whole fleet is on the site, and staff manage its cars (it has no portal sign-in yet; add its email on the partner page and invite it later).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Partners</b> &gt; the partner. <b class="gd-ui">Pricing</b> shows how it is paid: the renter pays the partner&#39;s sheet rate plus the markup (10% unless you set another), rounded to the nearest dollar; CarmaCars keeps the markup plus its cut (20% of the sheet rate); the partner is owed the rest of its sheet rate. Press <b class="gd-ui">Edit pricing</b> to change the markup, the cut or the basis for every car at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Cars</b> lists each car with its sheet rates a day (1 to 2 days, 3 or more, 7 or more) and the renter&#39;s rates. Press <b class="gd-ui">Edit</b> on a car to change a negotiated rate, give that car its own markup or cut, mark it <b class="gd-ui">Insurance included</b> or <b class="gd-ui">No credit card needed</b>, or confirm its model year. The renter&#39;s rates change at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The site shows these cars with their tiers (1 to 2 days, 3 to 6 days, 7 days or more) and &quot;Guideline rates; final price confirmed after review&quot;. A car with insurance included needs no coverage choice from the renter (coverage option 4, confirmed by itself); a car with no credit card needed takes a debit card for the payment and the deposit. The deposit, the licence and identity checks and the ages stay the same.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The price sheet has no years, VINs or plates. Until you confirm the year, the site leaves it out and says &quot;Year confirmed when you book&quot;; an offer waits until the year is confirmed (Edit on the car, Model year). Add the plate and the VIN on the car&#39;s page before its first handover.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Real photos: open the car (its name in Cars), <b class="gd-ui">Photos</b>, and add them. Once approved they replace the eight studio stand-ins.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The partner&#39;s monthly statement shows each rental at the sheet rate, the cut and the payout; never what the renter paid. A refund lowers the partner&#39;s share in proportion; a discount CarmaCars gives comes out of the markup.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-a-partner-s-crm-01-motors-gohighlevel" data-gd-task><h2 class="gd-h2">A partner&#39;s CRM (01 Motors&#39; GoHighLevel)</h2><p class="gd-p"><b class="gd-ui">Settings</b>, the <b class="gd-ui">Partners</b> tile, then the partner (or <b class="gd-ui">CRM link</b> on the partner&#39;s page). Their CRM gets our cars, kept up to date, and their cars come to us.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Ask the partner for a Private Integration token and their location ID (the box <b class="gd-ui">What 01 Motors gives us</b> on the page says exactly what to create and which scopes to tick). Paste both and press <b class="gd-ui">Connect</b>. The token goes to the vault; the page only ever shows its last four characters.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Connect tests the link (their location, objects, products and pipelines) and runs the first sync. After that it runs by itself every 15 minutes, and within five minutes of a change to a car, a rate, a photo, a booking or a block. <b class="gd-ui">Test connection</b> and <b class="gd-ui">Run sync now</b> do it at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">What 01 Motors sees</b>: CarmaCars&#39; own cars and program owners&#39; cars that are on the site, with rates, the next 60 days and photos, as records of a &quot;CarmaCars Vehicles&quot; object in their CRM (or as products when their plan has no custom objects). Partner cars are never sent: not theirs, not another partner&#39;s. Press <b class="gd-ui">Change what we share</b> to leave out program owners&#39; cars, rates, availability or photos.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Partner price</b>: the site&#39;s rates, or the site&#39;s rates less (or plus) a percentage, to the nearest dollar.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Their cars coming in</b>: name the object in their CRM that holds their cars (Test connection lists them), or their feed address. Each of their cars is matched to their car here, or added as their partner car (it waits off the site unless you choose otherwise), with their rates as its sheet rates, their booked dates as calendar blocks and their photos for a car with none. A car that waits shows <b class="gd-ui">Add as their car</b>, <b class="gd-ui">Link</b> or <b class="gd-ui">Set aside</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Leads both ways</b> (off until you turn it on): requests for their cars, and requests that came through their booking links, become contacts and opportunities in the pipeline stage you choose; an opportunity they move to the stage you name becomes a lead in <b class="gd-ui">Leads</b>.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><b class="gd-ui">Feed, widget and booking links</b>: a JSON or CSV feed and a widget for their GoHighLevel funnels and sites (copy the iframe), and booking links carmacars.ca/p/01-motors/&lt;car&gt; that mark the request as theirs for 30 days. <b class="gd-ui">New key</b> ends the old feed and widget addresses at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A link that has failed for an hour shows on Admin &gt; Today. Disconnect deletes the token from the vault; what is already in their CRM stays there.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-rental-by-hand" data-gd-task><h2 class="gd-h2">Add a rental by hand</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>. For phone, walk-in, Turo, partner and insurer bookings, the owner using their own car, and placeholders: a rental already agreed. To send an offer instead, use Send an offer.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Standing with the renter at pickup? Press <b class="gd-ui">Start at pickup</b>: type the renter&#39;s name and phone, choose the car, type the kilometres and the fuel, and press <b class="gd-ui">Hold the car and finish later</b>. The pickup is now; the car is held for 2 hours (renewed while you work on it) and you get a task to finish the rental.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Nothing is required to save: the form is saved as a draft as you type (<b class="gd-ui">Save draft</b> saves at once). Unfinished rentals, on Bookings and on this page, lists every draft with who started it, when, and what is still missing; Finish it opens it where it was left, on any device. Tick Hold the car while I finish to keep the car off the calendar while you type (2 hours, renewed as you save). Discard drops it and frees the car.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Quick start sets the usual choices in one tap: <b class="gd-ui">Phone</b>, <b class="gd-ui">Walk-in</b>, <b class="gd-ui">Turo or another platform</b>, <b class="gd-ui">Insurance replacement</b>, <b class="gd-ui">Owner using own car</b> or <b class="gd-ui">Placeholder</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Choose the car and the dates. The calendar and the price are checked by themselves: clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">We deliver it, or we pick it up: pick the address from the suggestions and its distance from our location prices the delivery (shown under the address), as on Send an offer.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Check the price: every line of the price can be changed where it stands. Type a new amount in the line (the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the deposit, the kilometres a day); HST and the total follow. Add a line from the list or a charge of its own; Remove takes a fee off. The (i) beside each line says what it is and how it is worked out. One optional reason covers all the changes.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Any length: the dates may run past 30 days (up to the staff limit in Program settings, 730 days by default). From 30 days the rental charge is the monthly rate for each 30 days, and the monthly periods are listed. On the booking, Monthly periods shows each period: its share, and its own version of the agreement (CarmaCars&#39; and Blind Spot&#39;s), sent to the renter to sign a few days before it starts (Program settings: long_rental_agreement_lead_days, 3 by default), with what is due for it on the renter&#39;s Balance due. With Program settings, Charge the saved card for each period, on, that share is charged to the saved card when the agreement goes out (the renter gets the receipt; a declined or missing card gives Finance a task).</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">An owner&#39;s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner&#39;s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press <b class="gd-ui">Insurer confirmed</b> once the insurer confirms it.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Insurer billed later (or the Insurance replacement quick start): choose the insurer (Not listed: type its name, and it is added to the list), the claim number, the adjuster, the days and the daily rate authorized, the provisional end, and whether the insurer pays everything or the rental only. The booking is billed to the insurer; the renter owes only what it does not cover. The daily rate authorized is filled from the insurer&#39;s rate sheet for the car (Insurance replacements: rates and billing); a different rate needs the reason.</div></li><li><span class="gd-n" aria-hidden="true">13</span><div class="gd-t">The rent is paid by: e-Transfer or cash (received), card on file (charged when the renter signs), payment link, platform payout (Turo), insurer billed later, cheque, bank transfer, or unpaid. Paid in parts (some cash, some e-Transfer): press <b class="gd-ui">Add another payment (paid in parts)</b> and type each amount. Then the deposit, its own way: card hold, cash, e-Transfer (with its reference and date) or no deposit.</div></li><li><span class="gd-n" aria-hidden="true">14</span><div class="gd-t">Before you save checks it all in one box: the renter, the car, the days, the total, what was received and what is still to collect, the deposit and the agreement.</div></li><li><span class="gd-n" aria-hidden="true">15</span><div class="gd-t">The rental agreement: Send it to sign online, or Already signed on paper (a task asks for the scan). The calendar: untick Blocks the car&#39;s calendar for an insurance replacement with dates not known yet, with the reason.</div></li><li><span class="gd-n" aria-hidden="true">16</span><div class="gd-t">Tick <b class="gd-ui">Do not email the renter</b> if they should not get the confirmation. Press <b class="gd-ui">Add the rental</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, <b class="gd-ui">Verified in person</b> records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-retire-or-delete-a-car" data-gd-task><h2 class="gd-h2">Retire or delete a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Retire or delete</b>, or the car&#39;s own page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Retire this car</b> takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. <b class="gd-ui">Restore</b> brings it back.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Delete this car</b> removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On the same page, <b class="gd-ui">Delete all sample cars</b> deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-sample-cars-on-the-site" data-gd-task><h2 class="gd-h2">Sample cars on the site</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, or <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Site</b>. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Hide sample cars</b> asks first (&quot;Hide all 20 sample cars from the site?&quot;); press <b class="gd-ui">Hide them</b> to take every sample car off the site at once, or <b class="gd-ui">Keep them</b>. Nothing else stops it: not an enquiry, not an old request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Show sample cars</b> puts the 20 back, with their photos and rates. Ones that were deleted are made again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the site each one is marked &quot;Example car&quot;. They never appear in search engines or the sitemap.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A request on a sample car is never a booking. When the person picks dates, the car page and the request form show a real car free for them (the same make and model first, else the same class and body at a similar price) with one tap to switch to it. If they keep the sample car, it becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car, naming the free real car.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-why-a-car-is-not-on-the-site-yet" data-gd-task><h2 class="gd-h2">Why a car is not on the site yet</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, the card Not on the site yet.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The same car is a line on To do with <b class="gd-ui">Set rates and publish</b>. The car comes off both once it is on the site.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-tolls-when-two-rentals-overlap" data-gd-task><h2 class="gd-h2">Tolls when two rentals overlap</h2><p class="gd-p">Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.</p></section>');
select app.guide_release_section('admin', 'insurance-replacements-rates-and-billing', 'chapter', 'partners-company-cars-and-rentals-added-by-hand', null, 'Insurance replacements: rates and billing', 'The rate sheet by insurer and car class, the rate on a rental, the invoices and the billing history.',
  'Each insurance company pays an agreed rate a day for a replacement car, by car class. The rate sheet keeps those rates with their history; a rental billed to an insurer takes its rate from it, the insurer''s invoice follows it, and each insurer''s page shows what it was billed, paid and still owes.

## The rate sheet

Open **Money** > **Insurer rates**.

1. One row for each insurer, one column for each car class (the list in Settings > Vehicle classes). Each cell shows the rate today and, under it, a rate already saved for a later date. On a phone each insurer is a card with its classes.
2. Press **Set** (or **Change**) in a cell. Type the Daily rate and, when the insurer has them, a weekly cap, a cap for 30 days, a delivery and pickup allowance, the kilometres a day and a taxes note (printed on its invoices). Choose From, say why it changed, and press **Save the rate**.
3. A change never overwrites the rate before it: it is a new rate from its date, and the earlier one stays in the history. **End** stops a rate from a date.
4. Add an insurer, or change its billing contact and email, in Settings > Insurers.

> Good to know: A car takes the rate of its pricing class; when the insurer has no rate for that class, the rate of the car''s other classes, in the order of the list. A 2024 Jetta (standard, also a sedan) replaced for an insurer that pays $65 a day for sedans is billed $65 a day.

## The rate on a rental

- Add a rental, Insurance replacement (or Insurer billed later): once the price is checked and the insurer chosen, the daily rate authorized is filled from its rate sheet for the car, with the caps and the taxes note under it.
- A different rate: type it, and Differs from the rate sheet asks for the reason. The rental is not added without it. Empty the field to take the sheet''s rate again.
- The review screen of a request or an offer does the same when you choose Bill to and the insurer: the rate follows the insurer chosen, and a rate typed that differs needs the reason.
- An insurer with no rate for the car: type the rate the adjuster authorized, as before.
- The booking''s Insurance replacement card (Overview and Money tabs) shows the insurer and the claim, the daily rate and where it comes from, Differs with the reason when it is not the sheet''s, the caps, the days covered, what the insurer pays and its invoices.

## Invoices to the insurer

- **Draft insurer invoice** on the booking bills the insurer at the booking''s daily rate (the sheet''s, or the one typed with its reason) for the days authorized.
- The weekly cap and the cap for 30 days lower the amount of a long rental. Billed for the rental only, the insurer also pays delivery and pickup up to its allowance; billed for everything, delivery and pickup above the allowance are the renter''s.
- The invoice line says the rate and where it comes from (for example at $65.00 a day, Example Mutual rate sheet, Sedan), and the PDF prints the taxes note. Send it and record its payments in Money > Insurer invoices, as before.

## Billing history

**Money** > **Insurer rates**, then the insurer''s name.

1. The tiles: bookings, days used and authorized, billed, paid, outstanding, the average daily rate and the days the insurer takes to pay (from sent to paid).
2. Rates by class (Set, Change and End work here too), then the History of the rates: each rate with its dates, its status, why it changed and who saved it.
3. Billing by class: for each class the bookings, days authorized and used, billed, paid, outstanding, the average rate and the days to pay.
4. Bookings: each booking with its class, claim, dates, days, rate (Sheet and the reason when it differs), what was billed, paid and outstanding, and its invoices (each opens its PDF).
5. Choose Picked up from and to and press **Show** for a period. **Download CSV** saves the bookings of the period for a spreadsheet.
',
  '<p class="gd-p">Each insurance company pays an agreed rate a day for a replacement car, by car class. The rate sheet keeps those rates with their history; a rental billed to an insurer takes its rate from it, the insurer&#39;s invoice follows it, and each insurer&#39;s page shows what it was billed, paid and still owes.</p><section class="gd-task" id="insurance-replacements-rates-and-billing-the-rate-sheet" data-gd-task><h2 class="gd-h2">The rate sheet</h2><p class="gd-p">Open <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Insurer rates</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">One row for each insurer, one column for each car class (the list in Settings &gt; Vehicle classes). Each cell shows the rate today and, under it, a rate already saved for a later date. On a phone each insurer is a card with its classes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Set</b> (or <b class="gd-ui">Change</b>) in a cell. Type the Daily rate and, when the insurer has them, a weekly cap, a cap for 30 days, a delivery and pickup allowance, the kilometres a day and a taxes note (printed on its invoices). Choose From, say why it changed, and press <b class="gd-ui">Save the rate</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A change never overwrites the rate before it: it is a new rate from its date, and the earlier one stays in the history. <b class="gd-ui">End</b> stops a rate from a date.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add an insurer, or change its billing contact and email, in Settings &gt; Insurers.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A car takes the rate of its pricing class; when the insurer has no rate for that class, the rate of the car&#39;s other classes, in the order of the list. A 2024 Jetta (standard, also a sedan) replaced for an insurer that pays $65 a day for sedans is billed $65 a day.</div></aside></section><section class="gd-task" id="insurance-replacements-rates-and-billing-the-rate-on-a-rental" data-gd-task><h2 class="gd-h2">The rate on a rental</h2><ul class="gd-ul"><li>Add a rental, Insurance replacement (or Insurer billed later): once the price is checked and the insurer chosen, the daily rate authorized is filled from its rate sheet for the car, with the caps and the taxes note under it.</li><li>A different rate: type it, and Differs from the rate sheet asks for the reason. The rental is not added without it. Empty the field to take the sheet&#39;s rate again.</li><li>The review screen of a request or an offer does the same when you choose Bill to and the insurer: the rate follows the insurer chosen, and a rate typed that differs needs the reason.</li><li>An insurer with no rate for the car: type the rate the adjuster authorized, as before.</li><li>The booking&#39;s Insurance replacement card (Overview and Money tabs) shows the insurer and the claim, the daily rate and where it comes from, Differs with the reason when it is not the sheet&#39;s, the caps, the days covered, what the insurer pays and its invoices.</li></ul></section><section class="gd-task" id="insurance-replacements-rates-and-billing-invoices-to-the-insurer" data-gd-task><h2 class="gd-h2">Invoices to the insurer</h2><ul class="gd-ul"><li><b class="gd-ui">Draft insurer invoice</b> on the booking bills the insurer at the booking&#39;s daily rate (the sheet&#39;s, or the one typed with its reason) for the days authorized.</li><li>The weekly cap and the cap for 30 days lower the amount of a long rental. Billed for the rental only, the insurer also pays delivery and pickup up to its allowance; billed for everything, delivery and pickup above the allowance are the renter&#39;s.</li><li>The invoice line says the rate and where it comes from (for example at $65.00 a day, Example Mutual rate sheet, Sedan), and the PDF prints the taxes note. Send it and record its payments in Money &gt; Insurer invoices, as before.</li></ul></section><section class="gd-task" id="insurance-replacements-rates-and-billing-billing-history" data-gd-task><h2 class="gd-h2">Billing history</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Insurer rates</b>, then the insurer&#39;s name.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tiles: bookings, days used and authorized, billed, paid, outstanding, the average daily rate and the days the insurer takes to pay (from sent to paid).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Rates by class (Set, Change and End work here too), then the History of the rates: each rate with its dates, its status, why it changed and who saved it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Billing by class: for each class the bookings, days authorized and used, billed, paid, outstanding, the average rate and the days to pay.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Bookings: each booking with its class, claim, dates, days, rate (Sheet and the reason when it differs), what was billed, paid and outstanding, and its invoices (each opens its PDF).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Choose Picked up from and to and press <b class="gd-ui">Show</b> for a period. <b class="gd-ui">Download CSV</b> saves the bookings of the period for a spreadsheet.</div></li></ol></div></section>');
select app.guide_release_section('admin', 'settings', 'chapter', 'search-car-pages-landing-pages-and-guides', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.
9. Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task).
10. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
11. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
12. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record paper signature**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Promo codes: end dates and reminders

**Settings** > **All settings**, **Promo codes**.

- Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.
- A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.
- A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with "This code has expired".
- A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.
- The list shows each code''s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.

## Reviews: review requests and Google

**Settings** > **Reviews**: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.

1. When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.
2. The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile''s own review link.
3. Google Business Profile: press **Connect Google** and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.
4. A clear match stops that renter''s reminders at once. A possible match waits in Reviews: press **Confirm**, **Not this renter** or **Match to a booking**.

> Tip: Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.
', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.
9. Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task).
10. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
11. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
12. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record paper signature**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes. Its rates by car class are in **Money** > **Insurer rates**.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Promo codes: end dates and reminders

**Settings** > **All settings**, **Promo codes**.

- Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.
- A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.
- A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with "This code has expired".
- A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.
- The list shows each code''s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.

## Reviews: review requests and Google

**Settings** > **Reviews**: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.

1. When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.
2. The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile''s own review link.
3. Google Business Profile: press **Connect Google** and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.
4. A clear match stops that renter''s reminders at once. A possible match waits in Reviews: press **Confirm**, **Not this renter** or **Match to a booking**.

> Tip: Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.
',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: Blind Spot&#39;s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company&#39;s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task).</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;Signed here by hand, in ink&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with <b class="gd-ui">Record paper signature</b>. Each form not checked yet is also a line on To do with the same button and Preview it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form&#39;s notes list what to tick or choose at the counter.</div></aside></section><section class="gd-task" id="settings-blind-spot-rental-agreement" data-gd-task><h2 class="gd-h2">Blind Spot rental agreement</h2><p class="gd-p">We rent under Blind Spot Car Rental&#39;s insurance, so every booking has two agreements: CarmaCars&#39; rental agreement and Blind Spot&#39;s own. Blind Spot&#39;s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. The Blind Spot Car Rental agreement card is first. Press <b class="gd-ui">Upload Blind Spot&#39;s PDF</b> and choose Blind Spot&#39;s blank form (2 pages, A4).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled sample</b>: a made-up booking on the form. <b class="gd-ui">Sample billed to an insurer</b> also fills the claim number, the adjuster and the insurance company. Check every box.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars&#39; HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative&#39;s signature instead of Sam&#39;s.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for bookings</b>. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A new version of Blind Spot&#39;s form? Upload it the same way: it waits for <b class="gd-ui">Checked: use for bookings</b>, and bookings keep the version in use until then.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.</div></aside><p class="gd-p">The renter&#39;s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking&#39;s Drivers and documents tab, in the renter&#39;s Documents, and the signed Blind Spot agreement is attached to the &quot;Your signed rental agreement&quot; email. Admin &gt; Today lists the HST number, the upload and the check until they are done.</p></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes. Its rates by car class are in <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Insurer rates</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section><section class="gd-task" id="settings-promo-codes-end-dates-and-reminders" data-gd-task><h2 class="gd-h2">Promo codes: end dates and reminders</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, <b class="gd-ui">Promo codes</b>.</p><ul class="gd-ul"><li>Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.</li><li>A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.</li><li>A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with &quot;This code has expired&quot;.</li><li>A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.</li><li>The list shows each code&#39;s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.</li></ul></section><section class="gd-task" id="settings-card-coverage-which-credit-cards-include-rental-car-coverage" data-gd-task><h2 class="gd-h2">Card coverage: which credit cards include rental car coverage</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Card coverage</b> is the list renters see at <span class="gd-url">carmacars.ca/credit-card-rental-coverage</span> and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer&#39;s own document, and when it was last checked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a card under Change a card, open its official guide, correct what changed and press <b class="gd-ui">Save</b>. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A card whose numbers come from a published summary has Read in the issuer&#39;s own document unticked and the summary&#39;s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer&#39;s guide.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer&#39;s guide.</div></aside></section><section class="gd-task" id="settings-reviews-review-requests-and-google" data-gd-task><h2 class="gd-h2">Reviews: review requests and Google</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Reviews</b>: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile&#39;s own review link.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Google Business Profile: press <b class="gd-ui">Connect Google</b> and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A clear match stops that renter&#39;s reminders at once. A possible match waits in Reviews: press <b class="gd-ui">Confirm</b>, <b class="gd-ui">Not this renter</b> or <b class="gd-ui">Match to a booking</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and &quot;I already left a review&quot;, Mark reviewed and on-site reviews still stop the messages.</div></aside></section>');
-- GUIDES 0163 END
