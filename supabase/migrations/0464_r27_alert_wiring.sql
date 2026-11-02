-- 0464: the staff alerts meet the rest of r27 (r27 merged: tracker 0400, AI interviews 0380, data health 0441).
--
-- Owner's ask: nothing "not wired yet" where the data exists. So:
--   1. Tracker alerts (0400 already notifies Admins and fleet staff, push topic alerts, sent as urgent): the rule table now
--      lists each kind (offline, left the zone or Ontario, speeding, driving after the return time, battery or unplugged),
--      and its switch works: a rule turned off in Settings > Staff alerts stops that kind. The levels (speed, hours offline,
--      zone) stay in Tracker settings.
--   2. AI interview scored: one normal alert to the Admins, with the recommendation and the score (the Admin decides).
--   3. Data health: the nightly in-app notice of 0441 to the Admins now also reaches the phone (topic alerts).
-- Still without a data source (stay "not wired yet" in the rule table): see docs/alerts/matrix.md.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. tracker rules
update staff_alert_rules set rule = 'tracker_zone', label = 'Left the zone or Ontario', wired = true,
       hint = 'Sent by the tracker (0400) as urgent to the Admins and fleet staff. The zone is in Tracker settings.', sort = 96
 where rule = 'geofence_exit';
update staff_alert_rules set label = 'Tracker offline', wired = true, who = '{admin,on_duty:fleet}',
       hint = 'Sent by the tracker (0400) as urgent to the Admins and fleet staff once a tracker has not reported for the hours set in Tracker settings (the booking is named when it is out on rent).', sort = 95
 where rule = 'tracker_offline';
insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('tracker_speeding', 'Speeding', 'Fleet and cars', '{admin,on_duty:fleet}', 'urgent', 'alerts', true, false, 'Sent by the tracker (0400) as urgent. The speed is in Tracker settings.', 97),
  ('tracker_afterhours', 'Still driving after the return time', 'Fleet and cars', '{admin,on_duty:fleet}', 'urgent', 'alerts', true, false, 'Sent by the tracker (0400) as urgent, after the grace minutes set in Tracker settings.', 98),
  ('tracker_battery', 'Tracker battery low or unplugged', 'Fleet and cars', '{admin,on_duty:fleet}', 'urgent', 'alerts', true, false, 'Sent by the tracker (0400) as urgent.', 99)
on conflict (rule) do nothing;

