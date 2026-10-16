-- 29: one confirmation email per sign-up (migration 0045). Granting a role emails nothing; the two account emails are
-- welcomes, emitted once when the address is first confirmed; an owner gets the owner welcome, a renter with no other
-- portal the renter welcome, staff and investors none; no catalogue email asks for a confirmation link; the live
-- verification's sign-up functions. Fixtures start with "oc".
select test.suite('29 one confirmation email');
create or replace function test.oc_events(p_user uuid) returns text language sql stable as $$
  select coalesce(string_agg(code || ':' || split_part(dedupe_key, ':', 3), ',' order by id), 'none')
    from app_events where entity_id = p_user and code in ('renter_account_created', 'owner_account_created')
$$;

-- ================================================================ 1. a role granted emails nothing
select test.eq('trigger: 0023''s user_roles trigger is gone', (select count(*) from pg_trigger where tgname = 'user_roles_notify'), 0::bigint);
select app.register_account(test.id('oc_rita'), 'oc_rita@example.test', 'Oc Rita');
select test.eq('create account: the users row and the renter role, no email yet (Supabase sends the confirmation)', test.oc_events(test.id('oc_rita')), 'none');
-- the owner application: register, then the owner record and role (as app.submit_owner_application grants it)
select app.register_account(test.id('oc_olga'), 'oc_olga@example.test', 'Oc Olga');
insert into owners (user_id, owner_type, legal_name, email, status) values (test.id('oc_olga'), 'individual', 'Oc Olga', 'oc_olga@example.test', 'lead');
insert into user_roles (user_id, role) values (test.id('oc_olga'), 'owner');
select test.eq('owner application: the owner role emails nothing either', test.oc_events(test.id('oc_olga')), 'none');
-- a guest's booking request: a users row and the renter role with no sign-in
insert into users (id, email, full_name) values (test.id('oc_gus'), 'oc_gus@example.test', 'Oc Gus');
insert into user_roles (user_id, role) values (test.id('oc_gus'), 'renter');
insert into renters (user_id, legal_name, email) values (test.id('oc_gus'), 'Oc Gus', 'oc_gus@example.test');
select test.eq('booking request: the guest gets no "finish your account" email', test.oc_events(test.id('oc_gus')), 'none');
select test.mk_user('oc_vera', 'va', 'cs');
select test.eq('staff invitation: the staff role emails nothing', test.oc_events(test.id('oc_vera')), 'none');

-- ================================================================ 2. the welcome, once, after the confirmation
select app.account_email_verified(test.id('oc_rita'), 'oc_rita@example.test');
select test.eq('renter: the confirmation link emits the renter welcome', test.oc_events(test.id('oc_rita')), 'renter_account_created:confirmed');
select app.account_email_verified(test.id('oc_rita'), 'oc_rita@example.test');
update users set email_verified_at = now() where id = test.id('oc_rita');
select test.eq('renter: a later sign-in (verified again) sends nothing more', test.oc_events(test.id('oc_rita')), 'renter_account_created:confirmed');
select app.account_email_verified(test.id('oc_olga'), 'OC_OLGA@example.test');
select test.eq('owner who applied (renter and owner roles): the owner welcome only', test.oc_events(test.id('oc_olga')), 'owner_account_created:confirmed');
select app.account_email_verified(test.id('oc_gus'), 'oc_gus@example.test');
select test.eq('guest who later chose a password (the address on record): the renter welcome', test.oc_events(test.id('oc_gus')), 'renter_account_created:confirmed');
select app.account_email_verified(test.id('oc_vera'), 'oc_vera@example.test');
select test.eq('staff: no welcome', test.oc_events(test.id('oc_vera')), 'none');
select app.register_account(test.id('oc_ivan'), 'oc_ivan@example.test', 'Oc Ivan');
insert into investors (user_id, legal_name, investor_type, status, email) values (test.id('oc_ivan'), 'Oc Ivan', 'individual', 'active', 'oc_ivan@example.test');
select app.account_email_verified(test.id('oc_ivan'), 'oc_ivan@example.test');
select test.eq('investor (with the renter role from the sign-in): no renter welcome', test.oc_events(test.id('oc_ivan')), 'none');
select app.register_account(test.id('oc_mia'), 'oc_mia@example.test', 'Oc Mia');
select app.account_email_verified(test.id('oc_mia'), 'someone.else@example.test');
select test.eq('a confirmation for another address changes nothing', test.oc_events(test.id('oc_mia')), 'none');

