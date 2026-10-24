-- 0129: offers and rentals made easy (docs/changes/2026-10-24-offers-and-rentals.md)
--
-- The owner: "The booking flow has fundamental flaws. U need to make it easier for us to adjust offers and to send out
-- offers without requests and to input rentals." Then: "I don't see anywhere to accept a deposit in cash and rental
-- payment on card or e-transfer and vice versa", "Need a way to bill through Stripe through the website so we don't
-- have to use Stripe directly" and "What's the difference between protection plan and coverage price?"
--
-- 1. An offer without a request (app.staff_offer_create): the customer found by phone or email or created, the car, the
--    dates, the price, fees, deposit, Protection Plan, how the rental and the deposit are paid, the expiry; it makes the
--    same request and offer records the website makes, so approval, signing, payment, the calendar, statements and
--    commissions work unchanged. No "request received" email for a request staff made; the renter hears of the offer
--    by email, by text, both or not at all (staff choose). A rolled-back preview (app.staff_offer_preview) shows the
--    renter's view before anything is sent.
-- 2. An offer edited in place (app.offer_revise): an offer that is out (offered, or approved and not paid) is edited
--    and sent again in one step, or saved without telling the renter. No "Withdraw to edit".
-- 3. Payments by part and method: the rental, the deposit, fees and later charges each paid by card, e-Transfer, cash,
--    cheque, platform payout or the insurer, in any combination (app.record_booking_payment). A deposit in cash or by
--    e-Transfer is a deposit like a card one (method offline) and is returned the same way it came, with a receipt. A
--    booking whose rental is paid offline is confirmed by staff once the money is in and the agreement is signed.
-- 4. Rentals added by hand take the deposit method, platform payouts and insurer billing, "signed on paper" and
--    "does not block the calendar" in the same call (wrapper of app.manual_rental_create).
-- 5. Card actions from the booking page through Stripe (payment_requests): a pay link for the renter's phone or the
--    staff device handed to the renter, a deposit hold, saving the card, charging the saved card, capture, release.
-- 6. One name for the Protection Plan in staff wording.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0129: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. schema
alter table bookings
  add column if not exists rental_pay_method text not null default 'card',
  add column if not exists deposit_pay_method text not null default 'card',
  add column if not exists agreement_on_paper boolean not null default false;
alter table bookings drop constraint if exists bookings_rental_pay_method_check;
alter table bookings add constraint bookings_rental_pay_method_check
  check (rental_pay_method in ('card', 'e_transfer', 'cash', 'cheque', 'bank_transfer', 'platform_payout', 'insurer'));
alter table bookings drop constraint if exists bookings_deposit_pay_method_check;
alter table bookings add constraint bookings_deposit_pay_method_check check (deposit_pay_method in ('card', 'cash', 'e_transfer', 'none'));
comment on column bookings.rental_pay_method is 'How the amount due at booking is paid (0129): card (online, the usual way) or offline (e-Transfer, cash, cheque, bank transfer, platform payout, insurer). An offline booking is confirmed by staff when the money is in.';
comment on column bookings.deposit_pay_method is 'How the deposit is taken at pickup (0129): card (hold or charge), cash, e-Transfer, or none (waived or not needed).';
comment on column bookings.agreement_on_paper is 'The renter signs on paper (0129): no signing email; a task asks for the scan.';

alter table payments drop constraint if exists payments_method_check;
alter table payments add constraint payments_method_check
  check (method in ('card', 'pre_authorized_debit', 'e_transfer', 'bank_transfer', 'cheque', 'cash', 'other', 'platform_payout', 'insurer'));
alter table manual_payments drop constraint if exists manual_payments_method_check;
alter table manual_payments add constraint manual_payments_method_check
  check (method in ('e_transfer', 'cheque', 'cash', 'bank_transfer', 'other', 'platform_payout', 'insurer'));
alter table manual_payments add column if not exists covers text;
alter table manual_payments drop constraint if exists manual_payments_covers_check;
alter table manual_payments add constraint manual_payments_covers_check check (covers in ('rental', 'deposit', 'fees', 'later'));
comment on column manual_payments.covers is 'Which part of the booking the payment covers (0129): the rental, the deposit, fees or a later charge.';

alter table deposits drop constraint if exists deposits_method_check;
alter table deposits add constraint deposits_method_check check (method in ('card_hold', 'charged', 'carried_over', 'offline'));
alter table deposits add column if not exists paid_method text;
alter table deposits drop constraint if exists deposits_paid_method_check;
alter table deposits add constraint deposits_paid_method_check check (paid_method in ('cash', 'e_transfer') and method = 'offline' or paid_method is null and method <> 'offline');
comment on column deposits.paid_method is 'A deposit taken in cash or by e-Transfer (method offline, 0129): it is returned the same way, with a receipt.';

alter table program_settings
  add column if not exists e_transfer_email text,
  add column if not exists stripe_moto_enabled boolean not null default false;
comment on column program_settings.e_transfer_email is 'Where renters send an e-Transfer (0129); empty: the public email of Site settings.';
comment on column program_settings.stripe_moto_enabled is 'Staff may type a card the renter reads out (mail or telephone order). Off: only the renter enters a card, on their phone or on the staff device. Turn on only after Stripe enables MOTO on the account.';

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('paper_agreement_scan', 'cs', 'Upload the scan of the agreement signed on paper', 'normal', 'business_days', 1, 1, null,
   'The renter signed on paper (a rental added by hand): record the signature with the scan on the booking, Drivers and documents.'),
  ('return_deposit_offline', 'finance', 'Give the deposit back the way it came', 'high', 'business_days', 2, 3, null,
   'The deposit was paid in cash or by e-Transfer: give back the amount released, then press Returned on the booking (Money) with the reference.'),
  ('confirm_offline_booking', 'cs', 'Confirm a booking paid another way', 'high', 'opening_minutes', 60, 1, null,
   'The renter approved the offer and signed; the rental is paid by e-Transfer, cash, cheque, platform or insurer. Record the payment on the booking, then press Confirm the booking.')
on conflict (task_type) do nothing;

-- Payment requests (5): one per pay link or card hand-over. The renter (or the staff device handed to them) opens
-- /pay/<token>; the token is stored as its SHA-256. kind: charge (a part of the booking), hold (the deposit, captured
-- later or released), setup (save the card, no money).
create table if not exists payment_requests (
  id              uuid primary key default gen_random_uuid(),
  booking_id      uuid not null references bookings (id),
  renter_id       uuid references renters (id),
  kind            text not null check (kind in ('charge', 'hold', 'setup')),
  covers          text not null check (covers in ('rental', 'deposit', 'fees', 'later', 'card')),
  amount_cents    bigint not null default 0 check (amount_cents >= 0),
  reason          text,
  token_sha256    text not null unique,
  channel         text not null check (channel in ('device', 'text', 'email', 'link')),
  status          text not null default 'open' check (status in ('open', 'paid', 'cancelled', 'expired', 'failed')),
  processor_intent_id text,
  payment_id      uuid references payments (id),
  expires_at      timestamptz not null,
  created_by      uuid not null references users (id),
  created_at      timestamptz not null default now(),
  completed_at    timestamptz,
  last_error      text,
  check ((kind = 'setup') = (amount_cents = 0)),
  check (kind <> 'hold' or covers = 'deposit'),
  check (kind <> 'setup' or covers = 'card')
);
create index if not exists payment_requests_booking_idx on payment_requests (booking_id, created_at desc);
alter table payment_requests enable row level security;
create policy admin_all on payment_requests for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_payment_requests after insert or update or delete on payment_requests for each row execute function app.audit_row();
comment on table payment_requests is 'Card payments staff start from the booking (0129): a pay link texted or emailed to the renter, or the staff device handed to the renter. The card is entered only in Stripe''s own form; nothing of the card reaches CarmaCars but its brand and last four digits.';

-- ================================================================ 2. notifications: a request staff made, a quiet offer, email only
-- app.offer_direct: the request is part of an offer staff send now (no "request received" to the renter or staff).
-- app.offer_quiet: the offer is saved and sent without telling the renter (staff tell them their own way).
-- app.offer_email_only: the renter gets the offer by email only (staff text the link themselves).
select pg_temp.patch_fn('app.ntf_booking_events_after()'::regprocedure,
  $o$  if new.kind = 'requested' then$o$,
  $n$  if new.kind = 'requested' and coalesce(current_setting('app.offer_direct', true), '') = 'on' then
    null;
  elsif new.kind = 'requested' then$n$);
select pg_temp.patch_fn('app.ntf_booking_events_after()'::regprocedure,
  $o$  elsif new.kind = 'offer_sent' then
    perform app.ntf_emit('renter_offer_ready', 'booking', new.booking_id, 'v' || coalesce(new.offer_version, 0),
                         jsonb_build_object('booking_id', new.booking_id, 'offer_version', new.offer_version));$o$,
  $n$  elsif new.kind = 'offer_sent' and coalesce(current_setting('app.offer_quiet', true), '') = 'on' then
    null;
  elsif new.kind = 'offer_sent' then
    perform app.ntf_emit('renter_offer_ready', 'booking', new.booking_id, 'v' || coalesce(new.offer_version, 0),
                         jsonb_build_object('booking_id', new.booking_id, 'offer_version', new.offer_version)
                         || case when coalesce(current_setting('app.offer_email_only', true), '') = 'on' then jsonb_build_object('_email_only', true) else '{}'::jsonb end);$n$);
-- the withdrawal that goes with an edit in place is not news to the renter: the revised offer is
select pg_temp.patch_fn('app.ntf_booking_events_after()'::regprocedure,
  $o$  elsif new.kind in ('offer_withdrawn', 'pushed_back') then$o$,
  $n$  elsif new.kind = 'offer_withdrawn' and coalesce(current_setting('app.offer_revising', true), '') = 'on' then
    null;
  elsif new.kind in ('offer_withdrawn', 'pushed_back') then$n$);
select pg_temp.patch_fn('app.notify_route()'::regprocedure,
  $o$  v_ch := r ->> 'channel';
  new.channel := v_ch;$o$,
  $n$  v_ch := r ->> 'channel';
  -- staff chose email for this message (0129): no text, whatever the person's own choice
  if coalesce((new.payload ->> '_email_only')::boolean, false) then new.channel := 'email'; return new; end if;
  new.channel := v_ch;$n$);

-- staff wording: one name for the Protection Plan
select pg_temp.patch_fn('app.va_guard_booking_edit(text,jsonb)'::regprocedure,
  $o$'Only customer service or an Admin prices coverage'$o$, $n$'Only customer service or an Admin changes the Protection Plan price'$n$);
select pg_temp.patch_fn('app.set_coverage_price(uuid,uuid,bigint,text)'::regprocedure,
  $o$'Customer service or an Admin prices coverage'$o$, $n$'Customer service or an Admin changes the Protection Plan price'$n$);
select pg_temp.patch_fn('app.set_coverage_price(uuid,uuid,bigint,text)'::regprocedure,
  $o$'Booking % is %: coverage is priced on a request (withdraw an offer first)'$o$, $n$'Booking % is %: the Protection Plan price is set on a request (edit the offer in place, or withdraw an offer first)'$n$);
select pg_temp.patch_fn('app.set_coverage_price(uuid,uuid,bigint,text)'::regprocedure,
  $o$'Coverage priced for this booking'$o$, $n$'Protection Plan price set for this booking'$n$);
update fee_types set label = 'Protection Plan' where code = 'coverage_sold' and label is distinct from 'Protection Plan';

create or replace function app.payment_method_label(p_method text) returns text
language sql immutable as $$
  select case p_method when 'e_transfer' then 'e-Transfer' when 'cheque' then 'cheque' when 'cash' then 'cash' when 'bank_transfer' then 'bank transfer'
                       when 'card' then 'card' when 'pre_authorized_debit' then 'pre-authorized debit' when 'other' then 'another way'
                       when 'platform_payout' then 'platform payout' when 'insurer' then 'the insurer' else p_method end
$$;

-- ================================================================ 3. who may do what
-- send an offer (with or without a request) and edit one: an Admin, customer service, sales
create or replace function app.offer_role(p_user uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when app.user_is_admin(p_user) then 'admin'
              when app.user_va_has(p_user, 'cs') then 'cs'
              when app.user_va_has(p_user, 'sales') then 'sales' end
$$;

-- record a payment received another way: an Admin, Finance within the single limit (0044), and customer service or
-- sales within the single limit when Program settings let assistants take "paid another way" on rentals (0058)
create or replace function app.booking_payment_allowed(p_by uuid, p_amount bigint) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when app.user_is_admin(p_by) then null
    when app.user_va_has(p_by, 'finance') or (app.user_va_has(p_by, 'cs', 'sales') and 'other_way' = any ((app.settings()).manual_rental_va_payment_modes))
      then case when p_amount > coalesce((select sp.single_limit_cents from staff_profiles sp where sp.user_id = p_by), 0)
                then format('%s is above your single limit of %s: an Admin records it', app.fmt_money(p_amount),
                            app.fmt_money(coalesce((select sp.single_limit_cents from staff_profiles sp where sp.user_id = p_by), 0))) end
    else 'Only an Admin, Finance, customer service or sales records a payment received another way'
  end
$$;

-- start a card payment on the renter's phone or the staff device: every staff member who deals with renters
create or replace function app.card_collect_allowed(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'sales', 'finance') or app.user_is_field(p_by)
$$;

-- ================================================================ 4. the preview of an offer that is out
-- 0030's preview applies the edit to a request; an offer that is out is previewed as if it were open for editing.
create or replace function app.admin_booking_preview(p_admin uuid, p_booking uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
begin
  begin
    perform app.offer_reopen_for_edit(p_booking, p_admin, true);
    perform app.admin_apply_booking_edit(p_admin, p_booking, p);
    v_out := jsonb_build_object('ok', true, 'booking', app.admin_booking_json(p_booking),
                                'available', (select app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id) from bookings b where b.id = p_booking));
    raise exception using errcode = 'P0001', message = 'admin-preview-rollback';
  exception when others then
    if sqlerrm <> 'admin-preview-rollback' then
      v_out := jsonb_build_object('ok', false, 'error', sqlerrm);
    end if;
  end;
  return v_out;
end $$;

-- An offer that is out goes back to "requested" for its edit, without telling the renter (the revised offer will).
-- p_preview: inside a preview (rolled back), nothing is logged.
create or replace function app.offer_reopen_for_edit(p_booking uuid, p_by uuid, p_preview boolean default false) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status not in ('offered', 'pending_payment') then return b.status::text; end if;
  if b.status = 'pending_payment' and exists (select 1 from payments x where x.booking_id = b.id and x.purpose = 'booking_total' and x.kind = 'charge' and x.status = 'succeeded') then
    raise exception 'Booking % has a payment for its total already: change it with a booking change after it is confirmed, or refund first', b.booking_number using errcode = '23514';
  end if;
  update booking_offers set status = 'superseded', responded_at = now() where booking_id = b.id and status in ('sent', 'approved');
  update bookings set status = 'requested', offer_approved_version = null, offer_approved_at = null, offer_approved_by = null where id = b.id;
  -- an agreement opened for the approved version is for a price that is changing: the renter signs the revised one
  if b.status = 'pending_payment' then
    update rental_agreements set status = 'voided', voided_at = now(), void_reason = 'The offer was revised before payment'
     where booking_id = b.id and status = 'open';
  end if;
  if not p_preview then
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, 'requested', b.current_offer_version, 'Offer opened for editing', p_by, 'staff');
    perform app.resolve_tasks(array['confirm_offline_booking'], b.id, p_by, 'The offer was revised');
  end if;
  return b.status::text;
end $$;

-- ================================================================ 5. an offer edited in place
-- p: booking, the review screen's edit (changes, places, fee_terms, coverage_cents, promo_code, addons, blocks_calendar),
-- internal_note, message, expires_at, notify (default true), channels {email, text}, rental_pay_method, deposit_pay_method.
create or replace function app.offer_revise(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_role text := app.offer_role(p_by);
  b bookings;
  v_was text;
  v_version integer;
  v_notify boolean := coalesce((p ->> 'notify')::boolean, true);
  v_out jsonb;
  v_before jsonb;
begin
  if v_role is null then raise exception 'An Admin, customer service or sales edits an offer' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = p ->> 'booking' for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status not in ('requested', 'offered', 'pending_payment') then
    raise exception 'Booking % is %: change a confirmed booking with Propose a change', b.booking_number, b.status using errcode = '23514';
  end if;
  if v_role = 'sales' and b.status = 'pending_payment' then raise exception 'Sales works on requests and offers only' using errcode = '42501'; end if;
  if v_role <> 'admin' then
    perform app.va_guard_booking_edit(v_role, p);
    perform app.va_delegate(p_by);
  end if;
  v_before := jsonb_build_object('vehicle', app.vehicle_name(b.vehicle_id), 'pickup_at', b.pickup_at, 'return_at', b.return_at,
                                 'total_cents', b.total_due_at_booking_cents, 'deposit_cents', b.deposit_cents);
  perform set_config('app.offer_revising', 'on', true);
  v_was := app.offer_reopen_for_edit(b.id, p_by);
  perform app.admin_apply_booking_edit(p_by, b.id, p);
  if p ? 'internal_note' then update bookings set notes = nullif(btrim(p ->> 'internal_note'), '') where id = b.id; end if;
  perform app.booking_set_pay_methods(b.id, p_by, p);
  if v_was in ('offered', 'pending_payment') or coalesce((p ->> 'send')::boolean, false) then
    perform app.offer_channels_begin(v_notify, p -> 'channels');
    v_version := app.send_offer(b.id, p_by, nullif(btrim(p ->> 'message'), ''), coalesce((p ->> 'expires_at')::timestamptz, b.offer_expires_at, now() + make_interval(hours => (app.settings()).offer_expiry_hours)));
    perform app.offer_channels_end();
  end if;
  perform set_config('app.offer_revising', '', true);
  select * into b from bookings where id = b.id;
  v_out := jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'version', v_version, 'was', v_was,
    'notified', v_version is not null and v_notify, 'text', case when v_version is not null and v_notify then app.offer_text(b.id, p_by, p -> 'channels') end,
    'before', v_before,
    'after', jsonb_build_object('vehicle', app.vehicle_name(b.vehicle_id), 'pickup_at', b.pickup_at, 'return_at', b.return_at,
                                'total_cents', b.total_due_at_booking_cents, 'deposit_cents', b.deposit_cents));
  return v_out;
end $$;

