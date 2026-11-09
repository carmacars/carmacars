-- 99: hotfix 0843: a contact number from any country, saved without a texted code. Fixtures start with "hcp".
select test.suite('99 hotfix contact phone (0843)');
select test.mk_user('hcp_va', 'va', 'cs');
select test.eq('a Philippine number is saved as the contact number, unverified',
  (select (app.account_set_contact_phone(test.id('hcp_va'), '+63 917 123 4567')) ->> 'phone'), '+639171234567');
select test.eq('it is on the account and not verified',
  (select phone || '/' || (phone_verified_at is null)::text from users where id = test.id('hcp_va')), '+639171234567/true');
select test.throws('a number without its country code is refused', $$select app.account_set_contact_phone(test.id('hcp_va'), '0917')$$, '%country code%');
-- (its own number: 99_r35z rings +16475550199 for a renter, and a staff member with it would take the call)
update users set phone = '+16475550163', phone_verified_at = now() where id = test.id('hcp_va');
select test.throws('a verified number on file is never replaced this way',
  $$select app.account_set_contact_phone(test.id('hcp_va'), '+639171234567')$$, '%verified number stays%');
select test.ok('the change is audited', exists (select 1 from audit_log where action = 'account_contact_phone_set' and entity_id = test.id('hcp_va')::text));
select test.ok('only the server may run it', not has_function_privilege('authenticated', 'app.account_set_contact_phone(uuid, text)', 'execute'));
