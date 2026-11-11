-- 99: migration 0802 (release 34, part N): the academy gate. A new hire opens only the academy, the guide, their profile and
-- Welcome until every section of their path is passed (each quiz at 80%, retakes allowed); an Admin waives it for one
-- person with a reason; the content of releases 33 and 34 is on the paths of the roles that use it, with a quiz per
-- section; a guide chapter published again flags the sections written from it. Fixtures start with "zag"; example.test only.
select test.suite('99 r34n academy gate (0802)');
grant usage on schema test to service_role;

select test.mk_user('zag_admin', 'admin');
select test.mk_user('zag_cs', 'va', 'cs');
select test.mk_user('zag_field', 'field');
select test.mk_user('zag_other', 'va', 'cs');
update program_settings set academy_gate = true;
select app.academy_enroll(test.id('zag_cs'), test.id('zag_admin'), 'hire', now());
select app.academy_enroll(test.id('zag_field'), test.id('zag_admin'), 'hire', now());
select app.academy_enroll(test.id('zag_other'), test.id('zag_admin'), 'hire', now());
select test.mk_user('zag_old', 'va', 'cs');
create function test.zag_locked(p text) returns boolean language sql as $$ select (app.my_roles(test.id(p)) ->> 'academy_locked')::boolean $$;

-- ================================================================ 1. the gate
select test.eq('gate: a new customer service hire is held', test.zag_locked('zag_cs'), true);
select test.eq('gate: a new field hire is held', test.zag_locked('zag_field'), true);
select test.eq('gate: an Admin is never held', test.zag_locked('zag_admin'), false);
select test.eq('gate: staff already working, with no enrollment from Hire or an Admin, are never held (0840)', test.zag_locked('zag_old'), false);

-- ================================================================ 2. the content of releases 33 and 34
select test.eq('content: the four new sections are on the paths of the roles that use them',
  (select string_agg(s.slug || ':' || (select string_agg(ps.path_code, ',' order by ps.path_code) from academy_path_sections ps where ps.section_id = s.id), ' ' order by s.slug)
     from academy_sections s where s.slug in ('new-r33-bookings', 'new-r33-money', 'new-r33-photos', 'new-r34-caller-notes')),
  'new-r33-bookings:admin,cs,field,fleet,sales_in_person,sales_remote new-r33-money:admin,finance new-r33-photos:admin,cs,fleet new-r34-caller-notes:admin,cs,sales_in_person,sales_remote');
select test.eq('content: every section of every path has lessons and a quiz', (select count(*) from academy_path_sections ps
  where not exists (select 1 from academy_questions q where q.section_id = ps.section_id) or not exists (select 1 from academy_lessons l where l.section_id = ps.section_id)), 0::bigint);
select test.eq('content: each new section names the guide chapters it was written from', (select count(*) from academy_sections where slug like 'new-r3%' and slug in ('new-r33-bookings', 'new-r33-money', 'new-r33-photos', 'new-r34-caller-notes') and cardinality(guide_refs) > 0), 4::bigint);
select test.eq('content: no vendor names in the new sections', (select count(*) from academy_lessons l join academy_sections s on s.id = l.section_id
  where s.slug in ('new-r33-bookings', 'new-r33-money', 'new-r33-photos', 'new-r34-caller-notes') and l.scenes::text ~* '(google|stripe|quo\M|openphone|cloudflare|claude)'), 0::bigint);

-- ================================================================ 3. passing: 90% (1154), retakes
-- every section before the last on the path passed; then the last one's quiz
insert into academy_attempts (user_id, section_id, correct, total, score_bps, passed)
select test.id('zag_cs'), ps.section_id, 1, 1, 10000, true from academy_path_sections ps join academy_sections s on s.id = ps.section_id
 where ps.path_code = 'cs' and s.slug <> 'new-r34-caller-notes';
select test.eq('passing: one section left, still held', test.zag_locked('zag_cs'), true);
-- 1154: the quiz is started first (its reading time and cooldown have a suite of their own: off here)
update program_settings set academy_read_wpm = 0, academy_fail_cooldown_minutes = 0 where id = (app.settings()).id;
create function test.zag_quiz(p_right integer) returns jsonb language sql as $$
  select app.academy_quiz_start(test.id('zag_cs'), '{"section": "new-r34-caller-notes"}');
  select app.academy_quiz_submit(test.id('zag_cs'), jsonb_build_object('section', 'new-r34-caller-notes', 'answers',
    (select jsonb_object_agg(q.id::text, case when q.sort <= p_right then q.answer else (q.answer + 1) % jsonb_array_length(q.options) end)
       from academy_questions q join academy_sections s on s.id = q.section_id where s.slug = 'new-r34-caller-notes'))) $$;
select test.eq('passing: 3 of 5 right (60%) is not a pass', (select (x ->> 'passed') || '/' || (x ->> 'score_bps') from test.zag_quiz(3) x), 'false/6000');
select test.eq('passing: still held after a failed quiz', test.zag_locked('zag_cs'), true);
select test.eq('passing: 4 of 5 (80%) is under the 90% mark (1154)', (select (x ->> 'passed') || '/' || (x ->> 'score_bps') from test.zag_quiz(4) x), 'false/8000');
select test.eq('passing: a retake with 5 of 5 passes', (select (x ->> 'passed') || '/' || (x ->> 'score_bps') from test.zag_quiz(5) x), 'true/10000');
select test.eq('passing: every section passed opens the portal', test.zag_locked('zag_cs'), false);
select test.eq('passing: the three attempts are kept', (select count(*) from academy_attempts a join academy_sections s on s.id = a.section_id where a.user_id = test.id('zag_cs') and s.slug = 'new-r34-caller-notes'), 3::bigint);

