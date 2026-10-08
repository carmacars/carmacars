-- 09: operations (migration 0020). Pickup and return with the photo list, a late return, mileage
-- overage, damage under and over the deductible, the renter's statement and the Deposit, field
-- jobs and vehicle moves, the calendar (new entry types, preview and apply), rates and fees,
-- every task trigger, the scheduled jobs, incidents, swap, tracker disable, reconciliation, and
-- row-level security for each role on each new table and view.
--
-- The amounts are the examples of docs/source/renter_billing_spec.md: daily $100, weekend $120,
-- weekly $560, monthly $1,800 (section 2), with the catalogue of section 1: $0.35 per km,
-- late return $25 per started hour and the daily rate per extra day, fuel at pump price plus 25%
-- plus $25, cleaning $75, administration $50 or $75, deductible $2,500, Deposit $1,000 (premium).
select test.suite('09 operations');

-- ------------------------------------------------------------------ helpers and fixture
create or replace function test.at(p_local text) returns timestamptz
language sql immutable as $$ select p_local::timestamp at time zone 'America/Toronto' $$;

-- the 19 required photos in the fixed order, optionally without one shot
create function test.op_photos(p_kind text, p_skip text default null) returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object('seq', r.seq, 'shot', r.shot, 'storage_path', 'bookings/op/' || p_kind || '/' || r.seq || '-' || r.shot || '.jpg',
                                      'width', 2400, 'height', 1600) order by r.seq)
    from app.required_shots_for(p_kind, 'premium') r where r.shot is distinct from p_skip
$$;

-- a request through to "ready to confirm" (helpers of 06), then confirmed, with a verified
-- driver and a confirmed Coverage Option: everything procedure 2 leaves behind
create function test.op_confirm(p_key text, p_renter text, p_verify boolean default true) returns void language plpgsql as $$
begin
  perform test.rq_ready(p_key);
  update bookings set status = 'confirmed' where id = test.b(p_key);
  if p_verify then
    insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_expiry,
                                 age_at_pickup, age_band, identity_method, identity_verified_on)
    values (test.b(p_key), test.id('driver:' || p_renter), 'renter', initcap(p_renter), date '1990-05-05', 'L1', 'G', date '2035-01-01',
            40, '26_plus', 'staff_review', date '2031-01-01');
    insert into coverage_proofs (booking_id, coverage_option, status, card_issuer, card_last4, confirmed_at)
    values (test.b(p_key), 2, 'confirmed', 'Bank', '4242', now());
    update bookings set coverage_option = 2, coverage_confirmed_at = now() where id = test.b(p_key);
  end if;
end $$;

-- the Deposit payment the server would have placed: a hold (7 days or less) or a charge
create function test.op_deposit_payment(p_key text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
  select v_id, b.id, b.renter_id, 'deposit', case when b.billable_days <= 7 then 'hold' else 'charge' end, 'card', b.deposit_cents,
         case when b.billable_days <= 7 then 'authorized' else 'succeeded' end, now()
    from bookings b where b.id = test.b(p_key);
  return v_id;
end $$;

-- the whole handover, as the checklist would send it
create function test.op_handover(p_key text, p_by text, p_at text, p_odometer integer default 20000) returns uuid language sql as $$
  select app.complete_handover(test.b(p_key), test.id(p_by),
    jsonb_build_object('odometer_km', p_odometer, 'fuel_pct', 100, 'keys_count', 2, 'licence_seen', true, 'card_seen', true,
                       'tracker_reporting', true, 'renter_signature_ref', 'sig/renter', 'staff_signature_ref', 'sig/staff',
                       'photos', test.op_photos('pickup'), 'deposit_payment_id', test.op_deposit_payment(p_key)),
    null, test.at(p_at))
$$;
create function test.op_return(p_key text, p_by text, p_at text, p_odometer integer, p_extra jsonb default '{}') returns jsonb language sql as $$
  select app.complete_return(test.b(p_key), test.id(p_by),
    jsonb_build_object('odometer_km', p_odometer, 'fuel_pct', 100, 'keys_count', 2, 'cleanliness', 'clean',
                       'renter_signature_ref', 'sig/renter-in', 'staff_signature_ref', 'sig/staff-in', 'photos', test.op_photos('return')) || p_extra,
    null, test.at(p_at))
$$;
create function test.op_line(p_key text, p_assessment text) returns text language sql stable as $$
  select amount_cents || '+' || hst_cents || ':' || revenue_class from booking_line_items
   where booking_id = test.b(p_key) and assessment_key = p_assessment and voided_at is null
$$;
create function test.op_tasks(p_key text, p_type text) returns text language sql stable as $$
  select count(*) || ':' || coalesce(min(queue), '-') || ':' || coalesce(min(priority), '-') from tasks where booking_id = test.b(p_key) and task_type = p_type
$$;
create function test.op_events(p_code text, p_entity uuid) returns bigint language sql stable as $$
  select count(*) from app_events where code = p_code and entity_id = p_entity
$$;
grant execute on all functions in schema test to authenticated, anon;

select test.mk_user('op_admin', 'admin');
select test.mk_user('op_admin2', 'admin');
select test.mk_user('op_fin', 'va', 'finance');
select test.mk_user('op_fleet', 'va', 'fleet');
select test.mk_user('op_cs', 'va', 'cs');
select test.mk_user('op_sales', 'va', 'sales');
select test.mk_user('op_field', 'field', null, 'driver');
select test.mk_user('op_field2', 'field', null, 'detailer');
select test.mk_owner('op_owen');
select test.mk_owner('op_pat');
select test.mk_vehicle(v, 'op_owen') from unnest(array['OP1', 'OP2', 'OP3', 'OP4', 'OP5', 'OP6', 'OP7']) v;
select test.mk_vehicle('OP8', 'op_pat');
select test.mk_vehicle('OPT', 'op_pat', 'turo_only', 0, 0, 2500);
select test.mk_renter(r) from unnest(array['op_r1', 'op_r2', 'op_r3', 'op_r4', 'op_r5', 'op_r6', 'op_r7']) r;

-- ------------------------------------------------------------------ structure
select test.eq('S the seven new tables have row-level security, the admin policy and an audit trigger',
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname in ('required_shots', 'vehicle_moves', 'task_rules', 'quick_replies', 'incident_steps',
                                                 'payout_reconciliations', 'payout_reconciliation_items')
      and c.relrowsecurity
      and exists (select 1 from pg_policies p where p.tablename = c.relname and p.policyname = 'admin_all')
      and exists (select 1 from pg_trigger g where g.tgrelid = c.oid and g.tgname = 'audit_' || c.relname)), 7::bigint);
select test.eq('S vehicle_moves has the columns the toll matcher reads',
  (select count(*) from information_schema.columns where table_name = 'vehicle_moves'
     and column_name in ('vehicle_id', 'staff_user_id', 'purpose', 'started_at', 'ended_at', 'from_place', 'to_place', 'odometer_start', 'odometer_end')), 9::bigint);
select test.eq('S no function of this migration that changes state is executable from a browser session',
  (select string_agg(p.proname, ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))
      and p.proname in ('complete_handover', 'complete_return', 'save_condition_report', 'record_deposit_taken', 'record_deposit_declined',
        'waive_deposit', 'assess_check_in', 'issue_booking_statement', 'settle_deposit', 'post_rental_payment_result', 'set_assessed_line',
        'create_field_job', 'assign_field_job', 'accept_field_job', 'start_field_job', 'complete_field_job', 'cancel_field_job', 'reschedule_field_job',
        'start_vehicle_move', 'end_vehicle_move', 'calendar_apply_change', 'set_rate_card', 'set_vehicle_fee_override', 'set_booking_fee_term',
        'apply_bulk_rate_change', 'preview_bulk_rate_change', 'raise_task', 'complete_task', 'assign_task', 'snooze_task', 'escalate_task',
        'open_incident', 'swap_vehicle', 'request_tracker_disable', 'approve_tracker_disable', 'record_processor_payout', 'match_payout_item',
        'job_deposits_due', 'job_ops_watch', 'job_expiry_watch', 'job_reconcile', 'record_late_damage', 'submit_return_findings')), null::text);
select test.eq('S the server may run every function', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and not has_function_privilege('service_role', p.oid, 'execute')), 0::bigint);
select test.eq('S the anonymous role still reads exactly one thing',
  (select string_agg(table_name || ':' || privilege_type, ',') from information_schema.role_table_grants where table_schema = 'public' and grantee = 'anon'),
  'public_vehicle_listings:SELECT');
select test.eq('S 19 photos are required at pickup and at return, 4 after detailing, in the order of procedure 3',
  (select count(*) || '/' || min(shot) filter (where seq = 1) || '/' || min(shot) filter (where seq = 19) from app.required_shots_for('pickup', 'premium'))
  || ' ' || (select count(*) from app.required_shots_for('return', 'suv')) || ' ' || (select string_agg(shot, ',' order by seq) from app.required_shots_for('ready', 'premium')),
  '19/front/keys 19 front,rear,front_seats,instrument_cluster');
insert into required_shots (report_kind, vehicle_class, seq, shot, is_required) values ('pickup', 'exotic', 18, 'trunk', false);
select test.eq('S a vehicle class can have its own list: no trunk photo on an exotic', (select count(*) from app.required_shots_for('pickup', 'exotic')), 18::bigint);

-- opening hours: 0025, the business is always open (opening_hours.always_open)
select test.eq('O 15 opening minutes from 10:00 is 10:15', app.add_opening_minutes(test.at('2031-03-03 10:00'), 15), test.at('2031-03-03 10:15'));
select test.eq('O (0025) always open: 15 opening minutes from 22:00 is 22:15', app.add_opening_minutes(test.at('2031-03-03 22:00'), 15), test.at('2031-03-03 22:15'));
select test.eq('O (0025) always open: 30 opening minutes from 17:50 is 18:20', app.add_opening_minutes(test.at('2031-03-03 17:50'), 30), test.at('2031-03-03 18:20'));

-- ------------------------------------------------------------------ confirmation: jobs, tasks, fee terms
-- A: Thursday 10:00 to Sunday 10:00, the renter collects. B: the same days on another car, delivered and collected by staff.
select test.rq_new('opA', 'op_r1', 'OP1', '2031-05-01 10:00', '2031-05-04 10:00');
insert into test.rq_ids values ('opB', app.request_booking(test.id('renter:op_r2'), test.id('vehicle:OP2'), test.at('2031-05-01 10:00'), test.at('2031-05-04 10:00'),
  'standard', null, 'phone', test.id('rq_cs'), null, null, 'delivered', 'picked_up', '12 Elm St, Toronto', '12 Elm St, Toronto'));
select test.eq('C the spec''s first example: Thursday to Sunday is $100 + $120 + $120 = $340',
  (select rental_charge_cents || '/' || deposit_cents from bookings where id = test.b('opA')), '34000/100000');
select test.eq('C the new request task takes its queue, priority and due time from its rule (0025: the 2-hour reply target)',
  (select queue || '/' || priority || '/' || sla_minutes || '/' || (due_at is not null) || '/' || completion_rule from tasks
    where booking_id = test.b('opA') and task_type = 'booking_request'), 'cs/high/120/true/offer_sent_or_declined');
select test.op_confirm('opA', 'op_r1');
select test.op_confirm('opB', 'op_r2');
select test.eq('C a confirmed booking the renter collects gets no automatic job', (select count(*) from field_jobs where booking_id = test.b('opA')), 0::bigint);
select test.eq('C a confirmed booking with delivery gets a delivery job and a pickup job, unassigned, at the booking''s times and place',
  (select string_agg(kind || '@' || to_char(scheduled_at at time zone 'America/Toronto', 'MM-DD HH24:MI') || ':' || place || ':' || auto_created
                     || ':' || (assigned_to is null), ' ' order by scheduled_at) from field_jobs where booking_id = test.b('opB')),
  'delivery@05-01 10:00:12 Elm St, Toronto:true:true pickup_from_renter@05-04 10:00:12 Elm St, Toronto:true:true');
select test.eq('C creating those jobs emits no event (nobody is assigned yet)',
  (select count(*) from app_events e join field_jobs j on j.id = e.entity_id where j.booking_id = test.b('opB')), 0::bigint);
select test.eq('C confirmation asks Fleet to schedule the handover (due the day before) and customer service to verify (due 24 hours before)',
  (select string_agg(task_type || ':' || queue || ':' || to_char(due_at at time zone 'America/Toronto', 'MM-DD HH24:MI') || ':' || procedure_no, ' ' order by task_type)
     from tasks where booking_id = test.b('opA') and task_type in ('schedule_handover', 'offer_approved_paid')),
  'offer_approved_paid:cs:04-30 10:00:2 schedule_handover:fleet:04-30 10:00:3');
select test.eq('C the fee terms that apply are written on the booking at confirmation',
  (select string_agg(fee_type_code || '=' || coalesce(amount_cents::text, percent_bps || 'bps') || ':' || source, ' ' order by fee_type_code)
     from booking_fee_terms where booking_id = test.b('opA') and fee_type_code in ('cleaning', 'fuel', 'late_return_fee', 'admin_fee_other', 'deposit')),
  'admin_fee_other=5000:default cleaning=7500:default deposit=100000:default fuel=2500bps:default late_return_fee=2500:default');

-- ------------------------------------------------------------------ field jobs: create, assign, reassign, accept, start
select test.throws('F customer service does not dispatch a field job',
  format($$select app.create_field_job('handover', %L, test.at('2031-05-01 10:00'), %L, %L)$$, test.id('vehicle:OP1'), test.id('op_cs'), test.b('opA')), 'Only Fleet or an Admin');
select test.throws('F a handover job belongs to a booking',
  format($$select app.create_field_job('handover', %L, test.at('2031-05-01 10:00'), %L)$$, test.id('vehicle:OP1'), test.id('op_fleet')), 'belongs to a booking');
select test.throws('F a job is assigned to field staff, not to an assistant',
  format($$select app.create_field_job('handover', %L, test.at('2031-05-01 10:00'), %L, %L, %L)$$, test.id('vehicle:OP1'), test.id('op_fleet'), test.b('opA'), test.id('op_cs')), 'active field staff');
insert into test.rq_ids values ('jobA', app.create_field_job('handover', test.id('vehicle:OP1'), test.at('2031-05-01 10:00'), test.id('op_fleet'), test.b('opA'),
  test.id('op_field2'), 'CarmaCars lot', 'Renter collects'));
select test.eq('F assigning a job emits staff_field_job_assigned to the assignee',
  (select count(*) || '/' || (min(payload ->> 'recipient_user_id') = test.id('op_field2')::text) || '/' || min(payload ->> 'job_type') || '/' || min(payload ->> 'customer_first_name')
          || '/' || (min(dedupe_key) like 'staff_field_job_assigned:' || test.b('jobA') || ':%')
     from app_events where code = 'staff_field_job_assigned' and entity_id = test.b('jobA')), '1/true/handover/Op/true');
select test.throws('F the completion rule holds a task open: the handover is scheduled only once someone is assigned',
  format($$select app.complete_task((select id from tasks where booking_id = %L and task_type = 'schedule_handover'), %L)$$, test.b('opB'), test.id('op_fleet')), 'Assign a field staff member');
select app.accept_field_job(test.b('jobA'), test.id('op_field2'));
select app.assign_field_job(test.b('jobA'), test.id('op_field'), test.id('op_fleet'));
select test.eq('F reassigning tells the old assignee (changed) and the new one (assigned), and the job must be accepted again',
  test.op_events('staff_field_job_assigned', test.b('jobA')) || '/'
  || (select count(*) || ':' || (min(payload ->> 'recipient_user_id') = test.id('op_field2')::text) from app_events where code = 'staff_field_job_changed' and entity_id = test.b('jobA'))
  || '/' || (select status || ':' || (acknowledged_at is null) from field_jobs where id = test.b('jobA')), '2/1:true/scheduled:true');
select test.throws('F only the assignee accepts a job', format('select app.accept_field_job(%L, %L)', test.b('jobA'), test.id('op_field2')), 'assigned to accepts');
select app.accept_field_job(test.b('jobA'), test.id('op_field'));
select app.reschedule_field_job(test.b('jobA'), test.id('op_fleet'), test.at('2031-05-01 10:30'), 'CarmaCars lot, bay 2');
select test.eq('F a change of time and place emits staff_field_job_changed with what changed, and asks for a new acknowledgement',
  (select (payload -> 'job_changes')::text || '/' || (payload ->> 'job_cancelled') from app_events where code = 'staff_field_job_changed' and entity_id = test.b('jobA') order by id desc limit 1)
  || '/' || (select status from field_jobs where id = test.b('jobA')), '["time", "place"]/false/scheduled');
select app.reschedule_field_job(test.b('jobA'), test.id('op_fleet'), test.at('2031-05-01 10:00'), 'CarmaCars lot');
select app.accept_field_job(test.b('jobA'), test.id('op_field'));
select test.lives('F the task can be completed now that the handover has an assignee',
  format($$select app.complete_task((select id from tasks where booking_id = %L and task_type = 'schedule_handover'), %L)$$, test.b('opA'), test.id('op_fleet')));
select test.throws('F a handover job is not completed without its checklist',
  format('select app.complete_field_job(%L, %L)', test.b('jobA'), test.id('op_field')), 'Condition Report');

-- ------------------------------------------------------------------ handover (procedure 3)
select test.throws('H a stranger cannot fill the Condition Report',
  format($$select app.save_condition_report(%L, 'pickup', %L, '{}')$$, test.b('opA'), test.id('op_field2')), 'not on a job assigned to you');
