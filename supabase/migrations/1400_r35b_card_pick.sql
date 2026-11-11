-- 1400_r35b_card_pick.sql
-- Release 35 part B, task 1 (docs/changes/2026-11-11-r35-card-pick-opcf-fuel-delivery.md). The owner, November 11, 2026:
-- "when a renter chooses credit card coverage they pick their card (issuer + card product) from a searchable list. If the
-- card has no coverage, or the car's value or type is over the card's limits, tell the renter clearly and offer the other
-- coverage options. Unknown cards: staff review. Admin can edit the database. Enforce server-side."
--
-- 1. card_rental_coverage (0131, 48 cards from the issuers' guides and Rewards Canada) gets the structured facts the check
--    needs: the network, whether it includes rental car damage coverage (CDW) as yes, no or unknown, the vehicle types it
--    leaves out (from a fixed list), and whether the renter must decline the rental company's CDW and pay the full rental on
--    the card (yes, no or unknown). They are filled from each card's own text at this migration; nothing is guessed: a
--    card whose document says nothing stays unknown. Two cards added from their sources (SimplyCash Preferred, Scene+ Visa).
-- 2. The car's value: vehicles.black_book_value_cents (Canadian Black Book, with its date) and vehicles.estimated_value_cents,
--    editable on the car (Admin and Fleet); app.vehicle_value prefers the Black Book on the car, then the latest buyout's
--    Black Book value, then the estimate. The car's types for the exclusions: app.vehicle_coverage_types (the class, the
--    body and the exotic makes of Program settings card_exotic_makes).
-- 3. app.card_product_check(booking, card): covered, not_covered (with each reason) or review (an unknown card, a card whose
--    coverage or value limit is not known, a car without a value on file).
-- 4. The renter picks the card (public.renter_submit_card_coverage gains p_card and p_card_other; a card is required): a
--    card that does not cover the car is refused with the reason and the other options; a pick that needs review goes to
--    staff with the reason. public.server_card_coverage_preview gives the page the same answer before the renter confirms.
--    Staff cannot approve a card proof whose card does not cover the car (app.review_coverage_proof).
-- 5. Admin > Settings > Card coverage saves the new fields (app.card_coverage_save).
-- No applied migration is edited.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '1400: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the card list's structured facts
create or replace function app.card_vehicle_types() returns text[]
language sql immutable as $$
  select array['exotic', 'luxury', 'truck', 'van', 'off_road', 'antique', 'motorcycle', 'limousine', 'rv']
$$;
comment on function app.card_vehicle_types() is 'The vehicle types a card''s rental coverage may leave out (card_rental_coverage.excluded_types), matched against app.vehicle_coverage_types.';

alter table card_rental_coverage
  add column if not exists network text not null default 'unknown' check (network in ('visa', 'mastercard', 'amex', 'unknown')),
  add column if not exists cdw_included text not null default 'unknown' check (cdw_included in ('yes', 'no', 'unknown')),
  add column if not exists excluded_types text[] not null default '{}',
  add column if not exists must_decline_cdw text not null default 'unknown' check (must_decline_cdw in ('yes', 'no', 'unknown')),
  add column if not exists must_pay_full text not null default 'unknown' check (must_pay_full in ('yes', 'no', 'unknown'));
alter table card_rental_coverage drop constraint if exists card_rental_coverage_excluded_types_known;
alter table card_rental_coverage add constraint card_rental_coverage_excluded_types_known check (excluded_types <@ app.card_vehicle_types());
comment on column card_rental_coverage.network is 'visa, mastercard or amex: the card a renter picks must match the brand of the card that paid';
comment on column card_rental_coverage.cdw_included is 'yes: the card includes rental car damage (collision and loss) coverage; no: it does not; unknown: not stated in what was read (staff review)';
comment on column card_rental_coverage.excluded_types is 'Vehicle types the coverage leaves out, from app.card_vehicle_types(); a car of one of them is not covered';
comment on column card_rental_coverage.must_decline_cdw is 'yes: the renter must decline the rental company''s CDW or LDW for the card to cover';
comment on column card_rental_coverage.must_pay_full is 'yes: the full rental must be paid on the card';
comment on column card_rental_coverage.last_checked is 'The date the facts were last verified against source_url or guide_url';

