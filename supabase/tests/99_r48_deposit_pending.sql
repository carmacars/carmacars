-- 99: "Picked up, deposit pending" (migration 2970, docs/changes/2026-11-14-r48-deposit-pending.md). Uses the helpers of
-- 06 (test.rq_new, test.b), 09 (test.op_confirm, test.op_deposit_payment) and 82 (test.ho_local). Fixtures start with "dp48".
select test.suite('99 r48 deposit pending');
select set_config('app.paper_fixture', 'on', false);
update program_settings set deposit_auto_hour = 0, deposit_pending_retry = true, phone_enabled = true where id = (app.settings()).id;

select test.mk_user('dp48_admin', 'admin');
select test.mk_user('dp48_fleet', 'va', 'fleet');
select test.mk_user('dp48_fin', 'va', 'finance');
select test.mk_owner('dp48_o');
select test.mk_vehicle('DP48A', 'dp48_o');
select test.mk_vehicle('DP48B', 'dp48_o');
select test.mk_renter('dp48_r');
select test.mk_renter('dp48_q');
create function test.dp48_do(p_user text, p_name text, p jsonb) returns jsonb language sql as $$
  select public.door(test.id(p_user), null, 'ops_do', p_name, p) $$;
create function test.dp48_tok() returns text language sql as $$ select md5(random()::text) || md5(random()::text) $$;
create function test.dp48_sha(p text) returns text language sql as $$ select encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;

select test.rq_new('dp48A', 'dp48_r', 'DP48A', test.ho_local(interval '3 hours'), test.ho_local(interval '3 days 3 hours'));
select test.op_confirm('dp48A', 'dp48_r');
update bookings set deposit_cents = 50000 where id = test.b('dp48A');

-- ---------------------------------------------------------------- 1. the pickup with the deposit owed
select test.throws('as before: no deposit, no pickup',
  format($$select test.dp48_do('dp48_admin', 'handover_record_now', jsonb_build_object('booking', %L, 'kind', 'pickup', 'reason', 'Phone died at the lot', 'signature_override_reason', 'Signed on paper'))$$, test.b('dp48A')), 'deposit is not taken');
select test.throws('the reason is asked (5 characters or more)',
  format($$select test.dp48_do('dp48_admin', 'handover_record_now', jsonb_build_object('booking', %L, 'kind', 'pickup', 'reason', 'Phone died at the lot', 'deposit_pending', true, 'deposit_pending_reason', 'no'))$$, test.b('dp48A')), 'at least 5 characters');
select test.throws('Finance does not let a car go',
  format($$select test.dp48_do('dp48_fin', 'deposit_pending_allow', jsonb_build_object('booking', %L, 'reason', 'Card declined at the lot'))$$, test.b('dp48A')), 'deposit owed');
select test.ok('a refused pickup leaves no row', not exists (select 1 from deposit_pendings where booking_id = test.b('dp48A')));
create temp table dp48_p as select test.dp48_do('dp48_admin', 'handover_record_now', jsonb_build_object('booking', test.b('dp48A'), 'kind', 'pickup',
  'reason', 'Phone died at the lot', 'signature_override_reason', 'Signed on paper', 'deposit_pending_reason', 'Card declined at the lot, renter pays tonight')) r;
select test.eq('on rent with the deposit owed, logged with the reason',
  (select status::text from bookings where id = test.b('dp48A'))
  || '/' || (select amount_cents || ':' || reason || ':' || (cleared_at is null) from deposit_pendings where booking_id = test.b('dp48A'))
  || '/' || (select count(*) from booking_events where booking_id = test.b('dp48A') and note like 'Car released with the deposit owed%Card declined at the lot%'),
  'on_rent/50000:Card declined at the lot, renter pays tonight:true/1');
select test.eq('the chip read: pending, the amount, not overdue',
  (select (s ->> 'pending') || ':' || (s ->> 'amount_cents') || ':' || (s ->> 'overdue') from public.server_deposit_pending_state(test.b('dp48A')) s), 'true:50000:false');
select test.eq('the caller pop-up says pending', app.caller_deposit(test.b('dp48A')) ->> 'state', 'pending');
select test.eq('the renter sees what is owed; another person does not',
  (public.server_my_deposit_pending(test.b('dp48A'), test.id('dp48_r')) ->> 'amount_cents') || '/' || (public.server_my_deposit_pending(test.b('dp48A'), test.id('dp48_q')) ->> 'pending'),
  '50000/false');
select test.eq('a second time keeps the first reason', test.dp48_do('dp48_fleet', 'deposit_pending_allow', jsonb_build_object('booking', test.b('dp48A'), 'reason', 'Again please')) ->> 'reason',
  'Card declined at the lot, renter pays tonight');

