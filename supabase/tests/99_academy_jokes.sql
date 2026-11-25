-- 99: the academy's funny wrong option (migration 4200, release 50; per question since 4720). A question carries 0 or 1 joke: its
-- own line of jokes-by-question.json (app.academy_question_joke_line), never one of the 4200 bank, never the right answer; the right
-- answer keeps pointing at the same option wherever the joke lands; a question saved again with its plain options gets its own joke
-- back; a question with no line gets none; and a joke is simply a wrong answer when the quiz is graded. Fixtures start with "acj".
select test.suite('99 academy jokes');

-- ================================================================ 1. the questions there are
select test.ok('the joke column names an option of the question, at most one', not exists (
  select 1 from academy_questions q where q.joke is not null
    and (select count(*) from jsonb_array_elements_text(q.options) o where o = q.joke) <> 1));
select test.ok('every joke is the question''s own line, never a bank joke', not exists (
  select 1 from academy_questions q join academy_sections s on s.id = q.section_id
   where q.joke is distinct from app.academy_question_joke_line(s.slug || ':' || q.sort, q.prompt)));
select test.eq('no option anywhere is a 4200 bank joke any more', (select count(*)::int from academy_questions q, jsonb_array_elements_text(q.options) o
  where o = any (app.academy_joke_bank())), 0);
select test.ok('about one question in three carries a joke, not all of them', (select count(*) filter (where joke is not null) * 1.0 / count(*) from academy_questions) between 0.2 and 0.5);
select test.ok('a joke is never the right answer, and the answer is inside the options', not exists (
  select 1 from academy_questions q where q.answer >= jsonb_array_length(q.options) or (q.options ->> q.answer) = q.joke));
select test.ok('no question has two options alike', not exists (
  select 1 from academy_questions q where (select count(distinct o) from jsonb_array_elements_text(q.options) o) <> jsonb_array_length(q.options)));
select test.ok('the joke is not always in the same place (shuffled)', (
  select count(distinct t.pos) from (select o.ord - 1 as pos from academy_questions q, jsonb_array_elements_text(q.options) with ordinality o(v, ord) where o.v = q.joke) t) >= 4);
select test.ok('serious questions carry no joke (the deductible, OPCF 27, 911)', not exists (
  select 1 from academy_questions q where q.joke is not null and (q.prompt ilike '%deductible%' or q.prompt ilike '%OPCF%' or q.prompt ilike '%hurt%' or q.prompt ilike '%licence%')));
select test.ok('every section has its See it lesson with a picture scene (4200)', not exists (
  select 1 from academy_sections s where not exists (select 1 from academy_lessons l, jsonb_array_elements(l.scenes) sc
    where l.section_id = s.id and l.title = 'See it' and sc -> 'visual' ->> 'kind' in ('pic', 'compare', 'flow', 'dodont', 'icons')
      and length(coalesce(sc -> 'visual' ->> 'alt', '')) >= 12)));

-- ================================================================ 2. a question saved: its own joke or none, the right answer kept
-- a question with a line: cs-requests 2 ("What is the first reply target in opening hours?")
create temp table acj_one as select q.id, q.options, q.answer, q.joke, q.options ->> q.answer as right_text
  from academy_questions q join academy_sections s on s.id = q.section_id where s.slug = 'cs-requests' and q.sort = 2;
