-- 99: R50 hotfix 2, Sales (migrations 5130 to 5137). Sample-car enquiries in Requests and offers with real cars to offer;
-- duplicate leads merged by themselves (email, phone, name variants) with their history; the renter's notes on a request
-- and "Who referred you?"; every salesperson in the sale and extension lists (Jamal: field staff with Sales); no
-- commission on an extension the salesperson did not start; lead generators (entry, no claims, the $100 credit when the
-- owner signs, Admin approval); recruit invite links; Admin approval of a salesperson's shift claim; texts with a phone
-- number blocked and calls flagged with the line. Fixtures start with "rss".
select test.suite('99 r50 hotfix 2 sales');

select test.mk_user('rss_admin', 'admin');
select test.mk_user('rss_cs', 'va', 'cs');
select test.mk_user('rss_sam', 'va', 'sales');
select test.mk_user('rss_eric', 'va', 'sales');
select test.mk_user('rss_jamal', 'field', null, 'driver_detailer', 'RSSJAMAL');
insert into user_roles (user_id, role) values (test.id('rss_jamal'), 'va') on conflict do nothing;
update staff_profiles set functions = array['field', 'sales'], sales_opt_in_at = now() where user_id = test.id('rss_jamal');
update users set full_name = 'Rss Jamal Safy' where id = test.id('rss_jamal');
select test.mk_renter('rss_rita');
select test.mk_owner('rss_co');
select test.mk_vehicle('rss_real', 'rss_co');
select test.mk_vehicle('rss_sample', 'rss_co');
update vehicles set is_sample = true where id = test.id('vehicle:rss_sample');

create function test.rss_admin(p_name text, p jsonb) returns jsonb language sql as $$ select app.door(test.id('rss_admin'), 'aal2', 'admin_do', p_name, p) $$;
create function test.rss_alert(p_rule text) returns integer language sql stable as $$
  select count(*)::integer from app_events e where e.code like 'staff_alert_%' and e.payload ->> 'rule' = p_rule $$;

-- ================================================================ 1. a sample-car enquiry is a request (5130)
create temp table rss_eq as select app.sample_car_enquiry(jsonb_build_object('vehicle_id', test.id('vehicle:rss_sample'), 'note', 'Is this one free?',
  'renter', jsonb_build_object('full_name', 'Rss Dost Asker', 'email', 'rss_dost@example.test', 'mobile', '416-555-0141'),
  'pickup_at', '2031-03-01T15:00:00Z', 'return_at', '2031-03-04T15:00:00Z')) r;
create temp table rss_q as select x from jsonb_array_elements(app.admin_requests(test.id('rss_admin'), '{}'::jsonb)) x
  where x ->> 'lead_id' = (select r ->> 'lead_id' from rss_eq);
select test.eq('sample: the enquiry is a row of Requests and offers, marked as a sample car',
  (select x ->> 'status' || '/' || (x ->> 'sample') || '/' || (x ->> 'state') || '/' || (x -> 'flags' ->> 0) || '/' || (x ->> 'days') from rss_q), 'requested/true/sample/Sample car/3');
select test.ok('sample: real cars are suggested, never a sample car', (select jsonb_array_length(x -> 'suggestions') between 1 and 3 from rss_q)
  and not exists (select 1 from rss_q, jsonb_array_elements(x -> 'suggestions') s join vehicles v on v.id = (s ->> 'id')::uuid where v.is_sample));
select test.ok('sample: a car booked for those dates is not suggested',
  not exists (select 1 from rss_q, jsonb_array_elements(x -> 'suggestions') s
               where exists (select 1 from bookings b where b.vehicle_id = (s ->> 'id')::uuid and b.blocks_calendar
                               and b.status in ('requested', 'offered', 'pending_payment', 'confirmed', 'on_rent')
                               and b.pickup_at < '2031-03-04T15:00:00Z' and b.return_at > '2031-03-01T15:00:00Z')));
select test.ok('sample: customer service reads it in their request queue too',
  exists (select 1 from jsonb_array_elements(app.door(test.id('rss_cs'), 'aal2', 'va_read', 'requests', '{"_va": "cs"}')) x where x ->> 'lead_id' = (select r ->> 'lead_id' from rss_eq)));
