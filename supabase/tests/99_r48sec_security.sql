-- 99: release 48 pre-deploy security audit (migration 3400; docs/security/audit-2026-11-r48.md). The native app's
-- signed-out tokens are refused until they would have expired anyway; a tracker request refused for the rate can be
-- sent again; every security definer function searches pg_temp last. Fixtures start with "r48sec".
select test.suite('99 r48sec security');

-- ---------------------------------------------------------------- definer functions: pg_temp last
select test.eq('every security definer function in public and app has a search_path that ends with pg_temp (names any other)',
  (select string_agg(p.oid::regprocedure::text, ', ' order by 1) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where p.prosecdef and n.nspname in ('public', 'app')
      and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c ~ '^search_path=.*, pg_temp$')), null::text);

-- ---------------------------------------------------------------- signed-out bearer tokens
select public.server_bearer_revoke(array['t:' || repeat('a', 64), 's:00000000-0000-4000-8000-0000000048a1', 'not a key'], now() + interval '1 hour');
select test.eq('a signed-out token is refused by its hash, and by its sign-in session',
  public.server_bearer_revoked(array['t:' || repeat('a', 64)]) || '/' || public.server_bearer_revoked(array['t:' || repeat('b', 64), 's:00000000-0000-4000-8000-0000000048a1']), 'true/true');
select test.eq('another token is not', public.server_bearer_revoked(array['t:' || repeat('c', 64), 's:00000000-0000-4000-8000-0000000048a2']), false);
select test.eq('what is not a key is never stored', (select count(*) from revoked_bearers where key !~ '^(t|s):'), 0::bigint);
update revoked_bearers set expires_at = now() - interval '1 second' where key = 't:' || repeat('a', 64);
select test.eq('...and a revocation ends when the token could no longer be used anyway', public.server_bearer_revoked(array['t:' || repeat('a', 64)]), false);
select public.server_bearer_revoke(array['t:' || repeat('d', 64)], now() + interval '10 days');
select test.ok('a revocation is kept two days at most (no access token lives longer)',
  (select expires_at <= now() + interval '2 days' from revoked_bearers where key = 't:' || repeat('d', 64)));
select public.server_bearer_revoke(array['t:' || repeat('e', 64)], now() + interval '1 hour');
select test.eq('expired revocations are removed as new ones are made', (select count(*) from revoked_bearers where key = 't:' || repeat('a', 64)), 0::bigint);
select test.eq('no browser role calls these or reads the table',
  (select count(*) from unnest(array['public.server_bearer_revoke(text[], timestamptz)', 'public.server_bearer_revoked(text[])']) f, unnest(array['anon', 'authenticated']) r
    where has_function_privilege(r, f::regprocedure, 'execute'))
  + (select count(*) from unnest(array['anon', 'authenticated']) r where has_table_privilege(r, 'public.revoked_bearers', 'select')), 0::bigint);

-- ---------------------------------------------------------------- the tracker ingest: a request refused for the rate is not a replay
update tracker_settings set ingest_per_minute = 10;
delete from app.rate_limit_hits where key = 'tracker_ingest';
select test.eq('over the rate, a signed request is refused for the rate',
  (select string_agg(coalesce(public.server_tracker_ingest_signed('{"points": []}'::jsonb, lpad('48a' || to_hex(g), 64, '0'), 1) ->> 'refused', 'ok'), ',' order by g) from generate_series(1, 11) g),
  'ok,ok,ok,ok,ok,ok,ok,ok,ok,ok,rate');
delete from app.rate_limit_hits where key = 'tracker_ingest';
select test.eq('...and the same request sent again in the next minute is taken (not refused as a replay)',
  coalesce(public.server_tracker_ingest_signed('{"points": []}'::jsonb, lpad('48ab', 64, '0'), 1) ->> 'refused', 'taken'), 'taken');
select test.eq('...once: the same request a third time is a replay',
  public.server_tracker_ingest_signed('{"points": []}'::jsonb, lpad('48ab', 64, '0'), 1) ->> 'refused', 'replay');
update tracker_settings set ingest_per_minute = 240;
delete from app.rate_limit_hits where key = 'tracker_ingest';

-- ---------------------------------------------------------------- password sign-in by address
delete from app.rate_limit_hits where key like 'sign_in:ip:%';
select test.eq('30 password sign-ins in 15 minutes from one address, then no more from it (another address goes on)',
  (select count(*) filter (where public.server_sign_in_ip_allowed('203.0.113.48')) from generate_series(1, 31))
    || '/' || public.server_sign_in_ip_allowed('203.0.113.49'), '30/true');
select test.eq('with no address, every such try shares one count: the limit is never skipped',
  (select count(*) filter (where public.server_sign_in_ip_allowed(null)) from generate_series(1, 20))
    + (select count(*) filter (where public.server_sign_in_ip_allowed('')) from generate_series(1, 20)), 30::bigint);
select test.eq('no browser role calls it', has_function_privilege('anon', 'public.server_sign_in_ip_allowed(text)', 'execute')
  or has_function_privilege('authenticated', 'public.server_sign_in_ip_allowed(text)', 'execute'), false);
delete from app.rate_limit_hits where key like 'sign_in:ip:%';