-- the renter hears of an offer by email, by text, both or not at all
create or replace function app.offer_channels_begin(p_notify boolean, p_channels jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_email boolean := coalesce((p_channels ->> 'email')::boolean, true);
begin
  if not p_notify or not v_email then perform set_config('app.offer_quiet', 'on', true); end if;
  -- staff text the link themselves (app.offer_text): the email goes alone
  if p_notify and v_email and coalesce((p_channels ->> 'text')::boolean, false) then perform set_config('app.offer_email_only', 'on', true); end if;
end $$;
create or replace function app.offer_channels_end() returns void
language sql security definer set search_path = public, app as $$
  select set_config('app.offer_quiet', '', true), set_config('app.offer_email_only', '', true);
$$;

-- The offer's text to the renter's phone (Quo), when staff chose text: the Program settings wording of 0085 with the link.
create or replace function app.offer_text(p_booking uuid, p_by uuid, p_channels jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  b bookings;
  rn renters;
  v_body text;
  o phone_outbox;
begin
  if not coalesce((p_channels ->> 'text')::boolean, false) then return null; end if;
  select * into b from bookings where id = p_booking;
  select * into rn from renters where id = b.renter_id;
  if app.phone_e164(rn.mobile) is null then
    return jsonb_build_object('ok', false, 'reason', 'The renter has no mobile number on file: the text was not sent');
  end if;
  v_body := s.phone_sms_offer_sent_text;
  v_body := replace(v_body, '{first_name}', coalesce(nullif(split_part(btrim(rn.legal_name), ' ', 1), ''), 'there'));
  v_body := replace(v_body, '{booking}', b.booking_number);
  v_body := replace(v_body, '{car}', app.vehicle_name(b.vehicle_id));
  v_body := replace(v_body, '{pickup}', app.fmt_at(b.pickup_at));
  v_body := replace(v_body, '{return}', app.fmt_at(b.return_at));
  v_body := replace(v_body, '{amount}', app.fmt_money(b.renter_due_at_booking_cents));
  v_body := replace(v_body, '{link}', app.ntf_link('booking_offer', jsonb_build_object('booking_number', b.booking_number)));
  o := app.phone_outbox_put(rn.mobile, v_body, 'staff', b.id, rn.id, 'offer_sent', null, 'offer_text:' || b.id || ':v' || b.current_offer_version, now(), 'queued', p_by);
  return jsonb_build_object('ok', o.status <> 'skipped', 'status', o.status, 'reason', o.status_reason, 'to', app.phone_display(o.to_number));
end $$;

-- how the rental and the deposit are paid, from the offer screen or the review screen
create or replace function app.booking_set_pay_methods(p_booking uuid, p_by uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_rental text := nullif(p ->> 'rental_pay_method', '');
  v_deposit text := nullif(p ->> 'deposit_pay_method', '');
begin
  if v_rental is null and v_deposit is null then return; end if;
  select * into b from bookings where id = p_booking for update;
  if v_rental is not null and v_rental not in ('card', 'e_transfer', 'cash', 'cheque', 'bank_transfer', 'platform_payout', 'insurer') then
    raise exception 'Choose how the rental is paid: card, e-Transfer, cash, cheque, bank transfer, platform payout or the insurer' using errcode = '22023';
  end if;
  if v_deposit is not null and v_deposit not in ('card', 'cash', 'e_transfer', 'none') then
    raise exception 'Choose how the deposit is taken: card, cash, e-Transfer or no deposit' using errcode = '22023';
  end if;
  if v_deposit = 'none' and b.deposit_cents > 0 and not app.user_is_admin(p_by) then
    raise exception 'Only an Admin takes no deposit: choose card, cash or e-Transfer' using errcode = '42501';
  end if;
  if (v_rental is distinct from b.rental_pay_method and v_rental is not null) or (v_deposit is distinct from b.deposit_pay_method and v_deposit is not null) then
    update bookings set rental_pay_method = coalesce(v_rental, rental_pay_method), deposit_pay_method = coalesce(v_deposit, deposit_pay_method) where id = b.id;
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
      format('Paid by: rental %s, deposit %s', app.payment_method_label(coalesce(v_rental, b.rental_pay_method)),
             case coalesce(v_deposit, b.deposit_pay_method) when 'card' then 'card hold or charge' when 'none' then 'none' else app.payment_method_label(coalesce(v_deposit, b.deposit_pay_method)) end),
      p_by, 'staff');
  end if;
end $$;

-- ================================================================ 6. an offer without a request
-- p: renter_id, or renter {full_name, email, mobile, date_of_birth, licence_class}: a renter already on file with the
-- same email or mobile is used (never a second one); vehicle_id, pickup_at, return_at, pickup_location / return_location
-- ({kind, address, distance_km, airport_code}), coverage_option, sales_choice, note (internal), rental_charge_cents with
-- price_tax and price_reason, and the review screen's edit (changes, fee_terms, coverage_cents, promo_code, addons,
-- blocks_calendar), deposit_cents (an Admin), rental_pay_method, deposit_pay_method, message, expires_at, notify, channels.
create or replace function app.staff_offer_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_role text := app.offer_role(p_by);
  r jsonb := coalesce(p -> 'renter', '{}'::jsonb);
  rn renters;
  v_email text := lower(nullif(btrim(coalesce(r ->> 'email', '')), ''));
  v_mobile text := nullif(btrim(coalesce(r ->> 'mobile', '')), '');
  v_q jsonb;
  v_out jsonb;
  b bookings;
  v_edit jsonb;
  v_version integer;
  v_notify boolean := coalesce((p ->> 'notify')::boolean, true);
  v_changes jsonb := coalesce(p -> 'changes', '{}'::jsonb);
begin
  if v_role is null then raise exception 'An Admin, customer service or sales sends an offer' using errcode = '42501'; end if;
  -- the customer: the one on file, by id, email or mobile
  if nullif(p ->> 'renter_id', '') is not null then
    select * into rn from renters where id = (p ->> 'renter_id')::uuid;
    if rn.id is null then raise exception 'That customer is no longer on file: search again' using errcode = 'P0002'; end if;
  else
    rn := app.renter_match(v_email, v_mobile);
  end if;
  if rn.id is not null then
    if rn.is_blocked then raise exception '% is blocked from renting: an Admin must lift the block first', rn.legal_name using errcode = '23514'; end if;
    v_q := jsonb_build_object('full_name', rn.legal_name, 'email', coalesce(rn.email, (select u.email from users u where u.id = rn.user_id)),
                              'mobile', coalesce(rn.mobile, v_mobile), 'date_of_birth', coalesce(rn.date_of_birth::text, r ->> 'date_of_birth'),
                              'licence_class', coalesce((select d.licence_class from drivers d where d.renter_id = rn.id and d.is_account_holder), r ->> 'licence_class', 'G'));
    if rn.mobile is null and v_mobile is not null then update renters set mobile = v_mobile where id = rn.id; end if;
  else
    if nullif(btrim(coalesce(r ->> 'full_name', '')), '') is null then raise exception 'Enter the customer''s full legal name' using errcode = '22023'; end if;
    if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter the customer''s email address (like name@example.com): the offer link goes there' using errcode = '22023'; end if;
    if v_mobile is null then raise exception 'Enter the customer''s mobile number' using errcode = '22023'; end if;
    if nullif(r ->> 'date_of_birth', '') is null then raise exception 'Enter the customer''s date of birth: the driver''s age decides the car and the young driver fee' using errcode = '22023'; end if;
    v_q := jsonb_build_object('full_name', btrim(r ->> 'full_name'), 'email', v_email, 'mobile', v_mobile, 'date_of_birth', r ->> 'date_of_birth',
                              'licence_class', coalesce(nullif(r ->> 'licence_class', ''), 'G'));
  end if;
  if coalesce(v_q ->> 'date_of_birth', '') = '' then raise exception 'Enter the customer''s date of birth: it is not on file' using errcode = '22023'; end if;
  if v_role <> 'admin' then perform app.va_guard_booking_edit(v_role, p); perform app.va_delegate(p_by); end if;
  if v_role <> 'admin' and (p ? 'deposit_cents' or v_changes ? 'deposit_cents') then raise exception 'Only an Admin changes the deposit' using errcode = '42501'; end if;

  -- the request, as the quote form makes it (0058), with nothing sent to anyone yet
  perform set_config('app.offer_direct', 'on', true);
  v_out := app.staff_quote_create(p_by, v_q || jsonb_build_object(
    'vehicle_id', p ->> 'vehicle_id', 'pickup_at', p ->> 'pickup_at', 'return_at', p ->> 'return_at',
    'source', case when p ->> 'source' in ('phone', 'email', 'whatsapp') then p ->> 'source' else 'phone' end,
    'coverage_option', nullif(p ->> 'coverage_option', ''), 'note', nullif(btrim(coalesce(p ->> 'request_note', '')), ''),
    'sales_choice', coalesce(nullif(p ->> 'sales_choice', ''), case when v_role = 'admin' then 'for_carmacars' end),
    'rental_charge_cents', p -> 'rental_charge_cents', 'price_tax', p -> 'price_tax', 'price_reason', p -> 'price_reason',
    'pickup_method', case when p #>> '{pickup_location,kind}' in ('delivery', 'airport') then 'delivered' else 'collected' end,
    'return_method', case when p #>> '{return_location,kind}' in ('delivery', 'airport') then 'picked_up' else 'returned' end,
    'pickup_location', p -> 'pickup_location', 'return_location', p -> 'return_location', 'addons', p -> 'addons'));
  perform set_config('app.offer_direct', '', true);
  select * into b from bookings where id = (v_out ->> 'booking_id')::uuid;
  update bookings set request_details = coalesce(request_details, '{}'::jsonb) || jsonb_build_object('offer_without_request', true, 'source', coalesce(p ->> 'source', 'phone'))
   where id = b.id;
  -- the rest of the price, as on the review screen
  v_edit := jsonb_strip_nulls(jsonb_build_object('changes', case when p ? 'deposit_cents' then v_changes || jsonb_build_object('deposit_cents', (p ->> 'deposit_cents')::bigint) else v_changes end,
    'fee_terms', p -> 'fee_terms', 'coverage_cents', p -> 'coverage_cents', 'coverage_reason', p -> 'coverage_reason',
    'promo_code', p -> 'promo_code', 'blocks_calendar', p -> 'blocks_calendar', 'blocks_calendar_reason', p -> 'blocks_calendar_reason'));
  if v_edit <> '{}'::jsonb and v_edit <> '{"changes": {}}'::jsonb then perform app.admin_apply_booking_edit(p_by, b.id, v_edit); end if;
  if nullif(btrim(coalesce(p ->> 'note', '')), '') is not null then update bookings set notes = btrim(p ->> 'note') where id = b.id; end if;
  perform app.booking_set_pay_methods(b.id, p_by, p);
  if coalesce((p ->> 'draft')::boolean, false) then
    select * into b from bookings where id = b.id;
    return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'renter_id', b.renter_id, 'draft', true);
  end if;
  perform app.offer_channels_begin(v_notify, p -> 'channels');
  v_version := app.send_offer(b.id, p_by, nullif(btrim(coalesce(p ->> 'message', '')), ''),
                              coalesce((p ->> 'expires_at')::timestamptz, now() + make_interval(hours => (app.settings()).offer_expiry_hours)));
  perform app.offer_channels_end();
  select * into b from bookings where id = b.id;
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'renter_id', b.renter_id, 'version', v_version,
    'total_cents', b.total_due_at_booking_cents, 'due_cents', b.renter_due_at_booking_cents, 'expires_at', b.offer_expires_at,
    'renter_existing', rn.id is not null, 'notified', v_notify, 'sales_sourced', b.sales_sourced, 'price_flags', to_jsonb(b.price_flags),
    'text', case when v_notify then app.offer_text(b.id, p_by, p -> 'channels') end);
end $$;

-- The offer as the renter will see it, before it is sent: everything made and priced, then rolled back.
create or replace function app.staff_offer_preview(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
  v_id uuid;
begin
  begin
    -- the price does not depend on who found the client: an assistant sees it before choosing
    v_id := (app.staff_offer_create(p_by, p || jsonb_build_object('draft', true, 'sales_choice', coalesce(nullif(p ->> 'sales_choice', ''), 'for_carmacars'))) ->> 'booking_id')::uuid;
    v_out := jsonb_build_object('ok', true, 'booking', app.admin_booking_json(v_id),
      'available', (select app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id) from bookings b where b.id = v_id),
      'renter', (select jsonb_build_object('id', r.id, 'legal_name', r.legal_name, 'existing', r.created_at < now() - interval '1 second')
                   from bookings b join renters r on r.id = b.renter_id where b.id = v_id));
    raise exception using errcode = 'P0001', message = 'offer-preview-rollback';
  exception when others then
    if sqlerrm <> 'offer-preview-rollback' then v_out := jsonb_build_object('ok', false, 'error', sqlerrm); end if;
  end;
  return v_out;
end $$;

-- A customer on file: by email when one is typed (one person, one record), else by mobile (compared as digits, the last
-- ten). A mobile shared by two people with different emails makes two customers; the offer screen shows the one on
-- file with that phone so staff can choose it.
create or replace function app.renter_match(p_email text, p_mobile text) returns renters
language sql stable security definer set search_path = public, app as $$
  select r.* from renters r left join users u on u.id = r.user_id
   where case when nullif(lower(btrim(coalesce(p_email, ''))), '') is not null
              then lower(r.email) = lower(btrim(p_email)) or lower(u.email) = lower(btrim(p_email))
              else length(regexp_replace(coalesce(p_mobile, ''), '\D', '', 'g')) >= 10
                   and right(regexp_replace(coalesce(r.mobile, u.phone, ''), '\D', '', 'g'), 10) = right(regexp_replace(p_mobile, '\D', '', 'g'), 10) end
   order by r.created_at
   limit 1
$$;

-- The customer search of the offer screen and the rental form: by name, email or phone, with the card on file and the
-- number of rentals (staff see who they deal with; the ids stay on the server).
create or replace function app.staff_find_customers(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_q text := btrim(coalesce(p ->> 'q', ''));
  v_digits text := regexp_replace(v_q, '\D', '', 'g');
begin
  if not (app.offer_role(p_by) is not null or app.manual_rental_role(p_by) is not null) then raise exception 'Not permitted' using errcode = '42501'; end if;
  if length(v_q) < 3 then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(x order by x ->> 'legal_name') from (
    select jsonb_build_object('id', r.id, 'legal_name', r.legal_name, 'email', coalesce(r.email, u.email), 'mobile', coalesce(r.mobile, u.phone),
             'date_of_birth', r.date_of_birth, 'is_blocked', r.is_blocked, 'licence_class', (select d.licence_class from drivers d where d.renter_id = r.id and d.is_account_holder limit 1),
             'bookings', (select count(*) from bookings b where b.renter_id = r.id and b.status in ('confirmed', 'on_rent', 'returned', 'closed')),
             'card', (select jsonb_build_object('brand', pm.card_brand, 'last4', pm.card_last4) from payment_methods pm where pm.renter_id = r.id and pm.status = 'active' order by pm.created_at desc limit 1)) x
      from renters r left join users u on u.id = r.user_id
     where r.legal_name ilike '%' || v_q || '%' or coalesce(r.email, u.email, '') ilike '%' || v_q || '%'
        or (length(v_digits) >= 4 and regexp_replace(coalesce(r.mobile, u.phone, ''), '\D', '', 'g') like '%' || v_digits || '%')
     limit 12) q), '[]'::jsonb);
end $$;

-- The offer screen: the cars with their rates and whether each is free for the dates, the settings it needs.
create or replace function app.staff_offer_form(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_from timestamptz := nullif(p ->> 'pickup_at', '')::timestamptz;
  v_to timestamptz := nullif(p ->> 'return_at', '')::timestamptz;
  v_role text := app.offer_role(p_by);
begin
  if v_role is null then raise exception 'An Admin, customer service or sales sends an offer' using errcode = '42501'; end if;
  return jsonb_build_object('role', v_role, 'offer_hours', s.offer_expiry_hours, 'min_notice_minutes', s.booking_min_notice_minutes,
    'km_choices', coalesce((select jsonb_agg(k.km_per_day order by k.km_per_day) from km_allowance_choices k where k.is_active), '[]'::jsonb),
    'text_enabled', s.phone_enabled and s.phone_sms_offer_sent,
    'cars', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'car_code', v.car_code,
              'daily_rate_cents', rc.daily_rate_cents, 'weekly_rate_cents', rc.weekly_rate_cents, 'deposit_cents', rc.deposit_cents,
              'free', case when v_from is not null and v_to is not null and v_to > v_from then app.vehicle_is_available(v.id, v_from, v_to) end)
              order by v.fleet_number nulls last, v.make, v.model, v.year)
              from vehicles v left join rate_cards rc on rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())
             where app.vehicle_bookable(v.id)), '[]'::jsonb));
end $$;

-- ================================================================ 7. payments by part and method
-- p: booking, covers (rental | deposit | fees | later), method (e_transfer | cash | cheque | bank_transfer | platform_payout
-- | insurer | other), amount_cents (empty: what is open for that part), reference, received_on, note.
create or replace function app.record_booking_payment(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_covers text := coalesce(nullif(p ->> 'covers', ''), 'rental');
  v_method text := coalesce(nullif(p ->> 'method', ''), 'e_transfer');
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_ref text := nullif(btrim(coalesce(p ->> 'reference', '')), '');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_on date := coalesce(nullif(p ->> 'received_on', '')::date, app.today());
  v_refuse text;
  v_pay uuid;
  v_mp uuid;
  v_open bigint;
  v_out jsonb;
  v_conf jsonb;
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v_covers not in ('rental', 'deposit', 'fees', 'later') then raise exception 'Choose what the payment covers: the rental, the deposit, fees or a later charge' using errcode = '22023'; end if;
  if v_method not in ('e_transfer', 'cash', 'cheque', 'bank_transfer', 'platform_payout', 'insurer', 'other') then
    raise exception 'Choose how it was paid: e-Transfer, cash, cheque, bank transfer, platform payout, the insurer or another way. A card is paid through Collect a card' using errcode = '22023';
  end if;
  if b.status in ('cancelled', 'declined', 'expired') then raise exception 'Booking % is %: nothing is owed on it', b.booking_number, b.status using errcode = '23514'; end if;
  if v_covers = 'deposit' then
    if v_method not in ('cash', 'e_transfer') then raise exception 'A deposit is taken by card, in cash or by e-Transfer' using errcode = '22023'; end if;
    return app.record_offline_deposit(p_by, b.id, v_method, v_amount, v_ref, v_on, v_note);
  end if;
  if v_ref is not null then
    select m.id into v_mp from manual_payments m where m.booking_id = b.id and m.method = v_method and lower(m.reference) = lower(v_ref) and m.voided_at is null;
    if v_mp is not null then return jsonb_build_object('ok', true, 'repeat', true, 'id', v_mp); end if;
  end if;
  v_open := app.booking_part_open(b.id, v_covers);
  v_amount := coalesce(v_amount, v_open);
  if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount received: nothing is open for that part' using errcode = '22023'; end if;
  v_refuse := app.booking_payment_allowed(p_by, v_amount);
  if v_refuse is not null then raise exception '%', v_refuse using errcode = '42501'; end if;
  if v_method in ('e_transfer', 'cheque', 'bank_transfer') and (v_ref is null or length(v_ref) < 3) then
    raise exception '%', case v_method when 'cheque' then 'Enter the cheque number' when 'e_transfer' then 'Enter the e-Transfer reference number' else 'Enter the reference of the bank transfer' end using errcode = '22023';
  end if;
  if v_method = 'other' and v_note is null then raise exception 'Say how it was paid in the note' using errcode = '22023'; end if;
  if v_on > app.today() then raise exception 'The date received cannot be in the future' using errcode = '22023'; end if;
  insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_by)
  values (b.id, b.renter_id, case v_covers when 'later' then 'post_rental' else 'booking_total' end, 'charge', v_method, v_amount, 'succeeded',
          app.local_midnight(v_on) + interval '12 hours', p_by)
  returning id into v_pay;
  insert into payment_processor_details (payment_id, processor, processor_payment_id, raw)
  values (v_pay, 'offline', v_method || ':' || coalesce(v_ref, v_pay::text), jsonb_strip_nulls(jsonb_build_object('reference', v_ref, 'received_on', v_on, 'note', v_note, 'recorded_by', p_by, 'covers', v_covers)));
  insert into manual_payments (payment_id, target, booking_id, renter_id, method, amount_cents, received_on, reference, note, recorded_by, covers)
  values (v_pay, 'booking', b.id, b.renter_id, v_method, v_amount, v_on, v_ref, v_note, p_by, v_covers)
  returning id into v_mp;
  -- the lines it pays: the booking's lines of that part once it is paid in full, a later charge's statement lines
  perform app.booking_tie_lines(b.id, v_covers, v_pay);
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
    format('%s received by %s for the %s%s', app.fmt_money(v_amount), app.payment_method_label(v_method),
           case v_covers when 'rental' then 'rental' when 'fees' then 'fees' else 'later charges' end, coalesce(' (' || v_ref || ')', '')), p_by, 'staff',
    jsonb_build_object('payment_id', v_pay, 'covers', v_covers, 'method', v_method, 'amount_cents', v_amount));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'record_booking_payment', 'bookings', b.id::text, jsonb_build_object('payment_id', v_pay, 'manual_payment_id', v_mp, 'covers', v_covers, 'method', v_method,
          'amount_cents', v_amount, 'reference', v_ref, 'received_on', v_on));
  -- the receipt (a payment that confirms an online booking has its own; this one is offline)
  perform app.ntf_emit('renter_payment_receipt', 'payment', v_pay, 'succeeded', jsonb_build_object('booking_id', b.id, 'renter_id', b.renter_id));
  -- paid in full, approved and signed: confirmed now
  if b.status = 'pending_payment' and v_covers in ('rental', 'fees') then
    v_conf := app.confirm_offline_booking(p_by, b.id, false);
  end if;
  v_out := jsonb_build_object('ok', true, 'id', v_mp, 'payment_id', v_pay, 'open_cents', app.booking_part_open(b.id, v_covers), 'confirmed', coalesce((v_conf ->> 'ok')::boolean, false),
                              'confirm', v_conf);
  return v_out;
end $$;

