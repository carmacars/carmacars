-- 2710_r42_handover_late.sql
-- Release 42 (docs/changes/2026-11-12-r42-handover.md). The owner: "The check-in and check-out process has to be made much
-- easier", and a late return must not be invoiced by itself.
--
-- A. One screen per handover. The checklist of a pickup or a return (field staff, and an Admin or an assistant from the
--    booking) is one screen on the phone. The database gives it what to prefill: app.handover_defaults (the odometer and the
--    fuel from the Tracker when it reported in the last 30 minutes, else the car's last report; the keys from the last
--    report or the pickup; "Standard" for the cleanliness of a return), added to field_read('job') as "defaults". Nothing a
--    handover requires is dropped: complete_handover and complete_return check the same things as before.
-- B. The late return is a choice, never an automatic charge. Until now the return wrote the late lines by itself
--    (app.assess_check_in: extra days and the hourly late fee). Now a car that comes back after the grace period gets a
--    row in late_return_decisions (pending) and a To do for Fleet, and the two late lines stay empty until someone chooses:
--      extension    every started day late at the booking's daily cost, as an extension would have cost
--      extra_days   the number of days staff choose (1 up to the started days) at the booking's daily cost
--      late_fee     the late return fee of the rental terms (whole days as extra days, the started hours after them at
--                   the hourly fee, capped a day): what the return charged by itself before
--      custom       an amount with its reason
--      waive        no charge, with the reason
--    The choice writes the same lines as before (late_return_extra_days, late_return_fee) through app.set_assessed_line, so
--    the statement, the deposit settlement (kept from the hold, then the card on file, then a pay link) and the owner's
--    share work as they did. It is audited (audit_log, the booking history) and the renter gets a message on the booking
--    that says what was chosen. Rules that stay: a custom amount above the person's single limit waits for an Admin; a
--    waiver is an Admin's, Finance's or Fleet's (as check_in_waive), anyone else's waits for an Admin; a line on a statement
--    or paid is not changed here.
--    The choice is made on the return screen (sent with complete_return as late_choice; never in the way of the return) or
--    on the booking (ops_do late_return_decide; ops_read late_return).
--    A return that was already charged the old way keeps its lines: it is recorded as decided (late_fee).
-- No applied migration is edited: assess_check_in is patched; complete_return, field_read and door are wrapped.
-- SCHEMA_MARKER 2711 (2711 carries the guide chapters).
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

-- ================================================================ the decision
create table late_return_decisions (
  booking_id   uuid primary key references bookings (id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'needs_admin', 'decided')),
  minutes_late integer not null default 0,
  option       text check (option in ('extension', 'extra_days', 'late_fee', 'custom', 'waive')),
  days         integer check (days is null or days between 1 and 366),
  amount_cents bigint check (amount_cents is null or amount_cents >= 0),
  reason       text,
  requested_by uuid references users (id),
  requested_at timestamptz,
  decided_by   uuid references users (id),
  decided_at   timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (status = 'pending' or option is not null)
);
comment on table late_return_decisions is 'One row per booking that came back late (2710): pending until staff choose how it is charged (extension, extra days, the late fee of the terms, a custom amount, or waived); needs_admin while a choice above the person''s limit waits for an Admin. The late lines of the booking follow the decision.';
alter table late_return_decisions enable row level security;
revoke all on late_return_decisions from public, anon, authenticated;
grant select, insert, update, delete on late_return_decisions to service_role;
create policy admin_all on late_return_decisions for select to authenticated using (app.is_admin());
create trigger audit_late_return_decisions after insert or update or delete on late_return_decisions for each row execute function app.audit_row();

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('late_return_decision', 'fleet', 'Late return: choose the charge', 'high', 'business_days', 1, 8, 'late_return_decided',
   'The car came back late. Open the booking and choose: an extension, extra days, the late return fee, a custom amount, or waive it. Nothing is charged until someone chooses.'),
  ('late_return_approval', 'admin', 'Late return: approve the charge', 'high', 'business_days', 1, 8, 'late_return_decided',
   'Staff chose a late return charge above their limit, or a waiver. Open the booking and approve it or choose another.')
