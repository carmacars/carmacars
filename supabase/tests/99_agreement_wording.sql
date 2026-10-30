-- 99: the rental agreement's wording per booking (migration 0198, docs/changes/2026-10-30-agreement-wording.md): an
-- Admin rewords a clause with a reason, it is kept with its history, the snapshot carries it, a change after signing is
-- a material version signed again; required clauses are not removed, the consents not reworded, other staff refused.
-- Uses 87's booking test.agb('a') (signed and countersigned) and its users.
select test.suite('99 agreement wording');

select test.eq('snapshot: a booking with the standard wording has no wording key (nothing changes for other bookings)',
  app.agreement_snapshot(test.agb('a')) ? 'wording', false);
select test.throws('refused: customer service does not change the wording', format($$select public.door(%L, null, 'ops_do', 'agreement_wording_save',
  jsonb_build_object('booking', %L, 'code', 'damage', 'action', 'edit', 'text', 'New text', 'reason', 'Customer asked'))$$, test.id('ag_cs'), test.agb('a')), 'Only an Admin%');
select test.throws('required: the damage clause is reworded, never removed', format($$select public.door(%L, null, 'ops_do', 'agreement_wording_save',
  jsonb_build_object('booking', %L, 'code', 'damage', 'action', 'remove', 'reason', 'Not wanted here'))$$, test.id('ag_admin'), test.agb('a')), '%required by law or the insurer%');
select test.throws('required: nor the coverage clause', format($$select public.door(%L, null, 'ops_do', 'agreement_wording_save',
  jsonb_build_object('booking', %L, 'code', 'coverage', 'action', 'remove', 'reason', 'Not wanted here'))$$, test.id('ag_admin'), test.agb('a')), '%required by law or the insurer%');
select test.throws('fixed: the consents the signer ticks are not reworded', format($$select public.door(%L, null, 'ops_do', 'agreement_wording_save',
  jsonb_build_object('booking', %L, 'code', 'consents', 'action', 'edit', 'text', 'x', 'reason', 'Shorter please'))$$, test.id('ag_admin'), test.agb('a')), '%not changed per booking%');
select test.throws('reason: a change says why', format($$select public.door(%L, null, 'ops_do', 'agreement_wording_save',
  jsonb_build_object('booking', %L, 'code', 'damage', 'action', 'edit', 'text', 'x', 'reason', ''))$$, test.id('ag_admin'), test.agb('a')), 'Say why%');

select test.eq('save: an Admin rewords the damage clause for this booking',
  public.door(test.id('ag_admin'), null, 'ops_do', 'agreement_wording_save', jsonb_build_object('booking', test.agb('a'), 'code', 'damage', 'action', 'edit',
    'text', '**9.1 Your responsibility.** Damage up to $500 for this rental.', 'reason', 'Long-term customer, agreed by phone')) #>> '{wording,damage,action}', 'edit');
select test.eq('stored: the change with its reason and who made it',
  (select clause_code || '/' || action || '/' || reason || '/' || (by_user = test.id('ag_admin'))::text from booking_clause_overrides where booking_id = test.agb('a')),
  'damage/edit/Long-term customer, agreed by phone/true');
select test.eq('stored: the site reads the wording in force', public.server_agreement_wording(test.agb('a')) #>> '{damage,text}', '**9.1 Your responsibility.** Damage up to $500 for this rental.');
select test.eq('snapshot: the wording is part of what the agreement prints', app.agreement_snapshot(test.agb('a')) #>> '{wording,damage}', '**9.1 Your responsibility.** Damage up to $500 for this rental.');
-- (this booking is returned: the version is its closing copy, now signed again; a booking on rent makes a "changed" one)
select test.eq('plan: after signing, a new version the renter signs (material, never a correction filed without signing)',
  (select (p ->> 'state') || '/' || (p ->> 'material') || '/' || (p ->> 'kind' <> 'correction')::text from (select app.agreement_plan(test.agb('a')) p) x), 'version/true/true');
select test.eq('plan: the change list shows the clause before and after',
  (select x ->> 'label' || '|' || (x ->> 'before') || '|' || (x ->> 'material') from jsonb_array_elements(app.agreement_plan(test.agb('a')) -> 'changes') x where x ->> 'key' = 'wording.damage'),
  'Agreement wording: 9. Damage|Standard wording|true');
select test.ok('plan: the renter signs it', exists (select 1 from jsonb_array_elements(app.agreement_plan(test.agb('a')) -> 'signers') s where s ->> 'role' = 'renter'));
select test.eq('touch: the booking''s agreements are queued', (select count(*) from agreement_jobs where kind = 'version' and ref = test.agb('a')), 1::bigint);
select test.eq('history: the booking''s history says what changed and why',
  (select count(*) from booking_events where booking_id = test.agb('a') and kind = 'agreement_wording' and note like '%9. Damage: reworded. Reason: Long-term customer%'), 1::bigint);

select test.throws('unchanged: the same text again is refused', format($$select public.door(%L, null, 'ops_do', 'agreement_wording_save',
  jsonb_build_object('booking', %L, 'code', 'damage', 'action', 'edit', 'text', '**9.1 Your responsibility.** Damage up to $500 for this rental.', 'reason', 'Again please'))$$,
  test.id('ag_admin'), test.agb('a')), 'Nothing changes%');
select public.door(test.id('ag_admin'), null, 'ops_do', 'agreement_wording_save', jsonb_build_object('booking', test.agb('a'), 'code', 'tolls', 'action', 'remove', 'reason', 'Tolls billed by the insurer'));
select public.door(test.id('ag_admin'), null, 'ops_do', 'agreement_wording_save', jsonb_build_object('booking', test.agb('a'), 'code', 'additional', 'action', 'add', 'text', 'The car is returned washed.', 'reason', 'Agreed with the renter'));
select test.eq('optional: tolls removed, additional terms added',
  (select (w #>> '{tolls,action}') || '/' || (w #>> '{additional,text}') from (select app.agreement_wording(test.agb('a')) w) x), 'remove/The car is returned washed.');
select test.eq('snapshot: a removed clause reads as removed in the change list',
  (select x ->> 'after' from jsonb_array_elements(app.agreement_plan(test.agb('a')) -> 'changes') x where x ->> 'key' = 'wording.tolls'), 'Removed');
select public.door(test.id('ag_admin'), null, 'ops_do', 'agreement_wording_save', jsonb_build_object('booking', test.agb('a'), 'code', 'damage', 'action', 'restore', 'reason', 'Back to the standard'));
select test.eq('restore: the damage clause is standard again; its history is kept',
  (select (not (app.agreement_wording(test.agb('a')) ? 'damage'))::text || '/' || count(*) from booking_clause_overrides where booking_id = test.agb('a') and clause_code = 'damage'), 'true/2');
select test.throws('history: a change is never edited', format($$update booking_clause_overrides set reason = 'rewritten' where booking_id = %L$$, test.agb('a')), '%kept as written%');
select test.ok('state: the Agreement card reads the clauses and the history',
  (select jsonb_array_length(s #> '{wording,clauses}') = 19 and jsonb_array_length(s #> '{wording,history}') = 4
     from (select public.door(test.id('ag_cs'), null, 'ops_read', 'agreement_state', jsonb_build_object('booking', test.agb('a'))) s) x));
select test.eq('privileges: the new functions are the service role''s only',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where ((n.nspname = 'public' and p.proname = 'server_agreement_wording') or (n.nspname = 'app' and p.proname like 'agreement_wording%'))
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);
