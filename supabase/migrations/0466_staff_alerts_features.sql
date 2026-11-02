-- 0466: the staff alerts get handy (docs/changes/2026-11-07-lead-alerts.md).
--   1. Per-person quiet hours and focus mode (staff_alert_prefs). Quiet hours hold a non-urgent phone alert until they
--      end (default 21:00 to 8:00, which every normal-tier alert already followed); once a person saves their own hours
--      they apply to every non-urgent staff alert. Focus mode: only urgent alerts reach the phone until it ends; the rest
--      stay in the Alerts feed.
--   2. Per-device topics (push_subscriptions.topics): a device may keep its own choice; null follows the person's.
--   3. Buttons on the phone alert (push_outbox.actions): Call (the renter's or visitor's number: the phone's dialer, the
--      Quo app where it is installed), Send offer, Approve or Decline, Mark picked up, and Snooze 30 min on urgent ones.
--      Approve, Decline, Send offer and Mark picked up open the page where it is done (nothing is decided from the lock
--      screen). Snooze sends the alert again 30 minutes later and holds its escalation.
--   4. Escalation: an urgent alert a non-Admin did not open in alert_escalate_minutes goes to the next person on duty of
--      the rule's function; still unopened after the same time again (or nobody on duty), to the Admins.
--   5. Grouping: more than alert_burst_count (5) alerts of one non-urgent rule in alert_burst_minutes (10) push once as
--      "N alerts: <rule>"; each stays in the feed.
--   6. The 8:00 morning brief is each person's own (Sales: their leads and offers; customer service: requests and chats;
--      fleet: pickups and returns; field staff: their jobs). 21:00 evening wrap for the Admins as before.
--   7. Sign-in security: sign_in_events (kept 90 days). An Admin signing in from a new device or country, and a burst
--      of failed sign-ins (5 on one address or 20 in all within 10 minutes), are urgent alerts.
--   8. Deploy result: server_deploy_result, called by the deploy job (finished or failed).
--   9. The Alerts feed RPCs (server_alert_feed, _unread, _read, _snooze) and the settings (server_alert_prefs).
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
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0466: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. settings, rules, columns
alter table program_settings
  add column if not exists alert_burst_count integer not null default 5 check (alert_burst_count between 2 and 50),
  add column if not exists alert_burst_minutes integer not null default 10 check (alert_burst_minutes between 1 and 120);
comment on column program_settings.alert_burst_count is 'Staff alerts (0466): more than this many alerts of one non-urgent rule inside alert_burst_minutes push once as a group; each stays in the Alerts feed.';
comment on column program_settings.alert_burst_minutes is 'Staff alerts (0466): the grouping window in minutes (10).';

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('escalation_duty', 'Urgent alert passed to the next person on duty', 'Briefs', '{assigned}', 'urgent', 'alerts', true, false, 'After alert_escalate_minutes; the Admins get it after the same time again.', 144),
  ('alert_group', 'Several alerts of one kind (grouped)', 'Briefs', '{admin}', 'normal', 'alerts', true, false, 'Program settings alert_burst_count and alert_burst_minutes. The who is that of the grouped rule.', 145)
on conflict (rule) do nothing;
update staff_alert_rules set wired = true, hint = 'An Admin account signed in from a device or country not seen in 180 days.' where rule = 'admin_new_device';
update staff_alert_rules set wired = true, hint = '5 failed sign-ins on one address, or 20 in all, within 10 minutes.' where rule = 'failed_sign_ins';
update staff_alert_rules set wired = true, hint = 'Sent by the deploy job when it finishes or fails.' where rule = 'deploy_result';
update staff_alert_rules set hint = 'Each person''s own: Sales their leads and offers, customer service requests and chats, fleet pickups and returns, field staff their jobs.' where rule = 'morning_brief_staff';
update staff_alert_rules set hint = 'alert_escalate_minutes in Program settings: first to the next person on duty, then the Admins.' where rule = 'escalation';

alter table push_subscriptions add column if not exists topics text[];
comment on column push_subscriptions.topics is 'Phone alerts (0466): this device''s own topics; null follows the person''s choice (push_preferences).';
alter table push_outbox add column if not exists actions jsonb;
comment on column push_outbox.actions is 'Phone alerts (0466): the buttons on the alert, [{action, title, url}] (snooze is handled by the service worker).';
alter table notifications add column if not exists snoozed_until timestamptz;
comment on column notifications.snoozed_until is 'Staff alerts (0466): snoozed from the phone or the feed; the alert comes again then and escalation waits.';
create index if not exists app_events_staff_rule_idx on app_events ((payload ->> 'rule'), created_at) where code like 'staff_alert_%';

