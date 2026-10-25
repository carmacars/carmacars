-- 99: referral partners and the RentalCoverage affiliate (migration 0164, docs/changes/2026-10-25-referral-partners.md).
-- Partners (body shops, tow trucks): added by an Admin or signed up on the public page (pending until approved), a code nobody else
-- holds, the code on a request or on Add a rental ties the booking to the partner (never together with an owner's or a field staff
-- member's code); the kickback accrues, is earned when the rental is completed and paid in full, on the rental charge after
-- discounts, approved and paid by hand; before Owner Revenue on a program owner's car, CarmaCars' own otherwise; reversed,
-- voided or clawed back when the rental is cancelled, charged back or refunded; the partner's own page shows a first name and
-- a month, nothing more. The RentalCoverage affiliate: off until a link is pasted, clicks recorded, payments entered by hand.
-- Fixtures start with "rp".
select test.suite('99 referral partners');

select test.mk_user('rfp_admin', 'admin');
select test.mk_user('rfp_cs', 'va', 'cs');
select test.mk_renter('rfp_rita');
select test.mk_renter('rfp_ron');
select test.mk_owner('rfp_olive', 'RPOWNER1');
select test.mk_vehicle('rfp_prog', 'rfp_olive');

create temp table s99 as select null::text as k, null::jsonb as v limit 0;
create or replace function test.s99(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.s99 where k = p_k $$;
create or replace function test.s99b(p_k text) returns bookings language sql stable as $$
  select * from bookings where id = coalesce((test.s99(p_k) ->> 'booking_id')::uuid, (test.s99(p_k) ->> 'id')::uuid) $$;
create or replace function test.s99e(p_k text) returns referral_partner_earnings language sql stable as $$
  select * from referral_partner_earnings where booking_id = (test.s99b(p_k)).id and kind = 'earning' order by created_at desc limit 1 $$;
create or replace function test.s99p(p_k text) returns referral_partners language sql stable as $$
  select * from referral_partners where id = (test.s99(p_k) ->> 'id')::uuid $$;
-- CarmaCars-owned cars with rates
do $$
declare i integer;
begin
  for i in 1 .. 6 loop
    insert into s99 select 'car' || i, app.vehicle_add(test.id('rfp_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1RPCXMM00000000' || lpad(i::text, 2, '0'),
      'plate', 'RPC00' || i, 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  end loop;
end $$;
create or replace function test.s99v(p text) returns uuid language sql stable as $$ select (test.s99(p) ->> 'vehicle_id')::uuid $$;
create or replace function test.s99m() returns date language sql stable as $$ select (app.month_start(app.today()) - interval '1 month')::date $$;
-- a completed, paid rental last month (start day, days), recorded by an Admin, with an optional partner code
create or replace function test.s99past(p_vehicle uuid, p_day integer, p_days integer, p_code text default null, p_renter text default 'rfp_rita') returns jsonb language sql as $$
  select jsonb_build_object('vehicle_id', p_vehicle, 'pickup_at', app.local_midnight(test.s99m() + p_day - 1) + interval '10 hours',
    'return_at', app.local_midnight(test.s99m() + p_day - 1 + p_days) + interval '10 hours', 'source', 'phone', 'coverage_option', 1, 'past', true,
    'renter_id', test.id('renter:' || p_renter), 'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash'))
    || case when p_code is not null then jsonb_build_object('referral_code', p_code) else '{}'::jsonb end $$;
create or replace function test.s99sold(p_k text, p_spec jsonb) returns void language plpgsql as $$
begin
  insert into s99 select p_k, app.manual_rental_create(test.id('rfp_admin'), p_spec);
end $$;

-- ================================================================ 1. settings and codes
select test.eq('settings: $50 flat, 10% when a percentage is chosen', (select s.referral_partner_flat_cents || '/' || s.referral_partner_percent_bps from (select (app.settings()).*) s), '5000/1000');
select test.eq('program rate for the public page', public.referral_program_public() ->> 'flat_cents', '5000');
insert into s99 select 'shop', app.door(test.id('rfp_admin'), 'aal2', 'admin_do', 'referral_partner_save', jsonb_build_object('kind', 'body_shop', 'business_name', 'Test Collision Works',
  'contact_name', 'Sam Tester', 'phone', '4165550142', 'email', 'Shop@Example.com', 'address_line1', '1 Test Street', 'city', 'Toronto', 'postal_code', 'm5v 1a1', 'payout_email', 'pay@example.com'));
select test.eq('add: an Admin''s partner is active, at the default flat rate, email lowercased, postal code upper case',
  (select status || '/' || rate_kind || '/' || flat_cents || '/' || email || '/' || postal_code || '/' || source from test.s99p('shop')), 'active/flat/5000/shop@example.com/M5V 1A1/admin');
select test.ok('add: a code of 6 letters and digits, none of the look-alikes', (test.s99p('shop')).referral_code ~ '^[A-HJKMN-Z2-9]{6}$');
select test.eq('add: the rate in words', app.referral_rate_text(test.s99p('shop')), '$50.00 per completed rental');
select test.eq('code: the partner''s code is known to the site', public.referral_partner_code_ok((test.s99p('shop')).referral_code), true);
select test.eq('code: an owner''s code is not a partner''s', public.referral_partner_code_ok('RPOWNER1'), false);
select test.ok('code: an owner''s code is taken', not app.referral_code_free('rpowner1'));
select test.throws('add: a code already used by an owner is refused', format($$select app.referral_partner_save(%L, jsonb_build_object('business_name', 'Another Shop', 'referral_code', 'RPOWNER1'))$$, test.id('rfp_admin')), 'already in use');
select test.throws('add: an Admin only', format($$select app.door(%L, 'aal2', 'admin_do', 'referral_partner_save', jsonb_build_object('business_name', 'Sneaky Shop'))$$, test.id('rfp_cs')), 'admin');
select test.throws('add: a name is needed', format($$select app.referral_partner_save(%L, jsonb_build_object('kind', 'tow_truck'))$$, test.id('rfp_admin')), 'business name');
insert into s99 select 'tow', app.referral_partner_save(test.id('rfp_admin'), jsonb_build_object('kind', 'tow_truck', 'business_name', 'Test Towing', 'rate_kind', 'percent', 'rate_bps', 1200, 'referral_code', 'rptow1'));
select test.eq('add: a tow truck on a percentage, its own code', (select kind || '/' || rate_kind || '/' || rate_bps || '/' || referral_code from test.s99p('tow')), 'tow_truck/percent/1200/RPTOW1');
select test.eq('rate in words: a share of the rental charge', app.referral_rate_text(test.s99p('tow')), '12% of the rental charge');

-- ================================================================ 2. the public sign-up
select test.eq('sign-up: answered ok', public.server_referral_partner_signup(jsonb_build_object('kind', 'body_shop', 'business_name', 'Signup Autobody', 'contact_name', 'Pat Tester',
  'phone', '4165550143', 'email', 'signup@example.com', 'city', 'Mississauga', 'note', 'Two shops'), '203.0.113.7') ->> 'ok', 'true');
select test.eq('sign-up: a pending partner, not active', (select status || '/' || source || '/' || flat_cents from referral_partners where email = 'signup@example.com'), 'pending/signup/5000');
select test.eq('sign-up: its code is not live until it is approved', public.referral_partner_code_ok((select referral_code from referral_partners where email = 'signup@example.com')), false);
select test.ok('sign-up: a task for the Admins', exists (select 1 from tasks t where t.task_type = 'referral_partner_signup' and t.status = 'open' and t.queue = 'admin'));
select test.eq('sign-up: the same address again is one sign-up', (public.server_referral_partner_signup(jsonb_build_object('kind', 'body_shop', 'business_name', 'Signup Autobody', 'contact_name', 'Pat Tester',
  'phone', '4165550143', 'email', 'SIGNUP@example.com'), '203.0.113.7') ->> 'ok') || '/' || (select count(*) from referral_partners where email = 'signup@example.com'), 'true/1');
select test.throws('sign-up: a full email address', $$select public.server_referral_partner_signup(jsonb_build_object('kind', 'tow_truck', 'business_name', 'No Email Towing', 'contact_name', 'X Y', 'phone', '4165550144', 'email', 'nope'))$$, 'email');
select test.throws('sign-up: a phone number', $$select public.server_referral_partner_signup(jsonb_build_object('kind', 'tow_truck', 'business_name', 'No Phone Towing', 'contact_name', 'X Y', 'email', 'np@example.com'))$$, 'phone');
select test.ok('sign-up: not callable by the public (the server only)', not has_function_privilege('anon', 'public.server_referral_partner_signup(jsonb, text)', 'execute'));
select test.ok('code check and rate are public reads', has_function_privilege('anon', 'public.referral_partner_code_ok(text)', 'execute') and has_function_privilege('anon', 'public.referral_program_public()', 'execute'));
select test.throws('approve: an Admin only', format($$select app.door(%L, 'aal2', 'admin_do', 'referral_partner_decide', jsonb_build_object('id', %L, 'action', 'approve'))$$,
  test.id('rfp_cs'), (select id from referral_partners where email = 'signup@example.com')), 'admin');
select app.referral_partner_decide(test.id('rfp_admin'), jsonb_build_object('id', (select id from referral_partners where email = 'signup@example.com'), 'action', 'approve'));
select test.eq('approve: active, the code live, the task done', (select status from referral_partners where email = 'signup@example.com') || '/'
  || public.referral_partner_code_ok((select referral_code from referral_partners where email = 'signup@example.com')) || '/'
  || (select status from tasks where task_type = 'referral_partner_signup' order by created_at desc limit 1), 'active/true/done');
select test.throws('approve: only a sign-up waiting', format($$select app.referral_partner_decide(%L, jsonb_build_object('id', %L, 'action', 'approve'))$$, test.id('rfp_admin'), (test.s99p('shop')).id), 'waiting');
select app.referral_partner_decide(test.id('rfp_admin'), jsonb_build_object('id', (select id from referral_partners where email = 'signup@example.com'), 'action', 'pause'));
select test.eq('pause: the code stops working', public.referral_partner_code_ok((select referral_code from referral_partners where email = 'signup@example.com')), false);

-- ================================================================ 3. the code ties a booking to the partner
insert into s99 select 'web1', jsonb_build_object('id', app.request_booking(test.id('renter:rfp_ron'), test.s99v('car1'), date_trunc('hour', now()) + interval '40 days',
  date_trunc('hour', now()) + interval '43 days', 'standard', null, 'web', test.id('rfp_ron'), (test.s99p('shop')).referral_code));
select test.eq('request with the partner''s code: tied to the partner, no owner or staff referrer', (select (referral_partner_id = (test.s99p('shop')).id) || '/' || coalesce(referrer_type, 'none') from test.s99b('web1')), 'true/none');
select test.eq('request: the partner earns on its own ledger, never the owner Referral Kickback', app.kickback_ineligible_reason((test.s99b('web1')).id), 'not referred');
select test.eq('request: a kickback accruing at the partner''s rate while the rental is ahead', (select status || '/' || amount_cents from test.s99e('web1')), 'accruing/0');
insert into s99 select 'web2', jsonb_build_object('id', app.request_booking(test.id('renter:rfp_ron'), test.s99v('car2'), date_trunc('hour', now()) + interval '45 days',
  date_trunc('hour', now()) + interval '47 days', 'standard', null, 'web', test.id('rfp_ron'), 'RPOWNER1'));
select test.eq('request with an owner''s code: the owner''s referral, no partner', (select coalesce(referrer_type, 'none') || '/' || coalesce(referral_partner_id::text, 'none') from test.s99b('web2')), 'owner/none');
insert into s99 select 'web3', jsonb_build_object('id', app.request_booking(test.id('renter:rfp_ron'), test.s99v('car3'), date_trunc('hour', now()) + interval '50 days',
  date_trunc('hour', now()) + interval '52 days', 'standard', null, 'web', test.id('rfp_ron'), 'ZZZZZZ'));
select test.eq('request with a code nobody holds: no referrer at all', (select coalesce(referrer_type, 'none') || '/' || coalesce(referral_partner_id::text, 'none') from test.s99b('web3')), 'none/none');
select set_config('rp.web1', (test.s99b('web1')).id::text, false);
select set_config('request.jwt.claim.sub', test.id('rfp_cs')::text, false);
set role authenticated;
select test.throws('a staff browser session may not change the partner of a booking', $$update bookings set referral_partner_id = null where id = current_setting('rp.web1')::uuid$$, 'Only an Admin');
reset role;
select set_config('request.jwt.claim.sub', '', false);

-- ================================================================ 4. earned, approved, paid (flat $50)
select test.throws('Add a rental: a partner code nobody holds is refused', format($$select app.manual_rental_create(%L, test.s99past(test.s99v('car4'), 3, 3, 'NOPE99'))$$, test.id('rfp_admin')), 'No active referral partner');
select test.s99sold('flat', test.s99past(test.s99v('car4'), 3, 3, (test.s99p('shop')).referral_code));
select test.eq('Add a rental with the code: tied to the partner', (select (referral_partner_id = (test.s99p('shop')).id)::text from test.s99b('flat')), 'true');
select test.eq('earned: completed and paid in full, pending approval, $50 flat on the rental charge after discounts',
  (select e.status || '/' || e.amount_cents || '/' || (e.base_cents = app.commission_base_cents(e.booking_id)) || '/' || e.rate_kind from test.s99e('flat') e), 'pending_approval/5000/true/flat');
select test.eq('base: before tax, after discounts', (test.s99e('flat')).base_cents, (select rental_charge_cents - discount_cents - staff_discount_cents - promo_discount_cents from test.s99b('flat')));
select test.throws('approve: an Admin only', format($$select app.door(%L, 'aal2', 'admin_do', 'referral_earning_approve', jsonb_build_object('ids', jsonb_build_array(%L)))$$, test.id('rfp_cs'), (test.s99e('flat')).id), 'admin');
select test.throws('pay: only approved kickbacks', format($$select app.referral_partner_payout(%L, jsonb_build_object('partner', %L, 'ids', jsonb_build_array(%L), 'method', 'cash'))$$,
  test.id('rfp_admin'), (test.s99p('shop')).id, (test.s99e('flat')).id), 'approved');
select app.door(test.id('rfp_admin'), 'aal2', 'admin_do', 'referral_earning_approve', jsonb_build_object('ids', jsonb_build_array((test.s99e('flat')).id)));
select test.eq('approved', (test.s99e('flat')).status, 'approved');
select test.throws('pay: an e-Transfer needs its reference', format($$select app.referral_partner_payout(%L, jsonb_build_object('partner', %L, 'method', 'e_transfer'))$$, test.id('rfp_admin'), (test.s99p('shop')).id), 'reference');
select test.throws('pay: not dated in the future', format($$select app.referral_partner_payout(%L, jsonb_build_object('partner', %L, 'method', 'cash', 'paid_on', app.today() + 1))$$, test.id('rfp_admin'), (test.s99p('shop')).id), 'future');
-- the rate changes later: what is already tied keeps its rate, nothing is rewritten
select app.referral_partner_save(test.id('rfp_admin'), jsonb_build_object('id', (test.s99p('shop')).id, 'flat_cents', 7500));
select test.eq('a rate change leaves earned kickbacks alone', (test.s99e('flat')).amount_cents, 5000::bigint);
select app.referral_partner_save(test.id('rfp_admin'), jsonb_build_object('id', (test.s99p('shop')).id, 'flat_cents', 5000));
select test.eq('payment: recorded with the reference, the total and the count', (select (r ->> 'amount_cents') || '/' || (r ->> 'count') from (select app.door(test.id('rfp_admin'), 'aal2', 'admin_do', 'referral_partner_payout',
  jsonb_build_object('partner', (test.s99p('shop')).id, 'method', 'e_transfer', 'reference', 'E-TEST-0001', 'paid_on', app.today())) r) x), '5000/1');
select test.eq('paid: the kickback and its payment', (select e.status || '/' || (e.payout_id is not null) || '/' || (select y.reference from referral_partner_payouts y where y.id = e.payout_id) from test.s99e('flat') e), 'paid/true/E-TEST-0001');
select test.eq('the partner''s row totals', (select (r ->> 'paid_cents') || '/' || (r ->> 'approved_cents') || '/' || (r ->> 'completed') from (select app.referral_partner_row(test.s99p('shop')) r) x), '5000/0/1');

-- ================================================================ 5. a percentage, and what a cancelled rental earns
select test.s99sold('pct', test.s99past(test.s99v('car5'), 3, 4, 'RPTOW1'));
select test.eq('percentage: 12% of the rental charge after discounts', (select e.amount_cents = round(e.base_cents * 0.12) and e.amount_cents > 0 and e.rate_bps = 1200 from test.s99e('pct') e), true);
select test.ok('a kickback is never more than the base itself', app.referral_earning_amount('flat', 99999999, null, 4000) = 4000 and app.referral_earning_amount('percent', null, 5000, 4000) = 2000);
-- a later partner credit: an Admin ties a booking to a partner after the fact, and takes it off
select test.s99sold('late', test.s99past(test.s99v('car6'), 3, 2));
select test.eq('no partner, no kickback', (select count(*) from referral_partner_earnings where booking_id = (test.s99b('late')).id), 0::bigint);
select test.throws('credit: a reason is needed', format($$select app.referral_partner_credit(%L, jsonb_build_object('booking', %L, 'partner', %L))$$, test.id('rfp_admin'), (test.s99b('late')).booking_number, (test.s99p('shop')).id), 'Say why');
select app.door(test.id('rfp_admin'), 'aal2', 'admin_do', 'referral_partner_credit', jsonb_build_object('booking', (test.s99b('late')).booking_number, 'partner', (test.s99p('shop')).id, 'reason', 'The shop sent the renter; she forgot the code'));
select test.eq('credit: the kickback appears, pending approval', (select status || '/' || amount_cents from test.s99e('late')), 'pending_approval/5000');
select app.referral_partner_credit(test.id('rfp_admin'), jsonb_build_object('booking', (test.s99b('late')).booking_number, 'partner', null, 'reason', 'Wrong partner'));
select test.eq('credit removed: the kickback stops (reversed) and the booking has no partner', (select status from test.s99e('late')) || '/' || coalesce((test.s99b('late')).referral_partner_id::text, 'none'), 'reversed/none');
select test.throws('credit: a booking with an owner referrer cannot have a partner', format($$select app.referral_partner_credit(%L, jsonb_build_object('booking', %L, 'partner', %L, 'reason', 'x'))$$,
  test.id('rfp_admin'), (test.s99b('web2')).booking_number, (test.s99p('shop')).id), 'owner or field staff');
-- a request that is cancelled earns nothing
update bookings set status = 'declined' where id = (test.s99b('web1')).id;
select test.eq('declined or cancelled booking: the accruing kickback is void', (select status || '/' || reason from test.s99e('web1')), 'void/Cancelled booking');
-- a chargeback after payment: a clawback is taken off the next payment
select test.s99sold('cb', test.s99past(test.s99v('car4'), 12, 2, (test.s99p('shop')).referral_code));
select app.referral_earning_approve(test.id('rfp_admin'), jsonb_build_object('partner', (test.s99p('shop')).id));
select app.referral_partner_payout(test.id('rfp_admin'), jsonb_build_object('partner', (test.s99p('shop')).id, 'method', 'cash'));
select test.eq('second payment made', (test.s99e('cb')).status, 'paid');
insert into disputes (payment_id, booking_id, amount_cents, status) select p.id, p.booking_id, p.amount_cents, 'lost' from payments p where p.booking_id = (test.s99b('cb')).id and p.status = 'succeeded' limit 1;
select test.eq('charged back after payment: a clawback of the same amount, approved, for the next payment',
  (select c.status || '/' || c.amount_cents || '/' || (c.clawback_of = (test.s99e('cb')).id) from referral_partner_earnings c where c.booking_id = (test.s99b('cb')).id and c.kind = 'clawback'), 'approved/-5000/true');
select test.eq('the booking counts nothing against Owner Revenue once taken back', app.booking_referral_partner_cents((test.s99b('cb')).id), 0::bigint);
-- an Admin's reversal stands
select app.referral_earning_reverse(test.id('rfp_admin'), jsonb_build_object('id', (test.s99e('pct')).id, 'reason', 'The partner''s own rental'));
select test.eq('Admin reversal: reversed with the reason, and it stays so', (select status || '/' || reason || '/' || admin_reversed from test.s99e('pct')), 'reversed/The partner''s own rental/true');
select test.throws('reverse: a reason is needed', format($$select app.referral_earning_reverse(%L, jsonb_build_object('id', %L))$$, test.id('rfp_admin'), (test.s99e('flat')).id), 'Say why');

-- ================================================================ 6. before Owner Revenue (an owner's car), a CarmaCars expense otherwise
select test.s99sold('own_car', test.s99past(test.id('vehicle:rfp_prog'), 5, 3, (test.s99p('shop')).referral_code));
select test.eq('owner''s car: the kickback is deducted before Owner Revenue, with the staff commissions',
  (select (s.staff_commission_cents = 5000) || '/' || (s.kickback_cents = 5000) || '/' || (s.owner_revenue_cents = s.rental_charge_cents + s.mileage_overage_cents - s.kickback_cents)
     from booking_splits s where s.booking_id = (test.s99b('own_car')).id), 'true/true/true');
select test.ok('owner''s car: the Revenue Share is taken after it',
  (select s.company_share_cents = (select x.company_share_cents from public.calc_split(s.rental_charge_cents, s.mileage_overage_cents, s.kickback_cents, s.company_share_bps) x)
     from booking_splits s where s.booking_id = (test.s99b('own_car')).id));
select test.eq('CarmaCars-owned car: nothing deducted from anyone but CarmaCars', (select coalesce(sum(staff_commission_cents), 0) from booking_splits where booking_id = (test.s99b('flat')).id), 0::bigint);
select app.referral_earning_reverse(test.id('rfp_admin'), jsonb_build_object('id', (test.s99e('own_car')).id, 'reason', 'Test: reversed before payment'));
select test.eq('reversed: the deduction goes and Owner Revenue is whole again', (select s.kickback_cents || '/' || (s.owner_revenue_cents = s.rental_charge_cents + s.mileage_overage_cents)
  from booking_splits s where s.booking_id = (test.s99b('own_car')).id), '0/true');

-- ================================================================ 7. the partner's own page
select test.eq('portal: nothing for a partner that is not live (pending or unknown)', public.server_referral_partner_portal(gen_random_uuid()) is null, true);
select test.eq('portal: the totals', (select (r #>> '{totals,paid_cents}') from (select public.server_referral_partner_portal((test.s99p('shop')).id) r) x), '10000');
select test.eq('portal: a row has a first name, a month, a status and an amount, and nothing else',
  (select string_agg(k, ',' order by k) from (select distinct jsonb_object_keys(r) k from jsonb_array_elements(public.server_referral_partner_portal((test.s99p('shop')).id) -> 'rows') r) x), 'amount_cents,first_name,month,paid_on,sort,status');
select test.ok('portal: no booking number or surname anywhere in it', public.server_referral_partner_portal((test.s99p('shop')).id)::text !~* 'booking_number|legal_name|email|mobile');
select test.ok('portal: the renter''s first name only', exists (select 1 from jsonb_array_elements(public.server_referral_partner_portal((test.s99p('shop')).id) -> 'rows') r
   where r ->> 'first_name' = split_part((select legal_name from renters where id = test.id('renter:rfp_rita')), ' ', 1)) and
   public.server_referral_partner_portal((test.s99p('shop')).id)::text !~ (select split_part(legal_name, ' ', 2) from renters where id = test.id('renter:rfp_rita')));
select test.ok('portal: not callable by the public (the server checks the partner''s link)', not has_function_privilege('anon', 'public.server_referral_partner_portal(uuid)', 'execute'));

-- ================================================================ 8. Admin reads
select test.eq('door: the partners list', (select jsonb_array_length(app.door(test.id('rfp_admin'), 'aal2', 'admin_read', 'referral_partners', '{}'::jsonb) -> 'partners') >= 3)::text, 'true');
select test.throws('door: the list is an Admin''s', format($$select app.door(%L, 'aal2', 'admin_read', 'referral_partners', '{}'::jsonb)$$, test.id('rfp_cs')), 'admin');
select test.eq('door: a partner''s detail has its earnings and payments', (select (jsonb_array_length(r -> 'earnings') >= 2) || '/' || (jsonb_array_length(r -> 'payouts') = 2)
  from (select app.door(test.id('rfp_admin'), 'aal2', 'admin_read', 'referral_partner', jsonb_build_object('id', (test.s99p('shop')).id)) r) x), 'true/true');
select test.eq('door: the ledger by status', (select bool_and(x ->> 'status' = 'paid') from jsonb_array_elements(app.door(test.id('rfp_admin'), 'aal2', 'admin_read', 'referral_earnings', jsonb_build_object('status', 'paid')) -> 'rows') x), true);
select test.eq('door: link new ends the old link', (select (r ->> 'portal_version') from (select app.door(test.id('rfp_admin'), 'aal2', 'admin_do', 'referral_partner_link_new', jsonb_build_object('id', (test.s99p('shop')).id)) r) x), '2');

-- ================================================================ 9. the RentalCoverage affiliate
select test.eq('affiliate: off until a link is pasted', (public.coverage_affiliate_public() ->> 'enabled') || '/' || (public.coverage_affiliate_public() ->> 'name'), 'false/RentalCoverage');
select test.eq('affiliate: a click while it is off is not recorded and gives no link', (public.server_coverage_click(jsonb_build_object('placement', 'requirements')) ->> 'ok') || '/' || (select count(*) from coverage_clicks), 'false/0');
select test.throws('affiliate: the program cannot be on without a link', format($$select app.coverage_affiliate_save(%L, jsonb_build_object('enabled', true))$$, test.id('rfp_admin')), 'Paste the affiliate link');
select test.throws('affiliate: a link starts with https://', format($$select app.coverage_affiliate_save(%L, jsonb_build_object('link_url', 'http://example.com/a'))$$, test.id('rfp_admin')), 'https');
select test.throws('affiliate: an Admin only', format($$select app.door(%L, 'aal2', 'admin_do', 'coverage_affiliate_save', jsonb_build_object('link_url', 'https://example.com/a'))$$, test.id('rfp_cs')), 'admin');
select app.door(test.id('rfp_admin'), 'aal2', 'admin_do', 'coverage_affiliate_save', jsonb_build_object('link_url', 'https://example.com/rc?aff={id}'));
select test.eq('affiliate: pasting the link the first time turned it on, but {id} has no ID yet so the site shows nothing', (select enabled::text from coverage_affiliate) || '/' || (public.coverage_affiliate_public() ->> 'enabled'), 'true/false');
select app.coverage_affiliate_save(test.id('rfp_admin'), jsonb_build_object('affiliate_id', 'abc123'));
select test.eq('affiliate: link and ID set: the site shows it', public.coverage_affiliate_public() ->> 'enabled', 'true');
insert into s99 select 'click1', public.server_coverage_click(jsonb_build_object('placement', 'booking_step', 'visitor_id', test.id('rfp_visitor'), 'booking_number', (test.s99b('flat')).booking_number), '203.0.113.9');
select test.eq('affiliate: a click is recorded for the place, the visitor and the booking, and returns the link',
  (test.s99('click1') ->> 'link_url') || '/' || (select placement || '/' || (booking_id = (test.s99b('flat')).id) || '/' || (visitor_id = test.id('rfp_visitor')) from coverage_clicks), 'https://example.com/rc?aff={id}/booking_step/true/true');
insert into s99 select 'click2', public.server_coverage_click(jsonb_build_object('placement', 'whatever'), '203.0.113.9');
select test.eq('affiliate: an unknown place is "other"', (test.s99('click2') ->> 'ok') || '/' || (select count(*) from coverage_clicks where placement = 'other'), 'true/1');
select test.ok('affiliate: clicks are not callable by the public (through the redirect only)', not has_function_privilege('anon', 'public.server_coverage_click(jsonb, text)', 'execute'));
select app.door(test.id('rfp_admin'), 'aal2', 'admin_do', 'coverage_affiliate_payment_add', jsonb_build_object('received_on', app.today(), 'amount_cents', 12345, 'period_note', 'September', 'reference', 'RC-TEST-1'));
select test.throws('affiliate payment: an amount', format($$select app.coverage_affiliate_payment_add(%L, jsonb_build_object('amount_cents', 0))$$, test.id('rfp_admin')), 'amount');
select test.eq('affiliate report: clicks, visitors, clicks with a booking, what was received, by place',
  (select (r #>> '{totals,clicks}') || '/' || (r #>> '{totals,visitors}') || '/' || (r #>> '{totals,with_booking}') || '/' || (r #>> '{totals,received_cents}') || '/' || jsonb_array_length(r -> 'by_place')
     from (select app.door(test.id('rfp_admin'), 'aal2', 'admin_read', 'coverage_affiliate', '{}'::jsonb) r) x), '2/1/1/12345/2');
select app.coverage_affiliate_save(test.id('rfp_admin'), jsonb_build_object('enabled', false));
select test.eq('affiliate: switched off again, the site shows nothing and clicks are not recorded', (public.coverage_affiliate_public() ->> 'enabled') || '/' || (public.server_coverage_click(jsonb_build_object('placement', 'requirements')) ->> 'ok'), 'false/false');

-- ================================================================ 10. privileges
select test.ok('the partner tables are Admin only (row security)', (select bool_and(c.relrowsecurity) from pg_class c where c.relname in ('referral_partners', 'referral_partner_earnings', 'referral_partner_payouts', 'coverage_affiliate', 'coverage_clicks', 'coverage_affiliate_payments')));
select test.ok('the ledger functions are not for browser sessions', not has_function_privilege('authenticated', 'app.referral_partner_payout(uuid, jsonb)', 'execute') and not has_function_privilege('anon', 'app.referral_partner_sync(uuid)', 'execute'));
