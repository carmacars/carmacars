-- 0354_owner_calculator.sql
-- What a car can earn a month, for people listing theirs (docs/changes/2026-11-06-owner-earnings-calculator.md).
--
-- The owner, November 1, 2026: a calculator on /list-your-car (and a compact one at the start of the application) that
-- shows how much a car can make each month. The browser does the maths; this is the small set of numbers it needs, read
-- once with the page:
--   - the classes, each with the average daily rate of the real cars on the site in that class and the class rate card
--     (Program settings listing_default_daily_rate_cents, the rate a new car of that class starts from);
--   - the same averages by make and model (the closest match wins over the class);
--   - the class rules (vehicle_class_rules, the order app.infer_vehicle_class reads them), so a year, make and model
--     picked on the page get the class the car would get when added;
--   - the monthly program fees, two new Program settings in cents, empty until an Admin sets them: then the page says
--     "Insurance and tracker fees: quoted in your agreement" and shows the earnings before fees. No amount is made up.

alter table program_settings
  add column if not exists owner_calc_insurance_fee integer check (owner_calc_insurance_fee between 0 and 1000000),
  add column if not exists owner_calc_tracker_fee integer check (owner_calc_tracker_fee between 0 and 1000000);
comment on column program_settings.owner_calc_insurance_fee is 'The earnings calculator on List your car (0354): the monthly insurance fee of a car on the fleet policy, in cents, as the page shows it (empty: "quoted in your agreement").';
comment on column program_settings.owner_calc_tracker_fee is 'The earnings calculator on List your car (0354): the monthly tracker fee, in cents, as the page shows it (empty: "quoted in your agreement").';

create or replace function app.owner_calc_data() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  f jsonb;
begin
  select coalesce(jsonb_agg(r), '[]'::jsonb) into f from app.public_fleet('{}'::jsonb) r
   where not coalesce((r ->> 'is_sample')::boolean, false) and (r ->> 'daily_rate_cents') ~ '^[0-9]+$';
  return jsonb_build_object(
    'classes', (select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'label', c.label,
                  'card_cents', nullif(s.listing_default_daily_rate_cents ->> c.code, '')::bigint,
                  'avg_cents', (select round(avg((x ->> 'daily_rate_cents')::bigint)) from jsonb_array_elements(f) x where x ->> 'class' = c.code),
                  'n', (select count(*) from jsonb_array_elements(f) x where x ->> 'class' = c.code)) order by c.sort_order, c.code), '[]'::jsonb)
                  from vehicle_classes c where c.is_active),
    'models', (select coalesce(jsonb_agg(jsonb_build_object('make', m.mk, 'model', m.md, 'class', m.cls, 'avg_cents', m.avg, 'n', m.n)), '[]'::jsonb)
                 from (select app.make_key(x ->> 'make') mk, lower(btrim(x ->> 'model')) md, min(x ->> 'class') cls,
                              round(avg((x ->> 'daily_rate_cents')::bigint)) avg, count(*) n
                         from jsonb_array_elements(f) x group by 1, 2) m),
    'rules', (select coalesce(jsonb_agg(jsonb_build_object('make', r.make_key, 'model_re', r.model_re, 'trim_re', r.trim_re, 'body_re', r.body_re,
                 'class', r.class, 'aged_years', r.aged_years, 'aged_class', r.aged_class)
                 order by r.rank, (r.model_re is not null) desc, (r.trim_re is not null) desc, (r.body_re is not null) desc, r.created_at), '[]'::jsonb)
                from vehicle_class_rules r where r.is_active),
    'fees', jsonb_build_object('insurance_cents', s.owner_calc_insurance_fee, 'tracker_cents', s.owner_calc_tracker_fee),
    'year', extract(year from app.today())::integer);
end $$;
revoke all on function app.owner_calc_data() from public;
grant execute on function app.owner_calc_data() to anon, authenticated, service_role;

create or replace function public.owner_calc_data() returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_calc_data() $$;
grant execute on function public.owner_calc_data() to anon, authenticated, service_role;
