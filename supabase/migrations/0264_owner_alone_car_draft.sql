-- 0264: an owner added on their own, and a car added before its VIN or plate is known (the owner, Release 24b).
-- docs/changes/2026-11-04-owner-alone-car-draft.md.
--
-- 1. Owners > Add an owner: the name, email, phone, individual or corporation and the owner's default terms, without a
--    car (app.owner_add; an Admin, customer service or fleet; terms by an Admin). Nothing is emailed: the owner is
--    invited only when staff choose Invite (the existing invitation, from the server). Listed on Owners at once.
-- 2. Add a car for an owner takes a car with only its year, make and model (trim, colour, odometer and notes if known)
--    when neither the VIN nor the plate is known yet: saved as an onboarding draft with its fleet number
--    (vehicles.id_pending). Until a VIN or plate is added it is never listed, never bookable and not put on the fleet
--    policy (the database refuses each, with "VIN or plate needed"); the car page and To do say so (a task closed by
--    itself once the VIN or plate is on file).
-- 3. vehicles.notes: free notes on a car, on the add-car form and the car page.
-- No applied migration is edited.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0264: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. an owner on their own
alter table owners add column if not exists added_alone_at timestamptz;
alter table owners add column if not exists added_alone_by uuid references users (id) on delete set null;
comment on column owners.added_alone_at is 'Added by staff on their own, without a car (0264): listed on Owners; nothing emailed until invited.';

create or replace function app.owner_add(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_name text := nullif(btrim(coalesce(p ->> 'legal_name', '')), '');
  v_email text := lower(nullif(btrim(coalesce(p ->> 'email', '')), ''));
  v_phone text := nullif(btrim(coalesce(p ->> 'phone', '')), '');
  v_type text := coalesce(nullif(p ->> 'owner_type', ''), 'individual');
  v_corp text := nullif(btrim(coalesce(p ->> 'corporation_name', '')), '');
  v_terms jsonb := coalesce(p -> 'terms', '{}'::jsonb);
  v_has_terms boolean;
  v_dup owners;
  v_id uuid;
  v_saved jsonb;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then
    raise exception 'Only an Admin, customer service or fleet adds an owner' using errcode = '42501';
  end if;
  if v_name is null then raise exception 'Enter the owner''s full legal name' using errcode = '22023'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Check the email address' using errcode = '22023'; end if;
  if v_email is null and v_phone is null then raise exception 'Enter the owner''s email or phone' using errcode = '22023'; end if;
  if v_type not in ('individual', 'corporation') then raise exception 'Choose individual or corporation' using errcode = '22023'; end if;
  if v_type = 'corporation' and v_corp is null then raise exception 'Enter the corporation''s name' using errcode = '22023'; end if;
  if v_email is not null then
    select * into v_dup from owners where lower(email) = v_email limit 1;
    if v_dup.id is not null then raise exception 'An owner with this email is on file: %', v_dup.legal_name using errcode = '23505'; end if;
  end if;
  v_has_terms := exists (select 1 from jsonb_each_text(v_terms) e where e.key in ('insurance_fee_cents', 'tracker_fee_cents', 'revenue_share_bps', 'install_fee_cents', 'first_last_cents')
                          and nullif(btrim(e.value), '') is not null);
  if v_has_terms and not app.user_is_admin(p_by) then raise exception 'Only an Admin sets an owner''s terms' using errcode = '42501'; end if;
  insert into owners (owner_type, legal_name, corporation_name, email, phone, status, kind, recruited_by, added_alone_at, added_alone_by)
  values (v_type::owner_type, v_name, case when v_type = 'corporation' then v_corp end, v_email, v_phone, 'lead', 'program',
          case when coalesce((p ->> 'sourced')::boolean, false) then p_by end, now(), p_by)
  returning id into v_id;
  if v_has_terms then
    v_saved := app.owner_terms_save(p_by, (select jsonb_object_agg(e.key, e.value) from jsonb_each(v_terms) e where jsonb_typeof(e.value) <> 'null' and e.value::text <> '""')
                                         || jsonb_build_object('owner_id', v_id));
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'owner_add', 'owners', v_id::text, jsonb_build_object('legal_name', v_name, 'email', v_email, 'owner_type', v_type, 'terms', v_has_terms));
  return jsonb_build_object('owner_id', v_id, 'legal_name', v_name, 'email', v_email, 'terms', v_saved);
