-- 13: the owner's answers (migration 0025). Runs after every other file and reuses their
-- helpers (test.at, test.ba_req of 08). Every fixture label starts with "oa" (and "OA" for cars
-- and booking numbers). One block per decision, in the order of the record
-- docs/changes/0025_owner_answers.md.
select test.suite('13 owner answers');

create or replace function test.at(p_local text) returns timestamptz
language sql immutable as $$ select p_local::timestamp at time zone 'America/Toronto' $$;
create table test.oa_ids (k text primary key, id uuid);
create function test.oa(p_key text) returns uuid language sql stable as $$ select id from test.oa_ids where k = p_key $$;
create function test.oa_put(p_key text, p_id uuid) returns uuid language sql as $$
  insert into test.oa_ids values (p_key, p_id) on conflict (k) do update set id = excluded.id returning id
$$;
create function test.oa_bk(p_number text) returns uuid language sql stable as $$ select id from bookings where booking_number = p_number $$;
grant select on test.oa_ids to authenticated, anon;
grant execute on all functions in schema test to authenticated, anon;

select test.mk_user('oa_admin', 'admin');
select test.mk_user('oa_cs', 'va', 'cs');
select test.mk_user('oa_fleet', 'va', 'fleet');
select test.mk_owner('oa_one');
select test.mk_owner('oa_two');
select test.mk_owner('oa_ref', 'OAREF');
select test.mk_vehicle('OA1', 'oa_one');                                   -- managed, Revenue Share 35%
select test.mk_vehicle('OA2', 'oa_two', p_share_bps => 2000);             -- managed, 20%
select test.mk_vehicle('OA3', 'oa_two', 'self_managed', p_share_bps => 0); -- Self-Managed
select test.mk_renter('oa_rita');
select test.mk_renter('oa_kim');

-- =====================================================================================
-- 1. Vehicle swap: revenue follows the car
-- =====================================================================================
-- Monday 7 to Friday 11 February 2033, 4 days at $100, referred by an Owner (first rental):
-- the car is swapped on Wednesday at 13:00 (2 whole days done), so 2 days on OA1, 2 on OA2.
select test.mk_booking('OA-S1', 'OA1', 'oa_kim', '2033-02-07 10:00', '2033-02-11 10:00', 'closed', 40000, p_referred_by => 'OAREF');
insert into booking_vehicle_swaps (booking_id, from_vehicle_id, to_vehicle_id, swapped_at, reason)
values (test.oa_bk('OA-S1'), test.id('vehicle:OA1'), test.id('vehicle:OA2'), test.at('2033-02-09 13:00'), 'breakdown');
update bookings set vehicle_id = test.id('vehicle:OA2') where id = test.oa_bk('OA-S1');
select test.mk_line('OA-S1', 'mileage_overage', 3500);          -- no odometer readings: the last car
select test.mk_line('OA-S1', 'late_return_extra_days', 10000);  -- arises on the car returned late
select app.compute_booking_split(test.oa_bk('OA-S1'));

select test.eq('1 the swap keeps the replacement car''s Owner, mode and Revenue Share',
  (select (to_owner_id = test.id('owner:oa_two')) || '/' || to_management_mode || '/' || to_company_share_bps from booking_vehicle_swaps
    where booking_id = test.oa_bk('OA-S1')), 'true/managed/2000');
select test.eq('1 two segments by time; the day of the swap counts for the new car: 2 days on OA1, 2 on OA2',
  (select string_agg(s.seq || ':' || v.fleet_number || ':' || s.days || ':' || s.company_share_bps, ' ' order by s.seq)
     from app.booking_segments(test.oa_bk('OA-S1')) s join vehicles v on v.id = s.vehicle_id), '1:F-OA1:2:3500 2:F-OA2:2:2000');
-- kickback 20% of the whole rental charge ($500) = $100, shared $40 / $60 with the rental charge
-- OA1: $200 - $40 = $160, 35% = $56, payout $104
-- OA2: $200 + $100 late days + $35 mileage - $60 = $275, 20% = $55, payout $220
select test.eq('1 the split pays each Owner for the part on their car, with that car''s Revenue Share',
  (select string_agg(v.fleet_number || ':' || s.rental_charge_cents || '/' || s.mileage_overage_cents || '/' || s.kickback_cents || '/'
                     || s.owner_revenue_cents || '/' || s.company_share_cents || '/' || s.owner_payout_cents || '/' || s.segment_days, ' ' order by v.fleet_number)
     from booking_splits s join vehicles v on v.id = s.vehicle_id where s.booking_id = test.oa_bk('OA-S1')),
  'F-OA1:20000/0/4000/16000/5600/10400/2 F-OA2:30000/3500/6000/27500/5500/22000/2');
select test.eq('1 the parts add up to the booking: rental charge and late days $500, mileage $35',
  (select sum(rental_charge_cents) || '/' || sum(mileage_overage_cents) || '/' || sum(kickback_cents) from booking_splits where booking_id = test.oa_bk('OA-S1')),
  '50000/3500/10000');
select test.eq('1 the kickback is one record on the whole rental charge',
  (select count(*) || '/' || min(base_cents) || '/' || min(amount_cents) || '/' || min(status) from referral_kickbacks where booking_id = test.oa_bk('OA-S1')),
  '1/50000/10000/earned');
select test.eq('1 computing again changes nothing',
  (select app.compute_booking_split(test.oa_bk('OA-S1'))::text || (select string_agg(owner_payout_cents::text, '/' order by owner_payout_cents) from booking_splits where booking_id = test.oa_bk('OA-S1'))),
  '10400/22000');

select test.oa_put('st:one', app.build_owner_statement(test.id('owner:oa_one'), date '2033-02-01'));
select test.oa_put('st:two', app.build_owner_statement(test.id('owner:oa_two'), date '2033-02-01'));
select test.oa_put('st:ref', app.build_owner_statement(test.id('owner:oa_ref'), date '2033-02-01'));
select test.eq('1 each Owner''s statement carries their own part, on their own car, from the segment''s start',
  (select v.fleet_number || ':' || l.amount_cents || ':' || l.starts_on || ':' || l.ends_on from owner_statement_lines l join vehicles v on v.id = l.vehicle_id
    where l.owner_statement_id = test.oa('st:one') and l.line_type = 'rental')
  || ' ' || (select v.fleet_number || ':' || l.amount_cents || ':' || l.starts_on || ':' || l.ends_on from owner_statement_lines l join vehicles v on v.id = l.vehicle_id
    where l.owner_statement_id = test.oa('st:two') and l.line_type = 'rental'),
  'F-OA1:10400:2033-02-07:2033-02-11 F-OA2:22000:2033-02-09:2033-02-11');
