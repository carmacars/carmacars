-- 2981 (release 48): long-term rentals paid weekly never fall off the calendar
-- (docs/changes/2026-11-14-r48-rolling-weekly.md).
--
-- The owner (Nov 14): a renter on a long rental pays week by week; the booking's return was the end of the week paid,
-- so once that time passed the car showed free on the calendar and on the site while it was still out. Now a booking can
-- be "long-term, paid weekly" (Admin, customer service, finance or fleet; the connector: change_booking with
-- changes.rolling_weekly true):
--   rolling_rentals       one row per booking: who turned it on and when, the notice (end_at: "End rental on <date>"),
--                         the reminder sent for which return, and whether the pay link is waiting to go
--   the calendar          a block on the car from the current return until the notice date (no date: until notice),
--                         kept by itself: the car is out for the calendar, the site's search and every booking check,
--                         and the booking's own next week is never refused because of it
--   each week             one 7-day extension (booking_extensions, rolling): priced like any extension (the booking's
--                         rates, app.preview_extension), up to the notice date. Recording the weekly payment (Record a
--                         payment of the rental with nothing of the rental open, or the connector's record_payment)
--                         confirms the week with that payment and the return moves 7 days; the renter's pay link
--                         confirms it the same way
--   48 hours before       (Program settings, Long-term weekly: reminder lead time) with the next week unpaid: an Admin
--                         To do and the renter's pay link for the next week (text, else email). Paid: the To do closes.
--   the notice            end_at: the last week stops there; the block ends there. Cleared: until notice again.
-- No applied migration is edited: the door and server_jobs_due are wrapped (_pre2981).
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

-- ================================================================ 1. the setting, the table, the block source
alter table program_settings add column if not exists rolling_weekly_lead_hours integer not null default 48
  check (rolling_weekly_lead_hours between 1 and 336);
comment on column program_settings.rolling_weekly_lead_hours is 'r48 (2981): a long-term rental paid weekly: this many hours before its return, with the next week unpaid, an Admin To do and the renter''s pay link for the next week.';

create table if not exists rolling_rentals (
  booking_id     uuid primary key references bookings (id) on delete cascade,
  started_at     timestamptz not null default now(),
  started_by     uuid references users (id) on delete set null,
  end_at         timestamptz,
  end_set_by     uuid references users (id) on delete set null,
  end_set_at     timestamptz,
  reminded_for   timestamptz,
  link_due       boolean not null default false,
  stopped_at     timestamptz,
  stopped_by     uuid references users (id) on delete set null
);
create index if not exists rolling_rentals_on on rolling_rentals (booking_id) where stopped_at is null;
create index if not exists rolling_rentals_started_by_idx on rolling_rentals (started_by) where started_by is not null;
create index if not exists rolling_rentals_end_set_by_idx on rolling_rentals (end_set_by) where end_set_by is not null;
create index if not exists rolling_rentals_stopped_by_idx on rolling_rentals (stopped_by) where stopped_by is not null;
comment on table rolling_rentals is 'r48 (2981): a booking that is a long-term rental paid weekly (on while stopped_at is null). end_at: the notice (the last day); reminded_for: the return the 48 hour reminder was sent for. Read through the door only.';
alter table rolling_rentals enable row level security;
create policy admin_all on rolling_rentals for select to authenticated using (app.is_admin());
revoke all on rolling_rentals from anon, authenticated;
grant all on rolling_rentals to service_role;
create trigger audit_rolling_rentals after insert or update or delete on rolling_rentals for each row execute function app.audit_row();

alter table booking_extensions add column if not exists rolling boolean not null default false;
comment on column booking_extensions.rolling is 'r48 (2981): the next week of a long-term rental paid weekly (made by itself, approved at once).';

alter table vehicle_calendar_blocks drop constraint if exists vehicle_calendar_blocks_source_check;
alter table vehicle_calendar_blocks add constraint vehicle_calendar_blocks_source_check check (source in ('staff', 'turnaround', 'external', 'rolling'));

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('rolling_week_due', 'admin', 'Long-term rental: next week not paid yet', 'high', 'none', null,
   'A long-term rental paid weekly (2981) returns soon and the next week is not paid. The renter has the pay link; collect the week (Record a payment adds the week and moves the return), or set the end date with End rental on. Done by itself when the week is paid.')
on conflict (task_type) do nothing;

-- ================================================================ 2. the rules
create function app.rolling_on(p_booking uuid) returns rolling_rentals
language sql stable security definer set search_path = public, app as $$
  select * from rolling_rentals where booking_id = p_booking and stopped_at is null
$$;

-- the return the next week ends at (the notice caps it); null: nothing more to add
create function app.rolling_next_return(b bookings, r rolling_rentals) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select case when r.booking_id is null or b.status not in ('confirmed', 'on_rent') then null
              when r.end_at is not null and r.end_at <= b.return_at then null
              else least(b.return_at + interval '7 days', coalesce(r.end_at, 'infinity'::timestamptz)) end
$$;

-- the block that keeps the car out after the return: from the return to the notice (none: until notice)
create function app.rolling_sync_block(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  r rolling_rentals;
  v_on boolean;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return; end if;
  r := app.rolling_on(b.id);
  v_on := r.booking_id is not null and b.status in ('confirmed', 'on_rent') and (r.end_at is null or r.end_at > b.return_at);
  if v_on then
    update vehicle_calendar_blocks set starts_at = b.return_at, ends_at = r.end_at, vehicle_id = b.vehicle_id
     where booking_id = b.id and source = 'rolling' and removed_at is null
       and (starts_at, ends_at, vehicle_id) is distinct from (b.return_at, r.end_at, b.vehicle_id);
    if not exists (select 1 from vehicle_calendar_blocks where booking_id = b.id and source = 'rolling' and removed_at is null) then
      insert into vehicle_calendar_blocks (vehicle_id, reason, starts_at, ends_at, note, booking_id, source)
      values (b.vehicle_id, 'admin', b.return_at, r.end_at,
              format('Long-term rental %s, paid weekly: out until %s', b.booking_number, coalesce(app.fmt_date(r.end_at), 'the renter gives notice')), b.id, 'rolling');
    end if;
  else
    update vehicle_calendar_blocks set removed_at = now(), removed_reason = 'The long-term rental ended or is no longer paid weekly'
     where booking_id = b.id and source = 'rolling' and removed_at is null;
  end if;
end $$;

create function app.rolling_follow_booking() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from rolling_rentals r where r.booking_id = new.id) then
    perform app.rolling_sync_block(new.id);
  end if;
  return null;
end $$;
create trigger bookings_rolling_block after update of return_at, status, vehicle_id on bookings for each row
  when (old.return_at is distinct from new.return_at or old.status is distinct from new.status or old.vehicle_id is distinct from new.vehicle_id)
  execute function app.rolling_follow_booking();

-- the next week as an extension, approved at once (an open one for that week is reused); null with the reason when it
-- cannot be made (another extension open, the preview refused it)
create function app.rolling_offer(p_booking uuid, out e booking_extensions, out problem text)
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  r rolling_rentals;
  v_next timestamptz;
  v jsonb;
begin
  select * into b from bookings where id = p_booking for update;
  r := app.rolling_on(p_booking);
  v_next := app.rolling_next_return(b, r);
  if v_next is null then problem := 'nothing more to add (the end date is reached)'; return; end if;
  select * into e from booking_extensions x where x.booking_id = b.id and x.status in ('requested', 'approved') order by x.seq desc limit 1;
  if e.id is not null then
    if e.rolling and e.status = 'approved' and e.previous_return_at = b.return_at and e.new_return_at = v_next then return; end if;
    if not e.rolling then e := null; problem := 'another extension is open on this booking'; return; end if;
    update booking_extensions set status = 'lapsed' where id = e.id;
    e := null;
  end if;
  v := app.preview_extension(b.id, v_next);
  if not coalesce((v ->> 'ok')::boolean, false) then
    problem := coalesce(v -> 'problems' -> 0 ->> 'message', 'the extension preview refused it'); return;
  end if;
  insert into booking_extensions (booking_id, seq, status, previous_return_at, new_return_at, previous_days, new_days,
      previous_rental_charge_cents, new_rental_charge_cents, rental_difference_cents, fees_difference_cents, hst_cents, total_cents,
      requested_by, note, lines, pricing, regular_total_cents, auto_approved, approved_at, rolling)
  values (b.id, (select coalesce(max(x.seq), 0) + 1 from booking_extensions x where x.booking_id = b.id), 'approved',
      b.return_at, v_next, b.billable_days, (v ->> 'new_days')::integer,
      (v ->> 'previous_rental_charge_cents')::bigint, (v ->> 'new_rental_charge_cents')::bigint, (v ->> 'rental_difference_cents')::bigint,
      (v ->> 'fees_difference_cents')::bigint, (v ->> 'hst_cents')::bigint, (v ->> 'total_cents')::bigint,
      null, 'Long-term rental, paid weekly: the next week', v -> 'lines', v ->> 'pricing', (v ->> 'regular_total_cents')::bigint, true, now(), true)
  returning * into e;
end $$;

-- Record a payment of the rental on a long-term weekly booking with no rental left open: the payment is the next week's.
-- The week is added as a confirmed extension (its lines, the new return: app.confirm_extension_payment, with nothing
-- charged there) and the money received is recorded as that extension's payment (like a card-paid extension), with the
-- same checks and the same receipt as Record a payment. p: {booking, method, amount_cents, reference, received_on, note}.
-- null: not this case (the payment is recorded as usual).
create function app.rolling_record_week(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  o record;
  v_total bigint;
  v jsonb;
  v_method text := nullif(btrim(coalesce(p ->> 'method', '')), '');
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_ref text := nullif(left(btrim(coalesce(p ->> 'reference', '')), 120), '');
  v_note text := nullif(left(btrim(coalesce(p ->> 'note', '')), 500), '');
  v_on date := coalesce(nullif(p ->> 'received_on', '')::date, app.today());
  v_refuse text;
  v_pay uuid;
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null or (app.rolling_on(b.id)).booking_id is null or b.status not in ('confirmed', 'on_rent') then return null; end if;
  if coalesce(app.booking_part_open(b.id, 'rental'), 0) > 0 then return null; end if;
  if v_method is null or v_method not in ('cash', 'e_transfer', 'cheque', 'bank_transfer', 'other') then
    raise exception 'Choose how the week was paid: e-Transfer, cash, cheque, bank transfer or another way. A card is paid through the renter''s pay link or Collect a card' using errcode = '22023';
  end if;
  select * into o from app.rolling_offer(b.id);
  if (o.e).id is null then raise exception 'The next week could not be added: %. Change the booking, or set the end date with End rental on', o.problem using errcode = '23514'; end if;
  v_total := (o.e).total_cents;
  v_amount := coalesce(v_amount, v_total);
  if v_amount <> v_total then
    raise exception 'The next week (to %) is %: record that amount. For another amount, change the booking first', app.fmt_at((o.e).new_return_at), app.fmt_money(v_total) using errcode = '22023';
  end if;
  v_refuse := app.booking_payment_allowed(p_by, v_amount);
  if v_refuse is not null then raise exception '%', v_refuse using errcode = '42501'; end if;
  if v_method in ('e_transfer', 'cheque', 'bank_transfer') and (v_ref is null or length(v_ref) < 3) then
    raise exception '%', case v_method when 'cheque' then 'Enter the cheque number' when 'e_transfer' then 'Enter the e-Transfer reference number' else 'Enter the reference of the bank transfer' end using errcode = '22023';
  end if;
  if v_method = 'other' and v_note is null then raise exception 'Say how it was paid in the note' using errcode = '22023'; end if;
  if v_on > app.today() then raise exception 'The date received cannot be in the future' using errcode = '22023'; end if;
  update booking_extensions set total_cents = 0 where id = (o.e).id;
  v := app.confirm_extension_payment((o.e).id, '{}'::jsonb, 0, now(), p_by);
  if not coalesce((v ->> 'ok')::boolean, false) then
    raise exception 'The next week could not be added: %', coalesce(v ->> 'message', v ->> 'reason') using errcode = '23514';
  end if;
  insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_by)
  values (b.id, b.renter_id, 'extension', 'charge', v_method, v_amount, 'succeeded', app.local_midnight(v_on) + interval '12 hours', p_by)
  returning id into v_pay;
  insert into payment_processor_details (payment_id, processor, processor_payment_id, raw)
  values (v_pay, 'offline', v_method || ':' || coalesce(v_ref, v_pay::text), jsonb_strip_nulls(jsonb_build_object('reference', v_ref, 'received_on', v_on, 'note', v_note, 'recorded_by', p_by, 'covers', 'rolling_week')));
  update booking_extensions set total_cents = v_total, payment_id = v_pay, paid_at = now() where id = (o.e).id;
  update booking_line_items set payment_id = v_pay where extension_id = (o.e).id and payment_id is null;
  update app_events set payload = payload || jsonb_build_object('total_cents', v_total, 'payment_id', v_pay)
   where dedupe_key = 'renter_extension_confirmed:' || (o.e).id || ':confirmed' and processed_at is null;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
    format('%s received by %s for the next week, to %s%s', app.fmt_money(v_amount), app.payment_method_label(v_method), app.fmt_at((o.e).new_return_at), coalesce(' (' || v_ref || ')', '')), p_by, 'staff',
    jsonb_build_object('payment_id', v_pay, 'covers', 'rolling_week', 'method', v_method, 'amount_cents', v_amount, 'extension_id', (o.e).id));
  perform app.ntf_emit('renter_payment_receipt', 'payment', v_pay, 'succeeded', jsonb_build_object('booking_id', b.id, 'renter_id', b.renter_id));
  return jsonb_build_object('ok', true, 'payment_id', v_pay, 'rolling', true, 'extension_id', (o.e).id, 'return_at', (o.e).new_return_at, 'week_cents', v_total, 'open_cents', 0);
