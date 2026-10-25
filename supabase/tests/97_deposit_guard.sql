-- 97: the deposit guard (migration 0155, docs/changes/2026-10-25-deposit-guard.md): nothing releases a deposit by itself;
-- the toll window and what blocks a release; the charges after the return taken from the deposit without releasing the
-- rest; a card hold captured before it lapses, a lapsed hold charged to the saved card; the money steps marked for the
-- server and recorded; the balance after the deposit (card on file, pay link, Finance task); Keep the whole deposit
-- (damage) and the damage charge; the hold actions guarded. Fixtures start with "dgx" and "DG-".
select test.suite('97 deposit guard');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_user('dgx_admin', 'admin');
select test.mk_user('dgx_fin', 'va', 'finance');
select test.mk_user('dgx_cs', 'va', 'cs');
update staff_profiles set single_limit_cents = 500000 where user_id = test.id('dgx_fin');
select test.mk_owner('dgx_o');
select test.mk_vehicle('DGA', 'dgx_o'); select test.mk_vehicle('DGB', 'dgx_o'); select test.mk_vehicle('DGC', 'dgx_o'); select test.mk_vehicle('DGD', 'dgx_o');
select test.mk_vehicle('DGE', 'dgx_o'); select test.mk_vehicle('DGF', 'dgx_o'); select test.mk_vehicle('DGG', 'dgx_o'); select test.mk_vehicle('DGH', 'dgx_o');
select test.mk_vehicle('DGI', 'dgx_o'); select test.mk_vehicle('DGJ', 'dgx_o'); select test.mk_vehicle('DGK', 'dgx_o'); select test.mk_vehicle('DGL', 'dgx_o');
select test.mk_renter('dgx_r');      -- a saved card at Stripe (below)
select test.mk_renter('dgx_nocard'); -- no card the server can charge
insert into payment_method_secrets (payment_method_id, processor, processor_customer_id, processor_method_id) values (test.id('card:dgx_r'), 'stripe', 'cus_dg', 'pm_dg');

-- a Toronto wall-clock time p_days from today (negative: in the past)
create function test.dgl(p_days numeric, p_hour text default '10:00') returns text language sql stable as $$
  select to_char((now() at time zone 'America/Toronto')::date + floor(p_days)::int, 'YYYY-MM-DD') || ' ' || p_hour $$;
create function test.dgb(p text) returns uuid language sql stable as $$ select test.id('booking:' || p) $$;
create function test.dgd(p text) returns deposits language sql stable as $$ select * from deposits where booking_id = test.dgb(p) $$;
-- a card hold on the booking (Stripe intent pi_<booking>), lapsing at p_expires
create function test.dg_hold(p text, p_expires timestamptz) returns uuid language plpgsql as $$
declare v_pay uuid := test.id('hold:' || p);
begin
  insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
  select v_pay, b.id, b.renter_id, 'deposit', 'hold', 'card', 100000, 'authorized', now() - interval '5 days' from bookings b where b.id = test.dgb(p);
  insert into payment_processor_details (payment_id, processor, processor_payment_id) values (v_pay, 'stripe', 'pi_' || p);
  insert into deposits (booking_id, amount_cents, method, status, hold_payment_id, taken_at, hold_expires_at)
  values (test.dgb(p), 100000, 'card_hold', 'held', v_pay, now() - interval '5 days', p_expires);
  return v_pay;
end $$;
-- the Check-in statement, with a line on it when an amount is given
create function test.dg_statement(p text, p_type text default null, p_amount bigint default 0) returns uuid language plpgsql as $$
declare v_st uuid := gen_random_uuid(); f fee_types;
begin
  insert into booking_statements (id, booking_id, statement_number, kind, issued_at) values (v_st, test.dgb(p), 'RS-' || p, 'check_in', now() - interval '1 hour');
  if p_type is not null then
    select * into f from fee_types where code = p_type;
    insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents, revenue_class, stage, statement_id, supporting_refs)
    values (test.dgb(p), f.code, f.label, 1, p_amount, p_amount, f.hst_applies, case when f.hst_applies then public.calc_hst(p_amount) else 0 end, f.revenue_class, 'check_in', v_st, '{"note": "test"}');
  end if;
  return v_st;
end $$;
create function test.dg_settle(p_user text, p text, p_plan jsonb default '{}') returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', 'ops_do', 'deposit_settle', jsonb_build_object('booking', test.dgb(p)) || p_plan) $$;
create table test.dg (k text primary key, v jsonb);
create function test.dgv(p text) returns jsonb language sql stable as $$ select v from test.dg where k = p $$;

-- ================================================================ 1. settings
select test.eq('settings: a 7-day toll window, the 30-day hold-back limit kept, holds captured 36 hours before they lapse, automatic capture and collection on',
  (select deposit_toll_window_days || '/' || deposit_holdback_days || '/' || deposit_hold_capture_hours || '/' || deposit_auto_capture || '/' || balance_auto_collect from program_settings limit 1),
  '7/30/36/true/true');
select test.eq('the cron gate asks about deposits', (public.server_jobs_due() ? 'deposits'), true);

