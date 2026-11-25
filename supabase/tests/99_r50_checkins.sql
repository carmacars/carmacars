-- 99: monthly check-in visits for long-term renters (migrations 4000 and 4001, release 50; docs/changes/2026-11-24-r50-checkins.md).
-- Eligibility (length, long-term weekly, rideshare, the switch), the visit made the lead days before it is due with the
-- renter's reminder, one follow-up, booking a slot (taken slots refused, Fleet told), the checklist (photos required, the
-- odometer reading and the tread in the maintenance tracker, the To do, the damage intake), the timeline, the owner's view,
-- who may read and write, the table rules. Fixtures start with "xci"; every address is example.test.
select test.suite('99 r50 check-in visits');
select test.mk_user('xci_admin', 'admin');
select test.mk_user('xci_fleet', 'va', 'fleet');
select test.mk_user('xci_fin', 'va', 'finance');
select test.mk_user('xci_field', 'field');
select test.mk_owner('xci_owner');
select test.mk_vehicle('xci_car', 'xci_owner');
select test.mk_vehicle('xci_car2', 'xci_owner');
select test.mk_renter('xci_long');
select test.mk_renter('xci_short');
select test.mk_booking('XCI-LONG', 'xci_car', 'xci_long', to_char((now() - interval '27 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
  to_char((now() + interval '40 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'on_rent');
select test.mk_booking('XCI-SHORT', 'xci_car2', 'xci_short', to_char((now() - interval '2 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
  to_char((now() + interval '5 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'on_rent');
create function test.xci_b(p text) returns bookings language sql stable as $$ select * from bookings where booking_number = p $$;
create function test.xci_v(p text) returns checkin_visits language sql stable as $$
  select v.* from checkin_visits v join bookings b on b.id = v.booking_id where b.booking_number = p order by v.created_at desc limit 1 $$;
create function test.xci_photos(p text) returns jsonb language sql stable as $$
  select jsonb_agg(jsonb_build_object('angle', a, 'bucket', 'condition-photos', 'path', 'bookings/' || (test.xci_b(p)).id || '/checkin/' || gen_random_uuid() || '.jpg'))
    from unnest(array['front', 'rear', 'left', 'right', 'odometer']) a $$;

-- ================================================================ 1. settings and eligibility
select test.eq('on by default: 28 days, every 30, reminded 5 days before',
  (select s.checkin_enabled::text || '/' || s.checkin_min_days || '/' || s.checkin_interval_days || '/' || s.checkin_lead_days from (select (app.settings()).*) s), 'true/28/30/5');
select test.eq('a 67-day rental has visits; a week does not', coalesce(app.checkin_why(test.xci_b('XCI-LONG')), '-') || '/' || coalesce(app.checkin_why(test.xci_b('XCI-SHORT')), '-'), 'long/-');
select test.eq('the first visit is due 30 days after the pickup', app.checkin_next_due(test.xci_b('XCI-LONG')), app.local_date((test.xci_b('XCI-LONG')).pickup_at) + 30);
insert into rideshare_doc_requests (booking_id, renter_id, platforms) select id, renter_id, array['uber'] from bookings where booking_number = 'XCI-SHORT';
select test.eq('a rideshare driver has visits whatever the length', app.checkin_why(test.xci_b('XCI-SHORT')), 'rideshare');
delete from rideshare_doc_requests where booking_id = (test.xci_b('XCI-SHORT')).id;
update program_settings set checkin_enabled = false where id = (app.settings()).id;
select test.eq('the Program settings switch turns them all off', app.checkin_why(test.xci_b('XCI-LONG')) is null, true);
update program_settings set checkin_enabled = true where id = (app.settings()).id;

-- ================================================================ 2. the sweep: the visit and the renter's reminder
select test.eq('the sweep makes the visit 3 days before it is due, with the reminder', app.checkin_sweep() >= 1, true);
select test.eq('one visit, due, reminded', (select v.status || '/' || (v.reminded_at is not null)::text from (select (test.xci_v('XCI-LONG')).*) v), 'due/true');
select test.eq('the renter''s reminder is queued once', (select count(*) from app_events where code = 'renter_checkin_reminder' and entity_id = (test.xci_b('XCI-LONG')).id), 1::bigint);
select test.lives('a second sweep', $$select app.checkin_sweep()$$);
select test.eq('...makes nothing twice', (select count(*) from checkin_visits where booking_id = (test.xci_b('XCI-LONG')).id) || '/' ||
  (select count(*) from app_events where code = 'renter_checkin_reminder' and entity_id = (test.xci_b('XCI-LONG')).id), '1/1');
select test.eq('the timeline says it was suggested', (select count(*) from booking_events where booking_id = (test.xci_b('XCI-LONG')).id and note like 'Check-in visit suggested%'), 1::bigint);
select test.ok('the reminder has its text (the channel policy and the opt-out decide whether it goes)',
  exists (select 1 from sms_templates where code = 'renter_checkin_reminder') and exists (select 1 from sms_templates where code = 'renter_checkin_followup'));
select test.ok('staff notices are never texted', (select bool_and(no_text) from notification_catalogue where code in ('staff_checkin_booked', 'staff_checkin_today')));

-- ================================================================ 3. the renter: what they see and picking a time
select test.eq('the renter sees it on, around the due date, with slots',
  (select (v ->> 'on') || '/' || (v -> 'visit' ->> 'status') || '/' || (jsonb_array_length(v -> 'slots') > 0)::text from public.server_checkin_renter(test.id('xci_long'), 'XCI-LONG') v), 'true/due/true');
select test.eq('another renter sees nothing of it', (public.server_checkin_renter(test.id('xci_short'), 'XCI-LONG') ->> 'on'), 'false');
select test.throws('a time that is not a slot is refused', $$select public.server_checkin_book(test.id('xci_long'), jsonb_build_object('booking', 'XCI-LONG', 'slot_at', now() + interval '3 days 7 minutes'))$$, 'no longer free');
select test.throws('by request needs when and where', $$select public.server_checkin_book(test.id('xci_long'), '{"booking": "XCI-LONG", "place": "request"}')$$, 'Say when and where');
select test.lives('a slot is booked', format($$select public.server_checkin_book(test.id('xci_long'), jsonb_build_object('booking', 'XCI-LONG', 'slot_at', %L))$$,
  public.server_checkin_renter(test.id('xci_long'), 'XCI-LONG') -> 'slots' -> 0 ->> 'at'));
select test.eq('booked at the office, Fleet and the Admins told, on the timeline',
  (select v.status || '/' || v.place from (select (test.xci_v('XCI-LONG')).*) v) || '/' ||
  (select count(*) from app_events where code = 'staff_checkin_booked' and entity_id = (test.xci_b('XCI-LONG')).id) || '/' ||
  (select count(*) from booking_events where booking_id = (test.xci_b('XCI-LONG')).id and note like 'Check-in visit booked%'), 'booked/office/1/1');
select test.eq('the staff notice goes to Fleet and the Admins',
  (select string_agg(distinct x.audience, ',' order by x.audience) from app_events e, app.notification_recipients(e, (select c from notification_catalogue c where c.code = 'staff_checkin_booked')) x
    where e.code = 'staff_checkin_booked'), 'staff_admin,staff_va_fleet');
select test.lives('the renter takes the time back', $$select public.server_checkin_book(test.id('xci_long'), '{"booking": "XCI-LONG", "cancel": true}')$$);
select test.eq('due again', (test.xci_v('XCI-LONG')).status, 'due');
select test.lives('a time by request', $$select public.server_checkin_book(test.id('xci_long'), '{"booking": "XCI-LONG", "place": "request", "note": "Weekday evenings near Yonge and Eglinton"}')$$);
select test.eq('booked by request', (select v.status || '/' || v.place from (select (test.xci_v('XCI-LONG')).*) v), 'booked/request');

-- ================================================================ 4. staff: who may, the queue, the checklist
select test.throws('Finance alone does not do check-in visits', $$select public.door(test.id('xci_fin'), 'aal2', 'ops_read', 'checkin_queue', '{}')$$, 'Staff only');
select test.ok('Fleet sees the visit in the queue',
  exists (select 1 from jsonb_array_elements(public.door(test.id('xci_fleet'), 'aal2', 'ops_read', 'checkin_queue', '{}') -> 'visits') x where x ->> 'booking_number' = 'XCI-LONG' and x ->> 'bucket' = 'booked'));
select test.ok('field work reads the visit', (public.door(test.id('xci_field'), 'aal2', 'field_read', 'checkin_visit', jsonb_build_object('id', (test.xci_v('XCI-LONG')).id)) -> 'visit' ->> 'id') is not null);
select test.throws('the photos are required', format($$select public.door(test.id('xci_field'), 'aal2', 'field_do', 'checkin_do', jsonb_build_object('op', 'complete', 'id', %L, 'odometer_km', 12000, 'damage_found', false, 'fluids_ok', true))$$,
  (test.xci_v('XCI-LONG')).id), 'Add the photos still missing: front, rear, left, right, odometer');
select test.throws('a photo of another booking does not count', format($$select public.door(test.id('xci_field'), 'aal2', 'field_do', 'checkin_do', jsonb_build_object('op', 'complete', 'id', %L, 'odometer_km', 12000, 'damage_found', false, 'fluids_ok', true, 'photos', test.xci_photos('XCI-SHORT')))$$,
  (test.xci_v('XCI-LONG')).id), 'Add the photos still missing');
select test.throws('damage needs its description', format($$select public.door(test.id('xci_field'), 'aal2', 'field_do', 'checkin_do', jsonb_build_object('op', 'complete', 'id', %L, 'odometer_km', 12000, 'damage_found', true, 'fluids_ok', true, 'photos', test.xci_photos('XCI-LONG')))$$,
  (test.xci_v('XCI-LONG')).id), 'Describe the damage');
select test.lives('field work saves the visit: damage, low tread, a warning light', format($$select public.door(test.id('xci_field'), 'aal2', 'field_do', 'checkin_do', jsonb_build_object('op', 'complete', 'id', %L,
  'odometer_km', 12000, 'damage_found', true, 'damage_note', 'Scratch on the rear bumper', 'tread_mm', 2.5, 'fluids_ok', true, 'warning_lights', 'Tire pressure', 'notes', 'Renter happy', 'photos', test.xci_photos('XCI-LONG')))$$,
  (test.xci_v('XCI-LONG')).id));
select test.eq('done, with what was found', (select v.status || '/' || v.odometer_km || '/' || v.damage_found::text || '/' || v.tread_mm from (select (test.xci_v('XCI-LONG')).*) v), 'done/12000/true/2.5');
select test.eq('the odometer reading is in the maintenance tracker', (select count(*) from vehicle_odometer_readings where vehicle_id = test.id('vehicle:xci_car') and source = 'checkin' and km = 12000), 1::bigint);
select test.eq('a Fleet To do for the maintenance', (select count(*) || '/' || max(queue) from tasks where task_type = 'checkin_maintenance' and booking_id = (test.xci_b('XCI-LONG')).id and status = 'open'), '1/fleet');
select test.eq('a damage intake and an Admin To do', (select count(*) from damage_intakes where booking_id = (test.xci_b('XCI-LONG')).id and description like 'Found at a check-in visit%') || '/' ||
  (select count(*) from tasks where task_type = 'checkin_damage' and booking_id = (test.xci_b('XCI-LONG')).id), '1/1');
select test.eq('on the timeline', (select count(*) from booking_events where booking_id = (test.xci_b('XCI-LONG')).id and note like 'Check-in visit done: 12000 km, damage found%'), 1::bigint);
select test.throws('done once', format($$select public.door(test.id('xci_field'), 'aal2', 'field_do', 'checkin_do', jsonb_build_object('op', 'complete', 'id', %L))$$, (test.xci_v('XCI-LONG')).id), 'already done');
select test.eq('the next visit is 30 days after this one', app.checkin_next_due(test.xci_b('XCI-LONG')), app.today() + 30);
select test.eq('the owner sees the visit, condition only', (select (x ->> 'odometer_km') || '/' || (x ->> 'summary') from jsonb_array_elements(app.maint_owner_history(test.id('vehicle:xci_car')) -> 'checkins') x), '12000/Damage noted; we are handling it');
select test.ok('the owner never sees the notes or the photos', not (app.maint_owner_history(test.id('vehicle:xci_car')) -> 'checkins' -> 0 ? 'notes') and not (app.maint_owner_history(test.id('vehicle:xci_car')) -> 'checkins' -> 0 ? 'photos'));

-- ================================================================ 5. the switch, skip
select test.throws('field work cannot switch visits', $$select public.door(test.id('xci_field'), 'aal2', 'field_do', 'checkin_do', '{"op": "switch", "booking": "XCI-SHORT", "mode": "on"}')$$, 'switch check-in visits');
select test.lives('Fleet switches them on for a short rental', $$select public.door(test.id('xci_fleet'), 'aal2', 'ops_do', 'checkin_do', '{"op": "switch", "booking": "XCI-SHORT", "mode": "on"}')$$);
select test.eq('...on', app.checkin_why(test.xci_b('XCI-SHORT')), 'switched_on');
select test.lives('a visit started now (the renter dropped by)', $$select public.door(test.id('xci_fleet'), 'aal2', 'ops_do', 'checkin_do', '{"op": "start", "booking": "XCI-SHORT"}')$$);
select test.throws('skipping needs the reason', format($$select public.door(test.id('xci_fleet'), 'aal2', 'ops_do', 'checkin_do', jsonb_build_object('op', 'skip', 'id', %L))$$, (test.xci_v('XCI-SHORT')).id), 'Say why');
select test.lives('switched off', $$select public.door(test.id('xci_admin'), 'aal2', 'ops_do', 'checkin_do', '{"op": "switch", "booking": "XCI-SHORT", "mode": "off"}')$$);
select test.eq('off, and the open visit closes', coalesce(app.checkin_why(test.xci_b('XCI-SHORT')), 'off') || '/' || (test.xci_v('XCI-SHORT')).status, 'off/cancelled');

-- ================================================================ 6. the follow-up, the rules of the tables
update checkin_visits set due_on = app.today(), status = 'due' where id = (test.xci_v('XCI-LONG')).id;
insert into checkin_visits (booking_id, vehicle_id, due_on) select id, vehicle_id, app.today() - 1 from bookings where booking_number = 'XCI-LONG' on conflict do nothing;
select test.eq('only one open visit a booking', (select count(*) from checkin_visits where booking_id = (test.xci_b('XCI-LONG')).id and status in ('due', 'booked')), 1::bigint);
select test.lives('the follow-up sweep', $$select app.checkin_sweep()$$);
select test.eq('one gentle follow-up', (select count(*) from app_events where code = 'renter_checkin_followup' and entity_id = (test.xci_b('XCI-LONG')).id), 1::bigint);
select app.checkin_sweep();
select test.eq('...never a second', (select count(*) from app_events where code = 'renter_checkin_followup' and entity_id = (test.xci_b('XCI-LONG')).id), 1::bigint);
select test.ok('row-level security, admin_all and the audit trigger on both tables',
  (select bool_and(c.relrowsecurity) from pg_class c where c.relname in ('checkin_visits', 'checkin_booking_switch'))
  and (select count(*) from pg_policies where tablename in ('checkin_visits', 'checkin_booking_switch') and policyname = 'admin_all') = 2
  and (select count(*) from pg_trigger where tgname in ('audit_checkin_visits', 'audit_checkin_booking_switch')) = 2);
select test.ok('the new functions are the server''s alone, with pg_temp last on the search path',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where p.proname ~ '^(server_)?checkin_' and n.nspname in ('app', 'public')
               and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')
                    or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%pg\_temp')))
);
