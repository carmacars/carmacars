-- 17: the admin portal's door (migration 0030). Every fixture label starts with "ap".
select test.suite('17 admin portal');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_user('ap_admin', 'admin');
select test.mk_user('ap_cs', 'va', 'cs');
select test.mk_owner('ap_o');
select test.mk_vehicle('apV', 'ap_o');
select test.mk_renter('ap_r');
select test.mk_booking('AP-1', 'apV', 'ap_r', '2027-03-01 10:00', '2027-03-04 10:00', 'requested', 30000);
select test.mk_booking('AP-2', 'apV', 'ap_r', '2027-04-01 10:00', '2027-04-03 10:00', 'confirmed', 20000);

-- ---------------------------------------------------------------- 1. only an Admin
select test.throws('door: an assistant cannot use the admin reads', format($$select public.admin_read(%L, 'dashboard')$$, test.id('ap_cs')), 'Only an Admin');
select test.throws('door: nor the admin actions', format($$select public.admin_do(%L, 'block_remove', '{}')$$, test.id('ap_cs')), 'Only an Admin');
select test.throws('door: nor the settings', format($$select public.admin_save(%L, 'site_settings', '{"values": {"tagline": "x"}}')$$, test.id('ap_cs')), 'Only an Admin');
select test.throws('door: anonymous callers have no execute right', $$set local role anon; select public.admin_read(null, 'dashboard')$$, 'permission denied');
select test.eq('door: the Admin becomes the acting user for the transaction',
  (select app.admin_begin(test.id('ap_admin'))::text || auth.uid()::text), test.id('ap_admin')::text);

-- ---------------------------------------------------------------- 2. lists
select test.throws('lists: a table off the allow-list is refused', format($$select public.admin_list(%L, 'payment_method_secrets')$$, test.id('ap_admin')), 'does not list');
select test.throws('lists: a filter on a column that does not exist is refused', format($$select public.admin_list(%L, 'bookings', '{"eq": {"nope; drop table x": 1}}')$$, test.id('ap_admin')), 'Unknown column');
select test.eq('lists: filter by status, names added for ids',
  (select (r -> 'rows' -> 0 ->> 'booking_number') || '/' || (r -> 'rows' -> 0 ->> 'vehicle_name' is not null)::text || '/' || (r ->> 'count')
     from public.admin_list(test.id('ap_admin'), 'bookings', jsonb_build_object('eq', jsonb_build_object('booking_number', 'AP-2'))) r), 'AP-2/true/1');
select test.eq('lists: text search finds the row', (public.admin_list(test.id('ap_admin'), 'bookings', '{"q": "AP-1"}') ->> 'count')::integer >= 1, true);

-- ---------------------------------------------------------------- 3. reads
select test.eq('reads: the dashboard has every card', (select count(*) from jsonb_object_keys(public.admin_read(test.id('ap_admin'), 'dashboard')) k
  where k in ('pickups', 'returns', 'requests', 'offers', 'payments_failed', 'deposits_due', 'late', 'tasks', 'fleet', 'cash', 'alerts')), 11::bigint);
select test.eq('reads: the dashboard alerts carry the missing mailing address when it is missing',
  (select (public.admin_read(test.id('ap_admin'), 'dashboard') -> 'alerts')::text like '%mailing_address%' = ((select mailing_address from site_settings limit 1) is null)), true);
select test.eq('reads: the request queue lists the request', (select count(*) from jsonb_array_elements(public.admin_read(test.id('ap_admin'), 'requests')) x where x ->> 'booking_number' = 'AP-1'), 1::bigint);
select test.eq('reads: a booking with its lines, events and history', (select (b ->> 'booking_number') || '/' || jsonb_typeof(b -> 'events') || '/' || jsonb_typeof(b -> 'lines')
  from public.admin_read(test.id('ap_admin'), 'booking', '{"number": "AP-1"}') b), 'AP-1/array/array');
select test.eq('reads: the preview never keeps the change',
  (select coalesce(public.admin_read(test.id('ap_admin'), 'booking_preview', jsonb_build_object('booking', test.id('booking:AP-1'), 'changes', jsonb_build_object('notes', 'preview only'))) ->> 'ok', 'x')
     || '/' || coalesce((select notes from bookings where id = test.id('booking:AP-1')), 'unchanged')), 'true/unchanged');
select test.eq('reads: the calendar has the vehicle with its booking', (select count(*) from jsonb_array_elements(public.admin_read(test.id('ap_admin'), 'calendar',
    jsonb_build_object('from', '2027-03-28', 'to', '2027-04-10')) -> 'vehicles') v, jsonb_array_elements(v -> 'entries') e where e ->> 'booking_number' = 'AP-2'), 1::bigint);
select test.eq('reads: a vehicle with its rates and fees', (select jsonb_typeof(v -> 'rate_history') || '/' || jsonb_typeof(v -> 'fee_types')
  from public.admin_read(test.id('ap_admin'), 'vehicle', jsonb_build_object('id', test.id('vehicle:apV'))) v), 'array/array');
select test.eq('reads: the settings bundle', (select count(*) from jsonb_object_keys(public.admin_read(test.id('ap_admin'), 'settings')) k
  where k in ('site', 'program', 'content', 'fee_defaults', 'deposit_tiers', 'km_choices', 'classes', 'airports', 'coverage', 'email_aliases', 'reply_to', 'staff', 'insurers', 'promo_codes')), 14::bigint);
select test.throws('reads: an unknown read is refused', format($$select public.admin_read(%L, 'everything')$$, test.id('ap_admin')), 'Unknown admin read');

