-- 99: overdue returns, "I've returned the car" (migration 0532, docs/changes/2026-11-06-overdue-returns.md), the website
-- crash digest line (0532) and the email provider budgets (0531). Fixtures start with "or".
select test.suite('99 overdue returns');

select test.mk_user('or_admin', 'admin');
select test.mk_user('or_fleet', 'va', 'fleet');
select test.mk_user('or_fin', 'va', 'finance');
select test.mk_owner('or_o');
select test.mk_vehicle('ORV', 'or_o');
select test.mk_vehicle('ORW', 'or_o');
select test.mk_renter('or_r');
create function test.or_t(p interval) returns text language sql stable as $$
  select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;
select test.mk_booking('OR-1', 'ORV', 'or_r', test.or_t(- interval '3 days'), test.or_t(- interval '3 hours'), 'on_rent');
select test.mk_booking('OR-2', 'ORW', 'or_r', test.or_t(- interval '2 days'), test.or_t(- interval '2 hours'), 'on_rent');
update bookings set odometer_out_km = 20000 where id in (test.id('booking:OR-1'), test.id('booking:OR-2'));
create function test.or_tok(p text) returns uuid language sql stable as $$ select return_link_token from bookings where booking_number = p $$;
create function test.or_do(p_user text, p jsonb) returns jsonb language sql as $$
  select public.door(test.id(p_user), null, 'ops_do', 'return_claim_decide', p) $$;
create function test.or_photo(p_booking text) returns jsonb language sql stable as $$
  select jsonb_build_object('bucket', 'condition-photos', 'path', 'bookings/' || test.id('booking:' || p_booking) || '/return-claim/' || gen_random_uuid() || '.jpg') $$;

-- ---------------------------------------------------------------- 1. the overdue notices carry the link
select app.ntf_emit('renter_late_return_first', 'booking', test.id('booking:OR-1'), 'or-t13', jsonb_build_object('booking_id', test.id('booking:OR-1')));
select app.process_events();
select test.eq('overdue: the late notice is emitted while nothing is reported',
  (select count(*) from app_events where entity_id = test.id('booking:OR-1') and code = 'renter_late_return_first')::integer, 1);
select test.ok('overdue: its email or text waits in the outbox',
  exists (select 1 from notification_outbox o join app_events e on e.id = o.event_id
           where e.entity_id = test.id('booking:OR-1') and o.code = 'renter_late_return_first' and o.status in ('queued', 'delayed')));
select test.eq('overdue: every overdue notice has the one-tap link of the booking',
  (select app.notification_payload('renter_late_return_first', e, '{}'::jsonb) ->> 'returned_url' from app_events e
    where e.entity_id = test.id('booking:OR-1') and e.code = 'renter_late_return_first'),
  rtrim((app.settings()).notify_base_url, '/') || '/returned/' || test.or_tok('OR-1'));
select test.ok('overdue: the texts carry the link too',
  (select bool_and(strpos(body, '{{returned_url}}') > 0) from sms_templates where code in ('renter_return_due', 'renter_late_return_first', 'renter_late_return_final')));

create function test.or_copy() returns void language plpgsql as $f$
declare cols text;
begin
  select string_agg(quote_ident(attname), ', ' order by attnum) into cols from pg_attribute
   where attrelid = 'public.bookings'::regclass and attnum > 0 and not attisdropped and attgenerated = '';
  execute format('insert into bookings (%1$s) select %1$s from jsonb_populate_record(null::bookings, (select to_jsonb(b) || jsonb_build_object(''id'', gen_random_uuid(), ''booking_number'', ''OR-COPY'', ''agreement_number'', null, ''request_key'', null, ''calendar_token'', gen_random_uuid(), ''status'', ''closed'', ''pickup_at'', now() - interval ''400 days'', ''handed_over_at'', now() - interval ''400 days'', ''return_at'', now() - interval ''398 days'', ''original_return_at'', now() - interval ''398 days'', ''checked_in_at'', now() - interval ''398 days'') from bookings b where b.booking_number = ''OR-2''))', cols);
end $f$;
select test.lives('a booking copied with the same link gets its own (the e2e suites copy bookings this way)', $$select test.or_copy()$$);
select test.ok('the copy has its own link', test.or_tok('OR-COPY') is distinct from test.or_tok('OR-2'));
delete from bookings where booking_number = 'OR-COPY';

-- ---------------------------------------------------------------- 2. the link's page
select test.eq('read: the booking out with the renter can be reported',
  (select (r ->> 'number') || ':' || (r ->> 'can_report') || ':' || coalesce(r ->> 'return_state', '-') from public.server_return_claim_read(test.or_tok('OR-1')) r), 'OR-1:true:-');
select test.ok('read: an unknown link reads nothing', public.server_return_claim_read(gen_random_uuid()) is null);
select test.eq('read: the signed-in renter''s own booking gives its link; another user none',
  coalesce(public.server_return_link(test.id('booking:OR-1'), (select user_id from renters where id = test.id('renter:or_r')))::text, '-') || '/'
  || coalesce(public.server_return_link(test.id('booking:OR-1'), test.id('or_fleet'))::text, '-'), test.or_tok('OR-1')::text || '/-');