update leads set sales_outcome = 'lost', sales_outcome_reason = 'No real car fits', sales_outcome_at = now() where id = (select (r ->> 'lead_id')::uuid from rss_eq);
select test.ok('sample: an outcome on the enquiry takes it off the queue',
  not exists (select 1 from jsonb_array_elements(app.admin_requests(test.id('rss_admin'), '{}'::jsonb)) x where x ->> 'lead_id' = (select r ->> 'lead_id' from rss_eq)));

-- ================================================================ 2. duplicate leads merge by themselves (5131)
insert into leads (id, kind, name, email, phone, source, created_at) values
  (test.id('lead:rss_a'), 'contact', 'Rss Mona Lisa Smith', 'rss_mona@example.test', null, 'web', now() - interval '20 days'),
  (test.id('lead:rss_b'), 'phone', 'Smith, Rss Mona Lisa', null, '(647) 555-0177', 'missed_call', now() - interval '5 days');
select test.eq('merge: a name variant (the same words in another order) with contacts that do not disagree joins the older lead',
  (select merged_into from leads where id = test.id('lead:rss_b')), test.id('lead:rss_a'));
select test.eq('merge: the kept lead took the phone and keeps the merged one under it',
  (select phone || '/' || jsonb_array_length(payload -> 'merged') from leads where id = test.id('lead:rss_a')), '(647) 555-0177/1');
insert into leads (id, kind, name, email, phone, source, created_at) values (test.id('lead:rss_c'), 'contact', 'R. Mona', 'RSS_MONA@example.test', null, 'web', now());
select test.eq('merge: the same email joins it, any source, any age', (select merged_into from leads where id = test.id('lead:rss_c')), test.id('lead:rss_a'));
insert into leads (id, kind, name, email, phone, source) values (test.id('lead:rss_d'), 'contact', 'Rss Mona Lisa Smith', 'rss_other@example.test', '416-555-0178', 'web');
select test.eq('merge: the same name with a different email and phone stays apart (two people)', (select merged_into from leads where id = test.id('lead:rss_d')), null::uuid);
insert into leads (id, kind, name, email, phone, source) values (test.id('lead:rss_e'), 'owner_program', 'Rss Mona Smith', 'rss_mona@example.test', null, 'web');
select test.eq('merge: an owner lead and a renter lead of one person stay apart', (select merged_into from leads where id = test.id('lead:rss_e')), null::uuid);
select test.ok('merge: the history is kept (the audit log has each automatic merge)',
  (select count(*) from audit_log where action = 'lead_auto_merge' and entity_id = test.id('lead:rss_a')::text) = 2);
insert into leads (id, kind, name, email, phone, source, created_at) values (test.id('lead:rss_f'), 'contact', 'Rss Pat Lee', 'rss_pat@example.test', null, 'web', now() - interval '3 days');
insert into leads (id, kind, name, email, phone, source) values (test.id('lead:rss_h'), 'chat', 'Rss Pat Quinn Lee', null, '416-555-0179', 'web');
select test.eq('merge: a middle name given once is the same name (no contact disagrees)', (select merged_into from leads where id = test.id('lead:rss_h')), test.id('lead:rss_f'));
insert into leads (id, kind, name, email, phone, source) values (test.id('lead:rss_g'), 'contact', 'Rss Pat Lee', 'rss_pat2@example.test', '416-555-0180', 'web');
update leads set email = 'rss_pat@example.test' where id = test.id('lead:rss_g');
select test.eq('merge: a lead whose email is corrected later joins too', (select merged_into from leads where id = test.id('lead:rss_g')), test.id('lead:rss_f'));

-- ================================================================ 3. notes and who referred you (5132)
select test.mk_booking('RSS-1', 'rss_real', 'rss_rita', '2031-05-01 10:00', '2031-05-04 10:00', 'requested');
select test.throws('note: only the renter of the request', format($$select public.renter_request_note(%L, %L, 'Hello')$$, test.id('booking:RSS-1'), test.id('rss_cs')), '%not found%');
select test.eq('note: the renter adds a note to their open request',
  jsonb_array_length(public.renter_request_note(test.id('booking:RSS-1'), test.id('rss_rita'), 'Flight AC123 lands at 9')), 1);
