-- 0460: staff alerts, in the app and on the phone, for leads, unfinished requests, owner leads and hot visitors
-- (docs/changes/2026-11-07-lead-alerts.md). The owner: "I'll get alerted for literally everything right? And each staff
-- member gets alerted for every single thing relevant to them. For example active visitor, signals, requests, leads,
-- games, unfinished forms or partial leads."
--
-- Why: the phone alerts of 0300 cover requests, payments, handovers, messages and urgent notices, but nothing told staff
-- about a new renter lead (contact form, phone number box, discount game claim, live chat), a request typed and not
-- sent, a new owner lead (also the unfinished application and its 30-minute chase) or a visitor turning Hot.
--
-- 1. Four notices, in the app and on the phone only (has_email = false, so the daily email limit is untouched; no text):
--      staff_lead_new            a renter lead from any source, naming the source              (topic leads)
--      staff_request_unfinished  contact typed into the booking request or contact form, not sent, after capture_continue_minutes (leads)
--      staff_owner_lead_new      an owner lead when it is made, and again when the unfinished application becomes the chase (leads)
--      staff_hot_visitor         a visitor turns Hot, once per visitor per day, analytics consent only (topic visitors)
-- 2. Who: the Admins always (every device that turned alerts on); plus, for a renter lead or unfinished request, the person
--    the lead is assigned to, else customer service and Sales on duty (Live chat, Live visitors or Texts open within
--    chat_shift_minutes); for an owner lead the Sales person it is assigned to (Sales see only their own, 0342); for a hot
--    visitor customer service and Sales on duty. Never a test account (app.staff_is_test).
-- 3. Two push topics, leads and visitors, on by default for Admins, customer service and Sales (also for the people who
--    already chose their topics). A leads alert goes at once and is sent as urgent; staff phones follow their own quiet hours.
-- 4. Noise: one alert per lead, capture, owner lead stage and visitor per day (the event key). More than
--    notify_lead_burst_count (5) lead and unfinished alerts in notify_lead_burst_minutes (10) become one "N new leads"
--    alert for the rest of that window (the outbox has no grouping, so the grouping is made before the alert).
-- 5. Switches in Program settings, all on: notify_lead_new, notify_request_unfinished, notify_owner_lead_new,
--    notify_hot_visitor (and Live visitors' own notify_hot), notify_lead_burst_count, notify_lead_burst_minutes.
-- SCHEMA_MARKER 0463 (0461 carries the guide chapters). No applied migration is edited.
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
    raise exception '0460: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists notify_lead_new boolean not null default true,
  add column if not exists notify_request_unfinished boolean not null default true,
  add column if not exists notify_owner_lead_new boolean not null default true,
  add column if not exists notify_hot_visitor boolean not null default true,
  add column if not exists notify_lead_burst_count integer not null default 5 check (notify_lead_burst_count between 2 and 50),
  add column if not exists notify_lead_burst_minutes integer not null default 10 check (notify_lead_burst_minutes between 1 and 120);
comment on column program_settings.notify_lead_new is 'Staff lead alerts (0460): an alert in the app and on the phone for each new renter lead (contact form, phone number box, discount game claim, live chat), to the Admins and the person it is assigned to, else customer service and Sales on duty.';
comment on column program_settings.notify_request_unfinished is 'Staff lead alerts (0460): an alert when a renter typed their contact details into the booking request or contact form and did not send it, capture_continue_minutes later.';
comment on column program_settings.notify_owner_lead_new is 'Staff lead alerts (0460): an alert for a new owner lead (also the unfinished application, and again when it becomes the 30-minute chase) to the Admins and the Sales person it is assigned to.';
comment on column program_settings.notify_hot_visitor is 'Staff lead alerts (0460): an alert when a visitor turns Hot on Live visitors (analytics consent only, once per visitor per day), to the Admins and customer service and Sales on duty. Live visitors'' own notify_hot switch must also be on.';
comment on column program_settings.notify_lead_burst_count is 'Staff lead alerts (0460): more than this many lead and unfinished-request alerts inside notify_lead_burst_minutes become one "N new leads" alert.';
comment on column program_settings.notify_lead_burst_minutes is 'Staff lead alerts (0460): the window of notify_lead_burst_count.';

-- ================================================================ 2. two push topics
alter table notification_catalogue drop constraint if exists notification_catalogue_push_topic_check;
alter table notification_catalogue add constraint notification_catalogue_push_topic_check
  check (push_topic in ('requests', 'bookings', 'payments', 'handovers', 'messages', 'alerts', 'documents', 'leads', 'visitors'));
alter table push_preferences drop constraint if exists push_preferences_topics_check;
alter table push_preferences add constraint push_preferences_topics_check
  check (topics <@ array['requests', 'bookings', 'payments', 'handovers', 'messages', 'alerts', 'documents', 'leads', 'visitors']::text[]);

-- an Admin, or an active assistant holding customer service or Sales (own function or one they cover)
create or replace function app.push_lead_staff(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and (
    exists (select 1 from user_roles r where r.user_id = p_user and r.role::text = 'admin')
    or exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.staff_type = 'va' and sp.is_active
                and (sp.va_function::text in ('cs', 'sales') or exists (select 1 from unnest(sp.cover_functions) x where x::text in ('cs', 'sales')))))
$$;

create or replace function app.push_default_topics(p_role text) returns text[]
language sql immutable as $$
  select case p_role
    when 'admin' then array['requests', 'payments', 'messages', 'alerts', 'leads', 'visitors']
    when 'staff' then array['requests', 'bookings', 'messages', 'alerts']
    when 'field' then array['handovers', 'payments']
    when 'owner' then array['requests', 'bookings', 'payments', 'alerts', 'documents']
    when 'investor' then array['payments', 'messages', 'documents']
    else array['requests', 'bookings', 'payments', 'handovers', 'messages', 'alerts', 'documents'] end::text[]
$$;

-- the defaults of one person: their portal's, and for customer service and Sales the lead and visitor topics too
create or replace function app.push_user_defaults(p_user uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select app.push_default_topics(app.push_role(p_user))
         || case when app.push_role(p_user) = 'staff' and app.push_lead_staff(p_user) then array['leads', 'visitors']::text[] else '{}'::text[] end
$$;

create or replace function app.push_topics(p_user uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select coalesce((select p.topics from push_preferences p where p.user_id = p_user), app.push_user_defaults(p_user))
$$;

alter function app.push_state(uuid, text) rename to push_state_pre0460;
create function app.push_state(p_user uuid, p_endpoint text default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.push_state_pre0460(p_user, p_endpoint);
begin
  return jsonb_set(v, '{defaults}', to_jsonb(app.push_user_defaults(p_user)));
end $$;
select pg_temp.copy_grants('app.push_state(uuid, text)'::regprocedure, 'app.push_state_pre0460(uuid, text)'::regprocedure);

create or replace function app.push_set_topics(p_user uuid, p_topics text[]) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v text[] := array(select distinct t from unnest(coalesce(p_topics, '{}')) t
                     where t = any (array['requests', 'bookings', 'payments', 'handovers', 'messages', 'alerts', 'documents', 'leads', 'visitors']) order by 1);
begin
  if p_user is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  insert into push_preferences (user_id, topics) values (p_user, v)
  on conflict (user_id) do update set topics = excluded.topics, updated_at = now();
  return app.push_state(p_user, null);
end $$;

-- the people who chose their topics before these existed get the two new ones (they can switch them off per device)
update push_preferences pp
   set topics = array(select distinct t from unnest(pp.topics || array['leads', 'visitors']::text[]) t order by 1), updated_at = now()
 where app.push_role(pp.user_id) in ('admin', 'staff') and app.push_lead_staff(pp.user_id);

-- a leads alert cannot wait: sent as urgent (staff phones follow their own quiet hours; nothing here delays it)
select pg_temp.patch_fn('app.push_from_notice()'::regprocedure, 'v_urgent := v_topic = ''alerts'';', 'v_urgent := v_topic in (''alerts'', ''leads'');');

-- ================================================================ 3. the notices
insert into notification_catalogue (code, audience, also_sent_to, category, subject, preheader, has_email, priority, emitted_by, link_path,
                                    timing, trigger_text, variables, push_topic)
values
  ('staff_lead_new', 'staff_admin', array['staff_va_cs', 'staff_va_sales']::text[], 'transactional', '{{alert_title}}', '{{alert_body}}', false, 3,
   'app.lead_alert_lead (0460)', null, 'When the lead is made',
   'A renter lead is made: the contact form, the phone number box, a discount game claim, the live chat (a visitor left their contact) or another form. To the Admins and the person it is assigned to, else customer service and Sales on duty. Once per lead; more than 5 in 10 minutes become one "N new leads" alert. Not for test addresses.',
   '[{"name":"alert_title","type":"string"},{"name":"alert_body","type":"string"}]'::jsonb, 'leads'),
  ('staff_request_unfinished', 'staff_admin', array['staff_va_cs', 'staff_va_sales']::text[], 'transactional', '{{alert_title}}', '{{alert_body}}', false, 3,
   'app.lead_alert_unfinished (0460)', null, 'capture_continue_minutes after the form was left',
   'Someone typed their contact details into the booking request or the contact form and did not send it (contact capture, 0090), 30 minutes ago (Program settings, capture_continue_minutes). Checked with the capture job. To the Admins and the person the lead or follow-up task is assigned to, else customer service and Sales on duty. Once per capture.',
   '[{"name":"alert_title","type":"string"},{"name":"alert_body","type":"string"}]'::jsonb, 'leads'),
  ('staff_owner_lead_new', 'staff_admin', array['staff_va_sales']::text[], 'transactional', '{{alert_title}}', '{{alert_body}}', false, 3,
   'app.lead_alert_lead (0460)', null, 'When the owner lead is made, and when the unfinished application becomes the chase',
   'An owner lead is made (the list-your-car form, the owner application as it is filled in, "Website form, unfinished"), and again when an unfinished application is left 30 minutes and becomes a lead to chase (0344). To the Admins and the Sales person it is assigned to (Sales see only their own owner leads). Not for leads added by hand.',
   '[{"name":"alert_title","type":"string"},{"name":"alert_body","type":"string"}]'::jsonb, 'leads'),
  ('staff_hot_visitor', 'staff_admin', array['staff_va_cs', 'staff_va_sales']::text[], 'transactional', '{{alert_title}}', '{{alert_body}}', false, 3,
   'app.hot_visitor_alert (0460)', null, 'When the visitor turns Hot',
   'A visitor''s score first reaches the Hot band on Live visitors (Live visitors settings, hot score), only with their analytics consent. To the Admins and customer service and Sales on duty. At most once per visitor per day. Not for staff browsing the site or test addresses.',
   '[{"name":"alert_title","type":"string"},{"name":"alert_body","type":"string"}]'::jsonb, 'visitors')
on conflict (code) do nothing;
select app.notification_catalogue_refresh();

-- ================================================================ 4. who
-- Staff on duty: someone holding the function (own or covered) who had Live chat, Live visitors or Texts open within the
-- shift minutes.
create or replace function app.lead_alert_users(p_code text, p jsonb) returns table (user_id uuid, audience text)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_assigned uuid := nullif(p ->> 'assigned_to', '')::uuid;
  v_shift integer := (app.settings()).chat_shift_minutes;
begin
  return query
    select distinct on (c.uid) c.uid, c.aud
      from (
        -- the Admins, always
        select u.id uid, 'staff_admin'::text aud, 0 ord
          from users u where u.status = 'active' and exists (select 1 from user_roles r where r.user_id = u.id and r.role::text = 'admin')
        union all
        -- the person it is assigned to
        select u.id, 'staff_va_' || sp.va_function::text, 1
          from users u join staff_profiles sp on sp.user_id = u.id and sp.staff_type = 'va' and sp.is_active
         where u.id = v_assigned and u.status = 'active' and p_code in ('staff_lead_new', 'staff_request_unfinished', 'staff_owner_lead_new')
        union all
        -- unassigned renter leads and hot visitors: customer service and Sales on duty
        select u.id, 'staff_va_' || sp.va_function::text, 2
          from users u join staff_profiles sp on sp.user_id = u.id and sp.staff_type = 'va' and sp.is_active
          join chat_staff_prefs cp on cp.user_id = u.id and cp.last_seen_at > now() - make_interval(mins => v_shift)
         where u.status = 'active' and v_assigned is null and p_code in ('staff_lead_new', 'staff_request_unfinished', 'staff_hot_visitor')
           and (sp.va_function::text in ('cs', 'sales') or exists (select 1 from unnest(sp.cover_functions) x where x::text in ('cs', 'sales')))
      ) c
     where not app.staff_is_test(c.uid)
     order by c.uid, c.ord;
end $$;

alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre0460;
create function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_c.code in ('staff_lead_new', 'staff_request_unfinished', 'staff_owner_lead_new', 'staff_hot_visitor') then
    return query select x.audience, u.id, u.email, u.full_name, null::uuid, null::uuid, true
                   from app.lead_alert_users(p_c.code, p_event.payload) x join users u on u.id = x.user_id;
    return;
  end if;
  return query select * from app.notification_recipients_pre0460(p_event, p_c);
end $$;
select pg_temp.copy_grants('app.notification_recipients(app_events, notification_catalogue)'::regprocedure,
                           'app.notification_recipients_pre0460(app_events, notification_catalogue)'::regprocedure);

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0460;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := coalesce(app.ntf_payload_pre0460(p_code, p_event, p_to), '{}'::jsonb);
  v_admin boolean := p_to ->> 'audience' = 'staff_admin';
  v_path text;
begin
  if p_code in ('staff_lead_new', 'staff_request_unfinished', 'staff_owner_lead_new', 'staff_hot_visitor') then
    v_path := case p_code
      when 'staff_owner_lead_new' then case when v_admin then '/admin/marketing/owner-pipeline' else '/staff/owner-pipeline' end
      when 'staff_hot_visitor' then case when v_admin then '/admin/live' else '/staff/live' end
      else case when v_admin then '/admin/leads' else '/staff/leads' end end;
    x := x || jsonb_build_object('alert_title', coalesce(p_event.payload ->> 'alert_title', ''), 'alert_body', coalesce(p_event.payload ->> 'alert_body', ''),
                                 '_url', (app.settings()).notify_base_url || v_path);
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre0460(text, app_events, jsonb)'::regprocedure);

-- ================================================================ 5. the one way an alert is made
-- Switch, burst control and the event. Returns the event id (null: off, already sent, or folded into the "N new leads").
create or replace function app.lead_alert_emit(p_code text, p_entity text, p_id uuid, p_disc text, p_title text, p_body text, p_extra jsonb default '{}'::jsonb)
returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_on boolean;
  v_n integer;
begin
  v_on := case p_code when 'staff_lead_new' then s.notify_lead_new when 'staff_request_unfinished' then s.notify_request_unfinished
                      when 'staff_owner_lead_new' then s.notify_owner_lead_new when 'staff_hot_visitor' then s.notify_hot_visitor end;
  if not coalesce(v_on, true) then return null; end if;
  if p_code in ('staff_lead_new', 'staff_request_unfinished') then
    -- more than N in the window: one grouped alert for the window, then nothing more until it ends
    select count(*) into v_n from app_events e
     where e.code in ('staff_lead_new', 'staff_request_unfinished') and e.created_at > now() - make_interval(mins => s.notify_lead_burst_minutes)
       and coalesce(e.payload ->> 'burst', '') <> 'true';
    if v_n >= s.notify_lead_burst_count then
      return app.ntf_emit('staff_lead_new', 'lead_alert', null, 'burst:' || floor(extract(epoch from now()) / (s.notify_lead_burst_minutes * 60))::bigint,
        jsonb_build_object('burst', 'true', 'alert_title', format('%s new leads in %s minutes', v_n + 1, s.notify_lead_burst_minutes),
                           'alert_body', 'Open Leads to see them all and who is on each.'));
    end if;
  end if;
  return app.ntf_emit(p_code, p_entity, p_id, p_disc,
    jsonb_build_object('alert_title', left(p_title, 140), 'alert_body', left(coalesce(p_body, ''), 240)) || coalesce(p_extra, '{}'::jsonb));
end $$;

-- where a renter lead came from, in words
create or replace function app.lead_alert_source(l leads) returns text
language sql immutable as $$
  select case
    when l.source = 'unfinished_form' and l.payload ->> 'form' = 'phone_gate' then 'Phone number box'
    when l.source = 'unfinished_form' then 'Website form, unfinished'
    when l.source = 'discount_game' then 'Discount game claim'
    when l.source = 'chat' or l.kind = 'chat' then 'Live chat'
    when l.kind = 'contact' then 'Contact form'
    when l.kind = 'insurer' then 'Insurer form'
    when l.kind = 'launch_notice' then 'Launch notice sign-up'
    when l.kind = 'sample_car' then 'Sample car enquiry'
    when l.source in ('web', 'website') then 'Website form'
    else initcap(replace(coalesce(nullif(l.source, ''), 'website'), '_', ' ')) end
$$;

-- name and contact of a lead, for the body
create or replace function app.lead_alert_who(l leads) returns text
language sql immutable as $$
  select coalesce(nullif(btrim(coalesce(l.name, '')), ''), 'Someone') || coalesce(': ' || nullif(concat_ws(', ', nullif(l.phone, ''), nullif(l.email, '')), ''), '')
$$;

-- a new lead, a lead that became an owner lead (the unfinished application), the owner lead that became the chase
create or replace function app.lead_alert_lead(l leads, p_op text, o leads) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner boolean := l.kind = 'owner_program';
  v_was_owner boolean := p_op = 'UPDATE' and o.kind = 'owner_program';
  v_src text;
begin
  if app.email_is_test(l.email) or l.status = 'spam' then return; end if;
  if v_owner then
    -- added by hand (the person who added it knows) or sourced by a Sales person: no alert
    if l.payload ? 'added_by' or l.sourced_by is not null or l.pipeline_source in ('manual', 'classified') then return; end if;
    v_src := case when l.source = 'unfinished_form' then 'Website form, unfinished'
                  when l.source in ('web', 'website') then 'Website form' else initcap(replace(coalesce(nullif(l.source, ''), 'website'), '_', ' ')) end;
    if p_op = 'INSERT' or not v_was_owner then
      perform app.lead_alert_emit('staff_owner_lead_new', 'lead', l.id, 'new',
        'New owner lead: ' || v_src, app.lead_alert_who(l) || coalesce('. ' || nullif(l.vehicle_text, ''), ''),
        jsonb_build_object('lead_id', l.id, 'assigned_to', l.assigned_to));
    elsif not (o.payload ? 'chased_at') and l.payload ? 'chased_at' then
      perform app.lead_alert_emit('staff_owner_lead_new', 'lead', l.id, 'chase',
        'Owner lead to chase: ' || v_src, app.lead_alert_who(l) || ' started the application and stopped. Call or text them to finish it'
          || coalesce('. ' || nullif(l.vehicle_text, ''), ''),
        jsonb_build_object('lead_id', l.id, 'assigned_to', l.assigned_to));
    end if;
    return;
  end if;
  if p_op <> 'INSERT' then return; end if;
  -- renter leads: not owner recruitment, not a Turo guest, not made by staff on the phone
  if l.kind in ('owner_recruit', 'turo_guest', 'phone') then return; end if;
  -- a form typed and not sent is the unfinished-request alert (after the delay), except the phone number box
  if l.source = 'unfinished_form' and coalesce(l.payload ->> 'form', '') <> 'phone_gate' then return; end if;
  perform app.lead_alert_emit('staff_lead_new', 'lead', l.id, 'new', 'New lead: ' || app.lead_alert_source(l), app.lead_alert_who(l),
    jsonb_build_object('lead_id', l.id, 'assigned_to', l.assigned_to));
end $$;

create or replace function app.lead_alert_trg() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  -- an alert is extra: nothing here may stop the lead
  begin
    if tg_op = 'INSERT' then perform app.lead_alert_lead(new, 'INSERT', null);
    else perform app.lead_alert_lead(new, 'UPDATE', old); end if;
  exception when others then
    raise warning 'lead alert not made for %: %', new.id, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists leads_z_alert on leads;
create trigger leads_z_alert after insert on leads for each row execute function app.lead_alert_trg();
drop trigger if exists leads_z_alert_upd on leads;
create trigger leads_z_alert_upd after update of kind, payload on leads for each row
  when ((old.kind is distinct from new.kind and new.kind = 'owner_program') or (not (old.payload ? 'chased_at') and new.payload ? 'chased_at'))
  execute function app.lead_alert_trg();

-- ================================================================ 6. a request typed and not sent
create or replace function app.lead_alert_unfinished(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  c record;
  n integer := 0;
begin
  if not ps.capture_enabled or not ps.notify_request_unfinished then return 0; end if;
  for c in select cc.id, cc.form, cc.name, cc.email, cc.phone, cc.last_at, coalesce(l.assigned_to, t.assigned_to) as assigned
             from contact_captures cc left join leads l on l.id = cc.lead_id left join tasks t on t.id = cc.task_id
            where cc.done_at is null and cc.form in ('booking_request', 'contact') and (cc.email is not null or cc.phone is not null)
              and cc.last_at <= p_now - make_interval(mins => ps.capture_continue_minutes) and cc.last_at > p_now - interval '7 days'
              and not app.email_is_test(cc.email)
              and not exists (select 1 from app_events e where e.dedupe_key = 'staff_request_unfinished:' || cc.id || ':unfinished')
            order by cc.last_at limit 200 loop
    if app.lead_alert_emit('staff_request_unfinished', 'contact_capture', c.id, 'unfinished',
         'Unfinished request: ' || coalesce(nullif(btrim(coalesce(c.name, '')), ''), c.phone, c.email),
         format('Typed their details into the %s and did not send it. %s',
                case c.form when 'booking_request' then 'booking request' else 'contact form' end,
                coalesce(nullif(concat_ws(', ', nullif(c.phone, ''), nullif(c.email, '')), ''), '')),
         jsonb_build_object('capture_id', c.id, 'assigned_to', c.assigned)) is not null then
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

alter function app.job_capture(timestamptz) rename to job_capture_pre0460;
create function app.job_capture(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v text := app.job_capture_pre0460(p_now);
  n integer;
begin
  begin
    n := app.lead_alert_unfinished(p_now);
  exception when others then
    raise warning 'unfinished request alerts failed: %', sqlerrm;
    n := 0;
  end;
  return v || case when n > 0 then format(', unfinished alerts %s', n) else '' end;
end $$;
select pg_temp.copy_grants('app.job_capture(timestamptz)'::regprocedure, 'app.job_capture_pre0460(timestamptz)'::regprocedure);

-- ================================================================ 7. a hot visitor
create or replace function app.hot_visitor_alert() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_why text;
begin
  begin
    -- analytics consent only; renters only; not staff browsing the site; not a test address; Live visitors' own switch on
    if new.consent <> 'analytics' or new.audience is distinct from 'renter' then return null; end if;
    if not coalesce((app.settings()).visitor_tracking_enabled, true) or not coalesce((app.visitor_sig_cfg()).notify_hot, true) then return null; end if;
    if app.email_is_test(new.known_email) then return null; end if;
    if new.user_id is not null and exists (select 1 from user_roles r where r.user_id = new.user_id and r.role::text in ('admin', 'va', 'field')) then return null; end if;
    select string_agg(r ->> 'why', '; ') into v_why from (select r from jsonb_array_elements(coalesce(new.score_reasons, '[]'::jsonb)) r limit 2) z;
    -- once per visitor per day: the key
    perform app.lead_alert_emit('staff_hot_visitor', 'visitor', new.visitor_id, app.local_date(now())::text,
      'Hot visitor: ' || app.visitor_who(new), coalesce(v_why, 'Score ' || coalesce(new.score, 0)) || coalesce(' (' || nullif(new.city, '') || ')', ''),
      jsonb_build_object('session_id', new.id));
  exception when others then
    raise warning 'hot visitor alert not made for %: %', new.id, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists visitor_sessions_hot_alert on visitor_sessions;
create trigger visitor_sessions_hot_alert after update of hot_at on visitor_sessions for each row
  when (old.hot_at is null and new.hot_at is not null) execute function app.hot_visitor_alert();

-- ================================================================ 8. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['push_lead_staff', 'push_user_defaults', 'lead_alert_users', 'lead_alert_emit', 'lead_alert_source',
              'lead_alert_who', 'lead_alert_lead', 'lead_alert_trg', 'lead_alert_unfinished', 'hot_visitor_alert', 'push_state_pre0460',
              'notification_recipients_pre0460', 'ntf_payload_pre0460', 'job_capture_pre0460'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
