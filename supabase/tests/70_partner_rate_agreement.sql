-- 70: the partner agreement's facts on the partner's own rates (migration 0105). 01 Motors (0093, partner_rate basis)
-- gets its basis, its markup and each car's sheet rates with the car's markup and cut; a partner on the renter_price
-- basis (0046) keeps the facts it had. No fixtures of its own.
select test.suite('70 partner rate agreement');

create temp table pa_f as select app.partner_agreement_facts(p.owner_id) f from partners p where p.business_name = '01 Motors';
select test.eq('01 Motors: the partner_rate basis, a 10% markup and a 20% cut',
  (select format('%s %s %s', f ->> 'payout_basis', f ->> 'markup_bps', f ->> 'commission_bps') from pa_f), 'partner_rate 1000 2000');
select test.eq('every live car is in the table with its sheet rates',
  (select format('%s %s', jsonb_array_length(f -> 'cars'), (select count(*) from jsonb_array_elements(f -> 'cars') c where c -> 'sheet' ? 'base_cents')) from pa_f),
  (select format('%s %s', count(*), count(*)) from vehicles v join partners p on p.id = v.partner_id where p.business_name = '01 Motors' and v.retired_at is null));
select test.eq('each car''s sheet rates, markup and cut are the ones the pricing uses',
  (select string_agg(format('%s %s/%s/%s %s %s', c ->> 'name', c #>> '{sheet,base_cents}', c #>> '{sheet,multi_day_cents}', c #>> '{sheet,long_term_cents}', c ->> 'markup_bps', c ->> 'commission_bps'), '; '
                    order by format('%s %s/%s/%s %s %s', c ->> 'name', c #>> '{sheet,base_cents}', c #>> '{sheet,multi_day_cents}', c #>> '{sheet,long_term_cents}', c ->> 'markup_bps', c ->> 'commission_bps'))
     from pa_f, jsonb_array_elements(f -> 'cars') c),
  (select string_agg(x, '; ' order by x) from (select format('%s %s/%s/%s %s %s', app.vehicle_name(v.id) || coalesce(', ' || nullif(btrim(v.colour), ''), ''), r.base_cents, r.multi_day_cents, r.long_term_cents, app.partner_markup_bps(v.id), app.partner_commission_bps(v.id)) x
     from vehicles v join partner_rates r on r.vehicle_id = v.id join partners p on p.id = v.partner_id
    where p.business_name = '01 Motors' and v.retired_at is null) y));
select test.eq('the C43 AMG cars are told apart by their colour',
  (select count(distinct c ->> 'name') from pa_f, jsonb_array_elements(f -> 'cars') c where c ->> 'name' like '%C43 AMG,%'), 3::bigint);
select test.eq('the C43 AMG Blue: $250 / $225 / $200 a day on the sheet, 10% markup, 20% cut',
  (select count(*) from pa_f, jsonb_array_elements(f -> 'cars') c
    where c @> '{"sheet": {"base_cents": 25000, "multi_day_cents": 22500, "long_term_cents": 20000}, "markup_bps": 1000, "commission_bps": 2000}') >= 1, true);

-- a partner on the renter_price basis (test 30's): the facts say so, and its cars carry no sheet rates
select test.eq('a renter_price partner: its basis, and no sheet rates on its cars',
  (select format('%s %s', f ->> 'payout_basis', coalesce((select bool_or(c -> 'sheet' <> 'null'::jsonb) from jsonb_array_elements(f -> 'cars') c), false))
     from partners p, app.partner_agreement_facts(p.owner_id) f where p.business_name = 'Sm Rentals Inc'),
  'renter_price f');