-- ---------------------------------------------------------------- 2. each morning: no card, so the link
select test.ok('the deposit job is due', (app.server_jobs_due() ->> 'deposits')::boolean);
select test.ok('due for the morning try', exists (select 1 from jsonb_array_elements(public.server_deposit_pending_due()) x where x ->> 'booking_id' = test.b('dp48A')::text));
select test.eq('no usable saved card: the link is next', public.server_deposit_pending_begin(test.b('dp48A'), test.dp48_tok()) ->> 'link', 'true');
select test.eq('one try a day', public.server_deposit_pending_begin(test.b('dp48A'), test.dp48_tok()) ->> 'reason', 'not due');
select test.ok('the link of the day is due', exists (select 1 from jsonb_array_elements(public.server_deposit_pending_links_due()) x where x ->> 'booking_id' = test.b('dp48A')::text));
create temp table dp48_t as select test.dp48_tok() || 'abcdefgh' as tok;
create temp table dp48_l as select public.server_deposit_pending_link(test.b('dp48A'), test.dp48_sha((select tok from dp48_t))) r;
select test.eq('the link request: open, the deposit, by text', (select q.status || ':' || q.amount_cents || ':' || q.channel from payment_requests q where q.id = (select (r ->> 'id')::uuid from dp48_l)), 'open:50000:text');
select test.eq('one link a day', public.server_deposit_pending_link(test.b('dp48A'), test.dp48_sha(test.dp48_tok())) ->> 'reason', 'sent today');
select test.eq('sent to the renter', public.server_deposit_link_send((select (r ->> 'id')::uuid from dp48_l), 'https://carmacars.test/pay/' || (select tok from dp48_t)) ->> 'ok', 'true');
select test.ok('by text, urgent, with the words for a car already out',
  exists (select 1 from phone_outbox o where o.booking_id = test.b('dp48A') and o.sms_kind = 'deposit_link' and o.body like '%is still owed%' and o.urgent));
update program_settings set deposit_pending_retry = false where id = (app.settings()).id;
update deposit_pendings set last_try_on = null, last_link_on = null where booking_id = test.b('dp48A');
select test.ok('the setting off: no try, no link', jsonb_array_length(public.server_deposit_pending_due()) = 0 and jsonb_array_length(public.server_deposit_pending_links_due()) = 0);
update program_settings set deposit_pending_retry = true where id = (app.settings()).id;

-- ---------------------------------------------------------------- 3. after 48 hours: an Admin To do and an alert
update deposit_pendings set started_at = now() - interval '49 hours', last_try_on = app.today(), last_link_on = app.today() where booking_id = test.b('dp48A');
select public.server_deposit_pending_due();
select public.server_deposit_pending_due();
select test.eq('one Admin To do, urgent, on the booking',
  (select count(*) || ':' || min(queue) || ':' || min(priority) from tasks where booking_id = test.b('dp48A') and task_type = 'deposit_pending_overdue' and status = 'open'), '1:admin:urgent');
select test.ok('the alert opens the Money tab', exists (select 1 from app_events e where e.code like 'staff_alert_%' and e.payload ->> 'rule' = 'deposit_pending_overdue'
  and e.payload ->> 'path_admin' like '/admin/bookings/%?tab=money'));
select test.eq('the chip read: overdue', public.server_deposit_pending_state(test.b('dp48A')) ->> 'overdue', 'true');

-- ---------------------------------------------------------------- 4. taken: the row ends and the To do closes
select test.lives('a deposit taken later is recorded on the car already out', format($$select app.record_deposit_taken(%L, test.op_deposit_payment('dp48A'), test.id('dp48_fin'))$$, test.b('dp48A')));
select test.eq('taken: ended, the To do done, the chip read is clear',
  (select cleared_why from deposit_pendings where booking_id = test.b('dp48A')) || '/' || (select status from tasks where booking_id = test.b('dp48A') and task_type = 'deposit_pending_overdue')
  || '/' || (public.server_deposit_pending_state(test.b('dp48A')) ->> 'pending'), 'taken/done/false');

-- ---------------------------------------------------------------- 5. the connector's flag, the saved card in the morning, the return
select test.rq_new('dp48B', 'dp48_q', 'DP48B', test.ho_local(interval '3 hours'), test.ho_local(interval '3 days 3 hours'));
select test.op_confirm('dp48B', 'dp48_q');
update bookings set deposit_cents = 40000 where id = test.b('dp48B');
select test.throws('the flag alone, without any reason, is refused',
  format($$select test.dp48_do('dp48_admin', 'handover_record_now', jsonb_build_object('booking', %L, 'kind', 'pickup', 'deposit_pending', true, 'signature_override_reason', 'Signed on paper'))$$, test.b('dp48B')), 'at least 5 characters');
