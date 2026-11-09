-- 99: staff alerts for leads, unfinished requests, owner leads and hot visitors (migration 0460). Fixtures start with "la";
-- addresses are example.test. Cleans up after itself (leads, captures, visits, events, notices, devices).
select test.suite('99 lead alerts');

select test.mk_user('lal_admin', 'admin');
select test.mk_user('lal_cs', 'va', 'cs');
select test.mk_user('lal_sales', 'va', 'sales');
select test.mk_user('lal_sales2', 'va', 'sales');
select test.mk_user('lal_fleet', 'va', 'fleet');
select test.mk_user('lal_field', 'field');
select test.mk_renter('lal_rita');
-- a verification account in Sales, on duty
insert into users (id, email, full_name) values (test.id('lal_vtest'), 'verify-la-sales@carmacars.ca', 'Verify Sales');
insert into user_roles (user_id, role) values (test.id('lal_vtest'), 'va');
insert into staff_profiles (user_id, staff_type, va_function) values (test.id('lal_vtest'), 'va', 'sales');
-- on duty: Live chat, Live visitors or Texts open now (customer service, Sales, Fleet and the test account; not the second Sales person)
insert into chat_staff_prefs (user_id, last_seen_at) values (test.id('lal_cs'), now()), (test.id('lal_sales'), now()), (test.id('lal_fleet'), now()), (test.id('lal_vtest'), now());

delete from notifications where code in ('staff_lead_new', 'staff_request_unfinished', 'staff_owner_lead_new', 'staff_hot_visitor');
delete from app_events where code in ('staff_lead_new', 'staff_request_unfinished', 'staff_owner_lead_new', 'staff_hot_visitor');
create temp table lal_s as select notify_lead_new, notify_request_unfinished, notify_owner_lead_new, notify_hot_visitor, notify_lead_burst_count, notify_lead_burst_minutes, id from program_settings;
update program_settings set notify_lead_burst_count = 50;

create or replace function test.lal_sub(p_label text, p_user uuid, p_portal text) returns jsonb
language sql as $$ select app.push_subscribe(p_user, jsonb_build_object('endpoint', 'https://push.example.test/send/' || p_label,
  'p256dh', 'B' || repeat('A', 86), 'auth', repeat('Q', 22), 'portal', p_portal, 'device', 'iPhone')) $$;
create or replace function test.lal_n(p_user text, p_code text, p_like text default '%') returns bigint
language sql stable as $$ select count(*) from notifications where user_id = test.id(p_user) and code = p_code and title like p_like $$;
create or replace function test.lal_who(p_code text, p_like text default '%') returns text
language sql stable as $$
  select coalesce(string_agg(l, ',' order by l), 'none') from (select distinct replace(u.email, '@example.test', '') l
    from notifications n join users u on u.id = n.user_id
   where n.code = p_code and n.title like p_like and u.email like 'lal\_%@example.test'
      or (n.code = p_code and n.title like p_like and u.email = 'verify-la-sales@carmacars.ca')) x $$;

-- ================================================================== the catalogue and the topics
select test.eq('four notices: in the app and on the phone only, none by email',
  (select count(*) || '/' || bool_or(has_email)::text from notification_catalogue where code in ('staff_lead_new', 'staff_request_unfinished', 'staff_owner_lead_new', 'staff_hot_visitor')), '4/false');
select test.eq('topics: leads for three notices, visitors for the hot visitor',
  (select string_agg(push_topic, ',' order by code) from notification_catalogue where code in ('staff_lead_new', 'staff_request_unfinished', 'staff_owner_lead_new', 'staff_hot_visitor')),
  'visitors,leads,leads,leads');
select test.eq('defaults: Admin, customer service and Sales get leads and visitors; Fleet, field and renters do not',
  (app.push_topics(test.id('lal_admin')) @> array['leads', 'visitors'])::text || '/' || (app.push_topics(test.id('lal_cs')) @> array['leads', 'visitors'])::text || '/'
  || (app.push_topics(test.id('lal_sales')) @> array['leads', 'visitors'])::text || '/' || (app.push_topics(test.id('lal_fleet')) && array['leads', 'visitors'])::text
  || '/' || (app.push_topics(test.id('lal_field')) && array['leads', 'visitors'])::text || '/' || (app.push_topics(test.id('lal_rita')) && array['leads', 'visitors'])::text,
  'true/true/true/false/false/false');
select test.eq('the alerts card shows the same defaults', (app.push_state(test.id('lal_cs')) -> 'defaults')::text,
  '["requests", "bookings", "messages", "alerts", "leads", "visitors"]');