-- What is still open for a part of the booking: the rental and fees at booking (the renter's share), later charges on
-- issued statements. The rental part is the rental charge with its tax and discounts; fees are the other booking lines.
create or replace function app.booking_part_open(p_booking uuid, p_covers text) returns bigint
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_due bigint;
  v_paid bigint;
  v_rental bigint;
begin
  select * into b from bookings where id = p_booking;
  if p_covers = 'later' then
    select coalesce(sum(l.amount_cents + l.hst_cents), 0) into v_due from booking_line_items l
     where l.booking_id = p_booking and l.stage <> 'booking' and l.statement_id is not null and l.payment_id is null and l.voided_at is null and l.charged_to_renter;
    return greatest(v_due, 0);
  end if;
  select coalesce(sum(l.amount_cents + l.hst_cents), 0) into v_rental from booking_line_items l
   where l.booking_id = p_booking and l.stage = 'booking' and l.voided_at is null and l.charged_to_renter
     and l.charge_type in ('rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'discount');
  if b.bill_to <> 'renter' and b.renter_due_at_booking_cents is not null then
    v_rental := least(v_rental, b.renter_due_at_booking_cents);
  end if;
  v_due := case when p_covers = 'rental' then v_rental else greatest(coalesce(b.renter_due_at_booking_cents, b.total_due_at_booking_cents) - v_rental, 0) end;
  select coalesce(sum(m.amount_cents), 0) into v_paid from manual_payments m where m.booking_id = p_booking and m.voided_at is null and m.covers = p_covers;
  -- a card payment of the whole booking (the website's) pays both parts
  if exists (select 1 from payments x where x.booking_id = p_booking and x.purpose = 'booking_total' and x.method = 'card' and x.kind in ('charge', 'capture') and x.status = 'succeeded') then
    return 0;
  end if;
  -- a payment of the whole booking recorded before 0129 (no part named)
  if exists (select 1 from manual_payments m where m.booking_id = p_booking and m.voided_at is null and m.covers is null) then
    v_paid := v_paid + (select coalesce(sum(m.amount_cents), 0) from manual_payments m where m.booking_id = p_booking and m.voided_at is null and m.covers is null)
              * case when p_covers = 'rental' then 1 else 0 end;
  end if;
  return greatest(v_due - v_paid, 0);
end $$;

-- A payment ties the lines it pays (statements and owner revenue read line_items.payment_id).
create or replace function app.booking_tie_lines(p_booking uuid, p_covers text, p_payment uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if p_covers = 'later' then
    update booking_line_items set payment_id = p_payment
     where booking_id = p_booking and stage <> 'booking' and statement_id is not null and payment_id is null and voided_at is null and charged_to_renter
       and app.booking_part_open(p_booking, 'later') = 0;
  elsif app.booking_part_open(p_booking, p_covers) = 0 then
    update booking_line_items set payment_id = p_payment
     where booking_id = p_booking and stage = 'booking' and voided_at is null and charged_to_renter and payment_id is null
       and ((p_covers = 'rental') = (charge_type in ('rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'discount')));
  end if;
end $$;

-- A deposit in cash or by e-Transfer: a payment (purpose deposit) and the deposit row, method offline. It is taken from
-- the approval of the offer to the end of the trip, so it can be taken before pickup.
create or replace function app.record_offline_deposit(p_by uuid, p_booking uuid, p_method text, p_amount bigint, p_ref text, p_on date, p_note text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  d deposits;
  v_pay uuid;
  v_amount bigint;
  v_refuse text;
begin
  select * into b from bookings where id = p_booking for update;
  if b.status not in ('pending_payment', 'confirmed', 'on_rent') then
    raise exception 'Booking % is %: a deposit is taken once the offer is approved, until the end of the trip', b.booking_number, b.status using errcode = '23514';
  end if;
  if b.booking_type = 'owner' or b.deposit_cents = 0 then raise exception 'Booking % has no deposit to take', b.booking_number using errcode = '23514'; end if;
  v_amount := coalesce(p_amount, b.deposit_cents);
  if v_amount <> b.deposit_cents then
    raise exception 'The deposit on % is %: take it in full (an Admin can change the deposit on the booking first)', b.booking_number, app.fmt_money(b.deposit_cents) using errcode = '23514';
  end if;
  v_refuse := app.booking_payment_allowed(p_by, v_amount);
  if v_refuse is not null then raise exception '%', v_refuse using errcode = '42501'; end if;
  if p_method = 'e_transfer' and (p_ref is null or length(p_ref) < 3) then raise exception 'Enter the e-Transfer reference number' using errcode = '22023'; end if;
  select * into d from deposits where booking_id = b.id for update;
  if d.id is not null and d.status not in ('pending', 'failed') then raise exception 'The deposit on % has already been taken', b.booking_number using errcode = '23514'; end if;
  insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_by)
  values (b.id, b.renter_id, 'deposit', 'charge', p_method, v_amount, 'succeeded', app.local_midnight(p_on) + interval '12 hours', p_by)
  returning id into v_pay;
  insert into payment_processor_details (payment_id, processor, processor_payment_id, raw)
  values (v_pay, 'offline', p_method || ':' || coalesce(p_ref, v_pay::text), jsonb_strip_nulls(jsonb_build_object('reference', p_ref, 'received_on', p_on, 'note', p_note, 'recorded_by', p_by, 'covers', 'deposit')));
  insert into manual_payments (payment_id, target, booking_id, renter_id, method, amount_cents, received_on, reference, note, recorded_by, covers)
  values (v_pay, 'booking', b.id, b.renter_id, p_method, v_amount, p_on, p_ref, p_note, p_by, 'deposit');
  insert into deposits as x (booking_id, amount_cents, method, paid_method, status, hold_payment_id, taken_at, captured_cents)
  values (b.id, v_amount, 'offline', p_method, 'captured', v_pay, now(), v_amount)
  on conflict (booking_id) do update set amount_cents = excluded.amount_cents, method = 'offline', paid_method = excluded.paid_method, status = 'captured',
         hold_payment_id = excluded.hold_payment_id, taken_at = excluded.taken_at, hold_expires_at = null, captured_cents = excluded.captured_cents
  returning * into d;
  insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note, created_by)
  values (d.id, 'taken', v_amount, v_pay, app.payment_method_label(p_method), p_by);
  update bookings set deposit_pay_method = p_method where id = b.id and deposit_pay_method is distinct from p_method;
  perform app.resolve_tasks(array['take_deposit', 'deposit_declined'], b.id, p_by, 'Deposit taken by ' || app.payment_method_label(p_method));
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
    format('Deposit of %s taken by %s%s', app.fmt_money(v_amount), app.payment_method_label(p_method), coalesce(' (' || p_ref || ')', '')), p_by, 'staff',
    jsonb_build_object('payment_id', v_pay, 'covers', 'deposit', 'method', p_method));
  perform app.ntf_emit('renter_payment_receipt', 'payment', v_pay, 'succeeded', jsonb_build_object('booking_id', b.id, 'renter_id', b.renter_id));
  return jsonb_build_object('ok', true, 'payment_id', v_pay, 'deposit_id', d.id, 'open_cents', 0);
end $$;

-- A booking whose rental is paid another way: confirmed by staff once the renter approved the current offer, signed (on
-- screen or on paper), and what is due at booking is paid (or billed to the insurer or a platform). The website's own
-- confirmation (0019) needs a card payment; this is the same step for the money that came another way.
create or replace function app.confirm_offline_booking(p_by uuid, p_booking uuid, p_raise boolean default true) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  a rental_agreements;
  v_open bigint;
  v_problem text;
begin
  if app.offer_role(p_by) is null and not app.user_runs_finance(p_by) then raise exception 'Customer service, sales, Finance or an Admin confirms a booking' using errcode = '42501'; end if;
  perform 1 from vehicles where id = (select vehicle_id from bookings where id = p_booking) for no key update;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status <> 'pending_payment' then v_problem := format('Booking %s is %s, not waiting for payment', b.booking_number, replace(b.status::text, '_', ' '));
  elsif b.offer_approved_version is distinct from b.current_offer_version then v_problem := 'The renter has not approved the current offer';
  end if;
  if v_problem is null then
    select * into a from rental_agreements where booking_id = b.id and status in ('signed', 'completed') order by opened_at desc limit 1;
    if a.id is null then v_problem := 'The rental agreement is not signed yet (on screen, or record the paper signature)'; end if;
  end if;
  if v_problem is null and b.rental_pay_method not in ('insurer', 'platform_payout') then
    v_open := app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees');
    if v_open > 0 then v_problem := format('%s is still open: record the payment first', app.fmt_money(v_open)); end if;
  end if;
  if v_problem is null and b.blocks_calendar and not app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id) then
    v_problem := 'The car is no longer free for these dates';
  end if;
  if v_problem is not null then
    if p_raise then raise exception '%', v_problem using errcode = '23514'; end if;
    return jsonb_build_object('ok', false, 'reason', v_problem);
  end if;
  if a.signature_request_id is not null and a.status = 'signed' then
    perform app.complete_signature_request(a.signature_request_id, (select m.payment_id from manual_payments m where m.booking_id = b.id and m.voided_at is null and m.covers in ('rental', 'fees') order by m.recorded_at desc limit 1));
  end if;
  update bookings set status = 'confirmed' where id = b.id;
  perform app.log_booking_event(b.id, 'confirmed', 'pending_payment', 'confirmed', b.offer_approved_version, 'Paid by ' || app.payment_method_label(b.rental_pay_method), p_by, 'staff',
    jsonb_build_object('mode', 'offline', 'method', b.rental_pay_method));
  perform app.resolve_tasks(array['confirm_offline_booking'], b.id, p_by, 'Confirmed');
  return jsonb_build_object('ok', true, 'status', 'confirmed', 'booking_number', b.booking_number);
end $$;

-- The confirmation rule (0011, 0025): a booking is confirmed when its payment succeeded and a card is on file. A rental
-- billed to the insurer or paid through a platform waits for no payment at booking; a deposit taken in cash or by
-- e-Transfer (or none) needs no card on file.
select pg_temp.patch_fn('app.booking_before_write()'::regprocedure,
  $o$         and not exists (
           select 1 from payments p where p.booking_id = new.id and p.purpose = 'booking_total'
              and p.kind = 'charge' and p.status = 'succeeded') then
        raise exception 'A booking is confirmed only when payment succeeds' using errcode = '23514';$o$,
  $n$         and new.rental_pay_method not in ('insurer', 'platform_payout')
         and not exists (
           select 1 from payments p where p.booking_id = new.id and p.purpose = 'booking_total'
              and p.kind = 'charge' and p.status = 'succeeded') then
        raise exception 'A booking is confirmed only when payment succeeds' using errcode = '23514';$n$);
select pg_temp.patch_fn('app.booking_before_write()'::regprocedure,
  $o$      if new.booking_type <> 'owner' and new.card_on_file_id is null then
        raise exception 'No saved card, no confirmed booking' using errcode = '23514';$o$,
  $n$      if new.booking_type <> 'owner' and new.card_on_file_id is null and new.deposit_pay_method = 'card' then
        raise exception 'No saved card, no confirmed booking' using errcode = '23514';$n$);

-- the renter approved an offer paid another way: customer service has a task to record the money and confirm
create or replace function app.bookings_offline_approved() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'pending_payment' and old.status is distinct from 'pending_payment' and new.rental_pay_method <> 'card' then
    perform app.raise_task(p_type => 'confirm_offline_booking',
      p_title => format('Booking %s: approved, paid by %s. Record the payment, then confirm', new.booking_number, app.payment_method_label(new.rental_pay_method)),
      p_booking => new.id, p_vehicle => new.vehicle_id, p_renter => new.renter_id, p_dedupe => 'confirm_offline_booking:' || new.id || ':' || coalesce(new.offer_approved_version, 0));
  end if;
  return null;
end $$;
drop trigger if exists bookings_offline_approved on bookings;
create trigger bookings_offline_approved after update of status on bookings for each row execute function app.bookings_offline_approved();

-- A deposit taken in cash or by e-Transfer is settled as 0020 settles a charged deposit; what it releases is given back
-- the same way (a task for Finance), never refunded to a card.
alter function app.settle_deposit(uuid, uuid, jsonb, timestamptz) rename to settle_deposit_pre0129;
create or replace function app.settle_deposit(p_booking uuid, p_by uuid, p_plan jsonb default '{}'::jsonb, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  d deposits;
  v_out jsonb;
  a jsonb;
  v_actions jsonb := '[]'::jsonb;
  b bookings;
begin
  v_out := app.settle_deposit_pre0129(p_booking, p_by, p_plan, p_now);
  select * into d from deposits where booking_id = p_booking;
  if d.id is null or d.method <> 'offline' then return v_out; end if;
  select * into b from bookings where id = p_booking;
  for a in select value from jsonb_array_elements(coalesce(v_out -> 'server_actions', '[]'::jsonb)) loop
    if a ->> 'action' in ('refund_deposit', 'release_hold') then
      update payments set method = d.paid_method, payment_method_id = null, kind = 'refund' where id = (a ->> 'payment_id')::uuid;
      perform app.raise_task(p_type => 'return_deposit_offline',
        p_title => format('Booking %s: give back %s of the deposit by %s', b.booking_number, app.fmt_money((a ->> 'amount_cents')::bigint), app.payment_method_label(d.paid_method)),
        p_detail => 'Give the amount back the way it came, then press Returned on the booking (Money) with the reference or the receipt number.',
        p_booking => p_booking, p_renter => b.renter_id, p_related_table => 'payments', p_related_id => (a ->> 'payment_id')::uuid,
        p_dedupe => 'return_deposit_offline:' || (a ->> 'payment_id'), p_created_by => p_by);
    else
      v_actions := v_actions || a;
    end if;
  end loop;
  return v_out || jsonb_build_object('server_actions', v_actions, 'offline_return', d.paid_method);
end $$;

-- the deposit given back in cash or by e-Transfer: the refund payment succeeds, with its reference
create or replace function app.deposit_return_offline(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  pay payments;
  v_ref text := nullif(btrim(coalesce(p ->> 'reference', '')), '');
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin records a deposit given back' using errcode = '42501'; end if;
  select * into pay from payments where id = (p ->> 'payment')::uuid for update;
  if pay.id is null or pay.purpose <> 'deposit' or pay.kind <> 'refund' or pay.method not in ('cash', 'e_transfer') then
    raise exception 'That is not a deposit to give back in cash or by e-Transfer' using errcode = '22023';
  end if;
  if pay.status = 'succeeded' then return jsonb_build_object('ok', true, 'repeat', true); end if;
  if pay.method = 'e_transfer' and (v_ref is null or length(v_ref) < 3) then raise exception 'Enter the e-Transfer reference number' using errcode = '22023'; end if;
  update payments set status = 'succeeded', processed_at = now() where id = pay.id;
  insert into payment_processor_details (payment_id, processor, processor_payment_id, raw)
  values (pay.id, 'offline', pay.method || ':' || coalesce(v_ref, pay.id::text), jsonb_strip_nulls(jsonb_build_object('reference', v_ref, 'note', nullif(btrim(coalesce(p ->> 'note', '')), ''), 'recorded_by', p_by, 'returned', true)))
  on conflict (payment_id) do nothing;
  perform app.resolve_tasks(array['return_deposit_offline'], pay.booking_id, p_by, 'Given back by ' || app.payment_method_label(pay.method));
  perform app.log_booking_event(pay.booking_id, 'adjusted', null, (select status::text from bookings where id = pay.booking_id), null,
    format('Deposit of %s given back by %s%s', app.fmt_money(pay.amount_cents), app.payment_method_label(pay.method), coalesce(' (' || v_ref || ')', '')), p_by, 'staff');
  return jsonb_build_object('ok', true, 'payment_id', pay.id);
end $$;

-- ================================================================ 8. a rental added by hand: the deposit, more ways to pay, paper, the calendar
-- p, beyond 0074's: deposit {method: card | cash | e_transfer | none, reference, received_on}; payment.method platform_payout
-- or insurer (recorded once the rental is made; insurer: billed later, bill_to insurer); agreement: send | paper;
-- blocks_calendar false with blocks_calendar_reason.
-- an assistant may add a rental paid through a platform or billed to the insurer: nothing is collected at booking, so it
-- is made unpaid (0058 lets assistants take only the ways of Program settings, and unpaid is not one of them)
select pg_temp.patch_fn('app.manual_rental_create_0058(uuid,jsonb)'::regprocedure,
  $o$    if not v_mode = any (case when v_role = 'field' then array['link', 'card'] else s.manual_rental_va_payment_modes end) then$o$,
  $n$    if not v_mode = any (case when v_role = 'field' then array['link', 'card'] else s.manual_rental_va_payment_modes end)
       and not (v_mode = 'unpaid' and v_role = 'va' and coalesce(current_setting('app.manual_rental_paid_elsewhere', true), '') = 'on') then$n$);
alter function app.manual_rental_create(uuid, jsonb) rename to manual_rental_create_pre0129;
create or replace function app.manual_rental_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_method text := nullif(p #>> '{payment,method}', '');
  v_mode text := nullif(p #>> '{payment,mode}', '');
  v_dep jsonb := coalesce(p -> 'deposit', '{}'::jsonb);
  v_dep_method text := coalesce(nullif(v_dep ->> 'method', ''), 'card');
  v_paper boolean := coalesce(p ->> 'agreement', 'send') = 'paper';
  v_core jsonb := p - 'deposit' - 'agreement' - 'blocks_calendar' - 'blocks_calendar_reason';
  v_out jsonb;
  b bookings;
  v_extra jsonb := '{}'::jsonb;
  v_pay jsonb;
begin
  if v_dep_method not in ('card', 'cash', 'e_transfer', 'none') then raise exception 'Choose how the deposit is taken: card, cash, e-Transfer or no deposit' using errcode = '22023'; end if;
  if v_dep_method = 'none' and not app.user_is_admin(p_by) then raise exception 'Only an Admin takes no deposit' using errcode = '42501'; end if;
  if coalesce((p ->> 'blocks_calendar')::boolean, true) = false and nullif(btrim(coalesce(p ->> 'blocks_calendar_reason', '')), '') is null then
    raise exception 'Say why it does not block the calendar (for example: insurance replacement, dates not known yet)' using errcode = '22023';
  end if;
  -- a payout from a platform or a bill to the insurer: the rental is made unpaid, then the payment is recorded as such
  if v_mode = 'other_way' and v_method in ('platform_payout', 'insurer') then
    v_core := jsonb_set(v_core, '{payment}', (v_core -> 'payment') || jsonb_build_object('mode', 'unpaid'));
  end if;
  if v_method in ('platform_payout', 'insurer') and v_mode in ('other_way', 'unpaid') then
    perform set_config('app.manual_rental_paid_elsewhere', 'on', true);
  end if;
  -- paper: no signing email; the rest of the renter's emails as staff chose
  v_out := app.manual_rental_create_pre0129(p_by, v_core);
  perform set_config('app.manual_rental_paid_elsewhere', '', true);
  select * into b from bookings where id = (v_out ->> 'booking_id')::uuid;
  update bookings set deposit_pay_method = v_dep_method,
         rental_pay_method = case when v_mode = 'other_way' and v_method in ('e_transfer', 'cash', 'cheque', 'bank_transfer', 'platform_payout', 'insurer') then v_method
                                  when v_mode = 'unpaid' and v_method = 'insurer' then 'insurer' else rental_pay_method end,
         agreement_on_paper = v_paper
   where id = b.id;
  if v_mode = 'other_way' and v_method = 'platform_payout' then
    v_pay := app.record_booking_payment(p_by, jsonb_build_object('booking', b.id, 'covers', 'rental', 'method', 'platform_payout',
               'amount_cents', coalesce(nullif(p #>> '{payment,amount_cents}', '')::bigint, b.renter_due_at_booking_cents),
               'reference', p #>> '{payment,reference}', 'received_on', p #>> '{payment,received_on}', 'note', coalesce(nullif(p #>> '{payment,note}', ''), 'Paid on ' || coalesce(nullif(p ->> 'source', ''), 'the platform'))));
    v_extra := v_extra || jsonb_build_object('platform_payment', v_pay);
  end if;
  if v_dep_method in ('cash', 'e_transfer') and b.deposit_cents > 0 and b.status in ('confirmed', 'on_rent') then
    v_extra := v_extra || jsonb_build_object('deposit', app.record_offline_deposit(p_by, b.id, v_dep_method, null, nullif(btrim(coalesce(v_dep ->> 'reference', '')), ''),
                 coalesce(nullif(v_dep ->> 'received_on', '')::date, app.today()), null));
  end if;
  if coalesce((p ->> 'blocks_calendar')::boolean, true) = false and b.blocks_calendar and b.status in ('confirmed', 'on_rent', 'requested', 'offered', 'pending_payment') then
    perform app.set_blocks_calendar(b.id, false, p_by, btrim(p ->> 'blocks_calendar_reason'));
  end if;
  if v_paper and b.status in ('confirmed', 'on_rent', 'pending_payment', 'requested') then
    perform app.raise_task(p_type => 'paper_agreement_scan', p_title => format('Booking %s: upload the scan of the agreement signed on paper', b.booking_number),
      p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_dedupe => 'paper_agreement_scan:' || b.id, p_created_by => p_by);
  end if;
  select * into b from bookings where id = b.id;
  return v_out || v_extra || jsonb_build_object('blocks_calendar', b.blocks_calendar, 'deposit_pay_method', b.deposit_pay_method, 'rental_pay_method', b.rental_pay_method,
                                                'agreement_on_paper', b.agreement_on_paper);
end $$;

-- ================================================================ 9. card payments started by staff (Stripe)
-- The server makes the PaymentIntent or SetupIntent and the token; the database keeps the request and records what
-- Stripe reports. Amounts come from the booking, never from the browser of the renter.
create or replace function app.payreq_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_kind text := coalesce(nullif(p ->> 'kind', ''), 'charge');
  v_covers text := coalesce(nullif(p ->> 'covers', ''), case v_kind when 'hold' then 'deposit' when 'setup' then 'card' else 'rental' end);
  v_channel text := coalesce(nullif(p ->> 'channel', ''), 'device');
  v_amount bigint;
  v_id uuid;
  v_open bigint;
  s program_settings := app.settings();
begin
  if not app.card_collect_allowed(p_by) then raise exception 'Staff who deal with renters start a card payment' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status in ('cancelled', 'declined', 'expired', 'closed') then raise exception 'Booking % is %: no card payment is taken on it', b.booking_number, b.status using errcode = '23514'; end if;
  if v_kind not in ('charge', 'hold', 'setup') then raise exception 'Choose a payment, a deposit hold or saving the card' using errcode = '22023'; end if;
  if v_channel not in ('device', 'text', 'email', 'link') then raise exception 'Choose how the renter pays: on this device, by text or by email' using errcode = '22023'; end if;
  if nullif(p ->> 'token_sha256', '') is null or (p ->> 'token_sha256') !~ '^[0-9a-f]{64}$' then raise exception 'The link token is missing' using errcode = '22023'; end if;
  if v_kind = 'setup' then
    v_amount := 0;
  elsif v_kind = 'hold' then
    if b.deposit_cents <= 0 or b.booking_type = 'owner' then raise exception 'Booking % has no deposit to hold', b.booking_number using errcode = '23514'; end if;
    if exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured', 'settled')) then raise exception 'The deposit on % is already taken', b.booking_number using errcode = '23514'; end if;
    if b.status not in ('pending_payment', 'confirmed', 'on_rent') then raise exception 'A deposit hold is placed once the offer is approved' using errcode = '23514'; end if;
    if b.billable_days > s.deposit_hold_max_days then
      raise exception 'A rental of more than % days takes no hold (a hold lapses after about % days): save the card now, and charge the deposit with Charge the saved card', s.deposit_hold_max_days, s.deposit_hold_max_days using errcode = '23514';
    end if;
    v_amount := b.deposit_cents;
  else
    if v_covers not in ('rental', 'fees', 'later') then raise exception 'Choose what the card pays: the rental, fees or a later charge' using errcode = '22023'; end if;
    v_open := app.booking_part_open(b.id, v_covers);
    v_amount := coalesce(nullif(p ->> 'amount_cents', '')::bigint, v_open);
    if v_amount is null or v_amount <= 0 then raise exception 'Nothing is open for that part: enter the amount' using errcode = '22023'; end if;
    if v_amount > greatest(v_open, 0) then
      -- a later charge not on a statement yet (fuel, extra km, a late return): its reason, within the person's single limit
      if v_covers = 'later' and nullif(btrim(coalesce(p ->> 'reason', '')), '') is null then
        raise exception 'Say what the charge is for (fuel, extra km, late return...): the renter sees it' using errcode = '22023';
      elsif v_covers <> 'later' and not app.user_is_admin(p_by) then
        raise exception 'That is more than what is open (%): an Admin charges more', app.fmt_money(v_open) using errcode = '42501';
      elsif not app.user_is_admin(p_by) and v_amount > coalesce((select sp.single_limit_cents from staff_profiles sp where sp.user_id = p_by), 0) then
        raise exception '% is above your single limit: an Admin or Finance charges it', app.fmt_money(v_amount) using errcode = '42501';
      end if;
    end if;
  end if;
  update payment_requests set status = 'cancelled' where booking_id = b.id and status = 'open' and kind = v_kind and covers = v_covers;
  insert into payment_requests (booking_id, renter_id, kind, covers, amount_cents, reason, token_sha256, channel, expires_at, created_by)
  values (b.id, b.renter_id, v_kind, v_covers, v_amount, nullif(btrim(coalesce(p ->> 'reason', '')), ''), p ->> 'token_sha256', v_channel,
          now() + case when v_channel = 'device' then interval '2 hours' else interval '3 days' end, p_by)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'kind', v_kind, 'covers', v_covers, 'amount_cents', v_amount, 'booking_id', b.id, 'booking_number', b.booking_number,
    'renter', (select jsonb_build_object('id', r.id, 'legal_name', r.legal_name, 'email', coalesce(r.email, u.email), 'mobile', r.mobile,
                 'customer_id', (select sc.processor_customer_id from payment_methods pm join payment_method_secrets sc on sc.payment_method_id = pm.id
                                  where pm.renter_id = r.id and sc.processor_customer_id is not null order by pm.created_at desc limit 1))
                 from renters r left join users u on u.id = r.user_id where r.id = b.renter_id),
    'vehicle_name', app.vehicle_name(b.vehicle_id), 'channel', v_channel);
end $$;

create or replace function public.server_payreq_attach(p_id uuid, p_intent text) returns void
language sql security definer set search_path = public, app as $$
  update payment_requests set processor_intent_id = p_intent where id = p_id and status = 'open'
$$;

-- The pay page (/pay/<token>): what the renter sees, by the token's hash. No account needed: the link is the key.
create or replace function public.server_payreq_facts(p_token_sha256 text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', q.id, 'kind', q.kind, 'covers', q.covers, 'amount_cents', q.amount_cents, 'reason', q.reason, 'status',
           case when q.status = 'open' and q.expires_at <= now() then 'expired' else q.status end,
           'expires_at', q.expires_at, 'intent_id', q.processor_intent_id, 'booking_id', b.id, 'booking_number', b.booking_number,
           'vehicle_name', app.vehicle_name(b.vehicle_id), 'pickup_at', b.pickup_at, 'return_at', b.return_at, 'renter_name', r.legal_name,
           'renter_id', r.id, 'email', coalesce(r.email, u.email),
           'customer_id', (select sc.processor_customer_id from payment_methods pm join payment_method_secrets sc on sc.payment_method_id = pm.id
                            where pm.renter_id = r.id and sc.processor_customer_id is not null order by pm.created_at desc limit 1),
           'hold_days', (app.settings()).deposit_hold_max_days)
    from payment_requests q join bookings b on b.id = q.booking_id join renters r on r.id = b.renter_id left join users u on u.id = r.user_id
   where q.token_sha256 = lower(p_token_sha256)
$$;

-- What Stripe reported for a request: a charge that succeeded, a hold authorized, a card saved. p_intent is fetched
-- again from Stripe by the server (never the browser's word): {id, status, amount, amount_capturable, charge_id,
-- customer_id, method_id, card {brand, last4, ...}}.
create or replace function public.server_payreq_settle(p_id uuid, p_intent jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q payment_requests;
  b bookings;
  v_pm uuid;
  v_pay uuid;
  v_dep uuid;
  v_st text := p_intent ->> 'status';
  v_card jsonb := p_intent -> 'card';
begin
  select * into q from payment_requests where id = p_id for update;
  if q.id is null then raise exception 'Payment request not found' using errcode = 'P0002'; end if;
  if q.status = 'paid' then return jsonb_build_object('ok', true, 'repeat', true, 'payment_id', q.payment_id); end if;
  if q.processor_intent_id is distinct from p_intent ->> 'id' then raise exception 'That payment is not this request''s' using errcode = '22023'; end if;
  select * into b from bookings where id = q.booking_id for update;
  -- the card, saved for the deposit at pickup and later charges the renter agreed to
  if v_card is not null and (p_intent ->> 'method_id') is not null then
    v_pm := app.save_card_on_file(b.renter_id, v_card || jsonb_build_object('cardholder_name', v_card ->> 'name', 'is_credit', (v_card ->> 'funding') = 'credit'),
              jsonb_build_object('processor', 'stripe', 'customer_id', p_intent ->> 'customer_id', 'method_id', p_intent ->> 'method_id', 'fingerprint', v_card ->> 'fingerprint'));
    if v_pm is not null then update bookings set card_on_file_id = v_pm where id = b.id; end if;
  end if;
  if q.kind = 'setup' then
    if v_st <> 'succeeded' then
      update payment_requests set last_error = coalesce(p_intent ->> 'error', v_st) where id = q.id;
      return jsonb_build_object('ok', false, 'reason', coalesce(p_intent ->> 'error', 'The card was not saved'));
    end if;
    update payment_requests set status = 'paid', completed_at = now() where id = q.id;
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null, format('Card saved (%s ending %s)', initcap(coalesce(v_card ->> 'brand', 'card')), v_card ->> 'last4'), null, 'system',
      jsonb_build_object('payment_request_id', q.id, 'consent', 'The renter saved the card for the deposit and the later charges in the rental agreement'));
    return jsonb_build_object('ok', true, 'saved', true, 'payment_method_id', v_pm);
  end if;
  if q.kind = 'hold' then
    if v_st not in ('requires_capture', 'succeeded') then
      update payment_requests set last_error = coalesce(p_intent ->> 'error', v_st) where id = q.id;
      return jsonb_build_object('ok', false, 'reason', coalesce(p_intent ->> 'error', 'The hold was not approved'));
    end if;
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, payment_method_id, card_brand, card_last4, processed_at)
    values (b.id, b.renter_id, 'deposit', 'hold', 'card', q.amount_cents, 'authorized', v_pm, v_card ->> 'brand', v_card ->> 'last4', now())
    returning id into v_pay;
    insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id) values (v_pay, 'stripe', p_intent ->> 'id', p_intent ->> 'charge_id');
    insert into deposits as d (booking_id, amount_cents, method, status, hold_payment_id, taken_at, hold_expires_at)
    values (b.id, q.amount_cents, 'card_hold', 'held', v_pay, now(), now() + make_interval(days => (app.settings()).deposit_hold_max_days))
    on conflict (booking_id) do update set amount_cents = excluded.amount_cents, method = 'card_hold', paid_method = null, status = 'held', hold_payment_id = excluded.hold_payment_id,
           taken_at = excluded.taken_at, hold_expires_at = excluded.hold_expires_at, captured_cents = 0
     where d.status in ('pending', 'failed')
    returning id into v_dep;
    if v_dep is null then raise exception 'The deposit on % has already been taken', b.booking_number using errcode = '23514'; end if;
    insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note) values (v_dep, 'taken', q.amount_cents, v_pay, 'card hold, from the booking page');
    update bookings set deposit_pay_method = 'card' where id = b.id and deposit_pay_method <> 'card';
    perform app.resolve_tasks(array['take_deposit', 'deposit_declined'], b.id, null, 'Deposit hold placed');
    update payment_requests set status = 'paid', completed_at = now(), payment_id = v_pay where id = q.id;
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null, format('Deposit hold of %s placed on %s ending %s', app.fmt_money(q.amount_cents),
      initcap(coalesce(v_card ->> 'brand', 'card')), v_card ->> 'last4'), null, 'system', jsonb_build_object('payment_id', v_pay, 'payment_request_id', q.id));
    return jsonb_build_object('ok', true, 'payment_id', v_pay, 'deposit_id', v_dep);
  end if;
  -- a charge of a part of the booking
  if v_st <> 'succeeded' then
    update payment_requests set last_error = coalesce(p_intent ->> 'error', v_st) where id = q.id;
    return jsonb_build_object('ok', false, 'reason', coalesce(p_intent ->> 'error', 'The card was not charged'));
  end if;
  insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, payment_method_id, card_brand, card_last4, processed_at)
  values (b.id, b.renter_id, case q.covers when 'later' then 'post_rental' else 'booking_total' end, 'charge', 'card', (p_intent ->> 'amount')::bigint, 'succeeded', v_pm,
          v_card ->> 'brand', v_card ->> 'last4', now())
  returning id into v_pay;
  insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, raw)
  values (v_pay, 'stripe', p_intent ->> 'id', p_intent ->> 'charge_id', jsonb_build_object('covers', q.covers, 'payment_request_id', q.id, 'reason', q.reason));
  update payment_requests set status = 'paid', completed_at = now(), payment_id = v_pay where id = q.id;
  perform app.booking_tie_lines(b.id, q.covers, v_pay);
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null, format('%s paid by card (%s ending %s) for the %s', app.fmt_money((p_intent ->> 'amount')::bigint),
    initcap(coalesce(v_card ->> 'brand', 'card')), v_card ->> 'last4', case q.covers when 'rental' then 'rental' when 'fees' then 'fees' else 'later charges' end), null, 'system',
    jsonb_build_object('payment_id', v_pay, 'covers', q.covers, 'payment_request_id', q.id));
  if q.covers <> 'later' then
    perform app.ntf_emit('renter_payment_receipt', 'payment', v_pay, 'succeeded', jsonb_build_object('booking_id', b.id, 'renter_id', b.renter_id));
  end if;
  -- paid in full, approved and signed: confirmed now
  if b.status = 'pending_payment' and q.covers in ('rental', 'fees') then
    return jsonb_build_object('ok', true, 'payment_id', v_pay, 'confirm', app.confirm_offline_booking(q.created_by, b.id, false));
  end if;
  return jsonb_build_object('ok', true, 'payment_id', v_pay);
end $$;

-- card payments of a part, through a request: they count for that part (booking_part_open's card rule covers the whole
-- booking paid online; a request pays one part)
create or replace function app.card_part_paid(p_booking uuid, p_covers text) returns bigint
language sql stable security definer set search_path = public, app as $$
  select coalesce(sum(x.amount_cents), 0) - coalesce((select sum(rf.amount_cents) from refunds rf join payments x2 on x2.id = rf.payment_id
                                                       join payment_requests q2 on q2.payment_id = x2.id
                                                      where x2.booking_id = p_booking and q2.covers = p_covers and rf.status = 'paid'), 0)
    from payments x join payment_requests q on q.payment_id = x.id
   where x.booking_id = p_booking and q.covers = p_covers and q.kind = 'charge' and x.status = 'succeeded'
$$;
select pg_temp.patch_fn('app.booking_part_open(uuid,text)'::regprocedure,
  $o$  select coalesce(sum(m.amount_cents), 0) into v_paid from manual_payments m where m.booking_id = p_booking and m.voided_at is null and m.covers = p_covers;$o$,
  $n$  select coalesce(sum(m.amount_cents), 0) + app.card_part_paid(p_booking, p_covers) into v_paid from manual_payments m where m.booking_id = p_booking and m.voided_at is null and m.covers = p_covers;$n$);
select pg_temp.patch_fn('app.booking_part_open(uuid,text)'::regprocedure,
  $o$    return greatest(v_due, 0);
  end if;$o$,
  $n$    return greatest(v_due - coalesce((select sum(m.amount_cents) from manual_payments m where m.booking_id = p_booking and m.voided_at is null and m.covers = 'later'
                                        and not exists (select 1 from booking_line_items l2 where l2.payment_id = m.payment_id)), 0), 0);
  end if;$n$);
select pg_temp.patch_fn('app.booking_part_open(uuid,text)'::regprocedure,
  $o$  if exists (select 1 from payments x where x.booking_id = p_booking and x.purpose = 'booking_total' and x.method = 'card' and x.kind in ('charge', 'capture') and x.status = 'succeeded') then$o$,
  $n$  if exists (select 1 from payments x where x.booking_id = p_booking and x.purpose = 'booking_total' and x.method = 'card' and x.kind in ('charge', 'capture') and x.status = 'succeeded'
               and not exists (select 1 from payment_requests q where q.payment_id = x.id)) then$n$);

-- The saved card, charged for a later charge or the deposit of a long rental (extra km, fuel, damage, late return): the
-- database checks the person, the reason and the amount and gives the server what to charge; the result is recorded.
create or replace function app.card_charge_begin(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_covers text := coalesce(nullif(p ->> 'covers', ''), 'later');
  v_refuse text;
  v_pay uuid;
  sc payment_method_secrets;
  pm payment_methods;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin charges a saved card' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v_covers not in ('later', 'deposit', 'rental', 'fees') then raise exception 'Choose what the charge is for' using errcode = '22023'; end if;
  if v_reason is null then raise exception 'Say what the charge is for (extra km, fuel, damage, late return...): the renter''s receipt shows it' using errcode = '22023'; end if;
  if v_covers = 'deposit' then
    v_amount := b.deposit_cents;
    if exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured', 'settled')) then raise exception 'The deposit on % is already taken', b.booking_number using errcode = '23514'; end if;
  end if;
  if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount to charge' using errcode = '22023'; end if;
  v_refuse := app.booking_payment_allowed(p_by, v_amount);
  if v_refuse is not null and not app.user_is_admin(p_by) then raise exception '%', replace(v_refuse, 'records it', 'charges it') using errcode = '42501'; end if;
  select x.* into pm from payment_methods x where x.id = b.card_on_file_id and x.status = 'active';
  if pm.id is null then
    select x.* into pm from payment_methods x join payment_method_secrets s2 on s2.payment_method_id = x.id where x.renter_id = b.renter_id and x.status = 'active' and s2.processor_method_id is not null order by x.created_at desc limit 1;
  end if;
  select * into sc from payment_method_secrets where payment_method_id = pm.id;
  if sc.processor_method_id is null then raise exception 'No saved card on this booking: use Collect a card' using errcode = '23514'; end if;
  insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, payment_method_id, card_brand, card_last4, created_by)
  values (b.id, b.renter_id, case v_covers when 'deposit' then 'deposit' when 'later' then 'post_rental' else 'booking_total' end, 'charge', 'card', v_amount, 'pending', pm.id,
          pm.card_brand, pm.card_last4, p_by)
  returning id into v_pay;
  return jsonb_build_object('payment_id', v_pay, 'amount_cents', v_amount, 'customer_id', sc.processor_customer_id, 'method_id', sc.processor_method_id,
    'booking_id', b.id, 'booking_number', b.booking_number, 'reason', v_reason, 'covers', v_covers, 'idempotency_key', 'staff-charge:' || v_pay,
    'card', jsonb_build_object('brand', pm.card_brand, 'last4', pm.card_last4));
end $$;

create or replace function app.card_charge_finish(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  pay payments;
  b bookings;
  v_ok boolean := coalesce((p ->> 'ok')::boolean, false);
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_dep uuid;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into pay from payments where id = (p ->> 'payment')::uuid for update;
  if pay.id is null or pay.status <> 'pending' then raise exception 'That charge is not waiting for a result' using errcode = '23514'; end if;
  select * into b from bookings where id = pay.booking_id;
  if not v_ok then
    update payments set status = 'failed', decline_count = decline_count + 1, last_decline_code = left(coalesce(p ->> 'error', 'declined'), 60) where id = pay.id;
    return jsonb_build_object('ok', false, 'reason', coalesce(p ->> 'error', 'The card was declined'));
  end if;
  update payments set status = 'succeeded', processed_at = now() where id = pay.id;
  insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, raw)
  values (pay.id, 'stripe', p ->> 'intent_id', p ->> 'charge_id', jsonb_strip_nulls(jsonb_build_object('reason', v_reason, 'charged_by', p_by)))
  on conflict (payment_id) do nothing;
  if pay.purpose = 'deposit' then
    insert into deposits as d (booking_id, amount_cents, method, status, hold_payment_id, taken_at, captured_cents)
    values (b.id, pay.amount_cents, 'charged', 'captured', pay.id, now(), pay.amount_cents)
    on conflict (booking_id) do update set amount_cents = excluded.amount_cents, method = 'charged', paid_method = null, status = 'captured', hold_payment_id = excluded.hold_payment_id,
           taken_at = excluded.taken_at, captured_cents = excluded.captured_cents where d.status in ('pending', 'failed')
    returning id into v_dep;
    if v_dep is not null then insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note, created_by) values (v_dep, 'taken', pay.amount_cents, pay.id, 'charged to the saved card', p_by); end if;
    perform app.resolve_tasks(array['take_deposit', 'deposit_declined'], b.id, p_by, 'Deposit charged');
  elsif pay.purpose = 'post_rental' then
    -- the statement lines it pays, oldest first, while the amount covers them
    perform app.booking_tie_lines(b.id, 'later', pay.id);
  end if;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('%s charged to the saved card (%s ending %s): %s', app.fmt_money(pay.amount_cents), initcap(coalesce(pay.card_brand, 'card')), pay.card_last4, coalesce(v_reason, '')), p_by, 'staff',
    jsonb_build_object('payment_id', pay.id));
  -- 0023 sends the receipt of a charge that is not the booking total or the deposit; the deposit has its own line
  return jsonb_build_object('ok', true, 'payment_id', pay.id);
end $$;

-- A deposit hold: captured in full or in part, or released. The database checks and gives the server the intent; the
-- result is recorded as the settlement of 0020 records it (a capture, a release).
create or replace function app.hold_action_begin(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d deposits;
  b bookings;
  pd payment_processor_details;
  v_action text := p ->> 'action';
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin captures or releases a hold' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  select * into d from deposits where booking_id = b.id for update;
  if d.id is null or d.method <> 'card_hold' or d.status <> 'held' then raise exception 'There is no deposit hold to capture or release on this booking' using errcode = '23514'; end if;
  select * into pd from payment_processor_details where payment_id = d.hold_payment_id;
  if pd.processor_payment_id is null then raise exception 'The hold has no Stripe reference: settle it from the statement' using errcode = '23514'; end if;
  if v_action not in ('capture', 'release') then raise exception 'Choose capture or release' using errcode = '22023'; end if;
  if v_action = 'capture' then
    v_amount := coalesce(v_amount, d.amount_cents);
    if v_amount <= 0 or v_amount > d.amount_cents then raise exception 'Capture between $0.01 and the hold of %', app.fmt_money(d.amount_cents) using errcode = '22023'; end if;
    if nullif(btrim(coalesce(p ->> 'reason', '')), '') is null then raise exception 'Say why the hold is captured (damage, fuel, extra km...)' using errcode = '22023'; end if;
  elsif not app.may_release_payment(p_by, d.amount_cents, true) and not app.user_is_admin(p_by) then
    raise exception 'This release needs an Admin' using errcode = '42501';
  end if;
  return jsonb_build_object('deposit_id', d.id, 'intent_id', pd.processor_payment_id, 'amount_cents', coalesce(v_amount, d.amount_cents), 'action', v_action,
                            'idempotency_key', 'hold-' || v_action || ':' || d.id, 'booking_id', b.id);
end $$;

create or replace function app.hold_action_finish(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d deposits;
  b bookings;
  v_pay uuid;
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_rest bigint;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into d from deposits where id = (p ->> 'deposit')::uuid for update;
  select * into b from bookings where id = d.booking_id;
  if d.status <> 'held' then return jsonb_build_object('ok', true, 'repeat', true); end if;
  if not coalesce((p ->> 'ok')::boolean, false) then return jsonb_build_object('ok', false, 'reason', coalesce(p ->> 'error', 'Stripe refused')); end if;
  if p ->> 'action' = 'capture' then
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, parent_payment_id, payment_method_id, processed_at, created_by)
    values (b.id, b.renter_id, 'deposit', 'capture', 'card', v_amount, 'succeeded', d.hold_payment_id, b.card_on_file_id, now(), p_by) returning id into v_pay;
    v_rest := d.amount_cents - v_amount;
    insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note, created_by) values (d.id, 'captured', v_amount, v_pay, nullif(btrim(coalesce(p ->> 'reason', '')), ''), p_by);
    -- the rest of a part capture is released by Stripe at once (the hold ends with the capture)
    if v_rest > 0 then
      insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note, created_by) values (d.id, 'released', v_rest, null, 'the rest of the hold, released with the capture', p_by);
    end if;
    update deposits set status = 'captured', captured_cents = v_amount, amount_cents = d.amount_cents, released_cents = v_rest, release_approved_by = case when v_rest > 0 then p_by end,
           released_at = case when v_rest > 0 then now() end where id = d.id;
  else
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, parent_payment_id, payment_method_id, processed_at, created_by)
    values (b.id, b.renter_id, 'deposit', 'release', 'card', d.amount_cents, 'succeeded', d.hold_payment_id, b.card_on_file_id, now(), p_by) returning id into v_pay;
    insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note, created_by) values (d.id, 'released', d.amount_cents, v_pay, nullif(btrim(coalesce(p ->> 'reason', '')), ''), p_by);
    update deposits set status = 'settled', released_cents = d.amount_cents, release_approved_by = p_by, released_at = now() where id = d.id;
  end if;
  update payments set status = case when p ->> 'action' = 'capture' then 'succeeded' else 'cancelled' end where id = d.hold_payment_id;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    case when p ->> 'action' = 'capture' then format('Deposit hold captured: %s of %s%s', app.fmt_money(v_amount), app.fmt_money(d.amount_cents), coalesce('. ' || nullif(btrim(p ->> 'reason'), ''), ''))
         else format('Deposit hold of %s released', app.fmt_money(d.amount_cents)) end, p_by, 'staff', jsonb_build_object('payment_id', v_pay));
  return jsonb_build_object('ok', true, 'payment_id', v_pay);
