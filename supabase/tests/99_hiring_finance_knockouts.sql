-- 99: every role's minimum requirements (migration 0219): basic spoken English, or under a year of experience, is not invited.
select test.suite('99 hiring minimum requirements');
select test.eq('every role asks about spoken English, once',
  (select count(*) from hiring_roles r where (select count(*) from jsonb_array_elements(r.questions) q where q ->> 'key' = 'english') <> 1), 0::bigint);
select test.eq('on every role, basic spoken English is a knock-out with its reason',
  (select count(*) from hiring_roles r, jsonb_array_elements(r.questions) q, jsonb_array_elements(q -> 'choices') c
    where q ->> 'key' = 'english' and c ->> 'v' like 'Basic%' and coalesce((c ->> 'ko')::boolean, false)
      and q ->> 'ko_reason' = 'good spoken English for calls with North American customers'), (select count(*) from hiring_roles));
select test.eq('on every role with a years question, under a year is a knock-out',
  (select count(*) from hiring_roles r, jsonb_array_elements(r.questions) q, jsonb_array_elements(q -> 'choices') c
    where q ->> 'key' = 'years' and c ->> 'v' = 'Under 1 year' and not coalesce((c ->> 'ko')::boolean, false)), 0::bigint);
select test.eq('Finance and billing: the reason names bookkeeping',
  (select (x -> 'ko_reasons') ? 'at least one year of bookkeeping or billing'
     from hiring_roles r, app.hiring_score(r.questions, '{"english": "Good: I can handle most calls", "years": "Under 1 year"}'::jsonb) x where r.slug = 'va-finance-billing'), true);
select test.eq('Sales in person: basic English knocks out',
  (select (x -> 'ko_reasons') ? 'good spoken English for calls with North American customers'
     from hiring_roles r, app.hiring_score(r.questions, '{"english": "Basic: I am more comfortable in writing", "years": "3 to 5 years"}'::jsonb) x where r.slug = 'sales-in-person'), true);
select test.eq('Field staff: English asked just before the start date; driving years keep their own knock-out',
  (select (select q ->> 'key' from jsonb_array_elements(r.questions) with ordinality y(q, i) where i = (select i2 from jsonb_array_elements(r.questions) with ordinality z(q2, i2) where q2 ->> 'key' = 'start') - 1)
          || '/' || (select count(*) from jsonb_array_elements(r.questions) q, jsonb_array_elements(q -> 'choices') c where q ->> 'key' = 'years' and coalesce((c ->> 'ko')::boolean, false))
     from hiring_roles r where r.slug = 'field-staff'), 'english/1');
select test.eq('the points are unchanged', (select string_agg(c ->> 'pts', ',' order by n) from hiring_roles r, jsonb_array_elements(r.questions) q, jsonb_array_elements(q -> 'choices') with ordinality z(c, n)
  where r.slug = 'va-finance-billing' and q ->> 'key' = 'english'), '15,8,0');
