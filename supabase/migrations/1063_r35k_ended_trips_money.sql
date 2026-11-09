-- 1063_r35k_ended_trips_money.sql
-- Release 35, part K (docs/changes/2026-11-08-r35-close-ended-trips.md).
--   1. Close ended trips (Admin > Bookings, and the Fleet and Finance staff portals): every booking past its return time that
--      is not closed: never picked up in the system, on rent after its return, or returned and never closed. Each row (or
--      several, ticked) is marked returned on time, returned late at a time, or a no-show, with the record-past-trip logic
--      (0770, 0910's past_trip_close); and a deposit decision: release in full, deduct the balance owed, or deduct the late
--      fee. Nothing is released or refunded by itself: the decision waits on the same page (and as an Admin To do) for an
--      Admin to press Release, which settles the deposit through the usual settlement (0155). A card hold that has expired
--      is marked settled ("released by expiry") at once: no money moves.
--   2. Record a past trip (coordinator, item 2): "Admin: deposit not taken, waive it because" in the same dialog, as the
--      pickup forms have; Close ended trips takes the same field. 0019's rule stands: no car goes without the deposit or an
--      Admin's waiver, a booking offered with none included.
--   3. Hold expired (item 3): a card hold past its expiry is marked settled, released by expiry, in one click on the booking
--      (Admin, Finance, Fleet), and by Close ended trips for returned trips.
--   4. Return lines (item 4): an Admin changes the amount of, or waives, a renter line not on a statement yet (the late
--      return lines included), with a reason; audited and in the booking history; the next assessment keeps it.
--      The late return: whole days late are extra days at the daily rate; only the started hours after them get the hourly
--      late fee (capped per day as before); the grace period applies to that remainder. A return 1 day 1 hour late is 1 extra
--      day and 1 hour, never 2 days and the hourly fee on top.
--   5. Careers (item 5): an application sent to a closed role says so with the Sales role to apply for instead.
-- No applied migration is edited: functions are replaced or wrapped; 0020's set_assessed_line patched.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '1063: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;
create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 4. the late return, and Admin changes to return lines
create or replace function public.calc_late_return(
  p_minutes_late integer, p_booking_daily_rate_cents bigint,
  p_fee_per_hour_cents bigint default 2500, p_cap_multiplier_bps integer default 15000,
  p_grace_minutes integer default 30)
returns table (extra_days integer, extra_days_cents bigint, late_fee_cents bigint)
language plpgsql immutable as $$
declare
  v_cap bigint := public.calc_bps(p_booking_daily_rate_cents, p_cap_multiplier_bps);
  v_days integer;
  v_rest integer;
begin
  if p_minutes_late is null or p_minutes_late <= p_grace_minutes then
    return query select 0, 0::bigint, 0::bigint;
    return;
  end if;
  -- 1063: whole days are extra days; the started hours after them get the hourly fee (never both for the same time)
  v_days := floor(p_minutes_late / 1440.0)::integer;
  v_rest := p_minutes_late - v_days * 1440;
  return query select v_days, v_days * p_booking_daily_rate_cents,
    case when v_rest <= p_grace_minutes then 0::bigint else least(ceil(v_rest / 60.0)::bigint * p_fee_per_hour_cents, v_cap) end;
end $$;

-- 1063 (the owner's rule, item 11): a started extra day costs the booking's full effective daily cost: the rental charge per
-- day after its discounts, plus every per-day and per-trip fee (Protection Plan, young driver, a typed price) per day; never
-- one-time fees (delivery, pickup, an add-on item). HST on top, as on every line.
create function app.booking_daily_cost_cents(p_booking uuid) returns bigint
language sql stable security definer set search_path = public, app as $$
  select coalesce(round(sum(l.amount_cents)::numeric / greatest(1, coalesce(max(b.billable_days), ceil(extract(epoch from (max(b.return_at) - max(b.pickup_at))) / 86400.0)::int, 1)))::bigint,
                  max(b.daily_rate_cents))
    from bookings b
    join booking_line_items l on l.booking_id = b.id and l.voided_at is null and l.charged_to_renter and l.extension_id is null
    join fee_types f on f.code = l.charge_type and f.stage = 'booking'
   where b.id = p_booking and l.charge_type not in ('delivery', 'pickup', 'addon') and f.per_what <> 'item'
$$;

-- every caller of the late return (the check-in, Record now, the time correction, the extension preview) uses that cost
do $$
declare
  f record;
  d text;
begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.prosrc like '%calc_late_return(%' loop
    d := pg_get_functiondef(f.sig);
    d := regexp_replace(d, '(calc_late_return\([^,]+,\s*)b\.daily_rate_cents', '\1app.booking_daily_cost_cents(b.id)', 'g');
    d := replace(d, 'calc_late_return(coalesce(b.minutes_late, 0), b.daily_rate_cents', 'calc_late_return(coalesce(b.minutes_late, 0), app.booking_daily_cost_cents(b.id)');
    d := replace(d, '''late_return_extra_days'', ''late_return_extra_days'', l.extra_days, b.daily_rate_cents,', '''late_return_extra_days'', ''late_return_extra_days'', l.extra_days, app.booking_daily_cost_cents(b.id),');
    d := replace(d, 'extra day(s) at the daily rate', 'extra day(s) at the booking''''s daily cost');
    -- a return late by hours only (no whole day) is still a late return
    d := replace(d, 'when l.extra_days > 0 then ''late_return''', 'when l.extra_days > 0 or l.late_fee_cents > 0 then ''late_return''');
    execute d;
  end loop;
end $$;

-- the next assessment keeps an Admin's change or waiver
select pg_temp.patch_fn('app.set_assessed_line(uuid, text, text, numeric, bigint, bigint, text, jsonb, uuid, uuid, uuid)'::regprocedure,
  'if li.id is not null and li.statement_id is not null then return li.id; end if;',
  'if li.id is not null and li.statement_id is not null then return li.id; end if;
  -- 1063: an Admin changed it (override_by) or waived it: the Admin''s decision stands
  if li.id is not null and li.override_by is not null then return li.id; end if;
  if li.id is null and exists (select 1 from booking_line_items w where w.booking_id = p_booking and w.assessment_key = p_key and w.voided_at is not null
                                and w.void_reason like ''Waived by an Admin%'') then return null; end if;');

-- p {line, amount_cents} changes the amount; p {line, waive: true} waives it; reason always
create function app.line_adjust(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  li booking_line_items;
  b bookings;
  v_reason text := btrim(coalesce(p ->> 'reason', ''));
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_waive boolean := coalesce((p ->> 'waive')::boolean, false);
  v_note text;
begin
  perform app.assert_admin(p_by);
  if length(v_reason) < 5 then raise exception 'Give the reason (at least 5 characters): it is in the booking history' using errcode = '22023'; end if;
  select * into li from booking_line_items where id = nullif(p ->> 'line', '')::uuid for update;
  if li.id is null or li.voided_at is not null then raise exception 'Line not found' using errcode = 'P0002'; end if;
  if li.statement_id is not null then raise exception 'This line is on an issued statement: credit it on a new statement instead' using errcode = '23514'; end if;
  if li.payment_id is not null then raise exception 'This line is paid: refund it instead' using errcode = '23514'; end if;
  if not li.charged_to_renter then raise exception 'Only a renter charge is changed here' using errcode = '23514'; end if;
  select * into b from bookings where id = li.booking_id;
  if v_waive then
    update booking_line_items set voided_at = now(), voided_by = p_by, void_reason = left('Waived by an Admin: ' || v_reason, 300) where id = li.id;
    v_note := format('%s waived (was %s): %s', li.description, app.fmt_money(li.amount_cents), v_reason);
  else
    if v_amount is null or v_amount < 0 then raise exception 'Enter the new amount' using errcode = '22023'; end if;
    if v_amount >= li.amount_cents then raise exception 'The new amount is lower than %: a higher charge is added as its own line', app.fmt_money(li.amount_cents) using errcode = '22023'; end if;
    if v_amount = 0 then
      update booking_line_items set voided_at = now(), voided_by = p_by, void_reason = left('Waived by an Admin: ' || v_reason, 300) where id = li.id;
    else
      update booking_line_items set amount_cents = v_amount, unit_amount_cents = case when coalesce(quantity, 0) > 0 then round(v_amount / quantity) else v_amount end,
             hst_cents = case when hst_applies then public.calc_hst(v_amount, b.hst_bps) else 0 end, override_by = p_by, override_reason = left(v_reason, 300)
       where id = li.id;
    end if;
    v_note := format('%s changed from %s to %s: %s', li.description, app.fmt_money(li.amount_cents), app.fmt_money(v_amount), v_reason);
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, case when v_waive then 'line_waived' else 'line_amount_changed' end, 'booking_line_items', li.id::text,
          jsonb_build_object('amount_cents', li.amount_cents), jsonb_build_object('amount_cents', case when v_waive then 0 else v_amount end, 'reason', v_reason));
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null, left(v_note, 600), p_by, 'staff', jsonb_build_object('line_id', li.id));
  return jsonb_build_object('ok', true, 'line', li.id);
end $$;

-- ================================================================ 2. the deposit waiver on a past trip
-- an Admin waives the deposit not taken (the pickup forms' rule, 0195), with the reason
create function app.k_waive_deposit(p_by uuid, p_booking uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, app as $$
declare v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if v_reason is null then return; end if;
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin waives the deposit' using errcode = '42501'; end if;
  if length(v_reason) < 5 then raise exception 'Say why the deposit is waived (at least 5 characters)' using errcode = '22023'; end if;
  if exists (select 1 from deposits d where d.booking_id = p_booking and d.status in ('held', 'captured', 'settled')) then return; end if;
  update bookings set deposit_waived_at = now(), deposit_waived_by = p_by, deposit_waived_reason = left(v_reason, 300),
         deposit_waived_cents = deposit_cents where id = p_booking and deposit_waived_at is null;
  perform app.log_booking_event(p_booking, 'adjusted', null, null, null, 'Deposit waived by an Admin: ' || v_reason, p_by, 'staff', jsonb_build_object('deposit_waived', true));
end $$;

alter function app.handover_override(uuid, jsonb) rename to handover_override_pre1063;
create function app.handover_override(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid;
begin
  if nullif(btrim(coalesce(p ->> 'deposit_waiver_reason', '')), '') is not null then
    select id into v_id from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
    if v_id is not null then perform app.k_waive_deposit(p_by, v_id, p ->> 'deposit_waiver_reason'); end if;
  end if;
  return app.handover_override_pre1063(p_by, p - 'deposit_waiver_reason');
end $$;
select pg_temp.copy_grants('app.handover_override(uuid, jsonb)'::regprocedure, 'app.handover_override_pre1063(uuid, jsonb)'::regprocedure);

-- ================================================================ 3. a card hold that expired: settled, released by expiry
select pg_temp.patch_fn('app.guard_deposit_release()'::regprocedure,
  'if v_delta > 0 then',
  'if v_delta > 0 and coalesce(current_setting(''app.deposit_expiry'', true), '''') = new.id::text then
    new.released_at := coalesce(new.released_at, now());
  elsif v_delta > 0 then');

create function app.deposit_hold_expired(d deposits) returns boolean
language sql stable as $$ select d.status = 'held' and d.method = 'card_hold' and d.hold_expires_at is not null and d.hold_expires_at <= now() $$;

create function app.deposit_expired_settle(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d deposits;
  b bookings;
  v_left bigint;
begin
  if not (app.user_runs_finance(p_by) or app.user_va_has(p_by, 'fleet')) then raise exception 'An Admin, Finance or Fleet marks it' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  select * into d from deposits where booking_id = b.id for update;
  if d.id is null or not app.deposit_hold_expired(d) then raise exception 'The deposit is not an expired card hold' using errcode = '23514'; end if;
  if b.status not in ('returned', 'closed', 'cancelled', 'no_show') then raise exception 'The trip is not over: take a new deposit instead' using errcode = '23514'; end if;
  v_left := d.amount_cents - d.applied_cents - d.held_back_cents - d.released_cents;
  perform set_config('app.deposit_expiry', d.id::text, true);
  update deposits set status = 'settled', released_cents = released_cents + greatest(v_left, 0), release_approved_by = p_by, updated_at = now() where id = d.id;
  perform set_config('app.deposit_expiry', '', true);
  insert into deposit_events (deposit_id, kind, amount_cents, note, created_by) values (d.id, 'released', greatest(v_left, 0), 'Released by expiry: the card hold ended; no money moved', p_by);
  perform app.resolve_tasks(array['approve_deposit_release', 'release_deposit', 'deposit_hold_lapsed'], b.id, p_by, 'Released by expiry');
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null, format('Deposit marked settled: released by expiry (the card hold of %s ended)', app.fmt_money(d.amount_cents)), p_by, 'staff',
    jsonb_build_object('deposit_id', d.id, 'released_by_expiry', true));
  if b.status = 'returned' and exists (select 1 from booking_statements s where s.booking_id = b.id and s.kind = 'check_in')
     and not exists (select 1 from booking_line_items l where l.booking_id = b.id and l.statement_id is not null and l.payment_id is null and l.voided_at is null and l.charged_to_renter) then
    update bookings set status = 'closed' where id = b.id;
  end if;
  return jsonb_build_object('ok', true, 'booking_id', b.id, 'released_cents', greatest(v_left, 0));
end $$;

-- ================================================================ 1. Close ended trips
create or replace function app.past_trips_allowed(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app as $$ select app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'finance') $$;

create table if not exists trip_close_decisions (
  booking_id   uuid primary key references bookings (id) on delete cascade,
  decision     text not null check (decision in ('full', 'balance', 'late_fee')),
  status       text not null default 'waiting' check (status in ('waiting', 'done', 'cancelled')),
  note         text,
  decided_by   uuid not null references users (id),
  decided_at   timestamptz not null default now(),
  done_by      uuid references users (id),
  done_at      timestamptz
);
comment on table trip_close_decisions is 'Close ended trips (1063): the deposit decision of an ended trip (release in full, deduct the balance owed, deduct the late fee), waiting for an Admin to press Release. Nothing moves by itself.';
alter table trip_close_decisions enable row level security;
revoke all on trip_close_decisions from anon, authenticated;
grant all on trip_close_decisions to service_role;
drop trigger if exists audit_trip_close_decisions on trip_close_decisions;
create trigger audit_trip_close_decisions after insert or update or delete on trip_close_decisions for each row execute function app.audit_row();
insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('trip_close_release', 'admin', 'A deposit decision waits for an Admin', 'normal', 'none', null, 'Close ended trips (1063): staff chose how the deposit of an ended trip is settled. Press Release on Close ended trips.')
on conflict (task_type) do nothing;

create function app.ended_trip_money(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'deposit_cents', coalesce(d.amount_cents, 0), 'deposit_status', d.status, 'hold_expired', coalesce(app.deposit_hold_expired(d), false),
    'deposit_waived', b.deposit_waived_at is not null, 'deposit_due', coalesce(b.deposit_cents, 0) > 0 and b.deposit_waived_at is null and d.id is null,
    'owed_cents', coalesce((select sum(l.amount_cents + l.hst_cents) from booking_line_items l where l.booking_id = b.id and l.payment_id is null and l.voided_at is null
                              and l.charged_to_renter and l.stage = 'check_in'), 0),
    'late_fee_cents', coalesce((select sum(l.amount_cents + l.hst_cents) from booking_line_items l where l.booking_id = b.id and l.voided_at is null
                              and l.charge_type in ('late_return_fee', 'late_return_extra_days')), 0),
    'statement', exists (select 1 from booking_statements s where s.booking_id = b.id and s.kind = 'check_in'))
    from bookings b left join deposits d on d.booking_id = b.id where b.id = p_booking
$$;

create function app.ended_trips_view(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.past_trips_allowed(p_by) then raise exception 'Admin, Fleet or Finance closes ended trips' using errcode = '42501'; end if;
  return jsonb_build_object('admin', app.user_is_admin(p_by), 'can_no_show', app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs'),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
      'booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at, 'return_at', b.return_at,
      'handed_over_at', b.handed_over_at, 'checked_in_at', b.checked_in_at, 'vehicle', app.vehicle_name(b.vehicle_id),
      'plate', (select v.plate from vehicles v where v.id = b.vehicle_id), 'renter', (select r.legal_name from renters r where r.id = b.renter_id),
      'hours_past', round(extract(epoch from now() - b.return_at) / 3600.0, 1), 'money', app.ended_trip_money(b.id),
      'decision', (select jsonb_build_object('decision', x.decision, 'status', x.status, 'at', x.decided_at, 'by', (select u.full_name from users u where u.id = x.decided_by))
                     from trip_close_decisions x where x.booking_id = b.id and x.status = 'waiting')) order by b.return_at)
      from bookings b
     where b.return_at < now() and not coalesce(b.is_placeholder, false)
       and (b.status::text in ('confirmed', 'on_rent') or (b.status::text = 'returned'))), '[]'::jsonb));
end $$;

-- p {booking, mark: on_time | late | no_show, return_at?, pickup_at?, deposit: full | balance | late_fee, deposit_waiver_reason?, note?}
create function app.ended_trip_close(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  d deposits;
  v_mark text := coalesce(nullif(p ->> 'mark', ''), 'on_time');
  v_dep text := nullif(p ->> 'deposit', '');
  v_res jsonb := '{}'::jsonb;
  v_expired boolean := false;
begin
  if not app.past_trips_allowed(p_by) then raise exception 'Admin, Fleet or Finance closes ended trips' using errcode = '42501'; end if;
  if v_mark not in ('on_time', 'late', 'no_show') then raise exception 'Mark it returned on time, late, or a no-show' using errcode = '22023'; end if;
  if v_dep is not null and v_dep not in ('full', 'balance', 'late_fee') then raise exception 'Choose the deposit: release in full, deduct the balance owed or deduct the late fee' using errcode = '22023'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.return_at >= now() then raise exception 'Booking % has not ended yet', b.booking_number using errcode = '23514'; end if;

  if v_mark = 'no_show' then
    if b.status::text <> 'confirmed' then raise exception 'Booking %: only a trip that never went out is a no-show', b.booking_number using errcode = '23514'; end if;
    if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs')) then raise exception 'An Admin or customer service marks a no-show' using errcode = '42501'; end if;
    v_res := app.cancel_booking(b.id, p_by, 'no_show', coalesce(nullif(btrim(coalesce(p ->> 'note', '')), ''), 'No-show, marked on Close ended trips'), 'system', greatest(b.pickup_at, least(now(), b.return_at)));
    return jsonb_build_object('booking_number', b.booking_number, 'closed', 'no_show', 'result', v_res);
  end if;

  if b.status::text in ('confirmed', 'on_rent') then
    perform app.k_waive_deposit(p_by, b.id, p ->> 'deposit_waiver_reason');
    if v_mark = 'late' and nullif(p ->> 'return_at', '') is null then raise exception 'Give the time the car came back' using errcode = '22023'; end if;
    v_res := app.past_trip_close(p_by, jsonb_strip_nulls(jsonb_build_object('booking', b.id, 'return_at', case when v_mark = 'late' then p ->> 'return_at' end,
               'pickup_at', nullif(p ->> 'pickup_at', ''), 'reason', nullif(btrim(coalesce(p ->> 'note', '')), ''))));
    select * into b from bookings where id = b.id;
  elsif b.status::text <> 'returned' then
    raise exception 'Booking % is %: nothing to close', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
  end if;

  -- the deposit: an expired card hold is settled by expiry now (nothing moves); else the decision waits for an Admin
  select * into d from deposits where booking_id = b.id;
  if d.id is not null and app.deposit_hold_expired(d) and b.status::text = 'returned' then
    perform app.deposit_expired_settle(p_by, jsonb_build_object('booking', b.id));
    v_expired := true;
  elsif v_dep is not null and d.id is not null and d.status in ('held', 'captured') then
    insert into trip_close_decisions (booking_id, decision, note, decided_by)
    values (b.id, v_dep, nullif(left(btrim(coalesce(p ->> 'note', '')), 300), ''), p_by)
    on conflict (booking_id) do update set decision = excluded.decision, status = 'waiting', note = excluded.note, decided_by = p_by, decided_at = now(), done_by = null, done_at = null;
    perform app.raise_task(p_type => 'trip_close_release', p_queue => 'admin',
      p_title => left(format('%s: release the deposit (%s)', b.booking_number, case v_dep when 'full' then 'in full' when 'balance' then 'less the balance owed' else 'less the late fee' end), 200),
      p_detail => 'Staff chose it on Close ended trips. Press Release there: the deposit is settled and the rest goes back to the renter.',
      p_booking => b.id, p_dedupe => 'trip_close_release:' || b.id);
  end if;
  return jsonb_build_object('booking_number', b.booking_number, 'closed', b.status, 'released_by_expiry', v_expired, 'decision', v_dep, 'result', v_res);
end $$;

-- p {bookings: [...], mark, deposit, deposit_waiver_reason?}: each one, the problems listed
create function app.ended_trips_close_many(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id text;
  n integer := 0;
  v_failed jsonb := '[]'::jsonb;
begin
  if not app.past_trips_allowed(p_by) then raise exception 'Admin, Fleet or Finance closes ended trips' using errcode = '42501'; end if;
  if jsonb_typeof(p -> 'bookings') is distinct from 'array' or jsonb_array_length(p -> 'bookings') = 0 then raise exception 'Tick the trips to close' using errcode = '22023'; end if;
  if jsonb_array_length(p -> 'bookings') > 100 then raise exception 'At most 100 at once' using errcode = '22023'; end if;
  for v_id in select jsonb_array_elements_text(p -> 'bookings') loop
    begin
      perform app.ended_trip_close(p_by, (p - 'bookings') || jsonb_build_object('booking', v_id));
      n := n + 1;
    exception when others then
      v_failed := v_failed || jsonb_build_object('booking', (select booking_number from bookings where id::text = v_id), 'problem', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('closed', n, 'failed', v_failed);
end $$;

-- an Admin presses Release: the deposit is settled by the usual settlement (the web layer then runs the money steps)
create function app.trip_close_release(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x trip_close_decisions;
  b bookings;
  m jsonb;
  v jsonb;
begin
  perform app.assert_admin(p_by);
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  select * into x from trip_close_decisions where booking_id = b.id and status = 'waiting' for update;
  if x.booking_id is null then raise exception 'No deposit decision waits on this booking' using errcode = 'P0002'; end if;
  m := app.ended_trip_money(b.id);
  if x.decision = 'full' and (m ->> 'owed_cents')::bigint > 0 then
    raise exception '% is still owed on this booking: choose Deduct the balance owed, or change the charges first', app.fmt_money((m ->> 'owed_cents')::bigint) using errcode = '23514';
  end if;
  if x.decision = 'late_fee' and (m ->> 'late_fee_cents')::bigint = 0 then
    raise exception 'There is no late fee on this booking: choose Release in full or Deduct the balance owed' using errcode = '23514';
  end if;
  v := app.deposit_settle_screen(p_by, jsonb_build_object('booking', b.id, 'release_now', coalesce((p ->> 'release_now')::boolean, false)));
  update trip_close_decisions set status = 'done', done_by = p_by, done_at = now() where booking_id = b.id;
  perform app.resolve_tasks(array['trip_close_release'], b.id, p_by, 'Released');
  return v;
end $$;

-- ================================================================ 5. an application to a closed role
alter function public.server_hiring_apply(jsonb, text) rename to server_hiring_apply_pre1063;
create function public.server_hiring_apply(p jsonb, p_ip text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r hiring_roles;
  s hiring_roles;
begin
  select * into r from hiring_roles where slug = p ->> 'role';
  if r.id is not null and not r.active then
    s := app.hiring_sales_for(r);
    return jsonb_build_object('ok', false, 'error', 'closed', 'sales_slug', s.slug, 'sales_title', s.title);
  end if;
  return public.server_hiring_apply_pre1063(p, p_ip);
end $$;
select pg_temp.copy_grants('public.server_hiring_apply(jsonb, text)'::regprocedure, 'public.server_hiring_apply_pre1063(jsonb, text)'::regprocedure);

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1063;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if (p_call = 'ops_read' and p_name = 'ended_trips')
     or (p_call = 'ops_do' and p_name in ('ended_trip_close', 'ended_trips_close_many', 'trip_close_release', 'deposit_expired_settle', 'line_adjust')) then
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'ended_trips' then app.ended_trips_view(p_user, p_)
      when 'ended_trip_close' then app.ended_trip_close(p_user, p_)
      when 'ended_trips_close_many' then app.ended_trips_close_many(p_user, p_)
      when 'trip_close_release' then app.trip_close_release(p_user, p_)
      when 'deposit_expired_settle' then app.deposit_expired_settle(p_user, p_)
      else app.line_adjust(p_user, p_) end;
  end if;
  return app.door_pre1063(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1063(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname = any (array['line_adjust', 'k_waive_deposit', 'handover_override_pre1063', 'deposit_hold_expired', 'deposit_expired_settle',
                     'ended_trip_money', 'ended_trips_view', 'ended_trip_close', 'ended_trips_close_many', 'trip_close_release', 'door_pre1063']))
               or (n.nspname = 'public' and p.proname = 'server_hiring_apply_pre1063')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
