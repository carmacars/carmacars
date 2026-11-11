-- 99: migration 2321 (release 37): calls go first, texts after. The academy section sits on the call-handling paths with a
-- quiz of at least five questions at the unchanged 90% pass mark; Unanswered lists missed calls above texts. (The guide text
-- is checked by supabase/seed/2321_gen_guides.mjs --check.) Fixtures start with "zk".
select test.suite('99 r37 calls first (2321)');

select test.mk_user('zk_cs', 'va', 'cs');
select test.mk_user('zk_fleet', 'va', 'fleet');

select test.eq('academy: the section is on the paths that handle calls',
  (select string_agg(p.path_code, ',' order by p.path_code) from academy_path_sections p join academy_sections s on s.id = p.section_id where s.slug = 'new-r37-calls-first'),
  'admin,cs,finance,fleet,sales_in_person,sales_remote');
select test.ok('academy: a quiz of at least five questions and two lessons or more',
  (select count(*) from academy_questions q join academy_sections s on s.id = q.section_id where s.slug = 'new-r37-calls-first') >= 5
  and (select count(*) from academy_lessons l join academy_sections s on s.id = l.section_id where s.slug = 'new-r37-calls-first') >= 2);
select test.ok('academy: it names guide chapters', not exists (select 1 from academy_sections where slug = 'new-r37-calls-first' and guide_refs = '{}'));
select test.ok('academy: the lessons say calls first and call before texting',
  (select bool_and(position('call' in lower(l.scenes::text)) > 0) from academy_lessons l join academy_sections s on s.id = l.section_id where s.slug = 'new-r37-calls-first')
  and (select string_agg(l.scenes::text, ' ') from academy_lessons l join academy_sections s on s.id = l.section_id where s.slug = 'new-r37-calls-first') ilike '%Call before you text%');
select test.eq('academy: the pass mark stays 90%', (select academy_pass_bps from program_settings where id = (app.settings()).id), 9000);

-- Unanswered: the missed call (older or newer) is above the texts, the longest wait first in each
insert into phone_threads (id, number, match_kind, name, last_at, last_direction) values
  (test.id('zk_t1'), '+15555550191', 'lead', 'Zk Text Old', now() - interval '50 minutes', 'in'),
  (test.id('zk_t2'), '+15555550192', 'lead', 'Zk Text New', now() - interval '20 minutes', 'in'),
  (test.id('zk_c1'), '+15555550193', 'lead', 'Zk Call New', now() - interval '5 minutes', 'in'),
  (test.id('zk_c2'), '+15555550194', 'lead', 'Zk Call Old', now() - interval '30 minutes', 'in');
insert into phone_activity (thread_id, kind, direction, body, started_at, missed) values
  (test.id('zk_t1'), 'text', 'in', 'Hello?', now() - interval '50 minutes', false),
  (test.id('zk_t2'), 'text', 'in', 'Anyone there?', now() - interval '20 minutes', false),
  (test.id('zk_c1'), 'call', 'in', null, now() - interval '5 minutes', true),
  (test.id('zk_c2'), 'call', 'in', null, now() - interval '30 minutes', true);
select test.eq('unanswered: missed calls first, then texts, the longest wait first in each',
  (select string_agg(x ->> 'name', ',' order by o) from jsonb_array_elements(public.door(test.id('zk_cs'), null, 'ops_read', 'unanswered', '{}'::jsonb) -> 'rows') with ordinality t(x, o)
    where x ->> 'name' like 'Zk %'),
  'Zk Call Old,Zk Call New,Zk Text Old,Zk Text New');
