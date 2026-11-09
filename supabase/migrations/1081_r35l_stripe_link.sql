-- 1081_r35l_stripe_link.sql
-- Release 35, part L (docs/changes/2026-11-08-r35-live-map-speed-stripe-link.md, section 2): link a payment taken
-- outside the platform, and the nightly list of Stripe payments tied to no booking. SCHEMA_MARKER 1081.
-- No applied migration is edited.
--   1. admin_do link_stripe_payment {booking, as: rental | deposit, verified, same_card, note}: an Admin pastes the Stripe
--      payment id (pi_... or ch_...) of a charge taken in the Stripe Dashboard or through a payment link; the website reads
--      it at Stripe (the existing lookup, 0201) and this checks it: Canadian dollars, paid (or, for the deposit, a hold
--      waiting to be captured), not linked to anything yet, and the amount (the rental: no more than is open for the rental
--      and fees; the deposit: the whole deposit). Recorded as a rental payment (0201's record_card_payment, "Rental and
--      fees", with the card Stripe read), or as the deposit: held when Stripe holds it (released or captured from Settle
--      the deposit like any hold), captured when it was charged. Audited (link_stripe_payment).
--   2. stripe_unlinked_checks and stripe_unlinked: the nightly check (from 3 a.m. Toronto, the deposit guard's job, which the
--      cron gate starts when it is due) lists the succeeded Stripe charges of the last 60 days that no payment, payment link
--      or owner debit knows, with a best guess of the booking: the booking number Stripe kept, the renter's email, or a
--      booking whose open amount or deposit is that amount (pickup within 30 days of the charge). ops_read stripe_unlinked
--      (Admin and Finance) shows them on Money; ops_do stripe_unlinked_dismiss puts one aside with a reason (not a booking:
--      an owner's fee, a test). Linking one takes it off the list.

-- ================================================================ 2. the nightly check's tables
create table if not exists stripe_unlinked_checks (
  id         uuid primary key default gen_random_uuid(),
  ran_at     timestamptz not null default now(),
  ok         boolean not null,
  error      text,
  charges    integer not null default 0 check (charges >= 0),
  unlinked   integer not null default 0 check (unlinked >= 0)
);
comment on table stripe_unlinked_checks is 'The nightly "unlinked Stripe payments" check (1081): one row a run, with what Stripe answered.';
create index if not exists stripe_unlinked_checks_at on stripe_unlinked_checks (ran_at desc);

create table if not exists stripe_unlinked (
  charge_id        text primary key check (charge_id ~ '^(ch|py)_[A-Za-z0-9_]+$'),
  intent_id        text check (intent_id is null or intent_id ~ '^pi_[A-Za-z0-9_]+$'),
  amount_cents     bigint not null check (amount_cents > 0),
  refunded_cents   bigint not null default 0 check (refunded_cents >= 0),
  currency         text not null check (currency ~ '^[a-z]{3}$'),
  charged_at       timestamptz not null,
  email            text,
  name             text,
  card_brand       text,
  card_last4       text check (card_last4 is null or card_last4 ~ '^[0-9]{4}$'),
  description      text,
  guess_booking_id uuid references bookings (id) on delete set null,
  guess_reason     text,
  seen_at          timestamptz not null default now(),
  dismissed_at     timestamptz,
  dismissed_by     uuid references users (id),
  dismiss_note     text,
  check (dismissed_at is null or dismiss_note is not null)
);
comment on table stripe_unlinked is 'Succeeded Stripe charges of the last 60 days tied to no booking, payment link or owner debit (1081), with the best guess of their booking; kept by the nightly check.';
create index if not exists stripe_unlinked_open on stripe_unlinked (charged_at desc) where dismissed_at is null;
create index if not exists stripe_unlinked_intent on stripe_unlinked (intent_id) where intent_id is not null;
-- the lookups of the check: a payment by its Stripe ids
create index if not exists payment_processor_details_charge_idx on payment_processor_details (processor_charge_id) where processor_charge_id is not null;
create index if not exists payment_processor_details_intent_idx on payment_processor_details (processor_payment_id) where processor_payment_id is not null;
create index if not exists payment_requests_intent_idx on payment_requests (processor_intent_id) where processor_intent_id is not null;

create trigger audit_stripe_unlinked after insert or update or delete on stripe_unlinked for each row execute function app.audit_row();
create trigger audit_stripe_unlinked_checks after insert or update or delete on stripe_unlinked_checks for each row execute function app.audit_row();
alter table stripe_unlinked enable row level security;
alter table stripe_unlinked_checks enable row level security;
create policy admin_all on stripe_unlinked for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on stripe_unlinked_checks for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on stripe_unlinked, stripe_unlinked_checks from public, anon, authenticated;
grant all on stripe_unlinked, stripe_unlinked_checks to service_role;

-- ================================================================ 1. link a payment taken outside the platform
-- Is this Stripe payment (intent or charge) already a payment, a payment link or an owner debit of ours?
create or replace function app.stripe_known(p_intent text, p_charge text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from payment_processor_details x where p_intent is not null and x.processor_payment_id = p_intent)
      or exists (select 1 from payment_processor_details x where p_charge is not null and x.processor_charge_id = p_charge)
      or exists (select 1 from payment_requests q where p_intent is not null and q.processor_intent_id = p_intent)
      or exists (select 1 from owner_debit_attempts a where p_intent is not null and a.processor_intent_id = p_intent)
$$;

-- p: booking, as (rental | deposit), verified (the website's lookup at Stripe: intent_id, charge_id, status, amount_cents,
--    capturable_cents, currency, last4, brand, fingerprint, capture_before), same_card, note
create or replace function app.link_stripe_payment(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  d deposits;
  v jsonb := case when jsonb_typeof(p -> 'verified') = 'object' then p -> 'verified' end;
  v_as text := coalesce(nullif(p ->> 'as', ''), 'rental');
  v_intent text;
  v_charge text;
  v_status text;
  v_last4 text;
  v_brand text;
  v_amount bigint;
  v_open bigint;
  v_note text := nullif(left(btrim(coalesce(p ->> 'note', '')), 300), '');
  v_refuse text;
  v_pay uuid;
  v_mp uuid;
  v_r jsonb;
begin
  perform app.assert_admin(p_by);
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v_as not in ('rental', 'deposit') then raise exception 'Link it as the rental or as the deposit' using errcode = '22023'; end if;
  if v is null then raise exception 'Paste the Stripe payment id (pi_... or ch_...): it is read at Stripe first' using errcode = '22023'; end if;
  v_intent := nullif(v ->> 'intent_id', '');
  v_charge := nullif(v ->> 'charge_id', '');
  v_status := coalesce(v ->> 'status', 'unknown');
  v_last4 := nullif(v ->> 'last4', '');
  v_brand := nullif(lower(v ->> 'brand'), '');
  if v_intent is null or v_intent !~ '^pi_[A-Za-z0-9_]{6,}$' then raise exception 'Stripe gave no payment for this id' using errcode = '22023'; end if;
  if lower(coalesce(v ->> 'currency', '')) <> 'cad' then
    raise exception 'Stripe says this payment is in %, not Canadian dollars: it cannot be linked', upper(coalesce(nullif(v ->> 'currency', ''), 'another currency')) using errcode = '23514';
  end if;
  if app.stripe_known(v_intent, v_charge) then raise exception 'This Stripe payment is already linked to a payment on the platform' using errcode = '23505'; end if;
  if v_last4 is null or v_last4 !~ '^[0-9]{4}$' then
    raise exception 'Stripe shows no card on this payment: record it with Record a payment instead' using errcode = '23514';
  end if;
  if b.status in ('cancelled', 'declined', 'expired') then raise exception 'Booking % is %: nothing is owed on it', b.booking_number, b.status using errcode = '23514'; end if;

  if v_as = 'rental' then
    if v_status = 'requires_capture' then
      raise exception 'Stripe says this is a hold waiting to be captured, not a payment: link it as the deposit' using errcode = '23514';
    end if;
    if v_status <> 'succeeded' then raise exception 'Stripe says this payment is %, not paid', replace(v_status, '_', ' ') using errcode = '23514'; end if;
    v_amount := (v ->> 'amount_cents')::bigint;
    v_open := app.booking_part_open(b.id, 'balance');
    if v_open <= 0 then
      raise exception 'Nothing is open for the rental or the fees on %: a later charge is recorded with Record card payment', b.booking_number using errcode = '23514';
    end if;
    if v_amount > v_open then
      raise exception 'Stripe says % was paid, more than the % open for the rental and fees on %', app.fmt_money(v_amount), app.fmt_money(v_open), b.booking_number using errcode = '23514';
    end if;
    v_r := app.record_card_payment(p_by, jsonb_build_object('booking', b.id, 'covers', 'both', 'amount_cents', v_amount, 'last4', v_last4, 'brand', v_brand,
             'source', 'dashboard', 'stripe_id', v_intent, 'verified', v, 'note', coalesce(v_note, 'Linked from Stripe'),
             'same_card', coalesce((p ->> 'same_card')::boolean, false)));
  elsif v_status = 'requires_capture' then
    -- a hold: 0201's deposit hold (released or captured from Settle the deposit)
    v_r := app.record_card_payment(p_by, jsonb_build_object('booking', b.id, 'covers', 'deposit', 'last4', v_last4, 'brand', v_brand, 'source', 'dashboard',
             'stripe_id', v_intent, 'verified', v, 'note', coalesce(v_note, 'Linked from Stripe')));
  elsif v_status = 'succeeded' then
    -- a deposit charged: kept as a captured deposit
    v_amount := (v ->> 'amount_cents')::bigint;
    if b.status not in ('pending_payment', 'confirmed', 'on_rent', 'returned') then
      raise exception 'Booking % is %: a deposit is taken once the offer is approved, until the end of the trip', b.booking_number, b.status using errcode = '23514';
    end if;
    if b.booking_type = 'owner' or b.deposit_cents = 0 then raise exception 'Booking % has no deposit to take', b.booking_number using errcode = '23514'; end if;
    if v_amount <> b.deposit_cents then
      raise exception 'Stripe says % was paid; the deposit on % is % (an Admin can change the deposit on the booking first)', app.fmt_money(v_amount), b.booking_number, app.fmt_money(b.deposit_cents)
        using errcode = '23514';
    end if;
    v_refuse := app.booking_payment_allowed(p_by, v_amount);
    if v_refuse is not null then raise exception '%', v_refuse using errcode = '42501'; end if;
    select * into d from deposits where booking_id = b.id for update;
    if d.id is not null and d.status not in ('pending', 'failed') then raise exception 'The deposit on % has already been taken', b.booking_number using errcode = '23514'; end if;
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, card_brand, card_last4, processed_at, created_by)
    values (b.id, b.renter_id, 'deposit', 'charge', 'card', v_amount, 'succeeded', v_brand, v_last4, now(), p_by)
    returning id into v_pay;
    insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, raw)
    values (v_pay, 'stripe', v_intent, v_charge, jsonb_strip_nulls(jsonb_build_object('recorded_by', p_by, 'source', 'dashboard', 'covers', 'deposit', 'note', v_note, 'outside_site', true, 'linked', true)));
    insert into manual_payments (payment_id, target, booking_id, renter_id, method, amount_cents, received_on, reference, note, recorded_by, covers, card_last4, card_source, stripe_verified)
    values (v_pay, 'booking', b.id, b.renter_id, 'card', v_amount, app.today(), v_intent, coalesce(v_note, 'Linked from Stripe'), p_by, 'deposit', v_last4, 'dashboard', true)
    returning id into v_mp;
    insert into deposits as x (booking_id, amount_cents, method, status, hold_payment_id, taken_at, captured_cents)
    values (b.id, v_amount, 'charged', 'captured', v_pay, now(), v_amount)
    on conflict (booking_id) do update set amount_cents = excluded.amount_cents, method = 'charged', paid_method = null, status = 'captured', hold_payment_id = excluded.hold_payment_id,
           taken_at = excluded.taken_at, hold_expires_at = null, captured_cents = excluded.captured_cents
     where x.status in ('pending', 'failed')
    returning * into d;
    insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note, created_by)
    values (d.id, 'taken', v_amount, v_pay, 'charged in Stripe, linked by hand', p_by);
    update bookings set deposit_pay_method = 'card' where id = b.id and deposit_pay_method is distinct from 'card';
    perform app.resolve_tasks(array['take_deposit', 'deposit_declined'], b.id, p_by, 'Deposit linked from Stripe');
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
      format('Deposit of %s charged in Stripe (%s ending %s), linked', app.fmt_money(v_amount), initcap(coalesce(v_brand, 'card')), v_last4), p_by, 'staff',
      jsonb_build_object('payment_id', v_pay, 'covers', 'deposit', 'method', 'card', 'intent_id', v_intent));
    v_r := jsonb_build_object('ok', true, 'payment_id', v_pay, 'deposit_id', d.id, 'id', v_mp, 'captured', true);
  else
    raise exception 'Stripe says this payment is %: only a paid payment or a hold waiting to be captured can be linked', replace(v_status, '_', ' ') using errcode = '23514';
  end if;

  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'link_stripe_payment', 'bookings', b.id::text, jsonb_build_object('as', v_as, 'intent_id', v_intent, 'charge_id', v_charge, 'status', v_status,
          'amount_cents', coalesce(v_amount, (v ->> 'capturable_cents')::bigint), 'payment_id', v_r ->> 'payment_id', 'last4', v_last4));
  -- off the nightly list
  delete from stripe_unlinked where intent_id = v_intent or (v_charge is not null and charge_id = v_charge);
  return v_r || jsonb_build_object('linked', true, 'as', v_as, 'booking_number', b.booking_number);