select test.ok('note: Admin and staff are told', test.rss_alert('request_note') >= 1);
select test.eq('note: the request queue shows it',
  (select x -> 'renter_notes' -> 0 ->> 'body' from jsonb_array_elements(app.admin_requests(test.id('rss_admin'), '{}'::jsonb)) x where x ->> 'booking_number' = 'RSS-1'), 'Flight AC123 lands at 9');
select test.eq('note: staff read it on the booking', app.door(test.id('rss_cs'), 'aal2', 'ops_read', 'request_notes', '{"booking": "RSS-1"}') -> 0 ->> 'body', 'Flight AC123 lands at 9');
select test.throws('note: not on a booking that is no longer a request',
  format($$select public.renter_request_note(%L, %L, 'Late')$$, test.mk_booking('RSS-2', 'rss_real', 'rss_rita', '2031-06-01 10:00', '2031-06-04 10:00', 'closed'), test.id('rss_rita')), '%no longer open%');
select test.ok('referrer: the search finds a salesperson by first name, first name and last initial only',
  exists (select 1 from jsonb_array_elements(public.server_referrer_search('rss jam')) x where x ->> 'key' = 's:' || test.id('rss_jamal') and x ->> 'label' = 'Rss S.'));
select test.eq('referrer: fewer than 3 letters find nobody', jsonb_array_length(public.server_referrer_search('rs')), 0);
select test.eq('referrer: a salesperson named by the renter is credited with the sale', app.request_referrer_credit(test.id('booking:RSS-1'), test.id('rss_sam')), 'sale');
select test.eq('referrer: credited as sourced, by referral', (select sales_staff_id = test.id('rss_sam') and sales_sourced and sales_source = 'referral' from bookings where id = test.id('booking:RSS-1')), true);
select test.ok('referrer: they are told', test.rss_alert('referral_named') >= 1);
select test.eq('referrer: a second name never takes the credit away', app.request_referrer_credit(test.id('booking:RSS-1'), test.id('rss_eric')), null::text);
select test.ok('privileges: the renter and search functions are the server''s only',
  not has_function_privilege('anon', 'public.server_referrer_search(text)', 'execute') and not has_function_privilege('authenticated', 'public.renter_request_note(uuid, uuid, text)', 'execute'));

-- ================================================================ 4. every salesperson in the lists (5133)
select test.eq('sales list: Jamal (field staff with Sales) is listed as Sales',
  (select x ->> 'function' || '/' || (x ->> 'sales') from jsonb_array_elements(app.sales_staff_options(test.id('rss_admin'))) x where x ->> 'id' = test.id('rss_jamal')::text), 'sales/true');
select test.eq('sales list: customer service is not Sales',
  (select x ->> 'sales' from jsonb_array_elements(app.sales_staff_options(test.id('rss_admin'))) x where x ->> 'id' = test.id('rss_cs')::text), 'false');

-- ================================================================ 5. no commission on an extension the salesperson did not start (5133)
select test.mk_booking('RSS-3', 'rss_real', 'rss_rita', '2031-07-01 10:00', '2031-07-08 10:00', 'on_rent');
update bookings set sales_staff_id = test.id('rss_sam'), sales_source = 'admin', sales_sourced = true, sales_attributed_at = now() where id = test.id('booking:RSS-3');
-- each extension is made, read, then lapsed (one open extension a booking at a time)
create function test.rss_ext(p_seq integer, p_by uuid) returns booking_extensions language plpgsql as $$
declare e booking_extensions;
begin
  insert into booking_extensions (booking_id, seq, status, previous_return_at, new_return_at, previous_days, new_days, previous_rental_charge_cents, new_rental_charge_cents,
                                  rental_difference_cents, requested_by)
  select b.id, p_seq, 'requested', b.return_at + make_interval(days => 7 * (p_seq - 1)), b.return_at + make_interval(days => 7 * p_seq), 7 * p_seq, 7 * (p_seq + 1), 10000, 20000, 10000, p_by
    from bookings b where b.id = test.id('booking:RSS-3') returning * into e;
  update booking_extensions set status = 'lapsed' where id = e.id;
  return e;
