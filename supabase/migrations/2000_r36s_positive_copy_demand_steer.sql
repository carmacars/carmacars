-- 2000_r36s_positive_copy_demand_steer.sql
-- Release 36, SEO (docs/changes/2026-11-11-r36-seo-growth.md), parts 1 and 8.
--   1. Positive copy: the search terms' notes that opened with what we lack ("We do not sell cars", "We do not lease
--      cars", "We do not publish ...") now say what CarmaCars does for that searcher. Same facts, positive framing;
--      the templates follow the same rule, checked in CI (scripts/check-seo-copy.mjs, web/src/features/seo/copy-lint.ts).
--   8. Demand steering: one car (an older luxury sedan) drew most booking requests, and the Trending order (0352) put it
--      first because of those requests, which brought it more. A car whose share of the requests over the Trending days
--      passes fleet_demand_cap_bps (Program settings, 25% by default) is "popular": its Trending place is capped at
--      fleet_demand_cap_rank (6 by default: it ranks after the 5th car), the fleet rows say popular = true, and its
--      page shows "Popular: see similar cars" (the similar cars ranked first). An Admin's pin still leads.
-- No applied migration is edited.

-- ================================================================ 1. positive term notes (data)
update place_terms set intent_note = 'CarmaCars is a rental company: tell us the car you are looking for and we help where we can, and you can rent a similar car first.'
 where intent_note = 'We do not sell cars. Tell us the car you are looking for and we will help where we can, and you can rent a similar car first.';
update place_terms set intent_note = 'CarmaCars rents cars by the day, the week and the month. Tell us what you need and a person helps you plan it.'
 where intent_note = 'We are not a lender and do not arrange loans. Tell us what you need and we will help where we can.';
update place_terms set intent_note = 'Renting by the month gives you a car while you arrange a loan with your bank or a lender, with nothing to finance.'
 where intent_note = 'We do not lend money. Renting by the month can bridge the time while you arrange a loan with your bank or a lender.';
update place_terms set intent_note = 'A monthly rental gives you a car while you rebuild your credit: no loan and no credit check for a loan.'
 where intent_note = 'We do not lend money or check credit for loans. A monthly rental is one way to have a car while you rebuild your credit.';
update place_terms set intent_note = 'A monthly rental is the flexible alternative to a lease: each booking runs up to {{maxDays}} days, with no long-term contract.'
 where intent_note = 'We do not lease cars. A monthly rental has no long-term contract: each booking runs up to {{maxDays}} days.';
update place_terms set intent_note = 'A monthly rental covers the weeks while your lease takeover is completed, booked by the month.'
 where intent_note = 'We do not arrange lease takeovers. A monthly rental can cover the weeks while a takeover is completed.';
update place_terms set intent_note = 'Rent the model first, for a day or a week on your own roads, then shop for a certified pre-owned one with confidence.'
 where intent_note = 'We do not sell certified pre-owned cars. Rent the model first, then shop for one with confidence.';
update place_terms set intent_note = 'Keep your car and have it earn: the CarmaCars owner program rents it out for you.'
 where intent_note = 'We do not buy cars. If you would rather keep your car and have it earn, our owner program rents it out for you.';
update place_terms set intent_note = 'Between cars? Rent one by the week or the month while you decide on your trade-in.'
 where intent_note = 'We do not take trade-ins. If you are between cars, rent one by the week or the month while you decide.';
update place_terms set intent_note = 'Month to month instead of a lease: one booking runs up to {{maxDays}} days, renews with a new agreement, and you can stop at the end of any booking.'
 where intent_note = 'We do not lease cars. A monthly rental is the short-term alternative: one booking runs up to {{maxDays}} days, renews with a new agreement, and you can stop at the end of any booking.';
update place_terms set intent_note = 'Rent the model you are considering for a few days first, then buy from a dealer with confidence.'
 where intent_note = 'We do not sell new cars. Rent the model you are considering for a few days first, then buy from a dealer with confidence.';
update place_terms set intent_note = 'Tell us the truck you are looking for and we help where we can, and you can rent a pickup first when one is in our fleet.'
 where intent_note = 'We do not sell trucks. Tell us the truck you are looking for and we will help where we can, and you can rent a pickup first when one is in our fleet.';
update place_terms set intent_note = 'Rent the SUV you are considering for a few days, with your family and your luggage, before you buy one.'
 where intent_note = 'We do not sell SUVs. Rent the SUV you are considering for a few days, with your family and your luggage, before you buy one.';
