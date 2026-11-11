-- 99: RentalCover quotes and the value cap (migration 1202). The car's value (an Admin's override, else the Canadian Black
-- Book value, else the AI estimate of the value job, else unknown), the cap and the trigger that refuses the Protection Plan on a car at or over it, the checkout
-- quote, a quote recorded with and without the markup, a failure recorded, a quote priced into the checkout quote and
-- into an offer (a price typed by staff wins), the audit columns, Data Health and the Admin's door. Fixtures "hw";
-- example.test only; no real prices.
select test.suite('99 r35h rentalcover');

select test.mk_user('hw_admin', 'admin');
select test.mk_user('hw_cs', 'va', 'cs');
select test.mk_renter('hw_rita');
-- the rule as it ships: a car with no value on file counts as over the cap (helpers.sql turns it off for the older suites)
update program_settings set rentalcover_unknown_value_allowed = false;
select test.eq('the markup as shipped: on, 20%, no fixed amount; quotes allowed when the key is set',
  (select rentalcover_markup_enabled || '/' || rentalcover_markup_pct || '/' || rentalcover_markup_flat_cents || '/' || rentalcover_api_allowed from app.settings()), 'true/20.00/0/true');

create temp table s1202 as select null::text as k, null::jsonb as v limit 0;
grant select on s1202 to public;
create or replace function test.s1202v(p text) returns uuid language sql stable as $$ select (v ->> 'vehicle_id')::uuid from pg_temp.s1202 where k = p $$;
create or replace function test.s1202(p text) returns jsonb language sql stable as $$ select v from pg_temp.s1202 where k = p $$;
do $$
declare i integer := 0; k text;
begin
  foreach k in array array['cheap', 'dear', 'book', 'none', 'bbcar', 'est'] loop
    i := i + 1;
    insert into s1202 select k, app.vehicle_add(test.id('hw_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1HWCXMM00000000' || lpad(i::text, 2, '0'),
      'plate', 'HWC00' || i, 'year', 2024, 'make', 'Kia', 'model', 'K5', 'class', 'standard', 'fuel', 'gasoline', 'body_type', 'sedan',
      'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 60000, 'monthly', 200000, 'deposit', 30000)));
  end loop;
end $$;
update vehicles set replacement_value_cents = 3500000 where id = test.s1202v('cheap');
update vehicles set replacement_value_cents = 5000000 where id = test.s1202v('dear');
insert into vehicle_buyouts (vehicle_id, offered_on, black_book_value_cents) values (test.s1202v('book'), current_date - 30, 4500000);
update vehicles set black_book_value_cents = 6000000, black_book_value_on = current_date where id = test.s1202v('bbcar');
update vehicles set estimated_value_cents = 3000000, estimated_value_source = 'ai: example', estimated_value_at = now() where id = test.s1202v('est');

-- ================================================================ the value and the cap
select test.eq('the value: the replacement value on file', app.vehicle_cover_value(test.s1202v('cheap')) ->> 'value_cents', '3500000');
select test.eq('the value: the car''s Canadian Black Book value, as it is (no x 1.2)', (select (c ->> 'value_cents') || '/' || (c ->> 'source') from app.vehicle_cover_value(test.s1202v('bbcar')) c), '6000000/black_book');
select test.eq('else the last buyout''s Black Book value', (select (c ->> 'value_cents') || '/' || (c ->> 'source') from app.vehicle_cover_value(test.s1202v('book')) c), '4500000/black_book');
select test.eq('else the AI estimate with its source', (select (c ->> 'value_cents') || '/' || (c ->> 'source') || '/' || (c ->> 'estimate_source') from app.vehicle_cover_value(test.s1202v('est')) c), '3000000/estimate/ai: example');
select test.eq('the value: else unknown', app.vehicle_cover_value(test.s1202v('none')) ->> 'source', 'unknown');
select test.eq('the cap is $50,000 by default', (app.settings()).rentalcover_max_vehicle_value_cents, 5000000::bigint);
select test.eq('offered: under the cap (override, buyout Black Book, estimate) yes; at the cap, over it (Black Book) and unknown no',
  app.rentalcover_allowed(test.s1202v('cheap')) || '/' || app.rentalcover_allowed(test.s1202v('book')) || '/' || app.rentalcover_allowed(test.s1202v('est'))
  || '/' || app.rentalcover_allowed(test.s1202v('dear')) || '/' || app.rentalcover_allowed(test.s1202v('bbcar')) || '/' || app.rentalcover_allowed(test.s1202v('none')),
  'true/true/true/false/false/false');
update vehicles set replacement_value_cents = 4000000 where id = test.s1202v('bbcar');
select test.eq('an Admin''s override wins over the Black Book value', app.vehicle_cover_value(test.s1202v('bbcar')) ->> 'source', 'replacement_value');
update vehicles set replacement_value_cents = null where id = test.s1202v('bbcar');
select test.ok('the reason names the other choices', app.rentalcover_check(test.s1202v('dear')) ->> 'reason' like '%OPCF 27%credit card%');

-- the database refuses option 3 on such a car, whatever the path
select test.mk_owner('hw_o');
select test.throws('a booking of a car at the cap cannot take the Protection Plan',
  format($$insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, pickup_at, return_at, billable_days, coverage_option)
           values ('CC-HW0', 'standard', 'requested', %L, %L, now() + interval '20 days', now() + interval '22 days', 2, 3)$$, test.s1202v('dear'), test.id('renter:hw_rita')),
  'The Protection Plan covers up to%');
select test.throws('nor switch to it', format($$select app.request_booking(%L, %L, now() + interval '30 days', now() + interval '32 days', 'standard', null, 'web', %L);
                                                update bookings set coverage_option = 3 where vehicle_id = %L$$,
  test.id('renter:hw_rita'), test.s1202v('none'), test.id('hw_rita'), test.s1202v('none')), 'The Protection Plan is offered only for a car with its value on file%');

-- ================================================================ the checkout quote
select test.eq('checkout, a car over the cap: the plan is not offered, and chosen it is a problem',
  (select (q #>> '{coverage,sold_by_carmacars_available}') || '/' || (select string_agg(x ->> 'code', ',') from jsonb_array_elements(q -> 'problems') x)
     from app.price_quote(test.s1202v('dear'), test.base(3) + interval '21 days', test.base(3) + interval '24 days', '{"coverage_option": 3}') q), 'false/coverage_not_offered');
select test.eq('checkout, a car under the cap: no such problem', (select coalesce((select string_agg(x ->> 'code', ',') from jsonb_array_elements(q -> 'problems') x), '')
     from app.price_quote(test.s1202v('cheap'), test.base(3) + interval '21 days', test.base(3) + interval '24 days', '{"coverage_option": 3}') q), '');

-- ================================================================ asking and recording
insert into s1202 select 'facts', app.rentalcover_facts(jsonb_build_object('coverage_option', 3, 'vehicle_id', test.s1202v('cheap'), 'pickup_at', test.base(3) + interval '21 days', 'return_at', test.base(3) + interval '24 days',
  'renter', jsonb_build_object('full_name', 'Pat Van Example', 'email', 'Pat.HW@example.test', 'date_of_birth', '1990-01-01')));
select test.eq('the facts for the API: first and last name, the email, CA and CA, the dates in Toronto time',
  (select (f ->> 'first_name') || '/' || (f ->> 'last_name') || '/' || (f ->> 'email') || '/' || (f ->> 'country') || (f ->> 'destination_country') || '/' || (f ->> 'from_date')
     from test.s1202('facts') f), 'Pat/Van Example/pat.hw@example.test/CACA/' || to_char((test.base(3) + interval '21 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI:SS'));
select test.eq('the age at pickup', (test.s1202('facts') ->> 'customer_age')::integer, app.age_on(date '1990-01-01', app.local_date(test.base(3) + interval '21 days')));
select test.eq('no fresh quote yet', test.s1202('facts') -> 'cached', 'null'::jsonb);
update program_settings set rentalcover_api_allowed = false;
select test.eq('quotes switched off: our own pricing, nothing to ask', app.rentalcover_facts(jsonb_build_object('coverage_option', 3, 'vehicle_id', test.s1202v('cheap'), 'pickup_at', now() + interval '5 days', 'return_at', now() + interval '6 days')) ->> 'missing', 'own_pricing');
update program_settings set rentalcover_api_allowed = true;
select test.eq('not the Protection Plan: nothing to ask', app.rentalcover_facts(jsonb_build_object('coverage_option', 1, 'vehicle_id', test.s1202v('cheap'), 'pickup_at', now() + interval '5 days', 'return_at', now() + interval '6 days')) ->> 'missing', 'not_the_plan');
select test.eq('a car over the cap: no facts, the reason instead', app.rentalcover_facts(jsonb_build_object('coverage_option', 3, 'vehicle_id', test.s1202v('dear'), 'pickup_at', now() + interval '5 days', 'return_at', now() + interval '6 days')) ->> 'missing', 'not_offered');

insert into s1202 select 'rec', app.rentalcover_record(test.s1202('facts') || jsonb_build_object('status', 'ok', 'reference', 'AB23-456C-INS', 'policy_code', 'EXAMPLE', 'quote_cents', 4321, 'currency', 'CAD',
  'response', jsonb_build_object('Reference', 'AB23-456C-INS', 'TotalAmount', 43.21), 'source', 'checkout'));
select test.eq('recorded: our price is the quote plus 20%', (test.s1202('rec') ->> 'price_cents')::bigint, 5185::bigint);
select test.eq('the raw quote, our price, the request without the email', (select quote_cents || '/' || price_cents || '/' || (request ? 'Email') || '/' || (response ->> 'Reference')
  from rentalcover_quotes where id = (test.s1202('rec') ->> 'id')::uuid), '4321/5185/false/AB23-456C-INS');
select test.eq('the same renter and dates reuse it', (app.rentalcover_facts(jsonb_build_object('coverage_option', 3, 'vehicle_id', test.s1202v('cheap'), 'pickup_at', test.base(3) + interval '21 days', 'return_at', test.base(3) + interval '24 days',
  'renter', jsonb_build_object('full_name', 'Pat Van Example', 'email', 'pat.hw@example.test', 'date_of_birth', '1990-01-01'))) #>> '{cached,id}'), test.s1202('rec') ->> 'id');
update program_settings set rentalcover_markup_enabled = true, rentalcover_markup_pct = 10, rentalcover_markup_flat_cents = 500;
select test.eq('with the markup on: the quote + 10% + $5.00', (app.rentalcover_price(4321) ->> 'price_cents')::bigint, (4321 + 432 + 500)::bigint);
update program_settings set rentalcover_markup_enabled = false;
select test.eq('with the markup off: the quote', (app.rentalcover_price(4321) ->> 'price_cents')::bigint, 4321::bigint);
update program_settings set rentalcover_markup_enabled = true, rentalcover_markup_pct = 20, rentalcover_markup_flat_cents = 0;
insert into s1202 select 'fail', app.rentalcover_record(test.s1202('facts') || jsonb_build_object('status', 'failed', 'error', 'HTTP 503'));
select test.eq('a failure is recorded for the log, with no quote to use',
  (test.s1202('fail') ->> 'id') || '/' || (select status || '/' || error from rentalcover_quotes where id = (test.s1202('fail') ->> 'logged_id')::uuid), null::text);
select test.eq('the failure''s log row', (select status || '/' || error from rentalcover_quotes where id = (test.s1202('fail') ->> 'logged_id')::uuid), 'failed/HTTP 503');

-- ================================================================ the quote prices the checkout and the offer
select test.eq('checkout with the quote: the Protection Plan line is our price, the total follows',
  (select (select (l ->> 'amount_cents') from jsonb_array_elements(q -> 'lines') l where l ->> 'charge_type' = 'coverage_sold') || '/'
          || ((q ->> 'total_due_at_booking_cents')::bigint = (select sum((l ->> 'amount_cents')::bigint + (l ->> 'hst_cents')::bigint) from jsonb_array_elements(q -> 'lines') l)) || '/' || (q #>> '{coverage,priced_in_offer}')
     from app.price_quote(test.s1202v('cheap'), test.base(3) + interval '21 days', test.base(3) + interval '24 days',
            jsonb_build_object('coverage_option', 3, 'rentalcover_quote_id', test.s1202('rec') ->> 'id')) q), '5185/true/false');
select test.eq('a quote for other dates is not used', (select coalesce((select (l ->> 'amount_cents') from jsonb_array_elements(q -> 'lines') l where l ->> 'charge_type' = 'coverage_sold'), 'none')
     from app.price_quote(test.s1202v('cheap'), test.base(3) + interval '21 days', test.base(3) + interval '25 days',
            jsonb_build_object('coverage_option', 3, 'rentalcover_quote_id', test.s1202('rec') ->> 'id')) q) <> '5185', true);

create or replace function test.s1202offer(p jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('vehicle_id', test.s1202v('cheap'), 'pickup_at', test.base(3) + interval '21 days', 'return_at', test.base(3) + interval '24 days',
    'coverage_option', 3, 'source', 'phone', 'notify', false,
    'renter', jsonb_build_object('full_name', 'Pat Van Example', 'email', 'pat.hw@example.test', 'mobile', '4165550111', 'date_of_birth', '1990-01-01'),
    'rentalcover_quote_id', test.s1202('rec') ->> 'id') || p $$;
select test.eq('the offer priced as staff type it (the preview): the Protection Plan at our price',
  (select l ->> 'amount_cents' from jsonb_array_elements(app.staff_offer_preview(test.id('hw_admin'), test.s1202offer()) #> '{booking,lines}') l where l ->> 'charge_type' = 'coverage_sold' and l ->> 'stage' = 'booking'), '5185');
select test.eq('a price staff type for the plan wins over the quote',
  (select l ->> 'amount_cents' from jsonb_array_elements(app.staff_offer_preview(test.id('hw_admin'), test.s1202offer(jsonb_build_object('line_overrides', jsonb_build_object('coverage_sold', 9900), 'fee_reason', 'Agreed'))) #> '{booking,lines}') l
    where l ->> 'charge_type' = 'coverage_sold' and l ->> 'stage' = 'booking'), '9900');
insert into s1202 select 'sent', app.staff_offer_create(test.id('hw_admin'), test.s1202offer());
select test.eq('the offer sent: offered, the plan at our price, the raw quote and our price kept on the booking',
  (select b.status || '/' || b.rentalcover_quote_cents || '/' || b.rentalcover_price_cents || '/' || (b.rentalcover_quote_id::text = test.s1202('rec') ->> 'id')
          || '/' || (select sum(amount_cents) from booking_line_items l where l.booking_id = b.id and l.charge_type = 'coverage_sold' and l.voided_at is null and l.stage = 'booking')
     from bookings b where b.id = (test.s1202('sent') ->> 'booking_id')::uuid), 'offered/4321/5185/true/5185');
select test.eq('the quote row knows its booking', (select booking_id::text from rentalcover_quotes where id = (test.s1202('rec') ->> 'id')::uuid), test.s1202('sent') ->> 'booking_id');
select test.eq('a booking whose price is settled is not repriced from a quote', app.rentalcover_apply((test.s1202('sent') ->> 'booking_id')::uuid, (test.s1202('rec') ->> 'id')::uuid) ->> 'why', 'price_settled');

-- ================================================================ the value job
select test.ok('a car with no Black Book value is due for an estimate; one with a value is not',
  jsonb_array_length(app.car_values_due(1, test.s1202v('none'))) = 1
  and jsonb_array_length(app.car_values_due(1, test.s1202v('bbcar'))) + jsonb_array_length(app.car_values_due(1, test.s1202v('book'))) + jsonb_array_length(app.car_values_due(1, test.s1202v('est'))) = 0);
select test.ok('the cron asks for the job', (app.server_jobs_due() ->> 'car_values')::boolean);
select public.server_car_value_save(test.s1202v('none'), null, 'ai: example', null);
select test.ok('a failed try waits a day', jsonb_array_length(app.car_values_due(1, test.s1202v('none'))) = 0);
select test.eq('staff ask again: due at once', (public.door(test.id('hw_admin'), 'aal2', 'ops_do', 'vehicle_value_refresh', jsonb_build_object('vehicle_id', test.s1202v('none'))) ->> 'queued'), 'true');
select public.server_car_value_save(test.s1202v('none'), 2600000, 'ai: example-model', 'typical listings for this year and model');
select test.eq('the estimate is kept with its source and date, and prices the cap', (select v.estimated_value_cents || '/' || (v.estimated_value_at is not null) || '/' || (v.estimated_value_source like 'ai: example-model%')
  from vehicles v where v.id = test.s1202v('none')) || '/' || app.rentalcover_allowed(test.s1202v('none')), '2600000/true/true/true');
select test.eq('a nonsense estimate is not kept', (public.server_car_value_save(test.s1202v('est'), 50, 'ai: example', null) ->> 'saved'), 'false');
update vehicles set estimated_value_cents = null, estimated_value_at = null, estimated_value_source = null where id = test.s1202v('none');

-- ================================================================ Data Health and the car page
select test.eq('Data Health counts the cars with no value on file (a car with one is not among them)',
  (select (c ->> 'count')::integer from jsonb_array_elements(app.data_health() -> 'checks') c where c ->> 'key' = 'car_value_missing'),
  (select count(*)::integer from vehicles v where not coalesce(v.is_sample, false) and v.status not in ('exited', 'total_loss', 'declined')
      and (app.vehicle_cover_value(v.id) ->> 'value_cents') is null));
select test.ok('the cars with a value are not counted', (app.vehicle_cover_value(test.s1202v('cheap')) ->> 'value_cents') is not null);
select test.ok('Fleet sees it', 'car_value_missing' = any (app.data_health_keys('fleet')));
select test.eq('an Admin sets the value on the car page: the plan is offered',
  (public.door(test.id('hw_admin'), 'aal2', 'admin_do', 'vehicle_cover_value', jsonb_build_object('vehicle_id', test.s1202v('none'), 'replacement_value_cents', 2800000)) #>> '{rentalcover,allowed}'), 'true');
select test.eq('the car page shows the value and the check', (app.admin_vehicle(test.s1202v('none')) #>> '{rentalcover,value_cents}'), '2800000');
select test.throws('only an Admin sets it', format($$select public.door(%L, 'aal2', 'admin_do', 'vehicle_cover_value', %L)$$, test.id('hw_cs'),
  jsonb_build_object('vehicle_id', test.s1202v('none'), 'replacement_value_cents', 100)));
select test.ok('the quotes: no visitor reads them, an Admin only (policy admin_all, select only)', not has_table_privilege('anon', 'rentalcover_quotes', 'select')
  and not has_table_privilege('authenticated', 'rentalcover_quotes', 'insert') and exists (select 1 from pg_policies where tablename = 'rentalcover_quotes' and policyname = 'admin_all'));
select test.ok('the server doors are for the server only', not has_function_privilege('anon', 'public.server_rentalcover_record(jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_rentalcover_apply(text, uuid)', 'execute'));

update program_settings set rentalcover_unknown_value_allowed = true;