end $$;
select test.eq('extension: one the renter asked for goes to Admin (no commission)',
  (select handled_queue || '/' || coalesce(handled_by::text, '-') from test.rss_ext(1, test.id('rss_rita'))), 'admin/-');
select test.eq('extension: one an Admin started goes to Admin (the Tibirica case)', (select handled_queue from test.rss_ext(2, test.id('rss_admin'))), 'admin');
select test.eq('extension: the weekly job''s (nobody started it) goes to Admin', (select handled_queue from test.rss_ext(3, null)), 'admin');
select test.eq('extension: one the salesperson started is theirs',
  (select handled_queue || '/' || (handled_by = test.id('rss_sam')) from test.rss_ext(4, test.id('rss_sam'))), 'sales/true');

-- ================================================================ 6. lead generators (5134)
select test.throws('lead gen: not a lead generator yet', $$select app.door(test.id('rss_eric'), 'aal2', 'va_do', 'owner_lead_add', '{"name": "Rss Owen", "phone": "416-555-0161", "_va": "sales"}')$$, '%Only lead generators%');
select test.throws('lead gen: only an Admin gives the role', $$select app.door(test.id('rss_sam'), 'aal2', 'admin_do', 'lead_gen_set', jsonb_build_object('staff', test.id('rss_eric'), 'on', true))$$, null);
select test.rss_admin('lead_gen_set', jsonb_build_object('staff', test.id('rss_eric'), 'on', true));
select test.throws('lead gen: the phone is needed (closers call it)', $$select app.door(test.id('rss_eric'), 'aal2', 'va_do', 'owner_lead_add', '{"name": "Rss Owen", "_va": "sales"}')$$, '%phone number%');
create temp table rss_ol as select app.door(test.id('rss_eric'), 'aal2', 'va_do', 'owner_lead_add',
  '{"name": "Rss Owen Car", "phone": "416-555-0161", "email": "rss_owen@example.test", "city": "Toronto", "car": "2021 Honda Civic", "note": "Wants a call after 5", "_va": "sales"}') r;
select test.eq('lead gen: an owner lead for the closers, credited to Eric, no automatic follow-ups',
  (select kind || '/' || pipeline_stage || '/' || source || '/' || (generated_by = test.id('rss_eric')) || '/' || (followup_stopped_at is not null) from leads where id = (select (r ->> 'lead_id')::uuid from rss_ol)),
  'owner_program/new/lead_gen/true/true');
select test.ok('lead gen: closers in Sales see it in their list', app.sl_sees(test.id('rss_sam'), (select l from leads l where l.id = (select (r ->> 'lead_id')::uuid from rss_ol))));
select test.throws('lead gen: a person already an open owner lead is refused', $$select app.door(test.id('rss_eric'), 'aal2', 'va_do', 'owner_lead_add', '{"name": "Owen Again", "phone": "(416) 555-0161", "_va": "sales"}')$$, '%Already an open owner lead%');
select test.throws('lead gen: an owner already with us is refused', $$select app.door(test.id('rss_eric'), 'aal2', 'va_do', 'owner_lead_add', '{"name": "Rss Co", "phone": "416-555-0162", "email": "rss_co@example.test", "_va": "sales"}')$$, '%Already an owner%');
select test.throws('lead gen: a lead generator does not claim leads (closers call)',
  format($$select app.door(test.id('rss_eric'), 'aal2', 'va_do', 'lead_claim', jsonb_build_object('lead', %L, '_va', 'sales'))$$, (select r ->> 'lead_id' from rss_ol)), '%closers call them%');
