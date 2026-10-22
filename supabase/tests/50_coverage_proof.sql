-- 49: proof of coverage (the coverage proof migration). The card's funding from Stripe; option 1, OPCF 27 (insurer,
-- policy number, an expiry after the return date, several pages to one proof, review as a whole, a declined proof
-- and a new one); option 2, credit card coverage (only the Card on File, a credit card in the renter's name, the
-- renter's tick, the benefit document optional, debit and prepaid refused, the card checked again at approval);
-- changing the option; the Protection Plan (a request becomes a task, staff confirm its activation); the staff
-- screen and its doors; the field summary; reminders 48 and 24 hours before pickup; the identity chase giving way;
-- retention and the purge list; privileges. Fixtures start with "cv".
select test.suite('50 coverage proof');

select test.mk_user('cv_admin', 'admin');
select test.mk_user('cv_cs', 'va', 'cs');
select test.mk_user('cv_fleet', 'va', 'fleet');
select test.mk_owner('cv_own');
select test.mk_vehicle('CV1', 'cv_own');
select test.mk_renter('cv_opal');
select test.mk_renter('cv_carl');
select test.mk_renter('cv_debi');
select test.mk_renter('cv_nora');
select test.mk_renter('cv_pat');
select test.mk_renter('cv_rem');

create or replace function test.cv_day(p_days integer, p_hour integer default 10) returns text language sql stable as $$
  select to_char((now() at time zone 'America/Toronto')::date + p_days, 'YYYY-MM-DD') || ' ' || lpad(p_hour::text, 2, '0') || ':00' $$;
create or replace function test.cv_err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create or replace function test.cv_up(p_number text, p_by uuid, p_details jsonb, p_tag text default 'a', p_mime text default 'application/pdf') returns uuid
language sql as $$ select app.register_verification_upload(test.id('booking:' || p_number), p_by, 'coverage_proof', null,
  'renters/cv/' || p_number || '/coverage-' || p_tag || '.pdf', md5(p_number || p_tag), p_mime, p_details) $$;
create or replace function test.cv_proof(p_number text) returns coverage_proofs language sql stable as $$
  select * from app.current_coverage_proof(test.id('booking:' || p_number)) $$;
grant execute on all functions in schema test to authenticated, anon;

-- five confirmed bookings, 3 days out for 3 days, each with its option; nobody else is on the car for those dates
select test.mk_booking('CV-1', 'CV1', 'cv_opal', test.cv_day(3), test.cv_day(6), 'confirmed');
select test.mk_booking('CV-2', 'CV1', 'cv_carl', test.cv_day(10), test.cv_day(13), 'confirmed');
select test.mk_booking('CV-3', 'CV1', 'cv_debi', test.cv_day(17), test.cv_day(20), 'confirmed');
select test.mk_booking('CV-4', 'CV1', 'cv_nora', test.cv_day(24), test.cv_day(27), 'confirmed');
select test.mk_booking('CV-5', 'CV1', 'cv_pat', test.cv_day(31), test.cv_day(34), 'confirmed');
update bookings set coverage_option = 1 where booking_number = 'CV-1';
update bookings set coverage_option = 2 where booking_number in ('CV-2', 'CV-3', 'CV-4');
update bookings set coverage_option = 3 where booking_number = 'CV-5';
update payment_methods set funding = 'debit', is_credit = false where id = test.id('card:cv_debi');
update payment_methods set cardholder_name = 'Somebody Else' where id = test.id('card:cv_nora');

-- ================================================================ 1. the card's funding from Stripe
create temp table cv_saved as select app.save_card_on_file(test.id('renter:cv_rem'),
  '{"brand": "visa", "last4": "5556", "cardholder_name": "Cv Rem", "exp_month": 1, "exp_year": 2031, "is_credit": false, "funding": "debit", "country": "ca"}',
  '{"processor": "stripe", "method_id": "pm_cv_debit"}') as id;
select test.eq('the card''s funding and country are kept from Stripe (debit is not credit); a card with only is_credit reads as credit',
  (select f.funding || ':' || f.is_credit || ':' || f.card_country from payment_methods f where f.id = (select id from cv_saved))
  || '/' || (app.card_coverage_check(test.id('booking:CV-2')) ->> 'funding'),
  'debit:false:CA/credit');

-- ================================================================ 2. the card check
select test.eq('the card check: a credit card in the renter''s name qualifies, with the brand, the last four, the class and the days',
  (select (c ->> 'eligible') || '/' || (c ->> 'brand') || '/' || (c ->> 'last4') || '/' || (c ->> 'name_matches') || '/' || (c ->> 'vehicle_class') || '/' || (c ->> 'rental_days')
     from app.card_coverage_check(test.id('booking:CV-2')) c), 'true/visa/4242/true/Premium/3');
select test.eq('a debit card does not qualify, and the message offers OPCF 27 or the Protection Plan',
  (select (c ->> 'problem') || '/' || (c ->> 'message') from app.card_coverage_check(test.id('booking:CV-3')) c),
  'not_credit/The card you paid with (Visa ending 4242) is a debit card. Rental coverage counts only on a credit card: choose OPCF 27 on your own auto policy or the Protection Plan instead.');
select test.eq('a card in someone else''s name does not qualify', app.card_coverage_check(test.id('booking:CV-4')) ->> 'problem', 'name_mismatch');
update bookings set card_on_file_id = null where booking_number = 'CV-4';
select test.eq('no card yet: pay with the card first', app.card_coverage_check(test.id('booking:CV-4')) ->> 'problem', 'no_card');
update bookings set card_on_file_id = test.id('card:cv_nora') where booking_number = 'CV-4';
select test.eq('names compare without case, spaces or punctuation', app.same_person_name('ANNE-MARIE  o''neil', 'Anne Marie ONeil')::text || app.same_person_name('A B', 'A C')::text, 'truefalse');

-- ================================================================ 3. option 1: OPCF 27
select test.eq('an upload needs the insurer, the policy number and the expiry first',
  test.cv_err($$select test.cv_up('CV-1', test.id('cv_opal'), '{"coverage_option": 1, "insurer_name": "Maple Mutual"}')$$),
  'Add the insurer, the policy number and the policy expiry date first');
select test.ok('a policy ending on the return date is refused: it must still be active after it',
  test.cv_err(format($$select test.cv_up('CV-1', test.id('cv_opal'), '{"coverage_option": 1, "insurer_name": "Maple Mutual", "policy_number": "MM-1", "policy_expiry": "%s"}')$$,
                     (select app.local_date(return_at) from bookings where booking_number = 'CV-1')))
  like 'The policy must still be active after your return date%');
select test.eq('a proof for the other option is refused', test.cv_err($$select test.cv_up('CV-1', test.id('cv_opal'), '{"coverage_option": 2}')$$),
  'Your booking is set to coverage option 1. Change the option first.');
select test.eq('a stranger cannot add a proof', test.cv_err($$select test.cv_up('CV-1', test.id('cv_carl'), '{"coverage_option": 1}')$$), 'Not permitted');
select test.cv_up('CV-1', test.id('cv_opal'), jsonb_build_object('coverage_option', 1, 'insurer_name', 'Maple Mutual', 'policy_number', 'MM-1',
  'policy_expiry', (select app.local_date(return_at) + 30 from bookings where booking_number = 'CV-1')), 'p1');
select test.cv_up('CV-1', test.id('cv_opal'), '{"coverage_option": 1}', 'p2', 'image/jpeg');
select test.eq('two pages (a PDF and a phone photo) make one proof with the typed details; staff are asked once; a review task is raised',
  (select p.status || '/' || p.insurer_name || '/' || p.policy_number || '/' || (select count(*) from verification_uploads u where u.coverage_proof_id = p.id and u.status = 'submitted')
     from test.cv_proof('CV-1') p)
  || '/' || (select count(*) from app_events where code = 'staff_identity_review' and entity_id = test.id('booking:CV-1'))
  || '/' || (select count(*) from tasks where booking_id = test.id('booking:CV-1') and task_type = 'verify_renter' and status = 'open'),
  'submitted/Maple Mutual/MM-1/2/1/1');
select test.eq('each page is a private document, a rental record kept 7 years after the return',
  (select string_agg(distinct d.storage_bucket || ':' || d.retention || ':' || (d.purge_after = b.return_at + interval '7 years'), ',')
     from verification_uploads u join documents d on d.id = u.document_id join bookings b on b.id = u.booking_id where u.booking_id = test.id('booking:CV-1')),
  'documents:records_7y:true');
update program_settings set coverage_proof_max_pages = 2 where effective_from = (select effective_from from app.settings());
select test.eq('pages are limited by Program settings', test.cv_err($$select test.cv_up('CV-1', test.id('cv_opal'), '{"coverage_option": 1}', 'p3')$$),
  'A proof can have up to 2 pages. Combine them into one PDF, or message us.');
update program_settings set coverage_proof_max_pages = 6 where effective_from = (select effective_from from app.settings());
select test.eq('the renter''s page reads the proof: in review, two pages, the earliest expiry allowed is the day after the return',
  (select (r ->> 'option') || '/' || (r -> 'proof' ->> 'status') || '/' || jsonb_array_length(r -> 'proof' -> 'pages') || '/' || ((r ->> 'min_policy_expiry')::date = (r ->> 'return_date')::date + 1)
     from app.renter_coverage(test.id('booking:CV-1')) r), '1/submitted/2/true');
select test.eq('the readiness still misses coverage', app.booking_readiness(test.id('booking:CV-1')) -> 'missing' ? 'coverage', true);

-- staff review
select test.eq('a fleet assistant does not review coverage', test.cv_err(format($$select app.review_coverage_proof('%s', test.id('cv_fleet'), true)$$, (test.cv_proof('CV-1')).id)),
  'Only customer service or an Admin reviews identity and coverage documents');
select test.eq('nor through the assistants'' door', test.cv_err(format($$select app.va_do(test.id('cv_fleet'), 'coverage_review', '{"proof": "%s", "approve": true}')$$, (test.cv_proof('CV-1')).id)),
  'Identity and coverage documents are reviewed by customer service');
select test.eq('a rejection needs a reason', test.cv_err(format($$select app.review_coverage_proof('%s', test.id('cv_cs'), false)$$, (test.cv_proof('CV-1')).id)),
  'Rejecting a proof needs a reason the renter can act on');
select app.va_do(test.id('cv_cs'), 'coverage_review', jsonb_build_object('proof', (test.cv_proof('CV-1')).id, 'approve', false, 'reason', 'The endorsement page is missing: send the OPCF 27 page.'));
select test.eq('rejected as a whole: both pages and the proof carry the reason; the renter is told what to fix',
  (select p.status || '/' || p.rejection_reason || '/' || (select string_agg(u.status, ',') from verification_uploads u where u.coverage_proof_id = p.id) from test.cv_proof('CV-1') p)
  || '/' || (select (payload ->> 'kind') || ':' || (payload ->> 'reject_reason') from app_events where code = 'renter_identity_rejected' and entity_id = test.id('booking:CV-1')),
  'rejected/The endorsement page is missing: send the OPCF 27 page./rejected,rejected/coverage_proof:The endorsement page is missing: send the OPCF 27 page.');
select test.eq('the renter''s page shows the reason', app.renter_coverage(test.id('booking:CV-1')) -> 'proof' ->> 'rejection_reason', 'The endorsement page is missing: send the OPCF 27 page.');
select test.cv_up('CV-1', test.id('cv_opal'), jsonb_build_object('coverage_option', 1, 'insurer_name', 'Maple Mutual', 'policy_number', 'MM-1',
  'policy_expiry', (select app.local_date(return_at) + 30 from bookings where booking_number = 'CV-1')), 'p4');
select test.eq('a new upload starts a new proof; the declined one is kept',
  (select string_agg(status, ',' order by created_at) from coverage_proofs where booking_id = test.id('booking:CV-1')), 'rejected,submitted');
-- the policy changed under the reviewer (here typed again shorter): approval checks the date again
update coverage_proofs set policy_expiry = (select app.local_date(return_at) from bookings where booking_number = 'CV-1') where id = (test.cv_proof('CV-1')).id;
select test.ok('approval checks that the policy runs past the return date',
  test.cv_err(format($$select app.review_coverage_proof('%s', test.id('cv_cs'), true)$$, (test.cv_proof('CV-1')).id)) like 'The policy ends on %, not after the return date%');
update coverage_proofs set policy_expiry = policy_expiry + 30 where id = (test.cv_proof('CV-1')).id;
-- 0078: customer service reviews from the booking itself, with no review task needed
update tasks set status = 'done', completed_at = now() where booking_id = test.id('booking:CV-1') and task_type = 'verify_renter' and status = 'open';
select test.eq('approval needs no open review task on the booking (0078)', test.cv_err(format($$select app.va_do(test.id('cv_cs'), 'coverage_review', '{"proof": "%s", "approve": true, "checks": {"active_after_return": true, "covers_car_and_drivers": true}}')$$,
  (test.cv_proof('CV-1')).id)), 'ok');
select test.eq('approved: the proof is confirmed with the reviewer and the ticks, its page approved, and the booking''s coverage confirmed',
  (select p.status || '/' || (p.confirmed_by = test.id('cv_cs')) || '/' || (p.reviewed_checks ->> 'covers_car_and_drivers') || '/'
          || (select string_agg(u.status, ',') from verification_uploads u where u.coverage_proof_id = p.id) from test.cv_proof('CV-1') p)
  || '/' || (select (coverage_confirmed_at is not null)::text from bookings where booking_number = 'CV-1')
  || '/' || (app.booking_readiness(test.id('booking:CV-1')) ->> 'coverage_confirmed'),
  'confirmed/true/true/approved/true/true');
select test.eq('after confirmation the renter cannot add pages', test.cv_err($$select test.cv_up('CV-1', test.id('cv_opal'), '{"coverage_option": 1}', 'p5')$$),
  'Your coverage is already confirmed. To change it, message us.');
select test.eq('the field summary names the policy', app.coverage_summary(test.id('booking:CV-1')) like 'Own policy with OPCF 27, Maple Mutual, valid to %', true);

-- ================================================================ 4. option 2: credit card coverage
select test.eq('the benefit document comes after the renter''s tick', test.cv_err($$select test.cv_up('CV-2', test.id('cv_carl'), '{"coverage_option": 2}')$$),
  'Confirm that your card includes rental car coverage first, then add its benefit document');
select test.eq('the tick is required', test.cv_err($$select app.submit_card_coverage(test.id('booking:CV-2'), test.id('cv_carl'), false)$$),
  'Tick that your card includes rental car coverage for this car and this length of rental, and that you will claim on it');
select test.eq('a debit card is refused with the message', test.cv_err($$select app.submit_card_coverage(test.id('booking:CV-3'), test.id('cv_debi'), true)$$),
  'The card you paid with (Visa ending 4242) is a debit card. Rental coverage counts only on a credit card: choose OPCF 27 on your own auto policy or the Protection Plan instead.');
select test.ok('a card in another name is refused', test.cv_err($$select app.submit_card_coverage(test.id('booking:CV-4'), test.id('cv_nora'), true)$$) like 'The card you paid with is not in your name.%');
select app.submit_card_coverage(test.id('booking:CV-2'), test.id('cv_carl'), true);
select test.eq('the renter''s tick: the proof takes the Card on File (brand, last four, credit, the cardholder), the words ticked with the class and days, and staff are asked once',
  (select p.status || '/' || p.card_issuer || '/' || p.card_last4 || '/' || p.card_funding || '/' || p.cardholder_name || '/' || p.name_matches || '/' || (p.renter_confirmed_by = test.id('cv_carl'))
          || '/' || p.confirmation_text from test.cv_proof('CV-2') p)
  || '/' || (select count(*) from app_events where code = 'staff_identity_review' and entity_id = test.id('booking:CV-2')),
  'submitted/Visa/4242/credit/Cv Carl/true/true/My card ending 4242 includes rental car coverage for a premium for 3 days, and I will claim on it for any damage to the car./1');
select test.cv_up('CV-2', test.id('cv_carl'), '{"coverage_option": 2}', 'benefit');
select test.eq('the optional benefit document is a page of the same proof (no second staff alert)',
  (select count(*) from verification_uploads u where u.coverage_proof_id = (test.cv_proof('CV-2')).id) || '/' || (select count(*) from app_events where code = 'staff_identity_review' and entity_id = test.id('booking:CV-2')),
  '1/1');
select test.eq('staff see the card facts, the Card on File check and the page with its private key',
  (select (f -> 'card' ->> 'funding') || '/' || (f -> 'card' ->> 'eligible') || '/' || (f -> 'proof' ->> 'card_is_card_on_file') || '/' || jsonb_array_length(f -> 'proof' -> 'pages')
          || '/' || ((f -> 'proof' -> 'pages' -> 0 ->> 'path') like 'renters/cv/CV-2/%') from app.coverage_review_facts(test.id('booking:CV-2')) f), 'credit/true/true/1/true');
-- the Card on File changed since the tick: approval is refused
insert into payment_methods (id, renter_id, card_brand, card_last4, cardholder_name, exp_month, exp_year, is_credit, funding)
values (test.id('card:cv_carl2'), test.id('renter:cv_carl'), 'mastercard', '4444', 'Cv Carl', 1, 2032, true, 'credit');
update bookings set card_on_file_id = test.id('card:cv_carl2') where booking_number = 'CV-2';
select test.eq('approval checks the card is still the Card on File', test.cv_err(format($$select app.review_coverage_proof('%s', test.id('cv_cs'), true)$$, (test.cv_proof('CV-2')).id)),
  'The card on this proof is no longer the Card on File');
update bookings set card_on_file_id = test.id('card:cv_carl') where booking_number = 'CV-2';
select app.review_coverage_proof((test.cv_proof('CV-2')).id, test.id('cv_admin'), true);
select test.eq('approved by an Admin: confirmed, and the summary names the card', (test.cv_proof('CV-2')).status || '/' || app.coverage_summary(test.id('booking:CV-2')),
  'confirmed/Credit card coverage, Visa ending 4242');

-- ================================================================ 5. changing the option
select test.eq('the debit card''s renter cannot move to option 2 (already there) nor have it confirmed; moving back to 2 from 1 is refused with the reason',
  (app.set_coverage_option(test.id('booking:CV-3'), test.id('cv_debi'), 1) ->> 'option')
  || '/' || test.cv_err($$select app.set_coverage_option(test.id('booking:CV-3'), test.id('cv_debi'), 2)$$),
  '1/The card you paid with (Visa ending 4242) is a debit card. Rental coverage counts only on a credit card: choose OPCF 27 on your own auto policy or the Protection Plan instead.');
select test.eq('the change is in the booking''s history', (select count(*) from booking_events where booking_id = test.id('booking:CV-3') and kind = 'verification' and note like 'Coverage option changed from 2 to 1'), 1::bigint);
select test.eq('option 3 is asked for, not chosen', test.cv_err($$select app.set_coverage_option(test.id('booking:CV-3'), test.id('cv_debi'), 3)$$) like 'Choose option 1%', true);
select app.set_coverage_option(test.id('booking:CV-2'), test.id('cv_carl'), 1);
select test.eq('changing a confirmed option lapses the proof and its page, and the coverage must be confirmed again',
  (select string_agg(status, ',') from coverage_proofs where booking_id = test.id('booking:CV-2'))
  || '/' || (select string_agg(status, ',') from verification_uploads where booking_id = test.id('booking:CV-2'))
  || '/' || (select coalesce(coverage_confirmed_at::text, 'not confirmed') || ':' || coverage_option from bookings where booking_number = 'CV-2'),
  'lapsed/replaced/not confirmed:1');
select test.eq('a stranger cannot change the option', test.cv_err($$select app.set_coverage_option(test.id('booking:CV-2'), test.id('cv_opal'), 2)$$), 'Not permitted');

-- ================================================================ 6. the Protection Plan
select app.request_protection_plan(test.id('booking:CV-3'), test.id('cv_debi'), 'My policy has no OPCF 27');
select test.eq('asking for the Protection Plan raises one task for customer service, with the note', (select count(*) || ':' || min(queue) || ':' || (min(detail) like '%My policy has no OPCF 27%')
  from tasks where booking_id = test.id('booking:CV-3') and task_type = 'protection_plan_request'), '1:cs:true');
select app.request_protection_plan(test.id('booking:CV-3'), test.id('cv_debi'));
select test.eq('asking again keeps one task', (select count(*) from tasks where booking_id = test.id('booking:CV-3') and task_type = 'protection_plan_request'), 1::bigint);
select test.eq('the Protection Plan is confirmed only once its line is on the booking',
  test.cv_err($$select app.confirm_protection_plan(test.id('booking:CV-5'), test.id('cv_cs'))$$), 'The booking has no Protection Plan line: price it and have the renter pay for it first');
select test.mk_line('CV-5', 'coverage_sold', 4500);
select test.eq('field staff do not confirm it', test.cv_err($$select app.confirm_protection_plan(test.id('booking:CV-5'), test.id('cv_fleet'))$$), 'Only customer service or an Admin confirms the Protection Plan');
select app.confirm_protection_plan(test.id('booking:CV-5'), test.id('cv_cs'), 'ACT-77');
select test.eq('confirmed: activation recorded, the booking''s coverage confirmed, the summary says Protection Plan',
  (select c.status || ':' || c.activation_ref || ':' || (c.activated_at is not null) from coverage_proofs c where c.booking_id = test.id('booking:CV-5'))
  || '/' || (app.booking_readiness(test.id('booking:CV-5')) ->> 'coverage_confirmed') || '/' || app.coverage_summary(test.id('booking:CV-5')),
  'confirmed:ACT-77:true/true/Protection Plan');
select test.eq('option 1 or 2 is not confirmed this way', test.cv_err($$select app.confirm_protection_plan(test.id('booking:CV-2'), test.id('cv_cs'))$$), 'This booking is not on the Protection Plan (option 3)');

-- ================================================================ 7. handover stays blocked until coverage is confirmed
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band, identity_verified_on, identity_method)
values (test.id('booking:CV-2'), test.id('driver:cv_carl'), 'renter', 'Cv Carl', date '1990-05-05', 36, '26_plus', app.today(), 'staff_review');
select test.eq('handover is refused while the coverage is not confirmed',
  test.cv_err($$update bookings set status = 'on_rent' where booking_number = 'CV-2'$$), 'No car is released until a Coverage Option is confirmed');

