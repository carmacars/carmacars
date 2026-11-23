-- 99: the Finance dashboard and the bank reconciliation (migration 3480; docs/finance/bank-data.md): each bank line once
-- (same file, overlapping files, twin lines), only the last four digits kept, auto-matching when exactly one record fits,
-- each record matched once, matching by hand, setting aside with a reason, To dos and the staff notice for lines still
-- unmatched, who may see and do it (Admin and Finance), and the dashboard's figures. Fixtures start with "x49"; addresses
-- are example.test, account numbers are made up.
select test.suite('99 r49 finance');
select test.mk_user('x49_admin', 'admin');
select test.mk_user('x49_fin', 'va', 'finance');
select test.mk_user('x49_cs', 'va', 'cs');
select test.mk_owner('x49_o');
create temp table x49_base as select app.finance_dashboard(test.id('x49_admin'), '{}') b;
grant all on x49_base to public;

-- what the lines will be: a Stripe payout in, an owner payout and an expense out
insert into payout_reconciliations (id, processor, processor_payout_ref, paid_on, amount_cents)
values (test.id('x49:po1'), 'stripe', 'po_x49_1', app.today() - 3, 152040), (test.id('x49:po2'), 'stripe', 'po_x49_2', app.today() - 3, 99999);
insert into payouts (id, payee_type, owner_id, kind, amount_cents, scheduled_for, status, approved_by, paid_at)
values (test.id('x49:pay1'), 'owner', test.id('owner:x49_o'), 'other', 64000, app.today() - 3, 'paid', test.id('x49_admin'), now() - interval '3 days');
insert into company_expenses (id, expense_on, category, description, amount_cents, hst_cents, created_by)
values (test.id('x49:exp1'), app.today() - 2, 'fleet_insurance', 'X49 test premium', 10000, 1300, test.id('x49_admin'));

create function test.x49_lines(p_extra boolean default false) returns jsonb language sql as $$
  select jsonb_agg(x) from (
    select jsonb_build_object('posted_on', app.today() - 3, 'amount_cents', 152040, 'description', 'STRIPE  PAYOUT') x
    union all select jsonb_build_object('posted_on', app.today() - 3, 'amount_cents', -64000, 'description', 'E-TRANSFER SENT X49 OWNER')
    union all select jsonb_build_object('posted_on', app.today() - 2, 'amount_cents', -11300, 'description', 'INSURER X49')
    union all select jsonb_build_object('posted_on', app.today() - 2, 'amount_cents', -600, 'description', 'MONTHLY FEE')
    union all select jsonb_build_object('posted_on', app.today() - 2, 'amount_cents', -600, 'description', 'MONTHLY FEE')
    union all select jsonb_build_object('posted_on', app.today() - 5, 'amount_cents', 4242, 'description', 'DEPOSIT X49 UNKNOWN', 'balance_cents', 1000000)
    union all select jsonb_build_object('posted_on', app.today() - 1, 'amount_cents', 777, 'description', 'INTEREST') where p_extra) q $$;
create function test.x49_import(p_by text, p_sha text, p_extra boolean default false) returns jsonb language sql as $$
  select app.bank_import(test.id(p_by), jsonb_build_object('account', jsonb_build_object('last4', '00102-9994567', 'hash', repeat('a', 64), 'currency', 'CAD'),
    'source', 'csv', 'file_name', 'x49.csv', 'file_sha256', p_sha, 'lines', test.x49_lines(p_extra))) $$;

-- who may import
select test.throws('customer service cannot import bank lines', $$select test.x49_import('x49_cs', repeat('1', 64))$$, 'Finance or an Admin');
select test.throws('an owner cannot import bank lines', $$select test.x49_import('x49_o', repeat('1', 64))$$);
create temp table x49_r as select test.x49_import('x49_fin', repeat('1', 64)) r1;
grant all on x49_r to public;
select test.eq('Finance imports: 6 lines, all new (the two identical fees are two lines)', (select (r1 ->> 'lines_new') || '/' || (r1 ->> 'lines_in') from x49_r), '6/6');
select test.eq('the Stripe payout, the owner payout and the expense match by themselves', (select r1 ->> 'lines_matched' from x49_r), '3');
select test.eq('only the last four digits of the account are kept', (select account_last4 || ':' || nickname from bank_accounts where account_hash = repeat('a', 64)), '4567:RBC CAD 4567');
select test.eq('the balance column of the newest line becomes the balance', (select balance_cents || ':' || source from bank_balances b join bank_accounts a on a.id = b.bank_account_id where a.account_hash = repeat('a', 64)), '1000000:csv');
select test.eq('the matches are the right records',
  (select string_agg(match_kind || '=' || matched_table, ',' order by match_kind) from bank_lines l join bank_accounts a on a.id = l.bank_account_id where a.account_hash = repeat('a', 64) and status = 'matched'),
  'expense=company_expenses,owner_payout=payouts,stripe_payout=payout_reconciliations');
