-- 0710: the fleet supplier route (Release 33, part E). SCHEMA_MARKER 0711 (with the guides of 0711).
-- Record: docs/changes/2026-11-07-r33-fleet-supplier.md. No applied migration is edited; the functions it changes are
-- wrapped (renamed with the suffix _pre0710).
--
-- The owner, November 7, 2026:
-- 1. The lawyer approved the Fleet Supplier Lease Agreement: it is final (fleet_lease_agreements_awaiting_lawyer off, as
--    the flat-rate set since 0205).
-- 2. A supplier opens his own owner account on the website and chooses "Fleet supplier: lease your cars to CarmaCars"
--    (a corporation only): owners.onboarding_route = 'fleet_supplier'. His owner record gets the fleet lease structure
--    at once: the default lease terms of Program settings (Admin can change them) and the default Upkeep Table. Only
--    what the route needs is asked: the corporation (legal name, number, registered address, signing officer and
--    title) and per car the VIN, the plate, the ownership copy (uploaded in the portal), the tier and who the car is
--    registered to now. The ServiceOntario forms the route needs are pre-filled for each car at once (0042's official
--    forms, only their empty boxes): the lease to CarmaCars as the existing-corporation lease does (SR-LV-006 with his
--    corporation as the registrant, SR-LV-012 with CarmaCars holding the plates as the lessee, Form B on screen), and,
--    for a car not yet registered to his corporation, the transfer into it (ON00453 when the corporation has no RIN;
--    013-0169 and 013-1155 when an officer moves his own car into the corporation, the officer as the transferor; a
--    car bought from a seller is transferred on the back of the ownership permit, with the seller and the date asked).
--    He signs the Fleet Supplier Lease Agreement with the Title-Holding and Lease Agreement it relies on, in the portal;
--    Forms C and D (paper, witnessed) are not asked.
-- 3. He marks each car Regular or Troubled when he adds it (vehicle_onboardings.lease_tier); it is locked from then on.
--    An Admin approves each car (the application) and the car goes on the lease at that tier; before approval only an
--    Admin corrects a mistake (fleet_onboarding_tier_correct), after it 0640's fleet_lease_tier_correct.
-- 4. He signs in the owner portal only (the full e-signature flow): no paper signature is recorded for him, and staff
--    cannot choose "signs on paper" for him.
-- 5. The owner portal shows his lease (owner_portal_home.fleet_lease): cars, tier, monthly lease, next payment date;
--    no fee invoice or debit is ever made (0640's guards).
-- Staff (Admin, customer service, fleet, Sales) offer the same route where they add an owner.
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

-- ================================================================ 1. the lawyer approved the fleet lease text
alter table program_settings alter column fleet_lease_agreements_awaiting_lawyer set default false;
update program_settings set fleet_lease_agreements_awaiting_lawyer = false where fleet_lease_agreements_awaiting_lawyer;
comment on column program_settings.fleet_lease_agreements_awaiting_lawyer is 'Fleet lease agreements awaiting lawyer OK (0640): off since 0710, the lawyer approved docs/source/v2_fleet_lease.md. Turned on, Admin marks the agreement awaiting review again (a new text). Suppliers sign either way.';

-- ================================================================ 2. the route, the default terms, the tier
alter table owners add column if not exists onboarding_route text check (onboarding_route in ('fleet_supplier'));
comment on column owners.onboarding_route is 'How the owner came in (0710): fleet_supplier, a corporation leasing its cars to CarmaCars on the fleet lease (no fees; the lease and transfer forms pre-filled; no Forms C and D; portal signing only). Null: the standard owner routes.';

alter table program_settings
  add column if not exists fleet_lease_default_regular_cents bigint not null default 58000 check (fleet_lease_default_regular_cents > 0),
  add column if not exists fleet_lease_default_troubled_cents bigint not null default 20000 check (fleet_lease_default_troubled_cents > 0),
  add column if not exists fleet_lease_default_claim_profit_bps integer not null default 2000 check (fleet_lease_default_claim_profit_bps between 0 and 10000),
  add column if not exists fleet_lease_default_early_writeoff_bps integer not null default 10000 check (fleet_lease_default_early_writeoff_bps between 0 and 10000),
  add column if not exists fleet_lease_default_writeoff_months integer not null default 18 check (fleet_lease_default_writeoff_months between 1 and 240),
  add column if not exists fleet_lease_default_later_writeoff_bps integer not null default 5000 check (fleet_lease_default_later_writeoff_bps between 0 and 10000),
  add column if not exists fleet_lease_default_notice_days integer not null default 30 check (fleet_lease_default_notice_days between 1 and 365);
comment on column program_settings.fleet_lease_default_regular_cents is 'Fleet supplier route (0710): the lease a month of a Regular car a new supplier starts with (Admin changes a supplier''s own terms on its Terms tab).';
comment on column program_settings.fleet_lease_default_troubled_cents is 'Fleet supplier route (0710): the lease a month of a Troubled car a new supplier starts with.';
comment on column program_settings.fleet_lease_default_claim_profit_bps is 'Fleet supplier route (0710): the supplier''s share of a claim profit, in basis points.';
comment on column program_settings.fleet_lease_default_early_writeoff_bps is 'Fleet supplier route (0710): the supplier''s share of a write-off settlement (after liens) under the Write-Off Period.';
comment on column program_settings.fleet_lease_default_writeoff_months is 'Fleet supplier route (0710): the Write-Off Period, months in service.';
comment on column program_settings.fleet_lease_default_later_writeoff_bps is 'Fleet supplier route (0710): the supplier''s share of a write-off settlement (after liens) after the Write-Off Period.';
comment on column program_settings.fleet_lease_default_notice_days is 'Fleet supplier route (0710): the Notice Period, days.';

alter table vehicle_onboardings add column if not exists lease_tier text check (lease_tier in ('regular', 'troubled'));
alter table vehicle_onboardings add column if not exists fleet_transfer jsonb check (fleet_transfer is null or jsonb_typeof(fleet_transfer) = 'object');
comment on column vehicle_onboardings.fleet_transfer is 'A fleet supplier''s car (0710): who it is registered to now. registered_to: corporation (his corporation already), officer (a person, usually his officer, moving his own car into the corporation) or seller (bought from someone else); for officer and seller: name, address, date (the transfer or sale date).';
comment on column vehicle_onboardings.lease_tier is 'A fleet supplier''s car (0710): the tier he chose when he added it. Locked: only an Admin corrects it before approval (fleet_onboarding_tier_correct); approval puts the car on the lease at this tier.';

create or replace function app.fleet_supplier(p_owner uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select o.onboarding_route = 'fleet_supplier' from owners o where o.id = p_owner), false)
$$;
create or replace function app.vehicle_fleet_supplier(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select app.fleet_supplier(v.owner_id) from vehicles v where v.id = p_vehicle), false)
$$;