end $$;

-- The pay link to the renter: a text to their mobile (Quo, as staff), or the booking's message by email. The link holds
-- the token; the database keeps only its hash, so the link is sent from here once and never shown again.
create or replace function app.payreq_send(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q payment_requests;
  b bookings;
  rn renters;
  v_link text := nullif(btrim(coalesce(p ->> 'link', '')), '');
  v_what text;
  o phone_outbox;
begin
  if not app.card_collect_allowed(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into q from payment_requests where id = (p ->> 'id')::uuid;
  if q.id is null or q.status <> 'open' then raise exception 'That payment request is not open' using errcode = '23514'; end if;
  if v_link is null or v_link !~ '^https?://[^ ]+/pay/[A-Za-z0-9_-]{20,}$' then raise exception 'The pay link is missing' using errcode = '22023'; end if;
  if encode(sha256(convert_to(regexp_replace(v_link, '^.*/pay/', ''), 'UTF8')), 'hex') <> q.token_sha256 then raise exception 'That link is not this request''s' using errcode = '22023'; end if;
  select * into b from bookings where id = q.booking_id;
  select * into rn from renters where id = b.renter_id;
  v_what := case q.kind when 'hold' then format('the deposit hold of %s', app.fmt_money(q.amount_cents)) when 'setup' then 'saving your card for the deposit and later charges'
                        else format('%s for %s', app.fmt_money(q.amount_cents), coalesce(q.reason, case q.covers when 'rental' then 'the rental' when 'fees' then 'the fees' else 'a charge' end)) end;
  if q.channel = 'text' then
    if app.phone_e164(rn.mobile) is null then raise exception 'The renter has no mobile number on file: send it by email' using errcode = '23514'; end if;
    o := app.phone_outbox_put(rn.mobile, format('CarmaCars: booking %s, %s. Pay securely: %s', b.booking_number, v_what, v_link), 'staff', b.id, rn.id, 'pay_link', null,
                              'payreq:' || q.id, now(), 'queued', p_by);
    return jsonb_build_object('ok', o.status <> 'skipped', 'to', app.phone_display(o.to_number), 'reason', o.status_reason);
  elsif q.channel = 'email' then
    perform app.staff_send_message(p_by, b.id, 'Payment for booking ' || b.booking_number,
      format('Hi %s, please use this secure link for %s: %s. The card is entered in Stripe''s own form; CarmaCars never sees the card number.',
             coalesce(nullif(split_part(btrim(rn.legal_name), ' ', 1), ''), 'there'), v_what, v_link));
    return jsonb_build_object('ok', true, 'to', coalesce(rn.email, (select u.email from users u where u.id = rn.user_id)));
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ 10. the money of a booking, by part
create or replace function app.booking_money(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  s program_settings := app.settings();
begin
  if app.offer_role(p_by) is null and not app.user_runs_finance(p_by) and app.manual_rental_role(p_by) is null then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status,
    'rental_pay_method', b.rental_pay_method, 'deposit_pay_method', b.deposit_pay_method, 'agreement_on_paper', b.agreement_on_paper,
    'parts', jsonb_build_array(
      jsonb_build_object('covers', 'rental', 'open_cents', app.booking_part_open(b.id, 'rental')),
      jsonb_build_object('covers', 'fees', 'open_cents', app.booking_part_open(b.id, 'fees')),
      jsonb_build_object('covers', 'later', 'open_cents', app.booking_part_open(b.id, 'later'))),
    'due_cents', coalesce(b.renter_due_at_booking_cents, b.total_due_at_booking_cents), 'deposit_cents', b.deposit_cents,
    'deposit', (select to_jsonb(d) || jsonb_build_object('hold_days_left', case when d.hold_expires_at is not null then greatest(0, ceil(extract(epoch from d.hold_expires_at - now()) / 86400)) end)
                  from deposits d where d.booking_id = b.id),
    'card', (select jsonb_build_object('brand', pm.card_brand, 'last4', pm.card_last4, 'exp_month', pm.exp_month, 'exp_year', pm.exp_year)
               from payment_methods pm where pm.id = coalesce(b.card_on_file_id, (select x.id from payment_methods x where x.renter_id = b.renter_id and x.status = 'active' order by x.created_at desc limit 1))),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'created_at', x.created_at, 'processed_at', x.processed_at, 'purpose', x.purpose, 'kind', x.kind, 'method', x.method,
                 'amount_cents', x.amount_cents, 'status', x.status, 'card_last4', x.card_last4, 'card_brand', x.card_brand,
                 'covers', coalesce(m.covers, q.covers, case x.purpose when 'deposit' then 'deposit' when 'post_rental' then 'later' when 'booking_total' then 'rental' end),
                 'reference', coalesce(m.reference, pd.raw ->> 'reference'), 'note', coalesce(m.note, pd.raw ->> 'reason'), 'manual_id', m.id, 'voided', m.voided_at is not null,
                 'by', (select u.full_name from users u where u.id = coalesce(m.recorded_by, x.created_by)))
                 order by x.created_at)
                 from payments x left join manual_payments m on m.payment_id = x.id left join payment_requests q on q.payment_id = x.id
                 left join payment_processor_details pd on pd.payment_id = x.id where x.booking_id = b.id), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'covers', q.covers, 'amount_cents', q.amount_cents, 'channel', q.channel,
                 'status', case when q.status = 'open' and q.expires_at <= now() then 'expired' else q.status end, 'created_at', q.created_at, 'expires_at', q.expires_at,
                 'last_error', q.last_error) order by q.created_at desc)
                 from payment_requests q where q.booking_id = b.id and q.created_at > now() - interval '30 days'), '[]'::jsonb),
    'e_transfer_email', coalesce(nullif(btrim(s.e_transfer_email), ''), (select ss.public_email from site_settings ss limit 1)),
    'moto', s.stripe_moto_enabled,
    'may', jsonb_build_object('record', app.booking_payment_allowed(p_by, 1) is null, 'collect', app.card_collect_allowed(p_by), 'charge', app.user_runs_finance(p_by),
                              'hold', app.user_runs_finance(p_by), 'confirm', app.offer_role(p_by) is not null or app.user_runs_finance(p_by),
                              'return_deposit', app.user_runs_finance(p_by)),
    'can_confirm', b.status = 'pending_payment' and (b.rental_pay_method <> 'card' or app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees') = 0
                                                     and exists (select 1 from payment_requests q where q.booking_id = b.id and q.status = 'paid' and q.kind = 'charge')));
