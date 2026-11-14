-- 2902_r47_photo_r48_academy.sql
-- Release 47 in the academy: one question on the generated listing views (2900), added to the listing photos section that
-- Fleet and Admin paths take. Written from admin/fleet-and-listings and va/fleet ("Every view generated from the car's
-- photos (release 47)"). The section names those chapters, so a later change to them marks the section for review.
update academy_sections set guide_refs = guide_refs || array['va/fleet']::text[], updated_at = now()
 where slug = 'new-r33-photos' and not ('va/fleet' = any (guide_refs));
insert into academy_questions (section_id, sort, prompt, options, answer, explain)
values ((select id from academy_sections where slug = 'new-r33-photos'), 6,
  'A car has no listing photos yet, only the photos taken at its last check-out. What does the site show once its generated views pass the check?',
  '["The check-out photos themselves","Nine views Gemini generated from those check-out photos, the sample view, the stock photo and the showroom background","A drawn sample car only","Nothing until someone uploads listing photos"]'::jsonb, 1,
  'Check-in and check-out photos are only references for Gemini: they are never shown on the site. The generated views are marked AI generated for staff.')
on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
