-- 2541: the order in which a renter may choose their coverage (Release 41; docs/changes/2026-11-12-r41-protection.md).
-- The owner, Nov 12: "Customers input what credit card they have and check if that credit card has coverage through our live
-- website checker and database. Only if their selected credit card has coverage AND they acknowledge they must pay with that
-- credit card can they pick credit card coverage. If not, they must have OPCF27, and to use OPCF27 they acknowledge they must
-- upload their policy. If they have neither, they must purchase the Protection Plan."
--
-- 1. The booking keeps the card the renter picked from the card list (card_rental_coverage, 0131/1400) and when they
--    acknowledged paying with it, or acknowledged uploading their policy for OPCF 27.
-- 2. app.card_cover_for_car(vehicle, days, card): the checker's answer before a booking exists (the request form), by the
--    same facts as app.card_product_check (1400): covered, not_covered or review. Only "covered" allows credit card coverage.
-- 3. app.coverage_choice_problem(option, check, card ack, policy ack): the one rule. Option 2 needs a card from the list that
--    covers this car (for a booking, also the same network as the card that paid: app.card_product_check) and the
--    acknowledgement; option 1 needs the acknowledgement (the policy upload itself stays required before the handover, as
--    0071/1401 rule); otherwise the Protection Plan.
-- 4. Enforced in the database: the website's request (details.source = web, set by the server), the renter's change of
--    protection (2540) and staff's change, where an Admin may override with a reason (recorded on the change, audited).
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. what the renter chose
alter table bookings
  add column if not exists coverage_card_id uuid references card_rental_coverage (id) on delete set null,
  add column if not exists coverage_card_ack_at timestamptz,
  add column if not exists opcf27_ack_at timestamptz;
comment on column bookings.coverage_card_id is 'Credit card coverage: the card (issuer and product) the renter picked from the card list (2541)';
comment on column bookings.coverage_card_ack_at is 'Credit card coverage: when the renter acknowledged they must pay for the rental with that card (2541)';
comment on column bookings.opcf27_ack_at is 'OPCF 27: when the renter acknowledged they must upload their auto policy with the endorsement (2541)';
alter table coverage_switches
  add column if not exists override_reason text check (char_length(override_reason) <= 500);
comment on column coverage_switches.override_reason is 'An Admin chose an option the coverage rule did not allow (no covering card, no acknowledgement), with this reason (2541).';

