-- 3650 (hotfix, Nov 24): booking and paying keep working with no card processor (docs/changes/2026-11-24-hotfix-card-off.md).
--
-- Stripe closed the account (charges_enabled and payouts_enabled false): every card form, pay link, deposit hold and
-- Collect a card failed, and renters could not book. Now:
--   1. One switch: Program settings card_payments (on by default) and card_provider (stripe, or helcim once its adapter
--      is in). The card processor's own state is kept in card_processor_state (the web reads Stripe's account and
--      reports it here). Card payments are on only when the switch is on AND the processor takes charges:
--      app.card_payments_state() is the one answer (provider stripe | helcim | off) the site, the staff portal and the
--      connector read. The first report of a processor that stopped taking charges alerts the Admins once
--      (admin_card_payments_paused, and a To do); a report that it takes them again ends the pause.
--   2. Card off, renter side: the renter pays by e-Transfer (the company e-Transfer email of Program settings, the
--      booking number as the message, the exact amounts) and uploads the screenshot: app.etransfer_report_renter makes
--      the same Check e-Transfer item as Sales (3610), which Finance or an Admin confirms in one tap. The renter is
--      told the answer (renter_etransfer_confirmed, renter_etransfer_declined). A deposit still to take by card becomes
--      an e-Transfer deposit (deposit_pay_method e_transfer; a cash deposit stays cash), given back by e-Transfer.
--   3. Nothing waits on a card: with card payments off a booking is confirmed without a saved card, an unpaid hold
--      never lapses while an e-Transfer report waits for Finance, and the staff calls that start a card payment
--      (payreq_create, card_charge_begin, deposit_hold_saved_begin, hold_reauth_begin, extension_charge_begin) refuse
--      with "Card payments are paused" instead of failing at the processor. booking_money carries the state, so the
--      Money tab shows "Ask the renter to e-Transfer" with the message to send.
--   4. The connector's get_settings returns card_payments (the switch, the provider and the processor's state).
-- Security definer functions run with search_path public, app, pg_temp; the server role alone executes them.
-- No applied migration is edited: functions are wrapped (renamed *_pre3650) or patched in place. SCHEMA_MARKER 3650.
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

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '3650: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the switch and the processor's state
alter table program_settings add column if not exists card_payments boolean not null default true;
alter table program_settings add column if not exists card_provider text not null default 'stripe';
do $$ begin
  alter table program_settings add constraint program_settings_card_provider_check check (card_provider in ('stripe', 'helcim'));
exception when duplicate_object then null; end $$;
comment on column program_settings.card_payments is
  'On (3650, the default): renters pay by card when the card processor takes payments. Off: every pay page shows e-Transfer instructions with the screenshot upload, and staff card tools are paused.';
comment on column program_settings.card_provider is
  'The card processor (3650): stripe, or helcim once its adapter is live. Card payments are off by themselves while the processor reports it cannot take charges.';

create table if not exists card_processor_state (
  provider         text primary key check (provider in ('stripe', 'helcim')),
  id               uuid not null unique default gen_random_uuid(),
  charges_enabled  boolean not null default true,
  payouts_enabled  boolean not null default true,
  disabled_reason  text check (disabled_reason is null or length(disabled_reason) <= 200),
  checked_at       timestamptz,
  paused_since     timestamptz,
  alerted_at       timestamptz,
  todo_task_id     uuid,
  updated_at       timestamptz not null default now()
);
comment on table card_processor_state is 'What the card processor last said about the account (3650): charges and payouts enabled, and the pause it caused. Written only by app.card_processor_report.';
create trigger card_processor_state_updated before update on card_processor_state for each row execute function app.set_updated_at();
create trigger audit_card_processor_state after insert or update or delete on card_processor_state for each row execute function app.audit_row();
alter table card_processor_state enable row level security;
create policy admin_all on card_processor_state for select to authenticated using (app.is_admin());
revoke all on card_processor_state from public, anon, authenticated;
grant select on card_processor_state to authenticated;
grant all on card_processor_state to service_role;

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('card_payments_paused', 'admin', 'Card payments are paused', 'urgent', 'opening_minutes', 60, 2, 'card_payments_back',
   'The card processor reports that the account cannot take card payments (3650). Renters pay by e-Transfer with a screenshot meanwhile. Answer what the processor asks for; this To do closes by itself when cards work again.')
