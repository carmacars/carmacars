-- 99: field expenses say whose money paid (migration 3720, release 50; docs/changes/2026-11-24-r50-field-reimbursements.md).
-- The choice is required; own money makes a reimbursement owed to the person that follows Finance's approve, decline (with
-- the reason) and paid back; Finance and the person see it; the notices reach Finance and the person (email and in-app);
-- the connector's add_expense and list_expenses carry paid_with. Fixtures start with "xf"; every address is example.test.
select test.suite('99 r50 field reimbursements');
select test.mk_user('xf_admin', 'admin');
select test.mk_user('xf_fin', 'va', 'finance');
select test.mk_user('xf_a', 'field');
select test.mk_user('xf_b', 'field');
create function test.xf_add(p_who text, p jsonb) returns jsonb language sql as $$ select app.fx_spend_add(test.id(p_who), p) $$;
create function test.xf_spend(p_desc text) returns uuid language sql stable as $$ select id from field_spends where description = p_desc $$;

-- ================================================================ 1. whose money: always chosen
select test.throws('no choice is refused', $$select test.xf_add('xf_a', '{"kind": "gas", "description": "Gas xf none", "amount_cents": 4000}')$$, 'Choose whose money it was');
select test.throws('anything else is refused', $$select test.xf_add('xf_a', '{"kind": "gas", "description": "Gas xf bad", "amount_cents": 4000, "paid_with": "boss"}')$$, 'Choose whose money it was');
select test.lives('own money', $$select test.xf_add('xf_a', '{"kind": "gas", "description": "Gas xf own", "amount_cents": 4000, "hst_cents": 520, "paid_with": "own"}')$$);
select test.lives('company card', $$select test.xf_add('xf_a', '{"kind": "wash", "description": "Wash xf company", "amount_cents": 2500, "paid_with": "company"}')$$);
select test.lives('own money, to be declined', $$select test.xf_add('xf_b', '{"kind": "parking", "description": "Parking xf decline", "amount_cents": 1500, "paid_with": "own"}')$$);
select test.eq('the expense keeps the choice', (select string_agg(paid_with, ',' order by description) from field_spends where description like '% xf %'), 'own,own,company');
select test.eq('own money is owed back once approved: pending now, for the amount with HST',
  (select r.status || '/' || r.amount_cents || '/' || (r.staff_id = test.id('xf_a'))::text from staff_reimbursements r where r.field_spend_id = test.xf_spend('Gas xf own')), 'pending/4520/true');
select test.eq('company money owes nobody', (select count(*) from staff_reimbursements r where r.field_spend_id = test.xf_spend('Wash xf company')), 0::bigint);
select test.ok('the column has no default any more', (select column_default is null from information_schema.columns where table_name = 'field_spends' and column_name = 'paid_with'));

-- ================================================================ 2. Finance decides
select test.throws('declining needs the reason', format($$select app.fx_spend_decide(test.id('xf_fin'), jsonb_build_object('id', %L, 'approve', false))$$, test.xf_spend('Parking xf decline')), 'Say why');
select test.lives('declined with the reason', format($$select app.fx_spend_decide(test.id('xf_fin'), jsonb_build_object('id', %L, 'approve', false, 'note', 'Personal parking'))$$, test.xf_spend('Parking xf decline')));
select test.eq('the reimbursement is declined with the reason', (select r.status || '/' || r.decline_reason from staff_reimbursements r where r.field_spend_id = test.xf_spend('Parking xf decline')), 'declined/Personal parking');
select test.lives('approved', format($$select app.fx_spend_decide(test.id('xf_fin'), jsonb_build_object('id', %L, 'approve', true))$$, test.xf_spend('Gas xf own')));
select test.eq('now owed, tied to its company expense, which says own money',
  (select r.status || '/' || (r.company_expense_id is not null)::text || '/' || e.paid_with from staff_reimbursements r join company_expenses e on e.id = r.company_expense_id where r.field_spend_id = test.xf_spend('Gas xf own')), 'owed/true/own');

-- ================================================================ 3. what each one sees
select test.eq('the person: owed and pending totals', (select (v ->> 'owed_cents') || '/' || (v ->> 'pending_cents') from public.door(test.id('xf_a'), null, 'field_read', 'my_reimbursements', '{}') v), '4520/0');
select test.eq('another field person sees only theirs', (select jsonb_array_length(v -> 'rows') || '/' || (v -> 'rows' -> 0 ->> 'status') from public.door(test.id('xf_b'), null, 'field_read', 'my_reimbursements', '{}') v), '1/declined');
select test.throws('a field person cannot read someone else''s', format($$select app.reimbursements_view(test.id('xf_b'), jsonb_build_object('staff', %L))$$, test.id('xf_a')), 'Only Finance or an Admin');
select test.eq('Finance: the payout list, per person', (select (x ->> 'owed_cents') from jsonb_array_elements(public.door(test.id('xf_fin'), null, 'ops_read', 'reimbursements', '{}') -> 'people') x where x ->> 'staff_id' = test.id('xf_a')::text), '4520');
select test.lives('paid back from the payout list', format($$select public.door(test.id('xf_fin'), null, 'ops_do', 'reimbursement_paid', jsonb_build_object('id', %L))$$,
  (select id from staff_reimbursements where field_spend_id = test.xf_spend('Gas xf own'))));