create table staff_alert_prefs (
  user_id     uuid primary key references users (id) on delete cascade,
  quiet_on    boolean not null default true,
  quiet_from  integer not null default 1260 check (quiet_from between 0 and 1439),
  quiet_until integer not null default 480 check (quiet_until between 0 and 1439),
  focus_until timestamptz,
  updated_at  timestamptz not null default now()
);
comment on table staff_alert_prefs is 'Staff alerts (0466): each person''s quiet hours (minutes of the day, Toronto) and focus mode (only urgent alerts reach the phone until focus_until). No row: 21:00 to 8:00 for the normal-tier alerts only.';
alter table staff_alert_prefs enable row level security;
create policy own_row on staff_alert_prefs for select to authenticated using (user_id = app.uid());
revoke all on staff_alert_prefs from anon, authenticated;
grant select on staff_alert_prefs to authenticated;
grant all on staff_alert_prefs to service_role;

create table sign_in_events (
  id      bigint generated always as identity primary key,
  user_id uuid references users (id) on delete cascade,
  email   text,
  ok      boolean not null,
  device  text check (device is null or length(device) <= 80),
  country text check (country is null or country ~ '^[A-Z]{2}$'),
  at      timestamptz not null default now()
);
create index sign_in_events_user_idx on sign_in_events (user_id, at desc);
create index sign_in_events_fail_idx on sign_in_events (at desc) where not ok;
comment on table sign_in_events is 'Sign-in security (0466): each password sign-in, ok or failed: the browser and system (no address, no IP) and the country the request came from. Kept 90 days. Only the server reads it.';
alter table sign_in_events enable row level security;
revoke all on sign_in_events from anon, authenticated;
grant all on sign_in_events to service_role;

-- ================================================================ 2. the emitter: grouping of bursts
create or replace function app.staff_alert(p_rule text, p_entity text, p_id uuid, p_disc text, p_title text, p_body text, p_extra jsonb default '{}'::jsonb)
returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  r staff_alert_rules;
  s program_settings := app.settings();
  v_n integer := 0;
  v_quiet boolean := false;
  v_extra jsonb := coalesce(p_extra, '{}'::jsonb);
begin
  select * into r from staff_alert_rules where rule = p_rule;
  if r.rule is null or not r.enabled then return null; end if;
  if r.tier <> 'urgent' and p_rule <> 'alert_group' then
    select count(*) into v_n from app_events e
     where e.code like 'staff_alert_%' and e.payload ->> 'rule' = p_rule and e.created_at > now() - make_interval(mins => s.alert_burst_minutes);
    if v_n >= s.alert_burst_count then
      v_quiet := true;
      if r.tier = 'normal' then
        perform app.ntf_emit('staff_alert_normal', 'alert_group', null, 'alert_group:' || p_rule || ':' || floor(extract(epoch from now()) / (s.alert_burst_minutes * 60))::bigint,
          jsonb_build_object('rule', p_rule, 'group_rule', 'alert_group', 'topic', r.topic, 'alert_title', format('%s or more alerts: %s', v_n + 1, r.label),
                             'alert_body', format('In the last %s minutes. Open Alerts to see each one.', s.alert_burst_minutes),
                             'path_admin', '/admin/alerts', 'path_staff', '/staff/alerts', 'assigned_to', v_extra ->> 'assigned_to'));
      end if;
    end if;
  end if;
  return app.ntf_emit('staff_alert_' || r.tier, p_entity, p_id, p_rule || ':' || coalesce(p_disc, 'x'),
    jsonb_build_object('rule', p_rule, 'topic', r.topic, 'alert_title', left(p_title, 140), 'alert_body', left(coalesce(p_body, ''), 240))
    || v_extra || case when v_quiet then jsonb_build_object('_nopush', true) else '{}'::jsonb end);
end $$;

-- ================================================================ 3. the buttons on a phone alert
create or replace function app.alert_actions(p_code text, p jsonb, p_url text, p_urgent boolean) returns jsonb
language plpgsql immutable as $$
declare
  a jsonb := '[]'::jsonb;
  v_rule text := coalesce(p ->> 'rule', p_code);
  v_url text := coalesce(nullif(p_url, ''), '/');
  v_base text := split_part(coalesce(nullif(p_url, ''), '/'), '?', 1);
  v_call text := nullif(p ->> 'call', '');