select test.eq('the description is tidied', (select count(*) from bank_lines where description = 'STRIPE PAYOUT'), 1::bigint);

-- the same file again, then an overlapping download with one more day
select test.eq('the same file again is a repeat: nothing added', (select (test.x49_import('x49_fin', repeat('1', 64)) ->> 'repeat')), 'true');
alter table x49_r add column r2 jsonb, add column r3 jsonb;
update x49_r set r2 = test.x49_import('x49_admin', repeat('2', 64));
select test.eq('the same lines in another file add nothing (6 already in)', (select (r2 ->> 'lines_new') || '/' || (r2 ->> 'lines_duplicate') from x49_r), '0/6');
update x49_r set r3 = test.x49_import('x49_admin', repeat('3', 64), true);
select test.eq('an overlapping download adds only its new line', (select r3 ->> 'lines_new' from x49_r), '1');
select test.eq('one account for every import', (select count(*) from bank_accounts where account_hash = repeat('a', 64)), 1::bigint);
select test.throws('a line with no amount refuses the whole file', $$select app.bank_import(test.id('x49_fin'), jsonb_build_object('account', jsonb_build_object('last4', '4567', 'hash', repeat('a', 64)),
  'lines', jsonb_build_array(jsonb_build_object('posted_on', app.today(), 'amount_cents', 0))))$$, 'no date or no amount');
select test.throws('a line dated in the future is refused', $$select app.bank_import(test.id('x49_fin'), jsonb_build_object('account', jsonb_build_object('last4', '4567', 'hash', repeat('a', 64)),
  'lines', jsonb_build_array(jsonb_build_object('posted_on', app.today() + 10, 'amount_cents', 100))))$$, 'future');

-- matching by hand: the unknown deposit fits nothing; a second Stripe payout for the interest does
create temp table x49_l as select
  (select id from bank_lines where description = 'DEPOSIT X49 UNKNOWN') unknown,
  (select id from bank_lines where description = 'INTEREST') interest,
  (select id from bank_lines where description = 'MONTHLY FEE' order by created_at limit 1) fee;
grant all on x49_l to public;
select test.eq('nothing fits the unknown deposit', jsonb_array_length(app.bank_free_candidates((select unknown from x49_l))), 0);
insert into payout_reconciliations (id, processor, processor_payout_ref, paid_on, amount_cents) values (test.id('x49:po3'), 'stripe', 'po_x49_3', app.today() - 1, 777),
  (test.id('x49:po4'), 'stripe', 'po_x49_4', app.today() - 2, 777);