end $$;

-- Owners lists them (the list was of owners with an application)
select pg_temp.patch_fn('app.admin_owner_applications(uuid)'::regprocedure,
  $o$from owners o where exists (select 1 from owner_applications a where a.owner_id = o.id)) q);$o$,
  $n$from owners o where exists (select 1 from owner_applications a where a.owner_id = o.id) or o.added_alone_at is not null) q);$n$);
select pg_temp.patch_fn('app.admin_owner_applications(uuid)'::regprocedure,
  $o$'last_at', (select max(a.created_at) from owner_applications a where a.owner_id = o.id),$o$,
  $n$'last_at', coalesce((select max(a.created_at) from owner_applications a where a.owner_id = o.id), o.added_alone_at),$n$);

-- ================================================================ 2. a car before its VIN or plate
alter table vehicles add column if not exists id_pending boolean not null default false;
alter table vehicles add column if not exists notes text check (notes is null or length(notes) <= 4000);
comment on column vehicles.id_pending is 'Added before its VIN or plate was known (0264): an onboarding draft, never listed, bookable or on the fleet policy until one is added.';
comment on column vehicles.notes is 'Free notes on the car (0264), from the add-car form and the car page.';
alter table vehicles drop constraint if exists vehicles_plate_or_vin;
alter table vehicles add constraint vehicles_plate_or_vin check (vin is not null or nullif(btrim(plate), '') is not null or supply_type = 'partner' or id_pending);

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description)
values ('vehicle_id_needed', 'fleet', 'VIN or plate needed', 'normal', 'none', null, null, null,
        'A car added before its VIN or plate was known: add one so it can be listed, booked and insured')
on conflict (task_type) do nothing;

-- the draft is marked when there is neither; the VIN or plate added clears it and closes the task
create or replace function app.vehicle_id_pending_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.vin is null and nullif(btrim(coalesce(new.plate, '')), '') is null and coalesce(new.supply_type::text, '') <> 'partner' then
    -- a new car without either is a draft; a car that had one keeps needing one (the check vehicles_plate_or_vin refuses)
    if tg_op = 'INSERT' then new.id_pending := true; end if;
  else
    new.id_pending := false;
  end if;
  if new.id_pending then
    -- the steps that move a car on by themselves (an application approved: ready to list) wait for the VIN or plate
    if new.status::text = 'ready_to_list' then new.status := 'onboarding'; end if;
    if new.status::text not in ('onboarding', 'declined', 'exited') then
      raise exception 'VIN or plate needed: add the VIN or the plate before the car is %', replace(new.status::text, '_', ' ') using errcode = '23514';
    end if;
    if new.on_fleet_policy then raise exception 'VIN or plate needed: a car goes on the fleet policy with its VIN or plate' using errcode = '23514'; end if;
  end if;
  return new;
end $$;
drop trigger if exists a01_vehicle_id_pending on vehicles;
create trigger a01_vehicle_id_pending before insert or update of vin, plate, status, on_fleet_policy, id_pending on vehicles
  for each row execute function app.vehicle_id_pending_before();

create or replace function app.vehicle_id_pending_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.id_pending and (tg_op = 'INSERT' or not old.id_pending) then
    perform app.raise_task(p_type => 'vehicle_id_needed', p_title => 'VIN or plate needed: ' || app.vehicle_name(new.id) || coalesce(' (' || new.fleet_number || ')', ''),
      p_detail => 'Added before its VIN or plate was known. Add the VIN (on the ownership permit and the driver''s door frame) or the plate on the car page: until then it is not listed, not bookable and not put on the fleet policy.',
      p_vehicle => new.id, p_owner => new.owner_id, p_dedupe => 'vehicle_id_needed:' || new.id, p_queue => 'fleet');
  elsif tg_op = 'UPDATE' and old.id_pending and not new.id_pending then
    update tasks set status = 'done', completed_at = now(), completion_note = 'The VIN or plate was added'
     where vehicle_id = new.id and task_type = 'vehicle_id_needed' and status in ('open', 'in_progress', 'waiting');
  end if;
  return null;