-- ================================================================ 2. inside the toll window
-- DG-1: returned yesterday on a card hold, fuel on the Check-in statement
select test.mk_booking('DG-1', 'DGA', 'dgx_r', test.dgl(-4), test.dgl(-1), 'returned', null, 'standard', null, null, test.dgl(-1));
select test.dg_hold('DG-1', now() + interval '2 days');
select test.dg_statement('DG-1', 'fuel', 5000);
select test.eq('the Settle screen: inside the window, the whole rest of the deposit is the suggested hold-back',
  (select (g ->> 'within_window') || '/' || (g ->> 'remaining_cents') || '/' || (g ->> 'suggested_hold_back_cents') || '/' || (g ->> 'blocked')
     from (select app.deposit_preview(test.id('dgx_fin'), test.dgb('DG-1')) -> 'guard' as g) x), 'true/94350/94350/false');
select test.throws('inside the window a release needs a hold-back or "Release now anyway"', $$select test.dg_settle('dgx_fin', 'DG-1', '{"hold_back_cents": 0}')$$, 'Tolls and tickets can take up to 7 days');
insert into test.dg select 's1', test.dg_settle('dgx_fin', 'DG-1', jsonb_build_object('hold_back_cents', 94350, 'hold_back_reason', 'Tolls and tickets may still come in', 'hold_back_until', (now() at time zone 'America/Toronto')::date + 6));
select test.eq('held back: the fuel taken from the deposit, the rest held, nothing released, the booking stays open',
  (select applied_cents || '/' || held_back_cents || '/' || released_cents || '/' || status from test.dgd('DG-1')) || ' ' || (select status::text from bookings where id = test.dgb('DG-1')),
  '5650/94350/0/captured returned');
select test.eq('the hold is captured for all of it (the charges and the hold-back), marked for the server',
  (select string_agg(kind || ':' || amount_cents || ':' || status || ':' || server_action, ',') from payments where booking_id = test.dgb('DG-1') and server_action is not null), 'capture:100000:pending:capture_deposit');
insert into test.dg select 'm1', public.server_money_action((select id from payments where booking_id = test.dgb('DG-1') and server_action = 'capture_deposit'));
select test.eq('the server is given the hold''s Stripe intent, the amount and a key of its own', (test.dgv('m1') ->> 'intent_id') || '/' || (test.dgv('m1') ->> 'amount_cents') || '/' || (test.dgv('m1') ->> 'idempotency_key' like 'money:%'), 'pi_DG-1/100000/true');
select public.server_money_action_finish((test.dgv('m1') ->> 'payment_id')::uuid, '{"ok": true, "intent_id": "pi_DG-1", "charge_id": "ch_dg1"}');
select test.eq('captured: the capture and the hold succeed', (select string_agg(kind || ':' || status, ',' order by kind) from payments where booking_id = test.dgb('DG-1') and purpose = 'deposit'), 'capture:succeeded,hold:succeeded');
select test.eq('recorded twice: the same answer', public.server_money_action_finish((test.dgv('m1') ->> 'payment_id')::uuid, '{"ok": true}') ->> 'repeat', 'true');

-- DG-2: "Release now anyway" inside the window is the person's choice, recorded
select test.mk_booking('DG-2', 'DGB', 'dgx_r', test.dgl(-4), test.dgl(-2), 'returned', null, 'standard', null, null, test.dgl(-2));
select test.dg_hold('DG-2', now() + interval '2 days');
select test.dg_statement('DG-2');
insert into test.dg select 's2', test.dg_settle('dgx_admin', 'DG-2', '{"hold_back_cents": 0, "release_now": true}');
select test.eq('released now: recorded as a release inside the window; the hold release is marked for the server',
  (select kind || '/' || amount_cents from deposit_overrides where booking_id = test.dgb('DG-2')) || ' ' ||
  (select string_agg(kind || ':' || server_action, ',') from payments where booking_id = test.dgb('DG-2') and server_action is not null), 'release_in_window/100000 release:release_hold');
select test.eq('a release with no capture before it is sent to Stripe (not skipped)', public.server_money_action((select id from payments where booking_id = test.dgb('DG-2') and server_action = 'release_hold')) ->> 'skip_processor', 'false');

-- ================================================================ 3. charges after the return never release the rest
-- DG-3: returned 2 days ago, not settled, the hold untouched; a toll charged now (0021's charge_after_rental)
select test.mk_booking('DG-3', 'DGC', 'dgx_r', test.dgl(-5), test.dgl(-2), 'returned', null, 'standard', null, null, test.dgl(-2));
select test.dg_hold('DG-3', now() + interval '1 day');
select test.dg_statement('DG-3');
select test.eq('charge_after_rental settles in "apply only" (0155)', position('apply_only' in pg_get_functiondef('app.charge_after_rental(uuid,uuid,timestamptz)'::regprocedure)) > 0, true);
insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents, revenue_class, stage, supporting_refs)
select test.dgb('DG-3'), 'toll_amount', '407 ETR trip', 1, 1250, 1250, false, 0, 'pass_through', 'after_return', '{"toll": "test"}';
insert into test.dg select 'c3', app.charge_after_rental(test.dgb('DG-3'), test.id('dgx_fin'));
select test.eq('the toll comes from the deposit; the rest stays held (it was released before 0155); nothing released',
  (select applied_cents || '/' || held_back_cents || '/' || released_cents || '/' || held_back_reason from test.dgd('DG-3')),
  '1250/98750/0/Kept until the deposit is settled: tolls, tickets and damage can still come in');
