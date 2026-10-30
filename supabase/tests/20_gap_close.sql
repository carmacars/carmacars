-- 20: the gaps of 0031 and 0032 closed (migration 0033): the assistant's functions and switcher, renter
-- messages both ways with their emails, the monthly statement emails (PDF first, 7-day link), Turo trips,
-- the daily checks, the photo review and re-shoot, the late-return panel, find a renter, Sales quotes,
-- the scorecard, the field checklists for every job kind, the field report, referrals and profile, and
-- every catalogue code emitted by something. Every fixture label starts with "gc".
select test.suite('20 gap close');

select test.mk_user('gc_admin', 'admin');
select test.mk_user('gc_cs', 'va', 'cs');
select test.mk_user('gc_cs2', 'va', 'cs');
select test.mk_user('gc_fin', 'va', 'finance');
select test.mk_user('gc_fleet', 'va', 'fleet');
select test.mk_user('gc_sales', 'va', 'sales');
select test.mk_user('gc_field', 'field');
select test.mk_user('gc_field2', 'field');
select test.mk_owner('gc_o');
select test.mk_vehicle('gcV', 'gc_o');
select test.mk_vehicle('gcW', 'gc_o');
select test.mk_vehicle('gcX', 'gc_o');
select test.mk_renter('gc_r');
select test.mk_renter('gc_r2');
create function test.gc(p_label text) returns uuid language sql stable as $$ select test.id('booking:' || p_label) $$;
-- a confirmed booking far ahead, one on rent and late, one returned
select test.mk_booking('GC-1', 'gcV', 'gc_r', to_char(now() + interval '20 days', 'YYYY-MM-DD 10:00'), to_char(now() + interval '23 days', 'YYYY-MM-DD 10:00'), 'confirmed');
select test.mk_booking('GC-2', 'gcW', 'gc_r2', to_char((now() at time zone 'America/Toronto') - interval '3 days', 'YYYY-MM-DD HH24:MI'),
  to_char((now() at time zone 'America/Toronto') - interval '40 minutes', 'YYYY-MM-DD HH24:MI'), 'on_rent');
select test.mk_booking('GC-3', 'gcX', 'gc_r', to_char(now() - interval '6 days', 'YYYY-MM-DD 10:00'), to_char(now() - interval '1 day', 'YYYY-MM-DD 10:00'), 'returned');
create or replace function test.gc_flush() returns integer language sql as $$ select app.process_events(100000) $$;

-- ---------------------------------------------------------------- 1. the assistant's functions
select test.eq('functions: one function by default, no switcher list beyond it',
  (public.my_roles(test.id('gc_cs')) ->> 'va') || '/' || (public.my_roles(test.id('gc_cs')) -> 'va_functions')::text, 'cs/["cs"]');
select test.throws('functions: only an Admin sets the functions an assistant covers',
  format($$select public.door(%L, null, 'admin_do', 'staff_cover', jsonb_build_object('user', %L, 'functions', jsonb_build_array('sales')))$$, test.id('gc_cs'), test.id('gc_cs2')), 'Admin');
select public.door(test.id('gc_admin'), null, 'admin_do', 'staff_cover', jsonb_build_object('user', test.id('gc_cs2'), 'functions', jsonb_build_array('sales', 'cs', 'fleet')));
select test.eq('functions: an Admin gives an assistant two more functions (the main one is not repeated)',
  (public.my_roles(test.id('gc_cs2')) -> 'va_functions')::text, '["cs", "sales", "fleet"]');
select test.eq('functions: without a choice the assistant works in the main function',
  public.door(test.id('gc_cs2'), null, 'va_read', 'functions') ->> 'active', 'cs');
select test.eq('functions: the switcher moves the assistant to a covered function for the call',
  (public.door(test.id('gc_cs2'), null, 'va_read', 'digest', jsonb_build_object('_va', 'fleet')) ->> 'function'), 'fleet');
select test.eq('functions: and the database checks the work by that function (Fleet''s board opens)',
  (public.door(test.id('gc_cs2'), null, 'va_read', 'fleet_board', jsonb_build_object('_va', 'fleet')) ? 'jobs'), true);
select test.eq('functions: a function they do not cover is ignored (back to the main one)',
  (public.door(test.id('gc_cs2'), null, 'va_read', 'digest', jsonb_build_object('_va', 'finance')) ->> 'function'), 'cs');
select test.throws('functions: another assistant cannot borrow a function',
  format($$select public.door(%L, null, 'va_read', 'fleet_board', jsonb_build_object('_va', 'fleet'))$$, test.id('gc_cs')), 'Not permitted');
select test.eq('functions: the choice lasts one call only', app.va_active_fn(test.id('gc_cs2')), 'cs');
-- one staff portal (0197): holding a function is enough for its checks, whichever is chosen on screen
select test.eq('functions: a held function counts without the choice', app.user_va_has(test.id('gc_cs2'), 'fleet'), true);

-- ---------------------------------------------------------------- 2. renter messages both ways
update program_settings set staff_blocked_terms = array['Acme Insurance'];
select test.throws('messages: a reply naming a blocked term is refused',
  format($$select public.door(%L, null, 'va_do', 'send_message', jsonb_build_object('booking', %L, 'body', 'Your cover is with ACME insurance.'))$$, test.id('gc_cs'), test.gc('GC-1')), 'may not name');
update program_settings set staff_blocked_terms = '{}';
create temp table gc_m1 as select public.door(test.id('gc_cs'), null, 'va_do', 'send_message', jsonb_build_object('booking', test.gc('GC-1'), 'body', 'We added a child seat for you.')) r;
select test.gc_flush();
select test.eq('messages: a staff reply is kept on the booking and emails the renter with the message',
  (select count(*) from messages where id = ((select r from gc_m1) ->> 'id')::uuid and direction = 'outbound' and channel = 'portal') || '/' ||
  (select count(*) from notification_outbox o where o.code = 'renter_staff_message' and o.entity_id = ((select r from gc_m1) ->> 'id')::uuid
      and o.to_address = 'gc_r@example.test' and o.payload ->> 'message_body' = 'We added a child seat for you.' and o.missing_variables = '{}'), '1/1');
select test.eq('messages: the renter also gets one in-app notice (not two)',
  (select count(*) from notifications n where n.user_id = test.id('gc_r') and n.code = 'renter_staff_message'), 1::bigint);
select test.eq('messages: the email links to the booking''s messages in the portal',
  (select app.notification_url(c, jsonb_build_object('booking_number', 'GC-1')) from notification_catalogue c where c.code = 'renter_staff_message'),
  'https://carmacars.ca/account/bookings/GC-1#messages');
select test.throws('messages: another renter cannot write on the booking',
  format($$select public.renter_send_message(%L, %L, 'Hello')$$, test.gc('GC-1'), test.id('gc_r2')), 'renter of the booking');
