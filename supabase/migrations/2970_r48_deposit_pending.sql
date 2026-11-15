-- 2970 (release 48): "Picked up, deposit pending". The car goes out with the deposit still owed.
--
-- The owner's report (Nov 14): a pickup could not be recorded until the deposit was taken or an Admin waived it
-- ("The deposit is not taken"), so a renter at the lot whose card would not take the hold either waited or had the
-- deposit waived for good. Now staff who record handovers (and an Admin) can let the car go with the deposit owed:
--   deposit_pendings          one row per booking: the amount, who let it go and why (5 characters or more), the
--                             morning tries, the link sent, the 48 hour alert, and when and why it ended (taken,
--                             waived, the car back, the booking ended)
--   app.deposit_pending_ok    the one rule the pickup checks use: a row still open on this booking
--   the pickup checks         Record now (handover_record_now), the one screen (handover_one_screen), the full check-in
--                             (complete_handover), the status triggers (booking_before_write, booking_app_before) and
--                             the override list (handover_blockers) let a booking with that row go on rent
--   door                      ops_do / field_do deposit_pending_allow {booking | job, reason}; handover_record_now and
--                             handover_one_screen take deposit_pending_reason (the connector: deposit_pending: true and
--                             deposit_pending_reason, else its reason)
--   reads                     server_deposit_pending_state (the booking page chip "Deposit pending $X", every role),
--                             server_my_deposit_pending (the renter's page: what is owed), the field ready check and
--                             the caller pop-up say "pending"
--   each morning              from the deposit hold hour (Toronto), once a day while the car is out: the saved card is
--                             tried for the hold once; when it fails, or there is no usable card, the deposit link goes
--                             to the renter (text, else email: the deposit link always keeps its text). Program
--                             settings, deposit_pending_retry, turns this off.
--   after 48 hours            still owed: one Admin To do (deposit_pending_overdue) and an urgent alert, both opening the
--                             booking's Money tab
-- Taken (a hold or a collected deposit), waived, or the car back: the row ends by itself and its To do closes.
-- No applied migration is edited: the functions are wrapped (_pre2970) or patched where they check the deposit.
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
  if position(p_old in d) = 0 then raise exception '2970: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the setting and the table
alter table program_settings add column if not exists deposit_pending_retry boolean not null default true;
comment on column program_settings.deposit_pending_retry is 'r48 (2970): a car out with the deposit owed: each morning the saved card is tried for the hold once, then the deposit link goes to the renter. Off: neither (the 48 hour Admin To do stays).';

create table if not exists deposit_pendings (
  booking_id       uuid primary key references bookings (id) on delete cascade,
  amount_cents     bigint not null check (amount_cents > 0),
  reason           text not null check (length(btrim(reason)) between 5 and 500),
  started_by       uuid references users (id) on delete set null,
  started_at       timestamptz not null default now(),
  last_try_on      date,
  last_try_result  text check (last_try_result is null or length(last_try_result) <= 300),
  last_link_on     date,
  alerted_at       timestamptz,
  cleared_at       timestamptz,
  cleared_why      text check (cleared_why is null or cleared_why in ('taken', 'waived', 'returned', 'ended'))
);
create index if not exists deposit_pendings_open on deposit_pendings (started_at) where cleared_at is null;
create index if not exists deposit_pendings_started_by_idx on deposit_pendings (started_by) where started_by is not null;
comment on table deposit_pendings is 'r48 (2970): a car released with the deposit still owed (staff or an Admin, with the reason). Open while cleared_at is null; the morning retry and the 48 hour To do read it. Never read by a browser.';
alter table deposit_pendings enable row level security;
create policy admin_all on deposit_pendings for select to authenticated using (app.is_admin());
revoke all on deposit_pendings from anon, authenticated;
grant all on deposit_pendings to service_role;
create trigger audit_deposit_pendings after insert or update or delete on deposit_pendings for each row execute function app.audit_row();

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('deposit_pending_overdue', 'admin', 'Deposit still owed 48 hours after pickup', 'urgent', 'none', null,
   'A car went out with the deposit owed (2970) and it is still not taken 48 hours later. Open the booking''s Money tab: take the hold, charge the card on file, or call the renter. Done by itself when the deposit is taken or the car is back.')
on conflict (task_type) do nothing;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('deposit_pending_overdue', 'Deposit still owed 48 hours after pickup', 'Money', '{admin}', 'urgent', 'alerts', true, false,
   'A car went out with the deposit owed (2970) and it is not taken 48 hours later; the alert opens the booking''s Money tab.', 45)
on conflict (rule) do nothing;

-- ================================================================ 2. the one rule
create function app.deposit_pending_ok(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_booking is not null and exists (select 1 from deposit_pendings x where x.booking_id = p_booking and x.cleared_at is null)
$$;

-- the deposit is owed on this booking right now (not an owner trip, not waived, nothing held or collected)
create function app.deposit_owed_now(b bookings) returns boolean
language sql stable security definer set search_path = public, app as $$
  select b.booking_type <> 'owner' and b.deposit_waived_at is null and coalesce(b.deposit_cents, 0) > 0
     and not exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured', 'settled'))
     and not exists (select 1 from payments p where p.booking_id = b.id and p.purpose = 'deposit' and p.status = 'succeeded')
$$;

-- p: {booking, reason}. Staff who record handovers, or an Admin, on a confirmed booking whose deposit is owed. Once per
-- booking (a second call keeps the first reason and returns the row).
create function app.deposit_pending_start(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  x deposit_pendings;
  v_reason text := nullif(left(btrim(coalesce(p ->> 'reason', '')), 500), '');
begin
  if not app.user_may_handover(p_by) then
    raise exception 'Only an Admin, Fleet, Sales, Customer service or field staff let a car go with the deposit owed' using errcode = '42501';
  end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  select * into x from deposit_pendings where booking_id = b.id and cleared_at is null;
  if x.booking_id is not null then return to_jsonb(x) || jsonb_build_object('already', true); end if;
  if v_reason is null or length(v_reason) < 5 then raise exception 'Say why the car goes before the deposit is taken (at least 5 characters)' using errcode = '22023'; end if;
  if b.status <> 'confirmed' then
    raise exception 'Booking % is %: a car goes out with the deposit owed at the pickup of a confirmed booking', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
  end if;
  if not app.deposit_owed_now(b) then raise exception 'No deposit is owed on this booking: record the pickup as usual' using errcode = '23514'; end if;
  insert into deposit_pendings (booking_id, amount_cents, reason, started_by) values (b.id, b.deposit_cents, v_reason, p_by)
  on conflict (booking_id) do update set amount_cents = excluded.amount_cents, reason = excluded.reason, started_by = excluded.started_by, started_at = now(),
     last_try_on = null, last_try_result = null, last_link_on = null, alerted_at = null, cleared_at = null, cleared_why = null
  returning * into x;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('Car released with the deposit owed (%s): %s', app.fmt_money(b.deposit_cents), v_reason), p_by, 'staff',
    jsonb_build_object('deposit_pending', true, 'amount_cents', b.deposit_cents, 'reason', v_reason));
  return to_jsonb(x) || jsonb_build_object('booking_number', b.booking_number);
end $$;

-- ================================================================ 3. the pickup checks
select pg_temp.patch_fn('app.booking_before_write()'::regprocedure,
  $o$if not app.override_skips(new.id, 'deposit') then raise exception 'The Deposit is taken at pickup, before handover'$o$,
  $n$if not (app.override_skips(new.id, 'deposit') or app.deposit_pending_ok(new.id)) then raise exception 'The Deposit is taken at pickup, before handover'$n$);
select pg_temp.patch_fn('app.booking_app_before()'::regprocedure,
  $o$if not app.override_skips(new.id, 'deposit') then raise exception 'No car is released without the Deposit$o$,
  $n$if not (app.override_skips(new.id, 'deposit') or app.deposit_pending_ok(new.id)) then raise exception 'No car is released without the Deposit$n$);
select pg_temp.patch_fn('app.handover_record_now(uuid, jsonb)'::regprocedure,
  $o$if not app.override_skips(b.id, 'deposit') then raise exception 'The deposit is not taken$o$,
  $n$if not (app.override_skips(b.id, 'deposit') or app.deposit_pending_ok(b.id)) then raise exception 'The deposit is not taken$n$);
select pg_temp.patch_fn('app.complete_handover_pre0154(uuid, uuid, jsonb, uuid, timestamptz)'::regprocedure,
  $o$if not (app.booking_readiness(p_booking) ->> 'deposit_ok')::boolean then$o$,
  $n$if not (app.booking_readiness(p_booking) ->> 'deposit_ok')::boolean and not app.deposit_pending_ok(p_booking) then$n$);
select pg_temp.patch_fn('app.handover_blockers_pre0930(uuid, uuid, text, jsonb)'::regprocedure,
  $o$v_codes := v_codes || 'deposit'::text;$o$,
  $n$if not app.deposit_pending_ok(b.id) then v_codes := v_codes || 'deposit'::text; end if;$n$);
-- a deposit taken later (the Money tab, the morning hold, the renter's link) is recorded on the car already out
select pg_temp.patch_fn('app.record_deposit_taken(uuid, uuid, uuid, timestamptz, timestamptz)'::regprocedure,
  $o$if b.status <> 'confirmed' then
    raise exception 'Booking % is %: the Deposit is taken at pickup of a confirmed booking'$o$,
  $n$if b.status <> 'confirmed' and not (b.status = 'on_rent' and app.deposit_pending_ok(b.id)) then
    raise exception 'Booking % is %: the Deposit is taken at pickup of a confirmed booking'$n$);
-- the field checklist's ready line and the caller pop-up: "pending"
select pg_temp.patch_fn('app.field_read_0031(uuid, text, jsonb)'::regprocedure,
  $o$then 'declined' else 'not_taken' end) end,$o$,
  $n$then 'declined' when app.deposit_pending_ok(b.id) then 'pending' else 'not_taken' end) end,$n$);
select pg_temp.patch_fn('app.caller_deposit(uuid)'::regprocedure,
  $o$when d.status = 'failed' then 'failed'$o$,
  $n$when app.deposit_pending_ok(b.id) then 'pending'
                  when d.status = 'failed' then 'failed'$n$);

-- ================================================================ 4. it ends by itself
create function app.deposit_pending_end(p_booking uuid, p_why text) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  update deposit_pendings set cleared_at = now(), cleared_why = p_why where booking_id = p_booking and cleared_at is null;
  if found then
    perform app.resolve_tasks(array['deposit_pending_overdue'], p_booking, null,
      case p_why when 'taken' then 'The deposit was taken' when 'waived' then 'The deposit was waived' when 'returned' then 'The car is back' else 'The booking ended' end);
  end if;
end $$;

create function app.deposit_pending_follow_deposit() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status in ('held', 'captured', 'settled') then perform app.deposit_pending_end(new.booking_id, 'taken'); end if;
  return new;
end $$;
create trigger deposits_deposit_pending after insert or update of status on deposits for each row execute function app.deposit_pending_follow_deposit();

create function app.deposit_pending_follow_booking() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.deposit_waived_at is not null and old.deposit_waived_at is null then perform app.deposit_pending_end(new.id, 'waived');
  elsif new.status is distinct from old.status and new.status in ('returned', 'closed') then perform app.deposit_pending_end(new.id, 'returned');
  elsif new.status is distinct from old.status and new.status in ('cancelled', 'no_show', 'expired', 'declined') then perform app.deposit_pending_end(new.id, 'ended');
  end if;
  return new;
end $$;
create trigger bookings_deposit_pending after update of status, deposit_waived_at on bookings for each row execute function app.deposit_pending_follow_booking();

-- ================================================================ 5. the reads
create function app.deposit_pending_state(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when x.booking_id is null then jsonb_build_object('pending', false) else jsonb_build_object(
      'pending', true, 'amount_cents', x.amount_cents, 'since', x.started_at, 'reason', x.reason,
      'by_name', (select u.full_name from users u where u.id = x.started_by),
      'last_try_on', x.last_try_on, 'last_try_result', x.last_try_result, 'last_link_on', x.last_link_on,
      'overdue', x.started_at < now() - interval '48 hours', 'retry_on', coalesce((app.settings()).deposit_pending_retry, true)) end
    from (select 1) one left join deposit_pendings x on x.booking_id = p_booking and x.cleared_at is null
$$;

create function public.server_deposit_pending_state(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.deposit_pending_state(p_booking) $$;

-- the renter's own booking page: what is owed (only the renter of the booking)
create function public.server_my_deposit_pending(p_booking uuid, p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when exists (select 1 from bookings b join renters r on r.id = b.renter_id where b.id = p_booking and r.user_id = p_by and p_by is not null)
              then (select jsonb_build_object('pending', s ->> 'pending' = 'true', 'amount_cents', (s ->> 'amount_cents')::bigint) from app.deposit_pending_state(p_booking) s)
              else jsonb_build_object('pending', false) end
$$;

-- ================================================================ 6. each morning, and the 48 hours
-- due: the setting on, the car out, the deposit still owed, not tried today, from the deposit hold hour (Toronto)
create function app.deposit_pending_retry_due(p_limit integer default 20) returns setof bookings
language sql stable security definer set search_path = public, app as $$
  select b.* from deposit_pendings x join bookings b on b.id = x.booking_id
   where x.cleared_at is null and coalesce((app.settings()).deposit_pending_retry, true)
     and b.status = 'on_rent' and app.deposit_owed_now(b)
     and x.last_try_on is distinct from app.today()
     and extract(hour from now() at time zone 'America/Toronto') >= coalesce((app.settings()).deposit_auto_hour, 8)
   order by x.started_at limit greatest(p_limit, 1)
$$;

-- the 48 hour To do and alert, once per booking
create function app.deposit_pending_sweep() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  x record;
  n integer := 0;
begin
  for x in select p.*, b.booking_number, b.renter_id, b.vehicle_id, b.status as bstatus from deposit_pendings p join bookings b on b.id = p.booking_id
            where p.cleared_at is null and p.alerted_at is null and p.started_at < now() - interval '48 hours' for update of p loop
    if x.bstatus <> 'on_rent' then continue; end if;
    perform app.raise_task(p_type => 'deposit_pending_overdue', p_title => 'Deposit still owed: ' || x.booking_number,
      p_detail => format('The car went out %s with the deposit of %s owed (%s). It is still not taken. Open the Money tab: take the hold, charge the card on file, or call the renter.',
                         app.fmt_at(x.started_at), app.fmt_money(x.amount_cents), x.reason),
      p_booking => x.booking_id, p_vehicle => x.vehicle_id, p_renter => x.renter_id, p_related_table => 'bookings', p_related_id => x.booking_id,
      p_priority => 'urgent', p_dedupe => 'deposit_pending_overdue:' || x.booking_id, p_queue => 'admin');
    perform app.staff_alert('deposit_pending_overdue', 'booking', x.booking_id, 'pending48:' || x.booking_id,
      format('Deposit still owed: %s', x.booking_number),
      format('%s owed since the pickup %s. Open the Money tab to take it.', app.fmt_money(x.amount_cents), app.fmt_at(x.started_at)),
      jsonb_build_object('path_admin', '/admin/bookings/' || x.booking_number || '?tab=money', 'path_staff', '/staff/bookings/' || x.booking_number || '?tab=money'));
    update deposit_pendings set alerted_at = now() where booking_id = x.booking_id;
    n := n + 1;
  end loop;
  return n;
end $$;

create function app.deposit_pending_job_due() returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from app.deposit_pending_retry_due(1))
      or exists (select 1 from deposit_pendings p where p.cleared_at is null and p.alerted_at is null and p.started_at < now() - interval '48 hours')
      or jsonb_array_length(public.server_deposit_pending_links_due()) > 0
$$;

-- the job's list: the 48 hour sweep runs first, then the bookings to try today
create function public.server_deposit_pending_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.deposit_pending_sweep();
  return coalesce((select jsonb_agg(jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number)) from app.deposit_pending_retry_due(20) b), '[]'::jsonb);
end $$;

-- the morning try: marks today tried; a usable saved card makes one hold request (never sent), else {ok: false, link: true}
create function public.server_deposit_pending_begin(p_booking uuid, p_token_sha256 text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  x deposit_pendings;
  c jsonb;
  v_why text;
  v_amount bigint;
  q payment_requests;
begin
  select * into x from deposit_pendings where booking_id = p_booking and cleared_at is null for update;
  select * into b from bookings where id = p_booking;
  if x.booking_id is null or b.id is null or not exists (select 1 from app.deposit_pending_retry_due(1000) d where d.id = b.id) then
    return jsonb_build_object('ok', false, 'reason', 'not due');
  end if;
  if p_token_sha256 is null or p_token_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'The token is missing' using errcode = '22023'; end if;
  update deposit_pendings set last_try_on = app.today() where booking_id = b.id;
  c := app.deposit_auto_card(b);
  if c is null then v_why := 'no card saved for it';
  elsif not app.booking_card_ok(b.id, jsonb_build_object('funding', c ->> 'funding')) then
    v_why := format('the card on file is a %s card and this booking needs a credit card', coalesce(nullif(c ->> 'funding', 'unknown'), 'non-credit'));
  end if;
  if v_why is not null then
    update deposit_pendings set last_try_result = left(v_why, 300) where booking_id = b.id;
    return jsonb_build_object('ok', false, 'link', true, 'reason', v_why);
  end if;
  v_amount := app.deposit_hold_amount(b, coalesce(c ->> 'funding', 'credit'));
  -- an older link of the deposit is replaced (never two holds asked at once)
  update payment_requests set status = 'cancelled', last_error = coalesce(last_error, 'Replaced by the morning try')
   where booking_id = b.id and kind = 'hold' and status = 'open';
  insert into payment_requests (booking_id, renter_id, kind, covers, amount_cents, reason, token_sha256, channel, expires_at, created_by, auto)
  values (b.id, b.renter_id, 'hold', 'deposit', v_amount, 'Deposit hold: the car is out with the deposit owed', p_token_sha256, 'link', now() + interval '1 day', null, true)
  returning * into q;
  return jsonb_build_object('ok', true, 'id', q.id, 'booking_id', b.id, 'booking_number', b.booking_number, 'amount_cents', v_amount,
    'customer_id', c ->> 'customer_id', 'method_id', c ->> 'method_id');
end $$;

-- the morning try did not go through: recorded, and the link is due next
create function public.server_deposit_pending_failed(p_id uuid, p_error text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare q payment_requests;
begin
  select * into q from payment_requests where id = p_id for update;
  if q.id is null or not exists (select 1 from deposit_pendings x where x.booking_id = q.booking_id) then raise exception 'Not a deposit owed' using errcode = '22023'; end if;
  if q.status = 'open' then
    update payment_requests set status = 'failed', last_error = left(coalesce(nullif(btrim(p_error), ''), 'the card was declined'), 300), completed_at = now() where id = q.id returning * into q;
  end if;
  update deposit_pendings set last_try_result = left(coalesce(nullif(btrim(p_error), ''), 'the card was declined'), 300) where booking_id = q.booking_id;
  perform app.log_booking_event(q.booking_id, 'adjusted', 'on_rent', 'on_rent', null,
    format('Deposit still owed: the morning hold on the saved card did not go through (%s). The deposit link goes to the renter.', coalesce(nullif(btrim(p_error), ''), 'the card was declined')),
    null, 'system', jsonb_build_object('payment_request_id', q.id));
  return jsonb_build_object('ok', true, 'status', q.status);
end $$;

-- the link of the day: one a day, after the morning try did not take it. Returns the request for the Stripe intent; the
-- text (else the email) is sent by server_deposit_link_send.
create function public.server_deposit_pending_link(p_booking uuid, p_token_sha256 text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  x deposit_pendings;
  v_id uuid;
begin
  select * into x from deposit_pendings where booking_id = p_booking and cleared_at is null for update;
  select * into b from bookings where id = p_booking;
  if x.booking_id is null or b.status <> 'on_rent' or not app.deposit_owed_now(b) or not coalesce((app.settings()).deposit_pending_retry, true) then
    return jsonb_build_object('ok', false, 'reason', 'not needed');
  end if;
  if x.last_link_on = app.today() then return jsonb_build_object('ok', false, 'reason', 'sent today'); end if;
  if p_token_sha256 is null or p_token_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'The link token is missing' using errcode = '22023'; end if;
  update payment_requests set status = 'cancelled', last_error = coalesce(last_error, 'Replaced by a new deposit link')
   where booking_id = b.id and kind = 'hold' and status = 'open';
  insert into payment_requests (booking_id, renter_id, kind, covers, amount_cents, reason, token_sha256, channel, expires_at, created_by, auto)
  values (b.id, b.renter_id, 'hold', 'deposit', x.amount_cents, 'Deposit hold: the car is out with the deposit owed', p_token_sha256, 'text', now() + interval '2 days', null, true)
  returning id into v_id;
  update deposit_pendings set last_link_on = app.today() where booking_id = b.id;
  return jsonb_build_object('ok', true, 'id', v_id, 'booking_id', b.id, 'booking_number', b.booking_number, 'amount_cents', x.amount_cents,
    'renter', (select jsonb_build_object('id', r.id, 'legal_name', r.legal_name, 'email', coalesce(r.email, u.email),
                 'customer_id', (select sc.processor_customer_id from payment_methods pm join payment_method_secrets sc on sc.payment_method_id = pm.id
                                  where pm.renter_id = r.id and sc.processor_customer_id is not null order by pm.created_at desc limit 1))
                 from renters r left join users u on u.id = r.user_id where r.id = b.renter_id));
end $$;

-- the deposit link's words when the car is already out (the pickup words otherwise, unchanged)
alter function public.server_deposit_link_send(uuid, text) rename to server_deposit_link_send_pre2970;
create function public.server_deposit_link_send(p_id uuid, p_link text) returns jsonb
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
  select * into b from bookings where id = q.booking_id;
  if q.id is null or b.status <> 'on_rent' then return public.server_deposit_link_send_pre2970(p_id, p_link); end if;
  if q.status <> 'open' or not q.auto then raise exception 'That deposit link is not open' using errcode = '23514'; end if;
  if p_link is null or p_link !~ '^https?://[^ ]+/pay/[A-Za-z0-9_-]{20,}$'
     or encode(sha256(convert_to(regexp_replace(p_link, '^.*/pay/', ''), 'UTF8')), 'hex') <> q.token_sha256 then
    raise exception 'That link is not this request''s' using errcode = '22023';
  end if;
  if q.texted_at is not null or q.emailed_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;
  select * into rn from renters where id = b.renter_id;
  v_to := app.phone_e164(rn.mobile);
  if v_to is not null then
    o := app.phone_outbox_put(v_to, format('CarmaCars: booking %s. Your deposit hold of %s is still owed. Please place it now with this secure link (it is a hold, released after the rental): %s',
                                           b.booking_number, app.fmt_money(q.amount_cents), p_link),
                              'booking', b.id, rn.id, 'deposit_link', null, 'deposit_link:' || q.id, now());
    if o.id is not null then update phone_outbox set urgent = true where id = o.id; end if;
    if o.id is not null and o.status <> 'skipped' then
      update payment_requests set texted_at = now(), text_id = o.id where id = q.id;
      return jsonb_build_object('ok', true, 'to', app.phone_display(o.to_number));
    end if;
    v_why := coalesce(o.status_reason, 'the text was not sent');
  else
    v_why := 'no mobile number on file';
  end if;
  v_email := coalesce(rn.email, (select u.email from users u where u.id = rn.user_id));
  if v_email is not null then
    perform app.staff_send_message(null, b.id, 'Deposit hold still owed for booking ' || b.booking_number,
      format('Hi %s, the deposit hold of %s for your rental is still owed. Please place it now with this secure link: %s. It is a hold, not a charge, and it is released after the rental. The card is entered in Stripe''s own form; CarmaCars never sees the card number.',
             coalesce(nullif(split_part(btrim(rn.legal_name), ' ', 1), ''), 'there'), app.fmt_money(q.amount_cents), p_link));
    update payment_requests set emailed_at = now(), last_error = left('Not texted (' || v_why || '): sent by email', 300) where id = q.id;
    return jsonb_build_object('ok', true, 'by', 'email', 'to', v_email);
  end if;
  update payment_requests set last_error = left(initcap(left(v_why, 1)) || substr(v_why, 2), 300) where id = q.id;
  update deposit_pendings set last_try_result = left('Link not sent: ' || v_why, 300) where booking_id = b.id;
  return jsonb_build_object('ok', false, 'reason', case when v_to is null then 'no mobile' else v_why end);
end $$;
select pg_temp.copy_grants('public.server_deposit_link_send(uuid, text)'::regprocedure, 'public.server_deposit_link_send_pre2970(uuid, text)'::regprocedure);

-- links of the day still to send (the morning try failed or found no card): the job sends them right after the tries
create function public.server_deposit_pending_links_due() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number)), '[]'::jsonb)
    from deposit_pendings x join bookings b on b.id = x.booking_id
   where x.cleared_at is null and coalesce((app.settings()).deposit_pending_retry, true) and b.status = 'on_rent' and app.deposit_owed_now(b)
     and x.last_try_on = app.today() and x.last_link_on is distinct from app.today()
     and not exists (select 1 from payment_requests q where q.booking_id = b.id and q.kind = 'hold' and q.status = 'open' and q.channel = 'link')
$$;

-- the deposit job runs while any of this is due
alter function app.server_jobs_due() rename to server_jobs_due_pre2970;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := app.server_jobs_due_pre2970();
begin
  if coalesce((v ->> 'deposits')::boolean, false) then return v; end if;
  return v || jsonb_build_object('deposits', coalesce(app.deposit_pending_job_due(), false));
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre2970()'::regprocedure);

-- ================================================================ 7. the door
-- deposit_pending_allow {booking | job, reason}; handover_record_now and handover_one_screen with deposit_pending_reason
-- (or deposit_pending: true and the reason) start the row first, in the same transaction: a refused pickup leaves nothing.
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2970;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
  v_reason text;
  v_booking text;
begin
  if p_call in ('ops_do', 'admin_do', 'va_do', 'field_do') and p_name = 'deposit_pending_allow' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    v_booking := coalesce(nullif(p_ ->> 'booking', ''), (select j.booking_id::text from field_jobs j where j.id::text = p_ ->> 'job'));
    return app.deposit_pending_start(p_user, jsonb_build_object('booking', v_booking, 'reason', p_ ->> 'reason'));
  end if;
  if p_call in ('ops_do', 'admin_do', 'va_do') and p_name in ('handover_record_now', 'handover_one_screen') and coalesce(p_ ->> 'kind', '') = 'pickup' then
    v_reason := nullif(btrim(coalesce(p_ ->> 'deposit_pending_reason', '')), '');
    if v_reason is null and coalesce((p_ ->> 'deposit_pending')::boolean, false) then v_reason := coalesce(nullif(btrim(coalesce(p_ ->> 'reason', '')), ''), nullif(btrim(coalesce(p_ ->> 'note', '')), '')); end if;
    if v_reason is not null or coalesce((p_ ->> 'deposit_pending')::boolean, false) then
      if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
      perform app.door_begin(p_user, p_aal);
      perform app.deposit_pending_start(p_user, jsonb_build_object('booking', p_ ->> 'booking', 'reason', v_reason));
    end if;
  end if;
  return app.door_pre2970(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2970(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 8. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['deposit_pending_ok', 'deposit_owed_now', 'deposit_pending_start', 'deposit_pending_end', 'deposit_pending_follow_deposit',
             'deposit_pending_follow_booking', 'deposit_pending_state', 'deposit_pending_retry_due', 'deposit_pending_sweep', 'deposit_pending_job_due', 'door_pre2970', 'server_jobs_due_pre2970']))
        or (n.nspname = 'public' and p.proname = any (array['server_deposit_pending_state', 'server_my_deposit_pending', 'server_deposit_pending_due', 'server_deposit_pending_begin',
             'server_deposit_pending_failed', 'server_deposit_pending_link', 'server_deposit_pending_links_due', 'server_deposit_link_send_pre2970']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