end $$;
comment on function app.link_stripe_payment(uuid, jsonb) is 'Link a payment taken in the Stripe Dashboard or through a payment link to a booking, as the rental or the deposit (1081).';

-- ================================================================ 2. the nightly check
-- due from 3 a.m. Toronto once a night; a failed run is tried again an hour later
create or replace function app.stripe_unlinked_due() returns boolean
language sql stable security definer set search_path = public, app as $$
  select now() >= app.local_midnight(app.today()) + interval '3 hours'
     and not exists (select 1 from stripe_unlinked_checks c where c.ok and c.ran_at >= app.local_midnight(app.today()) + interval '3 hours')
     and not exists (select 1 from stripe_unlinked_checks c where c.ran_at > now() - interval '1 hour')
$$;

create or replace function public.server_stripe_unlinked_due() returns boolean
language sql stable security definer set search_path = public, app as $$ select app.stripe_unlinked_due() $$;

-- p: {ok, error, charges: [{id, intent_id, amount_cents, refunded_cents, currency, created (epoch seconds), email, name,
--     last4, brand, description, booking_number}]}: the succeeded charges of the last 60 days as Stripe listed them.
create or replace function public.server_stripe_unlinked_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c jsonb;
  v_n integer := 0;
  v_kept integer := 0;
  v_ids text[] := '{}';
  v_at timestamptz;
  v_amount bigint;
  v_email text;
  v_guess uuid;
  v_why text;