update place_terms set intent_note = 'A monthly rental, renewed with a new agreement up to {{maxDays}} days at a time, gives you a car while you save or rebuild your credit. A rental stays a rental: you return the car at the end.'
 where intent_note = 'We do not offer rent to own: a rental never becomes a purchase. A monthly rental, renewed with a new agreement up to {{maxDays}} days at a time, gives you a car while you save or rebuild your credit.';
update place_terms set intent_note = 'Body repair: collisions, dents, scratches, bumpers, paint and windshield chips. For engines, brakes or oil changes we arrange a trusted shop.'
 where intent_note = 'Body repair: collisions, dents, scratches, bumpers, paint and windshield chips. We do not do mechanical work such as engines, brakes or oil changes.';
update place_terms set intent_note = 'Auto body repair after a collision, dents, scratches, paint and windshield chips. For engines, brakes or oil changes we arrange a trusted shop.'
 where intent_note = 'Auto body repair after a collision, dents, scratches, paint and windshield chips. We do not do mechanical repairs such as engines, brakes or oil changes.';
update place_terms set intent_note = 'Tell us the make, model and budget you have in mind and we help where we can, and you can rent the model first.'
 where intent_note = 'We are not a dealer. Tell us the make, model and budget you have in mind and we will help where we can.';
update place_terms set intent_note = 'Compare a lease with renting month to month from CarmaCars, which you can stop at the end of any booking.'
 where intent_note = 'We are not a leasing company. Compare a lease with renting month to month, which you can stop at the end of any booking.';
update place_terms set
  intent_note = 'What renting from CarmaCars involves, in figures from this site: the rates, the deposit, the kilometres included, the delivery fee, the age and licence rules and the coverage options. Check 01 Motors'' current prices and terms with 01 Motors when you compare.',
  faq = '[{"question": "Is this page from 01 Motors?", "answer": "No. This page is written by CarmaCars and gives CarmaCars'' own figures only."}, {"question": "Where do I find 01 Motors'' prices and terms?", "answer": "With 01 Motors, on its own site. This page shows CarmaCars'' figures."}]'::jsonb
 where slug = 'carmacars-vs-01-motors';

-- ================================================================ 8. demand steering
alter table program_settings
  add column if not exists fleet_demand_cap_bps integer not null default 2500 check (fleet_demand_cap_bps between 500 and 10000),
  add column if not exists fleet_demand_cap_rank smallint not null default 6 check (fleet_demand_cap_rank between 2 and 50),
  add column if not exists fleet_demand_min_requests integer not null default 5 check (fleet_demand_min_requests between 1 and 1000);
comment on column program_settings.fleet_demand_cap_bps is 'Demand steering (2000): a car with more than this share of the booking requests over fleet_trending_days is popular (2,500 = 25%). Its Trending place is capped and its page shows similar cars first. 10,000 turns it off.';
comment on column program_settings.fleet_demand_cap_rank is 'Demand steering (2000): the highest Trending place a popular car can take (6: after the 5th car). A pin still leads.';
comment on column program_settings.fleet_demand_min_requests is 'Demand steering (2000): the fewest requests over the whole fleet before a share counts (5), so one request on a quiet week makes no car popular.';

alter table app.fleet_trend
  add column if not exists popular boolean not null default false,
  add column if not exists request_share_bps integer not null default 0 check (request_share_bps between 0 and 10000),
  add column if not exists raw_score numeric(10, 2);
comment on column app.fleet_trend.popular is 'Demand steering (2000): the car''s share of the requests is above fleet_demand_cap_bps; its score is capped below the (cap_rank - 1)th car''s.';

-- each car's share of the booking requests over the Trending days (the request form's count and the bookings made, the larger)
create or replace function app.fleet_request_shares(p_now timestamptz default now()) returns table (vehicle_id uuid, requests bigint, share_bps integer)
language sql stable security definer set search_path = public, app as $$
  with s as (select (app.settings()).fleet_trending_days d),
  cars as (select l.vehicle_id from vehicle_listings l join vehicles v on v.id = l.vehicle_id
            where l.status = 'published' and v.management_mode <> 'turo_only' and v.retired_at is null),
  i as (select x.vehicle_id, sum(x.requests) n from vehicle_interest_daily x, s where x.day > app.local_date(p_now) - s.d group by x.vehicle_id),
  b as (select x.vehicle_id, count(*) n from bookings x, s where x.created_at > p_now - make_interval(days => s.d) and x.booking_type::text not in ('owner', 'placeholder') group by x.vehicle_id),
  r as (select c.vehicle_id, greatest(coalesce(i.n, 0), coalesce(b.n, 0))::bigint n from cars c left join i on i.vehicle_id = c.vehicle_id left join b on b.vehicle_id = c.vehicle_id),
  t as (select sum(n) total from r)
  select r.vehicle_id, r.n, case when t.total > 0 then least(10000, round(r.n * 10000.0 / t.total))::integer else 0 end from r, t