select test.eq('no release or refund was made', (select count(*) from payments where booking_id = test.dgb('DG-3') and kind in ('release', 'refund')), 0::bigint);
select test.eq('the booking is not closed', (select status::text from bookings where id = test.dgb('DG-3')), 'returned');

-- ================================================================ 4. what blocks a release
-- DG-4: returned 10 days ago (outside the window), the deposit collected; an incident open, a toll not matched, a dispute
select test.mk_booking('DG-4', 'DGD', 'dgx_r', test.dgl(-14), test.dgl(-10), 'returned', null, 'standard', null, null, test.dgl(-10));
select test.dg_hold('DG-4', now() - interval '1 day');
update deposits set status = 'captured', captured_cents = 100000 where booking_id = test.dgb('DG-4');
update payments set status = 'succeeded' where id = test.id('hold:DG-4');
select test.dg_statement('DG-4');
select test.eq('nothing open: no blockers, outside the window', (select (g ->> 'blocked') || '/' || (g ->> 'within_window') from (select app.deposit_guard_facts(test.dgb('DG-4')) g) x), 'false/false');
insert into incidents (kind, vehicle_id, booking_id, description, status) values ('damage_at_return', test.id('vehicle:DGD'), test.dgb('DG-4'), 'Bumper', 'open');
insert into toll_tickets (kind, plate, vehicle_id, occurred_at, amount_cents, status, matched_to)
select 'toll_invoice', 'UNKNOWN1', test.id('vehicle:DGD'), b.pickup_at + interval '1 day', 900, 'logged', 'unmatched' from bookings b where b.id = test.dgb('DG-4');
insert into disputes (payment_id, booking_id, amount_cents, status) values (test.id('hold:DG-4'), test.dgb('DG-4'), 20000, 'open');
insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents, revenue_class, stage, supporting_refs)
select test.dgb('DG-4'), 'cleaning', 'Cleaning', 1, 7500, 7500, true, public.calc_hst(7500), 'company_only', 'after_return', '{"note": "x"}';
select test.eq('blockers in plain words: the incident, the toll, the dispute, the charges not on a statement',
  (select string_agg(x ->> 'kind', ',' order by x ->> 'kind') from jsonb_array_elements(app.deposit_blockers(test.dgb('DG-4'))) x), 'charges,dispute,incident,toll');
select test.ok('no raw codes in the words', not exists (select 1 from jsonb_array_elements(app.deposit_blockers(test.dgb('DG-4'))) x where x ->> 'label' ~ '_'));
select test.throws('Finance cannot release any of it while something is open', $$select test.dg_settle('dgx_fin', 'DG-4', '{"hold_back_cents": 0}')$$, 'whole deposit stays held');
select test.throws('an Admin needs the reason', $$select test.dg_settle('dgx_admin', 'DG-4', '{"hold_back_cents": 0}')$$, 'whole deposit stays held');
select test.lives('keeping all of it back is allowed (nothing released)', $$select test.dg_settle('dgx_fin', 'DG-4', '{"hold_back_cents": 100000, "hold_back_reason": "Bumper damage, toll to match"}')$$);
select test.eq('kept: all held back, nothing released', (select held_back_cents || '/' || released_cents from test.dgd('DG-4')), '100000/0');
delete from booking_line_items where booking_id = test.dgb('DG-4') and charge_type = 'cleaning';
insert into test.dg select 's4', test.dg_settle('dgx_admin', 'DG-4', '{"hold_back_cents": 0, "override_reason": "Renter paid the bumper directly to the shop"}');
select test.eq('an Admin with the reason releases it: recorded with the blockers; the refund is marked for the server',
  (select kind || '/' || amount_cents || '/' || jsonb_array_length(blockers) from deposit_overrides where booking_id = test.dgb('DG-4')) || ' ' ||
  (select string_agg(kind || ':' || server_action || ':' || amount_cents, ',') from payments where booking_id = test.dgb('DG-4') and server_action is not null),
  'release_past_blockers/100000/3 refund:refund_deposit:100000');
select test.throws('an override is kept as recorded', $$update deposit_overrides set reason = 'changed reason here' where booking_id = test.dgb('DG-4')$$, 'kept as it was recorded');
insert into test.dg select 'm4', public.server_money_action((select id from payments where booking_id = test.dgb('DG-4') and server_action = 'refund_deposit'));
select test.eq('the refund goes against the deposit''s own Stripe payment', test.dgv('m4') ->> 'intent_id', 'pi_DG-4');
-- Stripe's refund webhook arriving first keeps it on the runner's payment (never "refunded outside the site")
select public.server_stripe_refund_event(jsonb_build_object('refund_id', 're_dg4', 'status', 'succeeded', 'amount_cents', 100000, 'intent_id', 'pi_DG-4', 'site_refund_id', test.dgv('m4') ->> 'payment_id'));
select test.eq('the webhook settles the runner''s refund, no "outside" task', (select status from payments where id = (test.dgv('m4') ->> 'payment_id')::uuid) || '/' ||
  (select count(*) from tasks where booking_id = test.dgb('DG-4') and task_type = 'stripe_refund_outside'), 'succeeded/0');