begin
  if not coalesce((p ->> 'ok')::boolean, false) then
    insert into stripe_unlinked_checks (ok, error) values (false, left(coalesce(p ->> 'error', 'Stripe could not be read'), 300));
    return jsonb_build_object('ok', false);
  end if;
  for c in select x from jsonb_array_elements(coalesce(p -> 'charges', '[]'::jsonb)) x loop
    v_n := v_n + 1;
    continue when coalesce(c ->> 'id', '') !~ '^(ch|py)_[A-Za-z0-9_]+$';
    continue when app.stripe_known(nullif(c ->> 'intent_id', ''), c ->> 'id');
    v_amount := nullif(c ->> 'amount_cents', '')::bigint - coalesce(nullif(c ->> 'refunded_cents', '')::bigint, 0);
    continue when v_amount is null or v_amount <= 0;   -- refunded in full: nothing to link
    v_at := to_timestamp(nullif(c ->> 'created', '')::double precision);
    continue when v_at is null or v_at < now() - interval '60 days';
    v_email := nullif(lower(btrim(coalesce(c ->> 'email', ''))), '');
    v_guess := null; v_why := null;
    -- 1. the booking number Stripe kept (a payment link made for a booking)
    select b.id, 'booking number in Stripe' into v_guess, v_why from bookings b where b.booking_number = upper(btrim(coalesce(c ->> 'booking_number', ''))) limit 1;
    -- 2. the renter's email: their booking nearest the charge, one with that much open or that deposit first
    if v_guess is null and v_email is not null then
      select b.id, case when app.booking_part_open(b.id, 'balance') = v_amount or b.deposit_cents = v_amount then 'email and amount' else 'email' end
        into v_guess, v_why
        from bookings b join renters r on r.id = b.renter_id
       where lower(btrim(coalesce(r.email, ''))) = v_email and b.booking_type <> 'owner' and b.status not in ('declined', 'expired')
       order by (app.booking_part_open(b.id, 'balance') = v_amount or b.deposit_cents = v_amount) desc, abs(extract(epoch from b.pickup_at - v_at)) limit 1;
    end if;
    -- 3. the amount: a booking with that much open, or that deposit not taken, pickup within 30 days of the charge
    if v_guess is null then
      select b.id, 'amount' into v_guess, v_why
        from bookings b left join deposits d on d.booking_id = b.id
       where b.booking_type <> 'owner' and b.status in ('pending_payment', 'confirmed', 'on_rent', 'returned', 'closed')
         and b.pickup_at between v_at - interval '30 days' and v_at + interval '30 days'
         and ((b.deposit_cents = v_amount and coalesce(d.status, 'pending') in ('pending', 'failed')) or app.booking_part_open(b.id, 'balance') = v_amount)
       order by abs(extract(epoch from b.pickup_at - v_at)) limit 1;
    end if;
    insert into stripe_unlinked (charge_id, intent_id, amount_cents, refunded_cents, currency, charged_at, email, name, card_brand, card_last4, description, guess_booking_id, guess_reason, seen_at)
    values (c ->> 'id', case when c ->> 'intent_id' ~ '^pi_[A-Za-z0-9_]+$' then c ->> 'intent_id' end, nullif(c ->> 'amount_cents', '')::bigint,
            coalesce(nullif(c ->> 'refunded_cents', '')::bigint, 0), lower(coalesce(nullif(c ->> 'currency', ''), 'cad')), v_at, left(v_email, 200), left(nullif(btrim(c ->> 'name'), ''), 120),
            left(nullif(lower(c ->> 'brand'), ''), 20), case when c ->> 'last4' ~ '^[0-9]{4}$' then c ->> 'last4' end, left(nullif(btrim(c ->> 'description'), ''), 200), v_guess, v_why, now())
    on conflict (charge_id) do update set refunded_cents = excluded.refunded_cents, email = excluded.email, name = excluded.name, guess_booking_id = excluded.guess_booking_id,
           guess_reason = excluded.guess_reason, seen_at = excluded.seen_at;
    v_ids := array_append(v_ids, c ->> 'id');
    v_kept := v_kept + 1;
  end loop;
  -- what is linked now, older than 60 days, or no longer listed by Stripe leaves the list (a put-aside row stays put aside)
  delete from stripe_unlinked u where not (u.charge_id = any (v_ids));
  insert into stripe_unlinked_checks (ok, charges, unlinked) values (true, v_n, v_kept);
  return jsonb_build_object('ok', true, 'charges', v_n, 'unlinked', v_kept);