on conflict (task_type) do nothing;

-- The one answer: provider (stripe | helcim | off), on, why it is off, the e-Transfer email renters send to.
create or replace function app.card_payments_state() returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  s program_settings;
  c card_processor_state;
  v_set boolean;
  v_proc boolean;
begin
  s := app.settings();
  select * into c from card_processor_state where provider = coalesce(s.card_provider, 'stripe');
  v_set := coalesce(s.card_payments, true);
  v_proc := coalesce(c.charges_enabled, true);
  return jsonb_build_object(
    'on', v_set and v_proc,
    'provider', case when v_set and v_proc then coalesce(s.card_provider, 'stripe') else 'off' end,
    'configured_provider', coalesce(s.card_provider, 'stripe'),
    'setting_on', v_set,
    'reason', case when not v_set then 'setting' when not v_proc then 'processor' end,
    'processor', jsonb_build_object('charges_enabled', v_proc, 'payouts_enabled', coalesce(c.payouts_enabled, true),
                                    'disabled_reason', c.disabled_reason, 'checked_at', c.checked_at, 'paused_since', c.paused_since),
    'e_transfer_email', coalesce(nullif(btrim(s.e_transfer_email), ''), (select nullif(btrim(ss.public_email), '') from site_settings ss limit 1)));
end $$;

create or replace function app.card_payments_on() returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce((app.card_payments_state() ->> 'on')::boolean, true)
$$;

create or replace function app.card_paused_message() returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select 'Card payments are paused: ask the renter to e-Transfer (the Money tab has the message to send), then record it or let Finance confirm their screenshot'::text
$$;

-- The processor's answer (the web reads Stripe's account): kept, and the first "cannot take charges" alerts the Admins once.
create or replace function app.card_processor_report(p_provider text, p_charges boolean, p_payouts boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  c card_processor_state;
  v_was boolean;
  v_task uuid;
  v_alert boolean := false;
begin
  if coalesce(p_provider, '') not in ('stripe', 'helcim') then raise exception 'Unknown card processor %', p_provider using errcode = '22023'; end if;
  insert into card_processor_state (provider) values (p_provider) on conflict (provider) do nothing;
  select * into c from card_processor_state where provider = p_provider for update;
  v_was := c.charges_enabled;
  update card_processor_state set charges_enabled = coalesce(p_charges, true), payouts_enabled = coalesce(p_payouts, true),
         disabled_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 200), checked_at = now(),
         paused_since = case when coalesce(p_charges, true) then null else coalesce(paused_since, now()) end
   where provider = p_provider returning * into c;
  if not c.charges_enabled and c.alerted_at is null then
    v_alert := true;
    v_task := app.raise_task(p_type => 'card_payments_paused', p_title => 'Card payments are paused: renters pay by e-Transfer',
      p_detail => format('%s reports the account cannot take card payments%s. Renters see e-Transfer instructions and upload the screenshot; Finance confirms them. Fix the account at the processor; this closes when cards work again.',
                         initcap(p_provider), coalesce(' (' || c.disabled_reason || ')', '')),
      p_related_table => 'card_processor_state', p_related_id => c.id, p_dedupe => 'card_payments_paused:' || p_provider || ':' || extract(epoch from c.paused_since)::bigint,
      p_queue => 'admin', p_priority => 'urgent');
    perform app.ntf_emit('admin_card_payments_paused', 'card_processor', c.id, extract(epoch from c.paused_since)::bigint::text,
      jsonb_build_object('card_provider_name', initcap(p_provider), 'card_pause_reason', coalesce(c.disabled_reason, 'no reason given'),
                         'card_paused_at', app.fmt_datetime(c.paused_since), 'card_payments_text', 'Off',
                         'card_payouts_text', case when c.payouts_enabled then 'On' else 'Off' end));
    update card_processor_state set alerted_at = now(), todo_task_id = v_task where provider = p_provider returning * into c;
    insert into audit_log (action, entity_table, entity_id, before, after)
    values ('card_payments_paused', 'card_processor_state', c.id::text, jsonb_build_object('charges_enabled', v_was),
            jsonb_build_object('charges_enabled', false, 'payouts_enabled', c.payouts_enabled, 'reason', c.disabled_reason));
  elsif c.charges_enabled and c.alerted_at is not null then
    -- cards work again: the pause ends, its To do closes; a later pause alerts again
    update tasks set status = 'done', completed_at = now(), completion_note = 'Card payments work again', wake_at = null
     where id = c.todo_task_id and status in ('open', 'in_progress', 'waiting');
    update card_processor_state set alerted_at = null, todo_task_id = null where provider = p_provider returning * into c;
    insert into audit_log (action, entity_table, entity_id, before, after)
    values ('card_payments_back', 'card_processor_state', c.id::text, jsonb_build_object('charges_enabled', false), jsonb_build_object('charges_enabled', true));
  end if;
  return app.card_payments_state() || jsonb_build_object('alerted', v_alert);
