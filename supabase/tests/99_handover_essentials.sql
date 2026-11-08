-- 99: the handover essentials (migration 0263): the list, the renter's reminder before the pickup day, the evening task,
-- and the gates of the handover kept. Fixtures start with "he"; 555 numbers.
select test.suite('99 handover essentials');
-- 0720 refuses new paper signatures; this file's fixtures signed on paper before it (a superuser session only)
select set_config('app.paper_fixture', 'on', false);
select test.mk_user('he_admin', 'admin');
select test.mk_owner('he_o');
select test.mk_vehicle('HEA', 'he_o');
select test.mk_vehicle('HEB', 'he_o');
select test.mk_renter('he_r');
select test.mk_renter('he_n', false);
update renters set mobile = null where id = test.id('renter:he_n');
update program_settings set phone_enabled = true where id = (app.settings()).id;
-- a fixed clock: the day before pickup, Toronto time
create function test.he_at(p text) returns timestamptz language sql as $$ select p::timestamp at time zone 'America/Toronto' $$;
select test.mk_booking('CC-HE1', 'HEA', 'he_r', '2027-03-11 10:00', '2027-03-14 10:00', 'confirmed');
select test.mk_booking('CC-HE2', 'HEB', 'he_n', '2027-03-11 15:00', '2027-03-13 15:00', 'confirmed');
update bookings set deposit_pay_method = 'card', deposit_cents = 50000, coverage_confirmed_at = now() where booking_number like 'CC-HE%';
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band)
select test.id('booking:CC-HE' || n), test.id('driver:he_' || r), 'renter', 'He ' || r, date '1990-05-05', 36, '26_plus' from (values (1, 'r'), (2, 'n')) v(n, r);
update booking_drivers set identity_verified_on = null where booking_id in (test.id('booking:CC-HE1'), test.id('booking:CC-HE2'));
update drivers set identity_status = 'not_started' where id in (test.id('driver:he_r'), test.id('driver:he_n'));

select test.eq('the list: nothing done yet', (select (e ->> 'licence') || '/' || (e ->> 'agreement') || '/' || (e ->> 'deposit') || '/' || (e ->> 'ready_for_handover')
  from (select app.handover_essentials(test.id('booking:CC-HE1')) e) x), 'false/false/false/false');
select test.ok('on by default: by text, the task at 18:00', (select essentials_reminders = 'text' and essentials_task_hour = 18 from program_settings where id = (app.settings()).id));

-- two days before: nothing
select test.eq('two days before: nothing yet', app.essentials_sweep(test.he_at('2027-03-09 12:00')) ->> 'texts', '0');
-- the day before at 9: too early for a text
select test.eq('the day before, 9:00: not yet', app.essentials_sweep(test.he_at('2027-03-10 09:00')) ->> 'texts', '0');
create temp table he as select app.essentials_sweep(test.he_at('2027-03-10 10:30')) v;
select test.eq('the day before, 10:30: the renter texted, the one with no mobile emailed', (select (v ->> 'texts') || '/' || (v ->> 'emails') from he), '1/1');
select test.ok('the text names the licence and the agreement, and the booking link', exists (select 1 from phone_outbox p where p.booking_id = test.id('booking:CC-HE1') and p.sms_kind = 'essentials'
  and p.body like '%upload your driver''s licence%' and p.body like '%sign the rental agreement%' and p.body like '%/account/bookings/CC-HE1'));
select test.ok('the email for the renter with no mobile', exists (select 1 from messages m where m.booking_id = test.id('booking:CC-HE2') and m.subject like 'Before your pickup%'));
select test.eq('once a day: the next run sends nothing', (select (v ->> 'texts') || '/' || (v ->> 'emails') from (select app.essentials_sweep(test.he_at('2027-03-10 11:00')) v) x), '0/0');
select test.eq('no staff task before the evening', (select count(*) from tasks where booking_id = test.id('booking:CC-HE1') and task_type = 'handover_essentials'), 0::bigint);

-- the evening before: the task names what is missing
select app.essentials_sweep(test.he_at('2027-03-10 18:05'));
select test.ok('the evening task: the licence, the signature, a card for the deposit', exists (select 1 from tasks t where t.booking_id = test.id('booking:CC-HE1') and t.task_type = 'handover_essentials'
  and t.title like 'Pickup tomorrow: CC-HE1 missing%' and t.title like '%licence approved%' and t.title like '%agreement signed%' and t.title like '%card for the deposit hold%'));
select app.essentials_sweep(test.he_at('2027-03-10 18:30'));
select test.eq('one task, not one per run', (select count(*) from tasks where booking_id = test.id('booking:CC-HE1') and task_type = 'handover_essentials'), 1::bigint);

-- done: the list says so, nothing more is sent
update booking_drivers set identity_verified_on = current_date where booking_id = test.id('booking:CC-HE1');
update bookings set agreement_on_paper = true where booking_number = 'CC-HE1';
insert into deposits (booking_id, amount_cents, method, status, taken_at) values (test.id('booking:CC-HE1'), 50000, 'card_hold', 'held', now());
select test.eq('all three done: ready for the handover', app.handover_essentials(test.id('booking:CC-HE1')) ->> 'ready_for_handover', 'true');
update program_settings set essentials_reminders = 'off' where id = (app.settings()).id;
select test.eq('reminders off: no text', app.essentials_sweep(test.he_at('2027-03-10 12:00')) ->> 'texts', '0');
update program_settings set essentials_reminders = 'text' where id = (app.settings()).id;

-- the gates of the handover stand: no car released without the licence, the signature or the deposit
update bookings set agreement_on_paper = false where booking_number = 'CC-HE2';
select test.throws('no handover without the licence approved', $$update bookings set status = 'on_rent' where booking_number = 'CC-HE2'$$, null);
select test.ok('the field job carries the list', (select app.handover_essentials(test.id('booking:CC-HE2')) ? 'checkout_photos'));
