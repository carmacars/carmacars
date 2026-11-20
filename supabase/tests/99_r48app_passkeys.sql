-- 99: Passkeys for the native app (migration 3170). A challenge is random, lasts five minutes and works once; a passkey
-- is added only with the signed-in person's own open challenge, at most ten each, and never twice; a sign-in spends its
-- challenge and moves the counter, and a counter that does not move forward is refused; removing is the owner's only;
-- nothing is readable or callable from a browser. Fixtures start with "pk"; every address is example.test.
select test.suite('99 r48app passkeys');

select test.mk_renter('pk_rita');
select test.mk_renter('pk_omar');
create or replace function test.pk_key() returns jsonb language sql immutable as $$ select '{"kty":"EC","crv":"P-256","x":"eA","y":"eQ"}'::jsonb $$;
create or replace function test.pk_ch(p_label text, p_kind text) returns uuid language sql volatile as $$
  select (public.server_passkey_challenge(case when p_label is null then null else test.id(p_label) end, p_kind, '203.0.113.9')->>'id')::uuid $$;

-- ---------------------------------------------------------------- challenges
select test.ok('a challenge is 32 random bytes in base64url, different each time',
  (select (a->>'challenge') ~ '^[A-Za-z0-9_-]{43}$' and a->>'challenge' <> b->>'challenge'
     from (select public.server_passkey_challenge(test.id('pk_rita'), 'register') a, public.server_passkey_challenge(test.id('pk_rita'), 'register') b) x));
select test.throws('adding a passkey needs a signed-in person', $$select public.server_passkey_challenge(null, 'register')$$, 'Sign in first');
select test.throws('an unknown step is refused', $$select public.server_passkey_challenge(null, 'other')$$, 'Unknown passkey step');
select test.ok('a sign-in challenge needs nobody, and lists no passkeys',
  (select c->'credentials' = '[]'::jsonb and public.server_passkey_challenge_read((c->>'id')::uuid, 'sign_in')->>'user_id' is null
     from (select public.server_passkey_challenge(null, 'sign_in') c) x));
select test.ok('a challenge is read only as its own kind',
  (select public.server_passkey_challenge_read(test.pk_ch(null, 'sign_in'), 'register') is null));

-- ---------------------------------------------------------------- adding
create temp table pk_c as select test.pk_ch('pk_rita', 'register') as id;
select test.throws('another person cannot use my challenge',
  $$select public.server_passkey_register(test.id('pk_omar'), (select id from pk_c), jsonb_build_object('credential_id', 'pk-cred-0000000000001', 'public_key', test.pk_key(), 'alg', -7))$$, 'took too long');
select test.eq('rita adds a passkey', jsonb_array_length(public.server_passkey_register(test.id('pk_rita'), (select id from pk_c),
  jsonb_build_object('credential_id', 'pk-cred-0000000000001', 'public_key', test.pk_key(), 'alg', -7, 'sign_count', 0, 'device', 'CarmaCars app on iPhone'))), 1);
select test.throws('the challenge works once',
  $$select public.server_passkey_register(test.id('pk_rita'), (select id from pk_c), jsonb_build_object('credential_id', 'pk-cred-0000000000002', 'public_key', test.pk_key(), 'alg', -7))$$, 'took too long');
select test.throws('the same passkey is not added twice',
  $$select public.server_passkey_register(test.id('pk_omar'), test.pk_ch('pk_omar', 'register'), jsonb_build_object('credential_id', 'pk-cred-0000000000001', 'public_key', test.pk_key(), 'alg', -7))$$, 'already added');
select test.throws('an answer without a key is refused',
  $$select public.server_passkey_register(test.id('pk_omar'), test.pk_ch('pk_omar', 'register'), jsonb_build_object('credential_id', 'pk-cred-0000000000003', 'alg', -7))$$, 'gave no passkey');
select test.ok('the next challenge lists her passkey, so the phone does not make a second one',
  (select public.server_passkey_challenge(test.id('pk_rita'), 'register')->'credentials' = '["pk-cred-0000000000001"]'::jsonb));
select test.ok('the list shows the device and never the key',
  (select l->0->>'device' = 'CarmaCars app on iPhone' and not (l->0 ? 'public_key') and not (l->0 ? 'credential_id') from (select public.server_passkeys(test.id('pk_rita')) l) x));
select test.ok('an expired challenge is refused', (select test.pk_ch('pk_omar', 'register') is not null));
update passkey_challenges set expires_at = now() - interval '1 second' where user_id = test.id('pk_omar') and used_at is null;
select test.throws('... when it is used',
  $$select public.server_passkey_register(test.id('pk_omar'), (select id from passkey_challenges where user_id = test.id('pk_omar') order by created_at desc limit 1),
      jsonb_build_object('credential_id', 'pk-cred-0000000000004', 'public_key', test.pk_key(), 'alg', -7))$$, 'took too long');

