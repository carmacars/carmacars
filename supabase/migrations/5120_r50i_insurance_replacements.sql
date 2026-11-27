-- 5120 (release 50 hotfix 2; docs/changes/2026-11-27-r50-insurance-replacements.md): Insurance replacements, one page in
-- Admin and in the staff portal (Finance and customer service; never Field) for every rental billed to an insurer.
-- The owner (Nov 27): one list with progress at a glance, a short entry form (a car of the fleet or one typed in), these
-- rentals off the calendar and owner notices on a switch, invoicing back and forth (every field editable, sent as an
-- estimate or an invoice as many times as needed, each a version with its history and its differences), getting paid
-- (approved, paid, partial, written off, aging) and the CarmaCars_Admin connector able to do all of it.
--   the invoice          one insurer_invoices row per booking stays the invoice (its number, its payments, every sum
--                        and report that reads it); its next version is edited in insurer_invoices.pending (a draft is
--                        edited in place). Send applies it and keeps a copy of what was sent in insurer_invoice_versions
--                        (an estimate is kept there only: it bills nothing). Re-invoicing, a new end of rental and an
--                        extension are new versions: "Nothing is left to invoice to the insurer on booking X" (0016) is
--                        gone, app.draft_insurer_invoice returns the booking's invoice once it has one.
--   a car not in the fleet  a vehicles row marked outside_fleet, retired as soon as the rental is added (unlisted, not
--                        bookable, off the calendars and the fleet lists), CarmaCars' own (company supply)
--   off the calendar     the switch is the booking's calendar switch (0016): an insurer-billed booking off the calendar is
--                        not its car owner's (2480: no owner email, not on statements, shown only as unavailable); on by
--                        default for a car not in the fleet (CC-10067)
--   getting paid         insurer_invoices.approved_cents (what the adjuster approved), negotiating_at with its note,
--                        payments as 0016 records them (cheque, e-Transfer, direct deposit as bank_transfer), a write-off
--                        of what is left with its reason (written_off_cents, set by a trigger on either path)
--   aging                the reminder of 0023 (staff_insurer_invoice_due) now opens this page
--   who                  app.insurer_rentals_may: an Admin, Finance or customer service; money (send, payments,
--                        approved, write-off) needs Finance or an Admin (app.user_runs_finance), as 0032 has it
--   the door             ops_read insurer_rentals, insurer_rental; ops_do insurer_rental_create, insurer_rental_update,
--                        insurer_rental_extend, insurer_invoice_save, insurer_invoice_send, insurer_money, draft_restore
--   the connector        list_insurer_rentals, get_insurer_rental (admin:read); insurer_rental_create,
--                        insurer_rental_update, insurer_rental_extend, insurer_invoice_edit, insurer_invoice_send,
--                        insurer_money (admin:write): each previewed by running it and rolling it back, then confirmed
--   unfinished rentals   a draft never vanishes: Unfinished rentals lists every open draft whatever its age (0148 hid
--                        them after 30 days), a discarded one can be restored, and draft_get says what became of one
-- No applied migration is edited: functions are wrapped (_pre5120).
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

-- ================================================================ 1. tables
alter table vehicles add column if not exists outside_fleet boolean not null default false;
comment on column vehicles.outside_fleet is 'A car that is not in the fleet, typed in for an insurance replacement (5120): retired once its rental is added, so it is never listed, booked or shown on a calendar.';

alter table insurer_invoices
  add column if not exists pending jsonb,
  add column if not exists version integer not null default 0 check (version >= 0),
  add column if not exists bill_to jsonb not null default '{}'::jsonb,
  add column if not exists invoice_date date,
  add column if not exists due_date date,
  add column if not exists approved_cents bigint check (approved_cents >= 0),
  add column if not exists approved_at timestamptz,
  add column if not exists approved_by uuid references users (id),
  add column if not exists negotiating_at timestamptz,
  add column if not exists negotiation_note text check (char_length(negotiation_note) <= 2000),
  add column if not exists written_off_cents bigint not null default 0 check (written_off_cents >= 0);
alter table insurer_invoices add constraint insurer_invoices_bill_to_object check (jsonb_typeof(bill_to) = 'object');
alter table insurer_invoices add constraint insurer_invoices_pending_object check (pending is null or jsonb_typeof(pending) = 'object');
comment on column insurer_invoices.pending is 'The next version being edited (5120): lines, hst_cents, notes, dates, bill_to, claim_number. Applied when sent as an invoice; a draft is edited in place.';
comment on column insurer_invoices.version is 'How many versions were sent (estimates included), 5120. Each is kept in insurer_invoice_versions.';

create table if not exists insurer_invoice_versions (
  id          uuid primary key default gen_random_uuid(),
  invoice_id  uuid not null references insurer_invoices (id),
  version     integer not null check (version >= 1),
  kind        text not null check (kind in ('estimate', 'invoice')),
  snapshot    jsonb not null check (jsonb_typeof(snapshot) = 'object'),
  emailed_to  text,
  sent_by     uuid references users (id),
  sent_at     timestamptz not null default now(),
  unique (invoice_id, version)
);
comment on table insurer_invoice_versions is 'Every estimate and invoice sent to an insurer for a booking (5120), as sent: never changed. The PDF of a version is /files/insurer_invoice/<invoice>:v<version>.';
create trigger audit_insurer_invoice_versions after insert or update or delete on insurer_invoice_versions for each row execute function app.audit_row();
create function app.insurer_invoice_versions_frozen() returns trigger language plpgsql as $$
begin raise exception 'A version sent to an insurer is never changed' using errcode = '23514'; end $$;
create trigger insurer_invoice_versions_frozen before update or delete on insurer_invoice_versions for each row execute function app.insurer_invoice_versions_frozen();
alter table insurer_invoice_versions enable row level security;
create policy admin_all on insurer_invoice_versions for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on insurer_invoice_versions from public, anon, authenticated;
grant select on insurer_invoice_versions to authenticated;
grant all on insurer_invoice_versions to service_role;

-- what was written off is kept (either path: the old Write off button, or insurer_money)
create function app.insurer_invoices_write_off_amount() returns trigger language plpgsql as $$
begin
  if new.status = 'written_off' and old.status is distinct from 'written_off' then
    new.written_off_cents := greatest(new.amount_cents + new.hst_cents - new.paid_cents, 0);
  end if;
  return new;
end $$;
create trigger insurer_invoices_write_off_amount before update on insurer_invoices for each row execute function app.insurer_invoices_write_off_amount();

-- the booking's history keeps each step of the claim
do $$
declare d text;
begin
  select pg_get_constraintdef(oid) into d from pg_constraint where conrelid = 'booking_events'::regclass and conname = 'booking_events_kind_check';
  if d is not null and d not like '%insurer_claim%' then
    execute 'alter table booking_events drop constraint booking_events_kind_check';
    execute 'alter table booking_events add constraint booking_events_kind_check ' || replace(d, 'ARRAY[', 'ARRAY[''insurer_claim''::text, ');
  end if;
end $$;

-- ================================================================ 2. helpers
create function app.insurer_rentals_may(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(app.user_is_admin(p_user), false) or coalesce(app.user_va_has(p_user, 'finance'), false) or coalesce(app.user_va_has(p_user, 'cs'), false)
$$;
comment on function app.insurer_rentals_may(uuid) is 'Who works Insurance replacements (5120): an Admin, Finance or customer service. Money needs app.user_runs_finance.';

create function app.insurer_assert(p_user uuid, p_money boolean default false) returns void
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  if not app.insurer_rentals_may(p_user) then raise exception 'Insurance replacements are for Admins, Finance and customer service' using errcode = '42501'; end if;
  if p_money and not app.user_runs_finance(p_user) then raise exception 'Finance or an Admin sends invoices and records what an insurer approves and pays' using errcode = '42501'; end if;
end $$;

-- a booking billed to an insurer, by its number or id
create function app.insurer_booking(p_ref text) returns bookings
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare b bookings;
begin
  select * into b from bookings x where x.booking_number = upper(btrim(coalesce(p_ref, ''))) or x.id::text = lower(btrim(coalesce(p_ref, '')));
  if b.id is null then raise exception 'booking: the booking number, for example CC-10482' using errcode = 'P0002'; end if;
  if b.bill_to not in ('insurer', 'split') or b.insurer_id is null then raise exception 'Booking % is not billed to an insurer', b.booking_number using errcode = '23514'; end if;
  return b;
end $$;

-- the booking's invoice: the newest one not written off, else the newest
create function app.insurer_live_invoice(p_booking uuid) returns insurer_invoices
language sql stable security definer set search_path = public, app, pg_temp as $$
  select * from insurer_invoices where booking_id = p_booking order by (status = 'written_off'), created_at desc limit 1
$$;

-- the invoice's lines, cleaned: description, quantity, rate_cents, amount_cents (typed, else quantity times rate), taxable
create function app.insurer_lines_clean(p_lines jsonb) returns jsonb
language plpgsql immutable set search_path = public, app, pg_temp as $$
declare
  l jsonb;
  v_out jsonb := '[]'::jsonb;
  v_d text;
  v_q numeric;
  v_r bigint;
  v_a bigint;
  n integer := 0;
begin
  if jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'lines: a list of {description, quantity, rate_cents, amount_cents, taxable}' using errcode = '22023'; end if;
  for l in select value from jsonb_array_elements(p_lines) loop
    n := n + 1;
    if n > 60 then raise exception 'At most 60 lines' using errcode = '22023'; end if;
    if jsonb_typeof(l) is distinct from 'object' then raise exception 'Line %: {description, quantity, rate_cents, amount_cents}', n using errcode = '22023'; end if;
    v_d := btrim(coalesce(l ->> 'description', ''));
    if v_d = '' or char_length(v_d) > 200 then raise exception 'Line %: a description of 1 to 200 characters', n using errcode = '22023'; end if;
    v_q := nullif(l ->> 'quantity', '')::numeric;
    v_r := round(nullif(l ->> 'rate_cents', '')::numeric)::bigint;
    v_a := coalesce(round(nullif(l ->> 'amount_cents', '')::numeric)::bigint, case when v_q is not null and v_r is not null then round(v_q * v_r)::bigint end);
    if v_a is null then raise exception 'Line % (%): the amount, or the quantity and the rate', n, v_d using errcode = '22023'; end if;
    if abs(v_a) > 100000000 or abs(coalesce(v_r, 0)) > 100000000 or abs(coalesce(v_q, 0)) > 10000 then raise exception 'Line % (%): the amount is out of range', n, v_d using errcode = '22023'; end if;
    v_out := v_out || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('description', v_d, 'quantity', v_q, 'rate_cents', v_r, 'amount_cents', v_a,
                                                                           'taxable', coalesce((l ->> 'taxable')::boolean, true))));
  end loop;
  if n = 0 then raise exception 'Give at least one line' using errcode = '22023'; end if;
  return v_out;