select test.eq('lead gen: Eric sees his lead and where it is', (select x -> 'rows' -> 0 ->> 'stage' from (select app.door(test.id('rss_eric'), 'aal2', 'va_read', 'my_owner_leads', '{"_va": "sales"}') x) s), 'New: waiting for a closer');
update leads set pipeline_stage = 'agreement_sent' where id = (select (r ->> 'lead_id')::uuid from rss_ol);
select test.eq('lead gen: no credit before the owner signs', (select count(*)::int from lead_gen_credits), 0);
update leads set pipeline_stage = 'signed' where id = (select (r ->> 'lead_id')::uuid from rss_ol);
select test.eq('lead gen: the owner signed: one credit of $100 waits for an Admin',
  (select count(*)::int || '/' || max(amount_cents) || '/' || max(status) from lead_gen_credits where staff_id = test.id('rss_eric')), '1/10000/pending_approval');
update leads set pipeline_stage = 'car_onboarded' where id = (select (r ->> 'lead_id')::uuid from rss_ol);
select test.eq('lead gen: one credit a lead, ever', (select count(*)::int from lead_gen_credits where staff_id = test.id('rss_eric')), 1);
select test.ok('lead gen: Eric and the Admins are told', test.rss_alert('lead_gen_closed') >= 1 and test.rss_alert('lead_gen_credit_due') >= 1);
select app.door(test.id('rss_eric'), 'aal2', 'va_do', 'owner_lead_add', '{"name": "Rss Gail Owner", "phone": "416-555-0163", "email": "rss_gail@example.test", "_va": "sales"}');
select test.mk_owner('rss_gail');
update owners set phone = '416-555-0163' where id = test.id('owner:rss_gail');
update owner_agreements set status = 'sent' where owner_id = test.id('owner:rss_gail');
update owner_agreements set status = 'signed' where owner_id = test.id('owner:rss_gail');
select test.eq('lead gen: an enrollment agreement signed by an owner with the lead''s email closes it too',
  (select count(*)::int from lead_gen_credits c join leads l on l.id = c.lead_id where l.email = 'rss_gail@example.test'), 1);
select test.throws('lead gen: a credit is approved before it is paid', format($$select test.rss_admin('lead_gen_credit', jsonb_build_object('credit', %L, 'action', 'paid', 'reference', 'ET-1'))$$,
  (select id from lead_gen_credits where staff_id = test.id('rss_eric') order by created_at limit 1)), '%Approve the credit%');
select test.rss_admin('lead_gen_credit', jsonb_build_object('credit', (select id from lead_gen_credits where staff_id = test.id('rss_eric') order by created_at limit 1), 'action', 'approve'));
select test.rss_admin('lead_gen_credit', jsonb_build_object('credit', (select id from lead_gen_credits where staff_id = test.id('rss_eric') order by created_at limit 1), 'action', 'paid', 'reference', 'ET-1'));
select test.eq('lead gen: approved then paid, with the reference; Eric''s totals follow',
  (select x -> 'totals' ->> 'paid_cents' from (select app.door(test.id('rss_eric'), 'aal2', 'va_read', 'my_owner_leads', '{"_va": "sales"}') x) s), '10000');
select test.eq('lead gen: Admin reads the people and the credits',
  (select x ->> 'signed' from jsonb_array_elements(app.door(test.id('rss_admin'), 'aal2', 'admin_read', 'lead_generators', '{}') -> 'people') x where x ->> 'id' = test.id('rss_eric')::text), '2');

-- ================================================================ 7. recruit invite links (5135)
select test.throws('recruit: invite links are for in-person salespeople', $$select app.door(test.id('rss_cs'), 'aal2', 'va_do', 'recruit_link', '{"_va": "cs"}')$$, '%in-person salespeople%');
create temp table rss_rl as select app.door(test.id('rss_jamal'), 'aal2', 'va_do', 'recruit_link', '{"_va": "sales"}') r;
select test.ok('recruit: Jamal gets his link, the in-person Sales application with his code',
  (select r ->> 'code' ~ '^[a-z0-9]{8}$' and r ->> 'link' like '%/careers/%/apply?by=' || (r ->> 'code') || '&src=referral' from rss_rl));