begin
  if v_call is not null and v_call ~ '^\+?[0-9]{7,15}$' then
    a := a || jsonb_build_object('action', 'call', 'title', 'Call', 'url', '/alerts/call?to=' || replace(v_call, '+', '%2B'));
  end if;
  if v_rule in ('staff_booking_request_new', 'staff_request_waiting', 'offer_expiring') then
    a := a || jsonb_build_object('action', 'offer', 'title', 'Send offer', 'url', v_base || '?tab=review');
  elsif coalesce(p ->> 'decide', '') = 'true' or v_rule in ('staff_extension_requested', 'staff_change_request_received') then
    a := a || jsonb_build_object('action', 'approve', 'title', 'Approve', 'url', v_base || '?tab=changes&do=approve')
           || jsonb_build_object('action', 'decline', 'title', 'Decline', 'url', v_base || '?tab=changes&do=decline');
  elsif v_rule in ('staff_pickup_unrecorded_admin', 'booking_no_show') or (v_rule = 'job_late' and coalesce(p ->> 'job_kind', '') in ('delivery', 'handover')) then
    a := a || jsonb_build_object('action', 'picked_up', 'title', 'Mark picked up', 'url', v_base || '?tab=overview#record');
  end if;
  if p_urgent then a := a || jsonb_build_object('action', 'snooze', 'title', 'Snooze 30 min'); end if;
  -- browsers show two buttons at most: the first two; a tap on the alert itself always opens it
  if jsonb_array_length(a) = 0 then return null; end if;
  return (select jsonb_agg(x) from (select x from jsonb_array_elements(a) with ordinality t(x, i) order by i limit 2) s);
end $$;

-- ================================================================ 4. the push: device topics, focus, quiet hours, buttons, grouping
create or replace function app.alert_quiet_end(p_user uuid, p_at timestamptz) returns timestamptz
language plpgsql stable security definer set search_path = public, app as $$
declare
  pr staff_alert_prefs;
  v_local timestamp := p_at at time zone 'America/Toronto';
  v_min integer := extract(hour from v_local)::integer * 60 + extract(minute from v_local)::integer;
  v_inside boolean;
begin
  select * into pr from staff_alert_prefs where user_id = p_user;
  if pr.user_id is null then return app.sms_quiet_end(p_at); end if;
  if not pr.quiet_on or pr.quiet_from = pr.quiet_until then return p_at; end if;
  v_inside := case when pr.quiet_from < pr.quiet_until then v_min >= pr.quiet_from and v_min < pr.quiet_until
                   else v_min >= pr.quiet_from or v_min < pr.quiet_until end;
  if not v_inside then return p_at; end if;
  return ((date_trunc('day', v_local) + case when v_min >= pr.quiet_until then interval '1 day' else interval '0' end)
          + make_interval(mins => pr.quiet_until)) at time zone 'America/Toronto';
end $$;

create or replace function app.push_from_notice()
returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_topic text;
  v_after timestamptz;
  v_urgent boolean;
  v_role text;
  v_payload jsonb := '{}'::jsonb;
  v_staff boolean;
  pr staff_alert_prefs;
  v_person text[];
begin
  if not coalesce(s.push_enabled, true) then return new; end if;
  if not exists (select 1 from push_subscriptions where user_id = new.user_id) then return new; end if;
  select c.push_topic into v_topic from notification_catalogue c where c.code = new.code;
  select coalesce(e.payload, '{}'::jsonb) into v_payload from app_events e where e.id = new.event_id;
  v_payload := coalesce(v_payload, '{}'::jsonb);
  if new.code in ('staff_alert_urgent', 'staff_alert_normal') then v_topic := v_payload ->> 'topic'; end if;
  if v_topic is null then return new; end if;
  -- one of a burst: in the feed, and the group alert goes to the phone instead
  if coalesce(v_payload ->> '_nopush', '') = 'true' then return new; end if;
  v_person := app.push_topics(new.user_id);
  if not (v_topic = any (v_person) or exists (select 1 from push_subscriptions x where x.user_id = new.user_id and v_topic = any (x.topics))) then return new; end if;
  -- an alert is extra: nothing here may stop the in-app notice, its email or its text
  begin
    v_urgent := v_topic in ('alerts', 'leads') or new.code = 'staff_alert_urgent';
    v_after := greatest(coalesce((v_payload ->> '_send_after')::timestamptz, now()), now());
    v_role := app.push_role(new.user_id);
    v_staff := v_role in ('admin', 'staff', 'field');
    if v_staff then select * into pr from staff_alert_prefs where user_id = new.user_id; end if;
    -- focus mode: only urgent alerts reach the phone; the rest stay in the Alerts feed
    if v_staff and not v_urgent and pr.focus_until is not null and pr.focus_until > now() then return new; end if;
    if not v_urgent then
      if v_role in ('renter', 'owner', 'investor') then v_after := app.sms_quiet_end(v_after);
      elsif v_staff and (pr.user_id is not null or new.code = 'staff_alert_normal') then v_after := app.alert_quiet_end(new.user_id, v_after);
      end if;
    end if;
    insert into push_outbox (subscription_id, user_id, notification_id, code, title, body, url, urgent, send_after, actions)
    select ps.id, new.user_id, new.id, new.code, left(new.title, 120), left(nullif(btrim(coalesce(new.body, '')), ''), 240),
           app.push_path(new.url), v_urgent, v_after, case when v_staff then app.alert_actions(new.code, v_payload, app.push_path(new.url), v_urgent) end
      from push_subscriptions ps where ps.user_id = new.user_id and v_topic = any (coalesce(ps.topics, v_person))
    on conflict (subscription_id, notification_id) do nothing;
  exception when others then
    raise warning 'push alert not queued for notice %: %', new.id, sqlerrm;
  end;
  return new;
