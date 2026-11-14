-- 2872_r46_academy.sql
-- Release 46 in the academy: one question on a lead's phone (2870), added to "Calls in the browser" (2866), the section
-- on calling customers that every Sales path takes. Written from va/sales ("A lead's phone number (release 46)").
-- The section also names that chapter now, so a later change to it marks the section for review.
update academy_sections set guide_refs = guide_refs || array['va/sales']::text[], updated_at = now()
 where slug = 'new-r45-calls-in-the-browser' and not ('va/sales' = any (guide_refs));
insert into academy_questions (section_id, sort, prompt, options, answer, explain)
values ((select id from academy_sections where slug = 'new-r45-calls-in-the-browser'), 6,
  'A lead''s number shows with dots in place of most digits. You need the whole number of that lead. What do you do?',
  '["Ask customer service to read it to you","Press Ask an Admin to show the number on the lead","Copy it from another lead","Nothing: Sales never sees a whole number"]'::jsonb, 1,
  'An Admin can show it to you for that lead only. It is hidden again by itself if the lead goes to another salesperson.')
on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