end $$;

-- the list on Money (Admin and Finance)
create or replace function app.stripe_unlinked_read(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_all boolean := coalesce((p ->> 'dismissed')::boolean, false);
  ck stripe_unlinked_checks;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Only an Admin or Finance sees the unlinked Stripe payments' using errcode = '42501'; end if;
  select * into ck from stripe_unlinked_checks order by ran_at desc limit 1;
  return jsonb_build_object(
    'checked_at', ck.ran_at, 'check_ok', ck.ok, 'check_error', ck.error,
    'last_ok_at', (select max(ran_at) from stripe_unlinked_checks where ok),
    'open', (select count(*) from stripe_unlinked where dismissed_at is null),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('charge_id', u.charge_id, 'intent_id', u.intent_id, 'amount_cents', u.amount_cents, 'refunded_cents', u.refunded_cents,
        'currency', u.currency, 'charged_at', u.charged_at, 'email', u.email, 'name', u.name, 'brand', u.card_brand, 'last4', u.card_last4, 'description', u.description,
        'guess', case when b.id is not null then jsonb_build_object('booking_number', b.booking_number, 'reason', u.guess_reason, 'status', b.status, 'pickup_at', b.pickup_at) end,
        'dismissed_at', u.dismissed_at, 'dismiss_note', u.dismiss_note) order by u.charged_at desc)
      from stripe_unlinked u left join bookings b on b.id = u.guess_booking_id
     where v_all or u.dismissed_at is null), '[]'::jsonb));
