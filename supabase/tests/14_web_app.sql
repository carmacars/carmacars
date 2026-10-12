-- 14: what the website needs (migration 0027). Every fixture label starts with "wa" (and "WA" for cars).
select test.suite('14 web app');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_owner('wa_one');
select test.mk_vehicle('WA1', 'wa_one');
select test.mk_vehicle('WA2', 'wa_one', 'self_managed', p_share_bps => 0);
insert into vehicle_listings (vehicle_id, slug, headline, status, home_area)
values (test.id('vehicle:WA1'), 'wa-one-test', 'Test car one', 'published', 'Leslieville'),
       (test.id('vehicle:WA2'), 'wa-two-test', 'Test car two', 'published', 'Midtown');

-- ---------------------------------------------------------------- 1. site facts
set role anon;
select test.eq('facts: the anonymous visitor reads the minimum age from program_settings',
  (public.site_facts() ->> 'min_renter_age')::int, 18);
select test.eq('facts: the notice and the turnaround are the settings of 0025',
  (public.site_facts() ->> 'booking_min_notice_minutes')::int || '/' || (public.site_facts() ->> 'turnaround_buffer_minutes')::int, '120/120');
select test.eq('facts: the weekly rate starts at 7 days, read back from calc_rental_charge',
  (public.site_facts() ->> 'weekly_from_days')::int, 7);
select test.eq('facts: the deposit tiers are the editable table',
  public.site_facts() -> 'deposit_tiers_cents', '[50000, 100000, 250000, 500000]'::jsonb);
select test.eq('facts: the kilometre choices, largest first', public.site_facts() -> 'km_choices', '[400, 300, 200, 150]'::jsonb);
select test.eq('facts: the young driver bands are read from the fee codes',
  (select string_agg((b ->> 'from_age') || '-' || (b ->> 'to_age'), ',') from jsonb_array_elements(public.site_facts() -> 'young_driver_bands') b),
  '18-20,21-25');
select test.eq('facts: the fee table carries the default amounts (young driver 18 to 20)',
  (public.site_facts() #>> '{fees,young_driver_18_20,amount_cents}')::bigint, 3500::bigint);
select test.eq('facts: the additional driver fee is a percentage of the daily rate',
  (public.site_facts() #>> '{fees,additional_driver,percent_bps}')::int, 2500);
select test.ok('facts: internal lines are not in the public fee table',
  not (public.site_facts() -> 'fees' ? 'referral_kickback') and not (public.site_facts() -> 'fees' ? 'staff_discount'));
select test.eq('facts: the cancellation tiers are read back from calc_refund_bps (renter billing section 4)',
  public.site_facts() -> 'cancellation',
  '{"grace_hours": 24, "grace_bps": 9500, "early_hours": 48, "early_bps": 7500, "late_hours": 24, "mid_bps": 5000, "late_bps": 0}'::jsonb);
select test.eq('facts: the receiving aliases are public, keyed by desk',
  public.site_facts() #>> '{email_aliases,bookings}', 'bookings@carmacars.ca');
select test.ok('facts: the payload holds neither the numbered company name nor "Canada Inc"',
  public.site_facts()::text !~* '18122211|canada inc');
reset role;

-- ---------------------------------------------------------------- 2. handover places
set role anon;
select test.eq('places: a managed car without an Owner address is not handed over at the Owner''s location',
  (public.handover_places(test.id('vehicle:WA1')) ->> 'owner_location')::boolean, false);
select test.eq('places: a Self-Managed car is, and the page sees the neighbourhood only',
  public.handover_places(test.id('vehicle:WA2')) - 'vehicle_id', '{"owner_location": true, "area": "Midtown", "delivery": true}'::jsonb);
select test.ok('places: a car that is not listed returns nothing', public.handover_places(gen_random_uuid()) is null);
reset role;
update vehicles set owner_pickup_address = '1 Test Street, Toronto' where id = test.id('vehicle:WA1');
set role anon;
select test.ok('places: an Owner address opens the Owner''s location, without the address',
  (public.handover_places(test.id('vehicle:WA1')) ->> 'owner_location')::boolean
  and public.handover_places(test.id('vehicle:WA1'))::text not like '%Test Street%');
reset role;

-- ---------------------------------------------------------------- 3 and 4. server only
set role anon;
select test.throws('server only: the anonymous role cannot save a form draft',
  $$select public.save_form_draft('booking_request', '{}'::jsonb)$$, 'permission denied');
select test.throws('server only: the anonymous role cannot register an account',
  $$select public.register_account(gen_random_uuid(), 'x@example.test', 'X')$$, 'permission denied');
select test.throws('server only: the anonymous role cannot read where delivery is measured from',
  $$select public.delivery_origin()$$, 'permission denied');
reset role;
set role authenticated;
select test.throws('server only: a signed-in session cannot load a draft by token',
  $$select public.load_form_draft('booking_request', null, 'abc')$$, 'permission denied');
reset role;

set role service_role;
create temp table wa_draft as select public.save_form_draft('booking_request', '{"step": "trip", "licence_number": "X123"}'::jsonb, 'trip') d;
select test.ok('drafts: the server saves a visitor draft and gets a resume token', (select d ->> 'token' from wa_draft) is not null);
select test.eq('drafts: the token loads it back, without the licence number',
  (select public.load_form_draft('booking_request', null, (select d ->> 'token' from wa_draft)) #>> '{data,step}'), 'trip');
select test.ok('drafts: a licence number is removed on write',
  (select public.load_form_draft('booking_request', null, (select d ->> 'token' from wa_draft)) -> 'data' ? 'licence_number') is not true);
select test.ok('origin: no coordinates until an Admin sets them', public.delivery_origin() is null);
select test.eq('accounts: a new sign-in account gets its users row and the renter role',
  public.register_account(test.id('wa_new_login'), 'WA.New@Example.test', 'Wa New') ->> 'created', 'true');
select test.eq('accounts: a second call changes nothing',
  public.register_account(test.id('wa_new_login'), 'wa.new@example.test', 'Wa New') ->> 'created', 'false');
select test.eq('accounts: an email already on record from a request is not taken over by another account',
  public.register_account(gen_random_uuid(), 'wa.new@example.test', 'Someone') ->> 'error', 'email_on_record');
reset role;
select test.eq('accounts: the users row carries the sign-in id and the email in lower case',
  (select email from users where id = test.id('wa_new_login')), 'wa.new@example.test');
select test.ok('accounts: the renter role is granted',
  exists (select 1 from user_roles where user_id = test.id('wa_new_login') and role = 'renter'));
