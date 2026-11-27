-- 5172 (R50 hotfix 2, academy; docs/changes/2026-11-27-r50-hotfix2-academy.md): a shorter academy, every question taught by
-- its lessons. The owner (Nov 27): "Shorten the academy overall: cut repetition; audit every quiz question so it matches its
-- lesson."
--   1. The renter's side path (9 sections, 47 questions: the request, offer, signing, payment, coverage, pickup, extension and
--      return as the renter sees them) repeats what the function paths teach (prices and deposits, coverage and drivers, trip
--      rules, bookings). Since 2990 it was added to every person's paths; now to customer service only, who walk renters
--      through the site. Fleet, Finance, Sales and field staff no longer take it.
--   2. The audit (every question's right answer and explanation checked against its section's lessons, numbers and words; the
--      flagged ones read by hand). Removed, because the lessons never teach them: r48-map-people 5 (how long job points are
--      kept), new-r45-calls-in-the-browser 6 (the masked number), new-r33-photos 4, 5 and 6 (Import button, unticking a folder,
--      generated views), r50-sign-first 5 (the wrong Onboarding Method), new-r35-field-prep 5 (prep on a day without a
--      shift). Fixed: new-r35-field-prep 2 (the lesson asks for the certificate PDF or photo, not an expiry date). Taught:
--      trip-rules 8 (rideshare and delivery driving are welcome, an owner decision, 1700) stays, and the trip-rules lesson
--      "On the trip" gets the scene that teaches it (only customer service's calls section taught it before).
--   3. The repetition: a question asked again, in the same words or nearly, in a later section of the same path is removed
--      there: r48-field-guide-cases 4 (field-return-and-cash 3), r48-cs-guide-cases 3 and 5 (cs-requests 2,
--      new-r35-cs-calls-answers 3), new-r35-fleet-shifts-delivery 1 (new-r45-field-shifts-checkins 4), finance-deposits-refunds 3
--      (trip-rules 6), new-bookings-r28-r32 2 (prices-and-deposits 2), new-r45-calls-in-the-browser 4 (new-r37-calls-first 1).
--   4. A quiz started with a fix pending (5070) on a changed section starts again (its kept answers name the old questions).
-- Passes already earned stay. No applied migration is edited: academy_paths_of is replaced (same signature, grants kept).
set local check_function_bodies = off;

-- ================================================================ 1. the renter's side for customer service only
create or replace function app.academy_paths_of(p_user uuid) returns text[]
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case when 'cs' = any (x) then (select array_agg(distinct p order by p) from unnest(x || array['renter_side']) p) else x end
    from (select app.academy_paths_of_pre2990(p_user) as x) s
$$;

-- ================================================================ 2 and 3. the questions
create temporary table q5172 (slug text, sort int) on commit drop;
insert into q5172 values
  ('r48-map-people', 5), ('new-r45-calls-in-the-browser', 6), ('new-r33-photos', 4), ('new-r33-photos', 5), ('new-r33-photos', 6),
  ('r50-sign-first', 5), ('new-r35-field-prep', 5),
  ('r48-field-guide-cases', 4), ('r48-cs-guide-cases', 3), ('r48-cs-guide-cases', 5), ('new-r35-fleet-shifts-delivery', 1),
  ('finance-deposits-refunds', 3), ('new-bookings-r28-r32', 2), ('new-r45-calls-in-the-browser', 4);

-- a pending fix on a changed section starts again
update academy_quiz_starts st set fix_wrong = null, fix_answers = null, fix_at = null
 where st.fix_wrong is not null
   and st.section_id in (select s.id from academy_sections s where s.slug in (select slug from q5172 union select 'new-r35-field-prep'));

do $$
declare n integer;
begin
  delete from academy_questions q using academy_sections s, q5172 x
   where s.id = q.section_id and s.slug = x.slug and q.sort = x.sort;
  get diagnostics n = row_count;
  if n <> 14 then raise exception '5172: expected 14 questions to remove, found %', n; end if;
end $$;

update academy_questions q set options = jsonb_set(q.options, '{1}', to_jsonb('The certificate PDF or photo, uploaded'::text)),
       explain = 'Tick it with its upload: the safety certificate PDF or photo.', updated_at = now()
  from academy_sections s
 where s.id = q.section_id and s.slug = 'new-r35-field-prep' and q.sort = 2 and q.options ->> 1 = 'The certificate upload and its expiry date';

update academy_lessons l set scenes = l.scenes || jsonb_build_array(jsonb_build_object(
         'caption', 'Rideshare and delivery',
         'say', 'Rideshare and delivery driving are welcome. Ask the renter to tell us in the request. Once booked, the booking page makes the documents the platforms ask for.',
         'visual', jsonb_build_object('kind', 'rule', 'heading', 'Rideshare and delivery driving', 'text', 'Welcome. The renter tells us in the request.', 'tone', 'ok'))),
       updated_at = now()
  from academy_sections s
 where s.id = l.section_id and s.slug = 'trip-rules' and l.title = 'On the trip: late, kilometres, fuel, tolls' and l.scenes::text !~* 'rideshare';

do $$ begin raise notice '5172: % questions in % sections now', (select count(*) from academy_questions), (select count(*) from academy_sections); end $$;

-- the cached onboarding answer follows the shorter paths
select app.staff_onboarding_refresh_all();