select test.eq('1 the referring Owner earns the kickback once',
  (select count(*) || '/' || sum(amount_cents) from owner_statement_lines where owner_statement_id = test.oa('st:ref') and line_type = 'kickback_earned'), '1/10000');
select app.approve_owner_statement(test.oa('st:one'), test.id('oa_admin'));
select test.eq('1 approving one Owner''s statement marks only their part as paid out',
  (select string_agg(v.fleet_number || ':' || (s.owner_statement_id is not null), ' ' order by v.fleet_number)
     from booking_splits s join vehicles v on v.id = s.vehicle_id where s.booking_id = test.oa_bk('OA-S1')), 'F-OA1:true F-OA2:false');
select test.oa_put('st:two', app.build_owner_statement(test.id('owner:oa_two'), date '2033-02-01'));
select test.eq('1 the second Owner''s statement, rebuilt after that, still carries their part',
  (select sum(amount_cents) from owner_statement_lines where owner_statement_id = test.oa('st:two') and line_type = 'rental' and booking_id = test.oa_bk('OA-S1')), 22000::bigint);
select test.login(test.id('oa_admin'));
select test.eq('1 owner_statement_vehicle_lines shows the booking once per Owner and car',
  (select string_agg(fleet_number || ':' || amount_cents, ' ' order by fleet_number) from owner_statement_vehicle_lines
    where booking_number = 'OA-S1' and line_type = 'rental'), 'F-OA1:10400 F-OA2:22000');
select test.logout();
select test.login(test.id('oa_two'));
select test.eq('1 the Owner of the replacement car sees their part of the booking',
  (select count(*) || '/' || min(owner_payout_cents) from owner_bookings where booking_number = 'OA-S1'), '1/22000');
select test.logout();

select test.oa_put('co', app.build_company_statement(date '2033-02-01'));
select test.eq('1 CarmaCars'' statement: per car, the rental revenue, billable days and Owner payout of each part',
  (select string_agg(l.label || ':' || l.rental_revenue_cents || '/' || l.billable_days || '/' || l.owner_share_out_cents, ' ' order by l.label)
     from company_statement_lines l where l.statement_id = test.oa('co') and l.level = 'vehicle' and l.vehicle_id in (test.id('vehicle:OA1'), test.id('vehicle:OA2'))),
  'F-OA1:20000/2/10400 F-OA2:30000/2/22000');
select test.eq('1 per Owner as well, and the statement reconciles (vehicles, owners, total, splits)',
  (select string_agg(o.legal_name || ':' || l.rental_revenue_cents, ' ' order by o.legal_name) from company_statement_lines l join owners o on o.id = l.owner_id
    where l.statement_id = test.oa('co') and l.level = 'owner' and l.owner_id in (test.id('owner:oa_one'), test.id('owner:oa_two')))
  || ' ' || (select ties_ok::text from company_statements where id = test.oa('co')),
  'Oa One:20000 Oa Two:30000 true');
select test.eq('1 utilization: each car counts the time it was out (Monday 10:00 to Wednesday 13:00, then to Friday 10:00)',
  (select round(rented, 2)::text from app.vehicle_month_days(test.id('vehicle:OA1'), date '2033-02-01'))
  || '/' || (select round(rented, 2)::text from app.vehicle_month_days(test.id('vehicle:OA2'), date '2033-02-01')), '2.13/1.88');
select test.eq('1 a booking that stays on one car is one segment with all its days',
  (select count(*) || ':' || sum(days) from app.booking_segments((select id from bookings where booking_type <> 'owner' and status = 'closed'
     and not exists (select 1 from booking_vehicle_swaps w where w.booking_id = bookings.id) order by booking_number limit 1))) = '1:' ||
  (select billable_days from bookings where booking_type <> 'owner' and status = 'closed'
     and not exists (select 1 from booking_vehicle_swaps w where w.booking_id = bookings.id) order by booking_number limit 1), true);
select test.eq('1 the worked owner month still pays $1,922.25',
  (select payout_cents from owner_statements where statement_number is not null and payout_cents = test.money('1,922.25') limit 1), test.money('1,922.25'));

-- mileage overage by the kilometres driven on each car: line pinned to a car goes to it
select test.mk_booking('OA-S2', 'OA1', 'oa_rita', '2033-03-07 10:00', '2033-03-09 10:00', 'closed', 20000);
insert into booking_vehicle_swaps (booking_id, from_vehicle_id, to_vehicle_id, swapped_at, reason)
values (test.oa_bk('OA-S2'), test.id('vehicle:OA1'), test.id('vehicle:OA2'), test.at('2033-03-08 09:00'), 'flat tire');
select test.oa_put('s2:mil', test.mk_line('OA-S2', 'mileage_overage', 7000));
update booking_line_items set arose_vehicle_id = test.id('vehicle:OA1') where id = test.oa('s2:mil');
select app.compute_booking_split(test.oa_bk('OA-S2'));
select test.eq('1 a swap 23 hours in: the first day is the new car''s; a charge pinned to the car it arose on stays with that car',
  (select string_agg(v.fleet_number || ':' || s.segment_days || ':' || s.rental_charge_cents || ':' || s.mileage_overage_cents, ' ' order by v.fleet_number)
     from booking_splits s join vehicles v on v.id = s.vehicle_id where s.booking_id = test.oa_bk('OA-S2')),
  'F-OA1:0:0:7000 F-OA2:2:20000:0');

-- the change flow and the calendar may move a confirmed booking to another Owner's car
select test.mk_booking('OA-M1', 'OA1', 'oa_rita', '2033-04-04 10:00', '2033-04-06 10:00', 'confirmed');
select test.eq('1 the change preview raises no Owner problem for another Owner''s car',
  (select coalesce((select string_agg(p ->> 'code', ',') from jsonb_array_elements(v -> 'problems') p where p ->> 'code' = 'other_owner_vehicle'), 'none')
     from app.preview_booking_change(test.oa_bk('OA-M1'), jsonb_build_object('vehicle_id', test.id('vehicle:OA2'))) v), 'none');
select test.eq('1 nor does the calendar preview',
  (select coalesce(r ->> 'refusal', 'none') from app.calendar_preview_change(test.oa_bk('OA-M1'), jsonb_build_object('vehicle_id', test.id('vehicle:OA2'))) r), 'none');