end $$;

-- the renter's pay page for an offer paid another way: where to send the e-Transfer
create or replace function public.renter_offline_pay_facts(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('rental_pay_method', b.rental_pay_method, 'deposit_pay_method', b.deposit_pay_method,
           'e_transfer_email', coalesce(nullif(btrim(s.e_transfer_email), ''), (select ss.public_email from site_settings ss limit 1)),
           'open_cents', app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees'))
    from bookings b cross join lateral (select * from app.settings()) s where b.id = p_booking
$$;

-- ================================================================ 11. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0129;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call in ('admin_do', 'va_do') and p_name = 'offer_revise')
     or (p_call = 'ops_read' and p_name in ('offer_form', 'offer_preview', 'find_customers', 'booking_money'))
     or (p_call = 'ops_do' and p_name in ('offer_create', 'offer_revise', 'record_booking_payment', 'confirm_offline_booking', 'deposit_return_offline',
                                          'payreq_create', 'payreq_send', 'payreq_cancel', 'card_charge_begin', 'card_charge_finish', 'hold_action_begin', 'hold_action_finish')) then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    p_ := p_ - '_va';
    perform app.door_begin(p_user, p_aal);
    case p_name
    when 'offer_form' then return app.staff_offer_form(p_user, p_);
    when 'offer_preview' then return app.staff_offer_preview(p_user, p_);
    when 'find_customers' then return app.staff_find_customers(p_user, p_);
    when 'booking_money' then return app.booking_money(p_user, p_);
    when 'offer_create' then return app.staff_offer_create(p_user, p_);
    when 'offer_revise' then return app.offer_revise(p_user, p_);
    when 'record_booking_payment' then return app.record_booking_payment(p_user, p_);
    when 'confirm_offline_booking' then return app.confirm_offline_booking(p_user, (select id from bookings where id::text = p_ ->> 'booking' or booking_number = p_ ->> 'booking'), true);
    when 'deposit_return_offline' then return app.deposit_return_offline(p_user, p_);
    when 'payreq_create' then return app.payreq_create(p_user, p_);
    when 'payreq_send' then return app.payreq_send(p_user, p_);
    when 'payreq_cancel' then
      if not app.card_collect_allowed(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
      update payment_requests set status = 'cancelled' where id = (p_ ->> 'id')::uuid and status = 'open';
      return jsonb_build_object('ok', true);
    when 'card_charge_begin' then return app.card_charge_begin(p_user, p_);
    when 'card_charge_finish' then return app.card_charge_finish(p_user, p_);
    when 'hold_action_begin' then return app.hold_action_begin(p_user, p_);
    when 'hold_action_finish' then return app.hold_action_finish(p_user, p_);
    end case;
  end if;
  return app.door_pre0129(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['offer_role', 'booking_payment_allowed', 'card_collect_allowed', 'offer_reopen_for_edit',
              'offer_revise', 'offer_channels_begin', 'offer_channels_end', 'offer_text', 'booking_set_pay_methods', 'staff_offer_create', 'staff_offer_preview', 'renter_match',
              'staff_find_customers', 'staff_offer_form', 'record_booking_payment', 'booking_part_open', 'booking_tie_lines', 'record_offline_deposit', 'confirm_offline_booking',
              'bookings_offline_approved', 'settle_deposit', 'settle_deposit_pre0129', 'deposit_return_offline', 'manual_rental_create', 'manual_rental_create_pre0129',
              'payreq_create', 'payreq_send', 'card_part_paid', 'card_charge_begin', 'card_charge_finish', 'hold_action_begin', 'hold_action_finish', 'booking_money', 'door', 'door_pre0129']))
        or (n.nspname = 'public' and p.proname = any (array['server_payreq_attach', 'server_payreq_facts', 'server_payreq_settle', 'renter_offline_pay_facts']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ the guides
-- GUIDES 0129 START (generated by supabase/seed/0129_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'requests-offers-and-bookings', 'chapter', 'people-and-access', 'Every booking starts as a request. You check it, adjust it and send the offer. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 18.5 21.2, 2 25.3 31.7")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-84570463.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 1 21.7 16.4, 2 20.0 45.4, 3 65.0 45.4, 4 96.5 98.8")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg "desktop; size: 620 810; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 5 91.9 33.6")

> Tip: After the offer is out: **Withdraw to edit** takes it back, **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10057; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

## Renter documents: licence and proof of coverage

A renter''s licence photos, selfie and proof of coverage (OPCF 27 or a credit card''s rental coverage) are checked before the handover. You check them yourself; no task is needed.

1. A booking with documents waiting is a line on To do: "Check ''s documents for booking ", marked Now when the pickup is within two days. Press **Review documents**.
2. The pop-up shows each driver''s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.
3. Tick the checks, then **Approve**. Or type the reason the renter reads and press **Reject**: they are asked for a new one.
4. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute.

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg "desktop; size: 1230 530; address: carmacars.ca/admin/bookings/CC-10057?tab=changes; pins: 1 12.9 15.3, 2 35.0 30.6, 3 49.8 59.1, 4 30.9 73.2")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.
', 'Requests, offers and bookings', 'Send an offer with or without a request, change it in place, take payments by part, run a booking, propose a change.',
  'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 18.5 21.2, 2 25.3 31.7")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-84570463.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 1 21.7 16.4, 2 20.0 45.4, 3 65.0 45.4, 4 96.5 98.8")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg "desktop; size: 620 810; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 5 91.9 33.6")

## Send an offer without a request

**Bookings** > **Send an offer**, or **Send an offer** on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.

1. The customer: type a name, phone or email and choose them. Not on file? Press **Add a new customer**: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.
2. The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).
3. The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason and can be plus tax or tax included. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.
4. How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).
5. Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.
6. The right side is the offer as the renter will see it, priced by the database as you type. Press **Send the offer**. **Save without sending** keeps it as a request for later.

> Good to know: It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.

## Change an offer that is out

The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press **Edit the offer** on the booking.

1. Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed.
2. Write what changed in Message to the renter and choose how long the offer is open.
3. Press **Save and send the update**: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press **Save without telling the renter** and tell them yourself.
4. A confirmed booking is changed with **Change the booking** (Propose a change, below).

> Tip: No need to withdraw first. **Withdraw the offer** is only for taking it back for good; **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## Payments by part: the rental, the deposit and later charges

On the booking''s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.

1. **Record a payment**: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press **Record it**. The renter gets a receipt; **Print** prints one to hand over.
2. **Collect a card**: a payment, the deposit hold or saving the card. The renter types the card in Stripe''s secure form: on this device (**Open the card form**, then hand it over) or by a link texted or emailed to them (**Send the link**). Staff never type a card number.
3. A deposit hold lasts about 7 days and shows the days left. After the return, **Capture the hold** (all or part, with the reason) or **Release the hold**.
4. **Charge the saved card** (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter''s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.
5. An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press **Confirm the booking**).
6. A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press **Returned** with the reference or receipt number.

> Good to know: Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10057; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

## Renter documents: licence and proof of coverage

A renter''s licence photos, selfie and proof of coverage (OPCF 27 or a credit card''s rental coverage) are checked before the handover. You check them yourself; no task is needed.

1. A booking with documents waiting is a line on To do: "Check ''s documents for booking ", marked Now when the pickup is within two days. Press **Review documents**.
2. The pop-up shows each driver''s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.
3. Tick the checks, then **Approve**. Or type the reason the renter reads and press **Reject**: they are asked for a new one.
4. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute.

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg "desktop; size: 1230 530; address: carmacars.ca/admin/bookings/CC-10057?tab=changes; pins: 1 12.9 15.3, 2 35.0 30.6, 3 49.8 59.1, 4 30.9 73.2")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.
',
  '<p class="gd-p">A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.</p><section class="gd-task" id="requests-offers-and-bookings-the-request-queue" data-gd-task><h2 class="gd-h2">The request queue</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests</b>. The oldest waiting request is at the top.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-02-requests-desktop-6521282d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:18.5%;top:21.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.3%;top:31.7%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless &quot;Email the renter when their request expires that way&quot; is on in Program settings.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-answer-a-request-with-an-offer" data-gd-task><h2 class="gd-h2">Answer a request with an offer</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The Review and offer tab shows the request as the renter sent it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Price on the right updates as you change things.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a message, choose how long the offer stays open, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1060"><img src="/guides/img/admin-03-booking-review-desktop-84570463.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1060"><span class="gd-pin" style="left:21.7%;top:16.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:20%;top:45.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:65%;top:45.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:96.5%;top:98.8%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Changed fields but not ready to send? Press <b class="gd-ui">Save changes</b>. The panel &quot;The offer as the renter sees it&quot; shows the result.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? Press <b class="gd-ui">Decline</b> and fill in Reason and any alternative.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Need an answer first? Press <b class="gd-ui">Ask the renter</b> to send a question.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:620/810"><img src="/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg" alt="" loading="lazy" decoding="async" width="620" height="810"><span class="gd-pin" style="left:91.9%;top:33.6%" aria-hidden="true">5</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-send-an-offer-without-a-request" data-gd-task><h2 class="gd-h2">Send an offer without a request</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Send an offer</b>, or <b class="gd-ui">Send an offer</b> on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The customer: type a name, phone or email and choose them. Not on file? Press <b class="gd-ui">Add a new customer</b>: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason and can be plus tax or tax included. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">The right side is the offer as the renter will see it, priced by the database as you type. Press <b class="gd-ui">Send the offer</b>. <b class="gd-ui">Save without sending</b> keeps it as a request for later.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No &quot;request received&quot; email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-change-an-offer-that-is-out" data-gd-task><h2 class="gd-h2">Change an offer that is out</h2><p class="gd-p">The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press <b class="gd-ui">Edit the offer</b> on the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Write what changed in Message to the renter and choose how long the offer is open.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save and send the update</b>: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press <b class="gd-ui">Save without telling the renter</b> and tell them yourself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A confirmed booking is changed with <b class="gd-ui">Change the booking</b> (Propose a change, below).</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>No need to withdraw first. <b class="gd-ui">Withdraw the offer</b> is only for taking it back for good; <b class="gd-ui">Send again, later expiry</b> gives the renter more time, and <b class="gd-ui">Renter approved by phone</b> records a yes given on a call.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-payments-by-part-the-rental-the-deposit-and-later-charges" data-gd-task><h2 class="gd-h2">Payments by part: the rental, the deposit and later charges</h2><p class="gd-p">On the booking&#39;s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Record a payment</b>: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press <b class="gd-ui">Record it</b>. The renter gets a receipt; <b class="gd-ui">Print</b> prints one to hand over.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Collect a card</b>: a payment, the deposit hold or saving the card. The renter types the card in Stripe&#39;s secure form: on this device (<b class="gd-ui">Open the card form</b>, then hand it over) or by a link texted or emailed to them (<b class="gd-ui">Send the link</b>). Staff never type a card number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A deposit hold lasts about 7 days and shows the days left. After the return, <b class="gd-ui">Capture the hold</b> (all or part, with the reason) or <b class="gd-ui">Release the hold</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Charge the saved card</b> (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter&#39;s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press <b class="gd-ui">Confirm the booking</b>).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press <b class="gd-ui">Returned</b> with the reference or receipt number.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-a-booking" data-gd-task><h2 class="gd-h2">A booking</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Bookings</b>, then a booking number. Or type the number in the search box.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Tabs: Overview, Money, Changes, History, and Drivers and documents.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Overview shows the trip, the renter, what is still missing for the handover, and the price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open tasks for this booking, with the queue and the due time.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Top right: <b class="gd-ui">Stop blocking the calendar</b>, <b class="gd-ui">Cancel for the renter</b> and <b class="gd-ui">Cancel by CarmaCars</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/960"><img src="/guides/img/admin-04-booking-desktop-b56b668a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="960"><span class="gd-pin" style="left:20.1%;top:24%" aria-hidden="true">1</span><span class="gd-pin" style="left:34.7%;top:58.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:20.1%;top:72.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:90.3%;top:18.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-renter-documents-licence-and-proof-of-coverage" data-gd-task><h2 class="gd-h2">Renter documents: licence and proof of coverage</h2><p class="gd-p">A renter&#39;s licence photos, selfie and proof of coverage (OPCF 27 or a credit card&#39;s rental coverage) are checked before the handover. You check them yourself; no task is needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A booking with documents waiting is a line on To do: &quot;Check &#39;s documents for booking &quot;, marked Now when the pickup is within two days. Press <b class="gd-ui">Review documents</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The pop-up shows each driver&#39;s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Tick the checks, then <b class="gd-ui">Approve</b>. Or type the reason the renter reads and press <b class="gd-ui">Reject</b>: they are asked for a new one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The same pop-up is on the booking: the card Renter documents (<b class="gd-ui">Review documents</b>) on Overview and on Drivers and documents.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening of a renter&#39;s documents is logged. The links to the images last one minute.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-propose-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">Propose a change to a confirmed booking</h2><p class="gd-p">The renter gets an email and answers on their booking. The calendar moves only when they accept.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking&#39;s Changes tab. Under Propose a change, set the new pickup, return or car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To price it by hand, type a New rental charge before tax. Leave it empty to use the car&#39;s rates.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the Reason, for the renter. They read it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057?tab=changes</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/530"><img src="/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="530"><span class="gd-pin" style="left:12.9%;top:15.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:35%;top:30.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:49.8%;top:59.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:30.9%;top:73.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-who-a-booking-is-credited-to" data-gd-task><h2 class="gd-h2">Who a booking is credited to</h2><p class="gd-p">Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To give it to someone else, press <b class="gd-ui">Reassign</b>, choose who (or Nobody), say whether they sourced the client and write the reason. The booking&#39;s history and the audit log keep it, and the deal stays in the same week and month.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Someone said they sourced a website request? The credit line shows the claim: press <b class="gd-ui">Credit them</b> or <b class="gd-ui">Not theirs</b>, with a reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press <b class="gd-ui">Mark reviewed</b> once you have looked at it.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.</div></aside></section>');
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

