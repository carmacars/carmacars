-- 99: migration 2670 (release 42): the Call helper of the caller pop-up. Whoever has the pop-up (Admins, customer service,
-- Fleet) reads the greetings, the situations with their steps and the FAQ, with the settings' numbers filled in; only an
-- Admin changes them, every change is checked (steps, links, tokens) and audited. Fixtures start with "zch".
select test.suite('99 r42 call helper (2670)');
grant usage on schema test to service_role;

select test.mk_user('zch_admin', 'admin');
select test.mk_user('zch_cs', 'va', 'cs');
select test.mk_user('zch_fleet', 'va', 'fleet');
select test.mk_user('zch_sales', 'va', 'sales');
update users set full_name = 'Robin Example' where id = test.id('zch_cs');

create function test.zch(p_user text, p_call text default 'va_read') returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', p_call, 'call_helper', '{}'::jsonb) $$;
create function test.zch_save(p jsonb, p_user text default 'zch_admin', p_call text default 'admin_do') returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', p_call, 'call_helper_save', p) $$;

-- ================================================================ 1. the read
create table test.zch_r as select test.zch('zch_cs') as j;
select test.eq('read: the greeting is personalised with the first name of the person on the phone', (select j ->> 'staff' from test.zch_r), 'Robin');
select test.eq('read: the greeting for a caller we do not know is the owner''s sentence',
  (select j #>> '{greetings,unknown}' from test.zch_r), 'Thank you for calling CarmaCars, this is {staff}, how can I help?');
select test.ok('read: a greeting for each kind of caller', (select j -> 'greetings' ?& array['unknown', 'renter', 'renter_booking', 'lead', 'owner', 'staff'] from test.zch_r));
select test.eq('read: the ten situations, in order', (select string_agg(x ->> 'code', ',' order by n) from test.zch_r, jsonb_array_elements(j -> 'situations') with ordinality a(x, n)),
  'situation_new_booking,situation_change_booking,situation_late_return,situation_pickup_delivery,situation_deposit_payments,situation_insurance,situation_accident_damage,situation_complaint,situation_owner_listing,situation_job_applicant');
select test.ok('read: every situation has 3 to 6 steps', (select bool_and(jsonb_array_length(x -> 'steps') between 3 and 6) from test.zch_r, jsonb_array_elements(j -> 'situations') x));
select test.ok('read: the FAQ has questions and answers', (select jsonb_array_length(j -> 'faq') >= 10 and bool_and(length(x ->> 'q') > 5 and length(x ->> 'a') > 20) from test.zch_r, jsonb_array_elements(j -> 'faq') x group by j));
select test.ok('read: no settings token is left unfilled (only the call''s own words stay in braces)',
  (select not exists (select 1 from regexp_matches(j::text, '\{([a-z0-9_]+)\}', 'g') m where m[1] not in ('staff', 'caller', 'booking', 'car')) from test.zch_r));
select test.eq('read: customer service cannot edit', (select j ->> 'can_edit' from test.zch_r), 'false');
select test.eq('read: an Admin gets it, and may edit', test.zch('zch_admin', 'admin_read') ->> 'can_edit', 'true');
select test.lives('read: Fleet gets it (they have the caller pop-up)', $$ select test.zch('zch_fleet') $$);
select test.throws('read: Sales do not', $$ select test.zch('zch_sales') $$, '%Admins, customer service and Fleet%');

-- ================================================================ 2. the numbers come from the settings
select test.eq('facts: the late return grace is the fee default''s',
  app.call_helper_facts() ->> 'late_grace',
  (select d.grace_minutes || ' minutes' from fee_defaults d where d.fee_type_code = 'late_return_fee' and d.vehicle_class is null and d.effective_from <= app.local_date(now()) order by d.effective_from desc limit 1));
select test.eq('facts: the youngest renter is the Program setting', app.call_helper_facts() ->> 'min_age', (app.settings()).min_renter_age::text);
select test.ok('facts: the late return answer says the grace of the settings',
  (select x ->> 'a' like '%' || (app.call_helper_facts() ->> 'late_grace') || '%' from test.zch_r, jsonb_array_elements(j -> 'faq') x where x ->> 'code' = 'faq_late'));
-- the fee default changes: the answer changes with no release
create table test.zch_fee as select d.id, d.grace_minutes from fee_defaults d where d.fee_type_code = 'late_return_fee' and d.vehicle_class is null
   and d.effective_from <= app.local_date(now()) order by d.effective_from desc limit 1;
update fee_defaults d set grace_minutes = 47 from test.zch_fee f where d.id = f.id;
select test.ok('facts: change the fee default and the answer changes at once',
  (select x ->> 'a' like '%47 minutes%' from jsonb_array_elements(test.zch('zch_cs') -> 'faq') x where x ->> 'code' = 'faq_late'));
update fee_defaults d set grace_minutes = f.grace_minutes from test.zch_fee f where d.id = f.id;
select test.ok('facts: each fact names where it comes from, for the Admin',
  (select bool_and(x ->> 'from' is not null and x ->> 'value' is not null) and count(*) >= 15 from jsonb_array_elements(app.door(test.id('zch_admin'), 'aal2', 'admin_read', 'call_helper_admin', '{}') -> 'facts') x));

-- ================================================================ 3. an Admin changes it
select test.throws('save: customer service cannot change a script', $$ select test.zch_save(jsonb_build_object('kind', 'faq', 'title', 'A question', 'body', 'An answer'), 'zch_cs', 'va_do') $$, '%');
select test.throws('save: nor read the Admin page', $$ select app.door(test.id('zch_cs'), 'aal2', 'va_read', 'call_helper_admin', '{}') $$, '%');
select test.eq('save: an Admin changes the greeting',
  test.zch_save(jsonb_build_object('id', (select id from app.call_helper_items where code = 'greeting_unknown'), 'body', 'CarmaCars, {staff} speaking. How can I help?')) ->> 'ok', 'true');
select test.eq('save: the pop-up reads the new greeting', test.zch('zch_cs') #>> '{greetings,unknown}', 'CarmaCars, {staff} speaking. How can I help?');
select test.ok('save: the change is in the audit log with the words before and after',
  exists (select 1 from audit_log a where a.action = 'call_helper_change' and a.actor_user_id = test.id('zch_admin')
           and a.before ->> 'body' like 'Thank you for calling%' and a.after ->> 'body' like 'CarmaCars, {staff} speaking%'));
select test.throws('save: the greeting every other falls back to stays on',
  $$ select test.zch_save(jsonb_build_object('id', (select id from app.call_helper_items where code = 'greeting_unknown'), 'is_active', false)) $$, '%stays on%');
select test.eq('save: a new situation', test.zch_save(jsonb_build_object('kind', 'situation', 'title', 'Lost key', 'body', E'Ask where the car is.\n\nOpen [Bookings](/bookings).\nTell Fleet.')) ->> 'code', 'situation_lost_key');
select test.eq('save: its lines are its steps, empty lines dropped, after the others',
  (select (x -> 'steps')::text || '/' || n from jsonb_array_elements(test.zch('zch_cs') -> 'situations') with ordinality a(x, n) where x ->> 'code' = 'situation_lost_key'),
  '["Ask where the car is.", "Open [Bookings](/bookings).", "Tell Fleet."]/11');
select test.eq('save: switched off, it leaves the pop-up',
  (select test.zch_save(jsonb_build_object('id', (select id from app.call_helper_items where code = 'situation_lost_key'), 'is_active', false)) ->> 'ok')
    || '/' || (select count(*) from jsonb_array_elements(test.zch('zch_cs') -> 'situations') x where x ->> 'code' = 'situation_lost_key'), 'true/0');
select test.throws('save: a link leaves the portal only for an https address',
  $$ select test.zch_save(jsonb_build_object('kind', 'faq', 'title', 'Bad link', 'body', 'See [this](javascript:alert(1))')) $$, '%link goes to a page of the portal%');
select test.throws('save: nor to another site without https', $$ select test.zch_save(jsonb_build_object('kind', 'faq', 'title', 'Bad link', 'body', 'See [this](//example.test/x)')) $$, '%link goes to a page of the portal%');
select test.lives('save: an https address is allowed', $$ select test.zch_save(jsonb_build_object('kind', 'faq', 'title', 'Where is the policy?', 'body', 'At [the policy](https://example.test/policy).')) $$);
select test.throws('save: a token the helper does not know is refused, so no braces reach a caller',
  $$ select test.zch_save(jsonb_build_object('kind', 'faq', 'title', 'Bad token', 'body', 'The fee is {late_fee}.')) $$, '%not a word the helper fills in%');
select test.throws('save: a situation has 8 steps at most',
  $$ select test.zch_save(jsonb_build_object('kind', 'situation', 'title', 'Too long', 'body', E'1\n2\n3\n4\n5\n6\n7\n8\n9')) $$, '%8 steps at most%');
select test.throws('save: a greeting is not added', $$ select test.zch_save(jsonb_build_object('kind', 'greeting', 'title', 'Another', 'body', 'Hello')) $$, '%greetings are fixed%');
select test.throws('remove: a greeting is not removed',
  $$ select app.door(test.id('zch_admin'), 'aal2', 'admin_do', 'call_helper_remove', jsonb_build_object('id', (select id from app.call_helper_items where code = 'greeting_lead'))) $$, '%not removed%');
select test.eq('remove: an Admin removes a situation',
  app.door(test.id('zch_admin'), 'aal2', 'admin_do', 'call_helper_remove', jsonb_build_object('id', (select id from app.call_helper_items where code = 'situation_lost_key'))) ->> 'ok', 'true');
select test.eq('remove: it is gone, and kept in the audit log',
  (select count(*) from app.call_helper_items where code = 'situation_lost_key') || '/' || (select count(*) from audit_log where action = 'call_helper_remove' and before ->> 'code' = 'situation_lost_key'), '0/1');

-- ================================================================ 4. the server only
select test.ok('security: the table has row-level security and nothing for a browser role',
  (select c.relrowsecurity from pg_class c where c.oid = 'app.call_helper_items'::regclass)
  and not has_table_privilege('authenticated', 'app.call_helper_items', 'select') and not has_table_privilege('anon', 'app.call_helper_items', 'select'));
select test.ok('security: no helper function is executable by a browser role',
  (select bool_and(not has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute'))
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname like 'call_helper%'));

-- put the seed back as it was for the suites after this one
update app.call_helper_items set body = 'Thank you for calling CarmaCars, this is {staff}, how can I help?' where code = 'greeting_unknown';
delete from app.call_helper_items where code like 'faq_where_is_the_policy%';
update fee_defaults d set grace_minutes = f.grace_minutes from test.zch_fee f where d.id = f.id;