select test.eq('two Stripe payouts fit the interest line: it waits for a person', jsonb_array_length(app.bank_free_candidates((select interest from x49_l))), 2);
select test.throws('a record that does not fit is refused', format($$select app.bank_line_match(test.id('x49_fin'), jsonb_build_object('line', %L, 'pick', 'payout_reconciliations:' || test.id('x49:po2')))$$, (select interest from x49_l)), 'does not fit');
select test.throws('customer service cannot match', format($$select app.bank_line_match(test.id('x49_cs'), jsonb_build_object('line', %L, 'pick', 'payout_reconciliations:' || test.id('x49:po3')))$$, (select interest from x49_l)), 'Finance or an Admin');
select test.eq('Finance matches it to the one they pick', (app.bank_line_match(test.id('x49_fin'), jsonb_build_object('line', (select interest from x49_l), 'pick', 'payout_reconciliations:' || test.id('x49:po3'))) ->> 'status'), 'matched');
select test.throws('a record is matched to one line only', format($$update bank_lines set status = 'matched', match_kind = 'stripe_payout', matched_table = 'payout_reconciliations', matched_id = test.id('x49:po3') where id = %L$$, (select fee from x49_l)), 'bank_lines_target_once');
select test.throws('a matched line is not matched again', format($$select app.bank_line_match(test.id('x49_fin'), jsonb_build_object('line', %L, 'pick', 'payout_reconciliations:' || test.id('x49:po4')))$$, (select interest from x49_l)), 'already matched');
select test.throws('setting a line aside needs what it is', format($$select app.bank_line_match(test.id('x49_fin'), jsonb_build_object('line', %L, 'ignore', true))$$, (select fee from x49_l)), 'Say what the line is');
select test.eq('a bank fee is set aside with its reason', (app.bank_line_match(test.id('x49_fin'), jsonb_build_object('line', (select fee from x49_l), 'ignore', true, 'note', 'RBC monthly fee')) ->> 'status'), 'ignored');
select test.throws('undoing needs a reason', format($$select app.bank_line_match(test.id('x49_admin'), jsonb_build_object('line', %L, 'unmatch', true))$$, (select fee from x49_l)), 'why');
select test.eq('an Admin undoes it with a reason', (app.bank_line_match(test.id('x49_admin'), jsonb_build_object('line', (select fee from x49_l), 'unmatch', true, 'note', 'Not a fee')) ->> 'status'), 'unmatched');
select app.bank_unmatched_scan();
select test.ok('undone, it is a To do again', exists (select 1 from bank_lines l join tasks t on t.id = l.todo_task_id where l.id = (select fee from x49_l) and t.status = 'open'));
select test.ok('every step is in the audit log', (select count(*) from audit_log where action in ('bank_import', 'bank_line_match', 'bank_line_ignore', 'bank_line_unmatch') and actor_user_id in (test.id('x49_fin'), test.id('x49_admin'))) >= 6);

-- To dos and the staff notice: the unknown deposit (5 days old) is past the 2 days; the fees (2 days) too
select test.ok('the unknown line is a To do for Finance', exists (select 1 from bank_lines l join tasks t on t.id = l.todo_task_id
  where l.id = (select unknown from x49_l) and t.queue = 'finance' and t.task_type = 'bank_unmatched' and t.status = 'open'));
select test.ok('and the staff notice is raised once', (select count(*) from app_events where code = 'staff_bank_line_unmatched' and entity_id = (select unknown from x49_l)) = 1);
select test.eq('a scan again raises nothing new for it', (select count(*) from tasks where dedupe_key = 'bank_unmatched:' || (select unknown from x49_l)), 1::bigint);
select app.bank_unmatched_scan();
select test.eq('still one To do after another scan', (select count(*) from tasks where dedupe_key = 'bank_unmatched:' || (select unknown from x49_l)), 1::bigint);
select test.ok('the notice has its values', (select (x ->> 'bank_direction') = 'in' and (x ->> 'bank_amount') = app.fmt_money(4242) and x ? 'bank_hint' and x ? 'bank_posted_on'
  from (select app.notification_payload('staff_bank_line_unmatched', e, '{}'::jsonb) x from app_events e where e.code = 'staff_bank_line_unmatched' and e.entity_id = (select unknown from x49_l)) q));
select test.eq('the notice is in the catalogue for Finance and the Admins, in the morning digest',
  (select audience || ':' || array_to_string(also_sent_to, ',') || ':' || is_digest || ':' || digest_slot from notification_catalogue where code = 'staff_bank_line_unmatched'), 'staff_va_finance:staff_admin:true:morning');
insert into payout_reconciliations (id, processor, processor_payout_ref, paid_on, amount_cents) values (test.id('x49:po5'), 'stripe', 'po_x49_5', app.today() - 5, 4242);
select app.bank_line_match(test.id('x49_fin'), jsonb_build_object('line', (select unknown from x49_l), 'pick', 'payout_reconciliations:' || test.id('x49:po5')));
select test.eq('matching closes its To do', (select t.status from bank_lines l join tasks t on t.id = l.todo_task_id where l.id = (select unknown from x49_l)), 'done');
select test.eq('a recent line is not a To do yet (under 2 days)', (select todo_task_id is null from bank_lines where description = 'INTEREST'), true);