## Add a rental by hand

**Bookings** > **Add a rental**. For phone, walk-in, Turo, partner and insurer bookings.

1. Choose the car and the dates. The check shows clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
2. The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.
3. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
4. Check the price: the car''s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.
5. A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.
6. An owner''s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner''s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press **Insurer confirmed** once the insurer confirms it.
7. Choose Where it came from and how it is paid: **Paid another way**, **Send a payment link**, **Charge the saved card when the renter signs** or **Unpaid: invoice later**.
8. Press **Check the calendar and the price**. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

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

## Add a rental by hand

**Bookings** > **Add a rental**. For phone, walk-in, Turo, partner and insurer bookings, the owner using their own car, and placeholders: a rental already agreed. To send an offer instead, use Send an offer.

1. Quick start sets the usual choices in one tap: **Phone**, **Walk-in**, **Turo or another platform**, **Insurance replacement**, **Owner using own car** or **Placeholder**.
2. Choose the car and the dates. The calendar and the price are checked by themselves: clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
3. The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.
4. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
5. Check the price: the car''s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.
6. A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.
7. An owner''s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner''s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press **Insurer confirmed** once the insurer confirms it.
8. The rental is paid by: e-Transfer or cash (received), card on file (charged when the renter signs), payment link, platform payout (Turo), insurer billed later, cheque, bank transfer, or unpaid. The deposit is taken by card hold, cash, e-Transfer or no deposit.
9. The rental agreement: Send it to sign online, or Already signed on paper (a task asks for the scan). The calendar: untick Blocks the car''s calendar for an insurance replacement with dates not known yet, with the reason.
10. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

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
  '<p class="gd-p">A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.</p><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-car" data-gd-task><h2 class="gd-h2">Add a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then <b class="gd-ui">Add a car</b>. Start with the VIN: everything else about the car comes from it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">When the VIN fits several trims, the form asks which trim it is: press the one on the car&#39;s papers or badge, or <b class="gd-ui">Not sure</b> (Admin &gt; Today asks again).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">No VIN at hand? Press <b class="gd-ui">No VIN at hand? Add the car by its plate</b> and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Choose who supplies it: <b class="gd-ui">A program owner&#39;s car</b> (choose the owner; the car starts its onboarding), <b class="gd-ui">CarmaCars-owned (company fleet)</b> (no owner; all of its revenue is CarmaCars&#39;) or <b class="gd-ui">A partner rental company&#39;s car</b> (choose the partner; leave the commission empty to use the partner&#39;s).</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car&#39;s Rates tab. Press <b class="gd-ui">Add the car</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car&#39;s listing; a field you change is kept.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car&#39;s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.</div></aside><p class="gd-p">The gearbox comes from the government&#39;s fuel economy data for the model when it has one gearbox for it, or from the VIN when the VIN states it. Seats come from the VIN, or the usual number for the body (4 for a coupe or convertible, 5 for a sedan, SUV or hatchback). When either is not certain, Admin &gt; Today shows <b class="gd-ui">Confirm gearbox and seats</b>: press the gearbox and the number of seats, then <b class="gd-ui">Save</b>. A car whose VIN fits several trims shows <b class="gd-ui">Pick the trim</b> there: press the right one. Either way the title, description and search text are written again.</p><p class="gd-p">On a car&#39;s page, <b class="gd-ui">Who supplies the car</b> shows the supplier and the commission, and changes them. Vehicles filters by supply type.</p></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-partners" data-gd-task><h2 class="gd-h2">Partners</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Partners</b>. Partner rental companies whose cars we rent out on commission.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Add a partner</b>: business and legal name, contacts, HST number, commission and insurance with its expiry date.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Staff tasks gets a reminder (Program settings sets how many days before).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Banking (Admins only): <b class="gd-ui">Save the payout account</b> for the account we pay the partner into. The account number is stored encrypted. Press <b class="gd-ui">Verify</b> once checked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Portal: <b class="gd-ui">Invite to the owner portal</b> gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Signed on paper? Press <b class="gd-ui">Print the partner agreement</b>, then record the signed scan under Record a paper signature.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-a-partner-fleet-on-its-own-rates" data-gd-task><h2 class="gd-h2">A partner fleet on its own rates</h2><p class="gd-p">Some partners send a price sheet of their own rates instead of sharing what the renter pays. 01 Motors works this way: its whole fleet is on the site, and staff manage its cars (it has no portal sign-in yet; add its email on the partner page and invite it later).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Partners</b> &gt; the partner. <b class="gd-ui">Pricing</b> shows how it is paid: the renter pays the partner&#39;s sheet rate plus the markup (10% unless you set another), rounded to the nearest dollar; CarmaCars keeps the markup plus its cut (20% of the sheet rate); the partner is owed the rest of its sheet rate. Press <b class="gd-ui">Edit pricing</b> to change the markup, the cut or the basis for every car at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Cars</b> lists each car with its sheet rates a day (1 to 2 days, 3 or more, 7 or more) and the renter&#39;s rates. Press <b class="gd-ui">Edit</b> on a car to change a negotiated rate, give that car its own markup or cut, mark it <b class="gd-ui">Insurance included</b> or <b class="gd-ui">No credit card needed</b>, or confirm its model year. The renter&#39;s rates change at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The site shows these cars with their tiers (1 to 2 days, 3 to 6 days, 7 days or more) and &quot;Guideline rates; final price confirmed after review&quot;. A car with insurance included needs no coverage choice from the renter (coverage option 4, confirmed by itself); a car with no credit card needed takes a debit card for the payment and the deposit. The deposit, the licence and identity checks and the ages stay the same.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The price sheet has no years, VINs or plates. Until you confirm the year, the site leaves it out and says &quot;Year confirmed when you book&quot;; an offer waits until the year is confirmed (Edit on the car, Model year). Add the plate and the VIN on the car&#39;s page before its first handover.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Real photos: open the car (its name in Cars), <b class="gd-ui">Photos</b>, and add them. Once approved they replace the eight studio stand-ins.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The partner&#39;s monthly statement shows each rental at the sheet rate, the cut and the payout; never what the renter paid. A refund lowers the partner&#39;s share in proportion; a discount CarmaCars gives comes out of the markup.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-rental-by-hand" data-gd-task><h2 class="gd-h2">Add a rental by hand</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>. For phone, walk-in, Turo, partner and insurer bookings, the owner using their own car, and placeholders: a rental already agreed. To send an offer instead, use Send an offer.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Quick start sets the usual choices in one tap: <b class="gd-ui">Phone</b>, <b class="gd-ui">Walk-in</b>, <b class="gd-ui">Turo or another platform</b>, <b class="gd-ui">Insurance replacement</b>, <b class="gd-ui">Owner using own car</b> or <b class="gd-ui">Placeholder</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the car and the dates. The calendar and the price are checked by themselves: clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Check the price: the car&#39;s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">An owner&#39;s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner&#39;s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press <b class="gd-ui">Insurer confirmed</b> once the insurer confirms it.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">The rental is paid by: e-Transfer or cash (received), card on file (charged when the renter signs), payment link, platform payout (Turo), insurer billed later, cheque, bank transfer, or unpaid. The deposit is taken by card hold, cash, e-Transfer or no deposit.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">The rental agreement: Send it to sign online, or Already signed on paper (a task asks for the scan). The calendar: untick Blocks the car&#39;s calendar for an insurance replacement with dates not known yet, with the reason.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Tick <b class="gd-ui">Do not email the renter</b> if they should not get the confirmation. Press <b class="gd-ui">Add the rental</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, <b class="gd-ui">Verified in person</b> records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-retire-or-delete-a-car" data-gd-task><h2 class="gd-h2">Retire or delete a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Retire or delete</b>, or the car&#39;s own page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Retire this car</b> takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. <b class="gd-ui">Restore</b> brings it back.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Delete this car</b> removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On the same page, <b class="gd-ui">Delete all sample cars</b> deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-sample-cars-on-the-site" data-gd-task><h2 class="gd-h2">Sample cars on the site</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, or <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Site</b>. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Hide sample cars</b> asks first (&quot;Hide all 20 sample cars from the site?&quot;); press <b class="gd-ui">Hide them</b> to take every sample car off the site at once, or <b class="gd-ui">Keep them</b>. Nothing else stops it: not an enquiry, not an old request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Show sample cars</b> puts the 20 back, with their photos and rates. Ones that were deleted are made again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the site each one is marked &quot;Example car&quot;. They never appear in search engines or the sitemap.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A request on a sample car is never a booking. When the person picks dates, the car page and the request form show a real car free for them (the same make and model first, else the same class and body at a similar price) with one tap to switch to it. If they keep the sample car, it becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car, naming the free real car.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-why-a-car-is-not-on-the-site-yet" data-gd-task><h2 class="gd-h2">Why a car is not on the site yet</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, the card Not on the site yet.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The same car is a line on To do with <b class="gd-ui">Set rates and publish</b>. The car comes off both once it is on the site.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-tolls-when-two-rentals-overlap" data-gd-task><h2 class="gd-h2">Tolls when two rentals overlap</h2><p class="gd-p">Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.</p></section>');
select app.guide_release_section('admin', 'settings', 'chapter', 'search-car-pages-landing-pages-and-guides', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
9. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
10. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

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
', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Protection Plan prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
9. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
10. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

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
',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: Blind Spot&#39;s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Protection Plan prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;Signed here by hand, in ink&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with <b class="gd-ui">Record paper signature</b>. Each form not checked yet is also a line on To do with the same button and Preview it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form&#39;s notes list what to tick or choose at the counter.</div></aside></section><section class="gd-task" id="settings-blind-spot-rental-agreement" data-gd-task><h2 class="gd-h2">Blind Spot rental agreement</h2><p class="gd-p">We rent under Blind Spot Car Rental&#39;s insurance, so every booking has two agreements: CarmaCars&#39; rental agreement and Blind Spot&#39;s own. Blind Spot&#39;s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. The Blind Spot Car Rental agreement card is first. Press <b class="gd-ui">Upload Blind Spot&#39;s PDF</b> and choose Blind Spot&#39;s blank form (2 pages, A4).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled sample</b>: a made-up booking on the form. <b class="gd-ui">Sample billed to an insurer</b> also fills the claim number, the adjuster and the insurance company. Check every box.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars&#39; HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative&#39;s signature instead of Sam&#39;s.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for bookings</b>. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A new version of Blind Spot&#39;s form? Upload it the same way: it waits for <b class="gd-ui">Checked: use for bookings</b>, and bookings keep the version in use until then.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.</div></aside><p class="gd-p">The renter&#39;s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking&#39;s Drivers and documents tab, in the renter&#39;s Documents, and the signed Blind Spot agreement is attached to the &quot;Your signed rental agreement&quot; email. Admin &gt; Today lists the HST number, the upload and the check until they are done.</p></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section>');
select app.guide_release_section('va', 'your-workday', 'chapter', 'start-here', 'Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.

## The menu

My work comes first: To do, Today at a glance, My scorecard and My sales. Customer service and Sales then have Live: Live chat, Live visitors and Game leads. Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.

| Function | Groups and pages |
| --- | --- |
| Customer service | Bookings (Requests, Chauffeur, New quote, Add a rental, Calendar, Find a car), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms) |
| Sales | Bookings (Requests and offers, Chauffeur, New quote, Add a rental, Calendar, Find a car), Owners (Owner leads) |
| Finance | Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote, Find a car) |
| Fleet | Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote, Find a car) |

## To do

Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.

1. The top line shows your function and how many tasks are open.
2. Filter: All, Mine, Unassigned or Waiting. Under More filters: Any time, Overdue, Due today or Escalated, and by type.
3. Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.
4. Press **Take it** to make it yours. Pressing the task opens the screen where it is done: a chat waiting for a person opens that chat, documents to check open the review, a request opens the booking. **Sheet** opens the step-by-step procedure.
5. Tasks close by themselves when their work is done elsewhere (an invoice paid or voided, a chat answered or closed); a day''s opening and closing checks close at the end of that day.

![](/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg "desktop; size: 1440 640; address: carmacars.ca/va; pins: 1 13.9 5.0, 2 36.1 17.5, 3 31.9 43.8, 4 91.7 52.3")

## Work a task

Open the task. The buttons along the top move it on.

| Button | What it does |
| --- | --- |
| **Open the working screen** | Jumps to the booking, car or owner the task is about. |
| **Done** | You finished it. It leaves the queue. |
| **Waiting** | You are waiting on someone (a renter, an owner). It stays yours. |
| **Escalate** | It needs an Admin. Add why. |
| **Hand over** | Give it to someone else on the team. |
| **Add a note** | Leave a note for whoever looks next. |

> Tip: Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.

## Today

1. Today lists pickups and returns, and what is due, for your function.
2. Press a booking number to open it. **To do** takes you back to your tasks.

![](/guides/img/va-cs-02-today-desktop-dfd277b7.jpg "desktop; size: 1440 700; address: carmacars.ca/va/today; pins: 1 20.8 14.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. The queue shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, hours, rate and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). Several documents? One signature covers all of them. The signed copy stays on the same page.

## Several functions? Switch with Working as

If you cover more than one function, **Working as** above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.

## Your scorecard

1. Open **My work** > **My scorecard**.
2. By week shows each measure, its target and your result for each week.
3. A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.
4. The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.

![](/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg "desktop; size: 1440 360; address: carmacars.ca/va/scorecard; pins: 1 4.2 39.7, 2 62.5 58.3")
', 'Your workday', 'The menu, To do, task actions, Today, switching functions and your scorecard.',
  'Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.

## The menu

My work comes first: To do, Today at a glance, My scorecard and My sales. Customer service and Sales then have Live: Live chat, Live visitors and Game leads. Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.

| Function | Groups and pages |
| --- | --- |
| Customer service | Bookings (Requests, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms) |
| Sales | Bookings (Requests and offers, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car), Owners (Owner leads) |
| Finance | Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote, Find a car) |
| Fleet | Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote, Find a car) |

## To do

Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.

1. The top line shows your function and how many tasks are open.
2. Filter: All, Mine, Unassigned or Waiting. Under More filters: Any time, Overdue, Due today or Escalated, and by type.
3. Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.
4. Press **Take it** to make it yours. Pressing the task opens the screen where it is done: a chat waiting for a person opens that chat, documents to check open the review, a request opens the booking. **Sheet** opens the step-by-step procedure.
5. Tasks close by themselves when their work is done elsewhere (an invoice paid or voided, a chat answered or closed); a day''s opening and closing checks close at the end of that day.

![](/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg "desktop; size: 1440 640; address: carmacars.ca/va; pins: 1 13.9 5.0, 2 36.1 17.5, 3 31.9 43.8, 4 91.7 52.3")

## Work a task

Open the task. The buttons along the top move it on.

| Button | What it does |
| --- | --- |
| **Open the working screen** | Jumps to the booking, car or owner the task is about. |
| **Done** | You finished it. It leaves the queue. |
| **Waiting** | You are waiting on someone (a renter, an owner). It stays yours. |
| **Escalate** | It needs an Admin. Add why. |
| **Hand over** | Give it to someone else on the team. |
| **Add a note** | Leave a note for whoever looks next. |

> Tip: Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.

## Today

