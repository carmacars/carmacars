-- 0300_push_notifications.sql
-- Phone and browser alerts (Web Push with VAPID keys) and the installable site (docs/changes/2026-11-05-push-alerts.md).
-- SCHEMA_MARKER 0301 (0301 carries the guide chapters).
--
--   1. Each person turns alerts on per device (phone or computer) from their profile in the renter, owner, investor and
--      staff portals and from Admin > Settings > My phone alerts. A device is one push subscription (push_subscriptions):
--      the endpoint the browser's push service gave, and its two public keys. Nothing else about the device is kept
--      except a short label ("iPhone", "Chrome on Windows") so the person can tell their devices apart.
--   2. What alerts: seven topics (requests, bookings, payments, handovers, messages, alerts, documents), each catalogue
--      notice belongs to at most one (notification_catalogue.push_topic). A notice without a topic never goes by push:
--      sign-in links and codes, digests, marketing, hiring. Each person's topics default by their portal (app.push_role):
--      renters everything; owners new bookings, booking changes, payments, incidents and documents; investors payments,
--      documents and messages; staff requests, booking changes, messages and alerts; field staff their jobs and pay;
--      admins requests, payments, messages and alerts. The person changes them on the same card (push_preferences).
--   3. The send path: every in-app notice (notifications, written by app.process_events for each recipient with an
--      account) that has a topic the person keeps queues one push per device of that person (push_outbox), due when the
--      notice's email is due. Customers' alerts wait for the end of the text quiet hours (0096, 21:00 to 8:00) unless
--      they are urgent (the alerts topic). The Worker's five-minute tick sends them (/api/jobs/push) only when the VAPID
--      keys are set and something is due (public.server_push_waiting); a notice read in the portal before its push goes
--      is not pushed. A push service answering 404 or 410 means the device unsubscribed: the subscription is deleted.
--      Other failures retry up to 5 times; 3 refusals in a row (a key change) end the subscription too.
--   4. Off switch: program_settings.push_enabled (on by default). Without the VAPID keys in the Worker (the vault
--      secrets deploy_vapid_public_key and deploy_vapid_private_key) the cards are hidden and nothing is queued for
--      devices, because no device can subscribe.
--   5. The privacy policy: one paragraph after the text alerts paragraph (section 10).
-- No earlier migration is edited.
set local check_function_bodies = off;

-- ================================================================ 1. settings and topics
alter table program_settings add column if not exists push_enabled boolean not null default true;
comment on column program_settings.push_enabled is 'Phone and browser alerts (0300): send in-app notices to the devices people turned alerts on for. Needs the VAPID keys in the Worker; off stops every push at once.';

alter table notification_catalogue add column if not exists push_topic text
  check (push_topic in ('requests', 'bookings', 'payments', 'handovers', 'messages', 'alerts', 'documents'));
comment on column notification_catalogue.push_topic is 'Phone and browser alerts (0300): the topic this notice belongs to; null never goes by push (sign-in links and codes, digests, marketing).';

