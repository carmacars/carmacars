-- 99: the training academy (migrations 0207, 0208; Release 21b, item 9). Paths by function, sections opened in order by a
-- passed quiz (80%), retries, an Admin opening a section early, progress, editing, and the gate (off by default).
-- Fixtures start with "acd".
select test.suite('99 academy');

select test.mk_user('acd_admin', 'admin');
select test.mk_user('acd_cs', 'va', 'cs');
select test.mk_user('acd_sales', 'va', 'sales');
select test.mk_user('acd_field', 'field', null, 'driver');
select test.mk_user('acd_renter', 'renter');

-- ================================================================ 1. the content and the paths
select test.eq('seven paths', (select count(*)::int from academy_paths), 7);
select test.ok('every path has sections, every section lessons and at least 5 questions',
  not exists (select 1 from academy_paths p where not exists (select 1 from academy_path_sections ps where ps.path_code = p.code))
  and not exists (select 1 from academy_sections s where not exists (select 1 from academy_lessons l where l.section_id = s.id)
                    or (select count(*) from academy_questions q where q.section_id = s.id) < 5));
select test.ok('every scene has a caption, words and a known picture', not exists (
  select 1 from academy_lessons l, jsonb_array_elements(l.scenes) sc
   where coalesce(sc ->> 'caption', '') = '' or coalesce(sc ->> 'say', '') = '' or sc #>> '{visual,kind}' not in ('title', 'chat', 'list', 'steps', 'money', 'rule')));
select test.eq('customer service takes the customer service path', app.academy_paths_of(test.id('acd_cs')), array['cs']);
select test.eq('Sales in person by default', app.academy_paths_of(test.id('acd_sales')), array['sales_in_person']);
update staff_profiles set sales_work_mode = 'remote' where user_id = test.id('acd_sales');
select test.eq('remote Sales takes the remote path', app.academy_paths_of(test.id('acd_sales')), array['sales_remote']);
select test.eq('field work', app.academy_paths_of(test.id('acd_field')), array['field']);
select test.eq('an Admin takes the Admin path', app.academy_paths_of(test.id('acd_admin')), array['admin']);
select test.eq('the gate is off by default', (app.settings()).academy_gate, false);
select test.eq('the pass mark is 80%', (app.settings()).academy_pass_bps, 8000);

-- ================================================================ 2. the home, a section, the order
select test.eq('the home lists the path', public.door(test.id('acd_cs'), 'aal2', 'ops_read', 'academy_home', '{}') #>> '{paths,0,code}', 'cs');
select test.eq('the first section is open', (public.door(test.id('acd_cs'), 'aal2', 'ops_read', 'academy_home', '{}') #> '{paths,0,sections,0,open}')::boolean, true);
select test.eq('the second is closed', (public.door(test.id('acd_cs'), 'aal2', 'ops_read', 'academy_home', '{}') #> '{paths,0,sections,1,open}')::boolean, false);
select test.ok('a section reads its lessons, and its questions without the answers', (
  select jsonb_array_length(x -> 'lessons') > 0 and jsonb_array_length(x -> 'questions') >= 5 and not (x #> '{questions,0}' ? 'answer')
    from public.door(test.id('acd_cs'), 'aal2', 'ops_read', 'academy_section', '{"path": "cs", "section": "prices-and-deposits"}') x));
select test.throws('a closed section is refused',
  format($s$select public.door(%L, 'aal2', 'ops_read', 'academy_section', '{"path": "cs", "section": "coverage-and-drivers"}')$s$, test.id('acd_cs')), 'Pass the section before');
select test.throws('another function''s path is refused',
  format($s$select public.door(%L, 'aal2', 'ops_read', 'academy_section', '{"path": "finance", "section": "prices-and-deposits"}')$s$, test.id('acd_cs')), 'not one of yours');
select test.throws('a renter has no academy',
  format($s$select public.door(%L, 'aal1', 'ops_read', 'academy_home', '{}')$s$, test.id('acd_renter')), 'Staff only');
select test.eq('a lesson watched',
  public.door(test.id('acd_cs'), 'aal2', 'ops_do', 'academy_viewed', jsonb_build_object('lesson', (select l.id from academy_lessons l join academy_sections s on s.id = l.section_id where s.slug = 'prices-and-deposits' and l.sort = 1))) ->> 'ok', 'true');

-- ================================================================ 3. the quiz: graded in the database, 80% to pass, retries
create temp table acd_q as select q.id, q.answer, q.sort, jsonb_array_length(q.options) n from academy_questions q join academy_sections s on s.id = q.section_id where s.slug = 'prices-and-deposits';
-- every answer wrong
select test.eq('all wrong fails',
  (public.door(test.id('acd_cs'), 'aal2', 'ops_do', 'academy_quiz_submit', jsonb_build_object('section', 'prices-and-deposits',
     'answers', (select jsonb_object_agg(id::text, (answer + 1) % n) from acd_q))) ->> 'passed')::boolean, false);
select test.throws('every question answered',
  format($s$select public.door(%L, 'aal2', 'ops_do', 'academy_quiz_submit', '{"section": "prices-and-deposits", "answers": {}}')$s$, test.id('acd_cs')), 'Answer every question');
-- 4 of 6 right: 66%, under the mark
select test.eq('4 of 6 is under 80%',
  (public.door(test.id('acd_cs'), 'aal2', 'ops_do', 'academy_quiz_submit', jsonb_build_object('section', 'prices-and-deposits',
     'answers', (select jsonb_object_agg(id::text, case when sort <= 4 then answer else (answer + 1) % n end) from acd_q))) ->> 'score_bps')::int, 6666);
select test.eq('still closed after a fail', app.academy_open(test.id('acd_cs'), 'cs', (select id from academy_sections where slug = 'coverage-and-drivers')), false);
-- all right on a retry
select test.eq('a retry, all right, passes',
  (public.door(test.id('acd_cs'), 'aal2', 'ops_do', 'academy_quiz_submit', jsonb_build_object('section', 'prices-and-deposits',
     'answers', (select jsonb_object_agg(id::text, answer) from acd_q))) ->> 'passed')::boolean, true);
select test.eq('three attempts kept', (select count(*)::int from academy_attempts where user_id = test.id('acd_cs')), 3);
select test.eq('the next section opens', app.academy_open(test.id('acd_cs'), 'cs', (select id from academy_sections where slug = 'coverage-and-drivers')), true);
select test.eq('passed once counts on every path with that section (Admin path too)', app.academy_passed(test.id('acd_cs'), (select id from academy_sections where slug = 'prices-and-deposits')), true);

-- ================================================================ 4. Admin: progress, early opening, editing
select test.ok('progress lists the staff member with a section passed', exists (
  select 1 from jsonb_array_elements(public.door(test.id('acd_admin'), 'aal2', 'admin_read', 'academy_progress', '{}') -> 'staff') x
   where x ->> 'id' = test.id('acd_cs')::text and (x ->> 'passed')::int = 1));
select test.throws('progress is for Admins',
  format($s$select public.door(%L, 'aal2', 'admin_read', 'academy_progress', '{}')$s$, test.id('acd_cs')), 'Admins only');
select test.throws('opening early needs a reason',
  format($s$select public.door(%L, 'aal2', 'admin_do', 'academy_unlock', '{"user_id": "%s", "section": "%s", "reason": ""}')$s$, test.id('acd_admin'), test.id('acd_field'),
    (select id from academy_sections where slug = 'field-handover')), 'reason');
select public.door(test.id('acd_admin'), 'aal2', 'admin_do', 'academy_unlock', jsonb_build_object('user_id', test.id('acd_field'), 'section', (select id from academy_sections where slug = 'field-handover'), 'reason', 'Five years of handovers at another rental company'));
select test.eq('an Admin opens a section early', app.academy_open(test.id('acd_field'), 'field', (select id from academy_sections where slug = 'field-handover')), true);
select test.ok('the content reads with the answers for an Admin', (
  select (x #> '{questions,0}') ? 'answer' from public.door(test.id('acd_admin'), 'aal2', 'admin_read', 'academy_content', jsonb_build_object('section', (select id from academy_sections where slug = 'commission'))) x));
select test.throws('a scene needs a known picture',
  format($s$select public.door(%L, 'aal2', 'admin_do', 'academy_lesson_save', '{"section_id": "%s", "title": "x", "scenes": [{"caption": "c", "say": "s", "visual": {"kind": "video"}}]}')$s$,
    test.id('acd_admin'), (select id from academy_sections where slug = 'commission')), 'picture');
select test.ok('an Admin adds a lesson', (public.door(test.id('acd_admin'), 'aal2', 'admin_do', 'academy_lesson_save', jsonb_build_object('section_id', (select id from academy_sections where slug = 'commission'),
  'title', 'A worked month', 'scenes', '[{"caption": "60 rental days", "say": "Sixty rental days is the middle tier.", "visual": {"kind": "title", "heading": "15%"}}]'::jsonb)) ->> 'id') is not null);
select test.ok('an Admin changes a question', (public.door(test.id('acd_admin'), 'aal2', 'admin_do', 'academy_question_save', jsonb_build_object('id', (select q.id from academy_questions q join academy_sections s on s.id = q.section_id where s.slug = 'commission' and q.sort = 1),
  'prompt', 'Commission is a share of what?', 'options', '["The total", "The rental charge"]'::jsonb, 'answer', 1, 'explain', 'The rental charge only.')) ->> 'id') is not null);
select test.throws('the answer is one of the options',
  format($s$select public.door(%L, 'aal2', 'admin_do', 'academy_question_save', '{"section_id": "%s", "prompt": "p", "options": ["a", "b"], "answer": 2}')$s$,
    test.id('acd_admin'), (select id from academy_sections where slug = 'commission')));

-- ================================================================ 5. the gate
select test.eq('gate off: never locked', app.academy_locked(test.id('acd_field')), false);
select test.eq('my_roles says so', (public.my_roles(test.id('acd_field')) ->> 'academy_locked')::boolean, false);
update program_settings set academy_gate = true where id = (app.settings()).id;
select test.eq('gate on: a staff member with paths to pass is locked', app.academy_locked(test.id('acd_field')), true);
select test.eq('gate on: an Admin is never locked', app.academy_locked(test.id('acd_admin')), false);
update program_settings set academy_gate = false where id = (app.settings()).id;