select test.throws('H no handover with a photo missing: the roof',
  format($$select app.complete_handover(%L, %L, jsonb_build_object('odometer_km', 20000, 'fuel_pct', 100, 'keys_count', 2, 'licence_seen', true, 'card_seen', true,
           'tracker_reporting', true, 'renter_signature_ref', 's', 'staff_signature_ref', 's', 'photos', test.op_photos('pickup', 'roof'),
           'deposit_payment_id', test.op_deposit_payment('opA')), null, test.at('2031-05-01 10:00'))$$, test.b('opA'), test.id('op_field')), 'missing photo: roof');
select test.eq('H a refused handover leaves nothing behind', (select status::text from bookings where id = test.b('opA'))
  || '/' || (select count(*) from condition_reports where booking_id = test.b('opA')) || '/' || (select count(*) from deposits where booking_id = test.b('opA')), 'confirmed/0/0');
select test.throws('H no handover without the Deposit',
  format($$select app.complete_handover(%L, %L, jsonb_build_object('odometer_km', 20000, 'fuel_pct', 100, 'keys_count', 2, 'licence_seen', true, 'card_seen', true,
           'tracker_reporting', true, 'renter_signature_ref', 's', 'staff_signature_ref', 's', 'photos', test.op_photos('pickup')), null, test.at('2031-05-01 10:00'))$$,
         test.b('opA'), test.id('op_field')), 'Deposit is taken at pickup');
select test.throws('H no handover when the licence was not seen',
  format($$select app.complete_handover(%L, %L, jsonb_build_object('odometer_km', 20000, 'fuel_pct', 100, 'keys_count', 2, 'licence_seen', false, 'card_seen', true,
           'tracker_reporting', true, 'renter_signature_ref', 's', 'staff_signature_ref', 's', 'photos', test.op_photos('pickup'),
           'deposit_payment_id', test.op_deposit_payment('opA')), null, test.at('2031-05-01 10:00'))$$, test.b('opA'), test.id('op_field')), 'original licence');
select test.throws('H no handover without the renter''s signature',
  format($$select app.complete_handover(%L, %L, jsonb_build_object('odometer_km', 20000, 'fuel_pct', 100, 'keys_count', 2, 'licence_seen', true, 'card_seen', true,
           'tracker_reporting', true, 'staff_signature_ref', 's', 'photos', test.op_photos('pickup'),
           'deposit_payment_id', test.op_deposit_payment('opA')), null, test.at('2031-05-01 10:00'))$$, test.b('opA'), test.id('op_field')), 'renter''s signature');
select test.throws('H no handover when the Tracker is not reporting',
  format($$select app.complete_handover(%L, %L, jsonb_build_object('odometer_km', 20000, 'fuel_pct', 100, 'keys_count', 2, 'licence_seen', true, 'card_seen', true,
           'tracker_reporting', false, 'renter_signature_ref', 's', 'staff_signature_ref', 's', 'photos', test.op_photos('pickup'),
           'deposit_payment_id', test.op_deposit_payment('opA')), null, test.at('2031-05-01 10:00'))$$, test.b('opA'), test.id('op_field')), 'Tracker is not in place');
-- the Deposit is declined at pickup
select app.record_deposit_declined(test.b('opA'), null, 'insufficient_funds', test.id('op_fin'), test.at('2031-05-01 09:50'));
select test.eq('H a declined Deposit: the renter is told, an Admin gets an urgent task, the Deposit is marked failed',
  test.op_events('renter_deposit_declined', test.b('opA')) || '/' || test.op_tasks('opA', 'deposit_declined')
  || '/' || (select status from deposits where booking_id = test.b('opA'))
  || '/' || (select payload ->> 'deposit_amount_cents' from app_events where code = 'renter_deposit_declined' and entity_id = test.b('opA')), '1/1:admin:urgent/failed/100000');
select test.eq('H the event''s dedupe key follows the convention',
  (select dedupe_key like 'renter_deposit_declined:' || test.b('opA') || ':%' from app_events where code = 'renter_deposit_declined' and entity_id = test.b('opA')), true);
select test.throws('H stopping the handover needs a reason', format($$select app.block_handover(%L, %L, ' ')$$, test.b('opA'), test.id('op_field')), 'why the handover is stopped');
select app.block_handover(test.b('opA'), test.id('op_field'), 'Licence does not match the booking');
select test.eq('H a stopped handover is an urgent, escalated task for an Admin', (select count(*) || '/' || bool_and(escalated) || '/' || min(priority) || '/' || min(queue)
  from tasks where booking_id = test.b('opA') and task_type = 'handover_blocked'), '1/true/urgent/admin');
select test.throws('H only an Admin waives a Deposit', format($$select app.waive_deposit(%L, %L, 'regular customer')$$, test.b('opB'), test.id('op_fin')), 'Only an Admin');

-- the handover itself: the server passes the hold it just placed
select test.lives('H handover completed', $$select test.op_handover('opA', 'op_field', '2031-05-01 10:05')$$);
select test.eq('H the booking is on rent with the readings, the vehicle is on rent, the job is done',
  (select status || '/' || odometer_out_km || '/' || fuel_out_pct || '/' || (handed_over_at = test.at('2031-05-01 10:05')) from bookings where id = test.b('opA'))
  || ' ' || (select status::text || '/' || odometer_km from vehicles where id = test.id('vehicle:OP1'))
  || ' ' || (select status || '/' || (completed_at = test.at('2031-05-01 10:05')) from field_jobs where id = test.b('jobA')), 'on_rent/20000/100/true on_rent/20000 done/true');
select test.eq('H the Deposit is held on the card hold the server placed (3 days: a hold, not a charge), expiring in 7 days',
  (select d.status || '/' || d.method || '/' || d.amount_cents || '/' || (p.kind = 'hold') || '/' || (d.hold_expires_at = test.at('2031-05-08 10:05'))
          || '/' || (select count(*) from deposit_events e where e.deposit_id = d.id and e.kind = 'taken')
     from deposits d join payments p on p.id = d.hold_payment_id where d.booking_id = test.b('opA')), 'held/card_hold/100000/true/true/1');
select test.eq('H the pickup report is complete, signed, with the 19 photos and their sizes, performed by field staff',
  (select (completed_at is not null) || '/' || performed_by_role || '/' || renter_signature_ref || '/' || (renter_signed_at is not null) || '/'
          || (select count(*) || ':' || min(width) from condition_report_photos p where p.condition_report_id = c.id)
     from condition_reports c where booking_id = test.b('opA') and kind = 'pickup'), 'true/field/sig/renter/true/19:2400');
select test.eq('H the tasks the handover answers are closed, and Fleet is asked to review the photos within the hour',
  (select string_agg(task_type || ':' || status, ' ' order by task_type) from tasks
    where booking_id = test.b('opA') and task_type in ('deposit_declined', 'offer_approved_paid', 'handover_blocked', 'review_photos')),
  'deposit_declined:done handover_blocked:done offer_approved_paid:done review_photos:open');
select test.throws('H a signed report can no longer change',
  format($$select app.save_condition_report(%L, 'pickup', %L, '{"odometer_km": 1}')$$, test.b('opA'), test.id('op_field')), 'signed and can no longer change');
select test.throws('H a booking is handed over once', $$select test.op_handover('opA', 'op_field', '2031-05-01 10:06')$$, 'only a confirmed booking');
select app.review_condition_report((select id from condition_reports where booking_id = test.b('opA') and kind = 'pickup'), test.id('op_fleet'));
select test.eq('H reviewing the pickup photos closes the review task', test.op_tasks('opA', 'review_photos')
  || '/' || (select status from tasks where booking_id = test.b('opA') and task_type = 'review_photos'), '1:fleet:high/done');

-- delivery: the job is started (a vehicle move opens with the driver), then the handover ends it
select app.assign_field_job((select id from field_jobs where booking_id = test.b('opB') and kind = 'delivery'), test.id('op_field'), test.id('op_fleet'));
select app.start_field_job((select id from field_jobs where booking_id = test.b('opB') and kind = 'delivery'), test.id('op_field'), test.at('2031-05-01 09:15'));
select test.eq('M starting a delivery opens a vehicle move with the driver and the start time',
  (select purpose || '/' || (staff_user_id = test.id('op_field')) || '/' || (started_at = test.at('2031-05-01 09:15')) || '/' || (ended_at is null)
     from vehicle_moves where vehicle_id = test.id('vehicle:OP2')), 'delivery/true/true/true');
select test.op_handover('opB', 'op_field', '2031-05-01 10:00', 30000);
select test.eq('M the handover ends the move at the handover time, at the delivery place',
  (select (ended_at = test.at('2031-05-01 10:00')) || '/' || to_place from vehicle_moves where vehicle_id = test.id('vehicle:OP2')), 'true/12 Elm St, Toronto');

-- ------------------------------------------------------------------ return (procedure 4): late, over the allowance, low on fuel, dirty
-- A comes back Sunday 13:10 (190 minutes late) with 750 km driven (600 included), fuel 60%, needing a clean.
insert into test.rq_ids values ('jobAr', app.create_field_job('return_check_in', test.id('vehicle:OP1'), test.at('2031-05-04 10:00'), test.id('op_fleet'), test.b('opA'), test.id('op_field'), 'CarmaCars lot'));
select test.throws('R no return with a photo missing',
  format($$select app.complete_return(%L, %L, jsonb_build_object('odometer_km', 20750, 'fuel_pct', 60, 'keys_count', 2, 'cleanliness', 'cleaning',
           'renter_signature_ref', 's', 'staff_signature_ref', 's', 'photos', test.op_photos('return', 'keys')), null, test.at('2031-05-04 13:10'))$$,
         test.b('opA'), test.id('op_field')), 'missing photo: keys');
select test.throws('R the odometer cannot be lower than at pickup', $$select test.op_return('opA', 'op_field', '2031-05-04 13:10', 19000)$$, 'lower than at pickup');
select test.throws('R the renter signs, or is recorded as declining with the reason',
  format($$select app.complete_return(%L, %L, jsonb_build_object('odometer_km', 20750, 'fuel_pct', 60, 'keys_count', 2, 'cleanliness', 'cleaning',
           'staff_signature_ref', 's', 'photos', test.op_photos('return')), null, test.at('2031-05-04 13:10'))$$, test.b('opA'), test.id('op_field')), 'declined to sign');
create table test.op_out as select test.op_return('opA', 'op_field', '2031-05-04 13:10', 20750,
  '{"fuel_pct": 60, "cleanliness": "cleaning", "renter_signature_ref": null, "renter_declined_to_sign": true, "renter_decline_reason": "disputes the cleaning"}') as r;
select test.eq('R 190 minutes late is one extra day (a part day counts as a full day) and 4 started hours',
  (select (r ->> 'minutes_late') || '/' || (r ->> 'extra_days') || '/' || (r ->> 'late_extra_days_cents') || '/' || (r ->> 'late_fee_cents') from test.op_out), '190/1/10000/10000');
select test.eq('R the findings: 750 km driven, 600 included, 150 over; fuel 40% short',
  (select (r ->> 'km_driven') || '/' || (r ->> 'km_allowance') || '/' || (r ->> 'km_over') || '/' || (r ->> 'fuel_short_pct') || '/' || (r ->> 'cleanliness') from test.op_out),
  '750/600/150/40/cleaning');
select test.eq('R the booking is returned with the Check-in time and readings; the vehicle is in cleaning; the Deposit is due in 7 business days',
  (select status || '/' || (checked_in_at = test.at('2031-05-04 13:10')) || '/' || odometer_in_km || '/' || fuel_in_pct || '/' || minutes_late || '/' || extra_days || '/' || end_reason
     from bookings where id = test.b('opA')) || ' ' || (select status::text from vehicles where id = test.id('vehicle:OP1'))
  || ' ' || (select release_due_on from deposits where booking_id = test.b('opA')), 'returned/true/20750/60/190/1/late_return cleaning 2031-05-13');
select test.eq('R Fleet is asked to review the return photos and to schedule the detail; the return job is done with the cleaning grade',
  test.op_tasks('opA', 'schedule_detail') || ' ' || (select count(*) from tasks where booking_id = test.b('opA') and task_type = 'review_photos' and status = 'open')
  || ' ' || (select status || '/' || cleaning_grade from field_jobs where id = test.b('jobAr')), '1:fleet:normal 1 done/cleaning');
select test.eq('R grace: 30 minutes late costs nothing, 31 minutes costs an extra day and one hour',
  (select extra_days || '/' || late_fee_cents from public.calc_late_return(30, 10000, 2500, 15000, 30)) || ' '
  || (select extra_days || '/' || extra_days_cents || '/' || late_fee_cents from public.calc_late_return(31, 10000, 2500, 15000, 30)), '0/0 1/10000/2500');

-- Fleet confirms the findings: Finance gets the task and the event
select test.throws('R the statement waits for Fleet''s review', format('select app.issue_booking_statement(%L, %L)', test.b('opA'), test.id('op_fin')), 'has not been reviewed');
select test.throws('R Finance does not review photo sets', format('select app.submit_return_findings(%L, %L)', test.b('opA'), test.id('op_fin')), 'Fleet or an Admin');
select app.submit_return_findings(test.b('opA'), test.id('op_fleet'));
select test.eq('R findings confirmed: a finance task due the same day, the T7 note, and staff_return_findings once',
  test.op_tasks('opA', 'price_findings') || '/' || (select count(*) from messages where booking_id = test.b('opA') and template_code = 'T7')
  || '/' || test.op_events('staff_return_findings', test.b('opA'))
  || '/' || (select (payload ->> 'km_over') || ':' || (payload ->> 'minutes_late') || ':' || (payload ->> 'has_damage') from app_events where code = 'staff_return_findings' and entity_id = test.b('opA')),
  '1:finance:normal/1/1/150:190:false');

-- ------------------------------------------------------------------ assessment: the charge lines and who they belong to
select test.throws('A Fleet does not price findings', format('select app.assess_check_in(%L, %L, %L)', test.b('opA'), '{}', test.id('op_fleet')), 'Finance or an Admin');
create table test.op_assess as select app.assess_check_in(test.b('opA'), '{}', test.id('op_fin')) as r;
select test.eq('A without the pump cost the fuel line waits, and the assessment says so', (select r -> 'pending' ->> 0 from test.op_assess), 'fuel: 40% short, enter the pump cost from the receipt');
select app.assess_check_in(test.b('opA'), '{"pump_cost_cents": 4000}', test.id('op_fin'));
select test.eq('A mileage overage: 150 km x $0.35 = $52.50, Owner Revenue, with HST', test.op_line('opA', 'mileage_overage'), '5250+683:owner_revenue');
select test.eq('A late return: one extra day at the daily rate, Owner Revenue', test.op_line('opA', 'late_return_extra_days'), '10000+1300:owner_revenue');
select test.eq('A late return fee: 4 started hours x $25, company only', test.op_line('opA', 'late_return_fee'), '10000+1300:company_only');
select test.eq('A fuel: pump $40 plus 25% = $50, and the $25 service fee, company only',
  test.op_line('opA', 'fuel') || ' ' || test.op_line('opA', 'fuel_service_fee'), '5000+650:company_only 2500+325:company_only');
select test.eq('A cleaning: $75, company only', test.op_line('opA', 'cleaning:cleaning'), '7500+975:company_only');
select test.eq('A every line carries its supporting records: both Condition Reports, and the instrument cluster photos for the mileage',
  (select bool_and(supporting_refs ? 'return_report_id' and supporting_refs ? 'pickup_report_id') || '/' || count(*)
          || '/' || (select jsonb_array_length(supporting_refs -> 'photo_ids') from booking_line_items where booking_id = test.b('opA') and assessment_key = 'mileage_overage')
     from booking_line_items where booking_id = test.b('opA') and assessment_key is not null and voided_at is null), 'true/6/2');
select test.eq('A running the assessment again changes nothing', (select count(*) || '/' || sum(amount_cents) || '/' || sum(hst_cents) from booking_line_items
  where booking_id = test.b('opA') and assessment_key is not null and voided_at is null
    and (select app.assess_check_in(test.b('opA'), '{"pump_cost_cents": 4000}', test.id('op_fin')) is not null)), '6/40250/5233');
select test.eq('A the split follows: Owner Revenue = $340 rental + $100 extra day + $52.50 mileage = $492.50; 35% to CarmaCars',
  (select rental_charge_cents || '/' || mileage_overage_cents || '/' || owner_revenue_cents || '/' || company_share_cents || '/' || company_only_cents
     from booking_splits where booking_id = test.b('opA')), '44000/5250/49250/17238/25000');

-- nothing is hard-coded: an Admin changes a fee on this booking and the line follows
select test.throws('A only an Admin changes a fee on one booking',
  format($$select app.set_booking_fee_term(%L, 'cleaning', %L, 'goodwill', 5000)$$, test.b('opA'), test.id('op_fin')), 'Only an Admin');
select app.set_booking_fee_term(test.b('opA'), 'cleaning', test.id('op_admin'), 'light soiling only', 5000);
select app.assess_check_in(test.b('opA'), '{"pump_cost_cents": 4000}', test.id('op_fin'));
select test.eq('A the cleaning line follows the booking''s own fee term ($50)', test.op_line('opA', 'cleaning:cleaning'), '5000+650:company_only');
select app.set_booking_fee_term(test.b('opA'), 'cleaning', test.id('op_admin'), 'back to the standard fee', 7500);
select app.assess_check_in(test.b('opA'), '{"pump_cost_cents": 4000}', test.id('op_fin'));