end $$;

-- the buttons and the notice id travel with the push (the service worker snoozes by the notice id)
select pg_temp.patch_fn('app.server_push_due(integer, text[])'::regprocedure,
  '''tag'', coalesce(c.notification_id::text, c.id::text), ''code'', c.code)',
  '''tag'', coalesce(c.notification_id::text, c.id::text), ''code'', c.code, ''nid'', c.notification_id, ''actions'', c.actions)');
-- a snoozed alert waits (it is queued again for the end of the snooze)
select pg_temp.patch_fn('app.server_push_due(integer, text[])'::regprocedure,
  'from notifications n where n.id = o.notification_id and o.status = ''queued'' and n.read_at is not null;',
  'from notifications n where n.id = o.notification_id and o.status = ''queued'' and n.read_at is not null;
  update push_outbox o set send_after = n.snoozed_until
    from notifications n where n.id = o.notification_id and o.status = ''queued'' and n.snoozed_until > now() and o.send_after < n.snoozed_until;');

-- ================================================================ 5. the feed, the snooze and the settings
create or replace function app.alert_tier(p_code text) returns text
language sql stable security definer set search_path = public, app as $$
  select case when p_code like 'staff_alert_%' then substr(p_code, 13)
              when (select c.push_topic from notification_catalogue c where c.code = p_code) in ('alerts', 'leads') then 'urgent'
              when (select c.is_digest from notification_catalogue c where c.code = p_code) then 'digest'
              else 'normal' end
$$;

create or replace function app.server_alert_feed(p_user uuid, p_limit integer default 60, p_filter text default 'all') returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_user is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by (x ->> 'created_at') desc) from (
    select jsonb_build_object('id', n.id, 'code', n.code, 'tier', app.alert_tier(n.code), 'title', n.title, 'body', n.body, 'url', app.push_path(n.url),
             'created_at', n.created_at, 'read_at', n.read_at, 'snoozed_until', n.snoozed_until,
             'group', coalesce((select r.grp from app_events e join staff_alert_rules r on r.rule = e.payload ->> 'rule' where e.id = n.event_id), 'Other')) x
      from notifications n join notification_catalogue c on c.code = n.code
     where n.user_id = p_user and c.audience like 'staff%'
       and (p_filter = 'all' or (p_filter = 'unread' and n.read_at is null) or (p_filter = 'urgent' and app.alert_tier(n.code) = 'urgent'))
     order by n.created_at desc limit greatest(1, least(coalesce(p_limit, 60), 200))) t), '[]'::jsonb);
end $$;

create or replace function app.server_alert_unread(p_user uuid) returns integer
language sql stable security definer set search_path = public, app as $$
  select count(*)::integer from notifications n join notification_catalogue c on c.code = n.code
   where n.user_id = p_user and n.read_at is null and c.audience like 'staff%' and n.created_at > now() - interval '30 days'
$$;

create or replace function app.server_alert_read(p_user uuid, p_ids uuid[] default null) returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  if p_user is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  update notifications x set read_at = now()
    from notification_catalogue c
   where c.code = x.code and c.audience like 'staff%' and x.user_id = p_user and x.read_at is null and (p_ids is null or x.id = any (p_ids));
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function app.server_alert_snooze(p_user uuid, p_id uuid, p_minutes integer default 30) returns timestamptz
language plpgsql security definer set search_path = public, app as $$
declare
  v timestamptz := now() + make_interval(mins => greatest(5, least(coalesce(p_minutes, 30), 240)));
begin
  if p_user is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  update notifications set snoozed_until = v where id = p_id and user_id = p_user and read_at is null;
  if not found then return null; end if;
  -- the phone alert comes again at the end of the snooze
  update push_outbox set status = 'queued', send_after = v, locked_at = null, sent_at = null, attempts = 0, last_error = null
   where notification_id = p_id and user_id = p_user;
  return v;
end $$;