-- ---------------------------------------------------------------- signing in
select test.ok('the passkey is found with its key and its account',
  (select k->>'user_id' = test.id('pk_rita')::text and k->'public_key' = test.pk_key() and (k->>'alg')::int = -7 from (select public.server_passkey_lookup('pk-cred-0000000000001') k) x));
select test.ok('an unknown passkey is not found', (select public.server_passkey_lookup('pk-cred-unknown-000000') is null));
create temp table pk_s as select test.pk_ch(null, 'sign_in') as id;
select test.eq('a checked sign-in returns the account', public.server_passkey_used((select id from pk_s), 'pk-cred-0000000000001', 5), test.id('pk_rita'));
select test.eq('... and moves the counter', (select sign_count from passkeys where credential_id = 'pk-cred-0000000000001'), 5::bigint);
select test.ok('... and records the use', (select last_used_at is not null from passkeys where credential_id = 'pk-cred-0000000000001'));
select test.throws('the sign-in challenge works once', $$select public.server_passkey_used((select id from pk_s), 'pk-cred-0000000000001', 6)$$, 'took too long');
select test.throws('a counter that does not move forward is refused (a copied key)', $$select public.server_passkey_used(test.pk_ch(null, 'sign_in'), 'pk-cred-0000000000001', 5)$$, 'was refused');
select test.throws('a registration challenge does not sign in', $$select public.server_passkey_used(test.pk_ch('pk_rita', 'register'), 'pk-cred-0000000000001', 9)$$, 'took too long');
select test.throws('an unknown passkey does not sign in', $$select public.server_passkey_used(test.pk_ch(null, 'sign_in'), 'pk-cred-unknown-000000', 1)$$, 'not known');
-- a phone that does not count (always 0) signs in again and again
select public.server_passkey_register(test.id('pk_omar'), test.pk_ch('pk_omar', 'register'), jsonb_build_object('credential_id', 'pk-cred-0000000000009', 'public_key', test.pk_key(), 'alg', -7));
select test.eq('a phone that does not count signs in', public.server_passkey_used(test.pk_ch(null, 'sign_in'), 'pk-cred-0000000000009', 0), test.id('pk_omar'));
select test.eq('... and again', public.server_passkey_used(test.pk_ch(null, 'sign_in'), 'pk-cred-0000000000009', 0), test.id('pk_omar'));

-- ---------------------------------------------------------------- limits
do $$
begin
  for i in 1..9 loop
    perform public.server_passkey_register(test.id('pk_rita'), test.pk_ch('pk_rita', 'register'),
      jsonb_build_object('credential_id', 'pk-cred-limit-00000000' || i, 'public_key', test.pk_key(), 'alg', -257));
  end loop;
end $$;
select test.eq('ten passkeys are kept', (select count(*) from passkeys where user_id = test.id('pk_rita')), 10::bigint);
select test.throws('an eleventh is refused before the phone is asked', $$select public.server_passkey_challenge(test.id('pk_rita'), 'register')$$, 'ten passkeys');
select test.throws('thirty challenges in five minutes from one address is the limit',
  $$select public.server_passkey_challenge(null, 'sign_in', '203.0.113.9') from generate_series(1, 31)$$, 'Too many tries');

-- ---------------------------------------------------------------- removing
select test.throws('another person cannot remove my passkey',
  $$select public.server_passkey_remove(test.id('pk_omar'), (select id from passkeys where credential_id = 'pk-cred-0000000000001'))$$, 'not found');
select test.eq('rita removes one', jsonb_array_length(public.server_passkey_remove(test.id('pk_rita'), (select id from passkeys where credential_id = 'pk-cred-0000000000001'))), 9);
select test.ok('a removed passkey no longer signs in', (select public.server_passkey_lookup('pk-cred-0000000000001') is null));

-- ---------------------------------------------------------------- nothing from a browser
select test.ok('the tables have row-level security',
  (select bool_and(c.relrowsecurity) from pg_class c where c.oid in ('public.passkeys'::regclass, 'public.passkey_challenges'::regclass)));
select test.ok('no passkey function is executable by a browser role',
  (select not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app') and p.proname ~ '^(server_)?passkey' and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')))));
select test.login(test.id('pk_rita'));
select test.eq('a renter session reads no passkeys', test.visible('select 1 from passkeys'), 0::bigint);
select test.eq('... and no challenges', test.visible('select 1 from passkey_challenges'), 0::bigint);
select test.logout();