update bookings set vehicle_id = test.id('vehicle:OA2') where id = test.oa_bk('OA-M1');
select test.eq('1 moved before pickup, the whole booking is one segment on the new car: its Owner and Revenue Share, the stored rates kept',
  (select (owner_id = test.id('owner:oa_two')) || '/' || company_share_bps || '/' || daily_rate_cents from bookings where id = test.oa_bk('OA-M1'))
  || ' ' || (select string_agg(v.fleet_number || ':' || s.days, ',') from app.booking_segments(test.oa_bk('OA-M1')) s join vehicles v on v.id = s.vehicle_id),
  'true/2000/10000 F-OA2:2');
-- =====================================================================================
-- 2. Expired offers close and go back to staff
-- =====================================================================================
select test.oa_put('x', app.request_booking(test.id('renter:oa_rita'), test.id('vehicle:OA1'), test.at('2033-05-02 10:00'), test.at('2033-05-04 10:00'),
  'standard', null, 'phone', test.id('oa_cs'), null, null, 'collected', 'returned', null, null));
select app.send_offer(test.oa('x'), test.id('oa_cs'), 'Here is your offer', now() + interval '1 hour');
select test.eq('2 the offer expires: one booking', app.expire_offers(now() + interval '2 hours'), 1);
select test.eq('2 the request is closed: booking expired, offer expired, deadline cleared',
  (select b.status || '/' || o.status || '/' || coalesce(b.offer_expires_at::text, 'none') from bookings b join booking_offers o on o.booking_id = b.id
    where b.id = test.oa('x')), 'expired/expired/none');
select test.eq('2 and it goes back to staff: one customer service task from its rule',
  (select count(*) || '/' || min(queue) || '/' || min(status) || '/' || bool_and(due_at is not null) from tasks where booking_id = test.oa('x') and task_type = 'offer_expired'),
  '1/cs/open/true');
select test.eq('2 renter_offer_expired is emitted once; running again expires nothing and emits nothing',
  app.expire_offers(now() + interval '3 hours') || '/' || (select count(*) from app_events where code = 'renter_offer_expired' and entity_id = test.oa('x')), '0/1');
select test.throws('2 only staff reopen', $$select app.reopen_expired_request(test.oa('x'), test.id('oa_rita'))$$, 'Not permitted');
select app.reopen_expired_request(test.oa('x'), test.id('oa_cs'), 'Customer called back');
select test.eq('2 reopened: requested, the history says so, the task is closed',
  (select status::text from bookings where id = test.oa('x'))
  || '/' || (select count(*) from booking_events where booking_id = test.oa('x') and kind = 'reopened' and from_status = 'expired' and to_status = 'requested')
  || '/' || (select count(*) from tasks where booking_id = test.oa('x') and task_type = 'offer_expired' and status in ('open', 'in_progress', 'waiting')),
  'requested/1/0');
select test.eq('2 then the normal offer flow: version 2 is sent', app.send_offer(test.oa('x'), test.id('oa_cs'), 'Still free for you'), 2);
select test.throws('2 a booking that is not expired is not reopened', $$select app.reopen_expired_request(test.oa('x'), test.id('oa_cs'))$$, 'only a request whose offer expired');

-- =====================================================================================
-- 3. Timing
-- =====================================================================================
select test.eq('3 the settings: 2 hours notice, 2-hour turnaround, Deposit 1 hour before pickup, reply target 2 hours; also the defaults of a new dated row',
  (select booking_min_notice_minutes || '/' || turnaround_buffer_minutes || '/' || take_deposit_lead_minutes || '/' || notify_request_waiting_minutes from app.settings())
  || '/' || (select string_agg(column_default, ' ' order by column_name) from information_schema.columns
              where table_name = 'program_settings' and column_name in ('turnaround_buffer_minutes', 'booking_min_notice_minutes', 'take_deposit_lead_minutes')),
  '120/120/60/120/120 60 120');
select test.throws('3 a request inside 2 hours of pickup is refused',
  $$select app.submit_booking_request(test.ba_req('oa-n1', 'oa.notice@example.test', 'BA1', now() + interval '1 hour', now() + interval '1 day'))$$, 'at least 120 minutes');
-- OA-M1 is confirmed on OA2 from 4 April 10:00 to 6 April 10:00
select test.eq('3 two bookings of one car 1 hour apart are refused; 2 hours apart allowed (either side)',
  app.vehicle_is_available(test.id('vehicle:OA2'), test.at('2033-04-06 11:00'), test.at('2033-04-07 11:00')) || '/'
  || app.vehicle_is_available(test.id('vehicle:OA2'), test.at('2033-04-06 12:00'), test.at('2033-04-07 12:00')) || '/'
  || app.vehicle_is_available(test.id('vehicle:OA2'), test.at('2033-04-03 09:00'), test.at('2033-04-04 09:00')) || '/'
  || app.vehicle_is_available(test.id('vehicle:OA2'), test.at('2033-04-03 08:00'), test.at('2033-04-04 08:00')), 'false/true/false/true');
select test.oa_put('t1', app.request_booking(test.id('renter:oa_kim'), test.id('vehicle:OA2'), test.at('2033-04-06 11:00'), test.at('2033-04-07 11:00'),
  'standard', null, 'phone', test.id('oa_cs'), null, null, 'collected', 'returned', null, null));
select test.oa_put('t2', app.request_booking(test.id('renter:oa_kim'), test.id('vehicle:OA2'), test.at('2033-04-06 12:00'), test.at('2033-04-07 12:00'),
  'standard', null, 'phone', test.id('oa_cs'), null, null, 'collected', 'returned', null, null));
select test.throws('3 an offer 1 hour after the other booking is refused', $$select app.send_offer(test.oa('t1'), test.id('oa_cs'))$$);
select test.eq('3 an offer 2 hours after it is sent', app.send_offer(test.oa('t2'), test.id('oa_cs')), 1);
select app.withdraw_offer(test.oa('t2'), test.id('oa_cs'), 'test done');
select test.eq('3 confirmation, calendar moves and extensions check the car under the vehicle lock (0019''s payment lock in finalize_booking; 0025 in the booking trigger)',
  (select prosrc ~ 'vehicle_free_locked' from pg_proc where proname = 'booking_before_write')
  || '/' || (select prosrc ~ 'for no key update' from pg_proc where proname = 'finalize_booking')
  || '/' || (select prosrc ~ 'for no key update' from pg_proc where proname = 'vehicle_free_locked'), 'true/true/true');
select test.eq('3 always open: 2 opening hours from Sunday 03:00 is Sunday 05:00 (2030, before the 2032 hours a 09 test sets)',
  app.add_opening_minutes(test.at('2030-06-02 03:00'), 120) = test.at('2030-06-02 05:00'), true);
set role anon;
select test.eq('3 the site says open 24 hours, handover at any time',
  (select (s ->> 'opening_hours_text') || '/' || (s ->> 'handover_any_time') || '/' || (s -> 'opening_hours' ->> 'always_open') from public.site_settings_public() s),
  'Open 24 hours/true/true');
