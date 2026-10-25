-- 97: field staff may take a cash deposit (migration 0153, docs/changes/2026-10-25-field-cash-deposit-clause.md): cash is
-- on by default among the ways field staff may take a deposit at the check-out, and on in the settings in force.
select test.suite('97 field cash deposit clause');

select test.eq('settings: e-Transfer and cash are the default ways field staff may take a deposit besides the card',
  (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'field_offline_deposit_methods'),
  'ARRAY[''e_transfer''::text, ''cash''::text]');
select test.ok('settings: cash is on in the settings in force', 'cash' = any ((app.settings()).field_offline_deposit_methods));
select test.ok('settings: every settings row allows cash after 0153',
  not exists (select 1 from program_settings where not ('cash' = any (field_offline_deposit_methods))));
