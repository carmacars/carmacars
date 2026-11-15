-- 99_r48_alert_targets: every staff alert opens the exact record it is about (2960). Fixtures start with "at48".
select test.suite('99 r48 alert targets');

select test.mk_user('at48_admin', 'admin');
select test.mk_user('at48_cs', 'va', 'cs');
select test.mk_user('at48_fleet', 'va', 'fleet');
select test.mk_user('at48_field', 'field');
select test.mk_owner('at48_own');
select test.mk_vehicle('AT48V', 'at48_own');
select test.mk_renter('at48_ren');
select test.mk_booking('AT4801', 'AT48V', 'at48_ren', '2026-12-01 10:00', '2026-12-05 10:00', 'confirmed');

create temp table at48 as select (app.settings()).notify_base_url b;
create function pg_temp.at(p_who text, p_url text, p_code text, p_entity text default null, p_id uuid default null, p_event bigint default null) returns text
language sql as $$ select app.alert_path_for(test.id(p_who), p_url, p_code, p_entity, p_id, p_event) $$;
-- a bare page: a portal home or a list with nothing in its address that names a record
create function pg_temp.bare(p text) returns boolean language sql as $$
  select p in ('/', '/admin', '/staff', '/staff/field') or (p !~ '[?#]' and app.alert_route_static(p)) $$;

-- the records of the owner's sample
insert into messages (id, direction, channel, booking_id, renter_id, body)
  values (test.id('at48:msg'), 'inbound', 'portal', test.id('booking:AT4801'), test.id('renter:at48_ren'), 'Can I pick up at 9?');
insert into academy_sections (id, slug, title) values (test.id('at48:sec'), 'at48-section', 'At48 section');
insert into academy_lessons (id, section_id, sort, title) values (test.id('at48:lesson'), test.id('at48:sec'), 1, 'At48 lesson');
insert into academy_attempts (id, user_id, section_id, correct, total, score_bps, passed)
  values (test.id('at48:attempt'), test.id('at48_cs'), test.id('at48:sec'), 5, 5, 10000, true);
insert into visitor_sessions (id, visitor_id, started_at) values (test.id('at48:session'), test.id('at48:visitor'), now() - interval '5 minutes');
insert into phone_threads (id, number) values (test.id('at48:thread'), '+16475550148');
insert into chat_conversations (id) values (test.id('at48:chat'));
insert into field_jobs (id, kind, vehicle_id, booking_id, scheduled_at) values (test.id('at48:job'), 'handover', test.id('vehicle:AT48V'), test.id('booking:AT4801'), '2026-12-01 15:00+00');
insert into field_shift_slots (id, starts_at, ends_at) values (test.id('at48:slot'), '2026-12-01 14:00+00', '2026-12-01 20:00+00');

-- the sample, as the owner reported it: a generic page, now the exact record
select test.eq('renter replied (old /va address): Admin opens the booking messages',
  pg_temp.at('at48_admin', (select b from at48) || '/va/cs/bookings/AT4801', 'staff_renter_replied', 'message', test.id('at48:msg')), '/admin/bookings/AT4801?tab=activity');
select test.eq('renter replied (old /va address): Customer service opens the booking messages',
  pg_temp.at('at48_cs', (select b from at48) || '/va/cs/bookings/AT4801', 'staff_renter_replied', 'message', test.id('at48:msg')), '/staff/bookings/AT4801?tab=activity');
select test.eq('renter replied with only the home page: the booking messages',
  pg_temp.at('at48_admin', (select b from at48) || '/admin', 'staff_renter_replied', 'message', test.id('at48:msg')), '/admin/bookings/AT4801?tab=activity');
select test.eq('Customer service end of day: the Admin opens that role''s To do list',
  pg_temp.at('at48_admin', (select b from at48) || '/staff', 'staff_digest_eod_va_cs'), '/admin/tasks?queue=cs');
select test.eq('Admin end of day: the Admin To do list',
  pg_temp.at('at48_admin', (select b from at48) || '/admin', 'staff_digest_eod_admin'), '/admin/tasks?queue=admin');
select test.eq('Finance end of day: the Finance To do list',
  pg_temp.at('at48_admin', (select b from at48) || '/staff', 'staff_digest_eod_va_finance'), '/admin/tasks?queue=finance');
select test.eq('job running late: the Admin opens that job on the board',
  pg_temp.at('at48_admin', '/admin/staff', 'staff_alert_urgent', 'field_job', test.id('at48:job')), '/admin/field-jobs?job=' || test.id('at48:job'));
select test.eq('job running late: Fleet opens that job on their board',
  pg_temp.at('at48_fleet', '/staff/field', 'staff_alert_urgent', 'field_job', test.id('at48:job')), '/staff/fleet?job=' || test.id('at48:job'));