-- the typed balance
select test.throws('a balance in the future is refused', format($$select app.bank_balance_set(test.id('x49_fin'), jsonb_build_object('account_id', %L, 'balance_cents', 5, 'as_of', app.today() + 1))$$, (select id from bank_accounts where account_hash = repeat('a', 64))), 'future');
select app.bank_balance_set(test.id('x49_fin'), jsonb_build_object('account_id', (select id from bank_accounts where account_hash = repeat('a', 64)), 'balance_cents', 2500000, 'as_of', app.today()));

-- the dashboard: Admin and Finance only, with the figures moved by this suite
select test.throws('customer service does not see the dashboard', $$select app.finance_dashboard(test.id('x49_cs'), '{}')$$, 'Finance or an Admin');
select test.throws('nor the bank lines', $$select app.bank_lines_view(test.id('x49_cs'), '{}')$$, 'Finance or an Admin');
create temp table x49_d as select app.finance_dashboard(test.id('x49_fin'), '{}') d;
grant all on x49_d to public;
select test.eq('the bank balance is the latest one', (select (d -> 'bank' ->> 'total_cad_cents')::bigint - (b -> 'bank' ->> 'total_cad_cents')::bigint from x49_d, x49_base), 2500000::bigint);
select test.eq('HST paid on the expense counts for the quarter', (select (d -> 'hst' ->> 'paid_cents')::bigint - (b -> 'hst' ->> 'paid_cents')::bigint from x49_d, x49_base),
  case when date_trunc('quarter', app.today() - 2) = date_trunc('quarter', app.today()) then 1300::bigint else 0::bigint end);
select test.eq('the owner payout paid this month', (select (d -> 'money_out' -> 'owner_payouts' ->> 'paid_month_cents')::bigint - (b -> 'money_out' -> 'owner_payouts' ->> 'paid_month_cents')::bigint from x49_d, x49_base),
  case when date_trunc('month', app.today() - 3) = date_trunc('month', app.today()) then 64000::bigint else 0::bigint end);
select test.eq('twelve months of money in and out', (select jsonb_array_length(d -> 'pnl') from x49_d), 12);
select test.ok('the reconciliation counts the lines', (select (d -> 'reconciliation' ->> 'matched')::int >= 5 and (d -> 'reconciliation' ->> 'unmatched')::int >= 1 from x49_d));
select test.ok('every section is there', (select d ?& array['bank', 'money_in', 'deposits', 'insurers', 'renters_overdue', 'money_out', 'hst', 'pnl', 'reconciliation'] from x49_d));
select test.eq('the door serves it to Finance', (app.door(test.id('x49_fin'), 'aal2', 'va_read', 'finance_dashboard', '{"_va":"finance"}') ? 'hst'), true);
select test.eq('the door imports for an Admin (a repeat here)', (app.door(test.id('x49_admin'), 'aal2', 'admin_do', 'bank_import', jsonb_build_object('account', jsonb_build_object('last4', '4567', 'hash', repeat('a', 64), 'currency', 'CAD'),
  'source', 'csv', 'file_sha256', repeat('1', 64), 'lines', test.x49_lines())) ->> 'repeat'), 'true');
select test.throws('the door refuses customer service', $$select app.door(test.id('x49_cs'), 'aal2', 'va_read', 'bank_lines', '{}')$$, 'Finance or an Admin');

-- row-level security: read only, Admin and Finance
select test.login(test.id('x49_fin'));
select test.ok('Finance reads the bank lines', test.visible('select 1 from bank_lines') >= 7);
select test.throws('Finance cannot change a line directly', $$update bank_lines set note = 'x'$$);
select test.logout();
select test.login(test.id('x49_cs'));
select test.eq('customer service sees no bank line', test.visible('select 1 from bank_lines'), 0::bigint);
select test.eq('nor a bank account', test.visible('select 1 from bank_accounts'), 0::bigint);
select test.logout();
select test.eq('only the server runs the finance functions', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app' and p.proname in ('bank_import', 'bank_line_match', 'finance_dashboard', 'bank_lines_view', 'bank_unmatched_scan')
    and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))), 0::bigint);