-- ================================================================ 5. the balance after the deposit
-- DG-5: a cash deposit of $300, no card the server can charge, $500 cleaning: the settlement no longer fails
select test.mk_booking('DG-5', 'DGE', 'dgx_nocard', test.dgl(-14), test.dgl(-10), 'returned', null, 'standard', null, null, test.dgl(-10));
update bookings set card_on_file_id = null, deposit_pay_method = 'cash' where id = test.dgb('DG-5');
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
select test.id('dep:DG-5'), id, renter_id, 'deposit', 'charge', 'cash', 30000, 'succeeded', now() from bookings where id = test.dgb('DG-5');
insert into deposits (booking_id, amount_cents, method, paid_method, status, hold_payment_id, taken_at, captured_cents) values (test.dgb('DG-5'), 30000, 'offline', 'cash', 'captured', test.id('dep:DG-5'), now(), 30000);
select test.dg_statement('DG-5', 'cleaning', 50000);
insert into test.dg select 's5', test.dg_settle('dgx_fin', 'DG-5');
select test.eq('no card: the deposit pays $300, the rest ($265) stays owed (it failed before 0155)',
  (test.dgv('s5') ->> 'applied_cents') || '/' || (test.dgv('s5') ->> 'charged_to_card_cents') || '/' || app.booking_balance_open(test.dgb('DG-5')), '30000/0/26500');
insert into test.dg select 'n5', public.server_balance_next(test.dgb('DG-5'));
select test.eq('the next step: a pay link to the renter (no card to charge)', (test.dgv('n5') ->> 'action') || '/' || (test.dgv('n5') ->> 'open_cents'), 'pay_link/26500');
insert into test.dg select 'q5', public.server_balance_payreq(test.dgb('DG-5'), repeat('a', 64), 26500);
select test.eq('the pay link: a later charge, from the system (no staff member), for 7 days',
  (select kind || '/' || covers || '/' || amount_cents || '/' || (created_by is null) || '/' || (expires_at > now() + interval '6 days') from payment_requests where id = (test.dgv('q5') ->> 'id')::uuid), 'charge/later/26500/true/true');
select test.throws('the link must be the request''s', format($$select public.server_balance_payreq_send(%L, 'https://carmacars.ca/pay/AAAAAAAAAAAAAAAAAAAAAAAAAAAA')$$, test.dgv('q5') ->> 'id'), 'not this request');
-- the token whose SHA-256 is the request's: a 64-char hex hash of a known token
update payment_requests set token_sha256 = encode(sha256(convert_to('dgtoken-0123456789-abcdefghij', 'UTF8')), 'hex') where id = (test.dgv('q5') ->> 'id')::uuid;
insert into test.dg select 'p5', public.server_balance_payreq_send((test.dgv('q5') ->> 'id')::uuid, 'https://carmacars.ca/pay/dgtoken-0123456789-abcdefghij');
select test.eq('sent by email (the booking''s message) and by text', (test.dgv('p5') ->> 'email') || '/' || (select count(*) from messages where booking_id = test.dgb('DG-5') and body like '%/pay/dgtoken%'), 'true/1');
select test.eq('a Finance task: what is owed and that a pay link went out', (select count(*) || '/' || bool_and(title like '%$265.00 still owed%') || '/' || bool_and(detail like '%no card on file%pay link%')
  from tasks where booking_id = test.dgb('DG-5') and task_type = 'collect_balance' and status = 'open'), '1/true/true');
select test.eq('with a pay link waiting, the next step is the task (not a second link)', public.server_balance_next(test.dgb('DG-5')) ->> 'action', 'task');
-- the renter pays the link
select public.server_payreq_attach((test.dgv('q5') ->> 'id')::uuid, 'pi_dg5');
select public.server_payreq_settle((test.dgv('q5') ->> 'id')::uuid, jsonb_build_object('id', 'pi_dg5', 'status', 'succeeded', 'amount', 26500, 'charge_id', 'ch_dg5'));
select test.eq('paid by the link: the cleaning line is paid (0129 left it open), nothing owed', (select count(*) from booking_line_items where booking_id = test.dgb('DG-5') and charge_type = 'cleaning' and payment_id is not null) || '/' || app.booking_balance_open(test.dgb('DG-5')), '1/0');
select test.eq('paid: the next step is none', public.server_balance_next(test.dgb('DG-5')) ->> 'action', 'none');
select test.eq('paid: the Finance task is done', (select status from tasks where booking_id = test.dgb('DG-5') and task_type = 'collect_balance'), 'done');