-- the network from the card's name (an American Express issuer is amex)
update card_rental_coverage set network = case
    when issuer ilike 'American Express%' or card ~* '(american express|\mamex\M)' then 'amex'
    when card ~* '\mvisa\M' then 'visa'
    when card ~* 'mastercard' then 'mastercard'
    when issuer = 'Chase' or (issuer = 'Capital One' and card ilike 'Venture%') then 'visa'
    else 'unknown' end
 where network = 'unknown';
-- coverage: none is no; a card with its days or who pays first stated includes it; otherwise unknown
update card_rental_coverage set cdw_included = case
    when coverage = 'none' then 'no'
    when coverage in ('primary', 'secondary') or max_days is not null then 'yes'
    else 'unknown' end
 where cdw_included = 'unknown';
update card_rental_coverage set must_decline_cdw = 'yes' where must_decline_cdw = 'unknown' and conditions ~* 'decline';
update card_rental_coverage set must_pay_full = 'yes' where must_pay_full = 'unknown' and conditions ~* '(full rental|entire rental|full cost|charge the (full|entire|whole))';
-- the exclusions named in each card's own text
update card_rental_coverage c set excluded_types = coalesce((select array_agg(t order by t) from (
    select 'exotic' as t where c.exclusions ~* '(exotic|ferrari|lamborghini|rolls|aston martin|bentley)'
    union all select 'luxury' where c.exclusions ~* 'luxury'
    union all select 'truck' where c.exclusions ~* '(\mtrucks?\M|pickup)'
    union all select 'van' where c.exclusions ~* '\m(cargo )?vans?\M'
    union all select 'off_road' where c.exclusions ~* 'off.road'
    union all select 'antique' where c.exclusions ~* 'antique'
    union all select 'motorcycle' where c.exclusions ~* 'motorcycle'
    union all select 'limousine' where c.exclusions ~* 'limousine'
    union all select 'rv' where c.exclusions ~* '(\mrvs?\M|camper|recreational vehicle|motorhome)') x), '{}')
 where c.excluded_types = '{}';

-- two more Canadian cards, from their sources (verified November 11, 2026)
insert into card_rental_coverage (country, issuer, card, coverage, max_msrp_cents, max_days, exclusions, conditions, note, guide_url, source_url, issuer_checked, last_checked, sort_order,
                                  network, cdw_included, must_decline_cdw, must_pay_full) values
('CA', 'American Express', 'SimplyCash Preferred Card', 'ask', 8500000, 48, 'In the certificate of insurance.',
 'Charge the full rental to the card and decline the rental company''s CDW, LDW or similar option.',
 'From a third-party summary of the American Express cards; read the certificate before relying on it.',
 'https://www.americanexpress.com/en-ca/insurance/', 'https://travelupdate.com/american-express-car-rental-theft-and-damage-insurance/', false, '2026-11-11', 16,
 'amex', 'yes', 'yes', 'yes'),
('CA', 'Scotiabank', 'Scene+ Visa', 'none', null, null, '', '',
 'Scotiabank''s benefits page for this card lists rental discounts at Avis and Budget, and no rental car damage coverage.',
 'https://www.scotiabank.com/ca/en/personal/credit-cards/visa/scene-card/welcome-kit/benefits-and-features.html', null, true, '2026-11-11', 60,
 'visa', 'no', 'unknown', 'unknown')
on conflict (country, issuer, card) do nothing;

