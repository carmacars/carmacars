-- 5013 (release 50; docs/changes/2026-11-25-r50-calc-year.md): the earnings calculator reads the car's year. A Sales
-- rep found that "what you could earn" gave a 2012 and a 2024 of the same make and model one rate: the model average
-- ignored the year. Each model now also carries its cars by year (the year and its average daily rate) and its average
-- year, so the page uses cars of about the same year (within two years) and otherwise moves the model's average by the
-- years between them (web/src/features/owner/earnings.ts, rateFor).
-- SCHEMA_MARKER 5013.

alter function app.owner_calc_data_pre3291() rename to owner_calc_data_pre5013;

create function app.owner_calc_data_pre3291() returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  d jsonb := app.owner_calc_data_pre5013();
  f jsonb;
begin
  select coalesce(jsonb_agg(r), '[]'::jsonb) into f from app.public_fleet('{}'::jsonb) r
   where not coalesce((r ->> 'is_sample')::boolean, false) and (r ->> 'daily_rate_cents') ~ '^[0-9]+$';
  return d || jsonb_build_object('models',
    (select coalesce(jsonb_agg(jsonb_build_object('make', m.mk, 'model', m.md, 'class', m.cls, 'avg_cents', m.avg, 'n', m.n,
              'avg_year', m.avg_year, 'years', m.years)), '[]'::jsonb)
       from (select g.mk, g.md, min(g.cls) cls, round(sum(g.sum_cents)::numeric / sum(g.n)) avg, sum(g.n)::integer n,
                    round(sum(g.y * g.n)::numeric / nullif(sum(g.n) filter (where g.y is not null), 0)) avg_year,
                    coalesce(jsonb_agg(jsonb_build_object('year', g.y, 'avg_cents', round(g.sum_cents::numeric / g.n), 'n', g.n) order by g.y)
                               filter (where g.y is not null), '[]'::jsonb) years
               from (select app.make_key(x ->> 'make') mk, lower(btrim(x ->> 'model')) md, min(x ->> 'class') cls,
                            (select v.year from vehicles v where v.id = (x ->> 'vehicle_id')::uuid) y,
                            sum((x ->> 'daily_rate_cents')::bigint) sum_cents, count(*) n
                       from jsonb_array_elements(f) x group by 1, 2, 4) g
              group by g.mk, g.md) m));
end $$;

revoke all on function app.owner_calc_data_pre3291() from public, anon, authenticated;
grant execute on function app.owner_calc_data_pre3291() to service_role;
revoke all on function app.owner_calc_data_pre5013() from public, anon, authenticated;
grant execute on function app.owner_calc_data_pre5013() to service_role;
