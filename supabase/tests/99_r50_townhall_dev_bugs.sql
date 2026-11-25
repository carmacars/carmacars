-- 99: the townhall's Platform updates slide: bugs fixed this week (migration 4620). Fixtures start with "th7".
select test.suite('99 r50 townhall dev: bugs fixed');
select test.mk_user('th7_admin', 'admin');
select test.mk_user('th7_cs', 'va', 'cs');
create temp table th7_w as select (date_trunc('week', app.today()::timestamp))::date w;
create temp table th7_b as select app.townhall_bug_facts((select w from th7_w)) before;
insert into bug_reports (reporter_id, happened, severity, page_path, status, admin_notes, fixed_in, status_changed_at) values
  (test.id('th7_cs'), 'The totals on the money page are off by one cent today.', 'cosmetic', '/staff/money', 'fixed', E'Rounded the total once.\nInternal detail', 'r50', now()),
  (test.id('th7_cs'), 'The save button on the renters page does nothing when clicked.', 'annoying', '/staff/renters', 'fixed', null, 'r50', now()),
  (test.id('th7_cs'), 'An old bug fixed long before this townhall week began at all.', 'annoying', '/staff/renters', 'fixed', 'Old fix', 'r40', now() - interval '60 days'),
  (test.id('th7_cs'), 'Still broken: the calendar will not scroll on a small phone.', 'blocks_work', '/staff/today', 'new', null, null, null);
select app.townhall_build((select w from th7_w), test.id('th7_admin'));
create function test.th7_dev() returns jsonb language sql as $$
  select s from townhall_decks d, jsonb_array_elements(d.slides) s where d.week_of = (select w from th7_w) and s ->> 'key' = 'dev' $$;
create function test.th7_point(p_label text) returns text language sql as $$
  select p ->> 'value' from jsonb_array_elements(test.th7_dev() -> 'points') p where p ->> 'label' = p_label $$;

select test.eq('bugs fixed: counts only this week''s fixes', test.th7_point('Bugs fixed this week')::int - (select (before ->> 'fixed')::int from th7_b), 2);
select test.eq('bugs open: counts new and triaged', test.th7_point('Bugs still open')::int - (select (before ->> 'open')::int from th7_b), 1);
select test.ok('a line says what was wrong, what was fixed and thanks the reporter',
  exists (select 1 from jsonb_array_elements_text(test.th7_dev() -> 'bug_lines') l where l like 'The totals on the money page%Fixed: Rounded the total once.%Thanks, %'));
select test.ok('the line keeps only the first line of the note', not exists (select 1 from jsonb_array_elements_text(test.th7_dev() -> 'bug_lines') l where l like '%Internal detail%'));
select test.ok('without a note, the release says what was fixed', exists (select 1 from jsonb_array_elements_text(test.th7_dev() -> 'bug_lines') l where l like 'The save button%Fixed: fixed in r50%'));
select test.ok('the old fix is not in the week', not exists (select 1 from jsonb_array_elements_text(test.th7_dev() -> 'bug_lines') l where l like 'An old bug%'));
select test.ok('the reporter is a shout-out with their count', exists (select 1 from jsonb_array_elements(test.th7_dev() -> 'reporters') r where r ->> 'user_id' = test.id('th7_cs')::text and (r ->> 'fixed')::int = 2));
select test.eq('the run is still 30 minutes', (select sum((s ->> 'minutes')::int) from jsonb_array_elements((select slides from townhall_decks where week_of = (select w from th7_w))) s), 30::bigint);
select test.ok('only the server calls the helpers', not has_function_privilege('authenticated', 'app.townhall_bug_facts(date)', 'execute') and has_function_privilege('service_role', 'app.townhall_bug_facts(date)', 'execute'));