-- ------------------------------------------------------------------ statement and Deposit: the plain case
-- Charges $402.50 + HST $52.33 = $454.83. Deposit $1,000: $454.83 applied, $545.17 returned, nothing on the card.
select test.throws('D the Deposit is settled only after the statement', format('select app.settle_deposit(%L, %L)', test.b('opA'), test.id('op_fin')), 'Issue the Check-in statement');
insert into test.rq_ids values ('stA', app.issue_booking_statement(test.b('opA'), test.id('op_fin'), test.at('2031-05-05 11:00')));
select test.eq('D the Check-in statement: charges $402.50, HST $52.33, interest from 7 days later; the finance task is closed',
  (select kind || '/' || charges_cents || '/' || hst_cents || '/' || interest_starts_on || '/' || (statement_number like 'RS-%') from booking_statements where id = test.b('stA'))
  || ' ' || (select status from tasks where booking_id = test.b('opA') and task_type = 'price_findings'), 'check_in/40250/5233/2031-05-12/true done');
select test.throws('D with no new charge there is no second statement', format('select app.issue_booking_statement(%L, %L)', test.b('opA'), test.id('op_fin')), 'no new charge');
-- the finance assistant's Single Limit is $0: the proposal goes to an Admin and nothing moves
create table test.op_settle as select app.settle_deposit(test.b('opA'), test.id('op_fin'), '{}', test.at('2031-05-05 11:30')) as r;
select test.eq('D a finance assistant proposes; the release of $545.17 waits for an Admin and nothing has moved',
  (select (r ->> 'status') || '/' || (r -> 'proposed' ->> 'applied_cents') || '/' || (r -> 'proposed' ->> 'released_cents') || '/' || (r -> 'proposed' ->> 'charged_to_card_cents')
          || '/' || jsonb_array_length(r -> 'server_actions') from test.op_settle)
  || ' ' || (select applied_cents || '/' || released_cents || '/' || status from deposits where booking_id = test.b('opA')), 'awaiting_approval/45483/54517/0/0 0/0/held');
select test.eq('D the approval is an admin task and one staff_approval_needed event',
  test.op_tasks('opA', 'approve_deposit_release') || '/' || (select count(*) from app_events e join deposits d on d.id = e.entity_id where e.code = 'staff_approval_needed' and d.booking_id = test.b('opA')),
  '1:admin:high/1');
select test.eq('D the task cannot be closed while a balance is still to be released',
  app.task_completion_problem((select id from tasks where booking_id = test.b('opA') and task_type = 'approve_deposit_release')), 'A Deposit balance is still to be applied or released');
create table test.op_settle2 as select app.settle_deposit(test.b('opA'), test.id('op_admin'), '{}', test.at('2031-05-06 09:00')) as r;
select test.eq('D the Admin settles: $454.83 applied, $545.17 returned, the Deposit is settled, the booking closed',
  (select applied_cents || '/' || released_cents || '/' || held_back_cents || '/' || status || '/' || (release_approved_by = test.id('op_admin')) from deposits where booking_id = test.b('opA'))
  || ' ' || (select status::text from bookings where id = test.b('opA')), '45483/54517/0/settled/true closed');
select test.eq('D what the server must do at the processor: capture $454.83 of the hold and release $545.17',
  (select string_agg((a ->> 'action') || ':' || (a ->> 'amount_cents'), ' ') from test.op_settle2, jsonb_array_elements(r -> 'server_actions') a),
  'capture_deposit:45483 release_hold:54517');
select test.eq('D the statement shows it: applied $454.83, returned $545.17, nothing to the card',
  (select deposit_applied_cents || '/' || deposit_returned_cents || '/' || held_back_cents || '/' || charged_to_card_cents from booking_statements where id = test.b('stA')), '45483/54517/0/0');
select test.eq('D every line is tied to the capture, and each has its "applied" event',
  (select count(distinct payment_id) || '/' || bool_and(p.kind = 'capture' and p.status = 'pending' and p.amount_cents = 45483) || '/'
          || (select sum(e.amount_cents) from deposit_events e join deposits d on d.id = e.deposit_id where d.booking_id = test.b('opA') and e.kind = 'applied')
     from booking_line_items li join payments p on p.id = li.payment_id where li.booking_id = test.b('opA') and li.statement_id = test.b('stA')), '1/true/45483');
select app.post_rental_payment_result((select hold.id from payments hold where hold.booking_id = test.b('opA') and hold.kind = 'capture'), true, null, test.at('2031-05-06 09:05'));
select test.eq('D once the processor confirms the capture the statement is paid and the split has nothing uncollected after it',
  (select (paid_at is not null)::text from booking_statements where id = test.b('stA')) || '/'
  || (select status from booking_splits where booking_id = test.b('opA')), 'true/final');
select test.eq('D the approval and release tasks are closed', (select string_agg(distinct status, ',') from tasks where booking_id = test.b('opA') and task_type in ('approve_deposit_release', 'release_deposit')), 'done');
select test.eq('D settling again does nothing', (select (r ->> 'applied_cents') || '/' || (r ->> 'released_cents') || '/' || jsonb_array_length(r -> 'server_actions')
  from (select app.settle_deposit(test.b('opA'), test.id('op_admin')) as r) x), '0/0/0');

-- ------------------------------------------------------------------ damage under the deductible: at cost plus the administration fee
-- B is collected from the renter on time, with a new dent. Repair $1,000 + towing $100 + 2 days' loss of use $200 = $1,300.
select app.assign_field_job((select id from field_jobs where booking_id = test.b('opB') and kind = 'pickup_from_renter'), test.id('op_field'), test.id('op_fleet'));
create table test.op_outB as select test.op_return('opB', 'op_field', '2031-05-04 10:00', 30500,
  jsonb_build_object('damages', jsonb_build_array(jsonb_build_object('label', 'D1', 'location', 'rear bumper', 'description', 'dent, 10 cm', 'is_new', true, 'kind', 'dent', 'size_cm', 10)),
                     'photos', test.op_photos('return') || jsonb_build_array(jsonb_build_object('seq', 20, 'shot', 'damage_closeup', 'damage_label', 'D1', 'storage_path', 'bookings/op/return/20-d1.jpg')))) as r;
select test.eq('X new damage at return opens an incident with its first-response steps, linked to the damage mark',
  (select i.kind || '/' || i.status || '/' || (select count(*) from incident_steps s where s.incident_id = i.id) || '/'
          || (select count(*) from condition_report_damages dm where dm.incident_id = i.id and dm.is_new and dm.kind = 'dent' and dm.size_cm = 10)
     from incidents i where i.booking_id = test.b('opB')), 'damage_at_return/open/6/1');
select test.eq('X the incident is an urgent task for Fleet and for an Admin',
  (select string_agg(queue || ':' || priority, ' ' order by queue) from tasks where booking_id = test.b('opB') and task_type = 'incident'), 'admin:urgent fleet:urgent');
select test.eq('X a damage mark without a close-up stops the return',
  (select app.condition_report_problems(c.id) from condition_reports c where c.booking_id = test.b('opB') and c.kind = 'return'), '{}'::text[]);
select test.eq('M collecting a car from the renter: the drive back is a move that starts at Check-in and stays open',
  (select purpose || '/' || (started_at = test.at('2031-05-04 10:00')) || '/' || from_place || '/' || (ended_at is null)
     from vehicle_moves where vehicle_id = test.id('vehicle:OP2') and purpose = 'pickup_from_renter'), 'pickup_from_renter/true/12 Elm St, Toronto/true');
select app.end_vehicle_move((select id from vehicle_moves where vehicle_id = test.id('vehicle:OP2') and ended_at is null), 'CarmaCars lot', 30512, test.at('2031-05-04 10:40'));
select test.eq('M ending the move records the place, the time and the odometer',
  (select to_place || '/' || (ended_at = test.at('2031-05-04 10:40')) || '/' || odometer_end from vehicle_moves where vehicle_id = test.id('vehicle:OP2') and purpose = 'pickup_from_renter')
  || '/' || (select odometer_km from vehicles where id = test.id('vehicle:OP2')), 'CarmaCars lot/true/30512/30512');
select app.submit_return_findings(test.b('opB'), test.id('op_fleet'));
select test.eq('X findings with damage say so in the event', (select payload ->> 'has_damage' from app_events where code = 'staff_return_findings' and entity_id = test.b('opB')), 'true');
select test.eq('X with no estimate yet the damage is pending, with the advice to hold back',
  (select r -> 'pending' ->> 0 like 'damage IN-%: no estimate or invoice yet%' from (select app.assess_check_in(test.b('opB'), '{}', test.id('op_fin')) as r) x), true);
insert into incident_costs (incident_id, kind, amount_cents, approved_shop, shop_name, days)
select i.id, k.kind, k.amount, k.approved, 'Approved Auto Body', k.days from incidents i,
  (values ('repair_estimate', 100000, true, null::integer), ('towing', 10000, null, null), ('loss_of_use', 20000, null, 2)) k(kind, amount, approved, days)
 where i.booking_id = test.b('opB');
select test.eq('X Finance cannot price damage: it is listed as pending, with no line',
  (select (r -> 'pending' ->> 0 like '%an Admin prices damage') || '/' || jsonb_array_length(r -> 'lines') from (select app.assess_check_in(test.b('opB'), '{}', test.id('op_fin')) as r) x), 'true/0');
select test.eq('X and an Admin is asked to price it', test.op_tasks('opB', 'price_damage'), '1:admin:high');
create table test.op_assessB as select app.assess_check_in(test.b('opB'), '{}', test.id('op_admin')) as r;
select test.eq('X under $2,500: repair and towing at cost (pass-through, no HST added), loss of use (claim funds), and the $50 administration fee (company, HST)',
  (select string_agg(charge_type || '=' || amount_cents || '+' || hst_cents || ':' || revenue_class, ' ' order by charge_type) from booking_line_items
    where booking_id = test.b('opB') and assessment_key like 'damage:%' and voided_at is null),
  'admin_fee_other=5000+650:company_only damage_at_cost=110000+0:pass_through loss_of_use=20000+0:claim_funds');
select test.eq('X no claim on the fleet policy: the claim record is "at cost", the incident is billed, and the lines point to the incident and its costs',
  (select c.path || '/' || i.status || '/' || c.damage_cost_cents from claims c join incidents i on i.id = c.incident_id where i.booking_id = test.b('opB'))
  || ' ' || (select bool_and(incident_id is not null and supporting_refs ? 'incident_id' and jsonb_array_length(supporting_refs -> 'cost_ids') = 3)
               from booking_line_items where booking_id = test.b('opB') and assessment_key like 'damage:%' and voided_at is null),
  'at_cost/billed/130000 true');
select test.eq('X the totals by who the money belongs to', (select r -> 'totals' from test.op_assessB),
  '{"hst_cents": 650, "total_cents": 135650, "charges_cents": 135000, "claim_funds_cents": 20000, "company_only_cents": 5000, "pass_through_cents": 110000, "owner_revenue_cents": 0}'::jsonb);
select test.throws('X a statement with a damage line needs an Admin', format('select app.issue_booking_statement(%L, %L)', test.b('opB'), test.id('op_fin')), 'needs an Admin');
insert into test.rq_ids values ('stB', app.issue_booking_statement(test.b('opB'), test.id('op_admin'), test.at('2031-05-06 10:00')));
create table test.op_settleB as select app.settle_deposit(test.b('opB'), test.id('op_admin'), '{}', test.at('2031-05-06 10:05')) as r;
select test.eq('X the Deposit does not cap what is owed: $1,356.50 due, $1,000 from the Deposit, $356.50 to the Card on File',
  (select (r ->> 'charges_due_cents') || '/' || (r ->> 'applied_cents') || '/' || (r ->> 'released_cents') || '/' || (r ->> 'charged_to_card_cents') || '/' || (r ->> 'booking_closed') from test.op_settleB)
  || ' ' || (select string_agg((a ->> 'action') || ':' || (a ->> 'amount_cents'), ' ') from test.op_settleB, jsonb_array_elements(r -> 'server_actions') a),
  '135650/100000/0/35650/true capture_deposit:100000 charge_card:35650');
select test.eq('X the card charge is a pending payment on the Card on File; the statement shows the two parts',
  (select p.purpose || '/' || p.kind || '/' || p.status || '/' || p.amount_cents || '/' || (p.payment_method_id = b.card_on_file_id)
     from payments p join bookings b on b.id = p.booking_id where p.booking_id = test.b('opB') and p.purpose = 'post_rental')
  || ' ' || (select deposit_applied_cents || '/' || charged_to_card_cents from booking_statements where id = test.b('stB')), 'post_rental/charge/pending/35650/true 100000/35650');
select app.post_rental_payment_result((select id from payments where booking_id = test.b('opB') and purpose = 'post_rental'), false, 'card_declined', test.at('2031-05-06 10:06'));
select test.eq('X a declined card charge is counted and retried a day later',
  (select status || '/' || decline_count || '/' || (next_retry_at = test.at('2031-05-07 10:06')) from payments where booking_id = test.b('opB') and purpose = 'post_rental'), 'failed/1/true');
select app.post_rental_payment_result((select id from payments where booking_id = test.b('opB') and purpose = 'post_rental'), true, null, test.at('2031-05-07 10:06'));
select test.eq('X once paid, the damage money the renter paid (repair and towing, loss of use) is on the claim''s ledger',
  (select string_agg(e.kind || '=' || e.amount_cents, ' ' order by e.amount_cents) from claim_ledger_entries e join claims c on c.id = e.claim_id
     join incidents i on i.id = c.incident_id where i.booking_id = test.b('opB')), 'renter_at_cost=20000 renter_at_cost=110000');

-- ------------------------------------------------------------------ damage of $2,500 or more: a claim, the deductible and the claim fee
-- C: 10 days (weekly rate / 7 x 10 = $800), so the Deposit is charged, not held.
select test.rq_new('opC', 'op_r3', 'OP3', '2031-06-05 10:00', '2031-06-15 10:00');
select test.op_confirm('opC', 'op_r3');
insert into test.rq_ids values ('jobC', app.create_field_job('handover', test.id('vehicle:OP3'), test.at('2031-06-05 10:00'), test.id('op_admin'), test.b('opC'), test.id('op_field')));
select test.op_handover('opC', 'op_field', '2031-06-05 10:00', 40000);
select test.eq('Y a rental over 7 days takes a charged Deposit', (select method || '/' || status || '/' || captured_cents from deposits where booking_id = test.b('opC')), 'charged/captured/100000');
insert into test.rq_ids values ('jobCr', app.create_field_job('return_check_in', test.id('vehicle:OP3'), test.at('2031-06-15 10:00'), test.id('op_admin'), test.b('opC'), test.id('op_field')));
select test.op_return('opC', 'op_field', '2031-06-15 09:00', 41000,
  jsonb_build_object('damages', jsonb_build_array(jsonb_build_object('label', 'D1', 'location', 'left side', 'description', 'door and fender crushed', 'is_new', true)),
                     'photos', test.op_photos('return') || jsonb_build_array(jsonb_build_object('seq', 20, 'shot', 'damage_closeup', 'damage_label', 'D1', 'storage_path', 'x/20.jpg'))));
select app.submit_return_findings(test.b('opC'), test.id('op_fleet'));
insert into incident_costs (incident_id, kind, amount_cents, approved_shop) select id, 'repair_estimate', 300000, true from incidents where booking_id = test.b('opC');
select app.assess_check_in(test.b('opC'), '{}', test.id('op_admin'));
select test.eq('Y $2,500 or more: a fleet policy claim is opened and the renter is billed the $2,500 deductible (claim funds, no HST) plus the $75 fee (company, HST)',
  (select string_agg(charge_type || '=' || amount_cents || '+' || hst_cents || ':' || revenue_class, ' ' order by charge_type) from booking_line_items
    where booking_id = test.b('opC') and voided_at is null and stage in ('check_in', 'after_return'))
  || ' ' || (select c.path || '/' || i.status from claims c join incidents i on i.id = c.incident_id where i.booking_id = test.b('opC')),
  'admin_fee_claim=7500+975:company_only deductible=250000+0:claim_funds fleet_policy/claim_open');
select test.eq('Y loss of use is not added on top of the deductible, and 1,000 km in 10 days is inside the allowance',
  (select count(*) from booking_line_items where booking_id = test.b('opC') and voided_at is null and charge_type in ('loss_of_use', 'damage_at_cost', 'mileage_overage')), 0::bigint);
select app.issue_booking_statement(test.b('opC'), test.id('op_admin'), test.at('2031-06-16 10:00'));
create table test.op_settleC as select app.settle_deposit(test.b('opC'), test.id('op_admin'), '{}', test.at('2031-06-16 10:05')) as r;
select test.eq('Y $2,584.75 due: the charged Deposit of $1,000 is applied (no capture needed) and $1,584.75 goes to the card',
  (select (r ->> 'charges_due_cents') || '/' || (r ->> 'applied_cents') || '/' || (r ->> 'charged_to_card_cents') from test.op_settleC)
  || ' ' || (select string_agg((a ->> 'action') || ':' || (a ->> 'amount_cents'), ' ') from test.op_settleC, jsonb_array_elements(r -> 'server_actions') a),
  '258475/100000/158475 charge_card:158475');
select app.post_rental_payment_result((select id from payments where booking_id = test.b('opC') and purpose = 'post_rental'), true);
select test.eq('Y the deductible paid by the renter is money in on the claim', (select c.money_in_cents from claims c join incidents i on i.id = c.incident_id where i.booking_id = test.b('opC')), 250000::bigint);

