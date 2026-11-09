-- 99: Sales gets a renter ready (1106) and the office reads the Prepare checklist (1107). docs/changes/2026-11-09-r35-ux-batch.md.
-- Fixtures start with "ux".
select test.suite('99 r35 ux: sales get-ready, prepare progress');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_user('ux_admin', 'admin');
select test.mk_user('ux_sales', 'va', 'sales');
select test.mk_user('ux_cs', 'va', 'cs');
select test.mk_user('ux_fleet', 'va', 'fleet');
select test.mk_user('ux_fin', 'va', 'finance');
select test.mk_user('ux_field', 'field', null, 'driver');
select test.mk_owner('ux_o');
select test.mk_vehicle('UXA', 'ux_o');
select test.mk_vehicle('UXB', 'ux_o');
select test.mk_vehicle('UXC', 'ux_o');
select test.mk_renter('ux_r');
create function test.ux_day(p_days integer) returns text language sql stable as $$
  select to_char((now() at time zone 'America/Toronto')::date + p_days, 'YYYY-MM-DD') || ' 10:00' $$;
create function test.uxb(p text) returns uuid language sql stable as $$ select test.id('booking:' || p) $$;
create function test.ux_try(p_user text, p_call text, p_name text, p jsonb) returns text language plpgsql as $$
begin
  perform app.door(test.id(p_user), 'aal2', p_call, p_name, p);
  return 'ok';
exception when others then return sqlerrm;
end $$;

-- UX-1 confirmed (not handed over), UX-2 waiting for payment, UX-3 on rent
select test.mk_booking('UX-1', 'UXA', 'ux_r', test.ux_day(5), test.ux_day(7), 'confirmed');
select test.mk_booking('UX-2', 'UXB', 'ux_r', test.ux_day(6), test.ux_day(8), 'pending_payment');
select test.mk_booking('UX-3', 'UXC', 'ux_r', test.ux_day(-1), test.ux_day(2), 'on_rent');
update bookings set handed_over_at = now() - interval '1 day' where id = test.uxb('UX-3');
update bookings set coverage_option = 1 where id = test.uxb('UX-1');
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_expiry, age_at_pickup, age_band)
select test.uxb(n), test.id('driver:ux_r'), 'renter', 'Ux R', date '1990-05-05', 'L1', 'G', date '2031-01-01', 36, '26_plus' from unnest(array['UX-1', 'UX-2', 'UX-3']) n;
select app.register_verification_upload(test.uxb('UX-1'), test.id('ux_cs'), 'coverage_proof', null, 'renters/ux/p1.pdf', md5('ux-p1'), 'application/pdf',
  jsonb_build_object('coverage_option', 1, 'insurer_name', 'Maple Mutual', 'policy_number', 'MM-9', 'policy_expiry', app.today() + 60));
select app.register_verification_upload(test.uxb('UX-1'), test.id('ux_cs'), 'licence_front', test.id('driver:ux_r'), 'renters/ux/l1.jpg', md5('ux-l1'), 'image/jpeg', null, 'identity');
create function test.uxup(p_kind text) returns uuid language sql stable as $$ select id from verification_uploads where booking_id = test.uxb('UX-1') and kind = p_kind $$;

-- ================================================================ 1. the rule
select test.eq('the get-ready calls and their stages: offers while waiting for payment, ID and reads until the handover, nothing that refunds (a request keeps Sales'' own claim rules)',
  coalesce(array_to_string(app.sales_ready_stages('va_do', 'resend_offer'), ','), '-') || '|' || coalesce(array_to_string(app.sales_ready_stages('ops_do', 'doc_review_upload'), ','), '-')
  || '|' || coalesce(array_to_string(app.sales_ready_stages('va_do', 'cancel_booking'), ','), '-') || '|' || coalesce(array_to_string(app.sales_ready_stages('va_do', 'request_refund'), ','), '-')
  || '|' || coalesce(array_to_string(app.sales_ready_stages('ops_do', 'hold_action_begin'), ','), '-'),
  'pending_payment,tentative|pending_payment,tentative,confirmed|-|-|-');

-- ================================================================ 2. Sales opens a booking past the offer
select test.eq('Sales reads a confirmed booking (before 1106: requests and offers only), its conversation and its activity',
  test.ux_try('ux_sales', 'va_read', 'booking', '{"number": "UX-1", "_va": "sales"}') || '/' || test.ux_try('ux_sales', 'ops_read', 'booking_conversation', '{"booking": "UX-1", "_va": "sales"}')
  || '/' || test.ux_try('ux_sales', 'ops_read', 'renter_activity', '{"booking": "UX-1", "_va": "sales"}'), 'ok/ok/ok');
