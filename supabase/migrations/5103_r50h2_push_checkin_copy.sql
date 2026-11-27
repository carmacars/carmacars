-- 5103 (R50 hotfix 2). SCHEMA_MARKER is not changed.
-- 1. The owner's phone alerts kept turning themselves off. Two causes in the database:
--    a. Signing out of the app removed the phone as "turned off" (app.push_unsubscribe), and a device the person turned
--       off is never switched back on by itself (app.push_subscribe, 3113). A sign-out (the app sends signout: true) is
--       now recorded as "signed_out": the app turns alerts back on after the next sign-in.
--    b. At most 10 devices a person, the oldest removed first: every new browser an Admin signs in to (a second profile,
--       a laptop, an assistant's browser) pushed the first device out, which for the owner was his phone. Phones (the app,
--       or a phone's browser) now stay; the oldest browser goes first.
-- 2. The check-in visit emails read like the pickup check-in. They are the free mid-rental car check of a long rental:
--    the renter keeps the car. New subject and preheader (emails/src/emails/renter_checkin_*.mjs), and the text.

create or replace function app.push_unsubscribe(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  perform set_config('app.push_lost_reason', case when coalesce((p ->> 'signout')::boolean, false) then 'signed_out' else 'turned_off' end, true);
  return app.push_unsubscribe_pre3113(p_user, p - 'signout');
end $$;

create or replace function app.push_subscribe_pre3113(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
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
    if v_token !~ '^[A-Za-z0-9_:.-]+$' or length(v_token) not between 20 and 1000 then raise exception 'This phone gave a push address we cannot use.' using errcode = '22023'; end if;
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
  -- at most 10 devices a person: phones stay first, then the newest; the oldest browser goes (5103)
  delete from push_subscriptions where id in (
    select id from push_subscriptions where user_id = p_user
     order by (kind = 'fcm' or coalesce(device, '') ~* '(iphone|ipad|android|phone|mobile)') desc, created_at desc offset 10);
  return app.push_state(p_user, v_endpoint);
end $$;

revoke all on function app.push_unsubscribe(uuid, jsonb), app.push_subscribe_pre3113(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.push_unsubscribe(uuid, jsonb), app.push_subscribe_pre3113(uuid, jsonb) to service_role;

update notification_catalogue set
  subject = 'Your free mid-rental car check: pick a time',
  preheader = 'You keep the {{vehicle_name}}: a free 15-minute look at it while you have it. Nothing to pay.'
 where code = 'renter_checkin_followup';
update notification_catalogue set
  subject = 'Your free mid-rental car check: around {{checkin_due_date}}',
  preheader = 'You keep the {{vehicle_name}}: a free 15-minute look at it to keep it in top shape. Pick a time that suits you.'
 where code = 'renter_checkin_reminder';
update sms_templates set label = 'Mid-rental car check follow-up',
  body = 'CarmaCars: still time for the free mid-rental check of your {{vehicle_name}} (you keep the car), whenever suits you: {{link}}'
 where code = 'renter_checkin_followup';
update sms_templates set body = 'CarmaCars: the {{vehicle_name}} you are renting is due for its free mid-rental check around {{checkin_due_date}} (you keep the car). Pick a time: {{link}}'
 where code = 'renter_checkin_reminder';