-- ================================================================ 8. reminders 48 and 24 hours before pickup
create or replace function test.cv_rem(p_number text) returns text language sql stable as $$
  select coalesce(string_agg(split_part(dedupe_key, ':', 3), ',' order by id), 'none') from app_events where code = 'renter_coverage_needed' and entity_id = test.id('booking:' || p_number) $$;
select app.job_coverage_reminders((select pickup_at - interval '47 hours' from bookings where booking_number = 'CV-2'));
select app.job_coverage_reminders((select pickup_at - interval '46 hours' from bookings where booking_number = 'CV-2'));
select test.eq('48 hours before pickup with no proof: one reminder, not repeated', test.cv_rem('CV-2'), 'h48');
select app.job_coverage_reminders((select pickup_at - interval '23 hours' from bookings where booking_number = 'CV-2'));
select test.eq('24 hours before: the second one', test.cv_rem('CV-2'), 'h48,h24');
select test.mk_booking('CV-6', 'CV1', 'cv_rem', test.cv_day(40), test.cv_day(42), 'confirmed');
update bookings set coverage_option = 1 where booking_number = 'CV-6';
select app.job_coverage_reminders((select pickup_at - interval '20 hours' from bookings where booking_number = 'CV-6'));
select test.eq('a booking first seen inside 24 hours gets only the 24-hour one', test.cv_rem('CV-6'), 'h24');
select test.mk_booking('CV-7', 'CV1', 'cv_rem', test.cv_day(45), test.cv_day(47), 'confirmed');
update bookings set coverage_option = 1 where booking_number = 'CV-7';
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band) values (test.id('booking:CV-7'), test.id('driver:cv_rem'), 'renter', 'Cv Rem', date '1990-05-05', 36, '26_plus');
select app.job_coverage_reminders((select pickup_at - interval '40 hours' from bookings where booking_number = 'CV-7'));
select test.eq('at 48 hours with a licence also missing, the identity reminder carries it (no coverage email)', test.cv_rem('CV-7'), 'none');
select app.job_coverage_reminders((select pickup_at - interval '40 hours' from bookings where booking_number = 'CV-3'));
select test.eq('no reminder while nothing is asked of the renter: proof in review (CV-1 confirmed), Protection Plan (CV-5)',
  test.cv_rem('CV-1') || '/' || test.cv_rem('CV-5'), 'none/none');
