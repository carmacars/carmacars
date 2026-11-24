-- 3710 (release 50; docs/changes/2026-11-24-r50-helcim.md): card payments move to Helcim. Stripe closed the account; the
-- site's card flows run on Helcim's HelcimPay.js and Payment API through web/src/integrations/payments/helcim.ts, behind
-- the same adapter as Stripe (PAYMENTS_PROVIDER=helcim|stripe|off). Stripe's history stays readable and Stripe stays
-- selectable in case the account is restored.
--   1. helcim_intents: Helcim has no PaymentIntent, so the adapter keeps one per payment here, in Stripe's words (status
--      requires_payment_method, requires_capture, succeeded, canceled), with its checkout session (the secret token that
--      checks the HelcimPay.js answer never leaves the server), its Helcim transactions and card token. Ids start hc_.
--      helcim_calls keeps the result of each capture, refund, reverse and saved-card charge by its idempotency key (Helcim
--      keeps keys 5 minutes only): a repeat never moves money twice.
--   2. Payments get a provider (stripe | helcim): set from the processor details of the payment (an id hc_... is Helcim's,
--      whatever the recording function wrote), backfilled for the history. payment_processor_details.processor follows it.
--   3. Deposits longer than the hold window: Helcim's preauth must be captured within 7 days. A deposit hold for a rental
--      of more billable days than that is charged and refunded at release instead (server_helcim_hold_plan); the deposit is
--      marked held_as_charge (the booking's Money tab and the pay page say so) and never shows a hold expiry.
--   4. The connector: helcim_account, helcim_find_payments (read) and helcim_record_paid (preview, then confirm), mirroring
--      the stripe_* tools. A payment taken outside the site (the Helcim dashboard or terminal) is linked to its booking
--      through the same untied-payment plan as Stripe's (app.stripe_untied_plan now takes hc_ ids).
-- Security definer functions run with search_path public, app, pg_temp; the server role alone executes them. The tables
-- are the server's only (no row-level policy grants anyone else). SCHEMA_MARKER 3710. No applied migration is edited.
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
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '3710: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the adapter's payments
create table if not exists helcim_intents (
  id                     text primary key check (id ~ '^hc_[A-Za-z0-9]{8,40}$'),
  idempotency_key        text not null unique check (length(idempotency_key) between 1 and 300),
  kind                   text not null check (kind in ('booking', 'addon', 'gift', 'invoice', 'staff', 'setup', 'charge')),
  status                 text not null check (status in ('requires_payment_method', 'requires_capture', 'succeeded', 'canceled')),
  amount_cents           bigint not null check (amount_cents >= 0),
  customer_code          text,
  checkout_token         text,
  transaction_id         bigint,
  capture_transaction_id bigint,
  held_as_charge         boolean not null default false,
  booking_id             uuid,
  purpose                text,
  state                  jsonb not null,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
create index if not exists helcim_intents_tx_idx on helcim_intents (transaction_id) where transaction_id is not null;
create index if not exists helcim_intents_capture_idx on helcim_intents (capture_transaction_id) where capture_transaction_id is not null;
create index if not exists helcim_intents_checkout_idx on helcim_intents (checkout_token) where checkout_token is not null;
create index if not exists helcim_intents_open_idx on helcim_intents (customer_code, amount_cents, created_at desc) where status = 'requires_payment_method';
create index if not exists helcim_intents_booking_idx on helcim_intents (booking_id) where booking_id is not null;
create unique index if not exists helcim_intents_one_tx on helcim_intents (transaction_id) where transaction_id is not null;
comment on table helcim_intents is 'r50 (3710): one row per Helcim payment the site starts, in Stripe''s words (the adapter''s PaymentIntent). state holds the whole row, including the checkout session''s secret token: the server role alone reads it.';
create trigger helcim_intents_updated before update on helcim_intents for each row execute function app.set_updated_at();
create trigger audit_helcim_intents after insert or update or delete on helcim_intents for each row execute function app.audit_row('redact');
alter table helcim_intents enable row level security;
revoke all on helcim_intents from public, anon, authenticated;
grant all on helcim_intents to service_role;

create table if not exists helcim_calls (
  idempotency_key text primary key check (length(idempotency_key) between 1 and 400),
  result          jsonb not null,
  created_at      timestamptz not null default now()
);
comment on table helcim_calls is 'r50 (3710): the result of each money call to Helcim (capture, refund, reverse, a saved-card charge, a customer) by our idempotency key, kept for good (Helcim keeps its keys 5 minutes).';
alter table helcim_calls enable row level security;
revoke all on helcim_calls from public, anon, authenticated;
grant all on helcim_calls to service_role;

-- the whole row as the adapter wrote it (camelCase), its columns kept for lookups
create or replace function public.server_helcim_intent_put(p jsonb) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_id text := p ->> 'id';
begin
  if coalesce(v_id, '') !~ '^hc_[A-Za-z0-9]{8,40}$' then raise exception 'Not a Helcim payment id' using errcode = '22023'; end if;
  insert into helcim_intents (id, idempotency_key, kind, status, amount_cents, customer_code, checkout_token, transaction_id, capture_transaction_id,
                              held_as_charge, booking_id, purpose, state)
  values (v_id, p ->> 'key', p ->> 'kind', p ->> 'status', (p ->> 'amountCents')::bigint, nullif(p ->> 'customerCode', ''), nullif(p ->> 'checkoutToken', ''),
          nullif(p ->> 'transactionId', '')::bigint, nullif(p ->> 'captureTransactionId', '')::bigint, coalesce((p ->> 'heldAsCharge')::boolean, false),
          case when coalesce(p #>> '{metadata,booking_id}', '') ~ '^[0-9a-f-]{36}$' then (p #>> '{metadata,booking_id}')::uuid end, p #>> '{metadata,purpose}', p)
  on conflict (id) do update set status = excluded.status, amount_cents = excluded.amount_cents, customer_code = excluded.customer_code,
    checkout_token = excluded.checkout_token, transaction_id = excluded.transaction_id, capture_transaction_id = excluded.capture_transaction_id,
    held_as_charge = excluded.held_as_charge, state = excluded.state;
end $$;

create or replace function public.server_helcim_intent_get(p_id text) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select state from helcim_intents where id = p_id
$$;

-- p: key | transaction_id (a payment's own transaction or its capture) | checkout_token
create or replace function public.server_helcim_intent_find(p jsonb) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select h.state from helcim_intents h
   where (p ? 'key' and h.idempotency_key = p ->> 'key')
      or (p ? 'transaction_id' and (h.transaction_id = (p ->> 'transaction_id')::bigint or h.capture_transaction_id = (p ->> 'transaction_id')::bigint))
      or (p ? 'checkout_token' and h.checkout_token = p ->> 'checkout_token')
   order by h.created_at desc limit 1
$$;

create or replace function public.server_helcim_intent_open(p_customer text, p_amount bigint, p_since timestamptz) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(jsonb_agg(h.state order by h.created_at desc), '[]'::jsonb) from helcim_intents h
   where h.status = 'requires_payment_method' and h.amount_cents = p_amount and h.customer_code is not distinct from nullif(p_customer, '') and h.created_at >= p_since
$$;

create or replace function public.server_helcim_call_get(p_key text) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('result', result) from helcim_calls where idempotency_key = p_key
$$;

create or replace function public.server_helcim_call_put(p_key text, p_result jsonb) returns void
language sql security definer set search_path = public, app, pg_temp as $$
  insert into helcim_calls (idempotency_key, result) values (p_key, coalesce(p_result, 'null'::jsonb)) on conflict (idempotency_key) do nothing
$$;

-- ================================================================ 2. the deposit of a rental longer than the hold window
alter table deposits add column if not exists held_as_charge boolean not null default false;
comment on column deposits.held_as_charge is 'r50 (3710): the card processor''s hold lasts less than this rental (Helcim: 7 days), so the deposit was charged and is refunded at release instead of held. No hold expiry applies.';

-- 'charge' when the booking's rental is longer than the processor's hold window (Helcim: 7 days)
create or replace function app.helcim_hold_plan(p_booking uuid, p_window_days integer) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case when coalesce((select b.billable_days from bookings b where b.id = p_booking), 0) > greatest(coalesce(p_window_days, 7), 1) then 'charge' else 'hold' end
$$;
create or replace function public.server_helcim_hold_plan(p_booking uuid, p_window_days integer) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$ select app.helcim_hold_plan(p_booking, p_window_days) $$;

-- ================================================================ 3. the provider of each payment
alter table payments add column if not exists provider text check (provider is null or provider in ('stripe', 'helcim'));
comment on column payments.provider is 'r50 (3710): the card processor that took this payment (stripe or helcim); empty for money taken another way (e-Transfer, bank transfer, cash). Set from its processor details.';
create index if not exists payments_provider_idx on payments (provider) where provider is not null;

-- a Helcim payment's details say so whatever the recording function wrote (they were all written for Stripe); its payment
-- and, for a deposit charged instead of held, its deposit follow
create or replace function app.processor_details_provider() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if coalesce(new.processor_payment_id, '') like 'hc\_%' or coalesce(new.processor_refund_id, '') like 'hcr\_%' then new.processor := 'helcim'; end if;
  return new;
end $$;
create or replace function app.processor_details_after() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  update payments set provider = new.processor where id = new.payment_id and new.processor in ('stripe', 'helcim') and provider is distinct from new.processor;
  if new.processor = 'helcim' and exists (select 1 from helcim_intents h where h.id = new.processor_payment_id and h.held_as_charge) then
    update deposits set held_as_charge = true, hold_expires_at = null, hold_expiry_from_bank = false where hold_payment_id = new.payment_id and not held_as_charge;
  end if;
  return null;
end $$;
drop trigger if exists payment_processor_details_provider on payment_processor_details;
create trigger payment_processor_details_provider before insert or update of processor_payment_id, processor_refund_id, processor on payment_processor_details
  for each row execute function app.processor_details_provider();
drop trigger if exists payment_processor_details_after on payment_processor_details;
create trigger payment_processor_details_after after insert or update of processor, processor_payment_id on payment_processor_details
  for each row execute function app.processor_details_after();

-- the history: every card payment recorded so far was Stripe's
update payments p set provider = d.processor from payment_processor_details d
 where d.payment_id = p.id and p.provider is null and d.processor in ('stripe', 'helcim');

-- ================================================================ 4. a payment taken outside the site, linked to its booking
select pg_temp.patch_fn('app.stripe_untied_plan(uuid, bigint, text, text, text)'::regprocedure,
  $o$if coalesce(p_intent, '') !~ '^pi_[A-Za-z0-9_]{6,}$' then return no || jsonb_build_object('reason', 'Stripe gave no PaymentIntent for this payment'); end if;$o$,
  $n$if coalesce(p_intent, '') !~ '^(pi|hc)_[A-Za-z0-9_]{6,}$' then return no || jsonb_build_object('reason', 'The processor gave no payment id for this payment'); end if;$n$);

-- ================================================================ 5. the connector: helcim_account, helcim_find_payments, helcim_record_paid
-- The database checks the key, the scope and (for the write) the preview; Helcim is read and the payment recorded in the
-- web layer (api/mcp: helcimTool), exactly as the stripe_* tools.
alter function app.api_call(text, text, jsonb, text) rename to api_call_pre3710;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  v_write boolean := p_tool = 'helcim_record_paid';
  chk jsonb;
  k api_keys;
  v_args jsonb;
  v_confirm boolean;
  pv api_previews;
  v_rec jsonb;
  v_to timestamptz;
  v_from timestamptz;
  v_hours numeric;
  v_amount bigint;
  v_result jsonb;
  v_target text := left(coalesce(nullif(a ->> 'booking', ''), p_tool), 200);
begin
  if p_tool not in ('helcim_account', 'helcim_find_payments', 'helcim_record_paid') then return app.api_call_pre3710(p_hash, p_tool, p_args, p_client); end if;
  chk := app.api_key_check(p_hash, case when v_write then 'admin:write' else 'admin:read' end, p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  v_confirm := coalesce((a ->> 'confirm')::boolean, false);
  v_args := a - 'confirm' - 'preview_id';
  begin
    if p_tool = 'helcim_account' then
      v_result := jsonb_build_object('run', 'helcim_account');
    elsif p_tool = 'helcim_find_payments' then
      v_to := coalesce(nullif(a ->> 'to', '')::timestamptz, now());
      if v_to > now() then v_to := now(); end if;
      v_hours := coalesce(nullif(a ->> 'hours', '')::numeric, 24);
      if v_hours <= 0 or v_hours > 720 then raise exception 'hours: from 1 to 720 (30 days)' using errcode = '22023'; end if;
      v_from := coalesce(nullif(a ->> 'from', '')::timestamptz, v_to - make_interval(secs => v_hours * 3600));
      if v_from >= v_to then raise exception 'from must be before to' using errcode = '22023'; end if;
      if v_to - v_from > interval '30 days' then raise exception 'The window is 30 days at most' using errcode = '22023'; end if;
      v_amount := nullif(a ->> 'amount_cents', '')::bigint;
      if v_amount is not null and v_amount <= 0 then raise exception 'amount_cents: a positive amount in cents' using errcode = '22023'; end if;
      v_result := jsonb_build_object('run', 'helcim_find', 'from', v_from, 'to', v_to, 'amount_cents', v_amount);
    else
      v_rec := app.stripe_booking_recorded(v_args ->> 'booking');
      v_target := v_rec ->> 'booking_number';
      if coalesce(v_args ->> 'transaction_id', '') !~ '^[0-9]{1,15}$' then
        raise exception 'transaction_id: the Helcim transaction id (digits) that helcim_find_payments lists' using errcode = '22023';
      end if;
      if exists (select 1 from helcim_intents h join payment_processor_details d on d.processor_payment_id = h.id join payments p on p.id = d.payment_id
                  where (h.transaction_id = (v_args ->> 'transaction_id')::bigint or h.capture_transaction_id = (v_args ->> 'transaction_id')::bigint)
                    and p.status in ('succeeded', 'authorized')) then
        raise exception 'Helcim transaction % is already recorded', v_args ->> 'transaction_id' using errcode = '23514';
      end if;
      if not v_confirm then
        insert into api_previews (key_id, user_id, tool, args, before, after) values (k.id, k.user_id, p_tool, v_args, v_rec -> 'payments', null) returning * into pv;
        v_result := jsonb_build_object('preview', true, 'preview_id', pv.id, 'tool', p_tool, 'expires_at', pv.created_at + interval '10 minutes', 'run', 'helcim_record_preview',
          'booking_id', v_rec ->> 'booking_id', 'booking_number', v_target, 'transaction_id', v_args ->> 'transaction_id',
          'will_do', format('Record the Helcim transaction %s on booking %s exactly as Helcim''s webhook would. Nothing is charged, captured or refunded: it is recorded only if Helcim shows it approved for this booking (or, taken outside the site, for exactly what is open on it).', v_args ->> 'transaction_id', v_target),
          'next', 'Nothing was changed. To do it, call this tool again with exactly the same arguments plus "confirm": true and "preview_id": "' || pv.id || '".');
      else
        select * into pv from api_previews where id = nullif(a ->> 'preview_id', '')::uuid for update;
        if pv.id is null or pv.key_id <> k.id or pv.tool <> p_tool then raise exception 'Preview first: call without confirm, then confirm with its preview_id' using errcode = '22023'; end if;
        if pv.used_at is not null then raise exception 'This preview was already used: preview again' using errcode = '22023'; end if;
        if pv.created_at < now() - interval '10 minutes' then raise exception 'This preview is more than 10 minutes old: preview again' using errcode = '22023'; end if;
        if pv.args is distinct from v_args then raise exception 'The arguments differ from the preview: preview again with these' using errcode = '22023'; end if;
        update api_previews set used_at = now() where id = pv.id;
        v_result := jsonb_build_object('run', 'helcim_record_paid', 'actor', k.user_id,
          'params', jsonb_build_object('id', v_rec ->> 'booking_id', 'booking_number', v_target, 'transaction_id', v_args ->> 'transaction_id'));
      end if;
    end if;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, v_target, v_args, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, ok, client)
  values (k.id, k.user_id, case when v_write and not v_confirm then p_tool || ':preview' else p_tool end, v_target, v_args, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre3710(text, text, jsonb, text)'::regprocedure);

-- which Helcim transactions the site knows, and on which booking (helcim_find_payments): {txid: {intent, booking_number, where}}
create or replace function public.server_helcim_known(p_tx bigint[]) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(jsonb_object_agg(x.tx::text, jsonb_build_object('intent', x.id, 'status', x.status, 'booking_number', x.booking_number, 'recorded', x.recorded)), '{}'::jsonb)
    from (select distinct on (t.tx) t.tx, h.id, h.status, b.booking_number,
                 exists (select 1 from payment_processor_details d join payments p on p.id = d.payment_id where d.processor_payment_id = h.id and p.status in ('succeeded', 'authorized')) recorded
            from unnest(coalesce(p_tx, '{}')) t(tx)
            join helcim_intents h on h.transaction_id = t.tx or h.capture_transaction_id = t.tx
            left join bookings b on b.id = h.booking_id
           order by t.tx, h.created_at desc) x
$$;

-- ================================================================ 6. privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'public' and p.proname in ('server_helcim_intent_put', 'server_helcim_intent_get', 'server_helcim_intent_find', 'server_helcim_intent_open',
                     'server_helcim_call_get', 'server_helcim_call_put', 'server_helcim_hold_plan', 'server_helcim_known'))
               or (n.nspname = 'app' and p.proname in ('helcim_hold_plan', 'processor_details_provider', 'processor_details_after', 'api_call_pre3710')) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