select test.eq('the booking as Sales reads it: payments (no processor ids), no refunds, statements or emails',
  (select (x ? 'payments') || '/' || (x ? 'refunds') || '/' || (x ? 'statements') || '/' || (x ? 'emails') || '/' || (x ->> 'va_function')
     from app.door(test.id('ux_sales'), 'aal2', 'va_read', 'booking', '{"number": "UX-1", "_va": "sales"}') x), 'true/false/false/false/sales');
select test.eq('not once the car is out (handed over)', test.ux_try('ux_sales', 'va_read', 'booking', '{"number": "UX-3", "_va": "sales"}'), 'Sales works on requests and offers only');
select test.eq('the flags are cleared after the call', coalesce(current_setting('app.sales_as_cs', true), '') || coalesce(current_setting('app.field_as_cs', true), ''), '');

-- ================================================================ 3. offers while the renter pays
select test.eq('Sales saves the offer while it waits for payment', test.ux_try('ux_sales', 'va_do', 'booking_save', '{"booking": "UX-2", "_va": "sales"}'), 'ok');
select test.ok('Sales may not save a confirmed booking (a change after confirmation is customer service''s)',
  test.ux_try('ux_sales', 'va_do', 'booking_save', '{"booking": "UX-1", "_va": "sales"}') <> 'ok');

-- ================================================================ 4. ID and coverage
select test.eq('Sales rejects the proof of coverage with the reason (before 1106: customer service and Admin only)',
  test.ux_try('ux_sales', 'ops_do', 'doc_review_upload', jsonb_build_object('upload', test.uxup('coverage_proof'), 'approve', false, 'reason', 'The policy expired', '_va', 'sales')), 'ok');
select test.eq('the rejection is recorded with the reason and the Sales person as the reviewer',
  (select status || '/' || reject_reason || '/' || (reviewed_by = test.id('ux_sales')) from verification_uploads where id = test.uxup('coverage_proof')), 'rejected/The policy expired/true');
select test.eq('Sales approves the licence on a confirmed booking',
  test.ux_try('ux_sales', 'ops_do', 'doc_review_upload', jsonb_build_object('upload', test.uxup('licence_front'), 'approve', true, '_va', 'sales')), 'ok');
select test.ok('the review is in the audit trail with the Sales person', exists (select 1 from audit_log a where a.entity_table = 'verification_uploads' and a.entity_id = test.uxup('licence_front')::text and a.actor_user_id = test.id('ux_sales')));
select test.eq('Fleet still cannot review coverage', test.ux_try('ux_fleet', 'ops_do', 'doc_review_upload', jsonb_build_object('upload', test.uxup('coverage_proof'), 'approve', true, '_va', 'fleet')),
  'Only an Admin or customer service reviews identity and coverage documents');
select test.eq('field staff cannot either', left(test.ux_try('ux_field', 'ops_do', 'doc_review_upload', jsonb_build_object('upload', test.uxup('coverage_proof'), 'approve', true)), 2) = 'ok', false);

-- ================================================================ 5. nothing that moves money out
select test.ok('Sales cannot cancel a confirmed booking for the renter', test.ux_try('ux_sales', 'va_do', 'cancel_booking', '{"booking": "UX-1", "reason": "renter_request", "_va": "sales"}') <> 'ok');
select test.ok('Sales cannot request a refund', test.ux_try('ux_sales', 'va_do', 'request_refund', '{"booking": "UX-1", "amount_cents": 100, "_va": "sales"}') <> 'ok');
select test.ok('Sales cannot settle or release the deposit', test.ux_try('ux_sales', 'va_do', 'settle_deposit', '{"booking": "UX-1", "_va": "sales"}') <> 'ok');
select test.eq('Sales cannot remove an add-on after booking (a paid one is refunded)', test.ux_try('ux_sales', 'ops_do', 'booking_addon_remove', jsonb_build_object('id', gen_random_uuid(), 'reason', 'x', '_va', 'sales')),
  'Customer service or an Admin removes an add-on after booking (a paid one is refunded)');
select test.ok('customer service is unchanged (reads a confirmed booking as before)', test.ux_try('ux_cs', 'va_read', 'booking', '{"number": "UX-1", "_va": "cs"}') = 'ok');

