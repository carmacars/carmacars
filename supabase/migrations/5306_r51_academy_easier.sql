-- 5306 (R51 staff, REQ-134; docs/changes/2026-11-27-r51-staff.md): the academy is easier. The owner (Nov 27 17:45): "the
-- academy wait time when getting things wrong is too long and they need to have 1 chance to retry the wrong questions
-- before it starts the wait time. also i think theres a lot of redundant sections or questions and just unnecessary steps.
-- it needs to be easier".
--   1. The retry of only the wrong questions, at once, before any wait, is 5070 (fix once): kept as it is.
--   2. The wait after a failed try is halved: academy_fail_cooldown_minutes 2 -> 1 (the default and the setting when it is 2).
--   3. Questions that test the same thing twice for one role are dropped (listed in the change doc):
--      - r48-renter-pay-deposit "When is the deposit taken?" (customer service also has it in prices-and-deposits);
--      - new-r45-townhall-agreements "Do missed townhalls that were held still count?" (every path; new-r35-team-rules
--        asks what two missed townhalls do);
--      - r48-cs-guide-cases "Where does the Assistant panel point you before you ask?" (the question before it: open the
--        guide chapter of the page);
--      - r48-whatsapp-tag "Where do you set your member tag?" (the section's first question and the Welcome step teach it).
--   4. Two answers that were wrong since 5070 are corrected (new-r35-team-rules): after a failed quiz you fix the wrong
--      ones at once and wait 1 minute after a failed fix (it said 30 minutes); 10 tries a day (it said 3).
-- Every change refuses when the row it changes is not found. No applied migration is edited.

-- ================================================================ 2. the wait
alter table program_settings alter column academy_fail_cooldown_minutes set default 1;
update program_settings set academy_fail_cooldown_minutes = 1 where id = (app.settings()).id and academy_fail_cooldown_minutes = 2;
comment on column program_settings.academy_fail_cooldown_minutes is 'Academy (1154; 2 since 5070; 1 since 5306): minutes after a failed attempt (after the one fix of the wrong answers) before the same quiz can be taken again.';

-- ================================================================ 3. the same thing twice
do $$
declare
  r record;
  n integer;
begin
  for r in select * from (values
      ('r48-renter-pay-deposit', 'When is the deposit taken?'),
      ('new-r45-townhall-agreements', 'Do missed townhalls that were held still count?'),
      ('r48-cs-guide-cases', 'Where does the Assistant panel point you before you ask?'),
      ('r48-whatsapp-tag', 'Where do you set your member tag?')) v(slug, prompt) loop
    delete from academy_questions q using academy_sections s where s.id = q.section_id and s.slug = r.slug and q.prompt = r.prompt;
    get diagnostics n = row_count;
    -- a database without the academy content (none of its sections) has nothing to drop
    if n <> 1 and exists (select 1 from academy_sections where slug = r.slug) then raise exception '5306: % / "%" not found (% rows)', r.slug, r.prompt, n; end if;
  end loop;
end $$;

-- ================================================================ 4. two wrong answers
do $$
declare n integer;
begin
  update academy_questions q set options = jsonb_set(q.options, '{2}', '"Fix the wrong ones at once; after a failed fix, 1 minute"'),
         explain = 'Under the pass mark, you fix only the questions marked wrong, straight away. If the fix is still under the mark, wait 1 minute.'
    from academy_sections s where s.id = q.section_id and s.slug = 'new-r35-team-rules' and q.prompt = 'You failed a quiz. When can you try again?' and q.answer = 2;
  get diagnostics n = row_count;
  if n <> 1 and exists (select 1 from academy_sections where slug = 'new-r35-team-rules') then raise exception '5306: the try again question was not found'; end if;
  update academy_questions q set options = jsonb_set(q.options, '{1}', '"10"'), explain = 'Ten tries a day.'
    from academy_sections s where s.id = q.section_id and s.slug = 'new-r35-team-rules' and q.prompt = 'How many tries of a quiz do you have a day?' and q.answer = 1;
  get diagnostics n = row_count;
  if n <> 1 and exists (select 1 from academy_sections where slug = 'new-r35-team-rules') then raise exception '5306: the tries question was not found'; end if;
end $$;