select test.eq('paid, and the expense too', (select r.status || '/' || s.status from staff_reimbursements r join field_spends s on s.id = r.field_spend_id where r.field_spend_id = test.xf_spend('Gas xf own')), 'paid/reimbursed');
select test.throws('not paid twice', format($$select app.reimbursement_paid(test.id('xf_fin'), jsonb_build_object('id', %L))$$, (select id from staff_reimbursements where field_spend_id = test.xf_spend('Gas xf own'))), 'Only an approved reimbursement');
select test.throws('a field person cannot pay it', format($$select app.reimbursement_paid(test.id('xf_a'), jsonb_build_object('id', %L))$$, (select id from staff_reimbursements where field_spend_id = test.xf_spend('Gas xf own'))), 'Only Finance');

-- ================================================================ 4. the connector
select test.throws('add_expense own money needs the staff member', $$select app.api_expense_add(test.id('xf_admin'), '{"category": "other", "amount_cents": 3000, "description": "Tolls xf", "paid_with": "own"}')$$, 'staff:');
create temp table xf_ex as select app.api_expense_add(test.id('xf_admin'), jsonb_build_object('category', 'other', 'amount_cents', 3000, 'description', 'Tolls xf admin', 'paid_with', 'own', 'staff', test.id('xf_b'))) as r;
select test.eq('owed at once to that person', (select x.status || '/' || x.amount_cents from staff_reimbursements x where x.company_expense_id = (select (r ->> 'id')::uuid from xf_ex)), 'owed/3000');
select test.eq('list_expenses: paid_with, the staff member and the reimbursement', (select (j ->> 'paid_with') || '/' || (j #>> '{reimbursement,status}') from app.api_row('list_expenses', (select (r ->> 'id')::uuid from xf_ex)) j), 'own/owed');
select test.eq('the default is the company', (select app.api_expense_add(test.id('xf_admin'), '{"category": "other", "amount_cents": 1000, "description": "Paper xf"}') ->> 'paid_with'), 'company');
select test.ok('list_expenses filters by paid_with', (select count(*) from app.api_src('list_expenses', '{"paid_with": "own"}') s join company_expenses e on e.id = s.id where e.paid_with <> 'own') = 0);

-- ================================================================ 5. the notices: email and in-app, to the right people
select test.eq('submitted: once per expense, to Finance', (select count(*) from app_events where code = 'staff_expense_submitted' and payload ->> 'spend_id' in (test.xf_spend('Gas xf own')::text, test.xf_spend('Wash xf company')::text, test.xf_spend('Parking xf decline')::text)), 3::bigint);
select test.eq('the person hears the decision, at their own address',
  (select string_agg(distinct x.email, ',') from app_events e, app.notification_recipients(e, (select c from notification_catalogue c where c.code = 'staff_expense_declined')) x
    where e.code = 'staff_expense_declined' and e.payload ->> 'spend_id' = test.xf_spend('Parking xf decline')::text), (select email from users where id = test.id('xf_b')));
select app.process_events(100000);
select test.eq('every expense email was built, with no variable missing',
  (select string_agg(c, ',' order by c) from unnest(array['staff_expense_submitted', 'staff_expense_approved', 'staff_expense_declined']) c
    where not exists (select 1 from notification_outbox o where o.code = c and o.missing_variables = '{}')
      and not exists (select 1 from staff_digest_items d where d.code = c)), null::text);
select test.ok('Finance has the alert in the app', exists (select 1 from notifications n where n.user_id = test.id('xf_fin') and n.code = 'staff_expense_submitted'));
select test.ok('the person has the decision in the app', exists (select 1 from notifications n where n.user_id = test.id('xf_b') and n.code = 'staff_expense_declined'));
select test.ok('the other field person does not', not exists (select 1 from notifications n where n.user_id = test.id('xf_a') and n.code = 'staff_expense_declined'));
select test.ok('the functions end their search_path with pg_temp',
  not exists (select 1 from pg_proc p where p.proname in ('spend_notice', 'field_spends_reimburse', 'reimbursements_view', 'reimbursement_paid', 'api_expense_add')
               and not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%pg_temp')));
