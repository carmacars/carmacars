-- 18: the staff and investor portals (migration 0031). Every fixture label starts with "sp".
-- Uses the request helpers of 06 (test.rq_new, test.b) and the operations helpers of 09
-- (test.op_confirm, test.op_photos, test.op_deposit_payment).
select test.suite('18 staff and investor portals');

select test.mk_user('sp_admin', 'admin');
select test.mk_user('sp_cs', 'va', 'cs');
select test.mk_user('sp_fin', 'va', 'finance');
select test.mk_user('sp_fleet', 'va', 'fleet');
select test.mk_user('sp_sales', 'va', 'sales');
select test.mk_user('sp_field', 'field', null, 'driver');
select test.mk_user('sp_field2', 'field', null, 'driver');
select test.mk_user('sp_inv', 'renter');
select test.mk_user('sp_inv2', 'renter');
select test.mk_owner('sp_o');
select test.mk_vehicle('spV', 'sp_o');
select test.mk_vehicle('spW', 'sp_o');
select test.mk_renter('sp_r');
select test.mk_renter('sp_r2');

-- a request near now (the field window is 36 hours), and a confirmed booking ready for handover
create function test.sp_local(p interval) returns text language sql stable as $$
  select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:00') $$;
select test.rq_new('spA', 'sp_r', 'spV', test.sp_local(interval '3 hours'), test.sp_local(interval '2 days 3 hours'));
select test.rq_new('spB', 'sp_r2', 'spW', test.sp_local(interval '5 days'), test.sp_local(interval '8 days'));

-- ---------------------------------------------------------------- 1. the door
select test.eq('door: roles route an assistant, a field staff member and an Admin',
  (public.my_roles(test.id('sp_cs')) ->> 'va') || '/' || (public.my_roles(test.id('sp_field')) ->> 'field') || '/' || (public.my_roles(test.id('sp_admin')) ->> 'admin'), 'cs/true/true');
select test.throws('door: anonymous callers have no execute right', $$set local role anon; select public.door(null, null, 'roles', null)$$, 'permission denied');
select test.throws('door: a signed-in browser session has none either', $$set local role authenticated; select public.door(null, null, 'roles', null)$$, 'permission denied');
select test.eq('door: the user and the assurance level become the session''s',
  (select public.door(test.id('sp_cs'), 'aal2', 'roles', null) is not null)::text || '/' || auth.uid()::text || '/' || app.session_aal(), 'true/' || test.id('sp_cs') || '/aal2');
update program_settings set require_staff_two_step = true;
select test.throws('door: with the two-step switch on, a staff session without the second factor is refused',
  format($$select public.door(%L, 'aal1', 'va_read', 'digest')$$, test.id('sp_cs')), 'Two-step sign-in is required');
select test.eq('door: with the second factor it passes, and the guards see an Admin as an Admin',
  (select (public.door(test.id('sp_admin'), 'aal2', 'admin_read', 'dashboard') ? 'requests')::text || '/' || app.is_admin()::text), 'true/true');
select test.eq('door: a customer is not staff, so the switch does not apply to them',
  (public.door(test.id('sp_r'), 'aal1', 'roles', null) ->> 'renter'), 'true');
update program_settings set require_staff_two_step = false;
select test.throws('door: an assistant still cannot use the admin calls', format($$select public.door(%L, null, 'admin_read', 'dashboard')$$, test.id('sp_cs')), 'Only an Admin');

-- ---------------------------------------------------------------- 2. assistants: lists and screens
select test.throws('va: a table outside the function is refused', format($$select public.door(%L, null, 'va_list', 'payments')$$, test.id('sp_cs')), 'does not list');
select test.throws('va: Fleet does not list payments', format($$select public.door(%L, null, 'va_list', 'payments')$$, test.id('sp_fleet')), 'does not list');
select test.eq('va: the task list is the function''s own queue, whatever filter is asked',
  (select coalesce(string_agg(distinct x ->> 'queue', ','), 'none') from jsonb_array_elements(public.door(test.id('sp_cs'), null, 'va_list', 'tasks', '{"eq": {"queue": "finance"}}') -> 'rows') x), 'cs');