end $$;

-- a rolling week confirmed (by a recorded payment or the renter's link): the reminder's To do closes, the link stops
create function app.rolling_follow_extension() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.rolling and new.status = 'confirmed' and old.status is distinct from 'confirmed' then
    update rolling_rentals set link_due = false where booking_id = new.booking_id;
    perform app.resolve_tasks(array['rolling_week_due'], new.booking_id, null, 'The next week is paid');
    update payment_requests set status = 'cancelled', last_error = coalesce(last_error, 'The week was paid another way')
     where extension_id = new.id and status = 'open' and payment_id is null
       and not exists (select 1 from payments p where p.id = new.payment_id and p.purpose = 'extension');
    perform app.log_booking_event(new.booking_id, 'adjusted', null, null, null,
      format('Long-term rental: paid for the week, the return is now %s', app.fmt_at(new.new_return_at)), new.confirmed_by,
      case when new.confirmed_by is null then 'system' else 'staff' end, jsonb_build_object('rolling', true, 'extension_id', new.id, 'return_at', new.new_return_at));
  end if;
  return null;
end $$;
create trigger booking_extensions_rolling after update of status on booking_extensions for each row execute function app.rolling_follow_extension();

-- ================================================================ 3. on, off and the notice
create function app.rolling_may(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'finance', 'fleet')
$$;

create function app.rolling_state(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'on', r.booking_id is not null, 'since', r.started_at, 'by_name', (select u.full_name from users u where u.id = r.started_by),
    'end_at', r.end_at, 'return_at', b.return_at, 'next_return_at', app.rolling_next_return(b, r),
    'lead_hours', coalesce((app.settings()).rolling_weekly_lead_hours, 48), 'reminded_for', r.reminded_for,
    'may_turn_on', b.status in ('confirmed', 'on_rent') and b.booking_type <> 'owner',
    'next', (select jsonb_build_object('total_cents', x.total_cents, 'new_return_at', x.new_return_at, 'link_sent', exists (select 1 from payment_requests q where q.extension_id = x.id and q.status = 'open' and (q.texted_at is not null or q.emailed_at is not null)))
               from booking_extensions x where x.booking_id = b.id and x.rolling and x.status = 'approved' order by x.seq desc limit 1),
    'weeks_paid', (select count(*) from booking_extensions x where x.booking_id = b.id and x.rolling and x.status = 'confirmed'))
    from bookings b left join rolling_rentals r on r.booking_id = b.id and r.stopped_at is null
   where b.id = p_booking
$$;

-- p: {booking, on}. On: from the current return the car stays out until the notice.
create function app.rolling_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  r rolling_rentals;
  v_on boolean := coalesce((p ->> 'on')::boolean, (p ->> 'rolling_weekly')::boolean);
  v_clash record;
begin
  if not app.rolling_may(p_by) then raise exception 'Admins, customer service, finance and fleet only' using errcode = '42501'; end if;
  if v_on is null then raise exception 'Say whether the booking is a long-term rental paid weekly (on: true or false)' using errcode = '22023'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  r := app.rolling_on(b.id);
  if v_on and r.booking_id is not null then return jsonb_build_object('ok', true, 'changed', false, 'state', app.rolling_state(b.id)); end if;
  if not v_on and r.booking_id is null then return jsonb_build_object('ok', true, 'changed', false, 'state', app.rolling_state(b.id)); end if;
  if v_on then
    if b.status not in ('confirmed', 'on_rent') or b.booking_type = 'owner' then
      raise exception 'Booking % is %: a booking becomes long-term weekly once it is confirmed or the car is out', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
    end if;
    -- the car must be free after the return: the next booking or block on it is named
    select x.what, x.at into v_clash from (
      select 'booking ' || o.booking_number as what, o.pickup_at as at from bookings o
       where o.vehicle_id = b.vehicle_id and o.id <> b.id and o.blocks_calendar and o.status in ('confirmed', 'on_rent', 'pending_payment') and o.pickup_at >= b.return_at
      union all
      select 'a calendar block (' || c.reason || ')', c.starts_at from vehicle_calendar_blocks c
       where c.vehicle_id = b.vehicle_id and c.removed_at is null and c.booking_id is distinct from b.id and (c.ends_at is null or c.ends_at > b.return_at)) x
     order by x.at limit 1;
    if v_clash.what is not null then
      raise exception 'The car has % from %: move it first, or set the end date with End rental on', v_clash.what, app.fmt_at(v_clash.at) using errcode = '23514';
    end if;
    insert into rolling_rentals (booking_id, started_by) values (b.id, p_by)
    on conflict (booking_id) do update set started_at = now(), started_by = excluded.started_by, end_at = null, end_set_by = null, end_set_at = null,
       reminded_for = null, link_due = false, stopped_at = null, stopped_by = null;
  else
    update rolling_rentals set stopped_at = now(), stopped_by = p_by, link_due = false where booking_id = b.id;
    update booking_extensions set status = 'lapsed' where booking_id = b.id and rolling and status = 'approved';
    perform app.resolve_tasks(array['rolling_week_due'], b.id, null, 'No longer a long-term weekly rental');
  end if;
  perform app.rolling_sync_block(b.id);
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    case when v_on then 'Long-term rental, paid weekly: on. The car stays out until the renter gives notice.' else 'Long-term rental, paid weekly: off.' end,
    p_by, 'staff', jsonb_build_object('rolling_weekly', v_on));
  return jsonb_build_object('ok', true, 'changed', true, 'state', app.rolling_state(b.id));