$$;

-- the hourly job (0352) with the cap: a popular car's score is held just under the score of the car at (cap_rank - 1)
-- among the cars that are not popular, so it ranks no higher than cap_rank (pins aside)
create or replace function app.job_fleet_trending() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  n integer;
  st program_settings := app.settings();
  v_total bigint;
  v_line numeric;
begin
  create temp table if not exists _ft (vehicle_id uuid primary key, score numeric, raw numeric, requests bigint, share_bps integer, popular boolean) on commit drop;
  truncate _ft;
  insert into _ft select s.vehicle_id, s.score, s.score, coalesce(r.requests, 0), coalesce(r.share_bps, 0), false
    from app.fleet_trending_scores() s left join app.fleet_request_shares() r on r.vehicle_id = s.vehicle_id;
  select coalesce(sum(requests), 0) into v_total from _ft;
  if v_total >= st.fleet_demand_min_requests and st.fleet_demand_cap_bps < 10000 then
    update _ft set popular = true where share_bps > st.fleet_demand_cap_bps;
    select score into v_line from _ft where not popular order by score desc offset greatest(st.fleet_demand_cap_rank - 2, 0) limit 1;
    if v_line is not null then update _ft set score = least(score, v_line - 0.01) where popular; end if;
  end if;
  insert into app.fleet_trend as t (vehicle_id, score, raw_score, popular, request_share_bps, at)
  select f.vehicle_id, round(f.score, 2), round(f.raw, 2), f.popular, f.share_bps, now() from _ft f
  on conflict (vehicle_id) do update set score = excluded.score, raw_score = excluded.raw_score, popular = excluded.popular, request_share_bps = excluded.request_share_bps, at = excluded.at
   where t.score is distinct from excluded.score or t.popular is distinct from excluded.popular or t.request_share_bps is distinct from excluded.request_share_bps;
  get diagnostics n = row_count;
  delete from app.fleet_trend t where not exists (select 1 from vehicle_listings l where l.vehicle_id = t.vehicle_id and l.status = 'published');
  return n;
end $$;

-- the website's fleet (0352) with each car's popular flag
create or replace function app.public_fleet_trending(p_filters jsonb default '{}'::jsonb) returns setof jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare hot integer := (app.settings()).fleet_hot_count;
begin
  return query
  select q.r || jsonb_build_object('trend_rank', q.n, 'pinned', q.pinned_rank is not null,
                                   'hot', q.n <= hot and q.trend_score > 0 and not coalesce((q.r ->> 'is_sample')::boolean, false),
                                   'popular', q.popular)
    from (select f.r, l.pinned_rank, coalesce(t.score, 0) trend_score, coalesce(t.popular, false) popular,
                 row_number() over (order by l.pinned_rank nulls last, coalesce((f.r ->> 'is_sample')::boolean, false), coalesce(t.score, 0) desc, f.o) n
            from app.public_fleet(p_filters) with ordinality f(r, o)
            left join vehicle_listings l on l.vehicle_id = (f.r ->> 'vehicle_id')::uuid
            left join app.fleet_trend t on t.vehicle_id = (f.r ->> 'vehicle_id')::uuid) q
   order by q.n;
end $$;

-- the popular cars (for the search pages' similar-car lists, which push them after the others): vehicle ids
create or replace function public.fleet_popular_ids() returns uuid[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(vehicle_id order by request_share_bps desc), '{}') from app.fleet_trend where popular
$$;
revoke all on function app.fleet_request_shares(timestamptz), app.job_fleet_trending(), public.fleet_popular_ids() from public, anon, authenticated;
grant execute on function app.fleet_request_shares(timestamptz), app.job_fleet_trending() to service_role;
grant execute on function public.fleet_popular_ids() to anon, authenticated, service_role;