select test.eq('va: the queue holds the new request task', (select count(*) from jsonb_array_elements(public.door(test.id('sp_cs'), null, 'va_read', 'queue')) x
  where x ->> 'booking_id' = test.b('spA')::text and x ->> 'task_type' = 'booking_request'), 1::bigint);
select test.eq('va: the digest counts the queue', (public.door(test.id('sp_cs'), null, 'va_read', 'digest') ->> 'open')::integer >= 1, true);
select test.eq('va: Fleet sees a booking without money and with the renter''s first name',
  (select (b ? 'payments')::text || '/' || (b -> 'renter' ->> 'legal_name') from public.door(test.id('sp_fleet'), null, 'va_read', 'booking', jsonb_build_object('id', test.b('spA'))) b), 'false/Sp');
select test.eq('va: customer service sees the request queue', (select count(*) from jsonb_array_elements(public.door(test.id('sp_cs'), null, 'va_read', 'requests')) x
  where x ->> 'id' = test.b('spA')::text), 1::bigint);
select test.throws('va: Finance does not work requests', format($$select public.door(%L, null, 'va_read', 'requests')$$, test.id('sp_fin')), 'customer service and sales');

-- ---------------------------------------------------------------- 3. assistants: actions
select test.throws('va: no per-booking price override for an assistant',
  format($$select public.door(%L, null, 'va_do', 'booking_save', jsonb_build_object('booking', %L, 'changes', '{"daily_rate_cents": 100}'::jsonb))$$, test.id('sp_cs'), test.b('spA')), 'Only an Admin changes daily rate cents');
select test.throws('va: an offer open longer than 48 hours is refused',
  format($$select public.door(%L, null, 'va_do', 'send_offer', jsonb_build_object('booking', %L, 'expires_at', now() + interval '72 hours', 'sales_choice', 'for_carmacars'))$$, test.id('sp_cs'), test.b('spA')), '48 hours');
create temp table sp_offer as select public.door(test.id('sp_cs'), null, 'va_do', 'send_offer', jsonb_build_object('booking', test.b('spA'), 'message', 'Here is your offer.', 'expires_at', now() + interval '24 hours', 'sales_choice', 'for_carmacars')) as r;
select test.eq('va: customer service sends the offer through the rules of 0016, as the actor',
  (select (r ->> 'version') from sp_offer) || '/' || (select status::text from bookings where id = test.b('spA'))
     || '/' || (select (sent_by = test.id('sp_cs'))::text from booking_offers where booking_id = test.b('spA') order by version desc limit 1), '1/offered/true');
select test.throws('va: an action outside the function is refused with the way forward',
  format($$select public.door(%L, null, 'va_do', 'payout_approve', '{}')$$, test.id('sp_fin')), 'send it for approval or escalate');
select test.throws('va: Sales works only on requests and offers',
  format($$select public.door(%L, null, 'va_do', 'ask_info', jsonb_build_object('booking', %L, 'question', 'x'))$$, test.id('sp_sales'), test.id('booking:nope')), 'Booking not found');
update program_settings set staff_blocked_terms = array['Acme Insurance'];
select test.throws('va: a message naming a blocked term is refused',
  format($$select public.door(%L, null, 'va_do', 'send_message', jsonb_build_object('booking', %L, 'body', 'Your cover is with acme insurance.'))$$, test.id('sp_cs'), test.b('spA')), 'may not name');
create temp table sp_msg as select public.door(test.id('sp_cs'), null, 'va_do', 'send_message', jsonb_build_object('booking', test.b('spA'), 'body', 'Thanks, we have it.')) as r;
select test.eq('va: a reply is kept on the booking, sent by the assistant',
  (select (r ? 'id')::text from sp_msg) || '/' || (select count(*) from messages where booking_id = test.b('spA') and sent_by = test.id('sp_cs')), 'true/1');
update program_settings set staff_blocked_terms = '{}';

-- confirmed and ready: the refund and the field job work on it
select test.op_confirm('spA', 'sp_r');
create temp table sp_ref as select public.door(test.id('sp_fin'), null, 'va_do', 'request_refund', jsonb_build_object('booking', test.b('spA'), 'amount_cents', 5000, 'reason', 'goodwill', 'note', 'late car')) as r;
select test.eq('va: a refund above the Finance limit is a request with an Admin task',
  (select (r ->> 'needs_admin') || '/' || (select status from refunds where id = (r ->> 'id')::uuid)
     || '/' || (select queue || ':' || task_type || ':' || escalated from tasks where related_table = 'refunds' and related_id = (r ->> 'id')::uuid) from sp_ref),
  'true/pending_approval/admin:approve_refund:true');
