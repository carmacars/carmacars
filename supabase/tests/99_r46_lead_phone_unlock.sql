-- 99: release 46 (migration 2870): an Admin shows a lead's phone to a salesperson, lead by lead. Every other lead stays
-- masked, a reassignment hides it again, an Admin hides it again, only an Admin unlocks, and each step is in the audit
-- log. Fixtures: "zp". Test data only (example.test addresses, 555 numbers).
select test.suite('99 r46 lead phone unlock (2870)');

select test.mk_user('zp_admin', 'admin');
select test.mk_user('zp_sales', 'va', 'sales');
select test.mk_user('zp_sales2', 'va', 'sales');
select test.mk_user('zp_cs', 'va', 'cs');
insert into leads (id, kind, name, email, phone, source, message) values
  (test.id('lead:zp1'), 'contact', 'Zp One', 'zp_one@example.test', '905-555-0171', 'web', 'A car for the weekend'),
  (test.id('lead:zp2'), 'contact', 'Zp Two', 'zp_two@example.test', '905-555-0172', 'web', 'A car next week');

create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb) returns jsonb language sql as
$$ select app.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
create function pg_temp.phone(p_user text, p_lead text) returns text language sql as
$$ select pg_temp.dr(p_user, 'va_read', 'sales_lead', jsonb_build_object('id', test.id('lead:' || p_lead))) ->> 'phone' $$;
create function pg_temp.masked(p_last text) returns text language sql as
$$ select '(905) ' || repeat(chr(8226), 3) || '-' || repeat(chr(8226), 2) || p_last $$;

select pg_temp.dr('zp_admin', 'ops_do', 'lead_reassign', jsonb_build_object('lead', test.id('lead:zp1'), 'to', test.id('zp_sales')));
select pg_temp.dr('zp_admin', 'ops_do', 'lead_reassign', jsonb_build_object('lead', test.id('lead:zp2'), 'to', test.id('zp_sales')));

-- ---------------------------------------------------------------- before: masked
select test.eq('before: Sales sees the lead''s phone masked', pg_temp.phone('zp_sales', 'zp1'), pg_temp.masked('71'));
select test.ok('before: the whole person behind the lead is masked for Sales too (2411 read, now masked on the outer door)',
  position('555-0172' in pg_temp.dr('zp_sales', 'va_read', 'lead_context', jsonb_build_object('lead', test.id('lead:zp2')))::text) = 0);

-- ---------------------------------------------------------------- only an Admin unlocks
select test.throws('Sales cannot unlock a number', format($$select app.door(%L, 'aal2', 'ops_do', 'lead_phone_unlock', %L)$$, test.id('zp_sales'),
  jsonb_build_object('lead', test.id('lead:zp1'))), '%Only an Admin%');
select test.throws('customer service cannot unlock a number', format($$select app.door(%L, 'aal2', 'ops_do', 'lead_phone_unlock', %L)$$, test.id('zp_cs'),
  jsonb_build_object('lead', test.id('lead:zp1'))), '%Only an Admin%');
select test.throws('an Admin cannot unlock for a person who is not in Sales', format($$select app.door(%L, 'aal2', 'ops_do', 'lead_phone_unlock', %L)$$, test.id('zp_admin'),
  jsonb_build_object('lead', test.id('lead:zp1'), 'to', test.id('zp_cs'))), '%works in Sales%');

-- ---------------------------------------------------------------- unlock: that lead, that person
select test.eq('unlock: the lead''s salesperson by default',
  pg_temp.dr('zp_admin', 'ops_do', 'lead_phone_unlock', jsonb_build_object('lead', test.id('lead:zp1'), 'reason', 'Calling from the counter')) ->> 'to', test.id('zp_sales')::text);
select test.eq('unlock: audited with who, for whom and why',
  (select count(*) from audit_log where action = 'lead_phone_unlock' and actor_user_id = test.id('zp_admin') and entity_id = test.id('lead:zp1')::text
     and after ->> 'to' = test.id('zp_sales')::text and after ->> 'reason' = 'Calling from the counter')::int, 1);
