-- 99: the alerts of a lead nobody holds (migration 1153). Fixtures start with "ula"; addresses are example.test. Cleans up
-- its notices, events, duty and clock rows.
select test.suite('99 r35g unassigned lead alerts (1153)');
-- the events earlier suites left unprocessed are not this suite's (process_events takes the oldest first)
update app_events set processed_at = now() where processed_at is null;

select test.mk_user('ula_admin', 'admin');
select test.mk_user('ula_on', 'va', 'sales');      -- Sales, Live chat open now
select test.mk_user('ula_clock', 'va', 'sales');   -- Sales, clocked in now
select test.mk_user('ula_off', 'va', 'sales');     -- Sales, off duty
select test.mk_user('ula_ended', 'va', 'sales');   -- Sales, clocked out
select test.mk_user('ula_held', 'va', 'sales');    -- Sales on duty, not fully onboarded
select test.mk_user('ula_cs', 'va', 'cs');         -- customer service, on duty
insert into users (id, email, full_name) values (test.id('ula_vtest'), 'verify-ula-sales@carmacars.ca', 'Verify Sales');
insert into user_roles (user_id, role) values (test.id('ula_vtest'), 'va');
insert into staff_profiles (user_id, staff_type, va_function) values (test.id('ula_vtest'), 'va', 'sales');
update staff_profiles set onboarding_exempt = false where user_id = test.id('ula_held');
insert into chat_staff_prefs (user_id, last_seen_at)
values (test.id('ula_on'), now()), (test.id('ula_held'), now()), (test.id('ula_cs'), now()), (test.id('ula_vtest'), now()),
       (test.id('ula_off'), now() - interval '3 days')
on conflict (user_id) do update set last_seen_at = excluded.last_seen_at;
insert into staff_clock_entries (user_id, started_at) values (test.id('ula_clock'), now() - interval '2 hours');
insert into staff_clock_entries (user_id, started_at, ended_at) values (test.id('ula_ended'), now() - interval '5 hours', now() - interval '1 hour');

create or replace function test.ula_who(p_code text, p_like text) returns text
language sql stable as $$
  select coalesce(string_agg(l, ',' order by l), 'none') from (select distinct replace(replace(u.email, '@example.test', ''), '@carmacars.ca', '') l
    from notifications n join users u on u.id = n.user_id
   where n.code = p_code and n.title like p_like and (u.email like 'ula\_%@example.test' or u.email = 'verify-ula-sales@carmacars.ca')) x $$;
create or replace function test.ula_users(p_code text, p jsonb) returns text
language sql stable as $$
  select coalesce(string_agg(l, ',' order by l), 'none') from (select replace(u.email, '@example.test', '') l
    from app.lead_alert_users(p_code, p) x join users u on u.id = x.user_id
   where u.email like 'ula\_%@example.test' or u.email = 'verify-ula-sales@carmacars.ca') y $$;

select test.eq('on duty: Live chat open or clocked in; not off duty or clocked out',
  app.lead_on_duty(test.id('ula_on')) || '/' || app.lead_on_duty(test.id('ula_clock')) || '/' || app.lead_on_duty(test.id('ula_off')) || '/'
  || app.lead_on_duty(test.id('ula_ended')), 'true/true/false/false');
select test.eq('the one not fully onboarded is held', app.staff_fully_onboarded(test.id('ula_held')), false);

-- ================================================================== a new owner lead nobody holds
insert into leads (id, kind, name, email, source, vehicle_text) values (test.id('ula_o1'), 'owner_program', 'Una Owner', 'ula_una@example.test', 'web', '2021 Example');
select test.eq('it arrives unassigned (1152)', (select assigned_to from leads where id = test.id('ula_o1')), null::uuid);
select app.process_events(1000);
select test.eq('an unassigned owner lead: the Admin and every onboarded Sales person on duty or clocked in; not off duty, clocked out, held, customer service or a test account',
  test.ula_who('staff_owner_lead_new', 'New owner lead: Website form'), 'ula_admin,ula_clock,ula_on');

