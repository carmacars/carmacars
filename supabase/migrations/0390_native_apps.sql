-- 0390_native_apps.sql
-- The App Store and Google Play app (docs/decisions/0002-native-apps-plan.md, docs/changes/2026-11-06-native-apps.md).
-- SCHEMA_MARKER 0391 (0391 carries the guide chapters).
--
--   1. Phone alerts in the app. The app registers with Firebase Cloud Messaging (APNs on iPhone, through Firebase) and
--      gives a token instead of a browser's push address and keys. A device is still one push_subscriptions row, now of
--      a kind: 'web' (the browser, as in 0300) or 'fcm' (the app; endpoint 'fcm:<token>', no keys). Everything else is
--      the same outbox and the same topics: every in-app notice queues one alert per device (0300's trigger), and the
--      Worker sends each by its kind (web/src/server/push.ts). A kind without its keys in the Worker is not claimed:
--      until the Firebase service account is set (deploy_fcm_service_account in the vault), the app's alerts stay off
--      and the app shows no alerts card. An alert not sent within 3 days is dropped (it would only be stale).
--   2. Delete my account (Apple's rule for apps with sign-up: the deletion starts inside the app). A renter, owner or
--      investor asks from their profile; the request opens a task for the Admin (Today) and the person sees it as
--      requested, with the option to withdraw it. Marking the task Done marks the request done. Rental agreements,
--      receipts and tax records are kept as the law requires; everything else is deleted (the task says what).
-- No applied migration is edited.
set local check_function_bodies = off;

-- ================================================================ 1. devices of two kinds
alter table push_subscriptions add column if not exists kind text not null default 'web';
alter table push_subscriptions add column if not exists platform text;
alter table push_subscriptions alter column p256dh drop not null;
alter table push_subscriptions alter column auth drop not null;
-- 0300's column checks (a browser's https address and keys) become one check per kind
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'push_subscriptions'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ~ '(endpoint|p256dh|auth) ~' loop
    execute format('alter table push_subscriptions drop constraint %I', c.conname);
  end loop;
end $$;
alter table push_subscriptions drop constraint if exists push_subscriptions_kind_check;
alter table push_subscriptions add constraint push_subscriptions_kind_check check (kind in ('web', 'fcm'));
alter table push_subscriptions drop constraint if exists push_subscriptions_platform_check;
alter table push_subscriptions add constraint push_subscriptions_platform_check check (platform is null or platform in ('ios', 'android'));
alter table push_subscriptions drop constraint if exists push_subscriptions_shape_check;
alter table push_subscriptions add constraint push_subscriptions_shape_check check (
  (kind = 'web' and endpoint ~ '^https://[^\s]+$' and length(endpoint) <= 1000
     and p256dh ~ '^[A-Za-z0-9_-]{80,100}={0,2}$' and auth ~ '^[A-Za-z0-9_-]{16,32}={0,2}$')
  or (kind = 'fcm' and endpoint ~ '^fcm:[A-Za-z0-9_:.-]{20,1000}$' and p256dh is null and auth is null));
comment on column push_subscriptions.kind is 'Native apps (0390): web, a browser''s Web Push subscription (endpoint and keys); fcm, the App Store or Google Play app (endpoint fcm:<Firebase token>, no keys).';
comment on column push_subscriptions.platform is 'Native apps (0390): ios or android for the app; null for a browser.';

-- ================================================================ 2. subscribe: a browser or the app
create or replace function app.push_subscribe(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_kind text := case when p ->> 'kind' = 'fcm' then 'fcm' else 'web' end;
  v_endpoint text;
  v_token text;
  v_portal text := nullif(p ->> 'portal', '');
  v_device text := left(nullif(btrim(coalesce(p ->> 'device', '')), ''), 60);
  v_platform text := case when v_kind = 'fcm' and p ->> 'platform' in ('ios', 'android') then p ->> 'platform' end;
begin
  if p_user is null or not exists (select 1 from users where id = p_user) then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if v_kind = 'fcm' then
    v_token := btrim(coalesce(p ->> 'token', ''));
    if v_token !~ '^[A-Za-z0-9_:.-]{20,1000}$' then raise exception 'This phone gave a push address we cannot use.' using errcode = '22023'; end if;
    v_endpoint := 'fcm:' || v_token;
  else
    v_endpoint := btrim(coalesce(p ->> 'endpoint', ''));
    if v_endpoint !~ '^https://[^\s]+$' or length(v_endpoint) > 1000 then raise exception 'This browser gave an address we cannot use.' using errcode = '22023'; end if;
  end if;
  if v_portal is not null and v_portal not in ('renter', 'owner', 'investor', 'staff', 'field', 'admin') then v_portal := null; end if;
  -- one device, one person: a phone or browser signed in as someone else now alerts the person signed in
  insert into push_subscriptions (user_id, kind, platform, endpoint, p256dh, auth, portal, device)
  values (p_user, v_kind, v_platform, v_endpoint,
          case when v_kind = 'web' then p ->> 'p256dh' end, case when v_kind = 'web' then p ->> 'auth' end, v_portal, v_device)
  on conflict (endpoint) do update set user_id = excluded.user_id, kind = excluded.kind, platform = excluded.platform,
    p256dh = excluded.p256dh, auth = excluded.auth, portal = excluded.portal,
    device = coalesce(excluded.device, push_subscriptions.device), refusals = 0, last_error = null,
    created_at = case when push_subscriptions.user_id = excluded.user_id then push_subscriptions.created_at else now() end;
  -- at most 10 devices a person: the oldest goes
  delete from push_subscriptions where id in (select id from push_subscriptions where user_id = p_user order by created_at desc offset 10);
  return app.push_state(p_user, v_endpoint);
end $$;

-- the devices list says which are the app (the card shows "CarmaCars app")
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
                 'kind', ps.kind, 'platform', ps.platform,
                 'created_at', ps.created_at, 'last_sent_at', ps.last_sent_at, 'this', ps.endpoint = p_endpoint) order by ps.created_at desc)
               from push_subscriptions ps where ps.user_id = p_user), '[]'::jsonb));
