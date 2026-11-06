-- 0541: deposits stay as card holds in Stripe, never paid out (docs/changes/2026-11-07-r28-operations.md, A5).
--
-- The owner: "deposit returns aren't working because Stripe paid the funds out. They should stay with Stripe (holds)
-- instead of being paid out; lowest fees" and "holds longer than seven days such as 30 days".
--
--   1. A deposit is always a card authorization hold (capture_method manual), on the pickup day as before; rentals over
--      the hold limit are no longer charged and refunded (public.calc_deposit_method answers card_hold for any length).
--   2. A hold is never captured by itself any more (Program settings: deposit_auto_capture off). Nothing is captured
--      except an actual charge (tickets, tolls, fuel, late, damage), partly, by a person; the rest is released (cancel)
--      by a person from the booking, as before.
--   3. The hold's real expiry: Stripe's capture_before of the authorization is kept on the deposit (hold_expires_at),
--      with whether the bank gave an extended authorization. The booking shows "hold expires <date>".
--   4. A hold that nears its expiry while the car is out, or while tickets and tolls can still come in: a To do
--      "deposit_hold_expiring" with the one-tap Re-authorize (a new hold on the saved card, off-session, for what is
--      still held, then the old one is released) or Capture (to the balance, per policy, by a person).
--   5. Extended holds (Program settings, "Extended deposit holds", OFF by default until Stripe confirms IC+ pricing):
--      when on, the deposit hold placed off-session on the saved card (the pickup-day hold and Re-authorize) asks Stripe
--      for an extended authorization (up to about 30 days, car rental) "if available", and falls back silently to a
--      standard hold. Never on the rental charge (hotfix-stripe-ext-auth, October 30: asking for it on the booking's
--      payment made Stripe refuse cards).
--   6. Everything in the booking ledger: each re-authorization is a deposit event (hold_renewed) and a booking event.
-- No applied migration is edited.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. settings
alter table program_settings add column if not exists deposit_extended_holds boolean not null default false;
comment on column program_settings.deposit_extended_holds is 'Extended deposit holds (0541): ask Stripe for an extended authorization (up to about 30 days) on the off-session deposit hold, falling back to a standard hold. Off until Stripe confirms IC+ pricing. Never on the rental charge.';
alter table program_settings alter column deposit_auto_capture set default false;
do $$
begin
  if exists (select 1 from program_settings where deposit_auto_capture) then
    insert into audit_log (action, entity_table, entity_id, before, after)
    select '0541_deposit_holds_stay', 'program_settings', id::text, jsonb_build_object('deposit_auto_capture', true), jsonb_build_object('deposit_auto_capture', false)
      from program_settings where deposit_auto_capture;
    update program_settings set deposit_auto_capture = false where deposit_auto_capture;
  end if;
end $$;

alter table deposits add column if not exists hold_extended boolean not null default false;
alter table deposits add column if not exists hold_expiry_from_bank boolean not null default false;
comment on column deposits.hold_extended is 'The bank gave an extended authorization for this hold (0541).';
comment on column deposits.hold_expiry_from_bank is 'hold_expires_at is Stripe''s capture_before of the authorization, not an estimate (0541).';

-- ================================================================ 2. always a hold
create or replace function public.calc_deposit_method(p_days integer, p_hold_max_days integer default 7) returns text
language sql immutable as $$ select 'card_hold'::text $$;
comment on function public.calc_deposit_method(integer, integer) is 'A deposit by card is always a hold (0541): kept in Stripe, renewed before it lapses, never charged and paid out.';

-- ================================================================ 3. the real expiry, from Stripe
create or replace function public.server_deposit_hold_expiry(p_intent text, p_capture_before bigint, p_extended boolean default false) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d deposits;
begin
  if p_intent is null or p_capture_before is null then return jsonb_build_object('ok', false); end if;
  select x.* into d from deposits x join payment_processor_details pd on pd.payment_id = x.hold_payment_id
   where pd.processor_payment_id = p_intent and x.method = 'card_hold' and x.status = 'held' for update of x;
  if d.id is null then return jsonb_build_object('ok', false); end if;
  update deposits set hold_expires_at = to_timestamp(p_capture_before), hold_expiry_from_bank = true, hold_extended = coalesce(p_extended, false)
   where id = d.id;
  return jsonb_build_object('ok', true, 'deposit_id', d.id, 'hold_expires_at', to_timestamp(p_capture_before));
