-- 0261: the deposit hold is placed on the morning of the pickup day, on the card on file (the owner: "deposits should be
-- taken day of, not right on the spot"). docs/changes/2026-11-04-deposit-pickup-day.md.
--
-- 1. program_settings.deposit_timing: pickup_day (the default) or handover (as before: at the handover, with 0213's link
--    texted before pickup). program_settings.deposit_auto_hour (8): the hour, Toronto time, the hold is placed on the
--    pickup day; at once when the booking is confirmed later that day; from midnight when the pickup is before that hour.
-- 2. The deposit job (the Worker's five-minute tick, server_jobs_due "deposits") places the hold off-session on the card
--    on file, through the same payment request as Money > Collect a card > The deposit hold (kind hold, covers deposit,
--    channel auto): a manual-capture authorization, recorded by server_payreq_settle as every hold (deposits, the
--    capture before it lapses, never released by itself). One automatic try per booking (a unique index); the card's
--    rules hold: a credit card unless the booking takes debit or prepaid (app.booking_card_ok), the coverage card on a
--    card-coverage rental. Not for a deposit in cash or by e-Transfer, a waived deposit, a long rental (its deposit is
--    charged), or a booking with no saved card.
-- 3. A try that fails (declined, the bank wants the renter, no usable card): the try is recorded with the reason, a task
--    "Deposit not taken" opens on the booking, and the deposit link (0213) goes to the renter at once, by text, or by
--    email when there is no mobile or the text cannot go. The Money tab and the handover ready check say where it is.
-- 4. 0213's link before pickup is the fallback only: under pickup_day it is not sent while the automatic hold will run
--    (a usable card on file and no failed try); its switch and hours stay.
-- No applied migration is edited.
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

alter table program_settings add column if not exists deposit_timing text not null default 'pickup_day' check (deposit_timing in ('handover', 'pickup_day'));
alter table program_settings add column if not exists deposit_auto_hour integer not null default 8 check (deposit_auto_hour between 0 and 23);
comment on column program_settings.deposit_timing is 'When the deposit hold is taken (0261): pickup_day (the default: on the card on file, the morning of the pickup day) or handover (at the handover, as before).';
comment on column program_settings.deposit_auto_hour is 'The hour (Toronto time, 0 to 23) the deposit hold is placed on the pickup day (0261).';

alter table payment_requests drop constraint if exists payment_requests_channel_check;
alter table payment_requests add constraint payment_requests_channel_check check (channel = any (array['device', 'text', 'email', 'link', 'reader', 'auto']));
alter table payment_requests add column if not exists emailed_at timestamptz;
comment on column payment_requests.emailed_at is 'When the deposit link went by email instead of a text (0261).';
-- one automatic try per booking: never two holds
create unique index if not exists payment_requests_auto_hold_once on payment_requests (booking_id) where channel = 'auto';

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description)
values ('deposit_not_taken', 'cs', 'Deposit not taken', 'high', 'none', null, 3, 'deposit_taken',
        'The automatic deposit hold on the pickup day did not go through: the renter has the link; take it at the handover if still missing')
on conflict (task_type) do nothing;

-- ================================================================ the card, the amount, the time
-- the saved card the hold goes on: the coverage card on a card-coverage rental, else the card on file
create or replace function app.deposit_auto_card(b bookings) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_pm uuid;
  v jsonb;
begin
  if coalesce(b.coverage_option, 0) = 2 then
    v_pm := (app.card_coverage_ref(b.id) ->> 'payment_method_id')::uuid;
    if v_pm is null then return null; end if;
  end if;
  select jsonb_build_object('payment_method_id', pm.id, 'customer_id', sc.processor_customer_id, 'method_id', sc.processor_method_id,
           'brand', pm.card_brand, 'last4', pm.card_last4, 'funding', coalesce(pm.funding, case when pm.is_credit then 'credit' end, 'unknown'))
    into v
    from payment_methods pm join payment_method_secrets sc on sc.payment_method_id = pm.id and sc.processor_method_id is not null and sc.processor_customer_id is not null
   where pm.renter_id = b.renter_id and pm.status = 'active' and (v_pm is null or pm.id = v_pm)
     and (pm.exp_year is null or make_date(pm.exp_year, pm.exp_month, 1) + interval '1 month' > (b.pickup_at at time zone 'America/Toronto')::date)
   order by (pm.id = b.card_on_file_id) desc, pm.created_at desc limit 1;
  return v;
end $$;

-- the deposit held on a card (0262 makes it higher on a debit or prepaid card)
create or replace function app.deposit_hold_amount(b bookings, p_funding text) returns bigint
language sql stable security definer set search_path = public, app as $$
  select b.deposit_cents
$$;

-- when the hold is placed: the set hour of the pickup day (Toronto), or from midnight when the pickup is before that hour
create or replace function app.deposit_auto_due_at(b bookings) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  with d as (select (b.pickup_at at time zone 'America/Toronto')::date as day, coalesce((app.settings()).deposit_auto_hour, 8) as h)
  select case when b.pickup_at < ((d.day + make_interval(hours => d.h)) at time zone 'America/Toronto')
              then d.day::timestamp at time zone 'America/Toronto'
              else (d.day + make_interval(hours => d.h)) at time zone 'America/Toronto' end
    from d
$$;

create or replace function app.deposit_auto_on() returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((app.settings()).deposit_timing, 'pickup_day') = 'pickup_day'
$$;

-- the booking needs its hold, and the job may still try (no try yet)
create or replace function app.deposit_auto_needed(b bookings) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.deposit_auto_on() and b.status = 'confirmed' and b.deposit_pay_method = 'card' and coalesce(b.deposit_cents, 0) > 0 and b.booking_type <> 'owner'
     and b.deposit_waived_at is null and b.renter_id is not null and b.pickup_at > now() - interval '12 hours'
     and coalesce(b.billable_days, 0) <= coalesce((app.settings()).deposit_hold_max_days, 0)
     and not exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured', 'settled'))
     and not exists (select 1 from payments p where p.booking_id = b.id and p.purpose = 'deposit' and p.status = 'succeeded')
     and not exists (select 1 from payment_requests q where q.booking_id = b.id and q.channel = 'auto')
$$;

-- the try failed (or found no usable card)
create or replace function app.deposit_auto_failed(b bookings) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from payment_requests q where q.booking_id = b.id and q.channel = 'auto' and q.status in ('failed', 'cancelled'))
$$;