end $$;

-- ================================================================ 3. the sender claims only the kinds it can send
drop function if exists public.server_push_waiting();
drop function if exists app.server_push_waiting();
drop function if exists public.server_push_due(integer);
drop function if exists app.server_push_due(integer);

create or replace function app.server_push_waiting(p_kinds text[] default null) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((app.settings()).push_enabled, true)
     and exists (select 1 from push_outbox o join push_subscriptions ps on ps.id = o.subscription_id
                  where ((o.status = 'queued' and o.send_after <= now()) or (o.status = 'sending' and o.locked_at < now() - interval '10 minutes'))
                    and (p_kinds is null or ps.kind = any (p_kinds)))
$$;

create or replace function app.server_push_due(p_limit integer default 50, p_kinds text[] default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb;
begin
  if not coalesce((app.settings()).push_enabled, true) then return '[]'::jsonb; end if;
  -- read in the portal before it went: nothing to alert
  update push_outbox o set status = 'skipped', last_error = 'read before it was sent'
    from notifications n where n.id = o.notification_id and o.status = 'queued' and n.read_at is not null;
  -- not sent within 3 days (no sender for its kind yet, or retried out): stale, dropped
  update push_outbox set status = 'failed', locked_at = null, last_error = 'not sent within 3 days'
   where status = 'queued' and created_at < now() - interval '3 days';
  -- kept 30 days
  delete from push_outbox where status in ('sent', 'failed', 'skipped') and created_at < now() - interval '30 days';
  with due as (
    select o.id from push_outbox o join push_subscriptions ps on ps.id = o.subscription_id
     where ((o.status = 'queued' and o.send_after <= now()) or (o.status = 'sending' and o.locked_at < now() - interval '10 minutes'))
       and (p_kinds is null or ps.kind = any (p_kinds))
     order by o.urgent desc, o.send_after limit greatest(1, least(coalesce(p_limit, 50), 200)) for update of o skip locked
  ), claimed as (
    update push_outbox o set status = 'sending', locked_at = now(), attempts = o.attempts + 1
      from due where o.id = due.id returning o.*
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'kind', ps.kind, 'platform', ps.platform,
           'endpoint', case when ps.kind = 'web' then ps.endpoint end,
           'token', case when ps.kind = 'fcm' then substr(ps.endpoint, 5) end,
           'p256dh', ps.p256dh, 'auth', ps.auth,
           'urgent', c.urgent, 'payload', jsonb_build_object('title', c.title, 'body', c.body, 'url', c.url, 'tag', coalesce(c.notification_id::text, c.id::text), 'code', c.code))), '[]'::jsonb)
    into v from claimed c join push_subscriptions ps on ps.id = c.subscription_id;
  return v;
end $$;

create or replace function public.server_push_waiting(p_kinds text[] default null) returns boolean
language sql stable security invoker set search_path = public, app as $$ select app.server_push_waiting(p_kinds) $$;
create or replace function public.server_push_due(p_limit integer default 50, p_kinds text[] default null) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.server_push_due(p_limit, p_kinds) $$;

-- ================================================================ 4. delete my account
create table if not exists account_deletion_requests (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references users (id) on delete cascade,
  status        text not null default 'open' check (status in ('open', 'done', 'withdrawn')),
  reason        text check (length(reason) <= 500),
  task_id       uuid references tasks (id) on delete set null,
  requested_at  timestamptz not null default now(),
  closed_at     timestamptz,
  check (status = 'open' or closed_at is not null)
);
create unique index if not exists account_deletion_requests_open_idx on account_deletion_requests (user_id) where status = 'open';
comment on table account_deletion_requests is 'Native apps (0390): a person asked to delete their account (from their profile, in the app or on the site). Opens an Admin task; Done on the task marks it done.';