-- ------------------------------------------------------------------ hold-back, the 48-hour review, and a release inside the assistant's limit
select test.rq_new('opD', 'op_r4', 'OP4', '2031-07-03 10:00', '2031-07-06 10:00');
select test.rq_new('opE', 'op_r5', 'OP5', '2031-07-03 10:00', '2031-07-06 10:00');
select test.op_confirm('opD', 'op_r4'); select test.op_confirm('opE', 'op_r5');
select test.op_handover('opD', 'op_fleet', '2031-07-03 10:00'); select test.op_handover('opE', 'op_admin', '2031-07-03 10:00');
select test.eq('H Fleet or an Admin may complete a handover with no field job', (select string_agg(performed_by_role, ',') from condition_reports
  where booking_id in (test.b('opD'), test.b('opE')) and kind = 'pickup'), 'staff,staff');
select test.op_return('opD', 'op_fleet', '2031-07-06 10:20', 20300); select test.op_return('opE', 'op_fleet', '2031-07-06 09:50', 20300);
select test.eq('R 20 minutes late is inside the grace period: no extra day', (select minutes_late || '/' || extra_days || '/' || end_reason from bookings where id = test.b('opD')), '20/0/normal');
select app.submit_return_findings(test.b('opD'), test.id('op_fleet')); select app.submit_return_findings(test.b('opE'), test.id('op_fleet'));
select test.eq('A a clean, on-time return has no charge line', (select jsonb_array_length(app.assess_check_in(test.b('opD'), '{}', test.id('op_fin')) -> 'lines')), 0);
select app.issue_booking_statement(test.b('opD'), test.id('op_fin'), test.at('2031-07-07 10:00'));
select app.issue_booking_statement(test.b('opE'), test.id('op_fin'), test.at('2031-07-07 10:00'));
select test.eq('D a Check-in statement is issued even when there is nothing to charge',
  (select count(*) || '/' || sum(charges_cents) from booking_statements where booking_id in (test.b('opD'), test.b('opE')) and kind = 'check_in'), '2/0');

-- damage found in the 48-hour photo review (Check-in was July 6, 10:20)
select test.throws('L damage found later needs a description', format($$select app.record_late_damage(%L, %L, '{"location": "roof"}')$$, test.b('opD'), test.id('op_fleet')), 'Describe the damage');
select test.throws('L after 48 hours Fleet can no longer record it against the renter',
  format($$select app.record_late_damage(%L, %L, '{"location": "roof", "description": "scratch"}', test.at('2031-07-08 10:21'))$$, test.b('opD'), test.id('op_fleet')), '48 hours after Check-in have passed');
insert into test.rq_ids values ('incD', app.record_late_damage(test.b('opD'), test.id('op_fleet'),
  '{"location": "roof", "description": "long scratch", "kind": "scratch", "photos": [{"storage_path": "bookings/opD/late/1.jpg"}]}', test.at('2031-07-07 15:00')));
select test.eq('L inside 48 hours: a damage mark on the return report (found later) with its close-up, an incident, and the renter is told once',
  (select dm.label || '/' || dm.found_later || '/' || dm.is_new || '/' || (dm.reported_to_renter_at = test.at('2031-07-07 15:00')) || '/'
          || (select count(*) from condition_report_photos p where p.damage_id = dm.id and p.shot = 'damage_closeup')
     from condition_report_damages dm where dm.incident_id = test.b('incD'))
  || ' ' || (select kind from incidents where id = test.b('incD')) || ' ' || test.op_events('renter_damage_found', test.b('incD'))
  || ' ' || (select (payload ->> 'damage_description') || '/' || (payload ->> 'reported_late') || '/' || (dedupe_key like 'renter_damage_found:' || test.b('incD') || ':%')
               from app_events where code = 'renter_damage_found' and entity_id = test.b('incD')),
  'L1/true/true/true/1 damage_found_later 1 roof: long scratch/false/true');
select test.lives('L after 48 hours an Admin may still record it, with the reason',
  format($$select app.record_late_damage(%L, %L, '{"location": "trunk", "description": "stain"}', test.at('2031-07-09 12:00'), 'car was in the shop until now')$$, test.b('opD'), test.id('op_admin')));
select test.eq('L and that late report is marked as late', (select count(*) filter (where payload ->> 'reported_late' = 'true') || '/' || count(*)
  from app_events where code = 'renter_damage_found' and payload ->> 'booking_id' = test.b('opD')::text), '1/2');

-- hold-back: the estimate is not in, so $600 is held back; a finance assistant proposes, an Admin approves
update staff_profiles set single_limit_cents = 150000 where user_id = test.id('op_fin');
select test.throws('D a hold-back needs its reason', format($$select app.settle_deposit(%L, %L, '{"hold_back_cents": 60000}')$$, test.b('opD'), test.id('op_admin')), 'needs its reason');
select test.throws('D a hold-back runs at most 30 days after Check-in',
  format($$select app.settle_deposit(%L, %L, '{"hold_back_cents": 60000, "hold_back_reason": "pending claim", "hold_back_until": "2031-08-20"}')$$, test.b('opD'), test.id('op_admin')), 'at most 30 days');
select test.eq('D with a hold-back even an assistant inside their limit needs an Admin',
  (select r ->> 'status' from (select app.settle_deposit(test.b('opD'), test.id('op_fin'), '{"hold_back_cents": 60000, "hold_back_reason": "pending claim"}', test.at('2031-07-07 16:00')) as r) x), 'awaiting_approval');
create table test.op_settleD as select app.settle_deposit(test.b('opD'), test.id('op_admin'), '{"hold_back_cents": 60000, "hold_back_reason": "pending claim"}', test.at('2031-07-07 17:00')) as r;
select test.eq('D $600 held back until 30 days after Check-in, $400 released; the hold is captured for what is held back; the booking stays open',
  (select held_back_cents || '/' || held_back_until || '/' || released_cents || '/' || captured_cents || '/' || status from deposits where booking_id = test.b('opD'))
  || ' ' || (select status::text from bookings where id = test.b('opD'))
  || ' ' || (select string_agg((a ->> 'action') || ':' || (a ->> 'amount_cents'), ' ') from test.op_settleD, jsonb_array_elements(r -> 'server_actions') a),
  '60000/2031-08-05/40000/60000/captured returned capture_deposit:60000 release_hold:40000');
-- a release inside the assistant's limit, with nothing held back, needs no Admin
create table test.op_settleE as select app.settle_deposit(test.b('opE'), test.id('op_fin'), '{}', test.at('2031-07-07 16:00')) as r;
select test.eq('D inside the Single Limit and with nothing held back, the assistant releases the whole Deposit and the booking closes',
  (select (r ->> 'status') || '/' || (r ->> 'released_cents') || '/' || (r ->> 'booking_closed') from test.op_settleE)
  || ' ' || (select status || '/' || (release_approved_by = test.id('op_fin')) from deposits where booking_id = test.b('opE')), 'settled/100000/true settled/true');
select test.eq('R returning 10 minutes early is a normal end', (select end_reason from bookings where id = test.b('opE')), 'normal');

-- the estimate arrives: $350. An Admin prices it, a later-charge statement is issued, the hold-back pays it and the rest is refunded.
insert into incident_costs (incident_id, kind, amount_cents, approved_shop) values (test.b('incD'), 'repair_invoice', 35000, true);
update incidents set status = 'closed', closed_at = now() where booking_id = test.b('opD') and id <> test.b('incD');
select app.assess_check_in(test.b('opD'), '{}', test.id('op_admin'));
insert into test.rq_ids values ('stD2', app.issue_booking_statement(test.b('opD'), test.id('op_admin'), test.at('2031-07-20 10:00')));
select test.eq('D a charge after the Check-in statement goes on a later-charge statement: $350 + $50 + HST $6.50',
  (select kind || '/' || charges_cents || '/' || hst_cents from booking_statements where id = test.b('stD2')), 'later_charge/40000/650');
create table test.op_settleD2 as select app.settle_deposit(test.b('opD'), test.id('op_admin'), '{"hold_back_cents": 0}', test.at('2031-07-20 10:05')) as r;
select test.eq('D the held-back $600 pays $406.50 and $193.50 is refunded (it was captured); the booking closes and the renter is told',
  (select applied_cents || '/' || held_back_cents || '/' || released_cents || '/' || status from deposits where booking_id = test.b('opD'))
  || ' ' || (select status::text from bookings where id = test.b('opD'))
  || ' ' || (select string_agg((a ->> 'action') || ':' || (a ->> 'amount_cents'), ' ') from test.op_settleD2, jsonb_array_elements(r -> 'server_actions') a)
  || ' ' || (select count(*) || ':' || min(e.payload ->> 'holdback_applied_cents') || ':' || min(e.payload ->> 'release_amount_cents')
               from app_events e join deposits d on d.id = e.entity_id where e.code = 'renter_deposit_released' and d.booking_id = test.b('opD')),
  '40650/0/59350/settled closed refund_deposit:19350 1:40650:19350');
select test.eq('D the later statement shows the Deposit paid it', (select deposit_applied_cents || '/' || charged_to_card_cents from booking_statements where id = test.b('stD2')), '40650/0');

-- an Admin waives a Deposit
select test.rq_new('opW', 'op_r6', 'OP6', '2031-07-10 10:00', '2031-07-12 10:00');
select test.op_confirm('opW', 'op_r6');
select app.complete_handover(test.b('opW'), test.id('op_fleet'),
  jsonb_build_object('odometer_km', 5000, 'fuel_pct', 100, 'keys_count', 1, 'licence_seen', true, 'card_seen', true, 'tracker_reporting', true,
                     'renter_signature_ref', 's', 'staff_signature_ref', 's', 'photos', test.op_photos('pickup'),
                     'deposit_waiver', jsonb_build_object('by', test.id('op_admin'), 'reason', 'long-standing customer')), null, test.at('2031-07-10 10:00'));
select test.eq('H with an Admin''s waiver the car is handed over with no Deposit, and the waiver is on the booking',
  (select status || '/' || deposit_cents || '/' || deposit_waived_cents || '/' || (deposit_waived_by = test.id('op_admin')) || '/' || deposit_waived_reason from bookings where id = test.b('opW'))
  || ' ' || (select count(*) from deposits where booking_id = test.b('opW')), 'on_rent/0/100000/true/long-standing customer 0');

-- ------------------------------------------------------------------ incidents, breakdown, vehicle swap
select test.throws('I a renter reports only on their own booking',
  format($$select app.open_incident('breakdown', %L, %L, '{"description": "will not start"}', %L, 'renter')$$, test.id('vehicle:OP6'), test.id('op_r1'), test.b('opW')), 'their own booking');
select test.throws('I field staff report only on a vehicle of their own jobs',
  format($$select app.open_incident('accident', %L, %L, '{"description": "hit a post"}', null, 'field')$$, test.id('vehicle:OP6'), test.id('op_field2')), 'their own jobs');
select test.throws('I an incident needs a description',
  format($$select app.open_incident('breakdown', %L, %L, '{}', %L, 'renter')$$, test.id('vehicle:OP6'), test.id('op_r6'), test.b('opW')), 'Describe what happened');
insert into test.rq_ids values ('incW', app.open_incident('breakdown', test.id('vehicle:OP6'), test.id('op_r6'),
  '{"description": "engine warning light, car will not start", "place": "Highway 401 at Keele", "breakdown_cause": "mechanical", "drivable": false}',
  test.b('opW'), 'renter', test.at('2031-07-11 09:00')));
select test.eq('I the renter''s breakdown report: an incident on the booking, mechanical so not the renter''s fault, with the six steps of procedure 10',
  (select kind || '/' || (booking_id = test.b('opW')) || '/' || renter_at_fault || '/' || rental_ended || '/' || (opened_by = test.id('op_r6'))
          || '/' || (select count(*) || ':' || min(step_code) filter (where seq = 1) || ':' || min(procedure_no) from incident_steps s where s.incident_id = i.id)
          || '/' || (select count(*) from incident_events e where e.incident_id = i.id)
     from incidents i where id = test.b('incW')), 'breakdown/true/false/false/true/6:safety:10/1');
select test.eq('I a breakdown is an urgent Fleet task due in 15 minutes, and not an Admin task',
  (select string_agg(queue || ':' || task_type || ':' || priority || ':' || sla_minutes, ' ') from tasks where related_id = test.b('incW')), 'fleet:breakdown:urgent:15');
select test.eq('I a car that cannot be driven goes out of service and its calendar is blocked for repair, open-ended',
  (select status::text from vehicles where id = test.id('vehicle:OP6')) || '/'
  || (select reason || ':' || (ends_at is null) || ':' || (starts_at = test.at('2031-07-11 09:00')) from vehicle_calendar_blocks where vehicle_id = test.id('vehicle:OP6') and removed_at is null),
  'out_of_service/repair:true:true');
select test.eq('I the amounts named in the steps come from the settings and fee defaults, not from the code',
  (select instruction from incident_steps where incident_id = test.b('incW') and step_code = 'cause') like '%call-out cost plus $50', true);
select app.complete_incident_step((select id from incident_steps where incident_id = test.b('incW') and step_code = 'safety'), test.id('op_fleet'), 'renter is safe, off the highway');
select test.eq('I a step ticked off is on the step and in the incident''s timeline',
  (select (done_by = test.id('op_fleet')) || '/' || note from incident_steps where incident_id = test.b('incW') and step_code = 'safety')
  || '/' || (select count(*) from incident_events where incident_id = test.b('incW') and kind = 'decision'), 'true/renter is safe, off the highway/1');
-- staff open an accident: Fleet and an Admin, and the renter's report is due in 48 hours
insert into test.rq_ids values ('incW2', app.open_incident('accident', test.id('vehicle:OP1'), test.id('op_cs'),
  '{"description": "scraped in a parking lot while staff had the car", "anyone_hurt": false, "drivable": true, "staff_had_car": true}', null, 'staff', test.at('2031-07-11 12:00')));
select test.eq('I an accident logged by staff: ten steps of procedure 9, tasks for Fleet and an Admin, the staff member recorded',
  (select (select count(*) from incident_steps s where s.incident_id = i.id) || '/' || (staff_user_id = test.id('op_cs')) || '/' || (renter_report_due_at is null)
     from incidents i where id = test.b('incW2'))
  || ' ' || (select string_agg(queue, ',' order by queue) from tasks where related_id = test.b('incW2')), '10/true/true admin,fleet');

select test.throws('I an Admin''s step is not ticked by Fleet',
  format('select app.complete_incident_step((select s.id from incident_steps s join incidents i on i.id = s.incident_id where i.kind = %L and s.owner_role = %L limit 1), %L)',
         'accident', 'admin', test.id('op_fleet')), 'an Admin''s');

-- vehicle swap on the breakdown
update vehicles set status = 'available' where id = test.id('vehicle:OP5');
select test.throws('W a replacement vehicle needs an Admin''s approval',
  format($$select app.swap_vehicle(%L, %L, %L, 'breakdown, not the renter''s fault')$$, test.b('opW'), test.id('vehicle:OP5'), test.id('op_fleet')), 'Admin''s approval');
select test.throws('W the replacement must be available', format($$select app.swap_vehicle(%L, %L, %L, 'breakdown')$$, test.b('opW'), test.id('vehicle:OP1'), test.id('op_admin')), 'cannot be handed over');
insert into test.rq_ids values ('swapW', app.swap_vehicle(test.b('opW'), test.id('vehicle:OP5'), test.id('op_fleet'), 'breakdown, not the renter''s fault',
  test.id('op_admin'), test.b('incW'), test.at('2031-07-11 11:00')));
select test.eq('W the swap: recorded with its approver, the booking is on the new car, the old car is out of service, the new one on rent',
  (select (from_vehicle_id = test.id('vehicle:OP6')) || '/' || (to_vehicle_id = test.id('vehicle:OP5')) || '/' || (approved_by = test.id('op_admin')) from booking_vehicle_swaps where id = test.b('swapW'))
  || ' ' || (select (vehicle_id = test.id('vehicle:OP5')) || '/' || status from bookings where id = test.b('opW'))
  || ' ' || (select string_agg(fleet_number || '=' || status, ' ' order by fleet_number) from vehicles where id in (test.id('vehicle:OP5'), test.id('vehicle:OP6'))),
  'true/true/true true/on_rent F-OP5=on_rent F-OP6=out_of_service');
select test.eq('W the Owner''s controls: restored on the old car, blocked on the new one; Fleet gets the task for the two reports',
  app.owner_controls_blocked(test.id('vehicle:OP6'), test.at('2031-07-11 12:00')) || '/' || app.owner_controls_blocked(test.id('vehicle:OP5'), test.at('2031-07-11 12:00'))
  || ' ' || test.op_tasks('opW', 'vehicle_swap'), 'false/true 1:fleet:urgent');
select app.save_condition_report(test.b('opW'), 'swap_out', test.id('op_fleet'), jsonb_build_object('odometer_km', 5200, 'fuel_pct', 80, 'photos', test.op_photos('swap_out')), null, test.id('vehicle:OP6'));
select app.save_condition_report(test.b('opW'), 'swap_in', test.id('op_fleet'), jsonb_build_object('odometer_km', 20300, 'fuel_pct', 100), null, test.id('vehicle:OP5'));
select test.throws('W a swap report needs its photo set too',
  format($$select app.complete_condition_report((select id from condition_reports where booking_id = %L and kind = 'swap_in'), %L)$$, test.b('opW'), test.id('op_fleet')), 'missing photo: front');
select app.save_condition_report(test.b('opW'), 'swap_in', test.id('op_fleet'), jsonb_build_object('photos', test.op_photos('swap_in')), null, test.id('vehicle:OP5'));
select app.complete_condition_report(id, test.id('op_fleet')) from condition_reports where booking_id = test.b('opW') and kind in ('swap_out', 'swap_in');