-- the card the automatic hold would use is there and allowed
create or replace function app.deposit_auto_card_ok(b bookings) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select app.booking_card_ok(b.id, jsonb_build_object('funding', c ->> 'funding')) from (select app.deposit_auto_card(b) c) x where c is not null), false)
$$;

create or replace function app.deposit_autos_due(p_limit integer default 20) returns setof bookings
language sql stable security definer set search_path = public, app as $$
  select b.* from bookings b
   where app.deposit_auto_on() and b.status = 'confirmed' and b.deposit_pay_method = 'card'
     and b.pickup_at between now() - interval '12 hours' and now() + interval '25 hours'
     and app.deposit_auto_due_at(b) <= now() and app.deposit_auto_needed(b)
   order by b.pickup_at limit greatest(p_limit, 1)
$$;

create or replace function public.server_deposit_autos_due() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number)), '[]'::jsonb) from app.deposit_autos_due(20) b
$$;

-- ================================================================ the try
-- "Deposit not taken": a task on the booking (closed by the hold, a waiver or a deposit taken another way)
create or replace function app.deposit_auto_problem(q payment_requests, p_why text) returns void
language plpgsql security definer set search_path = public, app as $$
declare b bookings;
begin
  select * into b from bookings where id = q.booking_id;
  perform app.raise_task(p_type => 'deposit_not_taken', p_title => 'Deposit not taken: ' || b.booking_number,
    p_detail => format('The deposit hold of %s on the card on file did not go through on the pickup day: %s. The renter was sent the deposit link. If it is still missing at the handover, take it then (Money tab or the handover screen: The deposit hold). Pickup %s at %s.',
                       app.fmt_money(q.amount_cents), p_why, app.fmt_date(b.pickup_at), app.fmt_time(b.pickup_at)),
    p_booking => b.id, p_renter => b.renter_id, p_related_table => 'payment_requests', p_related_id => q.id,
    p_due_at => greatest(now(), b.pickup_at - interval '2 hours'), p_priority => 'high', p_dedupe => 'deposit_not_taken:' || b.id, p_queue => 'cs');
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('Automatic deposit hold not placed: %s. The deposit link goes to the renter.', p_why), null, 'system', jsonb_build_object('payment_request_id', q.id));
end $$;