update notification_catalogue c set push_topic = t.topic
  from (values
    -- new requests, offers and their answers
    ('staff_booking_request_new', 'requests'), ('staff_request_waiting', 'requests'), ('staff_extension_requested', 'requests'),
    ('staff_change_request_received', 'requests'), ('staff_owner_application_received', 'requests'), ('staff_identity_review', 'requests'),
    ('owner_new_booking', 'requests'), ('renter_offer_ready', 'requests'), ('renter_offer_reminder', 'requests'),
    ('renter_offer_expired', 'requests'), ('renter_offer_withdrawn', 'requests'), ('renter_request_needs_info', 'requests'),
    ('renter_request_declined', 'requests'),
    -- booking changes
    ('renter_booking_confirmed', 'bookings'), ('owner_booking_confirmed', 'bookings'), ('owner_booking_changed', 'bookings'),
    ('renter_booking_cancelled', 'bookings'), ('renter_booking_cancelled_by_us', 'bookings'), ('renter_change_proposed', 'bookings'),
    ('renter_change_applied', 'bookings'), ('renter_change_request_approved', 'bookings'), ('renter_change_request_declined', 'bookings'),
    ('renter_change_proposal_reminder', 'bookings'), ('renter_change_proposal_expired', 'bookings'), ('renter_extension_approved', 'bookings'),
    ('renter_extension_declined', 'bookings'), ('renter_extension_confirmed', 'bookings'), ('renter_rental_added', 'bookings'),
    ('staff_cancellation_received', 'bookings'), ('staff_change_proposal_answered', 'bookings'),
    -- money
    ('owner_payment_received', 'payments'), ('owner_payment_failed', 'payments'), ('owner_payment_reversed', 'payments'),
    ('owner_payout_sent', 'payments'), ('owner_debit_returned', 'payments'), ('owner_invoice_issued', 'payments'),
    ('renter_payment_receipt', 'payments'), ('renter_payment_failed', 'payments'), ('renter_refund_issued', 'payments'),
    ('renter_deposit_released', 'payments'), ('renter_deposit_declined', 'payments'), ('renter_extra_charge', 'payments'),
    ('renter_balance_overdue', 'payments'), ('renter_recovery_pay', 'payments'), ('investor_return_paid', 'payments'),
    ('staff_offer_approved_paid', 'payments'), ('staff_payment_failed', 'payments'), ('staff_deposit_release_due', 'payments'),
    ('staff_commission_paid', 'payments'),
    -- pickups, returns and field jobs
    ('renter_pickup_details', 'handovers'), ('renter_booking_reminder', 'handovers'), ('renter_return_reminder', 'handovers'),
    ('renter_return_details', 'handovers'), ('renter_trip_checkin', 'handovers'), ('renter_return_complete', 'handovers'),
    ('staff_field_job_assigned', 'handovers'), ('staff_field_job_changed', 'handovers'), ('staff_field_jobs_today', 'handovers'),
    ('staff_field_jobs_tomorrow', 'handovers'),
    -- messages
    ('renter_staff_message', 'messages'), ('insurance_staff_message', 'messages'), ('staff_renter_replied', 'messages'),
    ('staff_chat_waiting', 'messages'), ('investor_notice_received', 'messages'),
    -- urgent
    ('staff_late_return_alert', 'alerts'), ('staff_breakdown_reported', 'alerts'), ('staff_incident_reported', 'alerts'),
    ('staff_site_alert', 'alerts'), ('staff_job_failed', 'alerts'), ('staff_dispute_opened', 'alerts'),
    ('staff_disable_approval_needed', 'alerts'), ('staff_approval_needed', 'alerts'), ('staff_calendar_conflict', 'alerts'),
    ('renter_late_return_first', 'alerts'), ('renter_late_return_final', 'alerts'), ('renter_vehicle_disabled', 'alerts'),
    ('renter_accident_instructions', 'alerts'), ('renter_breakdown_help', 'alerts'), ('renter_damage_found', 'alerts'),
    ('owner_incident_opened', 'alerts'), ('owner_incident_update', 'alerts'),
    -- documents to sign and statements
    ('renter_agreement_ready', 'documents'), ('owner_agreement_ready', 'documents'), ('person_document_to_sign', 'documents'),
    ('owner_statement_ready', 'documents'), ('investor_statement_ready', 'documents'), ('renter_final_statement', 'documents'),
    ('renter_identity_needed', 'documents'), ('renter_identity_approved', 'documents'), ('renter_identity_rejected', 'documents'),
    ('renter_coverage_needed', 'documents'), ('owner_document_due', 'documents'), ('owner_cosigner_sign', 'documents')
  ) as t(code, topic)
 where c.code = t.code and c.push_topic is null;

-- ================================================================ 2. devices, choices and the queue
create table if not exists push_subscriptions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references users (id) on delete cascade,
  endpoint      text not null unique check (endpoint ~ '^https://[^\s]+$' and length(endpoint) <= 1000),
  p256dh        text not null check (p256dh ~ '^[A-Za-z0-9_-]{80,100}={0,2}$'),
  auth          text not null check (auth ~ '^[A-Za-z0-9_-]{16,32}={0,2}$'),
  portal        text check (portal in ('renter', 'owner', 'investor', 'staff', 'field', 'admin')),
  device        text check (length(device) <= 60),
  created_at    timestamptz not null default now(),
  last_sent_at  timestamptz,
  refusals      integer not null default 0 check (refusals >= 0),
  last_error    text
);
create index if not exists push_subscriptions_user_idx on push_subscriptions (user_id);
comment on table push_subscriptions is 'Phone and browser alerts (0300): one row per device a person turned alerts on for. The endpoint and keys come from the browser; a 404 or 410 from the push service deletes the row.';