reset role;

-- =====================================================================================
-- 4. Classes
-- =====================================================================================
select test.eq('4 the class list: the ten asked for and the existing ones',
  (select string_agg(code, ',' order by sort_order, code) from vehicle_classes),
  'economy,standard,premium,luxury,suv,convertible,coupe,sedan,van,pickup,exotic');
select test.eq('4 every car''s existing class became a link', (select count(*) from vehicles v where not app.vehicle_in_classes(v.id, array[v.class::text])), 0::bigint);
select test.eq('4 a car belongs to several classes',
  array_to_string(app.set_vehicle_classes(test.id('vehicle:BA2'), test.id('oa_fleet'), array['sedan', 'convertible']), ','), 'premium,convertible,sedan');
select app.set_vehicle_classes(test.id('vehicle:BA3'), test.id('oa_fleet'), array['premium', 'van']);
select test.throws('4 an unknown class is refused', $$select app.set_vehicle_classes(test.id('vehicle:BA3'), test.id('oa_fleet'), array['spaceship'])$$, 'Unknown class');
select test.throws('4 only Fleet or an Admin sets classes', $$select app.set_vehicle_classes(test.id('vehicle:BA3'), test.id('oa_cs'), array['van'])$$, 'Fleet or an Admin');
select test.eq('4 the search accepts any of several classes',
  (select string_agg(slug, ',' order by slug) from app.search_available(test.at('2034-01-09 09:00'), test.at('2034-01-12 09:00'), '{"classes": ["sedan", "van"]}')
    where slug like 'ba-%'), 'ba-ba2,ba-ba3');
set role anon;
select test.eq('4 the public fleet filters by any of several classes, and the car page lists them',
  (select string_agg(r ->> 'slug', ',' order by r ->> 'slug') from public.fleet('{"classes": ["convertible", "van"]}') r where r ->> 'slug' like 'ba-%')
  || ' ' || (select (public.car_page('ba-ba2') -> 'classes')::text), 'ba-ba2,ba-ba3 ["premium", "convertible", "sedan"]');
select test.eq('4 the public class list', (select jsonb_array_length(public.vehicle_classes())), 11);
reset role;
insert into listing_drafts (id, vehicle_id, source) values (test.id('oa:draft'), test.id('vehicle:BA4'), 'ai');
select test.eq('4 the listing draft may propose classes; only listed ones are kept',
  array_to_string(app.propose_listing_classes(test.id('oa:draft'), array['SUV', 'spaceship']), ','), 'suv');
select test.eq('4 nothing changes until staff approve; then the car has them',
  app.vehicle_in_classes(test.id('vehicle:BA4'), array['suv'])::text || '/'
  || array_to_string(app.review_listing_classes(test.id('oa:draft'), test.id('oa_cs'), true), ','), 'false/premium,suv');

-- =====================================================================================
-- 5 and 6. Deposits and kilometres
-- =====================================================================================
select test.eq('5 6 the choices: Deposit tiers $500, $1,000, $2,500, $5,000 or any amount; 400, 300, 200, 150 km a day',
  (select (c -> 'deposit_tiers')::text || ' ' || (c ->> 'deposit_any_amount') || ' ' || (c -> 'km_allowances')::text from app.rate_card_choices() c),
  '[{"label": "$500", "amount_cents": 50000}, {"label": "$1,000", "amount_cents": 100000}, {"label": "$2,500", "amount_cents": 250000}, {"label": "$5,000", "amount_cents": 500000}] true [400, 300, 200, 150]');
select app.set_vehicle_deposit(test.id('vehicle:BA5'), test.id('oa_admin'), 500000);
select app.set_vehicle_deposit(test.id('vehicle:BA6'), test.id('oa_admin'), 123400);
select test.throws('5 only an Admin sets a car''s Deposit', $$select app.set_vehicle_deposit(test.id('vehicle:BA6'), test.id('oa_cs'), 50000)$$, 'Only an Admin');
update rate_cards set km_allowance_per_day = 400, overage_cents_per_km = 50
 where vehicle_id = test.id('vehicle:BA6') and effective_to is null;
select test.eq('5 6 the Deposit, the daily allowance and the overage rate are the car''s own: $5,000 tier; any amount; 400 km at 50 cents',
  (select (q ->> 'deposit_cents') from app.quote_booking(test.id('vehicle:BA5'), test.at('2034-01-09 09:00'), test.at('2034-01-12 09:00')) q)
  || ' ' || (select (q ->> 'deposit_cents') || '/' || (q ->> 'km_allowance_per_day') || '/' || (q ->> 'overage_cents_per_km') || '/' || (q ->> 'km_allowance_total')
               from app.quote_booking(test.id('vehicle:BA6'), test.at('2034-01-09 09:00'), test.at('2034-01-12 09:00')) q),
  '500000 123400/400/50/1200');

-- =====================================================================================
-- 7. Age: 18 and up with G2 or G; the young driver fee has no maximum
-- =====================================================================================
select test.eq('7 drivers 18 and up, G2 or G; every car takes 18 to 20',
  (select min_renter_age || '/' || array_to_string(accepted_licence_classes, ',') from app.settings())
  || '/' || (select count(*) from vehicles where not allows_18_to_20), '18/G,G2/0');
select test.eq('7 the young driver fee has no maximum: 12 days at $35 is $420, at $20 is $240',
  (select string_agg((l ->> 'charge_type') || '=' || (l ->> 'amount_cents'), ' ' order by l ->> 'charge_type')
     from app.quote_booking(test.id('vehicle:BA1'), test.at('2034-01-09 09:00'), test.at('2034-01-21 09:00'), '{"drivers": [{"age": 19}, {"age": 23}]}') q,
          jsonb_array_elements(q -> 'lines') l where l ->> 'charge_type' like 'young%'),
  'young_driver_18_20=42000 young_driver_21_25=24000');
select test.eq('7 the caps are gone from the defaults', (select count(*) from fee_defaults where fee_type_code like 'young_driver%' and cap_cents is not null), 0::bigint);
insert into vehicle_fee_overrides (vehicle_id, fee_type_code, amount_cents, reason, effective_from)
values (test.id('vehicle:BA9'), 'young_driver_18_20', 2000, 'owner wants young drivers', app.today());
select test.eq('7 the fee is set per car: $20 a day on this car',
  (select (l ->> 'amount_cents') from app.quote_booking(test.id('vehicle:BA9'), test.at('2034-01-09 09:00'), test.at('2034-01-21 09:00'), '{"drivers": [{"age": 19}]}') q,
          jsonb_array_elements(q -> 'lines') l where l ->> 'charge_type' = 'young_driver_18_20'), '24000');