end $$;
revoke all on function public.server_deposit_hold_expiry(text, bigint, boolean) from public, anon, authenticated;
grant execute on function public.server_deposit_hold_expiry(text, bigint, boolean) to service_role;

create or replace function public.server_deposit_extended_holds() returns boolean
language sql stable security definer set search_path = public, app as $$ select coalesce((app.settings()).deposit_extended_holds, false) $$;
revoke all on function public.server_deposit_extended_holds() from public, anon, authenticated;
grant execute on function public.server_deposit_extended_holds() to service_role;

-- ================================================================ 4. nearing expiry: a To do, never a capture by itself
insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, description)
values ('deposit_hold_expiring', 'finance', 'The deposit hold expires soon: re-authorize it', 'high', 'none', 0, 1,
        'A deposit hold nears its expiry while the car is out or tickets and tolls can still come in (0541). Booking > Money: Re-authorize places a new hold on the saved card and releases the old one; or capture what is owed.')
on conflict (task_type) do nothing;

alter function public.server_deposit_guard_sweep() rename to server_deposit_guard_sweep_pre0541;
create function public.server_deposit_guard_sweep() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  r record;
begin
  for r in select d.id, b.id as booking_id, b.booking_number, b.renter_id, b.vehicle_id, d.hold_expires_at, b.status
             from deposits d join bookings b on b.id = d.booking_id
            where d.method = 'card_hold' and d.status = 'held' and b.status in ('on_rent', 'returned', 'closed')
              and d.hold_expires_at > now() and d.hold_expires_at <= now() + make_interval(hours => greatest(s.deposit_hold_capture_hours, 48)) loop
    perform app.raise_task(p_type => 'deposit_hold_expiring',
      p_title => format('Booking %s: the deposit hold expires %s: re-authorize it', r.booking_number, app.fmt_at(r.hold_expires_at)),
      p_detail => case when r.status = 'on_rent' then 'The car is still out. ' else 'Tickets and tolls can still come in. ' end
                  || 'Booking > Money: Re-authorize (a new hold on the saved card, the old one released), or capture what is owed. Never released by itself.',
      p_booking => r.booking_id, p_vehicle => r.vehicle_id, p_renter => r.renter_id, p_due_at => r.hold_expires_at - interval '6 hours',
      p_dedupe => 'deposit_hold_expiring:' || r.id || ':' || extract(epoch from r.hold_expires_at)::bigint);
  end loop;
  return public.server_deposit_guard_sweep_pre0541();
end $$;
select pg_temp.copy_grants('public.server_deposit_guard_sweep()'::regprocedure, 'public.server_deposit_guard_sweep_pre0541()'::regprocedure);

-- the job also wakes for a hold nearing expiry (it woke only for one to capture)
alter function app.deposit_guard_due() rename to deposit_guard_due_pre0541;
create function app.deposit_guard_due() returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.deposit_guard_due_pre0541()
      or exists (select 1 from deposits d join bookings b on b.id = d.booking_id
                  where d.method = 'card_hold' and d.status = 'held' and b.status in ('on_rent', 'returned', 'closed')
                    and d.hold_expires_at > now() and d.hold_expires_at <= now() + interval '48 hours'
                    and not exists (select 1 from tasks t where t.booking_id = b.id and t.task_type = 'deposit_hold_expiring' and t.status in ('open', 'in_progress', 'waiting')))
$$;
select pg_temp.copy_grants('app.deposit_guard_due()'::regprocedure, 'app.deposit_guard_due_pre0541()'::regprocedure);

