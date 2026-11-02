-- 99: asking for alerts at the right moment, and the store app's links (migration 0523). Staff are asked at their first
-- sign-in, an owner once the application is approved (again after a later approval), a person with a device on never;
-- the answer is kept for every device. Program settings app_store_url / play_store_url feed public.app_links().
-- Fixtures start with "ap"; every address is example.test.
select test.suite('99 alert prompts and app links');

select test.mk_user('ap_admin', 'admin');
select test.mk_user('ap_cs', 'va', 'cs');
select test.mk_owner('ap_olga');
select test.mk_user('ap_rita', 'renter');
create or replace function test.ap(p text) returns text language sql stable as $$
  select (r ->> 'ask') || ' ' || coalesce(r ->> 'why', '-') from (select public.server_alerts_ask(test.id(p)) r) x $$;

select test.eq('staff at their first sign-in: asked', test.ap('ap_cs'), 'true staff_first');
select test.eq('an Admin too', test.ap('ap_admin'), 'true staff_first');
select test.eq('a renter is not asked by the database (the device decides, as before)', test.ap('ap_rita'), 'false -');
select test.eq('an owner whose application is not approved: not asked yet', test.ap('ap_olga'), 'false -');
insert into owner_applications (id, owner_id, source, status, decided_at)
values (test.id('app:ap_olga'), test.id('owner:ap_olga'), 'web', 'approved', now() - interval '1 minute');
select test.eq('approved: asked', test.ap('ap_olga'), 'true owner_approved');
select public.server_alerts_asked(test.id('ap_olga'), 'later');
select test.eq('"Not now": not asked again on any device', test.ap('ap_olga'), 'false -');
update owner_applications set decided_at = now() + interval '1 minute' where id = test.id('app:ap_olga');
select test.eq('a later approval asks again', test.ap('ap_olga'), 'true owner_approved');
select public.server_alerts_asked(test.id('ap_cs'), 'on');
select test.eq('staff answered once: never asked again', test.ap('ap_cs'), 'false -');
insert into push_subscriptions (user_id, kind, endpoint, platform) values (test.id('ap_admin'), 'fcm', 'fcm:ap-admin-token-0000000000', 'android');
select test.eq('a device already on: not asked', test.ap('ap_admin'), 'false on');
select test.throws('the answer is on or later', $$select public.server_alerts_asked(test.id('ap_cs'), 'maybe')$$, 'Answer on or later');
select test.ok('the two reads are for the server only',
  not has_function_privilege('anon', 'public.server_alerts_ask(uuid)', 'execute') and not has_function_privilege('authenticated', 'public.server_alerts_asked(uuid, text)', 'execute'));

-- ================================================================ the store app's links
select test.eq('empty until the apps are live', public.app_links(), '{"ios": null, "android": null}'::jsonb);
update program_settings set app_store_url = 'https://apps.apple.com/ca/app/carmacars/id000000', play_store_url = '';
select test.eq('the App Store link set, Google Play left empty',
  public.app_links(), '{"ios": "https://apps.apple.com/ca/app/carmacars/id000000", "android": null}'::jsonb);
select test.throws('only a store address', $$update program_settings set play_store_url = 'https://example.test/app'$$, 'play_store_url');
select test.ok('anyone may read the links (the public footer)', has_function_privilege('anon', 'public.app_links()', 'execute'));
update program_settings set app_store_url = null, play_store_url = null;

-- ================================================================ client_errors (0433) has the admin policy
select test.ok('client_errors: the admin policy, nothing for the anonymous role',
  exists (select 1 from pg_policies where tablename = 'client_errors' and policyname = 'admin_all')
  and not has_table_privilege('anon', 'client_errors', 'select'));