-- DG-6: a saved card; $1,800 damage-level charges on a $1,000 deposit: the card is charged the rest; declined: a pay link
select test.mk_booking('DG-6', 'DGF', 'dgx_r', test.dgl(-14), test.dgl(-10), 'returned', null, 'standard', null, null, test.dgl(-10));
select test.dg_hold('DG-6', now() + interval '1 day');
select test.dg_statement('DG-6', 'damage_at_cost', 180000);
insert into test.dg select 's6', test.dg_settle('dgx_admin', 'DG-6');
select test.eq('the deposit pays $1,000, the card is charged $800, both marked for the server',
  (select string_agg(kind || ':' || amount_cents || ':' || server_action, ',' order by kind) from payments where booking_id = test.dgb('DG-6') and server_action is not null), 'capture:100000:capture_deposit,charge:80000:charge_card');
insert into test.dg select 'm6', public.server_money_action((select id from payments where booking_id = test.dgb('DG-6') and server_action = 'charge_card'));
select test.eq('the card charge uses the saved card''s Stripe ids', (test.dgv('m6') ->> 'customer_id') || '/' || (test.dgv('m6') ->> 'method_id'), 'cus_dg/pm_dg');
insert into test.dg select 'f6', public.server_money_action_finish((test.dgv('m6') ->> 'payment_id')::uuid, '{"ok": false, "error": "Your card was declined."}');
select test.eq('declined: the charge failed with a retry date; the server is told to follow the balance', (select status || '/' || (next_retry_at is not null) from payments where id = (test.dgv('m6') ->> 'payment_id')::uuid) || '/' || (test.dgv('f6') #>> '{next,balance}'), 'failed/true/true');
-- a capture refused because the hold lapsed: what it was to pay is open again, Finance is told at once
insert into test.dg select 'm6c', public.server_money_action((select id from payments where booking_id = test.dgb('DG-6') and server_action = 'capture_deposit'));
select public.server_money_action_finish((test.dgv('m6c') ->> 'payment_id')::uuid, '{"ok": false, "intent_status": "canceled", "error": "This PaymentIntent could not be captured because it has a status of canceled."}');
select test.eq('the capture refused: the deposit is not taken, an urgent task, the whole $1,800 owed again',
  (select status from test.dgd('DG-6')) || '/' || (select priority from tasks where booking_id = test.dgb('DG-6') and task_type = 'deposit_capture_failed') || '/' || app.booking_balance_open(test.dgb('DG-6')), 'failed/urgent/180000');
select test.eq('the next step: the card was declined in the last 3 days, so a pay link for all of it', (select (x ->> 'action') || '/' || (x ->> 'open_cents') from (select public.server_balance_next(test.dgb('DG-6')) x) y), 'pay_link/180000');

-- DG-7: the balance charged to the saved card by the follow-up, accepted
select test.mk_booking('DG-7', 'DGG', 'dgx_r', test.dgl(-14), test.dgl(-10), 'returned', null, 'standard', null, null, test.dgl(-10));
update bookings set card_on_file_id = null where id = test.dgb('DG-7');
select test.dg_statement('DG-7', 'smoking', 25000);
select test.dg_settle('dgx_fin', 'DG-7');
insert into test.dg select 'n7', public.server_balance_next(test.dgb('DG-7'));
select test.eq('no deposit, a saved card at Stripe: the follow-up charges it', (test.dgv('n7') ->> 'action') || '/' || (test.dgv('n7') #>> '{payment,action}') || '/' || (test.dgv('n7') #>> '{payment,amount_cents}'), 'charge_card/balance_charge/28250');
select test.eq('while it runs, nothing else is started', public.server_balance_next(test.dgb('DG-7')) ->> 'action', 'wait');
select public.server_money_action_finish((test.dgv('n7') #>> '{payment,payment_id}')::uuid, '{"ok": true, "intent_id": "pi_dg7", "charge_id": "ch_dg7"}');
select test.eq('charged: the smoking line is paid, nothing owed, the statement paid', (select count(*) from booking_line_items where booking_id = test.dgb('DG-7') and charge_type = 'smoking' and payment_id = (test.dgv('n7') #>> '{payment,payment_id}')::uuid)
  || '/' || app.booking_balance_open(test.dgb('DG-7')) || '/' || (select paid_at is not null from booking_statements where booking_id = test.dgb('DG-7')), '1/0/true');

-- ================================================================ 6. card holds before they lapse
-- DG-8 on the road, the hold lapsing in 10 hours; DG-9 confirmed, its hold lapsing before the pickup
select test.mk_booking('DG-8', 'DGH', 'dgx_r', test.dgl(-4), test.dgl(2), 'on_rent');
select test.dg_hold('DG-8', now() + interval '10 hours');
select test.mk_booking('DG-9', 'DGI', 'dgx_r', test.dgl(3), test.dgl(5), 'confirmed');
select test.dg_hold('DG-9', now() + interval '20 hours');
create table test.dg_before as select (select count(*) from payments where kind in ('release', 'refund')) as n, (select coalesce(sum(released_cents), 0) from deposits) as rel;
select test.eq('the job is due (a hold to capture)', app.deposit_guard_due(), true);
insert into test.dg select 'sw', public.server_deposit_guard_sweep();
select test.eq('the sweep: the on-the-road hold to capture; not the one before its pickup', (select string_agg(x ->> 'booking_number', ',') from jsonb_array_elements(test.dgv('sw') -> 'captures') x where x ->> 'booking_number' like 'DG-%'), 'DG-8');
select test.eq('the hold lapsing before the pickup: a task to place a new one', (select count(*) from tasks where booking_id = test.dgb('DG-9') and task_type = 'renew_deposit_hold' and status = 'open'), 1::bigint);
select test.eq('the sweep releases nothing', (select count(*) from payments where kind in ('release', 'refund')) || '/' || (select coalesce(sum(released_cents), 0) from deposits),
  (select n || '/' || rel from test.dg_before));
insert into test.dg select 'b8', public.server_deposit_capture_begin((test.dgd('DG-8')).id);
select test.eq('the capture before the lapse: the whole hold, once', (test.dgv('b8') ->> 'action') || '/' || (test.dgv('b8') ->> 'amount_cents') || '/' || (test.dgv('b8') ->> 'intent_id')
  || '/' || (public.server_deposit_capture_begin((test.dgd('DG-8')).id) ->> 'payment_id' = test.dgv('b8') ->> 'payment_id'), 'protect_capture/100000/pi_DG-8/true');
select public.server_money_action_finish((test.dgv('b8') ->> 'payment_id')::uuid, '{"ok": true, "intent_id": "pi_DG-8"}');
select test.eq('captured, not released: the deposit is collected in full and the history says why',
  (select status || '/' || captured_cents || '/' || released_cents from test.dgd('DG-8')) || ' ' ||
  (select count(*) from deposit_events e where e.deposit_id = (test.dgd('DG-8')).id and e.kind = 'captured' and e.note like '%before the card hold lapsed%'), 'captured/100000/0 1');
-- returned, settled after the window: what is not owed is refunded from the capture
set session_replication_role = replica;  -- the check-in itself is not this test's: straight to returned
update bookings set status = 'returned', checked_in_at = now() - interval '9 days' where id = test.dgb('DG-8');
reset session_replication_role;
select test.dg_statement('DG-8', 'fuel', 4000);
insert into test.dg select 's8', test.dg_settle('dgx_admin', 'DG-8');
select test.eq('settled: the fuel kept, the rest refunded (the hold was captured)', (select string_agg(kind || ':' || amount_cents || ':' || server_action, ',') from payments where booking_id = test.dgb('DG-8') and kind = 'refund'), 'refund:95480:refund_deposit');

-- DG-10: the capture refused because the hold already lapsed: the deposit is charged to the saved card
select test.mk_booking('DG-10', 'DGJ', 'dgx_r', test.dgl(-4), test.dgl(2), 'on_rent');
select test.dg_hold('DG-10', now() + interval '5 hours');
insert into test.dg select 'b10', public.server_deposit_capture_begin((test.dgd('DG-10')).id);
insert into test.dg select 'f10', public.server_money_action_finish((test.dgv('b10') ->> 'payment_id')::uuid, '{"ok": false, "intent_status": "canceled", "error": "status of canceled"}');
select test.eq('lapsed: the hold is recorded as lost and the deposit charged to the saved card (a step for the server)',
  (select status from test.dgd('DG-10')) || '/' || (test.dgv('f10') #>> '{next,next,action}') || '/' || (test.dgv('f10') #>> '{next,next,amount_cents}'), 'failed/deposit_charge/100000');
select test.eq('Finance is told at once', (select priority || '/' || escalated from tasks where booking_id = test.dgb('DG-10') and task_type = 'deposit_hold_lapsed'), 'urgent/true');
select public.server_money_action_finish((test.dgv('f10') #>> '{next,next,payment_id}')::uuid, '{"ok": true, "intent_id": "pi_dg10c", "charge_id": "ch_dg10c"}');
select test.eq('charged: the deposit is a charged deposit, collected; the task is done',
  (select method || '/' || status || '/' || captured_cents from test.dgd('DG-10')) || '/' || (select status from tasks where booking_id = test.dgb('DG-10') and task_type = 'deposit_hold_lapsed'), 'charged/captured/100000/done');

-- DG-11: Stripe's webhook says a hold lapsed (no saved card: a task only)
select test.mk_booking('DG-11', 'DGK', 'dgx_nocard', test.dgl(-8), test.dgl(-1), 'returned', null, 'standard', null, null, test.dgl(-1));
select test.dg_hold('DG-11', now() - interval '1 hour');
insert into test.dg select 'w11', public.server_deposit_hold_lapsed('pi_DG-11');
select test.eq('the webhook: lapsed, no card, Finance told', (select status from test.dgd('DG-11')) || '/' || coalesce(test.dgv('w11') #>> '{next,payment_id}', 'none') || '/' ||
  (select count(*) from tasks where booking_id = test.dgb('DG-11') and task_type = 'deposit_hold_lapsed' and status = 'open'), 'failed/none/1');
select test.eq('an intent that is not a held deposit of ours is ignored', public.server_deposit_hold_lapsed('pi_nothing') ? 'ignored', true);

-- ================================================================ 7. the hold actions
select test.lives('before the pickup a hold may be released as before', format($$select app.door(%L, 'aal2', 'ops_do', 'hold_action_begin', jsonb_build_object('booking', 'DG-9', 'action', 'release'))$$, test.id('dgx_fin')));
select test.mk_booking('DG-13', 'DGB', 'dgx_r', test.dgl(-1), test.dgl(3), 'on_rent');
select test.dg_hold('DG-13', now() + interval '4 days');
select test.throws('on the road: Finance cannot release the hold', format($$select app.door(%L, 'aal2', 'ops_do', 'hold_action_begin', jsonb_build_object('booking', 'DG-13', 'action', 'release'))$$, test.id('dgx_fin')), 'stays held');
select test.throws('on the road: a part capture (it releases the rest) is refused too', format($$select app.door(%L, 'aal2', 'ops_do', 'hold_action_begin', jsonb_build_object('booking', 'DG-13', 'action', 'capture', 'amount_cents', 5000, 'reason', 'Fuel'))$$, test.id('dgx_fin')), 'stays held');
select test.lives('a capture of the whole hold is protection: allowed', format($$select app.door(%L, 'aal2', 'ops_do', 'hold_action_begin', jsonb_build_object('booking', 'DG-13', 'action', 'capture', 'reason', 'Keep it safe'))$$, test.id('dgx_fin')));
select test.lives('an Admin releases with the reason', format($$select app.door(%L, 'aal2', 'ops_do', 'hold_action_begin', jsonb_build_object('booking', 'DG-13', 'action', 'release', 'reason', 'Renter swapped to another car'))$$, test.id('dgx_admin')));
select test.eq('the Admin''s release is recorded', (select kind || '/' || reason from deposit_overrides where booking_id = test.dgb('DG-13')), 'hold_action/Renter swapped to another car');

-- ================================================================ 8. damage
-- DG-12: returned, the deposit collected, fuel on the statement, damage found: an Admin keeps the whole deposit
select test.mk_booking('DG-12', 'DGL', 'dgx_r', test.dgl(-6), test.dgl(-3), 'returned', null, 'standard', null, null, test.dgl(-3));
select test.dg_hold('DG-12', now() + interval '1 day');
update deposits set status = 'captured', captured_cents = 100000 where booking_id = test.dgb('DG-12');
update payments set status = 'succeeded' where id = test.id('hold:DG-12');
select test.dg_statement('DG-12', 'fuel', 6000);
insert into incidents (kind, vehicle_id, booking_id, description, status) values ('damage_at_return', test.id('vehicle:DGL'), test.dgb('DG-12'), 'Door dent', 'open');
select test.throws('Finance does not keep a deposit for damage', format($$select app.door(%L, 'aal2', 'ops_do', 'deposit_keep_whole', jsonb_build_object('booking', 'DG-12', 'reason', 'Dent in the rear door', 'photos', '["R12"]'::jsonb))$$, test.id('dgx_fin')), 'An Admin');
select test.throws('the damage needs its photos or estimate', format($$select app.door(%L, 'aal2', 'ops_do', 'deposit_keep_whole', jsonb_build_object('booking', 'DG-12', 'reason', 'Dent in the rear door'))$$, test.id('dgx_admin')), 'photos');
insert into test.dg select 'k12', app.door(test.id('dgx_admin'), 'aal2', 'ops_do', 'deposit_keep_whole', jsonb_build_object('booking', 'DG-12', 'reason', 'Dent in the rear door, left side', 'photos', '["Return report photo 7", "Close-up 21"]'::jsonb));
select test.eq('kept: what is left after the fuel ($932.20) is a damage line with the reason and photos, on a statement',
  (select amount_cents || '/' || description || '/' || jsonb_array_length(supporting_refs -> 'photos') || '/' || (statement_id is not null) from booking_line_items where booking_id = test.dgb('DG-12') and charge_type = 'damage_at_cost'),
  '93220/Damage: Dent in the rear door, left side/2/true');
select test.eq('the whole deposit is applied, nothing released or refunded; the booking closes',
  (select applied_cents || '/' || released_cents || '/' || held_back_cents from test.dgd('DG-12')) || ' ' || (select status::text from bookings where id = test.dgb('DG-12'))
  || ' ' || (select count(*) from payments where booking_id = test.dgb('DG-12') and kind in ('release', 'refund')), '100000/0/0 closed 0');
select test.eq('the renter is told about the damage charge', (select count(*) from app_events where code = 'renter_extra_charge' and payload ->> 'charge_kind' = 'damage' and payload ->> 'booking_id' = test.dgb('DG-12')::text), 1::bigint);
-- a damage charge above what is left: the card on file pays the rest; above the deductible it goes through a claim
select test.throws('above the deductible a damage charge goes through a claim', format($$select app.door(%L, 'aal2', 'ops_do', 'damage_charge_add', jsonb_build_object('booking', 'DG-12', 'amount_cents', 300000, 'reason', 'Rear bumper replaced', 'photos', '["P1"]'::jsonb))$$, test.id('dgx_admin')), 'goes through a claim');
insert into test.dg select 'd12', app.door(test.id('dgx_admin'), 'aal2', 'ops_do', 'damage_charge_add', jsonb_build_object('booking', 'DG-12', 'amount_cents', 150000, 'reason', 'Rear bumper replaced', 'photos', '["P1"]'::jsonb));
select test.eq('the damage after the deposit is used: charged to the card on file (marked for the server), on a later statement',
  (select amount_cents || '/' || server_action from payments where booking_id = test.dgb('DG-12') and server_action = 'charge_card') || '/' ||
  (select count(*) from booking_statements where booking_id = test.dgb('DG-12') and kind = 'later_charge'), '150000/charge_card/2');

-- ================================================================ 8b. nothing old is run by itself (the first run in production)
select test.eq('the automatic limit: 14 days', (select deposit_auto_max_age_days from program_settings limit 1), 14);
-- DG-14: a card charge a settlement left pending 20 days ago
select test.mk_booking('DG-14', 'DGC', 'dgx_r', test.dgl(-30), test.dgl(-27), 'closed', null, 'standard', null, null, test.dgl(-27));
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, payment_method_id, server_action, created_at)
select test.id('old:DG-14'), id, renter_id, 'post_rental', 'charge', 'card', 7700, 'pending', test.id('card:dgx_r'), 'charge_card', now() - interval '20 days' from bookings where id = test.dgb('DG-14');
-- DG-15: a balance on a statement issued 20 days ago, never followed up
select test.mk_booking('DG-15', 'DGD', 'dgx_r', test.dgl(-40), test.dgl(-37), 'closed', null, 'standard', null, null, test.dgl(-37));
select test.dg_statement('DG-15', 'cleaning', 10000);
update booking_statements set issued_at = now() - interval '20 days' where booking_id = test.dgb('DG-15');
-- DG-16: a hold still recorded as held two days after it lapsed
select test.mk_booking('DG-16', 'DGE', 'dgx_r', test.dgl(-9), test.dgl(-4), 'returned', null, 'standard', null, null, test.dgl(-4));
select test.dg_hold('DG-16', now() - interval '2 days');
insert into test.dg select 'sw2', public.server_deposit_guard_sweep();
select test.eq('the old step is not on the list to run, and the server gets nothing to run for it',
  (test.dgv('sw2') -> 'payments') ? test.id('old:DG-14')::text || '/' || coalesce(public.server_money_action(test.id('old:DG-14'))::text, 'none'), 'false/none');
select test.eq('the lapsed hold is not captured', (select count(*) from jsonb_array_elements(test.dgv('sw2') -> 'captures') x where x ->> 'booking_number' = 'DG-16'), 0::bigint);
select test.eq('Finance reviews the old step and the lapsed hold', (select string_agg(b.booking_number, ',' order by b.booking_number) from tasks t join bookings b on b.id = t.booking_id
  where t.task_type = 'deposit_money_review' and t.status = 'open' and b.booking_number in ('DG-14', 'DG-16')), 'DG-14,DG-16');
select test.eq('the old balance: reviewed, never charged or chased by itself', (public.server_balance_next(test.dgb('DG-15')) ->> 'action') || '/' ||
  (select count(*) from payments where booking_id = test.dgb('DG-15') and server_action is not null) || '/' ||
  (select count(*) from payment_requests where booking_id = test.dgb('DG-15')), 'review/0/0');
select test.eq('and it stays by hand', public.server_balance_next(test.dgb('DG-15')) ->> 'action', 'review');
select test.eq('a lapse found long after is never charged by itself', (select count(*) from payments where booking_id = test.dgb('DG-16') and server_action = 'deposit_charge'), 0::bigint);

-- ================================================================ 9. pay links and privileges
select test.lives('a pay link for a later charge on a closed booking (tickets arrive weeks later)',
  format($$select app.door(%L, 'aal2', 'ops_do', 'payreq_create', jsonb_build_object('booking', 'DG-12', 'kind', 'charge', 'covers', 'later', 'amount_cents', 4000, 'reason', 'Parking ticket', 'channel', 'email', 'token_sha256', repeat('c', 64)))$$, test.id('dgx_admin')));
select test.throws('still no deposit hold on a closed booking', format($$select app.door(%L, 'aal2', 'ops_do', 'payreq_create', jsonb_build_object('booking', 'DG-12', 'kind', 'hold', 'token_sha256', repeat('d', 64)))$$, test.id('dgx_cs')), 'closed');
select test.eq('the server functions are the service role''s only',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('server_money_action', 'server_money_action_finish', 'server_deposit_capture_begin', 'server_deposit_hold_lapsed', 'server_balance_next',
                                                  'server_balance_payreq', 'server_balance_payreq_send', 'server_deposit_guard_sweep')
      and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))), 0::bigint);
select test.eq('the new tables have row-level security', (select count(*) from pg_class where relname in ('deposit_overrides', 'balance_followups', 'deposit_guard_state') and relrowsecurity), 3::bigint);