select test.throws('messages: an empty reply is refused', format($$select public.renter_send_message(%L, %L, '  ')$$, test.gc('GC-1'), test.id('gc_r')), 'Write the message');
create temp table gc_m2 as select public.renter_send_message(test.gc('GC-1'), test.id('gc_r'), 'Thank you, can I pick up at 9?') r;
select public.renter_send_message(test.gc('GC-1'), test.id('gc_r'), 'Or 9:30 is fine too.');
select test.gc_flush();
select test.eq('messages: the renter''s replies open one task in the customer service queue',
  (select count(*) || '/' || min(queue) || '/' || min(status) from tasks where task_type = 'renter_message' and booking_id = test.gc('GC-1')), '1/cs/open');
select test.eq('messages: and reach customer service (the next digest: the pickup is weeks away)',
  (select count(*) from staff_digest_items where code = 'staff_renter_replied' and booking_id = test.gc('GC-1')), 2::bigint);
select test.login(test.id('gc_r'));
create temp table gc_thread as select public.my_booking_messages('GC-1') t;
select test.logout();
select test.eq('messages: the renter reads the whole thread in the portal, as themself',
  (select string_agg(x ->> 'direction', ',' order by x ->> 'at') from gc_thread, jsonb_array_elements(t) x), 'outbound,inbound,inbound');
select test.login(test.id('gc_r2'));
create temp table gc_thread2 as select public.my_booking_messages('GC-1') t;
select test.logout();
select test.eq('messages: another renter reads nothing', (select t from gc_thread2)::text, '[]');
select public.door(test.id('gc_cs'), null, 'va_do', 'send_message', jsonb_build_object('booking', 'GC-1', 'body', '9:30 works. See you then.'));
select test.eq('messages: the staff reply closes the "renter replied" task',
  (select status from tasks where task_type = 'renter_message' and booking_id = test.gc('GC-1')), 'done');
select test.throws('messages: Fleet does not write to renters',
  format($$select public.door(%L, null, 'va_do', 'send_message', jsonb_build_object('booking', 'GC-1', 'body', 'Hi'))$$, test.id('gc_fleet')), 'customer service work');
select public.renter_send_message(test.gc('GC-2'), test.id('gc_r2'), 'I am running late, sorry.');
select test.gc_flush();
select test.eq('messages: a reply while the car is out reaches customer service at once (an email, not the digest)',
  (select count(*) from notification_outbox where code = 'staff_renter_replied' and booking_id = test.gc('GC-2')) > 0
  and not exists (select 1 from staff_digest_items where code = 'staff_renter_replied' and booking_id = test.gc('GC-2')), true);

-- ---------------------------------------------------------------- 3. the statement emails: PDF first, then the email
insert into owner_statements (id, statement_number, owner_id, statement_month, payout_date, status, owner_revenue_cents, revenue_share_cents, payout_cents, approved_by, approved_at)
values (test.id('gc_st'), 'OS-GC-1', test.id('owner:gc_o'), date_trunc('month', app.today() - 32)::date, app.today(), 'approved', 65000, 35000, 60000, test.id('gc_admin'), now()),
       (test.id('gc_st_old'), 'OS-GC-0', test.id('owner:gc_o'), date_trunc('month', app.today() - 120)::date, app.today() - 90, 'approved', 1000, 1000, 1000, test.id('gc_admin'), now());
select test.eq('statements: an approved owner statement is due on its payout date; an old one is never mailed late',
  (select string_agg(x ->> 'key', ',') from jsonb_array_elements(public.server_statement_mail_due()) x
    where x ->> 'kind' = 'owner_statement' and x ->> 'key' in (test.id('gc_st')::text, test.id('gc_st_old')::text)), test.id('gc_st')::text);
select test.throws('statements: the email waits for the stored PDF', format($$select public.server_statement_mail_release('owner_statement', %L)$$, test.id('gc_st')), 'PDF first');
insert into documents (id, kind, title, storage_bucket, storage_path) values (test.id('gc_st_doc'), 'owner_statement', 'Statement OS-GC-1', 'documents', 'generated/owner_statement/x/OS-GC-1.pdf');
insert into generated_documents (kind, entity_key, document_id, sha256) values ('owner_statement', test.id('gc_st')::text, test.id('gc_st_doc'), 'aa');
select public.server_statement_mail_release('owner_statement', test.id('gc_st')::text);
select test.eq('statements: with the PDF stored, the statement is marked sent and its email emitted once',
  (select (sent_at is not null)::text || '/' || document_id from owner_statements where id = test.id('gc_st')) || '/' || (select count(*) from app_events where code = 'owner_statement_ready' and entity_id = test.id('gc_st')),
  'true/' || test.id('gc_st_doc') || '/1');
select test.eq('statements: a second run sends nothing more',
  (public.server_statement_mail_release('owner_statement', test.id('gc_st')::text) ->> 'sent') || '/' || (select count(*) from app_events where code = 'owner_statement_ready' and entity_id = test.id('gc_st')), 'false/1');
select test.gc_flush();
select test.eq('statements: the owner email carries a 7-day link to the PDF (statement_url)',
  (select app.outbox_file_refs(o.id) -> 'statement_url' ->> 'k' from notification_outbox o where o.code = 'owner_statement_ready' and o.entity_id = test.id('gc_st') limit 1), 'owner_statement');
select test.eq('statements: the catalogue entry lists the link among its values',
  (select v ->> 'name' from notification_catalogue c, jsonb_array_elements(c.variables) v where c.code = 'owner_statement_ready' and v ->> 'name' = 'statement_url'), 'statement_url');
insert into investors (id, user_id, legal_name, investor_type, status, email) values (test.id('gc_inv'), null, 'Gina Investor', 'individual', 'active', 'gc_inv@example.test');
insert into documents (id, kind, storage_bucket, storage_path) values (test.id('gc_d1'), 'other', 'documents', 'x/c.pdf');
insert into investment_agreements (id, investor_id, agreement_number, status, schedule_c_document_id, schedule_d_document_id, exemption_category, legal_advice_choice)
values (test.id('gc_agr'), test.id('gc_inv'), 'IA-GC-1', 'signed', test.id('gc_d1'), test.id('gc_d1'), 'accredited_investor', 'declined');
insert into investments (id, investor_id, agreement_id, is_initial, principal_cents, yearly_bps, investment_date, lockup_end_date)
values (test.id('gc_ivt'), test.id('gc_inv'), test.id('gc_agr'), true, 2500000, 1200, date '2026-01-05', date '2026-07-05');
insert into investment_returns (id, investment_id, return_month, opening_invested_cents, yearly_bps, days_earning, days_in_month, return_cents, disposition, payment_date, closing_invested_cents, status)
values (test.id('gc_ret'), test.id('gc_ivt'), date_trunc('month', app.today() - 40)::date, 2500000, 1200, 30, 30, 24658, 'reinvest', app.today() - 1, 2524658, 'reinvested'),
       (test.id('gc_ret2'), test.id('gc_ivt'), date_trunc('month', app.today() - 10)::date, 2500000, 1200, 30, 30, 24658, 'reinvest', app.today() + 20, 2524658, 'accrued');