-- the switch of the rule: a kind turned off makes no notice (the tracker's own row and the Tracker page stay)
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre0464;
create function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_c.code in ('staff_tracker_alert', 'staff_tracker_alert_fleet') and exists (
       select 1 from staff_alert_rules r
        where not r.enabled and r.rule = case p_event.payload ->> 'alert_kind'
                when 'offline' then 'tracker_offline' when 'left_zone' then 'tracker_zone' when 'left_ontario' then 'tracker_zone'
                when 'speeding' then 'tracker_speeding' when 'overdue_driving' then 'tracker_afterhours'
                when 'battery_low' then 'tracker_battery' when 'unplugged' then 'tracker_battery' end) then
    return;
  end if;
  return query select * from app.notification_recipients_pre0464(p_event, p_c);
end $$;
select pg_temp.copy_grants('app.notification_recipients(app_events, notification_catalogue)'::regprocedure,
                           'app.notification_recipients_pre0464(app_events, notification_catalogue)'::regprocedure);

-- the tracker notices of 0400 carry their words in the event; without them the notice and its push had no title
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0464;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := coalesce(app.ntf_payload_pre0464(p_code, p_event, p_to), '{}'::jsonb);
begin
  if p_code in ('staff_tracker_alert', 'staff_tracker_alert_fleet') then
    x := x || jsonb_build_object('alert_title', coalesce(p_event.payload ->> 'alert_title', ''), 'alert_detail', coalesce(p_event.payload ->> 'alert_detail', ''));
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre0464(text, app_events, jsonb)'::regprocedure);

-- ================================================================ 2. AI interview scored
update staff_alert_rules set wired = true, who = '{admin}', tier = 'normal', topic = 'requests',
       hint = 'The AI interview of an applicant was scored (0380): its recommendation and score. The Admin decides; nothing is sent to the applicant.'
 where rule = 'interview_finished';

create or replace function app.sa_interview() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications;
begin
  begin
    if new.state = 'scored' and old.state is distinct from 'scored' then
      select * into a from job_applications where id = new.application_id;
      if a.id is null or app.email_is_test(a.email) then return null; end if;
      perform app.staff_alert('interview_finished', 'job_application', a.id, 'scored',
        'AI interview scored: ' || coalesce(a.full_name, 'an applicant'),
        format('%s of 100, suggests %s.', coalesce(new.interview_score::text, '?'),
               case new.recommendation when 'live_call' then 'a live call' when 'hire' then 'hiring' when 'decline' then 'declining' when 'sales' then 'Sales' else 'a look' end),
        jsonb_build_object('path_admin', '/admin/hiring'));
    end if;
  exception when others then
    raise warning 'interview alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists ai_interviews_z_staff_alert on ai_interviews;
create trigger ai_interviews_z_staff_alert after update on ai_interviews for each row execute function app.sa_interview();

-- ================================================================ 3. data health to the phone
update notification_catalogue set push_topic = 'alerts' where code = 'staff_data_health';
update staff_alert_rules set wired = true,
       hint = 'The nightly check (0441) found records that need you: the in-app notice of Admin > To do, now also on the phone once a day.'
 where rule = 'data_health';

-- ================================================================ 4. delete my account (the native apps, 0390)
update staff_alert_rules set wired = true, who = '{admin}', tier = 'urgent', topic = 'alerts',
       hint = 'Someone asked to delete their account (profile page, app or site). The Admin task of 0390 stays; the settle-up and the 30-day reply are the Admin''s.'
 where rule = 'account_delete_request';

create or replace function app.sa_account_deletion() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  u users;
begin
  begin
    select * into u from users where id = new.user_id;
    if u.id is null or app.email_is_test(u.email) or app.staff_is_test(u.id) then return null; end if;
    perform app.staff_alert('account_delete_request', 'account_deletion', new.id, 'new', 'Account deletion asked: ' || coalesce(u.full_name, 'a customer'),
      coalesce(nullif(left(new.reason, 120), ''), 'No reason given') || '. Settle anything open, reply within 30 days.', jsonb_build_object('path_admin', '/admin'));
  exception when others then
    raise warning 'account deletion alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists account_deletion_requests_z_staff_alert on account_deletion_requests;
create trigger account_deletion_requests_z_staff_alert after insert on account_deletion_requests for each row execute function app.sa_account_deletion();

-- ================================================================ 5. the academy (a quiz passed or failed: a line of the digest)
update staff_alert_rules set wired = true, who = '{admin}', tier = 'digest', topic = 'alerts',
       hint = 'A staff member passed or did not pass a section quiz of the academy. A line of the Admin digest, never a push.'
 where rule = 'academy_progress';

create or replace function app.sa_academy_attempt() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  u users;
begin
  begin
    select * into u from users where id = new.user_id;
    if u.id is null or app.email_is_test(u.email) or app.staff_is_test(u.id) then return null; end if;
    perform app.staff_alert('academy_progress', 'academy_attempt', new.id, case when new.passed then 'passed' else 'failed' end,
      (case when new.passed then 'Quiz passed: ' else 'Quiz not passed: ' end) || coalesce(u.full_name, 'a staff member'),
      format('%s, %s of %s right.', coalesce((select s.title from academy_sections s where s.id = new.section_id), 'a section'), new.correct, new.total),
      jsonb_build_object('path_admin', '/admin/staff'));
  exception when others then
    raise warning 'academy alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists academy_attempts_z_staff_alert on academy_attempts;
create trigger academy_attempts_z_staff_alert after insert on academy_attempts for each row execute function app.sa_academy_attempt();
