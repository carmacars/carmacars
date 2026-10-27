-- 99: every box of the Blind Spot agreement (migration 0178, docs/changes/2026-10-27-agreement-every-box.md): CarmaCars'
-- HST account in box 1, the card coverage provider asked for and filled on the Agreement card, and in the snapshot a
-- version compares. Uses 87's booking test.agb('a') (card coverage).
select test.suite('99 agreement every box');

select test.eq('settings: CarmaCars'' GST/HST account is set (box 1)', (select company_hst_number from program_settings limit 1), '76339 9177 RT0001');

update coverage_proofs set coverage_provider = null where booking_id = test.agb('a');
select test.eq('missing: card coverage without its provider is a field a claim needs',
  (select count(*) from jsonb_array_elements(app.agreement_missing(test.agb('a'))) x where x ->> 'key' = 'coverage.coverage_provider' and (x ->> 'required')::boolean), 1::bigint);
select test.eq('fill: customer service fills the provider on the booking: no longer missing',
  (select count(*) from jsonb_array_elements(public.door(test.id('ag_cs'), null, 'ops_do', 'agreement_fill',
     jsonb_build_object('booking', test.agb('a'), 'coverage', jsonb_build_object('coverage_provider', ' Assurant '))) -> 'missing') x
    where x ->> 'key' = 'coverage.coverage_provider'), 0::bigint);
select test.eq('fill: kept trimmed on the coverage proof', (select coverage_provider from coverage_proofs where booking_id = test.agb('a') order by created_at desc limit 1), 'Assurant');
select test.eq('detail: what boxes 12 and 13 print', public.server_coverage_detail(test.agb('a')) ->> 'coverage_provider', 'Assurant');
select test.eq('snapshot: a version compares the provider (a correction, not material)',
  app.agreement_snapshot(test.agb('a')) #>> '{coverage,provider}', 'Assurant');
select test.eq('privileges: the new functions are the service role''s only',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where ((n.nspname = 'public' and p.proname = 'server_coverage_detail') or (n.nspname = 'app' and p.proname in ('coverage_detail', 'agreement_fill', 'agreement_missing', 'agreement_snapshot')))
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);
