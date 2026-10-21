-- 0070_listing_no_roadblocks.sql
-- The owner, October 21, 2026: "It's a necessity to be able to list cars with no roadblocks."
-- (docs/changes/2026-10-21-listing-no-roadblocks.md)
--   1. A car goes public with only the basics: year, make, model, the plate or the VIN, who supplies it, and its rates
--      (pre-filled from the defaults). Everything else is a checklist on the car, never a reason to refuse: sample
--      photos stand in for real ones (and a real photo whose plate is not checked yet stays private while the others
--      show), a clean template text stands in for the AI copy, missing details (colour, seats, gearbox, body), owner
--      documents, signatures, invoices, the safety certificate, the registry, the tracker and possible duplicates are
--      warnings.
--   2. "Publish now" on every car page: one click when the basics exist (with no rates yet it uses the default rates and
--      says so). Program setting "Publish new cars automatically" (on by default): a new car is published as soon as its
--      basics are complete (added with rates, rates saved, an owner's application approved, the enrollment confirmed).
--   3. The only hard gates are the ones the law and the insurer need before a HANDOVER, enforced at the handover: the car
--      on the fleet policy (a program owner's car whose onboarding is not confirmed is never handed over) and the renter
--      verification (unchanged). Staff see a warning on a request for a car not on the policy yet when they send the
--      offer. A car in onboarding can be on the site and take requests and offers.
--   4. Staff add a car by its plate when the VIN is not at hand (vehicles.vin is optional when the plate is given).
-- Functions changed are wrapped (renamed with the suffix _pre0070) or replaced with the same signature. No applied
-- migration is edited.

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists listing_publish_new_cars_automatically boolean not null default true,
  add column if not exists listing_default_daily_rate_cents jsonb not null
    default '{"economy": 5900, "standard": 6900, "premium": 10900, "suv": 8900, "luxury": 18900, "exotic": 29900}'::jsonb
    check (jsonb_typeof(listing_default_daily_rate_cents) = 'object');
comment on column program_settings.listing_publish_new_cars_automatically is 'Publish new cars automatically (0070): a new car goes on the site as soon as its basics are complete (year, make, model, plate or VIN, supply, rates). Off: staff press Publish now.';
comment on column program_settings.listing_default_daily_rate_cents is 'The daily rate a new car starts from, by deposit class (0070), when no similar real car has rates: pre-filled on Add a car and used by Publish now on a car with no rates. The other rates derive from it (weekend = daily, weekly 6 days, monthly 22 days).';
-- the starting daily rates: the owner's own sample car prices (0065 catalogue), the median by class
update program_settings set listing_default_daily_rate_cents = listing_default_daily_rate_cents || coalesce((
  select jsonb_object_agg(c, d) from (
    select data ->> 'class' as c, percentile_disc(0.5) within group (order by (data #>> '{rates,daily}')::bigint) as d
      from sample_car_catalogue where data #>> '{rates,daily}' ~ '^[0-9]+$' and data ->> 'class' is not null group by 1) x), '{}'::jsonb);

-- ================================================================ 2. the plate or the VIN
alter table vehicles alter column vin drop not null;
alter table vehicles add constraint vehicles_plate_or_vin check (vin is not null or nullif(btrim(plate), '') is not null);
comment on column vehicles.vin is 'The 17-character VIN. Optional when the plate is given (0070): staff add a car by its plate and the VIN later; the checklist asks for it.';

-- ================================================================ 3. statuses and the public site
-- A car in onboarding or ready to list is on the site once its listing is published (it takes requests and offers;
-- it is handed over only once it is on the fleet policy, section 9). Enrollment of a published car makes it Available.
insert into status_transitions (entity, from_status, to_status, note)
select 'vehicle', f, t, n from (values
  ('onboarding', 'available', 'enrollment confirmed while the listing is already published (0070)'),
  ('ready_to_list', 'on_rent', 'handover of an enrolled car whose listing is not published yet (0070)')) x(f, t, n)
 where not exists (select 1 from status_transitions s where s.entity = 'vehicle' and s.from_status = x.f and s.to_status = x.t);

create or replace view public_vehicle_listings with (security_barrier = true) as
  select l.slug, l.headline, l.description, l.features, l.seats, l.transmission,
         v.id as vehicle_id, v.year, v.make, v.model, v.trim, v.colour, v.fuel, v.class, v.allows_18_to_20,
         rc.daily_rate_cents, rc.weekend_rate_cents, rc.weekly_rate_cents, rc.monthly_rate_cents,
         rc.km_allowance_per_day, rc.overage_cents_per_km, rc.deposit_cents, rc.delivery_fee_cents, rc.pickup_fee_cents
    from vehicle_listings l
    join vehicles v on v.id = l.vehicle_id
    join rate_cards rc on rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())
   where l.status = 'published' and v.management_mode <> 'turo_only' and v.retired_at is null
     and v.bookings_enabled and v.status in ('onboarding', 'ready_to_list', 'available', 'on_rent', 'cleaning')
     and not (v.management_mode = 'self_managed' and v.in_arrears);
grant select on public_vehicle_listings to anon;

-- ================================================================ 4. adding a car: the plate or the VIN
-- 0022's app.add_owner_vehicle, word for word, except: staff (Admin, customer service, fleet) may give the plate
-- instead of the VIN (the plate's duplicate check then), and staff who leave the title empty mean owned outright. An
-- owner applying for themselves still gives the VIN.
create or replace function app.add_owner_vehicle(p_owner uuid, p_v jsonb, p_by uuid default null, p_application uuid default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  d vin_decodes;
  v_vin text := app.clean_vin(p_v ->> 'vin');
  v_id uuid := gen_random_uuid();
  v_onb uuid := gen_random_uuid();
  v_mode management_mode := coalesce(nullif(p_v ->> 'management_mode', '')::management_mode, 'managed');
  v_held owner_type;
  v_title title_status := nullif(p_v ->> 'title_status', '')::title_status;
  v_method onboarding_method := nullif(p_v ->> 'onboarding_method', '')::onboarding_method;
  v_lien boolean := coalesce((p_v ->> 'owners_lien')::boolean, false);
  v_perm finance_permission := nullif(p_v ->> 'finance_permission', '')::finance_permission;
  v_party text := nullif(btrim(p_v ->> 'finance_party_name'), '');
  v_plan jsonb;
  v_options jsonb;
  v_year smallint; v_make text; v_model text; v_trim text; v_fuel fuel_type; v_body text;
  v_sources jsonb := '{}'::jsonb;
  v_src jsonb := jsonb_build_object('source', 'person', 'by', p_by, 'at', now());
  v_dec jsonb := jsonb_build_object('source', 'decoded', 'at', now());
  v_clear boolean := coalesce((p_v ->> 'title_brand_clear')::boolean, true);
  v_flag boolean;
  v_staff boolean := p_by is not null and (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet'));
  v_plate text := nullif(upper(regexp_replace(coalesce(p_v ->> 'plate', ''), '\s', '', 'g')), '');
  v_dupcar vehicles;
begin
  select * into o from owners where id = p_owner;
  if o.id is null then
    raise exception 'Owner not found' using errcode = 'P0002';
  end if;
  if p_by is not null and not app.user_is_admin(p_by) and not app.user_va_has(p_by, 'cs', 'fleet')
     and not app.user_is_owner_of(p_by, p_owner) and o.user_id is distinct from p_by then
    raise exception 'Not permitted: an owner adds vehicles only to their own account' using errcode = '42501';
  end if;
  -- 0070: staff add a car by its plate or its VIN; an owner applying for themselves still gives the VIN
  if v_vin is null and nullif(btrim(coalesce(p_v ->> 'vin', '')), '') is not null then
    raise exception 'The VIN has 17 characters (letters and digits, no I, O or Q)%', case when v_staff then '. Leave it empty to add the car by its plate' else '' end using errcode = '22023';
  end if;
  if v_vin is null and not (v_staff and v_plate is not null) then
    raise exception '%', case when v_staff then 'Enter the plate or the 17-character VIN' else 'Enter the 17-character VIN. It is on the ownership permit and the driver''s door frame.' end using errcode = '22023';
  end if;
  if v_vin is not null and exists (select 1 from vehicles v where upper(v.vin) = v_vin) then
    raise exception 'This vehicle is already with CarmaCars. If it is yours, contact us.' using errcode = '23505';
  end if;
  if v_vin is null then
    select * into v_dupcar from vehicles where app.norm_plate(plate) = app.norm_plate(v_plate) and retired_at is null
       and status not in ('exited', 'total_loss', 'declined') limit 1;
    if v_dupcar.id is not null then
      raise exception 'Plate % is on another car in the fleet: %', v_plate, app.vehicle_name(v_dupcar.id) using errcode = '23505';
    end if;
  end if;
  -- staff who leave the title empty: owned outright (the forms' default); financed or leased is chosen with the lender
  if v_title is null and v_staff then v_title := 'owned_outright'; end if;
  if v_title is null then
    raise exception 'Say whether the vehicle is owned outright, financed or leased' using errcode = '22023';
  end if;
  v_held := coalesce(nullif(p_v ->> 'held_by', '')::owner_type, o.owner_type);
  if v_held = 'corporation' and nullif(btrim(o.corporation_name), '') is null then
    raise exception 'Add the corporation''s name before a vehicle held by a corporation' using errcode = '22023';
  end if;
  if v_title <> 'owned_outright' and v_party is null then
    raise exception 'Enter the name of the %', case v_title when 'leased' then 'lease company' else 'lender' end using errcode = '22023';
  end if;
  if v_title = 'owned_outright' then
    v_party := null; v_perm := 'not_applicable';
  else
    v_perm := coalesce(nullif(v_perm, 'not_applicable'), 'not_obtained');
  end if;

  -- facts typed by a person win; anything left empty is taken from a VIN decode already on file
  select * into d from vin_decodes vd where vd.vin = v_vin and vd.ok order by vd.decoded_at desc limit 1;
  v_year := coalesce(nullif(p_v ->> 'year', '')::smallint, d.year);
  v_make := coalesce(nullif(btrim(p_v ->> 'make'), ''), d.make);
  v_model := coalesce(nullif(btrim(p_v ->> 'model'), ''), d.model);
  v_trim := coalesce(nullif(btrim(p_v ->> 'trim'), ''), d.trim);
  v_fuel := coalesce(nullif(p_v ->> 'fuel', '')::fuel_type, d.fuel, 'gasoline');
  v_body := coalesce(nullif(btrim(p_v ->> 'body_type'), ''), d.body_class);
  if v_year is null or v_make is null or v_model is null then
    raise exception 'Enter the year, make and model from the ownership permit' using errcode = '22023';
  end if;
  v_sources := jsonb_strip_nulls(jsonb_build_object(
    'year', case when nullif(p_v ->> 'year', '') is not null then v_src when d.year is not null then v_dec end,
    'make', case when nullif(btrim(p_v ->> 'make'), '') is not null then v_src when d.make is not null then v_dec end,
    'model', case when nullif(btrim(p_v ->> 'model'), '') is not null then v_src when d.model is not null then v_dec end,
    'trim', case when nullif(btrim(p_v ->> 'trim'), '') is not null then v_src when d.trim is not null then v_dec end,
    'fuel', case when nullif(p_v ->> 'fuel', '') is not null then v_src when d.fuel is not null then v_dec end,
    'body_type', case when nullif(btrim(p_v ->> 'body_type'), '') is not null then v_src when d.body_class is not null then v_dec end,
    'colour', case when nullif(btrim(p_v ->> 'colour'), '') is not null then v_src end));

  -- the method: the one chosen, else the recommended one, else the only one open
  select jsonb_agg(to_jsonb(x)) into v_options from app.onboarding_options(v_held, v_title, v_mode) x;
  if v_method is null then
    select x.method into v_method from app.onboarding_options(v_held, v_title, v_mode) x
     where x.recommended or (select count(*) from app.onboarding_options(v_held, v_title, v_mode)) = 1
     order by x.recommended desc limit 1;
  end if;
  if v_method is not null then
    v_plan := app.onboarding_plan(v_held, v_title, v_mode, v_method, v_lien);
  elsif v_lien then
    raise exception 'Choose the Transfer method to elect the Owner''s Lien' using errcode = '23514';
  end if;

  insert into vehicles (id, owner_id, year, make, model, trim, colour, fuel, vin, plate, odometer_km, status, management_mode,
                        onboarding_method, title_brand_clear, home_location, body_type, registration_status, spec_sources)
  values (v_id, p_owner, v_year, v_make, v_model, v_trim, nullif(btrim(p_v ->> 'colour'), ''), v_fuel, v_vin,
          nullif(upper(regexp_replace(coalesce(p_v ->> 'plate', ''), '\s', '', 'g')), ''), nullif(p_v ->> 'odometer_km', '')::integer,
          'onboarding', v_mode, v_method, v_clear, o.city, v_body, nullif(p_v ->> 'registration_status', ''), v_sources);

  insert into vehicle_onboardings (id, vehicle_id, application_id, current_insurer, held_by, title_status, finance_party_name,
      finance_party_account, finance_permission, proposed_management_mode, proposed_onboarding_method, owners_lien_elected,
      situation, government_forms, sign_back_on_permit, estimate_cents, estimate_plus_tax, disclosures, new_corporation)
  values (v_onb, v_id, p_application, nullif(btrim(p_v ->> 'current_insurer'), ''), v_held, v_title, v_party,
      nullif(btrim(p_v ->> 'finance_party_account'), ''), v_perm, v_mode, v_method, v_lien,
      v_plan ->> 'situation',
      coalesce((select array_agg(f) from jsonb_array_elements_text(v_plan -> 'government_forms') f), '{}'),
      coalesce((v_plan ->> 'sign_back_on_permit')::boolean, false),
      (v_plan ->> 'estimate_cents')::bigint, coalesce((v_plan ->> 'estimate_plus_tax')::boolean, false),
      p_v -> 'disclosures', p_v -> 'new_corporation');

  if not v_clear then
    -- Enrollment Agreement 3.1: a rebuilt, salvage or irreparable brand is not eligible
    update vehicle_onboardings set status = 'declined',
           decline_reason = 'Rebuilt, salvage or irreparable brand: not eligible (Enrollment Agreement 3.1)'
     where id = v_onb;
  else
    v_flag := coalesce((p_v -> 'disclosures' ->> 'open_recall')::boolean, false)
           or coalesce((p_v -> 'disclosures' ->> 'damage')::boolean, false);
    if v_flag then
      perform app.raise_task(p_type => 'onboarding_disclosure',
          p_detail => format('%s: the owner answered yes to an open recall or to structural, flood or fire damage. Read the details before terms are set.', app.vehicle_name(v_id)),
          p_vehicle => v_id, p_owner => p_owner, p_related_table => 'vehicle_onboardings', p_related_id => v_onb,
          p_created_by => p_by, p_escalation_reason => 'recall or damage disclosed', p_dedupe => 'onboarding_disclosure:' || v_onb);
    end if;
    perform app.emit_event('owner_application_received', 'vehicle_onboarding', v_onb,
      jsonb_build_object('owner_id', p_owner, 'vehicle_id', v_id, 'first_name', coalesce(o.first_name, split_part(o.legal_name, ' ', 1)),
                         'vehicle_name', app.vehicle_name(v_id), 'vehicle_plate', nullif(upper(p_v ->> 'plate'), ''), 'vehicle_vin', v_vin,
                         'ownership_summary', concat_ws(', ', case v_held when 'corporation' then 'held by a corporation' else 'held personally' end,
                                                        replace(v_title::text, '_', ' '), v_plan ->> 'label')),
      'owner_application_received:' || v_onb || ':intake');
    perform app.emit_event('staff_owner_application_received', 'vehicle_onboarding', v_onb,
      jsonb_build_object('owner_id', p_owner, 'vehicle_id', v_id, 'owner_name', o.legal_name, 'vehicle_name', app.vehicle_name(v_id),
                         'situation', v_plan ->> 'situation', 'management_mode', v_mode),
      'staff_owner_application_received:' || v_onb || ':intake');
  end if;

  return jsonb_build_object('vehicle_id', v_id, 'onboarding_id', v_onb, 'vin', v_vin, 'declined', not v_clear,
                            'management_mode', v_mode, 'method', v_method, 'method_needed', v_method is null and v_clear,
                            'plan', v_plan, 'options', coalesce(v_options, '[]'::jsonb));
end $$;

-- 0064's app.vehicle_add as app.vehicle_add_core, word for word, except the VIN: optional when the plate is given.
create or replace function app.vehicle_add_core(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_type text := coalesce(nullif(p ->> 'supply_type', ''), 'program_owner');
  v_vin text := app.clean_vin(p ->> 'vin');
  v_plate text := nullif(upper(regexp_replace(coalesce(p ->> 'plate', ''), '\s', '', 'g')), '');
  x vehicles;
  pr partners;
  d vin_decodes;
  v_id uuid := gen_random_uuid();
  v_res jsonb;
  r jsonb := coalesce(p -> 'rates', '{}'::jsonb);
  v_has_rates boolean;
  chk jsonb;
  v_year smallint; v_make text; v_model text;
begin
  perform app.assert_admin(p_by);
  if v_type not in ('program_owner', 'company', 'partner') then raise exception 'Choose who supplies the car' using errcode = '22023'; end if;
  -- 0070: the plate or the VIN
  if v_vin is null and nullif(btrim(coalesce(p ->> 'vin', '')), '') is not null then
    raise exception 'The VIN has 17 characters (letters and digits, no I, O or Q). Leave it empty to add the car by its plate' using errcode = '22023';
  end if;
  if v_vin is null and v_plate is null then raise exception 'Enter the plate or the 17-character VIN' using errcode = '22023'; end if;
  -- the rates are checked first, so a car is never added half way
  v_has_rates := exists (select 1 from jsonb_each_text(r) e where e.key in ('daily', 'weekend', 'weekly', 'monthly') and nullif(btrim(e.value), '') is not null);
  if v_has_rates then
    chk := app.rate_card_check(null, r || jsonb_build_object('class', coalesce(nullif(p ->> 'class', ''), 'standard'), 'make', p ->> 'make', 'model', p ->> 'model'));
    if not (chk ->> 'ok')::boolean then
      raise exception 'Check the rates. %', (select string_agg(m #>> '{}', '. ') from jsonb_array_elements(chk -> 'messages') m) using errcode = '22023';
    end if;
  end if;
  -- the duplicate check, the same for the three kinds: one VIN once in the fleet; a plate on another active car is named
  select * into x from vehicles where upper(vin) = v_vin;
  if x.id is not null then
    raise exception 'This VIN is already in the fleet: % (%)%', app.vehicle_name(x.id), lower(app.supply_label(x.supply_type)),
      case when x.retired_at is not null then '. It is retired: restore it instead of adding it again' else '' end using errcode = '23505';
  end if;
  if v_plate is not null then
    select * into x from vehicles where app.norm_plate(plate) = app.norm_plate(v_plate) and retired_at is null
       and status not in ('exited', 'total_loss', 'declined') limit 1;
    if x.id is not null then
      raise exception 'Plate % is on another car in the fleet: % (%)', v_plate, app.vehicle_name(x.id), lower(app.supply_label(x.supply_type)) using errcode = '23505';
    end if;
  end if;

  if v_type = 'program_owner' then
    if nullif(p ->> 'owner_id', '') is null or (select kind from owners where id = (p ->> 'owner_id')::uuid) is distinct from 'program' then
      raise exception 'Choose the owner (an owner in the owner program)' using errcode = '22023';
    end if;
    v_res := app.add_owner_vehicle((p ->> 'owner_id')::uuid, p - 'supply_type' - 'owner_id' - 'rates', p_by, null);
    update vehicles set added_by = p_by where id = (v_res ->> 'vehicle_id')::uuid;
    if v_has_rates then perform app.vehicle_add_rates((v_res ->> 'vehicle_id')::uuid, p_by, r); end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'vehicle_add', 'vehicles', v_res ->> 'vehicle_id', jsonb_build_object('supply_type', v_type, 'owner_id', p ->> 'owner_id', 'vin', v_vin, 'rates', v_has_rates));
    return v_res || jsonb_build_object('supply_type', v_type, 'rates_set', v_has_rates);
  end if;

  if v_type = 'partner' then
    select * into pr from partners where id = nullif(p ->> 'partner_id', '')::uuid;
    if pr.id is null then raise exception 'Choose the partner rental company' using errcode = '22023'; end if;
    if pr.status = 'ended' then raise exception 'The partnership with % has ended', pr.business_name using errcode = '23514'; end if;
  end if;
  select * into d from vin_decodes z where z.vin = v_vin and z.ok order by z.decoded_at desc limit 1;
  v_year := coalesce(nullif(p ->> 'year', '')::smallint, d.year);
  v_make := coalesce(nullif(btrim(p ->> 'make'), ''), d.make);
  v_model := coalesce(nullif(btrim(p ->> 'model'), ''), d.model);
  if v_year is null or v_make is null or v_model is null then
    raise exception 'Enter the year, make and model' using errcode = '22023';
  end if;
  insert into vehicles (id, owner_id, supply_type, partner_id, commission_bps, year, make, model, trim, colour, fuel, vin, plate, odometer_km, class,
                        status, management_mode, enrollment_date, home_location, body_type, allows_18_to_20, title_brand_clear, added_by)
  values (v_id, case when v_type = 'company' then app.company_owner_id() else pr.owner_id end, v_type, pr.id,
          case when v_type = 'partner' then nullif(p ->> 'commission_bps', '')::integer end,
          v_year, v_make, v_model, coalesce(nullif(btrim(p ->> 'trim'), ''), d.trim), nullif(btrim(p ->> 'colour'), ''),
          coalesce(nullif(p ->> 'fuel', '')::fuel_type, d.fuel, 'gasoline'), v_vin, v_plate, nullif(p ->> 'odometer_km', '')::integer,
          coalesce(nullif(p ->> 'class', '')::vehicle_class, 'standard'), 'available', 'managed', app.today(),
          nullif(btrim(p ->> 'home_location'), ''), coalesce(nullif(btrim(p ->> 'body_type'), ''), d.body_class),
          coalesce((p ->> 'allows_18_to_20')::boolean, false), true, p_by);
  if v_has_rates then perform app.vehicle_add_rates(v_id, p_by, r); end if;
  perform app.ensure_listing(v_id);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'vehicle_add', 'vehicles', v_id::text, jsonb_build_object('supply_type', v_type, 'partner_id', pr.id, 'vin', v_vin, 'plate', v_plate, 'rates', v_has_rates));
  return jsonb_build_object('vehicle_id', v_id, 'supply_type', v_type, 'name', app.vehicle_name(v_id), 'rates_set', v_has_rates,
                            'similar', (select count(*) from listing_similarity_flags f where f.vehicle_id = v_id and f.status = 'open'));
end $$;

-- Add a car (every supply type): 0064's function as app.vehicle_add_core above, then the listing published when the
-- basics are complete and Program settings say so.
create or replace function app.vehicle_add(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.vehicle_add_core(p_by, p);
begin
  return v_out || jsonb_build_object('listing', app.listing_auto_publish((v_out ->> 'vehicle_id')::uuid, 'added'));
end $$;

-- ================================================================ 5. the basics, the checklist, the listing state
-- Is the car on the fleet insurance policy, so it may be handed over? A program owner's car is until its onboarding is
-- confirmed (the insurer's written confirmation makes it ready to list); CarmaCars-owned and partner cars have no
-- onboarding (a partner insures its own).
create or replace function app.vehicle_on_policy(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select v.status <> 'onboarding' from vehicles v where v.id = p_vehicle), false)
$$;

-- An owner's own application from the website waits for staff to decide before the car is published by itself
-- (Publish now still works: pressing it is the decision). A car staff entered never waits.
create or replace function app.listing_waits_for_decision(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from vehicle_onboardings ob join owner_applications a on a.id = ob.application_id
                  where ob.vehicle_id = p_vehicle and a.status in ('new', 'waiting_on_owner')
                    and a.entered_by is null and coalesce(a.source, 'web') <> 'staff')
$$;

-- What is missing before the car can be on the site: only the basics and the states that mean "not on the site" by
-- definition. Each: {code, label, action, who}. Empty: Publish now works.
create or replace function app.listing_basics_missing(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  g jsonb := '[]'::jsonb;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return jsonb_build_array(jsonb_build_object('code', 'missing', 'label', 'Car not found', 'action', 'None', 'who', 'carmacars')); end if;
  -- an example car publishes as any car (Show sample cars publishes them all; it is never published by itself)
  if v.retired_at is not null then
    g := g || jsonb_build_object('code', 'retired', 'label', 'Retired', 'action', 'Restore the car (the car > Retire or delete)', 'who', 'carmacars');
  end if;
  if v.status in ('exited', 'total_loss', 'declined') then
    g := g || jsonb_build_object('code', 'closed', 'label', 'Left the program (' || replace(v.status::text, '_', ' ') || ')', 'action', 'None: the car is no longer in the program', 'who', 'carmacars');
  elsif v.status in ('out_of_service', 'exit_notice') then
    g := g || jsonb_build_object('code', 'status', 'label', 'Out of service (' || replace(v.status::text, '_', ' ') || ')', 'action', 'Put the car back in service (the car > Change status)', 'who', 'carmacars');
  end if;
  if v.management_mode = 'turo_only' then
    g := g || jsonb_build_object('code', 'turo_only', 'label', 'Turo only', 'action', 'None: a Turo-only car is not listed on the website (change how it is managed to list it)', 'who', 'carmacars');
  end if;
  if v.year is null or nullif(btrim(v.make), '') is null or nullif(btrim(v.model), '') is null then
    g := g || jsonb_build_object('code', 'name', 'label', 'Year, make and model', 'action', 'Enter the year, make and model', 'who', 'carmacars');
  end if;
  if v.vin is null and nullif(btrim(v.plate), '') is null then
    g := g || jsonb_build_object('code', 'plate_or_vin', 'label', 'Plate or VIN', 'action', 'Enter the plate or the VIN', 'who', 'carmacars');
  end if;
  if not exists (select 1 from rate_cards rc where rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())) then
    g := g || jsonb_build_object('code', 'rates', 'label', 'no rates are set', 'action', 'Set the rates (the car > Rates), or press Publish now to use the default rates', 'who', 'carmacars');
  end if;
  if not v.bookings_enabled then
    g := g || jsonb_build_object('code', 'bookings_off', 'label', 'Bookings turned off', 'action', 'Turn bookings on for the car (the car > Edit details)', 'who', 'carmacars');
  end if;
  if v.management_mode = 'self_managed' and v.in_arrears then
    g := g || jsonb_build_object('code', 'arrears', 'label', 'Owner in arrears', 'action', 'Collect the overdue owner invoice', 'who', 'owner');
  end if;
  if (app.settings()).listing_similarity_enabled
     and exists (select 1 from listing_similarity_flags x where x.vehicle_id = v.id and x.status = 'confirmed' and x.blocking) then
    g := g || jsonb_build_object('code', 'duplicate', 'label', 'Staff confirmed it is a duplicate of another listing', 'action', 'Clear the decision under Cars > Similar cars if it is not', 'who', 'carmacars');
  end if;
  return g;
end $$;

-- The checklist on the car: warnings that never stop the listing. kind: handover (the car is not handed over until
-- it is done), listing (makes the page better), records (paperwork). Each: {code, label, action, who, kind}.
create or replace function app.listing_checklist(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  l vehicle_listings;
  ob vehicle_onboardings;
  ps program_settings := app.settings();
  g jsonb := '[]'::jsonb;
  c record;
  n integer;
  v_specs text[];
  cc car_copy;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return g; end if;
  select * into l from vehicle_listings where vehicle_id = v.id;
  select * into ob from vehicle_onboardings where vehicle_id = v.id;
  if not app.vehicle_on_policy(v.id) then
    g := g || jsonb_build_object('code', 'insurance', 'kind', 'handover', 'who', 'carmacars',
      'label', 'Not on the fleet insurance policy yet',
      'action', 'Requests, offers and payment are fine. No handover until the insurer confirms the car is on the policy: confirm it in the car''s onboarding (Insurer confirmation, then the enrollment)');
  end if;
  if app.listing_waits_for_decision(v.id) then
    g := g || jsonb_build_object('code', 'application', 'kind', 'listing', 'who', 'carmacars', 'label', 'The owner''s application is not decided',
      'action', 'Approve the application (Owners and partners > Applications). It is published by itself then, or press Publish now');
  end if;
  if ob.id is not null and v.status = 'onboarding' then
    for c in select * from app.onboarding_checklist(v.id) x where x.status = 'open' and x.code not in ('photos', 'listing', 'insurer_confirmation') order by x.sort_order loop
      g := g || jsonb_build_object('code', c.code, 'kind', 'records', 'who', c.waits_on, 'label', c.label, 'action', coalesce(c.next_action, c.staff_action, 'Open the onboarding'));
    end loop;
    if ob.safety_certificate_on is null and coalesce(ob.proposed_onboarding_method::text, v.onboarding_method::text, '') = 'transfer' then
      g := g || jsonb_build_object('code', 'safety_certificate', 'kind', 'records', 'who', 'owner', 'label', 'Safety certificate not on file',
        'action', 'Record the safety certificate in the onboarding before the registry visit');
    end if;
  end if;
  if v.supply_type = 'program_owner' and app.vehicle_needs_terms(v.id) then
    g := g || jsonb_build_object('code', 'terms', 'kind', 'records', 'who', 'carmacars', 'label', 'Owner terms not set (Revenue Share)',
      'action', 'Set the terms (approve the application, or the owner > Terms)');
  end if;
  if v.vin is null then
    g := g || jsonb_build_object('code', 'vin', 'kind', 'records', 'who', 'carmacars', 'label', 'No VIN yet',
      'action', 'Add the VIN (the car > Edit details): the agreements, the registry forms and the toll matching use it');
  end if;
  if app.vehicle_uses_sample_photos(v.id) then
    g := g || jsonb_build_object('code', 'photos', 'kind', 'listing', 'who', 'carmacars', 'label', 'Shows sample photos',
      'action', 'Add real photos on the car''s listing; approved photos replace the sample at once');
  end if;
  select count(*) into n from vehicle_photos ph where ph.vehicle_id = v.id and ph.replaced_at is null and ph.status in ('uploaded', 'processing', 'processed');
  if n > 0 then
    g := g || jsonb_build_object('code', 'photos_review', 'kind', 'listing', 'who', 'carmacars', 'label', format('%s photo%s waiting for review', n, case when n = 1 then '' else 's' end),
      'action', 'Approve them on the listing review; they show once approved');
  end if;
  if ps.listing_plate_check_required then
    select count(*) into n from vehicle_photos ph join listing_shot_types st on st.code = ph.shot_type
     where ph.vehicle_id = v.id and ph.replaced_at is null and ph.status = 'approved' and st.is_public and ph.processed_path is not null and ph.plate_status = 'unchecked';
    if n > 0 then
      g := g || jsonb_build_object('code', 'plates', 'kind', 'listing', 'who', 'carmacars', 'label', format('%s photo%s held back for the plate check', n, case when n = 1 then '' else 's' end),
        'action', 'Cover the plate or mark it not visible on the listing review; each photo shows once checked');
    end if;
  end if;
  v_specs := array(select x from unnest(app.listing_spec_problems(v.id)) x where x not in ('Year', 'Make', 'Model'));
  if cardinality(v_specs) > 0 then
    g := g || jsonb_build_object('code', 'details', 'kind', 'listing', 'who', 'carmacars', 'label', 'Details not shown: ' || lower(array_to_string(v_specs, ', ')),
      'action', 'Fill them in on the listing review (the page leaves them out until then)');
  end if;
  select * into cc from car_copy where vehicle_id = v.id;
  if l.id is null or cc.vehicle_id is null or cc.source = 'template' then
    g := g || jsonb_build_object('code', 'copy', 'kind', 'listing', 'who', 'carmacars', 'label', 'Plain text from the car''s facts',
      'action', 'Nothing to do: the AI text replaces it by itself when Workers AI writes it');
  end if;
  select count(*) into n from listing_similarity_flags x where x.vehicle_id = v.id and x.status = 'open';
  if n > 0 then
    g := g || jsonb_build_object('code', 'similar', 'kind', 'listing', 'who', 'carmacars', 'label', format('%s possible duplicate%s', n, case when n = 1 then '' else 's' end),
      'action', 'Check under Cars > Similar cars (the car stays on the site meanwhile)');
  end if;
  return g;
end $$;

-- The daily rate a car starts from: similar real cars (the same model, else the same class), else Program settings by
-- class. Returns {daily_cents, source, text}.
create or replace function app.listing_default_daily(p_vehicle uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  d jsonb := app.rate_card_defaults_pre0070(p_vehicle, coalesce(p, '{}'::jsonb));
  v_class text := coalesce(d ->> 'class', 'standard');
  v_cents bigint;
begin
  if (d #>> '{suggestion,daily_cents}') ~ '^[0-9]+$' and (d #>> '{suggestion,daily_cents}')::bigint > 0 then
    return jsonb_build_object('daily_cents', (d #>> '{suggestion,daily_cents}')::bigint, 'source', 'similar',
                              'text', format('%s a day: the median of similar cars', app.rc_money((d #>> '{suggestion,daily_cents}')::bigint)));
  end if;
  v_cents := coalesce(nullif((app.settings()).listing_default_daily_rate_cents ->> v_class, '')::bigint,
                      nullif((app.settings()).listing_default_daily_rate_cents ->> 'standard', '')::bigint, 6900);
  return jsonb_build_object('daily_cents', v_cents, 'source', 'class',
                            'text', format('%s a day: the default for the %s class (Program settings)', app.rc_money(v_cents), v_class));
end $$;

alter function app.rate_card_defaults(uuid, jsonb) rename to rate_card_defaults_pre0070;
create or replace function app.rate_card_defaults(p_vehicle uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  dd jsonb := app.listing_default_daily(p_vehicle, p);
begin
  return app.rate_card_defaults_pre0070(p_vehicle, p) || jsonb_build_object('daily_default_cents', dd -> 'daily_cents', 'daily_default_text', dd ->> 'text');
end $$;

-- ================================================================ 6. the text, publishing, the intake, the review
-- A clean template text from the car's facts (0061's plain copy), used when the listing has no text yet or its text
-- fails the rules; if even that cannot be applied, a short text from the name. Never refuses.
create or replace function app.listing_template_copy(p_vehicle uuid) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  f jsonb;
  v_name text := app.vehicle_name(p_vehicle);
begin
  begin
    f := app.car_copy_facts(p_vehicle);
    perform app.car_copy_apply(p_vehicle, app.car_copy_template(f), 'template', md5(f::text));
    update car_copy set status = 'pending', next_attempt_at = least(coalesce(next_attempt_at, now()), now()) where vehicle_id = p_vehicle and source = 'template';
    return 'template';
  exception when others then
    perform app.ensure_listing(p_vehicle);
    update vehicle_listings set
      headline = coalesce(nullif(btrim(headline), ''), left(v_name || ' rental in Toronto', 70)),
      description = coalesce(nullif(btrim(description), ''), 'This ' || v_name || ' is available to rent in Toronto. Collect it at our location or have it delivered. '
                      || 'Send a request with your dates and we confirm the car and the price before you pay anything.'),
      features = case when cardinality(features) > 0 then features else array['Pickup at our location or delivery', 'Request with no payment up front'] end
     where vehicle_id = p_vehicle;
    return 'name';
  end;
end $$;

-- Publish: one check of the basics, then everything 0022's publish did (slug, status, photos, the car Available, the
-- intake, the tasks, the owner's email), with the checklist returned as warnings. Who may publish is unchanged: an
-- Admin, customer service or fleet, an owner only through an approved review (listing_review_required_roles), and the
-- system (p_by null) for an approved intake or the automatic publishing of a new car.
create or replace function app.publish_listing(p_vehicle uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  l vehicle_listings;
  i listing_intakes;
  ps program_settings := app.settings();
  v_role text := app.acting_role(p_by);
  v_missing jsonb;
  v_slug text;
  v_first boolean;
  v_copy text;
begin
  -- the template text applied below may publish an approved intake itself: that inner call returns at once
  if coalesce(current_setting('app.listing_publishing', true), '') = p_vehicle::text then
    return jsonb_build_object('status', 'publishing', 'vehicle_id', p_vehicle);
  end if;
  select * into v from vehicles where id = p_vehicle for update;
  if v.id is null then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
  perform app.ensure_listing(p_vehicle);
  select * into l from vehicle_listings where vehicle_id = p_vehicle for update;
  select * into i from listing_intakes where vehicle_id = p_vehicle and state not in ('published', 'cancelled') order by created_at desc limit 1;

  if p_by is null then
    if not (coalesce(current_setting('app.listing_auto', true), '') = p_vehicle::text or (i.id is not null and i.state = 'approved')) then
      raise exception 'Cannot publish: nobody approved this listing' using errcode = '42501';
    end if;
  else
    if app.user_owns_vehicle(p_by, p_vehicle) and not app.user_is_admin(p_by) and not app.user_va_has(p_by) then v_role := 'owner'; end if;
    if v_role is null or (v_role = 'va' and not app.user_va_has(p_by, 'cs', 'fleet'))
       or (v_role = 'owner' and not app.user_owns_vehicle(p_by, p_vehicle))
       or (v_role = 'field' and not app.user_field_has_job(p_by, p_vehicle)) then
      raise exception 'Not permitted to publish this listing' using errcode = '42501';
    end if;
    if v_role = any (ps.listing_review_required_roles) and (i.id is null or i.state <> 'approved') then
      raise exception 'Cannot publish: a % listing is published after a CarmaCars review', v_role using errcode = '42501';
    end if;
  end if;

  v_missing := app.listing_basics_missing(p_vehicle);
  if jsonb_array_length(v_missing) > 0 then
    raise exception 'Cannot publish: %. %', (select string_agg(m ->> 'label', '; ') from jsonb_array_elements(v_missing) m), v_missing -> 0 ->> 'action'
      using errcode = '23514';
  end if;

  perform set_config('app.listing_publishing', p_vehicle::text, true);
  -- the text: a clean template when there is none yet or it fails the rules (the AI text replaces it by itself)
  if cardinality(app.listing_copy_problems(l.headline, l.description, l.features, l.faq)) > 0 then
    v_copy := app.listing_template_copy(p_vehicle);
    select * into l from vehicle_listings where vehicle_id = p_vehicle;
  end if;
  -- a twin that is not live is no canonical address
  if l.canonical_vehicle_id is not null and not exists (
       select 1 from vehicle_listings c where c.vehicle_id = l.canonical_vehicle_id and c.status in ('published', 'paused') and c.canonical_vehicle_id is null) then
    update vehicle_listings set canonical_vehicle_id = null where id = l.id;
  end if;
  -- possible duplicates are compared again: flags for staff, never a refusal
  if ps.listing_similarity_enabled then
    begin perform app.check_listing_similarity(p_vehicle, 'copy'); exception when others then null; end;
  end if;

  v_slug := coalesce(l.slug, app.listing_slug(v.id));
  v_first := l.first_published_at is null;
  update vehicle_listings
     set slug = v_slug, status = 'published', published_at = now(), first_published_at = coalesce(first_published_at, now()),
         published_by = p_by, unpublished_at = null, unpublished_reason = null, redirect_to = null, needs_rewrite = false,
         publish_at = null, publish_error = null,
         channels = case when 'website' = any (channels) then channels else channels || 'website'::text end
   where id = l.id;
  delete from listing_redirects where from_path = '/cars/' || v_slug;
  -- approved photos go public as their shot allows; one whose plate is not checked yet waits (section 7)
  update vehicle_photos set is_public = st.is_public
    from listing_shot_types st
   where st.code = vehicle_photos.shot_type and vehicle_photos.vehicle_id = v.id and vehicle_photos.replaced_at is null
     and vehicle_photos.status = 'approved';
  if v.status = 'ready_to_list' then
    update vehicles set status = 'available' where id = v.id;
  end if;
  if i.id is not null then
    update listing_intakes set state = 'published', published_at = now() where id = i.id;
  end if;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'listing published'
   where vehicle_id = v.id and task_type in ('list_vehicle', 'review_listing', 'listing_failed') and status in ('open', 'in_progress', 'waiting');
  -- the owner hears "live and open for bookings" once the car can be handed over (a car in onboarding: at enrollment)
  if v.status <> 'onboarding' then
    perform app.emit_event('owner_vehicle_listed', 'vehicle', v.id,
      jsonb_build_object('owner_id', v.owner_id, 'vehicle_name', app.vehicle_name(v.id), 'listing_path', '/cars/' || v_slug, 'first_time', v_first),
      'owner_vehicle_listed:' || v.id || ':' || coalesce(i.id::text, to_char(now(), 'YYYYMMDDHH24MISS')));
  end if;
  if v_slug is not null then
    begin perform app.indexnow_queue_path('/cars/' || v_slug, 'published'); exception when others then null; end;
  end if;
  perform set_config('app.listing_publishing', '', true);
  return jsonb_build_object('status', 'published', 'vehicle_id', v.id, 'slug', v_slug, 'path', '/cars/' || v_slug, 'first_time', v_first,
                            'sample_photos', app.vehicle_uses_sample_photos(v.id), 'copy', coalesce(v_copy, 'kept'), 'warnings', app.listing_checklist(v.id));
exception when others then
  perform set_config('app.listing_publishing', '', true);
  raise;
end $$;

-- Submitting the listing intake: photos are optional and so is any one shot (sample photos stand in); the copy is
-- drafted and the uploaded photos processed as before (0022, 0054).
create or replace function app.submit_listing_intake(p_by uuid, p_intake uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i listing_intakes;
  v_missing text[];
  r record;
begin
  select * into i from listing_intakes where id = p_intake for update;
  if i.id is null then raise exception 'Listing intake not found' using errcode = 'P0002'; end if;
  if p_by is null or not (app.user_may_list(p_by, i.vehicle_id, 'start') or app.user_may_list(p_by, i.vehicle_id, 'review')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if i.submitted_at is not null then
    return jsonb_build_object('intake_id', i.id, 'state', i.state, 'already_submitted', true);
  end if;
  v_missing := app.listing_missing_shots(i.vehicle_id);
  update listing_intakes set submitted_at = now(),
         notes = case when cardinality(v_missing) > 0 then concat_ws(' ', notes, 'Submitted without: ' || array_to_string(v_missing, ', ') || '. Sample photos stand in until real photos are approved.') else notes end
   where id = i.id;
  perform app.enqueue_listing_job(i.id, 'draft_copy', null, jsonb_build_object('facts', app.listing_facts(i.vehicle_id), 'notes', i.notes));
  for r in select ph.id from vehicle_photos ph
            where ph.vehicle_id = i.vehicle_id and ph.replaced_at is null and ph.status in ('uploaded', 'processing')
            order by ph.sort_order loop
    perform app.enqueue_listing_job(i.id, 'process_photo', r.id);
  end loop;
  return jsonb_build_object('intake_id', i.id, 'state', app.advance_listing_intake(i.id), 'missing_shots', to_jsonb(v_missing),
                            'sample_photos', app.vehicle_uses_sample_photos(i.vehicle_id));
end $$;

-- Approving a listing review whose text fails the rules (the AI was not available): the template text first, then
-- 0022's review as before.
alter function app.review_listing(uuid, uuid, boolean, jsonb, text) rename to review_listing_pre0070;
create or replace function app.review_listing(p_by uuid, p_intake uuid, p_approve boolean, p jsonb default '{}'::jsonb, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  i listing_intakes;
  l vehicle_listings;
begin
  if p_approve and not coalesce(p, '{}'::jsonb) ? 'listing' then
    select * into i from listing_intakes where id = p_intake;
    select * into l from vehicle_listings where vehicle_id = i.vehicle_id;
    if l.id is not null and cardinality(app.listing_copy_problems(l.headline, l.description, l.features, l.faq)) > 0
       and app.user_may_list(p_by, i.vehicle_id, 'review') then
      perform set_config('app.listing_publishing', i.vehicle_id::text, true);
      perform app.listing_template_copy(i.vehicle_id);
      perform set_config('app.listing_publishing', '', true);
    end if;
  end if;
  return app.review_listing_pre0070(p_by, p_intake, p_approve, p, p_note);
end $$;

-- ================================================================ 7. photos: never public with an unchecked plate
-- While Program settings ask for the plate check, a real photo whose plate is not checked is kept private (the rest of
-- the photos show, or the sample photos); it goes public by itself once its plate is covered or marked not visible.
create or replace function app.vehicle_photo_plate_public() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if not (app.settings()).listing_plate_check_required then return new; end if;
  -- an example car's photos are the static sample pictures (0065): no plate to check
  if exists (select 1 from vehicles v where v.id = new.vehicle_id and v.is_sample) then return new; end if;
  if new.plate_status = 'unchecked' and new.is_public then
    new.is_public := false;
  elsif tg_op = 'UPDATE' and old.plate_status = 'unchecked' and new.plate_status in ('covered', 'not_visible') and new.status = 'approved'
        and new.replaced_at is null and not new.is_public
        and exists (select 1 from vehicle_listings l where l.vehicle_id = new.vehicle_id and l.status in ('published', 'paused')) then
    new.is_public := coalesce((select st.is_public from listing_shot_types st where st.code = new.shot_type), false);
  end if;
  return new;
end $$;
drop trigger if exists vehicle_photos_plate_public on vehicle_photos;
create trigger vehicle_photos_plate_public before insert or update of is_public, plate_status, status on vehicle_photos
  for each row execute function app.vehicle_photo_plate_public();
-- photos already public with an unchecked plate (none expected: 0042 refused such a publish)
update vehicle_photos ph set is_public = false
 where ph.is_public and ph.plate_status = 'unchecked' and (app.settings()).listing_plate_check_required
   and not exists (select 1 from vehicles v where v.id = ph.vehicle_id and v.is_sample);

-- ================================================================ 8. publishing new cars automatically
-- A new car (never published, not scheduled, not taken off by staff) is published as soon as its basics are complete,
-- while Program settings "Publish new cars automatically" is on. Never raises: the reason it waits comes back.
create or replace function app.listing_auto_publish(p_vehicle uuid, p_why text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  l vehicle_listings;
  v_missing jsonb;
  v_out jsonb;
begin
  if p_vehicle is null then return jsonb_build_object('published', false, 'reason', 'no car'); end if;
  select * into v from vehicles where id = p_vehicle;
  if v.id is null or coalesce(v.is_sample, false) then return jsonb_build_object('published', false, 'reason', 'not a real car'); end if;
  select * into l from vehicle_listings where vehicle_id = p_vehicle;
  if l.status in ('published', 'paused') then return jsonb_build_object('published', l.status = 'published', 'reason', 'already ' || l.status); end if;
  if not coalesce((app.settings()).listing_publish_new_cars_automatically, false) then
    return jsonb_build_object('published', false, 'auto', false, 'reason', 'Publish new cars automatically is off: press Publish now');
  end if;
  if l.id is not null and (l.first_published_at is not null or l.status = 'unpublished' or l.publish_at > now()) then
    return jsonb_build_object('published', false, 'reason', case when l.publish_at > now() then 'scheduled' else 'taken off the site by staff: press Publish now' end);
  end if;
  v_missing := app.listing_basics_missing(p_vehicle);
  if jsonb_array_length(v_missing) > 0 then
    return jsonb_build_object('published', false, 'missing', v_missing, 'reason', (select string_agg(m ->> 'label', '; ') from jsonb_array_elements(v_missing) m));
  end if;
  if app.listing_waits_for_decision(p_vehicle) then
    return jsonb_build_object('published', false, 'reason', 'the owner''s application is not decided');
  end if;
  begin
    perform set_config('app.listing_auto', p_vehicle::text, true);
    v_out := app.publish_listing(p_vehicle, null);
    perform set_config('app.listing_auto', '', true);
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (null, 'listing_auto_publish', 'vehicles', p_vehicle::text, jsonb_build_object('why', p_why, 'path', v_out ->> 'path'));
    return v_out || jsonb_build_object('published', true, 'auto', true);
  exception when others then
    perform set_config('app.listing_auto', '', true);
    return jsonb_build_object('published', false, 'reason', sqlerrm);
  end;
end $$;

-- Rates saved (the car's Rates tab, Fleet, Add a car): a new car with its basics complete goes on the site.
alter function app.rate_card_save(uuid, jsonb) rename to rate_card_save_pre0070;
create or replace function app.rate_card_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.rate_card_save_pre0070(p_by, p);
begin
  return v_out || jsonb_build_object('listing', app.listing_auto_publish(nullif(p ->> 'vehicle', '')::uuid, 'rates'));
end $$;

-- A car staff add for an owner: the rates in the same step (p.rates, as Add a car), then the listing.
alter function app.staff_add_owner_car(uuid, jsonb) rename to staff_add_owner_car_pre0070;
create or replace function app.staff_add_owner_car(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb := coalesce(p -> 'rates', '{}'::jsonb);
  v_rates boolean := exists (select 1 from jsonb_each_text(coalesce(p -> 'rates', '{}'::jsonb)) e where e.key in ('daily', 'weekend', 'weekly', 'monthly') and nullif(btrim(e.value), '') is not null);
  chk jsonb;
  v_out jsonb;
  v_vehicle uuid;
begin
  if v_rates then
    chk := app.rate_card_check(null, r || jsonb_build_object('class', coalesce(nullif(p #>> '{vehicle,class}', ''), 'standard'), 'make', p #>> '{vehicle,make}', 'model', p #>> '{vehicle,model}'));
    if not (chk ->> 'ok')::boolean then
      raise exception 'Check the rates. %', (select string_agg(m #>> '{}', '. ') from jsonb_array_elements(chk -> 'messages') m) using errcode = '22023';
    end if;
  end if;
  v_out := app.staff_add_owner_car_pre0070(p_by, p - 'rates');
  v_vehicle := (v_out ->> 'vehicle_id')::uuid;
  if v_rates then perform app.rate_card_save_pre0070(p_by, r || jsonb_build_object('vehicle', v_vehicle)); end if;
  return v_out || jsonb_build_object('rates_set', v_rates, 'listing', app.listing_auto_publish(v_vehicle, 'added for an owner'));
end $$;

-- An owner's application approved: each of its cars with its basics complete goes on the site.
alter function app.application_approve(uuid, jsonb) rename to application_approve_pre0070;
create or replace function app.application_approve(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.application_approve_pre0070(p_admin, p);
  v_list jsonb := '[]'::jsonb;
  r record;
begin
  for r in select ob.vehicle_id from vehicle_onboardings ob where ob.application_id = (p ->> 'id')::uuid loop
    v_list := v_list || jsonb_build_array(app.listing_auto_publish(r.vehicle_id, 'application approved') || jsonb_build_object('vehicle_id', r.vehicle_id));
  end loop;
  return v_out || jsonb_build_object('listings', v_list);
end $$;

-- The car's status: enrollment of a car already on the site makes it Available (not "ready to list"); a car that
-- becomes ready to list is published by itself when new; the owner's "live" email goes at enrollment.
create or replace function app.vehicle_status_listing_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'ready_to_list' and old.status = 'onboarding'
     and exists (select 1 from vehicle_listings l where l.vehicle_id = new.id and l.status = 'published') then
    new.status := 'available';
  end if;
  return new;
end $$;
drop trigger if exists a00_vehicle_status_listing on vehicles;
create trigger a00_vehicle_status_listing before update of status on vehicles
  for each row execute function app.vehicle_status_listing_before();

create or replace function app.vehicle_status_listing_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  l vehicle_listings;
begin
  if new.status = old.status then return null; end if;
  if new.status = 'ready_to_list' then
    perform app.listing_auto_publish(new.id, 'enrolled');
  elsif new.status = 'available' and old.status = 'onboarding' then
    select * into l from vehicle_listings where vehicle_id = new.id;
    if l.status = 'published' then
      perform app.emit_event('owner_vehicle_listed', 'vehicle', new.id,
        jsonb_build_object('owner_id', new.owner_id, 'vehicle_name', app.vehicle_name(new.id), 'listing_path', '/cars/' || l.slug, 'first_time', true),
        'owner_vehicle_listed:' || new.id || ':enrolled');
    end if;
  end if;
  return null;
end $$;
drop trigger if exists vehicles_status_listing on vehicles;
create trigger vehicles_status_listing after update of status on vehicles
  for each row execute function app.vehicle_status_listing_after();

-- ================================================================ 9. the handover: the car on the fleet policy
-- The hard gate, at the handover only: a program owner's car whose onboarding is not confirmed (not on the fleet policy
-- yet) is never handed over. The renter's verification, coverage, deposit and condition report stay as they were
-- (0011, 0019). An enrolled car whose listing is not published is handed over too (0011's check, below).
create or replace function app.booking_handover_on_policy() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'on_rent' and old.status is distinct from 'on_rent' and not app.vehicle_on_policy(new.vehicle_id) then
    raise exception 'This car is not on the fleet insurance policy yet: it cannot be handed over. Confirm the insurer''s written confirmation in the car''s onboarding first (the enrollment), or move the booking to another car'
      using errcode = '23514';
  end if;
  return new;
end $$;
drop trigger if exists bookings_a1_handover_on_policy on bookings;
create trigger bookings_a1_handover_on_policy before update of status on bookings
  for each row execute function app.booking_handover_on_policy();

-- 0011's app.booking_after_status, word for word, except an enrolled car whose listing is not published (ready to list)
-- is handed over too.
create or replace function app.booking_after_status() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_status vehicle_status;
begin
  if new.status = old.status then return null; end if;

  if new.status = 'on_rent' then
    select status into v_status from vehicles where id = new.vehicle_id;
    -- 0070: a car enrolled (on the fleet policy) whose listing is not published yet is handed over too
    if v_status not in ('available', 'exit_notice', 'ready_to_list') then
      raise exception 'Vehicle is % and cannot be handed over', v_status using errcode = '23514';
    end if;
    update vehicles set status = 'on_rent' where id = new.vehicle_id;
    -- during a rental CarmaCars manages, the Owner's lock, alarm and shut-off are blocked (live location stays)
    if new.booking_type <> 'owner' and new.management_mode = 'managed' then
      insert into tracker_access_blocks (vehicle_id, booking_id, reason, starts_at)
      values (new.vehicle_id, new.id, 'managed_rental', coalesce(new.handed_over_at, now()))
      on conflict do nothing;
    end if;
  elsif new.status = 'returned' then
    -- Fleet restores the Owner's controls
    update tracker_access_blocks set ends_at = coalesce(new.checked_in_at, now())
     where booking_id = new.id and ends_at is null;
    -- the Deposit balance is due back within 7 business days of Check-in; a hold-back may run 30 days
    update deposits d
       set release_due_on = app.add_business_days(app.local_date(new.checked_in_at), (app.settings()).deposit_release_business_days),
           held_back_until = case when d.held_back_cents > 0
                                  then app.local_date(new.checked_in_at) + (app.settings()).deposit_holdback_days end
     where d.booking_id = new.id and d.release_due_on is null;
    update vehicles v
       set status = case when exists (select 1 from vehicle_exits e where e.vehicle_id = v.id and e.status = 'notice')
                         then 'exit_notice'::vehicle_status else 'cleaning'::vehicle_status end
     where v.id = new.vehicle_id and v.status = 'on_rent';
    -- the renter's first completed booking drives "first rental only"
    if new.booking_type <> 'owner' then
      update renters set first_completed_booking_id = new.id where id = new.renter_id and first_completed_booking_id is null;
    end if;
    perform app.compute_booking_split(new.id);
  elsif new.status in ('closed', 'cancelled', 'no_show') then
    perform app.compute_booking_split(new.id);
  end if;
  return null;
end $$;

-- ================================================================ 10. why a real car is not on the site (0065's list)
-- Only the basics now, then the listing itself: not published yet (Publish now), scheduled or paused. The checklist
-- items are warnings and are not listed here.
create or replace function app.vehicle_public_gates(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  l vehicle_listings;
  g jsonb;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is not null and exists (select 1 from public_vehicle_listings p where p.vehicle_id = v.id) then return '[]'::jsonb; end if;
  g := app.listing_basics_missing(p_vehicle);
  if v.id is null then return g; end if;
  select * into l from vehicle_listings where vehicle_id = v.id;
  if l.status = 'paused' then
    g := g || jsonb_build_object('code', 'paused', 'label', 'Listing paused', 'action', 'Resume the listing', 'who', 'carmacars');
  elsif l.id is null or l.status <> 'published' then
    g := g || jsonb_build_object('code', 'listing', 'label', case when l.publish_at > now() then 'Listing scheduled' else 'Listing not published' end,
                                 'action', case when l.publish_at > now() then 'Nothing: it publishes on ' || app.fmt_day(app.local_date(l.publish_at))
                                                when jsonb_array_length(g) > 0 then 'Then press Publish now on the car'
                                                else 'Press Publish now on the car' end, 'who', 'carmacars');
  end if;
  return g;
end $$;

-- ================================================================ 11. Publish now, and the state of a car's listing
-- Publish now (Admin, customer service, fleet): one click when the basics exist. A car with no rates yet gets the
-- default rates first (similar cars, else Program settings by class) and the reply says so.
create or replace function app.listing_publish_now(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(coalesce(p ->> 'vehicle_id', p ->> 'vehicle'), '')::uuid;
  v vehicles;
  dd jsonb;
  v_rates jsonb;
  v_out jsonb;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then
    raise exception 'An Admin, customer service or fleet publishes a car' using errcode = '42501';
  end if;
  select * into v from vehicles where id = v_vehicle;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  if not exists (select 1 from rate_cards rc where rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now()))
     and coalesce((p ->> 'default_rates')::boolean, true)
     and not exists (select 1 from jsonb_array_elements(app.listing_basics_missing(v.id)) m where m ->> 'code' <> 'rates') then
    dd := app.listing_default_daily(v.id);
    perform app.rate_card_save_pre0070(p_by, jsonb_build_object('vehicle', v.id, 'daily', dd -> 'daily_cents', 'km_mode', 'default'));
    v_rates := dd;
  end if;
  v_out := app.publish_listing(v.id, p_by);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'listing_publish_now', 'vehicles', v.id::text, jsonb_build_object('path', v_out ->> 'path', 'default_rates', v_rates));
  return v_out || jsonb_build_object('default_rates', v_rates);
end $$;

-- Everything the car page shows about its listing: on the site or not, what is missing, the checklist, whether it can
-- be handed over, Publish now. Any staff member (the booking pages read it for the insurance warning).
create or replace function app.listing_state(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(coalesce(p ->> 'vehicle_id', p ->> 'vehicle'), '')::uuid;
  v vehicles;
  l vehicle_listings;
  v_missing jsonb;
  v_check jsonb;
  v_public boolean;
  v_rates boolean;
begin
  if not app.user_is_staff(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into v from vehicles where id = v_vehicle;
  if v.id is null then return null; end if;
  select * into l from vehicle_listings where vehicle_id = v.id;
  v_missing := app.listing_basics_missing(v.id);
  v_check := app.listing_checklist(v.id);
  v_public := exists (select 1 from public_vehicle_listings x where x.vehicle_id = v.id);
  v_rates := exists (select 1 from rate_cards rc where rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now()));
  return jsonb_build_object(
    'vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'is_sample', coalesce(v.is_sample, false),
    'listing_status', coalesce(l.status, 'none'), 'public', v_public, 'path', case when l.slug is not null then '/cars/' || l.slug end,
    'published_at', l.published_at, 'missing', v_missing, 'checklist', v_check,
    'can_publish', not v_public and coalesce(l.status, 'draft') <> 'paused'
                   and not exists (select 1 from jsonb_array_elements(v_missing) m where m ->> 'code' <> 'rates'),
    'needs_default_rates', not v_rates, 'default_daily', case when not v_rates then app.listing_default_daily(v.id) end,
    'can_act', app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet'),
    'auto_publish', coalesce((app.settings()).listing_publish_new_cars_automatically, false),
    'on_policy', app.vehicle_on_policy(v.id),
    'handover_note', case when not app.vehicle_on_policy(v.id)
                          then 'Not on the fleet insurance policy yet: you can send the offer and take payment, but the car cannot be handed over until the insurer confirms it (the car''s onboarding: Insurer confirmation, then the enrollment).' end);
end $$;

-- ================================================================ 12. the doors
create or replace function app.ops70(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_name = 'listing_state' then return app.listing_state(p_user, p); end if;
  if p_name = 'listing_publish_now' then return app.listing_publish_now(p_user, p); end if;
  raise exception 'Unknown action %', p_name using errcode = '22023';
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0070;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call in ('ops_read', 'va_read', 'admin_read') and p_name = 'listing_state')
     or (p_call in ('ops_do', 'va_do', 'admin_do') and p_name = 'listing_publish_now') then
    perform app.door_begin(p_user, p_aal);
    return app.ops70(p_user, p_call, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0070(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 12a. a request on a car listed before its terms are signed
-- A program owner's car on the site before its Vehicle Schedule is signed takes requests on the owner's agreed terms,
-- or the standard grid when none are set (app.owner_terms_resolve, 0067): the split is never left empty (it failed the
-- booking with a database error before).
create or replace function app.bookings_default_share() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.company_share_bps is null and new.booking_type <> 'owner' then
    new.company_share_bps := nullif(app.owner_terms_resolve(new.vehicle_id, app.local_date(coalesce(new.booked_at, now()))) ->> 'revenue_share_bps', '')::integer;
  end if;
  return new;
end $$;
create trigger bookings_before_write_z70_share before insert on bookings
  for each row execute function app.bookings_default_share();

-- ================================================================ 12b. a car deleted before its events are sent
-- Publishing new cars automatically emits "listed" at once; a car deleted before the outbox runs left an event whose
-- notification could not be written (the outbox's car is gone), stopping the whole batch. Its unsent events close.
create or replace function app.vehicles_close_events_before_delete() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  update app_events set processed_at = now(), process_note = 'vehicle deleted before sending'
   where processed_at is null and ((entity = 'vehicle' and entity_id = old.id) or payload ->> 'vehicle_id' = old.id::text);
  return old;
end $$;
create trigger vehicles_close_events_before_delete before delete on vehicles
  for each row execute function app.vehicles_close_events_before_delete();

-- ================================================================ 13. privileges
-- The new functions and the wrappers: the server only (the wrappers then get what the function they wrap had). The
-- functions replaced in place keep their privileges.
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['vehicle_add_core', 'vehicle_on_policy', 'listing_waits_for_decision',
              'listing_basics_missing', 'listing_checklist', 'listing_default_daily', 'rate_card_defaults', 'listing_template_copy',
              'review_listing', 'vehicle_photo_plate_public', 'listing_auto_publish', 'rate_card_save', 'staff_add_owner_car',
              'application_approve', 'vehicle_status_listing_before', 'vehicle_status_listing_after', 'booking_handover_on_policy',
              'listing_publish_now', 'listing_state', 'ops70', 'door', 'vehicles_close_events_before_delete', 'bookings_default_share'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- Each renamed function keeps its privileges; the function in its place gets the same.
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('door_pre0070', 'door'), ('rate_card_defaults_pre0070', 'rate_card_defaults'), ('review_listing_pre0070', 'review_listing'),
                          ('rate_card_save_pre0070', 'rate_card_save'), ('staff_add_owner_car_pre0070', 'staff_add_owner_car'),
                          ('application_approve_pre0070', 'application_approve')) m(old_name, new_name) on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;
