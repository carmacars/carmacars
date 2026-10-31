-- 0219: Two minimum requirements for every role: good spoken English, and experience.
--
-- Until now "Basic: I am more comfortable in writing" and "Under 1 year" only gave 0 points, so a candidate with neither
-- could still pass the bar on the other answers and book a call. Now, on every role:
--   1. Spoken English: "Basic" is a knock-out. A role without the question (Field staff, Sales in person) gets it, with
--      the same answers and points as the remote roles.
--   2. Experience: "Under 1 year" on the role's years question is a knock-out (the remote roles and Sales in person).
--      Field staff keeps its own: at least two years of driving (already a knock-out, 0173).
-- A knocked-out candidate is not invited: the role's referral rule offers the next role, with the reason, or the polite
-- decline. Applications already received keep their status. The file name is from the first version (Finance only).

create function pg_temp.ko_choice(q jsonb, p_match text, p_reason text) returns jsonb language sql immutable as $$
  select q || jsonb_build_object('ko_reason', p_reason, 'choices',
    (select jsonb_agg(case when c ->> 'v' like p_match then c || '{"ko": true}'::jsonb else c end order by n) from jsonb_array_elements(q -> 'choices') with ordinality x(c, n)))
$$;

-- the English question where a role has none: before "Earliest start date" when there is one, else at the end
update hiring_roles r set questions = (
    select jsonb_agg(q order by i) from (
      select q, (i * 10)::numeric i from jsonb_array_elements(r.questions) with ordinality y(q, i)
      union all
      select jsonb_build_object('key', 'english', 'label', 'How is your spoken English with North American customers?', 'type', 'single', 'choices', jsonb_build_array(
               jsonb_build_object('v', 'Fluent: I handle calls on my own every day', 'pts', 15), jsonb_build_object('v', 'Good: I can handle most calls', 'pts', 8),
               jsonb_build_object('v', 'Basic: I am more comfortable in writing', 'pts', 0))),
             coalesce((select i * 10 - 5 from jsonb_array_elements(r.questions) with ordinality z(q2, i) where q2 ->> 'key' = 'start' limit 1), 1e9)) s(q, i)),
  updated_at = now()
 where not exists (select 1 from jsonb_array_elements(r.questions) q where q ->> 'key' = 'english');

update hiring_roles r set questions = (
    select jsonb_agg(
      case
        when q ->> 'key' = 'english' then pg_temp.ko_choice(q, 'Basic%', 'good spoken English for calls with North American customers')
        when q ->> 'key' = 'years' and exists (select 1 from jsonb_array_elements(q -> 'choices') c where c ->> 'v' = 'Under 1 year')
          then pg_temp.ko_choice(q, 'Under 1 year', case when r.slug = 'va-finance-billing' then 'at least one year of bookkeeping or billing'
                                                         else 'at least one year of experience in this kind of work' end)
        else q end
      order by i)
    from jsonb_array_elements(r.questions) with ordinality y(q, i)),
  updated_at = now();