select test.lives('the connector: deposit_pending true with its reason',
  format($$select test.dp48_do('dp48_admin', 'handover_record_now', jsonb_build_object('booking', %L, 'kind', 'pickup', 'reason', 'Recorded from the connector', 'deposit_pending', true,
    'deposit_pending_reason', 'Renter will pay the hold tomorrow', 'signature_override_reason', 'Signed on paper'))$$, test.b('dp48B')));
select test.eq('on rent, pending', (select status::text from bookings where id = test.b('dp48B')) || '/' || app.deposit_pending_ok(test.b('dp48B'))::text, 'on_rent/true');
insert into payment_method_secrets (payment_method_id, processor, processor_customer_id, processor_method_id, fingerprint)
values (test.id('card:dp48_q'), 'stripe', 'cus_dp48_q', 'pm_dp48_q', 'fp_dp48_q');
set session_replication_role = replica;
update bookings set coverage_option = 1 where id = test.b('dp48B');
set session_replication_role = origin;
create temp table dp48_b as select public.server_deposit_pending_begin(test.b('dp48B'), test.dp48_tok()) r;
select test.eq('the morning try: the saved card', (select (r ->> 'ok') || ':' || (r ->> 'customer_id') || ':' || (r ->> 'method_id') from dp48_b), 'true:cus_dp48_q:pm_dp48_q');
select test.ok('no link while the try is under way', not exists (select 1 from jsonb_array_elements(public.server_deposit_pending_links_due()) x where x ->> 'booking_id' = test.b('dp48B')::text));
select public.server_payreq_attach((select (r ->> 'id')::uuid from dp48_b), 'pi_dp48_b');
select test.eq('the hold goes through on a car already out', public.server_payreq_settle((select (r ->> 'id')::uuid from dp48_b), jsonb_build_object('id', 'pi_dp48_b', 'status', 'requires_capture',
  'amount', (select (r ->> 'amount_cents')::bigint from dp48_b), 'amount_capturable', (select (r ->> 'amount_cents')::bigint from dp48_b), 'customer_id', 'cus_dp48_q', 'method_id', 'pm_dp48_q',
  'card', '{"brand": "visa", "last4": "4242", "funding": "credit", "fingerprint": "fp_dp48_q", "exp_month": 12, "exp_year": 2030}'::jsonb)) ->> 'ok', 'true');
select test.eq('held, and the row ended by itself', (select d.status from deposits d where d.booking_id = test.b('dp48B') order by d.created_at desc limit 1)
  || '/' || (select cleared_why from deposit_pendings where booking_id = test.b('dp48B')), 'held/taken');

-- a failed morning try: recorded, the link is due
select test.rq_new('dp48C', 'dp48_q', 'DP48A', test.ho_local(interval '10 days'), test.ho_local(interval '12 days'));
select test.op_confirm('dp48C', 'dp48_q');
update bookings set deposit_cents = 30000 where id = test.b('dp48C');
set session_replication_role = replica;
update bookings set coverage_option = 1 where id = test.b('dp48C');
set session_replication_role = origin;
select test.lives('Fleet lets it go first (the full check-in follows)',
  format($$select test.dp48_do('dp48_fleet', 'deposit_pending_allow', jsonb_build_object('booking', %L, 'reason', 'Hold declined, renter calls the bank'))$$, test.b('dp48C')));
select test.ok('the override list no longer names the deposit', not exists (select 1 from jsonb_array_elements(app.handover_blockers_pre0930(test.id('dp48_fleet'), test.b('dp48C'), 'pickup', '{}'::jsonb)) x where x ->> 'code' = 'deposit'));
set session_replication_role = replica;
update bookings set status = 'on_rent', handed_over_at = now() where id = test.b('dp48C');
set session_replication_role = origin;
create temp table dp48_c as select public.server_deposit_pending_begin(test.b('dp48C'), test.dp48_tok()) r;
select public.server_deposit_pending_failed((select (r ->> 'id')::uuid from dp48_c), 'Your card was declined.');
select test.eq('a declined try: recorded, the link of the day due',
  (select last_try_result from deposit_pendings where booking_id = test.b('dp48C'))
  || '/' || exists (select 1 from jsonb_array_elements(public.server_deposit_pending_links_due()) x where x ->> 'booking_id' = test.b('dp48C')::text)::text,
  'Your card was declined./true');
set session_replication_role = replica;
update bookings set status = 'returned', checked_in_at = now() where id = test.b('dp48C');
set session_replication_role = origin;
select app.deposit_pending_end(test.b('dp48C'), 'returned');
select test.eq('the car back: no more tries', (select cleared_why from deposit_pendings where booking_id = test.b('dp48C')) || '/' ||
  (jsonb_array_length(public.server_deposit_pending_links_due()) = 0)::text, 'returned/true');