end $$;

create function app.insurer_lines_sum(p_lines jsonb) returns bigint
language sql immutable as $$ select coalesce(sum((e ->> 'amount_cents')::bigint), 0)::bigint from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e $$;

-- the booking's figures now, as the next version's working copy: the rental (days at the insurer's rate), each charge by
-- name, the other fees, the HST of the insurer's share (app.booking_insurer_share), the period it covers
create function app.insurer_from_booking(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  s record;
  r record;
  v_lines jsonb;
  v_named bigint;
begin
  select * into b from bookings where id = p_booking;
  select * into s from app.booking_insurer_share(p_booking);
  select * into r from app.booking_insurer_rate(b);
  v_lines := jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('description', format('Replacement rental, %s day(s)', s.covered_days), 'quantity', s.covered_days,
               'rate_cents', case when r.daily_rate_cents is not null and r.daily_rate_cents * s.covered_days = s.rental_share_cents then r.daily_rate_cents end,
               'amount_cents', s.rental_share_cents, 'taxable', true)));
  -- the insurer's own charges a day (0191), then every other fee by name (1108)
  v_lines := v_lines || coalesce((select jsonb_agg(jsonb_build_object('description', li.description, 'amount_cents', li.amount_cents, 'taxable', li.hst_cents <> 0) order by ft.sort_order, li.created_at, li.id)
                                    from booking_line_items li join fee_types ft on ft.code = li.charge_type
                                   where li.booking_id = p_booking and li.voided_at is null and li.charged_to_renter and li.stage in ('booking', 'extension')
                                     and li.charge_type = any (app.insurer_fee_codes()) and li.amount_cents <> 0), '[]'::jsonb);
  if b.bill_to = 'insurer' then
    v_lines := v_lines || (select coalesce(jsonb_agg(x || jsonb_build_object('taxable', true)), '[]'::jsonb) from jsonb_array_elements(app.insurer_fee_items(p_booking)) x);
  end if;
  v_named := app.insurer_lines_sum(v_lines) - s.rental_share_cents;
  if s.fees_share_cents - v_named <> 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('description', 'Other charges at booking', 'amount_cents', s.fees_share_cents - v_named, 'taxable', true));
  end if;
  return jsonb_build_object('lines', v_lines, 'hst_cents', s.hst_cents, 'claim_number', b.insurer_claim_number,
    'period_start', app.local_date(b.pickup_at), 'period_end', greatest(app.local_date(b.pickup_at + make_interval(days => s.covered_days)), app.local_date(b.pickup_at)));
end $$;

-- what the next version says: the pending copy, else the invoice as it stands
create function app.insurer_working(ii insurer_invoices) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('lines', ii.lines, 'hst_cents', ii.hst_cents, 'notes', ii.notes, 'period_start', ii.period_start, 'period_end', ii.period_end,
           'invoice_date', ii.invoice_date, 'due_date', ii.due_date, 'bill_to', ii.bill_to, 'claim_number', ii.claim_number) || coalesce(ii.pending, '{}'::jsonb)
$$;

-- a working copy with its totals, as a version keeps it
create function app.insurer_snapshot(ii insurer_invoices, w jsonb, p_kind text, p_version integer) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select w || jsonb_build_object('kind', p_kind, 'version', p_version, 'invoice_number', ii.invoice_number,
    'amount_cents', app.insurer_lines_sum(w -> 'lines'), 'hst_cents', coalesce((w ->> 'hst_cents')::bigint, 0),
    'total_cents', app.insurer_lines_sum(w -> 'lines') + coalesce((w ->> 'hst_cents')::bigint, 0), 'paid_cents', ii.paid_cents,
    'adjuster', (select jsonb_build_object('name', b.insurer_adjuster_name, 'email', b.insurer_adjuster_email, 'phone', b.insurer_adjuster_phone) from bookings b where b.id = ii.booking_id))
$$;

-- an insurer-billed booking off the calendar is not its car owner's (2480): not on the statements, shown to the owner only
-- as unavailable, and the owner gets no booking email (app.booking_owner_view 'unavailable')
create function app.insurer_bypass(b bookings) returns boolean
language sql stable as $$ select not b.blocks_calendar $$;

-- where a claim stands, for the list
create function app.insurer_stage(b bookings, ii insurer_invoices) returns text
language sql stable as $$
  select case
    when ii.status = 'written_off' then 'written_off'
    when ii.status = 'paid' then 'paid'
    when ii.approved_cents is not null and ii.status in ('sent', 'part_paid') then 'approved'
    when ii.negotiating_at is not null and ii.status in ('sent', 'part_paid') then 'negotiating'
    when ii.status in ('sent', 'part_paid') then 'invoiced'
    when b.status = 'on_rent' then 'on_rent'
    when b.status in ('returned', 'closed') then 'returned'
    else 'upcoming' end
$$;

create function app.insurer_log(p_by uuid, p_booking uuid, p_note text, p_details jsonb default '{}'::jsonb) returns void
language sql security definer set search_path = public, app, pg_temp as $$
  insert into booking_events (booking_id, kind, note, details, actor_type, actor_user_id) values (p_booking, 'insurer_claim', left(p_note, 500), p_details, 'staff', p_by)
$$;

-- ================================================================ 3. reading
-- p: q (claim, booking, renter, insurer, adjuster or plate), stage, insurer (id), aging (30, 60 or 90: outstanding at
-- least that many days), limit (200 at most)
create function app.insurer_rentals_json(p_user uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_q text := nullif(lower(btrim(coalesce(p ->> 'q', ''))), '');
  v_rows jsonb;
begin
  perform app.insurer_assert(p_user);
  with x as (
    select b, ii, app.insurer_stage(b, ii) as stage,
           case when ii.status in ('sent', 'part_paid') then (app.local_date(now()) - app.local_date(ii.sent_at)) end as aging
      from bookings b
      left join lateral (select * from app.insurer_live_invoice(b.id)) ii on ii.id is not null
     where b.bill_to in ('insurer', 'split') and b.insurer_id is not null
       and b.status in ('confirmed', 'on_rent', 'returned', 'closed', 'pending_payment')
  ), y as (
    select x.*, i.name as insurer_name, r.legal_name as renter_name, v.plate, v.outside_fleet, app.vehicle_name(v.id) as car
      from x join insurers i on i.id = (x.b).insurer_id join renters r on r.id = (x.b).renter_id join vehicles v on v.id = (x.b).vehicle_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'booking_number', (y.b).booking_number, 'booking_id', (y.b).id, 'claim_number', (y.b).insurer_claim_number, 'insurer_id', (y.b).insurer_id, 'insurer', y.insurer_name,
      'adjuster', (y.b).insurer_adjuster_name, 'adjuster_email', (y.b).insurer_adjuster_email, 'renter', y.renter_name, 'car', y.car, 'plate', y.plate, 'outside_fleet', y.outside_fleet,
      'pickup_at', (y.b).pickup_at, 'return_at', (y.b).return_at, 'days', greatest(ceil(extract(epoch from (y.b).return_at - (y.b).pickup_at) / 86400.0), 0)::integer,
      'booking_status', (y.b).status, 'stage', y.stage, 'bypass', app.insurer_bypass(y.b),
      'invoice_id', (y.ii).id, 'invoice_number', (y.ii).invoice_number, 'invoice_status', (y.ii).status, 'versions', coalesce((y.ii).version, 0),
      'edited', (y.ii).pending is not null,
      'billed_cents', case when (y.ii).status <> 'draft' then (y.ii).total_cents else 0 end, 'approved_cents', (y.ii).approved_cents,
      'paid_cents', coalesce((y.ii).paid_cents, 0), 'balance_cents', case when (y.ii).status in ('sent', 'part_paid') then (y.ii).balance_cents else 0 end,
      'written_off_cents', coalesce((y.ii).written_off_cents, 0), 'sent_at', (y.ii).sent_at, 'aging_days', y.aging)
      order by (y.stage in ('paid', 'written_off')), coalesce(y.aging, -1) desc, (y.b).pickup_at desc), '[]'::jsonb)
    into v_rows
    from y
   where (v_q is null or lower(concat_ws(' ', (y.b).booking_number, (y.b).insurer_claim_number, y.insurer_name, (y.b).insurer_adjuster_name, y.renter_name, y.plate, (y.ii).invoice_number)) like '%' || v_q || '%')
     and (nullif(p ->> 'stage', '') is null or y.stage = p ->> 'stage')
     and (nullif(p ->> 'insurer', '') is null or (y.b).insurer_id::text = p ->> 'insurer')
     and (nullif(p ->> 'aging', '') is null or coalesce(y.aging, -1) >= (p ->> 'aging')::integer);
  return jsonb_build_object('rows', (select coalesce(jsonb_agg(e), '[]'::jsonb) from (select e from jsonb_array_elements(v_rows) e limit least(greatest(coalesce((p ->> 'limit')::integer, 200), 1), 500)) z),
    'count', jsonb_array_length(v_rows),
    'outstanding_cents', (select coalesce(sum((e ->> 'balance_cents')::bigint), 0) from jsonb_array_elements(v_rows) e),
    'over_30', (select count(*) from jsonb_array_elements(v_rows) e where (e ->> 'aging_days')::integer >= 30),
    'over_60', (select count(*) from jsonb_array_elements(v_rows) e where (e ->> 'aging_days')::integer >= 60),
    'to_invoice', (select count(*) from jsonb_array_elements(v_rows) e where e ->> 'stage' = 'returned'),
    'insurers', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name) order by i.name), '[]'::jsonb) from insurers i where i.is_active),
    'may_money', app.user_runs_finance(p_user), 'today', app.local_date(now()));
