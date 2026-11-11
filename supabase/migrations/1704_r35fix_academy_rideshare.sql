-- 1704_r35fix_academy_rideshare.sql
-- Release 35, fix helper, task 1 (docs/changes/2026-11-11-r35fix-owner-decisions.md). The owner, November 11, 2026:
-- "Ride-hailing and delivery work are allowed." The academy's trip rules (0208, supabase/seed/academy/policies.mjs, its
-- source) gain a question: a renter asks to drive for Uber or deliver food; the answer is "Rideshare and delivery driving
-- are welcome". Added once, after the section's last question; an Admin's own questions are kept. Nobody is reset: the
-- question counts from the next attempt.
-- No applied migration is edited.
insert into academy_questions (section_id, sort, prompt, options, answer, explain)
select s.id, coalesce((select max(q.sort) from academy_questions q where q.section_id = s.id), 0) + 1,
       'A renter asks: "Can I drive for Uber or deliver food with the car?"',
       '["No, it is not allowed","Yes: rideshare and delivery driving are welcome; ask them to tell us in the request","Only with an extra fee","Only on cars over $65,000"]'::jsonb,
       1, 'Rideshare and delivery driving are welcome (rental agreement, section 10.3). Once booked, the booking page makes the documents the platforms ask for.'
  from academy_sections s
 where s.slug = 'trip-rules'
   and not exists (select 1 from academy_questions q where q.section_id = s.id and q.prompt ilike '%drive for Uber%');