select test.ok('privileges: only the server calls the link functions',
  not has_function_privilege('anon', 'public.server_return_claim_submit(uuid, jsonb, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_return_claim_submit(uuid, jsonb, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_return_claim_read(uuid)', 'execute'));

-- ---------------------------------------------------------------- 3. the renter's report
select test.throws('report: not in the future',
  format($$select public.server_return_claim_submit(%L, jsonb_build_object('returned_at', now() + interval '1 day'))$$, test.or_tok('OR-1')), 'future');
select test.throws('report: the odometer is not below the pickup''s',
  format($$select public.server_return_claim_submit(%L, jsonb_build_object('odometer_km', 19000))$$, test.or_tok('OR-1')), 'lower than at pickup');
select test.throws('report: only photos this link uploaded',
  format($$select public.server_return_claim_submit(%L, jsonb_build_object('photos', jsonb_build_array(jsonb_build_object('bucket', 'condition-photos', 'path', 'bookings/x/return-claim/a.jpg'))))$$, test.or_tok('OR-1')), 'not uploaded through this link');
select test.throws('report: an unknown link', format($$select public.server_return_claim_submit(%L, '{}'::jsonb)$$, gen_random_uuid()), 'not valid');
create temp table or_c1 as select public.server_return_claim_submit(test.or_tok('OR-1'),
  -- no fuel level: with the odometer, the fuel and photos the renter's own checkout completes the trip at once (0545)
  jsonb_build_object('returned_at', now() - interval '1 hour', 'odometer_km', 20450, 'note', 'Keys in the drop box',
                     'photos', jsonb_build_array(test.or_photo('OR-1'), test.or_photo('OR-1'), test.or_photo('OR-1')))) r;
select test.eq('report: pending, the booking returned waiting for confirmation, kept as renter-provided',
  (select r ->> 'status' from or_c1) || '/' || (select return_state from bookings where id = test.id('booking:OR-1'))
  || '/' || (select status || ':' || renter_provided || ':' || odometer_km || ':' || coalesce(fuel_pct::text, '-') || ':' || jsonb_array_length(photos) from return_claims where booking_id = test.id('booking:OR-1')),
  'pending/returned_pending_confirmation/pending:true:20450:-:3');
select test.eq('report: every overdue notice still waiting is skipped at once',
  (select count(*) from notification_outbox o join app_events e on e.id = o.event_id
    where e.entity_id = test.id('booking:OR-1') and o.code = any (app.overdue_codes()) and o.status in ('queued', 'delayed'))::integer, 0);
select test.eq('report: Fleet has one urgent To do linked to the report',
  (select count(*) || ':' || min(queue) || ':' || min(priority) from tasks where booking_id = test.id('booking:OR-1') and task_type = 'return_claim_review' and status = 'open'), '1:fleet:urgent');
select test.eq('report: the booking history says so', (select count(*) from booking_events where booking_id = test.id('booking:OR-1') and kind = 'return_claimed')::integer, 1);
select test.eq('report: sending it again changes nothing',
  (public.server_return_claim_submit(test.or_tok('OR-1'), '{}'::jsonb) ->> 'already') || '/' || (select count(*) from return_claims where booking_id = test.id('booking:OR-1')), 'true/1');
select test.ok('report: no overdue notice is emitted while it waits (the reminders job, the late panel)',
  app.ntf_emit('renter_late_return_final', 'booking', test.id('booking:OR-1'), 'or-t14', jsonb_build_object('booking_id', test.id('booking:OR-1'))) is null
  and app.ntf_emit('staff_late_return_alert', 'booking', test.id('booking:OR-1'), 'or-st', jsonb_build_object('booking_id', test.id('booking:OR-1'))) is null
  and not exists (select 1 from app_events where entity_id = test.id('booking:OR-1') and code in ('renter_late_return_final', 'staff_late_return_alert')));
select test.eq('report: the staff card reads it',
  (select (public.door(test.id('or_fleet'), null, 'ops_read', 'return_claim', jsonb_build_object('booking', 'OR-1')) ->> 'odometer_km')), '20450');

-- ---------------------------------------------------------------- 4. Deny: the notices resume, the renter is told
select test.throws('deny: Finance does not decide',
  $$select test.or_do('or_fin', jsonb_build_object('booking', 'OR-1', 'decision', 'deny', 'reason', 'Car not at the lot'))$$, 'confirm a return');
select test.throws('deny: the reason is asked', $$select test.or_do('or_fleet', jsonb_build_object('booking', 'OR-1', 'decision', 'deny'))$$, 'Say why');
select test.lives('deny: Fleet denies with the reason',
  $$select test.or_do('or_fleet', jsonb_build_object('booking', 'OR-1', 'decision', 'deny', 'reason', 'The tracker shows the car on the road'))$$);