end $$;

-- p: {booking, end_on (a date, Toronto) | end_at; empty: no notice}. The last day keeps the return's time of day.
create function app.rolling_end(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  r rolling_rentals;
  v_end timestamptz;
  v_on text := nullif(btrim(coalesce(p ->> 'end_on', p ->> 'rolling_end_on', '')), '');
begin
  if not app.rolling_may(p_by) then raise exception 'Admins, customer service, finance and fleet only' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  r := app.rolling_on(b.id);
  if r.booking_id is null then raise exception 'Booking % is not a long-term weekly rental', b.booking_number using errcode = '23514'; end if;
  if nullif(p ->> 'end_at', '') is not null then v_end := (p ->> 'end_at')::timestamptz;
  elsif v_on is not null then
    begin
      v_end := (v_on::date + ((b.return_at at time zone 'America/Toronto')::time)) at time zone 'America/Toronto';
    exception when others then raise exception 'Enter the last day as a date (YYYY-MM-DD)' using errcode = '22023';
    end;
  end if;
  if v_end is not null and v_end < b.return_at then
    raise exception 'The rental is paid to %: the last day is that day or later', app.fmt_at(b.return_at) using errcode = '22023';
  end if;
  update rolling_rentals set end_at = v_end, end_set_by = p_by, end_set_at = now(),
         reminded_for = case when end_at is distinct from v_end then null else reminded_for end where booking_id = b.id;
  -- an open week priced to the old end is made again at the next reminder
  update booking_extensions set status = 'lapsed' where booking_id = b.id and rolling and status = 'approved' and new_return_at is distinct from
    least(b.return_at + interval '7 days', coalesce(v_end, 'infinity'::timestamptz));
  perform app.rolling_sync_block(b.id);
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    case when v_end is null then 'Long-term rental: no end date, the car stays out until the renter gives notice.'
         else format('Long-term rental: the renter gave notice, the rental ends %s.', app.fmt_at(v_end)) end,
    p_by, 'staff', jsonb_build_object('rolling_end_at', v_end));
  return jsonb_build_object('ok', true, 'end_at', v_end, 'state', app.rolling_state(b.id));