select test.oa_put('y', (app.submit_booking_request(test.ba_req('oa-y1', 'oa.young@example.test', 'BA7', test.at('2034-02-06 09:00'), test.at('2034-02-09 09:00'),
  jsonb_build_object('renter', jsonb_build_object('date_of_birth', '2014-12-01', 'licence_class', 'G2')))) ->> 'booking_id')::uuid);
select app.set_booking_fee_term(test.oa('y'), 'young_driver_18_20', test.id('oa_admin'), 'agreed with the renter', 1500, null, null);
select app.reprice_booking(test.oa('y'));
select test.eq('7 and per booking: a renter of 19 on a G2, at $15 a day for this booking',
  (select string_agg(charge_type || '=' || amount_cents, ' ') from booking_line_items where booking_id = test.oa('y') and charge_type like 'young%' and voided_at is null),
  'young_driver_18_20=4500');

-- =====================================================================================
-- 8. Additional driver: 25% of the daily rate a day, no maximum
-- =====================================================================================
update rate_cards set daily_rate_cents = 12000 where vehicle_id = test.id('vehicle:OA1') and effective_to is null;
select test.eq('8 a $120 car: the additional driver is $30 a day ($90 for 3 days), per driver',
  (select string_agg((l ->> 'amount_cents') || ':' || (l -> 'detail' ->> 'per_day_cents'), ' ')
     from app.quote_booking(test.id('vehicle:OA1'), test.at('2034-01-09 09:00'), test.at('2034-01-12 09:00'), '{"drivers": [{"age": 40}, {"age": 41}]}') q,
          jsonb_array_elements(q -> 'lines') l where l ->> 'charge_type' = 'additional_driver'), '9000:3000');
select test.eq('8 the default is a percentage of the daily rate, with no cap',
  (select coalesce(amount_cents::text, 'none') || '/' || percent_bps || '/' || coalesce(cap_cents::text, 'none') from fee_defaults where fee_type_code = 'additional_driver'),
  'none/2500/none');
select test.eq('8 30 days: no maximum ($900)',
  (select (l ->> 'amount_cents') from app.quote_booking(test.id('vehicle:OA1'), test.at('2034-01-09 09:00'), test.at('2034-02-08 09:00'), '{"drivers": [{"age": 40}, {"age": 41}]}') q,
          jsonb_array_elements(q -> 'lines') l where l ->> 'charge_type' = 'additional_driver'), '90000');
insert into vehicle_fee_overrides (vehicle_id, fee_type_code, percent_bps, reason, effective_from)
values (test.id('vehicle:OA3'), 'additional_driver', 1000, 'owner rate', app.today());
select test.eq('8 per car: 10% of this car''s $100 daily rate is $10 a day',
  (select (l -> 'detail' ->> 'per_day_cents') from app.quote_booking(test.id('vehicle:OA3'), test.at('2034-01-09 09:00'), test.at('2034-01-12 09:00'), '{"drivers": [{"age": 40}, {"age": 41}]}') q,
          jsonb_array_elements(q -> 'lines') l where l ->> 'charge_type' = 'additional_driver'), '1000');
select test.eq('8 the pricer''s percentage basis: amount wins, else a percentage of the daily rate',
  app.fee_per_day('{"amount_cents": 700, "percent_bps": 2500}', 12000) || '/' || app.fee_per_day('{"percent_bps": 2500}', 12000)
  || '/' || coalesce(app.fee_per_day('{}', 12000)::text, 'none'), '700/3000/none');

-- =====================================================================================
-- 9. Coverage sold through CarmaCars
-- =====================================================================================
-- 0079 seeds a default Protection Plan price for every class and age band; this block tests the table without them
create table if not exists test.cov_0079 as select * from coverage_prices where false;
insert into test.cov_0079 select * from coverage_prices where note like 'Default of 0079%';
delete from coverage_prices where note like 'Default of 0079%';
select test.eq('9 with no default price the quote offers it and says it is priced in the offer',
  (select (q -> 'coverage' ->> 'sold_by_carmacars_available') || '/' || (q -> 'coverage' ->> 'price_note') || '/' || jsonb_array_length(q -> 'problems')
     from app.quote_booking(test.id('vehicle:BA3'), test.at('2034-01-09 09:00'), test.at('2034-01-12 09:00'), '{"coverage_option": 3}') q),
  'true/Priced in your offer/0');
insert into coverage_prices (class_code, age_band, amount_cents, per_day) values ('premium', '26_plus', 2500, true);
insert into coverage_prices (vehicle_id, age_band, amount_cents, per_day) values (test.id('vehicle:BA3'), '21_to_25', 4000, true);
select test.eq('9 the default table, for a driver of 19, 23 and 40: none for 18 to 20 here; by car and age band ($40 a day for 21 to 25); by class and age band ($25 for 26 and over)',
  (select string_agg(coalesce((select (l ->> 'amount_cents') from jsonb_array_elements(q -> 'lines') l where l ->> 'charge_type' = 'coverage_sold'), q -> 'coverage' ->> 'price_note'), ' ' order by a)
     from unnest(array[40, 23, 19]) a,
          lateral app.quote_booking(test.id('vehicle:BA3'), test.at('2034-01-09 09:00'), test.at('2034-01-12 09:00'),
                                    jsonb_build_object('coverage_option', 3, 'drivers', jsonb_build_array(jsonb_build_object('age', a)))) q),
  'Priced in your offer 12000 7500');
select test.oa_put('cv', (app.submit_booking_request(test.ba_req('oa-c1', 'oa.cover@example.test', 'BA3', test.at('2034-03-06 09:00'), test.at('2034-03-09 09:00'),
  '{"coverage_option": 3}')) ->> 'booking_id')::uuid);
select test.eq('9 a request takes the default price', (select amount_cents from booking_line_items where booking_id = test.oa('cv') and charge_type = 'coverage_sold' and voided_at is null), 7500::bigint);
-- the 0079 defaults back for the later suites
insert into coverage_prices select * from test.cov_0079 on conflict (id) do nothing;
delete from test.cov_0079;
select test.throws('9 only customer service or an Admin prices it', $$select app.set_coverage_price(test.oa('cv'), test.id('oa_fleet'), 9900)$$, 'Customer service or an Admin');
select test.eq('9 customer service overrides the price on the request: the line follows',
  app.set_coverage_price(test.oa('cv'), test.id('oa_cs'), 9900, 'priced for this renter'), 9900::bigint);