select test.eq('statements: an investor statement is due on its Payment Date, once the return is reinvested or paid',
  (select string_agg(x ->> 'key', ',') from jsonb_array_elements(public.server_statement_mail_due()) x
    where x ->> 'kind' = 'investor_statement' and x ->> 'key' in (test.id('gc_ret')::text, test.id('gc_ret2')::text)), test.id('gc_ret')::text);
insert into documents (id, kind, title, storage_bucket, storage_path) values (test.id('gc_ret_doc'), 'investor_statement', 'Statement', 'documents', 'generated/investor_statement/x/s.pdf');
insert into generated_documents (kind, entity_key, document_id, sha256) values ('investor_statement', test.id('gc_ret')::text, test.id('gc_ret_doc'), 'bb');
select public.server_statement_mail_release('investor_statement', test.id('gc_ret')::text);
select test.eq('statements: then the investor statement email goes, with the stored PDF on the return',
  (select (statement_sent_at is not null)::text || '/' || statement_document_id from investment_returns where id = test.id('gc_ret')) || '/' || (select count(*) from app_events where code = 'investor_statement_ready' and entity_id = test.id('gc_ret')),
  'true/' || test.id('gc_ret_doc') || '/1');
select test.eq('statements: once sent, neither is due any more',
  (select count(*) from jsonb_array_elements(public.server_statement_mail_due()) x where x ->> 'key' in (test.id('gc_st')::text, test.id('gc_ret')::text)), 0::bigint);

-- ---------------------------------------------------------------- 4. Finance: Turo trips
select test.throws('turo: Fleet does not record Turo money',
  format($$select public.door(%L, null, 'va_do', 'turo_trip_save', jsonb_build_object('vehicle', %L, 'turo_trip_ref', 'T-1', 'starts_at', now() - interval '3 days', 'ends_at', now() - interval '1 day', 'gross_cents', 30000))$$,
         test.id('gc_fleet'), test.id('vehicle:gcV')), 'Finance work');
create temp table gc_turo as select public.door(test.id('gc_fin'), null, 'va_do', 'turo_trip_save', jsonb_build_object('plate', (select plate from vehicles where id = test.id('vehicle:gcV')),
  'turo_trip_ref', 'GC-TURO-1', 'starts_at', '2026-09-02T14:00:00-04:00', 'ends_at', '2026-09-05T14:00:00-04:00', 'gross_cents', 40000, 'turo_fees_cents', 10000, 'company_extras_cents', 2500)) r;
select test.eq('turo: a trip by plate takes the car''s Revenue Share (35% of the Turo Payout) and the end month',
  (select (r ->> 'revenue_share_cents') || '/' || (r ->> 'owner_payout_cents') || '/' || (r ->> 'statement_month') from gc_turo), '10500/19500/2026-09-01');
select public.door(test.id('gc_fin'), null, 'va_do', 'turo_trip_save', jsonb_build_object('vehicle', test.id('vehicle:gcV'),
  'turo_trip_ref', 'GC-TURO-1', 'starts_at', '2026-09-02T14:00:00-04:00', 'ends_at', '2026-09-05T14:00:00-04:00', 'gross_cents', 50000, 'turo_fees_cents', 10000));
select test.eq('turo: the same reference is corrected, not doubled', (select count(*) || '/' || max(revenue_share_cents) from turo_trips where turo_trip_ref = 'GC-TURO-1'), '1/14000');
create temp table gc_imp as select public.door(test.id('gc_fin'), null, 'va_do', 'turo_trip_import', jsonb_build_object('rows', jsonb_build_array(
  jsonb_build_object('plate', (select plate from vehicles where id = test.id('vehicle:gcW')), 'turo_trip_ref', 'GC-TURO-2', 'starts_at', '2026-09-10T10:00:00-04:00', 'ends_at', '2026-09-12T10:00:00-04:00', 'gross_cents', 20000, 'turo_fees_cents', 5000),
  jsonb_build_object('plate', 'NOPE', 'turo_trip_ref', 'GC-TURO-3', 'starts_at', '2026-09-10T10:00:00-04:00', 'ends_at', '2026-09-12T10:00:00-04:00', 'gross_cents', 20000)))) r;
select test.eq('turo: an import saves the good rows and lists the bad ones', (select (r ->> 'saved') || '/' || (r -> 'errors' -> 0 ->> 'ref') from gc_imp), '1/GC-TURO-3');
select test.eq('turo: the Finance screen lists the trips', (select count(*) from jsonb_array_elements(public.door(test.id('gc_fin'), null, 'va_read', 'turo_trips') -> 'trips') x where x ->> 'turo_trip_ref' like 'GC-TURO-%'), 2::bigint);
select test.eq('reconciliation: Finance records a processor payout through the door',
  (public.door(test.id('gc_fin'), null, 'va_do', 'reconcile_record', jsonb_build_object('payout_ref', 'po_gc_1', 'paid_on', app.today(), 'amount_cents', 12345)) is not null), true);

-- ---------------------------------------------------------------- 5. Fleet: the daily checks
select test.eq('checks: the opening check has its five lines, the system answers four of them',
  (select jsonb_array_length(f -> 'items') || '/' || (select count(*) from jsonb_array_elements(f -> 'items') i where i -> 'system' <> 'null'::jsonb)
     from public.door(test.id('gc_fleet'), null, 'va_read', 'daily_check', jsonb_build_object('kind', 'opening')) f), '5/4');
select test.eq('checks: a car on rent past its return time is shown as overdue on line 4',
  (select i ->> 'detail' like '%GC-2%' from jsonb_array_elements(public.door(test.id('gc_fleet'), null, 'va_read', 'daily_check', jsonb_build_object('kind', 'opening')) -> 'items') i where (i ->> 'n') = '4'), true);
select test.throws('checks: every line needs an answer',
  format($$select public.door(%L, null, 'va_do', 'daily_check_save', jsonb_build_object('kind', 'opening', 'items', jsonb_build_object('1', jsonb_build_object('result', 'ok'))))$$, test.id('gc_fleet')), 'Answer line 2');
select test.throws('checks: a Problem needs a note',
  format($$select public.door(%L, null, 'va_do', 'daily_check_save', jsonb_build_object('kind', 'opening', 'items', jsonb_build_object('1', jsonb_build_object('result', 'ok'),
    '2', jsonb_build_object('result', 'ok'), '3', jsonb_build_object('result', 'ok'), '4', jsonb_build_object('result', 'problem'), '5', jsonb_build_object('result', 'ok'))))$$, test.id('gc_fleet')), 'Say what the problem');