-- the job asks to try: the request (never sent: its token is thrown away), the card and the amount; or the reason not
create or replace function public.server_deposit_auto_begin(p_booking uuid, p_token_sha256 text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  c jsonb;
  v_amount bigint;
  v_why text;
  q payment_requests;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null or not app.deposit_auto_needed(b) or app.deposit_auto_due_at(b) > now() then return jsonb_build_object('ok', false, 'reason', 'not due'); end if;
  if p_token_sha256 is null or p_token_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'The token is missing' using errcode = '22023'; end if;
  c := app.deposit_auto_card(b);
  if c is null then v_why := 'no card saved for it';
  elsif not app.booking_card_ok(b.id, jsonb_build_object('funding', c ->> 'funding')) then
    v_why := format('the card on file is a %s card and this booking needs a credit card', coalesce(nullif(c ->> 'funding', 'unknown'), 'non-credit'));
  end if;
  v_amount := app.deposit_hold_amount(b, coalesce(c ->> 'funding', 'credit'));
  insert into payment_requests (booking_id, renter_id, kind, covers, amount_cents, reason, token_sha256, channel, expires_at, created_by, auto, status, last_error, completed_at)
  values (b.id, b.renter_id, 'hold', 'deposit', v_amount, 'Deposit hold on the pickup day', p_token_sha256, 'auto', greatest(b.pickup_at + interval '1 day', now() + interval '1 day'), null, true,
          case when v_why is null then 'open' else 'failed' end, v_why, case when v_why is not null then now() end)
  returning * into q;
  if v_why is not null then
    perform app.deposit_auto_problem(q, v_why);
    return jsonb_build_object('ok', false, 'reason', v_why, 'id', q.id);
  end if;
  return jsonb_build_object('ok', true, 'id', q.id, 'booking_id', b.id, 'booking_number', b.booking_number, 'amount_cents', v_amount,
    'customer_id', c ->> 'customer_id', 'method_id', c ->> 'method_id');
end $$;

-- the try did not place the hold (a decline, the bank wanted the renter, Stripe unreachable)
create or replace function public.server_deposit_auto_failed(p_id uuid, p_error text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare q payment_requests;
begin
  select * into q from payment_requests where id = p_id for update;
  if q.id is null or q.channel <> 'auto' then raise exception 'Not an automatic deposit hold' using errcode = '22023'; end if;
  if q.status <> 'open' then return jsonb_build_object('ok', true, 'status', q.status); end if;
  update payment_requests set status = 'failed', last_error = left(coalesce(nullif(btrim(p_error), ''), 'the card was declined'), 300), completed_at = now() where id = q.id
  returning * into q;
  perform app.deposit_auto_problem(q, q.last_error);
  return jsonb_build_object('ok', true, 'status', 'failed');
end $$;

-- a hold placed (by the job, the link or staff) closes "Deposit not taken"
alter function public.server_payreq_settle(uuid, jsonb) rename to server_payreq_settle_pre0261;
create function public.server_payreq_settle(p_id uuid, p_intent jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q payment_requests;
  v_out jsonb := public.server_payreq_settle_pre0261(p_id, p_intent);
begin
  select * into q from payment_requests where id = p_id;
  if q.kind = 'hold' and q.status = 'paid' and coalesce((v_out ->> 'ok')::boolean, false) then
    perform app.resolve_tasks(array['deposit_not_taken'], q.booking_id, null, 'Deposit hold placed');
    -- the link no longer needed once the hold is placed another way
    update payment_requests set status = 'cancelled', last_error = coalesce(last_error, 'The deposit hold was placed')
     where booking_id = q.booking_id and kind = 'hold' and status = 'open' and id <> q.id;
  elsif q.kind = 'hold' and q.channel = 'auto' and q.status = 'open' and not coalesce((v_out ->> 'ok')::boolean, false) then
    perform public.server_deposit_auto_failed(q.id, coalesce(v_out ->> 'reason', 'the hold was not approved'));
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('public.server_payreq_settle(uuid, jsonb)'::regprocedure, 'public.server_payreq_settle_pre0261(uuid, jsonb)'::regprocedure);

-- ================================================================ 0213's link: the fallback
create or replace function app.deposit_links_due(p_limit integer default 20) returns setof bookings
language sql stable security definer set search_path = public, app as $$
  select b.* from bookings b, site_settings ss
   where ss.singleton and ss.deposit_link_auto and b.status = 'confirmed' and b.deposit_pay_method = 'card'
     and b.pickup_at > now()
     and (b.pickup_at - make_interval(hours => ss.deposit_link_hours) <= now() or app.deposit_auto_failed(b))
     and app.deposit_link_needed(b) and not app.deposit_link_live(b)
     -- under pickup_day: not while the automatic hold will run on the day (a usable card, no failed try)
     and (not app.deposit_auto_on() or app.deposit_auto_failed(b) or not app.deposit_auto_card_ok(b))
   order by b.pickup_at limit greatest(p_limit, 1)
$$;

-- a link made while the automatic try is under way leaves it alone
create or replace function public.server_deposit_link_payreq(p_booking uuid, p_token_sha256 text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_id uuid;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null or not app.deposit_link_needed(b) then return jsonb_build_object('ok', false, 'reason', 'not needed'); end if;
  if exists (select 1 from payment_requests q where q.booking_id = b.id and q.channel = 'auto' and q.status = 'open') then
    return jsonb_build_object('ok', false, 'reason', 'the automatic hold is under way');
  end if;
  if app.deposit_link_live(b) then return jsonb_build_object('ok', false, 'reason', 'a live request exists'); end if;
  if p_token_sha256 is null or p_token_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'The link token is missing' using errcode = '22023'; end if;
  update payment_requests set status = 'cancelled', last_error = coalesce(last_error, 'Replaced by a new deposit link')
   where booking_id = b.id and kind = 'hold' and status = 'open' and channel <> 'auto';
  insert into payment_requests (booking_id, renter_id, kind, covers, amount_cents, token_sha256, channel, expires_at, created_by, auto)
  values (b.id, b.renter_id, 'hold', 'deposit', b.deposit_cents, p_token_sha256, 'text', greatest(b.pickup_at + interval '1 day', now() + interval '1 day'), null, true)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'booking_id', b.id, 'booking_number', b.booking_number, 'amount_cents', b.deposit_cents,
    'renter', (select jsonb_build_object('id', r.id, 'legal_name', r.legal_name, 'email', coalesce(r.email, u.email),
                 'customer_id', (select sc.processor_customer_id from payment_methods pm join payment_method_secrets sc on sc.payment_method_id = pm.id
                                  where pm.renter_id = r.id and sc.processor_customer_id is not null order by pm.created_at desc limit 1))
                 from renters r left join users u on u.id = r.user_id where r.id = b.renter_id));
end $$;

-- the link by text, else by email (no mobile, or the text could not go); a task only when neither
create or replace function public.server_deposit_link_send(p_id uuid, p_link text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q payment_requests;
  b bookings;
  rn renters;
  o phone_outbox;
  v_to text;
  v_email text;
  v_why text;
begin
  select * into q from payment_requests where id = p_id for update;
  if q.id is null or q.status <> 'open' or not q.auto then raise exception 'That deposit link is not open' using errcode = '23514'; end if;
  if p_link is null or p_link !~ '^https?://[^ ]+/pay/[A-Za-z0-9_-]{20,}$'
     or encode(sha256(convert_to(regexp_replace(p_link, '^.*/pay/', ''), 'UTF8')), 'hex') <> q.token_sha256 then
    raise exception 'That link is not this request''s' using errcode = '22023';
  end if;
  if q.texted_at is not null or q.emailed_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;
  select * into b from bookings where id = q.booking_id;
  select * into rn from renters where id = b.renter_id;
  v_to := app.phone_e164(rn.mobile);
  if v_to is not null then
    o := app.phone_outbox_put(v_to, format('CarmaCars: booking %s, pickup %s at %s. Please place the deposit hold of %s before pickup (it is released after the rental): %s',
                                           b.booking_number, app.fmt_date(b.pickup_at), app.fmt_time(b.pickup_at), app.fmt_money(q.amount_cents), p_link),
                              'booking', b.id, rn.id, 'deposit_link', null, 'deposit_link:' || q.id, now());
    update phone_outbox set urgent = true where id = o.id;
    if o.status <> 'skipped' then
      update payment_requests set texted_at = now(), text_id = o.id where id = q.id;
      return jsonb_build_object('ok', true, 'to', app.phone_display(o.to_number));
    end if;
    v_why := coalesce(o.status_reason, 'the text was not sent');
    update payment_requests set text_id = o.id where id = q.id;
  else
    v_why := 'no mobile number on file';
  end if;
  -- the email instead
  v_email := coalesce(rn.email, (select u.email from users u where u.id = rn.user_id));
  if v_email is not null then
    perform app.staff_send_message(null, b.id, 'Deposit hold for booking ' || b.booking_number,
      format('Hi %s, please place the deposit hold of %s for your pickup on %s at %s with this secure link: %s. It is a hold, not a charge, and it is released after the rental. The card is entered in Stripe''s own form; CarmaCars never sees the card number.',
             coalesce(nullif(split_part(btrim(rn.legal_name), ' ', 1), ''), 'there'), app.fmt_money(q.amount_cents), app.fmt_date(b.pickup_at), app.fmt_time(b.pickup_at), p_link));
    update payment_requests set emailed_at = now(), last_error = left('Not texted (' || v_why || '): sent by email', 300) where id = q.id;
    return jsonb_build_object('ok', true, 'by', 'email', 'to', v_email);
  end if;
  perform app.deposit_link_problem(q, v_why);
  update payment_requests set last_error = left(initcap(left(v_why, 1)) || substr(v_why, 2), 300) where id = q.id;
  return jsonb_build_object('ok', false, 'reason', case when v_to is null then 'no mobile' else v_why end);
end $$;

-- ================================================================ the job, the Money tab, the handover
alter function app.server_jobs_due() rename to server_jobs_due_pre0261;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  j jsonb := app.server_jobs_due_pre0261();
begin
  if coalesce((j ->> 'deposits')::boolean, false) then return j; end if;
  return j || jsonb_build_object('deposits', exists (select 1 from app.deposit_autos_due(1)));
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre0261()'::regprocedure);

-- where the automatic hold is: off, scheduled (with when), held, failed (with why)
create or replace function app.deposit_auto_state(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  q payment_requests;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or b.booking_type = 'owner' or b.deposit_pay_method <> 'card' or coalesce(b.deposit_cents, 0) <= 0 then return null; end if;
  select * into q from payment_requests x where x.booking_id = b.id and x.channel = 'auto' limit 1;
  if q.id is not null then
    return jsonb_build_object('status', case q.status when 'paid' then 'held' when 'open' then 'running' else 'failed' end, 'at', coalesce(q.completed_at, q.created_at),
      'error', case when q.status <> 'paid' then q.last_error end, 'amount_cents', q.amount_cents);
  end if;
  if not app.deposit_auto_on() then return jsonb_build_object('status', 'off'); end if;
  if exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured', 'settled')) or b.deposit_waived_at is not null then return null; end if;
  if coalesce(b.billable_days, 0) > coalesce((app.settings()).deposit_hold_max_days, 0) then return null; end if;
  return jsonb_build_object('status', case when app.deposit_auto_card_ok(b) then 'scheduled' else 'no_card' end, 'due_at', app.deposit_auto_due_at(b),
    'amount_cents', app.deposit_hold_amount(b, coalesce(app.deposit_auto_card(b) ->> 'funding', 'credit')));
end $$;

alter function app.booking_money(uuid, jsonb) rename to booking_money_pre0261;
create function app.booking_money(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := app.booking_money_pre0261(p_by, p);
begin
  if v is null or nullif(v ->> 'booking_id', '') is null then return v; end if;
  return v || jsonb_build_object('deposit_auto', app.deposit_auto_state((v ->> 'booking_id')::uuid));
end $$;
select pg_temp.copy_grants('app.booking_money(uuid, jsonb)'::regprocedure, 'app.booking_money_pre0261(uuid, jsonb)'::regprocedure);

alter function app.field_read(uuid, text, jsonb) rename to field_read_pre0261;
create function app.field_read(p_user uuid, p_what text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x jsonb := app.field_read_pre0261(p_user, p_what, p);
begin
  if p_what = 'job' and x is not null and jsonb_typeof(x -> 'ready') = 'object' and (x #>> '{booking,id}') is not null then
    x := jsonb_set(x, '{ready,deposit_auto}', coalesce(app.deposit_auto_state((x #>> '{booking,id}')::uuid), 'null'::jsonb));
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.field_read(uuid, text, jsonb)'::regprocedure, 'app.field_read_pre0261(uuid, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname in ('deposit_auto_card', 'deposit_hold_amount', 'deposit_auto_due_at', 'deposit_auto_on', 'deposit_auto_needed', 'deposit_auto_failed',
                                                       'deposit_auto_card_ok', 'deposit_autos_due', 'deposit_auto_problem', 'deposit_auto_state', 'deposit_links_due',
                                                       'server_jobs_due_pre0261', 'booking_money_pre0261', 'field_read_pre0261'))
               or (n.nspname = 'public' and p.proname in ('server_deposit_autos_due', 'server_deposit_auto_begin', 'server_deposit_auto_failed', 'server_deposit_link_payreq',
                                                          'server_deposit_link_send', 'server_payreq_settle_pre0261')) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