end $$;

-- ================================================================ 4. the reminder and the link
create function app.rolling_reminders_due() returns setof bookings
language sql stable security definer set search_path = public, app as $$
  select b.* from rolling_rentals r join bookings b on b.id = r.booking_id
   where r.stopped_at is null and b.status in ('confirmed', 'on_rent')
     and app.rolling_next_return(b, r) is not null
     and b.return_at - make_interval(hours => coalesce((app.settings()).rolling_weekly_lead_hours, 48)) <= now()
     and r.reminded_for is distinct from b.return_at
$$;

-- the To do and the link of the next week, once per return
create function app.rolling_sweep() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  o record;
  n integer := 0;
begin
  for b in select * from app.rolling_reminders_due() limit 50 loop
    begin
      select * into o from app.rolling_offer(b.id);
      perform app.raise_task(p_type => 'rolling_week_due', p_title => 'Next week not paid: ' || b.booking_number,
        p_detail => case when (o.e).id is not null
          then format('Long-term rental paid weekly. It returns %s and the next week (%s, to %s) is not paid. The renter gets the pay link. Collect it, or set the end date with End rental on.',
                      app.fmt_at(b.return_at), app.fmt_money((o.e).total_cents), app.fmt_at((o.e).new_return_at))
          else format('Long-term rental paid weekly. It returns %s and the next week could not be priced (%s). Change the booking, or set the end date with End rental on.', app.fmt_at(b.return_at), o.problem) end,
        p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_related_table => 'bookings', p_related_id => b.id,
        p_priority => 'high', p_dedupe => 'rolling_week_due:' || b.id || ':' || extract(epoch from b.return_at)::bigint, p_queue => 'admin');
      update rolling_rentals set reminded_for = b.return_at, link_due = (o.e).id is not null and (o.e).total_cents > 0 where booking_id = b.id;
      n := n + 1;
    exception when others then
      raise warning 'rolling sweep %: %', b.booking_number, sqlerrm;
    end;
  end loop;
  return n;