select test.throws('va: the assistant cannot approve it', format($$select public.door(%L, null, 'va_do', 'refund_approve', jsonb_build_object('id', %L))$$,
  test.id('sp_fin'), (select id from refunds where booking_id = test.b('spA') limit 1)), 'needs an Admin');
select public.door(test.id('sp_admin'), null, 'admin_do', 'refund_approve', jsonb_build_object('id', (select id from refunds where booking_id = test.b('spA') limit 1)));
select test.eq('va: the Admin''s approval closes the approval task',
  (select status from tasks where related_table = 'refunds' and related_id = (select id from refunds where booking_id = test.b('spA') limit 1)), 'done');

select test.throws('va: customer service does not dispatch field jobs',
  format($$select public.door(%L, null, 'va_do', 'field_job_create', jsonb_build_object('booking', %L, 'kind', 'handover', 'vehicle', %L, 'scheduled_at', now()))$$,
         test.id('sp_cs'), test.b('spA'), test.id('vehicle:spV')), 'cannot field job create');
create temp table sp_job as select (public.door(test.id('sp_fleet'), null, 'va_do', 'field_job_create', jsonb_build_object('booking', test.b('spA'), 'kind', 'handover',
  'vehicle', test.id('vehicle:spV'), 'scheduled_at', (select pickup_at from bookings where id = test.b('spA')), 'place', '1 Front St W, Toronto')) ->> 'id')::uuid as id;
select public.door(test.id('sp_fleet'), null, 'va_do', 'field_job_assign', jsonb_build_object('id', (select id from sp_job), 'to', test.id('sp_field')));
select test.eq('va: Fleet creates and assigns the job', (select assigned_to from field_jobs where id = (select id from sp_job)), test.id('sp_field'));
select test.eq('va: the fleet board lists the field staff', (select count(*) from jsonb_array_elements(public.door(test.id('sp_fleet'), null, 'va_read', 'fleet_board') -> 'staff') x
  where x ->> 'id' = test.id('sp_field')::text), 1::bigint);

-- ---------------------------------------------------------------- 4. field staff
select test.eq('field: only their own jobs', (public.door(test.id('sp_field2'), null, 'field_read', 'job', jsonb_build_object('id', (select id from sp_job))) is null), true);
select test.throws('field: another person''s job cannot be touched',
  format($$select public.door(%L, null, 'field_do', 'acknowledge', jsonb_build_object('job', %L))$$, test.id('sp_field2'), (select id from sp_job)), 'not one of yours');
select test.eq('field: the job shows the ready check, the deposit status and the photo list',
  (select (j -> 'ready' ->> 'identity') || '/' || (j -> 'ready' ->> 'deposit') || '/' || jsonb_array_length(j -> 'shots') || '/' || (j ->> 'report_kind')
     from public.door(test.id('sp_field'), null, 'field_read', 'job', jsonb_build_object('id', (select id from sp_job))) j), 'true/not_taken/19/pickup');
select public.door(test.id('sp_field'), null, 'field_do', 'acknowledge', jsonb_build_object('job', (select id from sp_job)));
select public.door(test.id('sp_field'), null, 'field_do', 'start', jsonb_build_object('job', (select id from sp_job)));
select test.eq('field: saving the photos reports what is still missing',
  (select jsonb_array_length(r -> 'problems') > 0 from public.door(test.id('sp_field'), null, 'field_do', 'save_report', jsonb_build_object('job', (select id from sp_job),
     'report', jsonb_build_object('odometer_km', 20000, 'fuel_pct', 100, 'photos', (select jsonb_agg(x) from jsonb_array_elements(test.op_photos('pickup')) x where (x ->> 'seq')::int < 5)))) r), true);
select test.throws('field: the handover is refused while the Deposit is not taken',
  format($$select public.door(%L, null, 'field_do', 'complete_handover', jsonb_build_object('job', %L, 'report', jsonb_build_object('photos', test.op_photos('pickup'))))$$,
         test.id('sp_field'), (select id from sp_job)), 'Deposit');
