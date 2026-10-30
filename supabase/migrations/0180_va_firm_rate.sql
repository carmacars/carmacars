-- 0180: every remote assistant role asks the candidate to confirm the rate is firm (the owner, October 28). SCHEMA_MARKER 0180.
-- The three VA roles (customer service, fleet operations, finance and billing): the pay question now says the rate is firm and
-- not negotiable, and the yes answer confirms it. A no stays a knock-out, and every knock-out or score below the pass mark in
-- these roles is referred to Remote sales (refer_on below_or_ko, set again here so it holds whatever 0179 left).
-- Remote sales (commission only) gets the same question about its commission rates; a no declines.

create or replace function pg_temp.firm_pay(p_questions jsonb) returns jsonb
language sql immutable as $$
  select jsonb_agg(case when q ->> 'key' = 'pay' then
           jsonb_set(jsonb_set(q, '{label}', to_jsonb(replace(q ->> 'label', 'Do you accept this pay?',
             'This rate is firm and not negotiable. Do you understand and accept it?'))),
             '{choices}', jsonb_build_array(
               jsonb_build_object('v', 'Yes, I understand the rate is firm and I accept it', 'pts', 10),
               jsonb_build_object('v', 'No', 'pts', 0, 'ko', true)))
           || jsonb_build_object('ko_reason', 'acceptance of the firm rate of the role')
         else q end order by o)
    from jsonb_array_elements(p_questions) with ordinality t(q, o)
$$;

update hiring_roles set questions = pg_temp.firm_pay(questions),
       refer_on = 'below_or_ko', refer_to = '{sales-remote}', refer_alt = null, updated_at = now()
 where slug in ('va-customer-service', 'va-fleet-operations', 'va-finance-billing');

-- Remote sales: the firm commission question goes first among its questions.
update hiring_roles set questions = jsonb_build_array(jsonb_build_object(
         'key', 'rate_firm', 'type', 'single', 'ko_reason', 'acceptance of the firm commission rates of the role',
         'label', 'This role is commission only: 5%, 10% or 15% of each rental you source, by the rental days you close each month. These rates are firm and not negotiable. Do you understand and accept them?',
         'choices', jsonb_build_array(
           jsonb_build_object('v', 'Yes, I understand the rates are firm and I accept them', 'pts', 0),
           jsonb_build_object('v', 'No', 'pts', 0, 'ko', true)))) || questions,
       updated_at = now()
 where slug = 'sales-remote' and not questions @> '[{"key":"rate_firm"}]'::jsonb;
