-- 2370_r38_short_notice_waiver.sql (release 38)
-- Owner, Nov 11: a "Waive short-notice upcharge" switch with a required reason (audited) under "More options"; Admin
-- always, staff within the existing price limits (1205); offers, manual rentals and extensions.
--   1. bookings.short_notice_waived_at / _by / _reason / _bps: the waiver on the booking (the percentage it took away).
--   2. A call that carries waive_short_notice true with short_notice_waive_reason (3 characters or more) waives the
--      short-notice (positive) lead-time percentage of 0360 for that call: the quote shows no line, and the booking it
--      makes keeps none. Booked-ahead (negative) percentages are never waived. Admin or staff only; the renter's own
--      quote never takes it. The owner's minimum daily rate of 1205 still applies (its line brings a price back up to
--      it); only an Admin's price limit override (1205) lifts it, as before.
--      Paths: the offer (app.staff_offer_create and its preview), Add a rental (app.manual_rental_quote and
--      app.manual_rental_create), and staff extending a booking (app.booking_staff_edit).
--   3. Add a rental's check now shows the short-notice line its booking gets (the booking saved always had it when the
--      rate sheet prices it; 0360's check said none), so the switch is seen where it matters.
--   4. app.short_notice_waive(p_by, {booking, waive, reason}): on a booking made already. A request (requested,
--      tentative) is priced again without the line (taken back: with it again; an offer out is withdrawn first); on a
--      confirmed or on-trip booking the line already paid stays and the waiver keeps it out of the all-in price a day
--      extensions are charged at (1201). Every waiver and its removal is in the audit log and on the booking's history.
-- No applied migration is edited: functions that change are wrapped (_pre2370) or patched with pg_temp.patch_fn.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '2370: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
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

-- ================================================================ 1. on the booking
alter table bookings
  add column if not exists short_notice_waived_at timestamptz,
  add column if not exists short_notice_waived_by uuid references users (id),
  add column if not exists short_notice_waive_reason text check (short_notice_waive_reason is null or length(short_notice_waive_reason) between 3 and 500),
  add column if not exists short_notice_waived_bps integer check (short_notice_waived_bps is null or short_notice_waived_bps between 1 and 5000);
comment on column bookings.short_notice_waived_at is 'The short-notice upcharge (lead-time pricing, 0360) waived by Admin or staff with a reason (2370): not charged while the price is open, never in the all-in price a day of an extension.';
comment on column bookings.short_notice_waived_bps is 'The short-notice percentage the waiver took away (2370), so taking the waiver back puts it again.';
create index if not exists bookings_short_notice_waived_by_idx on bookings (short_notice_waived_by) where short_notice_waived_by is not null;

-- ================================================================ 2. the switch on a call
-- The waiver of the call being made: {by, reason} while app.short_notice_waive_begin has set it, else empty.
create or replace function app.short_notice_waiving() returns boolean
language sql stable as $$ select coalesce(current_setting('app.short_notice_waive', true), '') <> '' $$;

create or replace function app.short_notice_waive_begin(p_by uuid, p jsonb) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  v_reason text := btrim(coalesce(p ->> 'short_notice_waive_reason', ''));
begin
  if not coalesce(nullif(p ->> 'waive_short_notice', '')::boolean, false) then
    perform set_config('app.short_notice_waive', '', true);
    return false;
  end if;
  if p_by is null or not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then
    raise exception 'Only an Admin or staff waive the short-notice upcharge' using errcode = '42501';
  end if;
  if length(v_reason) < 3 then
    raise exception 'Give the reason for waiving the short-notice upcharge' using errcode = '22023';
  end if;
  perform set_config('app.short_notice_waive', jsonb_build_object('by', p_by, 'reason', left(v_reason, 500))::text, true);
  return true;
end $$;

create or replace function app.short_notice_waive_end() returns void
language sql as $$ select set_config('app.short_notice_waive', '', true); select null::void $$;