-- ================================================================ 5. Re-authorize: a new hold on the saved card, then the old one released
create or replace function app.hold_reauth_begin(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  d deposits;
  pd payment_processor_details;
  v_card jsonb;
  v_amount bigint;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin re-authorizes a deposit hold' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  select * into d from deposits where booking_id = b.id for update;
  if d.id is null or d.method <> 'card_hold' or d.status <> 'held' then raise exception 'There is no deposit hold to re-authorize on this booking' using errcode = '23514'; end if;
  select * into pd from payment_processor_details where payment_id = d.hold_payment_id;
  v_card := app.booking_saved_card(b.id);
  if v_card is null or v_card ->> 'customer_id' is null then
    raise exception 'The renter has no saved card: send a deposit link (Collect a card, The deposit hold) instead' using errcode = '23514';
  end if;
  v_amount := d.amount_cents - d.applied_cents - d.released_cents - d.held_back_cents;
  if v_amount <= 0 then raise exception 'Nothing is left on the hold to re-authorize' using errcode = '23514'; end if;
  return jsonb_build_object('deposit_id', d.id, 'booking_id', b.id, 'booking_number', b.booking_number, 'amount_cents', v_amount,
    'customer_id', v_card ->> 'customer_id', 'method_id', v_card ->> 'method_id', 'payment_method_id', v_card ->> 'payment_method_id',
    'old_intent', pd.processor_payment_id, 'extended', coalesce((app.settings()).deposit_extended_holds, false),
    'idempotency_key', 'hold-reauth:' || d.id || ':' || d.hold_payment_id);
end $$;

create or replace function app.hold_reauth_finish(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  d deposits;
  v_old uuid;
  v_pay uuid;
  v_amount bigint := (p ->> 'amount_cents')::bigint;
  v_card jsonb;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin re-authorizes a deposit hold' using errcode = '42501'; end if;
  select * into d from deposits where id = (p ->> 'deposit')::uuid for update;
  if d.id is null or d.method <> 'card_hold' or d.status <> 'held' then raise exception 'The deposit hold changed meanwhile: reload the booking' using errcode = '23514'; end if;
  select * into b from bookings where id = d.booking_id;
  if not coalesce((p ->> 'ok')::boolean, false) then
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
      format('Re-authorizing the deposit hold failed: %s. The current hold stands until %s', coalesce(p ->> 'error', 'the card was declined'), app.fmt_at(d.hold_expires_at)), p_by, 'staff',
      jsonb_build_object('deposit_id', d.id, 'error', p ->> 'error'));
    return jsonb_build_object('ok', false, 'message', coalesce(p ->> 'error', 'The card was declined.'));
  end if;
  v_card := app.booking_saved_card(b.id);
  v_old := d.hold_payment_id;
  insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, payment_method_id, card_brand, card_last4, processed_at, created_by)
  values (b.id, b.renter_id, 'deposit', 'hold', 'card', v_amount, 'authorized', (v_card ->> 'payment_method_id')::uuid, v_card ->> 'brand', v_card ->> 'last4', now(), p_by)
  returning id into v_pay;
  insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id) values (v_pay, 'stripe', p ->> 'intent_id', p ->> 'charge_id');
  update payments set status = 'cancelled' where id = v_old and status = 'authorized';
  update deposits set hold_payment_id = v_pay, amount_cents = d.applied_cents + d.released_cents + d.held_back_cents + v_amount,
         hold_expires_at = coalesce(to_timestamp(nullif(p ->> 'capture_before', '')::bigint), now() + make_interval(days => (app.settings()).deposit_hold_max_days)),
         hold_expiry_from_bank = (p ->> 'capture_before') is not null, hold_extended = coalesce((p ->> 'extended')::boolean, false)
   where id = d.id returning * into d;
  insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note, created_by)
  values (d.id, 'hold_renewed', v_amount, v_pay, format('Re-authorized on the saved card; held until %s%s', app.fmt_at(d.hold_expires_at), case when d.hold_extended then ' (extended)' else '' end), p_by);
  perform app.resolve_tasks(array['deposit_hold_expiring', 'renew_deposit_hold'], b.id, p_by, 'Re-authorized until ' || app.fmt_at(d.hold_expires_at));
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('Deposit hold of %s re-authorized on the saved card, held until %s; the old hold is released', app.fmt_money(v_amount), app.fmt_at(d.hold_expires_at)), p_by, 'staff',
    jsonb_build_object('deposit_id', d.id, 'payment_id', v_pay, 'replaced_payment_id', v_old, 'extended', d.hold_extended));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'deposit_hold_reauthorized', 'deposits', d.id::text, jsonb_build_object('hold_payment_id', v_old),
          jsonb_build_object('hold_payment_id', v_pay, 'hold_expires_at', d.hold_expires_at, 'amount_cents', v_amount));
  return jsonb_build_object('ok', true, 'hold_expires_at', d.hold_expires_at, 'extended', d.hold_extended);
end $$;
revoke all on function app.hold_reauth_begin(uuid, jsonb), app.hold_reauth_finish(uuid, jsonb) from public, anon, authenticated;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0541;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_do' and p_name in ('hold_reauth_begin', 'hold_reauth_finish') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    if p_name = 'hold_reauth_begin' then return app.hold_reauth_begin(p_user, coalesce(p, '{}'::jsonb) - '_va'); end if;
    return app.hold_reauth_finish(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0541(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0541(uuid, text, text, text, jsonb)'::regprocedure);
