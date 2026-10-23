-- 75: a price typed by hand is "plus tax" or "tax included" (migration 0112): the arithmetic (the amount before tax backed
-- out to the cent, the HST what is left), Add a rental, a quote, the review screen before an offer, the offer, the price
-- lines and their names, the emails, Admin, the default (plus tax, as before) and bookings from before 0112 left as they
-- were. Fixtures start with "pt".
select test.suite('75 custom price tax');

select test.mk_user('pt_admin', 'admin');
select test.mk_user('pt_cs', 'va', 'cs');
select test.mk_renter('pt_rita');
update staff_profiles set single_limit_cents = 500000 where user_id = test.id('pt_cs');

create temp table s75 as select null::text as k, null::jsonb as v limit 0;
create or replace function test.s75(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.s75 where k = p_k $$;
create or replace function test.s75b(p_k text) returns bookings language sql stable as $$
  select * from bookings where id = coalesce((test.s75(p_k) ->> 'booking_id')::uuid, (test.s75(p_k) ->> 'id')::uuid) $$;
-- the booking's rental charge line: amount/HST/name
create or replace function test.s75l(p_k text) returns text language sql stable as $$
  select li.amount_cents || '/' || li.hst_cents || '/' || li.description from booking_line_items li
   where li.booking_id = (test.s75b(p_k)).id and li.charge_type = 'rental_charge' and li.stage = 'booking' and li.voided_at is null $$;
do $$
declare i integer;
begin
  for i in 1 .. 6 loop
    insert into s75 select 'car' || i, app.vehicle_add(test.id('pt_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1PTCXMM00000000' || lpad(i::text, 2, '0'),
      'plate', 'PTC00' || i, 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  end loop;
end $$;
create or replace function test.s75v(p text) returns uuid language sql stable as $$ select (test.s75(p) ->> 'vehicle_id')::uuid $$;
create or replace function test.s75r(p_vehicle uuid, p_from interval, p_to interval, p jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('vehicle_id', p_vehicle, 'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_to,
                            'source', 'phone', 'coverage_option', 1, 'renter_id', test.id('renter:pt_rita'), 'sales_choice', 'for_carmacars',
                            'payment', jsonb_build_object('mode', 'link')) || p $$;

-- ================================================================ 1. the arithmetic
select test.eq('HST is 13% (the rate the bookings carry)', (app.settings()).hst_bps, 1300);
select test.eq('tax included, backed out to the cent: $100.00 is $88.50 before tax ($88.4956 rounds up); $113.00 is $100.00; $210.00 is $185.84; 5 cents is 4; 1 cent is 1; 0 is 0',
  app.price_before_tax(10000, 1300) || ' ' || app.price_before_tax(11300, 1300) || ' ' || app.price_before_tax(21000, 1300) || ' ' || app.price_before_tax(5, 1300)
    || ' ' || app.price_before_tax(1, 1300) || ' ' || app.price_before_tax(0, 1300), '8850 10000 18584 4 1 0');
select test.eq('rounding down too: $99.99 is $88.49 ($88.4867), $1,234.56 is $1,092.53 ($1,092.531)',
  app.price_before_tax(9999, 1300) || ' ' || app.price_before_tax(123456, 1300), '8849 109253');
select test.eq('no HST (0 bps): the amount typed is the amount before tax', app.price_before_tax(10000, 0), 10000::bigint);
select test.eq('split, tax included: the HST is what is left, so before tax + HST is exactly the amount typed ($100.00: $88.50 + $11.50, not the $11.51 13% of $88.50 would give)',
  app.price_tax_split(10000, 'included', 1300), '{"tax": "included", "hst_cents": 1150, "with_tax_cents": 10000, "before_tax_cents": 8850}'::jsonb);
select test.eq('split, plus tax: 13% on top ($100.00 + $13.00)',
  app.price_tax_split(10000, 'plus', 1300), '{"tax": "plus", "hst_cents": 1300, "with_tax_cents": 11300, "before_tax_cents": 10000}'::jsonb);
select test.eq('split, every amount from 1 cent to $1,000.00 tax included adds back to the amount typed',
  (select count(*) from generate_series(1, 100000) c where (app.price_tax_split(c, 'included', 1300) ->> 'before_tax_cents')::bigint
                                                         + (app.price_tax_split(c, 'included', 1300) ->> 'hst_cents')::bigint <> c), 0::bigint);
select test.eq('the words: plus tax, or the amount with "tax included"', app.price_tax_label('plus', null) || ' | ' || app.price_tax_label('included', 10000), 'plus tax | $100.00 tax included');
select test.eq('the choice: plus tax by default', app.price_tax_choice('{}') || ' ' || app.price_tax_choice('{"price_tax": ""}') || ' ' || app.price_tax_choice('{"price_tax": "included"}'), 'plus plus included');
select test.throws('the choice: anything else is refused', $$select app.price_tax_choice('{"price_tax": "maybe"}')$$, 'plus tax or tax included');

-- ================================================================ 2. Add a rental
insert into s75 select 'inc', app.door(test.id('pt_cs'), 'aal2', 'ops_do', 'manual_rental_create',
  test.s75r(test.s75v('car1'), interval '3 days', interval '5 days', '{"rental_charge_cents": 21000, "price_reason": "Flat price agreed by phone", "price_tax": "included"}'));
select test.eq('tax included: the choice and the amount typed are kept; the rental charge is the amount before tax',
  (select price_tax || '/' || price_with_tax_cents || '/' || rental_charge_cents from test.s75b('inc')), 'included/21000/18584');
select test.eq('tax included: the rental charge line is $185.84 with $24.16 HST ($210.00 exactly), and says "$210.00 tax included"',
  test.s75l('inc'), '18584/2416/Rental charge ($210.00 tax included)');
select test.eq('tax included: the renter pays exactly the amount typed (no other line on this rental)',
  (select subtotal_at_booking_cents || '/' || hst_at_booking_cents || '/' || total_due_at_booking_cents || '/' || renter_due_at_booking_cents from test.s75b('inc')), '18584/2416/21000/21000');
select test.eq('tax included: the price is compared with the rate sheet before tax (two days $200.00; $185.84 is 7% under, not flagged)',
  (select rate_sheet_rental_cents || '/' || array_to_string(price_flags, ',') from test.s75b('inc')), '20000/');
select test.ok('tax included: the history says so', exists (select 1 from booking_events e where e.booking_id = (test.s75b('inc')).id and e.kind = 'custom_price'
  and e.note like 'Price typed by hand: $210.00 tax included ($185.84 before tax, HST $24.16)%'));
select test.eq('tax included: the call returns the choice', (select (v ->> 'price_tax') || '/' || (v ->> 'price_with_tax_cents') || '/' || (v ->> 'rental_charge_cents') from s75 where k = 'inc'),
  'included/21000/18584');

insert into s75 select 'plus', app.door(test.id('pt_cs'), 'aal2', 'ops_do', 'manual_rental_create',
  test.s75r(test.s75v('car2'), interval '3 days', interval '5 days', '{"rental_charge_cents": 21000, "price_reason": "Flat price agreed by phone", "price_tax": "plus"}'));
select test.eq('plus tax: charged as typed, HST on top, the line says "plus tax"',
  (select price_tax || '/' || coalesce(price_with_tax_cents::text, 'none') || '/' || rental_charge_cents || '/' || total_due_at_booking_cents from test.s75b('plus')) || ' ' || test.s75l('plus'),
  'plus/none/21000/23730 21000/2730/Rental charge (plus tax)');

insert into s75 select 'dflt', app.door(test.id('pt_cs'), 'aal2', 'ops_do', 'manual_rental_create',
  test.s75r(test.s75v('car3'), interval '3 days', interval '5 days', '{"rental_charge_cents": 21000, "price_reason": "Flat price agreed by phone"}'));
select test.eq('no choice sent: plus tax, as before 0112', (select price_tax || '/' || total_due_at_booking_cents from test.s75b('dflt')) || ' ' || test.s75l('dflt'),
  'plus/23730 21000/2730/Rental charge (plus tax)');

insert into s75 select 'rate', app.door(test.id('pt_cs'), 'aal2', 'ops_do', 'manual_rental_create',
  test.s75r(test.s75v('car4'), interval '3 days', interval '5 days', '{"price_tax": "included"}'));
select test.eq('no price typed: the rate sheet, no choice and no words on the line (the choice is ignored)',
  (select coalesce(price_tax, 'none') || '/' || total_due_at_booking_cents from test.s75b('rate')) || ' ' || test.s75l('rate'), 'none/22600 20000/2600/Rental charge (daily, weekend, weekly or monthly rate)');

insert into s75 select 'same', app.door(test.id('pt_cs'), 'aal2', 'ops_do', 'manual_rental_create',
  test.s75r(test.s75v('car5'), interval '3 days', interval '5 days', '{"rental_charge_cents": 20000, "price_reason": "Same as the rate sheet"}'));
select test.eq('plus tax at the rate-sheet price: no price typed by hand, so no words (as before 0112)',
  (select coalesce(price_tax, 'none') || '/' || (custom_price_at is null) from test.s75b('same')) || ' ' || test.s75l('same'), 'none/true 20000/2600/Rental charge (daily, weekend, weekly or monthly rate)');

-- paid another way: the payment covers the booking exactly
insert into s75 select 'paid', app.door(test.id('pt_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.s75r(test.s75v('car6'), interval '10 days', interval '12 days', '{"rental_charge_cents": 9999, "price_reason": "Friends and family", "price_tax": "included",
    "payment": {"mode": "other_way", "method": "cash"}}'));
select test.eq('tax included $99.99 paid in cash: $88.49 + $11.50 HST, the payment $99.99 covers every line',
  (select rental_charge_cents || '/' || hst_at_booking_cents || '/' || renter_due_at_booking_cents from test.s75b('paid')) || '/'
  || (select sum(p.amount_cents) from payments p where p.booking_id = (test.s75b('paid')).id and p.status = 'succeeded') || '/'
  || (select count(*) from booking_line_items li where li.booking_id = (test.s75b('paid')).id and li.stage = 'booking' and li.voided_at is null and li.payment_id is null),
  '8849/1150/9999/9999/0');

-- the check before adding: the split from the database
select test.eq('the check: tax included $210.00 splits into $185.84 and $24.16',
  app.door(test.id('pt_cs'), 'aal2', 'ops_read', 'manual_rental_quote', test.s75r(test.s75v('car4'), interval '20 days', interval '22 days',
    '{"rental_charge_cents": 21000, "price_tax": "included"}')) -> 'price_tax', '{"tax": "included", "hst_cents": 2416, "with_tax_cents": 21000, "before_tax_cents": 18584}'::jsonb);
select test.eq('the check: plus tax by default; nothing typed, no split',
  (app.door(test.id('pt_cs'), 'aal2', 'ops_read', 'manual_rental_quote', test.s75r(test.s75v('car4'), interval '20 days', interval '22 days', '{"rental_charge_cents": 21000}')) #>> '{price_tax,tax}')
  || '/' || coalesce(app.door(test.id('pt_cs'), 'aal2', 'ops_read', 'manual_rental_quote', test.s75r(test.s75v('car4'), interval '20 days', interval '22 days')) ->> 'price_tax', 'none'),
  'plus/none');
select test.throws('a bad choice is refused', format($$select app.door(%L, 'aal2', 'ops_do', 'manual_rental_create', test.s75r(test.s75v('car4'), interval '30 days', interval '32 days',
  '{"rental_charge_cents": 21000, "price_reason": "x", "price_tax": "half"}'))$$, test.id('pt_cs')), 'plus tax or tax included');

-- ================================================================ 3. a quote, the review screen, the offer
insert into s75 select 'q', app.door(test.id('pt_cs'), 'aal2', 'va_do', 'quote_create', jsonb_build_object('vehicle_id', test.s75v('car4'), 'source', 'phone',
  'pickup_at', date_trunc('hour', now()) + interval '40 days', 'return_at', date_trunc('hour', now()) + interval '44 days', 'full_name', 'Paula Taxpayer', 'email', 'pt.paula@example.test',
  'mobile', '4165550175', 'date_of_birth', '1985-03-04', 'sales_choice', 'for_carmacars', 'rental_charge_cents', 34000, 'price_reason', 'Four days, all in', 'price_tax', 'included'));
select test.eq('quote tax included $340.00: a request with $300.88 before tax and $39.12 HST',
  (select status || '/' || price_tax || '/' || rental_charge_cents || '/' || hst_at_booking_cents || '/' || total_due_at_booking_cents from test.s75b('q')) || ' ' || test.s75l('q'),
  'requested/included/30088/3912/34000 30088/3912/Rental charge ($340.00 tax included)');

select app.door(test.id('pt_cs'), 'aal2', 'va_do', 'booking_save', jsonb_build_object('booking', (test.s75b('q')).id,
  'changes', jsonb_build_object('rental_charge_cents', 36000, 'price_reason', 'Four days plus a car seat', 'price_tax', 'plus')));
select test.eq('review screen: the price typed again, plus tax: $360.00 + $46.80',
  (select price_tax || '/' || coalesce(price_with_tax_cents::text, 'none') || '/' || rental_charge_cents || '/' || total_due_at_booking_cents from test.s75b('q')) || ' ' || test.s75l('q'),
  'plus/none/36000/40680 36000/4680/Rental charge (plus tax)');
select app.door(test.id('pt_cs'), 'aal2', 'va_do', 'booking_save', jsonb_build_object('booking', (test.s75b('q')).id,
  'changes', jsonb_build_object('rental_charge_cents', 36000, 'price_reason', 'Four days plus a car seat, all in', 'price_tax', 'included')));
select test.eq('review screen: tax included $360.00: $318.58 + $41.42, the total $360.00',
  (select price_tax || '/' || price_with_tax_cents || '/' || rental_charge_cents || '/' || total_due_at_booking_cents from test.s75b('q')) || ' ' || test.s75l('q'),
  'included/36000/31858/36000 31858/4142/Rental charge ($360.00 tax included)');
select test.ok('the preview shows the same before saving', (select (v -> 'booking' ->> 'total_due_at_booking_cents')::bigint = 34000
  from (select public.admin_read(test.id('pt_admin'), 'booking_preview', jsonb_build_object('booking', (test.s75b('q')).id,
          'changes', jsonb_build_object('rental_charge_cents', 34000, 'price_reason', 'preview', 'price_tax', 'included'))) as v) x));
select test.eq('the preview saved nothing', (select total_due_at_booking_cents from test.s75b('q')), 36000::bigint);
select test.ok('a change of notes keeps the price and its words', (select public.admin_read(test.id('pt_admin'), 'booking_preview', jsonb_build_object('booking', (test.s75b('q')).id,
  'changes', jsonb_build_object('notes', 'call first'))) -> 'booking' ->> 'total_due_at_booking_cents') = '36000');

select app.door(test.id('pt_cs'), 'aal2', 'va_do', 'send_offer', jsonb_build_object('booking', (test.s75b('q')).id, 'expires_at', now() + interval '24 hours'));
select test.eq('the offer: its lines carry the words and the HST, its total is the amount typed',
  (select o.total_cents || '/' || o.hst_cents || '/' || (select l ->> 'description' from jsonb_array_elements(o.line_items) l where l ->> 'charge_type' = 'rental_charge')
     from booking_offers o where o.booking_id = (test.s75b('q')).id and o.status = 'sent'), '36000/4142/Rental charge ($360.00 tax included)');
select test.eq('the email lines: the words next to the price, the HST on its own line',
  app.ntf_lines((test.s75b('q')).id, 'booking'), '[{"label": "Rental charge ($360.00 tax included)", "amount": "$318.58"}, {"label": "HST (13%)", "amount": "$41.42"}]'::jsonb);
select test.eq('the renter''s booking page reads the same line', (select count(*) from booking_line_items li where li.booking_id = (test.s75b('q')).id
  and li.description = 'Rental charge ($360.00 tax included)' and li.voided_at is null), 1::bigint);

-- the dates change: back to the rate sheet, the words go
select app.withdraw_offer((test.s75b('q')).id, test.id('pt_admin'), 'dates change');
select app.door(test.id('pt_cs'), 'aal2', 'va_do', 'booking_save', jsonb_build_object('booking', (test.s75b('q')).id,
  'changes', jsonb_build_object('return_at', date_trunc('hour', now()) + interval '45 days')));
select test.eq('new dates: the rate sheet again (five days $500.00 plus tax), no choice, no words',
  (select coalesce(price_tax, 'none') || '/' || coalesce(price_with_tax_cents::text, 'none') || '/' || (custom_price_at is null) || '/' || total_due_at_booking_cents from test.s75b('q')) || ' ' || test.s75l('q'),
  'none/none/true/56500 50000/6500/Rental charge (daily, weekend, weekly or monthly rate)');

-- ================================================================ 4. Admin
select test.eq('Admin''s booking page: the choice beside the price typed by hand',
  (select (v -> 'price' ->> 'tax') || '/' || (v -> 'price' ->> 'with_tax_cents') || '/' || (v -> 'price' ->> 'rental_cents')
     from (select app.booking_sales_credit(test.id('pt_admin'), jsonb_build_object('booking', (test.s75b('inc')).id)) as v) x), 'included/21000/18584');
select test.eq('Admin''s prices to review: the choice too',
  (select string_agg(p ->> 'tax', ',' order by p ->> 'booking_number') from jsonb_array_elements(app.commission_reviews(test.id('pt_admin')) -> 'prices') p
    where p ->> 'booking_number' in ((test.s75b('inc')).booking_number, (test.s75b('plus')).booking_number)), 'included,plus');
select test.throws('the database refuses a choice without its amount', format($$update bookings set price_tax = 'included' where id = %L$$, (test.s75b('plus')).id), 'price_with_tax');

-- ================================================================ 5. bookings from before 0112
-- a price typed by hand before 0112: no choice stored; a reprice leaves the line and the money as they were
update bookings set price_tax = null where id = (test.s75b('dflt')).id;
update booking_line_items set description = 'Rental charge (daily, weekend, weekly or monthly rate)' where booking_id = (test.s75b('dflt')).id and charge_type = 'rental_charge' and voided_at is null;
select app.sync_booking_price((test.s75b('dflt')).id);
select test.eq('a booking from before 0112: repriced, the same money and the same name',
  (select total_due_at_booking_cents from test.s75b('dflt')) || ' ' || test.s75l('dflt'), '23730 21000/2730/Rental charge (daily, weekend, weekly or monthly rate)');
select test.eq('Admin reads it as plus tax', (select app.booking_sales_credit(test.id('pt_admin'), jsonb_build_object('booking', (test.s75b('dflt')).id)) #>> '{price,tax}'), 'plus');
