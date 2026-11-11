-- r35 gaps, item 5 (owner): sending an offer again, or editing it without touching a price, keeps the price exactly as it was
-- (rental charge, discounts, deposit, HST, total, every charge line). Fixtures start with "g5".
select test.suite('99 r35g offer resend keeps its price');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_user('g5_admin', 'admin');
select test.mk_user('g5_cs', 'va', 'cs');
select test.mk_owner('g5_o');
select test.mk_vehicle('G5V', 'g5_o');
select test.mk_renter('g5_r');
select test.mk_booking('G5-1', 'G5V', 'g5_r', to_char(app.today() + 10, 'YYYY-MM-DD') || ' 10:00', to_char(app.today() + 13, 'YYYY-MM-DD') || ' 10:00', 'requested', 30000);
update bookings set requested_at = now() - interval '1 hour' where booking_number = 'G5-1';
create function test.g5_offer(p_v integer) returns text language sql stable as $$
  select concat_ws('|', rental_charge_cents, discount_cents, deposit_cents, subtotal_cents, hst_cents, total_cents, renter_due_cents, billable_days, line_items::text)
    from booking_offers where booking_id = test.id('booking:G5-1') and version = p_v $$;

select test.eq('send: version 1 goes out', (app.door(test.id('g5_cs'), 'aal2', 'va_do', 'send_offer', jsonb_build_object('booking', test.id('booking:G5-1'), 'sales_choice', 'for_carmacars')) ->> 'version'), '1');
select test.ok('the offer carries a price', (select total_cents > 0 from booking_offers where booking_id = test.id('booking:G5-1') and version = 1));
select test.eq('resend: version 2', (app.door(test.id('g5_admin'), 'aal2', 'admin_do', 'resend_offer', jsonb_build_object('booking', test.id('booking:G5-1'), 'expected_version', 1, 'expires_at', now() + interval '2 days')) ->> 'version'), '2');
select test.eq('resend: the price is exactly the same', test.g5_offer(2), test.g5_offer(1));
select test.eq('edit with no change, sent again: version 3', (app.door(test.id('g5_admin'), 'aal2', 'ops_do', 'offer_revise', jsonb_build_object('booking', test.id('booking:G5-1'), 'changes', '{}'::jsonb, 'send', true, 'expected_version', 2)) ->> 'version'), '3');
select test.eq('edit: the price is still exactly the same', test.g5_offer(3), test.g5_offer(1));
select test.eq('only the latest version is live', (select string_agg(version || ':' || status, ' ' order by version) from booking_offers where booking_id = test.id('booking:G5-1')), '1:withdrawn 2:superseded 3:sent');