-- ------------------------------------------------------------------ tracker: disabling a vehicle
insert into tracker_devices (id, serial_number, vehicle_id, status, installed_at, tested_at) values (test.id('trk:OP5'), 'OP-TRK-5', test.id('vehicle:OP5'), 'installed', now(), now());
select test.throws('T customer service does not request a disable',
  format($$select app.request_tracker_disable(%L, %L, 'suspected_theft', 'car reported two provinces away')$$, test.id('vehicle:OP5'), test.id('op_cs')), 'Fleet or an Admin');
select test.throws('T a late return needs the final notice first',
  format($$select app.request_tracker_disable(%L, %L, 'late_return', 'two hours overdue', %L, null, null, test.at('2031-07-12 13:00'))$$, test.id('vehicle:OP5'), test.id('op_fleet'), test.b('opW')), 'Notice is required');
select test.throws('T and the notice must be an hour old',
  format($$select app.request_tracker_disable(%L, %L, 'late_return', 'two hours overdue', %L, null, test.at('2031-07-12 12:30'), test.at('2031-07-12 13:00'))$$, test.id('vehicle:OP5'), test.id('op_fleet'), test.b('opW')), 'at least 60 minutes ago');
select test.throws('T "the renter was rude" is not a ground', format($$select app.request_tracker_disable(%L, %L, 'other', 'rude')$$, test.id('vehicle:OP5'), test.id('op_fleet')), 'not a ground');
insert into test.rq_ids values ('cmdW', app.request_tracker_disable(test.id('vehicle:OP5'), test.id('op_fleet'), 'late_return', 'two hours overdue, renter unreachable',
  test.b('opW'), null, test.at('2031-07-12 12:00'), test.at('2031-07-12 13:05')));
select test.eq('T the request waits: nothing is sent, an Admin gets an urgent task and the two admins are told at once',
  (select status || '/' || actor_type || '/' || (approved_by is null) from tracker_commands where id = test.b('cmdW'))
  || ' ' || (select queue || ':' || priority || ':' || status from tasks where related_id = test.b('cmdW'))
  || ' ' || test.op_events('staff_disable_approval_needed', test.b('cmdW')), 'requested/staff/true admin:urgent:open 1');
select test.throws('T Fleet cannot approve a disable',
  format($$select app.approve_tracker_disable(%L, %L, test.at('2031-07-12 13:06'), 0, false, null, test.at('2031-07-12 13:07'))$$, test.b('cmdW'), test.id('op_fleet')), 'Only an Admin');
select test.throws('T never while moving',
  format($$select app.approve_tracker_disable(%L, %L, test.at('2031-07-12 13:06'), 42, true, null, test.at('2031-07-12 13:07'))$$, test.b('cmdW'), test.id('op_admin')), 'Never disable while moving');
select test.throws('T not on a reading older than 5 minutes',
  format($$select app.approve_tracker_disable(%L, %L, test.at('2031-07-12 13:00'), 0, false, null, test.at('2031-07-12 13:07'))$$, test.b('cmdW'), test.id('op_admin')), 'more than 5 minutes old');
select app.approve_tracker_disable(test.b('cmdW'), test.id('op_admin'), test.at('2031-07-12 13:06'), 0, false, null, test.at('2031-07-12 13:07'));
select test.eq('T approved by an Admin on a fresh reading showing the car parked with the ignition off; the task is closed',
  (select status || '/' || (approved_by = test.id('op_admin')) || '/' || observed_speed_kmh || '/' || observed_ignition_on from tracker_commands where id = test.b('cmdW'))
  || ' ' || (select status from tasks where related_id = test.b('cmdW')), 'approved/true/0.0/false done');
insert into test.rq_ids values ('cmdW2', app.request_tracker_disable(test.id('vehicle:OP5'), test.id('op_fleet'), 'suspected_theft', 'tracker shows the car in a shipping yard'));
select app.reject_tracker_disable(test.b('cmdW2'), test.id('op_admin'), 'renter answered, on the way back');
select test.eq('T suspected theft needs no notice; an Admin may refuse, with the reason',
  (select status || '/' || error from tracker_commands where id = test.b('cmdW2')) || ' ' || (select status from tasks where related_id = test.b('cmdW2')),
  'rejected/renter answered, on the way back done');

-- ------------------------------------------------------------------ calendar: the new entries
insert into turo_trips (id, vehicle_id, turo_trip_ref, starts_at, ends_at, gross_cents, turo_fees_cents, revenue_share_bps, revenue_share_cents)
values (test.id('turo:1'), test.id('vehicle:OPT'), 'TURO-OP-1', test.at('2031-05-02 10:00'), test.at('2031-05-05 10:00'), 30000, 5000, 2500, 6250);
select test.eq('K the 21 columns of migration 0016 are still the first 21, in the same order; four are added after them',
  (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns where table_name = 'calendar_entries'),
  'entry_type,entry_id,vehicle_id,vehicle_label,plate,fleet_number,booking_id,booking_number,booking_type,status,calendar_state,starts_at,ends_at,blocks_calendar,is_blocking,bill_to,dates_provisional,insurer_name,renter_name,block_reason,note,related_booking_id,assigned_to,assignee_name,detail');
select test.login(test.id('op_admin'));
select test.eq('K the master calendar shows a booking, its field jobs and the staff moves on one car',
  (select string_agg(entry_type || ':' || coalesce(detail, '-') || ':' || status, ' ' order by starts_at, entry_type)
     from app.master_calendar(test.at('2031-05-01 00:00'), test.at('2031-05-06 00:00')) where vehicle_id = test.id('vehicle:OP2')),
  'vehicle_move:delivery:done booking:-:closed field_job:delivery:done field_job:pickup_from_renter:done vehicle_move:pickup_from_renter:done');
select test.eq('K a job or move entry is not "the booking''s entry": booking_id is empty and related_booking_id carries the link, with who has it',
  (select count(*) filter (where booking_id is not null) || '/' || bool_and(related_booking_id = test.b('opB')) || '/' || min(assignee_name) || '/' || bool_or(is_blocking)
     from app.master_calendar(test.at('2031-05-01 00:00'), test.at('2031-05-06 00:00')) where vehicle_id = test.id('vehicle:OP2') and entry_type <> 'booking'), '0/true/Op Field/false');
select test.eq('K a Turo trip is an entry on its car',
  (select entry_type || '/' || calendar_state || '/' || detail || '/' || is_blocking from app.master_calendar(test.at('2031-05-01 00:00'), test.at('2031-05-06 00:00'))
    where vehicle_id = test.id('vehicle:OPT')), 'turo_trip/turo/TURO-OP-1/false');
select test.eq('K the vehicle calendar has everything for one car: bookings, jobs, moves, the Owner''s control block, incidents',
  (select string_agg(distinct entry_type, ',' order by entry_type) from app.vehicle_calendar(test.id('vehicle:OP2'), test.at('2031-01-01 00:00'), test.at('2032-01-01 00:00'))),
  'booking,field_job,incident,owner_controls_blocked,vehicle_move');
select test.eq('K and on the broken-down car: the repair block and the swap''s end of the control block',
  (select string_agg(entry_type || ':' || status, ' ' order by entry_type, status) from app.vehicle_calendar(test.id('vehicle:OP6'), test.at('2031-07-01 00:00'), test.at('2031-08-01 00:00'))
    where entry_type in ('block', 'owner_controls_blocked', 'incident')), 'block:blocked incident:open owner_controls_blocked:ended');
select test.logout();

-- ------------------------------------------------------------------ calendar: preview and apply (drag and resize)
select test.rq_new('opP1', 'op_r7', 'OP7', '2031-08-07 10:00', '2031-08-10 10:00');
create table test.op_pv as select app.calendar_preview_change(test.b('opP1'), jsonb_build_object('return_at', test.at('2031-08-11 10:00'))) as r;
select test.eq('P resizing a request by a day: applied at once; Thursday to Monday is $100 + $120 + $120 + $100 = $440; total $497.20, $113.00 more',
  (select (r ->> 'action') || '/' || (r ->> 'offer_must_be_resent') || '/' || (r ->> 'renter_must_approve') || '/' || (r -> 'old' ->> 'total_cents') || '/' || (r -> 'new' ->> 'billable_days')
          || '/' || (r -> 'new' ->> 'rental_charge_cents') || '/' || (r -> 'new' ->> 'total_cents') || '/' || (r ->> 'difference_cents') || '/' || (r ->> 'available') from test.op_pv),
  'apply_now/false/false/38420/4/44000/49720/11300/true');
select test.eq('P a preview changes nothing', (select return_at = test.at('2031-08-10 10:00') from bookings where id = test.b('opP1')), true);
select test.throws('P applying needs a reason', format($$select app.calendar_apply_change(%L, %L, %L, '')$$, test.b('opP1'), test.id('op_cs'), jsonb_build_object('return_at', test.at('2031-08-11 10:00'))), 'reason for the change');
select app.calendar_apply_change(test.b('opP1'), test.id('op_cs'), jsonb_build_object('return_at', test.at('2031-08-11 10:00')), 'customer asked for one more day');
select test.eq('P applied: the request has the new return and the price the preview showed, with the reason in its history',
  (select (return_at = test.at('2031-08-11 10:00')) || '/' || billable_days || '/' || total_due_at_booking_cents from bookings where id = test.b('opP1'))
  || ' ' || (select note from booking_events where booking_id = test.b('opP1') and kind = 'adjusted' order by id desc limit 1), 'true/4/49720 customer asked for one more day');
-- an offer is out: moving it withdraws the offer and sends a new version
select app.send_offer(test.b('opP1'), test.id('op_cs'));
create table test.op_pv2 as select app.calendar_preview_change(test.b('opP1'), jsonb_build_object('pickup_at', test.at('2031-08-08 10:00'), 'return_at', test.at('2031-08-12 10:00'))) as r;
select test.eq('P moving an offered booking: the offer must be re-sent', (select (r ->> 'action') || '/' || (r ->> 'offer_must_be_resent') from test.op_pv2), 'resend_offer/true');
create table test.op_ap2 as select app.calendar_apply_change(test.b('opP1'), test.id('op_cs'),
  jsonb_build_object('pickup_at', test.at('2031-08-08 10:00'), 'return_at', test.at('2031-08-12 10:00')), 'car not back until the 8th', false, 'New dates as discussed') as r;
select test.eq('P applied: version 1 withdrawn, the booking moved, version 2 sent with the message',
  (select (r ->> 'offer_version') || '/' || (r ->> 'applied') from test.op_ap2)
  || ' ' || (select status || '/' || current_offer_version || '/' || (pickup_at = test.at('2031-08-08 10:00')) from bookings where id = test.b('opP1'))
  || ' ' || (select string_agg(version || ':' || status, ' ' order by version) from booking_offers where booking_id = test.b('opP1'))
  || ' ' || (select message from booking_offers where booking_id = test.b('opP1') and version = 2), '2/true offered/2/true 1:withdrawn 2:sent New dates as discussed');
-- a confirmed booking: nothing moves until the renter agrees
select test.rq_new('opP2', 'op_r7', 'OP7', '2031-08-20 10:00', '2031-08-22 10:00');
select test.op_confirm('opP2', 'op_r7');
insert into test.rq_ids values ('jobP2', app.create_field_job('return_check_in', test.id('vehicle:OP7'), test.at('2031-08-22 10:00'), test.id('op_fleet'), test.b('opP2'), test.id('op_field')));
select test.eq('P a move onto a confirmed booking is shown as a conflict, with the competing offers on those dates',
  (select (r ->> 'available') || '/' || jsonb_array_length(r -> 'conflicts') || '/' || (r -> 'conflicts' -> 0 ->> 'booking_number' = (select booking_number from bookings where id = test.b('opP2')))
     from (select app.calendar_preview_change(test.b('opP1'), jsonb_build_object('pickup_at', test.at('2031-08-19 10:00'), 'return_at', test.at('2031-08-21 10:00'))) as r) x)
  || ' ' || (select jsonb_array_length(r -> 'competing') from (select app.calendar_preview_change(test.b('opP2'), jsonb_build_object('pickup_at', test.at('2031-08-10 10:00'), 'return_at', test.at('2031-08-12 10:00'))) as r) x),
  'false/1/true 1');
create table test.op_pv3 as select app.calendar_preview_change(test.b('opP2'), jsonb_build_object('return_at', test.at('2031-08-23 10:00'))) as r;
select test.eq('P resizing a confirmed booking: the renter must approve; Wednesday to Saturday at the stored rates is $320, $135.60 more with HST',
  (select (r ->> 'action') || '/' || (r ->> 'renter_must_approve') || '/' || (r -> 'new' ->> 'rental_charge_cents') || '/' || (r ->> 'difference_cents') from test.op_pv3), 'renter_approval/true/32000/13560');
select test.eq('P (0025) a confirmed booking may move to another Owner''s car once the renter agrees, but not into the past, past 30 days, or to a car that does not exist',
  (select r ->> 'refusal' from (select app.calendar_preview_change(test.b('opP2'), jsonb_build_object('vehicle_id', test.id('vehicle:OP8'))) as r) x) is null
  and (select r ->> 'refusal' from (select app.calendar_preview_change(test.b('opP2'), jsonb_build_object('pickup_at', test.at('2020-01-01 10:00'), 'return_at', test.at('2020-01-03 10:00'))) as r) x) like '%into the past%'
  and (select r ->> 'refusal' from (select app.calendar_preview_change(test.b('opP2'), jsonb_build_object('return_at', test.at('2031-10-20 10:00'))) as r) x) like '%at most 30 days%'
  and (select r ->> 'action' from (select app.calendar_preview_change(test.b('opP2'), jsonb_build_object('vehicle_id', gen_random_uuid())) as r) x) = 'refused', true);
create table test.op_ap3 as select app.calendar_apply_change(test.b('opP2'), test.id('op_cs'), jsonb_build_object('return_at', test.at('2031-08-23 10:00')), 'customer wants Saturday') as r;
select test.eq('P without the renter''s agreement nothing moves: customer service gets the task to obtain it',
  (select r ->> 'applied' from test.op_ap3) || '/' || (select (return_at = test.at('2031-08-22 10:00'))::text from bookings where id = test.b('opP2')) || '/' || test.op_tasks('opP2', 'booking_change_approval'),
  'false/true/1:cs:normal');
select test.throws('P only an Admin records the renter''s agreement by word',
  format($$select app.calendar_apply_change(%L, %L, %L, 'agreed by phone', true)$$, test.b('opP2'), test.id('op_cs'), jsonb_build_object('return_at', test.at('2031-08-23 10:00'))), 'Only an Admin records');
create table test.op_ap4 as select app.calendar_apply_change(test.b('opP2'), test.id('op_admin'), jsonb_build_object('return_at', test.at('2031-08-23 10:00')), 'agreed by phone 14:05', true) as r;
select test.eq('P (0024) a change that costs the renter more is not agreed by word: the calendar''s change request waits for the renter to agree and pay online',
  (select (r ->> 'applied') || '/' || (r ->> 'renter_pays_online') from test.op_ap4)
  || ' ' || (select status || '/' || source || '/' || requested_by_role || '/' || total_difference_cents from booking_change_requests where id = (select (r ->> 'change_request_id')::uuid from test.op_ap4))
  || ' ' || (select (return_at = test.at('2031-08-22 10:00'))::text from bookings where id = test.b('opP2')), 'false/true proposed/staff_calendar/staff/13560 true');
select app.agree_booking_change((select (r ->> 'change_request_id')::uuid from test.op_ap4), test.id('op_r7'), inet '203.0.113.9', 'test browser');
select app.apply_booking_change((select (r ->> 'change_request_id')::uuid from test.op_ap4), test.id('op_r7'), '{"payment_id": "pi_opP2", "charge_id": "ch_opP2"}', 13560);
select test.eq('P (0024) the renter agrees and pays online: the booking moves at its stored rates through 0019, the payment is the difference, the task is closed',
  (select (return_at = test.at('2031-08-23 10:00')) || '/' || billable_days || '/' || rental_charge_cents || '/' || km_allowance_total || '/' || total_due_at_booking_cents from bookings where id = test.b('opP2'))
  || ' ' || (select p.purpose || ':' || p.status || ':' || p.amount_cents from payments p where p.id = (select payment_id from booking_change_requests where id = (select (r ->> 'change_request_id')::uuid from test.op_ap4)))
  || ' ' || (select status from booking_change_requests where id = (select (r ->> 'change_request_id')::uuid from test.op_ap4))
  || ' ' || (select status from tasks where booking_id = test.b('opP2') and task_type = 'booking_change_approval'),
  'true/3/32000/600/36160 extension:succeeded:13560 applied done');
select test.eq('P the return job follows the booking, and its field staff member is told the time changed',
  (select (scheduled_at = test.at('2031-08-23 10:00')) || '/' || status from field_jobs where id = test.b('jobP2'))
  || ' ' || (select (payload -> 'job_changes')::text from app_events where code = 'staff_field_job_changed' and entity_id = test.b('jobP2') order by id desc limit 1), 'true/scheduled ["time"]');
create table test.op_ap5 as select app.calendar_apply_change(test.b('opP2'), test.id('op_admin'), jsonb_build_object('return_at', test.at('2031-08-22 10:00')), 'changed their mind, agreed by phone', true) as r;
select test.eq('P moving it back the next day: less to pay becomes a refund request waiting for approval',
  (select reason || '/' || status || '/' || amount_cents from refunds where id = (select (r ->> 'refund_id')::uuid from test.op_ap5)), 'other/pending_approval/13560');