select test.eq('unlock: the salesperson gets an alert that opens the lead, with no number in it',
  (select count(*) || '/' || max(e.payload ->> 'path_staff') || '/' || max(e.payload ->> 'assigned_to') || '/' || (position('555' in max(e.payload::text)) = 0)::text
     from app_events e where e.code like 'staff_alert_%' and e.payload ->> 'rule' = 'lead_phone_shown' and e.entity_id = test.id('lead:zp1')),
  '1/' || '/staff/sales-leads/' || test.id('lead:zp1') || '/' || test.id('zp_sales') || '/true');
select test.eq('Admin lead views: lead_phone_state gives the row facts of the leads asked for',
  pg_temp.dr('zp_admin', 'admin_read', 'lead_phone_state', jsonb_build_object('leads', jsonb_build_array(test.id('lead:zp1')))) #>> array[test.id('lead:zp1')::text, 'phone_unlocks', '0', 'name'],
  app.sl_name(test.id('zp_sales')));
select test.throws('Admin lead views: Sales cannot read lead_phone_state', format($$select app.door(%L, 'aal2', 'ops_read', 'lead_phone_state', '{}')$$, test.id('zp_sales')), '%Only an Admin%');
select test.eq('unlocked: Sales sees the full number of that lead', pg_temp.phone('zp_sales', 'zp1'), '905-555-0171');
select test.eq('unlocked: the lead says so', pg_temp.dr('zp_sales', 'va_read', 'sales_lead', jsonb_build_object('id', test.id('lead:zp1'))) ->> 'phone_unlocked', 'true');
select test.eq('unlocked: the other lead stays masked', pg_temp.phone('zp_sales', 'zp2'), pg_temp.masked('72'));
select test.eq('unlocked: the list shows it in full on that lead only',
  (select string_agg(r ->> 'phone', '|' order by r ->> 'name') from jsonb_array_elements(pg_temp.dr('zp_sales', 'va_read', 'sales_leads', '{}') -> 'rows') r where r ->> 'name' like 'Zp %'),
  '905-555-0171|' || pg_temp.masked('72'));