-- ---------------------------------------------------------------- 4. settings
select test.eq('settings: the tagline changes', (public.admin_save(test.id('ap_admin'), 'site_settings', '{"values": {"tagline": "Admin portal tagline"}}') ->> 'tagline'), 'Admin portal tagline');
select test.eq('settings: the Admin is recorded on the row', (select updated_by from site_settings limit 1), test.id('ap_admin'));
select test.eq('settings: the change is in the audit log with the Admin as actor',
  (select count(*) from audit_log where entity_table = 'site_settings' and actor_user_id = test.id('ap_admin') and after ->> 'tagline' = 'Admin portal tagline') >= 1, true);
select test.throws('settings: a column off the allow-list is refused', format($$select public.admin_save(%L, 'site_settings', '{"values": {"legal_name_displayed": true}}')$$, test.id('ap_admin')), 'Not a field');
select test.throws('settings: a table off the allow-list is refused', format($$select public.admin_save(%L, 'user_roles', '{"values": {}}')$$, test.id('ap_admin')), 'does not edit');
create temp table ap_ps as select count(*) as n from program_settings;
create temp table ap_ps2 as select public.admin_save(test.id('ap_admin'), 'program_settings', jsonb_build_object('effective_from', app.today() + 1, 'values', '{"offer_expiry_hours": 36}'::jsonb)) as r;
select test.eq('settings: program settings are a new dated row, history kept',
  (select r ->> 'offer_expiry_hours' from ap_ps2) || '/' || ((select count(*) from program_settings) - (select n from ap_ps))::text || '/' || (app.settings(app.today() + 1)).offer_expiry_hours, '36/1/36');
select test.throws('settings: history is not edited', format($$select public.admin_save(%L, 'program_settings', '{"effective_from": "2020-01-01", "values": {"offer_expiry_hours": 1}}')$$, test.id('ap_admin')), 'history is not edited');
select test.eq('settings: a deposit tier is added', (public.admin_save(test.id('ap_admin'), 'deposit_tiers', '{"values": {"amount_cents": 123400, "label": "Test tier"}}') ->> 'label'), 'Test tier');
select test.eq('settings: a promo code is stored in upper case', (public.admin_save(test.id('ap_admin'), 'promo_codes', '{"values": {"code": "apwelcome", "amount_cents": 2500}}') ->> 'code'), 'APWELCOME');

-- ---------------------------------------------------------------- 5. actions
select test.throws('actions: an unknown action is refused', format($$select public.admin_do(%L, 'drop_everything')$$, test.id('ap_admin')), 'Unknown admin action');
select test.eq('actions: a block over a confirmed booking lists the conflict first',
  (select jsonb_array_length(public.admin_do(test.id('ap_admin'), 'block_create', jsonb_build_object('vehicle', test.id('vehicle:apV'), 'reason', 'service',
     'starts_at', '2027-04-02 08:00', 'ends_at', '2027-04-05 08:00')) -> 'conflicts')), 1);
select test.eq('actions: nothing was created until confirmed', (select count(*) from vehicle_calendar_blocks where vehicle_id = test.id('vehicle:apV')), 0::bigint);
create temp table ap_blk as select (public.admin_do(test.id('ap_admin'), 'block_create', jsonb_build_object('vehicle', test.id('vehicle:apV'), 'reason', 'service',
  'starts_at', '2027-05-02 08:00', 'ends_at', '2027-05-05 08:00')) ->> 'id')::uuid as id;
select test.eq('actions: a free block is created by the Admin', (select created_by from vehicle_calendar_blocks where id = (select id from ap_blk)), test.id('ap_admin'));
select test.throws('actions: removing a block needs a reason', format($$select public.admin_do(%L, 'block_remove', jsonb_build_object('block', %L))$$, test.id('ap_admin'), (select id from ap_blk)), 'reason');
select public.admin_do(test.id('ap_admin'), 'block_remove', jsonb_build_object('block', (select id from ap_blk), 'reason', 'service moved'));
select test.eq('actions: a removed block is kept with who and why', (select (removed_by = test.id('ap_admin'))::text || '/' || removed_reason from vehicle_calendar_blocks where id = (select id from ap_blk)), 'true/service moved');
select test.throws('actions: an admin block needs a note', format($$select public.admin_do(%L, 'block_create', jsonb_build_object('vehicle', %L, 'reason', 'admin', 'starts_at', '2027-06-01', 'ends_at', '2027-06-02'))$$,
  test.id('ap_admin'), test.id('vehicle:apV')), 'note is required');
create temp table ap_rc as select public.admin_do(test.id('ap_admin'), 'rate_card', jsonb_build_object('vehicle', test.id('vehicle:apV'), 'daily_rate_cents', 11100, 'weekend_rate_cents', 12200,
  'weekly_rate_cents', 70000, 'monthly_rate_cents', 250000)) as r;
select test.eq('actions: a new rate card through set_rate_card', (select daily_rate_cents from rate_cards where id = (select (r ->> 'id')::uuid from ap_rc)), 11100::bigint);
select test.throws('actions: ending your own access is refused', format($$select public.admin_do(%L, 'staff_end', jsonb_build_object('user', %L))$$, test.id('ap_admin'), test.id('ap_admin')), 'own access');
select public.admin_do(test.id('ap_admin'), 'staff_end', jsonb_build_object('user', test.id('ap_cs')));
select test.eq('actions: an ended assistant is no longer staff', app.user_is_staff(test.id('ap_cs')), false);
select test.throws('actions: a review is hidden only for the allowed reasons', format($$select public.admin_do(%L, 'review_hide', '{"id": "%s", "reason": "negative"}')$$, test.id('ap_admin'), gen_random_uuid()), 'Hide a review only');