end $$;
drop trigger if exists vehicle_id_pending_after on vehicles;
create trigger vehicle_id_pending_after after insert or update of vin, plate, id_pending on vehicles
  for each row execute function app.vehicle_id_pending_after();

-- never listed
select pg_temp.patch_fn('app.listing_auto_publish(uuid, text)'::regprocedure,
  $o$  if v.id is null or coalesce(v.is_sample, false) then return jsonb_build_object('published', false, 'reason', 'not a real car'); end if;$o$,
  $n$  if v.id is null or coalesce(v.is_sample, false) then return jsonb_build_object('published', false, 'reason', 'not a real car'); end if;
  if v.id_pending then return jsonb_build_object('published', false, 'reason', 'VIN or plate needed'); end if;$n$);
create or replace function app.listing_id_pending_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'published' and (tg_op = 'INSERT' or old.status is distinct from 'published')
     and exists (select 1 from vehicles v where v.id = new.vehicle_id and v.id_pending) then
    raise exception 'VIN or plate needed: add the VIN or the plate before the car is listed' using errcode = '23514';
  end if;
  return new;
end $$;
drop trigger if exists listing_id_pending_guard on vehicle_listings;
create trigger listing_id_pending_guard before insert or update of status on vehicle_listings
  for each row execute function app.listing_id_pending_guard();

-- never bookable
create or replace function app.booking_id_pending_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if (tg_op = 'INSERT' or new.vehicle_id is distinct from old.vehicle_id)
     and exists (select 1 from vehicles v where v.id = new.vehicle_id and v.id_pending) then
    raise exception 'VIN or plate needed: this car cannot be booked until its VIN or plate is added' using errcode = '23514';
  end if;
  return new;
end $$;
drop trigger if exists bookings_id_pending_guard on bookings;
create trigger bookings_id_pending_guard before insert or update of vehicle_id on bookings
  for each row execute function app.booking_id_pending_guard();