end $$;

create or replace function app.stripe_unlinked_dismiss(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_note text := nullif(left(btrim(coalesce(p ->> 'note', '')), 300), '');
  v_id text := p ->> 'charge_id';
begin
  if not app.user_runs_finance(p_by) then raise exception 'Only an Admin or Finance puts an unlinked Stripe payment aside' using errcode = '42501'; end if;
  if coalesce((p ->> 'undo')::boolean, false) then
    update stripe_unlinked set dismissed_at = null, dismissed_by = null, dismiss_note = null where charge_id = v_id;
  else
    if v_note is null or length(v_note) < 5 then raise exception 'Say why it is not a booking''s payment (5 characters or more)' using errcode = '22023'; end if;
    update stripe_unlinked set dismissed_at = now(), dismissed_by = p_by, dismiss_note = v_note where charge_id = v_id and dismissed_at is null;
  end if;
  if not found then raise exception 'That Stripe payment is not on the list' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ the cron gate: the deposit guard's job runs the check when due
alter function app.server_jobs_due() rename to server_jobs_due_pre1081;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare j jsonb := app.server_jobs_due_pre1081();
begin
  if app.stripe_unlinked_due() then j := j || jsonb_build_object('deposits', true, 'stripe_unlinked', true); end if;
  return j;
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1081;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_call = 'admin_do' and p_name = 'link_stripe_payment' then
    perform app.door_begin(p_user, p_aal);
    return app.link_stripe_payment(p_user, p_);
  end if;
  if (p_call = 'ops_read' and p_name = 'stripe_unlinked') or (p_call = 'ops_do' and p_name = 'stripe_unlinked_dismiss') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'stripe_unlinked' then app.stripe_unlinked_read(p_user, p_) else app.stripe_unlinked_dismiss(p_user, p_) end;
  end if;
  return app.door_pre1081(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ privileges
do $$
declare
  g text;
  pair text[];
  f regprocedure;
begin
  foreach pair slice 1 in array array[
      array['app.server_jobs_due()', 'app.server_jobs_due_pre1081()'],
      array['app.door(uuid, text, text, text, jsonb)', 'app.door_pre1081(uuid, text, text, text, jsonb)']] loop
    execute format('revoke all on function %s from public, anon, authenticated', pair[1]);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, pair[2]::regprocedure, 'execute') then execute format('grant execute on function %s to %I', pair[1], g); end if;
    end loop;
  end loop;
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname in ('stripe_known', 'link_stripe_payment', 'stripe_unlinked_due', 'stripe_unlinked_read', 'stripe_unlinked_dismiss',
                                                       'server_jobs_due_pre1081', 'door_pre1081'))
               or (n.nspname = 'public' and p.proname in ('server_stripe_unlinked_due', 'server_stripe_unlinked_save')) loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