1. Today lists pickups and returns, and what is due, for your function.
2. Press a booking number to open it. **To do** takes you back to your tasks.

![](/guides/img/va-cs-02-today-desktop-dfd277b7.jpg "desktop; size: 1440 700; address: carmacars.ca/va/today; pins: 1 20.8 14.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. The queue shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, hours, rate and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). Several documents? One signature covers all of them. The signed copy stays on the same page.

## Several functions? Switch with Working as

If you cover more than one function, **Working as** above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.

## Your scorecard

1. Open **My work** > **My scorecard**.
2. By week shows each measure, its target and your result for each week.
3. A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.
4. The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.

![](/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg "desktop; size: 1440 360; address: carmacars.ca/va/scorecard; pins: 1 4.2 39.7, 2 62.5 58.3")
',
  '<p class="gd-p">Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.</p><section class="gd-task" id="your-workday-the-menu" data-gd-task><h2 class="gd-h2">The menu</h2><p class="gd-p">My work comes first: To do, Today at a glance, My scorecard and My sales. Customer service and Sales then have Live: Live chat, Live visitors and Game leads. Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Function</th><th scope="col">Groups and pages</th></tr></thead><tbody><tr><td>Customer service</td><td>Bookings (Requests, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms)</td></tr><tr><td>Sales</td><td>Bookings (Requests and offers, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car), Owners (Owner leads)</td></tr><tr><td>Finance</td><td>Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote, Find a car)</td></tr><tr><td>Fleet</td><td>Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote, Find a car)</td></tr></tbody></table></div></section><section class="gd-task" id="your-workday-to-do" data-gd-task><h2 class="gd-h2">To do</h2><p class="gd-p">Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The top line shows your function and how many tasks are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Filter: All, Mine, Unassigned or Waiting. Under More filters: Any time, Overdue, Due today or Escalated, and by type.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Take it</b> to make it yours. Pressing the task opens the screen where it is done: a chat waiting for a person opens that chat, documents to check open the review, a request opens the booking. <b class="gd-ui">Sheet</b> opens the step-by-step procedure.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Tasks close by themselves when their work is done elsewhere (an invoice paid or voided, a chat answered or closed); a day&#39;s opening and closing checks close at the end of that day.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:13.9%;top:5%" aria-hidden="true">1</span><span class="gd-pin" style="left:36.1%;top:17.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:31.9%;top:43.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:91.7%;top:52.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="your-workday-work-a-task" data-gd-task><h2 class="gd-h2">Work a task</h2><p class="gd-p">Open the task. The buttons along the top move it on.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">What it does</th></tr></thead><tbody><tr><td><b class="gd-ui">Open the working screen</b></td><td>Jumps to the booking, car or owner the task is about.</td></tr><tr><td><b class="gd-ui">Done</b></td><td>You finished it. It leaves the queue.</td></tr><tr><td><b class="gd-ui">Waiting</b></td><td>You are waiting on someone (a renter, an owner). It stays yours.</td></tr><tr><td><b class="gd-ui">Escalate</b></td><td>It needs an Admin. Add why.</td></tr><tr><td><b class="gd-ui">Hand over</b></td><td>Give it to someone else on the team.</td></tr><tr><td><b class="gd-ui">Add a note</b></td><td>Leave a note for whoever looks next.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.</div></aside></section><section class="gd-task" id="your-workday-today" data-gd-task><h2 class="gd-h2">Today</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Today lists pickups and returns, and what is due, for your function.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press a booking number to open it. <b class="gd-ui">To do</b> takes you back to your tasks.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/today</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/700"><img src="/guides/img/va-cs-02-today-desktop-dfd277b7.jpg" alt="" loading="lazy" decoding="async" width="1440" height="700"><span class="gd-pin" style="left:20.8%;top:14.3%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="your-workday-documents-to-sign" data-gd-task><h2 class="gd-h2">Documents to sign</h2><p class="gd-p">Your staff agreement, when CarmaCars sends it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The queue shows &quot;You have a document to sign&quot;. Press <b class="gd-ui">Read and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values at the top (your role, hours, rate and start date), then press <b class="gd-ui">Read the PDF</b> and read it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. Your full legal name is your signature (or press <b class="gd-ui">Draw instead</b>). Several documents? One signature covers all of them. The signed copy stays on the same page.</div></li></ol></div></section><section class="gd-task" id="your-workday-several-functions-switch-with-working-as" data-gd-task><h2 class="gd-h2">Several functions? Switch with Working as</h2><p class="gd-p">If you cover more than one function, <b class="gd-ui">Working as</b> above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.</p></section><section class="gd-task" id="your-workday-your-scorecard" data-gd-task><h2 class="gd-h2">Your scorecard</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">My scorecard</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">By week shows each measure, its target and your result for each week.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/scorecard</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/360"><img src="/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg" alt="" loading="lazy" decoding="async" width="1440" height="360"><span class="gd-pin" style="left:4.2%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:62.5%;top:58.3%" aria-hidden="true">2</span></div></div></figure></div></section>');
select app.guide_release_section('va', 'customer-service', 'chapter', 'your-workday', 'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests**. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10056?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after **Free:** (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.
2. Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## A request from a vehicle page

Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.

1. The request arrives as an enquiry with the car named in the message ("About the car: 2023 Toyota RAV4 XLE") and an Enquiry task in To do.
2. If we have that car, or one close to it, free for their dates, make a **New quote** for it. If not, suggest the nearest car of the same kind and price.
3. Reply by email or phone, then mark the task done.

> Tip: The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.

## A buyer lead from a /buy page

Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with "Find me this car", and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.

1. The lead is in **Owner leads** (customer service: **Owners and enquiries**), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.
2. If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a "Mechanical work to arrange" task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop''s price or time, and offer a rental while their car is in.
3. Press **Take it**, then **Update** as you go: contacted, qualified, converted or closed with the reason.

> Tip: We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Add a car for an owner

Open **Owners** > **Add a car for an owner** (fleet: under Cars). You enter everything for the owner; they never fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
3. Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.
5. Press **Add the car and send to an Admin**. The application waits in the Admin''s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded, with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## A rental agreement signed on paper

1. Open the booking. Under Signed on paper, press **Record paper signature**.
2. Choose the Rental agreement, or the booking change the renter signed.
3. Check Signed by and Date signed, and upload the scan of every signed page.
4. Press **Record signature**. It counts as signed, and the renter is not asked to sign again.

## Check renter documents

The renter''s licence photos, selfie and proof of coverage, before the handover.

1. Open the task "identity documents or coverage proof to review", or open the booking: **Review** shows the documents of any booking being arranged or under way, with no task needed.
2. Tick every check under a document, then press **Approve**. Or type the reason the renter reads and press **Reject**.
3. The coverage: OPCF 27 shows the insurer, policy number and expiry; credit card coverage shows the card, its type and whether the name matches. Approve or reject it as a whole.

> Tip: Each opening is logged. An Admin can do the same from Admin > To do.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. Work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |
', 'Customer service', 'Requests and offers, new quotes, renter messages, find a renter, owner forms, late returns.',
  'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests**. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10056?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after **Free:** (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.
2. Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## A request from a vehicle page

Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.

1. The request arrives as an enquiry with the car named in the message ("About the car: 2023 Toyota RAV4 XLE") and an Enquiry task in To do.
2. If we have that car, or one close to it, free for their dates, make a **New quote** for it. If not, suggest the nearest car of the same kind and price.
3. Reply by email or phone, then mark the task done.

> Tip: The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.

## A buyer lead from a /buy page

Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with "Find me this car", and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.

1. The lead is in **Owner leads** (customer service: **Owners and enquiries**), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.
2. If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a "Mechanical work to arrange" task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop''s price or time, and offer a rental while their car is in.
3. Press **Take it**, then **Update** as you go: contacted, qualified, converted or closed with the reason.

> Tip: We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.

## Send an offer to a caller

Open **Send an offer** (or **Send an offer** beside a car in Find a car). No request needed: one screen, and the renter has the link.

1. Find the customer by name, phone or email, or press **Add a new customer**: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.
2. Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.
3. The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price.
4. How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.
5. Check the offer as the renter will see it on the right, then press **Send the offer**.

> Tip: An offer that is out is changed in place: **Edit the offer**, change it, then **Save and send the update** or **Save without telling the renter**. No need to withdraw it first.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Add a car for an owner

Open **Owners** > **Add a car for an owner** (fleet: under Cars). You enter everything for the owner; they never fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
3. Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.
5. Press **Add the car and send to an Admin**. The application waits in the Admin''s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded, with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## A rental agreement signed on paper

1. Open the booking. Under Signed on paper, press **Record paper signature**.
2. Choose the Rental agreement, or the booking change the renter signed.
3. Check Signed by and Date signed, and upload the scan of every signed page.
4. Press **Record signature**. It counts as signed, and the renter is not asked to sign again.

## Check renter documents

The renter''s licence photos, selfie and proof of coverage, before the handover.

1. Open the task "identity documents or coverage proof to review", or open the booking: **Review** shows the documents of any booking being arranged or under way, with no task needed.
2. Tick every check under a document, then press **Approve**. Or type the reason the renter reads and press **Reject**.
3. The coverage: OPCF 27 shows the insurer, policy number and expiry; credit card coverage shows the card, its type and whether the name matches. Approve or reject it as a whole.

> Tip: Each opening is logged. An Admin can do the same from Admin > To do.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. Work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |
',
  '<p class="gd-p">You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter&#39;s first person.</p><p class="gd-p">Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.</p><section class="gd-task" id="customer-service-answer-a-request" data-gd-task><h2 class="gd-h2">Answer a request</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Requests</b>. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited. Open the booking number.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:27.1%;top:17.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:52.8%;top:32.8%" aria-hidden="true">2</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the Review tab, check the request: the car is free, the renter, the places.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Adjust the booking</b> to change the car, dates, places, price or extras, then <b class="gd-ui">Save changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Add a message and press <b class="gd-ui">Send the offer</b>. Within your limit you can also use <b class="gd-ui">Approve (within my limit)</b> or <b class="gd-ui">Approve and send the pay link</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? <b class="gd-ui">Decline</b> with Reason and any alternative. Need to know more? <b class="gd-ui">Ask the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:69.4%;top:24%" aria-hidden="true">3</span><span class="gd-pin" style="left:95.8%;top:98%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within 5 minutes: send the offer, or ask the renter what you need. That is the &quot;First reply in opening hours&quot; measure on your scorecard. Requests waiting longer show in red.</div></aside></section><section class="gd-task" id="customer-service-an-enquiry-on-an-example-car" data-gd-task><h2 class="gd-h2">An enquiry on an example car</h2><p class="gd-p">Some cars on the site are marked &quot;Example car&quot;: samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after <b class="gd-ui">Free:</b> (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a <b class="gd-ui">New quote</b> for it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Call or email the person with the car and the price, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.</div></aside></section><section class="gd-task" id="customer-service-a-request-from-a-vehicle-page" data-gd-task><h2 class="gd-h2">A request from a vehicle page</h2><p class="gd-p">Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The request arrives as an enquiry with the car named in the message (&quot;About the car: 2023 Toyota RAV4 XLE&quot;) and an Enquiry task in To do.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If we have that car, or one close to it, free for their dates, make a <b class="gd-ui">New quote</b> for it. If not, suggest the nearest car of the same kind and price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Reply by email or phone, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.</div></aside></section><section class="gd-task" id="customer-service-a-buyer-lead-from-a-buy-page" data-gd-task><h2 class="gd-h2">A buyer lead from a /buy page</h2><p class="gd-p">Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with &quot;Find me this car&quot;, and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The lead is in <b class="gd-ui">Owner leads</b> (customer service: <b class="gd-ui">Owners and enquiries</b>), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a &quot;Mechanical work to arrange&quot; task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop&#39;s price or time, and offer a rental while their car is in.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take it</b>, then <b class="gd-ui">Update</b> as you go: contacted, qualified, converted or closed with the reason.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.</div></aside></section><section class="gd-task" id="customer-service-send-an-offer-to-a-caller" data-gd-task><h2 class="gd-h2">Send an offer to a caller</h2><p class="gd-p">Open <b class="gd-ui">Send an offer</b> (or <b class="gd-ui">Send an offer</b> beside a car in Find a car). No request needed: one screen, and the renter has the link.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Find the customer by name, phone or email, or press <b class="gd-ui">Add a new customer</b>: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Check the offer as the renter will see it on the right, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An offer that is out is changed in place: <b class="gd-ui">Edit the offer</b>, change it, then <b class="gd-ui">Save and send the update</b> or <b class="gd-ui">Save without telling the renter</b>. No need to withdraw it first.</div></aside></section><section class="gd-task" id="customer-service-new-quote-for-a-caller" data-gd-task><h2 class="gd-h2">New quote for a caller</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">New quote</b>. Choose the Car, the Pickup and Return (at least 2 hours from now).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose how the lead came in, then the caller&#39;s Full legal name, Email, Mobile and Date of birth.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Set the Licence class and Damage cover, and note places, extras and what they asked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Create the request</b>. It opens like any request; send the offer from there.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/quotes/new</span></div><div class="gd-imgwrap" style="aspect-ratio:1220/1260"><img src="/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg" alt="" loading="lazy" decoding="async" width="1220" height="1260"><span class="gd-pin" style="left:72.1%;top:15.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:72.1%;top:41.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:72.1%;top:72.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:63.9%;top:85.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="customer-service-renter-messages-and-find-a-renter" data-gd-task><h2 class="gd-h2">Renter messages and Find a renter</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Renter messages</b> lists the latest messages with their booking. Open the booking to reply, then press <b class="gd-ui">Send</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Find a renter</b>: search by name, email, phone or booking number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To open a renter&#39;s private details, press <b class="gd-ui">Open with a reason</b>. The reason is kept in the access log.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/messages</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/260"><img src="/guides/img/va-cs-06-messages-desktop-3441fa91.jpg" alt="" loading="lazy" decoding="async" width="1440" height="260"><span class="gd-pin" style="left:32.6%;top:48.5%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="customer-service-add-a-car-for-an-owner" data-gd-task><h2 class="gd-h2">Add a car for an owner</h2><p class="gd-p">Open <b class="gd-ui">Owners</b> &gt; <b class="gd-ui">Add a car for an owner</b> (fleet: under Cars). You enter everything for the owner; they never fill in the application.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender&#39;s information if you have them. Photos are optional.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Add the car and send to an Admin</b>. The application waits in the Admin&#39;s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.</div></li></ol></div></section><section class="gd-task" id="customer-service-owner-forms-forms-c-and-d" data-gd-task><h2 class="gd-h2">Owner forms (Forms C and D)</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Owner forms</b>. Each row is a scan an owner uploaded, with the witnesses and the status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the scan. Check every page is there and signed, with each witness&#39;s signature and name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/300"><img src="/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="300"><span class="gd-pin" style="left:68.6%;top:36.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:36.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="customer-service-a-rental-agreement-signed-on-paper" data-gd-task><h2 class="gd-h2">A rental agreement signed on paper</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking. Under Signed on paper, press <b class="gd-ui">Record paper signature</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Rental agreement, or the booking change the renter signed.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check Signed by and Date signed, and upload the scan of every signed page.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Record signature</b>. It counts as signed, and the renter is not asked to sign again.</div></li></ol></div></section><section class="gd-task" id="customer-service-check-renter-documents" data-gd-task><h2 class="gd-h2">Check renter documents</h2><p class="gd-p">The renter&#39;s licence photos, selfie and proof of coverage, before the handover.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the task &quot;identity documents or coverage proof to review&quot;, or open the booking: <b class="gd-ui">Review</b> shows the documents of any booking being arranged or under way, with no task needed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tick every check under a document, then press <b class="gd-ui">Approve</b>. Or type the reason the renter reads and press <b class="gd-ui">Reject</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The coverage: OPCF 27 shows the insurer, policy number and expiry; credit card coverage shows the card, its type and whether the name matches. Approve or reject it as a whole.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening is logged. An Admin can do the same from Admin &gt; To do.</div></aside></section><section class="gd-task" id="customer-service-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">A change to a confirmed booking</h2><p class="gd-p">On a booking&#39;s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.</p></section><section class="gd-task" id="customer-service-a-late-return" data-gd-task><h2 class="gd-h2">A late return</h2><p class="gd-p">A booking past its return time shows the late return panel. Work it in order:</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">When</th></tr></thead><tbody><tr><td><b class="gd-ui">Log a call</b></td><td>Record each call to the renter and what they said.</td></tr><tr><td><b class="gd-ui">Send T13</b></td><td>The first late notice email.</td></tr><tr><td><b class="gd-ui">Send T14 (final notice)</b></td><td>The final notice.</td></tr><tr><td><b class="gd-ui">Request disable</b></td><td>Ask an Admin to approve disabling the car.</td></tr><tr><td><b class="gd-ui">Open an incident</b></td><td>When the car is not coming back as planned.</td></tr></tbody></table></div></section>');