select test.eq('recruit: the same link every time', (select app.door(test.id('rss_jamal'), 'aal2', 'va_do', 'recruit_link', '{"_va": "sales"}') ->> 'code'), (select r ->> 'code' from rss_rl));
select test.ok('recruit: the application from the link is saved', coalesce((public.server_hiring_apply(jsonb_build_object('role', 'sales-in-person', 'full_name', 'Rss Rick Recruit',
  'email', 'rss_rick@example.test', 'phone', '416-555-0171', 'by', (select r ->> 'code' from rss_rl),
  'answers', '{"english":"Fluent: I handle calls on my own every day","years":"3 to 5 years","done":["Phone sales","Used a CRM","Car rental, dealership or automotive"],"commission":"I like being paid for results","in_person":"Yes","days":["Thursday","Friday","Saturday","Sunday"],"hours":"Yes, all of them","languages":["English","Tagalog"],"turo":"Ask what matters most to them, then show what is included (delivery, support, coverage options) and offer only the savings our rate sheet allows","discount":"Explain the options we do have (longer rental rates, the non-refundable saving) and ask which works for them","toll":"Listen, show them the toll record, explain the charge, and pass it to the office if they still dispute it","why_local":"A person answers, we deliver, and we fix problems the same day.","expect":"twenty","start":"2026-11-02","hours_week":"25"}'::jsonb), null) ->> 'ok')::boolean, false));
select test.eq('recruit: the application is Jamal''s recruit', (select recruited_by from job_applications where email = 'rss_rick@example.test'), test.id('rss_jamal'));
select test.ok('recruit: Jamal is told', test.rss_alert('recruit_applied') >= 1);
select test.eq('recruit: Jamal tracks the recruit (first name only)', (select x -> 'rows' -> 0 ->> 'name' from (select app.door(test.id('rss_jamal'), 'aal2', 'va_read', 'my_recruits', '{"_va": "sales"}') x) s), 'Rss');
select test.eq('recruit: Admin sees who recruited them',
  (select app.hiring_application_read(test.id('rss_admin'), jsonb_build_object('id', (select id from job_applications where email = 'rss_rick@example.test'))) ->> 'recruited_by'), 'Rss Jamal Safy');
update job_applications set status = 'hired' where email = 'rss_rick@example.test';
select test.ok('recruit: Jamal is told when they are hired', test.rss_alert('recruit_hired') >= 1);

-- ================================================================ 8. a salesperson's shift claim waits for an Admin (5136)
insert into field_shift_slots (id, starts_at, ends_at, capacity, created_by) values
  (test.id('slot:rss_1'), now() + interval '3 days', now() + interval '3 days 6 hours', 2, test.id('rss_admin')),
  (test.id('slot:rss_2'), now() + interval '4 days', now() + interval '4 days 6 hours', 1, test.id('rss_admin'));
create temp table rss_c1 as select app.door(test.id('rss_jamal'), 'aal2', 'field_do', 'shift_take', jsonb_build_object('slot', test.id('slot:rss_1'))) r;
select test.eq('shift: a salesperson''s claim is pending, not held', (select (r ->> 'pending') || '/' || (select count(*) from field_shift_plans where slot_id = test.id('slot:rss_1') and cancelled_at is null) from rss_c1), 'true/0');
select test.ok('shift: the Admins are told', test.rss_alert('shift_claim_pending') >= 1);
select test.eq('shift: a second press is the same claim', app.door(test.id('rss_jamal'), 'aal2', 'field_do', 'shift_take', jsonb_build_object('slot', test.id('slot:rss_1'))) ->> 'claim', (select r ->> 'claim' from rss_c1));
select test.eq('shift: My shifts lists it as waiting', (select x -> 'claims' -> 0 ->> 'status' from (select app.door(test.id('rss_jamal'), 'aal2', 'field_read', 'my_shifts', '{}') x) s), 'pending');
select test.throws('shift: only an Admin decides', format($$select app.door(test.id('rss_sam'), 'aal2', 'admin_do', 'shift_claim_decide', jsonb_build_object('claim', %L, 'approve', true))$$, (select r ->> 'claim' from rss_c1)), null);
select test.rss_admin('shift_claim_decide', jsonb_build_object('claim', (select r ->> 'claim' from rss_c1), 'approve', true));
select test.eq('shift: approved: the shift is his', (select count(*)::int from field_shift_plans where slot_id = test.id('slot:rss_1') and staff_id = test.id('rss_jamal') and cancelled_at is null), 1);
select test.ok('shift: he is told', test.rss_alert('shift_claim_decided') >= 1);
create temp table rss_c2 as select app.door(test.id('rss_jamal'), 'aal2', 'field_do', 'shift_take', jsonb_build_object('slot', test.id('slot:rss_2'))) r;
select test.throws('shift: a denial needs the reason', format($$select test.rss_admin('shift_claim_decide', jsonb_build_object('claim', %L, 'approve', false))$$, (select r ->> 'claim' from rss_c2)), '%why%');
select test.rss_admin('shift_claim_decide', jsonb_build_object('claim', (select r ->> 'claim' from rss_c2), 'approve', false, 'note', 'Covered already'));
select test.eq('shift: denied, with the reason, nothing held',
  (select status || '/' || decided_note || '/' || (select count(*) from field_shift_plans where slot_id = test.id('slot:rss_2') and cancelled_at is null) from shift_claims where id = (select (r ->> 'claim')::uuid from rss_c2)), 'denied/Covered already/0');