-- ================================================================ 2. the car's value and its types
alter table vehicles
  add column if not exists black_book_value_cents bigint check (black_book_value_cents is null or black_book_value_cents > 0),
  add column if not exists black_book_checked_on date,
  add column if not exists estimated_value_cents bigint check (estimated_value_cents is null or estimated_value_cents > 0);
comment on column vehicles.black_book_value_cents is 'The car''s Canadian Black Book value on file (cents), compared with a credit card''s car value limit (1400)';
comment on column vehicles.estimated_value_cents is 'The car''s estimated value (cents) when no Black Book value is on file; compared with a credit card''s car value limit (1400)';

alter table program_settings
  add column if not exists card_exotic_makes text[] not null default array['Aston Martin', 'Bentley', 'Bugatti', 'Ferrari', 'Lamborghini', 'Lotus', 'Maserati', 'Maybach', 'McLaren', 'Pagani', 'Rolls-Royce'];
comment on column program_settings.card_exotic_makes is 'Makes counted as exotic for credit card rental coverage (cards that leave out exotic cars), on top of cars of the exotic class (1400)';

create or replace function app.vehicle_value(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case
    when v.black_book_value_cents is not null then jsonb_build_object('cents', v.black_book_value_cents, 'source', 'black_book', 'on', v.black_book_checked_on)
    when bb.cents is not null then jsonb_build_object('cents', bb.cents, 'source', 'black_book', 'on', bb.on_day)
    when v.estimated_value_cents is not null then jsonb_build_object('cents', v.estimated_value_cents, 'source', 'estimate', 'on', null)
    else jsonb_build_object('cents', null, 'source', null, 'on', null) end
    from vehicles v
    left join lateral (select x.black_book_value_cents as cents, x.offered_on as on_day from vehicle_buyouts x
                        where x.vehicle_id = v.id and x.black_book_value_cents is not null order by x.offered_on desc limit 1) bb on true
   where v.id = p_vehicle
$$;

create or replace function app.vehicle_coverage_types(p_vehicle uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(distinct t order by t), '{}') from vehicles v, lateral (
    select 'exotic' as t where v.class = 'exotic' or lower(coalesce(v.make, '')) = any (select lower(m) from unnest((app.settings()).card_exotic_makes) m)
    union all select 'luxury' where v.class = 'luxury'
    union all select 'truck' where v.class = 'pickup' or coalesce(v.body_type, '') ~* '(pickup|truck)'
    union all select 'van' where v.class = 'van' or (coalesce(v.body_type, '') ~* '\mvan\M' and coalesce(v.body_type, '') !~* 'minivan')) x
   where v.id = p_vehicle
$$;

-- ================================================================ 3. the check
create or replace function app.card_type_label(p text) returns text
language sql immutable as $$
  select case p when 'exotic' then 'exotic cars' when 'luxury' then 'luxury cars' when 'truck' then 'trucks and pickups' when 'van' then 'vans'
                when 'off_road' then 'off-road vehicles' when 'antique' then 'antique cars' when 'motorcycle' then 'motorcycles'
                when 'limousine' then 'limousines' when 'rv' then 'RVs and campers' else p end
$$;

-- result: covered, not_covered or review; reasons: [{code, text}] (every reason found, the refusals first)
create or replace function app.card_product_check(p_booking uuid, p_card uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  c card_rental_coverage;
  pm payment_methods;
  v_value jsonb;
  v_cents bigint;
  v_types text[];
  v_hit text[];
  v_no jsonb := '[]'::jsonb;
  v_review jsonb := '[]'::jsonb;
  v_result text;
  v_name text;
  v_brand text;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return null; end if;
  if p_card is not null then select * into c from card_rental_coverage where id = p_card; end if;
  select * into pm from payment_methods where id = b.card_on_file_id;
  v_value := app.vehicle_value(b.vehicle_id);
  v_cents := (v_value ->> 'cents')::bigint;
  v_types := app.vehicle_coverage_types(b.vehicle_id);
  v_name := case when c.id is null then null else c.issuer || ' ' || c.card end;
  v_brand := lower(coalesce(pm.card_brand, ''));
  if c.id is null then
    v_review := v_review || jsonb_build_object('code', 'unknown_card', 'text', 'Your card is not on our list yet: our team checks its rental car coverage before pickup.');
  else
    if c.network <> 'unknown' and v_brand in ('visa', 'mastercard', 'amex') and v_brand <> c.network then
      v_no := v_no || jsonb_build_object('code', 'network_mismatch', 'text', format('The %s is a %s card, but you paid with a %s card. The coverage counts only on the card that paid.',
                v_name, case c.network when 'amex' then 'American Express' when 'visa' then 'Visa' else 'Mastercard' end,
                case v_brand when 'amex' then 'American Express' when 'visa' then 'Visa' else 'Mastercard' end));
    end if;
    if c.cdw_included = 'no' then
      v_no := v_no || jsonb_build_object('code', 'no_cdw', 'text', format('The %s does not include rental car damage coverage.', v_name));
    elsif c.cdw_included = 'unknown' then
      v_review := v_review || jsonb_build_object('code', 'cdw_unknown', 'text', format('We do not know yet whether the %s includes rental car damage coverage: our team checks it before pickup.', v_name));
    end if;
    v_hit := array(select x from unnest(c.excluded_types) x where x = any (v_types) order by x);
    if cardinality(v_hit) > 0 then
      v_no := v_no || jsonb_build_object('code', 'excluded_type', 'types', to_jsonb(v_hit),
                'text', format('The %s does not cover %s, and this car is one.', v_name, (select string_agg(app.card_type_label(x), ' or ') from unnest(v_hit) x)));
    end if;
    if c.max_days is not null and b.billable_days > c.max_days then
      v_no := v_no || jsonb_build_object('code', 'too_long', 'text', format('The %s covers rentals of up to %s days; this rental is %s days.', v_name, c.max_days, b.billable_days));
    end if;
    if c.cdw_included <> 'no' then
      if c.max_msrp_cents is not null and v_cents is not null and v_cents > c.max_msrp_cents then
        v_no := v_no || jsonb_build_object('code', 'over_value', 'text', format('The %s covers cars worth up to %s; this car is worth about %s.', v_name, app.money_text(c.max_msrp_cents), app.money_text(v_cents)));
      elsif c.max_msrp_cents is not null and v_cents is null then
        v_review := v_review || jsonb_build_object('code', 'value_unknown', 'text', format('The %s covers cars worth up to %s: our team checks this car''s value before pickup.', v_name, app.money_text(c.max_msrp_cents)));
      elsif c.max_msrp_cents is null and c.cdw_included = 'yes' then
        v_review := v_review || jsonb_build_object('code', 'limit_unknown', 'text', format('We do not have the car value limit of the %s: our team checks it before pickup.', v_name));
      end if;
    end if;
  end if;
  v_result := case when jsonb_array_length(v_no) > 0 then 'not_covered' when jsonb_array_length(v_review) > 0 then 'review' else 'covered' end;
  return jsonb_build_object(
    'result', v_result, 'reasons', v_no || v_review,
    'card_id', c.id, 'card_label', v_name, 'network', c.network, 'cdw_included', c.cdw_included, 'max_msrp_cents', c.max_msrp_cents, 'max_days', c.max_days,
    'excluded_types', to_jsonb(coalesce(c.excluded_types, '{}')), 'must_decline_cdw', c.must_decline_cdw, 'must_pay_full', c.must_pay_full,
    'source_url', coalesce(c.guide_url, c.source_url), 'last_checked', c.last_checked,
    'vehicle_value_cents', v_cents, 'vehicle_value_source', v_value ->> 'source', 'vehicle_types', to_jsonb(v_types), 'rental_days', b.billable_days,
    'paid_brand', nullif(v_brand, ''),
    'message', case v_result
      when 'not_covered' then (select string_agg(r ->> 'text', ' ') from jsonb_array_elements(v_no) r)
                              || ' Choose OPCF 27 on your own auto policy, or ask for the CarmaCars Protection Plan.'
      when 'review' then (select string_agg(r ->> 'text', ' ') from jsonb_array_elements(v_review) r)
      else format('The %s covers this car for this rental, as its guide says.', v_name)
           || case when c.must_decline_cdw = 'yes' then ' Decline any other damage waiver.' else '' end
           || case when c.must_pay_full = 'yes' then ' The full rental must be paid on this card.' else '' end end);
end $$;

-- ================================================================ 4. the renter's pick
alter table coverage_proofs
  add column if not exists card_coverage_id uuid references card_rental_coverage (id) on delete set null,
  add column if not exists card_other text check (card_other is null or length(card_other) <= 120),
  add column if not exists card_check jsonb;
comment on column coverage_proofs.card_coverage_id is 'Option 2: the card (issuer and product) the renter picked from the list (1400)';
comment on column coverage_proofs.card_other is 'Option 2: the card the renter typed when it is not on the list (staff review)';
comment on column coverage_proofs.card_check is 'Option 2: app.card_product_check when the renter confirmed (result, reasons, the car''s value and types)';

create or replace function app.submit_card_pick(p_booking uuid, p_by uuid, p_confirm boolean, p_text text, p_card uuid, p_card_other text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_other text := nullif(left(btrim(coalesce(p_card_other, '')), 120), '');
  v_check jsonb;
  v_id uuid;
begin
  perform app.coverage_assert_actor(p_booking, p_by);
  if p_card is null and v_other is null then
    raise exception 'Choose your card from the list, or type its name if it is not there' using errcode = '22023';
  end if;
  if p_card is not null and not exists (select 1 from card_rental_coverage c where c.id = p_card and c.is_active) then
    raise exception 'Choose your card from the list' using errcode = '22023';
  end if;
  v_check := app.card_product_check(p_booking, p_card);
  if v_check ->> 'result' = 'not_covered' then
    raise exception '%', v_check ->> 'message' using errcode = '23514';
  end if;
  v_id := app.submit_card_coverage(p_booking, p_by, p_confirm, p_text);
  update coverage_proofs set card_coverage_id = p_card, card_other = case when p_card is null then v_other end,
         card_check = v_check || jsonb_build_object('checked_at', now(), 'card_other', case when p_card is null then v_other end)
   where id = v_id and status = 'submitted';
  return v_id;
end $$;

-- the renter's door: a card is now required
drop function if exists public.renter_submit_card_coverage(uuid, uuid, boolean, text);
create function public.renter_submit_card_coverage(p_booking uuid, p_by uuid, p_confirm boolean, p_text text default null, p_card uuid default null, p_card_other text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
begin
  perform app.submit_card_pick(p_booking, p_by, p_confirm, p_text, p_card, p_card_other);
  return app.renter_coverage(p_booking);
end $$;
revoke all on function public.renter_submit_card_coverage(uuid, uuid, boolean, text, uuid, text) from public, anon, authenticated;
grant execute on function public.renter_submit_card_coverage(uuid, uuid, boolean, text, uuid, text) to service_role;

-- the page's answer before the renter confirms
create or replace function public.server_card_coverage_preview(p_booking uuid, p_by uuid, p_card uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.coverage_assert_actor(p_booking, p_by);
  return app.card_product_check(p_booking, p_card);
end $$;
revoke all on function public.server_card_coverage_preview(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.server_card_coverage_preview(uuid, uuid, uuid) to service_role;

-- staff cannot approve a card that does not cover the car (checked again now: the car or the dates may have changed)
select pg_temp.patch_fn('app.review_coverage_proof(uuid, uuid, boolean, text, jsonb)'::regprocedure,
  $o$    elsif cp.coverage_option = 2 then
      v_check := app.card_coverage_check(b.id);$o$,
  $n$    elsif cp.coverage_option = 2 then
      if cp.card_coverage_id is not null and app.card_product_check(b.id, cp.card_coverage_id) ->> 'result' = 'not_covered' then
        raise exception 'The card the renter picked does not cover this car: %', app.card_product_check(b.id, cp.card_coverage_id) ->> 'message' using errcode = '23514';
      end if;
      v_check := app.card_coverage_check(b.id);$n$);

-- the renter's read and the staff review carry the pick
alter function app.renter_coverage(uuid) rename to renter_coverage_pre1400;
create function app.renter_coverage(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.renter_coverage_pre1400(p_booking);
  cp coverage_proofs;
begin
  if x is null then return null; end if;
  cp := app.current_coverage_proof(p_booking);
  return x || jsonb_build_object('card_pick', case when cp.id is null or cp.coverage_option <> 2 or (cp.card_coverage_id is null and cp.card_other is null) then null
    else jsonb_build_object('card_id', cp.card_coverage_id, 'card_other', cp.card_other,
           'label', coalesce((select c.issuer || ' ' || c.card from card_rental_coverage c where c.id = cp.card_coverage_id), cp.card_other),
           'check', app.card_product_check(p_booking, cp.card_coverage_id)) end);
end $$;

alter function app.coverage_review_facts(uuid) rename to coverage_review_facts_pre1400;
create function app.coverage_review_facts(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.coverage_review_facts_pre1400(p_booking);
  cp coverage_proofs;
begin
  if x is null then return null; end if;
  cp := app.current_coverage_proof(p_booking);
  return x || jsonb_build_object('card_pick', case when cp.id is null or cp.coverage_option <> 2 or (cp.card_coverage_id is null and cp.card_other is null) then null
    else jsonb_build_object('card_id', cp.card_coverage_id, 'card_other', cp.card_other,
           'label', coalesce((select c.issuer || ' ' || c.card from card_rental_coverage c where c.id = cp.card_coverage_id), cp.card_other),
           'check', app.card_product_check(p_booking, cp.card_coverage_id), 'at_confirm', cp.card_check) end);
end $$;

do $$
declare g text; f text;
begin
  foreach f in array array['app.renter_coverage(uuid)', 'app.coverage_review_facts(uuid)'] loop
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      execute format('revoke all on function %s from %I', f, g);
      if has_function_privilege(g, replace(f, '(uuid)', '_pre1400(uuid)'), 'execute') then execute format('grant execute on function %s to %I', f, g); end if;
    end loop;
    execute format('revoke all on function %s from public', f);
  end loop;
  foreach f in array array['app.card_product_check(uuid, uuid)', 'app.submit_card_pick(uuid, uuid, boolean, text, uuid, text)', 'app.vehicle_value(uuid)', 'app.vehicle_coverage_types(uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- ================================================================ 5. Admin: the new fields
create or replace function app.card_coverage_save(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_values jsonb := coalesce(p -> 'values', '{}'::jsonb);
  v_key text := nullif(p ->> 'key', '');
  v_allowed constant text[] := array['country', 'issuer', 'card', 'coverage', 'max_msrp_cents', 'value_note', 'max_days', 'exclusions', 'conditions',
                                      'car_sharing', 'note', 'guide_url', 'source_url', 'issuer_checked', 'last_checked', 'sort_order', 'is_active',
                                      'network', 'cdw_included', 'excluded_types', 'must_decline_cdw', 'must_pay_full'];
  v_facts constant text[] := array['coverage', 'max_msrp_cents', 'value_note', 'max_days', 'exclusions', 'conditions', 'car_sharing', 'guide_url', 'issuer_checked',
                                    'network', 'cdw_included', 'excluded_types', 'must_decline_cdw', 'must_pay_full'];
  v_cols text[];
  v_out jsonb;
  v_types text[];
  k text;
begin
  perform app.assert_admin(p_admin);
  perform set_config('request.jwt.claim.sub', p_admin::text, true);
  perform set_config('request.jwt.claims', (coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb || jsonb_build_object('sub', p_admin))::text, true);
  if exists (select 1 from jsonb_object_keys(v_values) x where not (x = any (v_allowed))) then
    raise exception 'Not a field of card_rental_coverage: %', (select string_agg(x, ', ') from jsonb_object_keys(v_values) x where not (x = any (v_allowed))) using errcode = '22023';
  end if;
  for k in select x from jsonb_object_keys(v_values) x where x in ('issuer', 'card', 'value_note', 'exclusions', 'conditions', 'car_sharing', 'note', 'guide_url', 'source_url') loop
    if jsonb_typeof(v_values -> k) = 'string' then
      v_values := v_values || jsonb_build_object(k, case when btrim(v_values ->> k) = '' and k not in ('exclusions', 'conditions') then null else btrim(v_values ->> k) end);
    end if;
  end loop;
  -- the excluded types: a list, or words separated by commas ("exotic, van")
  if v_values ? 'excluded_types' then
    v_types := case jsonb_typeof(v_values -> 'excluded_types')
      when 'array' then array(select distinct lower(btrim(x)) from jsonb_array_elements_text(v_values -> 'excluded_types') x where btrim(x) <> '')
      when 'string' then array(select distinct lower(btrim(x)) from unnest(string_to_array(v_values ->> 'excluded_types', ',')) x where btrim(x) <> '')
      else '{}'::text[] end;
    v_types := array(select replace(replace(x, '-', '_'), ' ', '_') from unnest(v_types) x order by 1);
    if not v_types <@ app.card_vehicle_types() then
      raise exception 'Excluded types are among: %', array_to_string(app.card_vehicle_types(), ', ') using errcode = '22023';
    end if;
    v_values := v_values || jsonb_build_object('excluded_types', to_jsonb(v_types));
  end if;
  v_values := v_values || coalesce((select jsonb_object_agg(x.k, x.d) from (values ('exclusions', '""'::jsonb), ('conditions', '""'::jsonb), ('sort_order', '0'::jsonb),
      ('issuer_checked', 'false'::jsonb), ('is_active', 'true'::jsonb), ('coverage', '"ask"'::jsonb), ('country', '"CA"'::jsonb),
      ('network', '"unknown"'::jsonb), ('cdw_included', '"unknown"'::jsonb), ('must_decline_cdw', '"unknown"'::jsonb), ('must_pay_full', '"unknown"'::jsonb)) x(k, d)
    where v_values ? x.k and jsonb_typeof(v_values -> x.k) = 'null'), '{}'::jsonb);
  if (v_values ? 'guide_url' and v_values ->> 'guide_url' !~ '^https://[^[:space:]]+$') or (v_values ? 'source_url' and v_values ->> 'source_url' !~ '^https://[^[:space:]]+$') then
    raise exception 'A link starts with https:// and has no spaces' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(v_values) x where x = any (v_facts)) and not (v_values ? 'last_checked') then
    v_values := v_values || jsonb_build_object('last_checked', app.today());
  end if;
  if v_values ? 'last_checked' and (v_values ->> 'last_checked') is null then v_values := v_values - 'last_checked'; end if;
  v_values := v_values || jsonb_build_object('updated_by', p_admin);
  v_cols := array(select x from jsonb_object_keys(v_values) x);
  if v_key is null then
    if not (v_values ? 'issuer' and v_values ? 'card') then raise exception 'Give the issuer and the card' using errcode = '22023'; end if;
    execute format('insert into card_rental_coverage (%s) select %s from jsonb_populate_record(null::card_rental_coverage, $1) r returning to_jsonb(card_rental_coverage.*)',
                   (select string_agg(format('%I', c), ', ') from unnest(v_cols) c), (select string_agg(format('r.%I', c), ', ') from unnest(v_cols) c))
      into v_out using v_values;
  else
    if cardinality(v_cols) <= 1 then raise exception 'Nothing to change' using errcode = '22023'; end if;
    execute format('update card_rental_coverage t set %s from jsonb_populate_record(null::card_rental_coverage, $1) r where t.id::text = $2 returning to_jsonb(t.*)',
                   (select string_agg(format('%I = r.%I', c, c), ', ') from unnest(v_cols) c))
      into v_out using v_values, v_key;
    if v_out is null then raise exception 'That card is not there any more' using errcode = 'P0002'; end if;
  end if;
  return v_out;
exception when unique_violation then
  raise exception 'That card is already on the list' using errcode = '23505';
end $$;

-- ================================================================ 6. the car's value on the car page (Admin and Fleet)
create or replace function app.vehicle_value_fuel(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v vehicles;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('vehicle_id', v.id, 'black_book_value_cents', v.black_book_value_cents, 'black_book_checked_on', v.black_book_checked_on,
    'estimated_value_cents', v.estimated_value_cents, 'value', app.vehicle_value(v.id), 'coverage_types', to_jsonb(app.vehicle_coverage_types(v.id)));
end $$;

create or replace function app.vehicle_value_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_new jsonb;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')) then raise exception 'Only an Admin or fleet sets a car''s value' using errcode = '42501'; end if;
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid for update;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  update vehicles set
    black_book_value_cents = case when p ? 'black_book_value_cents' then nullif(p ->> 'black_book_value_cents', '')::bigint else black_book_value_cents end,
    black_book_checked_on = case when p ? 'black_book_checked_on' then nullif(p ->> 'black_book_checked_on', '')::date
                                 when p ? 'black_book_value_cents' and nullif(p ->> 'black_book_value_cents', '')::bigint is distinct from v.black_book_value_cents then app.today()
                                 else black_book_checked_on end,
    estimated_value_cents = case when p ? 'estimated_value_cents' then nullif(p ->> 'estimated_value_cents', '')::bigint else estimated_value_cents end
   where id = v.id;
  v_new := app.vehicle_value_fuel(p_by, p);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'vehicle_value_set', 'vehicles', v.id::text,
          jsonb_build_object('black_book_value_cents', v.black_book_value_cents, 'estimated_value_cents', v.estimated_value_cents), v_new);
  return v_new;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1400;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_read', 'admin_read', 'va_read') and p_name = 'vehicle_value_fuel' then
    perform app.door_begin(p_user, p_aal);
    if p_user is not null and app.staff_is_member(p_user) and not app.staff_fully_onboarded(p_user) then
      raise exception 'Finish your onboarding first: the academy, your staff agreement, then the WhatsApp groups (Welcome shows the next step)' using errcode = '42501';
    end if;
    return app.vehicle_value_fuel(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call in ('ops_do', 'admin_do', 'va_do') and p_name = 'vehicle_value_set' then
    perform app.door_begin(p_user, p_aal);
    if p_user is not null and app.staff_is_member(p_user) and not app.staff_fully_onboarded(p_user) then
      raise exception 'Finish your onboarding first: the academy, your staff agreement, then the WhatsApp groups (Welcome shows the next step)' using errcode = '42501';
    end if;
    return app.vehicle_value_set(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre1400(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare g text; f text;
begin
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    execute format('revoke all on function app.door(uuid, text, text, text, jsonb) from %I', g);
    if has_function_privilege(g, 'app.door_pre1400(uuid, text, text, text, jsonb)', 'execute') then execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g); end if;
  end loop;
  execute 'revoke all on function app.door(uuid, text, text, text, jsonb) from public';
  foreach f in array array['app.vehicle_value_fuel(uuid, jsonb)', 'app.vehicle_value_set(uuid, jsonb)', 'app.card_type_label(text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
