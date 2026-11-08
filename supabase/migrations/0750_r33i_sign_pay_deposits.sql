-- 0750_r33i_sign_pay_deposits.sql
-- Release 33 part I (docs/changes/2026-11-07-r33-sign-and-pay.md):
--
--   1. One rule for "signed, ready to pay" (app.sign_pay_state). Until now the sign page read the booking's latest
--      agreement (my_booking: any of open, signed, completed, whatever its offer version) and the payment read its own
--      (server_booking_payment_facts: signed or completed AND for the approved offer version). They disagreed when:
--        a. the offer was revised after the renter signed (app.offer_reopen_for_edit voids an open agreement but leaves a
--           signed one) and the new version was approved without a new agreement being opened (approved by phone, or the
--           page's agreement render failed after the approval): the sign page sent the renter to pay, the payment said
--           "sign first" (the loop of booking CC-10080);
--        b. a rental added while already underway with a payment link (0074): its agreement has no offer version, so an
--           approved version on the booking made the payment refuse what the database's live payment accepts;
--        c. an additional driver who must sign before payment (required_before_payment) had not signed: the sign page sent
--           the renter to pay, the card was authorized, then the confirmation refused it (agreement_not_signed).
--      The rule answers one step (offer, sign, drivers, pay, none), whether the signed agreement is for an older offer
--      version (stale: the renter signs a fresh one), what is due and who is still to sign. my_booking and my_bookings carry
--      it (sign_pay), the payment facts take agreement_signed from it, and server_booking_sign_pay gives it to the Admin
--      and staff booking page.
--   2. Deposit keep reasons: Keep part of the deposit and A later charge take a reason from a list (payments and
--      deposit_events: reason_code, reason_note); the reason is on the renter's receipt and the Money tab.
--   3. Expired card holds: a capture Stripe refuses because the hold lapsed marks the deposit (hold_lapsed_at) and is
--      refused before Stripe next time; the guard sweep marks a hold past its expiry; a job re-authorizes a hold about
--      24 hours before it expires (the existing Re-authorize, as the system) and alerts Finance and an Admin when it fails.
-- No applied migration is edited: the functions changed are wrapped (suffix _pre0750).

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. the one sign-and-pay rule
create or replace function app.sign_pay_state(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  a rental_agreements;
  v_live boolean;
  v_version integer;
  v_renter_signed boolean := false;
  v_for_current boolean := false;
  v_waiting text[] := '{}';
  v_signed boolean;
  v_pay_due boolean;
  v_sign_due boolean;
  v_step text;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return null; end if;
  -- the booking's live agreement: the one my_booking shows (the latest opened of open, signed, completed)
  select * into a from rental_agreements x where x.booking_id = b.id and x.status in ('open', 'signed', 'completed') order by x.opened_at desc limit 1;
  -- a rental added by hand (and a long rental's period) is signed with no offer version; an owner booking has none
  v_live := app.booking_added_live(b);
  v_version := case when b.booking_type = 'owner' or v_live then null else b.offer_approved_version end;
  if a.id is not null then
    v_renter_signed := a.status in ('signed', 'completed') and a.renter_signed_at is not null;
    v_for_current := v_live or a.offer_version is not distinct from v_version;
    select coalesce(array_agg(g.signer_name order by g.signer_name), '{}') into v_waiting from rental_agreement_signers g
     where g.agreement_id = a.id and g.signer_role = 'additional_driver' and g.required_before_payment and g.signed_at is null;
  end if;
  v_signed := v_renter_signed and v_for_current and cardinality(v_waiting) = 0;
  v_pay_due := b.status = 'pending_payment' or app.booking_link_due(b);
  v_sign_due := not v_signed and (v_pay_due or v_live or app.booking_paid_unsigned(b));
  v_step := case when b.status = 'offered' then 'offer'
                 when v_sign_due and v_renter_signed and v_for_current then 'drivers'
                 when v_sign_due then 'sign'
                 when v_pay_due then 'pay'
                 else 'none' end;
  return jsonb_build_object('step', v_step, 'signed', v_signed, 'renter_signed', v_renter_signed, 'for_current', v_for_current,
    'stale', v_renter_signed and not v_for_current, 'pay_after', v_pay_due,
    'due_cents', case when v_pay_due then coalesce(b.renter_due_at_booking_cents, 0) else 0 end,
    'waiting', to_jsonb(v_waiting), 'agreement_id', a.id, 'agreement_status', a.status, 'agreement_version', a.offer_version,
    'approved_version', v_version, 'signed_at', a.renter_signed_at);
end $$;
revoke all on function app.sign_pay_state(uuid) from public, anon, authenticated;
comment on function app.sign_pay_state(uuid) is 'The one rule for signing and paying a booking (0750): step offer, sign, drivers, pay or none; signed (the renter signed the agreement for the approved offer and every driver who must sign before payment did); stale (signed for an older offer version: a fresh agreement is opened and signed); due_cents; waiting (the drivers still to sign). The sign and pay pages, the payment and the booking pages read it.';

-- the renter's own (my_booking runs as the renter: the booking must be theirs)
create or replace function app.my_sign_pay(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.sign_pay_state(p_booking) where app.is_booking_renter(p_booking, app.uid())
$$;
revoke all on function app.my_sign_pay(uuid) from public, anon;
grant execute on function app.my_sign_pay(uuid) to authenticated, service_role;

-- staff and the server: the Admin and staff booking page's Next step states what the renter sees
create or replace function public.server_booking_sign_pay(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.sign_pay_state(p_booking) $$;
revoke all on function public.server_booking_sign_pay(uuid) from public, anon, authenticated;
grant execute on function public.server_booking_sign_pay(uuid) to service_role;

alter function public.my_booking(text) rename to my_booking_pre0750;
alter function public.my_booking_pre0750(text) set schema app;
create function public.my_booking(p_number text) returns jsonb
language sql stable set search_path = public, app as $$
  select case when x is null then null else x || jsonb_build_object('sign_pay', app.my_sign_pay((x ->> 'id')::uuid)) end
    from (select app.my_booking_pre0750(p_number) as x) q
$$;
select pg_temp.copy_grants('public.my_booking(text)'::regprocedure, 'app.my_booking_pre0750(text)'::regprocedure);

alter function public.my_bookings() rename to my_bookings_pre0750;
alter function public.my_bookings_pre0750() set schema app;
create function public.my_bookings() returns setof jsonb
language sql stable set search_path = public, app as $$
  select x || jsonb_build_object('sign_pay', case when x ->> 'status' in ('offered', 'pending_payment', 'confirmed', 'on_rent') then app.my_sign_pay((x ->> 'id')::uuid) end)
    from app.my_bookings_pre0750() x
$$;
select pg_temp.copy_grants('public.my_bookings()'::regprocedure, 'app.my_bookings_pre0750()'::regprocedure);

-- the payment takes "signed" from the same rule (startPayment, the pay page)
alter function public.server_booking_payment_facts(uuid) rename to server_booking_payment_facts_pre0750;
alter function public.server_booking_payment_facts_pre0750(uuid) set schema app;
revoke all on function app.server_booking_payment_facts_pre0750(uuid) from public, anon, authenticated;
create function public.server_booking_payment_facts(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select f || jsonb_build_object('agreement_signed', coalesce((s ->> 'signed')::boolean, false), 'sign_pay', s)
    from (select app.server_booking_payment_facts_pre0750(p_booking) as f, app.sign_pay_state(p_booking) as s) q
   where f is not null
$$;
revoke all on function public.server_booking_payment_facts(uuid) from public, anon, authenticated;
grant execute on function public.server_booking_payment_facts(uuid) to service_role;

-- ================================================================ 2. deposit keep reasons and later charge reasons
create or replace function app.charge_reason_label(p_code text) returns text
language sql immutable as $$
  select case p_code when 'mileage' then 'Mileage overage' when 'fuel' then 'Fuel' when 'cleaning' then 'Cleaning' when 'smoking' then 'Smoking'
                     when 'late_return' then 'Late return' when 'tolls' then 'Tolls' when 'tickets' then 'Tickets/fines' when 'damage' then 'Damage'
                     when 'missing_items' then 'Missing items' when 'other' then 'Other' end
$$;
comment on function app.charge_reason_label(text) is 'The reason list of Keep part of the deposit and A later charge (0750), in words.';

alter table payments add column if not exists reason_code text check (reason_code is null or reason_code in ('mileage', 'fuel', 'cleaning', 'smoking', 'late_return', 'tolls', 'tickets', 'damage', 'missing_items', 'other'));
alter table payments add column if not exists reason_note text check (reason_note is null or length(reason_note) <= 500);
alter table deposit_events add column if not exists reason_code text check (reason_code is null or reason_code in ('mileage', 'fuel', 'cleaning', 'smoking', 'late_return', 'tolls', 'tickets', 'damage', 'missing_items', 'other'));
alter table deposit_events add column if not exists reason_note text check (reason_note is null or length(reason_note) <= 500);
comment on column payments.reason_code is 'Why a later charge or a part of the deposit kept was charged (0750): mileage, fuel, cleaning, smoking, late_return, tolls, tickets, damage, missing_items, other (with reason_note).';
comment on column deposit_events.reason_code is 'Why part of the deposit was kept (0750), as payments.reason_code.';

-- the reason in words (checked): null without a code; Other needs its note
create or replace function app.charge_reason_text(p jsonb) returns text
language plpgsql immutable as $$
declare
  v_code text := nullif(btrim(coalesce(p ->> 'reason_code', '')), '');
  v_note text := nullif(btrim(coalesce(p ->> 'reason_note', '')), '');
begin
  if v_code is null then return null; end if;
  if app.charge_reason_label(v_code) is null then raise exception 'Choose the reason from the list' using errcode = '22023'; end if;
  if v_code = 'other' and v_note is null then raise exception 'Other: say what the charge is for (the renter''s receipt shows it)' using errcode = '22023'; end if;
  if length(coalesce(v_note, '')) > 500 then raise exception 'The note is 500 characters at most' using errcode = '22023'; end if;
  return app.charge_reason_label(v_code) || coalesce(': ' || v_note, '');
end $$;

alter function app.hold_action_begin(uuid, jsonb) rename to hold_action_begin_pre0750;
create function app.hold_action_begin(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_reason text := app.charge_reason_text(p);
  d deposits;
begin
  if p ->> 'action' = 'capture' then
    select x.* into d from deposits x join bookings b on b.id = x.booking_id
     where b.id::text = p ->> 'booking' or b.booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
    if d.id is not null and d.method = 'card_hold' and d.status = 'held' and d.hold_lapsed_at is not null then
      raise exception 'The card hold has expired, so nothing can be kept from it. Charge the card on file instead.' using errcode = '23514';
    end if;
  end if;
  return app.hold_action_begin_pre0750(p_by, case when v_reason is not null then p || jsonb_build_object('reason', v_reason) else p end);
end $$;
select pg_temp.copy_grants('app.hold_action_begin(uuid, jsonb)'::regprocedure, 'app.hold_action_begin_pre0750(uuid, jsonb)'::regprocedure);

alter function app.hold_action_finish(uuid, jsonb) rename to hold_action_finish_pre0750;
create function app.hold_action_finish(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_reason text := app.charge_reason_text(p);
  v_out jsonb;
  d deposits;
  b bookings;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  -- Stripe refused because the hold lapsed (the PaymentIntent is canceled): marked, never kept, the card on file instead
  if not coalesce((p ->> 'ok')::boolean, false) and coalesce((p ->> 'lapsed')::boolean, false) then
    select * into d from deposits where id = (p ->> 'deposit')::uuid for update;
    if d.id is not null and d.method = 'card_hold' and d.status = 'held' then
      update deposits set hold_lapsed_at = coalesce(hold_lapsed_at, now()), hold_expires_at = least(coalesce(hold_expires_at, now()), now()) where id = d.id;
      select * into b from bookings where id = d.booking_id;
      perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
        'The deposit hold expired at the card processor: nothing was kept from it. Charge the card on file instead.', p_by, 'staff', jsonb_build_object('deposit_id', d.id));
    end if;
    return jsonb_build_object('ok', false, 'lapsed', true, 'reason', 'The card hold has expired, so nothing can be kept from it. Charge the card on file instead.');
  end if;
  v_out := app.hold_action_finish_pre0750(p_by, case when v_reason is not null then p || jsonb_build_object('reason', v_reason) else p end);
  if v_reason is not null and coalesce((v_out ->> 'ok')::boolean, false) and v_out ->> 'payment_id' is not null and p ->> 'action' = 'capture' then
    update payments set reason_code = p ->> 'reason_code', reason_note = nullif(btrim(coalesce(p ->> 'reason_note', '')), '') where id = (v_out ->> 'payment_id')::uuid;
    update deposit_events set reason_code = p ->> 'reason_code', reason_note = nullif(btrim(coalesce(p ->> 'reason_note', '')), '')
     where payment_id = (v_out ->> 'payment_id')::uuid and kind = 'captured';
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.hold_action_finish(uuid, jsonb)'::regprocedure, 'app.hold_action_finish_pre0750(uuid, jsonb)'::regprocedure);

alter function app.card_charge_begin(uuid, jsonb) rename to card_charge_begin_pre0750;
create function app.card_charge_begin(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_reason text := app.charge_reason_text(p);
  v_out jsonb;
  pay payments;
  v_fee bigint;
begin
  v_out := app.card_charge_begin_pre0750(p_by, case when v_reason is not null then p || jsonb_build_object('reason', v_reason) else p end);
  if v_reason is not null and v_out ->> 'payment_id' is not null then
    update payments set reason_code = p ->> 'reason_code', reason_note = nullif(btrim(coalesce(p ->> 'reason_note', '')), '') where id = (v_out ->> 'payment_id')::uuid;
  end if;
  -- a deposit charged to a debit or prepaid card: its card processing fee on the same charge, apart from the deposit
  if v_out ->> 'covers' = 'deposit' then
    select * into pay from payments where id = (v_out ->> 'payment_id')::uuid for update;
    if pay.card_funding in ('debit', 'prepaid') or (select pm.funding from payment_methods pm where pm.id = pay.payment_method_id) in ('debit', 'prepaid') then
      v_fee := app.debit_deposit_fee(pay.amount_cents);
      if v_fee > 0 then
        update payments set amount_cents = pay.amount_cents + v_fee, card_fee_cents = v_fee where id = pay.id;
        v_out := v_out || jsonb_build_object('amount_cents', pay.amount_cents + v_fee, 'deposit_cents', pay.amount_cents, 'fee_cents', v_fee);
      end if;
    end if;
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.card_charge_begin(uuid, jsonb)'::regprocedure, 'app.card_charge_begin_pre0750(uuid, jsonb)'::regprocedure);

-- the deposit recorded is the deposit only: the fee stays on the payment (never refunded with the deposit)
alter function app.card_charge_finish(uuid, jsonb) rename to card_charge_finish_pre0750;
create function app.card_charge_finish(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.card_charge_finish_pre0750(p_by, p);
  pay payments;
begin
  select * into pay from payments where id = (p ->> 'payment')::uuid;
  if pay.purpose = 'deposit' and pay.card_fee_cents > 0 and pay.status = 'succeeded' and coalesce((v_out ->> 'ok')::boolean, false) then
    update deposits set amount_cents = pay.amount_cents - pay.card_fee_cents, captured_cents = pay.amount_cents - pay.card_fee_cents
     where hold_payment_id = pay.id and method = 'charged' and amount_cents = pay.amount_cents;
    update deposit_events set amount_cents = pay.amount_cents - pay.card_fee_cents, note = coalesce(note, '') || format(' (with a non-refundable card processing fee of %s)', app.fmt_money(pay.card_fee_cents))
     where payment_id = pay.id and kind = 'taken' and amount_cents = pay.amount_cents;
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.card_charge_finish(uuid, jsonb)'::regprocedure, 'app.card_charge_finish_pre0750(uuid, jsonb)'::regprocedure);

alter table payments add column if not exists card_fee_cents bigint not null default 0 check (card_fee_cents >= 0);
-- the Money tab: the reason of each charge that has one, and the card fee of a debit deposit charged
create or replace function public.server_booking_charge_reasons(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'reasons', (select coalesce(jsonb_agg(jsonb_build_object('payment_id', x.payment_id, 'code', x.code, 'label', app.charge_reason_label(x.code), 'note', x.note) order by x.at), '[]'::jsonb)
      from (select p.id as payment_id, p.reason_code as code, p.reason_note as note, p.created_at as at from payments p where p.booking_id = p_booking and p.reason_code is not null
            union all
            select e.payment_id, e.reason_code, e.reason_note, e.created_at from deposit_events e join deposits d on d.id = e.deposit_id
             where d.booking_id = p_booking and e.reason_code is not null and e.payment_id is not null
               and not exists (select 1 from payments p2 where p2.id = e.payment_id and p2.reason_code is not null)) x),
    'fees', (select coalesce(jsonb_agg(jsonb_build_object('payment_id', p.id, 'fee_cents', p.card_fee_cents, 'status', p.status) order by p.created_at), '[]'::jsonb)
               from payments p where p.booking_id = p_booking and p.card_fee_cents > 0))
$$;
revoke all on function public.server_booking_charge_reasons(uuid) from public, anon, authenticated;
grant execute on function public.server_booking_charge_reasons(uuid) to service_role;

-- ================================================================ 2b. the card fee of a deposit charged to a debit or prepaid card
-- A deposit taken as a charge (not a hold) on a debit or prepaid card: the renter pays the card processing fee on it, a
-- separate non-refundable amount on the same charge (payments.card_fee_cents). The deposit itself (deposits.amount_cents)
-- is the deposit only, so its refund returns the deposit only.
alter table program_settings add column if not exists debit_deposit_fee_bps integer not null default 290 check (debit_deposit_fee_bps between 0 and 1000);
alter table program_settings add column if not exists debit_deposit_fee_cents integer not null default 30 check (debit_deposit_fee_cents between 0 and 500);
comment on column program_settings.debit_deposit_fee_bps is 'Card processing fee for a debit deposit (0750): the percentage, in hundredths of a percent (290: 2.9%), on a deposit charged to a debit or prepaid card. Non-refundable.';
comment on column program_settings.debit_deposit_fee_cents is 'Card processing fee for a debit deposit (0750): the fixed part, in cents (30: $0.30).';
comment on column payments.card_fee_cents is 'The card processing fee for a debit deposit included in this charge (0750): not part of the deposit, never refunded with it.';

create or replace function app.debit_deposit_fee(p_amount bigint) returns bigint
language sql stable security definer set search_path = public, app as $$
  select case when coalesce(p_amount, 0) <= 0 then 0
              else round(p_amount * (app.settings()).debit_deposit_fee_bps / 10000.0)::bigint + (app.settings()).debit_deposit_fee_cents end
$$;
create or replace function public.server_debit_deposit_fee(p_amount bigint) returns bigint
language sql stable security definer set search_path = public, app as $$ select app.debit_deposit_fee(p_amount) $$;
revoke all on function public.server_debit_deposit_fee(bigint) from public, anon, authenticated;
grant execute on function public.server_debit_deposit_fee(bigint) to service_role;

-- the renter's receipt names the reason
alter function app.pdf_facts(text, text, uuid) rename to pdf_facts_pre0750;
create function app.pdf_facts(p_kind text, p_key text, p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  f jsonb := app.pdf_facts_pre0750(p_kind, p_key, p_user);
  pay payments;
  v_code text;
  v_note text;
begin
  if p_kind <> 'receipt' or f is null then return f; end if;
  select * into pay from payments where id = app.file_key_id(p_key);
  if pay.card_fee_cents > 0 then
    f := f || jsonb_build_object('fee_cents', pay.card_fee_cents, 'lines', coalesce(f -> 'lines', '[]'::jsonb) || jsonb_build_array(
      jsonb_build_object('label', 'Security deposit (refundable)', 'amount_cents', pay.amount_cents - pay.card_fee_cents, 'hst_cents', 0),
      jsonb_build_object('label', 'Card processing fee for a debit deposit (non-refundable)', 'amount_cents', pay.card_fee_cents, 'hst_cents', 0)));
  end if;
  select coalesce(p.reason_code, e.reason_code), coalesce(p.reason_note, e.reason_note) into v_code, v_note
    from payments p left join deposit_events e on e.payment_id = p.id and e.kind = 'captured' and e.reason_code is not null
   where p.id = app.file_key_id(p_key) limit 1;
  if v_code is null then return f; end if;
  return f || jsonb_build_object('reason', app.charge_reason_label(v_code) || coalesce(': ' || v_note, ''), 'reason_code', v_code);
end $$;
select pg_temp.copy_grants('app.pdf_facts(text, text, uuid)'::regprocedure, 'app.pdf_facts_pre0750(text, text, uuid)'::regprocedure);

-- ================================================================ 3. expired card holds, and the hold re-authorized before it lapses
alter table deposits add column if not exists hold_lapsed_at timestamptz;
alter table deposits add column if not exists reauth_tried_at timestamptz;
comment on column deposits.hold_lapsed_at is 'The card hold lapsed (0750): Stripe refused a capture as canceled, or the guard sweep found it past its expiry. Nothing can be kept from it: the card on file is charged instead.';
comment on column deposits.reauth_tried_at is 'The last time the job tried to re-authorize this hold before it lapses (0750): one try every 6 hours.';

-- the guard sweep marks a hold past its expiry
alter function public.server_deposit_guard_sweep() rename to server_deposit_guard_sweep_pre0750;
alter function public.server_deposit_guard_sweep_pre0750() set schema app;
revoke all on function app.server_deposit_guard_sweep_pre0750() from public, anon, authenticated;
create function public.server_deposit_guard_sweep() returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  update deposits set hold_lapsed_at = now()
   where method = 'card_hold' and status = 'held' and hold_lapsed_at is null and hold_expires_at is not null and hold_expires_at < now();
  return app.server_deposit_guard_sweep_pre0750();
end $$;
revoke all on function public.server_deposit_guard_sweep() from public, anon, authenticated;
grant execute on function public.server_deposit_guard_sweep() to service_role;

-- the deposits due: a held card hold of a booking not settled, expiring within 24 hours, not tried in the last 6
create or replace function app.deposit_reauth_due(p_limit integer default 10)
returns table (deposit_id uuid, booking_id uuid, booking_number text, hold_expires_at timestamptz)
language sql stable security definer set search_path = public, app as $$
  select d.id, b.id, b.booking_number, d.hold_expires_at
    from deposits d join bookings b on b.id = d.booking_id
   where d.method = 'card_hold' and d.status = 'held' and d.hold_lapsed_at is null
     and d.hold_expires_at > now() and d.hold_expires_at <= now() + interval '24 hours'
     and (d.reauth_tried_at is null or d.reauth_tried_at < now() - interval '6 hours')
     and b.status in ('confirmed', 'on_rent', 'returned', 'closed')
     and d.amount_cents - d.applied_cents - d.released_cents - d.held_back_cents > 0
   order by d.hold_expires_at
   limit greatest(coalesce(p_limit, 10), 1)
$$;
revoke all on function app.deposit_reauth_due(integer) from public, anon, authenticated;

create or replace function public.server_deposit_reauth_due(p_limit integer default 10) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('deposit_id', x.deposit_id, 'booking_id', x.booking_id, 'booking_number', x.booking_number, 'hold_expires_at', x.hold_expires_at)), '[]'::jsonb)
    from app.deposit_reauth_due(p_limit) x
$$;
revoke all on function public.server_deposit_reauth_due(integer) from public, anon, authenticated;
grant execute on function public.server_deposit_reauth_due(integer) to service_role;

-- the alert when the job could not re-authorize (Finance and an Admin)
insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort)
values ('deposit_reauth_failed', 'Deposit hold not re-authorized', 'Money', '{admin,on_duty:finance}', 'urgent', 'alerts', true, false,
        'The job re-authorizes a deposit hold about 24 hours before it expires; this alert says it could not (0750).', 44)
on conflict (rule) do nothing;

create or replace function app.deposit_reauth_alert(p_deposit uuid, p_why text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  d deposits;
  b bookings;
begin
  select * into d from deposits where id = p_deposit;
  select * into b from bookings where id = d.booking_id;
  if b.id is null then return; end if;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('The deposit hold was not re-authorized automatically: %s. The current hold stands until %s', coalesce(nullif(btrim(p_why), ''), 'the card was declined'), app.fmt_at(d.hold_expires_at)),
    null, 'system', jsonb_build_object('deposit_id', d.id));
  perform app.staff_alert('deposit_reauth_failed', 'deposit', d.id, 'reauth:' || coalesce(extract(epoch from d.hold_expires_at)::bigint, 0),
    format('Deposit hold not re-authorized: %s', b.booking_number),
    format('The hold of %s expires %s. %s. Booking > Money: Re-authorize the hold, or charge the card on file.',
           app.fmt_money(d.amount_cents - d.applied_cents - d.released_cents - d.held_back_cents), app.fmt_at(d.hold_expires_at), coalesce(nullif(btrim(p_why), ''), 'The card was declined')),
    jsonb_build_object('path_admin', '/admin/bookings/' || b.booking_number || '?tab=money', 'path_staff', '/staff/bookings/' || b.booking_number || '?tab=money'));
end $$;
revoke all on function app.deposit_reauth_alert(uuid, text) from public, anon, authenticated;

-- the job's begin: what Re-authorize the hold begins with, as the system (no person), one try per 6 hours
create or replace function public.server_deposit_reauth_begin(p_deposit uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d deposits;
  b bookings;
  pd payment_processor_details;
  v_card jsonb;
  v_amount bigint;
begin
  select * into d from deposits where id = p_deposit for update;
  if d.id is null or d.method <> 'card_hold' or d.status <> 'held' or d.hold_lapsed_at is not null then return jsonb_build_object('ok', false, 'skip', true); end if;
  if d.reauth_tried_at is not null and d.reauth_tried_at > now() - interval '6 hours' then return jsonb_build_object('ok', false, 'skip', true); end if;
  select * into b from bookings where id = d.booking_id;
  update deposits set reauth_tried_at = now() where id = d.id;
  v_amount := d.amount_cents - d.applied_cents - d.released_cents - d.held_back_cents;
  if v_amount <= 0 then return jsonb_build_object('ok', false, 'skip', true); end if;
  v_card := app.booking_saved_card(b.id);
  if v_card is null or v_card ->> 'customer_id' is null or v_card ->> 'method_id' is null then
    perform app.deposit_reauth_alert(d.id, 'The renter has no saved card');
    return jsonb_build_object('ok', false, 'message', 'The renter has no saved card');
  end if;
  select * into pd from payment_processor_details where payment_id = d.hold_payment_id;
  return jsonb_build_object('ok', true, 'deposit_id', d.id, 'booking_id', b.id, 'booking_number', b.booking_number, 'amount_cents', v_amount,
    'customer_id', v_card ->> 'customer_id', 'method_id', v_card ->> 'method_id', 'old_intent', pd.processor_payment_id,
    'extended', coalesce((app.settings()).deposit_extended_holds, false),
    'idempotency_key', 'hold-reauth:' || d.id || ':' || d.hold_payment_id || ':job:' || floor(extract(epoch from now()) / 21600)::bigint);
end $$;
revoke all on function public.server_deposit_reauth_begin(uuid) from public, anon, authenticated;
grant execute on function public.server_deposit_reauth_begin(uuid) to service_role;

-- the finish of Re-authorize, as the system: the same function without the person's check (copied from the live one)
do $$
declare
  d text := pg_get_functiondef('app.hold_reauth_finish(uuid, jsonb)'::regprocedure);
  v_gate text := $g$if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin re-authorizes a deposit hold' using errcode = '42501'; end if;$g$;
begin
  if position(v_gate in d) = 0 or position('app.hold_reauth_finish(' in d) = 0 then raise exception '0750: app.hold_reauth_finish is not as expected'; end if;
  execute replace(replace(d, v_gate, '-- 0750: the job runs it as the system (server_deposit_reauth_finish), no person'), 'app.hold_reauth_finish(', 'app.hold_reauth_finish_sys(');
end $$;
revoke all on function app.hold_reauth_finish_sys(uuid, jsonb) from public, anon, authenticated;

create or replace function public.server_deposit_reauth_finish(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
begin
  v_out := app.hold_reauth_finish_sys(null, p);
  if not coalesce((v_out ->> 'ok')::boolean, false) then perform app.deposit_reauth_alert((p ->> 'deposit')::uuid, coalesce(p ->> 'error', v_out ->> 'message')); end if;
  return v_out;
end $$;
revoke all on function public.server_deposit_reauth_finish(jsonb) from public, anon, authenticated;
grant execute on function public.server_deposit_reauth_finish(jsonb) to service_role;

-- the deposit job is due when a hold needs re-authorizing
alter function app.server_jobs_due() rename to server_jobs_due_pre0750;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  j jsonb := app.server_jobs_due_pre0750();
begin
  if coalesce((j ->> 'deposits')::boolean, false) then return j; end if;
  return j || jsonb_build_object('deposits', exists (select 1 from app.deposit_reauth_due(1)));
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre0750()'::regprocedure);

-- the renamed functions stay internal (each is called by its wrapper only)
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('hold_action_begin_pre0750', 'hold_action_finish_pre0750', 'card_charge_begin_pre0750', 'card_charge_finish_pre0750', 'pdf_facts_pre0750', 'server_jobs_due_pre0750') loop
    execute format('revoke all on function %s from public, anon, authenticated', r.f);
  end loop;
end $$;

-- the server runs every function of the app schema (tests 06, 08, 09): the ones made or renamed here
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and not has_function_privilege('service_role', p.oid, 'execute') loop
    execute format('grant execute on function %s to service_role', r.f);
  end loop;
end $$;