select app.raise_task(p_type => 'opening_checks', p_title => 'Opening checks', p_due_at => app.local_midnight(app.today()) + interval '9 hours', p_dedupe => 'gc_opening');
create temp table gc_dc as select public.door(test.id('gc_fleet'), null, 'va_do', 'daily_check_save', jsonb_build_object('kind', 'opening', 'items', jsonb_build_object('1', jsonb_build_object('result', 'ok'),
    '2', jsonb_build_object('result', 'ok'), '3', jsonb_build_object('result', 'ok'), '4', jsonb_build_object('result', 'problem', 'note', 'GC-2 not back; calling'), '5', jsonb_build_object('result', 'ok')))) r;
select test.eq('checks: the check is recorded with who did it; a Problem escalates to an Admin; the opening task closes',
  (select (r ->> 'problems') from gc_dc) || '/' || (select completed_by from daily_checks where check_date = app.today() and kind = 'opening')
    || '/' || (select queue || ':' || escalated from tasks where task_type = 'daily_check_problem' and related_id = ((select r from gc_dc) ->> 'id')::uuid)
    || '/' || (select status from tasks where dedupe_key = 'gc_opening'),
  '1/' || test.id('gc_fleet') || '/admin:true/done');
select test.throws('checks: customer service does not fill the Fleet checks',
  format($$select public.door(%L, null, 'va_read', 'daily_check', '{}'::jsonb)$$, test.id('gc_cs')), 'Fleet work');

-- ---------------------------------------------------------------- 6. Fleet: photo review side by side, and the re-shoot
set session_replication_role = replica;
insert into condition_reports (id, vehicle_id, booking_id, kind, performed_by, performed_by_role, completed_at, odometer_km, fuel_pct, keys_count)
values (test.id('gc_cr_p'), test.id('vehicle:gcX'), test.gc('GC-3'), 'pickup', test.id('gc_field'), 'field', now() - interval '6 days', 10000, 100, 2),
       (test.id('gc_cr_r'), test.id('vehicle:gcX'), test.gc('GC-3'), 'return', test.id('gc_field'), 'field', now() - interval '1 day', 10800, 90, 2);
insert into condition_report_photos (condition_report_id, seq, shot, storage_path, taken_at)
select r, s.seq, s.shot, 'bookings/' || test.gc('GC-3') || '/' || k || '/' || s.seq || '-' || s.shot || '.jpg', now() - interval '1 day'
  from (values (test.id('gc_cr_p'), 'pickup'), (test.id('gc_cr_r'), 'return')) x(r, k)
  cross join app.required_shots_for('pickup', 'premium') s where not (k = 'return' and s.shot in ('roof', 'instrument_cluster'));
set session_replication_role = origin;
create temp table gc_pr as select public.door(test.id('gc_fleet'), null, 'va_read', 'photo_review', jsonb_build_object('booking', 'GC-3')) r;
select test.eq('review: pickup and return sets side by side, with the missing return shots listed',
  (select jsonb_array_length(r -> 'pickup' -> 'photos') || '/' || jsonb_array_length(r -> 'return' -> 'photos') || '/' || (r -> 'return' -> 'missing')::text || '/' || jsonb_array_length(r -> 'pickup' -> 'missing') from gc_pr),
  (select count(*) from app.required_shots_for('pickup', 'premium')) || '/' || ((select count(*) from app.required_shots_for('pickup', 'premium')) - 2) || '/["roof", "instrument_cluster"]/0');
select test.throws('review: Fleet chooses which shots to take again', format($$select public.door(%L, null, 'va_do', 'request_reshoot', jsonb_build_object('booking', 'GC-3', 'which', 'return', 'shots', '[]'::jsonb))$$, test.id('gc_fleet')), 'Choose the shots');
create temp table gc_rs as select public.door(test.id('gc_fleet'), null, 'va_do', 'request_reshoot', jsonb_build_object('booking', 'GC-3', 'which', 'return', 'shots', jsonb_build_array('roof', 'instrument_cluster', 'not_a_shot'), 'at', now() + interval '1 hour')) r;
select test.eq('review: "Ask for a re-shoot" gives a field job for those shots to whoever took the set',
  (select kind || '/' || assigned_to || '/' || array_to_string(reshoot_shots, ',') || '/' || reshoot_report_id from field_jobs where id = ((select r from gc_rs) ->> 'job_id')::uuid),
  'other/' || test.id('gc_field') || '/roof,instrument_cluster/' || test.id('gc_cr_r'));
create function test.gc_rsj() returns uuid language sql stable as $$ select ((select r from gc_rs) ->> 'job_id')::uuid $$;
select test.eq('review: the field job shows the shots to take',
  (select string_agg(x ->> 'shot', ',' order by (x ->> 'seq')::int) from jsonb_array_elements(public.door(test.id('gc_field'), null, 'field_read', 'job', jsonb_build_object('id', test.gc_rsj())) -> 'checklist' -> 'reshoot' -> 'shots') x),
  'roof,instrument_cluster');
select public.door(test.id('gc_field'), null, 'field_do', 'acknowledge', jsonb_build_object('job', test.gc_rsj()));
select public.door(test.id('gc_field'), null, 'field_do', 'start', jsonb_build_object('job', test.gc_rsj()));
select public.door(test.id('gc_field'), null, 'field_do', 'reshoot_photo', jsonb_build_object('job', test.gc_rsj(), 'shot', 'roof', 'bucket', 'condition-photos', 'path', 'bookings/x/return/9-roof.jpg'));
select test.throws('review: the job cannot finish until every shot is taken again',
  format($$select public.door(%L, null, 'field_do', 'complete_job', jsonb_build_object('job', %L))$$, test.id('gc_field'), test.gc_rsj()), 'Still to do');
select test.throws('review: a shot that was not asked for is refused',
  format($$select public.door(%L, null, 'field_do', 'reshoot_photo', jsonb_build_object('job', %L, 'shot', 'front', 'bucket', 'condition-photos', 'path', 'x.jpg'))$$, test.id('gc_field'), test.gc_rsj()), 'not asked for');
select public.door(test.id('gc_field'), null, 'field_do', 'reshoot_photo', jsonb_build_object('job', test.gc_rsj(), 'shot', 'instrument_cluster', 'bucket', 'condition-photos', 'path', 'bookings/x/return/15-instrument_cluster.jpg'));
select public.door(test.id('gc_field'), null, 'field_do', 'complete_job', jsonb_build_object('job', test.gc_rsj()));
select test.eq('review: the new photos are on the return report and the job is done',
  jsonb_array_length(public.door(test.id('gc_fleet'), null, 'va_read', 'photo_review', jsonb_build_object('booking', 'GC-3')) -> 'return' -> 'missing') || '/' || (select status from field_jobs where id = test.gc_rsj()), '0/done');