end $$;

-- ================================================================ 2. a booking paid with card payments off
-- A deposit still to take by card becomes an e-Transfer deposit (a cash deposit stays cash). Returns true when changed.
create or replace function app.card_off_prepare(p_booking uuid) returns boolean
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
begin
  if app.card_payments_on() then return false; end if;
  select * into b from bookings where id = p_booking for update;
  if b.id is null or b.booking_type = 'owner' or b.deposit_pay_method <> 'card' or coalesce(b.deposit_cents, 0) <= 0
     or b.status not in ('pending_payment', 'confirmed', 'on_rent') then return false; end if;
  if exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured', 'settled', 'carried_forward')) then return false; end if;
  update bookings set deposit_pay_method = 'e_transfer' where id = b.id;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
    format('Card payments are paused: the deposit is taken by e-Transfer (%s) and given back the same way', app.fmt_money(app.deposit_for_method(b, 'e_transfer'))),
    null, 'system', jsonb_build_object('deposit_pay_method', jsonb_build_object('from', 'card', 'to', 'e_transfer'), 'reason', 'card_payments_off'));
  return true;
end $$;

-- A booking is confirmed without a saved card while card payments are off (its deposit is taken by e-Transfer)
select pg_temp.patch_fn('app.booking_before_write()'::regprocedure,
  $o$if new.booking_type <> 'owner' and new.card_on_file_id is null and new.deposit_pay_method = 'card'$o$,
  $n$if new.booking_type <> 'owner' and new.card_on_file_id is null and new.deposit_pay_method = 'card' and app.card_payments_on()$n$);

-- An unpaid hold never lapses while an e-Transfer report waits for Finance
select pg_temp.patch_fn('app.unpaid_hold_until(bookings)'::regprocedure,
  $o$     and coalesce(b.rental_pay_method, 'card') = 'card' and b.offer_approved_at is not null$o$,
  $n$     and coalesce(b.rental_pay_method, 'card') = 'card' and b.offer_approved_at is not null
     and not exists (select 1 from etransfer_reports r where r.booking_id = b.id and r.status = 'open')$n$);

