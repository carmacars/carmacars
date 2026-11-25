-- 99_r50_bug_reports: BR-4 (a masked number is found by its record, or by the people it masks to) and BR-3 (staff
-- approving by phone accept the current charges) (4700). Fixtures start with "br50".
select test.suite('99 r50 bug reports');
select test.mk_user('br50_admin', 'admin');
select test.mk_user('br50_sales', 'va', 'sales');
select test.mk_owner('br50_own');
select test.mk_vehicle('BR50V', 'br50_own');
select test.mk_renter('br50_ren');
update renters set mobile = '(647) 555-0311', legal_name = 'Br Fifty' where id = test.id('renter:br50_ren');
select test.mk_booking('BR50-1', 'BR50V', 'br50_ren', to_char(now() + interval '20 days', 'YYYY-MM-DD HH24:MI'), to_char(now() + interval '23 days', 'YYYY-MM-DD HH24:MI'), 'requested');
update payments set status = 'cancelled' where booking_id = test.id('booking:BR50-1');
select app.send_offer(test.id('booking:BR50-1'), test.id('br50_admin'), null, now() + interval '2 days');
update booking_line_items set amount_cents = amount_cents + 1000
 where id = (select id from booking_line_items where booking_id = test.id('booking:BR50-1') and stage = 'booking' and charged_to_renter and voided_at is null limit 1);
select test.throws('BR-3: the renter alone is shown the new charges first',
  $$select app.approve_offer(test.id('booking:BR50-1'), 1, test.id('br50_ren'))$$, '%charges%');
select app.admin_do(test.id('br50_admin'), 'approve_offer_by_phone', jsonb_build_object('booking', test.id('booking:BR50-1')));
select test.eq('BR-3: staff on the phone accept the booking as it stands',
  (select status::text || '/' || offer_approved_version::text from bookings where booking_number = 'BR50-1'), 'pending_payment/2');

insert into leads (id, name, phone, kind) values (test.id('lead:br50a'), null, '647-555-0322', 'contact'), (test.id('lead:br50b'), 'Other', '647-555-0422', 'contact');
select test.eq('BR-4: the lead the button sits on', app.server_phone_unmask(test.id('br50_sales'), jsonb_build_object('masked', '(647) •••-••22', 'lead', test.id('lead:br50a'))), '+16475550322');
select test.eq('BR-4: the booking the button sits on', app.server_phone_unmask(test.id('br50_sales'), '{"masked": "(647) •••-••11", "booking": "BR50-1"}'), '+16475550311');
select test.eq('BR-4: shared digits, the name decides', app.server_phone_unmask(test.id('br50_sales'), '{"masked": "(647) •••-••22", "name": "other"}'), '+16475550422');
select test.throws('BR-4: shared digits and nothing to choose by: refused', format($$select app.server_phone_unmask(%L, '{"masked": "(647) •••-••22"}')$$, test.id('br50_sales')), '%Open the record again%');