end $$;

-- one rental: the booking, the claim, the invoice and its working copy, every version sent, the payments and the history
create function app.insurer_rental_json(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  ii insurer_invoices;
  v vehicles;
begin
  perform app.insurer_assert(p_user);
  b := app.insurer_booking(coalesce(p ->> 'booking', p ->> 'booking_number'));
  ii := app.insurer_live_invoice(b.id);
  select * into v from vehicles where id = b.vehicle_id;
  return jsonb_build_object(
    'booking', jsonb_build_object('id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at, 'return_at', b.return_at,
      'bill_to', b.bill_to, 'hst_bps', b.hst_bps, 'blocks_calendar', b.blocks_calendar, 'owner_visibility', b.owner_visibility, 'bypass', app.insurer_bypass(b),
      'authorized_days', b.insurer_authorized_days, 'authorized_daily_rate_cents', b.insurer_authorized_daily_rate_cents, 'notes', b.notes),
    'stage', app.insurer_stage(b, ii),
    'claim', jsonb_build_object('insurer_id', b.insurer_id, 'insurer', (select i.name from insurers i where i.id = b.insurer_id), 'claim_number', b.insurer_claim_number,
      'adjuster_name', b.insurer_adjuster_name, 'adjuster_email', b.insurer_adjuster_email, 'adjuster_phone', b.insurer_adjuster_phone,
      'insurer_billing_email', (select i.billing_email from insurers i where i.id = b.insurer_id)),
    'renter', (select jsonb_build_object('id', r.id, 'name', r.legal_name, 'email', r.email, 'phone', r.mobile) from renters r where r.id = b.renter_id),
    'car', jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'year', v.year, 'make', v.make, 'model', v.model, 'plate', v.plate, 'outside_fleet', v.outside_fleet),
    'invoice', case when ii.id is not null then jsonb_build_object('id', ii.id, 'invoice_number', ii.invoice_number, 'status', ii.status, 'version', ii.version,
      'amount_cents', ii.amount_cents, 'hst_cents', ii.hst_cents, 'total_cents', ii.total_cents, 'paid_cents', ii.paid_cents, 'balance_cents', ii.balance_cents,
      'sent_at', ii.sent_at, 'paid_at', ii.paid_at, 'approved_cents', ii.approved_cents, 'approved_at', ii.approved_at, 'negotiating_at', ii.negotiating_at,
      'negotiation_note', ii.negotiation_note, 'written_off_cents', ii.written_off_cents, 'written_off_reason', ii.written_off_reason, 'edited', ii.pending is not null,
      'working', app.insurer_working(ii),
      -- what the last version sent said (the page shows what the next one changes from it)
      'current', (select x.snapshot from insurer_invoice_versions x where x.invoice_id = ii.id order by x.version desc limit 1),
      'aging_days', case when ii.status in ('sent', 'part_paid') then app.local_date(now()) - app.local_date(ii.sent_at) end) end,
    'from_booking', app.insurer_from_booking(b.id),
    'versions', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'version', x.version, 'kind', x.kind, 'snapshot', x.snapshot, 'emailed_to', x.emailed_to, 'sent_at', x.sent_at,
                   'sent_by', (select coalesce(u.full_name, u.email) from users u where u.id = x.sent_by)) order by x.version) from insurer_invoice_versions x where x.invoice_id = ii.id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('amount_cents', y.amount_cents, 'method', y.method, 'at', y.processed_at) order by y.processed_at)
                            from payments y where y.booking_id = b.id and y.purpose = 'other' and y.kind = 'charge' and y.status = 'succeeded' and y.method in ('cheque', 'e_transfer', 'bank_transfer')), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(jsonb_build_object('at', e.created_at, 'note', e.note, 'by', (select coalesce(u.full_name, u.email) from users u where u.id = e.actor_user_id)) order by e.created_at desc)
                           from booking_events e where e.booking_id = b.id and e.kind = 'insurer_claim'), '[]'::jsonb),
    'may_money', app.user_runs_finance(p_user), 'is_admin', app.user_is_admin(p_user),
    'insurers', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name) order by i.name), '[]'::jsonb) from insurers i where i.is_active));
end $$;

-- ================================================================ 4. writing
-- an insurer by id, or by name (added when new, as Add a rental does)
create function app.insurer_pick(p_by uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v uuid;
  v_name text := nullif(btrim(coalesce(p ->> 'insurer_name', '')), '');
begin
  if nullif(p ->> 'insurer_id', '') is not null then
    select id into v from insurers where id = (p ->> 'insurer_id')::uuid;
    if v is null then raise exception 'insurer_id: not an insurer' using errcode = 'P0002'; end if;
    return v;
  end if;
  if v_name is null then return null; end if;
  select id into v from insurers where lower(name) = lower(v_name);
  if v is null then
    if char_length(v_name) > 120 then raise exception 'The insurer''s name: at most 120 characters' using errcode = '22023'; end if;
    insert into insurers (name, created_by) values (v_name, p_by) returning id into v;
  end if;
  return v;
end $$;

-- The short form. p: renter_name (required), renter_phone, renter_email; insurer_id or insurer_name and claim_number
-- (required); adjuster_name, adjuster_email, adjuster_phone; pickup_at, return_at (required); vehicle_id, or car {year,
-- make, model, plate} for a car not in the fleet; daily_rate_cents (what the insurer pays a day), authorized_days, pays
-- (insurer: the rental and the fees, split: the rental only), bypass (off the calendar and owner notices; on by default
-- for a car not in the fleet), notes, draft_id (the unfinished rental it finishes).
create function app.insurer_rental_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_name text := nullif(btrim(coalesce(p ->> 'renter_name', '')), '');
  v_email text := lower(nullif(btrim(coalesce(p ->> 'renter_email', '')), ''));
  v_phone text := nullif(regexp_replace(coalesce(p ->> 'renter_phone', ''), '[^0-9+]', '', 'g'), '');
  v_claim text := nullif(btrim(coalesce(p ->> 'claim_number', '')), '');
  v_ins uuid;
  v_from timestamptz;
  v_to timestamptz;
  v_car uuid;
  v_outside boolean := false;
  v_bypass boolean;
  v_rate bigint := nullif(p ->> 'daily_rate_cents', '')::numeric::bigint;
  v_days integer;
  c jsonb := case when jsonb_typeof(p -> 'car') = 'object' then p -> 'car' end;
  v_out jsonb;
  b bookings;
begin
  perform app.insurer_assert(p_by);
  if v_name is null or char_length(v_name) > 120 then raise exception 'Type the renter''s name' using errcode = '22023'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'The renter''s email does not look right: correct it or leave it empty' using errcode = '22023'; end if;
  if v_claim is null or char_length(v_claim) > 60 then raise exception 'Type the claim number' using errcode = '22023'; end if;
  begin
    v_from := (p ->> 'pickup_at')::timestamptz; v_to := (p ->> 'return_at')::timestamptz;
  exception when others then raise exception 'pickup_at and return_at: the dates and times, for example 2026-11-03T10:00:00-05:00' using errcode = '22023';
  end;
  if v_from is null or v_to is null or v_to <= v_from then raise exception 'Give the pickup and the return, the return after the pickup' using errcode = '22023'; end if;
  if v_rate is not null and (v_rate < 0 or v_rate > 1000000) then raise exception 'daily_rate_cents: the rate a day in cents' using errcode = '22023'; end if;
  v_ins := app.insurer_pick(p_by, p);
  if v_ins is null then raise exception 'Choose the insurer (or type its name)' using errcode = '22023'; end if;
  v_days := greatest(ceil(extract(epoch from v_to - v_from) / 86400.0)::integer, 1);
  if nullif(p ->> 'vehicle_id', '') is not null then
    if c is not null then raise exception 'Give a car of the fleet (vehicle_id) or a car typed in (car), not both' using errcode = '22023'; end if;
    select id into v_car from vehicles where id = (p ->> 'vehicle_id')::uuid and not outside_fleet;
    if v_car is null then raise exception 'vehicle_id: not a car of the fleet' using errcode = 'P0002'; end if;
  elsif c is not null then
    if nullif(btrim(coalesce(c ->> 'make', '')), '') is null or nullif(btrim(coalesce(c ->> 'model', '')), '') is null
       or coalesce(nullif(c ->> 'year', '')::integer, 0) not between 1980 and extract(year from now())::integer + 2
       or nullif(regexp_replace(coalesce(c ->> 'plate', ''), '\s', '', 'g'), '') is null then
      raise exception 'The car not in the fleet: its year, make, model and plate' using errcode = '22023';
    end if;
    insert into vehicles (owner_id, supply_type, year, make, model, plate, status, bookings_enabled, outside_fleet, added_by)
    values (app.company_owner_id(), 'company', (c ->> 'year')::integer, left(btrim(c ->> 'make'), 40), left(btrim(c ->> 'model'), 60),
            nullif(upper(regexp_replace(coalesce(c ->> 'plate', ''), '\s', '', 'g')), ''), 'out_of_service', true, true, p_by)
    returning id into v_car;
    v_outside := true;
  else
    raise exception 'Choose the car: one of the fleet, or type the car not in the fleet' using errcode = '22023';
  end if;
  v_bypass := coalesce(nullif(p ->> 'bypass', '')::boolean, v_outside);
  if v_outside and not v_bypass then raise exception 'A car not in the fleet is always off the calendar and owner notices' using errcode = '22023'; end if;

  v_out := app.manual_rental_create(p_by, jsonb_strip_nulls(jsonb_build_object(
    'vehicle_id', v_car, 'pickup_at', v_from, 'return_at', v_to, 'coverage_option', 1, 'source', 'insurer', 'sales_choice', 'for_carmacars', 'agreement', 'send',
    'do_not_email', v_email is null,
    'renter', jsonb_strip_nulls(jsonb_build_object('full_name', v_name, 'email', v_email, 'mobile', v_phone)),
    'insurance', jsonb_strip_nulls(jsonb_build_object('insurer_id', v_ins, 'claim_number', v_claim,
      'adjuster_name', nullif(btrim(coalesce(p ->> 'adjuster_name', '')), ''), 'adjuster_email', lower(nullif(btrim(coalesce(p ->> 'adjuster_email', '')), '')),
      'adjuster_phone', nullif(btrim(coalesce(p ->> 'adjuster_phone', '')), ''), 'authorized_days', nullif(p ->> 'authorized_days', '')::integer,
      'authorized_daily_rate_cents', v_rate, 'pays', case when p ->> 'pays' = 'split' then 'split' else 'insurer' end)),
    'payment', jsonb_build_object('mode', 'unpaid', 'method', 'insurer'), 'deposit', jsonb_build_object('method', 'card'),
    'rental_charge_cents', case when v_outside then coalesce(v_rate, 0) * v_days end,
    'price_reason', case when v_outside then 'Insurance replacement: a car not in the fleet, at the insurer''s rate' end,
    'blocks_calendar', case when v_bypass then false end,
    'blocks_calendar_reason', case when v_bypass then 'Insurance replacement: off the calendar and owner notices' end,
    'note', nullif(btrim(coalesce(p ->> 'notes', '')), ''),
    'draft_id', nullif(p ->> 'draft_id', ''))));
  select * into b from bookings where id = (v_out ->> 'booking_id')::uuid;
  if v_outside then
    update vehicles set retired_at = now(), retired_by = p_by, retired_reason = 'Not a fleet car: insurance replacement ' || b.booking_number where id = v_car and retired_at is null;
  end if;
  perform app.insurer_log(p_by, b.id, format('Insurance replacement added: claim %s%s', v_claim, case when v_outside then ', a car not in the fleet' else '' end));
  perform app.ntf_emit('staff_insurer_rental_added', 'booking', b.id, 'added', jsonb_build_object('booking_id', b.id,
    '_roles', jsonb_build_array('staff_va_finance', 'staff_admin'), 'booking_number', b.booking_number,
    'insurer_name', (select i.name from insurers i where i.id = v_ins), 'claim_number', v_claim, 'renter_name', v_name,
    'vehicle_name', app.vehicle_name(v_car), 'period', app.fmt_day(app.local_date(v_from)) || ' to ' || app.fmt_day(app.local_date(v_to)),
    'added_by', (select coalesce(u.full_name, u.email) from users u where u.id = p_by),
    '_url', app.ntf_link('insurer_rental', jsonb_build_object('booking_number', b.booking_number)),
    '_digest_line', format('Insurance replacement %s added: %s', b.booking_number, v_name)));
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'outside_fleet', v_outside, 'bypass', v_bypass);
end $$;