-- a car on rent: only a later return, as an extension the renter pays first
select test.eq('P a car on rent: moving the pickup is refused; a later return is an extension',
  (select r ->> 'action' from (select app.calendar_preview_change(test.b('opW'), jsonb_build_object('pickup_at', test.at('2031-07-11 10:00'))) as r) x) || '/'
  || (select r ->> 'action' from (select app.calendar_preview_change(test.b('opW'), jsonb_build_object('return_at', test.at('2031-07-13 10:00'))) as r) x), 'refused/extension');
create table test.op_ap6 as select app.calendar_apply_change(test.b('opW'), test.id('op_cs'), jsonb_build_object('return_at', test.at('2031-07-13 10:00')), 'renter asked to keep the car a day') as r;
select test.eq('P applying it records the extension request (Thursday to Sunday: $220 becomes $340) and leaves the return alone until it is paid',
  (select status || '/' || previous_days || '>' || new_days || '/' || rental_difference_cents || '/' || total_cents from booking_extensions where id = (select (r ->> 'extension_id')::uuid from test.op_ap6))
  || ' ' || (select (return_at = test.at('2031-07-12 10:00'))::text from bookings where id = test.b('opW')), 'requested/2>3/12000/13560 true');
select test.eq('Q an extension request is an urgent customer service task due at the current return time',
  (select queue || '/' || priority || '/' || (due_at = test.at('2031-07-12 10:00')) || '/' || procedure_no from tasks where booking_id = test.b('opW') and task_type = 'review_extension'), 'cs/urgent/true/6');
select test.eq('P a closed booking cannot be moved', (select r ->> 'refusal' from (select app.calendar_preview_change(test.b('opA'), jsonb_build_object('return_at', test.at('2031-05-05 10:00'))) as r) x),
  'A booking that is closed cannot be moved');

-- ------------------------------------------------------------------ rates and fees
select test.mk_vehicle('OPS', 'op_pat', 'self_managed', 45000, 2500, 0);
select test.throws('V customer service does not set rates',
  format($$select app.set_rate_card(%L, 11000, 13000, 60000, 190000, test.at('2031-01-01 00:00'), %L)$$, test.id('vehicle:OP8'), test.id('op_cs')), 'Rates are set by an Admin');
select test.throws('V every rate must be above zero',
  format($$select app.set_rate_card(%L, 11000, 0, 60000, 190000, test.at('2031-01-01 00:00'), %L)$$, test.id('vehicle:OP8'), test.id('op_admin')), 'above zero');
select test.throws('V a delivery fee outside the $75 to $200 of the fee defaults is refused',
  format($$select app.set_rate_card(%L, 11000, 13000, 60000, 190000, test.at('2031-01-01 00:00'), %L, '{"delivery_fee_cents": 5000}')$$, test.id('vehicle:OP8'), test.id('op_admin')), 'outside the range');
select app.set_rate_card(test.id('vehicle:OP8'), 11000, 13000, 60000, 190000, test.at('2031-01-01 00:00'), test.id('op_fleet'));
select app.set_rate_card(test.id('vehicle:OP8'), 12000, 14000, 65000, 200000, test.at('2031-06-01 00:00'), test.id('op_admin'), '{"deposit_cents": 150000, "delivery_fee_cents": 0}');
select test.eq('V the history is kept: each card ends where the next begins, and what was not given is carried over',
  (select string_agg(daily_rate_cents || ':' || to_char(effective_from at time zone 'America/Toronto', 'YYYY-MM-DD') || '>' || coalesce(to_char(effective_to at time zone 'America/Toronto', 'YYYY-MM-DD'), 'open')
                     || ':' || deposit_cents || ':' || delivery_fee_cents || ':' || km_allowance_per_day, ' ' order by effective_from)
     from rate_cards where vehicle_id = test.id('vehicle:OP8')),
  '10000:2026-08-31>2031-01-01:100000:7500:200 11000:2031-01-01>2031-06-01:100000:7500:200 12000:2031-06-01>open:150000:0:200');
select test.eq('V who set each card is recorded', (select string_agg(coalesce(u.full_name, '-'), ',' order by r.effective_from) from rate_cards r left join users u on u.id = r.set_by
  where r.vehicle_id = test.id('vehicle:OP8')), '-,Op Fleet,Op Admin');
select test.throws('V two cards cannot start at the same moment',
  format($$select app.set_rate_card(%L, 12500, 14000, 65000, 200000, test.at('2031-06-01 00:00'), %L)$$, test.id('vehicle:OP8'), test.id('op_admin')), 'already starts at that moment');
select app.set_rate_card(test.id('vehicle:OP8'), 11500, 13500, 62000, 195000, test.at('2031-03-01 00:00'), test.id('op_admin'));
select test.eq('V a card slotted in between ends where the later one already begins',
  (select to_char(effective_to at time zone 'America/Toronto', 'YYYY-MM-DD') from rate_cards where vehicle_id = test.id('vehicle:OP8') and daily_rate_cents = 11500), '2031-06-01');
select test.eq('V a booking made today still prices from the card in force today', (select daily_rate_cents from public_vehicle_listings where vehicle_id = test.id('vehicle:OP8')), null::bigint);
select test.throws('V an Owner does not set the rates of a car CarmaCars manages',
  format($$select app.set_rate_card(%L, 9000, 9900, 50000, 150000, test.at('2031-09-01 00:00'), %L)$$, test.id('vehicle:OP8'), test.id('op_pat')), 'Rates are set by an Admin');
select app.set_rate_card(test.id('vehicle:OPS'), 9000, 9900, 50000, 150000, test.at('2031-09-01 00:00'), test.id('op_pat'));
select test.eq('V on a Self-Managed car the Owner sets the rates, and the card says so',
  (select set_by_owner || '/' || daily_rate_cents from rate_cards where vehicle_id = test.id('vehicle:OPS') and effective_to is null), 'true/9000');
-- bulk change with preview
create table test.op_bulk as select * from app.preview_bulk_rate_change(
  jsonb_build_object('vehicle_ids', jsonb_build_array(test.id('vehicle:OP7'), test.id('vehicle:OP6'), test.id('vehicle:OPS'))), '{"percent_bps": 1250, "round_to_cents": 500}');
select test.eq('V bulk preview: up 12.5% rounded to $5; a Self-Managed car is listed and left out',
  (select string_agg(fleet_number || '=' || old_daily_cents || '>' || new_daily_cents || ':' || old_weekly_cents || '>' || new_weekly_cents || ':' || will_change || ':' || coalesce(note, '-'), ' ' order by fleet_number)
     from test.op_bulk), 'F-OP6=10000>11500:56000>63000:true:- F-OP7=10000>11500:56000>63000:true:- F-OPS=10000>11500:56000>63000:false:Self-Managed: the Owner sets the rates');
select test.eq('V a preview writes nothing', (select count(*) from rate_cards where vehicle_id in (test.id('vehicle:OP6'), test.id('vehicle:OP7'))), 2::bigint);
select test.throws('V only an Admin applies a bulk change',
  format($$select app.apply_bulk_rate_change(%L, '{"percent_bps": 1250}', %L)$$, jsonb_build_object('vehicle_ids', jsonb_build_array(test.id('vehicle:OP7'))), test.id('op_fleet')), 'Only an Admin');
select test.eq('V applying it changes the two cars that the preview said would change',
  app.apply_bulk_rate_change(jsonb_build_object('vehicle_ids', jsonb_build_array(test.id('vehicle:OP7'), test.id('vehicle:OP6'), test.id('vehicle:OPS'))),
                             '{"percent_bps": 1250, "round_to_cents": 500}', test.id('op_admin'), test.at('2032-01-01 00:00')), 2);
select test.eq('V each gets a new card from the date given, and the old one is kept',
  (select string_agg(daily_rate_cents || '@' || to_char(effective_from at time zone 'America/Toronto', 'YYYY'), '>' order by effective_from) from rate_cards where vehicle_id = test.id('vehicle:OP7')),
  '10000@2026>11500@2032');
select test.eq('V a bulk change can be limited to some rates: only the weekend rate, by $10',
  (select old_daily_cents || '>' || new_daily_cents || '/' || old_weekend_cents || '>' || new_weekend_cents
     from app.preview_bulk_rate_change(jsonb_build_object('vehicle_ids', jsonb_build_array(test.id('vehicle:OP7'))), '{"add_cents": 1000, "fields": ["weekend"]}')), '10000>10000/12000>13000');
-- per-vehicle fee overrides
select test.throws('V only charges marked "V" can be set per vehicle',
  format($$select app.set_vehicle_fee_override(%L, 'cleaning', %L, 'white interior', 12000)$$, test.id('vehicle:OP7'), test.id('op_admin')), 'cannot be set per vehicle');
select test.throws('V only an Admin sets a fee for one vehicle',
  format($$select app.set_vehicle_fee_override(%L, 'mileage_overage', %L, 'high-mileage lease', 50)$$, test.id('vehicle:OP7'), test.id('op_fleet')), 'Only an Admin');
select app.set_vehicle_fee_override(test.id('vehicle:OP7'), 'mileage_overage', test.id('op_admin'), 'high-mileage lease', 50, null, null, app.today() - 10);
select app.set_vehicle_fee_override(test.id('vehicle:OP7'), 'mileage_overage', test.id('op_admin'), 'lease renewed', 45, null, null, app.today() - 2);
select test.eq('V a new override closes the one in force and keeps it; the fee resolves to the vehicle''s value',
  (select string_agg(amount_cents || ':' || (effective_to is not null), ' ' order by effective_from) from vehicle_fee_overrides where vehicle_id = test.id('vehicle:OP7') and fee_type_code = 'mileage_overage')
  || ' ' || (select amount_cents || '/' || source from public.effective_fee('mileage_overage', test.id('vehicle:OP7'))), '50:true 45:false 45/vehicle');
select test.eq('V a booking confirmed before the override keeps the term written on it', (select amount_cents || '/' || source from app.booking_fee_term(test.b('opP2'), 'mileage_overage')), '35/default');
select test.eq('V a request not yet confirmed resolves to the vehicle''s value', (select amount_cents || '/' || source from app.booking_fee_term(test.b('opP1'), 'mileage_overage')), '45/vehicle');
select app.end_vehicle_fee_override(test.id('vehicle:OP7'), 'mileage_overage', test.id('op_admin'));
select test.eq('V ending the override brings the default back', (select amount_cents || '/' || source from public.effective_fee('mileage_overage', test.id('vehicle:OP7'), app.today() + 1)), '35/default');
select test.eq('V per-booking terms: an Admin''s override is marked as such and wins',
  (select amount_cents || '/' || source from app.booking_fee_term(test.b('opA'), 'cleaning')) || ' '
  || (select source || '/' || (override_by = test.id('op_admin')) || '/' || override_reason from booking_fee_terms where booking_id = test.b('opA') and fee_type_code = 'cleaning'),
  '7500/booking booking/true/back to the standard fee');
select test.throws('V fixed charges cannot be overridden on a booking',
  format($$select app.set_booking_fee_term(%L, 'deductible', %L, 'goodwill', 100000)$$, test.b('opP2'), test.id('op_admin')), 'fixed');
-- an Admin changes a default: the next booking's snapshot and its charges follow
insert into fee_defaults (fee_type_code, amount_cents, effective_from, set_by) values ('smoking', 35000, app.today(), test.id('op_admin'));
update fee_defaults set effective_to = app.today() where fee_type_code = 'smoking' and effective_from < app.today();
select test.rq_new('opF', 'op_r1', 'OP1', '2031-11-06 10:00', '2031-11-08 10:00');
select test.op_confirm('opF', 'op_r1');
select test.eq('V after an Admin raises the smoking fee to $350, a booking confirmed afterwards carries $350; an earlier one keeps $300',
  (select amount_cents from booking_fee_terms where booking_id = test.b('opF') and fee_type_code = 'smoking') || '/'
  || (select amount_cents from booking_fee_terms where booking_id = test.b('opA') and fee_type_code = 'smoking'), '35000/30000');

-- ------------------------------------------------------------------ the other task triggers
-- cancellation: Finance refunds; the booking's jobs and open tasks are cancelled
select test.rq_new('opX', 'op_r2', 'OP8', '2031-10-02 10:00', '2031-10-04 10:00');
select test.op_confirm('opX', 'op_r2', false);
insert into test.rq_ids values ('jobX', app.create_field_job('handover', test.id('vehicle:OP8'), test.at('2031-10-02 10:00'), test.id('op_fleet'), test.b('opX'), test.id('op_field')));
insert into booking_cancellations (booking_id, received_at, cancelled_by, reason) values (test.b('opX'), now(), 'renter', 'renter_request');
select test.eq('Q a cancellation with a refund is a Finance task, due in 10 business days',
  (select queue || '/' || priority || '/' || procedure_no || '/' || (due_at = app.local_midnight(app.add_business_days(app.today(), 10) + 1)) from tasks
    where booking_id = test.b('opX') and task_type = 'refund_cancellation'), 'finance/normal/7/true');
update bookings set status = 'cancelled' where id = test.b('opX');
select test.eq('Q cancelling the booking cancels its open job (the assignee is told) and the tasks that no longer apply',
  (select status || '/' || cancel_reason from field_jobs where id = test.b('jobX'))
  || ' ' || (select payload ->> 'job_cancelled' from app_events where code = 'staff_field_job_changed' and entity_id = test.b('jobX') order by id desc limit 1)
  || ' ' || (select string_agg(task_type || ':' || status, ' ' order by task_type) from tasks where booking_id = test.b('opX') and task_type in ('schedule_handover', 'offer_approved_paid', 'refund_cancellation')),
  'cancelled/Booking cancelled true offer_approved_paid:cancelled refund_cancellation:open schedule_handover:cancelled');
-- identity documents and coverage proof to review
select test.rq_new('opV', 'op_r3', 'OP4', '2031-09-04 10:00', '2031-09-06 10:00');
select test.op_confirm('opV', 'op_r3', false);
insert into identity_verifications (driver_id, booking_id, method, status) values (test.id('driver:op_r3'), test.b('opV'), 'staff_review', 'pending');
insert into coverage_proofs (booking_id, coverage_option, status) values (test.b('opV'), 1, 'submitted');
select test.eq('Q identity documents and coverage proof to review: one customer service task per booking, due 24 hours before pickup',
  (select count(*) || '/' || min(queue) || '/' || min(priority) || '/' || bool_and(due_at = test.at('2031-09-03 10:00')) || '/' || bool_and(renter_id = test.id('renter:op_r3'))
     from tasks where booking_id = test.b('opV') and task_type = 'verify_renter'), '1/cs/high/true/true');
select test.throws('Q a verification task is not done until every driver is verified or rejected',
  format($$select app.complete_task((select id from tasks where booking_id = %L and task_type = 'verify_renter'), %L)$$, test.b('opV'), test.id('op_cs')), 'Every driver must be verified');
-- owner side: application, upfront invoice, failed debit, arrears, draft statements, exit, listing, document
select test.mk_vehicle('OPN', 'op_pat', 'turo_only', 0, 0, 2500);
insert into vehicle_onboardings (id, vehicle_id) values (test.id('onb:OPN'), test.id('vehicle:OPN'));
select test.eq('Q a new owner application is a customer service task due in 1 business day',
  (select queue || '/' || procedure_no || '/' || (owner_id = test.id('owner:op_pat')) || '/' || (due_at = app.local_midnight(app.add_business_days(app.today(), 1) + 1))
     from tasks where related_id = test.id('onb:OPN') and task_type = 'owner_intake'), 'cs/12/true/true');
insert into owner_invoices (id, owner_id, vehicle_id, kind, billing_date, status, fees_cents) values (test.id('inv:op:up'), test.id('owner:op_pat'), test.id('vehicle:OP8'), 'upfront', app.today(), 'issued', 10000);
insert into owner_invoices (id, owner_id, vehicle_id, kind, period_month, billing_date, status, fees_cents)
values (test.id('inv:op:m'), test.id('owner:op_pat'), test.id('vehicle:OP8'), 'monthly', date '2031-08-01', date '2031-08-15', 'issued', 47500);
update owner_invoices set status = 'failed' where id = test.id('inv:op:m');
update owner_invoices set status = 'in_arrears', removal_allowed_on = date '2031-08-20' where id = test.id('inv:op:m');
select test.eq('Q an upfront invoice, a failed debit and arrears are each a Finance task',
  (select string_agg(task_type || ':' || queue || ':' || procedure_no, ' ' order by task_type) from tasks where related_id in (test.id('inv:op:up'), test.id('inv:op:m'))
      and task_type in ('arrears', 'collect_upfront', 'debit_failed')),
  'arrears:finance:14 collect_upfront:finance:12 debit_failed:finance:14');
insert into owner_statements (owner_id, statement_month, payout_date) values (test.id('owner:op_pat'), date '2031-08-01', date '2031-09-10'), (test.id('owner:op_owen'), date '2031-08-01', date '2031-09-10');
select test.eq('Q draft owner statements: one Finance review task for the month, due before the payout date',
  (select count(*) || '/' || min(queue) || '/' || bool_and(due_at = test.at('2031-09-10 00:00')) from tasks where dedupe_key = 'review_statements:2031-08'), '1/finance/true');