select app.record_deposit_taken(test.b('spA'), test.op_deposit_payment('spA'), test.id('sp_fin'));
select test.throws('field: the phone cannot claim the Tracker is reporting',
  format($$select public.door(%L, null, 'field_do', 'complete_handover', jsonb_build_object('job', %L, 'report', jsonb_build_object('keys_count', 2, 'licence_seen', true, 'card_seen', true, 'renter_present', true,
           'tracker_reporting', true, 'renter_signature_ref', 'sig/r', 'staff_signature_ref', 'sig/s', 'photos', test.op_photos('pickup'))))$$, test.id('sp_field'), (select id from sp_job)), 'Tracker');
insert into tracker_devices (id, serial_number, vehicle_id, status, installed_at, tested_at) values (test.id('trk:spV'), 'SP-TRK-1', test.id('vehicle:spV'), 'installed', now(), now());
insert into tracker_status (tracker_device_id, reported_at, speed_kmh, ignition_on) values (test.id('trk:spV'), now(), 0, false);
create temp table sp_ho as select public.door(test.id('sp_field'), null, 'field_do', 'complete_handover', jsonb_build_object('job', (select id from sp_job), 'report', jsonb_build_object('keys_count', 2,
       'licence_seen', true, 'card_seen', true, 'renter_present', true, 'renter_signature_ref', 'sig/r', 'staff_signature_ref', 'sig/s', 'photos', test.op_photos('pickup')))) r;
select test.eq('field: the full handover puts the booking on rent and closes the job',
  (select r ->> 'booking_status' from sp_ho) || '/' || (select status from field_jobs where id = (select id from sp_job)), 'on_rent/done');

-- the return, late, with new damage
set session_replication_role = replica;
update bookings set pickup_at = now() - interval '2 days 3 hours', handed_over_at = now() - interval '2 days 3 hours', return_at = now() - interval '3 hours' where id = test.b('spA');
set session_replication_role = origin;
create temp table sp_ret as select (public.door(test.id('sp_fleet'), null, 'va_do', 'field_job_create', jsonb_build_object('booking', test.b('spA'), 'kind', 'return_check_in',
  'vehicle', test.id('vehicle:spV'), 'scheduled_at', now() - interval '3 hours', 'assigned_to', test.id('sp_field'), 'place', '1 Front St W, Toronto')) ->> 'id')::uuid as id;
select test.eq('field: the return job shows the pickup readings to compare',
  (public.door(test.id('sp_field'), null, 'field_read', 'job', jsonb_build_object('id', (select id from sp_ret))) -> 'pickup' ->> 'odometer_km'), '20000');
create temp table sp_rt as select public.door(test.id('sp_field'), null, 'field_do', 'complete_return', jsonb_build_object('job', (select id from sp_ret), 'report', jsonb_build_object(
       'odometer_km', 20450, 'fuel_pct', 75, 'keys_count', 2, 'cleanliness', 'clean', 'renter_present', true, 'renter_signature_ref', 'sig/r2', 'staff_signature_ref', 'sig/s2',
       'damages', jsonb_build_array(jsonb_build_object('label', 'D1', 'location', 'rear bumper', 'description', 'scratch 10 cm', 'is_new', true, 'kind', 'scratch', 'size_cm', 10,
                                                       'position', jsonb_build_object('x', 0.5, 'y', 0.95))),
       'photos', test.op_photos('return') || jsonb_build_array(jsonb_build_object('seq', 20, 'shot', 'damage_closeup', 'damage_label', 'D1', 'storage_path', 'bookings/sp/return/20-d1.jpg'))))) r;
select test.eq('field: the late return with new damage: returned, minutes late, an incident',
  (select r ->> 'booking_status' from sp_rt) || '/' || ((select minutes_late from bookings where id = test.b('spA')) >= 170)::text
     || '/' || (select count(*) from incidents where booking_id = test.b('spA') and kind = 'damage_at_return'), 'returned/true/1');