-- ---------------------------------------------------------------- 7. Fleet: the late-return panel
create temp table gc_lp as select public.door(test.id('gc_fleet'), null, 'va_read', 'late_panel', jsonb_build_object('booking', 'GC-2')) r;
select test.eq('late: the panel shows the clock from the return time and the four steps',
  (select (r ->> 'late') || '/' || ((r ->> 'minutes_late')::int between 35 and 45) || '/' || jsonb_array_length(r -> 'steps') from gc_lp), 'true/true/4');
select public.door(test.id('gc_fleet'), null, 'va_do', 'late_call', jsonb_build_object('booking', 'GC-2', 'note', 'No answer, left a voicemail'));
select test.eq('late: a call is logged on the booking', jsonb_array_length(public.door(test.id('gc_fleet'), null, 'va_read', 'late_panel', jsonb_build_object('booking', 'GC-2')) -> 'calls'), 1);
create temp table gc_t13 as select public.door(test.id('gc_fleet'), null, 'va_do', 'late_t13', jsonb_build_object('booking', 'GC-2')) r;
select test.eq('late: T13 is sent from the panel, and a second press does not send it twice',
  (select (r ->> 'already_sent') from gc_t13) || '/' || (public.door(test.id('gc_cs'), null, 'va_do', 'late_t13', jsonb_build_object('booking', 'GC-2')) ->> 'already_sent')
    || '/' || (select count(*) from app_events where code = 'renter_late_return_first' and entity_id = test.gc('GC-2')), 'false/true/1');
select test.throws('late: T14 is the final notice and waits for 2 hours',
  format($$select public.door(%L, null, 'va_do', 'late_t14', jsonb_build_object('booking', 'GC-2'))$$, test.id('gc_fleet')), '2 hours after');
select test.throws('late: customer service does not request a disable',
  format($$select public.door(%L, null, 'va_do', 'late_disable', jsonb_build_object('booking', 'GC-2'))$$, test.id('gc_cs')), 'cannot late disable');
set session_replication_role = replica;
update bookings set return_at = now() - interval '3 hours' where id = test.gc('GC-2');
set session_replication_role = origin;
select public.door(test.id('gc_fleet'), null, 'va_do', 'late_t14', jsonb_build_object('booking', 'GC-2'));
select test.eq('late: after 2 hours T14 goes', (select count(*) from app_events where code = 'renter_late_return_final' and entity_id = test.gc('GC-2')), 1::bigint);
select test.throws('late: a disable needs a Tracker on the car',
  format($$select public.door(%L, null, 'va_do', 'late_disable', jsonb_build_object('booking', 'GC-2'))$$, test.id('gc_fleet')), 'Tracker');
select test.ok('late: Fleet opens a late-return incident from the panel',
  (public.door(test.id('gc_fleet'), null, 'va_do', 'late_incident', jsonb_build_object('booking', 'GC-2', 'note', 'Not back after T14')) ->> 'incident_id') is not null);
select test.eq('late: the panel shows the T14 time and the incident',
  (select (r ->> 't14_at' is not null)::text || '/' || (r -> 'incident' ->> 'kind') from (select public.door(test.id('gc_fleet'), null, 'va_read', 'late_panel', jsonb_build_object('booking', 'GC-2')) r) q), 'true/late_return');

-- ---------------------------------------------------------------- 8. find a renter
select test.throws('find: at least 3 characters', format($$select public.door(%L, null, 'va_read', 'find_renter', jsonb_build_object('q', 'gc'))$$, test.id('gc_cs')), '3 characters');
create temp table gc_find as select public.door(test.id('gc_cs'), null, 'va_read', 'find_renter', jsonb_build_object('q', 'Gc R2')) r;
select test.eq('find: a name finds the renter with the last booking (at most 10, logged); a live booking puts them in the window',
  (select (x ->> 'last_booking_number') || '/' || (x ->> 'in_window') from gc_find, jsonb_array_elements(r) x)
    || '/' || (select count(*) > 0 from data_access_log where user_id = test.id('gc_cs') and action = 'search' and query = 'Gc R2'), 'GC-2/true/true');
select test.throws('find: Sales does not search customers', format($$select public.door(%L, null, 'va_read', 'find_renter', jsonb_build_object('q', 'Gc R2'))$$, test.id('gc_sales')), 'Not permitted');
select test.throws('find: opening a renter outside the window needs a reason',
  format($$select public.door(%L, null, 'va_do', 'open_renter', jsonb_build_object('renter', %L, 'reason', 'x'))$$, test.id('gc_cs'), test.id('renter:gc_r2')), 'reason');
select test.eq('find: with a reason the record opens for 24 hours, with the bookings',
  (select (v ->> 'legal_name') || '/' || jsonb_array_length(v -> 'bookings') || '/' || (v ->> 'access_until' is not null)
     from public.door(test.id('gc_cs'), null, 'va_do', 'open_renter', jsonb_build_object('renter', test.id('renter:gc_r2'), 'reason', 'Caller asking about a refund')) v), 'Gc R2/1/true');

-- ---------------------------------------------------------------- 9. Sales quotes
create temp table gc_q as select public.door(test.id('gc_sales'), null, 'va_do', 'quote_create', jsonb_build_object('vehicle_id', test.id('vehicle:gcV'),
  'pickup_at', (now() + interval '40 days')::text, 'return_at', (now() + interval '43 days')::text, 'source', 'phone',
  'full_name', 'Quinn Caller', 'email', 'quinn.gc@example.test', 'mobile', '647-555-0177', 'date_of_birth', '1985-02-03', 'note', 'Called about a weekend trip', 'sales_choice', 'sourced')) r;
select test.eq('quotes: Sales takes a phone lead as a request, with the source and who took it, priced',
  (select b.status || '/' || b.source || '/' || b.created_by || '/' || (b.rental_charge_cents > 0) || '/' || (select count(*) from booking_drivers d where d.booking_id = b.id)
     from bookings b where b.id = ((select r from gc_q) ->> 'booking_id')::uuid), 'requested/phone/' || test.id('gc_sales') || '/true/1');
select test.eq('quotes: the lead becomes a renter (no consent is recorded for them)',
  (select count(*) || '/' || (select count(*) from consents c join renters r on r.user_id = c.user_id where r.email = 'quinn.gc@example.test') from renters where email = 'quinn.gc@example.test'), '1/0');
select test.throws('quotes: Finance takes quotes since 0058, with the choice "I sourced this client" or "Entered for CarmaCars"', format($$select public.door(%L, null, 'va_do', 'quote_create', '{}'::jsonb)$$, test.id('gc_fin')), 'I sourced this client');
select test.throws('quotes: a lead needs a date of birth',
  format($$select public.door(%L, null, 'va_do', 'quote_create', jsonb_build_object('vehicle_id', %L, 'pickup_at', %L, 'return_at', %L, 'full_name', 'A B', 'email', 'ab@example.test', 'mobile', '1', 'sales_choice', 'for_carmacars'))$$,
         test.id('gc_sales'), test.id('vehicle:gcV'), (now() + interval '50 days')::text, (now() + interval '52 days')::text), 'date of birth');