-- ================================================================ 6. the Prepare checklist, read only for the office (1107)
insert into booking_addons (booking_id, addon_id, name, fee_type_code, quantity, pricing_unit, unit_price_cents, hst_applies, status, added_via)
select test.uxb('UX-1'), a.id, a.name, a.fee_type_code, 2, a.pricing_unit, coalesce(a.price_cents, 0), a.hst_applies, 'confirmed', 'staff' from addons a where a.code = 'booster_seat';
insert into field_jobs (kind, vehicle_id, booking_id, scheduled_at, assigned_to, status, created_by)
values ('delivery', test.id('vehicle:UXA'), test.uxb('UX-1'), now() + interval '5 days', test.id('ux_field'), 'scheduled', test.id('ux_admin'));
select test.eq('Sales, customer service, Fleet, Finance and an Admin read it: the add-on with its quantity, the count, the job and who has it',
  (select string_agg(u || ':' || coalesce((x -> 'items' -> 0 ->> 'quantity') || 'x' || (x ->> 'ticked') || '/' || (x ->> 'total') || ' ' || (x -> 'job' ->> 'kind') || ' ' || (x -> 'job' ->> 'status'), 'null'), ',' order by u)
     from unnest(array['ux_admin', 'ux_cs', 'ux_fin', 'ux_fleet', 'ux_sales']) u, app.door(test.id(u), 'aal2', 'ops_read', 'prepare_progress', '{"booking": "UX-1"}') x),
  'ux_admin:2x0/1 delivery scheduled,ux_cs:2x0/1 delivery scheduled,ux_fin:2x0/1 delivery scheduled,ux_fleet:2x0/1 delivery scheduled,ux_sales:2x0/1 delivery scheduled');
insert into field_addon_ticks (booking_addon_id, booking_id, ticked_by)
select ba.id, ba.booking_id, test.id('ux_field') from booking_addons ba where ba.booking_id = test.uxb('UX-1');
select test.eq('a tick by field staff shows with who ticked it', (select (x ->> 'ticked') || '/' || (x -> 'items' -> 0 ->> 'ticked_by')
  from app.door(test.id('ux_sales'), 'aal2', 'ops_read', 'prepare_progress', '{"booking": "UX-1"}') x), '1/' || (select full_name from users where id = test.id('ux_field')));
select test.eq('from the car: its next rental', (select x ->> 'booking_number' from app.door(test.id('ux_fleet'), 'aal2', 'ops_read', 'prepare_progress', jsonb_build_object('vehicle', test.id('vehicle:UXA'))) x), 'UX-1');
select test.throws('field staff and renters do not read it here', format($$select app.prepare_progress(%L, '{"booking": "UX-1"}')$$, test.id('ux_field')), 'Only an Admin or staff');

-- ================================================================ 7. Sales' own offer tools on an offer (the owner: "edit offers or withdraw them or extend them")
select test.mk_vehicle('UXD', 'ux_o');
select test.mk_booking('UX-4', 'UXD', 'ux_r', test.ux_day(9), test.ux_day(11), 'requested');
select test.eq('Sales send the offer', test.ux_try('ux_sales', 'va_do', 'send_offer', jsonb_build_object('booking', 'UX-4', 'sales_choice', 'for_carmacars', '_va', 'sales')), 'ok');
select test.eq('it is out', (select status::text || '/' || current_offer_version from bookings where id = test.uxb('UX-4')), 'offered/1');
select test.eq('Sales edit the offer in place', test.ux_try('ux_sales', 'ops_do', 'offer_revise', jsonb_build_object('booking', test.uxb('UX-4'), 'changes', '{}'::jsonb, '_va', 'sales')), 'ok');
select test.eq('Sales extend the offer (sent again with a later expiry)', test.ux_try('ux_sales', 'va_do', 'resend_offer', jsonb_build_object('booking', test.uxb('UX-4'),
  'expected_version', (select current_offer_version from bookings where id = test.uxb('UX-4')), 'expires_at', (now() + interval '40 hours')::text, '_va', 'sales')), 'ok');
select test.ok('the new expiry holds', (select offer_expires_at > now() + interval '39 hours' from bookings where id = test.uxb('UX-4')));
select test.eq('Sales withdraw the offer', test.ux_try('ux_sales', 'va_do', 'withdraw_offer', jsonb_build_object('booking', test.uxb('UX-4'),
  'expected_version', (select current_offer_version from bookings where id = test.uxb('UX-4')), '_va', 'sales')), 'ok');
select test.eq('withdrawn: back to a request', (select status::text from bookings where id = test.uxb('UX-4')), 'requested');
