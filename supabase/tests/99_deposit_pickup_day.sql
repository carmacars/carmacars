-- 99: the deposit hold placed on the pickup day on the card on file (migration 0261). Fixtures start with "pd"; 555 numbers.
select test.suite('99 deposit on the pickup day');
select test.mk_user('dpd_admin', 'admin');
select test.mk_owner('dpd_o');
select test.mk_vehicle('DPDA', 'dpd_o');
select test.mk_vehicle('DPDB', 'dpd_o');
select test.mk_vehicle('DPDC', 'dpd_o');
select test.mk_vehicle('DPDD', 'dpd_o');
select test.mk_vehicle('DPDE', 'dpd_o');
select test.mk_renter('dpd_r');
select test.mk_renter('dpd_d');
select test.mk_renter('dpd_x');
select test.mk_renter('dpd_n', false);
update renters set mobile = null where id = test.id('renter:dpd_n');
update program_settings set phone_enabled = true where id = (app.settings()).id;
insert into payment_method_secrets (payment_method_id, processor, processor_customer_id, processor_method_id, fingerprint)
values (test.id('card:dpd_r'), 'stripe', 'cus_dpd_r', 'pm_dpd_r', 'fp_dpd_r'), (test.id('card:dpd_d'), 'stripe', 'cus_dpd_d', 'pm_dpd_d', 'fp_dpd_d');
update payment_methods set funding = 'debit', is_credit = false where id = test.id('card:dpd_d');
create or replace function test.dpd_at(p_hours int) returns text language sql as $$
  select to_char((now() + make_interval(hours => p_hours)) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;
select test.mk_booking('CC-DPD1', 'DPDA', 'dpd_r', test.dpd_at(30), test.dpd_at(80), 'confirmed');
select test.mk_booking('CC-DPD2', 'DPDB', 'dpd_d', test.dpd_at(30), test.dpd_at(80), 'confirmed');
select test.mk_booking('CC-DPD3', 'DPDC', 'dpd_r', test.dpd_at(30 + 24 * 6), test.dpd_at(80 + 24 * 6), 'confirmed');
select test.mk_booking('CC-DPD4', 'DPDD', 'dpd_x', test.dpd_at(30), test.dpd_at(80), 'confirmed');
select test.mk_booking('CC-DPD5', 'DPDE', 'dpd_r', test.dpd_at(30 + 24 * 12), test.dpd_at(80 + 24 * 12), 'confirmed');
update bookings set deposit_pay_method = 'card', deposit_cents = 50000 where booking_number like 'CC-DPD%';
-- the pickup: soon and still ahead, the same Toronto day (20 minutes from now, or just before midnight when that is
-- sooner), with the hour at midnight so the test does not depend on the clock (a pickup a moment ago needs no link)
create function test.dpd_soon(p_number text) returns void language sql as $$
  update bookings b set pickup_at = x.at, return_at = x.at + (b.return_at - b.pickup_at), original_return_at = x.at + (b.return_at - b.pickup_at)
    from (select least(now() + interval '20 minutes',
                       (date_trunc('day', now() at time zone 'America/Toronto') + interval '1 day' - interval '1 second') at time zone 'America/Toronto') as at) x
   where b.booking_number = p_number $$;
create function test.dpd_due(p_number text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(public.server_deposit_autos_due()) x where x ->> 'booking_number' = p_number) $$;
create function test.dpd_link_due(p_number text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(public.server_deposit_links_due()) x where x ->> 'booking_number' = p_number) $$;
create function test.dpd_b(p_number text) returns bookings language sql as $$ select * from bookings where booking_number = p_number $$;
create function test.dpd_tok() returns text language sql as $$ select md5(random()::text) || md5(random()::text) $$;

select test.ok('on by default: the morning of the pickup day, at 8', (select deposit_timing = 'pickup_day' and deposit_auto_hour = 8 from program_settings where id = (app.settings()).id));
-- the time, Toronto
create function test.dpd_due_at(p_pickup text) returns text language sql as $$
  select to_char(app.deposit_auto_due_at(jsonb_populate_record(null::bookings, jsonb_build_object('pickup_at', p_pickup::timestamp at time zone 'America/Toronto'))) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;
select test.eq('pickup at 10: the hold at 8 that morning', test.dpd_due_at('2026-12-05 10:00'), '2026-12-05 08:00');
select test.eq('pickup before 8: from midnight that day', test.dpd_due_at('2026-12-05 06:30'), '2026-12-05 00:00');
select test.eq('in summer time too', test.dpd_due_at('2026-07-05 18:00'), '2026-07-05 08:00');
select test.ok('a pickup days away: not due', not test.dpd_due('CC-DPD3'));
select test.ok('a pickup tomorrow: not due yet', not test.dpd_due('CC-DPD1'));
select test.ok('a card on file and the hold to come: the link before pickup is not sent', not test.dpd_link_due('CC-DPD1'));

update program_settings set deposit_auto_hour = 0 where id = (app.settings()).id;
select test.dpd_soon('CC-DPD1');
select test.dpd_soon('CC-DPD2');
select test.dpd_soon('CC-DPD4');
select test.ok('the pickup day: due', test.dpd_due('CC-DPD1'));
select test.ok('the deposit job runs for it', (app.server_jobs_due() ->> 'deposits')::boolean);
select test.ok('the Money tab: scheduled', (app.booking_money(test.id('dpd_admin'), '{"booking": "CC-DPD1"}') #>> '{deposit_auto,status}') = 'scheduled');

-- ================================================================ placed on the card on file
create temp table pd as select 'a'::text k, public.server_deposit_auto_begin((test.dpd_b('CC-DPD1')).id, test.dpd_tok()) v;
select test.eq('the try: the deposit, the saved card', (select (v ->> 'ok') || '/' || (v ->> 'amount_cents') || '/' || (v ->> 'customer_id') || '/' || (v ->> 'method_id') from pd where k = 'a'), 'true/50000/cus_dpd_r/pm_dpd_r');
select test.ok('a hold request made by the job, never sent', exists (select 1 from payment_requests q where q.id = (select (v ->> 'id')::uuid from pd where k = 'a')
  and q.kind = 'hold' and q.covers = 'deposit' and q.channel = 'auto' and q.auto and q.created_by is null and q.status = 'open' and q.texted_at is null));
select test.eq('one try per booking: a second is refused', public.server_deposit_auto_begin((test.dpd_b('CC-DPD1')).id, test.dpd_tok()) ->> 'reason', 'not due');
select test.throws('never two automatic holds', format($s$insert into payment_requests (booking_id, renter_id, kind, covers, amount_cents, token_sha256, channel, expires_at)
  values (%L, %L, 'hold', 'deposit', 50000, %L, 'auto', now() + interval '1 day')$s$, (test.dpd_b('CC-DPD1')).id, (test.dpd_b('CC-DPD1')).renter_id, test.dpd_tok()), 'duplicate');
select test.eq('the link is not made while the hold is under way', public.server_deposit_link_payreq((test.dpd_b('CC-DPD1')).id, test.dpd_tok()) ->> 'reason', 'the automatic hold is under way');
select public.server_payreq_attach((select (v ->> 'id')::uuid from pd where k = 'a'), 'pi_dpd_1');
select test.eq('authorized: the hold is recorded', public.server_payreq_settle((select (v ->> 'id')::uuid from pd where k = 'a'), jsonb_build_object('id', 'pi_dpd_1', 'status', 'requires_capture', 'amount', 50000,
  'amount_capturable', 50000, 'customer_id', 'cus_dpd_r', 'method_id', 'pm_dpd_r', 'card', '{"brand": "visa", "last4": "4242", "funding": "credit", "fingerprint": "fp_dpd_r", "exp_month": 12, "exp_year": 2030}'::jsonb)) ->> 'ok', 'true');
select test.eq('the deposit is held on the card, as a hold taken at pickup', (select d.method || '/' || d.status || '/' || d.amount_cents from deposits d where d.booking_id = (test.dpd_b('CC-DPD1')).id), 'card_hold/held/50000');
select test.ok('no longer due; the Money tab says held', not test.dpd_due('CC-DPD1') and (app.booking_money(test.id('dpd_admin'), '{"booking": "CC-DPD1"}') #>> '{deposit_auto,status}') = 'held');
select test.ok('the handover ready check carries it', app.deposit_auto_state((test.dpd_b('CC-DPD1')).id) ->> 'status' = 'held');

-- ================================================================ a debit card on a booking that needs credit
insert into pd select 'd', public.server_deposit_auto_begin((test.dpd_b('CC-DPD2')).id, test.dpd_tok());
select test.ok('a debit card is not used for the hold', (select (v ->> 'ok') = 'false' and v ->> 'reason' like '%debit card%' from pd where k = 'd'));
select test.ok('a task "Deposit not taken" on the booking', exists (select 1 from tasks t where t.booking_id = (test.dpd_b('CC-DPD2')).id and t.task_type = 'deposit_not_taken' and t.status = 'open'));
select test.ok('the deposit link goes at once', test.dpd_link_due('CC-DPD2'));
select test.eq('the Money tab: failed, with the reason', app.booking_money(test.id('dpd_admin'), '{"booking": "CC-DPD2"}') #>> '{deposit_auto,status}', 'failed');

-- ================================================================ no saved card
select test.ok('no card on file (none saved with Stripe): the link before pickup as before', test.dpd_link_due('CC-DPD4'));
insert into pd select 'x', public.server_deposit_auto_begin((test.dpd_b('CC-DPD4')).id, test.dpd_tok());
select test.eq('the pickup day with no card: not placed, the reason', (select v ->> 'reason' from pd where k = 'x'), 'no card saved for it');
select test.ok('the task opens for it too', exists (select 1 from tasks t where t.booking_id = (test.dpd_b('CC-DPD4')).id and t.task_type = 'deposit_not_taken'));

-- ================================================================ a decline, then the renter places it with the link
select test.dpd_soon('CC-DPD3');
insert into pd select 'c', public.server_deposit_auto_begin((test.dpd_b('CC-DPD3')).id, test.dpd_tok());
select test.ok('the try starts', (select (v ->> 'ok')::boolean from pd where k = 'c'));
select test.eq('declined at the bank: recorded', public.server_deposit_auto_failed((select (v ->> 'id')::uuid from pd where k = 'c'), 'Your card was declined.') ->> 'status', 'failed');
select test.eq('recorded once', public.server_deposit_auto_failed((select (v ->> 'id')::uuid from pd where k = 'c'), 'again') ->> 'status', 'failed');
select test.eq('one task, the reason in it', (select count(*) || '/' || bool_and(t.detail like '%Your card was declined.%') from tasks t where t.booking_id = (test.dpd_b('CC-DPD3')).id and t.task_type = 'deposit_not_taken'), '1/true');
select test.ok('the link is due at once', test.dpd_link_due('CC-DPD3'));
select test.ok('the job does not try again', not test.dpd_due('CC-DPD3'));
insert into pd select 'l', public.server_deposit_link_payreq((test.dpd_b('CC-DPD3')).id, encode(sha256('pdlinkabcdefghijklmnopqrstuvwxyz'::bytea), 'hex'));
select test.ok('the link texted to the renter', (public.server_deposit_link_send((select (v ->> 'id')::uuid from pd where k = 'l'), 'https://carmacars.ca/pay/pdlinkabcdefghijklmnopqrstuvwxyz') ->> 'ok')::boolean);
select public.server_payreq_attach((select (v ->> 'id')::uuid from pd where k = 'l'), 'pi_dpd_3');
select public.server_payreq_settle((select (v ->> 'id')::uuid from pd where k = 'l'), jsonb_build_object('id', 'pi_dpd_3', 'status', 'requires_capture', 'amount', 50000,
  'customer_id', 'cus_dpd_r', 'method_id', 'pm_dpd_r', 'card', '{"brand": "visa", "last4": "4242", "funding": "credit", "fingerprint": "fp_dpd_r", "exp_month": 12, "exp_year": 2030}'::jsonb));
select test.ok('placed by the renter: the task closes', not exists (select 1 from tasks t where t.booking_id = (test.dpd_b('CC-DPD3')).id and t.task_type = 'deposit_not_taken' and t.status in ('open', 'in_progress', 'waiting')));

-- ================================================================ the link by email when there is no mobile
select test.mk_vehicle('DPDF', 'dpd_o');
select test.mk_booking('CC-DPD6', 'DPDF', 'dpd_n', test.dpd_at(10), test.dpd_at(60), 'confirmed');
update bookings set deposit_pay_method = 'card', deposit_cents = 50000 where booking_number = 'CC-DPD6';
insert into pd select 'e', public.server_deposit_link_payreq((test.dpd_b('CC-DPD6')).id, encode(sha256('pdemailabcdefghijklmnopqrstuvwxyz'::bytea), 'hex'));
select test.eq('no mobile: the link goes by email', public.server_deposit_link_send((select (v ->> 'id')::uuid from pd where k = 'e'), 'https://carmacars.ca/pay/pdemailabcdefghijklmnopqrstuvwxyz') ->> 'by', 'email');
select test.ok('the booking''s message carries the link; no task', exists (select 1 from messages m where m.booking_id = (test.dpd_b('CC-DPD6')).id and m.body like '%/pay/pdemailabcdefghijklmnopqrstuvwxyz%')
  and not exists (select 1 from tasks t where t.booking_id = (test.dpd_b('CC-DPD6')).id and t.title like 'Deposit link not sent%'));

-- ================================================================ cash, and the setting back to the handover
update bookings set deposit_pay_method = 'cash' where booking_number = 'CC-DPD5';
select test.dpd_soon('CC-DPD5');
select test.ok('a cash deposit: never placed on a card', not test.dpd_due('CC-DPD5') and app.deposit_auto_state((test.dpd_b('CC-DPD5')).id) is null);
update bookings set deposit_pay_method = 'card' where booking_number = 'CC-DPD5';
select test.ok('back to a card: due', test.dpd_due('CC-DPD5'));
update program_settings set deposit_timing = 'handover' where id = (app.settings()).id;
select test.ok('At handover (the old way): nothing placed by the job', not test.dpd_due('CC-DPD5'));
select test.ok('and the link before pickup goes as before', test.dpd_link_due('CC-DPD5'));
select test.eq('the Money tab says off', app.deposit_auto_state((test.dpd_b('CC-DPD5')).id) ->> 'status', 'off');
update program_settings set deposit_timing = 'pickup_day', deposit_auto_hour = 8 where id = (app.settings()).id;