-- ---------------------------------------------------------------- 10. the scorecard
-- hours ago, squeezed into this Toronto week when the run is in the first hours of a Monday (the order is kept)
create or replace function test.gc_ago(p_hours numeric) returns timestamptz language sql stable as $$
  select now() - interval '1 hour' * p_hours
         * least(1, extract(epoch from now() - app.local_midnight(date_trunc('week', app.today())::date)) / (6 * 3600.0)) $$;
insert into tasks (queue, task_type, title, status, due_at, assigned_to, completed_by, completed_at) values
  ('cs', 'booking_request', 'on time', 'done', test.gc_ago(2), test.id('gc_cs'), test.id('gc_cs'), test.gc_ago(3)),
  ('cs', 'booking_request', 'late', 'done', test.gc_ago(5), test.id('gc_cs'), test.id('gc_cs'), test.gc_ago(1)),
  ('cs', 'verify_renter', 'overdue', 'open', test.gc_ago(1), test.id('gc_cs'), null, null);
create temp table gc_sc as select public.door(test.id('gc_cs'), null, 'va_read', 'scorecard', jsonb_build_object('weeks', 2)) r;
select test.eq('scorecard: this week''s measures for customer service: first reply 2 of 3 (the renter message answered above counts), verification 0 of 1',
  (select string_agg((m ->> 'met') || '/' || (m ->> 'total'), ',') from gc_sc, jsonb_array_elements(r -> 'weeks' -> -1 -> 'measures') m
    where m ->> 'name' in ('First reply in opening hours', 'Verification and coverage proof complete')), '2/3,0/1');
select test.eq('scorecard: the week''s score and four measures for the function', (select (r -> 'weeks' -> -1 ->> 'score_pct') || '/' || jsonb_array_length(r -> 'weeks' -> -1 -> 'measures') from gc_sc), '50/4');
select test.eq('scorecard: an Admin reads any assistant''s scorecard', public.door(test.id('gc_admin'), null, 'admin_read', 'scorecard', jsonb_build_object('staff', test.id('gc_cs'))) ->> 'name', 'Gc Cs');
select test.throws('scorecard: an assistant reads only their own (the Admin screen is the Admin''s)',
  format($$select public.door(%L, null, 'admin_read', 'scorecard', jsonb_build_object('staff', %L))$$, test.id('gc_cs2'), test.id('gc_cs')), 'Admin');

-- ---------------------------------------------------------------- 11. field checklists for every job kind
create function test.gc_job(p_kind text, p_vehicle text, p_to text default 'gc_field') returns uuid language plpgsql as $$
declare v uuid;
begin
  v := app.create_field_job(p_kind, test.id('vehicle:' || p_vehicle), now() + interval '2 hours', test.id('gc_fleet'), null, test.id(p_to), 'Yard', null);
  perform public.door(test.id(p_to), null, 'field_do', 'acknowledge', jsonb_build_object('job', v));
  perform public.door(test.id(p_to), null, 'field_do', 'start', jsonb_build_object('job', v));
  return v;
end $$;
create temp table gc_jobs as select k, test.gc_job(k, 'gcV') id from unnest(array['detail', 'tracker_install', 'registry_run', 'recovery', 'tracker_removal', 'photo_shoot', 'other']) k;
create function test.gc_j(p_kind text) returns uuid language sql stable as $$ select id from gc_jobs where k = p_kind $$;
select test.eq('checklist: every kind has its steps',
  (select string_agg(k || ':' || jsonb_array_length(public.door(test.id('gc_field'), null, 'field_read', 'job', jsonb_build_object('id', id)) -> 'checklist' -> 'steps'), ',' order by k) from gc_jobs),
  'detail:9,other:3,photo_shoot:3,recovery:4,registry_run:3,tracker_install:4,tracker_removal:3');
select test.throws('checklist: a job is not completed with steps missing',
  format($$select public.door(%L, null, 'field_do', 'complete_job', jsonb_build_object('job', %L))$$, test.id('gc_field'), test.gc_j('detail')), 'Still to do');
select test.throws('checklist: only the assignee works the checklist',
  format($$select public.door(%L, null, 'field_do', 'checklist_save', jsonb_build_object('job', %L, 'answers', '{}'::jsonb))$$, test.id('gc_field2'), test.gc_j('detail')), 'not one of yours');
select public.door(test.id('gc_field'), null, 'field_do', 'checklist_save', jsonb_build_object('job', test.gc_j('detail'), 'answers', jsonb_build_object(
  'grade', jsonb_build_object('v', 'pet'), 'exterior', jsonb_build_object('v', 'ok'), 'interior', jsonb_build_object('v', 'ok'),
  'checks', jsonb_build_object('v', 'problem', 'note', 'Tire pressure light on'), 'fuel', jsonb_build_object('v', 'ok'), 'items', jsonb_build_object('v', 'ok'),
  'not_a_step', jsonb_build_object('v', 'x'))));
select test.eq('checklist: answers are kept (only the steps of the kind); pet hair needs photos before cleaning, and the ready photos are missing',
  (select (checklist ? 'not_a_step')::text from field_jobs where id = test.gc_j('detail')) || '/' ||
  (public.door(test.id('gc_field'), null, 'field_read', 'job', jsonb_build_object('id', test.gc_j('detail'))) -> 'checklist' -> 'missing')::text,
  'false/["Photos before cleaning", "Ready photos"]');
select public.door(test.id('gc_field'), null, 'field_do', 'checklist_save', jsonb_build_object('job', test.gc_j('detail'), 'answers', jsonb_build_object(
  'before', jsonb_build_object('photos', jsonb_build_array('vehicles/x/ready/before-1.jpg')))));
select public.door(test.id('gc_field'), null, 'field_do', 'save_report', jsonb_build_object('job', test.gc_j('detail'), 'report', jsonb_build_object('photos',
  (select jsonb_agg(jsonb_build_object('seq', s.seq, 'shot', s.shot, 'storage_path', 'vehicles/x/ready/' || s.seq || '.jpg')) from app.required_shots_for('ready', 'premium') s))));
select public.door(test.id('gc_field'), null, 'field_do', 'complete_job', jsonb_build_object('job', test.gc_j('detail')));
select test.eq('checklist: the detail is done with its grade and fuel; the warning light becomes a Fleet task',
  (select status || '/' || cleaning_grade || '/' || fuel_or_charge_ok from field_jobs where id = test.gc_j('detail')) || '/' ||
  (select queue || ':' || task_type from tasks where related_id = test.gc_j('detail') and task_type = 'field_job_problem'), 'done/pet/true/fleet:field_job_problem');
