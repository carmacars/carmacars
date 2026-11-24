-- 3601 (release 49): the gift cards academy section (3600) is optional. A section marked optional counts as passed for every
-- gate (portal unlock, onboarding, path progress), so no staff member is locked out by a lesson added after they were hired.
-- It is still taught, and the quiz can still be taken.
alter table academy_sections add column if not exists optional boolean not null default false;
comment on column academy_sections.optional is 'Release 49 (3601): an optional section counts as passed for every gate; the lesson and quiz stay available.';
update academy_sections set optional = true where slug = 'r49-gift-cards';

create or replace function app.academy_passed(p_user uuid, p_section uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from academy_sections s where s.id = p_section and s.optional)
      or exists (select 1 from academy_attempts a where a.user_id = p_user and a.section_id = p_section and a.passed
                    and a.created_at > app.academy_since(p_user, p_section))
$$;

-- the r48-renter-coverage lesson 3 and question 6 say what the page now offers (the pick-another-card wording of the guide checks, 3461); 2990 is history, so the new text is set here
insert into academy_lessons (section_id, sort, title, scenes) values ((select id from academy_sections where slug = 'r48-renter-coverage'), 3, 'When the card does not cover it', '[{"caption":"The page says why","say":"No rental damage cover, the car is over the card''s value limit, the kind of car is left out, or the rental is too long. They pick another card, or choose OPCF 27 or the Protection Plan in the coverage choices.","visual":{"kind":"rule","heading":"Card does not cover","text":"Pick another card, or choose OPCF 27 on my own auto policy or the Protection Plan.","tone":"warn"}},{"caption":"Never say covered","say":"Only the card issuer decides a claim. Send them to the card coverage page and their issuer.","visual":{"kind":"chat","lines":[{"who":"you","text":"Your card issuer decides that. Please call the number on the back of your card about this car and these dates. If it is not covered, OPCF 27 or our Protection Plan work."}]}}]'::jsonb) on conflict (section_id, sort) do update set title = excluded.title, scenes = excluded.scenes, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'r48-renter-coverage'), 6, 'The card coverage check says the car is over the card''s limit. What can the renter choose?', '["Nothing","OPCF 27 on their policy, or the Protection Plan","A cheaper card","Skip coverage"]'::jsonb, 1, 'Pick another card, or choose OPCF 27 on my own auto policy or the Protection Plan.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