select test.eq('deny: the report denied, the booking overdue again, the task closed',
  (select status || ':' || decision_note from return_claims where booking_id = test.id('booking:OR-1')) || '/' || coalesce((select return_state from bookings where id = test.id('booking:OR-1')), '-')
  || '/' || (select status from tasks where booking_id = test.id('booking:OR-1') and task_type = 'return_claim_review'),
  'denied:The tracker shows the car on the road/-/done');
select test.eq('deny: the renter is told why, with the link',
  (select (e.payload ->> 'deny_reason') || ':' || (strpos(app.notification_payload('renter_return_claim_denied', e, '{}'::jsonb) ->> 'returned_url', test.or_tok('OR-1')::text) > 0)
     from app_events e where e.entity_id = test.id('booking:OR-1') and e.code = 'renter_return_claim_denied'), 'The tracker shows the car on the road:true');
select test.ok('deny: the overdue notices resume',
  app.ntf_emit('renter_late_return_final', 'booking', test.id('booking:OR-1'), 'or-t14', jsonb_build_object('booking_id', test.id('booking:OR-1'))) is not null);

-- ---------------------------------------------------------------- 5. Confirm: the trip is completed
create temp table or_c2 as select public.server_return_claim_submit(test.or_tok('OR-1'),
  jsonb_build_object('odometer_km', 20500, 'photos', jsonb_build_array(test.or_photo('OR-1'), test.or_photo('OR-1')))) r;
select test.eq('again: a new report waits', (select count(*) from return_claims where booking_id = test.id('booking:OR-1') and status = 'pending')::integer, 1);
select test.lives('confirm: Fleet confirms with a corrected odometer and time',
  $$select test.or_do('or_fleet', jsonb_build_object('booking', 'OR-1', 'decision', 'confirm', 'odometer_km', 20510, 'fuel_pct', 50, 'returned_at', now() - interval '90 minutes'))$$);
select test.eq('confirm: the booking returned at the confirmed time with the readings, the report confirmed, the photos on the check-in report',
  (select status::text || ':' || odometer_in_km || ':' || fuel_in_pct || ':' || (checked_in_at between now() - interval '91 minutes' and now() - interval '89 minutes') || ':' || coalesce(return_state, '-')
     from bookings where id = test.id('booking:OR-1'))
  || '/' || (select status || ':' || confirmed_odometer_km || ':' || (condition_report_id is not null) from return_claims where booking_id = test.id('booking:OR-1') and status <> 'denied')
  || '/' || (select count(*) from condition_report_photos p join condition_reports c on c.id = p.condition_report_id
              where c.booking_id = test.id('booking:OR-1') and c.kind = 'return' and p.storage_path like '%/return-claim/%')
  || '/' || (select count(*) from tasks where booking_id = test.id('booking:OR-1') and task_type = 'return_claim_review' and status = 'open'),
  'returned:20510:50:true:-/confirmed:20510:true/2/0');
select test.eq('confirm: the link page says it is recorded',
  (public.server_return_claim_read(test.or_tok('OR-1')) ->> 'done') || ':' || (public.server_return_claim_read(test.or_tok('OR-1')) ->> 'can_report'), 'true:false');
select test.eq('confirm: a report after the trip is done changes nothing',
  public.server_return_claim_submit(test.or_tok('OR-1'), '{}'::jsonb) ->> 'status', 'done');

-- ---------------------------------------------------------------- 6. the trip completed another way
select public.server_return_claim_submit(test.or_tok('OR-2'), jsonb_build_object('fuel_pct', 100));
select test.lives('check-in: staff record the return the usual way',
  format($$select public.door(%L, null, 'ops_do', 'handover_record_now', jsonb_build_object('booking', 'OR-2', 'kind', 'return', 'reason', 'Car found at the lot'))$$, test.id('or_fleet')));
select test.eq('check-in: the report is settled, the notices stay stopped, the task closed',
  (select status from return_claims where booking_id = test.id('booking:OR-2')) || '/' || coalesce((select return_state from bookings where id = test.id('booking:OR-2')), '-')
  || '/' || (select count(*) from tasks where booking_id = test.id('booking:OR-2') and task_type = 'return_claim_review' and status = 'open'),
  'confirmed/-/0');

-- ---------------------------------------------------------------- 7. website crashes: one digest line per kind a day
select public.server_client_error(jsonb_build_object('message', 'or: TypeError x is undefined', 'path', '/cars/or-test'));
select public.server_client_error(jsonb_build_object('message', 'or: TypeError x is undefined', 'path', '/cars/or-test'));
select test.eq('crashes: one morning digest line for the Admins, however many reports',
  (select count(*) || ':' || min(digest_slot) from staff_digest_items where role = 'admin' and line like 'Website crash on /cars/or-test%'), '1:morning');

-- ---------------------------------------------------------------- 8. the email budgets (0531)
select test.eq('budgets: Cloudflare first 200 a day, Resend after 100 a day',
  (select (b ->> 'cf_budget') || ':' || (b ->> 'resend_budget') from (select public.server_email_budgets() b) x), '200:100');
select test.ok('budgets: the next midnight is ahead', (public.server_email_budgets() ->> 'midnight')::timestamptz > now());