-- ================================================================ 2. the checker before a booking exists
create function app.card_cover_for_car(p_vehicle uuid, p_days integer, p_card uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  c card_rental_coverage;
  v_cents bigint := (app.vehicle_value(p_vehicle) ->> 'cents')::bigint;
  v_types text[] := app.vehicle_coverage_types(p_vehicle);
  v_no text[] := '{}';
  v_review text[] := '{}';
  v_name text;
  v_result text;
begin
  if p_card is not null then select * into c from card_rental_coverage where id = p_card; end if;
  if c.id is null then
    return jsonb_build_object('result', 'review', 'card_id', null, 'message', 'Pick your card from the list to check its rental car coverage.');
  end if;
  v_name := c.issuer || ' ' || c.card;
  if c.cdw_included = 'no' then v_no := v_no || format('The %s does not include rental car damage coverage.', v_name);
  elsif c.cdw_included = 'unknown' then v_review := v_review || format('We cannot confirm that the %s includes rental car damage coverage.', v_name);
  end if;
  if exists (select 1 from unnest(c.excluded_types) x where x = any (v_types)) then
    v_no := v_no || format('The %s does not cover this kind of car.', v_name);
  end if;
  if c.max_days is not null and coalesce(p_days, 1) > c.max_days then
    v_no := v_no || format('The %s covers rentals of up to %s days; this rental is %s days.', v_name, c.max_days, p_days);
  end if;
  if c.cdw_included <> 'no' then
    if c.max_msrp_cents is not null and v_cents is not null and v_cents > c.max_msrp_cents then
      v_no := v_no || format('The %s covers cars worth up to %s; this car is worth about %s.', v_name, app.money_text(c.max_msrp_cents), app.money_text(v_cents));
    elsif c.max_msrp_cents is not null and v_cents is null then
      v_review := v_review || format('We cannot confirm this car''s value against the %s limit of %s.', v_name, app.money_text(c.max_msrp_cents));
    elsif c.max_msrp_cents is null and c.cdw_included = 'yes' then
      v_review := v_review || format('We do not have the car value limit of the %s.', v_name);
    end if;
  end if;
  v_result := case when cardinality(v_no) > 0 then 'not_covered' when cardinality(v_review) > 0 then 'review' else 'covered' end;
  return jsonb_build_object('result', v_result, 'card_id', c.id, 'card_label', v_name, 'network', c.network,
    'message', case v_result when 'covered' then format('The %s covers this car for this rental.', v_name)
                             else array_to_string(v_no || v_review, ' ') end);
end $$;

-- ================================================================ 3. the one rule
create function app.coverage_choice_problem(p_option integer, p_check jsonb, p_card_ack boolean, p_opcf_ack boolean) returns text
language sql immutable as $$
  select case
    when p_option = 2 and (p_check is null or p_check ->> 'card_id' is null) then
      'Pick your credit card from the list to check its rental car coverage first'
    when p_option = 2 and p_check ->> 'result' <> 'covered' then
      coalesce(p_check ->> 'message', 'That card does not cover this car.')
      || ' Credit card coverage needs a card on our list that covers this car: choose OPCF 27 on your own auto policy, or the Protection Plan.'
    when p_option = 2 and coalesce(p_card_ack, false) is not true then
      'Tick that you will pay for the rental with this card: its coverage counts only on the card that paid'
    when p_option = 1 and coalesce(p_opcf_ack, false) is not true then
      'Tick that you will upload your auto policy with the OPCF 27 endorsement (the pink slip and the endorsement page)'
  end
$$;

-- for a booking: the card picked now or before, the network of the card that paid (1400), the acknowledgements given now or before
create function app.booking_coverage_choice_problem(b bookings, p_option integer, p jsonb) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_card uuid := coalesce(nullif(p ->> 'card', '')::uuid, b.coverage_card_id);
begin
  if p_option not in (1, 2) or b.booking_type = 'owner' or b.coverage_option = 4 or b.coverage_option = p_option then return null; end if;
  return app.coverage_choice_problem(p_option, case when v_card is null then null else app.card_product_check(b.id, v_card) end,
    coalesce((p ->> 'card_ack')::boolean, false) or (b.coverage_card_ack_at is not null and v_card is not distinct from b.coverage_card_id),
    coalesce((p ->> 'opcf27_ack')::boolean, false) or b.opcf27_ack_at is not null);
end $$;

create function app.booking_coverage_choice_save(p_booking uuid, p jsonb) returns void
language sql security definer set search_path = public, app as $$
  update bookings set
    coverage_card_id = coalesce(nullif(p ->> 'card', '')::uuid, coverage_card_id),
    coverage_card_ack_at = case when coalesce((p ->> 'card_ack')::boolean, false) then now() else coverage_card_ack_at end,
    opcf27_ack_at = case when coalesce((p ->> 'opcf27_ack')::boolean, false) then now() else opcf27_ack_at end
  where id = p_booking
$$;

-- what the request form asks before sending (the same rule; no booking yet)
create function public.server_coverage_choice_check(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_check jsonb;
  v_days integer;
begin
  v_days := public.calc_billable_days((p ->> 'pickup_at')::timestamptz, (p ->> 'return_at')::timestamptz);
  v_check := app.card_cover_for_car((p ->> 'vehicle_id')::uuid, v_days, nullif(p ->> 'card', '')::uuid);
  return v_check || jsonb_build_object('problem', app.coverage_choice_problem(nullif(p ->> 'option', '')::integer, v_check,
    coalesce((p ->> 'card_ack')::boolean, false), coalesce((p ->> 'opcf27_ack')::boolean, false)));
end $$;

-- ================================================================ 4. the website's request
alter function app.submit_booking_request(jsonb, inet, text, uuid) rename to submit_booking_request_pre2541;
create function app.submit_booking_request(p_request jsonb, p_ip inet default null, p_user_agent text default null, p_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.submit_booking_request_pre2541(p_request, p_ip, p_user_agent, p_user);
  b bookings;
  v_why text;
  v_c jsonb := coalesce(p_request -> 'coverage_choice', '{}'::jsonb);
begin
  if coalesce((v_out ->> 'ok')::boolean, false) and p_request #>> '{details,source}' = 'web' and nullif(v_out ->> 'booking_id', '') is not null then
    select * into b from bookings where id = (v_out ->> 'booking_id')::uuid;
    if b.coverage_option in (1, 2) and b.booking_type <> 'owner' then
      v_why := app.coverage_choice_problem(b.coverage_option,
        case when nullif(v_c ->> 'card', '') is null then null else app.card_cover_for_car(b.vehicle_id, b.billable_days, (v_c ->> 'card')::uuid) end,
        coalesce((v_c ->> 'card_ack')::boolean, false), coalesce((v_c ->> 'opcf27_ack')::boolean, false));
      -- an earlier request sent again (the same key) keeps what it had
      if v_why is not null and coalesce((v_out ->> 'created')::boolean, true) then raise exception '%', v_why using errcode = '23514'; end if;
      if v_why is null then perform app.booking_coverage_choice_save(b.id, case when b.coverage_option = 2 then v_c - 'opcf27_ack' else v_c - 'card' - 'card_ack' end); end if;
    end if;
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.submit_booking_request(jsonb, inet, text, uuid)'::regprocedure, 'app.submit_booking_request_pre2541(jsonb, inet, text, uuid)'::regprocedure);

-- ================================================================ 5. the change of protection (2540): the renter, and staff with an Admin override
alter function app.renter_protection_change(uuid, jsonb) rename to renter_protection_change_pre2541;
create function app.renter_protection_change(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  b bookings;
  v_to integer := nullif(btrim(coalesce(p_ ->> 'to', '')), '')::integer;
  v_why text;
begin
  if not coalesce((p_ ->> 'withdraw')::boolean, false) and v_to in (1, 2) then
    select * into b from bookings where id::text = p_ ->> 'booking' or booking_number = upper(btrim(coalesce(p_ ->> 'booking', '')));
    if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
    perform app.assert_booking_renter(b.id, p_by);
    v_why := app.booking_coverage_choice_problem(b, v_to, p_);
    if v_why is not null then raise exception '%', v_why using errcode = '23514'; end if;
    perform app.booking_coverage_choice_save(b.id, case when v_to = 2 then p_ - 'opcf27_ack' else p_ - 'card' - 'card_ack' end);
  end if;
  return app.renter_protection_change_pre2541(p_by, p_);
end $$;
select pg_temp.copy_grants('app.renter_protection_change(uuid, jsonb)'::regprocedure, 'app.renter_protection_change_pre2541(uuid, jsonb)'::regprocedure);

alter function app.protection_change(uuid, jsonb) rename to protection_change_pre2541;
create function app.protection_change(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  b bookings;
  v_to integer := nullif(btrim(coalesce(p_ ->> 'to', '')), '')::integer;
  v_side text := coalesce(nullif(current_setting('app.protection_side', true), ''), 'staff');
  v_why text;
  v_override text;
  v_out jsonb;
begin
  if v_side = 'staff' and v_to in (1, 2) then
    select * into b from bookings where id::text = p_ ->> 'booking' or booking_number = upper(btrim(coalesce(p_ ->> 'booking', '')));
    if b.id is not null then
      v_why := app.booking_coverage_choice_problem(b, v_to, p_);
      if v_why is not null then
        if not coalesce((p_ ->> 'override')::boolean, false) then
          raise exception '% (an Admin can override this with a reason)', v_why using errcode = '23514';
        end if;
        if not app.user_is_admin(p_by) then raise exception 'Only an Admin overrides the coverage rule' using errcode = '42501'; end if;
        v_override := coalesce(nullif(left(btrim(coalesce(p_ ->> 'reason', '')), 500), ''), 'Admin override');
      else
        perform app.booking_coverage_choice_save(b.id, case when v_to = 2 then p_ - 'opcf27_ack' else p_ - 'card' - 'card_ack' end);
      end if;
    end if;
  end if;
  v_out := app.protection_change_pre2541(p_by, p_);
  if v_override is not null then
    update coverage_switches set override_reason = v_override where id = (v_out ->> 'switch_id')::uuid;
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null, format('Admin override of the coverage rule: %s (%s)', v_why, v_override), p_by, 'staff',
      jsonb_build_object('coverage_switch', v_out ->> 'switch_id', 'coverage_override', true));
  end if;
  return v_out || jsonb_build_object('override', v_override is not null);
end $$;
select pg_temp.copy_grants('app.protection_change(uuid, jsonb)'::regprocedure, 'app.protection_change_pre2541(uuid, jsonb)'::regprocedure);

-- the dialog shows the rule for each option (and the card picked, if any)
alter function app.protection_options_of(bookings, text, boolean, text) rename to protection_options_of_pre2541;
create function app.protection_options_of(b bookings, p_side text, p_may boolean, p_why text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.protection_options_of_pre2541(b, p_side, p_may, p_why);
  o jsonb;
  v_opts jsonb := '[]'::jsonb;
  c card_rental_coverage;
begin
  for o in select * from jsonb_array_elements(x -> 'options') loop
    v_opts := v_opts || (o || jsonb_build_object('rule', case when (o ->> 'current')::boolean then null
                                                           else app.booking_coverage_choice_problem(b, (o ->> 'option')::integer, '{}'::jsonb) end));
  end loop;
  select * into c from card_rental_coverage where id = b.coverage_card_id;
  return x || jsonb_build_object('options', v_opts,
    'card', case when c.id is null then null else jsonb_build_object('id', c.id, 'label', c.issuer || ' ' || c.card, 'check', app.card_product_check(b.id, c.id)) end,
    'card_ack', b.coverage_card_ack_at is not null, 'opcf27_ack', b.opcf27_ack_at is not null);
end $$;
select pg_temp.copy_grants('app.protection_options_of(bookings, text, boolean, text)'::regprocedure, 'app.protection_options_of_pre2541(bookings, text, boolean, text)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname = any (array['card_cover_for_car', 'booking_coverage_choice_problem', 'booking_coverage_choice_save',
                     'submit_booking_request_pre2541', 'renter_protection_change', 'renter_protection_change_pre2541', 'protection_change', 'protection_change_pre2541',
                     'protection_options_of', 'protection_options_of_pre2541']))
               or (n.nspname = 'public' and p.proname = 'server_coverage_choice_check')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
grant execute on function app.coverage_choice_problem(integer, jsonb, boolean, boolean) to service_role;