select test.eq('job running late: field staff open the job',
  pg_temp.at('at48_field', '/staff/field', 'staff_alert_urgent', 'field_job', test.id('at48:job')), '/staff/field/jobs/' || test.id('at48:job'));
select test.eq('a field job page of the staff portal: the Admin gets that job on the board',
  pg_temp.at('at48_admin', (select b from at48) || '/staff/field/jobs/' || test.id('at48:job'), 'staff_field_job_assigned', 'field_job', test.id('at48:job')),
  '/admin/field-jobs?job=' || test.id('at48:job'));
select test.eq('quiz passed: the person''s academy page',
  pg_temp.at('at48_admin', '/admin/staff', 'staff_alert_digest', 'academy_attempt', test.id('at48:attempt')), '/admin/academy/staff/' || test.id('at48_cs'));
select test.eq('lesson finished: the person''s academy page (from the person in the alert)',
  app.alert_target(test.id('at48_admin'), true, false, 'academy_lesson', test.id('at48:lesson'), 'academy_lesson', jsonb_build_object('kind', 'academy_lesson:' || test.id('at48_cs'))),
  '/admin/academy/staff/' || test.id('at48_cs'));
select test.eq('hot visitor: the Admin opens the visit',
  pg_temp.at('at48_admin', '/admin/live', 'staff_hot_visitor', 'visitor', test.id('at48:visitor')), '/admin/live/history/' || test.id('at48:session'));
select test.eq('hot visitor: Customer service opens the visitor on Visitors',
  pg_temp.at('at48_cs', '/admin/live', 'staff_hot_visitor', 'visitor', test.id('at48:visitor')), '/staff/visitors?id=' || test.id('at48:session'));
select test.eq('waiting for an answer: the conversation',
  pg_temp.at('at48_admin', '/admin/unanswered', 'staff_alert_urgent', 'phone_thread', test.id('at48:thread')), '/admin/visitors?view=chat&inbox=phone&id=' || test.id('at48:thread'));
select test.eq('waiting for an answer: Customer service opens the conversation',
  pg_temp.at('at48_cs', '/staff/unanswered', 'staff_alert_urgent', 'phone_thread', test.id('at48:thread')), '/staff/visitors?view=chat&inbox=phone&id=' || test.id('at48:thread'));
select test.eq('a chat: the chat itself',
  pg_temp.at('at48_admin', '/admin/chat', 'staff_chat_message', 'chat_conversation', test.id('at48:chat')), '/admin/visitors?view=chat&id=' || test.id('at48:chat'));
select test.eq('a car alert on the Listings list: the car',
  pg_temp.at('at48_admin', '/admin/listings', 'staff_alert_normal', 'vehicle', test.id('vehicle:AT48V')), '/admin/vehicles/' || test.id('vehicle:AT48V'));
select test.eq('a shift with nobody: the shift on the board',
  pg_temp.at('at48_admin', '/admin/field-jobs', 'staff_alert_urgent', 'field_shift_slot', test.id('at48:slot')), '/admin/field-jobs?slot=' || test.id('at48:slot'));
select test.eq('a staff member alert: their scorecard',
  pg_temp.at('at48_admin', '/admin/staff', 'staff_alert_normal', 'user', test.id('at48_cs'), null), '/admin/staff/' || test.id('at48_cs') || '/scorecard');
select test.eq('a list alert (a payout run) keeps its list',
  pg_temp.at('at48_admin', (select b from at48) || '/admin/payouts', 'staff_payouts_due', 'payout_run', test.id('at48:run')), '/admin/payouts');
select test.eq('a page that names its record stays as it is',
  pg_temp.at('at48_admin', '/admin/bookings/AT4801?tab=documents', 'staff_alert_normal', 'vehicle', test.id('vehicle:AT48V')), '/admin/bookings/AT4801?tab=documents');

-- an escalated alert opens the page of the alert it escalates
insert into notifications (id, user_id, code, title, url, entity, entity_id, dedupe_key)
  values (test.id('at48:n1'), test.id('at48_cs'), 'staff_renter_replied', 'Replied', '/va/cs/bookings/AT4801', 'message', test.id('at48:msg'), 'at48:n1');
select test.eq('an escalation: the escalated alert''s page, for the Admin',
  pg_temp.at('at48_admin', '/admin', 'staff_alert_urgent', 'notification', test.id('at48:n1')), '/admin/bookings/AT4801?tab=activity');

-- the Alerts page, the "latest alert" pop-up and the phone alert use the same page
insert into notifications (user_id, code, title, url, entity, entity_id, dedupe_key)
  values (test.id('at48_admin'), 'staff_renter_replied', 'At48 replied', (select b from at48) || '/va/cs/bookings/AT4801', 'message', test.id('at48:msg'), 'at48:feed');