insert into vehicle_exits (id, vehicle_id, initiated_by, notice_received_at, notice_ends_on, exit_date) values (test.id('exit:OP8'), test.id('vehicle:OP8'), 'owner', now(), date '2031-12-01', date '2031-12-01');
select test.eq('Q an exit notice is a Fleet task due on the Exit Date', (select queue || '/' || procedure_no || '/' || (due_at = test.at('2031-12-01 00:00')) from tasks where related_id = test.id('exit:OP8')), 'fleet/16/true');
insert into documents (id, kind, storage_bucket, storage_path, owner_id, uploaded_by) values (test.id('doc:op:pat'), 'owner_insurance_proof', 'agreements', 'owners/op_pat/insurance.pdf', test.id('owner:op_pat'), test.id('op_pat'));
insert into documents (id, kind, storage_bucket, storage_path, owner_id, uploaded_by) values (test.id('doc:op:staff'), 'owner_insurance_proof', 'agreements', 'owners/op_pat/insurance2.pdf', test.id('owner:op_pat'), test.id('op_cs'));
select test.eq('Q a document the Owner uploads is a customer service task; one staff upload is not',
  (select count(*) from tasks where related_id = test.id('doc:op:pat') and task_type = 'check_owner_document' and queue = 'cs') || '/' || (select count(*) from tasks where related_id = test.id('doc:op:staff')), '1/0');
update vehicle_onboardings set status = 'terms_set' where id = test.id('onb:OPN');
update vehicle_onboardings set status = 'documents_sent' where id = test.id('onb:OPN');
insert into test.rq_ids values ('revA', app.submit_review(test.b('opA'), test.id('op_r1'), 5, 'Great car', 'Clean and on time'));
select test.eq('Q a review left by a renter is a low-priority customer service task',
  (select queue || '/' || priority from tasks where task_type = 'moderate_review' and related_id = test.b('revA')), 'cs/low');
-- a detail job: belongings found
insert into test.rq_ids values ('jobDt', app.create_field_job('detail', test.id('vehicle:OP1'), test.at('2031-05-04 15:00'), test.id('op_fleet'), null, test.id('op_field2'), 'CarmaCars lot'));
select app.start_field_job(test.b('jobDt'), test.id('op_field2'), test.at('2031-05-04 15:00'));
select app.complete_field_job(test.b('jobDt'), test.id('op_field2'), '{"cleaning_grade": "standard", "belongings_found": "sunglasses, bagged", "fuel_or_charge_ok": true, "odometer_km": 20752}', test.at('2031-05-04 16:10'));
select test.eq('Q a detail job done: its grade and move are recorded, and belongings found are a customer service task',
  (select status || '/' || cleaning_grade || '/' || fuel_or_charge_ok from field_jobs where id = test.b('jobDt'))
  || ' ' || (select purpose || '/' || (ended_at = test.at('2031-05-04 16:10')) || '/' || odometer_end from vehicle_moves where field_job_id = test.b('jobDt'))
  || ' ' || (select queue || '/' || detail from tasks where related_id = test.b('jobDt') and task_type = 'lost_property'), 'done/standard/true detail/true/20752 cs/sunglasses, bagged');

-- ------------------------------------------------------------------ working a task
insert into test.rq_ids values ('tk1', app.raise_task(p_type => 'collect_upfront', p_title => 'Collect a test invoice', p_dedupe => 'op:tk1'));
select test.eq('Q a dedupe key gives one open task', app.raise_task(p_type => 'collect_upfront', p_dedupe => 'op:tk1'), test.b('tk1'));
select test.throws('Q an assistant of another function cannot take a finance task', format('select app.assign_task(%L, %L, %L)', test.b('tk1'), test.id('op_cs'), test.id('op_cs')), 'Not permitted on the finance queue');
select test.throws('Q a task is handed only to someone who works that queue', format('select app.assign_task(%L, %L, %L)', test.b('tk1'), test.id('op_cs'), test.id('op_fin')), 'does not work the finance queue');
select app.assign_task(test.b('tk1'), test.id('op_fin'), test.id('op_fin'));
select test.eq('Q taking a task starts it', (select status || '/' || (assigned_to = test.id('op_fin')) from tasks where id = test.b('tk1')), 'in_progress/true');
select test.throws('Q waiting needs a reason and a time ahead', format($$select app.snooze_task(%L, %L, now() + interval '1 day', '')$$, test.b('tk1'), test.id('op_fin')), 'waiting for');
select app.snooze_task(test.b('tk1'), test.id('op_fin'), now() + interval '2 days', 'owner pays on Friday');
select test.eq('Q a waiting task leaves the queue until its time', (select status || '/' || waiting_reason from tasks where id = test.b('tk1')) || '/' || app.wake_tasks(now() + interval '1 day'), 'waiting/owner pays on Friday/0');
select test.eq('Q and comes back by itself', app.wake_tasks(now() + interval '3 days'), 1);
select test.eq('Q to the person who had it', (select status from tasks where id = test.b('tk1')), 'in_progress');
insert into test.rq_ids values ('tk1a', app.escalate_task(test.b('tk1'), test.id('op_fin'), 'owner disputes the invoice'));
select test.eq('Q escalating flags the task, puts a copy in the admin queue and emits staff_approval_needed',
  (select escalated || '/' || escalation_reason from tasks where id = test.b('tk1'))
  || ' ' || (select queue || '/' || priority || '/' || escalated || '/' || (related_id = test.b('tk1')) from tasks where id = test.b('tk1a'))
  || ' ' || test.op_events('staff_approval_needed', test.b('tk1a')), 'true/owner disputes the invoice admin/high/true/true 1');
select app.complete_task(test.b('tk1'), test.id('op_fin'), 'paid by e-Transfer');
select test.eq('Q done, with who and the note', (select status || '/' || (completed_by = test.id('op_fin')) || '/' || completion_note from tasks where id = test.b('tk1')), 'done/true/paid by e-Transfer');
select test.throws('Q a finished task is not finished twice', format('select app.complete_task(%L, %L)', test.b('tk1'), test.id('op_fin')), 'already done');
select test.throws('Q an assistant cannot force a task whose rule does not hold',
  format($$select app.complete_task((select id from tasks where booking_id = %L and task_type = 'verify_renter'), %L, 'will do later', true)$$, test.b('opV'), test.id('op_cs')), 'Every driver must be verified');
select test.lives('Q an Admin can, with a note',
  format($$select app.complete_task((select id from tasks where booking_id = %L and task_type = 'verify_renter'), %L, 'verified on paper at the counter', true)$$, test.b('opV'), test.id('op_admin')));
-- an Admin changes how long a task may wait: the next task follows
update task_rules set due_kind = 'minutes', due_amount = 45, priority = 'urgent' where task_type = 'moderate_review';
insert into test.rq_ids values ('tk2', app.raise_task(p_type => 'moderate_review', p_dedupe => 'op:tk2'));
select test.eq('Q the due time and priority of a task come from its rule, which an Admin can change',
  (select priority || '/' || sla_minutes || '/' || (due_at = created_at + interval '45 minutes') from tasks where id = test.b('tk2')), 'urgent/45/true');

-- ------------------------------------------------------------------ scheduled jobs
-- ops-watch at 08:30 on September 4, 2031. V is picked up at 10:00 that day, unverified, no Deposit, and does not block the car.
insert into test.rq_ids values ('jobV', app.create_field_job('handover', test.id('vehicle:OP4'), test.at('2031-09-04 10:00'), test.id('op_fleet'), test.b('opV'), test.id('op_field')));
select app.set_blocks_calendar(test.b('opV'), false, test.id('op_cs'), 'insurer has not confirmed the dates');
select test.rq_new('opO', 'op_r4', 'OP1', '2031-09-10 10:00', '2031-09-12 10:00');
select app.send_offer(test.b('opO'), test.id('op_cs'), null, test.at('2031-09-04 12:00'));
select test.eq('J ops-watch runs and reports', app.job_ops_watch(test.at('2031-09-04 08:30')), 'succeeded');
select test.eq('J pickup today: verification missing (customer service), Deposit not taken (Finance, due an hour before), dates not settled (customer service)',
  (select string_agg(task_type || ':' || queue || ':' || to_char(due_at at time zone 'America/Toronto', 'MM-DD HH24:MI'), ' ' order by task_type) from tasks
    where booking_id = test.b('opV') and task_type in ('chase_verification', 'take_deposit', 'insurer_provisional') and status = 'open'),
  'chase_verification:cs:09-04 08:30 insurer_provisional:cs:09-03 10:00 take_deposit:finance:09-04 09:00');
select test.eq('J a job 90 minutes away that nobody acknowledged is a Fleet task',
  (select queue || '/' || priority || '/' || title from tasks where related_id = test.b('jobV') and task_type = 'job_unacknowledged'), 'fleet/high/Handover job at 10:00: not acknowledged');
select test.eq('J an offer expiring within 6 hours goes to Sales', test.op_tasks('opO', 'chase_offer'), '1:sales:normal');
select test.eq('J a car still out after its return time: an urgent Fleet task, and an Admin once it is 2 hours overdue',
  test.op_tasks('opW', 'late_return') || ' ' || test.op_tasks('opW', 'late_return_admin'), '1:fleet:urgent 1:admin:urgent');
select test.eq('J the opening checks are raised an hour before they are due, the closing checks not yet',
  (select string_agg(task_type || ':' || to_char(due_at at time zone 'America/Toronto', 'HH24:MI'), ' ') from tasks where dedupe_key in ('opening_checks:2031-09-04', 'closing_checks:2031-09-04')), 'opening_checks:09:00');
select test.eq('J a second run a minute later has nothing new to do', app.job_ops_watch(test.at('2031-09-04 08:31')), 'not_due');
select test.eq('J the run is recorded once, with what it did', (select count(*) || '/' || (min(summary ->> 'tasks_raised')::integer > 5) from job_runs where job_name = 'ops-watch'), '1/true');
select app.job_ops_watch(test.at('2031-09-30 12:00'));
select test.eq('J on the business day before the 1st, Finance is asked for the fleet report (September 30, 2031 is a Tuesday)',
  (select queue || ':' || (due_at = test.at('2031-10-02 00:00')) from tasks where dedupe_key = 'fleet_report:2031-10'), 'finance:true');
select test.eq('J ops-watch sends nothing and disables nothing: it only raises tasks',
  (select count(*) from tracker_commands where created_at > now() - interval '1 minute' and requested_by is null) || '/' || (select count(*) from app_events where code like 'renter_late%' and created_at >= (select min(started_at) from job_runs where job_name = 'ops-watch')), '0/0');

-- deposits-due at 06:00 on September 10, 2031
select test.mk_booking('OPJ1', 'OP7', 'op_r7', '2030-03-01 10:00', '2030-03-03 10:00', 'returned');
select test.mk_booking('OPJ2', 'OP7', 'op_r7', '2030-03-05 10:00', '2030-03-07 10:00', 'returned');
select test.mk_booking('OPJ3', 'OP7', 'op_r7', '2030-03-09 10:00', '2030-03-11 10:00', 'returned');
insert into deposits (id, booking_id, amount_cents, method, status, release_due_on, held_back_cents, held_back_reason, held_back_until, applied_cents, released_cents, release_approved_by) values
  (test.id('dep:OPJ1'), test.id('booking:OPJ1'), 100000, 'card_hold', 'held', date '2031-09-12', 0, null, null, 0, 0, null),
  (test.id('dep:OPJ2'), test.id('booking:OPJ2'), 100000, 'card_hold', 'held', date '2031-09-02', 0, null, null, 0, 0, null),
  (test.id('dep:OPJ3'), test.id('booking:OPJ3'), 100000, 'card_hold', 'captured', date '2031-08-20', 20000, 'toll expected', date '2031-09-12', 0, 80000, test.id('op_admin'));
select test.eq('J deposits-due: too early before 06:00', app.job_deposits_due(test.at('2031-09-10 05:59')), 'not_due');
select test.eq('J deposits-due: runs from 06:00', app.job_deposits_due(test.at('2031-09-10 06:00')), 'succeeded');
select test.eq('J deposits-due: once a day', app.job_deposits_due(test.at('2031-09-10 09:00')), 'already_run');
select test.eq('J a Deposit due back within 2 business days is a Finance task; one already past its 7 business days is urgent',
  (select string_agg(t.priority || ':' || t.queue || ':' || to_char(t.due_at at time zone 'America/Toronto', 'MM-DD'), ' ' order by t.due_at)
     from tasks t where t.task_type = 'release_deposit' and t.related_id in (test.id('dep:OPJ1'), test.id('dep:OPJ2'))), 'urgent:finance:09-03 high:finance:09-13');
select test.eq('J a hold-back within 3 days of its last day is a Finance task; a Deposit with nothing left to release is not listed',
  (select count(*) filter (where task_type = 'settle_holdback') || '/' || count(*) filter (where task_type = 'release_deposit') || '/' || min(detail) filter (where task_type = 'settle_holdback')
     from tasks where related_id = test.id('dep:OPJ3')), '1/0/Held back for: toll expected. Apply it or release it by that day.');
select test.eq('J the run keeps its counts', (select summary - 'day' from job_runs where job_name = 'deposits-due' and run_key = '2031-09-10') ->> 'holdbacks_due', '1');

-- expiry-watch at 06:00 on September 1, 2031
insert into turo_listings (id, vehicle_id, status, owner_insurance_expires_on, plate_expires_on) values (test.id('tl:OPT'), test.id('vehicle:OPT'), 'listed', date '2031-09-10', date '2032-03-01');
select test.eq('J expiry-watch: runs from 06:00, once a day', app.job_expiry_watch(test.at('2031-09-01 05:00')) || '/' || app.job_expiry_watch(test.at('2031-09-01 06:00')) || '/' || app.job_expiry_watch(test.at('2031-09-01 07:00')),
  'not_due/succeeded/already_run');
select test.eq('J Turo-Only insurance expiring within 14 days: a customer service task due on the expiry date, and the Owner''s notice event',
  (select queue || '/' || (due_at = test.at('2031-09-10 00:00')) from tasks where related_id = test.id('tl:OPT') and task_type = 'turo_expiry')
  || ' ' || (select count(*) || ':' || min(payload ->> 'expires_on') from app_events where code = 'owner_document_due' and entity_id = test.id('vehicle:OPT')), 'cs/true 1:2031-09-10');
select test.eq('J arrears past the removal date: an Admin task; and one staff_expiry_watch event listing what was found',
  (select queue || '/' || priority from tasks where related_id = test.id('inv:op:m') and task_type = 'arrears_removal')
  || ' ' || (select count(*) || ':' || ((min(payload ->> 'expiry_count'))::integer >= 2) from app_events where code = 'staff_expiry_watch' and payload ->> 'day' = '2031-09-01'), 'admin/high 1:true');

