-- 38: the owner's decisions of October 19, 2026 (migration 0059): the guides publish every rewrite that passes the
-- checks (an Admin's edits and drafts included), a release's chapters too, and nothing waits for review; the commission
-- settings confirmed as set; staff enter their own home address, needed before they add a rental, mark a quote or an
-- offer "I sourced this client" or earn a commission; Sales is commission only in the staff agreement defaults.
-- Fixtures start with "ga".
select test.suite('38 guides auto, home address, Sales commission only');

select test.mk_user('ga_admin', 'admin');
select test.mk_user('ga_cs', 'va', 'cs');
select test.mk_user('ga_sales', 'va', 'sales');
select test.mk_user('ga_field', 'field', null, null, 'GAFIELD');
select test.mk_renter('ga_rita');
update staff_profiles set single_limit_cents = 500000 where user_id in (test.id('ga_cs'), test.id('ga_sales'));
-- these two have not entered their home address yet (their first sign-in)
update staff_profiles set home_address = null, home_postal_code = null where user_id in (test.id('ga_sales'), test.id('ga_field'));

create temp table s38 as select null::text as k, null::jsonb as v limit 0;
create or replace function test.s38(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.s38 where k = p_k $$;
create or replace function test.s38b(p_k text) returns bookings language sql stable as $$
  select * from bookings where id = coalesce((test.s38(p_k) ->> 'booking_id')::uuid, (test.s38(p_k) ->> 'id')::uuid) $$;
insert into s38 select 'car', app.vehicle_add(test.id('ga_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1GAAXMM0000000001', 'plate', 'GAA001',
  'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
create or replace function test.s38r(p_from interval, p_to interval, p jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('vehicle_id', (test.s38('car') ->> 'vehicle_id')::uuid, 'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_to,
                            'source', 'phone', 'coverage_option', 1, 'renter_id', test.id('renter:ga_rita'), 'payment', jsonb_build_object('mode', 'link')) || p $$;

-- ================================================================ 1. the guides publish themselves
insert into guides (portal, title, signin_url) values ('investor', 'Investor guide', '/investor') on conflict (portal) do nothing;
update guides set version = greatest(version, 1) where portal = 'investor';
insert into guide_sections (id, portal, kind, sort_order, slug, title, body_md, draft_version, published_title, published_md, published_html, published_hidden, published_version, published_at)
values (test.id('gs:ga1'), 'investor', 'chapter', 970, 'ga-edited', 'Ga edited', E'Admin draft not published.\n', 3, 'Ga edited', E'Admin published words.\n', '<p>a</p>', false, 2, now() - interval '1 day');
select test.eq('auto: a rewrite that passes the checks is published over an Admin''s edits and draft',
  public.server_guide_auto_update(jsonb_build_object('section_id', test.id('gs:ga1'), 'run', 'ga-1', 'checks_ok', true, 'reason', 'A screenshot changed',
    'body_md', E'Automatic words now.\n', 'html', '<p>auto</p>')) ->> 'result', 'updated');
select test.eq('auto: the newest automatic version is live, as a version after the draft',
  (select published_md || '|' || body_md || '|' || published_version || '|' || draft_version from guide_sections where id = test.id('gs:ga1')), E'Automatic words now.\n|Automatic words now.\n|4|4');
select test.eq('auto: every version stays in the history (the Admin''s draft, the new text)',
  (select string_agg(version || ':' || published, ',' order by version, published) from guide_section_versions where section_id = test.id('gs:ga1')), '3:false,4:false,4:true');
select test.eq('auto: Revert is offered and brings back the published text it replaced',
  (select (s ->> 'can_revert') from jsonb_array_elements(public.door(test.id('ga_admin'), null, 'ops_read', 'guide_admin', '{"portal": "investor"}') -> 'sections') s where s ->> 'slug' = 'ga-edited'), 'true');
select public.door(test.id('ga_admin'), null, 'ops_do', 'guide_auto_revert', jsonb_build_object('id', test.id('gs:ga1')));
select test.eq('auto: reverted', (select published_md from guide_sections where id = test.id('gs:ga1')), E'Admin published words.\n');
select test.eq('auto: a failed rewrite is kept as nothing: the old text, a log for the next run',
  public.server_guide_auto_update(jsonb_build_object('section_id', test.id('gs:ga1'), 'run', 'ga-2', 'checks_ok', false, 'problems', 'a task heading is missing',
    'body_md', E'Broken words here.\n', 'html', '<p>x</p>')) ->> 'result', 'kept');
select test.eq('auto: nothing to review: no flag, no suggestion, no note',
  (select needs_review::text || '/' || (suggestion_md is null) || '/' || (review_note is null) from guide_sections where id = test.id('gs:ga1')), 'false/true/true');
select test.eq('release: a chapter is published even when an Admin edited it',
  app.guide_release_0059('investor', 'ga-edited', 'chapter', null, E'Some older shipped text.\n', 'Ga edited', null, E'Release words.\n', '<p>release</p>'), 'updated');
select test.eq('release: published, logged clear, Revert offered',
  (select published_md || '|' || (auto_retry_at is null) || '|' || (auto_prev ->> 'published_md') from guide_sections where id = test.id('gs:ga1')),
  E'Release words.\n|true|Admin published words.\n');
select test.throws('the review steps are gone', format($$select public.door(%L, null, 'ops_do', 'guide_review_resolve', jsonb_build_object('id', %L, 'action', 'apply_suggestion'))$$,
  test.id('ga_admin'), test.id('gs:ga1')), 'nothing to review');

-- ================================================================ 2. Program settings, confirmed as set
select test.eq('settings: unchanged (20% discount limit, no floor, 10%, tiers 10/15/20 at 50 and 100 days)',
  (select coalesce(s.custom_price_floor_daily_cents::text, 'none') || '/' || s.custom_price_max_discount_bps || '/' || s.staff_commission_bps || '/' || s.sales_tier_low_bps || '/'
          || s.sales_tier_mid_bps || '/' || s.sales_tier_high_bps || '/' || s.sales_tier_mid_days || '/' || s.sales_tier_high_days from (select (app.settings()).*) s),
  'none/2000/1000/1000/1500/2000/50/100');
select test.ok('settings: the owner''s confirmation is recorded',
  exists (select 1 from audit_log where action = 'owner_confirmed_settings' and after ->> 'on' = '2026-10-19' and (after ->> 'custom_price_max_discount_bps')::integer = 2000));

-- ================================================================ 3. staff enter their own home address
select test.eq('address: a staff member who has not entered it is asked for it',
  public.door(test.id('ga_sales'), 'aal2', 'va_read', 'home_address', '{}') ->> 'missing', 'true');
select test.eq('address: one who has is not', public.door(test.id('ga_cs'), 'aal2', 'va_read', 'home_address', '{}') ->> 'missing', 'false');
select test.eq('address: Admins have no staff profile, so nothing is asked of them', app.staff_home_address_missing(test.id('ga_admin')), false);
select test.throws('gate: no rental added before the home address',
  format($$select public.door(%L, 'aal2', 'ops_do', 'manual_rental_create', test.s38r(interval '3 days', interval '5 days', '{"sales_choice": "for_carmacars"}'))$$, test.id('ga_sales')),
  'Add your home address first');
select test.throws('gate: no quote marked "I sourced this client" before the home address',
  format($$select public.door(%L, 'aal2', 'va_do', 'quote_create', '{"sales_choice": "sourced"}'::jsonb)$$, test.id('ga_sales')), 'Add your home address first');
select test.throws('gate: no offer marked "I sourced this client" before the home address',
  format($$select public.door(%L, 'aal2', 'va_do', 'send_offer', '{"booking": "CC-0", "sales_choice": "sourced"}'::jsonb)$$, test.id('ga_sales')), 'Add your home address first');
select test.throws('gate: field staff too',
  format($$select public.door(%L, 'aal2', 'ops_do', 'manual_rental_create', test.s38r(interval '3 days', interval '5 days', '{"sales_choice": "sourced"}'))$$, test.id('ga_field')),
  'Add your home address first');
select test.throws('save: a full address is needed', format($$select public.door(%L, 'aal2', 'va_do', 'home_address_save', '{"home_address": "Manila", "home_postal_code": "1000"}'::jsonb)$$,
  test.id('ga_sales')), 'full home address');
select test.throws('save: and a postal code', format($$select public.door(%L, 'aal2', 'va_do', 'home_address_save', '{"home_address": "12 Rizal Street, Quezon City", "home_postal_code": ""}'::jsonb)$$,
  test.id('ga_sales')), 'postal code');
select test.throws('save: an assistant cannot use the field door', format($$select public.door(%L, 'aal2', 'field_do', 'home_address_save', '{"home_address": "12 Rizal Street, Quezon City", "home_postal_code": "1100"}'::jsonb)$$,
  test.id('ga_sales')), null);
select test.throws('save: not for renters', format($$select app.staff_home_address_save(%L, '{"home_address": "12 Rizal Street, Quezon City", "home_postal_code": "1100"}'::jsonb)$$,
  test.id('renter:ga_rita')), 'Not permitted');

-- the field staff member's referral earns a commission, which waits for the address
insert into s38 select 'ref', app.manual_rental_create(test.id('ga_admin'), test.s38r(interval '-6 days', interval '-3 days',
  jsonb_build_object('past', true, 'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash'))));
select app.sales_reassign(test.id('ga_admin'), jsonb_build_object('booking', (test.s38b('ref')).id, 'staff', test.id('ga_field'), 'sourced', true, 'reason', 'Test: their referral'));
create or replace function test.s38c() returns staff_commissions language sql stable as $$
  select * from staff_commissions where booking_id = (test.s38b('ref')).id and kind = 'commission' order by created_at desc limit 1 $$;
select test.eq('commission: a completed, paid rental of staff without a home address is not earned yet, and says why',
  (select status || '|' || coalesce(note, '') from test.s38c()), 'accruing|Earned once the home address is in the staff member''s profile');
insert into s38 select 'saved', public.door(test.id('ga_field'), 'aal2', 'field_do', 'home_address_save', '{"home_address": "12  Queen Street West, Toronto", "home_postal_code": "m5h 2n2"}'::jsonb);
select test.eq('save: field staff save theirs (tidied), no longer asked', (test.s38('saved') ->> 'home_address') || '|' || (test.s38('saved') ->> 'home_postal_code') || '|' || (test.s38('saved') ->> 'missing'),
  '12 Queen Street West, Toronto|M5H 2N2|false');
select test.eq('save: dated, by themselves, in the audit log',
  (select (home_address_set_at is not null)::text || '/' || (home_address_set_by = test.id('ga_field')) from staff_profiles where user_id = test.id('ga_field'))
  || '/' || exists (select 1 from audit_log where action = 'staff_home_address_save' and entity_id = test.id('ga_field')::text), 'true/true/true');
select test.eq('commission: earned once the address is in (pending approval, the note gone)',
  (select status || '|' || coalesce(note, 'none') from test.s38c()), 'pending_approval|none');
select test.eq('address: the field agreement is prepared with it',
  app.staff_agreement_prepare(test.id('ga_admin'), test.id('ga_field')) #>> '{staff,home_address}', '12 Queen Street West, Toronto, M5H 2N2');
select public.door(test.id('ga_sales'), 'aal2', 'va_do', 'home_address_save', '{"home_address": "12 Rizal Street, Quezon City, Philippines", "home_postal_code": "1100"}'::jsonb);
insert into s38 select 'sales1', public.door(test.id('ga_sales'), 'aal2', 'ops_do', 'manual_rental_create', test.s38r(interval '3 days', interval '5 days', '{"sales_choice": "sourced"}'));
select test.eq('gate: with the address, Sales adds a sourced rental', (select sales_sourced::text || '/' || (sales_staff_id = test.id('ga_sales')) from test.s38b('sales1')), 'true/true');
select test.eq('admin: an Admin can still edit it', (app.staff_household_set(test.id('ga_admin'), jsonb_build_object('staff', test.id('ga_sales'), 'home_address', '14 Rizal Street, Quezon City',
  'home_postal_code', '1100')) ->> 'staff')::uuid = test.id('ga_sales'), true);
select test.eq('admin: the edit is dated and by the Admin', (select home_address || '/' || (home_address_set_by = test.id('ga_admin')) from staff_profiles where user_id = test.id('ga_sales')),
  '14 Rizal Street, Quezon City/true');
select test.throws('read: not for the site''s visitors', $$set local role anon; select app.staff_home_address_read(null)$$, 'permission denied');

-- ================================================================ 4. Sales is commission only
select test.eq('defaults: Sales is commission only, flexible, no rate or hours',
  (select (s.staff_agreement_defaults #>> '{va,by_function,sales,pay_basis}') || '/' || (s.staff_agreement_defaults #>> '{va,by_function,sales,schedule}') || '/'
          || coalesce(nullif(s.staff_agreement_defaults #>> '{va,by_function,sales,rate}', ''), 'none') || '/' || coalesce(nullif(s.staff_agreement_defaults #>> '{va,by_function,sales,days_per_week}', ''), 'none')
     from (select (app.settings()).*) s), 'commission/flexible/none/none');
select test.eq('defaults: the other functions keep their pay', (select (s.staff_agreement_defaults #>> '{va,by_function,cs,pay_basis}') || '/' || (s.staff_agreement_defaults #>> '{va,by_function,cs,rate}')
  from (select (app.settings()).*) s), 'monthly/350.00');
update staff_profiles set sales_work_mode = 'remote' where user_id = test.id('ga_sales');  -- 0197: a remote one (in person: the in-person agreement)
select test.eq('defaults: a Sales agreement starts from them',
  (select (d ->> 'pay_basis') || '/' || (d ->> 'schedule') || '/' || (d ->> 'country') from (select app.staff_agreement_prepare(test.id('ga_admin'), test.id('ga_sales')) -> 'defaults' d) x),
  'commission/flexible/Philippines');
select test.eq('defaults: a new database starts with them too',
  (select column_default like '%"pay_basis": "commission"%' and column_default like '%"schedule": "flexible"%' from information_schema.columns where table_name = 'program_settings' and column_name = 'staff_agreement_defaults'), true);