-- p: booking; any of claim_number, insurer_id or insurer_name, adjuster_name, adjuster_email, adjuster_phone,
-- authorized_days, renter_phone, renter_email, notes, bypass, car {year, make, model, plate} (a car not in the fleet)
create function app.insurer_rental_update(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  v vehicles;
  v_ins uuid;
  v_changed text[] := '{}';
  v_bypass boolean;
  c jsonb := case when jsonb_typeof(p -> 'car') = 'object' then p -> 'car' end;
begin
  perform app.insurer_assert(p_by);
  b := app.insurer_booking(p ->> 'booking');
  select * into v from vehicles where id = b.vehicle_id;
  if p ? 'insurer_id' or p ? 'insurer_name' then
    v_ins := app.insurer_pick(p_by, p);
    if v_ins is not null and v_ins <> b.insurer_id then
      update bookings set insurer_id = v_ins where id = b.id;
      update insurer_invoices set insurer_id = v_ins where booking_id = b.id and status <> 'written_off';
      v_changed := v_changed || 'insurer'::text;
    end if;
  end if;
  if p ? 'claim_number' then
    if nullif(btrim(coalesce(p ->> 'claim_number', '')), '') is null then raise exception 'The claim number cannot be empty' using errcode = '22023'; end if;
    update bookings set insurer_claim_number = left(btrim(p ->> 'claim_number'), 60) where id = b.id;
    update insurer_invoices set claim_number = left(btrim(p ->> 'claim_number'), 60) where booking_id = b.id and status = 'draft';
    v_changed := v_changed || 'claim number'::text;
  end if;
  if p ? 'adjuster_email' and nullif(btrim(coalesce(p ->> 'adjuster_email', '')), '') is not null and btrim(p ->> 'adjuster_email') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'The adjuster''s email does not look right' using errcode = '22023';
  end if;
  if p ? 'adjuster_name' or p ? 'adjuster_email' or p ? 'adjuster_phone' then
    update bookings set insurer_adjuster_name = case when p ? 'adjuster_name' then nullif(btrim(coalesce(p ->> 'adjuster_name', '')), '') else insurer_adjuster_name end,
                        insurer_adjuster_email = case when p ? 'adjuster_email' then lower(nullif(btrim(coalesce(p ->> 'adjuster_email', '')), '')) else insurer_adjuster_email end,
                        insurer_adjuster_phone = case when p ? 'adjuster_phone' then nullif(btrim(coalesce(p ->> 'adjuster_phone', '')), '') else insurer_adjuster_phone end
     where id = b.id;
    v_changed := v_changed || 'adjuster'::text;
  end if;
  if p ? 'authorized_days' then
    update bookings set insurer_authorized_days = nullif(p ->> 'authorized_days', '')::integer where id = b.id;
    v_changed := v_changed || 'days authorized'::text;
  end if;
  if p ? 'renter_email' and nullif(btrim(coalesce(p ->> 'renter_email', '')), '') is not null and btrim(p ->> 'renter_email') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'The renter''s email does not look right' using errcode = '22023';
  end if;
  if p ? 'renter_email' or p ? 'renter_phone' then
    update renters set email = case when p ? 'renter_email' then lower(nullif(btrim(coalesce(p ->> 'renter_email', '')), '')) else email end,
                       mobile = case when p ? 'renter_phone' then nullif(regexp_replace(coalesce(p ->> 'renter_phone', ''), '[^0-9+]', '', 'g'), '') else mobile end
     where id = b.renter_id;
    v_changed := v_changed || 'renter contact'::text;
  end if;
  if p ? 'notes' then
    update bookings set notes = nullif(btrim(coalesce(p ->> 'notes', '')), '') where id = b.id;
    v_changed := v_changed || 'notes'::text;
  end if;
  if c is not null then
    if not v.outside_fleet then raise exception 'Only a car typed in (not in the fleet) is changed here' using errcode = '23514'; end if;
    update vehicles set year = coalesce(nullif(c ->> 'year', '')::integer, year), make = coalesce(nullif(btrim(coalesce(c ->> 'make', '')), ''), make),
                        model = coalesce(nullif(btrim(coalesce(c ->> 'model', '')), ''), model),
                        plate = case when c ? 'plate' then nullif(upper(regexp_replace(coalesce(c ->> 'plate', ''), '\s', '', 'g')), '') else plate end
     where id = v.id;
    v_changed := v_changed || 'car'::text;
  end if;
  if p ? 'bypass' then
    v_bypass := (p ->> 'bypass')::boolean;
    select * into b from bookings where id = b.id;
    if v.outside_fleet and not v_bypass then raise exception 'A car not in the fleet is always off the calendar and owner notices' using errcode = '23514'; end if;
    if v_bypass is distinct from app.insurer_bypass(b) then
      perform app.set_blocks_calendar(b.id, not v_bypass, p_by, case when v_bypass then 'Insurance replacement: off the calendar and owner notices' else 'Insurance replacement: back on the calendar' end);
      v_changed := v_changed || case when v_bypass then 'off the calendar and owner notices' else 'on the calendar, shown to the owner' end;
    end if;
  end if;
  if cardinality(v_changed) > 0 then perform app.insurer_log(p_by, b.id, 'Changed: ' || array_to_string(v_changed, ', ')); end if;
  return jsonb_build_object('booking_number', b.booking_number, 'changed', to_jsonb(v_changed));
end $$;

-- p: booking, return_at (the new end), reason. The insurer authorized it, so it is applied at once, as the calendar's
-- insurer path of 0020 does (priced by app.calendar_preview_change, refused when the car is not free and the rental is on
-- the calendar), but nothing is charged to the renter's card or refunded: the insurer is invoiced. The invoice's next
-- version takes the new figures.
create function app.insurer_rental_extend(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  v vehicles;
  v_to timestamptz;
  v_reason text := coalesce(nullif(btrim(coalesce(p ->> 'reason', '')), ''), 'The insurer extended the rental');
  v_retired timestamptz;
  pv jsonb;
  nw jsonb;
  v_diff bigint;
  f fee_types;
begin
  perform app.insurer_assert(p_by);
  b := app.insurer_booking(p ->> 'booking');
  begin v_to := (p ->> 'return_at')::timestamptz; exception when others then v_to := null; end;
  if v_to is null or v_to <= b.pickup_at then raise exception 'return_at: the new return, after the pickup' using errcode = '22023'; end if;
  if v_to = b.return_at then raise exception 'Nothing would change' using errcode = '22023'; end if;
  if b.status not in ('confirmed', 'on_rent', 'returned') then raise exception 'Booking % is %: only a booking not yet closed changes its return', b.booking_number, b.status using errcode = '23514'; end if;
  select * into b from bookings where id = b.id for update;
  select * into v from vehicles where id = b.vehicle_id;
  -- a car not in the fleet is retired: open for this change only, retired again in the same transaction
  if v.outside_fleet and v.retired_at is not null then
    v_retired := v.retired_at;
    update vehicles set retired_at = null where id = v.id;
  end if;
  pv := app.calendar_preview_change(b.id, jsonb_build_object('return_at', v_to), now());
  if pv ->> 'refusal' is not null then raise exception '%', pv ->> 'refusal' using errcode = '23514'; end if;
  if b.blocks_calendar and not coalesce((pv ->> 'available')::boolean, true) then
    raise exception 'The car is not free for the new dates: a booking or a calendar block overlaps' using errcode = '23P01';
  end if;
  nw := pv -> 'new';
  update bookings set
      return_at = v_to, original_return_at = v_to, billable_days = coalesce((nw ->> 'billable_days')::integer, billable_days),
      km_allowance_total = km_allowance_per_day * coalesce((nw ->> 'billable_days')::integer, billable_days),
      rate_applied = coalesce(nw ->> 'rate_applied', rate_applied),
      daily_days = coalesce((nw ->> 'daily_days')::integer, daily_days), weekend_days = coalesce((nw ->> 'weekend_days')::integer, weekend_days),
      rental_charge_cents = coalesce((nw ->> 'rental_charge_cents')::bigint, rental_charge_cents)
   where id = b.id;
  -- the rental charge follows the new dates as a line of the extension, never a charge to the renter's card
  v_diff := coalesce((pv ->> 'difference_before_hst_cents')::bigint, 0);
  if v_diff <> 0 then
    select * into f from fee_types where code = 'rental_charge';
    insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents, revenue_class, stage, created_by)
    values (b.id, 'rental_charge', 'Rental charge: new return authorized by the insurer', 1, v_diff, v_diff, f.hst_applies,
            coalesce((pv ->> 'difference_cents')::bigint, 0) - v_diff, f.revenue_class, 'extension', p_by);
  end if;
  if v_retired is not null then update vehicles set retired_at = v_retired where id = v.id and retired_at is null; end if;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version, v_reason, p_by, 'staff',
      jsonb_build_object('return_at', v_to, 'insurer_extension', true));
  perform app.booking_jobs_follow(b.id);
  -- the invoice: a draft is drafted again from the booking, a sent one gets the new figures as its next version
  if exists (select 1 from insurer_invoices where booking_id = b.id) then perform app.draft_insurer_invoice(b.id, p_by); end if;
  perform app.insurer_log(p_by, b.id, format('Return moved from %s to %s: %s', app.fmt_date(b.return_at), app.fmt_date(v_to), v_reason));
  return jsonb_build_object('booking_number', b.booking_number, 'return_at', v_to);