select app.process_events(100000);
select test.eq('the reminder email is built with the choice, what to send and the hours left, with no variable missing',
  (select (payload ->> 'hours_left') || '/' || (payload ->> 'coverage_choice') || '/' || (payload ->> 'coverage_what_to_send' like 'A PDF or photos of your policy document%') || '/'
          || coalesce(array_to_string(missing_variables, ','), '')
     from notification_outbox where code = 'renter_coverage_needed' and entity_id = test.id('booking:CV-6')), '24 hours/OPCF 27 on your own auto policy/true/');
-- the identity chase gives way when only the proof is missing
select app.emit_event('renter_identity_needed', 'booking', test.id('booking:CV-6'), jsonb_build_object('booking_id', test.id('booking:CV-6')), 'renter_identity_needed:' || test.id('booking:CV-6') || ':chase');
select app.emit_event('renter_identity_needed', 'booking', test.id('booking:CV-7'), jsonb_build_object('booking_id', test.id('booking:CV-7')), 'renter_identity_needed:' || test.id('booking:CV-7') || ':chase');
select app.process_events(100000);
select test.eq('the 48-hour identity chase is not sent when only the proof is missing; it is when a licence is missing too',
  (select count(*) from notification_outbox where code = 'renter_identity_needed' and entity_id = test.id('booking:CV-6'))
  || '/' || (select count(*) from notification_outbox where code = 'renter_identity_needed' and entity_id = test.id('booking:CV-7')), '0/1');

