-- 99: the academy's funny wrong option (migration 4200, release 50). Every question carries exactly one joke from the bank, it is
-- never the right answer, the right answer keeps pointing at the same option wherever the joke lands, a question saved again with
-- its plain options gets its joke back, and a joke is simply a wrong answer when the quiz is graded. Fixtures start with "acj".
select test.suite('99 academy jokes');

-- ================================================================ 1. the questions there are
select test.ok('the bank has jokes and every one is different', cardinality(app.academy_joke_bank()) >= 50
  and (select count(distinct j) from unnest(app.academy_joke_bank()) j) = cardinality(app.academy_joke_bank()));
select test.eq('every question has exactly one joke option', (select count(*)::int from academy_questions q
  where (select count(*) from jsonb_array_elements_text(q.options) o where o = any (app.academy_joke_bank())) <> 1), 0);
select test.ok('a joke is never the right answer, and the answer is inside the options', not exists (
  select 1 from academy_questions q where q.answer >= jsonb_array_length(q.options) or (q.options ->> q.answer) = any (app.academy_joke_bank())));
select test.ok('no question has two options alike', not exists (
  select 1 from academy_questions q where (select count(distinct o) from jsonb_array_elements_text(q.options) o) <> jsonb_array_length(q.options)));
select test.ok('the joke is not always in the same place (shuffled)', (
  select count(distinct t.pos) from (select o.ord - 1 as pos from academy_questions q, jsonb_array_elements_text(q.options) with ordinality o(v, ord) where o.v = any (app.academy_joke_bank())) t) >= 4);
select test.ok('a section does not repeat a joke', not exists (
  select 1 from academy_questions q, jsonb_array_elements_text(q.options) o where o = any (app.academy_joke_bank())
  group by q.section_id, o having count(*) > 1));
select test.ok('every section has its See it lesson with a picture scene (4200)', not exists (
  select 1 from academy_sections s where not exists (select 1 from academy_lessons l, jsonb_array_elements(l.scenes) sc
    where l.section_id = s.id and l.title = 'See it' and sc -> 'visual' ->> 'kind' in ('pic', 'compare', 'flow', 'dodont', 'icons')
      and length(coalesce(sc -> 'visual' ->> 'alt', '')) >= 12)));

-- ================================================================ 2. a question saved: the joke, the position, the answer
insert into academy_sections (slug, title, blurb) values ('acj-probe', 'Joke probe', 'A section for the joke tests.');
do $$
declare
  v_sec uuid := (select id from academy_sections where slug = 'acj-probe');
  v_ok boolean := true; v_one boolean := true; v_len boolean := true; v_pos int[] := '{}';
  v_o jsonb; v_a int; r record; v_want text;
  v_plain jsonb[] := array['["alpha","bravo","charlie","delta"]'::jsonb, '["Yes","No"]'::jsonb, '["one","two","three","four","five","six"]'::jsonb];
begin
  for i in 1..60 loop
    v_o := v_plain[1 + i % 3];
    v_a := i % jsonb_array_length(v_o);
    v_want := v_o ->> v_a;
    insert into academy_questions (section_id, sort, prompt, options, answer, explain) values (v_sec, i, 'Joke probe question number ' || i, v_o, v_a, 'because');
    select options, answer into r from academy_questions where section_id = v_sec and sort = i;
    v_ok := v_ok and (r.options ->> r.answer) = v_want;
    v_one := v_one and (select count(*) from jsonb_array_elements_text(r.options) x where x = any (app.academy_joke_bank())) = 1;
    v_len := v_len and jsonb_array_length(r.options) = jsonb_array_length(v_o) + 1;
    v_pos := v_pos || (select (ord - 1)::int from jsonb_array_elements_text(r.options) with ordinality t(x, ord) where x = any (app.academy_joke_bank()));
  end loop;
  perform test.ok('the right answer keeps pointing at the same option wherever the joke lands (60 questions)', v_ok);
  perform test.ok('each new question gets exactly one joke, and one option more', v_one and v_len);
  perform test.ok('the joke lands in more than one place', (select count(distinct p) from unnest(v_pos) p) >= 3, array_to_string(v_pos, ','));
  perform test.ok('the joke lands first and last too, not only in the middle', 0 = any (v_pos) and 4 = any (v_pos), array_to_string(v_pos, ','));
end $$;
select test.ok('60 probe questions in one section repeat no joke', not exists (
  select 1 from academy_questions q, jsonb_array_elements_text(q.options) o where q.section_id = (select id from academy_sections where slug = 'acj-probe') and o = any (app.academy_joke_bank())
  group by o having count(*) > 1));

-- saved again with the plain options (a generator, a migration or an Admin): the joke comes back, the answer follows
update academy_questions set options = '["alpha","bravo","charlie","delta"]'::jsonb, answer = 2
 where section_id = (select id from academy_sections where slug = 'acj-probe') and sort = 3;
select test.eq('a question saved again with its plain options gets a joke again', (select jsonb_array_length(options) from academy_questions
  where section_id = (select id from academy_sections where slug = 'acj-probe') and sort = 3), 5);
select test.eq('and the right answer is still "charlie"', (select options ->> answer from academy_questions
  where section_id = (select id from academy_sections where slug = 'acj-probe') and sort = 3), 'charlie');
-- saved with its joke: nothing is added
update academy_questions set explain = 'again' where section_id = (select id from academy_sections where slug = 'acj-probe') and sort = 3;
update academy_questions set options = options where section_id = (select id from academy_sections where slug = 'acj-probe') and sort = 3;
select test.eq('a question that already has its joke keeps exactly one', (select count(*)::int from academy_questions q, jsonb_array_elements_text(q.options) o
  where q.section_id = (select id from academy_sections where slug = 'acj-probe') and q.sort = 3 and o = any (app.academy_joke_bank())), 1);
delete from academy_sections where slug = 'acj-probe';

-- ================================================================ 3. grading is unchanged: the joke is simply wrong
select test.mk_user('acj_admin', 'admin');
create temp table acj_q as select q.id, q.answer, q.options, q.sort,
  (select (ord - 1)::int from jsonb_array_elements_text(q.options) with ordinality t(x, ord) where x = any (app.academy_joke_bank())) as joke
  from academy_questions q join academy_sections s on s.id = q.section_id where s.slug = 'prices-and-deposits';
select test.ok('prices-and-deposits: its questions each carry a joke', (select count(*) from acj_q) >= 5 and not exists (select 1 from acj_q where joke is null));
-- an Admin takes the quiz: every answer the joke (wrong), then every answer right
select test.eq('picking the joke on every question scores zero', (public.door(test.id('acj_admin'), 'aal2', 'ops_do', 'academy_quiz_submit', jsonb_build_object('section', 'prices-and-deposits',
  'answers', (select jsonb_object_agg(id::text, joke) from acj_q))) ->> 'correct')::int, 0);
select test.eq('picking the right option on every question scores every question', (public.door(test.id('acj_admin'), 'aal2', 'ops_do', 'academy_quiz_submit', jsonb_build_object('section', 'prices-and-deposits',
  'answers', (select jsonb_object_agg(id::text, answer) from acj_q))) ->> 'correct')::int, (select count(*)::int from acj_q));