select test.eq('9 kept as a per-booking term (for the whole booking), with who and why',
  (select source || ':' || amount_cents || ':' || (override_by = test.id('oa_cs')) || ':' || override_reason from booking_fee_terms
    where booking_id = test.oa('cv') and fee_type_code = 'coverage_sold'), 'booking:9900:true:priced for this renter');
select app.send_offer(test.oa('cv'), test.id('oa_cs'));
select test.eq('9 the offer carries that price; on an offer it changes only after a withdrawal',
  (select count(*) from booking_offers o, jsonb_array_elements(o.line_items) l where o.booking_id = test.oa('cv') and l ->> 'charge_type' = 'coverage_sold' and (l ->> 'amount_cents')::bigint = 9900)
, '1');
select test.throws('9 not on an open offer', $$select app.set_coverage_price(test.oa('cv'), test.id('oa_cs'), 5000)$$, 'withdraw an offer first');
select test.eq('9 the provider is never named: renters read "Protection Plan" (the legal review, 0053)', (select label from fee_types where code = 'coverage_sold'), 'Protection Plan');

-- =====================================================================================
-- 10. Delivery, airports, places
-- =====================================================================================
update program_settings set company_latitude = 43.645000, company_longitude = -79.380000, delivery_per_km_cents = 150,
       delivery_min_cents = 5000, delivery_max_cents = 25000
 where effective_from = (select effective_from from app.settings());
update airports set surcharge_cents = 2000, distance_km = 25 where code = 'YYZ';
select test.eq('10 delivery: the car''s $75 fee plus $1.50 a km for 20.4 km = $105.60, rounded to $106; capped at $250',
  (app.delivery_fee(test.id('vehicle:BA4'), 'pickup', '{"kind": "delivery", "distance_km": 20.4}') ->> 'fee_cents')
  || '/' || (app.delivery_fee(test.id('vehicle:BA4'), 'pickup', '{"kind": "delivery", "distance_km": 200}') ->> 'fee_cents'), '10600/25000');
select test.eq('10 an airport: its distance and its surcharge: $75 + 25 km x $1.50 = $112.50, $113, + $20 = $133',
  (app.delivery_fee(test.id('vehicle:BA4'), 'return', '{"kind": "airport", "airport_code": "YYZ"}') ->> 'fee_cents'), '13300');
select test.eq('10 our location and the Owner''s location cost nothing',
  (app.delivery_fee(test.id('vehicle:BA4'), 'pickup', '{"kind": "our_location"}') ->> 'fee_cents') || '/'
  || (app.delivery_fee(test.id('vehicle:BA4'), 'pickup', '{"kind": "owner_location"}') ->> 'fee_cents'), '0/0');
set role anon;
select test.eq('10 a distance sent from a browser is not used: the car''s fee, and the quote says a distance is needed',
  (select (l ->> 'amount_cents') || '/' || (l -> 'detail' ->> 'needs_distance') from app.quote_booking(test.id('vehicle:BA4'), test.at('2034-01-09 09:00'), test.at('2034-01-12 09:00'),
      '{"pickup_method": "delivered", "pickup_location": {"kind": "delivery", "distance_km": 3}}') q,
      jsonb_array_elements(q -> 'lines') l where l ->> 'charge_type' = 'delivery'), '7500/true');
reset role;
select test.oa_put('dl', (app.submit_booking_request(test.ba_req('oa-d1', 'oa.deliver@example.test', 'BA4', test.at('2034-04-03 09:00'), test.at('2034-04-06 09:00'),
  jsonb_build_object('pickup_method', 'delivered', 'pickup_place', '1 Front Street West, Toronto', 'return_method', 'picked_up', 'return_place', 'Airport',
                     'pickup_location', jsonb_build_object('kind', 'delivery', 'distance_km', 20.4),
                     'return_location', jsonb_build_object('kind', 'airport', 'airport_code', 'YYZ')))) ->> 'booking_id')::uuid);
select test.eq('10 the booking keeps the address, the distance and the airport, and is priced from them',
  (select pickup_location_kind || '/' || pickup_place || '/' || pickup_distance_km || '/' || return_location_kind || '/' || return_place
          || '/' || (return_airport_id = (select id from airports where code = 'YYZ')) from bookings where id = test.oa('dl'))
  || ' ' || (select string_agg(charge_type || '=' || amount_cents, ' ' order by charge_type) from booking_line_items
              where booking_id = test.oa('dl') and charge_type in ('delivery', 'pickup') and voided_at is null),
  'delivery/1 Front Street West, Toronto/20.4/airport/Toronto Pearson International Airport/true delivery=10600 pickup=13300');
update vehicles set owner_pickup_address = '5 Owner Road, Toronto' where id = test.id('vehicle:OA3');
select test.oa_put('ow', app.request_booking(test.id('renter:oa_kim'), test.id('vehicle:OA3'), test.at('2034-05-01 10:00'), test.at('2034-05-03 10:00'),
  'standard', null, 'phone', test.id('oa_cs'), null, null, 'collected', 'returned', null, null));
select app.set_booking_places(test.oa('ow'), test.id('oa_cs'), '{"pickup_location": {"kind": "owner_location"}, "return_location": {"kind": "owner_location"}}');
select test.eq('10 a Self-Managed car is handed over at its Owner''s address',
  (select pickup_location_kind || '/' || pickup_place || '/' || pickup_method from bookings where id = test.oa('ow')), 'owner_location/5 Owner Road, Toronto/collected');
select test.throws('10 a managed car with no Owner address is not handed over there',
  $$select app.set_booking_places(test.oa('t1'), test.id('oa_cs'), '{"pickup_location": {"kind": "owner_location"}}')$$, 'not handed over at its Owner');

-- =====================================================================================
-- 11. Review requests held for a decision
-- =====================================================================================
select test.mk_booking('OA-R1', 'OA1', 'oa_rita', '2033-06-06 10:00', '2033-06-08 10:00', 'returned', 20000);
select test.mk_line('OA-R1', 'damage_at_cost', 30000);
select test.mk_booking('OA-R2', 'OA1', 'oa_kim', '2033-06-13 10:00', '2033-06-15 10:00', 'returned', 20000);
update bookings set status = 'closed' where id in (test.oa_bk('OA-R1'), test.oa_bk('OA-R2'));
select test.eq('11 a booking with a damage charge closes with a held request and a decision task; a clean one does not',
  (select status || ':' || array_to_string(problems, ',') from review_request_decisions where booking_id = test.oa_bk('OA-R1'))
  || '/' || (select count(*) || ':' || min(queue) from tasks where booking_id = test.oa_bk('OA-R1') and task_type = 'review_request_decision' and status = 'open')
  || '/' || (select count(*) from review_request_decisions where booking_id = test.oa_bk('OA-R2')), 'pending:damage_charge/1:cs/0');