select app.guide_release_section('va', 'finance', 'chapter', 'chauffeur-requests', 'You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips.

Your rail: Queue, Today, Payments, deposits, refunds, Tolls and tickets, Reconciliation, Turo trips, Find a renter, Calendar and Scorecard.

## Your queue

Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.

![The type filters show what Finance handles: collect upfront, debit failed, match toll, refund cancellation and review statements.](/guides/img/va-finance-01-queue-desktop-295e545d.jpg "desktop; size: 1440 560; address: carmacars.ca/va; pins: 1 26.4 45.4")

## Payments, deposits, refunds

1. Failed payments: each with the purpose, amount and the bank''s reason.
2. Deposits to take before pickup, and deposits due back.
3. Refunds in progress. Press **Request the refund** and choose What it refunds (the rental charge, delivery or pickup, kilometres, add-ons or other charges); above your limit it waits for an Admin. Then **Issue the refund**.
4. Owner invoices that failed, and owner statements to prepare.

![](/guides/img/va-finance-02-money-desktop-70fea0c7.jpg "desktop; size: 1230 1060; address: carmacars.ca/va/money; pins: 1 10.6 6.6, 2 12.2 19.2, 3 10.6 57.3, 4 13.0 73.2")

## A payment received another way

An owner or renter paid by e-Transfer, cheque, cash or bank transfer.

1. Owner invoice: on **Payments, deposits, refunds**, find it under Owner invoices owing and press **Record payment**.
2. Renter: beside the failed payment, press **Paid another way**. Or open the booking''s Money tab and press **Record a payment received another way**.
3. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.
4. Add the proof if you have it (a screenshot or a photo of the cheque), then press **Record payment**.

The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.

Each month''s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.

## Read a toll notice

1. Open **Tolls and tickets** and press **Read a notice**.
2. Choose the file: a PDF, a photo or a CSV, under 15 MB. Leave the reading profile to find it from the text.
3. Press **Read it**. Then check each line beside the notice and fix what was read wrong.
4. Press **Checked against the notice** on each line (**Leave out** to skip one), then **Save as checked** and **Confirm and import**.

![](/guides/img/va-finance-04-tolls-read-desktop-aa04a6b2.jpg "desktop; size: 1230 580; address: carmacars.ca/va/tolls/read; pins: 2 19.5 44.1, 3 4.1 64.8, 4 4.1 89.7")

> Tip: In the work queue, **Match again** retries the match after a fix, and **Dispute** marks a notice you think is wrong. Renters matched with high confidence are charged at import, with the notice and our fee.

![The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice''s plate, date, amount and match.](/guides/img/va-finance-03-tolls-desktop-37b6f99c.jpg "desktop; size: 1230 540; address: carmacars.ca/va/tolls; pins: 1 23.6 12.2")

## Reconciliation and Turo trips

1. **Reconciliation**: press **Record a processor payout**, then **Match** it to the payments it contains. Anything still unmatched at the closing check goes to an Admin.
2. **Turo trips**: press **Add a trip** for one trip, or paste CSV rows and press **Import**.

![](/guides/img/va-finance-06-turo-desktop-b59cc7f9.jpg "desktop; size: 1230 540; address: carmacars.ca/va/turo; pins: 2 95.1 14.8")
', 'Finance', 'Payments, deposits and refunds, tolls and tickets, reconciliation and Turo trips.',
  'You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips.

Your rail: Queue, Today, Payments, deposits, refunds, Tolls and tickets, Reconciliation, Turo trips, Find a renter, Calendar and Scorecard.

## Your queue

Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.

![The type filters show what Finance handles: collect upfront, debit failed, match toll, refund cancellation and review statements.](/guides/img/va-finance-01-queue-desktop-295e545d.jpg "desktop; size: 1440 560; address: carmacars.ca/va; pins: 1 26.4 45.4")

## Payments, deposits, refunds

1. Failed payments: each with the purpose, amount and the bank''s reason.
2. Deposits to take before pickup, and deposits due back.
3. Refunds in progress. Press **Request the refund** and choose What it refunds (the rental charge, delivery or pickup, kilometres, add-ons or other charges); above your limit it waits for an Admin. Then **Issue the refund**.
4. Owner invoices that failed, and owner statements to prepare.

![](/guides/img/va-finance-02-money-desktop-70fea0c7.jpg "desktop; size: 1230 1060; address: carmacars.ca/va/money; pins: 1 10.6 6.6, 2 12.2 19.2, 3 10.6 57.3, 4 13.0 73.2")

## A payment received another way

An owner or renter paid by e-Transfer, cheque, cash or bank transfer.

1. Owner invoice: on **Payments, deposits, refunds**, find it under Owner invoices owing and press **Record payment**.
2. Renter: beside the failed payment, press **Paid another way**. Or open the booking''s Money tab: under Money by part press **Record a payment**, choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid, then **Record it**.
3. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.
4. Add the proof if you have it (a screenshot or a photo of the cheque), then press **Record payment**.

The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.

Each month''s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.

## Cards, holds and deposits given back

On the booking''s Money tab.

1. **Charge the saved card**: a later charge (extra kilometres, fuel, damage, a late return) with the reason on the renter''s receipt, or the deposit of a rental over 7 days.
2. A deposit hold: **Capture the hold** for all or part of it, with the reason (the rest is released), or **Release the hold**.
3. A deposit taken in cash or by e-Transfer is given back the same way: the task Give the deposit back the way it came; then press **Returned** with the reference or receipt number.

## Read a toll notice

1. Open **Tolls and tickets** and press **Read a notice**.
2. Choose the file: a PDF, a photo or a CSV, under 15 MB. Leave the reading profile to find it from the text.
3. Press **Read it**. Then check each line beside the notice and fix what was read wrong.
4. Press **Checked against the notice** on each line (**Leave out** to skip one), then **Save as checked** and **Confirm and import**.

![](/guides/img/va-finance-04-tolls-read-desktop-aa04a6b2.jpg "desktop; size: 1230 580; address: carmacars.ca/va/tolls/read; pins: 2 19.5 44.1, 3 4.1 64.8, 4 4.1 89.7")

> Tip: In the work queue, **Match again** retries the match after a fix, and **Dispute** marks a notice you think is wrong. Renters matched with high confidence are charged at import, with the notice and our fee.

![The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice''s plate, date, amount and match.](/guides/img/va-finance-03-tolls-desktop-37b6f99c.jpg "desktop; size: 1230 540; address: carmacars.ca/va/tolls; pins: 1 23.6 12.2")

## Reconciliation and Turo trips

1. **Reconciliation**: press **Record a processor payout**, then **Match** it to the payments it contains. Anything still unmatched at the closing check goes to an Admin.
2. **Turo trips**: press **Add a trip** for one trip, or paste CSV rows and press **Import**.

![](/guides/img/va-finance-06-turo-desktop-b59cc7f9.jpg "desktop; size: 1230 540; address: carmacars.ca/va/turo; pins: 2 95.1 14.8")
',
  '<p class="gd-p">You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips.</p><p class="gd-p">Your rail: Queue, Today, Payments, deposits, refunds, Tolls and tickets, Reconciliation, Turo trips, Find a renter, Calendar and Scorecard.</p><section class="gd-task" id="finance-your-queue" data-gd-task><h2 class="gd-h2">Your queue</h2><p class="gd-p">Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.</p><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/va-finance-01-queue-desktop-295e545d.jpg" alt="The type filters show what Finance handles: collect upfront, debit failed, match toll, refund cancellation and review statements." loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:26.4%;top:45.4%" aria-hidden="true">1</span></div></div><figcaption>The type filters show what Finance handles: collect upfront, debit failed, match toll, refund cancellation and review statements.</figcaption></figure></div></section><section class="gd-task" id="finance-payments-deposits-refunds" data-gd-task><h2 class="gd-h2">Payments, deposits, refunds</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Failed payments: each with the purpose, amount and the bank&#39;s reason.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Deposits to take before pickup, and deposits due back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Refunds in progress. Press <b class="gd-ui">Request the refund</b> and choose What it refunds (the rental charge, delivery or pickup, kilometres, add-ons or other charges); above your limit it waits for an Admin. Then <b class="gd-ui">Issue the refund</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Owner invoices that failed, and owner statements to prepare.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/money</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/1060"><img src="/guides/img/va-finance-02-money-desktop-70fea0c7.jpg" alt="" loading="lazy" decoding="async" width="1230" height="1060"><span class="gd-pin" style="left:10.6%;top:6.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:12.2%;top:19.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:10.6%;top:57.3%" aria-hidden="true">3</span><span class="gd-pin" style="left:13%;top:73.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="finance-a-payment-received-another-way" data-gd-task><h2 class="gd-h2">A payment received another way</h2><p class="gd-p">An owner or renter paid by e-Transfer, cheque, cash or bank transfer.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Owner invoice: on <b class="gd-ui">Payments, deposits, refunds</b>, find it under Owner invoices owing and press <b class="gd-ui">Record payment</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Renter: beside the failed payment, press <b class="gd-ui">Paid another way</b>. Or open the booking&#39;s Money tab: under Money by part press <b class="gd-ui">Record a payment</b>, choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid, then <b class="gd-ui">Record it</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add the proof if you have it (a screenshot or a photo of the cheque), then press <b class="gd-ui">Record payment</b>.</div></li></ol></div><p class="gd-p">The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.</p><p class="gd-p">Each month&#39;s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.</p></section><section class="gd-task" id="finance-cards-holds-and-deposits-given-back" data-gd-task><h2 class="gd-h2">Cards, holds and deposits given back</h2><p class="gd-p">On the booking&#39;s Money tab.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Charge the saved card</b>: a later charge (extra kilometres, fuel, damage, a late return) with the reason on the renter&#39;s receipt, or the deposit of a rental over 7 days.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A deposit hold: <b class="gd-ui">Capture the hold</b> for all or part of it, with the reason (the rest is released), or <b class="gd-ui">Release the hold</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A deposit taken in cash or by e-Transfer is given back the same way: the task Give the deposit back the way it came; then press <b class="gd-ui">Returned</b> with the reference or receipt number.</div></li></ol></div></section><section class="gd-task" id="finance-read-a-toll-notice" data-gd-task><h2 class="gd-h2">Read a toll notice</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Tolls and tickets</b> and press <b class="gd-ui">Read a notice</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the file: a PDF, a photo or a CSV, under 15 MB. Leave the reading profile to find it from the text.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Read it</b>. Then check each line beside the notice and fix what was read wrong.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked against the notice</b> on each line (<b class="gd-ui">Leave out</b> to skip one), then <b class="gd-ui">Save as checked</b> and <b class="gd-ui">Confirm and import</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/tolls/read</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/580"><img src="/guides/img/va-finance-04-tolls-read-desktop-aa04a6b2.jpg" alt="" loading="lazy" decoding="async" width="1230" height="580"><span class="gd-pin" style="left:19.5%;top:44.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:4.1%;top:64.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:4.1%;top:89.7%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>In the work queue, <b class="gd-ui">Match again</b> retries the match after a fix, and <b class="gd-ui">Dispute</b> marks a notice you think is wrong. Renters matched with high confidence are charged at import, with the notice and our fee.</div></aside><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/tolls</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/540"><img src="/guides/img/va-finance-03-tolls-desktop-37b6f99c.jpg" alt="The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice&#39;s plate, date, amount and match." loading="lazy" decoding="async" width="1230" height="540"><span class="gd-pin" style="left:23.6%;top:12.2%" aria-hidden="true">1</span></div></div><figcaption>The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice&#39;s plate, date, amount and match.</figcaption></figure></div></section><section class="gd-task" id="finance-reconciliation-and-turo-trips" data-gd-task><h2 class="gd-h2">Reconciliation and Turo trips</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Reconciliation</b>: press <b class="gd-ui">Record a processor payout</b>, then <b class="gd-ui">Match</b> it to the payments it contains. Anything still unmatched at the closing check goes to an Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Turo trips</b>: press <b class="gd-ui">Add a trip</b> for one trip, or paste CSV rows and press <b class="gd-ui">Import</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/turo</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/540"><img src="/guides/img/va-finance-06-turo-desktop-b59cc7f9.jpg" alt="" loading="lazy" decoding="async" width="1230" height="540"><span class="gd-pin" style="left:95.1%;top:14.8%" aria-hidden="true">2</span></div></div></figure></div></section>');
select app.guide_release_section('va', 'sales', 'chapter', 'fleet', 'You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.

Your menu: To do, Today, My scorecard and My sales, then Requests and offers, New quote, Add a rental, Calendar and Owner leads.

## Requests, offers and new quotes

1. **Requests and offers**: the same queue customer service works. Answer requests and follow offers out.
2. **New quote**: price a car for a caller and press **Create the request**, as in chapter 2.

![](/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg "desktop; size: 1230 580; address: carmacars.ca/va/requests; pins: 1 13.8 19.3")

> Tip: Your first reply target is 5 minutes, the "Quote sent" measure on your scorecard. Follow every offer out before it expires.

## My sales

Open **My work** > **My sales**. It shows your own sales and commissions only.

1. Commissions comes first. In Sales your rate depends on the rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%. The bar shows your days against the target of 100, and says when your rate rises.
2. The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press **By month** for months, **By week** for weeks.
3. By week (or By month) lists each period with the same figures, newest first.
4. Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.
5. Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.

| Figure | How it is counted |
| --- | --- |
| Credited to you | A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else. |
| Quotes created, offers sent, rentals added | Counted on the day they happened. |
| Bookings confirmed, booked revenue | Counted on the day the booking was confirmed. |
| Conversion | Of the deals credited to you in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off. |
| Rental days (Sales) | The days of the completed, paid rentals you sourced that end in the month. The month''s tier applies to all of that month''s rentals. |

> Tip: Sales commissions are approved after the month ends, when the month''s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.

## Owner leads

1. Owner leads: each enquiry with the name, contact, car and status.
2. Press **Take it** to make it yours, then call the owner.
3. Press **Update** to set the status. When you close a lead, say why.
4. Owner applications, last 90 days, shows who applied and how far onboarding has come.

![](/guides/img/va-sales-04-leads-desktop-3402e913.jpg "desktop; size: 1230 400; address: carmacars.ca/va/leads; pins: 1 6.5 26.5, 3 94.8 44.0, 4 15.4 63.0")
', 'Sales', 'Requests and offers, new quotes and owner leads.',
  'You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.

Your menu: To do, Today, My scorecard and My sales, then Requests and offers, Send an offer, Add a rental, New quote, Calendar and Owner leads.

## Requests, offers and new quotes

1. **Requests and offers**: the same queue customer service works. Answer requests and follow offers out.
2. **Send an offer**: one screen for a caller, sent at once, as in chapter 2. **New quote** still makes a request to offer later.
3. An offer that is out: **Edit the offer**, then **Save and send the update**.

![](/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg "desktop; size: 1230 580; address: carmacars.ca/va/requests; pins: 1 13.8 19.3")

> Tip: Your first reply target is 5 minutes, the "Quote sent" measure on your scorecard. Follow every offer out before it expires.

## My sales

Open **My work** > **My sales**. It shows your own sales and commissions only.

1. Commissions comes first. In Sales your rate depends on the rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%. The bar shows your days against the target of 100, and says when your rate rises.
2. The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press **By month** for months, **By week** for weeks.
3. By week (or By month) lists each period with the same figures, newest first.
4. Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.
5. Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.

| Figure | How it is counted |
| --- | --- |
| Credited to you | A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else. |
| Quotes created, offers sent, rentals added | Counted on the day they happened. |
| Bookings confirmed, booked revenue | Counted on the day the booking was confirmed. |
| Conversion | Of the deals credited to you in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off. |
| Rental days (Sales) | The days of the completed, paid rentals you sourced that end in the month. The month''s tier applies to all of that month''s rentals. |

> Tip: Sales commissions are approved after the month ends, when the month''s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.

## Owner leads

1. Owner leads: each enquiry with the name, contact, car and status.
2. Press **Take it** to make it yours, then call the owner.
3. Press **Update** to set the status. When you close a lead, say why.
4. Owner applications, last 90 days, shows who applied and how far onboarding has come.

![](/guides/img/va-sales-04-leads-desktop-3402e913.jpg "desktop; size: 1230 400; address: carmacars.ca/va/leads; pins: 1 6.5 26.5, 3 94.8 44.0, 4 15.4 63.0")
',
  '<p class="gd-p">You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.</p><p class="gd-p">Your menu: To do, Today, My scorecard and My sales, then Requests and offers, Send an offer, Add a rental, New quote, Calendar and Owner leads.</p><section class="gd-task" id="sales-requests-offers-and-new-quotes" data-gd-task><h2 class="gd-h2">Requests, offers and new quotes</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Requests and offers</b>: the same queue customer service works. Answer requests and follow offers out.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Send an offer</b>: one screen for a caller, sent at once, as in chapter 2. <b class="gd-ui">New quote</b> still makes a request to offer later.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">An offer that is out: <b class="gd-ui">Edit the offer</b>, then <b class="gd-ui">Save and send the update</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/580"><img src="/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg" alt="" loading="lazy" decoding="async" width="1230" height="580"><span class="gd-pin" style="left:13.8%;top:19.3%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Your first reply target is 5 minutes, the &quot;Quote sent&quot; measure on your scorecard. Follow every offer out before it expires.</div></aside></section><section class="gd-task" id="sales-my-sales" data-gd-task><h2 class="gd-h2">My sales</h2><p class="gd-p">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">My sales</b>. It shows your own sales and commissions only.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Commissions comes first. In Sales your rate depends on the rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%. The bar shows your days against the target of 100, and says when your rate rises.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press <b class="gd-ui">By month</b> for months, <b class="gd-ui">By week</b> for weeks.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">By week (or By month) lists each period with the same figures, newest first.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Figure</th><th scope="col">How it is counted</th></tr></thead><tbody><tr><td>Credited to you</td><td>A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else.</td></tr><tr><td>Quotes created, offers sent, rentals added</td><td>Counted on the day they happened.</td></tr><tr><td>Bookings confirmed, booked revenue</td><td>Counted on the day the booking was confirmed.</td></tr><tr><td>Conversion</td><td>Of the deals credited to you in the period, the share confirmed so far.</td></tr><tr><td>Booked revenue</td><td>The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off.</td></tr><tr><td>Rental days (Sales)</td><td>The days of the completed, paid rentals you sourced that end in the month. The month&#39;s tier applies to all of that month&#39;s rentals.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Sales commissions are approved after the month ends, when the month&#39;s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.</div></aside></section><section class="gd-task" id="sales-owner-leads" data-gd-task><h2 class="gd-h2">Owner leads</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Owner leads: each enquiry with the name, contact, car and status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Take it</b> to make it yours, then call the owner.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Update</b> to set the status. When you close a lead, say why.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Owner applications, last 90 days, shows who applied and how far onboarding has come.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/leads</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/400"><img src="/guides/img/va-sales-04-leads-desktop-3402e913.jpg" alt="" loading="lazy" decoding="async" width="1230" height="400"><span class="gd-pin" style="left:6.5%;top:26.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.8%;top:44%" aria-hidden="true">3</span><span class="gd-pin" style="left:15.4%;top:63%" aria-hidden="true">4</span></div></div></figure></div></section>');
select app.guide_release_section('va', 'add-a-rental-by-hand', 'chapter', 'sales', 'Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.

## Add a rental

Open **Bookings** > **Add a rental**. Your home address must be in your profile first: until it is, the page asks for it.

1. Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.
2. The dates decide the case, shown under them. Car already out with the renter? Enter the pickup as when it left: the rental is recorded as on trip, and anything still missing (signature, licence check, coverage proof, deposit) becomes a task. A rental that has already ended is recorded by an Admin.
3. Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.
4. Press **Check the calendar and the price**. The price comes from the rate sheet. You may add the extras, the coverage and an allowed promo code.
5. A car tagged Listing not finished can be rented too: it stays off the public site. If it has no rates yet, type the rental charge for the whole rental and the reason. An owner''s car not yet on the fleet insurance policy is added by an Admin only.
6. To charge another price, type the rental charge and the reason. The rate-sheet price stays on the booking. A price far under the rate sheet is flagged for an Admin to review, but the rental is still added.
7. Choose Where it came from and how it is paid. The ways open to you are set by an Admin, such as **Paid another way**, **Send a payment link** or **Charge the saved card when the renter signs**.
8. Under Who found this client, choose **I sourced this client** or **Entered for CarmaCars**.
9. Press **Add the rental**. The renter gets the confirmation email unless you tick **Do not email the renter**.
10. A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.

> Tip: The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.
', 'Add a rental by hand', 'Choose the car and dates, find the renter, price it, record how it is paid.',
  'Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.

## Add a rental

Open **Bookings** > **Add a rental**. Your home address must be in your profile first: until it is, the page asks for it.

1. Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.
2. The dates decide the case, shown under them. Car already out with the renter? Enter the pickup as when it left: the rental is recorded as on trip, and anything still missing (signature, licence check, coverage proof, deposit) becomes a task. A rental that has already ended is recorded by an Admin.
3. Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.
4. The calendar and the price are checked by themselves once the car and the dates are in. The price comes from the rate sheet. You may add the extras, how damage is covered and an allowed promo code.
5. Quick start: **Phone**, **Walk-in**, **Turo or another platform** or **Insurance replacement** sets the usual choices.
6. A car tagged Listing not finished can be rented too: it stays off the public site. If it has no rates yet, type the rental charge for the whole rental and the reason. An owner''s car not yet on the fleet insurance policy is added by an Admin only.
7. To charge another price, type the rental charge and the reason. The rate-sheet price stays on the booking. A price far under the rate sheet is flagged for an Admin to review, but the rental is still added.
8. Choose how the rental is paid (e-Transfer or cash received, card on file, payment link, platform payout, insurer billed later; the ways open to you are set by an Admin) and how the deposit is taken (card hold, cash or e-Transfer). Signed on paper already? Choose it: a task asks for the scan. An insurance replacement with dates not known yet: untick Blocks the car''s calendar and say why.
9. Under Who found this client, choose **I sourced this client** or **Entered for CarmaCars**.
10. Press **Add the rental**. The renter gets the confirmation email unless you tick **Do not email the renter**.
11. A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.

> Tip: The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.
',
  '<p class="gd-p">Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.</p><section class="gd-task" id="add-a-rental-by-hand-add-a-rental" data-gd-task><h2 class="gd-h2">Add a rental</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>. Your home address must be in your profile first: until it is, the page asks for it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The dates decide the case, shown under them. Car already out with the renter? Enter the pickup as when it left: the rental is recorded as on trip, and anything still missing (signature, licence check, coverage proof, deposit) becomes a task. A rental that has already ended is recorded by an Admin.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The calendar and the price are checked by themselves once the car and the dates are in. The price comes from the rate sheet. You may add the extras, how damage is covered and an allowed promo code.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Quick start: <b class="gd-ui">Phone</b>, <b class="gd-ui">Walk-in</b>, <b class="gd-ui">Turo or another platform</b> or <b class="gd-ui">Insurance replacement</b> sets the usual choices.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A car tagged Listing not finished can be rented too: it stays off the public site. If it has no rates yet, type the rental charge for the whole rental and the reason. An owner&#39;s car not yet on the fleet insurance policy is added by an Admin only.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">To charge another price, type the rental charge and the reason. The rate-sheet price stays on the booking. A price far under the rate sheet is flagged for an Admin to review, but the rental is still added.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Choose how the rental is paid (e-Transfer or cash received, card on file, payment link, platform payout, insurer billed later; the ways open to you are set by an Admin) and how the deposit is taken (card hold, cash or e-Transfer). Signed on paper already? Choose it: a task asks for the scan. An insurance replacement with dates not known yet: untick Blocks the car&#39;s calendar and say why.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Under Who found this client, choose <b class="gd-ui">I sourced this client</b> or <b class="gd-ui">Entered for CarmaCars</b>.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Press <b class="gd-ui">Add the rental</b>. The renter gets the confirmation email unless you tick <b class="gd-ui">Do not email the renter</b>.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.</div></aside></section>');
-- GUIDES 0129 END
