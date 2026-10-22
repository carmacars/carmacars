-- 0087_car_defaults.sql
-- The owner's request of October 21, 2026 (docs/changes/2026-10-21-car-defaults.md): "every car that's entered gets
-- standard settings automatically based on what the car is, and a number right away."
--
--   A. Fleet number: every real car gets one when it is added, from a sequence that never gives a number twice, in
--      the real cars' own range (Program settings: the prefix and the first number, CC 101 by default; the 22 sample
--      cars keep CC 01 to CC 22). The real cars on file get theirs in the order they were added. Internal: staff
--      screens show it; the public reference stays the car code (0079).
--   B. Standard settings when a car is added, by its class, all read from Program settings and Fee defaults (nothing
--      typed into this file): a complete rate card (the typed daily rate, else the suggested one of 0070; weekend,
--      weekly and monthly derived by the rate form's own rules; the kilometres a day, the extra kilometre rate, the
--      deposit by class; delivery and pickup at the class's delivery default, within its range), and drivers 18 to 20
--      allowed (Program settings: Young drivers allowed for these classes, every class by default: staff switch it off
--      for a class there, or on one car). Add-ons
--      (each with its own class and fuel exclusions: no prepaid fuel for an electric car), winter tires (an add-on of
--      the season), the Protection Plan price (by class, 0025 and 0079) and the fuel from the VIN (0082) already
--      follow the car: suite 58 checks them for a new car.
--   C. One function, app.apply_car_defaults, called by every add path through 0082's app.vehicle_after_add (Add a car,
--      Add a car for an owner, Fleet, the owner's application, vehicle_add, staff_add_owner_car). Values typed by a
--      person are kept; a rate card the person types in the same step replaces the one made from the defaults and
--      keeps its defaulted deposit, delivery and pickup.
--   D. The real cars on file: only what is empty is filled (a fleet number, a rate card for a car without one), and
--      drivers 18 to 20 allowed on every real car nobody switched it off for (the audit log shows a person's change).
--   F. (section 6) An owner account without a car: the owner details and the password alone open the account, the
--      owner record and an application "Account only: no car yet"; the first car later is an ordinary application.
--   E. What was set automatically is kept on the car (vehicles.auto_defaults) and on its rate card
--      (rate_cards.auto_defaults): the Admin car page shows "Set automatically" next to those values until a person
--      changes them.

-- ================================================================ 1. settings and columns
alter table program_settings
  add column if not exists fleet_number_prefix text not null default 'CC ' check (length(fleet_number_prefix) <= 10),
  add column if not exists fleet_number_first integer not null default 101 check (fleet_number_first between 1 and 999999),
  add column if not exists young_driver_classes text[] not null default array['economy', 'standard', 'premium', 'suv', 'luxury', 'exotic']
    check (young_driver_classes <@ array['economy', 'standard', 'premium', 'suv', 'luxury', 'exotic']),
  add column if not exists car_defaults_rates_on_add boolean not null default true;
comment on column program_settings.fleet_number_prefix is 'Fleet number of a new real car: this prefix, then the number (0087). Sample cars keep their own numbers.';
comment on column program_settings.fleet_number_first is 'Fleet number of a new real car: the first number of the real cars'' range (0087; numbers are never given twice).';
comment on column program_settings.young_driver_classes is 'A new car allows drivers aged 18 to 20 when its class is one of these (0087; every class by default, the owner''s choice): take a class out to switch it off; staff also turn it off on one car.';
comment on column program_settings.car_defaults_rates_on_add is 'A new car without typed rates gets a complete rate card from the suggested daily rate and the class defaults (0087).';

alter table vehicles add column if not exists auto_defaults jsonb not null default '{}'::jsonb;
comment on column vehicles.auto_defaults is 'What was set automatically on the car (0087): {field: {value, source, at}}. The Admin car page marks a value while it is unchanged.';
alter table rate_cards add column if not exists auto_defaults jsonb not null default '{}'::jsonb;
comment on column rate_cards.auto_defaults is 'The values of this rate card set automatically (0087): {daily|weekend|weekly|monthly|km_per_day|overage|deposit|delivery|pickup: {value, source}}.';

create sequence if not exists vehicle_fleet_number_seq;

-- ================================================================ 2. the fleet number
-- The next free fleet number: prefix and number, the number from the sequence (never back), at least the first number
-- of the real cars' range, skipping any number a person already gave a car.
create or replace function app.next_fleet_number() returns text
language plpgsql volatile security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  n bigint;
  v text;
begin
  loop
    n := nextval('vehicle_fleet_number_seq');
    if n < ps.fleet_number_first then
      perform setval('vehicle_fleet_number_seq', ps.fleet_number_first);
      n := ps.fleet_number_first;
    end if;
    v := coalesce(ps.fleet_number_prefix, '') || lpad(n::text, greatest(2, length(n::text)), '0');
    exit when not exists (select 1 from vehicles x where upper(regexp_replace(x.fleet_number, '\s', '', 'g')) = upper(regexp_replace(v, '\s', '', 'g')));
  end loop;
  return v;
end $$;

create or replace function app.vehicle_fleet_number() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if nullif(btrim(new.fleet_number), '') is null and not coalesce(new.is_sample, false) then
    new.fleet_number := app.next_fleet_number();
    new.auto_defaults := coalesce(new.auto_defaults, '{}'::jsonb)
      || jsonb_build_object('fleet_number', jsonb_build_object('value', new.fleet_number, 'source', 'The next fleet number (Program settings)', 'at', now()));
  end if;
  return new;
end $$;
drop trigger if exists vehicles_a0_fleet_number on vehicles;
create trigger vehicles_a0_fleet_number before insert on vehicles for each row execute function app.vehicle_fleet_number();

-- ================================================================ 3. the standard settings of a car
-- What a car gets by default, from its class: the suggested daily rate (0070), the deposit, the extra kilometre rate
-- and the delivery fee from Fee defaults (the car's own override, its class, else every class), the kilometres a day
-- and the young driver classes from Program settings. Delivery without an amount takes the lowest of its range, kept
-- within the range; pickup is the same as delivery.
create or replace function app.car_default_values(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  ps program_settings := app.settings();
  dep record;
  ov record;
  del record;
  v_del bigint;
  dd jsonb;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return null; end if;
  select * into dep from app.class_fee_default('deposit', v.class::text, v.id);
  select * into ov from app.class_fee_default('mileage_overage', v.class::text, v.id);
  select * into del from app.class_fee_default('delivery', v.class::text, v.id);
  v_del := coalesce(del.amount_cents, del.min_cents);
  if v_del is not null then v_del := greatest(coalesce(del.min_cents, v_del), least(coalesce(del.max_cents, v_del), v_del)); end if;
  dd := app.listing_default_daily(v.id);
  return jsonb_build_object(
    'class', v.class,
    'daily_cents', dd -> 'daily_cents', 'daily_text', dd ->> 'text',
    'deposit_cents', dep.amount_cents, 'km_per_day', ps.default_km_allowance_per_day, 'overage_cents', ov.amount_cents,
    'delivery_cents', v_del, 'pickup_cents', v_del,
    'allows_18_to_20', v.class::text = any (ps.young_driver_classes));
end $$;

-- Applies the standard settings to a car. p: what the add path was given (a value given there is a person's and is
-- kept). p_backfill: a car already on file, where only empty values are filled. Returns what was set.
create or replace function app.apply_car_defaults(p_vehicle uuid, p_by uuid default null, p jsonb default '{}'::jsonb, p_backfill boolean default false)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  ps program_settings := app.settings();
  d jsonb;
  rc rate_cards;
  given jsonb := coalesce(p, '{}'::jsonb) || coalesce(p -> 'vehicle', '{}'::jsonb);
  r jsonb := coalesce(p -> 'rates', '{}'::jsonb);
  v_set jsonb := '{}'::jsonb;
  v_card jsonb := '{}'::jsonb;
  v_src text;
  v_id uuid;
  k text;
begin
  select * into v from vehicles where id = p_vehicle for update;
  if v.id is null or coalesce(v.is_sample, false) then return '{}'::jsonb; end if;
  d := app.car_default_values(v.id);
  v_src := format('Default for the %s class', v.class);

  -- the fleet number (the insert trigger gives it; a car whose number was emptied gets the next one)
  if nullif(btrim(v.fleet_number), '') is null then
    v.fleet_number := app.next_fleet_number();
    update vehicles set fleet_number = v.fleet_number where id = v.id;
    v_set := v_set || jsonb_build_object('fleet_number', jsonb_build_object('value', v.fleet_number, 'source', 'The next fleet number (Program settings)', 'at', now()));
  end if;

  -- drivers 18 to 20, by class, unless the add path was told; on a car on file, allowed unless a person switched it off
  if p_backfill then
    if not v.allows_18_to_20 and (d ->> 'allows_18_to_20')::boolean
       and not exists (select 1 from audit_log a where a.entity_table = 'vehicles' and a.entity_id = v.id::text and a.action = 'UPDATE'
                         and (a.after ->> 'allows_18_to_20') = 'false' and (a.before ->> 'allows_18_to_20') is distinct from 'false') then
      update vehicles set allows_18_to_20 = true where id = v.id;
      v_set := v_set || jsonb_build_object('allows_18_to_20', jsonb_build_object('value', true,
        'source', format('Young drivers allowed for the %s class (Program settings)', v.class), 'at', now()));
    end if;
  elsif not (given ? 'allows_18_to_20') then
    update vehicles set allows_18_to_20 = (d ->> 'allows_18_to_20')::boolean where id = v.id;
    v_set := v_set || jsonb_build_object('allows_18_to_20', jsonb_build_object('value', (d ->> 'allows_18_to_20')::boolean,
      'source', format('Young drivers allowed for the %s class: %s (Program settings)', v.class, case when (d ->> 'allows_18_to_20')::boolean then 'yes' else 'no' end), 'at', now()));
  end if;

  -- the rate card
  select * into rc from rate_cards x where x.vehicle_id = v.id and x.effective_from <= now() and (x.effective_to is null or x.effective_to > now());
  if not exists (select 1 from rate_cards x where x.vehicle_id = v.id) then
    if ps.car_defaults_rates_on_add and (d ->> 'daily_cents') is not null then
      v_id := app.set_rate_card_pre0087(v.id, (d ->> 'daily_cents')::bigint, null, null, null, now(), null,
                jsonb_strip_nulls(jsonb_build_object('km_mode', 'default', 'deposit_cents', d -> 'deposit_cents',
                                                     'delivery_fee_cents', d -> 'delivery_cents', 'pickup_fee_cents', d -> 'pickup_cents')));
      select * into rc from rate_cards where id = v_id;
      v_card := jsonb_build_object(
        'daily', jsonb_build_object('value', rc.daily_rate_cents, 'source', d ->> 'daily_text'),
        'weekend', jsonb_build_object('value', rc.weekend_rate_cents, 'source', 'The daily rate (the rate form''s rule)'),
        'weekly', jsonb_build_object('value', rc.weekly_rate_cents, 'source', '6 days at the daily rate (the rate form''s rule)'),
        'monthly', jsonb_build_object('value', rc.monthly_rate_cents, 'source', '22 days at the daily rate (the rate form''s rule)'),
        'km_per_day', jsonb_build_object('value', rc.km_allowance_per_day, 'source', 'Program settings'),
        'overage', jsonb_build_object('value', rc.overage_cents_per_km, 'source', v_src || ' (Fee defaults)'),
        'deposit', jsonb_build_object('value', rc.deposit_cents, 'source', v_src || ' (Fee defaults)'),
        'delivery', jsonb_build_object('value', rc.delivery_fee_cents, 'source', v_src || ' (Fee defaults, delivery)'),
        'pickup', jsonb_build_object('value', rc.pickup_fee_cents, 'source', 'The same as delivery'));
    end if;
  elsif not p_backfill and rc.id is not null and rc.created_at = now() then
    -- a rate card typed in this same step: what was not typed is marked, and an empty delivery or pickup ($0, the
    -- rate form's empty value) takes the class default
    if not (r ? 'delivery' or given ? 'delivery') and rc.delivery_fee_cents = 0 and (d ->> 'delivery_cents') is not null then
      update rate_cards set delivery_fee_cents = (d ->> 'delivery_cents')::bigint where id = rc.id;
      v_card := v_card || jsonb_build_object('delivery', jsonb_build_object('value', (d ->> 'delivery_cents')::bigint, 'source', v_src || ' (Fee defaults, delivery)'));
    end if;
    if not (r ? 'pickup' or given ? 'pickup') and rc.pickup_fee_cents = 0 and (d ->> 'pickup_cents') is not null then
      update rate_cards set pickup_fee_cents = (d ->> 'pickup_cents')::bigint where id = rc.id;
      v_card := v_card || jsonb_build_object('pickup', jsonb_build_object('value', (d ->> 'pickup_cents')::bigint, 'source', 'The same as delivery'));
    end if;
    foreach k in array array['weekend', 'weekly', 'monthly'] loop
      if nullif(btrim(coalesce(r ->> k, '')), '') is null then
        v_card := v_card || jsonb_build_object(k, jsonb_build_object('value', case k when 'weekend' then rc.weekend_rate_cents when 'weekly' then rc.weekly_rate_cents else rc.monthly_rate_cents end,
                                                                     'source', 'Derived from the daily rate (the rate form''s rule)'));
      end if;
    end loop;
    if nullif(btrim(coalesce(r ->> 'deposit', '')), '') is null then
      v_card := v_card || jsonb_build_object('deposit', jsonb_build_object('value', rc.deposit_cents, 'source', v_src || ' (Fee defaults)'));
    end if;
    if coalesce(r ->> 'km_mode', 'default') = 'default' then
      v_card := v_card || jsonb_build_object('km_per_day', jsonb_build_object('value', rc.km_allowance_per_day, 'source', 'Program settings'),
                                             'overage', jsonb_build_object('value', rc.overage_cents_per_km, 'source', v_src || ' (Fee defaults)'));
    end if;
  end if;
  if v_card <> '{}'::jsonb then update rate_cards set auto_defaults = auto_defaults || v_card where id = rc.id; end if;

  if v_set <> '{}'::jsonb then update vehicles set auto_defaults = auto_defaults || v_set where id = v.id; end if;
  if v_set <> '{}'::jsonb or v_card <> '{}'::jsonb then
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'car_defaults', 'vehicles', v.id::text, jsonb_build_object('vehicle', v_set, 'rate_card', v_card, 'backfill', p_backfill));
  end if;
  return jsonb_build_object('vehicle', v_set, 'rate_card', v_card);
end $$;

-- A rate card typed in the same step as the add replaces the one made from the defaults (same moment, same
-- transaction): the defaulted deposit, delivery and pickup carry over when the person left them out (or typed the
-- same amount), and stay marked.
alter function app.set_rate_card(uuid, bigint, bigint, bigint, bigint, timestamptz, uuid, jsonb) rename to set_rate_card_pre0087;
create or replace function app.set_rate_card(p_vehicle uuid, p_daily_cents bigint, p_weekend_cents bigint, p_weekly_cents bigint,
    p_monthly_cents bigint, p_effective_from timestamptz default now(), p_by uuid default null, p_other jsonb default '{}'::jsonb)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  a rate_cards;
  ot jsonb := coalesce(p_other, '{}'::jsonb);
  v_marks jsonb := '{}'::jsonb;
  v_id uuid;
  f record;
begin
  select * into a from rate_cards r where r.vehicle_id = p_vehicle and r.effective_from = coalesce(p_effective_from, now())
     and r.created_at = now() and r.auto_defaults ? 'daily';
  if a.id is not null then
    for f in select * from (values ('deposit_cents', 'deposit', a.deposit_cents), ('delivery_fee_cents', 'delivery', a.delivery_fee_cents),
                                   ('pickup_fee_cents', 'pickup', a.pickup_fee_cents)) x(key, short, val) loop
      if nullif(btrim(coalesce(ot ->> f.key, '')), '') is null then
        ot := ot || jsonb_build_object(f.key, f.val);
        v_marks := v_marks || jsonb_build_object(f.short, a.auto_defaults -> f.short);
      elsif (ot ->> f.key) = f.val::text then
        v_marks := v_marks || jsonb_build_object(f.short, a.auto_defaults -> f.short);
      end if;
    end loop;
    delete from rate_cards where id = a.id;
  end if;
  v_id := app.set_rate_card_pre0087(p_vehicle, p_daily_cents, p_weekend_cents, p_weekly_cents, p_monthly_cents, p_effective_from, p_by, ot);
  v_marks := jsonb_strip_nulls(v_marks);
  if v_marks <> '{}'::jsonb then update rate_cards set auto_defaults = auto_defaults || v_marks where id = v_id; end if;
  return v_id;
end $$;

-- Every add path ends in 0082's app.vehicle_after_add: the standard settings follow there. Never raises (adding the
-- car is what counts).
alter function app.vehicle_after_add(uuid, uuid, jsonb) rename to vehicle_after_add_pre0087;
create or replace function app.vehicle_after_add(p_vehicle uuid, p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.vehicle_after_add_pre0087(p_vehicle, p_by, p);
  v_def jsonb;
begin
  if p_vehicle is null then return v_out; end if;
  begin
    v_def := app.apply_car_defaults(p_vehicle, p_by, p, false);
  exception when others then
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'car_defaults_failed', 'vehicles', p_vehicle::text, jsonb_build_object('error', sqlerrm));
    v_def := jsonb_build_object('error', sqlerrm);
  end;
  return v_out || jsonb_build_object('defaults', v_def);
end $$;

-- ================================================================ 4. privileges
do $$
declare
  f record;
  r record;
  g text;
  v_new regprocedure;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['next_fleet_number', 'vehicle_fleet_number', 'car_default_values', 'apply_car_defaults']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('set_rate_card_pre0087', 'set_rate_card'), ('vehicle_after_add_pre0087', 'vehicle_after_add')) m(old_name, new_name) on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;
grant usage on sequence vehicle_fleet_number_seq to service_role;

-- ================================================================ 5. the real cars on file
-- Fleet numbers in the order the cars were added (the sequence starts after the highest number of the range already
-- given), then a rate card for a car that has none. Nothing a person set is changed.
do $$
declare
  ps program_settings := app.settings();
  v_max bigint;
  r record;
begin
  select max(nullif(regexp_replace(x.fleet_number, '\D', '', 'g'), '')::bigint) into v_max from vehicles x
   where not coalesce(x.is_sample, false) and x.fleet_number is not null
     and upper(x.fleet_number) like upper(coalesce(ps.fleet_number_prefix, '')) || '%'
     and length(regexp_replace(x.fleet_number, '\D', '', 'g')) between 1 and 12;
  perform setval('vehicle_fleet_number_seq', greatest(coalesce(v_max, 0), ps.fleet_number_first - 1, 1), coalesce(v_max, 0) >= ps.fleet_number_first);
  for r in select x.id from vehicles x where not coalesce(x.is_sample, false) order by x.created_seq loop
    perform app.apply_car_defaults(r.id, null, '{}'::jsonb, true);
  end loop;
end $$;

-- ================================================================ 6. an owner account without a car
-- The owner's request of October 21, 2026 (docs/changes/2026-10-21-owner-account-only.md): a car owner can open an
-- owner account without a car. The owner details and the password alone create the sign-in, the owner record and an
-- application "Account only: no car yet" (no per-car intake tasks); one light To do task asks staff to follow up. The
-- owner lands in the owner portal with "Add your first car" (the same application, VIN-first). The first car the owner
-- adds closes the follow-up and is an ordinary application.

alter table owner_applications drop constraint if exists owner_applications_status_check;
alter table owner_applications add constraint owner_applications_status_check
  check (status = any (array['new', 'waiting_on_owner', 'approved', 'declined', 'account_only']));
comment on column owner_applications.status is 'new, waiting_on_owner, approved, declined, or account_only (0087: the owner opened an account with no car yet).';

-- The application in one call (0022), now also with no car: p.account_only true and no vehicles. Everything else
-- (the owner, a second press of Submit, someone applying for themselves only, the lead, the draft) is 0022's.
alter function app.submit_owner_application(jsonb, uuid) rename to submit_owner_application_pre0087;
create or replace function app.submit_owner_application(p jsonb, p_by uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid := nullif(p ->> 'owner_id', '')::uuid;
  v_app uuid := gen_random_uuid();
  v_number text;
  v_staff boolean := p_by is not null and (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet'));
  v_draft uuid := nullif(p ->> 'draft_id', '')::uuid;
  v_out jsonb;
  v_result jsonb;
  o owners;
begin
  if p is not null and coalesce(jsonb_array_length(case when jsonb_typeof(p -> 'vehicles') = 'array' then p -> 'vehicles' end), 0) > 0 then
    v_out := app.submit_owner_application_pre0087(p, p_by);
    -- the owner's first car: the follow-up of an account opened without one is done
    update tasks set status = 'done', completed_at = now(), completion_note = coalesce(completion_note, 'The owner added a car')
     where task_type = 'owner_signup_no_car' and owner_id = (v_out ->> 'owner_id')::uuid and status in ('open', 'in_progress', 'waiting');
    return v_out;
  end if;
  if p is null or not coalesce((p ->> 'account_only')::boolean, false) then
    raise exception 'An application needs at least one vehicle' using errcode = '22023';
  end if;
  if v_draft is not null and exists (select 1 from form_drafts f where f.id = v_draft and f.submitted_at is not null) then
    return (select f.result from form_drafts f where f.id = v_draft);   -- a second press of "Submit"
  end if;
  if p_by is not null and not v_staff then
    if v_owner is null then
      select x.id into v_owner from owners x where x.user_id = p_by order by x.created_at limit 1;
    elsif not exists (select 1 from owners x where x.id = v_owner and x.user_id = p_by) then
      raise exception 'Not permitted: an owner opens only their own account' using errcode = '42501';
    end if;
    p := jsonb_set(p, '{owner}', coalesce(p -> 'owner', '{}'::jsonb) || jsonb_build_object('user_id', p_by));
  end if;
  v_owner := app.save_application_owner(v_owner, p -> 'owner', p_by);
  select * into o from owners where id = v_owner;

  -- one account-only application per owner while they have no car
  select a.id, a.application_number into v_app, v_number from owner_applications a where a.owner_id = v_owner and a.status = 'account_only' limit 1;
  if v_number is null then
    v_app := gen_random_uuid();
    insert into owner_applications (id, owner_id, lead_id, form_draft_id, source, submitted_by, note, status, vehicle_count)
    values (v_app, v_owner, nullif(p ->> 'lead_id', '')::uuid, v_draft,
            coalesce(nullif(p ->> 'source', ''), case when v_staff then 'staff' else 'web' end), p_by, nullif(p ->> 'note', ''), 'account_only', 0)
    returning application_number into v_number;
  end if;
  if not exists (select 1 from vehicles v where v.owner_id = v_owner) then
    perform app.raise_task(p_type => 'owner_signup_no_car', p_queue => 'admin',
        p_title => format('New owner signed up without a car: follow up with %s', o.legal_name),
        p_detail => format('%s opened an owner account with no car yet (application %s). Call or email to help them add their first car.', o.legal_name, v_number),
        p_owner => v_owner, p_related_table => 'owner_applications', p_related_id => v_app, p_priority => 'normal', p_created_by => p_by,
        p_dedupe => 'owner_signup_no_car:' || v_owner);
  end if;
  if nullif(p ->> 'lead_id', '') is not null then
    update leads set status = 'converted', owner_id = v_owner where id = (p ->> 'lead_id')::uuid;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'owner_account_only', 'owner_applications', v_app::text, jsonb_build_object('owner_id', v_owner, 'application_number', v_number));
  v_result := jsonb_build_object('application_id', v_app, 'application_number', v_number, 'owner_id', v_owner, 'account_only', true,
                                 'owner_missing', to_jsonb(app.owner_missing_fields(v_owner)), 'vehicles', '[]'::jsonb);
  if v_draft is not null then perform app.submit_form_draft(v_draft, v_result); end if;
  return v_result;
end $$;

-- The applications inbox (0054) with the account-only ones: "Account only: no car yet" while the owner has no car.
create or replace function app.applications_list(p_admin uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  return (select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'application_number', a.application_number, 'status', a.status, 'created_at', a.created_at,
              'owner', o.legal_name, 'email', o.email, 'owner_type', o.owner_type, 'is_test', o.is_test, 'source', a.source,
              'vehicles', (select coalesce(jsonb_agg(app.vehicle_name(v.id) order by v.created_at), '[]'::jsonb) from vehicles v where v.owner_id = o.id),
              'checks_done', (select count(*) from jsonb_each(a.checks) c where c.value ->> 'status' in ('ok', 'not_needed')),
              'requested_at', a.requested_at, 'owner_replied_at', a.owner_replied_at) order by a.created_at desc)
             from owner_applications a join owners o on o.id = a.owner_id
            where coalesce(nullif(p ->> 'status', ''), a.status) = a.status
              and (a.status <> 'account_only' or not exists (select 1 from vehicles v where v.owner_id = o.id))), '[]'::jsonb),
    'counts', (select jsonb_object_agg(s, (select count(*) from owner_applications x where x.status = s
                                                 and (s <> 'account_only' or not exists (select 1 from vehicles v where v.owner_id = x.owner_id))))
                 from unnest(array['new', 'waiting_on_owner', 'approved', 'declined', 'account_only']) s)));
end $$;

revoke all on function app.submit_owner_application(jsonb, uuid), app.submit_owner_application_pre0087(jsonb, uuid) from public, anon, authenticated;
do $$
declare
  g text;
begin
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.submit_owner_application_pre0087(jsonb, uuid)'::regprocedure, 'execute') then
      execute format('grant execute on function app.submit_owner_application(jsonb, uuid) to %I', g);
    end if;
  end loop;
end $$;