-- ------------------------------------------------------------------ reconciliation (procedure 19)
insert into payment_processor_details (payment_id, processor_payment_id, balance_transaction_id)
select id, 'pi_op_a', 'txn_op_1' from payments where booking_id = test.b('opA') and kind = 'capture';
insert into test.rq_ids values ('po1', app.record_processor_payout('po_op_1', date '2031-05-08', 53800,
  '[{"ref": "txn_op_1", "amount_cents": 45483, "fee_cents": 1349}, {"ref": "txn_op_2", "payment_ref": "pi_unknown", "amount_cents": 9900, "fee_cents": 317},
    {"ref": "txn_fee_1", "kind": "fee", "amount_cents": -100}]'));
select test.eq('N a payout: the item whose processor reference and amount agree is matched to its payment, the fee line needs none, the stranger stays unmatched',
  (select string_agg(processor_ref || ':' || status || ':' || (payment_id is not null), ' ' order by processor_ref) from payout_reconciliation_items where reconciliation_id = test.b('po1'))
  || ' ' || (select status || '/' || item_count || '/' || matched_cents || '/' || unmatched_cents || '/' || fees_cents from payout_reconciliations where id = test.b('po1')),
  'txn_fee_1:resolved:false txn_op_1:matched:true txn_op_2:unmatched:false unmatched/3/45483/9900/1766');
select test.eq('N anything unmatched is a Finance task for the same day', (select queue || '/' || priority || '/' || status || '/' || procedure_no from tasks where related_id = test.b('po1') and task_type = 'reconcile'), 'finance/high/open/19');
select test.eq('N recording the same payout again adds nothing', (select count(*) from payout_reconciliation_items where reconciliation_id =
  app.record_processor_payout('po_op_1', date '2031-05-08', 53800, '[{"ref": "txn_op_1", "amount_cents": 45483}]')), 3::bigint);
select test.throws('N the task stays open while an item is unmatched',
  format($$select app.complete_task((select id from tasks where related_id = %L and task_type = 'reconcile'), %L)$$, test.b('po1'), test.id('op_fin')), 'still has unmatched items');
select test.throws('N linking an item to a payment of another amount needs an explanation',
  format($$select app.match_payout_item((select id from payout_reconciliation_items where processor_ref = 'txn_op_2'), %L, (select id from payments where booking_id = %L and purpose = 'post_rental'))$$,
         test.id('op_fin'), test.b('opB')), 'amounts differ');
select test.throws('N only an Admin closes an item that has no payment',
  format($$select app.match_payout_item((select id from payout_reconciliation_items where processor_ref = 'txn_op_2'), %L, null, 'bank error')$$, test.id('op_fin')), 'Only an Admin closes');
select test.eq('N Finance links the item by hand with a note: the payout is matched and the task closes',
  (select app.match_payout_item((select id from payout_reconciliation_items where processor_ref = 'txn_op_2'), test.id('op_fin'),
                                (select id from payments where booking_id = test.b('opB') and purpose = 'post_rental'), 'part of a split payment, see processor note')), 'matched');
select test.eq('N and the task is closed', (select status from tasks where related_id = test.b('po1') and task_type = 'reconcile'), 'done');
select test.eq('N the reconcile job: from 18:00, once a day',
  app.job_reconcile(test.at('2031-09-10 17:59')) || '/' || app.job_reconcile(test.at('2031-09-10 18:00')) || '/' || app.job_reconcile(test.at('2031-09-10 19:00')), 'not_due/succeeded/already_run');
select test.eq('N it flags card payments no payout has carried, but not the ones that were matched',
  (select (count(*) > 0) || ':' || min(queue) from tasks where task_type = 'unmatched_payment')
  || ' ' || (select count(*) from tasks t where t.task_type = 'unmatched_payment' and t.related_id in (select payment_id from payout_reconciliation_items where payment_id is not null)),
  'true:finance 0');

-- ------------------------------------------------------------------ the swapped booking comes back: kilometres across two cars
create table test.op_outW as select test.op_return('opW', 'op_fleet', '2031-07-12 10:00', 20400) as r;
select test.eq('W kilometres across the swap: 200 on the first car (5,000 to 5,200) and 100 on the second (20,300 to 20,400)',
  (select r ->> 'km_driven' from test.op_outW) || '/' || app.booking_km_driven(test.b('opW')), '300/300');
select test.eq('W the return closes the late-return tasks and moves the replacement car to cleaning',
  (select string_agg(distinct status, ',') from tasks where booking_id = test.b('opW') and task_type in ('late_return', 'late_return_admin'))
  || '/' || (select status::text from vehicles where id = test.id('vehicle:OP5')), 'done/cleaning');

-- ------------------------------------------------------------------ row-level security, role by role
-- a job for today, so the field staff member's time window is open
insert into test.rq_ids values ('jobNow', app.create_field_job('detail', test.id('vehicle:OP8'), now() + interval '1 hour', test.id('op_fleet'), null, test.id('op_field'), 'CarmaCars lot'));
insert into quick_replies (title, body, is_active) values ('Licence type', 'Which class of licence do you hold?', true), ('Old snippet', 'no longer used', false);

-- field staff: their own jobs and moves, nothing else
select test.login(test.id('op_field'));
select test.eq('field: today''s and tomorrow''s list holds his own job, with the car and nothing about money or contact details',
  (select count(*) || '/' || min(kind) || '/' || min(vehicle_label) || '/' || bool_and(list_day in ('today', 'tomorrow')) from field_job_list)
  || ' ' || (select count(*) from information_schema.columns where table_name = 'field_job_list' and column_name ~ '(email|mobile|phone|address|licence|cents|card|legal_name)'),
  '1/detail/2023 Mercedes-Benz C 300 OP8/true 0');
select test.eq('field: the same list by function, for himself', (select count(*) from app.staff_field_jobs(test.id('op_field'), app.local_date(now() + interval '1 hour'))), 1::bigint);
select test.throws('field: not another staff member''s list', format('select * from app.staff_field_jobs(%L)', test.id('op_field2')), 'Not permitted');
select test.eq('field: sees only the moves he drove', (select bool_and(staff_user_id = test.id('op_field')) || '/' || (count(*) >= 2) from vehicle_moves), 'true/true');
select test.throws('field: cannot record a move himself', format($$insert into vehicle_moves (vehicle_id, staff_user_id, purpose, started_at, created_by) values (%L, %L, 'other', now(), %L)$$,
  test.id('vehicle:OP8'), test.id('op_field'), test.id('op_field')), 'row-level security');
select test.eq('field: may read the photo list; no task rules, quick replies, incident steps, payouts, queues or calendar',
  (test.visible('select * from required_shots') > 0) || '/' || (test.visible('select * from task_rules') + test.visible('select * from quick_replies') + test.visible('select * from incident_steps')
  + test.visible('select * from payout_reconciliations') + test.visible('select * from payout_reconciliation_items') + test.visible('select * from work_queue')
  + test.visible('select * from va_fleet_queue') + test.visible('select * from calendar_entries')), 'true/0');
select test.throws('field: cannot call the handover function directly', format($$select app.complete_handover(%L, %L, '{}')$$, test.b('opF'), test.id('op_field')), 'permission denied');
select test.throws('field: nor the preview of a calendar change', format($$select app.calendar_preview_change(%L, '{}')$$, test.b('opF')), 'Not permitted');
select test.throws('field: nor the vehicle calendar', format($$select * from app.vehicle_calendar(%L, now(), now() + interval '1 day')$$, test.id('vehicle:OP8')), 'Not permitted');
select test.logout();

-- another field staff member sees none of it
select test.login(test.id('op_field2'));
select test.eq('field: another staff member''s jobs and moves are invisible',
  test.visible('select * from field_job_list') + test.visible(format('select * from vehicle_moves where staff_user_id = %L', test.id('op_field'))), 0::bigint);
select test.logout();

-- Fleet
select test.login(test.id('op_fleet'));
select test.eq('fleet: all vehicle moves, the staff lists, the fleet queue; not the finance, customer service or admin queue',
  (test.visible('select * from vehicle_moves') >= 3) || '/' || (select count(*) from app.staff_field_jobs(test.id('op_field'), app.local_date(now() + interval '1 hour')))
  || '/' || (test.visible('select * from va_fleet_queue') > 0) || '/' || (test.visible('select * from va_finance_queue') + test.visible('select * from va_cs_queue') + test.visible('select * from admin_queue')
  + test.visible($$select * from work_queue where queue <> 'fleet'$$)), 'true/1/true/0');
select test.lives('fleet: may record a staff move', format($$insert into vehicle_moves (vehicle_id, staff_user_id, purpose, started_at, ended_at, from_place, to_place, created_by)
  values (%L, %L, 'service', now() - interval '2 hours', now() - interval '1 hour', 'lot', 'tire shop', %L)$$, test.id('vehicle:OP8'), test.id('op_field2'), test.id('op_fleet')));
select test.eq('fleet: may correct a move', test.affected($$update vehicle_moves set notes = 'winter tires' where purpose = 'service'$$), 1::bigint);
select test.eq('fleet: reads the task rules and the photo list but changes neither',
  (test.visible('select * from task_rules') > 40) || '/' || test.affected($$update task_rules set priority = 'low'$$) || '/' || test.affected('update required_shots set is_required = false'), 'true/0/0');
select test.eq('fleet: works the incident steps that are not an Admin''s, in his own name',
  test.affected(format($$update incident_steps set done_at = now(), done_by = %L where incident_id = %L and step_code = 'roadside'$$, test.id('op_fleet'), test.b('incW')))
  || '/' || test.affected($$update incident_steps set done_at = now(), done_by = app.uid() where owner_role = 'admin'$$), '1/0');
select test.throws('fleet: cannot tick a step in someone else''s name',
  format($$update incident_steps set done_at = now(), done_by = %L where incident_id = %L and step_code = 'cause'$$, test.id('op_admin'), test.b('incW')), 'your own approval');
select test.eq('fleet: no payout reconciliation', test.visible('select * from payout_reconciliations') + test.visible('select * from payout_reconciliation_items'), 0::bigint);
select test.eq('fleet: field jobs and staff moves are on the calendar', (select string_agg(distinct entry_type, ',' order by entry_type) from calendar_entries where vehicle_id = test.id('vehicle:OP2')),
  'booking,field_job,vehicle_move');
select test.eq('fleet: may preview a calendar change', (select app.calendar_preview_change(test.b('opF'), jsonb_build_object('return_at', test.at('2031-11-09 10:00'))) ->> 'action'), 'renter_approval');
select test.throws('fleet: but cannot apply one from the browser', format($$select app.calendar_apply_change(%L, %L, '{}', 'x')$$, test.b('opF'), test.id('op_fleet')), 'permission denied');
select test.logout();

-- Finance
select test.login(test.id('op_fin'));
select test.eq('finance: reads staff moves (proof for tolls) but records none',
  (test.visible('select * from vehicle_moves') >= 4)::text, 'true');
select test.throws('finance: cannot record a move', format($$insert into vehicle_moves (vehicle_id, staff_user_id, purpose, started_at, created_by) values (%L, %L, 'other', now(), %L)$$,
  test.id('vehicle:OP8'), test.id('op_field'), test.id('op_fin')), 'row-level security');
select test.eq('finance: reads the payouts and their items; cannot change them from the browser',
  (test.visible('select * from payout_reconciliations') > 0) || '/' || (test.visible('select * from payout_reconciliation_items') >= 3), 'true/true');
select test.throws('finance: no direct write to a payout item', $$update payout_reconciliation_items set status = 'resolved', note = 'x'$$, 'permission denied');
select test.eq('finance: the finance queue only, with the record each task is about',
  (test.visible('select * from va_finance_queue') > 0) || '/' || (test.visible('select * from va_fleet_queue') + test.visible('select * from va_cs_queue') + test.visible('select * from va_sales_queue') + test.visible('select * from admin_queue'))
  || '/' || (select bool_and(queue = 'finance') from work_queue)
  || '/' || (select booking_number is not null and renter_first_name = 'Op' from va_finance_queue where task_type = 'refund_cancellation' and booking_id = test.b('opX')), 'true/0/true/true');
select test.eq('finance: the queue shows a first name, never the full renter record',
  (select count(*) from information_schema.columns where table_name = 'work_queue' and column_name ~ '(email|mobile|phone|address|licence|legal_name)'), 0::bigint);
select test.eq('finance: staff moves are on the calendar for him; reads incident steps', (select count(*) > 0 from calendar_entries where entry_type = 'vehicle_move')
  || '/' || (test.visible('select * from incident_steps') > 0) || '/' || test.affected('update incident_steps set note = ''x'''), 'true/true/0');
select test.throws('finance: cannot settle a Deposit from the browser', format('select app.settle_deposit(%L, %L)', test.b('opF'), test.id('op_fin')), 'permission denied');
select test.logout();

-- Customer service
select test.login(test.id('op_cs'));
select test.eq('cs: no staff moves, no payouts; reads incident steps and the active quick replies only',
  (test.visible('select * from vehicle_moves') + test.visible('select * from payout_reconciliations')) || '/' || (test.visible('select * from incident_steps') > 0)
  || '/' || (select string_agg(title, ',') from quick_replies), '0/true/Licence type');
select test.eq('cs: cannot add or change a quick reply', test.affected($$update quick_replies set body = 'x'$$), 0::bigint);
select test.throws('cs: nor insert one', $$insert into quick_replies (title, body) values ('x', 'y')$$, 'row-level security');
select test.eq('cs: the customer service queue only', (test.visible('select * from va_cs_queue') > 0) || '/' || (test.visible('select * from va_finance_queue') + test.visible('select * from va_fleet_queue') + test.visible('select * from admin_queue')), 'true/0');
select test.eq('cs: field jobs are on the calendar, staff moves are not',
  (select string_agg(distinct entry_type, ',' order by entry_type) from calendar_entries where vehicle_id = test.id('vehicle:OP2')), 'booking,field_job');
select test.logout();

-- Sales
select test.login(test.id('op_sales'));
select test.eq('sales: the sales queue; no field jobs, moves or Turo trips on the calendar; no moves, steps or payouts',
  (test.visible('select * from va_sales_queue') > 0) || '/' || test.visible('select * from va_cs_queue')
  || '/' || test.visible($$select * from calendar_entries where entry_type in ('field_job', 'vehicle_move', 'turo_trip')$$)
  || '/' || (test.visible('select * from vehicle_moves') + test.visible('select * from incident_steps') + test.visible('select * from payout_reconciliations')), 'true/0/0/0');
select test.throws('sales: no staff job lists', format('select * from app.staff_field_jobs(%L)', test.id('op_field')), 'Not permitted');
select test.logout();

-- Owners
select test.login(test.id('op_owen'));
select test.eq('owner: his calendar still shows his bookings and blocks, and no field job or staff move',
  (select string_agg(distinct entry_type, ',' order by entry_type) from calendar_entries), 'block,booking');
select test.eq('owner: no moves, task rules, quick replies, incident steps, payouts, queues or job lists',
  test.visible('select * from vehicle_moves') + test.visible('select * from task_rules') + test.visible('select * from quick_replies') + test.visible('select * from incident_steps')
  + test.visible('select * from payout_reconciliations') + test.visible('select * from work_queue') + test.visible('select * from admin_queue') + test.visible('select * from field_job_list'), 0::bigint);
select test.throws('owner: no vehicle calendar function', format($$select * from app.vehicle_calendar(%L, now(), now() + interval '1 day')$$, test.id('vehicle:OP1')), 'Not permitted');
select test.logout();
select test.login(test.id('op_pat'));
select test.eq('owner: a Turo trip on his own Turo-Only car is on his calendar',
  (select string_agg(distinct entry_type, ',' order by entry_type) from calendar_entries where vehicle_id = test.id('vehicle:OPT')), 'turo_trip');
select test.logout();

-- Renters
select test.login(test.id('op_r1'));
select test.eq('renter: none of the new tables or views',
  test.visible('select * from vehicle_moves') + test.visible('select * from task_rules') + test.visible('select * from quick_replies') + test.visible('select * from incident_steps')
  + test.visible('select * from payout_reconciliations') + test.visible('select * from payout_reconciliation_items') + test.visible('select * from work_queue')
  + test.visible('select * from field_job_list') + test.visible('select * from calendar_entries'), 0::bigint);
select test.eq('renter: sees his own statement and its lines, as before', (select count(*) from booking_statements) || '/' || (select count(*) > 0 from booking_line_items where statement_id = test.b('stA')), '1/true');
select test.throws('renter: cannot open an incident by calling the function', format($$select app.open_incident('breakdown', %L, %L, '{"description": "x"}')$$, test.id('vehicle:OP1'), test.id('op_r1')), 'permission denied');
select test.logout();

-- Admin
select test.login(test.id('op_admin'));
select test.eq('admin: everything, every queue',
  (test.visible('select * from vehicle_moves') > 0 and test.visible('select * from task_rules') > 40 and test.visible('select * from quick_replies') = 2
   and test.visible('select * from incident_steps') > 0 and test.visible('select * from payout_reconciliation_items') >= 3 and test.visible('select * from admin_queue') > 0
   and test.visible('select * from va_finance_queue') > 0 and test.visible('select * from va_fleet_queue') > 0 and test.visible('select * from va_cs_queue') > 0)::text, 'true');
select test.eq('admin: changes a task rule, a quick reply and the photo list from the portal',
  test.affected($$update task_rules set due_amount = 20 where task_type = 'booking_request'$$) || '/' || test.affected($$update quick_replies set is_active = true where title = 'Old snippet'$$)
  || '/' || test.affected($$update required_shots set guide = 'Whole car in frame' where report_kind = 'pickup' and shot = 'front'$$), '1/1/1');
select test.eq('admin: changes the opening hours and the waiting times in a new settings row',
  test.affected($$insert into program_settings (effective_from, opening_hours, late_admin_minutes) values (date '2032-01-01', '{"open": "08:00", "close": "20:00", "days": [1, 2, 3, 4, 5, 6]}', 90)$$), 1::bigint);
select test.logout();
select test.eq('O the new opening hours apply from their date: Sunday is closed in 2032',
  app.add_opening_minutes(test.at('2032-02-07 19:50'), 30), test.at('2032-02-09 08:20'));

-- anonymous
set role anon;
select test.eq('anon: no privilege on any new table or view',
  test.visible('select * from vehicle_moves') + test.visible('select * from task_rules') + test.visible('select * from quick_replies') + test.visible('select * from required_shots')
  + test.visible('select * from incident_steps') + test.visible('select * from payout_reconciliations') + test.visible('select * from work_queue') + test.visible('select * from field_job_list')
  + test.visible('select * from admin_queue'), -9::bigint);
reset role;

-- an Admin's change to a rule is audited like every other change
select test.eq('A changes to rules, moves and payouts are in the audit log',
  (select count(distinct entity_table) from audit_log where entity_table in ('task_rules', 'vehicle_moves', 'payout_reconciliation_items', 'quick_replies', 'required_shots', 'incident_steps')), 6::bigint);

-- ------------------------------------------------------------------ the remaining clock and owner tasks
select app.job_ops_watch(test.at('2031-09-04 17:30'));
select test.eq('J the closing checks are raised an hour before 18:00', (select queue || ':' || to_char(due_at at time zone 'America/Toronto', 'HH24:MI') from tasks where dedupe_key = 'closing_checks:2031-09-04'), 'fleet:18:00');
update owner_invoices set status = 'paid', paid_cents = total_cents, paid_at = now() where id = test.id('inv:op:up');
update vehicle_onboardings set upfront_invoice_id = test.id('inv:op:up'), safety_certificate_expires_on = date '2031-10-10' where id = test.id('onb:OPN');
update vehicle_onboardings set status = 'documents_signed' where id = test.id('onb:OPN');
update vehicle_onboardings set status = 'upfront_paid' where id = test.id('onb:OPN');
select test.eq('Q documents signed and the upfront invoice paid: Fleet books the registry visit, due by the end of the safety certificate',
  (select queue || '/' || procedure_no || '/' || (due_at = test.at('2031-10-10 00:00')) from tasks where related_id = test.id('onb:OPN') and task_type = 'book_registry'), 'fleet/12/true');
insert into vehicle_registrations (id, vehicle_id, registered_as, registered_on, plate_renewal_month) values (test.id('reg:OP8'), test.id('vehicle:OP8'), 'plate_registrant', date '2030-10-15', 10);
select test.eq('J expiry-watch on October 1', app.job_expiry_watch(test.at('2031-10-01 06:30')), 'succeeded');
select test.eq('J a safety certificate about to run out with no registry visit booked, and a plate renewal within 30 days, are Fleet tasks',
  (select string_agg(task_type || ':' || queue, ' ' order by task_type) from tasks
    where (related_id = test.id('onb:OPN') and task_type = 'safety_certificate_window') or (related_id = test.id('reg:OP8') and task_type = 'plate_renewal')),
  'plate_renewal:fleet safety_certificate_window:fleet');
