-- 3830 (release 50): fixes found by the release's CI run.
--   1. owner_applications.sign_wait_by (3800) gets its index: every join-path foreign key has one (99_r35sec_security).
--   2. The "Sign first, then cars" academy section (3801) is optional, as 3601 made the gift cards section: a section added
--      after staff were hired is taught and quizzed but never locks them out (3801 also held staff who had finished the
--      academy a week later; an optional section counts as passed, so that hold no longer holds anyone). It gets its fifth question (every section has at least five, 99_academy).
-- Tests: 99_academy, 99_r33_hire_academy_connector, 99_r37_academy_videos, 99_r35sec_security. SCHEMA_MARKER 3830.
create index if not exists owner_applications_sign_wait_by_idx on owner_applications (sign_wait_by);

update academy_sections set optional = true where slug = 'r50-sign-first';
insert into academy_questions (section_id, sort, prompt, options, answer, explain)
select s.id, 5, 'An owner''s car was entered with the wrong Onboarding Method and its Vehicle Schedule is not signed yet. What do you do?',
       '["Delete the car and add it again","Change the method on the owner''s page before the schedule is signed","Nothing: the method cannot change","Ask the owner to sign first, then fix it"]'::jsonb,
       1, 'Change the method corrects it while the Vehicle Schedule is unsigned; the schedule is made again with the right method.'
  from academy_sections s where s.slug = 'r50-sign-first'
 on conflict do nothing;