select test.ok('cs-requests 2 carries its own joke', (select joke from acj_one) = app.academy_question_joke_line('cs-requests:2', (select prompt from academy_questions where id = (select id from acj_one))));
update academy_questions set options = (select jsonb_agg(o) from jsonb_array_elements(options) o where o #>> '{}' <> joke),
       answer = (select count(*)::int from jsonb_array_elements(options) with ordinality t(o, n) where n - 1 < answer and o #>> '{}' <> joke)
 where id = (select id from acj_one);
select test.ok('saved again with its plain options: the same joke comes back, at the same place, the right answer the same option',
  (select q.options = a.options and q.answer = a.answer and q.joke = a.joke and q.options ->> q.answer = a.right_text from academy_questions q, acj_one a where q.id = a.id));
update academy_questions set options = options, explain = explain where id = (select id from acj_one);
select test.ok('saved with its joke: still exactly one', (select count(*) from academy_questions q, jsonb_array_elements_text(q.options) o where q.id = (select id from acj_one) and o = q.joke) = 1);
-- the prompt changes: the line was written for the old prompt, so the joke goes
update academy_questions set prompt = prompt || ' (reworded)' where id = (select id from acj_one);
select test.ok('a reworded question loses the joke written for the old prompt, and keeps its right answer',
  (select q.joke is null and jsonb_array_length(q.options) = jsonb_array_length(a.options) - 1 and q.options ->> q.answer = a.right_text from academy_questions q, acj_one a where q.id = a.id));
update academy_questions set prompt = replace(prompt, ' (reworded)', '') where id = (select id from acj_one);
select test.ok('and the prompt put back brings its joke back', (select q.joke = a.joke and q.options ->> q.answer = a.right_text from academy_questions q, acj_one a where q.id = a.id));

-- brand-new questions: no line, no joke; a bank joke saved in is taken out
insert into academy_sections (slug, title, blurb) values ('acj-probe', 'Joke probe', 'A section for the joke tests.');
insert into academy_questions (section_id, sort, prompt, options, answer, explain)
select (select id from academy_sections where slug = 'acj-probe'), i, 'Joke probe question number ' || i, '["alpha","bravo","charlie","delta"]'::jsonb, i % 4, 'because'
  from generate_series(1, 20) i;
select test.ok('a new question with no written line gets no joke (no bank fallback)', not exists (
  select 1 from academy_questions q where q.section_id = (select id from academy_sections where slug = 'acj-probe') and (q.joke is not null or jsonb_array_length(q.options) <> 4)));
update academy_questions set options = jsonb_build_array('alpha', (app.academy_joke_bank())[1], 'bravo', 'charlie'), answer = 3
 where section_id = (select id from academy_sections where slug = 'acj-probe') and sort = 3;
select test.ok('a bank joke saved into a question is taken out, the right answer still "charlie"', (select options = '["alpha","bravo","charlie"]'::jsonb and options ->> answer = 'charlie' and joke is null
  from academy_questions where section_id = (select id from academy_sections where slug = 'acj-probe') and sort = 3));
select test.throws('the right answer cannot be a joke', $$update academy_questions set options = jsonb_build_array('alpha', (app.academy_joke_bank())[1]), answer = 1
  where section_id = (select id from academy_sections where slug = 'acj-probe') and sort = 4$$, 'The right answer cannot be a joke');
delete from academy_sections where slug = 'acj-probe';

-- ================================================================ 3. grading is unchanged: the joke is simply wrong
select test.mk_user('acj_admin', 'admin');
create temp table acj_q as select q.id, q.answer, q.options, q.sort,
  (select (ord - 1)::int from jsonb_array_elements_text(q.options) with ordinality t(x, ord) where x = q.joke) as joke
  from academy_questions q join academy_sections s on s.id = q.section_id where s.slug = 'new-r35-team-rules';
select test.ok('new-r35-team-rules: four of its questions carry a joke', (select count(*) from acj_q where joke is not null) = 4);
-- an Admin takes the quiz: every answer the joke (wrong), then every answer right
select test.eq('picking the joke (or another wrong option) on every question scores zero', (public.door(test.id('acj_admin'), 'aal2', 'ops_do', 'academy_quiz_submit', jsonb_build_object('section', 'new-r35-team-rules',
  'answers', (select jsonb_object_agg(id::text, coalesce(joke, (answer + 1) % jsonb_array_length(options))) from acj_q))) ->> 'correct')::int, 0);
select test.eq('picking the right option on every question scores every question', (public.door(test.id('acj_admin'), 'aal2', 'ops_do', 'academy_quiz_submit', jsonb_build_object('section', 'new-r35-team-rules',
  'answers', (select jsonb_object_agg(id::text, answer) from acj_q))) ->> 'correct')::int, (select count(*)::int from acj_q));
-- the quiz hands out where the joke is shown (questions[].joke), for its playful line; null on a question without one
select test.ok('the started quiz names the shown position of each joke, and only of a joke', not exists (
  select 1 from jsonb_array_elements(app.academy_quiz_start(test.id('acj_admin'), jsonb_build_object('section', 'new-r35-team-rules')) -> 'questions') x
    join academy_questions q on q.id = (x ->> 'id')::uuid
   where (x ->> 'joke') is distinct from (select (n - 1)::text from jsonb_array_elements_text(x -> 'options') with ordinality t(o, n) where o = q.joke)));