select test.eq('11 the automatic request (the follow-up job''s record) is not written for the problem booking; for the clean one it is',
  test.affected(format($$insert into marketing_sends (code, booking_id, renter_id) values ('renter_review_request', %L, %L)$$, test.oa_bk('OA-R1'), test.id('renter:oa_rita')))
  || '/' || test.affected(format($$insert into marketing_sends (code, booking_id, renter_id) values ('renter_review_request', %L, %L)$$, test.oa_bk('OA-R2'), test.id('renter:oa_kim'))),
  '0/1');
select test.throws('11 only customer service or an Admin decides', $$select app.decide_review_request(test.oa_bk('OA-R1'), test.id('oa_fleet'), true)$$, 'Customer service or an Admin');
create table test.oa_dec as select app.decide_review_request(test.oa_bk('OA-R1'), test.id('oa_cs'), true, 'Resolved well') as r;
select test.eq('11 staff say yes: the review request is sent, once; the task closes',
  (select (r ->> 'sent') from test.oa_dec)
  || '/' || (select count(*) from app_events where code = 'renter_review_request' and entity_id = test.oa_bk('OA-R1'))
  || '/' || (select status from review_request_decisions where booking_id = test.oa_bk('OA-R1'))
  || '/' || (select count(*) from tasks where booking_id = test.oa_bk('OA-R1') and task_type = 'review_request_decision' and status = 'open'), 'true/1/send/0');
select test.mk_booking('OA-R3', 'OA1', 'oa_kim', '2033-06-20 10:00', '2033-06-22 10:00', 'returned', 20000);
select test.mk_line('OA-R3', 'damage_at_cost', 10000);
update bookings set status = 'closed' where id = test.oa_bk('OA-R3');
insert into test.oa_dec select app.decide_review_request(test.oa_bk('OA-R3'), test.id('oa_cs'), false);
select test.eq('11 staff say no: nothing is sent',
  (select string_agg(r ->> 'sent', ',') from test.oa_dec)
  || '/' || (select count(*) from app_events where code = 'renter_review_request' and entity_id = test.oa_bk('OA-R3'))
  || '/' || (select status from review_request_decisions where booking_id = test.oa_bk('OA-R3')), 'true,false/0/skip');
update site_settings set google_place_id = 'ChIJpTvG15DL1IkRd8S0KlBVNTI';
set role anon;
select test.eq('11 the Google place id is a public site setting', (select s ->> 'google_place_id' from public.site_settings_public() s), 'ChIJpTvG15DL1IkRd8S0KlBVNTI');
reset role;

-- =====================================================================================
-- 12. Site settings defaults and reply-to aliases
-- =====================================================================================
set role anon;
select test.eq('12 the public settings: email, phone shown as 289-312-5991, hours, reply promise, listing promise, featured at random, street address shown once entered',
  (select (s ->> 'public_email') || '/' || (s ->> 'owners_email') || '/' || (s ->> 'phone_display') || '/' || (s ->> 'whatsapp_display') || '/' || (s ->> 'roadside_phone_display')
          || '/' || (s ->> 'opening_hours_text') || '/' || (s ->> 'reply_wording') || '/' || (s ->> 'listing_time_promise') || '/' || (s ->> 'featured_mode')
     from public.site_settings_public() s),
  'contact@carmacars.ca/owners@carmacars.ca/289-312-5991/289-312-5991/289-312-5991/Open 24 hours/within 2 hours/1 business day/random');
reset role;
select test.eq('12 the street address is shown publicly once entered', (select show_street_address from site_settings), true);
select test.eq('12 as the migration left them (later files edit some): +12893125991 for phone, WhatsApp and roadside; Instagram and TikTok profile addresses; airport delivery offered',
  (select count(*) > 0 from audit_log where entity_table = 'site_settings' and after ->> 'phone' = '+12893125991' and after ->> 'whatsapp' = '+12893125991'
     and after ->> 'roadside_phone' = '+12893125991' and after -> 'social_links' ->> 'instagram' = 'https://instagram.com/carmacars.ca'
     and after -> 'social_links' ->> 'tiktok' = 'https://tiktok.com/@carmacars.ca' and (after ->> 'airport_delivery')::boolean), true);
set role anon;
select test.eq('12 the public settings never carry the legal company name or the numbered corporation',
  (select (s::text ilike '%18122211%') or (s::text ilike '%Canada Inc%') from public.site_settings_public() s), false);
select test.eq('12 featured cars at random: a few published cars on each visit', (select count(*) from public.featured_cars(3)), 3::bigint);
reset role;
update site_settings set mailing_address = null;
select test.eq('12 the mailing address is required before marketing emails go out',
  (select string_agg((p ->> 'field') || ':' || coalesce(p ->> 'blocks', '-'), ' ') from jsonb_array_elements(app.site_setup_problems()) p
    where p ->> 'field' = 'mailing_address'), 'mailing_address:marketing_emails');
update site_settings set mailing_address = 'PO Box 1, Toronto, ON';
select test.eq('12 the six staff aliases, and Blind Spot Car Rental''s for the insurance emails (0187)', (select string_agg(split_part(address, '@', 1), ',' order by address) from email_aliases),
  'billing,blindspotcarrental,bookings,contact,investors,owners,privacy');
select test.eq('12 reply-to per audience (money emails to billing), editable in a table',
  app.email_reply_to_for('renter_booking_confirmed', 'renter') || ' ' || app.email_reply_to_for('owner_new_booking', 'owner') || ' '
  || app.email_reply_to_for('investor_return_paid', 'investor') || ' '
  || app.email_reply_to_for((select code from email_reply_to where code like 'owner%statement%' limit 1), 'owner'),
  'bookings@carmacars.ca owners@carmacars.ca investors@carmacars.ca billing@carmacars.ca');
select test.eq('12 every email queued in these tests carries its reply-to', (select count(*) from notification_outbox where reply_to is null), 0::bigint);

-- =====================================================================================
-- 13. Investors: visible only to the signed-in investor
-- =====================================================================================
select test.mk_user('oa_iva', 'renter');
select test.mk_user('oa_ivo', 'renter');
insert into investors (id, legal_name, investor_type, user_id) values
  (test.id('oa:iva'), 'Iva Investor', 'individual', test.id('oa_iva')), (test.id('oa:ivo'), 'Ivo Investor', 'individual', test.id('oa_ivo'));