select test.eq('unlocked: another salesperson still sees it masked', app.mask_phone_text(test.id('zp_sales2'), 'Call 905-555-0171', null), 'Call ' || pg_temp.masked('71'));
select test.eq('unlocked: the Admin''s lead says who sees it',
  pg_temp.dr('zp_admin', 'admin_read', 'sales_lead', jsonb_build_object('id', test.id('lead:zp1'))) #>> '{phone_unlocks,0,name}', app.sl_name(test.id('zp_sales')));
select test.eq('unlocked: pressing it again adds nothing',
  (pg_temp.dr('zp_admin', 'ops_do', 'lead_phone_unlock', jsonb_build_object('lead', test.id('lead:zp1'))) ->> 'already') || '/'
  || (select count(*) from lead_phone_unlocks where lead_id = test.id('lead:zp1') and hidden_at is null), 'true/1');

-- ---------------------------------------------------------------- ask an Admin
select test.throws('ask: customer service sees numbers already', format($$select app.door(%L, 'aal2', 'ops_do', 'lead_phone_ask', %L)$$, test.id('zp_cs'),
  jsonb_build_object('lead', test.id('lead:zp2'))), '%Only Sales%');
select test.eq('ask: Sales asks', pg_temp.dr('zp_sales', 'ops_do', 'lead_phone_ask', jsonb_build_object('lead', test.id('lead:zp2'), 'note', 'At the counter')) ->> 'asked', 'true');
select test.eq('ask: one Admin To do on the lead, opening the lead',
  (select count(*) from tasks where task_type = 'lead_phone_ask' and related_table = 'leads' and related_id = test.id('lead:zp2') and status = 'open' and queue = 'admin')::int, 1);
select test.eq('ask: asking again adds no second To do',
  (pg_temp.dr('zp_sales', 'ops_do', 'lead_phone_ask', jsonb_build_object('lead', test.id('lead:zp2'))) ->> 'already')
  || '/' || (select count(*) from tasks where task_type = 'lead_phone_ask' and related_id = test.id('lead:zp2')), 'true/1');
select test.eq('ask: the lead says an ask is waiting', pg_temp.dr('zp_sales', 'va_read', 'sales_lead', jsonb_build_object('id', test.id('lead:zp2'))) ->> 'phone_ask_open', 'true');
select test.eq('ask: the Admin''s Show the phone from the To do shows it to the one who asked',
  pg_temp.dr('zp_admin', 'ops_do', 'lead_phone_unlock', jsonb_build_object('lead', test.id('lead:zp2'), 'from_ask', true)) ->> 'to', test.id('zp_sales')::text);
select test.eq('ask: showing the number closes the To do', (select status from tasks where task_type = 'lead_phone_ask' and related_id = test.id('lead:zp2')), 'done');
select test.eq('ask: now in full', pg_temp.phone('zp_sales', 'zp2'), '905-555-0172');

-- ---------------------------------------------------------------- hide it again
select test.throws('hide: only an Admin', format($$select app.door(%L, 'aal2', 'ops_do', 'lead_phone_hide', %L)$$, test.id('zp_sales'),
  jsonb_build_object('lead', test.id('lead:zp2'))), '%Only an Admin%');
select test.eq('hide: an Admin hides it again', pg_temp.dr('zp_admin', 'ops_do', 'lead_phone_hide', jsonb_build_object('lead', test.id('lead:zp2'))) ->> 'hidden', '1');
select test.eq('hide: masked again', pg_temp.phone('zp_sales', 'zp2'), pg_temp.masked('72'));
select test.eq('hide: audited', (select count(*) from audit_log where action = 'lead_phone_hide' and actor_user_id = test.id('zp_admin') and entity_id = test.id('lead:zp2')::text)::int, 1);
select test.throws('hide: nothing shown, nothing to hide', format($$select app.door(%L, 'aal2', 'ops_do', 'lead_phone_hide', %L)$$, test.id('zp_admin'),
  jsonb_build_object('lead', test.id('lead:zp2'))), '%not shown to anyone%');

-- ---------------------------------------------------------------- reassignment: the unlock does not carry
select pg_temp.dr('zp_admin', 'ops_do', 'lead_reassign', jsonb_build_object('lead', test.id('lead:zp1'), 'to', test.id('zp_sales2')));
select test.eq('reassigned: the first salesperson sees it masked again', app.mask_phone_text(test.id('zp_sales'), 'Call 905-555-0171', null), 'Call ' || pg_temp.masked('71'));
select test.eq('reassigned: the new salesperson sees it masked (an Admin unlocks again)', pg_temp.phone('zp_sales2', 'zp1'), pg_temp.masked('71'));
select test.eq('reassigned: hidden by itself, audited',
  (select hidden_why from lead_phone_unlocks where lead_id = test.id('lead:zp1') and user_id = test.id('zp_sales')) || '/'
  || (select count(*) from audit_log where action = 'lead_phone_hide' and entity_id = test.id('lead:zp1')::text and after ->> 'why' = 'reassigned'), 'reassigned/1');
select pg_temp.dr('zp_admin', 'ops_do', 'lead_phone_unlock', jsonb_build_object('lead', test.id('lead:zp1')));
select test.eq('reassigned: unlocked again, for the new salesperson', pg_temp.phone('zp_sales2', 'zp1'), '905-555-0171');

-- ---------------------------------------------------------------- a changed phone is masked
update leads set phone = '905-555-0179' where id = test.id('lead:zp1');
select test.eq('a new phone on the lead is masked until an Admin shows it', pg_temp.phone('zp_sales2', 'zp1'), pg_temp.masked('79'));

select test.eq('the table and the functions are the server''s only',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname in ('lead_phone_unlock', 'lead_phone_hide', 'lead_phone_ask', 'lead_phone_state', 'phone_unlocked_for')
      and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute')))::int
  + (case when has_table_privilege('authenticated', 'lead_phone_unlocks', 'select') then 1 else 0 end), 0);