select public.door(test.id('gc_field'), null, 'field_do', 'checklist_save', jsonb_build_object('job', test.gc_j('tracker_install'), 'answers', jsonb_build_object(
  'serial', jsonb_build_object('v', 'GC-TRK-77'), 'installed', jsonb_build_object('v', 'ok'), 'tests', jsonb_build_object('v', 'ok'),
  'photo', jsonb_build_object('photos', jsonb_build_array('vehicles/x/other/photo-1.jpg')))));
select public.door(test.id('gc_field'), null, 'field_do', 'complete_job', jsonb_build_object('job', test.gc_j('tracker_install')));
select test.eq('checklist: a tracker install records the device on the car, tested, and the onboarding step',
  (select status || '/' || (tested_at is not null) || '/' || installed_by from tracker_devices where serial_number = 'GC-TRK-77' and vehicle_id = test.id('vehicle:gcV'))
    || '/' || (select tracker_installed_on is not null from vehicles where id = test.id('vehicle:gcV')), 'installed/true/' || test.id('gc_field') || '/true');
select public.door(test.id('gc_field'), null, 'field_do', 'checklist_save', jsonb_build_object('job', test.gc_j('registry_run'), 'answers', jsonb_build_object(
  'documents', jsonb_build_object('v', 'ok'), 'permit', jsonb_build_object('photos', jsonb_build_array('vehicles/' || test.id('vehicle:gcV') || '/other/permit-1.jpg')))));
select public.door(test.id('gc_field'), null, 'field_do', 'complete_job', jsonb_build_object('job', test.gc_j('registry_run')));
select test.eq('checklist: a registry run files the new permit on the car and asks Fleet to record it',
  (select count(*) from documents where vehicle_id = test.id('vehicle:gcV') and kind = 'ownership_permit') || '/' || (select queue from tasks where task_type = 'record_registration' and vehicle_id = test.id('vehicle:gcV')), '1/fleet');
select test.throws('checklist: a recovery needs the rules read and the arrival photos',
  format($$select public.door(%L, null, 'field_do', 'complete_job', jsonb_build_object('job', %L))$$, test.id('gc_field'), test.gc_j('recovery')), 'How a car is recovered');
select public.door(test.id('gc_field'), null, 'field_do', 'checklist_save', jsonb_build_object('job', test.gc_j('recovery'), 'answers', jsonb_build_object(
  'rules', jsonb_build_object('v', 'ok'), 'arrival', jsonb_build_object('photos', jsonb_build_array('a.jpg', 'b.jpg')), 'where', jsonb_build_object('v', 'Open lot, Dufferin St'),
  'secured', jsonb_build_object('v', 'ok'))));
select public.door(test.id('gc_field'), null, 'field_do', 'complete_job', jsonb_build_object('job', test.gc_j('recovery')));
select test.eq('checklist: a recovery done raises the urgent Fleet task to check the car in',
  (select priority from tasks where task_type = 'recovery_done' and related_id = test.gc_j('recovery')), 'urgent');
select public.door(test.id('gc_field'), null, 'field_do', 'checklist_save', jsonb_build_object('job', test.gc_j('tracker_removal'), 'answers', jsonb_build_object(
  'removed', jsonb_build_object('v', 'ok'), 'odometer', jsonb_build_object('v', '23456'), 'exit_photos', jsonb_build_object('photos', jsonb_build_array('1.jpg', '2.jpg', '3.jpg', '4.jpg')))));
select public.door(test.id('gc_field'), null, 'field_do', 'complete_job', jsonb_build_object('job', test.gc_j('tracker_removal')));
select test.eq('checklist: a tracker removal takes the device off the car and records the odometer',
  (select status from tracker_devices where serial_number = 'GC-TRK-77') || '/' || (select odometer_km from vehicles where id = test.id('vehicle:gcV')), 'removed/23456');
select test.eq('checklist: a photo shoot waits for the listing photos to be submitted',
  (public.door(test.id('gc_field'), null, 'field_read', 'job', jsonb_build_object('id', test.gc_j('photo_shoot'))) -> 'checklist' -> 'missing')::text,
  '["Daylight, plain background, landscape", "The listing photos"]');
select test.eq('checklist: field staff of the car''s photo shoot may start its listing (0032''s rule, now with a screen)',
  public.door(test.id('gc_field'), null, 'ops_do', 'listing_start', jsonb_build_object('vehicle_id', test.id('vehicle:gcV'))) ? 'intake_id', true);
select test.eq('checklist: a handover job keeps its own checklist (no generic one)',
  (public.door(test.id('gc_field'), null, 'field_read', 'job', jsonb_build_object('id', app.create_field_job('handover', test.id('vehicle:gcV'), now() + interval '3 hours', test.id('gc_fleet'), test.gc('GC-1'), test.id('gc_field'), 'Yard', null))) -> 'checklist'), 'null'::jsonb);

-- ---------------------------------------------------------------- 12. the field report, referrals, profile
select test.throws('report: only a car of one of their jobs',
  format($$select public.door(%L, null, 'field_do', 'report', jsonb_build_object('vehicle', %L, 'what', 'other', 'details', 'Something odd here'))$$, test.id('gc_field2'), test.id('vehicle:gcV')), 'one of your jobs');
select test.throws('report: damage needs a photo',
  format($$select public.door(%L, null, 'field_do', 'report', jsonb_build_object('vehicle', %L, 'what', 'new_damage', 'details', 'Scratch on the rear bumper'))$$, test.id('gc_field'), test.id('vehicle:gcV')), 'photo');
select test.throws('report: say what happened', format($$select public.door(%L, null, 'field_do', 'report', jsonb_build_object('vehicle', %L, 'what', 'other', 'details', 'short'))$$, test.id('gc_field'), test.id('vehicle:gcV')), '10 characters');
create temp table gc_rep as select public.door(test.id('gc_field'), null, 'field_do', 'report', jsonb_build_object('vehicle', test.id('vehicle:gcV'), 'what', 'new_damage',
  'details', 'Scratch on the rear bumper, 10 cm', 'photos', jsonb_build_array('vehicles/' || test.id('vehicle:gcV') || '/other/report-ab12cd34.jpg'))) r;
select test.eq('report: new damage opens an incident with the photo and an urgent Fleet task',
  (select kind from incidents where id = ((select r from gc_rep) ->> 'incident_id')::uuid) || '/' || (select count(*) from documents where incident_id = ((select r from gc_rep) ->> 'incident_id')::uuid)
    || '/' || (select queue || ':' || priority from tasks where id = ((select r from gc_rep) ->> 'task_id')::uuid), 'damage_found_later/1/fleet:urgent');