end $$;

-- Edit the invoice's next version. p: booking (or invoice), and any of lines, hst_cents (null: worked out from the
-- taxable lines at the booking's rate), notes, period_start, period_end, invoice_date, due_date, bill_to {name,
-- attention, email, address}, claim_number; from_booking: true starts from the booking's figures now. A draft is
-- changed in place; a sent invoice keeps what was sent until the next version is sent.
create function app.insurer_invoice_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  ii insurer_invoices;
  w jsonb;
  v_lines jsonb;
  v_hst bigint;
  v_id uuid;
  k text;
begin
  perform app.insurer_assert(p_by);
  if nullif(p ->> 'invoice', '') is not null then
    select * into ii from insurer_invoices where id = (p ->> 'invoice')::uuid;
    if ii.id is null then raise exception 'invoice: not found' using errcode = 'P0002'; end if;
    select * into b from bookings where id = ii.booking_id;
  else
    b := app.insurer_booking(p ->> 'booking');
    ii := app.insurer_live_invoice(b.id);
    if ii.id is null or ii.status = 'written_off' then
      -- drafted first, read after (a row inserted inside a query's own WHERE is not seen by that query)
      v_id := app.draft_insurer_invoice(b.id, p_by);
      select * into ii from insurer_invoices where id = v_id;
    end if;
  end if;
  if ii.status = 'written_off' then raise exception 'Invoice % is written off', ii.invoice_number using errcode = '23514'; end if;
  w := case when coalesce((p ->> 'from_booking')::boolean, false) then app.insurer_working(ii) || app.insurer_from_booking(b.id) else app.insurer_working(ii) end;
  if p ? 'lines' then
    v_lines := app.insurer_lines_clean(p -> 'lines');
    w := w || jsonb_build_object('lines', v_lines);
    if not (p ? 'hst_cents') then
      w := w || jsonb_build_object('hst_cents', round((select coalesce(sum((e ->> 'amount_cents')::bigint), 0) from jsonb_array_elements(v_lines) e where coalesce((e ->> 'taxable')::boolean, true)) * b.hst_bps / 10000.0)::bigint);
    end if;
  end if;
  if p ? 'hst_cents' then
    v_hst := nullif(p ->> 'hst_cents', '')::numeric::bigint;
    if v_hst is null then
      v_hst := round((select coalesce(sum((e ->> 'amount_cents')::bigint), 0) from jsonb_array_elements(w -> 'lines') e where coalesce((e ->> 'taxable')::boolean, true)) * b.hst_bps / 10000.0)::bigint;
    end if;
    if v_hst < 0 then raise exception 'hst_cents: not below zero' using errcode = '22023'; end if;
    w := w || jsonb_build_object('hst_cents', greatest(v_hst, 0));
  end if;
  foreach k in array array['notes', 'claim_number'] loop
    if p ? k then
      if char_length(coalesce(p ->> k, '')) > 2000 then raise exception '%: at most 2000 characters', k using errcode = '22023'; end if;
      w := w || jsonb_build_object(k, nullif(btrim(coalesce(p ->> k, '')), ''));
    end if;
  end loop;
  foreach k in array array['period_start', 'period_end', 'invoice_date', 'due_date'] loop
    if p ? k then w := w || jsonb_build_object(k, nullif(p ->> k, '')::date); end if;
  end loop;
  if (w ->> 'period_end')::date < (w ->> 'period_start')::date then raise exception 'The rental period ends before it starts' using errcode = '22023'; end if;
  if (w ->> 'due_date')::date < (w ->> 'invoice_date')::date then raise exception 'The due date is before the invoice date' using errcode = '22023'; end if;
  if p ? 'bill_to' then
    if jsonb_typeof(p -> 'bill_to') is distinct from 'object' then raise exception 'bill_to: {name, attention, email, address}' using errcode = '22023'; end if;
    if nullif(btrim(coalesce(p #>> '{bill_to,email}', '')), '') is not null and btrim(p #>> '{bill_to,email}') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
      raise exception 'The bill-to email does not look right' using errcode = '22023';
    end if;
    w := w || jsonb_build_object('bill_to', jsonb_strip_nulls(jsonb_build_object(
      'name', left(nullif(btrim(coalesce(p #>> '{bill_to,name}', '')), ''), 200), 'attention', left(nullif(btrim(coalesce(p #>> '{bill_to,attention}', '')), ''), 200),
      'email', lower(nullif(btrim(coalesce(p #>> '{bill_to,email}', '')), '')), 'address', left(nullif(btrim(coalesce(p #>> '{bill_to,address}', '')), ''), 500))));
  end if;
  if app.insurer_lines_sum(w -> 'lines') < 0 then raise exception 'The lines add up to less than nothing' using errcode = '22023'; end if;
  if app.insurer_lines_sum(w -> 'lines') + coalesce((w ->> 'hst_cents')::bigint, 0) < ii.paid_cents then
    raise exception 'The total would be less than the % already paid', app.fmt_money(ii.paid_cents) using errcode = '23514';
  end if;
  if ii.status = 'draft' then
    update insurer_invoices set lines = w -> 'lines', amount_cents = app.insurer_lines_sum(w -> 'lines'), hst_cents = coalesce((w ->> 'hst_cents')::bigint, 0),
           notes = w ->> 'notes', claim_number = w ->> 'claim_number', period_start = coalesce((w ->> 'period_start')::date, period_start),
           period_end = coalesce((w ->> 'period_end')::date, period_end), invoice_date = (w ->> 'invoice_date')::date, due_date = (w ->> 'due_date')::date,
           bill_to = coalesce(w -> 'bill_to', '{}'::jsonb), pending = null
     where id = ii.id;
  else
    update insurer_invoices set pending = w where id = ii.id;
  end if;
  select * into ii from insurer_invoices where id = ii.id;
  return jsonb_build_object('invoice_id', ii.id, 'invoice_number', ii.invoice_number, 'status', ii.status, 'edited', ii.pending is not null,
    'working', app.insurer_working(ii), 'total_cents', app.insurer_lines_sum(app.insurer_working(ii) -> 'lines') + coalesce((app.insurer_working(ii) ->> 'hst_cents')::bigint, 0));
end $$;

-- Send the next version. p: booking (or invoice), kind (invoice or estimate), email (true: to the bill-to email, else
-- the adjuster's, else the insurer's billing email; false: recorded as sent another way). An invoice takes the working
-- copy (the amounts the insurer owes from now); an estimate changes nothing it owes. Each is a version, kept as sent.
create function app.insurer_invoice_send(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  ii insurer_invoices;
  w jsonb;
  v_kind text := coalesce(nullif(p ->> 'kind', ''), 'invoice');
  v_email boolean := coalesce((p ->> 'email')::boolean, true);
  v_total bigint;
  v_n integer;
  v_to text;
  v_to_name text;
  v_status text;
  v_event bigint;
  v_id uuid;
begin
  perform app.insurer_assert(p_by, true);
  if v_kind not in ('invoice', 'estimate') then raise exception 'kind: invoice or estimate' using errcode = '22023'; end if;
  if nullif(p ->> 'invoice', '') is not null then
    select * into ii from insurer_invoices where id = (p ->> 'invoice')::uuid for update;
  else
    b := app.insurer_booking(p ->> 'booking');
    v_id := (app.insurer_live_invoice(b.id)).id;
    if v_id is null then v_id := app.draft_insurer_invoice(b.id, p_by); end if;
    select * into ii from insurer_invoices where id = v_id for update;
  end if;
  if ii.id is null then raise exception 'invoice: not found' using errcode = 'P0002'; end if;
  if ii.status = 'written_off' then raise exception 'Invoice % is written off', ii.invoice_number using errcode = '23514'; end if;
  select * into b from bookings where id = ii.booking_id;
  w := app.insurer_working(ii);
  v_total := app.insurer_lines_sum(w -> 'lines') + coalesce((w ->> 'hst_cents')::bigint, 0);
  if v_kind = 'invoice' and v_total < ii.paid_cents then raise exception 'The total is less than the % already paid', app.fmt_money(ii.paid_cents) using errcode = '23514'; end if;
  if v_total <= 0 then raise exception 'Nothing to bill: add the lines first' using errcode = '23514'; end if;
  if v_email then
    v_to := coalesce(nullif(w #>> '{bill_to,email}', ''), nullif(btrim(coalesce(b.insurer_adjuster_email, '')), ''));
    v_to_name := case when nullif(w #>> '{bill_to,email}', '') is not null then coalesce(nullif(w #>> '{bill_to,attention}', ''), nullif(w #>> '{bill_to,name}', ''))
                      when v_to is not null then nullif(btrim(coalesce(b.insurer_adjuster_name, '')), '') end;
    if v_to is null then select nullif(btrim(x.billing_email), ''), coalesce(nullif(btrim(x.billing_contact_name), ''), x.name) into v_to, v_to_name from insurers x where x.id = ii.insurer_id; end if;
    if v_to is null or v_to !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
      raise exception 'No email to send it to: type the bill-to email, the adjuster''s email, or the insurer''s billing email in Settings, Insurers' using errcode = '23514';
    end if;
  end if;
  v_n := ii.version + 1;
  if v_kind = 'invoice' then
    v_status := case when ii.paid_cents >= v_total then 'paid' when ii.paid_cents > 0 then 'part_paid' else 'sent' end;
    update insurer_invoices
       set lines = w -> 'lines', amount_cents = app.insurer_lines_sum(w -> 'lines'), hst_cents = coalesce((w ->> 'hst_cents')::bigint, 0),
           notes = w ->> 'notes', claim_number = w ->> 'claim_number', period_start = coalesce((w ->> 'period_start')::date, period_start),
           period_end = coalesce((w ->> 'period_end')::date, period_end), invoice_date = coalesce((w ->> 'invoice_date')::date, app.local_date(now())),
           due_date = (w ->> 'due_date')::date, bill_to = coalesce(w -> 'bill_to', '{}'::jsonb), pending = null, version = v_n,
           status = v_status, sent_at = coalesce(sent_at, now()), sent_by = coalesce(sent_by, p_by),
           paid_at = case when v_status = 'paid' then coalesce(paid_at, now()) end
     where id = ii.id;
    select * into ii from insurer_invoices where id = ii.id;
    w := app.insurer_working(ii);
  else
    update insurer_invoices set version = v_n where id = ii.id;
  end if;
  insert into insurer_invoice_versions (invoice_id, version, kind, snapshot, emailed_to, sent_by)
  values (ii.id, v_n, v_kind, app.insurer_snapshot(ii, w, v_kind, v_n), v_to, p_by);
  if v_email then
    v_event := app.emit_event(case v_kind when 'estimate' then 'insurer_estimate' else 'insurer_invoice' end, 'insurer_invoice', ii.id,
                              jsonb_build_object('insurer_id', ii.insurer_id, 'to_email', v_to, 'to_name', v_to_name, 'version', v_n),
                              'insurer_invoice:' || ii.id || ':v' || v_n);
  end if;
  perform app.insurer_log(p_by, b.id, format('%s %s version %s sent%s: %s', initcap(v_kind), ii.invoice_number, v_n,
    case when v_email then ' to ' || v_to else ' another way' end, app.fmt_money(v_total)), jsonb_build_object('version', v_n, 'kind', v_kind));
  return jsonb_build_object('invoice_id', ii.id, 'invoice_number', ii.invoice_number, 'version', v_n, 'kind', v_kind, 'status', ii.status, 'to', v_to,
                            'total_cents', v_total, 'pdf_path', '/files/insurer_invoice/' || ii.id || ':v' || v_n, 'event_id', v_event);
end $$;

-- Getting paid. p: booking (or invoice), action:
--   payment      amount_cents, method (cheque, e_transfer or direct_deposit), reference, received_on (a date)
--   approved     amount_cents (what the adjuster approved; null clears it), note
--   negotiating  note (what is disputed); negotiating false ends it
--   write_off    reason: what is left unpaid is written off
create function app.insurer_money(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  ii insurer_invoices;
  v_action text := coalesce(p ->> 'action', '');
  v_amount bigint := nullif(p ->> 'amount_cents', '')::numeric::bigint;
  v_method text;
  v_note text := nullif(btrim(coalesce(p ->> 'note', p ->> 'reason', '')), '');
  v_status text;
begin
  perform app.insurer_assert(p_by, true);
  if nullif(p ->> 'invoice', '') is not null then
    select * into ii from insurer_invoices where id = (p ->> 'invoice')::uuid;
  else
    b := app.insurer_booking(p ->> 'booking');
    ii := app.insurer_live_invoice(b.id);
  end if;
  if ii.id is null then raise exception 'There is no invoice yet: send one first' using errcode = 'P0002'; end if;
  select * into b from bookings where id = ii.booking_id;
  if char_length(coalesce(v_note, '')) > 2000 then raise exception 'The note: at most 2000 characters' using errcode = '22023'; end if;
  case v_action
  when 'payment' then
    v_method := case p ->> 'method' when 'cheque' then 'cheque' when 'e_transfer' then 'e_transfer' when 'direct_deposit' then 'bank_transfer' when 'bank_transfer' then 'bank_transfer' end;
    if v_method is null then raise exception 'method: cheque, e_transfer or direct_deposit' using errcode = '22023'; end if;
    v_status := app.record_insurer_payment(ii.id, v_amount, p_by, v_method,
                  coalesce(nullif(p ->> 'received_on', '')::date::timestamp at time zone 'America/Toronto' + interval '12 hours', now()), nullif(btrim(coalesce(p ->> 'reference', '')), ''));
    perform app.insurer_log(p_by, b.id, format('Payment of %s by %s%s', app.fmt_money(v_amount), replace(coalesce(p ->> 'method', ''), '_', ' '),
      coalesce(', reference ' || nullif(btrim(coalesce(p ->> 'reference', '')), ''), '')));
  when 'approved' then
    if v_amount is not null and v_amount < 0 then raise exception 'amount_cents: what the adjuster approved, in cents' using errcode = '22023'; end if;
    update insurer_invoices set approved_cents = v_amount, approved_at = case when v_amount is not null then now() end, approved_by = case when v_amount is not null then p_by end,
           negotiating_at = case when v_amount is not null then null else negotiating_at end where id = ii.id;
    perform app.insurer_log(p_by, b.id, case when v_amount is null then 'Approved amount cleared' else format('Approved by the adjuster: %s%s', app.fmt_money(v_amount), coalesce(': ' || v_note, '')) end);
  when 'negotiating' then
    if coalesce((p ->> 'negotiating')::boolean, true) then
      if v_note is null then raise exception 'Say what the adjuster disputes' using errcode = '22023'; end if;
      update insurer_invoices set negotiating_at = coalesce(negotiating_at, now()), negotiation_note = v_note where id = ii.id;
      perform app.insurer_log(p_by, b.id, 'Negotiating: ' || v_note);
    else
      update insurer_invoices set negotiating_at = null where id = ii.id;
      perform app.insurer_log(p_by, b.id, 'Negotiation ended');
    end if;
  when 'write_off' then
    if v_note is null then raise exception 'Give the reason for the write-off' using errcode = '22023'; end if;
    if ii.status not in ('sent', 'part_paid') then raise exception 'Only what is left of a sent invoice is written off' using errcode = '23514'; end if;
    update insurer_invoices set status = 'written_off', written_off_at = now(), written_off_by = p_by, written_off_reason = v_note where id = ii.id;
    perform app.insurer_log(p_by, b.id, format('Written off: %s (%s)', app.fmt_money(ii.balance_cents), v_note));
  else
    raise exception 'action: payment, approved, negotiating or write_off' using errcode = '22023';
  end case;
  select * into ii from insurer_invoices where id = ii.id;
  return jsonb_build_object('invoice_number', ii.invoice_number, 'status', ii.status, 'paid_cents', ii.paid_cents, 'balance_cents', ii.balance_cents,
                            'approved_cents', ii.approved_cents, 'written_off_cents', ii.written_off_cents, 'stage', app.insurer_stage(b, ii));
end $$;

-- ================================================================ 5. the invoice of 0016, the PDF, the emails
-- Drafting again returns the booking's invoice once it has one: a draft is drafted again from the booking (0016), a sent
-- one gets the booking's figures as its next version. Never "Nothing is left to invoice".
alter function app.draft_insurer_invoice(uuid, uuid) rename to draft_insurer_invoice_pre5120;
create function app.draft_insurer_invoice(p_booking uuid, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  ii insurer_invoices := app.insurer_live_invoice(p_booking);
begin
  if ii.id is null or ii.status = 'written_off' then return app.draft_insurer_invoice_pre5120(p_booking, p_by); end if;
  if ii.status = 'draft' then
    -- a draft edited by hand keeps its lines (version 0 and edited lines: the Insurance replacements page); else redrafted
    if ii.bill_to <> '{}'::jsonb or ii.invoice_date is not null or exists (select 1 from jsonb_array_elements(ii.lines) e where e ? 'quantity') then
      update insurer_invoices set pending = null where id = ii.id;
      return ii.id;
    end if;
    return app.draft_insurer_invoice_pre5120(p_booking, p_by);
  end if;
  update insurer_invoices set pending = app.insurer_working(ii) || app.insurer_from_booking(p_booking) where id = ii.id;
  return ii.id;
end $$;
select pg_temp.copy_grants('app.draft_insurer_invoice(uuid, uuid)'::regprocedure, 'app.draft_insurer_invoice_pre5120(uuid, uuid)'::regprocedure);

-- The PDF: a version (key <invoice>:v<n>) prints what was sent, as an estimate or an invoice, and is stored once; the
-- invoice itself (key <invoice>) prints as it stands and is drawn each time (it changes with each version).
alter function app.pdf_facts(text, text, uuid) rename to pdf_facts_pre5120;
create function app.pdf_facts(p_kind text, p_key text, p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  -- only an insurer invoice's key carries a version (<invoice>:v<n>); every other kind's key goes through unchanged
  f jsonb := app.pdf_facts_pre5120(p_kind, case when p_kind = 'insurer_invoice' then left(p_key, 36) else p_key end, p_user);
  ii insurer_invoices;
  x insurer_invoice_versions;
  s jsonb;
  v_n integer := (substring(p_key from ':v([0-9]{1,4})$'))::integer;
begin
  if p_kind <> 'insurer_invoice' then return f; end if;
  if f is null then return null; end if;
  select * into ii from insurer_invoices where id = app.file_key_id(p_key);
  if v_n is not null then
    select * into x from insurer_invoice_versions where invoice_id = ii.id and version = v_n;
    if x.id is null then return null; end if;
    s := x.snapshot;
  elsif ii.version > 0 or ii.bill_to <> '{}'::jsonb or ii.notes is not null then
    s := app.insurer_snapshot(ii, app.insurer_working(ii) - 'lines' - 'hst_cents' - 'notes' - 'period_start' - 'period_end' - 'invoice_date' - 'due_date' - 'bill_to' - 'claim_number'
           || jsonb_build_object('lines', ii.lines, 'hst_cents', ii.hst_cents, 'notes', ii.notes, 'period_start', ii.period_start, 'period_end', ii.period_end,
                                 'invoice_date', ii.invoice_date, 'due_date', ii.due_date, 'bill_to', ii.bill_to, 'claim_number', ii.claim_number), 'invoice', ii.version);
  end if;
  if s is null then return f || jsonb_build_object('store', false); end if;
  return f || jsonb_build_object(
    'doc_kind', s ->> 'kind', 'version', (s ->> 'version')::integer,
    'title', case when s ->> 'kind' = 'estimate' then 'Estimate ' else 'Invoice ' end || ii.invoice_number || case when coalesce((s ->> 'version')::integer, 0) > 1 then ' (version ' || (s ->> 'version') || ')' else '' end,
    'file_name', 'blindspot-' || coalesce(s ->> 'kind', 'invoice') || '-' || ii.invoice_number || case when v_n is not null then '-v' || v_n else '' end || '.pdf',
    'lines', coalesce(s -> 'lines', '[]'::jsonb), 'fee_items', '[]'::jsonb, 'amount_cents', (s ->> 'amount_cents')::bigint, 'hst_cents', (s ->> 'hst_cents')::bigint,
    'total_cents', (s ->> 'total_cents')::bigint,
    'paid_cents', case when s ->> 'kind' = 'estimate' then 0 else coalesce((s ->> 'paid_cents')::bigint, 0) end,
    'balance_cents', case when s ->> 'kind' = 'estimate' then (s ->> 'total_cents')::bigint else (s ->> 'total_cents')::bigint - coalesce((s ->> 'paid_cents')::bigint, 0) end,
    'period_start', s ->> 'period_start', 'period_end', s ->> 'period_end', 'claim_number', coalesce(s ->> 'claim_number', f ->> 'claim_number'),
    'invoice_date', s ->> 'invoice_date', 'due_date', s ->> 'due_date', 'bill_to', coalesce(s -> 'bill_to', '{}'::jsonb), 'adjuster', s -> 'adjuster',
    'notes', s ->> 'notes', 'sent_at', coalesce(x.sent_at, ii.sent_at), 'final', true, 'store', v_n is not null);
end $$;
select pg_temp.copy_grants('app.pdf_facts(text, text, uuid)'::regprocedure, 'app.pdf_facts_pre5120(text, text, uuid)'::regprocedure);

-- The emails to the insurer: a version's own values and its own PDF (insurer_estimate is new: 5121)
alter function app.notification_payload(text, app_events, jsonb) rename to notification_payload_pre5120;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  x jsonb;
  s jsonb;
  ii insurer_invoices;
begin
  if p_code not in ('insurer_invoice', 'insurer_estimate') then return app.notification_payload_pre5120(p_code, p_event, p_to); end if;
  x := app.notification_payload_pre5120('insurer_invoice', p_event, p_to);
  if nullif(p_event.payload ->> 'version', '') is null then return x; end if;
  select * into ii from insurer_invoices where id = p_event.entity_id;
  select v.snapshot into s from insurer_invoice_versions v where v.invoice_id = ii.id and v.version = (p_event.payload ->> 'version')::integer;
  if s is null then return x; end if;
  return x || jsonb_build_object(
    'claim_number', coalesce(nullif(s ->> 'claim_number', ''), 'not given'),
    'period', coalesce(app.fmt_day((s ->> 'period_start')::date) || ' to ' || app.fmt_day((s ->> 'period_end')::date), x ->> 'period'),
    'invoice_amount', app.fmt_money((s ->> 'amount_cents')::bigint), 'invoice_hst', app.fmt_money((s ->> 'hst_cents')::bigint),
    'invoice_total', app.fmt_money((s ->> 'total_cents')::bigint), 'version', s ->> 'version',
    'invoice_lines', coalesce((select jsonb_agg(jsonb_build_object('label', e ->> 'description', 'amount', app.fmt_money((e ->> 'amount_cents')::bigint)))
                                 from jsonb_array_elements(s -> 'lines') e), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.notification_payload_pre5120(text, app_events, jsonb)'::regprocedure);

alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre5120;
create function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  if p_c.code = 'insurer_estimate' and nullif(btrim(coalesce(p_event.payload ->> 'to_email', '')), '') is not null then
    return query select 'insurer'::text, null::uuid, btrim(p_event.payload ->> 'to_email'), coalesce(nullif(p_event.payload ->> 'to_name', ''), 'there'),
                        null::uuid, null::uuid, true;
    return;
  end if;
  return query select * from app.notification_recipients_pre5120(p_event, p_c);
end $$;
select pg_temp.copy_grants('app.notification_recipients(app_events, notification_catalogue)'::regprocedure, 'app.notification_recipients_pre5120(app_events, notification_catalogue)'::regprocedure);

-- the PDF link of a version's email opens that version
alter function app.outbox_file_refs(uuid) rename to outbox_file_refs_pre5120;
create function app.outbox_file_refs(p_outbox uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  o notification_outbox;
  v_n text;
begin
  select * into o from notification_outbox where id = p_outbox;
  if o.code in ('insurer_invoice', 'insurer_estimate') then
    select e.payload ->> 'version' into v_n from app_events e where e.id = o.event_id;
    if v_n is not null then return jsonb_build_object('invoice_url', jsonb_build_object('k', 'insurer_invoice', 'key', o.entity_id::text || ':v' || v_n)); end if;
  end if;
  return app.outbox_file_refs_pre5120(p_outbox);
end $$;
select pg_temp.copy_grants('app.outbox_file_refs(uuid)'::regprocedure, 'app.outbox_file_refs_pre5120(uuid)'::regprocedure);

-- the aging reminder (0023) and the new rental's notice open the page
insert into notification_link_paths (key, path) values
  ('va_finance_insurer_invoice', '/staff/insurance-replacements?q={{invoice_number}}'),
  ('insurer_rental', '/staff/insurance-replacements/{{booking_number}}')
on conflict (key) do update set path = excluded.path;

-- ================================================================ 6. unfinished rentals never vanish
-- Every open draft is listed whatever its age (0148 hid it after 30 days without a save), with the form it belongs to.
create or replace function app.drafts_list(p_by uuid, p jsonb) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'quick', d.quick, 'updated_at', d.updated_at, 'created_at', d.created_at,
           'by', (select coalesce(u.full_name, u.email) from users u where u.id = d.created_by), 'mine', d.created_by = p_by,
           'vehicle', case when d.vehicle_id is not null then app.vehicle_name(d.vehicle_id) end, 'form', d.data ->> 'form',
           'held_until', (select k.ends_at from vehicle_calendar_blocks k where k.id = d.hold_block_id and k.removed_at is null and k.ends_at > now()),
           'missing', to_jsonb(case when d.data ->> 'form' = 'insurer' then array_remove(array[
               case when coalesce(d.data #>> '{f,renter_name}', '') = '' then 'the renter' end,
               case when coalesce(d.data #>> '{f,claim_number}', '') = '' then 'the claim number' end,
               case when coalesce(d.data #>> '{f,pickup_at}', '') = '' or coalesce(d.data #>> '{f,return_at}', '') = '' then 'the dates' end], null)
             else app.draft_missing(d.kind, d.data) end)) order by d.updated_at desc), '[]'::jsonb)
    from rental_drafts d
   where app.may_draft(p_by) and d.status = 'open' and (nullif(p ->> 'kind', '') is null or d.kind = p ->> 'kind')
     and (d.created_by = p_by or not coalesce((p ->> 'mine')::boolean, false))
$$;

-- a draft says what became of it: added (the booking), or discarded (who and when), so the page can say so
alter function app.draft_get(uuid, jsonb) rename to draft_get_pre5120;
create function app.draft_get(p_by uuid, p jsonb) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.draft_get_pre5120(p_by, p) || jsonb_build_object('finished_at', d.finished_at,
           'booking_number', (select b.booking_number from bookings b where b.id = d.booking_id),
           'closed_by', (select coalesce(u.full_name, u.email) from users u where u.id = d.updated_by), 'form', d.data ->> 'form')
    from rental_drafts d where d.id = (p ->> 'id')::uuid and app.may_draft(p_by)
$$;
select pg_temp.copy_grants('app.draft_get(uuid, jsonb)'::regprocedure, 'app.draft_get_pre5120(uuid, jsonb)'::regprocedure);

-- a discarded draft comes back (an added one does not: its booking exists)
create function app.draft_restore(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare d rental_drafts;
begin
  if not app.may_draft(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into d from rental_drafts where id = (p ->> 'id')::uuid for update;
  if d.id is null then raise exception 'That draft is not there' using errcode = 'P0002'; end if;
  if d.status = 'done' then raise exception 'That draft was added as a rental: open the booking' using errcode = '23514'; end if;
  if d.status = 'discarded' then
    update rental_drafts set status = 'open', finished_at = null, updated_by = p_by where id = d.id;
  end if;
  return jsonb_build_object('id', d.id, 'status', 'open');
end $$;

-- ================================================================ 7. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5120;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_call = 'ops_read' and p_name in ('insurer_rentals', 'insurer_rental') then
    perform app.door_begin(p_user, p_aal);
    if p_name = 'insurer_rental' then return app.insurer_rental_json(p_user, coalesce(p, '{}'::jsonb)); end if;
    return app.insurer_rentals_json(p_user, coalesce(p, '{}'::jsonb));
  elsif p_call = 'ops_do' and p_name in ('insurer_rental_create', 'insurer_rental_update', 'insurer_rental_extend', 'insurer_invoice_save', 'insurer_invoice_send', 'insurer_money', 'draft_restore') then
    perform app.door_begin(p_user, p_aal);
    case p_name
    when 'insurer_rental_create' then return app.insurer_rental_create(p_user, coalesce(p, '{}'::jsonb));
    when 'insurer_rental_update' then return app.insurer_rental_update(p_user, coalesce(p, '{}'::jsonb));
    when 'insurer_rental_extend' then return app.insurer_rental_extend(p_user, coalesce(p, '{}'::jsonb));
    when 'insurer_invoice_save' then return app.insurer_invoice_save(p_user, coalesce(p, '{}'::jsonb));
    when 'insurer_invoice_send' then return app.insurer_invoice_send(p_user, coalesce(p, '{}'::jsonb));
    when 'insurer_money' then return app.insurer_money(p_user, coalesce(p, '{}'::jsonb));
    else return app.draft_restore(p_user, coalesce(p, '{}'::jsonb));
    end case;
  end if;
  return app.door_pre5120(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5120(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 8. the connector
-- list_insurer_rentals, get_insurer_rental (admin:read); insurer_rental_create, insurer_rental_update,
-- insurer_rental_extend, insurer_invoice_edit, insurer_invoice_send, insurer_money (admin:write). A write is previewed by
-- running it and undoing it (the preview shows exactly what the screens would do, or their refusal), then confirmed
-- with the same arguments and the preview_id. The key's person must work Insurance replacements (an Admin, Finance or
-- customer service); money needs Finance or an Admin.
create function app.insurer_tool_run(p_user uuid, p_tool text, a jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  return case p_tool
    when 'insurer_rental_create' then app.insurer_rental_create(p_user, a)
    when 'insurer_rental_update' then app.insurer_rental_update(p_user, a)
    when 'insurer_rental_extend' then app.insurer_rental_extend(p_user, a)
    when 'insurer_invoice_edit' then app.insurer_invoice_save(p_user, a)
    when 'insurer_invoice_send' then app.insurer_invoice_send(p_user, a)
    when 'insurer_money' then app.insurer_money(p_user, a) end;
end $$;

alter function app.api_call(text, text, jsonb, text) rename to api_call_pre5120;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  chk jsonb;
  k api_keys;
  v_args jsonb;
  v_confirm boolean;
  pv api_previews;
  v_result jsonb;
  v_after jsonb;
  v_target text;
  v_before jsonb;
begin
  if p_tool not in ('list_insurer_rentals', 'get_insurer_rental', 'insurer_rental_create', 'insurer_rental_update', 'insurer_rental_extend', 'insurer_invoice_edit',
                    'insurer_invoice_send', 'insurer_money') then
    return app.api_call_pre5120(p_hash, p_tool, p_args, p_client);
  end if;
  v_args := a - 'confirm' - 'preview_id';
  v_target := left(coalesce(a ->> 'booking', a ->> 'claim_number', a ->> 'query', p_tool), 200);
  if p_tool in ('list_insurer_rentals', 'get_insurer_rental') then
    chk := app.api_key_check(p_hash, 'admin:read', p_tool, a, p_client);
    if not (chk ->> 'ok')::boolean then return chk; end if;
    k := jsonb_populate_record(null::api_keys, chk -> 'key');
    perform app.door_begin(k.user_id, 'aal2');
    begin
      v_result := case p_tool when 'get_insurer_rental' then app.insurer_rental_json(k.user_id, jsonb_build_object('booking', a ->> 'booking'))
                  else app.insurer_rentals_json(k.user_id, jsonb_strip_nulls(jsonb_build_object('q', a ->> 'query', 'stage', a ->> 'stage', 'aging', a ->> 'aging', 'limit', a ->> 'limit'))) end;
    exception when others then
      insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, v_target, a, false, left(sqlerrm, 500), left(p_client, 64));
      return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
    end;
    insert into api_calls (key_id, user_id, tool, target, args, ok, client) values (k.id, k.user_id, p_tool, v_target, a, true, left(p_client, 64));
    return jsonb_build_object('ok', true, 'result', v_result);
  end if;

  chk := app.api_key_check(p_hash, 'admin:write', p_tool, v_args, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  v_confirm := coalesce((a ->> 'confirm')::boolean, false);
  begin
    if nullif(a ->> 'booking', '') is not null then
      begin v_before := app.insurer_rental_json(k.user_id, jsonb_build_object('booking', a ->> 'booking')) - 'insurers' - 'history' - 'from_booking';
      exception when others then v_before := null; end;
    end if;
    if not v_confirm then
      -- the dry run: done, read back, undone
      begin
        v_after := app.insurer_tool_run(k.user_id, p_tool, v_args);
        raise exception using errcode = 'P0001', message = 'cc_preview_undo';
      exception when others then
        if sqlerrm <> 'cc_preview_undo' then raise; end if;
      end;
      insert into api_previews (key_id, user_id, tool, args, before, after) values (k.id, k.user_id, p_tool, v_args, v_before, v_after) returning * into pv;
      v_result := jsonb_build_object('preview', true, 'preview_id', pv.id, 'tool', p_tool, 'expires_at', pv.created_at + interval '10 minutes',
        'before', v_before, 'after', v_after,
        'will_do', case p_tool
          when 'insurer_rental_create' then format('Add an insurance replacement for %s, claim %s, as the Insurance replacements page does (the renter, the insurer, the car and the dates as given).', a ->> 'renter_name', a ->> 'claim_number')
          when 'insurer_rental_update' then format('Change %s: %s.', a ->> 'booking', array_to_string(array(select x from jsonb_object_keys(v_args - 'booking') x order by x), ', '))
          when 'insurer_rental_extend' then format('Move the return of %s to %s (the renter agreed) and give the invoice the new figures as its next version.', a ->> 'booking', a ->> 'return_at')
          when 'insurer_invoice_edit' then format('Edit the next version of the invoice of %s (sent versions never change).', a ->> 'booking')
          when 'insurer_invoice_send' then format('Send %s of %s as a new version%s.', coalesce(nullif(a ->> 'kind', ''), 'the invoice'), a ->> 'booking',
                                                  case when coalesce((a ->> 'email')::boolean, true) then ', by email to ' || coalesce(v_after ->> 'to', 'the adjuster') else ', recorded as sent another way' end)
          else format('Record on %s: %s.', a ->> 'booking', coalesce(a ->> 'action', '?')) end,
        'next', 'Nothing was changed. To do it, call this tool again with exactly the same arguments plus "confirm": true and "preview_id": "' || pv.id || '".');
    else
      select * into pv from api_previews where id = nullif(a ->> 'preview_id', '')::uuid for update;
      if pv.id is null or pv.key_id <> k.id or pv.tool <> p_tool then raise exception 'Preview first: call without confirm, then confirm with its preview_id' using errcode = '22023'; end if;
      if pv.used_at is not null then raise exception 'This preview was already used: preview again' using errcode = '22023'; end if;
      if pv.created_at < now() - interval '10 minutes' then raise exception 'This preview is more than 10 minutes old: preview again' using errcode = '22023'; end if;
      if pv.args is distinct from v_args then raise exception 'The arguments differ from the preview: preview again with these' using errcode = '22023'; end if;
      update api_previews set used_at = now() where id = pv.id;
      v_after := app.insurer_tool_run(k.user_id, p_tool, v_args);
      v_result := jsonb_build_object('done', true, 'tool', p_tool, 'result', v_after,
        'admin_path', '/admin/insurance-replacements/' || coalesce(v_after ->> 'booking_number', a ->> 'booking', ''));
    end if;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, v_target, v_args, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, before, after, ok, client)
  values (k.id, k.user_id, case when v_confirm then p_tool else p_tool || ':preview' end, v_target, v_args, v_before, v_after, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre5120(text, text, jsonb, text)'::regprocedure);

-- ================================================================ 8b. Paste text: a new AI purpose (web/src/integrations/ai/guard.ts claim_read)
create or replace function app.ai_purposes() returns text[]
language sql immutable as $$
  select array['chat', 'faq_reply', 'staff_assistant', 'draft_copy', 'seo_car', 'seo_page', 'seo_article', 'guide_rewrite', 'turo_email', 'phone_draft',
               'phone_summary', 'interview_followup', 'interview_score', 'car_value', 'intent_enrich', 'toll_read', 'plate_detect', 'photo_sort', 'photo_check',
               'guide_review', 'colour_read', 'vin_read', 'dash_read', 'licence_read', 'permit_read', 'interview_transcribe', 'call_transcribe', 'claim_read']
$$;
-- a claim notice names the renter and their claim: never to Gemini's free tier (chain.ts PRIVATE_PURPOSES)
create or replace function app.ai_private(p_purpose text) returns boolean
language sql immutable as $$
  select p_purpose in ('licence_read', 'permit_read', 'interview_transcribe', 'call_transcribe', 'phone_summary', 'interview_followup', 'interview_score', 'claim_read')
$$;

alter function app.ai_tier(text) rename to ai_tier_pre5120;
create function app.ai_tier(p_purpose text) returns text
language sql immutable as $$ select case when p_purpose = 'claim_read' then 'live' else app.ai_tier_pre5120(p_purpose) end $$;
select pg_temp.copy_grants('app.ai_tier(text)'::regprocedure, 'app.ai_tier_pre5120(text)'::regprocedure);
alter function app.ai_feature_label(text) rename to ai_feature_label_pre5120;
create function app.ai_feature_label(p_purpose text) returns text
language sql immutable as $$ select case when p_purpose = 'claim_read' then 'Insurance replacements: Paste text' else app.ai_feature_label_pre5120(p_purpose) end $$;
select pg_temp.copy_grants('app.ai_feature_label(text)'::regprocedure, 'app.ai_feature_label_pre5120(text)'::regprocedure);

-- ================================================================ 9. privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['insurer_rentals_may', 'insurer_assert', 'insurer_booking', 'insurer_live_invoice', 'insurer_lines_clean',
                    'insurer_lines_sum', 'insurer_from_booking', 'insurer_working', 'insurer_snapshot', 'insurer_bypass', 'insurer_stage', 'insurer_log', 'insurer_rentals_json',
                    'insurer_rental_json', 'insurer_pick', 'insurer_rental_create', 'insurer_rental_update', 'insurer_rental_extend', 'insurer_invoice_save', 'insurer_invoice_send',
                    'insurer_money', 'insurer_tool_run', 'draft_restore', 'drafts_list', 'draft_insurer_invoice_pre5120', 'pdf_facts_pre5120', 'notification_payload_pre5120',
                    'notification_recipients_pre5120', 'outbox_file_refs_pre5120', 'draft_get_pre5120', 'door_pre5120', 'api_call_pre5120',
                    'insurer_invoices_write_off_amount', 'insurer_invoice_versions_frozen', 'ai_tier_pre5120', 'ai_feature_label_pre5120'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