-- ================================================================ 4. the waiver
select test.throws('waiver: staff cannot waive', format($$ select app.door(%L, 'aal2', 'admin_do', 'academy_waive', jsonb_build_object('user_id', %L, 'reason', 'experienced')) $$, test.id('zag_other'), test.id('zag_field')), '%Admin%');
select test.throws('waiver: an Admin gives a reason', format($$ select app.door(%L, 'aal2', 'admin_do', 'academy_waive', jsonb_build_object('user_id', %L)) $$, test.id('zag_admin'), test.id('zag_field')), '%reason%');
select test.eq('waiver: waived for one person, with the reason and who',
  (select (x ->> 'locked') || '/' || (x #>> '{waiver,reason}') || '/' || (x #>> '{waiver,by}') from app.door(test.id('zag_admin'), 'aal2', 'admin_do', 'academy_waive',
     jsonb_build_object('user_id', test.id('zag_field'), 'reason', 'Ten years of handovers at another rental company')) x),
  'false/Ten years of handovers at another rental company/Zag Admin');
select test.eq('waiver: the person''s portal opens', test.zag_locked('zag_field'), false);
select test.eq('waiver: in the audit log', (select count(*) from audit_log where entity_table = 'academy_waivers' and entity_id is not null and actor_user_id = test.id('zag_admin')) >= 1, true);
select test.eq('waiver: the other hire is still held', (select app.academy_locked(test.id('zag_other'))), true);
select app.door(test.id('zag_admin'), 'aal2', 'admin_do', 'academy_waive', jsonb_build_object('user_id', test.id('zag_field'), 'on', false));
select test.eq('waiver: taken back, held again', test.zag_locked('zag_field'), true);

-- ================================================================ 5. Welcome
create table test.zag_t as select app.raise_task(p_type => 'first_day', p_title => 'First day: read your guide', p_detail => 'Guide in your portal', p_related_table => 'users', p_related_id => test.id('zag_field'),
  p_due_at => now(), p_priority => 'normal', p_dedupe => 'zag:first', p_queue => 'fleet', p_created_by => test.id('zag_admin')) as id;
update tasks set assigned_to = test.id('zag_field') where id = (select id from test.zag_t);
create table test.zag_w as select app.door(test.id('zag_field'), 'aal2', 'ops_read', 'staff_welcome', '{}'::jsonb) as j;
select test.eq('welcome: the steps in order (1060: the agreement and the team group after the academy; 1154: then the approval; 1770: a field person''s availability after the profile)', (select string_agg(x ->> 'key', ',') from test.zag_w, jsonb_array_elements(j -> 'steps') x), 'welcome,profile,availability,academy,agreement,team,approval,tasks');
select test.eq('welcome: a field hire, held, with the academy not done and the first task open',
  (select (j ->> 'portal') || '/' || (j ->> 'locked') || '/' || (j #>> '{steps,3,done}') || '/' || (j #>> '{steps,7,done}') || '/' || jsonb_array_length(j #> '{steps,7,tasks}') from test.zag_w), 'field/true/false/false/1');
select test.throws('welcome: nobody ticks another person''s task', format($$ select app.door(%L, 'aal2', 'ops_do', 'staff_welcome_task', jsonb_build_object('id', %L)) $$,
  test.id('zag_other'), (select id from test.zag_t)), '%not one of your%');
select app.door(test.id('zag_field'), 'aal2', 'ops_do', 'staff_welcome_task', jsonb_build_object('id', (select id from test.zag_t)));
select test.eq('welcome: the hire ticks off their own first task', (select app.staff_welcome(test.id('zag_field')) #>> '{steps,6,done}'), 'true');

-- ================================================================ 6. kept up to date with the guides
-- the chapter as published (the local guides are seeded outside the migrations), then published again
insert into guide_sections (portal, kind, sort_order, slug, title, body_md, published_version)
select 'va', 'chapter', 9990, 'texts-and-calls', 'Texts and calls', 'Text', 1 where not exists (select 1 from guide_sections where portal = 'va' and slug = 'texts-and-calls');
update guide_sections set published_version = coalesce(published_version, 0) + 1 where portal = 'va' and slug = 'texts-and-calls';
select test.eq('review: a guide chapter published again flags the sections written from it',
  (select string_agg(slug, ',' order by slug) from academy_sections where review_due_at is not null and 'va/texts-and-calls' = any (guide_refs)), 'new-r34-caller-notes');
select test.ok('review: the note names the chapter', (select review_note like '%va/texts-and-calls%' from academy_sections where slug = 'new-r34-caller-notes'));
select test.eq('review: Admin > Academy lists it', (select count(*) from jsonb_array_elements(app.door(test.id('zag_admin'), 'aal2', 'admin_read', 'academy_reviews', '{}'::jsonb)) x where x ->> 'slug' = 'new-r34-caller-notes'), 1::bigint);
select app.door(test.id('zag_admin'), 'aal2', 'admin_do', 'academy_review_done', jsonb_build_object('id', 'new-r34-caller-notes'));
select test.eq('review: marked reviewed, the flag clears', (select (review_due_at is null)::text || '/' || (reviewed_by = test.id('zag_admin'))::text from academy_sections where slug = 'new-r34-caller-notes'), 'true/true');
select test.eq('the door still answers what it did before', (select app.door(test.id('zag_cs'), 'aal2', 'ops_read', 'academy_home', '{}'::jsonb) ? 'paths'), true);

-- leave no unprocessed events for the suites after this one (99_staff_alerts counts the Admin digest)
select app.process_events(1000) >= 0 as processed;
-- 1154's settings back to their defaults for the suites after this one
update program_settings set academy_read_wpm = 200, academy_fail_cooldown_minutes = 30 where id = (app.settings()).id;