insert into documents (id, kind, storage_bucket, storage_path, investor_id) values
  (test.id('oa:doc:iva:c'), 'investment_schedule_c', 'admin', 'oa/iva-c.pdf', test.id('oa:iva')),
  (test.id('oa:doc:iva:d'), 'investment_schedule_d', 'admin', 'oa/iva-d.pdf', test.id('oa:iva')),
  (test.id('oa:doc:ivo:c'), 'investment_schedule_c', 'admin', 'oa/ivo-c.pdf', test.id('oa:ivo')),
  (test.id('oa:doc:ivo:d'), 'investment_schedule_d', 'admin', 'oa/ivo-d.pdf', test.id('oa:ivo'));
insert into investment_agreements (id, investor_id, agreement_number, status, schedule_c_document_id, schedule_d_document_id, exemption_category, legal_advice_choice) values
  (test.id('oa:ag:iva'), test.id('oa:iva'), 'IA-OA-1', 'signed', test.id('oa:doc:iva:c'), test.id('oa:doc:iva:d'), 'accredited_investor', 'obtained'),
  (test.id('oa:ag:ivo'), test.id('oa:ivo'), 'IA-OA-2', 'signed', test.id('oa:doc:ivo:c'), test.id('oa:doc:ivo:d'), 'accredited_investor', 'obtained');
insert into investments (investor_id, agreement_id, principal_cents, yearly_bps, investment_date, lockup_end_date) values
  (test.id('oa:iva'), test.id('oa:ag:iva'), 2000000, 1200, date '2033-01-15', date '2033-07-15'),
  (test.id('oa:ivo'), test.id('oa:ag:ivo'), 3000000, 1500, date '2033-01-15', date '2033-07-15');
set role anon;
select test.eq('13 the anonymous role reaches no investor table',
  test.visible('select 1 from investors') || '/' || test.visible('select 1 from investments') || '/' || test.visible('select 1 from investment_agreements')
  || '/' || test.visible('select 1 from investment_returns'), '-1/-1/-1/-1');
reset role;
select test.login(test.id('oa_rita'));
select test.eq('13 a renter reads no investor record',
  test.visible('select 1 from investors') || '/' || test.visible('select 1 from investments') || '/' || test.visible('select 1 from investment_agreements'), '0/0/0');
select test.logout();
select test.login(test.id('oa_iva'));
select test.eq('13 a signed-in investor reads only their own records and terms',
  (select string_agg(legal_name, ',') from investors) || '/' || (select string_agg(yearly_bps || ':' || principal_cents, ',') from investments)
  || '/' || (select string_agg(agreement_number, ',') from investment_agreements), 'Iva Investor/1200:2000000/IA-OA-1');
select test.logout();
select test.eq('13 no function the public may call reads investment records (the pure return calculator aside)',
  (select coalesce(string_agg(p.proname, ',' order by p.proname), 'none') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('app', 'public') and has_function_privilege('anon', p.oid, 'execute')
      and p.prosrc ~* '(investors|investments|investment_)' ), 'none');
select test.eq('13 the public site content has no investor page', (select jsonb_array_length(public.site_content('investors'))), 0);

-- =====================================================================================
-- 14. Cookie consent
-- =====================================================================================
set role anon;
select test.eq('14 an anonymous visitor accepts all: necessary and analytics',
  (select (r ->> 'ok') || '/' || (r ->> 'analytics') || '/' || (r -> 'consent_codes')::text from public.record_cookie_choice('oa-visitor-0001', 'accept_all', 'cookies-2026-10') r),
  'true/true/["necessary_cookies", "analytics_cookies"]');
select test.eq('14 then changes their mind: necessary only; the latest answer is the one in force',
  (select (r ->> 'analytics') from public.record_cookie_choice('oa-visitor-0001', 'necessary_only', 'cookies-2026-10') r)
  || '/' || (select (c ->> 'choice') || ':' || (c ->> 'wording_version') from public.cookie_choice('oa-visitor-0001') c), 'false/necessary_only:cookies-2026-10');
select test.throws('14 a visitor id must look like one', $$select public.record_cookie_choice('x', 'accept_all', 'cookies-2026-10')$$, 'cookie_consents');
select test.eq('14 the anonymous role cannot read the stored answers', test.visible('select 1 from cookie_consents'), -1::bigint);
reset role;
select test.eq('14 both answers are stored with the visitor id, the choice, the wording version and the time',
  (select string_agg(choice || ':' || analytics || ':' || wording_version || ':' || (recorded_at is not null), ' ' order by recorded_at, id)
     from cookie_consents where visitor_id = 'oa-visitor-0001'), 'accept_all:true:cookies-2026-10:true necessary_only:false:cookies-2026-10:true');
select test.login(test.id('oa_rita'));
select public.record_cookie_choice('oa-visitor-0002', 'custom', 'cookies-2026-10', true);
select test.logout();
select test.eq('14 a signed-in visitor''s analytics consent is also a consent record (consent code analytics_cookies)',
  (select count(*) from consents where user_id = test.id('oa_rita') and consent_code = 'analytics_cookies' and text_version = 'cookies-2026-10')
  || '/' || (select (user_id = test.id('oa_rita'))::text from cookie_consents where visitor_id = 'oa-visitor-0002'), '1/true');

-- =====================================================================================
-- New tables follow the conventions
-- =====================================================================================
select test.eq('every new table has row-level security, admin_all and an audit trigger',
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname in ('vehicle_classes', 'vehicle_class_links', 'deposit_tiers', 'km_allowance_choices', 'coverage_prices',
                                                 'airports', 'email_aliases', 'email_reply_to', 'review_request_decisions', 'cookie_consents')
      and c.relrowsecurity
      and exists (select 1 from pg_policies p where p.tablename = c.relname and p.policyname = 'admin_all')
      and exists (select 1 from pg_trigger g where g.tgrelid = c.oid and g.tgname = 'audit_' || c.relname)), 10::bigint);
select test.eq('state-changing functions of 0025 are not executable from a browser session',
  (select coalesce(string_agg(p.proname, ',' order by p.proname), 'none') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname in ('set_vehicle_classes', 'review_listing_classes', 'propose_listing_classes', 'set_vehicle_deposit',
                                              'apply_booking_places', 'set_booking_places', 'reopen_expired_request', 'decide_review_request',
                                              'compute_booking_split', 'booking_split_parts', 'hold_review_request')
      and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))), 'none');

-- 0026: the catalogue decides the desk unless an admin overrides it
select test.eq('0026 reply-to follows the email catalogue',
  (select app.email_reply_to_for(c.code, c.audience) = c.reply_to from notification_catalogue c
    where c.code = 'renter_account_created'), true);
select test.eq('0026 every catalogue reply-to is an active alias',
  (select count(*) from notification_catalogue c
    where c.reply_to is not null and not exists (select 1 from email_aliases a where a.address = c.reply_to and a.is_active)), 0::bigint);