-- ================================================================ 9. texts with a phone number blocked, calls flagged (5137)
select test.eq('text: a phone number is found written or spoken',
  app.has_phone_number('call me at 647 555 0199') || '/' || app.has_phone_number('six four seven, five five five, zero one nine nine') || '/' || app.has_phone_number('Booking CC-10131 at $450'),
  'true/true/false');
create temp table rss_txt as select app.door(test.id('rss_sam'), 'aal2', 'va_do', 'phone_compose', '{"number": "+14165550199", "body": "Text me at (647) 555-0199", "_va": "sales"}') r;
select test.eq('text: a salesperson''s text with a phone number is refused with the reason, and kept for Admin',
  (select (r ->> 'blocked') || '/' || (r ->> 'error' like 'Not sent: phone numbers are not sent by text%') from rss_txt)
  || '/' || (select count(*) from call_flags where staff_id = test.id('rss_sam') and source = 'text' and blocked), 'true/true/1');
select test.ok('text: a text without a phone number goes on as before', coalesce(app.door(test.id('rss_sam'), 'aal2', 'va_do', 'phone_compose', '{"number": "+14165550199", "body": "See you at 5", "_va": "sales"}') ->> 'blocked', 'no') = 'no');
insert into phone_threads (id, number) values (test.id('thread:rss'), '+14165550111');
insert into phone_activity (id, thread_id, kind, direction, staff_user_id, transcript) values (test.id('act:rss'), test.id('thread:rss'), 'call', 'out', test.id('rss_sam'),
  '[{"who": "us", "text": "Sure, call my personal number, it is 647 555 0123"}, {"who": "them", "text": "My number is 416 555 0100"}, {"who": "us", "text": "We take cash only, no card"}]'::jsonb);
select test.eq('call: the salesperson''s lines are flagged with their category; the customer''s are not',
  (select string_agg(category, ',' order by category) from call_flags where activity_id = test.id('act:rss')), 'cash_only,personal_number,phone_number');
select test.ok('call: the Admins are told', test.rss_alert('call_flagged') >= 1);
insert into phone_activity (id, thread_id, kind, direction, staff_user_id, transcript) values (test.id('act:rss_cs'), test.id('thread:rss'), 'call', 'out', test.id('rss_cs'),
  '[{"who": "us", "text": "Call me at 647 555 0123"}]'::jsonb);
select test.eq('call: staff without Sales are not scanned', (select count(*)::int from call_flags where activity_id = test.id('act:rss_cs')), 0);
select test.rss_admin('call_flag_review', jsonb_build_object('flag', (select id from call_flags where activity_id = test.id('act:rss') and category = 'phone_number')));
select test.eq('call: Admin reviews a flag', (app.door(test.id('rss_admin'), 'aal2', 'admin_read', 'call_flags', '{}') ->> 'open'), (select count(*)::text from call_flags where reviewed_at is null));
select test.ok('tables: row-level security with admin_all on each new table',
  (select count(*) from pg_policies where policyname = 'admin_all' and tablename in ('booking_request_notes', 'lead_gen_credits', 'shift_claims', 'call_flags', 'call_flag_words')) = 5);