-- ================================================================ 9. retention: the purge list
insert into documents (id, kind, title, storage_bucket, storage_path, retention, purge_after, booking_id) values
  (test.id('doc:cv_due'), 'id_front', 'old licence', 'identity', 'renters/cv/old-front.jpg', 'id_face_90d', now() - interval '1 day', test.id('booking:CV-4')),
  (test.id('doc:cv_hold'), 'id_back', 'held licence', 'identity', 'renters/cv/held.jpg', 'id_face_90d', now() - interval '1 day', test.id('booking:CV-4')),
  (test.id('doc:cv_later'), 'coverage_proof', 'policy', 'documents', 'renters/cv/policy.pdf', 'records_7y', now() + interval '1 day', test.id('booking:CV-4')),
  (test.id('doc:cv_dispute'), 'id_front', 'disputed', 'identity', 'renters/cv/disputed.jpg', 'id_face_90d', now() - interval '1 day', test.id('booking:CV-3'));
update documents set legal_hold = true where id = test.id('doc:cv_hold');
insert into disputes (booking_id, payment_id, amount_cents, status) values (test.id('booking:CV-3'), test.id('payment:CV-3'), 1000, 'open');
select test.eq('the purge list: only a file past its date, not on legal hold, not of a booking with an open chargeback',
  (select string_agg(x ->> 'path', ',') from jsonb_array_elements(app.documents_due_for_purge(1000)) x where x ->> 'path' like 'renters/cv/%'), 'renters/cv/old-front.jpg');