create table if not exists push_preferences (
  user_id     uuid primary key references users (id) on delete cascade,
  topics      text[] not null default '{}' check (topics <@ array['requests', 'bookings', 'payments', 'handovers', 'messages', 'alerts', 'documents']::text[]),
  updated_at  timestamptz not null default now()
);
comment on table push_preferences is 'Phone and browser alerts (0300): the topics a person chose. No row: the defaults of their portal (app.push_default_topics).';

create table if not exists push_outbox (
  id               uuid primary key default gen_random_uuid(),
  subscription_id  uuid not null references push_subscriptions (id) on delete cascade,
  user_id          uuid not null references users (id) on delete cascade,
  notification_id  uuid references notifications (id) on delete cascade,
  code             text not null,
  title            text not null,
  body             text,
  url              text not null default '/',
  urgent           boolean not null default false,
  send_after       timestamptz not null default now(),
  status           text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'failed', 'skipped')),
  attempts         integer not null default 0 check (attempts >= 0),
  locked_at        timestamptz,
  sent_at          timestamptz,
  last_error       text,
  created_at       timestamptz not null default now(),
  unique (subscription_id, notification_id)
);
create index if not exists push_outbox_due_idx on push_outbox (send_after) where status in ('queued', 'sending');
comment on table push_outbox is 'Phone and browser alerts (0300): one push per device per in-app notice, sent by the Worker (/api/jobs/push). Kept 30 days.';