-- the welcome is built with every variable, and nothing in it asks to confirm
select app.process_events(100000);
select test.eq('outbox: one welcome each, every variable built',
  (select string_agg(o.code || ':' || (o.missing_variables = '{}'), ',' order by o.code) from notification_outbox o
    where o.recipient_user_id in (test.id('oc_rita'), test.id('oc_olga'), test.id('oc_gus'))),
  'owner_account_created:true,renter_account_created:true,renter_account_created:true');
select test.eq('outbox: the owner welcome goes to the owner''s address', (select to_address from notification_outbox where recipient_user_id = test.id('oc_olga')), 'oc_olga@example.test');
select test.eq('catalogue: the two account emails are welcomes',
  (select string_agg(code || '=' || subject, '; ' order by code) from notification_catalogue where code in ('renter_account_created', 'owner_account_created')),
  'owner_account_created=Your CarmaCars owner account is ready; renter_account_created=Your CarmaCars account is ready');
select test.eq('catalogue: no email reads a confirmation link (verify_url), and no subject asks to confirm an email',
  (select count(*) from notification_catalogue c where c.has_email and c.in_catalogue
      and (c.variables::text like '%"verify_url"%' or c.subject ilike '%confirm your email%')), 0::bigint);
select test.eq('catalogue: emitted by the confirmation',
  (select string_agg(distinct emitted_by, ',') from notification_catalogue where code in ('renter_account_created', 'owner_account_created')), 'users_confirmed_notify (0045)');

-- ================================================================ 3. the live verification's sign-up functions
select test.throws('verify: only the throwaway sign-up addresses', $$select app.verify_signup('{"email": "oc_x@example.test", "user_id": "00000000-0000-0000-0000-000000000001"}')$$, 'Not a sign-up verification address');
select test.throws('verify: never a real verification account', $$select app.verify_signup('{"email": "verify-owner@carmacars.ca", "user_id": "00000000-0000-0000-0000-000000000001"}')$$, 'Not a sign-up verification address');
select app.verify_signup(jsonb_build_object('email', 'verify-signup-owner-1700000000@carmacars.ca', 'user_id', test.id('oc_vo'), 'name', 'Verify Owner Signup'));
select test.eq('verify owner: the owner role and record, the address suppressed, nothing emitted yet',
  (select (app.my_roles(test.id('oc_vo')) ->> 'owner') || '/' || (select count(*) from owners where user_id = test.id('oc_vo')) || '/'
          || app.email_suppressed('verify-signup-owner-1700000000@carmacars.ca', false) || '/' || app.verify_signup_emails(test.id('oc_vo'))::text),
  'true/1/true/[]');
select app.account_email_verified(test.id('oc_vo'), 'verify-signup-owner-1700000000@carmacars.ca');
select app.process_events(100000);
select test.eq('verify owner: after the confirmation, the owner welcome, suppressed for this address',
  app.verify_signup_emails(test.id('oc_vo'))::text, '[{"key": "confirmed", "code": "owner_account_created", "outbox": "suppressed"}]');
create temp table oc_guest as select app.verify_signup('{"email": "verify-signup-guest-1700000000@carmacars.ca"}') r;
select test.eq('verify guest: a users row with the renter role and no sign-in, its id returned',
  (select (r ->> 'path') || '/' || exists (select 1 from user_roles x where x.user_id = (r ->> 'user_id')::uuid and x.role = 'renter') from oc_guest), 'guest/true');
create temp table oc_clean as select app.verify_signup_cleanup(test.id('oc_vo')) r;
select test.eq('verify cleanup: everything the check made is removed',
  (select (r ->> 'removed') || '/' || (select count(*) from users where id = test.id('oc_vo'))
          || '/' || (select count(*) from app_events where entity_id = test.id('oc_vo')) from oc_clean), 'true/0/0');
select test.throws('verify cleanup: never another account', format('select app.verify_signup_cleanup(%L)', test.id('oc_rita')), 'Not a sign-up verification address');
select test.eq('privileges: only the server runs the verification functions',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where p.proname in ('server_verify_signup', 'server_verify_signup_emails', 'server_verify_signup_cleanup', 'verify_signup', 'verify_signup_cleanup', 'verify_signup_emails')
      and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))), 0::bigint);