select test.eq('a choice may include the new topics', (app.push_set_topics(test.id('lal_sales2'), array['leads', 'visitors', 'nonsense']) ->> 'topics'), '["leads", "visitors"]');
delete from push_preferences where user_id = test.id('lal_sales2');

-- ================================================================== a renter lead
insert into leads (id, kind, name, phone, email, message, source) values (test.id('lal_l1'), 'contact', 'Lena Contact', '4165550101', 'lal_lena@example.test', 'Hello', 'web');
select app.process_events(1000);
select test.eq('a contact form lead: the Admin and customer service and Sales on duty (not Fleet, the second Sales person, a test account)',
  test.lal_who('staff_lead_new', 'New lead: Contact form'), 'lal_admin,lal_cs,lal_sales');
select test.eq('it names the source and the person',
  (select title || ' | ' || body from notifications where user_id = test.id('lal_cs') and code = 'staff_lead_new' and title like 'New lead: Contact%'), 'New lead: Contact form | Lena Contact: 4165550101, lal_lena@example.test');
-- r35 (0950): the alert opens that lead
select test.eq('the Admin''s link is that lead on Admin, an assistant''s that lead on the staff portal',
  (select url from notifications where user_id = test.id('lal_admin') and code = 'staff_lead_new' and title like 'New lead: Contact%') ~ '/admin/sales-leads/[0-9a-f-]{36}$'
  and (select url from notifications where user_id = test.id('lal_cs') and code = 'staff_lead_new' and title like 'New lead: Contact%') ~ '/staff/sales-leads/[0-9a-f-]{36}$', true);
-- once per lead
select app.lead_alert_lead((select l from leads l where id = test.id('lal_l1')), 'INSERT', null);
select app.process_events(1000);
select test.eq('dedupe: the same lead again makes no second alert', (select count(*) from app_events where code = 'staff_lead_new' and payload ->> 'lead_id' = test.id('lal_l1')::text), 1::bigint);