-- ================================================================== claimed: the claimer only (and the Admin)
insert into lead_claims (lead_id, claimed_by, expires_at, cap_at) values (test.id('ula_o1'), test.id('ula_off'), now() + interval '1 day', now() + interval '3 days');
update leads set payload = payload || jsonb_build_object('chased_at', now()) where id = test.id('ula_o1');
select app.process_events(1000);
select test.eq('claimed: the later alert goes to the claimer only (even off duty), and the Admin',
  test.ula_who('staff_owner_lead_new', 'Owner lead to chase%'), 'ula_admin,ula_off');
select test.eq('a claim is read when the alert is sent, not from the event',
  test.ula_users('staff_owner_lead_new', jsonb_build_object('lead_id', test.id('ula_o1'))), 'ula_admin,ula_off');
update lead_claims set expires_at = now() - interval '1 minute' where lead_id = test.id('ula_o1');
select test.eq('the claim ran out: Sales on duty again',
  test.ula_users('staff_owner_lead_new', jsonb_build_object('lead_id', test.id('ula_o1'))), 'ula_admin,ula_clock,ula_on');
delete from lead_claims where lead_id = test.id('ula_o1');
select set_config('app.lead_admin_move', 'on', false);
update leads set assigned_to = test.id('ula_off') where id = test.id('ula_o1');
select set_config('app.lead_admin_move', '', false);
select test.eq('assigned by an Admin: that person only, and the Admin',
  test.ula_users('staff_owner_lead_new', jsonb_build_object('lead_id', test.id('ula_o1'))), 'ula_admin,ula_off');
select test.eq('a holder not fully onboarded is not told (the Admin is)',
  test.ula_users('staff_owner_lead_new', jsonb_build_object('assigned_to', test.id('ula_held'))), 'ula_admin');

-- ================================================================== renter leads and unfinished requests
insert into leads (id, kind, name, phone, email, message, source) values (test.id('ula_r1'), 'contact', 'Rae Renter', '4165550191', 'ula_rae@example.test', 'Hi', 'web');
select app.process_events(1000);
select test.eq('an unassigned renter lead: the Admin, customer service and Sales on duty or clocked in, onboarded',
  test.ula_who('staff_lead_new', 'New lead: Contact form'), 'ula_admin,ula_clock,ula_cs,ula_on');
insert into lead_claims (lead_id, claimed_by, expires_at, cap_at) values (test.id('ula_r1'), test.id('ula_on'), now() + interval '1 day', now() + interval '3 days');
insert into contact_captures (id, visitor_id, form, ref, name, phone, lead_id, last_at, first_at) values (test.id('ula_cc1'), test.id('ula_v1'), 'contact', 'u1', 'Rae Renter', '4165550191', test.id('ula_r1'), now() - interval '1 hour', now() - interval '70 minutes');
select test.eq('an unfinished request of a claimed lead: the claimer only, and the Admin',
  test.ula_users('staff_request_unfinished', jsonb_build_object('capture_id', test.id('ula_cc1'))), 'ula_admin,ula_on');
select test.eq('the hot visitor alert: still on duty, now only the onboarded',
  test.ula_users('staff_hot_visitor', '{}'::jsonb), 'ula_admin,ula_clock,ula_cs,ula_on');

select test.eq('Alerts settings: a new owner lead goes to Sales on duty while nobody holds it',
  (select who::text from staff_alert_rules where rule = 'staff_owner_lead_new'), '{admin,assigned,unassigned_on_duty:sales}');
select test.ok('the catalogue says so', (select trigger_text like '%every fully onboarded Sales person on duty or clocked in%' from notification_catalogue where code = 'staff_owner_lead_new'));

-- clean-up
delete from notifications where user_id in (select id from users where email like 'ula\_%@example.test' or email = 'verify-ula-sales@carmacars.ca');
delete from notifications where event_id in (select id from app_events where payload ->> 'lead_id' in (test.id('ula_o1')::text, test.id('ula_r1')::text));
delete from app_events where payload ->> 'lead_id' in (test.id('ula_o1')::text, test.id('ula_r1')::text);
delete from contact_captures where id = test.id('ula_cc1');
delete from lead_claims where lead_id in (test.id('ula_o1'), test.id('ula_r1'));
delete from chat_staff_prefs where user_id in (select id from users where email like 'ula\_%@example.test' or email = 'verify-ula-sales@carmacars.ca');
delete from staff_clock_entries where user_id in (select id from users where email like 'ula\_%@example.test');
