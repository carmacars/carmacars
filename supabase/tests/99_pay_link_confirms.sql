-- 99: a pay link paid in full confirms the booking like the renter's pay page (migration 0260). Fixtures start with "plc".
select test.suite('99 pay link confirms');

select test.mk_user('plc_admin', 'admin');
select test.mk_user('plc_cs', 'va', 'cs');
update staff_profiles set single_limit_cents = 500000 where user_id = test.id('plc_cs');

create table test.plc (k text primary key, v jsonb);
grant select on test.plc to authenticated, service_role;
create function test.plcv(p text) returns jsonb language sql stable as $$ select v from test.plc where k = p $$;
create function test.plcb(p text) returns bookings language sql stable security definer as $$
  select * from public.bookings where id = coalesce((test.plcv(p) ->> 'booking_id')::uuid, (test.plcv(p) ->> 'id')::uuid) $$;
create function test.plcu(p text) returns uuid language sql stable security definer as $$
  select r.user_id from public.renters r where r.id = (test.plcb(p)).renter_id $$;
do $$
declare i integer;
begin
  for i in 1 .. 2 loop
    insert into test.plc select 'car' || i, app.vehicle_add(test.id('plc_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXMM00000099' || lpad(i::text, 2, '0'),
      'plate', 'PLC00' || i, 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  end loop;
end $$;
create function test.plc_offer(p_car text, p_email text, p_mobile text, p_from interval) returns jsonb language sql as $$
  select app.door(test.id('plc_cs'), 'aal2', 'ops_do', 'offer_create', jsonb_build_object('vehicle_id', (test.plcv(p_car) ->> 'vehicle_id')::uuid,
    'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_from + interval '3 days',
    'renter', jsonb_build_object('full_name', 'Pia Link', 'email', p_email, 'mobile', p_mobile, 'date_of_birth', '1990-05-06'),
    'coverage_option', 1, 'sales_choice', 'sourced', 'channels', jsonb_build_object('email', false, 'text', false), 'notify', false)) $$;
create function test.plc_ready(p text) returns void language plpgsql as $$
declare v_driver uuid := (select bd.driver_id from booking_drivers bd where bd.booking_id = (test.plcb(p)).id and bd.role = 'renter');
  k text;
begin
  foreach k in array array['licence_front', 'licence_back', 'selfie'] loop
    perform app.register_verification_upload((test.plcb(p)).id, test.plcu(p), k, v_driver, 'renters/plc/' || p || '-' || k || '-' || gen_random_uuid() || '.jpg', repeat('e', 64), 'image/jpeg', null, 'identity');
  end loop;
  perform public.renter_save_details(test.plcu(p), jsonb_build_object('licence_number', 'P1234-12345-12345', 'licence_issuer', 'ON', 'licence_class', 'G',
    'licence_expiry', (now() + interval '3 years')::date), (test.plcb(p)).id);
  perform public.renter_approve_offer((test.plcb(p)).id, (test.plcb(p)).current_offer_version, test.plcu(p));
  perform public.renter_open_agreement((test.plcb(p)).id, test.plcu(p), 'rental-test', repeat('e', 64), 'bookings/plc/' || p || '.pdf');
  perform public.renter_sign_agreement((test.plcb(p)).id, test.plcu(p), 'I agree', repeat('e', 64),
    '[{"code":"tracking_disabling","version":"v","text":"t"},{"code":"identity_verification","version":"v","text":"t"},{"code":"electronic_signature","version":"v","text":"t"},{"code":"card_authorization","version":"v","text":"t"}]'::jsonb, 'Pia Link');
end $$;
create function test.plc_link(p text, p_covers text, p_amount bigint default null) returns uuid language plpgsql as $$
declare v jsonb;
begin
  v := app.door(test.id('plc_cs'), 'aal2', 'ops_do', 'payreq_create', jsonb_build_object('booking', (test.plcb(p)).booking_number, 'kind', 'charge', 'covers', p_covers,
    'amount_cents', p_amount, 'channel', 'text', 'token_sha256', md5(random()::text) || md5(random()::text)));
  perform public.server_payreq_attach((v ->> 'id')::uuid, 'pi_plc_' || (v ->> 'id'));
  return (v ->> 'id')::uuid;
end $$;
create function test.plc_pay(p_req uuid) returns jsonb language sql as $$
  select public.server_payreq_settle(p_req, jsonb_build_object('id', 'pi_plc_' || p_req, 'status', 'succeeded', 'amount', (select amount_cents from payment_requests where id = p_req),
    'charge_id', 'ch_plc', 'customer_id', 'cus_plc', 'method_id', 'pm_plc_' || left(p_req::text, 8),
    'card', jsonb_build_object('brand', 'visa', 'last4', '4242', 'exp_month', 12, 'exp_year', 2030, 'funding', 'credit', 'name', 'Pia Link', 'fingerprint', 'fp_plc'))) $$;

-- ================================================================ CC-10053: approved, signed, Everything open paid by the link
insert into test.plc select 'b1', test.plc_offer('car1', 'pia.link@example.test', '(289) 555-0821', interval '5 days');
select test.plc_ready('b1');
select test.eq('approved and signed: waiting for payment', (test.plcb('b1')).status::text, 'pending_payment');
insert into test.plc select 'q1', jsonb_build_object('id', test.plc_link('b1', 'balance'));
select test.ok('the link is for everything open', (select amount_cents > 0 and covers = 'balance' from payment_requests where id = (test.plcv('q1') ->> 'id')::uuid));
insert into test.plc select 'p1', test.plc_pay((test.plcv('q1') ->> 'id')::uuid);
select test.eq('paid by the link: confirmed', (test.plcb('b1')).status::text, 'confirmed');
select test.eq('the answer says so', test.plcv('p1') #>> '{confirm,status}', 'confirmed');
select test.eq('CarmaCars countersigned the signed agreement', (select s.status from signature_requests s where s.id = (test.plcb('b1')).signature_request_id), 'completed');
select test.eq('the payment counts for the booking total, not later charges',
  (select string_agg(purpose, ',') from payments x join payment_requests q on q.payment_id = x.id where q.id = (test.plcv('q1') ->> 'id')::uuid), 'booking_total');
select test.eq('nothing is open for the rental and the fees', app.booking_part_open((test.plcb('b1')).id, 'rental') + app.booking_part_open((test.plcb('b1')).id, 'fees'), 0::bigint);
select test.ok('nothing counted as a later charge', app.booking_part_open((test.plcb('b1')).id, 'later') = 0);
select test.ok('the history says the booking was paid, not later charges', exists (select 1 from booking_events e where e.booking_id = (test.plcb('b1')).id and e.note like '%for the booking (everything open)%')
  and not exists (select 1 from booking_events e where e.booking_id = (test.plcb('b1')).id and e.note like '%later charges%'));
select test.ok('the renter''s signed copy is queued', exists (select 1 from pdf_jobs j where j.kind = 'renter_signed_copy' and j.ref = (test.plcb('b1')).id));
select test.eq('the card is saved on file', (select (card_on_file_id is not null)::text from test.plcb('b1')), 'true');
select test.eq('one confirmation: the renter''s confirmation message once', (select count(*) from app_events where entity_id = (test.plcb('b1')).id and code = 'renter_booking_confirmed'), 1::bigint);
select test.eq('one confirmed history line', (select count(*) from booking_events where booking_id = (test.plcb('b1')).id and kind = 'confirmed'), 1::bigint);
-- the webhook after the pay page: a repeat, nothing twice
select test.eq('settled again (the webhook): a repeat', test.plc_pay((test.plcv('q1') ->> 'id')::uuid) ->> 'repeat', 'true');
select test.eq('still one payment, one confirmation', (select count(*) from payments x join payment_requests q on q.payment_id = x.id where q.booking_id = (test.plcb('b1')).id)
  || '/' || (select count(*) from booking_events where booking_id = (test.plcb('b1')).id and kind = 'confirmed'), '1/1');
select test.ok('confirming again does nothing', app.confirm_when_paid((test.plcb('b1')).id, test.id('plc_cs')) is null);
select test.ok('the Money tab no longer asks to confirm', not coalesce((app.door(test.id('plc_cs'), 'aal2', 'ops_read', 'booking_money', jsonb_build_object('booking', (test.plcb('b1')).booking_number)) ->> 'can_confirm')::boolean, false));

-- ================================================================ part of the rental first: confirmed only once all is paid
insert into test.plc select 'b2', test.plc_offer('car2', 'pia.two@example.test', '(289) 555-0822', interval '9 days');
select test.plc_ready('b2');
insert into test.plc select 'q2', jsonb_build_object('id', test.plc_link('b2', 'rental', 5000));
select test.plc_pay((test.plcv('q2') ->> 'id')::uuid);
select test.eq('part paid: still waiting for payment', (test.plcb('b2')).status::text, 'pending_payment');
select test.ok('the rest is open', app.booking_part_open((test.plcb('b2')).id, 'rental') > 0);
insert into test.plc select 'q3', jsonb_build_object('id', test.plc_link('b2', 'balance'));
select test.plc_pay((test.plcv('q3') ->> 'id')::uuid);
select test.eq('the rest paid by a second link: confirmed', (test.plcb('b2')).status::text, 'confirmed');
select test.eq('confirmed once', (select count(*) from booking_events where booking_id = (test.plcb('b2')).id and kind = 'confirmed'), 1::bigint);