-- ================================================================ 3. topics per person
create or replace function app.push_role(p_user uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(
    (select case r.role::text when 'va' then 'staff' else r.role::text end from user_roles r where r.user_id = p_user
      order by array_position(array['admin', 'va', 'field', 'owner', 'renter'], r.role::text) limit 1),
    (select 'owner' from owners o where o.user_id = p_user limit 1),
    (select 'investor' from investors i where i.user_id = p_user limit 1),
    'renter')
$$;

create or replace function app.push_default_topics(p_role text) returns text[]
language sql immutable as $$
  select case p_role
    when 'admin' then array['requests', 'payments', 'messages', 'alerts']
    when 'staff' then array['requests', 'bookings', 'messages', 'alerts']
    when 'field' then array['handovers', 'payments']
    when 'owner' then array['requests', 'bookings', 'payments', 'alerts', 'documents']
    when 'investor' then array['payments', 'messages', 'documents']
    else array['requests', 'bookings', 'payments', 'handovers', 'messages', 'alerts', 'documents'] end::text[]
$$;

create or replace function app.push_topics(p_user uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select coalesce((select p.topics from push_preferences p where p.user_id = p_user), app.push_default_topics(app.push_role(p_user)))
$$;

-- a link of ours as a path on this site (an alert opens the page in the app); anything else opens the portal
create or replace function app.push_path(p_url text) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_base text := rtrim(coalesce((app.settings()).notify_base_url, ''), '/');
begin
  if p_url is null or btrim(p_url) = '' then return '/'; end if;
  if p_url ~ '^/[^/\\]' or p_url = '/' then return p_url; end if;
  if v_base <> '' and left(p_url, length(v_base) + 1) = v_base || '/' then return substr(p_url, length(v_base) + 1); end if;
  return '/';
end $$;

-- ================================================================ 4. queue from the in-app notice
create or replace function app.push_from_notice() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_topic text;
  v_after timestamptz;
  v_urgent boolean;
  v_role text;
begin
  if not coalesce(s.push_enabled, true) then return new; end if;
  if not exists (select 1 from push_subscriptions where user_id = new.user_id) then return new; end if;
  select c.push_topic into v_topic from notification_catalogue c where c.code = new.code;
  if v_topic is null or not (v_topic = any (app.push_topics(new.user_id))) then return new; end if;
  -- an alert is extra: nothing here may stop the in-app notice, its email or its text
  begin
    v_urgent := v_topic = 'alerts';
    select (e.payload ->> '_send_after')::timestamptz into v_after from app_events e where e.id = new.event_id;
    v_after := greatest(coalesce(v_after, now()), now());
    v_role := app.push_role(new.user_id);
    -- customers: the text quiet hours, except urgent alerts (staff choose their own phone's quiet hours)
    if not v_urgent and v_role in ('renter', 'owner', 'investor') then v_after := app.sms_quiet_end(v_after); end if;
    insert into push_outbox (subscription_id, user_id, notification_id, code, title, body, url, urgent, send_after)
    select ps.id, new.user_id, new.id, new.code, left(new.title, 120), left(nullif(btrim(coalesce(new.body, '')), ''), 240),
           app.push_path(new.url), v_urgent, v_after
      from push_subscriptions ps where ps.user_id = new.user_id
    on conflict (subscription_id, notification_id) do nothing;
  exception when others then
    raise warning 'push alert not queued for notice %: %', new.id, sqlerrm;
  end;
  return new;
end $$;

drop trigger if exists notifications_push on notifications;
create trigger notifications_push after insert on notifications for each row execute function app.push_from_notice();

-- ================================================================ 5. what the portals call
create or replace function app.push_state(p_user uuid, p_endpoint text default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_role text := app.push_role(p_user);
begin
  if p_user is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'enabled', coalesce((app.settings()).push_enabled, true),
    'role', v_role,
    'topics', to_jsonb(app.push_topics(p_user)),
    'defaults', to_jsonb(app.push_default_topics(v_role)),
    'chosen', exists (select 1 from push_preferences where user_id = p_user),
    'this_device', case when p_endpoint is null then null else exists (select 1 from push_subscriptions where user_id = p_user and endpoint = p_endpoint) end,
    'devices', coalesce((select jsonb_agg(jsonb_build_object('id', ps.id, 'device', coalesce(ps.device, 'Device'), 'portal', ps.portal,
                 'created_at', ps.created_at, 'last_sent_at', ps.last_sent_at, 'this', ps.endpoint = p_endpoint) order by ps.created_at desc)
               from push_subscriptions ps where ps.user_id = p_user), '[]'::jsonb));
end $$;

create or replace function app.push_subscribe(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_endpoint text := btrim(coalesce(p ->> 'endpoint', ''));
  v_portal text := nullif(p ->> 'portal', '');
  v_device text := left(nullif(btrim(coalesce(p ->> 'device', '')), ''), 60);
begin
  if p_user is null or not exists (select 1 from users where id = p_user) then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if v_endpoint !~ '^https://[^\s]+$' or length(v_endpoint) > 1000 then raise exception 'This browser gave an address we cannot use.' using errcode = '22023'; end if;
  if v_portal is not null and v_portal not in ('renter', 'owner', 'investor', 'staff', 'field', 'admin') then v_portal := null; end if;
  -- one device, one person: a browser signed in as someone else now alerts the person signed in
  insert into push_subscriptions (user_id, endpoint, p256dh, auth, portal, device)
  values (p_user, v_endpoint, p ->> 'p256dh', p ->> 'auth', v_portal, v_device)
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
    portal = excluded.portal, device = coalesce(excluded.device, push_subscriptions.device), refusals = 0, last_error = null,
    created_at = case when push_subscriptions.user_id = excluded.user_id then push_subscriptions.created_at else now() end;
  -- at most 10 devices a person: the oldest goes
  delete from push_subscriptions where id in (select id from push_subscriptions where user_id = p_user order by created_at desc offset 10);
  return app.push_state(p_user, v_endpoint);
end $$;

create or replace function app.push_unsubscribe(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_user is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  delete from push_subscriptions where user_id = p_user
     and (endpoint = p ->> 'endpoint' or id::text = p ->> 'id');
  return app.push_state(p_user, p ->> 'endpoint');
end $$;

create or replace function app.push_set_topics(p_user uuid, p_topics text[]) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v text[] := array(select distinct t from unnest(coalesce(p_topics, '{}')) t
                     where t = any (array['requests', 'bookings', 'payments', 'handovers', 'messages', 'alerts', 'documents']) order by 1);
begin
  if p_user is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  insert into push_preferences (user_id, topics) values (p_user, v)
  on conflict (user_id) do update set topics = excluded.topics, updated_at = now();
  return app.push_state(p_user, null);
end $$;

-- "Send a test alert": one push to each of the person's devices now
create or replace function app.push_test(p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_n integer;
begin
  if p_user is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if exists (select 1 from push_outbox where user_id = p_user and code = 'push_test' and created_at > now() - interval '30 seconds') then
    raise exception 'A test alert is on its way. Wait a moment before sending another.' using errcode = '22023';
  end if;
  insert into push_outbox (subscription_id, user_id, code, title, body, url, urgent)
  select ps.id, p_user, 'push_test', 'CarmaCars alerts are on', 'This is how an alert looks on this device.', '/', true
    from push_subscriptions ps where ps.user_id = p_user;
  get diagnostics v_n = row_count;
  return jsonb_build_object('queued', v_n);
end $$;

-- ================================================================ 6. the sender (the Worker)
create or replace function app.server_push_waiting() returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((app.settings()).push_enabled, true)
     and exists (select 1 from push_outbox where status = 'queued' and send_after <= now()
                 union all select 1 from push_outbox where status = 'sending' and locked_at < now() - interval '10 minutes')
$$;

create or replace function app.server_push_due(p_limit integer default 50) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb;
begin
  if not coalesce((app.settings()).push_enabled, true) then return '[]'::jsonb; end if;
  -- read in the portal before it went: nothing to alert
  update push_outbox o set status = 'skipped', last_error = 'read before it was sent'
    from notifications n where n.id = o.notification_id and o.status = 'queued' and n.read_at is not null;
  -- kept 30 days
  delete from push_outbox where status in ('sent', 'failed', 'skipped') and created_at < now() - interval '30 days';
  with due as (
    select o.id from push_outbox o
     where (o.status = 'queued' and o.send_after <= now()) or (o.status = 'sending' and o.locked_at < now() - interval '10 minutes')
     order by o.urgent desc, o.send_after limit greatest(1, least(coalesce(p_limit, 50), 200)) for update skip locked
  ), claimed as (
    update push_outbox o set status = 'sending', locked_at = now(), attempts = o.attempts + 1
      from due where o.id = due.id returning o.*
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'endpoint', ps.endpoint, 'p256dh', ps.p256dh, 'auth', ps.auth,
           'urgent', c.urgent, 'payload', jsonb_build_object('title', c.title, 'body', c.body, 'url', c.url, 'tag', coalesce(c.notification_id::text, c.id::text), 'code', c.code))), '[]'::jsonb)
    into v from claimed c join push_subscriptions ps on ps.id = c.subscription_id;
  return v;
end $$;

-- the push services' answers: sent; gone (404/410: the device unsubscribed, deleted); refused (400/401/403: counted,
-- 3 in a row end the subscription); retry (429/5xx/network: again in 5 minutes, at most 5 tries)
create or replace function app.server_push_result(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb;
  v_sub uuid;
  v_sent integer := 0; v_gone integer := 0; v_retry integer := 0; v_failed integer := 0;
begin
  for r in select * from jsonb_array_elements(coalesce(p -> 'results', '[]'::jsonb)) loop
    select subscription_id into v_sub from push_outbox where id = (r ->> 'id')::uuid and status = 'sending';
    if v_sub is null then continue; end if;
    case r ->> 'outcome'
      when 'sent' then
        update push_outbox set status = 'sent', sent_at = now(), locked_at = null, last_error = null where id = (r ->> 'id')::uuid;
        update push_subscriptions set last_sent_at = now(), refusals = 0, last_error = null where id = v_sub;
        v_sent := v_sent + 1;
      when 'gone' then
        delete from push_subscriptions where id = v_sub;
        v_gone := v_gone + 1;
      when 'refused' then
        update push_outbox set status = 'failed', locked_at = null, last_error = left(r ->> 'error', 300) where id = (r ->> 'id')::uuid;
        update push_subscriptions set refusals = refusals + 1, last_error = left(r ->> 'error', 300) where id = v_sub;
        delete from push_subscriptions where id = v_sub and refusals >= 3;
        v_failed := v_failed + 1;
      else
        update push_outbox set status = case when attempts >= 5 then 'failed' else 'queued' end, locked_at = null,
               send_after = now() + interval '5 minutes', last_error = left(coalesce(r ->> 'error', 'retry'), 300)
         where id = (r ->> 'id')::uuid;
        v_retry := v_retry + 1;
    end case;
  end loop;
  return jsonb_build_object('sent', v_sent, 'gone', v_gone, 'retry', v_retry, 'failed', v_failed);
end $$;

-- ================================================================ 7. the privacy policy (the live legal.privacy block, where it still has our text)
update site_content_blocks
   set body = replace(body, 'and START to turn them back on; we then reach you by email. Message and data rates may apply.',
     'and START to turn them back on; we then reach you by email. Message and data rates may apply.

If you turn on alerts on a phone or computer, your browser gives us an address at its push service (Google, Apple, Mozilla or Microsoft) and two keys for that device. We use them only to send you alerts about your bookings, account, payments and documents, encrypted so the push service cannot read them, and we delete them when you turn alerts off or the device stops accepting them.')
 where block_key = 'legal.privacy' and body like '%and START to turn them back on; we then reach you by email. Message and data rates may apply.%'
   and body not like '%If you turn on alerts on a phone or computer%';

-- ================================================================ 8. server wrappers and privileges
create or replace function public.server_push_state(p_user uuid, p_endpoint text default null) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.push_state(p_user, p_endpoint) $$;
create or replace function public.server_push_subscribe(p_user uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.push_subscribe(p_user, p) $$;
create or replace function public.server_push_unsubscribe(p_user uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.push_unsubscribe(p_user, p) $$;
create or replace function public.server_push_set_topics(p_user uuid, p_topics text[]) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.push_set_topics(p_user, p_topics) $$;
create or replace function public.server_push_test(p_user uuid) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.push_test(p_user) $$;
create or replace function public.server_push_waiting() returns boolean
language sql stable security invoker set search_path = public, app as $$ select app.server_push_waiting() $$;
create or replace function public.server_push_due(p_limit integer default 50) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.server_push_due(p_limit) $$;
create or replace function public.server_push_result(p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.server_push_result(p) $$;

alter table push_subscriptions enable row level security;
alter table push_preferences enable row level security;
alter table push_outbox enable row level security;
drop policy if exists admin_all on push_subscriptions;
create policy admin_all on push_subscriptions for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop policy if exists admin_all on push_preferences;
create policy admin_all on push_preferences for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop policy if exists admin_all on push_outbox;
create policy admin_all on push_outbox for all to authenticated using (app.is_admin()) with check (app.is_admin());
-- a device turned on or off and a choice of topics are in the audit log; the alerts queue is not (one row per alert)
drop trigger if exists audit_push_subscriptions on push_subscriptions;
-- a device added or removed, without its push address and keys (redact); each send's time stamp is not logged
create trigger audit_push_subscriptions after insert or delete on push_subscriptions for each row execute function app.audit_row('redact');
drop trigger if exists audit_push_preferences on push_preferences;
create trigger audit_push_preferences after insert or update or delete on push_preferences for each row execute function app.audit_row();
revoke all on push_subscriptions, push_preferences, push_outbox from anon, authenticated;
grant select on push_subscriptions, push_preferences, push_outbox to authenticated;   -- admins only, by policy
grant all on push_subscriptions, push_preferences, push_outbox to service_role;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['push_role', 'push_topics', 'push_path', 'push_from_notice', 'push_state', 'push_subscribe',
              'push_unsubscribe', 'push_set_topics', 'push_test', 'server_push_waiting', 'server_push_due', 'server_push_result']))
        or (n.nspname = 'public' and p.proname = any (array['server_push_state', 'server_push_subscribe', 'server_push_unsubscribe',
              'server_push_set_topics', 'server_push_test', 'server_push_waiting', 'server_push_due', 'server_push_result']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- a pure helper, no data
grant execute on function app.push_default_topics(text) to anon, authenticated, service_role;