create or replace function app.server_alert_prefs(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('custom', p.user_id is not null, 'quiet_on', coalesce(p.quiet_on, true), 'quiet_from', coalesce(p.quiet_from, 1260),
           'quiet_until', coalesce(p.quiet_until, 480), 'focus_until', case when p.focus_until > now() then p.focus_until end)
    from (select 1) one left join staff_alert_prefs p on p.user_id = p_user
$$;

create or replace function app.server_set_alert_prefs(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_focus timestamptz;
begin
  if p_user is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if app.push_role(p_user) not in ('admin', 'staff', 'field') then raise exception 'Only staff have alert settings.' using errcode = '42501'; end if;
  if p ? 'focus_minutes' then
    v_focus := case when coalesce((p ->> 'focus_minutes')::integer, 0) > 0 then now() + make_interval(mins => least((p ->> 'focus_minutes')::integer, 24 * 60)) end;
  end if;
  insert into staff_alert_prefs as x (user_id, quiet_on, quiet_from, quiet_until, focus_until)
  values (p_user, coalesce((p ->> 'quiet_on')::boolean, true), coalesce((p ->> 'quiet_from')::integer, 1260), coalesce((p ->> 'quiet_until')::integer, 480), v_focus)
  on conflict (user_id) do update set
    quiet_on = coalesce((p ->> 'quiet_on')::boolean, x.quiet_on),
    quiet_from = coalesce((p ->> 'quiet_from')::integer, x.quiet_from),
    quiet_until = coalesce((p ->> 'quiet_until')::integer, x.quiet_until),
    focus_until = case when p ? 'focus_minutes' then v_focus else x.focus_until end,
    updated_at = now();
  return app.server_alert_prefs(p_user);
end $$;

-- a device's own topics (null: follow the person's)
create or replace function app.server_push_device_topics(p_user uuid, p_endpoint text, p_topics text[]) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_user is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if p_topics is not null and exists (select 1 from unnest(p_topics) t where t not in ('requests', 'bookings', 'payments', 'handovers', 'messages', 'alerts', 'documents', 'leads', 'visitors')) then
    raise exception 'Unknown topic.' using errcode = '22023';
  end if;
  update push_subscriptions set topics = case when p_topics is null then null else array(select distinct t from unnest(p_topics) t order by 1) end
   where user_id = p_user and endpoint = p_endpoint;
  if not found then raise exception 'Turn alerts on for this device first.' using errcode = '22023'; end if;
  return app.push_state(p_user, p_endpoint);
end $$;

alter function app.push_state(uuid, text) rename to push_state_pre0466;
create function app.push_state(p_user uuid, p_endpoint text default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.push_state_pre0466(p_user, p_endpoint);
begin
  return v || jsonb_build_object(
    'device_topics', (select to_jsonb(ps.topics) from push_subscriptions ps where ps.user_id = p_user and ps.endpoint = p_endpoint),
    'devices', coalesce((select jsonb_agg(d || jsonb_build_object('topics', (select to_jsonb(ps.topics) from push_subscriptions ps where ps.id = (d ->> 'id')::uuid)))
                           from jsonb_array_elements(v -> 'devices') d), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.push_state(uuid, text)'::regprocedure, 'app.push_state_pre0466(uuid, text)'::regprocedure);
revoke all on function app.push_state_pre0466(uuid, text) from public, anon, authenticated;
grant execute on function app.push_state_pre0466(uuid, text) to service_role;

-- ================================================================ 6. sign-in security and the deploy result
create or replace function app.server_sign_in_event(p jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
  v_email text := lower(nullif(btrim(p ->> 'email'), ''));
  v_ok boolean := coalesce((p ->> 'ok')::boolean, false);
  v_device text := left(nullif(btrim(p ->> 'device'), ''), 80);
  v_country text := case when upper(coalesce(p ->> 'country', '')) ~ '^[A-Z]{2}$' and upper(p ->> 'country') <> 'XX' then upper(p ->> 'country') end;
  v_n integer;
  v_win bigint := floor(extract(epoch from now()) / 600)::bigint;
  v_name text;
begin
  begin
    if v_email is not null and app.email_is_test(v_email) then return; end if;
    if v_user is not null and app.staff_is_test(v_user) then return; end if;
    if v_ok and v_user is not null and app.user_is_admin(v_user)
       and exists (select 1 from sign_in_events e where e.user_id = v_user and e.ok)
       and not exists (select 1 from sign_in_events e where e.user_id = v_user and e.ok and e.at > now() - interval '180 days'
                          and e.device is not distinct from v_device and (v_country is null or e.country is null or e.country = v_country)) then
      select u.full_name into v_name from users u where u.id = v_user;
      perform app.staff_alert('admin_new_device', 'user', v_user, md5(coalesce(v_device, '') || coalesce(v_country, '')),
        'Admin sign-in from a new ' || case when v_country is not null and not exists (select 1 from sign_in_events e where e.user_id = v_user and e.ok and e.country = v_country) then 'country' else 'device' end,
        coalesce(v_name, 'An Admin') || ': ' || coalesce(v_device, 'unknown device') || coalesce(', ' || v_country, '') || '. If this was not them, change the password now.',
        jsonb_build_object('path_admin', '/admin/settings/profile'));
    end if;
    insert into sign_in_events (user_id, email, ok, device, country) values (v_user, v_email, v_ok, v_device, v_country);
    if not v_ok then
      select count(*) into v_n from sign_in_events e where not e.ok and e.email = v_email and e.at > now() - interval '10 minutes';
      if v_email is not null and v_n >= 5 then
        perform app.staff_alert('failed_sign_ins', 'sign_in', null, md5(v_email) || ':' || v_win, format('%s failed sign-ins on one account', v_n),
          'In the last 10 minutes, on ' || v_email || '. Someone may be guessing the password.', jsonb_build_object('path_admin', '/admin/audit'));
      end if;
      select count(*) into v_n from sign_in_events e where not e.ok and e.at > now() - interval '10 minutes';
      if v_n >= 20 then
        perform app.staff_alert('failed_sign_ins', 'sign_in', null, 'all:' || v_win, format('%s failed sign-ins in 10 minutes', v_n),
          'Across all accounts. The sign-in protection is on; watch for more.', jsonb_build_object('path_admin', '/admin/audit'));
      end if;
    end if;
  exception when others then
    raise warning 'sign-in event not kept: %', sqlerrm;
  end;
end $$;

create or replace function app.server_deploy_result(p jsonb) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_ok boolean := coalesce(p ->> 'status', '') = 'success';
  v_sha text := left(regexp_replace(coalesce(p ->> 'sha', ''), '[^0-9a-f]', '', 'g'), 8);
begin
  return app.staff_alert('deploy_result', 'deploy', null, coalesce(nullif(v_sha, ''), 'x') || ':' || coalesce(p ->> 'status', 'x'),
    case when v_ok then 'Deploy finished' else 'Deploy failed' end || coalesce(' (' || nullif(left(p ->> 'environment', 20), '') || ')', ''),
    case when v_ok then 'The new version is live' else 'The site keeps the version it had. The deploy run says why' end || coalesce(', commit ' || nullif(v_sha, ''), '') || '.',
    jsonb_build_object('path_admin', '/admin/settings/usage'));
end $$;

-- ================================================================ 7. the job (every 5 minutes): escalation, briefs per person, the checks of 0465
create or replace function app.job_staff_alerts(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  r record;
  v_hour integer := app.local_hour(p_now);
  v_day text := app.local_date(p_now)::text;
  v_today date := app.local_date(p_now);
  n_late integer := 0; n_offer integer := 0; n_esc integer := 0; n_brief integer := 0; n_more integer := 0;
  v_p integer; v_r integer; v_o integer; v_q integer; v_money bigint; v_cnt integer; v_made integer; v_urgent integer;
  v_next uuid; v_fns text[]; v_a integer; v_b integer; v_first timestamptz;
  bk bookings;
begin
  -- field jobs 15 minutes past their time and not started
  for r in select j.* from field_jobs j where j.status in ('scheduled', 'acknowledged') and j.scheduled_at < p_now - interval '15 minutes' and j.scheduled_at > p_now - interval '1 day' loop
    if app.staff_alert('job_late', 'field_job', r.id, 'late', 'Job running late: ' || replace(r.kind, '_', ' ') || coalesce(', ' || app.vehicle_name(r.vehicle_id), ''),
         'Was due ' || app.fmt_at(r.scheduled_at) || ' and has not started.', jsonb_build_object('assigned_to', r.assigned_to, 'job_kind', r.kind, 'path_admin', '/admin/staff', 'path_staff', '/staff/field')) is not null then n_late := n_late + 1; end if;
  end loop;
  -- offers that expire within the hour and are unanswered
  for bk in select b.* from bookings b where b.status = 'offered' and b.offer_expires_at > p_now and b.offer_expires_at <= p_now + interval '1 hour' and not coalesce(b.is_placeholder, false) loop
    if app.sa_booking_ok(bk) and app.staff_alert('offer_expiring', 'booking', bk.id, to_char(bk.offer_expires_at, 'YYYYMMDDHH24MI'), 'Offer expires within the hour: ' || app.sa_booking_line(bk),
         'Expires ' || app.fmt_at(bk.offer_expires_at), app.sa_booking_paths(bk) || jsonb_build_object('call', app.sa_phone(bk))) is not null then n_offer := n_offer + 1; end if;
  end loop;
  -- an urgent alert nobody opened: the next person on duty, then the Admins (a snooze holds it)
  if s.alert_escalate_enabled then
    for r in select n.id, n.title, n.body, n.code, n.user_id, u.full_name, coalesce(n.snoozed_until, n.created_at) since, e.payload
               from notifications n join users u on u.id = n.user_id left join app_events e on e.id = n.event_id
              where n.code in ('staff_alert_urgent', 'staff_lead_new', 'staff_owner_lead_new', 'staff_request_unfinished', 'staff_hot_visitor') and n.read_at is null
                and coalesce(e.payload ->> 'rule', '') not in ('escalation', 'escalation_duty')
                and coalesce(n.snoozed_until, n.created_at) < p_now - make_interval(mins => s.alert_escalate_minutes) and n.created_at > p_now - interval '1 day'
                and not app.user_is_admin(n.user_id) and not app.staff_is_test(n.user_id) loop
      if not exists (select 1 from app_events x where x.dedupe_key in ('staff_alert_urgent:' || r.id || ':escalation_duty:esc1', 'staff_alert_urgent:' || r.id || ':escalation:esc')) then
        select array_agg(split_part(w, ':', 2)) into v_fns from staff_alert_rules x, unnest(x.who) w
         where x.rule = coalesce(r.payload ->> 'rule', r.code) and w like '%on_duty:%';
        select u.id into v_next from users u join staff_profiles sp on sp.user_id = u.id and sp.is_active and sp.staff_type = 'va'
          join chat_staff_prefs cp on cp.user_id = u.id and cp.last_seen_at > p_now - make_interval(mins => s.chat_shift_minutes)
         where u.status = 'active' and u.id <> r.user_id and not app.staff_is_test(u.id) and not app.user_is_admin(u.id)
           and (sp.va_function::text = any (coalesce(v_fns, '{}')) or exists (select 1 from unnest(sp.cover_functions) c where c::text = any (coalesce(v_fns, '{}'))))
         order by cp.last_seen_at desc limit 1;
        if v_next is not null then
          if app.staff_alert('escalation_duty', 'notification', r.id, 'esc1', 'Passed to you: ' || r.title,
               format('%s did not open it in %s minutes. %s', r.full_name, s.alert_escalate_minutes, coalesce(r.body, '')),
               jsonb_build_object('assigned_to', v_next, 'path_admin', r.payload ->> 'path_admin', 'path_staff', r.payload ->> 'path_staff', 'call', r.payload ->> 'call')) is not null then n_esc := n_esc + 1; end if;
          continue;
        end if;
      elsif not exists (select 1 from app_events x where x.dedupe_key = 'staff_alert_urgent:' || r.id || ':escalation:esc')
            and r.since < p_now - make_interval(mins => 2 * s.alert_escalate_minutes) then
        null;  -- passed on once and still not opened: the Admins below
      else
        continue;
      end if;
      if app.staff_alert('escalation', 'notification', r.id, 'esc', 'Not opened: ' || r.title,
           format('Sent to %s and not opened. %s', r.full_name, coalesce(r.body, '')),
           jsonb_build_object('path_admin', r.payload ->> 'path_admin', 'call', r.payload ->> 'call')) is not null then n_esc := n_esc + 1; end if;
    end loop;
  end if;
  -- the morning brief (each person's own) and the evening wrap
  if s.alert_brief_enabled and v_hour in (8, 21) then
    select count(*) filter (where b.status = 'confirmed' and app.local_date(b.pickup_at) = v_today),
           count(*) filter (where b.status = 'on_rent' and app.local_date(b.return_at) = v_today),
           count(*) filter (where b.status = 'on_rent' and b.return_at < p_now),
           count(*) filter (where b.status = 'requested'),
           count(*) filter (where app.local_date(b.created_at) = v_today)
      into v_p, v_r, v_o, v_q, v_made from bookings b where not coalesce(b.is_placeholder, false) and b.booking_type <> 'owner' and not coalesce(app.booking_is_test(b.id), false);
    if v_hour = 8 then
      if app.staff_alert('morning_brief_admin', 'brief', null, v_day, 'Good morning: ' || v_p || ' pickups, ' || v_r || ' returns today',
           format('%s cars overdue. %s open requests.', v_o, v_q), jsonb_build_object('path_admin', '/admin/bookings')) is not null then n_brief := n_brief + 1; end if;
      for r in select sp.user_id, sp.staff_type, sp.va_function::text fn from staff_profiles sp join users u on u.id = sp.user_id and u.status = 'active'
                where sp.is_active and (sp.staff_type = 'field' or sp.va_function::text in ('cs', 'sales', 'fleet')) and not app.staff_is_test(sp.user_id)
                  and not app.user_is_admin(sp.user_id) loop
        if r.staff_type = 'field' then
          select count(*), min(j.scheduled_at) into v_a, v_first from field_jobs j where j.assigned_to = r.user_id and j.status in ('scheduled', 'acknowledged') and app.local_date(j.scheduled_at) = v_today;
          if v_a = 0 then continue; end if;
          if app.staff_alert('morning_brief_staff', 'brief', r.user_id, v_day, format('Good morning: %s %s today', v_a, case when v_a = 1 then 'job' else 'jobs' end),
               'The first at ' || app.fmt_at(v_first) || '.', jsonb_build_object('assigned_to', r.user_id, 'path_staff', '/staff/field')) is not null then n_brief := n_brief + 1; end if;
        elsif r.fn = 'sales' then
          select count(*) into v_a from leads l where l.assigned_to = r.user_id and l.status in ('new', 'contacted', 'qualified');
          select count(*) into v_b from bookings b join booking_offers o on o.booking_id = b.id and o.status = 'sent' where b.status = 'offered' and o.sent_by = r.user_id;
          if app.staff_alert('morning_brief_staff', 'brief', r.user_id, v_day, format('Good morning: %s open leads are yours', v_a),
               format('%s of your offers wait for an answer. %s new requests.', v_b, v_q), jsonb_build_object('assigned_to', r.user_id, 'path_staff', '/staff/leads')) is not null then n_brief := n_brief + 1; end if;
        elsif r.fn = 'cs' then
          select count(*) into v_a from chat_conversations c where c.status = 'waiting' and c.closed_at is null;
          select count(*) into v_b from tasks t where t.assigned_to = r.user_id and t.status in ('open', 'in_progress');
          if app.staff_alert('morning_brief_staff', 'brief', r.user_id, v_day, format('Good morning: %s open requests', v_q),
               format('%s chats waiting for a person. %s tasks are yours.', v_a, v_b), jsonb_build_object('assigned_to', r.user_id, 'path_staff', '/staff')) is not null then n_brief := n_brief + 1; end if;
        else
          if app.staff_alert('morning_brief_staff', 'brief', r.user_id, v_day, format('Good morning: %s pickups, %s returns today', v_p, v_r),
               format('%s cars overdue.', v_o), jsonb_build_object('assigned_to', r.user_id, 'path_staff', '/staff/fleet')) is not null then n_brief := n_brief + 1; end if;
        end if;
      end loop;
    else
      select coalesce(sum(p.amount_cents), 0), count(*) into v_money, v_cnt from payments p
       where p.status = 'succeeded' and p.kind in ('charge', 'capture') and app.local_date(p.created_at) = v_today;
      select count(*) into v_urgent from tasks t where t.status in ('open', 'in_progress') and t.priority = 'urgent';
      if app.staff_alert('evening_wrap', 'brief', null, v_day, 'Evening wrap: ' || app.fmt_money(v_money) || ' in, ' || v_made || ' bookings made',
           format('%s overdue cars. %s urgent tasks open.', v_o, v_urgent), jsonb_build_object('path_admin', '/admin/overview')) is not null then n_brief := n_brief + 1; end if;
      perform app.staff_alert('cash_summary', 'brief', null, v_day, 'Cash today: ' || app.fmt_money(v_money), v_cnt || ' payments received', jsonb_build_object('path_admin', '/admin/payments'));
    end if;
  end if;
  -- the checks of 0465 (documents before pickup, insurer claims, Sales hours, wins)
  n_more := app.sa_scheduled(p_now);
  delete from sign_in_events where at < p_now - interval '90 days';
  return format('late jobs %s, offers %s, escalated %s, briefs %s, checks %s', n_late, n_offer, n_esc, n_brief, n_more);
end $$;

-- ================================================================ 8. public wrappers (the server calls them as service_role) and privileges
create or replace function public.server_alert_feed(p_user uuid, p_limit integer default 60, p_filter text default 'all') returns jsonb
language sql set search_path = public, app as $$ select app.server_alert_feed(p_user, p_limit, p_filter) $$;
create or replace function public.server_alert_unread(p_user uuid) returns integer
language sql set search_path = public, app as $$ select app.server_alert_unread(p_user) $$;
create or replace function public.server_alert_read(p_user uuid, p_ids uuid[] default null) returns integer
language sql set search_path = public, app as $$ select app.server_alert_read(p_user, p_ids) $$;
create or replace function public.server_alert_snooze(p_user uuid, p_id uuid, p_minutes integer default 30) returns timestamptz
language sql set search_path = public, app as $$ select app.server_alert_snooze(p_user, p_id, p_minutes) $$;
create or replace function public.server_alert_prefs(p_user uuid) returns jsonb
language sql set search_path = public, app as $$ select app.server_alert_prefs(p_user) $$;
create or replace function public.server_set_alert_prefs(p_user uuid, p jsonb) returns jsonb
language sql set search_path = public, app as $$ select app.server_set_alert_prefs(p_user, p) $$;
create or replace function public.server_push_device_topics(p_user uuid, p_endpoint text, p_topics text[]) returns jsonb
language sql set search_path = public, app as $$ select app.server_push_device_topics(p_user, p_endpoint, p_topics) $$;
create or replace function public.server_sign_in_event(p jsonb) returns void
language sql set search_path = public, app as $$ select app.server_sign_in_event(p) $$;
create or replace function public.server_deploy_result(p jsonb) returns bigint
language sql set search_path = public, app as $$ select app.server_deploy_result(p) $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['staff_alert', 'alert_actions', 'alert_quiet_end', 'alert_tier', 'server_alert_feed', 'server_alert_unread',
              'server_alert_read', 'server_alert_snooze', 'server_alert_prefs', 'server_set_alert_prefs', 'server_push_device_topics', 'server_sign_in_event',
              'server_deploy_result', 'job_staff_alerts']))
        or (n.nspname = 'public' and p.proname = any (array['server_alert_feed', 'server_alert_unread', 'server_alert_read', 'server_alert_snooze', 'server_alert_prefs',
              'server_set_alert_prefs', 'server_push_device_topics', 'server_sign_in_event', 'server_deploy_result']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