on conflict (task_type) do nothing;

do $$
declare c record;
begin
  select conname, pg_get_constraintdef(oid) d into c from pg_constraint
   where conrelid = 'booking_events'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%kind = ANY%';
  if c.conname is not null and c.d not like '%late_return_decided%' then
    execute format('alter table booking_events drop constraint %I', c.conname);
    execute format('alter table booking_events add constraint %I %s', c.conname, replace(c.d, 'ARRAY[', 'ARRAY[''late_return_decided''::text, '));
  end if;
end $$;

-- "45 min", "2 h 10 min", "1 d 3 h"
create function app.late_duration(p_minutes integer) returns text
language sql immutable as $$
  select case when m < 60 then m || ' min'
              when m < 1440 then (m / 60) || ' h' || case when m % 60 > 0 then ' ' || (m % 60) || ' min' else '' end
              else (m / 1440) || ' d' || case when (m % 1440) / 60 > 0 then ' ' || ((m % 1440) / 60) || ' h' else '' end end
    from (select greatest(coalesce(p_minutes, 0), 0) m) x
$$;

-- What a late return may cost, each way, and where its decision stands. While the car is still out the lateness is
-- counted to p_at (the return screen shows what each choice would cost now); once back, from the actual return time.
create function app.late_return_options(p_booking uuid, p_by uuid default null, p_at timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  d late_return_decisions;
  t record;
  l record;
  v_min integer;
  v_grace integer;
  v_daily bigint;
  v_started integer;
  v_whole integer;
  v_admin boolean := p_by is not null and app.user_is_admin(p_by);
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or b.booking_type::text = 'owner' then return null; end if;
  v_min := case when b.checked_in_at is not null then coalesce(b.minutes_late, 0)
                when b.status::text = 'on_rent' then greatest(0, floor(extract(epoch from (p_at - b.return_at)) / 60)::integer)
                else 0 end;
  select * into t from app.booking_fee_term(p_booking, 'late_return_fee');
  v_grace := coalesce(t.grace_minutes, 0);
  v_daily := coalesce(app.booking_daily_cost_cents(b.id), b.daily_rate_cents, 0);
  select * into l from public.calc_late_return(v_min, v_daily, coalesce(t.amount_cents, 0), coalesce(t.percent_bps, 0), v_grace);
  v_started := greatest(1, ceil(v_min / 1440.0)::integer);
  v_whole := greatest(1, floor(v_min / 1440.0)::integer);
  select * into d from late_return_decisions where booking_id = p_booking;
  return jsonb_build_object(
    'booking_id', b.id, 'booking_number', b.booking_number, 'back', b.checked_in_at is not null,
    'minutes_late', v_min, 'grace_minutes', v_grace, 'late', v_min > v_grace, 'late_text', app.late_duration(v_min),
    'daily_cents', v_daily, 'hourly_cents', t.amount_cents, 'hst_bps', b.hst_bps,
    'options', jsonb_build_array(
      jsonb_build_object('key', 'extension', 'days', v_started, 'amount_cents', v_started * v_daily),
      jsonb_build_object('key', 'extra_days', 'days', v_whole, 'max_days', v_started, 'unit_cents', v_daily, 'amount_cents', v_whole * v_daily),
      jsonb_build_object('key', 'late_fee', 'amount_cents', l.extra_days_cents + l.late_fee_cents, 'extra_days', l.extra_days,
                         'extra_days_cents', l.extra_days_cents, 'late_fee_cents', l.late_fee_cents, 'set', t.amount_cents is not null and t.percent_bps is not null),
      jsonb_build_object('key', 'custom'),
      jsonb_build_object('key', 'waive')),
    'decision', case when d.booking_id is null then null else jsonb_build_object(
      'status', d.status, 'option', d.option, 'days', d.days, 'amount_cents', d.amount_cents, 'reason', d.reason,
      'requested_by', (select u.full_name from users u where u.id = d.requested_by), 'requested_at', d.requested_at,
      'decided_by', (select u.full_name from users u where u.id = d.decided_by), 'decided_at', d.decided_at,
      'charged_cents', (select coalesce(sum(li.amount_cents + li.hst_cents), 0) from booking_line_items li
                         where li.booking_id = b.id and li.voided_at is null and li.assessment_key in ('late_return_extra_days', 'late_return_fee'))) end,
    'locked', exists (select 1 from booking_line_items li where li.booking_id = b.id and li.voided_at is null
                        and li.assessment_key in ('late_return_extra_days', 'late_return_fee') and (li.statement_id is not null or li.payment_id is not null)),
    'may', jsonb_build_object(
      'decide', p_by is not null and (app.user_may_handover(p_by) or app.user_runs_finance(p_by)),
      'admin', v_admin,
      'waive', p_by is not null and (v_admin or app.user_va_has(p_by, 'finance', 'fleet')),
      'limit_cents', case when v_admin or p_by is null then null
                          else coalesce((select sp.single_limit_cents from staff_profiles sp where sp.user_id = p_by), 0) end));
end $$;

-- The two late lines of a booking, as its decision says. No decision yet, or waived: both lines are empty.
create function app.late_return_write(p_booking uuid, p_by uuid default null, p_refs jsonb default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  d late_return_decisions;
  t record;
  l record;
  v_daily bigint;
  v_refs jsonb;
  v_days numeric := 0; v_days_cents bigint := 0; v_days_text text;
  v_fee bigint := 0; v_fee_text text;
begin
  select * into b from bookings where id = p_booking;
  select * into d from late_return_decisions where booking_id = p_booking;
  v_daily := coalesce(app.booking_daily_cost_cents(b.id), b.daily_rate_cents, 0);
  v_refs := coalesce(p_refs, '{}'::jsonb) || jsonb_build_object('return_at', b.return_at, 'checked_in_at', b.checked_in_at, 'minutes_late', b.minutes_late)
            || case when d.status = 'decided' then jsonb_build_object('late_option', d.option, 'decided_by', d.decided_by, 'decided_at', d.decided_at) else '{}'::jsonb end;
  if d.status = 'decided' then
    case d.option
    when 'late_fee' then
      select * into t from app.booking_fee_term(p_booking, 'late_return_fee');
      if t.amount_cents is null or t.percent_bps is null or t.grace_minutes is null then
        raise exception 'The late return fee, its daily cap or its grace period is not set in the fee defaults' using errcode = '23514';
      end if;
      select * into l from public.calc_late_return(coalesce(b.minutes_late, 0), v_daily, t.amount_cents, t.percent_bps, t.grace_minutes);
      v_days := l.extra_days; v_days_cents := l.extra_days_cents; v_fee := l.late_fee_cents;
      v_days_text := format('Late return: %s extra day(s) at the booking''s daily cost (%s minutes late)', l.extra_days, b.minutes_late);
      v_fee_text := format('Late return fee: %s minutes late', b.minutes_late);
    when 'extension' then
      v_days := d.days; v_days_cents := d.days * v_daily;
      v_days_text := format('Late return charged as an extension: %s day(s) at the daily rate (late by %s)', d.days, app.late_duration(b.minutes_late));
    when 'extra_days' then
      v_days := d.days; v_days_cents := d.days * v_daily;
      v_days_text := format('Late return: %s extra day(s) at the daily rate (late by %s)', d.days, app.late_duration(b.minutes_late));
    when 'custom' then
      v_fee := coalesce(d.amount_cents, 0);
      v_fee_text := left(format('Late return (late by %s): %s', app.late_duration(b.minutes_late), d.reason), 300);
    else null;   -- waived
    end case;
  end if;
  perform app.set_assessed_line(p_booking, 'late_return_extra_days', 'late_return_extra_days', v_days, v_daily, v_days_cents, v_days_text, v_refs, p_by);
  perform app.set_assessed_line(p_booking, 'late_return_fee', 'late_return_fee', 1, v_fee, v_fee, v_fee_text, v_refs, p_by);
end $$;

-- The late part of the return assessment (app.assess_check_in): no charge by itself. A late return gets its pending
-- decision and a To do; a decided one gets its lines; a return that is not late (any more) has neither.
create function app.late_return_assess(p_booking uuid, p_by uuid default null, p_refs jsonb default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  d late_return_decisions;
  v_grace integer;
begin
  select * into b from bookings where id = p_booking;
  select coalesce(t.grace_minutes, 0) into v_grace from app.booking_fee_term(p_booking, 'late_return_fee') t;
  select * into d from late_return_decisions where booking_id = p_booking;
  if coalesce(b.minutes_late, 0) <= coalesce(v_grace, 0) then
    if d.booking_id is not null then
      delete from late_return_decisions where booking_id = p_booking;
      perform app.resolve_tasks(array['late_return_decision', 'late_return_approval'], p_booking, p_by, 'Not late', true);
    end if;
    perform app.late_return_write(p_booking, p_by, p_refs);
    return;
  end if;
  if d.booking_id is null then
    insert into late_return_decisions (booking_id, minutes_late) values (p_booking, b.minutes_late);
    perform app.raise_task(p_type => 'late_return_decision',
        p_title => format('Booking %s: came back late by %s, choose the charge', b.booking_number, app.late_duration(b.minutes_late)),
        p_detail => 'Nothing is charged for the late return until someone chooses: an extension, extra days, the late return fee, a custom amount, or waive it. Open the booking, Late return.',
        p_booking => p_booking, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_dedupe => 'late_return_decision:' || p_booking);
  else
    update late_return_decisions set minutes_late = b.minutes_late, updated_at = now() where booking_id = p_booking and minutes_late is distinct from b.minutes_late;
  end if;
  perform app.late_return_write(p_booking, p_by, p_refs);
end $$;

do $$
declare
  d text := pg_get_functiondef('app.assess_check_in(uuid, jsonb, uuid)'::regprocedure);
  a integer := position('select * into l from public.calc_late_return(coalesce(b.minutes_late, 0)' in d);
  z integer := position('-- ---- fuel or recharging' in d);
begin
  if a = 0 or z = 0 or z < a then raise exception '2710: the late return lines were not found in app.assess_check_in'; end if;
  execute left(d, a - 1) || '-- 2710: no late charge by itself: the pending choice, or the lines of the choice made
    perform app.late_return_assess(p_booking, p_by, v_refs);

    ' || substr(d, z);
end $$;

-- p {booking, option, days?, amount_cents?, reason?} chooses; p {booking, approve: true} is an Admin approving what waits.
create function app.late_return_decide(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  d late_return_decisions;
  o jsonb;
  x jsonb;
  v_opt text := nullif(btrim(coalesce(p ->> 'option', '')), '');
  v_days integer := nullif(p ->> 'days', '')::integer;
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_admin boolean := app.user_is_admin(p_by);
  v_needs boolean := false;
  v_limit bigint;
  v_total bigint;
  v_hst bigint;
  v_note text;
  v_body text;
  v_notice boolean := false;
  v_late text;
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = p ->> 'booking' limit 1;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  select * into b from bookings where id = b.id for update;
  if not (app.user_may_handover(p_by) or app.user_runs_finance(p_by)) then
    raise exception 'Staff who check cars in, Finance or an Admin choose the late return charge' using errcode = '42501';
  end if;
  if b.status::text not in ('returned', 'closed') then
    raise exception 'Booking % is %: the late return charge is chosen once the car is back', b.booking_number, b.status using errcode = '23514';
  end if;
  o := app.late_return_options(b.id, p_by);
  if o is null or not (o ->> 'late')::boolean then raise exception 'Booking % did not come back late', b.booking_number using errcode = '23514'; end if;
  if (o ->> 'locked')::boolean then
    raise exception 'The late return charge is already on a statement or paid: credit or refund it instead' using errcode = '23514';
  end if;
  select * into d from late_return_decisions where booking_id = b.id for update;
  if d.status = 'decided' and not v_admin then
    raise exception 'The late return is already decided: an Admin changes it' using errcode = '42501';
  end if;
  if coalesce((p ->> 'approve')::boolean, false) then
    if not v_admin then raise exception 'An Admin approves a late return charge' using errcode = '42501'; end if;
    if d.status is distinct from 'needs_admin' then raise exception 'Nothing waits for approval on this booking' using errcode = '23514'; end if;
    v_opt := d.option; v_days := d.days; v_amount := d.amount_cents; v_reason := d.reason;
  end if;
  v_late := o ->> 'late_text';
  case v_opt
  when 'extension' then
    x := o -> 'options' -> 0;
    v_days := (x ->> 'days')::integer; v_amount := (x ->> 'amount_cents')::bigint;
  when 'extra_days' then
    x := o -> 'options' -> 1;
    v_days := coalesce(v_days, (x ->> 'days')::integer);
    if v_days < 1 or v_days > (x ->> 'max_days')::integer then
      raise exception 'Choose 1 to % extra day(s): the car was late by %', x ->> 'max_days', v_late using errcode = '22023';
    end if;
    v_amount := v_days * (x ->> 'unit_cents')::bigint;
  when 'late_fee' then
    x := o -> 'options' -> 2;
    if not (x ->> 'set')::boolean then
      raise exception 'The late return fee or its daily cap is not set in the fee defaults: choose another way, or ask an Admin to set it' using errcode = '23514';
    end if;
    v_days := null; v_amount := (x ->> 'amount_cents')::bigint;
  when 'custom' then
    v_days := null;
    if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount to charge' using errcode = '22023'; end if;
    if v_reason is null or length(v_reason) < 5 then raise exception 'Say what the amount is for (at least 5 characters): the renter sees it' using errcode = '22023'; end if;
    v_limit := (o -> 'may' ->> 'limit_cents')::bigint;
    v_needs := not v_admin and v_amount > coalesce(v_limit, 0);
  when 'waive' then
    v_days := null; v_amount := 0;
    if v_reason is null or length(v_reason) < 5 then raise exception 'Say why the late return is waived (at least 5 characters)' using errcode = '22023'; end if;
    v_needs := not (o -> 'may' ->> 'waive')::boolean;
  else
    raise exception 'Choose how the late return is charged: an extension, extra days, the late return fee, a custom amount, or waive it' using errcode = '22023';
  end case;
  v_reason := left(v_reason, 500);

  if v_needs then
    insert into late_return_decisions (booking_id, status, minutes_late, option, days, amount_cents, reason, requested_by, requested_at)
    values (b.id, 'needs_admin', b.minutes_late, v_opt, v_days, v_amount, v_reason, p_by, now())
    on conflict (booking_id) do update set status = 'needs_admin', minutes_late = excluded.minutes_late, option = excluded.option, days = excluded.days,
      amount_cents = excluded.amount_cents, reason = excluded.reason, requested_by = excluded.requested_by, requested_at = excluded.requested_at,
      decided_by = null, decided_at = null, updated_at = now();
    perform app.resolve_tasks(array['late_return_decision'], b.id, p_by, 'Chosen: waits for an Admin', false);
    v_note := case v_opt when 'waive' then format('Late return (late by %s): a waiver waits for an Admin: %s', v_late, v_reason)
                         else format('Late return (late by %s): %s waits for an Admin (above the single limit): %s', v_late, app.fmt_money(v_amount), v_reason) end;
    perform app.raise_task(p_type => 'late_return_approval', p_title => format('Booking %s: approve the late return charge', b.booking_number),
        p_detail => v_note, p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_dedupe => 'late_return_approval:' || b.id, p_created_by => p_by);
    perform app.log_booking_event(b.id, 'late_return_decided', b.status::text, b.status::text, null, v_note, p_by, 'staff',
      jsonb_build_object('status', 'needs_admin', 'option', v_opt, 'amount_cents', v_amount, 'reason', v_reason));
    return jsonb_build_object('status', 'needs_admin', 'option', v_opt, 'amount_cents', v_amount);
  end if;

  insert into late_return_decisions (booking_id, status, minutes_late, option, days, amount_cents, reason, requested_by, requested_at, decided_by, decided_at)
  values (b.id, 'decided', b.minutes_late, v_opt, v_days, v_amount, v_reason, null, null, p_by, now())
  on conflict (booking_id) do update set status = 'decided', minutes_late = excluded.minutes_late, option = excluded.option, days = excluded.days,
    amount_cents = excluded.amount_cents, reason = excluded.reason, decided_by = excluded.decided_by, decided_at = excluded.decided_at, updated_at = now();
  perform app.late_return_write(b.id, p_by);
  select coalesce(sum(li.amount_cents), 0), coalesce(sum(li.hst_cents), 0) into v_total, v_hst from booking_line_items li
   where li.booking_id = b.id and li.voided_at is null and li.assessment_key in ('late_return_extra_days', 'late_return_fee');
  perform app.resolve_tasks(array['late_return_decision', 'late_return_approval'], b.id, p_by, 'Decided', false);

  v_note := format('Late return (late by %s): ', v_late) || case v_opt
    when 'extension' then format('charged as an extension, %s day(s) at the daily rate: %s', v_days, app.fmt_money(v_total))
    when 'extra_days' then format('%s extra day(s) at the daily rate: %s', v_days, app.fmt_money(v_total))
    when 'late_fee' then format('the late return fee of the rental terms: %s', app.fmt_money(v_total))
    when 'custom' then format('a custom amount of %s: %s', app.fmt_money(v_total), v_reason)
    else format('waived: %s', v_reason) end
    || case when v_hst > 0 then format(' plus %s HST', app.fmt_money(v_hst)) else '' end;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'late_return_decided', 'late_return_decisions', b.id::text,
          case when d.booking_id is null then null else to_jsonb(d) end,
          (select to_jsonb(n) from late_return_decisions n where n.booking_id = b.id) || jsonb_build_object('amount_charged_cents', v_total, 'hst_cents', v_hst));
  perform app.log_booking_event(b.id, 'late_return_decided', b.status::text, b.status::text, null, v_note, p_by, 'staff',
    jsonb_build_object('status', 'decided', 'option', v_opt, 'days', v_days, 'amount_cents', v_total, 'hst_cents', v_hst, 'reason', v_reason));

  -- the renter's notice, in the words of the choice (a message on the booking, emailed as every staff message is)
  v_body := format('Your %s came back %s after the return time of booking %s. ', app.vehicle_name(b.vehicle_id), v_late, b.booking_number) || case v_opt
    when 'extension' then format('We charged it as an extension: %s day(s) at your daily rate, %s%s.', v_days, app.fmt_money(v_total), case when v_hst > 0 then ' plus ' || app.fmt_money(v_hst) || ' HST' else '' end)
    when 'extra_days' then format('We charged %s extra day(s) at your daily rate: %s%s.', v_days, app.fmt_money(v_total), case when v_hst > 0 then ' plus ' || app.fmt_money(v_hst) || ' HST' else '' end)
    when 'late_fee' then format('The late return fee of your rental agreement applies: %s%s.', app.fmt_money(v_total), case when v_hst > 0 then ' plus ' || app.fmt_money(v_hst) || ' HST' else '' end)
    when 'custom' then format('We charged %s%s for the late return: %s.', app.fmt_money(v_total), case when v_hst > 0 then ' plus ' || app.fmt_money(v_hst) || ' HST' else '' end, rtrim(v_reason, '. '))
    else 'We have not charged anything for the late return this time.' end
    || case when v_opt = 'waive' or v_total = 0 then '' else ' It is on your statement and is taken from your deposit, or from your card on file if the deposit does not cover it.' end
    || ' Questions? Reply to this message.';
  begin
    -- a trip closed long after it ended (Close ended trips) sends the renter nothing, as its other notices (0910)
    if coalesce((p ->> 'quiet')::boolean, false) then raise exception 'quiet'; end if;
    perform app.staff_send_message(p_by, b.id, case when v_opt = 'waive' or v_total = 0 then 'Your late return: no charge' else 'Your late return charge' end, v_body);
    v_notice := true;
  exception when others then
    if sqlerrm <> 'quiet' then raise warning 'late return notice of % not sent: %', b.booking_number, sqlerrm; end if;
  end;
  return jsonb_build_object('status', 'decided', 'option', v_opt, 'days', v_days, 'amount_cents', v_total, 'hst_cents', v_hst, 'renter_told', v_notice);
end $$;

-- the return carries the choice made on the return screen; a choice that cannot be applied never stops the return
alter function app.complete_return(uuid, uuid, jsonb, uuid, timestamptz) rename to complete_return_pre2710;
create function app.complete_return(p_booking uuid, p_by uuid, p_report jsonb default '{}'::jsonb,
    p_job uuid default null, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_choice jsonb := coalesce(p_report, '{}'::jsonb) -> 'late_choice';
  v_out jsonb := app.complete_return_pre2710(p_booking, p_by, coalesce(p_report, '{}'::jsonb) - 'late_choice', p_job, p_now);
  v_late jsonb;
begin
  if v_choice is not null and jsonb_typeof(v_choice) = 'object' and nullif(v_choice ->> 'option', '') is not null
     and exists (select 1 from late_return_decisions d where d.booking_id = p_booking and d.status = 'pending') then
    begin
      v_late := app.late_return_decide(p_by, (v_choice - 'approve') || jsonb_build_object('booking', p_booking::text));
    exception when others then
      v_late := jsonb_build_object('status', 'pending', 'problem', sqlerrm);
    end;
  end if;
  return coalesce(v_out, '{}'::jsonb) || jsonb_build_object('late',
    coalesce(v_late, (select jsonb_build_object('status', d.status) from late_return_decisions d where d.booking_id = p_booking)));
end $$;
select pg_temp.copy_grants('app.complete_return(uuid, uuid, jsonb, uuid, timestamptz)'::regprocedure, 'app.complete_return_pre2710(uuid, uuid, jsonb, uuid, timestamptz)'::regprocedure);

-- Close ended trips (1063): marking a trip returned late and choosing "Deduct the late fee" is the choice of the late
-- return fee of the terms, made there by the person closing the trip; the other deposit choices leave the late return to
-- be chosen on the booking
alter function app.ended_trip_close(uuid, jsonb) rename to ended_trip_close_pre2710;
create function app.ended_trip_close(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_b uuid;
  v_late boolean := coalesce(p ->> 'mark', '') = 'late' and coalesce(p ->> 'deposit', '') = 'late_fee';
  v_out jsonb;
begin
  select b.id into v_b from bookings b where b.id::text = p ->> 'booking' or b.booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) limit 1;
  if not v_late or v_b is null then return app.ended_trip_close_pre2710(p_by, p); end if;
  -- first the trip is closed as returned late (the deposit choice is checked after the late fee is on the booking)
  v_out := app.ended_trip_close_pre2710(p_by, p - 'deposit');
  if exists (select 1 from late_return_decisions d where d.booking_id = v_b and d.status = 'pending') then
    perform app.late_return_decide(p_by, jsonb_build_object('booking', v_b::text, 'option', 'late_fee', 'quiet', true));
  end if;
  return v_out || app.ended_trip_close_pre2710(p_by, p);
end $$;
select pg_temp.copy_grants('app.ended_trip_close(uuid, jsonb)'::regprocedure, 'app.ended_trip_close_pre2710(uuid, jsonb)'::regprocedure);

-- returns charged the old way keep their lines: recorded as decided, by the rental terms
insert into late_return_decisions (booking_id, status, minutes_late, option, reason, decided_at)
select b.id, 'decided', b.minutes_late, 'late_fee', 'Charged by the rental terms at the return, before the late return choice (2710)', coalesce(b.checked_in_at, now())
  from bookings b
 where b.checked_in_at is not null and coalesce(b.minutes_late, 0) > 0 and b.booking_type::text <> 'owner'
on conflict (booking_id) do nothing;

-- ================================================================ what the one-screen handover prefills
create function app.handover_defaults(p_vehicle uuid, p_booking uuid, p_kind text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s record;
  c record;
  o record;
  v_odo integer; v_odo_from text;
  v_fuel integer; v_fuel_from text;
  v_keys integer; v_keys_from text;
begin
  select st.odometer_km, st.fuel_pct, st.reported_at into s
    from tracker_devices d join tracker_status st on st.tracker_device_id = d.id
   where d.vehicle_id = p_vehicle and d.status = 'installed' and st.reported_at > now() - interval '30 minutes'
   order by st.reported_at desc limit 1;
  select r.odometer_km, r.fuel_pct, r.keys_count into c from condition_reports r
   where r.vehicle_id = p_vehicle and r.completed_at is not null and r.odometer_km is not null
   order by r.completed_at desc limit 1;
  if p_booking is not null then
    select r.odometer_km, r.fuel_pct, r.keys_count into o from condition_reports r where r.booking_id = p_booking and r.kind = 'pickup' limit 1;
  end if;
  if s.odometer_km is not null and s.odometer_km > 0 then v_odo := round(s.odometer_km)::integer; v_odo_from := 'tracker';
  elsif p_kind = 'pickup' then
    v_odo := greatest(coalesce(c.odometer_km, 0), coalesce((select v.odometer_km from vehicles v where v.id = p_vehicle), 0));
    if v_odo > 0 then v_odo_from := 'last_report'; else v_odo := null; end if;
  end if;
  -- a return is never prefilled with a reading lower than the pickup's
  if p_kind = 'return' and v_odo is not null and o.odometer_km is not null and v_odo < o.odometer_km then v_odo := null; v_odo_from := null; end if;
  if s.fuel_pct is not null then v_fuel := least(100, greatest(0, s.fuel_pct)); v_fuel_from := 'tracker';
  elsif p_kind = 'return' and o.fuel_pct is not null then v_fuel := o.fuel_pct; v_fuel_from := 'pickup';
  elsif p_kind = 'pickup' and c.fuel_pct is not null then v_fuel := c.fuel_pct; v_fuel_from := 'last_report';
  elsif p_kind = 'pickup' then v_fuel := 100; v_fuel_from := 'full';
  end if;
  if p_kind = 'return' and o.keys_count is not null then v_keys := o.keys_count; v_keys_from := 'pickup';
  elsif c.keys_count is not null and c.keys_count > 0 then v_keys := c.keys_count; v_keys_from := 'last_report';
  else v_keys := 1; v_keys_from := 'one';
  end if;
  return jsonb_build_object('odometer_km', v_odo, 'odometer_from', v_odo_from, 'fuel_pct', v_fuel, 'fuel_from', v_fuel_from,
    'keys_count', v_keys, 'keys_from', v_keys_from, 'cleanliness', case when p_kind = 'return' then 'clean' end,
    'tracker_at', s.reported_at);
end $$;

alter function app.field_read(uuid, text, jsonb) rename to field_read_pre2710;
create function app.field_read(p_user uuid, p_what text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x jsonb := app.field_read_pre2710(p_user, p_what, p);
  v_b uuid;
begin
  if p_what = 'job' and x is not null and (x ->> 'report_kind') in ('pickup', 'return') then
    v_b := nullif(x #>> '{booking,id}', '')::uuid;
    x := x || jsonb_build_object('defaults', app.handover_defaults((x #>> '{vehicle,id}')::uuid, v_b, x ->> 'report_kind'));
    if (x ->> 'report_kind') = 'return' and v_b is not null then
      x := x || jsonb_build_object('late', app.late_return_options(v_b, p_user));
    end if;
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.field_read(uuid, text, jsonb)'::regprocedure, 'app.field_read_pre2710(uuid, text, jsonb)'::regprocedure);

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2710;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_b uuid;
begin
  if (p_call in ('ops_do', 'va_do', 'admin_do') and p_name = 'late_return_decide')
     or (p_call in ('ops_read', 'va_read', 'admin_read') and p_name = 'late_return') then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    p_ := p_ - '_va';
    perform app.door_begin(p_user, p_aal);
    if p_name = 'late_return_decide' then return app.late_return_decide(p_user, p_); end if;
    if not (app.user_may_handover(p_user) or app.user_runs_finance(p_user)) then raise exception 'Not permitted' using errcode = '42501'; end if;
    select b.id into v_b from bookings b where b.id::text = p_ ->> 'booking' or b.booking_number = p_ ->> 'booking' limit 1;
    if v_b is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
    return app.late_return_options(v_b, p_user);
  end if;
  return app.door_pre2710(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2710(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['late_duration', 'late_return_options', 'late_return_write', 'late_return_assess', 'late_return_decide',
                     'handover_defaults', 'complete_return_pre2710', 'ended_trip_close_pre2710', 'field_read_pre2710', 'door_pre2710'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
