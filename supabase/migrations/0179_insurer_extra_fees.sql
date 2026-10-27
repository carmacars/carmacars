-- 0179_insurer_extra_fees.sql
-- The charges CarmaCars bills an insurer on an insurance replacement rental (docs/changes/2026-10-27-insurer-extra-fees.md).
-- The owner, October 27, 2026: VLF, LDW, T&LDW, PAP/PEC and Waiver Saver are charged to the insurer and printed on Blind
-- Spot's rental agreement (boxes 43, 45, 46, 47 and Waiver Saver); "only add those fields for insurer bookings".
--
-- 1. Five charges (fee_types): vlf, ldw, tldw, pap_pec, waiver_saver. Fees a day like the winter tire or the young driver
--    fee (family fee, company revenue, HST applies, priced at booking), with no default price: staff type the rate a day
--    on each booking (fee_defaults amount null), and the line is the rate times the rental days.
-- 2. The rate a day of each, per booking: booking_insurer_fees. Set by staff where an insurer rental is entered or priced:
--    Add a rental (insurance replacement), the review screen of a request or an offer billed to an insurer (Save, Send
--    offer, Edit offer), and the booking's Insurance replacement card (app.booking_insurer_fees_set, the door's
--    insurer_fees_set). Each change is recorded (booking_fee_changes and the booking's history).
-- 3. Insurer bookings only: a booking billed to the renter is refused, in words, by the database (the rates, the price
--    lines, a fee set by hand and a booking switched back to the renter while it still has them).
-- 4. The price (app.price_lines) adds one line a charge, rate x days, with HST; Add a rental's check prices them too. The
--    insurer pays them on a booking billed to it wholly or for the rental only (app.booking_insurer_share), and its
--    invoice lists each on its own line (app.draft_insurer_invoice). The agreements print them as price lines (Blind
--    Spot: each in its box, web/src/features/blindspot/layout.ts).
-- No applied migration is edited.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0179: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the charges
insert into fee_types (code, label, family, unit, per_what, revenue_class, hst_applies, hst_as_invoiced, stage,
                       refundable_by_tier, change_default, change_vehicle, change_booking, in_master_spec, sort_order) values
  ('vlf',          'VLF (vehicle licence fee)',                          'fee', 'per_day', 'rental', 'company_only', true, false, 'booking', true, false, false, true, false, 111),
  ('ldw',          'LDW (loss damage waiver)',                           'fee', 'per_day', 'rental', 'company_only', true, false, 'booking', true, false, false, true, false, 112),
  ('tldw',         'T&LDW (theft and loss damage waiver)',               'fee', 'per_day', 'rental', 'company_only', true, false, 'booking', true, false, false, true, false, 113),
  ('pap_pec',      'PAP/PEC (personal accident and effects coverage)',   'fee', 'per_day', 'rental', 'company_only', true, false, 'booking', true, false, false, true, false, 114),
  ('waiver_saver', 'Waiver Saver',                                       'fee', 'per_day', 'rental', 'company_only', true, false, 'booking', true, false, false, true, false, 115)
on conflict (code) do nothing;
insert into fee_defaults (fee_type_code, vehicle_class, amount_cents, note, effective_from)
select c, null, null, 'per day; typed on each insurer booking (no default price)', date '2026-01-01'
  from unnest(array['vlf', 'ldw', 'tldw', 'pap_pec', 'waiver_saver']) c
 where not exists (select 1 from fee_defaults d where d.fee_type_code = c);

-- the codes, in the order of the form
create or replace function app.insurer_fee_codes() returns text[]
language sql immutable set search_path = public, app as $$
  select array['vlf', 'ldw', 'tldw', 'pap_pec', 'waiver_saver']
$$;

-- a booking these charges may go on: billed to an insurer (wholly, or the rental only), not an owner's own booking
create or replace function app.booking_bills_insurer(b bookings) returns boolean
language sql stable set search_path = public, app as $$
  select coalesce(b.bill_to, 'renter') <> 'renter' and b.insurer_id is not null and b.booking_type is distinct from 'owner'
$$;

-- the refusal, in words
create or replace function app.insurer_fee_refusal(p_booking_number text) returns text
language sql stable set search_path = public, app as $$
  select 'VLF, LDW, T&LDW, PAP/PEC and Waiver Saver are charged to an insurer only: '
      || coalesce('booking ' || p_booking_number || ' is', 'this rental is') || ' paid by the renter. Bill it to the insurer first (Bill to, or Insurer billed later)'
$$;

-- one price line a charge: rate x days, its HST (p_fees: {code: rate a day in cents}; 0 or null: none)
create or replace function app.insurer_fee_lines(p_fees jsonb, p_days integer, p_hst integer) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  c text;
  v jsonb;
  v_rate bigint;
  v_lines jsonb := '[]'::jsonb;
  v_days integer := greatest(coalesce(p_days, 0), 0);
begin
  if p_fees is null or jsonb_typeof(p_fees) <> 'object' then return v_lines; end if;
  for c in select x from jsonb_object_keys(p_fees) x loop
    if not c = any (app.insurer_fee_codes()) then
      raise exception 'Not a charge to the insurer: % (VLF, LDW, T&LDW, PAP/PEC or Waiver Saver)', c using errcode = '22023';
    end if;
  end loop;
  foreach c in array app.insurer_fee_codes() loop
    v := p_fees -> c;
    if v is null or jsonb_typeof(v) = 'null' then continue; end if;
    if jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric < 0 or (v #>> '{}')::numeric <> round((v #>> '{}')::numeric) then
      raise exception 'Type the rate a day of % in dollars and cents (0 or empty: none)', (select f.label from fee_types f where f.code = c) using errcode = '22023';
    end if;
    v_rate := (v #>> '{}')::bigint;
    if v_rate = 0 or v_days = 0 then continue; end if;
    v_lines := v_lines || app.price_line(c, v_days, v_rate, v_rate * v_days, p_hst,
      (select f.label from fee_types f where f.code = c) || format(': %s day%s at %s a day', v_days, case when v_days = 1 then '' else 's' end, app.fmt_money(v_rate)),
      null, jsonb_build_object('per_day_cents', v_rate, 'days', v_days, 'insurer_fee', true));
  end loop;
  return v_lines;
end $$;

-- ================================================================ 2. the rate a day, per booking
create table if not exists booking_insurer_fees (
  id            uuid primary key default gen_random_uuid(),
  booking_id    uuid not null references bookings (id) on delete cascade,
  fee_type_code text not null references fee_types (code) check (fee_type_code in ('vlf', 'ldw', 'tldw', 'pap_pec', 'waiver_saver')),
  rate_cents    bigint not null check (rate_cents > 0),
  set_by        uuid references users (id),
  set_at        timestamptz not null default now(),
  unique (booking_id, fee_type_code)
);
comment on table booking_insurer_fees is 'The rate a day of each charge CarmaCars bills an insurer on one booking (0179): VLF, LDW, T&LDW, PAP/PEC, Waiver Saver. The price line is the rate times the rental days. Insurer-billed bookings only.';
alter table booking_insurer_fees enable row level security;
drop policy if exists admin_all on booking_insurer_fees;
create policy admin_all on booking_insurer_fees for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop policy if exists staff_read on booking_insurer_fees;
create policy staff_read on booking_insurer_fees for select to authenticated using (app.is_staff());
revoke all on booking_insurer_fees from anon, authenticated;
grant select on booking_insurer_fees to authenticated;
grant all on booking_insurer_fees to service_role;
drop trigger if exists audit_booking_insurer_fees on booking_insurer_fees;
create trigger audit_booking_insurer_fees after insert or update or delete on booking_insurer_fees for each row execute function app.audit_row();

-- ================================================================ 3. insurer bookings only
-- a rate kept for a booking billed to the renter
create or replace function app.booking_insurer_fees_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  select * into b from bookings where id = new.booking_id;
  if b.id is null or not app.booking_bills_insurer(b) then
    raise exception '%', app.insurer_fee_refusal(b.booking_number) using errcode = '23514';
  end if;
  return new;
end $$;
drop trigger if exists booking_insurer_fees_guard on booking_insurer_fees;
create trigger booking_insurer_fees_guard before insert or update on booking_insurer_fees for each row execute function app.booking_insurer_fees_guard();

-- a price line of these charges on a booking billed to the renter (whatever wrote it)
create or replace function app.booking_line_insurer_fee_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  if new.charge_type = any (app.insurer_fee_codes()) and new.voided_at is null then
    select * into b from bookings where id = new.booking_id;
    if b.id is null or not app.booking_bills_insurer(b) then
      raise exception '%', app.insurer_fee_refusal(b.booking_number) using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists booking_line_insurer_fee_guard on booking_line_items;
create trigger booking_line_insurer_fee_guard before insert or update of charge_type, voided_at, booking_id on booking_line_items
  for each row execute function app.booking_line_insurer_fee_guard();

-- a booking switched back to the renter (or to an owner's booking) while it still carries them
create or replace function app.booking_insurer_fees_keep_trg() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.booking_bills_insurer(new) and (
       exists (select 1 from booking_insurer_fees f where f.booking_id = new.id)
       or exists (select 1 from booking_line_items li where li.booking_id = new.id and li.voided_at is null and li.charge_type = any (app.insurer_fee_codes()))) then
    raise exception 'Booking % has charges to the insurer (VLF, LDW, T&LDW, PAP/PEC or Waiver Saver): remove them before it is billed to the renter', new.booking_number
      using errcode = '23514';
  end if;
  return null;
end $$;
drop trigger if exists bookings_insurer_fees_keep on bookings;
create trigger bookings_insurer_fees_keep after update of bill_to, insurer_id, booking_type on bookings
  for each row when (old.bill_to is distinct from new.bill_to or old.insurer_id is distinct from new.insurer_id or old.booking_type is distinct from new.booking_type)
  execute function app.booking_insurer_fees_keep_trg();

-- Set the rates a day on a booking (staff): p {code: cents a day, or 0 / null to remove}. Recorded, the booking repriced.
create or replace function app.booking_insurer_fees_set(p_by uuid, p_booking uuid, p jsonb, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  k text;
  v jsonb;
  v_rate bigint;
  v_before jsonb := '{}'::jsonb;
  v_after bigint;
  v_changes jsonb := '[]'::jsonb;
  v_total0 bigint;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not app.user_is_staff(p_by) then
    raise exception 'Only CarmaCars staff set the charges to an insurer' using errcode = '42501';
  end if;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if p is null or jsonb_typeof(p) <> 'object' or p = '{}'::jsonb then
    return jsonb_build_object('ok', true, 'booking_number', b.booking_number, 'changes', '[]'::jsonb, 'total_cents', b.total_due_at_booking_cents);
  end if;
  -- the keys and amounts (the same check as the price)
  perform app.insurer_fee_lines(p, 1, 0);
  if b.status in ('cancelled', 'declined', 'expired', 'no_show')
     or (b.status = 'closed' and coalesce(current_setting('app.insurer_fees_new', true), '') <> 'on') then
    raise exception 'Booking % is %: its charges no longer change here', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
  end if;
  if exists (select 1 from jsonb_each(p) e where jsonb_typeof(e.value) = 'number' and (e.value #>> '{}')::numeric > 0) and not app.booking_bills_insurer(b) then
    raise exception '%', app.insurer_fee_refusal(b.booking_number) using errcode = '23514';
  end if;
  for k in select u.c from unnest(app.insurer_fee_codes()) with ordinality u(c, o) where p ? u.c order by u.o loop
    v_before := v_before || jsonb_build_object(k, app.booking_line_key_cents(b.id, k));
  end loop;
  v_total0 := b.total_due_at_booking_cents;
  for k, v in select e.key, e.value from jsonb_each(p) e loop
    v_rate := case when jsonb_typeof(v) = 'number' then (v #>> '{}')::bigint else 0 end;
    if v_rate > 0 then
      insert into booking_insurer_fees as f (booking_id, fee_type_code, rate_cents, set_by)
      values (b.id, k, v_rate, p_by)
      on conflict (booking_id, fee_type_code) do update set rate_cents = excluded.rate_cents, set_by = excluded.set_by, set_at = now()
        where f.rate_cents is distinct from excluded.rate_cents;
    else
      delete from booking_insurer_fees where booking_id = b.id and fee_type_code = k;
    end if;
  end loop;
  perform app.sync_booking_price(b.id);
  for k in select u.c from unnest(app.insurer_fee_codes()) with ordinality u(c, o) where p ? u.c order by u.o loop
    v_after := app.booking_line_key_cents(b.id, k);
    if (v_before ->> k)::bigint is distinct from v_after then
      insert into booking_fee_changes (booking_id, line_key, label, before_cents, after_cents, reason, booking_status, changed_by)
      values (b.id, k, app.line_key_label(k), (v_before ->> k)::bigint, v_after, coalesce(v_reason, 'Charge to the insurer'), b.status::text, p_by);
      v_changes := v_changes || jsonb_build_object('key', k, 'label', app.line_key_label(k), 'before_cents', (v_before ->> k)::bigint, 'after_cents', v_after);
    end if;
  end loop;
  select * into b from bookings where id = b.id;
  if jsonb_array_length(v_changes) > 0 then
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
      'Charges to the insurer: ' || (select string_agg(format('%s %s to %s', split_part(c ->> 'label', ' (', 1), coalesce(app.fmt_money((c ->> 'before_cents')::bigint), 'none'),
                                                            coalesce(app.fmt_money((c ->> 'after_cents')::bigint), 'none')), '; ')
                                       from jsonb_array_elements(v_changes) c) || coalesce(' (' || v_reason || ')', ''),
      p_by, 'staff', jsonb_build_object('fee_changes', v_changes, 'total_before_cents', v_total0, 'total_after_cents', b.total_due_at_booking_cents));
  end if;
  return jsonb_build_object('ok', true, 'booking_number', b.booking_number, 'changes', v_changes, 'total_cents', b.total_due_at_booking_cents,
                            'total_before_cents', v_total0, 'insurer_share_cents', b.insurer_share_cents, 'insurer_hst_cents', b.insurer_hst_cents,
                            'fees', app.booking_insurer_fees_json(b.id));
end $$;

-- the charges of a booking, for the screens: each with its rate a day, the days and the amount on the booking now
create or replace function app.booking_insurer_fees_json(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', f.code, 'label', f.label,
           'rate_cents', (select x.rate_cents from booking_insurer_fees x where x.booking_id = p_booking and x.fee_type_code = f.code),
           'days', b.billable_days,
           'amount_cents', (select sum(li.amount_cents) from booking_line_items li where li.booking_id = p_booking and li.charge_type = f.code and li.stage = 'booking' and li.voided_at is null),
           'hst_cents', (select sum(li.hst_cents) from booking_line_items li where li.booking_id = p_booking and li.charge_type = f.code and li.stage = 'booking' and li.voided_at is null))
         order by f.sort_order), '[]'::jsonb)
    from fee_types f cross join bookings b
   where b.id = p_booking and f.code = any (app.insurer_fee_codes())
$$;

-- ================================================================ 4. the price
-- price_lines: the booking's charges to the insurer (insurer_fees, with insurer_billed), one line each, rate x days
alter function app.price_lines(jsonb) rename to price_lines_pre0179;
create or replace function app.price_lines(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.price_lines_pre0179(p);
  v_fees jsonb := case when jsonb_typeof(p -> 'insurer_fees') = 'object' then p -> 'insurer_fees' else '{}'::jsonb end;
  v_extra jsonb;
  v_lines jsonb;
  v_sub bigint;
  v_tax bigint;
begin
  if coalesce(p ->> 'booking_type', 'standard') = 'owner' then return v; end if;
  if not coalesce((p ->> 'insurer_billed')::boolean, false) then
    if exists (select 1 from jsonb_each(v_fees) e where jsonb_typeof(e.value) = 'number' and (e.value #>> '{}')::numeric > 0)
       or exists (select 1 from jsonb_array_elements(coalesce(v -> 'lines', '[]'::jsonb)) l where l ->> 'charge_type' = any (app.insurer_fee_codes()) and (l ->> 'amount_cents')::bigint <> 0) then
      raise exception '%', app.insurer_fee_refusal(null) using errcode = '23514';
    end if;
    return v;
  end if;
  v_extra := app.insurer_fee_lines(v_fees, (v ->> 'billable_days')::integer, coalesce((p ->> 'hst_bps')::integer, 0));
  if jsonb_array_length(v_extra) = 0 then return v; end if;
  select coalesce(jsonb_agg(x.value order by (x.value ->> 'sort_order')::integer, x.ord), '[]'::jsonb),
         coalesce(sum((x.value ->> 'amount_cents')::bigint), 0), coalesce(sum((x.value ->> 'hst_cents')::bigint), 0)
    into v_lines, v_sub, v_tax
    from jsonb_array_elements(coalesce(v -> 'lines', '[]'::jsonb) || v_extra) with ordinality x(value, ord);
  return v || jsonb_build_object('lines', v_lines, 'subtotal_cents', v_sub, 'hst_cents', v_tax, 'total_cents', v_sub + v_tax);
end $$;

-- the booking's spec carries whether it bills an insurer, and its rates
alter function app.booking_price_spec(uuid, jsonb) rename to booking_price_spec_pre0179;
create or replace function app.booking_price_spec(p_booking uuid, p_changes jsonb default '{}'::jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.booking_price_spec_pre0179(p_booking, p_changes) || jsonb_build_object(
           'insurer_billed', app.booking_bills_insurer(b),
           'insurer_fees', coalesce((select jsonb_object_agg(f.fee_type_code, f.rate_cents) from booking_insurer_fees f where f.booking_id = p_booking), '{}'::jsonb))
    from bookings b where b.id = p_booking
$$;

-- the booking's price: a charge removed is voided like the other lines the price owns
select pg_temp.patch_fn('app.sync_booking_price(uuid)'::regprocedure,
  $o$'addon', 'baby_seat', 'winter_tire'];$o$,
  $n$'addon', 'baby_seat', 'winter_tire'] || app.insurer_fee_codes();   -- 0179: the charges to the insurer$n$);
-- a charge's line keeps its words up to date (its days and rate are in them)
select pg_temp.patch_fn('app.put_price_line(uuid, jsonb)'::regprocedure,
  $o$     or (v_ba is not null and v_line.description is distinct from p_line ->> 'description')$o$,
  $n$     or ((v_ba is not null or v_line.charge_type = any (app.insurer_fee_codes())) and v_line.description is distinct from p_line ->> 'description')$n$);
select pg_temp.patch_fn('app.put_price_line(uuid, jsonb)'::regprocedure,
  $o$           description = case when v_ba is not null then p_line ->> 'description'$o$,
  $n$           description = case when v_ba is not null or charge_type = any (app.insurer_fee_codes()) then p_line ->> 'description'$n$);

-- a fee set by hand (0132) is never one of these: they are a rate a day
alter function app.booking_line_overrides_store(uuid, uuid, jsonb, text) rename to booking_line_overrides_store_pre0179;
create or replace function app.booking_line_overrides_store(p_booking uuid, p_by uuid, p jsonb, p_reason text default null) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  k text;
begin
  if p is not null and jsonb_typeof(p) = 'object' then
    for k in select x from jsonb_object_keys(p) x loop
      if k = any (app.insurer_fee_codes()) then
        raise exception '% is charged to the insurer a day: type its rate a day under Charges to the insurer', (select f.label from fee_types f where f.code = k) using errcode = '22023';
      end if;
    end loop;
  end if;
  return app.booking_line_overrides_store_pre0179(p_booking, p_by, p, p_reason);
end $$;

-- ================================================================ 5. the insurer pays them, its invoice lists them
-- Billed to the insurer wholly, they were already among the fees it pays; billed for the rental only (split), the insurer
-- pays these too (they are its charges, never the renter's).
alter function app.booking_insurer_share(uuid) rename to booking_insurer_share_pre0179;
create or replace function app.booking_insurer_share(p_booking uuid)
returns table (covered_days integer, rental_share_cents bigint, fees_share_cents bigint, share_cents bigint, hst_cents bigint)
language plpgsql stable security definer set search_path = public, app as $$
declare
  s record;
  b bookings;
  v_x bigint := 0;
  v_xh bigint := 0;
begin
  select * into s from app.booking_insurer_share_pre0179(p_booking);
  select * into b from bookings where id = p_booking;
  if b.bill_to = 'split' and b.booking_type <> 'owner' then
    select coalesce(sum(li.amount_cents), 0), coalesce(sum(li.hst_cents), 0) into v_x, v_xh
      from booking_line_items li
     where li.booking_id = p_booking and li.voided_at is null and li.charged_to_renter and li.stage in ('booking', 'extension')
       and li.charge_type = any (app.insurer_fee_codes());
  end if;
  return query select s.covered_days, s.rental_share_cents, s.fees_share_cents + v_x, s.share_cents + v_x, s.hst_cents + v_xh;
end $$;

-- The invoice: each charge on its own line ("VLF (vehicle licence fee): 3 days at $5.00 a day"), taken out of the line
-- of the other fees (the total is the same).
alter function app.draft_insurer_invoice(uuid, uuid) rename to draft_insurer_invoice_pre0179;
create or replace function app.draft_insurer_invoice(p_booking uuid, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := app.draft_insurer_invoice_pre0179(p_booking, p_by);
  v_x jsonb;
  v_sum bigint;
  v_n bigint;
  v_fees bigint;
begin
  select coalesce(jsonb_agg(jsonb_build_object('description', li.description, 'amount_cents', li.amount_cents) order by ft.sort_order, li.created_at, li.id), '[]'::jsonb),
         coalesce(sum(li.amount_cents), 0)
    into v_x, v_sum
    from booking_line_items li join fee_types ft on ft.code = li.charge_type
   where li.booking_id = p_booking and li.voided_at is null and li.charged_to_renter and li.stage in ('booking', 'extension')
     and li.charge_type = any (app.insurer_fee_codes()) and li.amount_cents <> 0;
  if v_sum = 0 then return v_id; end if;
  -- the line of the fees: the second one, before "Less: already invoiced"
  select e.n, (e.l ->> 'amount_cents')::bigint into v_n, v_fees
    from insurer_invoices ii cross join lateral jsonb_array_elements(ii.lines) with ordinality e(l, n)
   where ii.id = v_id and e.n > 1 and e.l ->> 'description' <> 'Less: already invoiced'
   order by e.n limit 1;
  if v_n is null or v_fees < v_sum then return v_id; end if;
  update insurer_invoices ii
     set lines = (select jsonb_agg(q.l order by q.k) from (
                    select e.l, e.n * 100 as k from jsonb_array_elements(ii.lines) with ordinality e(l, n) where e.n <> v_n
                    union all
                    select jsonb_set(e.l, '{amount_cents}', to_jsonb(v_fees - v_sum)), e.n * 100 from jsonb_array_elements(ii.lines) with ordinality e(l, n)
                     where e.n = v_n and v_fees - v_sum <> 0
                    union all
                    select f.value, v_n * 100 + f.ord from jsonb_array_elements(v_x) with ordinality f(value, ord)) q)
   where ii.id = v_id;
  return v_id;
end $$;

-- ================================================================ 6. where staff set them
-- The review screen (Save, Send offer, an offer edited in place, its preview): insurer_fees {code: dollars a day in
-- cents, or 0 / null}. A removal first (so a booking can go back to the renter in the same save), the rest after the
-- booking's other changes (so it may become an insurer's in the same save).
alter function app.admin_apply_booking_edit(uuid, uuid, jsonb) rename to admin_apply_booking_edit_pre0179;
create or replace function app.admin_apply_booking_edit(p_admin uuid, p_booking uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_fees jsonb := case when jsonb_typeof(p -> 'insurer_fees') = 'object' then p -> 'insurer_fees' end;
  v_off jsonb;
  v_on jsonb;
  v_reason text := coalesce(nullif(btrim(coalesce(p ->> 'fee_reason', '')), ''), 'Set on the review screen');
begin
  if v_fees is null or v_fees = '{}'::jsonb then
    perform app.admin_apply_booking_edit_pre0179(p_admin, p_booking, p - 'insurer_fees');
    return;
  end if;
  select coalesce(jsonb_object_agg(e.key, e.value) filter (where not (jsonb_typeof(e.value) = 'number' and (e.value #>> '{}')::numeric > 0)), '{}'::jsonb),
         coalesce(jsonb_object_agg(e.key, e.value) filter (where jsonb_typeof(e.value) = 'number' and (e.value #>> '{}')::numeric > 0), '{}'::jsonb)
    into v_off, v_on from jsonb_each(v_fees) e;
  if v_off <> '{}'::jsonb then perform app.booking_insurer_fees_set(p_admin, p_booking, v_off, v_reason); end if;
  perform app.admin_apply_booking_edit_pre0179(p_admin, p_booking, p - 'insurer_fees');
  if v_on <> '{}'::jsonb then perform app.booking_insurer_fees_set(p_admin, p_booking, v_on, v_reason); end if;
end $$;

-- the booking as the review screen reads it: its rates a day
alter function app.admin_booking_json(uuid) rename to admin_booking_json_pre0179;
create or replace function app.admin_booking_json(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.admin_booking_json_pre0179(p_booking) || jsonb_build_object('insurer_fees',
    coalesce((select jsonb_object_agg(f.fee_type_code, f.rate_cents) from booking_insurer_fees f where f.booking_id = p_booking), '{}'::jsonb))
$$;

-- Add a rental: its check prices the charges of an insurance replacement (insurer_fees, with bill_to_insurer) ...
alter function app.manual_rental_quote(uuid, jsonb) rename to manual_rental_quote_pre0179;
create or replace function app.manual_rental_quote(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_fees jsonb := case when jsonb_typeof(p -> 'insurer_fees') = 'object' then p -> 'insurer_fees' else '{}'::jsonb end;
  v_out jsonb := app.manual_rental_quote_pre0179(p_by, p - 'insurer_fees' - 'bill_to_insurer');
  v_extra jsonb;
  v_sub bigint;
  v_tax bigint;
begin
  if not exists (select 1 from jsonb_each(v_fees) e where jsonb_typeof(e.value) = 'number' and (e.value #>> '{}')::numeric > 0) then
    perform app.insurer_fee_lines(v_fees, 1, 0);   -- (the keys and amounts are still checked)
    return v_out;
  end if;
  if not coalesce((p ->> 'bill_to_insurer')::boolean, false) then
    raise exception '%', app.insurer_fee_refusal(null) using errcode = '23514';
  end if;
  if jsonb_typeof(v_out -> 'quote') <> 'object' then return v_out; end if;
  v_extra := app.insurer_fee_lines(v_fees, (v_out #>> '{quote,billable_days}')::integer, coalesce((v_out #>> '{quote,hst_bps}')::integer, (app.settings()).hst_bps));
  select coalesce(sum((l ->> 'amount_cents')::bigint), 0), coalesce(sum((l ->> 'hst_cents')::bigint), 0) into v_sub, v_tax from jsonb_array_elements(v_extra) l;
  v_out := jsonb_set(v_out, '{quote,lines}', coalesce(v_out #> '{quote,lines}', '[]'::jsonb)
                                            || (select coalesce(jsonb_agg((l - 'revenue_class' - 'sort_order') order by o), '[]'::jsonb) from jsonb_array_elements(v_extra) with ordinality x(l, o)));
  v_out := jsonb_set(v_out, '{quote,total_due_at_booking_cents}', to_jsonb(coalesce((v_out #>> '{quote,total_due_at_booking_cents}')::bigint, 0) + v_sub + v_tax));
  if (v_out #>> '{quote,subtotal_cents}') is not null then v_out := jsonb_set(v_out, '{quote,subtotal_cents}', to_jsonb((v_out #>> '{quote,subtotal_cents}')::bigint + v_sub)); end if;
  if (v_out #>> '{quote,hst_cents}') is not null then v_out := jsonb_set(v_out, '{quote,hst_cents}', to_jsonb((v_out #>> '{quote,hst_cents}')::bigint + v_tax)); end if;
  if (v_out #>> '{quote,total_cents}') is not null then v_out := jsonb_set(v_out, '{quote,total_cents}', to_jsonb((v_out #>> '{quote,total_cents}')::bigint + v_sub + v_tax)); end if;
  return v_out;
end $$;

-- ... and the rental keeps them once its insurer is set (an insurance replacement only: Insurer billed later)
alter function app.manual_rental_create(uuid, jsonb) rename to manual_rental_create_pre0179;
create or replace function app.manual_rental_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_fees jsonb := case when jsonb_typeof(p -> 'insurer_fees') = 'object' then jsonb_strip_nulls(p -> 'insurer_fees') else '{}'::jsonb end;
  v_any boolean;
  v_out jsonb;
  v_id uuid;
  b bookings;
begin
  perform app.insurer_fee_lines(v_fees, 1, 0);
  v_any := exists (select 1 from jsonb_each(v_fees) e where jsonb_typeof(e.value) = 'number' and (e.value #>> '{}')::numeric > 0);
  if v_any and not (p #>> '{payment,method}' = 'insurer' and jsonb_typeof(p -> 'insurance') = 'object') then
    raise exception '%', app.insurer_fee_refusal(null) using errcode = '23514';
  end if;
  v_out := app.manual_rental_create_pre0179(p_by, p - 'insurer_fees' - 'bill_to_insurer');
  if not v_any or (v_out ->> 'booking_id') !~ '^[0-9a-f-]{36}$' then return v_out; end if;
  v_id := (v_out ->> 'booking_id')::uuid;
  perform set_config('app.insurer_fees_new', 'on', true);
  perform app.booking_insurer_fees_set(p_by, v_id, v_fees, 'Set when the rental was entered');
  perform set_config('app.insurer_fees_new', '', true);
  select * into b from bookings where id = v_id;
  -- a past rental: its split again, with the charges in it
  if b.status in ('returned', 'closed') then perform app.compute_booking_split(b.id); end if;
  return v_out || jsonb_build_object('total_cents', b.total_due_at_booking_cents, 'due_cents', b.renter_due_at_booking_cents);
end $$;

-- the booking's Insurance replacement card: the charges, each with its rate a day, and whether they can change now
alter function app.booking_insurer_read(uuid, jsonb) rename to booking_insurer_read_pre0179;
create or replace function app.booking_insurer_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.booking_insurer_read_pre0179(p_by, p);
  b bookings;
begin
  if v is null or not coalesce((v ->> 'billed_to_insurer')::boolean, false) then return v; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = p ->> 'booking' limit 1;
  return v || jsonb_build_object('booking_number', b.booking_number, 'extra_fees', app.booking_insurer_fees_json(b.id),
    'extra_fees_editable', b.status not in ('closed', 'cancelled', 'declined', 'expired', 'no_show'));
end $$;

-- ================================================================ 7. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0179;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_booking uuid;
begin
  if p_call in ('ops_do', 'admin_do') and p_name = 'insurer_fees_set' then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    p_ := p_ - '_va';
    perform app.door_begin(p_user, p_aal);
    select id into v_booking from bookings where id::text = p_ ->> 'booking' or booking_number = upper(btrim(coalesce(p_ ->> 'booking', '')));
    if v_booking is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
    return app.booking_insurer_fees_set(p_user, v_booking, p_ -> 'fees', p_ ->> 'reason');
  end if;
  return app.door_pre0179(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 8. privileges
-- the new functions: the server only; a wrapper keeps the grants of the function it wraps (sync_booking_price and
-- put_price_line are replaced in place and keep theirs)
do $$
declare
  f record;
  g text;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['insurer_fee_codes', 'booking_bills_insurer', 'insurer_fee_refusal', 'insurer_fee_lines',
              'booking_insurer_fees_guard', 'booking_line_insurer_fee_guard', 'booking_insurer_fees_keep_trg', 'booking_insurer_fees_set', 'booking_insurer_fees_json'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  for f in
    select * from (values ('app.price_lines(jsonb)', 'app.price_lines_pre0179(jsonb)'),
                          ('app.booking_price_spec(uuid, jsonb)', 'app.booking_price_spec_pre0179(uuid, jsonb)'),
                          ('app.booking_line_overrides_store(uuid, uuid, jsonb, text)', 'app.booking_line_overrides_store_pre0179(uuid, uuid, jsonb, text)'),
                          ('app.booking_insurer_share(uuid)', 'app.booking_insurer_share_pre0179(uuid)'),
                          ('app.draft_insurer_invoice(uuid, uuid)', 'app.draft_insurer_invoice_pre0179(uuid, uuid)'),
                          ('app.admin_apply_booking_edit(uuid, uuid, jsonb)', 'app.admin_apply_booking_edit_pre0179(uuid, uuid, jsonb)'),
                          ('app.admin_booking_json(uuid)', 'app.admin_booking_json_pre0179(uuid)'),
                          ('app.manual_rental_quote(uuid, jsonb)', 'app.manual_rental_quote_pre0179(uuid, jsonb)'),
                          ('app.manual_rental_create(uuid, jsonb)', 'app.manual_rental_create_pre0179(uuid, jsonb)'),
                          ('app.booking_insurer_read(uuid, jsonb)', 'app.booking_insurer_read_pre0179(uuid, jsonb)'),
                          ('app.door(uuid, text, text, text, jsonb)', 'app.door_pre0179(uuid, text, text, text, jsonb)')) x(fn, pre)
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.fn);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, f.pre, 'execute') then execute format('grant execute on function %s to %I', f.fn, g); end if;
    end loop;
  end loop;
end $$;

-- ================================================================ the guides
-- GUIDES 0179 START (generated by supabase/seed/0179_gen_guides.mjs from docs/guides/content; do not edit by hand)
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
8. Check the price: every line of the price can be changed where it stands. Type a new amount in the line (the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the deposit, the kilometres a day); HST and the total follow. Add a line from the list or a charge of its own; Remove takes a fee off. The (i) beside each line says what it is and how it is worked out. One optional reason covers all the changes. At the top of the price, Amounts I type: Before tax, or After tax (HST included) to type what the renter paid for each line ("$270 after tax for the rental, $50 for the Protection Plan"): each is worked back to its amount before tax, and a line without HST stays as typed. The choice is remembered on this device. Or type the Total the renter pays (after tax): the rental charge is worked out so the total is exactly that, to the cent, and the line under it shows each line before tax. The total shown is the total that is saved; if they ever differ, it says by how much before you save.
9. Any length: the dates may run past 30 days (up to the staff limit in Program settings, 730 days by default). From 30 days the rental charge is the monthly rate for each 30 days, and the monthly periods are listed. On the booking, Monthly periods shows each period: its share, and its own version of the agreement (CarmaCars'' and Blind Spot''s), sent to the renter to sign a few days before it starts (Program settings: long_rental_agreement_lead_days, 3 by default), with what is due for it on the renter''s Balance due. With Program settings, Charge the saved card for each period, on, that share is charged to the saved card when the agreement goes out (the renter gets the receipt; a declined or missing card gives Finance a task).
10. A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.
11. An owner''s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner''s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press **Insurer confirmed** once the insurer confirms it.
12. Insurer billed later (or the Insurance replacement quick start): choose the insurer (Not listed: type its name, and it is added to the list), the claim number, the adjuster, the days and the daily rate authorized, the provisional end, and whether the insurer pays everything or the rental only. The booking is billed to the insurer; the renter owes only what it does not cover. The daily rate authorized is filled from the insurer''s rate sheet for the car (Insurance replacements: rates and billing); a different rate needs the reason.
13. The rent is paid by: e-Transfer or cash (received), card on file (charged when the renter signs), payment link, platform payout (Turo), insurer billed later, cheque, bank transfer, or unpaid. Paid in parts (some cash, some e-Transfer): press **Add another payment (paid in parts)** and type each amount. Then the deposit, its own way: card hold, cash, e-Transfer (with its reference and date) or no deposit.
14. Before you save checks it all in one box: the renter, the car, the days, the total, what was received and what is still to collect, the deposit (or No deposit) and the agreement.
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
8. Check the price: every line of the price can be changed where it stands. Type a new amount in the line (the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the deposit, the kilometres a day); HST and the total follow. Add a line from the list or a charge of its own; Remove takes a fee off. The (i) beside each line says what it is and how it is worked out. One optional reason covers all the changes. At the top of the price, Amounts I type: Before tax, or After tax (HST included) to type what the renter paid for each line ("$270 after tax for the rental, $50 for the Protection Plan"): each is worked back to its amount before tax, and a line without HST stays as typed. The choice is remembered on this device. Or type the Total the renter pays (after tax): the rental charge is worked out so the total is exactly that, to the cent, and the line under it shows each line before tax. The total shown is the total that is saved; if they ever differ, it says by how much before you save.
9. Any length: the dates may run past 30 days (up to the staff limit in Program settings, 730 days by default). From 30 days the rental charge is the monthly rate for each 30 days, and the monthly periods are listed. On the booking, Monthly periods shows each period: its share, and its own version of the agreement (CarmaCars'' and Blind Spot''s), sent to the renter to sign a few days before it starts (Program settings: long_rental_agreement_lead_days, 3 by default), with what is due for it on the renter''s Balance due. With Program settings, Charge the saved card for each period, on, that share is charged to the saved card when the agreement goes out (the renter gets the receipt; a declined or missing card gives Finance a task).
10. A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.
11. An owner''s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner''s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press **Insurer confirmed** once the insurer confirms it.
12. Insurer billed later (or the Insurance replacement quick start): choose the insurer (Not listed: type its name, and it is added to the list), the claim number, the adjuster, the days and the daily rate authorized, the provisional end, and whether the insurer pays everything or the rental only. The booking is billed to the insurer; the renter owes only what it does not cover. The daily rate authorized is filled from the insurer''s rate sheet for the car (Insurance replacements: rates and billing); a different rate needs the reason. Charges to the insurer: type the rate a day of VLF, LDW, T&LDW, PAP/PEC or Waiver Saver when the insurer authorized them (Insurance replacements: rates and billing).
13. The rent is paid by: e-Transfer or cash (received), card on file (charged when the renter signs), payment link, platform payout (Turo), insurer billed later, cheque, bank transfer, or unpaid. Paid in parts (some cash, some e-Transfer): press **Add another payment (paid in parts)** and type each amount. Then the deposit, its own way: card hold, cash, e-Transfer (with its reference and date) or no deposit.
14. Before you save checks it all in one box: the renter, the car, the days, the total, what was received and what is still to collect, the deposit (or No deposit) and the agreement.
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
  '<p class="gd-p">A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.</p><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-car" data-gd-task><h2 class="gd-h2">Add a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then <b class="gd-ui">Add a car</b>. Start with the VIN: everything else about the car comes from it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">When the VIN fits several trims, the form asks which trim it is: press the one on the car&#39;s papers or badge, or <b class="gd-ui">Not sure</b> (Admin &gt; Today asks again).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">No VIN at hand? Press <b class="gd-ui">No VIN at hand? Add the car by its plate</b> and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Choose who supplies it: <b class="gd-ui">A program owner&#39;s car</b> (choose the owner; the car starts its onboarding), <b class="gd-ui">CarmaCars-owned (company fleet)</b> (no owner; all of its revenue is CarmaCars&#39;) or <b class="gd-ui">A partner rental company&#39;s car</b> (choose the partner; leave the commission empty to use the partner&#39;s).</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car&#39;s Rates tab. Press <b class="gd-ui">Add the car</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car&#39;s listing; a field you change is kept.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car&#39;s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.</div></aside><p class="gd-p">The gearbox comes from the government&#39;s fuel economy data for the model when it has one gearbox for it, or from the VIN when the VIN states it. Seats come from the VIN, or the usual number for the body (4 for a coupe or convertible, 5 for a sedan, SUV or hatchback). When either is not certain, Admin &gt; Today shows <b class="gd-ui">Confirm gearbox and seats</b>: press the gearbox and the number of seats, then <b class="gd-ui">Save</b>. A car whose VIN fits several trims shows <b class="gd-ui">Pick the trim</b> there: press the right one. Either way the title, description and search text are written again.</p><p class="gd-p">On a car&#39;s page, <b class="gd-ui">Who supplies the car</b> shows the supplier and the commission, and changes them. Vehicles filters by supply type.</p></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-partners" data-gd-task><h2 class="gd-h2">Partners</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Partners</b>. Partner rental companies whose cars we rent out on commission.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Add a partner</b>: business and legal name, contacts, HST number, commission and insurance with its expiry date.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Staff tasks gets a reminder (Program settings sets how many days before).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Banking (Admins only): <b class="gd-ui">Save the payout account</b> for the account we pay the partner into. The account number is stored encrypted. Press <b class="gd-ui">Verify</b> once checked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Portal: <b class="gd-ui">Invite to the owner portal</b> gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Signed on paper? Press <b class="gd-ui">Print the partner agreement</b>, then record the signed scan under Record a paper signature.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-a-partner-fleet-on-its-own-rates" data-gd-task><h2 class="gd-h2">A partner fleet on its own rates</h2><p class="gd-p">Some partners send a price sheet of their own rates instead of sharing what the renter pays. 01 Motors works this way: its whole fleet is on the site, and staff manage its cars (it has no portal sign-in yet; add its email on the partner page and invite it later).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Partners</b> &gt; the partner. <b class="gd-ui">Pricing</b> shows how it is paid: the renter pays the partner&#39;s sheet rate plus the markup (10% unless you set another), rounded to the nearest dollar; CarmaCars keeps the markup plus its cut (20% of the sheet rate); the partner is owed the rest of its sheet rate. Press <b class="gd-ui">Edit pricing</b> to change the markup, the cut or the basis for every car at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Cars</b> lists each car with its sheet rates a day (1 to 2 days, 3 or more, 7 or more) and the renter&#39;s rates. Press <b class="gd-ui">Edit</b> on a car to change a negotiated rate, give that car its own markup or cut, mark it <b class="gd-ui">Insurance included</b> or <b class="gd-ui">No credit card needed</b>, or confirm its model year. The renter&#39;s rates change at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The site shows these cars with their tiers (1 to 2 days, 3 to 6 days, 7 days or more) and &quot;Guideline rates; final price confirmed after review&quot;. A car with insurance included needs no coverage choice from the renter (coverage option 4, confirmed by itself); a car with no credit card needed takes a debit card for the payment and the deposit. The deposit, the licence and identity checks and the ages stay the same.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The price sheet has no years, VINs or plates. Until you confirm the year, the site leaves it out and says &quot;Year confirmed when you book&quot;; an offer waits until the year is confirmed (Edit on the car, Model year). Add the plate and the VIN on the car&#39;s page before its first handover.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Real photos: open the car (its name in Cars), <b class="gd-ui">Photos</b>, and add them. Once approved they replace the eight studio stand-ins.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The partner&#39;s monthly statement shows each rental at the sheet rate, the cut and the payout; never what the renter paid. A refund lowers the partner&#39;s share in proportion; a discount CarmaCars gives comes out of the markup.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-a-partner-s-crm-01-motors-gohighlevel" data-gd-task><h2 class="gd-h2">A partner&#39;s CRM (01 Motors&#39; GoHighLevel)</h2><p class="gd-p"><b class="gd-ui">Settings</b>, the <b class="gd-ui">Partners</b> tile, then the partner (or <b class="gd-ui">CRM link</b> on the partner&#39;s page). Their CRM gets our cars, kept up to date, and their cars come to us.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Ask the partner for a Private Integration token and their location ID (the box <b class="gd-ui">What 01 Motors gives us</b> on the page says exactly what to create and which scopes to tick). Paste both and press <b class="gd-ui">Connect</b>. The token goes to the vault; the page only ever shows its last four characters.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Connect tests the link (their location, objects, products and pipelines) and runs the first sync. After that it runs by itself every 15 minutes, and within five minutes of a change to a car, a rate, a photo, a booking or a block. <b class="gd-ui">Test connection</b> and <b class="gd-ui">Run sync now</b> do it at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">What 01 Motors sees</b>: CarmaCars&#39; own cars and program owners&#39; cars that are on the site, with rates, the next 60 days and photos, as records of a &quot;CarmaCars Vehicles&quot; object in their CRM (or as products when their plan has no custom objects). Partner cars are never sent: not theirs, not another partner&#39;s. Press <b class="gd-ui">Change what we share</b> to leave out program owners&#39; cars, rates, availability or photos.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Partner price</b>: the site&#39;s rates, or the site&#39;s rates less (or plus) a percentage, to the nearest dollar.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Their cars coming in</b>: name the object in their CRM that holds their cars (Test connection lists them), or their feed address. Each of their cars is matched to their car here, or added as their partner car (it waits off the site unless you choose otherwise), with their rates as its sheet rates, their booked dates as calendar blocks and their photos for a car with none. A car that waits shows <b class="gd-ui">Add as their car</b>, <b class="gd-ui">Link</b> or <b class="gd-ui">Set aside</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Leads both ways</b> (off until you turn it on): requests for their cars, and requests that came through their booking links, become contacts and opportunities in the pipeline stage you choose; an opportunity they move to the stage you name becomes a lead in <b class="gd-ui">Leads</b>.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><b class="gd-ui">Feed, widget and booking links</b>: a JSON or CSV feed and a widget for their GoHighLevel funnels and sites (copy the iframe), and booking links carmacars.ca/p/01-motors/&lt;car&gt; that mark the request as theirs for 30 days. <b class="gd-ui">New key</b> ends the old feed and widget addresses at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A link that has failed for an hour shows on Admin &gt; Today. Disconnect deletes the token from the vault; what is already in their CRM stays there.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-rental-by-hand" data-gd-task><h2 class="gd-h2">Add a rental by hand</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>. For phone, walk-in, Turo, partner and insurer bookings, the owner using their own car, and placeholders: a rental already agreed. To send an offer instead, use Send an offer.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Standing with the renter at pickup? Press <b class="gd-ui">Start at pickup</b>: type the renter&#39;s name and phone, choose the car, type the kilometres and the fuel, and press <b class="gd-ui">Hold the car and finish later</b>. The pickup is now; the car is held for 2 hours (renewed while you work on it) and you get a task to finish the rental.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Nothing is required to save: the form is saved as a draft as you type (<b class="gd-ui">Save draft</b> saves at once). Unfinished rentals, on Bookings and on this page, lists every draft with who started it, when, and what is still missing; Finish it opens it where it was left, on any device. Tick Hold the car while I finish to keep the car off the calendar while you type (2 hours, renewed as you save). Discard drops it and frees the car.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Quick start sets the usual choices in one tap: <b class="gd-ui">Phone</b>, <b class="gd-ui">Walk-in</b>, <b class="gd-ui">Turo or another platform</b>, <b class="gd-ui">Insurance replacement</b>, <b class="gd-ui">Owner using own car</b> or <b class="gd-ui">Placeholder</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Choose the car and the dates. The calendar and the price are checked by themselves: clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">We deliver it, or we pick it up: pick the address from the suggestions and its distance from our location prices the delivery (shown under the address), as on Send an offer.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Check the price: every line of the price can be changed where it stands. Type a new amount in the line (the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the deposit, the kilometres a day); HST and the total follow. Add a line from the list or a charge of its own; Remove takes a fee off. The (i) beside each line says what it is and how it is worked out. One optional reason covers all the changes. At the top of the price, Amounts I type: Before tax, or After tax (HST included) to type what the renter paid for each line (&quot;$270 after tax for the rental, $50 for the Protection Plan&quot;): each is worked back to its amount before tax, and a line without HST stays as typed. The choice is remembered on this device. Or type the Total the renter pays (after tax): the rental charge is worked out so the total is exactly that, to the cent, and the line under it shows each line before tax. The total shown is the total that is saved; if they ever differ, it says by how much before you save.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Any length: the dates may run past 30 days (up to the staff limit in Program settings, 730 days by default). From 30 days the rental charge is the monthly rate for each 30 days, and the monthly periods are listed. On the booking, Monthly periods shows each period: its share, and its own version of the agreement (CarmaCars&#39; and Blind Spot&#39;s), sent to the renter to sign a few days before it starts (Program settings: long_rental_agreement_lead_days, 3 by default), with what is due for it on the renter&#39;s Balance due. With Program settings, Charge the saved card for each period, on, that share is charged to the saved card when the agreement goes out (the renter gets the receipt; a declined or missing card gives Finance a task).</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">An owner&#39;s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner&#39;s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press <b class="gd-ui">Insurer confirmed</b> once the insurer confirms it.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Insurer billed later (or the Insurance replacement quick start): choose the insurer (Not listed: type its name, and it is added to the list), the claim number, the adjuster, the days and the daily rate authorized, the provisional end, and whether the insurer pays everything or the rental only. The booking is billed to the insurer; the renter owes only what it does not cover. The daily rate authorized is filled from the insurer&#39;s rate sheet for the car (Insurance replacements: rates and billing); a different rate needs the reason. Charges to the insurer: type the rate a day of VLF, LDW, T&amp;LDW, PAP/PEC or Waiver Saver when the insurer authorized them (Insurance replacements: rates and billing).</div></li><li><span class="gd-n" aria-hidden="true">13</span><div class="gd-t">The rent is paid by: e-Transfer or cash (received), card on file (charged when the renter signs), payment link, platform payout (Turo), insurer billed later, cheque, bank transfer, or unpaid. Paid in parts (some cash, some e-Transfer): press <b class="gd-ui">Add another payment (paid in parts)</b> and type each amount. Then the deposit, its own way: card hold, cash, e-Transfer (with its reference and date) or no deposit.</div></li><li><span class="gd-n" aria-hidden="true">14</span><div class="gd-t">Before you save checks it all in one box: the renter, the car, the days, the total, what was received and what is still to collect, the deposit (or No deposit) and the agreement.</div></li><li><span class="gd-n" aria-hidden="true">15</span><div class="gd-t">The rental agreement: Send it to sign online, or Already signed on paper (a task asks for the scan). The calendar: untick Blocks the car&#39;s calendar for an insurance replacement with dates not known yet, with the reason.</div></li><li><span class="gd-n" aria-hidden="true">16</span><div class="gd-t">Tick <b class="gd-ui">Do not email the renter</b> if they should not get the confirmation. Press <b class="gd-ui">Add the rental</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, <b class="gd-ui">Verified in person</b> records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-retire-or-delete-a-car" data-gd-task><h2 class="gd-h2">Retire or delete a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Retire or delete</b>, or the car&#39;s own page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Retire this car</b> takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. <b class="gd-ui">Restore</b> brings it back.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Delete this car</b> removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On the same page, <b class="gd-ui">Delete all sample cars</b> deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-sample-cars-on-the-site" data-gd-task><h2 class="gd-h2">Sample cars on the site</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, or <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Site</b>. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Hide sample cars</b> asks first (&quot;Hide all 20 sample cars from the site?&quot;); press <b class="gd-ui">Hide them</b> to take every sample car off the site at once, or <b class="gd-ui">Keep them</b>. Nothing else stops it: not an enquiry, not an old request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Show sample cars</b> puts the 20 back, with their photos and rates. Ones that were deleted are made again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the site each one is marked &quot;Example car&quot;. They never appear in search engines or the sitemap.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A request on a sample car is never a booking. When the person picks dates, the car page and the request form show a real car free for them (the same make and model first, else the same class and body at a similar price) with one tap to switch to it. If they keep the sample car, it becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car, naming the free real car.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-why-a-car-is-not-on-the-site-yet" data-gd-task><h2 class="gd-h2">Why a car is not on the site yet</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, the card Not on the site yet.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The same car is a line on To do with <b class="gd-ui">Set rates and publish</b>. The car comes off both once it is on the site.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-tolls-when-two-rentals-overlap" data-gd-task><h2 class="gd-h2">Tolls when two rentals overlap</h2><p class="gd-p">Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.</p></section>');
select app.guide_release_section('admin', 'insurance-replacements-rates-and-billing', 'chapter', 'partners-company-cars-and-rentals-added-by-hand', 'Each insurance company pays an agreed rate a day for a replacement car, by car class. The rate sheet keeps those rates with their history; a rental billed to an insurer takes its rate from it, the insurer''s invoice follows it, and each insurer''s page shows what it was billed, paid and still owes.

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
', 'Insurance replacements: rates and billing', 'The rate sheet by insurer and car class, the rate on a rental, the invoices and the billing history.',
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

## Charges to the insurer

VLF (vehicle licence fee), LDW, T&LDW, PAP/PEC and Waiver Saver are charged to the insurer, a rate a day each, only on a rental billed to an insurer. They have no set price: type the rate the insurer authorized on each booking.

1. Add a rental, Insurer billed later (or the Insurance replacement quick start): under the insurer''s details, **Charges to the insurer** has a box for each, the rate a day before HST. Under each box the amount for the days shows; the check of the price adds each line with its HST. Leave a box empty for none.
2. A request or an offer: on the review screen, once Bill to is an insurer, the same boxes are under the insurer''s details. Save, Send offer or the updated offer keeps them; Bill to back to Renter removes them in the same save.
3. A confirmed booking: the Insurance replacement card lists each charge with its rate a day, the days and the amount. **Change the charges** (or **Add a charge**), type the rates, and press **Save the charges**. Each change is in the booking''s history and the changes to the fees.
4. Each line is the rate times the rental days, plus HST: when the dates change, the amount follows. The insurer pays them whether it pays everything or the rental only.

> Good to know: They never show for a rental the renter pays, and the database refuses them there. They print on both agreements: on Blind Spot''s, VLF in box 43, LDW in 45, T&LDW in 46, PAP/PEC in 47 (each with its rate a day and amount) and Waiver Saver in its box beside Accepted; a box with no charge says N/A.

## Invoices to the insurer

- **Draft insurer invoice** on the booking bills the insurer at the booking''s daily rate (the sheet''s, or the one typed with its reason) for the days authorized.
- The weekly cap and the cap for 30 days lower the amount of a long rental. Billed for the rental only, the insurer also pays delivery and pickup up to its allowance; billed for everything, delivery and pickup above the allowance are the renter''s.
- Each charge to the insurer is a line of its own on the invoice (for example VLF (vehicle licence fee): 3 days at $5.00 a day).
- The invoice line says the rate and where it comes from (for example at $65.00 a day, Example Mutual rate sheet, Sedan), and the PDF prints the taxes note. Send it and record its payments in Money > Insurer invoices, as before.

## Billing history

**Money** > **Insurer rates**, then the insurer''s name.

1. The tiles: bookings, days used and authorized, billed, paid, outstanding, the average daily rate and the days the insurer takes to pay (from sent to paid).
2. Rates by class (Set, Change and End work here too), then the History of the rates: each rate with its dates, its status, why it changed and who saved it.
3. Billing by class: for each class the bookings, days authorized and used, billed, paid, outstanding, the average rate and the days to pay.
4. Bookings: each booking with its class, claim, dates, days, rate (Sheet and the reason when it differs), what was billed, paid and outstanding, and its invoices (each opens its PDF).
5. Choose Picked up from and to and press **Show** for a period. **Download CSV** saves the bookings of the period for a spreadsheet.
',
  '<p class="gd-p">Each insurance company pays an agreed rate a day for a replacement car, by car class. The rate sheet keeps those rates with their history; a rental billed to an insurer takes its rate from it, the insurer&#39;s invoice follows it, and each insurer&#39;s page shows what it was billed, paid and still owes.</p><section class="gd-task" id="insurance-replacements-rates-and-billing-the-rate-sheet" data-gd-task><h2 class="gd-h2">The rate sheet</h2><p class="gd-p">Open <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Insurer rates</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">One row for each insurer, one column for each car class (the list in Settings &gt; Vehicle classes). Each cell shows the rate today and, under it, a rate already saved for a later date. On a phone each insurer is a card with its classes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Set</b> (or <b class="gd-ui">Change</b>) in a cell. Type the Daily rate and, when the insurer has them, a weekly cap, a cap for 30 days, a delivery and pickup allowance, the kilometres a day and a taxes note (printed on its invoices). Choose From, say why it changed, and press <b class="gd-ui">Save the rate</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A change never overwrites the rate before it: it is a new rate from its date, and the earlier one stays in the history. <b class="gd-ui">End</b> stops a rate from a date.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add an insurer, or change its billing contact and email, in Settings &gt; Insurers.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A car takes the rate of its pricing class; when the insurer has no rate for that class, the rate of the car&#39;s other classes, in the order of the list. A 2024 Jetta (standard, also a sedan) replaced for an insurer that pays $65 a day for sedans is billed $65 a day.</div></aside></section><section class="gd-task" id="insurance-replacements-rates-and-billing-the-rate-on-a-rental" data-gd-task><h2 class="gd-h2">The rate on a rental</h2><ul class="gd-ul"><li>Add a rental, Insurance replacement (or Insurer billed later): once the price is checked and the insurer chosen, the daily rate authorized is filled from its rate sheet for the car, with the caps and the taxes note under it.</li><li>A different rate: type it, and Differs from the rate sheet asks for the reason. The rental is not added without it. Empty the field to take the sheet&#39;s rate again.</li><li>The review screen of a request or an offer does the same when you choose Bill to and the insurer: the rate follows the insurer chosen, and a rate typed that differs needs the reason.</li><li>An insurer with no rate for the car: type the rate the adjuster authorized, as before.</li><li>The booking&#39;s Insurance replacement card (Overview and Money tabs) shows the insurer and the claim, the daily rate and where it comes from, Differs with the reason when it is not the sheet&#39;s, the caps, the days covered, what the insurer pays and its invoices.</li></ul></section><section class="gd-task" id="insurance-replacements-rates-and-billing-charges-to-the-insurer" data-gd-task><h2 class="gd-h2">Charges to the insurer</h2><p class="gd-p">VLF (vehicle licence fee), LDW, T&amp;LDW, PAP/PEC and Waiver Saver are charged to the insurer, a rate a day each, only on a rental billed to an insurer. They have no set price: type the rate the insurer authorized on each booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Add a rental, Insurer billed later (or the Insurance replacement quick start): under the insurer&#39;s details, <b class="gd-ui">Charges to the insurer</b> has a box for each, the rate a day before HST. Under each box the amount for the days shows; the check of the price adds each line with its HST. Leave a box empty for none.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A request or an offer: on the review screen, once Bill to is an insurer, the same boxes are under the insurer&#39;s details. Save, Send offer or the updated offer keeps them; Bill to back to Renter removes them in the same save.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A confirmed booking: the Insurance replacement card lists each charge with its rate a day, the days and the amount. <b class="gd-ui">Change the charges</b> (or <b class="gd-ui">Add a charge</b>), type the rates, and press <b class="gd-ui">Save the charges</b>. Each change is in the booking&#39;s history and the changes to the fees.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Each line is the rate times the rental days, plus HST: when the dates change, the amount follows. The insurer pays them whether it pays everything or the rental only.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>They never show for a rental the renter pays, and the database refuses them there. They print on both agreements: on Blind Spot&#39;s, VLF in box 43, LDW in 45, T&amp;LDW in 46, PAP/PEC in 47 (each with its rate a day and amount) and Waiver Saver in its box beside Accepted; a box with no charge says N/A.</div></aside></section><section class="gd-task" id="insurance-replacements-rates-and-billing-invoices-to-the-insurer" data-gd-task><h2 class="gd-h2">Invoices to the insurer</h2><ul class="gd-ul"><li><b class="gd-ui">Draft insurer invoice</b> on the booking bills the insurer at the booking&#39;s daily rate (the sheet&#39;s, or the one typed with its reason) for the days authorized.</li><li>The weekly cap and the cap for 30 days lower the amount of a long rental. Billed for the rental only, the insurer also pays delivery and pickup up to its allowance; billed for everything, delivery and pickup above the allowance are the renter&#39;s.</li><li>Each charge to the insurer is a line of its own on the invoice (for example VLF (vehicle licence fee): 3 days at $5.00 a day).</li><li>The invoice line says the rate and where it comes from (for example at $65.00 a day, Example Mutual rate sheet, Sedan), and the PDF prints the taxes note. Send it and record its payments in Money &gt; Insurer invoices, as before.</li></ul></section><section class="gd-task" id="insurance-replacements-rates-and-billing-billing-history" data-gd-task><h2 class="gd-h2">Billing history</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Insurer rates</b>, then the insurer&#39;s name.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tiles: bookings, days used and authorized, billed, paid, outstanding, the average daily rate and the days the insurer takes to pay (from sent to paid).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Rates by class (Set, Change and End work here too), then the History of the rates: each rate with its dates, its status, why it changed and who saved it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Billing by class: for each class the bookings, days authorized and used, billed, paid, outstanding, the average rate and the days to pay.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Bookings: each booking with its class, claim, dates, days, rate (Sheet and the reason when it differs), what was billed, paid and outstanding, and its invoices (each opens its PDF).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Choose Picked up from and to and press <b class="gd-ui">Show</b> for a period. <b class="gd-ui">Download CSV</b> saves the bookings of the period for a spreadsheet.</div></li></ol></div></section>');
select app.guide_release_section('va', 'add-a-rental-by-hand', 'chapter', 'sales', 'Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.

## Add a rental

Open **Bookings** > **Add a rental**. Your home address must be in your profile first: until it is, the page asks for it.

1. At pickup with the renter? Press **Start at pickup**: the renter''s name and phone, the car, the kilometres and the fuel, then **Hold the car and finish later**. The car is held for 2 hours and you get a task to finish it.
2. Nothing is required to save: the form is saved as a draft as you type (**Save draft** saves at once). Unfinished rentals, on Today and on this page, opens a draft where it was left, on any device. Tick Hold the car while I finish to keep the car off the calendar while you type.
3. Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.
4. The dates decide the case, shown under them. Car already out with the renter? Enter the pickup as when it left: the rental is recorded as on trip, and anything still missing (signature, licence check, coverage proof, deposit) becomes a task. A rental that has already ended is recorded by an Admin.
5. Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.
6. The calendar and the price are checked by themselves once the car and the dates are in. The price comes from the rate sheet. You may add the extras, how damage is covered and an allowed promo code.
7. Quick start: **Phone**, **Walk-in**, **Turo or another platform** or **Insurance replacement** sets the usual choices.
8. A car tagged Listing not finished can be rented too: it stays off the public site. If it has no rates yet, type the rental charge for the whole rental and the reason. An owner''s car not yet on the fleet insurance policy is added by an Admin only.
9. Every line of the price can be changed where it stands (customer service and sales, while Program settings allow it): the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the kilometres a day; add a fee from the list or a charge of its own. The (i) beside each line says what it is. The rate-sheet price stays on the booking; a price far under it is flagged for an Admin, never refused. Know what the renter paid with tax? Choose After tax (HST included) under Amounts I type and type those amounts ("$270 after tax for the rental, $50 for the Protection Plan"), or type the Total the renter pays (after tax): the rental charge is worked out so the total is exactly that. The total shown is the total saved.
10. Any length: past 30 days the monthly rate applies for each 30 days, and the monthly periods are listed. Each later period gets its own agreement, sent to the renter to sign a few days before it starts (Monthly periods on the booking; Send the agreement for the next period now if needed).
11. Choose how the rent is paid (e-Transfer or cash received, card on file, payment link, platform payout, insurer billed later; the ways open to you are set by an Admin; paid in parts: Add another payment) and then how the deposit is paid (card hold, cash or e-Transfer with its reference). Before you save sums it all up. Signed on paper already? Choose it: a task asks for the scan. An insurance replacement with dates not known yet: untick Blocks the car''s calendar and say why.
12. Under Who found this client, choose **I sourced this client** or **Entered for CarmaCars**.
13. Press **Add the rental**. The renter gets the confirmation email unless you tick **Do not email the renter**.
14. A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.

> Tip: The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.
', 'Add a rental by hand', 'Choose the car and dates, find the renter, price it, record how it is paid.',
  'Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.

## Add a rental

Open **Bookings** > **Add a rental**. Your home address must be in your profile first: until it is, the page asks for it.

1. At pickup with the renter? Press **Start at pickup**: the renter''s name and phone, the car, the kilometres and the fuel, then **Hold the car and finish later**. The car is held for 2 hours and you get a task to finish it.
2. Nothing is required to save: the form is saved as a draft as you type (**Save draft** saves at once). Unfinished rentals, on Today and on this page, opens a draft where it was left, on any device. Tick Hold the car while I finish to keep the car off the calendar while you type.
3. Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.
4. The dates decide the case, shown under them. Car already out with the renter? Enter the pickup as when it left: the rental is recorded as on trip, and anything still missing (signature, licence check, coverage proof, deposit) becomes a task. A rental that has already ended is recorded by an Admin.
5. Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.
6. The calendar and the price are checked by themselves once the car and the dates are in. The price comes from the rate sheet. You may add the extras, how damage is covered and an allowed promo code.
7. Quick start: **Phone**, **Walk-in**, **Turo or another platform** or **Insurance replacement** sets the usual choices.
8. A car tagged Listing not finished can be rented too: it stays off the public site. If it has no rates yet, type the rental charge for the whole rental and the reason. An owner''s car not yet on the fleet insurance policy is added by an Admin only.
9. Every line of the price can be changed where it stands (customer service and sales, while Program settings allow it): the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the kilometres a day; add a fee from the list or a charge of its own. The (i) beside each line says what it is. The rate-sheet price stays on the booking; a price far under it is flagged for an Admin, never refused. Know what the renter paid with tax? Choose After tax (HST included) under Amounts I type and type those amounts ("$270 after tax for the rental, $50 for the Protection Plan"), or type the Total the renter pays (after tax): the rental charge is worked out so the total is exactly that. The total shown is the total saved.
10. Any length: past 30 days the monthly rate applies for each 30 days, and the monthly periods are listed. Each later period gets its own agreement, sent to the renter to sign a few days before it starts (Monthly periods on the booking; Send the agreement for the next period now if needed).
11. Choose how the rent is paid (e-Transfer or cash received, card on file, payment link, platform payout, insurer billed later; the ways open to you are set by an Admin; paid in parts: Add another payment) and then how the deposit is paid (card hold, cash or e-Transfer with its reference). Before you save sums it all up. Signed on paper already? Choose it: a task asks for the scan. An insurance replacement with dates not known yet: untick Blocks the car''s calendar and say why. Insurer billed later shows Charges to the insurer: type the rate a day of VLF, LDW, T&LDW, PAP/PEC or Waiver Saver that the insurer authorized (empty: none); each is the rate times the days, plus HST, billed to the insurer.
12. Under Who found this client, choose **I sourced this client** or **Entered for CarmaCars**.
13. Press **Add the rental**. The renter gets the confirmation email unless you tick **Do not email the renter**.
14. A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.

> Tip: The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.
',
  '<p class="gd-p">Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.</p><section class="gd-task" id="add-a-rental-by-hand-add-a-rental" data-gd-task><h2 class="gd-h2">Add a rental</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>. Your home address must be in your profile first: until it is, the page asks for it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">At pickup with the renter? Press <b class="gd-ui">Start at pickup</b>: the renter&#39;s name and phone, the car, the kilometres and the fuel, then <b class="gd-ui">Hold the car and finish later</b>. The car is held for 2 hours and you get a task to finish it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Nothing is required to save: the form is saved as a draft as you type (<b class="gd-ui">Save draft</b> saves at once). Unfinished rentals, on Today and on this page, opens a draft where it was left, on any device. Tick Hold the car while I finish to keep the car off the calendar while you type.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The dates decide the case, shown under them. Car already out with the renter? Enter the pickup as when it left: the rental is recorded as on trip, and anything still missing (signature, licence check, coverage proof, deposit) becomes a task. A rental that has already ended is recorded by an Admin.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">The calendar and the price are checked by themselves once the car and the dates are in. The price comes from the rate sheet. You may add the extras, how damage is covered and an allowed promo code.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Quick start: <b class="gd-ui">Phone</b>, <b class="gd-ui">Walk-in</b>, <b class="gd-ui">Turo or another platform</b> or <b class="gd-ui">Insurance replacement</b> sets the usual choices.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">A car tagged Listing not finished can be rented too: it stays off the public site. If it has no rates yet, type the rental charge for the whole rental and the reason. An owner&#39;s car not yet on the fleet insurance policy is added by an Admin only.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Every line of the price can be changed where it stands (customer service and sales, while Program settings allow it): the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the kilometres a day; add a fee from the list or a charge of its own. The (i) beside each line says what it is. The rate-sheet price stays on the booking; a price far under it is flagged for an Admin, never refused. Know what the renter paid with tax? Choose After tax (HST included) under Amounts I type and type those amounts (&quot;$270 after tax for the rental, $50 for the Protection Plan&quot;), or type the Total the renter pays (after tax): the rental charge is worked out so the total is exactly that. The total shown is the total saved.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Any length: past 30 days the monthly rate applies for each 30 days, and the monthly periods are listed. Each later period gets its own agreement, sent to the renter to sign a few days before it starts (Monthly periods on the booking; Send the agreement for the next period now if needed).</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Choose how the rent is paid (e-Transfer or cash received, card on file, payment link, platform payout, insurer billed later; the ways open to you are set by an Admin; paid in parts: Add another payment) and then how the deposit is paid (card hold, cash or e-Transfer with its reference). Before you save sums it all up. Signed on paper already? Choose it: a task asks for the scan. An insurance replacement with dates not known yet: untick Blocks the car&#39;s calendar and say why. Insurer billed later shows Charges to the insurer: type the rate a day of VLF, LDW, T&amp;LDW, PAP/PEC or Waiver Saver that the insurer authorized (empty: none); each is the rate times the days, plus HST, billed to the insurer.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Under Who found this client, choose <b class="gd-ui">I sourced this client</b> or <b class="gd-ui">Entered for CarmaCars</b>.</div></li><li><span class="gd-n" aria-hidden="true">13</span><div class="gd-t">Press <b class="gd-ui">Add the rental</b>. The renter gets the confirmation email unless you tick <b class="gd-ui">Do not email the renter</b>.</div></li><li><span class="gd-n" aria-hidden="true">14</span><div class="gd-t">A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.</div></aside></section>');
-- GUIDES 0179 END