-- the quote: a short-notice percentage waived is none (a booked-ahead one stays)
alter function app.quote_lead_time(uuid, timestamptz, jsonb) rename to quote_lead_time_pre2370;
create function app.quote_lead_time(p_vehicle uuid, p_pickup timestamptz, o jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  l jsonb := app.quote_lead_time_pre2370(p_vehicle, p_pickup, o);
begin
  -- a rental whose pickup has passed (a walk-in, a rental recorded after it started) is not short notice: no upcharge
  -- (r38: Add a rental's check now prices the line, and a pickup yesterday took the highest short-notice tier)
  if coalesce((l ->> 'bps')::integer, 0) > 0 and p_pickup <= now() then
    return l || jsonb_build_object('bps', 0, 'source', 'started');
  end if;
  if coalesce((l ->> 'bps')::integer, 0) > 0 and app.short_notice_waiving() then
    return l || jsonb_build_object('bps', 0, 'waived_bps', (l ->> 'bps')::integer, 'source', 'waived');
  end if;
  return l;
end $$;
select pg_temp.copy_grants('app.quote_lead_time(uuid, timestamptz, jsonb)'::regprocedure, 'app.quote_lead_time_pre2370(uuid, timestamptz, jsonb)'::regprocedure);

-- the booking made during the call keeps no short-notice percentage, and says who waived it and why
create or replace function app.bookings_short_notice_waive() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  w jsonb;
begin
  -- a pickup already passed when the booking is made carries no short-notice percentage (as the quote above)
  if coalesce(new.lead_time_bps, 0) > 0 and new.pickup_at <= coalesce(new.booked_at, now()) then
    new.lead_time_bps := null;
    return new;
  end if;
  if coalesce(new.lead_time_bps, 0) > 0 and app.short_notice_waiving() then
    w := current_setting('app.short_notice_waive', true)::jsonb;
    new.short_notice_waived_bps := new.lead_time_bps;
    new.lead_time_bps := null;
    new.short_notice_waived_at := now();
    new.short_notice_waived_by := (w ->> 'by')::uuid;
    new.short_notice_waive_reason := w ->> 'reason';
  end if;
  return new;
end $$;
-- after bookings_lead_time_lock (triggers of one kind fire by name)
drop trigger if exists bookings_lead_time_waive on bookings;
create trigger bookings_lead_time_waive before insert on bookings for each row execute function app.bookings_short_notice_waive();

-- the record of a waiver made with a booking: the audit log and the booking's history
create or replace function app.short_notice_waive_record(p_by uuid, p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or b.short_notice_waived_at is null then return; end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'short_notice_waive', 'bookings', b.id::text,
          jsonb_build_object('waived', true, 'bps', b.short_notice_waived_bps, 'reason', b.short_notice_waive_reason));
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('Short-notice upcharge (+%s) waived: %s', app.fmt_pct(b.short_notice_waived_bps), b.short_notice_waive_reason), p_by, 'staff');
end $$;

-- ---------------------------------------------------------------- the offer (and its preview)
alter function app.staff_offer_create(uuid, jsonb) rename to staff_offer_create_pre2370;
create function app.staff_offer_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
begin
  if not app.short_notice_waive_begin(p_by, p) then return app.staff_offer_create_pre2370(p_by, p); end if;
  v_out := app.staff_offer_create_pre2370(p_by, p - 'waive_short_notice' - 'short_notice_waive_reason');
  perform app.short_notice_waive_end();
  perform app.short_notice_waive_record(p_by, nullif(v_out ->> 'booking_id', '')::uuid);
  return v_out;
end $$;
select pg_temp.copy_grants('app.staff_offer_create(uuid, jsonb)'::regprocedure, 'app.staff_offer_create_pre2370(uuid, jsonb)'::regprocedure);

-- ---------------------------------------------------------------- Add a rental
-- its check shows the short-notice line the booking saved gets (0360's 'none' left it out of the check only)
select pg_temp.patch_fn('app.manual_rental_quote_0058(uuid, jsonb)'::regprocedure,
  $o$'lead_time', 'none', 'staff_rental_charge_cents'$o$, $n$'staff_rental_charge_cents'$n$);

alter function app.manual_rental_quote(uuid, jsonb) rename to manual_rental_quote_pre2370;
create function app.manual_rental_quote(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
  v_on boolean := app.short_notice_waive_begin(p_by, p);
begin
  v_out := app.manual_rental_quote_pre2370(p_by, p - 'waive_short_notice' - 'short_notice_waive_reason');
  perform app.short_notice_waive_end();
  return v_out || jsonb_build_object('short_notice_waived', v_on);
end $$;
select pg_temp.copy_grants('app.manual_rental_quote(uuid, jsonb)'::regprocedure, 'app.manual_rental_quote_pre2370(uuid, jsonb)'::regprocedure);

alter function app.manual_rental_create(uuid, jsonb) rename to manual_rental_create_pre2370;
create function app.manual_rental_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
begin
  if not app.short_notice_waive_begin(p_by, p) then return app.manual_rental_create_pre2370(p_by, p); end if;
  v_out := app.manual_rental_create_pre2370(p_by, p - 'waive_short_notice' - 'short_notice_waive_reason');
  perform app.short_notice_waive_end();
  perform app.short_notice_waive_record(p_by, nullif(v_out ->> 'booking_id', '')::uuid);
  return v_out;
end $$;
select pg_temp.copy_grants('app.manual_rental_create(uuid, jsonb)'::regprocedure, 'app.manual_rental_create_pre2370(uuid, jsonb)'::regprocedure);

-- ================================================================ 3. on a booking made already, and extensions
create or replace function app.short_notice_waive(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_waive boolean := coalesce(nullif(p ->> 'waive', '')::boolean, true);
  v_reason text := btrim(coalesce(p ->> 'reason', p ->> 'short_notice_waive_reason', ''));
  v_open boolean;
begin
  if p_by is null or not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then
    raise exception 'Only an Admin or staff waive the short-notice upcharge' using errcode = '42501';
  end if;
  select * into b from bookings where id::text = coalesce(p ->> 'booking_id', p ->> 'booking') or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if length(v_reason) < 3 then raise exception 'Give the reason for waiving the short-notice upcharge' using errcode = '22023'; end if;
  v_open := b.status::text in ('requested', 'tentative');
  if b.status::text in ('offered', 'pending_payment') then
    raise exception 'Booking % has an offer out: withdraw it (back to requested) to waive the short-notice upcharge, or waive it when the rental is made', b.booking_number using errcode = '23514';
  end if;
  if not v_open and b.status::text not in ('confirmed', 'on_rent') then
    raise exception 'Booking % is %: there is nothing left to waive', b.booking_number, b.status using errcode = '23514';
  end if;
  if v_waive then
    if b.short_notice_waived_at is not null then return jsonb_build_object('booking_id', b.id, 'waived', true, 'changed', false); end if;
    if coalesce(b.lead_time_bps, 0) <= 0 then
      raise exception 'Booking % has no short-notice upcharge to waive', b.booking_number using errcode = '22023';
    end if;
    update bookings set short_notice_waived_at = now(), short_notice_waived_by = p_by, short_notice_waive_reason = left(v_reason, 500),
           short_notice_waived_bps = b.lead_time_bps, lead_time_bps = case when v_open then null else lead_time_bps end
     where id = b.id;
  else
    if b.short_notice_waived_at is null then return jsonb_build_object('booking_id', b.id, 'waived', false, 'changed', false); end if;
    update bookings set lead_time_bps = case when v_open then coalesce(short_notice_waived_bps, lead_time_bps) else lead_time_bps end,
           short_notice_waived_at = null, short_notice_waived_by = null, short_notice_waive_reason = null, short_notice_waived_bps = null
     where id = b.id;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, case when v_waive then 'short_notice_waive' else 'short_notice_unwaive' end, 'bookings', b.id::text,
          jsonb_build_object('lead_time_bps', b.lead_time_bps, 'waived', b.short_notice_waived_at is not null),
          jsonb_build_object('waived', v_waive, 'reason', left(v_reason, 500), 'status', b.status));
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    case when v_waive then format('Short-notice upcharge (+%s) waived: %s', app.fmt_pct(b.lead_time_bps), left(v_reason, 500))
         else format('Short-notice upcharge waiver taken back: %s', left(v_reason, 500)) end, p_by, 'staff');
  if v_open then perform app.sync_booking_price(b.id); end if;
  select * into b from bookings where id = b.id;
  return jsonb_build_object('booking_id', b.id, 'waived', b.short_notice_waived_at is not null, 'changed', true,
                            'repriced', v_open, 'total_due_at_booking_cents', b.total_due_at_booking_cents);
end $$;

-- an extension's all-in price a day (1201) leaves out a short-notice line waived
alter function app.booking_all_in(uuid) rename to booking_all_in_pre2370;
create function app.booking_all_in(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with a as (select app.booking_all_in_pre2370(p_booking) as j),
  w as (
    select coalesce(sum(x.amount_cents + x.hst_cents), 0)::bigint as total, coalesce(sum(x.hst_cents), 0)::bigint as hst
      from booking_line_items x join bookings b on b.id = x.booking_id
     where x.booking_id = p_booking and x.charge_type = 'lead_time' and x.amount_cents > 0 and x.stage = 'booking' and x.voided_at is null
       and x.charged_to_renter and x.extension_id is null and b.short_notice_waived_at is not null)
  select case when w.total = 0 then a.j
              else a.j || jsonb_build_object('total_cents', (a.j ->> 'total_cents')::bigint - w.total, 'hst_cents', (a.j ->> 'hst_cents')::bigint - w.hst,
                                             'per_day_cents', round(((a.j ->> 'total_cents')::bigint - w.total)::numeric / greatest((a.j ->> 'days')::integer, 1))::bigint,
                                             'short_notice_waived_cents', w.total) end
    from a, w
$$;
select pg_temp.copy_grants('app.booking_all_in(uuid)'::regprocedure, 'app.booking_all_in_pre2370(uuid)'::regprocedure);

-- staff extending a booking may waive it with the extension (the switch under More options of Edit)
alter function app.booking_staff_edit(uuid, jsonb) rename to booking_staff_edit_pre2370;
create function app.booking_staff_edit(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  if coalesce(nullif(p ->> 'waive_short_notice', '')::boolean, false) then
    select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
    if b.id is not null and b.short_notice_waived_at is null and coalesce(b.lead_time_bps, 0) > 0 then
      perform app.short_notice_waive(p_by, jsonb_build_object('booking_id', b.id, 'waive', true, 'reason', p ->> 'short_notice_waive_reason'));
    elsif length(btrim(coalesce(p ->> 'short_notice_waive_reason', ''))) < 3 then
      raise exception 'Give the reason for waiving the short-notice upcharge' using errcode = '22023';
    end if;
  end if;
  return app.booking_staff_edit_pre2370(p_by, p - 'waive_short_notice' - 'short_notice_waive_reason');
end $$;
select pg_temp.copy_grants('app.booking_staff_edit(uuid, jsonb)'::regprocedure, 'app.booking_staff_edit_pre2370(uuid, jsonb)'::regprocedure);

-- what the screens read: the booking's waiver, and the extension's all-in price as waived
create or replace function app.short_notice_state(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('lead_time_bps', b.lead_time_bps, 'waived', b.short_notice_waived_at is not null, 'waived_bps', b.short_notice_waived_bps,
                            'reason', b.short_notice_waive_reason, 'waived_at', b.short_notice_waived_at,
                            'waived_by', (select u.full_name from users u where u.id = b.short_notice_waived_by))
    from bookings b where b.id = p_booking
$$;

-- ================================================================ 4. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2370;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_do', 'va_do', 'admin_do') and p_name = 'short_notice_waive' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.short_notice_waive(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre2370(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2370(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 5. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['short_notice_waive_begin', 'short_notice_waive_end', 'short_notice_waive_record', 'short_notice_waive',
                                                        'short_notice_state', 'bookings_short_notice_waive', 'quote_lead_time_pre2370', 'staff_offer_create_pre2370',
                                                        'manual_rental_quote_pre2370', 'manual_rental_create_pre2370', 'booking_all_in_pre2370',
                                                        'booking_staff_edit_pre2370', 'door_pre2370'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
