-- 99: release 48 in the academy (2990, 2991): a section of worked examples from the guide for every role, the shared path
-- The renter's side for every staff member, the screenshot scene, and the path required of new hires and given to staff
-- already working with 7 days. Fixtures start with "r48a".
select test.suite('99 r48 academy guides');

select test.mk_user('r48a_cs', 'va', 'cs');
select test.mk_user('r48a_hire', 'va', 'cs');
select test.mk_user('r48a_field', 'field', null, 'driver');
select test.mk_user('r48a_admin', 'admin');
select test.mk_user('r48a_renter', 'renter');

-- ================================================================ 1. the content
select test.eq('the renter''s side: its nine steps, in order', (select string_agg(s.slug, ' ' order by ps.sort) from academy_path_sections ps join academy_sections s on s.id = ps.section_id where ps.path_code = 'renter_side'),
  'r48-renter-request r48-renter-offer r48-renter-details-sign r48-renter-pay-deposit r48-renter-coverage r48-renter-pickup r48-renter-trip-extend r48-renter-return-deposit r48-renter-errors');
select test.eq('every role path has its worked examples from the guide', (select string_agg(ps.path_code || ':' || s.slug, ' ' order by ps.path_code) from academy_path_sections ps join academy_sections s on s.id = ps.section_id where s.slug like 'r48-%-guide-cases'),
  'admin:r48-admin-guide-cases cs:r48-cs-guide-cases field:r48-field-guide-cases finance:r48-finance-guide-cases fleet:r48-fleet-guide-cases sales_in_person:r48-sales-guide-cases sales_remote:r48-sales-guide-cases');
select test.eq('quiz integrity: every release 48 section has at least 5 questions, 4 options each, the answer in range and a reason',
  (select count(*) from academy_sections s where s.slug like 'r48-%' and (
     (select count(*) from academy_questions q where q.section_id = s.id) < 5
     or exists (select 1 from academy_questions q where q.section_id = s.id and (jsonb_array_length(q.options) <> 4 or q.answer not between 0 and jsonb_array_length(q.options) - 1 or btrim(q.explain) = '')))), 0::bigint);
select test.eq('the counts: 15 sections, 85 questions', (select count(*) || '/' || (select count(*) from academy_questions q join academy_sections x on x.id = q.section_id where x.slug like 'r48-%') from academy_sections s where s.slug like 'r48-%'), '15/85');
select test.eq('each renter step shows a page of the renter guide that the section names', (select count(*) from academy_sections s
  where s.slug like 'r48-renter-%' and not exists (select 1 from academy_lessons l, jsonb_array_elements(l.scenes) sc where l.section_id = s.id and sc #>> '{visual,kind}' = 'shot'
    and sc #>> '{visual,guide}' like 'renter/%' and (sc #>> '{visual,guide}') = any (s.guide_refs))), 0::bigint);
select test.eq('each role section has a worked example (a chat)', (select count(*) from academy_sections s
  where s.slug like 'r48-%-guide-cases' and not exists (select 1 from academy_lessons l, jsonb_array_elements(l.scenes) sc where l.section_id = s.id and sc #>> '{visual,kind}' = 'chat')), 0::bigint);
select test.eq('no long dash and no vendor name in the lessons', (select count(*) from academy_lessons l join academy_sections s on s.id = l.section_id
  where s.slug like 'r48-%' and (l.scenes::text ~ '[–—]' or regexp_replace(l.scenes::text, '"img": "[^"]*"', '', 'g') ~* '(google|stripe|quo\M|openphone|cloudflare|claude|gemini)')), 0::bigint);
select app.academy_check_scenes('[{"caption": "The offer", "say": "What the renter sees.", "visual": {"kind": "shot", "heading": "Trips", "guide": "renter/your-offer", "img": "renter-02-trips-offer-desktop-27603c14.jpg"}}]');
select test.ok('a guide screenshot is a scene an Admin can save', true);
select test.throws('an unknown picture is still refused', $$select app.academy_check_scenes('[{"caption": "x", "visual": {"kind": "video"}}]')$$, '%or shot%');

-- ================================================================ 2. the path for every staff member
select test.eq('staff with a path get The renter''s side', array_to_string(app.academy_paths_of(test.id('r48a_cs')), ',') || ' ' || array_to_string(app.academy_paths_of(test.id('r48a_field')), ',') || ' ' || array_to_string(app.academy_paths_of(test.id('r48a_admin')), ','),
  'cs,renter_side field,renter_side admin,renter_side');
select test.eq('a renter has no path', cardinality(app.academy_paths_of(test.id('r48a_renter'))), 0);
select test.eq('the home lists it after the role''s path', (select string_agg(p ->> 'code', ',') from jsonb_array_elements(public.door(test.id('r48a_cs'), 'aal2', 'ops_read', 'academy_home', '{}') -> 'paths') p), 'cs,renter_side');

-- ================================================================ 3. required of new hires (the hire's enrollment), due in 7 days for staff already working
select app.academy_enroll(test.id('r48a_hire'), test.id('r48a_admin'), 'hire', now());
select test.eq('a hire is enrolled on The renter''s side, gated', (select string_agg(path_code || ':' || gate, ',' order by path_code) from academy_enrollments where user_id = test.id('r48a_hire')), 'cs:true,renter_side:true');
insert into academy_attempts (user_id, section_id, correct, total, score_bps, passed)
select test.id('r48a_hire'), ps.section_id, 1, 1, 10000, true from academy_path_sections ps where ps.path_code = 'cs';
select test.eq('the hire''s own path passed: still held by The renter''s side', app.academy_locked(test.id('r48a_hire')) || '/' || app.academy_done(test.id('r48a_hire')), 'true/false');
insert into academy_attempts (user_id, section_id, correct, total, score_bps, passed)
select test.id('r48a_hire'), ps.section_id, 1, 1, 10000, true from academy_path_sections ps where ps.path_code = 'renter_side';
select test.eq('both passed: the academy is done', app.academy_locked(test.id('r48a_hire')) || '/' || app.academy_done(test.id('r48a_hire')), 'false/true');
-- staff already working: their enrollments' lock_from 7 days out (what 2990 gives those who had passed everything)
insert into academy_enrollments (user_id, path_code, gate, lock_from, source) select test.id('r48a_cs'), c, true, now() + interval '7 days', 'admin' from unnest(app.academy_paths_of(test.id('r48a_cs'))) c
on conflict (user_id, path_code) do update set lock_from = excluded.lock_from, source = 'admin';
select test.eq('staff already working: not held during the 7 days, the date on the academy page', app.academy_locked(test.id('r48a_cs')) || '/' || ((public.door(test.id('r48a_cs'), 'aal2', 'ops_read', 'academy_home', '{}') ->> 'lock_from')::timestamptz > now() + interval '6 days'), 'false/true');
update academy_enrollments set lock_from = now() - interval '1 minute' where user_id = test.id('r48a_cs');
select test.eq('after the 7 days: held until the new sections are passed', app.academy_locked(test.id('r48a_cs')), true);