create temp table sp_mv as select public.door(test.id('sp_field'), null, 'field_do', 'move_start', jsonb_build_object('vehicle', test.id('vehicle:spV'), 'purpose', 'other', 'from_place', 'Lot A')) ->> 'move_id' as id;
select public.door(test.id('sp_field'), null, 'field_do', 'move_end', jsonb_build_object('move', (select id from sp_mv), 'to_place', 'Lot B', 'odometer', 20460));
select test.eq('field: a vehicle move starts and ends on a car of their jobs',
  (select from_place || '>' || to_place || '/' || (ended_at is not null) from vehicle_moves where id = (select id::uuid from sp_mv)), 'Lot A>Lot B/true');
select test.throws('field: a car of nobody''s job is not theirs to move',
  format($$select public.door(%L, null, 'field_do', 'move_start', jsonb_build_object('vehicle', %L))$$, test.id('sp_field'), test.id('vehicle:spW')), 'one of your jobs');

-- ---------------------------------------------------------------- 5. investors
insert into investors (id, user_id, legal_name, investor_type, status, email) values
  (test.id('inv:1'), test.id('sp_inv'), 'Ivy Investor', 'individual', 'active', 'sp_inv@example.test'),
  (test.id('inv:2'), test.id('sp_inv2'), 'Otto Other', 'individual', 'active', 'sp_inv2@example.test');
insert into documents (id, kind, storage_bucket, storage_path) values (test.id('doc:spc'), 'other', 'documents', 'x/c.pdf'), (test.id('doc:spd'), 'other', 'documents', 'x/d.pdf');
insert into investment_agreements (id, investor_id, agreement_number, status, schedule_c_document_id, schedule_d_document_id, exemption_category, legal_advice_choice)
values (test.id('agr:1'), test.id('inv:1'), 'IA-SP-1', 'signed', test.id('doc:spc'), test.id('doc:spd'), 'accredited_investor', 'declined'),
       (test.id('agr:2'), test.id('inv:2'), 'IA-SP-2', 'signed', test.id('doc:spc'), test.id('doc:spd'), 'accredited_investor', 'declined');
insert into investments (id, investor_id, agreement_id, is_initial, principal_cents, yearly_bps, investment_date, lockup_end_date) values
  (test.id('ivt:1'), test.id('inv:1'), test.id('agr:1'), true, 2500000, 1200, date '2026-01-05', date '2026-07-05'),
  (test.id('ivt:2'), test.id('inv:2'), test.id('agr:2'), true, 9900000, 1200, date '2026-01-05', date '2026-07-05');
insert into investment_returns (investment_id, return_month, opening_invested_cents, yearly_bps, days_earning, days_in_month, return_cents, disposition, payment_date, closing_invested_cents)
values (test.id('ivt:1'), date '2026-08-01', 2500000, 1200, 31, 31, 25479, 'pay', date '2026-09-15', 2500000),
       (test.id('ivt:2'), date '2026-08-01', 9900000, 1200, 31, 31, 100898, 'pay', date '2026-09-15', 9900000);
select test.throws('investor: someone who is not an investor is refused', format($$select public.door(%L, null, 'investor_read', 'home')$$, test.id('sp_r')), 'for investors');
select test.eq('investor: only their own investments and statements',
  (select jsonb_array_length(h -> 'investments') || '/' || (h -> 'investments' -> 0 ->> 'principal_cents') || '/'
          || jsonb_array_length(public.door(test.id('sp_inv'), null, 'investor_read', 'statements'))
     from public.door(test.id('sp_inv'), null, 'investor_read', 'home') h), '1/2500000/1');
select test.eq('investor: another investor''s statement reads as nothing',
  (public.door(test.id('sp_inv'), null, 'investor_read', 'statement',
     jsonb_build_object('id', (select r.id from investment_returns r where r.investment_id = test.id('ivt:2')))) is null), true);
create temp table sp_iq as select public.door(test.id('sp_inv'), null, 'investor_do', 'election_change', '{"mode": "reinvest"}') r;
select test.eq('investor: a request is an Admin task, never a change',
  (select queue || ':' || task_type from tasks where id = (select (r ->> 'task_id')::uuid from sp_iq)) || '/' || (select count(*) from investment_elections where agreement_id = test.id('agr:1')), 'admin:investor_request/0');
select test.throws('investor: a transfer request names one of their own investments',
  format($$select public.door(%L, null, 'investor_do', 'transfer_request', jsonb_build_object('investment', %L, 'to_name', 'X'))$$, test.id('sp_inv'), test.id('ivt:2')), 'one of your investments');
