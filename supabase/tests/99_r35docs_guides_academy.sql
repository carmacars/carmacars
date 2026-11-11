-- 99: the release 35 docs pass (migration 2151): the six new academy sections sit on their paths with a quiz of five or more
-- questions each, name their guide chapters, and the pass mark stays 90%.
select test.suite('99 r35 docs guides and academy');

-- The guide text itself is checked by supabase/seed/2150_gen_guides.mjs --check (the test database seeds no guide chapters).

select test.eq('academy: six new sections',
  (select count(*)::int from academy_sections where slug in ('new-r35-team-rules', 'new-r35-cs-calls-answers', 'new-r35-sales-rebook-intent', 'new-r35-fleet-shifts-delivery', 'new-r35-finance-statements-payroll', 'new-r35-field-shift-picker')), 6);
select test.eq('academy: the team rules are on every path',
  (select string_agg(p.path_code, ',' order by p.path_code) from academy_path_sections p join academy_sections s on s.id = p.section_id where s.slug = 'new-r35-team-rules'),
  'admin,cs,field,finance,fleet,sales_in_person,sales_remote');
select test.eq('academy: each new section has a quiz of at least five questions',
  (select count(*)::int from academy_sections s where s.slug like 'new-r35-%' and s.slug not in ('new-r35-fleet-payments', 'new-r35-fleet-phone')
     and (select count(*) from academy_questions q where q.section_id = s.id) < 5), 0);
select test.eq('academy: field staff get the shift picker, not the Sales section',
  (select string_agg(s.slug, ',' order by s.slug) from academy_path_sections p join academy_sections s on s.id = p.section_id where p.path_code = 'field' and s.slug in ('new-r35-field-shift-picker', 'new-r35-sales-rebook-intent')),
  'new-r35-field-shift-picker');
select test.eq('academy: the pass mark stays 90%', (select academy_pass_bps from program_settings where id = (app.settings()).id), 9000);
select test.ok('academy: each new section names guide chapters', not exists (select 1 from academy_sections where slug like 'new-r35-%' and guide_refs = '{}'));