create or replace function app.account_deletion_state(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'allowed', not exists (select 1 from user_roles r where r.user_id = p_user and r.role::text = 'admin'),
    'request', (select jsonb_build_object('status', d.status, 'requested_at', d.requested_at, 'closed_at', d.closed_at)
                  from account_deletion_requests d where d.user_id = p_user order by d.requested_at desc limit 1))
$$;

create or replace function app.request_account_deletion(p_user uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  u users;
  v_task uuid;
  v_req uuid;
  v_roles text;
begin
  select * into u from users where id = p_user;
  if u.id is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if exists (select 1 from user_roles r where r.user_id = p_user and r.role::text = 'admin') then
    raise exception 'An Admin account is closed by another Admin.' using errcode = '22023';
  end if;
  if exists (select 1 from account_deletion_requests where user_id = p_user and status = 'open') then
    return app.account_deletion_state(p_user);
  end if;
  select string_agg(x, ', ') into v_roles from (
    select 'renter' x where exists (select 1 from renters where user_id = p_user)
    union all select 'car owner' where exists (select 1 from owners where user_id = p_user)
    union all select 'investor' where exists (select 1 from investors where user_id = p_user)
    union all select 'staff' where exists (select 1 from user_roles where user_id = p_user and role::text in ('va', 'field'))) r;
  insert into account_deletion_requests (user_id, reason) values (p_user, left(nullif(btrim(coalesce(p_reason, '')), ''), 500)) returning id into v_req;
  insert into tasks (queue, task_type, title, detail, priority, due_at, renter_id, owner_id, related_table, related_id)
  values ('admin', 'account_deletion', 'Delete an account on request: ' || u.full_name,
          'Asked on ' || to_char(now() at time zone 'America/Toronto', 'Mon DD, YYYY') || ' (' || coalesce(v_roles, 'account only') || ').'
          || coalesce(' Reason: ' || left(nullif(btrim(coalesce(p_reason, '')), ''), 300) || '.', '')
          || ' Settle anything still open (a car on rent, a deposit, money owed either way, an owner car or an investment under contract), then delete'
          || ' the sign-in, profile, licence and selfie photos, alerts devices and marketing choices. Keep rental agreements, receipts,'
          || ' statements and tax records as the law requires. Reply to the person when done (within 30 days), then mark this Done.',
          'high', now() + interval '14 days',
          (select id from renters where user_id = p_user), (select id from owners where user_id = p_user limit 1),
          'account_deletion_requests', v_req)
  returning id into v_task;
  update account_deletion_requests set task_id = v_task where id = v_req;
  return app.account_deletion_state(p_user);
end $$;

create or replace function app.withdraw_account_deletion(p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_task uuid;
begin
  if p_user is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  update account_deletion_requests set status = 'withdrawn', closed_at = now()
   where user_id = p_user and status = 'open' returning task_id into v_task;
  if v_task is not null then
    update tasks set status = 'cancelled', updated_at = now() where id = v_task and status in ('open', 'in_progress', 'waiting');
  end if;
  return app.account_deletion_state(p_user);
end $$;

-- Done on the Admin's task marks the request done
create or replace function app.account_deletion_task_done() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.task_type = 'account_deletion' and new.status = 'done' and old.status is distinct from 'done' then
    update account_deletion_requests set status = 'done', closed_at = now() where task_id = new.id and status = 'open';
  end if;
  return new;
end $$;
drop trigger if exists account_deletion_task_done on tasks;
create trigger account_deletion_task_done after update of status on tasks for each row
  when (new.task_type = 'account_deletion') execute function app.account_deletion_task_done();

create or replace function public.server_account_deletion_state(p_user uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.account_deletion_state(p_user) $$;
create or replace function public.server_request_account_deletion(p_user uuid, p_reason text default null) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.request_account_deletion(p_user, p_reason) $$;
create or replace function public.server_withdraw_account_deletion(p_user uuid) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.withdraw_account_deletion(p_user) $$;

alter table account_deletion_requests enable row level security;
drop policy if exists admin_all on account_deletion_requests;
create policy admin_all on account_deletion_requests for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop trigger if exists audit_account_deletion_requests on account_deletion_requests;
create trigger audit_account_deletion_requests after insert or update or delete on account_deletion_requests for each row execute function app.audit_row();
revoke all on account_deletion_requests from anon, authenticated;
grant select on account_deletion_requests to authenticated;   -- admins only, by policy
grant all on account_deletion_requests to service_role;

-- ================================================================ privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['push_subscribe', 'push_state', 'server_push_waiting', 'server_push_due',
              'account_deletion_state', 'request_account_deletion', 'withdraw_account_deletion', 'account_deletion_task_done']))
        or (n.nspname = 'public' and p.proname = any (array['server_push_waiting', 'server_push_due',
              'server_account_deletion_state', 'server_request_account_deletion', 'server_withdraw_account_deletion']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