create temp table cv_purged as select app.mark_documents_purged(array[test.id('doc:cv_due'), test.id('doc:cv_later')]) as n;
select test.eq('marking it purged clears its key; a file not due is not touched',
  (select n from cv_purged)
  || '/' || (select (purged_at is not null) || ':' || coalesce(storage_path, 'gone') from documents where id = test.id('doc:cv_due'))
  || '/' || (select coalesce(purged_at::text, 'kept') from documents where id = test.id('doc:cv_later')), '1/true:gone/kept');

-- ================================================================ 10. the renter's doors and privileges
select test.eq('the renter''s own reads only', test.cv_err($$select public.server_renter_coverage(test.id('booking:CV-1'), test.id('cv_carl'))$$) <> 'ok', true);
select test.eq('the renter reads their own', public.server_renter_coverage(test.id('booking:CV-1'), test.id('cv_opal')) ->> 'confirmed', 'true');
select test.eq('the browser roles execute none of the coverage functions',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where ((n.nspname = 'public' and p.proname in ('server_renter_coverage', 'renter_set_coverage_option', 'renter_submit_card_coverage', 'renter_request_protection_plan',
                                                   'server_documents_due_for_purge', 'server_mark_documents_purged'))
        or (n.nspname = 'app' and p.proname in ('card_coverage_check', 'set_coverage_option', 'submit_card_coverage', 'review_coverage_proof', 'confirm_protection_plan',
                                                'renter_coverage', 'coverage_review_facts', 'documents_due_for_purge', 'mark_documents_purged', 'job_coverage_reminders')))
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);
