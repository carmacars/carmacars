-- 99: extended deposit holds are on (2650, release 42: Stripe approved Extended Authorization on the account). The setting
-- is read by the server only; every deposit hold then asks Stripe for the longer hold, and never a rental charge (the
-- adapter's unit tests, stripe.test.ts).
select test.suite('99 r42 extended deposit holds (2650)');

select test.eq('extended deposit holds are on', (app.settings()).deposit_extended_holds, true);
select test.eq('... on every dated row of the settings', (select count(*) from program_settings where not deposit_extended_holds), 0::bigint);
select test.eq('... and by default for a new install',
  (select pg_get_expr(d.adbin, d.adrelid) from pg_attrdef d join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
    where d.adrelid = 'public.program_settings'::regclass and a.attname = 'deposit_extended_holds'), 'true');
select test.eq('the server reads it', public.server_deposit_extended_holds(), true);
select test.eq('only the server may read it',
  has_function_privilege('authenticated', 'public.server_deposit_extended_holds()', 'execute')
  or has_function_privilege('anon', 'public.server_deposit_extended_holds()', 'execute'), false);
select test.eq('nothing is captured by itself', (app.settings()).deposit_auto_capture, false);