-- staff add the car without either (the owner's own application still gives the VIN)
select pg_temp.patch_fn('app.add_owner_vehicle_pre0082(uuid, jsonb, uuid, uuid)'::regprocedure,
  $o$  if v_vin is null and not (v_staff and v_plate is not null) then$o$,
  $n$  if v_vin is null and not (v_staff and (v_plate is not null or (nullif(p_v ->> 'year', '') is not null and nullif(btrim(coalesce(p_v ->> 'make', '')), '') is not null
                                                                    and nullif(btrim(coalesce(p_v ->> 'model', '')), '') is not null))) then$n$);
select pg_temp.patch_fn('app.add_owner_vehicle_pre0082(uuid, jsonb, uuid, uuid)'::regprocedure,
  $o$then 'Enter the plate or the 17-character VIN' else$o$,
  $n$then 'Enter the plate or the 17-character VIN, or the year, make and model when neither is known yet' else$n$);

-- the notes typed on the form
alter function app.add_owner_vehicle(uuid, jsonb, uuid, uuid) rename to add_owner_vehicle_pre0264;
create function app.add_owner_vehicle(p_owner uuid, p_v jsonb, p_by uuid default null, p_application uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.add_owner_vehicle_pre0264(p_owner, p_v, p_by, p_application);
  v_id uuid := nullif(v_out ->> 'vehicle_id', '')::uuid;
begin
  if v_id is not null and nullif(btrim(coalesce(p_v ->> 'notes', '')), '') is not null then
    update vehicles set notes = left(btrim(p_v ->> 'notes'), 4000) where id = v_id;
  end if;
  return v_out || jsonb_build_object('id_pending', coalesce((select id_pending from vehicles where id = v_id), false),
                                     'fleet_number', (select fleet_number from vehicles where id = v_id));
end $$;

-- ================================================================ 3. the notes on the car page
create or replace function app.vehicle_notes_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v vehicles;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then raise exception 'Only an Admin, customer service or fleet edits a car''s notes' using errcode = '42501'; end if;
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid for update;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  update vehicles set notes = nullif(left(btrim(coalesce(p ->> 'notes', '')), 4000), '') where id = v.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'vehicle_notes_set', 'vehicles', v.id::text, jsonb_build_object('notes', v.notes), jsonb_build_object('notes', nullif(btrim(coalesce(p ->> 'notes', '')), '')));
  return jsonb_build_object('vehicle_id', v.id, 'notes', (select notes from vehicles where id = v.id));
end $$;

-- the VIN or plate added on the car page (the draft becomes a car like any other)
create or replace function app.vehicle_id_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_vin text := app.clean_vin(p ->> 'vin');
  v_plate text := nullif(upper(regexp_replace(coalesce(p ->> 'plate', ''), '\s', '', 'g')), '');
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then raise exception 'Only an Admin, customer service or fleet adds the VIN or plate' using errcode = '42501'; end if;
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid for update;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  if v_vin is null and nullif(btrim(coalesce(p ->> 'vin', '')), '') is not null then raise exception 'The VIN has 17 characters (letters and digits, no I, O or Q)' using errcode = '22023'; end if;
  if v_vin is null and v_plate is null then raise exception 'Enter the VIN or the plate' using errcode = '22023'; end if;
  if v_vin is not null and exists (select 1 from vehicles x where upper(x.vin) = v_vin and x.id <> v.id) then raise exception 'This VIN is on another car in the fleet' using errcode = '23505'; end if;
  if v_plate is not null and exists (select 1 from vehicles x where app.norm_plate(x.plate) = app.norm_plate(v_plate) and x.id <> v.id and x.retired_at is null
                                        and x.status not in ('exited', 'total_loss', 'declined')) then
    raise exception 'Plate % is on another car in the fleet', v_plate using errcode = '23505';
  end if;
  update vehicles set vin = coalesce(v_vin, vin), plate = coalesce(v_plate, plate) where id = v.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'vehicle_id_set', 'vehicles', v.id::text, jsonb_build_object('vin', v.vin, 'plate', v.plate), jsonb_build_object('vin', v_vin, 'plate', v_plate));
  return jsonb_build_object('vehicle_id', v.id, 'id_pending', (select id_pending from vehicles where id = v.id));
end $$;

-- the door: ops_do (an Admin) and va_do (customer service, fleet)
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0264;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_do', 'admin_do', 'va_do') and p_name in ('owner_add', 'vehicle_notes_set', 'vehicle_id_set') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'owner_add' then app.owner_add(p_user, coalesce(p, '{}'::jsonb) - '_va')
                       when 'vehicle_notes_set' then app.vehicle_notes_set(p_user, coalesce(p, '{}'::jsonb) - '_va')
                       else app.vehicle_id_set(p_user, coalesce(p, '{}'::jsonb) - '_va') end;
  end if;
  return app.door_pre0264(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare g text; f record;
begin
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    execute format('revoke all on function app.door(uuid, text, text, text, jsonb) from %I', g);
    if has_function_privilege(g, 'app.door_pre0264(uuid, text, text, text, jsonb)', 'execute') then execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g); end if;
    execute format('revoke all on function app.add_owner_vehicle(uuid, jsonb, uuid, uuid) from %I', g);
    if has_function_privilege(g, 'app.add_owner_vehicle_pre0264(uuid, jsonb, uuid, uuid)', 'execute') then execute format('grant execute on function app.add_owner_vehicle(uuid, jsonb, uuid, uuid) to %I', g); end if;
  end loop;
  execute 'revoke all on function app.door(uuid, text, text, text, jsonb) from public';
  execute 'revoke all on function app.add_owner_vehicle(uuid, jsonb, uuid, uuid) from public';
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('owner_add', 'vehicle_id_pending_before', 'vehicle_id_pending_after', 'listing_id_pending_guard', 'booking_id_pending_guard',
                                                     'vehicle_notes_set', 'vehicle_id_set', 'door_pre0264', 'add_owner_vehicle_pre0264') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