create temp table gc_rep2 as select public.door(test.id('gc_field'), null, 'field_do', 'report', jsonb_build_object('vehicle', test.id('vehicle:gcV'), 'what', 'collision',
  'details', 'Rear-ended at a light while moving the car', 'anyone_hurt', false)) r;
select test.eq('report: a collision while staff had the car is an accident with the staff member, and an Admin task at once',
  (select kind || '/' || staff_user_id from incidents where id = ((select r from gc_rep2) ->> 'incident_id')::uuid) || '/' ||
  (select count(*) from tasks where queue = 'admin' and related_id = ((select r from gc_rep2) ->> 'incident_id')::uuid and escalated), 'accident/' || test.id('gc_field') || '/1');
create temp table gc_rep3 as select public.door(test.id('gc_field'), null, 'field_do', 'report',
  jsonb_build_object('vehicle', test.id('vehicle:gcV'), 'what', 'ticket_or_toll', 'details', 'Took the 407 to the yard')) r;
select test.eq('report: a toll while driving goes to Finance', (select queue from tasks where id = ((select r from gc_rep3) ->> 'task_id')::uuid), 'finance');
create temp table gc_ref as select public.door(test.id('gc_field'), null, 'field_read', 'referrals') r;
select test.eq('referrals: a referral code is made once and kept, with the rate and the kickbacks',
  (select length(r ->> 'code') = 7 and (r ->> 'code') = (select referral_code from staff_profiles where user_id = test.id('gc_field')) and (r ->> 'rate_bps')::int > 0
     and (public.door(test.id('gc_field'), null, 'field_read', 'referrals') ->> 'code') = (r ->> 'code') from gc_ref), true);
select test.eq('profile: the staff member updates their phone',
  public.door(test.id('gc_field'), null, 'field_do', 'profile_save', jsonb_build_object('phone', '416-555-0142')) ->> 'phone', '416-555-0142');
select test.throws('profile: not a phone number', format($$select public.door(%L, null, 'field_do', 'profile_save', jsonb_build_object('phone', 'call me'))$$, test.id('gc_field')), 'phone');
select test.throws('field: an assistant is not field staff', format($$select public.door(%L, null, 'field_read', 'profile')$$, test.id('gc_fleet')), 'field staff');

-- ---------------------------------------------------------------- 13. every catalogue code emitted by something, or sender-only
select test.eq('catalogue: every email code is emitted by a database function, except the two the sign-in service sends',
  (with src as (select string_agg(p.prosrc, ' ') s from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'app' and p.proname not like 'notification\_%' and p.proname not like 'ntf\_payload%' and p.proname not like 'outbox\_%'
                   and p.proname not in ('digest_line', 'process_events'))
   select string_agg(c.code, ',' order by c.code) from notification_catalogue c, src
    where c.has_email and position('''' || c.code || '''' in src.s) = 0
      and not (c.code ~ '^staff_digest_(morning|eod)_(admin|va_finance|va_fleet|va_cs|va_sales)$' and src.s like '%''staff_digest_'' || p_slot%')
      and not (c.code in ('staff_field_jobs_today', 'staff_field_jobs_tomorrow') and src.s like '%''staff_field_jobs_'' || p_which%')),
  'account_password_reset,account_security_notice');
select test.eq('catalogue: those two are documented as sent by the sign-in service; the sign-in link email is the owner invitation''s (0029)',
  (select string_agg(code, ',' order by code) from notification_catalogue where emitted_by like 'not emitted%'), 'account_password_reset,account_security_notice');
select test.eq('catalogue: the two message emails are in the catalogue, with what emits them',
  (select string_agg(code || '=' || emitted_by, '; ' order by code) from notification_catalogue where code in ('renter_staff_message', 'staff_renter_replied')),
  'renter_staff_message=app.staff_send_message (0033), app.booking_email_send (0187); staff_renter_replied=app.renter_send_message (0033)');

-- ---------------------------------------------------------------- 14. the live verification's test accounts
select test.throws('verify accounts: only verify-<name>@carmacars.ca addresses',
  format($$select public.server_verify_accounts(jsonb_build_array(jsonb_build_object('user_id', %L, 'email', 'someone@example.test', 'role', 'renter')))$$, gen_random_uuid()), 'Not a verification address');
select test.throws('verify accounts: never an Admin, except the one verification Admin (0036)',
  format($$select public.server_verify_accounts(jsonb_build_array(jsonb_build_object('user_id', %L, 'email', 'verify-boss@carmacars.ca', 'role', 'admin')))$$, gen_random_uuid()), 'Only verify-admin@carmacars.ca');
create temp table gc_va as select public.server_verify_accounts(jsonb_build_array(
  jsonb_build_object('user_id', test.id('gc_v_owner'), 'email', 'verify-owner@carmacars.ca', 'role', 'owner'),
  jsonb_build_object('user_id', test.id('gc_v_inv'), 'email', 'verify-investor@carmacars.ca', 'role', 'investor'),
  jsonb_build_object('user_id', test.id('gc_v_cs'), 'email', 'verify-va-cs@carmacars.ca', 'role', 'va_cs'),
  jsonb_build_object('user_id', test.id('gc_v_field'), 'email', 'verify-field@carmacars.ca', 'role', 'field'))) r;
select test.throws('verify accounts (0054): the Admin role is refused for that address in the first place',
  format($$insert into user_roles (user_id, role) values (%L, 'admin')$$, test.id('gc_v_cs')), 'Admin access is only for');
select public.server_verify_accounts(jsonb_build_array(jsonb_build_object('user_id', test.id('gc_v_cs'), 'email', 'verify-va-cs@carmacars.ca', 'role', 'va_cs'),
  jsonb_build_object('user_id', test.id('gc_v_field'), 'email', 'verify-field@carmacars.ca', 'role', 'field')));
select test.eq('verify accounts: each portal''s role, made again without doubling, and an Admin role taken away',
  (select string_agg(x ->> 'role' || '=' || concat_ws('+', case when (x -> 'roles' ->> 'owner')::boolean then 'owner' end, case when (x -> 'roles' ->> 'investor')::boolean then 'investor' end,
                                                     x -> 'roles' ->> 'va', case when (x -> 'roles' ->> 'field')::boolean then 'field' end, case when (x -> 'roles' ->> 'admin')::boolean then 'admin' end), ',')
     from gc_va, jsonb_array_elements(r) x) || '/' || (public.my_roles(test.id('gc_v_cs')) ->> 'admin') || '/' || (select count(*) from owners where user_id = test.id('gc_v_owner')),
  'owner=owner,investor=investor,va_cs=cs,field=field/false/1');
select test.eq('verify accounts: every one is on the suppression list, so no email reaches them',
  (select count(*) from email_suppressions where email like 'verify-%@carmacars.ca' and scope = 'all' and lifted_at is null), 4::bigint);