-- assigned: the assigned person (on duty or not), the Admin; not the others on duty
-- (1152: a lead is assigned only by a person: an Admin's assignment here)
select set_config('app.lead_admin_move', 'on', false);
insert into leads (id, kind, name, phone, source, assigned_to) values (test.id('lal_l2'), 'other', 'Gina Game', '4165550102', 'discount_game', test.id('lal_sales2'));
select set_config('app.lead_admin_move', '', false);
select app.process_events(1000);
select test.eq('an assigned lead (discount game claim): the assigned person and the Admin only',
  test.lal_who('staff_lead_new', 'New lead: Discount game claim'), 'lal_admin,lal_sales2');
-- other sources
insert into leads (id, kind, name, email, source) values (test.id('lal_l3'), 'chat', 'Chad Chat', 'lal_chad@example.test', 'chat');
insert into leads (id, kind, phone, source, payload) values (test.id('lal_l4'), 'other', '4165550104', 'unfinished_form', jsonb_build_object('form', 'phone_gate'));
select app.process_events(1000);
select test.eq('live chat and the phone number box name their source',
  (select string_agg(distinct title, ' / ' order by title) from notifications where user_id = test.id('lal_admin') and code = 'staff_lead_new' and title in ('New lead: Live chat', 'New lead: Phone number box')),
  'New lead: Live chat / New lead: Phone number box');
-- not alerted: a form typed and not sent (its own alert later), a test address, a lead a person made on the phone, a Turo guest, owner recruitment
insert into leads (id, kind, name, phone, source, payload) values (test.id('lal_l5'), 'other', 'Una Unsent', '4165550105', 'unfinished_form', jsonb_build_object('form', 'booking_request'));
insert into leads (id, kind, name, email, source) values (test.id('lal_l6'), 'contact', 'Test Person', 'verify-la-lead@carmacars.ca', 'web');
insert into leads (id, kind, name, phone, source) values (test.id('lal_l7'), 'phone', 'Phil Phone', '4165550107', 'phone');
select test.eq('no renter alert for an unsent form, a test address or a lead made on the phone',
  (select count(*) from app_events where code = 'staff_lead_new' and payload ->> 'lead_id' in (test.id('lal_l5')::text, test.id('lal_l6')::text, test.id('lal_l7')::text)), 0::bigint);
select test.eq('a renter lead is not an owner lead alert', (select count(*) from app_events where code = 'staff_owner_lead_new' and payload ->> 'lead_id' in (test.id('lal_l1')::text, test.id('lal_l2')::text)), 0::bigint);

-- the switch
update program_settings set notify_lead_new = false;
insert into leads (id, kind, name, phone, source) values (test.id('lal_l8'), 'contact', 'Off Switch', '4165550108', 'web');
select test.eq('Program settings: notify_lead_new off, no alert', (select count(*) from app_events where code = 'staff_lead_new' and payload ->> 'lead_id' = test.id('lal_l8')::text), 0::bigint);
update program_settings set notify_lead_new = true;

-- ================================================================== a request typed and not sent
insert into contact_captures (visitor_id, form, ref, name, phone, last_at, first_at) values
  (test.id('lal_v1'), 'booking_request', 'd1', 'Uma Unsent', '4165550201', now() - interval '31 minutes', now() - interval '40 minutes'),
  (test.id('lal_v2'), 'booking_request', 'd2', 'Fresh Typer', '4165550202', now() - interval '5 minutes', now() - interval '6 minutes'),
  (test.id('lal_v3'), 'contact', 'd3', 'Cora Contact', '4165550203', now() - interval '45 minutes', now() - interval '50 minutes');
insert into contact_captures (visitor_id, form, ref, name, phone, last_at, first_at, done_at) values
  (test.id('lal_v4'), 'booking_request', 'd4', 'Sent It', '4165550204', now() - interval '60 minutes', now() - interval '70 minutes', now() - interval '50 minutes');
insert into contact_captures (visitor_id, form, ref, name, email, last_at, first_at) values
  (test.id('lal_v5'), 'booking_request', 'd5', 'Verify Typer', 'verify-la-capture@carmacars.ca', now() - interval '60 minutes', now() - interval '70 minutes');
create temp table lal_unf as select app.lead_alert_unfinished() as first_run;
select test.eq('unfinished: after the capture delay only, once, not a sent form, not a test address',
  (((select first_run from lal_unf) >= 2)::text || '/' || app.lead_alert_unfinished() || '/'
   || (select count(*) from app_events where code = 'staff_request_unfinished' and entity_id in (select id from contact_captures where visitor_id in (select test.id('lal_v' || g) from generate_series(1, 5) g)))), 'true/0/2');
select app.process_events(1000);
select test.eq('unfinished: the Admin and the staff on duty, naming the form',
  test.lal_who('staff_request_unfinished', 'Unfinished request: Uma%'), 'lal_admin,lal_cs,lal_sales');
select test.eq('unfinished: the booking request and the contact form are told apart',
  (select string_agg(body, ' / ' order by body) from notifications where user_id = test.id('lal_admin') and code = 'staff_request_unfinished' and (title like 'Unfinished request: Uma%' or title like 'Unfinished request: Cora%')),
  'Typed their details into the booking request and did not send it. 4165550201 / Typed their details into the contact form and did not send it. 4165550203'::text);
update program_settings set notify_request_unfinished = false;
insert into contact_captures (visitor_id, form, ref, name, phone, last_at, first_at) values (test.id('lal_v6'), 'booking_request', 'd6', 'Off Typer', '4165550206', now() - interval '60 minutes', now() - interval '70 minutes');
select test.eq('Program settings: notify_request_unfinished off, none', app.lead_alert_unfinished(), 0);
update program_settings set notify_request_unfinished = true;
-- assigned through the follow-up task
insert into contact_captures (visitor_id, form, ref, name, phone, last_at, first_at, lead_id) values
  (test.id('lal_v7'), 'booking_request', 'd7', 'Ada Assigned', '4165550207', now() - interval '60 minutes', now() - interval '70 minutes', test.id('lal_l5'));
update leads set assigned_to = test.id('lal_sales2') where id = test.id('lal_l5');
select app.lead_alert_unfinished();
select app.process_events(1000);
select test.eq('unfinished and assigned (through its lead): the assigned person and the Admin', test.lal_who('staff_request_unfinished', 'Unfinished request: Ada%'), 'lal_admin,lal_sales2');

-- ================================================================== owner leads
select set_config('app.lead_admin_move', 'on', false);
insert into leads (id, kind, name, email, source, assigned_to, vehicle_text) values (test.id('lal_o1'), 'owner_program', 'Owen Owner', 'lal_owen@example.test', 'web', test.id('lal_sales'), '2022 Example Car');
select set_config('app.lead_admin_move', '', false);
insert into leads (id, kind, name, email, source) values (test.id('lal_o2'), 'owner_program', 'Opal Unassigned', 'lal_opal@example.test', 'web');
select app.process_events(1000);
select test.eq('an owner lead: the Admin and the Sales person it is assigned to, not other Sales or customer service',
  test.lal_who('staff_owner_lead_new', 'New owner lead: Website form') , 'lal_admin,lal_sales');
select test.eq('an unassigned owner lead: the Admin only', test.lal_n('lal_admin', 'staff_owner_lead_new', 'New owner lead%') || '/' || test.lal_n('lal_sales', 'staff_owner_lead_new', 'New owner lead%') || '/' || test.lal_n('lal_cs', 'staff_owner_lead_new'), '2/1/0');
select test.eq('an owner lead''s link is that lead (r35, 0950)',
  (select url from notifications where user_id = test.id('lal_sales') and code = 'staff_owner_lead_new' and title like 'New owner lead%') ~ '/staff/sales-leads/[0-9a-f-]{36}$', true);
-- the unfinished application: a capture's lead made as "other", then an owner lead, then the 30-minute chase
insert into leads (id, kind, name, email, source, payload) values (test.id('lal_o3'), 'other', 'Ula Unfinished', 'lal_ula@example.test', 'unfinished_form', jsonb_build_object('form', 'owner_application'));
select test.eq('an unfinished application is not an owner alert until it becomes an owner lead', (select count(*) from app_events where code in ('staff_lead_new', 'staff_owner_lead_new') and payload ->> 'lead_id' = test.id('lal_o3')::text), 0::bigint);
update leads set kind = 'owner_program', pipeline_stage = 'new', pipeline_source = 'unfinished_form' where id = test.id('lal_o3');
select app.process_events(1000);
select test.eq('it becomes "Website form, unfinished": the Admin', test.lal_who('staff_owner_lead_new', 'New owner lead: Website form, unfinished'), 'lal_admin');
update leads set payload = payload || jsonb_build_object('chased_at', now()), assigned_to = test.id('lal_sales') where id = test.id('lal_o3');
select app.process_events(1000);
select test.eq('the 30-minute chase: the Admin and the Sales person it was given to', test.lal_who('staff_owner_lead_new', 'Owner lead to chase%'), 'lal_admin,lal_sales');
update leads set payload = payload || jsonb_build_object('chased_at', now(), 'x', 1) where id = test.id('lal_o3');
select test.eq('the chase is once per lead', (select count(*) from app_events where code = 'staff_owner_lead_new' and payload ->> 'lead_id' = test.id('lal_o3')::text), 2::bigint);
-- added by hand, a test address, the switch
insert into leads (id, kind, name, email, source, assigned_to, pipeline_source, payload) values (test.id('lal_o4'), 'owner_program', 'Hand Added', 'lal_hand@example.test', 'manual', test.id('lal_sales'), 'manual', jsonb_build_object('added_by', test.id('lal_sales')));
insert into leads (id, kind, name, email, source) values (test.id('lal_o5'), 'owner_program', 'Test Owner', 'verify-la-owner@carmacars.ca', 'web');
update program_settings set notify_owner_lead_new = false;
insert into leads (id, kind, name, email, source) values (test.id('lal_o6'), 'owner_program', 'Off Owner', 'lal_off@example.test', 'web');
update program_settings set notify_owner_lead_new = true;
select test.eq('no owner alert for a lead added by hand, a test address or with the switch off',
  (select count(*) from app_events where code = 'staff_owner_lead_new' and payload ->> 'lead_id' in (test.id('lal_o4')::text, test.id('lal_o5')::text, test.id('lal_o6')::text)), 0::bigint);

-- ================================================================== a hot visitor
update visitor_signal_config set notify_hot = true;
insert into visitor_sessions (id, visitor_id, consent, known_name, city, score, score_reasons) values
  (test.id('lal_s1'), test.id('lal_hv1'), 'analytics', 'Hana Hot', 'Toronto', 80, '[{"kind":"price_seen","why":"Saw $240 for 3 days"},{"kind":"dates_repeat","why":"Searched dates 3 times"}]'),
  (test.id('lal_s2'), test.id('lal_hv1'), 'analytics', 'Hana Hot', 'Toronto', 80, '[]'),
  (test.id('lal_s3'), test.id('lal_hv3'), 'essential', null, 'Toronto', 80, '[]'),
  (test.id('lal_s4'), test.id('lal_hv4'), 'analytics', null, 'Toronto', 80, '[]');
update visitor_sessions set hot_at = now() where id = test.id('lal_s1');
update visitor_sessions set hot_at = now() where id = test.id('lal_s2');
update visitor_sessions set hot_at = now() where id = test.id('lal_s3');
select app.process_events(1000);
select test.eq('hot visitor: the Admin and customer service and Sales on duty (Fleet and the test account are not told)',
  test.lal_who('staff_hot_visitor', 'Hot visitor: Hana Hot'), 'lal_admin,lal_cs,lal_sales');
select test.eq('hot visitor: names the visitor and why',
  (select title || ' | ' || body from notifications where user_id = test.id('lal_cs') and code = 'staff_hot_visitor'), 'Hot visitor: Hana Hot | Saw $240 for 3 days; Searched dates 3 times (Toronto)');
select test.eq('hot visitor: at most once per visitor per day (the second visit of the day makes none)',
  (select count(*) from app_events where code = 'staff_hot_visitor' and entity_id = test.id('lal_hv1')), 1::bigint);
select test.eq('hot visitor: without analytics consent, none', (select count(*) from app_events where code = 'staff_hot_visitor' and entity_id = test.id('lal_hv3')), 0::bigint);
-- a staff member browsing the site, a test address, the switches
update visitor_sessions set user_id = test.id('lal_cs') where id = test.id('lal_s4');
update visitor_sessions set hot_at = now() where id = test.id('lal_s4');
select test.eq('hot visitor: staff browsing the site are not a visitor to chase', (select count(*) from app_events where code = 'staff_hot_visitor' and entity_id = test.id('lal_hv4')), 0::bigint);
insert into visitor_sessions (id, visitor_id, consent, known_email, score) values (test.id('lal_s5'), test.id('lal_hv5'), 'analytics', 'verify-la-visitor@carmacars.ca', 80);
update visitor_sessions set hot_at = now() where id = test.id('lal_s5');
update program_settings set notify_hot_visitor = false;
insert into visitor_sessions (id, visitor_id, consent, score) values (test.id('lal_s6'), test.id('lal_hv6'), 'analytics', 80);
update visitor_sessions set hot_at = now() where id = test.id('lal_s6');
update program_settings set notify_hot_visitor = true;
update visitor_signal_config set notify_hot = false;
insert into visitor_sessions (id, visitor_id, consent, score) values (test.id('lal_s7'), test.id('lal_hv7'), 'analytics', 80);
update visitor_sessions set hot_at = now() where id = test.id('lal_s7');
update visitor_signal_config set notify_hot = true;
select test.eq('hot visitor: not for a test address, and not with either switch off',
  (select count(*) from app_events where code = 'staff_hot_visitor' and entity_id in (test.id('lal_hv5'), test.id('lal_hv6'), test.id('lal_hv7'))), 0::bigint);
-- a visitor from yesterday is told again today (the key has the day)
select test.eq('hot visitor: the key has the day', (select dedupe_key from app_events where code = 'staff_hot_visitor' and entity_id = test.id('lal_hv1')),
  'staff_hot_visitor:' || test.id('lal_hv1') || ':' || app.local_date(now())::text);

-- ================================================================== the phone
select test.lal_sub('lal_admin1', test.id('lal_admin'), 'admin');
select test.lal_sub('lal_cs1', test.id('lal_cs'), 'staff');
insert into leads (id, kind, name, phone, source) values (test.id('lal_p1'), 'contact', 'Pia Push', '4165550301', 'web');
select app.process_events(1000);
select test.eq('a lead is queued for each device that keeps the leads topic, urgent and due now',
  (select count(*) || '/' || bool_and(o.urgent) || '/' || bool_and(o.send_after <= now()) from push_outbox o join notifications n on n.id = o.notification_id
    where n.code = 'staff_lead_new' and n.title = 'New lead: Contact form' and n.body like 'Pia Push%'), '2/true/true');
select app.push_set_topics(test.id('lal_cs'), array['requests']);
insert into leads (id, kind, name, phone, source) values (test.id('lal_p2'), 'contact', 'Quin Quiet', '4165550302', 'web');
select app.process_events(1000);
select test.eq('a person who turned the leads topic off still has the notice in the app but gets no push',
  (select count(*) from notifications where user_id = test.id('lal_cs') and body like 'Quin Quiet%') || '/' || (select count(*) from push_outbox o join notifications n on n.id = o.notification_id where n.user_id = test.id('lal_cs') and n.body like 'Quin Quiet%'), '1/0');
update visitor_sessions set hot_at = null where id = test.id('lal_s2');
insert into visitor_sessions (id, visitor_id, consent, known_name, score) values (test.id('lal_s8'), test.id('lal_hv8'), 'analytics', 'Vic Visitor', 80);
update visitor_sessions set hot_at = now() where id = test.id('lal_s8');
select app.process_events(1000);
select test.eq('a hot visitor goes to the visitors topic, not as urgent',
  (select count(*) || '/' || bool_or(o.urgent) from push_outbox o join notifications n on n.id = o.notification_id where n.code = 'staff_hot_visitor' and n.title = 'Hot visitor: Vic Visitor'), '1/false');

-- ================================================================== noise: more than N in the window is one alert
delete from notifications where code in ('staff_lead_new', 'staff_request_unfinished');
delete from app_events where code in ('staff_lead_new', 'staff_request_unfinished');
update program_settings set notify_lead_burst_count = 3, notify_lead_burst_minutes = 10;
insert into leads (id, kind, name, phone, source) values (test.id('lal_b1'), 'contact', 'Burst One', '4165550401', 'web'), (test.id('lal_b2'), 'contact', 'Burst Two', '4165550402', 'web'),
  (test.id('lal_b3'), 'contact', 'Burst Three', '4165550403', 'web');
insert into leads (id, kind, name, phone, source) values (test.id('lal_b4'), 'contact', 'Burst Four', '4165550404', 'web');
insert into leads (id, kind, name, phone, source) values (test.id('lal_b5'), 'contact', 'Burst Five', '4165550405', 'web');
select app.process_events(1000);
select test.eq('burst: three alerts, then one "4 new leads in 10 minutes" and nothing more for the window',
  (select count(*) filter (where payload ->> 'burst' is null) || '/' || count(*) filter (where payload ->> 'burst' = 'true') || '/' || max(payload ->> 'alert_title') filter (where payload ->> 'burst' = 'true')
     from app_events where code = 'staff_lead_new'), '3/1/4 new leads in 10 minutes');
select test.eq('burst: the Admin has the grouped alert', (select count(*) from notifications where user_id = test.id('lal_admin') and code = 'staff_lead_new' and title = '4 new leads in 10 minutes'), 1::bigint);
update program_settings p set notify_lead_burst_count = s.notify_lead_burst_count, notify_lead_burst_minutes = s.notify_lead_burst_minutes from lal_s s where s.id = p.id;

-- ================================================================== the functions are not callable from a browser
select test.ok('the alert functions are for the server only',
  not has_function_privilege('authenticated', 'app.lead_alert_emit(text, text, uuid, text, text, text, jsonb)', 'execute')
  and not has_function_privilege('anon', 'app.lead_alert_users(text, jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'app.lead_alert_unfinished(timestamptz)', 'execute')
  and has_function_privilege('service_role', 'app.lead_alert_unfinished(timestamptz)', 'execute'));

-- ================================================================== clean up
delete from push_outbox where user_id in (select id from users where email like 'lal\_%@example.test');
delete from push_subscriptions where endpoint like '%/lal\_%';
delete from push_preferences where user_id in (select id from users where email like 'lal\_%@example.test');
delete from notifications where code in ('staff_lead_new', 'staff_request_unfinished', 'staff_owner_lead_new', 'staff_hot_visitor');
delete from app_events where code in ('staff_lead_new', 'staff_request_unfinished', 'staff_owner_lead_new', 'staff_hot_visitor');
delete from contact_captures where visitor_id in (select test.id('lal_v' || g) from generate_series(1, 7) g);
delete from leads where id in (select test.id(x) from unnest(array['lal_l1','lal_l2','lal_l3','lal_l4','lal_l5','lal_l6','lal_l7','lal_l8','lal_o1','lal_o2','lal_o3','lal_o4','lal_o5','lal_o6','lal_p1','lal_p2','lal_b1','lal_b2','lal_b3','lal_b4','lal_b5']) x);
delete from visitor_sessions where id in (select test.id('lal_s' || g) from generate_series(1, 8) g);
delete from chat_staff_prefs where user_id in (select id from users where email like 'lal\_%@example.test' or email = 'verify-la-sales@carmacars.ca');
update program_settings p set notify_lead_new = s.notify_lead_new, notify_request_unfinished = s.notify_request_unfinished, notify_owner_lead_new = s.notify_owner_lead_new,
  notify_hot_visitor = s.notify_hot_visitor, notify_lead_burst_count = s.notify_lead_burst_count, notify_lead_burst_minutes = s.notify_lead_burst_minutes from lal_s s where s.id = p.id;