select test.eq('Alerts page: the booking messages',
  (select x ->> 'url' from jsonb_array_elements(app.server_alert_feed(test.id('at48_admin'))) x where x ->> 'title' = 'At48 replied' limit 1), '/admin/bookings/AT4801?tab=activity');
select test.eq('latest alert pop-up: the same page',
  app.server_alert_latest(test.id('at48_admin')) #>> '{latest,url}', '/admin/bookings/AT4801?tab=activity');
select test.ok('the phone alert uses the viewer''s page',
  pg_get_functiondef('app.push_from_notice()'::regprocedure) like '%app.alert_path_for(new.user_id, new.url, new.code, new.entity, new.entity_id, new.event_id)%');

-- ================================================================ every kind of notice the code writes
-- the (rule or code, entity) pairs in the database's own functions: every entity is a known kind
create temp table at48_kinds as
with src as (select p.prosrc s from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('app', 'public') and p.proname !~ '_pre[0-9]+$'),
m as (select x[1] as kind, x[2] as entity from src, regexp_matches(s, $r$(?:staff_alert|lead_alert_emit)\(\s*'([a-z_:]+)',\s*'([a-z_]+)'$r$, 'g') x
      union select x[1], x[2] from src, regexp_matches(s, $r$(?:ntf_emit|emit_event)\(\s*'(staff_[a-z_]+)',\s*'([a-z_]+)'$r$, 'g') x)
select entity, string_agg(distinct kind, ' ') kinds from m group by entity;

select test.ok('the scan finds the notice kinds (more than 60)', (select count(*) from at48_kinds) > 60, (select count(*) from at48_kinds)::text);
select test.eq('every kind of record a staff notice is written for is known (booking, record or list)',
  (select string_agg(entity || ' (' || kinds || ')', ', ' order by entity) from at48_kinds where app.alert_entity_kind(entity) is null), null::text);

-- each kind with a record: a real row of its table opens that record, not a bare page, for an Admin
do $$
declare r record; v_id uuid; v_path text; v_tbl text; v_bad text := ''; v_n int := 0; v_skip text := '';
begin
  for r in select k.entity, k.kinds from at48_kinds k where app.alert_entity_kind(k.entity) in ('booking', 'record') order by 1 loop
    v_tbl := app.alert_entity_table(r.entity);
    v_id := null;
    if r.entity in ('user', 'users', 'staff') then v_id := test.id('at48_cs');
    elsif r.entity = 'visitor' then v_id := test.id('at48:visitor');
    elsif r.entity = 'notification' then v_id := test.id('at48:n1');
    elsif r.entity = 'academy_lesson' then v_id := null;  -- the person comes from the alert (tested above)
    elsif v_tbl is not null then
      -- a row whose parent record exists (the page needs it)
      execute format('select x.id from %I x where %s order by x.id limit 1', v_tbl,
        case when app.alert_entity_kind(r.entity) = 'booking' and v_tbl <> 'bookings' then 'exists (select 1 from bookings b where b.id = x.booking_id)'
             when r.entity in ('vehicle_exit', 'vehicle_service_record', 'field_car_update', 'field_prep_task', 'listing_intake', 'listing_similarity_flag') then 'x.vehicle_id is not null'
             when r.entity in ('owner_payout_account', 'owner_debit', 'owner_debit_attempt', 'owner_debit_notice', 'owner_agreement_form', 'owner_invoice') then 'x.owner_id is not null'
             when r.entity = 'message' then 'x.booking_id is not null or x.owner_id is not null or x.renter_id is not null'
             when r.entity = 'field_spend' then 'x.booking_id is not null or x.vehicle_id is not null'
             when r.entity = 'task' then 'x.booking_id is not null'
             -- a capture whose visit is no longer kept and that made nothing has nothing to open
             when r.entity = 'contact_capture' then 'x.lead_id is not null or x.chat_id is not null or x.renter_id is not null or exists (select 1 from visitor_sessions s where s.visitor_id = x.visitor_id)'
             else 'true' end) into v_id;
    end if;
    if v_id is null then v_skip := v_skip || r.entity || ' '; continue; end if;
    v_path := app.alert_path_for(test.id('at48_admin'), '/admin', 'staff_alert_normal', r.entity, v_id, null);
    v_n := v_n + 1;
    if pg_temp.bare(v_path) then v_bad := v_bad || r.entity || ' -> ' || v_path || '; '; end if;
  end loop;
  perform test.eq('every kind with a record opens the record, not a bare page', nullif(v_bad, ''), null::text);
  perform test.ok('kinds checked with a real row: more than 25', v_n > 25, v_n || ' checked; no row to sample: ' || v_skip);
end $$;