-- the tier is locked once chosen: only an Admin's correction (below) changes it
create or replace function app.onboarding_tier_lock() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if old.lease_tier is not null and new.lease_tier is distinct from old.lease_tier
     and coalesce(current_setting('app.fleet_tier_fix', true), '') <> 'on' then
    raise exception 'The car''s tier was set when it was added and does not change. An Admin corrects a tier entered by mistake' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger vehicle_onboardings_tier_lock before update of lease_tier on vehicle_onboardings
  for each row execute function app.onboarding_tier_lock();

-- The fleet lease structure of a supplier: the default terms (from the first of this month, so a car delivered this
-- month is covered) and the default Upkeep Table. Kept when the supplier already has terms or a split.
create or replace function app.fleet_supplier_setup(p_owner uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  s program_settings := app.settings();
  t owner_fleet_lease_terms;
begin
  select * into o from owners where id = p_owner for update;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  if o.owner_type <> 'corporation' then raise exception 'The fleet supplier route is for a corporation' using errcode = '22023'; end if;
  if exists (select 1 from vehicles v where v.owner_id = o.id and v.status not in ('exited', 'declined', 'total_loss')
               and not exists (select 1 from vehicle_onboardings ob where ob.vehicle_id = v.id and ob.lease_tier is not null)
               and not app.fleet_car(v.id)) then
    raise exception 'This owner has cars on the standard terms: a fleet supplier''s cars are all on the fleet lease. Add the supplier as its own owner' using errcode = '23514';
  end if;
  update owners set onboarding_route = 'fleet_supplier' where id = o.id and onboarding_route is distinct from 'fleet_supplier';
  t := app.fleet_terms_current(o.id);
  if t.id is null then
    insert into owner_fleet_lease_terms (owner_id, regular_cents, troubled_cents, claim_profit_bps, early_writeoff_bps, writeoff_months, later_writeoff_bps,
                                         notice_days, effective_from, note, created_by)
    values (o.id, s.fleet_lease_default_regular_cents, s.fleet_lease_default_troubled_cents, s.fleet_lease_default_claim_profit_bps,
            s.fleet_lease_default_early_writeoff_bps, s.fleet_lease_default_writeoff_months, s.fleet_lease_default_later_writeoff_bps,
            s.fleet_lease_default_notice_days, app.month_start(app.today()), 'The default terms of the fleet supplier route (Program settings)', p_by)
    returning * into t;
  end if;
  insert into owner_upkeep_split (owner_id, cost_type, party, set_by)
  select o.id, x.ct, x.party, p_by
    from (values ('engine', 'supplier'), ('transmission', 'supplier'), ('shocks', 'supplier'), ('rustproofing', 'supplier'), ('refurbishment', 'supplier'),
                 ('tires', 'company'), ('brakes', 'company'), ('oil_change', 'company'), ('ball_joints', 'company')) x(ct, party)
  on conflict (owner_id, cost_type) do nothing;
  return jsonb_build_object('owner_id', o.id, 'terms_id', t.id, 'regular_cents', t.regular_cents, 'troubled_cents', t.troubled_cents);
end $$;

-- The forms a supplier's car needs, filled now (app.vehicle_registry_forms, wrapped below, picks them). A form whose
-- template is missing is left out (it fills once an Admin uploads it); the application never fails on it.
create or replace function app.fleet_supplier_car_forms(p_vehicle uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  n integer := 0;
begin
  begin
    select count(*) into n from app.fill_vehicle_government_forms(p_vehicle, null);
  exception when others then
    raise notice 'fleet supplier forms of %: %', p_vehicle, sqlerrm;
  end;
  return n;
end $$;

-- who the car is registered to now: corporation | officer | seller, with the transferor's name, address and date
create or replace function app.fleet_transfer_check(v jsonb, p_staff boolean) returns jsonb
language plpgsql immutable as $$
declare
  t jsonb := case when jsonb_typeof(v -> 'fleet_transfer') = 'object' then v -> 'fleet_transfer' else '{}'::jsonb end;
  k text := coalesce(nullif(t ->> 'registered_to', ''), case when p_staff then 'corporation' end);
  v_on date;
begin
  if k is null or k not in ('corporation', 'officer', 'seller') then
    raise exception 'Say who each car is registered to now: your corporation, you or another officer personally, or a seller' using errcode = '22023';
  end if;
  if k = 'corporation' then return jsonb_build_object('registered_to', k); end if;
  if nullif(btrim(coalesce(t ->> 'name', '')), '') is null then
    raise exception '%', case k when 'seller' then 'Enter the seller''s name, as on the ownership' else 'Enter the name of the person the car is registered to now' end using errcode = '22023';
  end if;
  if nullif(btrim(coalesce(t ->> 'address', '')), '') is null then raise exception 'Enter the % address', case k when 'seller' then 'seller''s' else 'current registered owner''s' end using errcode = '22023'; end if;
  begin v_on := nullif(t ->> 'date', '')::date;
  exception when others then raise exception 'Give the % date as YYYY-MM-DD', case k when 'seller' then 'sale' else 'transfer' end using errcode = '22023';
  end;
  if v_on is null then raise exception 'Enter the % date', case k when 'seller' then 'sale' else 'transfer' end using errcode = '22023'; end if;
  return jsonb_build_object('registered_to', k, 'name', left(btrim(t ->> 'name'), 200), 'address', left(btrim(t ->> 'address'), 300),
                            'city', nullif(left(btrim(coalesce(t ->> 'city', '')), 100), ''), 'date', v_on);
end $$;

-- ================================================================ 3. the application: the route, the cars, the tier
-- p.owner.route = 'fleet_supplier' (or an owner already on the route): a corporation; per car the VIN, the plate and
-- the tier (lease_tier). The cars are Managed, held by the corporation, owned outright (the lender, if any, is
-- recorded by an Admin: liens come first on a write-off), with the forms its route needs (below).
alter function app.submit_owner_application(jsonb, uuid) rename to submit_owner_application_pre0710;
create function app.submit_owner_application(p jsonb, p_by uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid := nullif(p ->> 'owner_id', '')::uuid;
  v_fleet boolean;
  o jsonb := coalesce(p -> 'owner', '{}'::jsonb);
  v_cars jsonb := '[]'::jsonb;
  v jsonb;
  v_out jsonb;
  v_id uuid;
  v_owner_out uuid;
  x jsonb;
  k text;
begin
  if v_owner is null and p_by is not null and not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then
    select x2.id into v_owner from owners x2 where x2.user_id = p_by order by x2.created_at limit 1;
  end if;
  v_fleet := coalesce(o ->> 'route', '') = 'fleet_supplier' or (v_owner is not null and app.fleet_supplier(v_owner));
  if not v_fleet then
    if exists (select 1 from jsonb_array_elements(case when jsonb_typeof(p -> 'vehicles') = 'array' then p -> 'vehicles' else '[]'::jsonb end) e
                where jsonb_typeof(e) = 'object' and nullif(e ->> 'lease_tier', '') is not null) then
      raise exception 'A car''s tier is for the fleet supplier route only' using errcode = '22023';
    end if;
    return app.submit_owner_application_pre0710(p, p_by);
  end if;
  if v_owner is not null and not app.fleet_supplier(v_owner)
     and exists (select 1 from vehicles c where c.owner_id = v_owner and c.status not in ('exited', 'declined', 'total_loss')) then
    raise exception 'This owner has cars on the standard terms: a fleet supplier''s cars are all on the fleet lease. Add the supplier as its own owner' using errcode = '23514';
  end if;
  -- the corporation (a new owner, or the record being completed)
  if v_owner is null or jsonb_typeof(p -> 'owner') = 'object' and (p -> 'owner') ? 'owner_type' then
    if coalesce(o ->> 'owner_type', '') <> 'corporation' then
      raise exception 'The fleet supplier route is for a corporation: enrol as a corporation' using errcode = '22023';
    end if;
    foreach k in array array['corporation_name', 'corporation_number', 'address_line1', 'city', 'postal_code', 'signing_officer_name', 'signing_officer_title'] loop
      if nullif(btrim(coalesce(o ->> k, '')), '') is null and not (p_by is not null and (app.user_is_admin(p_by) or app.user_is_staff(p_by)) and k <> 'corporation_name') then
        raise exception 'Enter %', case k when 'corporation_name' then 'the corporation''s legal name' when 'corporation_number' then 'the corporation number'
          when 'address_line1' then 'the registered address' when 'city' then 'the city of the registered address' when 'postal_code' then 'the postal code of the registered address'
          when 'signing_officer_name' then 'the signing officer''s name' else 'the signing officer''s title' end using errcode = '22023';
      end if;
    end loop;
  end if;
  for v in select e from jsonb_array_elements(case when jsonb_typeof(p -> 'vehicles') = 'array' then p -> 'vehicles' else '[]'::jsonb end) e loop
    if jsonb_typeof(v) <> 'object' then continue; end if;
    if coalesce(v ->> 'lease_tier', '') not in ('regular', 'troubled') then
      raise exception 'Mark each car Regular or Troubled. It is set when you add the car and does not change' using errcode = '22023';
    end if;
    if app.clean_vin(v ->> 'vin') is null then raise exception 'Enter each car''s 17-character VIN' using errcode = '22023'; end if;
    if nullif(btrim(coalesce(v ->> 'plate', '')), '') is null then raise exception 'Enter each car''s plate' using errcode = '22023'; end if;
    perform app.fleet_transfer_check(v, p_by is not null and (app.user_is_admin(p_by) or app.user_is_staff(p_by)));
    v_cars := v_cars || jsonb_build_array((v - 'lease_tier' - 'fleet_transfer' - 'onboarding_method' - 'new_corporation' - 'owners_lien' - 'finance_party_name' - 'finance_party_account') || jsonb_build_object(
      'held_by', 'corporation', 'title_status', 'owned_outright', 'finance_permission', 'not_applicable', 'management_mode', 'managed',
      'onboarding_method', 'lease_existing_corporation', 'owners_lien', false, 'title_brand_clear', true));
  end loop;
  v_out := app.submit_owner_application_pre0710(case when jsonb_typeof(p -> 'vehicles') = 'array' then jsonb_set(p, '{vehicles}', v_cars) else p end, p_by);
  v_owner_out := coalesce(nullif(v_out ->> 'owner_id', '')::uuid, v_owner,
                          (select a.owner_id from owner_applications a where a.id = nullif(v_out ->> 'application_id', '')::uuid));
  update owners set onboarding_route = 'fleet_supplier' where id = v_owner_out and onboarding_route is null;
  for v in select e from jsonb_array_elements(case when jsonb_typeof(p -> 'vehicles') = 'array' then p -> 'vehicles' else '[]'::jsonb end) e loop
    continue when jsonb_typeof(v) <> 'object';
    select c.id into v_id from vehicles c where upper(c.vin) = app.clean_vin(v ->> 'vin') and c.owner_id = v_owner_out;
    continue when v_id is null;
    update vehicle_onboardings set lease_tier = v ->> 'lease_tier',
           fleet_transfer = app.fleet_transfer_check(v, p_by is not null and (app.user_is_admin(p_by) or app.user_is_staff(p_by)))
     where vehicle_id = v_id and lease_tier is null;
  end loop;
  perform app.fleet_supplier_setup(v_owner_out, p_by);
  -- the forms of each new car, pre-filled at once (the route's rule: no staff step)
  for v in select e from jsonb_array_elements(case when jsonb_typeof(p -> 'vehicles') = 'array' then p -> 'vehicles' else '[]'::jsonb end) e loop
    continue when jsonb_typeof(v) <> 'object';
    select c.id into v_id from vehicles c where upper(c.vin) = app.clean_vin(v ->> 'vin') and c.owner_id = v_owner_out;
    continue when v_id is null;
    perform app.fleet_supplier_car_forms(v_id);
  end loop;
  return v_out || jsonb_build_object('fleet_supplier', true);
end $$;
select pg_temp.copy_grants('app.submit_owner_application(jsonb, uuid)'::regprocedure, 'app.submit_owner_application_pre0710(jsonb, uuid)'::regprocedure);

-- Staff add a car (or a new owner and a car): p.owner.route, or an owner already on the route. The tier goes with the
-- car (p.fleet.tier, as 0640); the car goes on the lease when an Admin approves (at once for an Admin's own entry).
-- No paper signing for a supplier, and no terms or invoices: the supplier pays no fees.
alter function app.staff_add_owner_car(uuid, jsonb) rename to staff_add_owner_car_pre0710;
create function app.staff_add_owner_car(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid := nullif(p ->> 'owner_id', '')::uuid;
  v_fleet boolean := coalesce(p #>> '{owner,route}', '') = 'fleet_supplier' or (v_owner is not null and app.fleet_supplier(v_owner));
  v_tier text := coalesce(nullif(p #>> '{fleet,tier}', ''), nullif(p #>> '{vehicle,lease_tier}', ''));
  v_out jsonb;
begin
  if not v_fleet then return app.staff_add_owner_car_pre0710(p_by, p); end if;
  if coalesce(p ->> 'signing', 'email') = 'paper' then
    raise exception 'A fleet supplier signs in the owner portal only (the e-signature with its audit trail): choose "Email the owner to review and sign"' using errcode = '22023';
  end if;
  if v_tier is null or v_tier not in ('regular', 'troubled') then
    raise exception 'This owner is a fleet supplier: choose the car''s tier (Regular or Troubled). It is set once and does not change' using errcode = '22023';
  end if;
  p := jsonb_set(p, '{vehicle}', coalesce(p -> 'vehicle', '{}'::jsonb) || jsonb_build_object('lease_tier', v_tier)
         || case when jsonb_typeof(p #> '{fleet,transfer}') = 'object' then jsonb_build_object('fleet_transfer', p #> '{fleet,transfer}') else '{}'::jsonb end);
  if nullif(p #>> '{fleet,delivered_on}', '') is not null then p := jsonb_set(p, '{plan}', coalesce(p -> 'plan', '{}'::jsonb) || jsonb_build_object('delivered_on', p #>> '{fleet,delivered_on}')); end if;
  if p ? 'plan' then p := jsonb_set(p, '{plan,invoices}', '[]'::jsonb); end if;
  -- 0640's wrapper puts a car on the lease at once by its terms; the route waits for the approval (below), so it is
  -- passed by and the earlier chain runs
  return app.staff_add_owner_car_pre0640(p_by, p - 'fleet');
end $$;
select pg_temp.copy_grants('app.staff_add_owner_car(uuid, jsonb)'::regprocedure, 'app.staff_add_owner_car_pre0710(uuid, jsonb)'::regprocedure);

-- Owners > Add an owner: route fleet_supplier (a corporation): the lease structure at once, no fee terms.
alter function app.owner_add(uuid, jsonb) rename to owner_add_pre0710;
create function app.owner_add(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
begin
  if coalesce(p ->> 'route', '') <> 'fleet_supplier' then return app.owner_add_pre0710(p_by, p); end if;
  if coalesce(p ->> 'owner_type', '') <> 'corporation' then raise exception 'The fleet supplier route is for a corporation' using errcode = '22023'; end if;
  v_out := app.owner_add_pre0710(p_by, p - 'terms');
  return v_out || jsonb_build_object('fleet', app.fleet_supplier_setup((v_out ->> 'owner_id')::uuid, p_by));
end $$;
select pg_temp.copy_grants('app.owner_add(uuid, jsonb)'::regprocedure, 'app.owner_add_pre0710(uuid, jsonb)'::regprocedure);

-- Approve a supplier's application: each car Managed with no fees and no invoice, then on the lease at the tier he
-- chose, from the delivery date (p.cars[].delivered_on, or p.delivered_on, else today).
alter function app.application_approve(uuid, jsonb) rename to application_approve_pre0710;
create function app.application_approve(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a owner_applications;
  r record;
  c jsonb;
  v_cars jsonb := '[]'::jsonb;
  v_out jsonb;
  v_lease jsonb := '[]'::jsonb;
  v_on text;
begin
  select * into a from owner_applications where id = nullif(p ->> 'id', '')::uuid;
  if a.id is null or not app.fleet_supplier(a.owner_id) then return app.application_approve_pre0710(p_admin, p); end if;
  perform app.assert_admin(p_admin);
  if a.status = 'approved' then return app.application_approve_pre0710(p_admin, p); end if;
  perform app.fleet_supplier_setup(a.owner_id, p_admin);
  for r in select v.id, ob.lease_tier from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
            where v.owner_id = a.owner_id and ob.status = 'intake' order by v.created_at loop
    if r.lease_tier is null then
      raise exception '% has no tier: set it (Regular or Troubled) before approving', app.vehicle_name(r.id) using errcode = '23514';
    end if;
    c := (select x from jsonb_array_elements(coalesce(p -> 'cars', '[]'::jsonb)) x where x ->> 'vehicle_id' = r.id::text limit 1);
    v_cars := v_cars || jsonb_build_array(jsonb_build_object('vehicle_id', r.id,
      'terms', jsonb_build_object('management_mode', 'managed', 'onboarding_method', 'lease_existing_corporation', 'insurance_fee_cents', 0, 'tracker_fee_cents', 0,
                                  'revenue_share_bps', 0, 'install_fee_cents', 0, 'first_last_cents', 0, 'one_off_fees', '[]'::jsonb,
                                  'special_terms', 'Fleet Supplier Lease Agreement: leased at the ' || initcap(r.lease_tier) || ' rate; no fees'),
      'invoices', '[]'::jsonb, 'first_last', jsonb_build_object('action', 'none'),
      'delivered_on', coalesce(nullif(c ->> 'delivered_on', ''), nullif(p ->> 'delivered_on', ''), nullif(p #>> '{cars,0,delivered_on}', ''))));
  end loop;
  v_out := app.application_approve_pre0710(p_admin, jsonb_set(p, '{cars}', (select coalesce(jsonb_agg(x - 'delivered_on'), '[]'::jsonb) from jsonb_array_elements(v_cars) x)));
  for c in select x from jsonb_array_elements(v_cars) x loop
    continue when app.fleet_delivered_on((c ->> 'vehicle_id')::uuid) is not null;
    v_on := coalesce(c ->> 'delivered_on', app.today()::text);
    v_lease := v_lease || jsonb_build_array(app.fleet_lease_car_set(p_admin, jsonb_build_object('vehicle_id', c ->> 'vehicle_id',
      'tier', (select ob.lease_tier from vehicle_onboardings ob where ob.vehicle_id = (c ->> 'vehicle_id')::uuid), 'delivered_on', v_on, 'reason', 'Onboarded: approved')) || jsonb_build_object('vehicle_id', c ->> 'vehicle_id'));
    perform app.fleet_supplier_car_forms((c ->> 'vehicle_id')::uuid);
  end loop;
  return v_out || jsonb_build_object('fleet_lease', v_lease);
end $$;
select pg_temp.copy_grants('app.application_approve(uuid, jsonb)'::regprocedure, 'app.application_approve_pre0710(uuid, jsonb)'::regprocedure);

-- the approval page knows the route and each car's tier
alter function app.application_approve_plan(uuid, jsonb) rename to application_approve_plan_pre0710;
create function app.application_approve_plan(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.application_approve_plan_pre0710(p_by, p);
  a owner_applications;
  t owner_fleet_lease_terms;
begin
  select * into a from owner_applications where id = nullif(p ->> 'id', '')::uuid;
  if not app.fleet_supplier(a.owner_id) then return v || jsonb_build_object('fleet_supplier', false); end if;
  t := app.fleet_terms_current(a.owner_id);
  return jsonb_set(v, '{cars}', coalesce((select jsonb_agg(x || jsonb_build_object('lease_tier', ob.lease_tier, 'lease_cents', app.fleet_rate(t, ob.lease_tier)) order by n)
                                           from jsonb_array_elements(v -> 'cars') with ordinality e(x, n)
                                           left join vehicle_onboardings ob on ob.vehicle_id::text = x ->> 'vehicle_id'), '[]'::jsonb))
         || jsonb_build_object('fleet_supplier', true, 'fleet_terms', jsonb_build_object('regular_cents', t.regular_cents, 'troubled_cents', t.troubled_cents));
end $$;
select pg_temp.copy_grants('app.application_approve_plan(uuid, jsonb)'::regprocedure, 'app.application_approve_plan_pre0710(uuid, jsonb)'::regprocedure);

-- Admin only: a tier chosen by mistake, corrected before the car is approved (after it: fleet_lease_tier_correct).
-- p: vehicle_id, tier, reason.
create or replace function app.fleet_onboarding_tier_correct(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ob vehicle_onboardings;
  v_tier text := nullif(p ->> 'tier', '');
  v_reason text := btrim(coalesce(p ->> 'reason', ''));
begin
  perform app.assert_admin(p_by);
  select * into ob from vehicle_onboardings where vehicle_id = nullif(p ->> 'vehicle_id', '')::uuid for update;
  if ob.id is null or ob.lease_tier is null then raise exception 'This car has no fleet lease tier' using errcode = 'P0002'; end if;
  if app.fleet_delivered_on(ob.vehicle_id) is not null then
    raise exception 'This car is approved and on the lease: correct its tier on the owner''s Fleet lease card' using errcode = '23514';
  end if;
  if v_tier is null or v_tier not in ('regular', 'troubled') then raise exception 'Choose the correct tier: Regular or Troubled' using errcode = '22023'; end if;
  if v_tier = ob.lease_tier then raise exception 'This car''s tier is % already', initcap(v_tier) using errcode = '23514'; end if;
  if length(v_reason) < 5 then raise exception 'Write what was entered by mistake (kept in the audit log)' using errcode = '22023'; end if;
  perform set_config('app.fleet_tier_fix', 'on', true);
  update vehicle_onboardings set lease_tier = v_tier where id = ob.id;
  perform set_config('app.fleet_tier_fix', '', true);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'fleet_onboarding_tier_corrected', 'vehicles', ob.vehicle_id::text, jsonb_build_object('tier', ob.lease_tier), jsonb_build_object('tier', v_tier, 'reason', v_reason));
  return jsonb_build_object('done', true, 'tier', v_tier);
end $$;

-- ================================================================ 4. portal signing only
alter function app.record_paper_signature(uuid, jsonb) rename to record_paper_signature_pre0710;
create function app.record_paper_signature(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid;
begin
  if p ->> 'doc_type' in ('owner_agreement', 'form_a', 'form_b', 'form_d') then v_owner := nullif(p ->> 'target_id', '')::uuid;
  elsif p ->> 'doc_type' = 'form_c' then v_owner := (select owner_id from vehicles where id = nullif(p ->> 'target_id', '')::uuid);
  end if;
  if v_owner is not null and app.fleet_supplier(v_owner) then
    raise exception 'A fleet supplier signs in the owner portal only (the e-signature with its audit trail): no paper signature is recorded' using errcode = '23514';
  end if;
  return app.record_paper_signature_pre0710(p_by, p);
end $$;
select pg_temp.copy_grants('app.record_paper_signature(uuid, jsonb)'::regprocedure, 'app.record_paper_signature_pre0710(uuid, jsonb)'::regprocedure);

-- nothing from the other routes: no Forms C and D (paper, witnessed) and no upfront payment
alter function app.owner_witnessed_forms(uuid) rename to owner_witnessed_forms_pre0710;
create function app.owner_witnessed_forms(p_owner uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when app.fleet_supplier(p_owner) then '[]'::jsonb else app.owner_witnessed_forms_pre0710(p_owner) end
$$;
select pg_temp.copy_grants('app.owner_witnessed_forms(uuid)'::regprocedure, 'app.owner_witnessed_forms_pre0710(uuid)'::regprocedure);

alter function app.onboarding_checklist(uuid) rename to onboarding_checklist_pre0710;
create function app.onboarding_checklist(p_vehicle uuid)
returns table (code text, label text, sort_order integer, status text, waits_on text, next_action text, owner_action text, staff_action text)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_fleet boolean := app.vehicle_fleet_supplier(p_vehicle);
begin
  return query select c.* from app.onboarding_checklist_pre0710(p_vehicle) c
    where not v_fleet or c.code <> 'upfront_payment';
end $$;
select pg_temp.copy_grants('app.onboarding_checklist(uuid)'::regprocedure, 'app.onboarding_checklist_pre0710(uuid)'::regprocedure);

-- The forms of a supplier's car: the lease to CarmaCars as the existing-corporation lease (S1: SR-LV-006, SR-LV-012),
-- and the transfer into his corporation when the car is not registered to it yet.
alter function app.vehicle_registry_forms(uuid) rename to vehicle_registry_forms_pre0710;
create function app.vehicle_registry_forms(p_vehicle uuid) returns text[]
language plpgsql stable security definer set search_path = public, app as $$
declare
  ob vehicle_onboardings;
  v_forms text[];
  v_rin_missing boolean;
begin
  if not app.vehicle_fleet_supplier(p_vehicle) then return app.vehicle_registry_forms_pre0710(p_vehicle); end if;
  select * into ob from vehicle_onboardings where vehicle_id = p_vehicle;
  v_forms := array['SR-LV-006', 'SR-LV-012'];
  if coalesce(ob.fleet_transfer ->> 'registered_to', 'corporation') = 'corporation' then return v_forms; end if;
  v_rin_missing := coalesce((app.registry_context(p_vehicle) #>> '{corporation,rin_missing}')::boolean, true);
  if v_rin_missing then v_forms := array_append(v_forms, 'ON00453'); end if;
  if ob.fleet_transfer ->> 'registered_to' = 'officer' then v_forms := v_forms || array['013-0169', '013-1155']::text[]; end if;
  return v_forms;
end $$;
select pg_temp.copy_grants('app.vehicle_registry_forms(uuid)'::regprocedure, 'app.vehicle_registry_forms_pre0710(uuid)'::regprocedure);

-- The context of a supplier's car: his corporation is the vehicle's registrant (the lease, as S1); the transfer (who it
-- comes from and when); on the transfer forms (013-0169, 013-1155) the transferor is the current registered owner.
alter function app.registry_context(uuid) rename to registry_context_pre0710;
create function app.registry_context(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  c jsonb := app.registry_context_pre0710(p_vehicle);
  t jsonb;
begin
  if c is null or not app.vehicle_fleet_supplier(p_vehicle) then return c; end if;
  t := (select ob.fleet_transfer from vehicle_onboardings ob where ob.vehicle_id = p_vehicle);
  c := c || jsonb_build_object('fleet_transfer', coalesce(t, '{}'::jsonb) || jsonb_build_object('needed', coalesce(t ->> 'registered_to', 'corporation') <> 'corporation'));
  if coalesce(current_setting('app.fill_form', true), '') in ('013-0169', '013-1155') and t ->> 'registered_to' in ('officer', 'seller') then
    c := jsonb_set(c, '{owner}', (c -> 'owner') || jsonb_build_object('legal_name', upper(t ->> 'name'),
           'city', coalesce(t ->> 'city', app.split_ca_address(t ->> 'address') ->> 'city', c #>> '{owner,city}')));
  end if;
  return c;
end $$;
select pg_temp.copy_grants('app.registry_context(uuid)'::regprocedure, 'app.registry_context_pre0710(uuid)'::regprocedure);

alter function app.fill_government_form(uuid, text, uuid) rename to fill_government_form_pre0710;
create function app.fill_government_form(p_vehicle uuid, p_form_code text, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  perform set_config('app.fill_form', coalesce(p_form_code, ''), true);
  v_id := app.fill_government_form_pre0710(p_vehicle, p_form_code, p_by);
  perform set_config('app.fill_form', '', true);
  return v_id;
end $$;
select pg_temp.copy_grants('app.fill_government_form(uuid, text, uuid)'::regprocedure, 'app.fill_government_form_pre0710(uuid, text, uuid)'::regprocedure);

-- ================================================================ 5. the supplier's lease in the owner portal
-- The next Payout Date that pays a lease month: the first one at least one full month after delivery, then each 10th.
create or replace function app.fleet_next_payment(p_vehicle uuid) returns date
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_del date := app.fleet_delivered_on(p_vehicle);
  v_first date;
  m date;
begin
  if v_del is null then return null; end if;
  v_first := app.fleet_first_pay_month(v_del);
  m := greatest(v_first, (app.month_start(app.today()) - interval '1 month')::date);
  while app.payout_date(m) < app.today() loop m := (m + interval '1 month')::date; end loop;
  return app.payout_date(m);
end $$;

create or replace function app.owner_fleet_lease_view(p_owner uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when app.fleet_supplier(p_owner) or app.owner_pay_model(p_owner) = 'fleet_lease' then jsonb_build_object(
    'terms', (select jsonb_build_object('regular_cents', t.regular_cents, 'troubled_cents', t.troubled_cents, 'effective_from', t.effective_from,
                                        'awaiting_signature', t.awaiting_signature) from app.fleet_terms_current(p_owner) t where t.id is not null),
    'cars', coalesce((select jsonb_agg(jsonb_build_object('vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate,
              'tier', coalesce((app.flat_arrangement_on(v.id, app.today())).lease_tier, ob.lease_tier),
              'monthly_cents', coalesce((app.flat_arrangement_on(v.id, app.today())).monthly_cents, app.fleet_rate(app.fleet_terms_current(p_owner), ob.lease_tier)),
              'delivered_on', app.fleet_delivered_on(v.id), 'next_payment_on', app.fleet_next_payment(v.id),
              'status', case when app.fleet_delivered_on(v.id) is null then 'waiting_approval' else 'on_lease' end,
              'registered_to', coalesce(ob.fleet_transfer ->> 'registered_to', 'corporation'), 'forms', to_jsonb(coalesce(ob.government_forms, '{}'::text[])))
              order by v.fleet_number nulls last, v.created_at)
       from vehicles v left join vehicle_onboardings ob on ob.vehicle_id = v.id
      where v.owner_id = p_owner and v.retired_at is null and v.status not in ('exited', 'declined', 'total_loss')), '[]'::jsonb),
    'next_payment_on', (select min(app.fleet_next_payment(v.id)) from vehicles v where v.owner_id = p_owner and v.retired_at is null and v.status not in ('exited', 'declined', 'total_loss')),
    'route', (select onboarding_route from owners where id = p_owner)) end
$$;

alter function app.owner_portal_home(uuid) rename to owner_portal_home_pre0710;
create function app.owner_portal_home(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.owner_portal_home_pre0710(p_by);
  v_owner uuid;
begin
  if v is null or jsonb_typeof(v) <> 'object' then return v; end if;
  v_owner := nullif(v #>> '{owner,id}', '')::uuid;
  return v || jsonb_build_object('fleet_supplier', app.fleet_supplier(v_owner), 'fleet_lease', app.owner_fleet_lease_view(v_owner));
end $$;
select pg_temp.copy_grants('app.owner_portal_home(uuid)'::regprocedure, 'app.owner_portal_home_pre0710(uuid)'::regprocedure);

-- Admin's Fleet lease card: the route and each car's tier waiting for approval
alter function app.fleet_lease_read(uuid, jsonb) rename to fleet_lease_read_pre0710;
create function app.fleet_lease_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.fleet_lease_read_pre0710(p_by, p);
begin
  return jsonb_set(v, '{cars}', coalesce((select jsonb_agg(x || jsonb_build_object('requested_tier', ob.lease_tier, 'onboarding_status', ob.status) order by n)
                                           from jsonb_array_elements(v -> 'cars') with ordinality e(x, n)
                                           left join vehicle_onboardings ob on ob.vehicle_id::text = x ->> 'vehicle_id'), '[]'::jsonb))
         || jsonb_build_object('route', (select onboarding_route from owners where id = nullif(p ->> 'owner', '')::uuid));
end $$;
select pg_temp.copy_grants('app.fleet_lease_read(uuid, jsonb)'::regprocedure, 'app.fleet_lease_read_pre0710(uuid, jsonb)'::regprocedure);

-- the application page: the route's lease a month by tier (the defaults of Program settings)
alter function public.server_owner_program_facts() rename to server_owner_program_facts_pre0710;
create function public.server_owner_program_facts() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select public.server_owner_program_facts_pre0710() || jsonb_build_object('fleet_lease', jsonb_build_object(
    'regular_cents', (app.settings()).fleet_lease_default_regular_cents, 'troubled_cents', (app.settings()).fleet_lease_default_troubled_cents))
$$;
select pg_temp.copy_grants('public.server_owner_program_facts()'::regprocedure, 'public.server_owner_program_facts_pre0710()'::regprocedure);
revoke all on function public.server_owner_program_facts_pre0710() from public, anon, authenticated;
grant execute on function public.server_owner_program_facts_pre0710() to service_role;

-- ================================================================ 6. the door, privileges
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0710;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_do', 'admin_do') and p_name = 'fleet_onboarding_tier_correct' then
    perform app.door_begin(p_user, p_aal);
    return app.fleet_onboarding_tier_correct(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0710(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0710(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['fleet_supplier', 'vehicle_fleet_supplier', 'onboarding_tier_lock', 'fleet_supplier_setup', 'fleet_supplier_car_forms', 'fleet_transfer_check', 'vehicle_registry_forms_pre0710', 'registry_context_pre0710', 'fill_government_form_pre0710',
             'submit_owner_application_pre0710', 'staff_add_owner_car_pre0710', 'owner_add_pre0710', 'application_approve_pre0710',
             'application_approve_plan_pre0710', 'fleet_onboarding_tier_correct', 'record_paper_signature_pre0710', 'owner_witnessed_forms_pre0710',
             'onboarding_checklist_pre0710', 'fleet_next_payment', 'owner_fleet_lease_view',
             'owner_portal_home_pre0710', 'fleet_lease_read_pre0710', 'door_pre0710'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