end $$;

create function public.server_rolling_links_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.rolling_sweep();
  return coalesce((select jsonb_agg(jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number))
                     from rolling_rentals r join bookings b on b.id = r.booking_id
                    where r.stopped_at is null and r.link_due and b.status in ('confirmed', 'on_rent')), '[]'::jsonb);
end $$;

create function app.rolling_job_due() returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from app.rolling_reminders_due())
      or exists (select 1 from rolling_rentals r where r.stopped_at is null and r.link_due)
$$;

-- the next week's pay link: the open rolling week of the booking, paid like an extension (server_payreq_settle confirms it)
create function public.server_rolling_payreq(p_booking uuid, p_token_sha256 text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  e booking_extensions;
  v_id uuid;
begin
  select * into b from bookings where id = p_booking;
  select * into e from booking_extensions x where x.booking_id = p_booking and x.rolling and x.status = 'approved' and x.previous_return_at = b.return_at order by x.seq desc limit 1;
  if b.id is null or e.id is null or (app.rolling_on(b.id)).booking_id is null or coalesce(e.total_cents, 0) <= 0 then
    update rolling_rentals set link_due = false where booking_id = p_booking;
    return jsonb_build_object('ok', false, 'reason', 'not needed');
  end if;
  if p_token_sha256 is null or p_token_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'The link token is missing' using errcode = '22023'; end if;
  update payment_requests set status = 'cancelled', last_error = coalesce(last_error, 'Replaced by a new link') where extension_id = e.id and status = 'open';
  insert into payment_requests (booking_id, renter_id, kind, covers, extension_id, amount_cents, reason, token_sha256, channel, expires_at, created_by, auto)
  values (b.id, b.renter_id, 'charge', 'extension', e.id, e.total_cents, 'the next week of your rental, to ' || app.fmt_date(e.new_return_at) || ' ' || app.fmt_time(e.new_return_at),
          p_token_sha256, 'text', e.new_return_at, null, true)
  returning id into v_id;
  update rolling_rentals set link_due = false where booking_id = b.id;
  return jsonb_build_object('ok', true, 'id', v_id, 'booking_id', b.id, 'booking_number', b.booking_number, 'amount_cents', e.total_cents,
    'renter', (select jsonb_build_object('id', r.id, 'legal_name', r.legal_name, 'email', coalesce(r.email, u.email),
                 'customer_id', (select sc.processor_customer_id from payment_methods pm join payment_method_secrets sc on sc.payment_method_id = pm.id
                                  where pm.renter_id = r.id and sc.processor_customer_id is not null order by pm.created_at desc limit 1))
                 from renters r left join users u on u.id = r.user_id where r.id = b.renter_id));
end $$;

-- the link by text (urgent: it pays the next week), else by email
create function public.server_rolling_link_send(p_id uuid, p_link text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q payment_requests;
  b bookings;
  e booking_extensions;
  rn renters;
  o phone_outbox;
  v_to text;
  v_email text;
  v_why text;
begin
  select * into q from payment_requests where id = p_id for update;
  select * into e from booking_extensions where id = q.extension_id;
  if q.id is null or e.id is null or not e.rolling then raise exception 'Not a long-term rental''s weekly link' using errcode = '22023'; end if;
  if q.status <> 'open' then raise exception 'That link is not open' using errcode = '23514'; end if;
  if p_link is null or p_link !~ '^https?://[^ ]+/pay/[A-Za-z0-9_-]{20,}$'
     or encode(sha256(convert_to(regexp_replace(p_link, '^.*/pay/', ''), 'UTF8')), 'hex') <> q.token_sha256 then
    raise exception 'That link is not this request''s' using errcode = '22023';
  end if;
  if q.texted_at is not null or q.emailed_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;
  select * into b from bookings where id = q.booking_id;
  select * into rn from renters where id = b.renter_id;
  v_to := app.phone_e164(rn.mobile);
  if v_to is not null then
    o := app.phone_outbox_put(v_to, format('CarmaCars: booking %s. Your next week (to %s) is %s. Pay it with this secure link to keep the car: %s',
                                           b.booking_number, app.fmt_date(e.new_return_at), app.fmt_money(q.amount_cents), p_link),
                              'booking', b.id, rn.id, 'rolling_week_link', null, 'rolling_week_link:' || q.id, now());
    if o.id is not null then update phone_outbox set urgent = true where id = o.id; end if;
    if o.id is not null and o.status <> 'skipped' then
      update payment_requests set texted_at = now(), text_id = o.id where id = q.id;
      return jsonb_build_object('ok', true, 'to', app.phone_display(o.to_number));
    end if;
    v_why := coalesce(o.status_reason, 'the text was not sent');
  else
    v_why := 'no mobile number on file';
  end if;
  v_email := coalesce(rn.email, (select u.email from users u where u.id = rn.user_id));
  if v_email is not null then
    perform app.staff_send_message(null, b.id, 'Your next week for booking ' || b.booking_number,
      format('Hi %s, your next week of the rental (to %s) is %s. Please pay it with this secure link to keep the car: %s. The card is entered in Stripe''s own form; CarmaCars never sees the card number.',
             coalesce(nullif(split_part(btrim(rn.legal_name), ' ', 1), ''), 'there'), app.fmt_at(e.new_return_at), app.fmt_money(q.amount_cents), p_link));
    update payment_requests set emailed_at = now(), last_error = left('Not texted (' || v_why || '): sent by email', 300) where id = q.id;
    return jsonb_build_object('ok', true, 'by', 'email', 'to', v_email);
  end if;
  update payment_requests set last_error = left(initcap(left(v_why, 1)) || substr(v_why, 2), 300) where id = q.id;
  return jsonb_build_object('ok', false, 'reason', v_why);
end $$;

-- the deposit job (it sends pay links already) runs while a reminder or a link is due
alter function app.server_jobs_due() rename to server_jobs_due_pre2981;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := app.server_jobs_due_pre2981();
begin
  if coalesce((v ->> 'deposits')::boolean, false) then return v; end if;
  return v || jsonb_build_object('deposits', coalesce(app.rolling_job_due(), false));
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre2981()'::regprocedure);

-- ================================================================ 5. the door
-- ops_do / admin_do / va_do: rolling_weekly_set {booking, on}, rolling_weekly_end {booking, end_on}; booking_staff_edit
-- (the connector's change_booking) with changes.rolling_weekly and changes.rolling_end_on; record_booking_payment of the
-- rental on a long-term weekly booking adds the week first. ops_read: rolling_weekly_state {booking}.
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2981;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
  v_b uuid;
  v_out jsonb;
  v_ch jsonb;
begin
  if p_call in ('ops_do', 'admin_do', 'va_do', 'ops_read') and p_name in ('rolling_weekly_set', 'rolling_weekly_end', 'rolling_weekly_state', 'booking_staff_edit', 'record_booking_payment') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    if p_name = 'rolling_weekly_state' and p_call = 'ops_read' then
      perform app.door_begin(p_user, p_aal);
      if not (app.user_is_staff(p_user) or app.user_is_admin(p_user)) then raise exception 'Staff only' using errcode = '42501'; end if;
      select id into v_b from bookings where id::text = p_ ->> 'booking' or booking_number = upper(btrim(coalesce(p_ ->> 'booking', '')));
      return app.rolling_state(v_b) || jsonb_build_object('may_change', app.rolling_may(p_user));
    elsif p_call <> 'ops_read' and p_name = 'rolling_weekly_set' then
      perform app.door_begin(p_user, p_aal);
      return app.rolling_set(p_user, p_);
    elsif p_call <> 'ops_read' and p_name = 'rolling_weekly_end' then
      perform app.door_begin(p_user, p_aal);
      return app.rolling_end(p_user, p_);
    elsif p_call <> 'ops_read' and p_name = 'booking_staff_edit' and jsonb_typeof(p_ -> 'changes') = 'object'
          and (p_ -> 'changes' ? 'rolling_weekly' or p_ -> 'changes' ? 'rolling_end_on') then
      perform app.door_begin(p_user, p_aal);
      v_out := '{}'::jsonb;
      if p_ -> 'changes' ? 'rolling_weekly' then
        v_out := v_out || jsonb_build_object('rolling_weekly', app.rolling_set(p_user, jsonb_build_object('booking', p_ ->> 'booking', 'on', p_ -> 'changes' -> 'rolling_weekly')));
      end if;
      if p_ -> 'changes' ? 'rolling_end_on' then
        v_out := v_out || jsonb_build_object('rolling_end', app.rolling_end(p_user, jsonb_build_object('booking', p_ ->> 'booking', 'end_on', p_ -> 'changes' ->> 'rolling_end_on')));
      end if;
      v_ch := (p_ -> 'changes') - 'rolling_weekly' - 'rolling_end_on';
      if v_ch = '{}'::jsonb and coalesce(jsonb_array_length(case when jsonb_typeof(p_ -> 'lines') = 'array' then p_ -> 'lines' end), 0) = 0 then
        return jsonb_build_object('ok', true) || v_out;
      end if;
      return app.door_pre2981(p_user, p_aal, p_call, p_name, jsonb_set(p, '{changes}', v_ch)) || v_out;
    elsif p_call <> 'ops_read' and p_name = 'record_booking_payment' and coalesce(nullif(p_ ->> 'covers', ''), 'rental') in ('rental', 'both') then
      select id into v_b from bookings where id::text = p_ ->> 'booking' or booking_number = upper(btrim(coalesce(p_ ->> 'booking', '')));
      if v_b is not null and (app.rolling_on(v_b)).booking_id is not null then
        perform app.door_begin(p_user, p_aal);
        v_out := app.rolling_record_week(p_user, p_);
        if v_out is not null then return v_out; end if;
      end if;
    end if;
  end if;
  return app.door_pre2981(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2981(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 6. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['rolling_on', 'rolling_next_return', 'rolling_sync_block', 'rolling_follow_booking', 'rolling_offer', 'rolling_record_week',
             'rolling_follow_extension', 'rolling_may', 'rolling_state', 'rolling_set', 'rolling_end', 'rolling_reminders_due', 'rolling_sweep', 'rolling_job_due',
             'door_pre2981', 'server_jobs_due_pre2981']))
        or (n.nspname = 'public' and p.proname = any (array['server_rolling_links_due', 'server_rolling_payreq', 'server_rolling_link_send']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