-- What the renter sends: the amounts by e-Transfer (or cash where the booking takes cash), the email, the reports.
create or replace function app.renter_etransfer_state(p_booking uuid, p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  d deposits;
  o etransfer_reports;
  l etransfer_reports;
  v_dep_method text;
  v_owed bigint := 0;
  v_rent bigint;
  v_card jsonb := app.card_payments_state();
begin
  select x.* into b from bookings x join renters r on r.id = x.renter_id where x.id = p_booking and r.user_id = p_user;
  if b.id is null then return null; end if;
  select * into d from deposits where booking_id = b.id;
  v_dep_method := case when b.deposit_pay_method = 'card' and not (v_card ->> 'on')::boolean then 'e_transfer' else b.deposit_pay_method end;
  if coalesce(b.deposit_cents, 0) > 0 and b.booking_type <> 'owner' and v_dep_method in ('e_transfer', 'cash') then
    v_owed := case when d.id is null or d.status in ('pending', 'failed') then app.deposit_for_method(b, v_dep_method)
                   when d.method = 'offline' and d.status = 'captured' then greatest(app.deposit_for_method(b, v_dep_method) - d.amount_cents, 0)
                   else 0 end;
  end if;
  v_rent := case when b.status = 'pending_payment' or coalesce(app.booking_link_due(b), false) then app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees') else 0 end;
  select * into o from etransfer_reports where booking_id = b.id and status = 'open';
  select * into l from etransfer_reports where booking_id = b.id and status = 'declined' and decided_at > coalesce(o.reported_at, '-infinity') order by decided_at desc limit 1;
  return jsonb_build_object(
    'card', v_card, 'booking_number', b.booking_number, 'status', b.status,
    'e_transfer_email', v_card ->> 'e_transfer_email',
    'rental_cents', v_rent, 'rental_cash', b.rental_pay_method = 'cash',
    'deposit_cents', v_owed, 'deposit_method', v_dep_method, 'deposit_card_cents', coalesce(b.deposit_cents, 0),
    'may_report', o.id is null and (v_rent > 0 or (v_owed > 0 and v_dep_method = 'e_transfer')) and b.status in ('pending_payment', 'confirmed', 'on_rent'),
    'open', case when o.id is not null then jsonb_build_object('report_number', o.report_number, 'amount_cents', o.amount_cents, 'covers', o.covers, 'reported_at', o.reported_at) end,
    'declined', case when l.id is not null then jsonb_build_object('report_number', l.report_number, 'amount_cents', l.amount_cents, 'reason', l.decline_reason, 'decided_at', l.decided_at) end);
end $$;

-- The renter reports the e-Transfer they sent (Sign and pay, the booking page): the same Check e-Transfer item as Sales.
-- p: booking, amount_cents, covers (rental | deposit | both), sender_name, proof {path, sha256, mime}
create or replace function app.etransfer_report_renter(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  r etransfer_reports;
  v_state jsonb;
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_covers text := nullif(btrim(coalesce(p ->> 'covers', '')), '');
  v_sender text := nullif(btrim(coalesce(p ->> 'sender_name', '')), '');
  v_doc uuid;
  v_name text;
  v_fin uuid;
  v_adm uuid;
begin
  select x.* into b from bookings x join renters rr on rr.id = x.renter_id
   where (x.id::text = coalesce(p ->> 'booking', '') or x.booking_number = upper(btrim(coalesce(p ->> 'booking', '')))) and rr.user_id = p_user for update of x;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  perform app.card_off_prepare(b.id);
  select * into b from bookings where id = b.id;
  v_state := app.renter_etransfer_state(b.id, p_user);
  if v_state -> 'open' <> 'null'::jsonb then
    raise exception 'Your e-Transfer (%) is already with our team: we confirm it as soon as it is in the bank', v_state #>> '{open,report_number}' using errcode = '23505';
  end if;
  if not coalesce((v_state ->> 'may_report')::boolean, false) then
    raise exception 'Nothing is waiting for an e-Transfer on booking %', b.booking_number using errcode = '23514';
  end if;
  if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount you sent' using errcode = '22023'; end if;
  if v_amount > 10000000 then raise exception 'That amount is too large for one e-Transfer: check it' using errcode = '22023'; end if;
  if v_covers is null or v_covers not in ('rental', 'deposit', 'both') then raise exception 'Choose what it pays: the rental, the deposit or both' using errcode = '22023'; end if;
  if v_covers in ('rental', 'both') and (v_state ->> 'rental_cents')::bigint <= 0 then raise exception 'The rental is already paid: choose the deposit' using errcode = '22023'; end if;
  if v_covers in ('deposit', 'both') and ((v_state ->> 'deposit_cents')::bigint <= 0 or v_state ->> 'deposit_method' <> 'e_transfer') then
    raise exception 'No deposit is owed by e-Transfer on this booking: choose the rental' using errcode = '22023';
  end if;
  if v_sender is not null and length(v_sender) > 120 then raise exception 'The sender''s name is too long' using errcode = '22023'; end if;
  if jsonb_typeof(p -> 'proof') <> 'object' or lower(coalesce(p #>> '{proof,sha256}', '')) !~ '^[0-9a-f]{64}$'
     or coalesce(p #>> '{proof,path}', '') !~ '^etransfer/[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|png|pdf)$'
     or coalesce(p #>> '{proof,mime}', '') not in ('image/jpeg', 'image/png', 'application/pdf') then
    raise exception 'Add the screenshot of your e-Transfer' using errcode = '22023';
  end if;
  if split_part(p #>> '{proof,path}', '/', 2) <> b.id::text then raise exception 'Add the screenshot of your e-Transfer' using errcode = '22023'; end if;
  v_name := coalesce((select u.full_name from users u where u.id = p_user), 'The renter') || ' (the renter)';
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, uploaded_by)
  values ('receipt', format('e-Transfer proof, %s', b.booking_number), 'documents', p #>> '{proof,path}', p #>> '{proof,mime}', lower(p #>> '{proof,sha256}'), p_user)
  returning id into v_doc;
  begin
    insert into etransfer_reports (booking_id, amount_cents, covers, sender_name, note, proof_document_id, reported_by)
    values (b.id, v_amount, v_covers, v_sender, 'Sent by the renter from their booking', v_doc, p_user) returning * into r;
  exception when unique_violation then
    raise exception 'Your e-Transfer is already with our team: we confirm it as soon as it is in the bank' using errcode = '23505';
  end;
  v_fin := app.raise_task(p_type => 'etransfer_check',
    p_title => format('Check e-Transfer: %s on %s', app.fmt_money(v_amount), b.booking_number),
    p_detail => format('%s sent %s for %s%s (%s), with the screenshot. Check the bank, then Confirm received or Not received on the booking''s Money tab.',
                       v_name, app.fmt_money(v_amount), app.etransfer_covers_words(v_covers), coalesce(' from ' || v_sender, ''), r.report_number),
    p_booking => b.id, p_related_table => 'etransfer_reports', p_related_id => r.id, p_dedupe => 'etransfer_check:' || r.id || ':finance', p_queue => 'finance');
  if app.va_function_staffed('finance') then
    v_adm := app.raise_task(p_type => 'etransfer_check',
      p_title => format('Check e-Transfer: %s on %s', app.fmt_money(v_amount), b.booking_number),
      p_detail => format('%s sent %s for %s%s (%s). Confirm received records it; Not received tells the renter with the reason.',
                         v_name, app.fmt_money(v_amount), app.etransfer_covers_words(v_covers), coalesce(' from ' || v_sender, ''), r.report_number),
      p_booking => b.id, p_related_table => 'etransfer_reports', p_related_id => r.id, p_dedupe => 'etransfer_check:' || r.id || ':admin', p_queue => 'admin');
  end if;
  update etransfer_reports set todo_task_ids = array_remove(array[v_fin, v_adm], null) where id = r.id returning * into r;
  perform app.ntf_emit('staff_etransfer_reported', 'booking', b.id, r.id::text,
    jsonb_build_object('booking_id', b.id, 'report_id', r.id, 'etransfer_amount', app.fmt_money(v_amount), 'etransfer_covers', app.etransfer_covers_words(v_covers),
                       'etransfer_sender', coalesce(v_sender, 'Not given'), 'etransfer_number', r.report_number, 'reporter_name', v_name));
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
    format('The renter sent an e-Transfer of %s for %s (%s), with the screenshot: waiting for Finance. Nothing is recorded yet', app.fmt_money(v_amount), app.etransfer_covers_words(v_covers), r.report_number),
    p_user, 'renter', jsonb_build_object('etransfer_report_id', r.id, 'amount_cents', v_amount, 'covers', v_covers));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_user, 'etransfer_report_renter', 'etransfer_reports', r.id::text, jsonb_build_object('booking_id', b.id, 'report_number', r.report_number, 'amount_cents', v_amount,
          'covers', v_covers, 'sender_name', v_sender, 'proof_document_id', v_doc));
  return jsonb_build_object('ok', true, 'id', r.id, 'report_number', r.report_number, 'status', r.status, 'booking_number', b.booking_number);
end $$;

-- Finance decides as before (3610); a renter's report: the renter is told, and the deposit is an e-Transfer deposit first.
alter function app.etransfer_decide(uuid, jsonb, text) rename to etransfer_decide_pre3650;
create function app.etransfer_decide(p_by uuid, p jsonb, p_aal text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r etransfer_reports;
  v jsonb;
  v_status text;
begin
  r := app.etransfer_find(p);
  if r.id is not null and r.status = 'open' then perform app.card_off_prepare(r.booking_id); end if;
  v := app.etransfer_decide_pre3650(p_by, p, p_aal);
  select * into r from etransfer_reports where id = (v ->> 'id')::uuid;
  if r.id is not null and not (app.user_is_staff(r.reported_by) or app.user_is_admin(r.reported_by)) then
    select status::text into v_status from bookings where id = r.booking_id;
    if r.status = 'confirmed' then
      perform app.ntf_emit('renter_etransfer_confirmed', 'booking', r.booking_id, r.id::text || ':renter_confirmed',
        jsonb_build_object('booking_id', r.booking_id, 'report_id', r.id, 'etransfer_amount', app.fmt_money(r.amount_cents),
                           'etransfer_covers', app.etransfer_covers_words(r.covers), 'booking_status', initcap(replace(v_status, '_', ' '))));
    elsif r.status = 'declined' then
      perform app.ntf_emit('renter_etransfer_declined', 'booking', r.booking_id, r.id::text || ':renter_declined',
        jsonb_build_object('booking_id', r.booking_id, 'report_id', r.id, 'etransfer_amount', app.fmt_money(r.amount_cents),
                           'decline_reason', r.decline_reason, 'e_transfer_email', coalesce(app.card_payments_state() ->> 'e_transfer_email', '')));
    end if;
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.etransfer_decide(uuid, jsonb, text)'::regprocedure, 'app.etransfer_decide_pre3650(uuid, jsonb, text)'::regprocedure);

-- ================================================================ 3. the door: card calls refused while paused, the state on Money
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3650;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v jsonb;
  v_b uuid;
begin
  if p_call in ('ops_do', 'va_do', 'admin_do', 'field_do')
     and p_name in ('payreq_create', 'card_charge_begin', 'deposit_hold_saved_begin', 'hold_reauth_begin', 'extension_charge_begin')
     and not app.card_payments_on() then
    raise exception '%', app.card_paused_message() using errcode = '55000';
  end if;
  if p_call in ('ops_do', 'va_do', 'admin_do') and p_name in ('etransfer_report', 'record_booking_payment') and not app.card_payments_on() then
    select b.id into v_b from bookings b where b.id::text = coalesce(p ->> 'booking', '') or b.booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
    if v_b is not null and (p_name = 'etransfer_report' or coalesce(p ->> 'covers', '') = 'deposit') then perform app.card_off_prepare(v_b); end if;
  end if;
  v := app.door_pre3650(p_user, p_aal, p_call, p_name, p);
  if p_name = 'booking_money' and jsonb_typeof(v) = 'object' then
    v := v || jsonb_build_object('card_payments', app.card_payments_state());
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3650(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 4. the connector: get_settings carries card_payments
alter function app.api_call(text, text, jsonb, text) rename to api_call_pre3650;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v jsonb := app.api_call_pre3650(p_hash, p_tool, p_args, p_client);
begin
  if p_tool = 'get_settings' and coalesce((v ->> 'ok')::boolean, false) and jsonb_typeof(v -> 'result') = 'object' then
    v := jsonb_set(v, '{result,card_payments}', app.card_payments_state());
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre3650(text, text, jsonb, text)'::regprocedure);

-- ================================================================ 5. the server's calls
create or replace function public.server_card_payments_state() returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$ select app.card_payments_state() $$;

-- true when the processor's state is older than 10 minutes (the deposit guard then reads it again)
create or replace function public.server_card_processor_due(p_provider text) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce((select c.checked_at < now() - interval '10 minutes' from card_processor_state c where c.provider = p_provider), true)
$$;

create or replace function public.server_card_processor_report(p_provider text, p_charges boolean, p_payouts boolean, p_reason text default null) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$ select app.card_processor_report(p_provider, p_charges, p_payouts, p_reason) $$;

create or replace function public.server_card_off_prepare(p_booking uuid) returns boolean
language sql security definer set search_path = public, app, pg_temp as $$ select app.card_off_prepare(p_booking) $$;

create or replace function public.server_renter_etransfer_state(p_booking uuid, p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$ select app.renter_etransfer_state(p_booking, p_user) $$;

create or replace function public.server_renter_etransfer_report(p_user uuid, p jsonb) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$ select app.etransfer_report_renter(p_user, p) $$;

-- the deposit guard (which reads the processor's account) runs at least every 10 minutes once a processor has reported
alter function app.server_jobs_due() rename to server_jobs_due_pre3650;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v jsonb := app.server_jobs_due_pre3650();
begin
  if coalesce((v ->> 'deposits')::boolean, false) then return v; end if;
  return v || jsonb_build_object('deposits', coalesce((select c.checked_at < now() - interval '10 minutes' from card_processor_state c
                                                          where c.provider = coalesce((app.settings()).card_provider, 'stripe')), false));
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre3650()'::regprocedure);

-- ================================================================ 6. the notices (email, in-app and push)
-- CATALOGUE 3650 START (generated by supabase/seed/3650_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('admin_card_payments_paused', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'Card payments are paused: renters pay by e-Transfer', '{{card_provider_name}} reports the account cannot take card payments. Booking and paying keep working by e-Transfer.', 'Immediate', 'Hotfix 3650: the card processor reports that the account cannot take card payments (Stripe charges_enabled false), seen by the deposit guard or a Stripe account.updated event. Card payments are treated as off until it takes them again. Sent to the Admins once per pause (again only after it came back and paused again).', null, '/admin/settings/program', '[{"name":"card_pause_reason","type":"string"},{"name":"card_paused_at","type":"string"},{"name":"card_payments_text","type":"string"},{"name":"card_payouts_text","type":"string"},{"name":"card_provider_name","type":"string"},{"name":"company_address","type":"string","global":true}]'::jsonb, 'templates/admin_card_payments_paused.html', 'templates/admin_card_payments_paused.txt'),
  ('renter_etransfer_confirmed', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'We received your e-Transfer of {{etransfer_amount}}', 'Booking {{booking_number}}: {{etransfer_covers}} is recorded.', 'Immediate', 'Hotfix 3650: Finance or an Admin pressed Confirm received on an e-Transfer the renter reported from Sign and pay or the booking page (with the screenshot). The payment is recorded as an e-Transfer; a booking waiting for payment with nothing left open is confirmed (that sends its own confirmation too). Once per report.', null, '/account/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"booking_status","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"etransfer_amount","type":"string"},{"name":"etransfer_covers","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_etransfer_confirmed.html', 'templates/renter_etransfer_confirmed.txt'),
  ('renter_etransfer_declined', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'We have not found your e-Transfer yet: booking {{booking_number}}', '{{decline_reason}}', 'Immediate', 'Hotfix 3650: Finance or an Admin pressed Not received on an e-Transfer the renter reported, with the reason. Nothing was recorded; the renter can send it again or upload a clearer screenshot. Once per report.', null, '/account/bookings/{{booking_number}}/pay', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"decline_reason","type":"string"},{"name":"e_transfer_email","type":"string"},{"name":"etransfer_amount","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_etransfer_declined.html', 'templates/renter_etransfer_declined.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 3650 END
update notification_catalogue set emitted_by = 'app.card_processor_report (3650): the card processor stopped taking payments' where code = 'admin_card_payments_paused';
update notification_catalogue set emitted_by = 'app.etransfer_decide (3650): Confirm received on a renter''s e-Transfer' where code = 'renter_etransfer_confirmed';
update notification_catalogue set emitted_by = 'app.etransfer_decide (3650): Not received on a renter''s e-Transfer' where code = 'renter_etransfer_declined';
update notification_catalogue set no_text = true, push_topic = 'alerts', hold_to_merge = false, priority = 1 where code = 'admin_card_payments_paused';
-- the renter's answers by email, in-app and push, never a text (fewer texts, more email)
update notification_catalogue set no_text = true, push_topic = 'payments', hold_to_merge = false, priority = 2 where code in ('renter_etransfer_confirmed', 'renter_etransfer_declined');
insert into notification_link_paths (key, path) values ('admin_settings_program', '/admin/settings/program') on conflict (key) do update set path = excluded.path;

-- ================================================================ 7. privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname in ('card_payments_state', 'card_payments_on', 'card_paused_message', 'card_processor_report', 'card_off_prepare',
                     'renter_etransfer_state', 'etransfer_report_renter', 'etransfer_decide', 'etransfer_decide_pre3650', 'door_pre3650', 'api_call_pre3650', 'server_jobs_due_pre3650'))
               or (n.nspname = 'public' and p.proname in ('server_card_payments_state', 'server_card_processor_due', 'server_card_processor_report', 'server_card_off_prepare',
                     'server_renter_etransfer_state', 'server_renter_etransfer_report')) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
