-- 5212 (R51, REQ-141): the plate is asked after the car is registered, not at the owner application. The owner (Nov 27
-- 23:40): "U ask owners for their plate when the plate gets registered after the owners apply. It's a broken process".
--   1. app.plate_missing: no real plate on file (empty, only X characters such as XXXXXXXX, only zeros, or a placeholder
--      word: TBD, TBA, NA, NONE, NOPLATE, PENDING, UNKNOWN, TEMP). web/src/features/vehicles/plate.ts is the same rule.
--   2. The application never asks the plate: the fleet supplier route (app.submit_owner_application_pre3800, from 0710)
--      and the VIN list (app.owner_add_vins, 3800) no longer refuse a car without one. The standard route never did in
--      the database (the web form did).
--   3. A car with us without its plate (not a partner's car, not a sample, not retired or gone): the owner gets the
--      email owner_plate_needed once per car (email first, no text), the owner portal shows the step "Add the plate"
--      (web, steps.ts), and Fleet gets the To do "Plate needed". Adding the plate closes the To do by itself.
--   4. The owner adds it (ops_do vehicle_plate_set, own car, only while it is missing); Fleet, customer service and the
--      Admins add or correct it on the car page (the same call).
--   5. No car without its plate is published (vehicle_listings to published refused; listing_auto_publish says why) or
--      handed over (bookings to on_rent refused; the pickup checklist lists it; an override cannot skip it).
--   6. The cars already on file without a plate get the To do now; the owners of cars still onboarding get the email.
-- No applied migration is edited: the functions are patched in place (the patch refuses when the text is not found) or
-- wrapped (_pre5212).
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '5212: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. a missing plate
create function app.plate_missing(p text) returns boolean
language sql immutable set search_path = public, app, pg_temp as $$
  select coalesce(app.norm_plate(p), '') ~ '^(X+|0+|TBD|TBA|NA|NONE|NOPLATE|PENDING|UNKNOWN|TEMP)?$'
$$;
comment on function app.plate_missing(text) is 'No real plate (5212, REQ-141): empty, only X characters (XXXXXXXX), only zeros or a placeholder word. Same rule: web/src/features/vehicles/plate.ts.';

-- a car with us that needs its plate now
create function app.plate_needed(v vehicles) returns boolean
language sql stable set search_path = public, app, pg_temp as $$
  select app.plate_missing(v.plate) and not coalesce(v.is_sample, false) and v.retired_at is null
     and v.status::text not in ('exited', 'total_loss', 'declined') and coalesce(v.supply_type, '') <> 'partner'
     and not coalesce(v.id_pending, false)
$$;

-- why a car cannot be published or handed over yet (null: it has its plate)
create function app.plate_block(p_vehicle uuid, p_what text) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select format('Plate needed: add the plate of the %s before it is %s (on file: %s). Add it on the car page, or the owner adds it in their portal',
                app.vehicle_name(v.id), p_what, coalesce(nullif(btrim(v.plate), ''), 'none'))
    from vehicles v
   where v.id = p_vehicle and app.plate_missing(v.plate) and not coalesce(v.is_sample, false) and coalesce(v.supply_type, '') <> 'partner'
$$;

-- ================================================================ 2. the application never asks the plate
select pg_temp.patch_fn('app.submit_owner_application_pre3800(jsonb, uuid)'::regprocedure,
  $o$if nullif(btrim(coalesce(v ->> 'plate', '')), '') is null then raise exception 'Enter each car''s plate' using errcode = '22023'; end if;$o$,
  $n$-- 5212 (REQ-141): the plate is not asked here; the car gets the step "Add the plate" once it is registered$n$);
select pg_temp.patch_fn('app.owner_add_vins(uuid, jsonb)'::regprocedure,
  $o$
      elsif not coalesce((p ->> 'preview')::boolean, false) and v_plate is null then v_why := 'Enter its plate';$o$,
  $n$$n$);

-- ================================================================ 3. the step, the email and the To do
insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description)
values ('plate_needed', 'fleet', 'Plate needed', 'normal', 'none', null, null, null,
        'A car with no real plate on file (empty or a placeholder such as XXXXXXXX), often one applied for before it was registered: the owner adds it in their portal, or Fleet adds it on the car page. Until then it is not published or handed over')
on conflict (task_type) do nothing;

create function app.plate_step_sync(p_vehicle uuid, p_email boolean default true) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v vehicles;
  o owners;
  v_owner_car boolean;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return; end if;
  if app.plate_needed(v) then
    v_owner_car := v.supply_type = 'program_owner' and v.owner_id is not null;
    perform app.raise_task(p_type => 'plate_needed', p_title => 'Plate needed: ' || app.vehicle_name(v.id) || coalesce(' (' || v.fleet_number || ')', ''),
      p_detail => format('No real plate on file (%s). %sUntil it is added the car is not published or handed over.', coalesce(nullif(btrim(v.plate), ''), 'empty'),
                         case when v_owner_car then 'The owner is asked by email to add it in their portal once the car is registered; or add it on the car page. '
                              else 'Add it on the car page. ' end),
      p_vehicle => v.id, p_owner => v.owner_id, p_dedupe => 'plate_needed:' || v.id, p_queue => 'fleet');
    if p_email and v_owner_car then
      select * into o from owners where id = v.owner_id;
      if o.id is not null and nullif(btrim(coalesce(o.email, '')), '') is not null then
        perform app.ntf_emit('owner_plate_needed', 'owner', o.id, v.id::text, jsonb_build_object('owner_id', o.id, 'vehicle_id', v.id,
          'first_name', app.owner_first_name(o), 'vehicle_name', app.vehicle_name(v.id),
          'plate_url', rtrim(coalesce((app.settings()).notify_base_url, 'https://carmacars.ca'), '/') || '/owner/vehicles/' || v.id || '#plate'));
      end if;
    end if;
  else
    update tasks set status = 'done', completed_at = now(), completion_note = 'The plate was added'
     where vehicle_id = v.id and task_type = 'plate_needed' and status in ('open', 'in_progress', 'waiting');
  end if;
end $$;

create function app.plate_step_trg() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if app.plate_needed(new) or (tg_op = 'UPDATE' and app.plate_needed(old)) then perform app.plate_step_sync(new.id); end if;
  return null;
end $$;
create trigger vehicles_plate_step after insert or update of plate, status, retired_at, id_pending, is_sample, supply_type on vehicles
  for each row execute function app.plate_step_trg();

-- ================================================================ 4. adding the plate
create function app.vehicle_plate_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v vehicles;
  v_plate text := app.norm_plate(p ->> 'plate');
  v_staff boolean := app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet');
begin
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid for update;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  if not v_staff then
    if not exists (select 1 from owners o where o.id = v.owner_id and o.user_id = p_by) then
      raise exception 'Only the car''s owner, Fleet, customer service or an Admin adds its plate' using errcode = '42501';
    end if;
    if not app.plate_missing(v.plate) then
      raise exception 'This car has its plate (%). To change it, reply to our email or call us', v.plate using errcode = '23514';
    end if;
  end if;
  if v_plate is null or length(v_plate) not between 2 and 8 then
    raise exception 'Enter the plate as on the ownership permit: 2 to 8 letters and numbers' using errcode = '22023';
  end if;
  if app.plate_missing(v_plate) then raise exception 'Enter the real plate, as on the ownership permit, not a placeholder' using errcode = '22023'; end if;
  if exists (select 1 from vehicles x where app.norm_plate(x.plate) = v_plate and x.id <> v.id and x.retired_at is null
               and x.status not in ('exited', 'total_loss', 'declined')) then
    raise exception 'Plate % is on another car in the fleet', v_plate using errcode = '23505';
  end if;
  update vehicles set plate = v_plate where id = v.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'vehicle_plate_set', 'vehicles', v.id::text, jsonb_build_object('plate', v.plate), jsonb_build_object('plate', v_plate));
  return jsonb_build_object('vehicle_id', v.id, 'plate', v_plate);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5212;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_call in ('ops_do', 'va_do', 'admin_do') and p_name = 'vehicle_plate_set' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.vehicle_plate_set(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre5212(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5212(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 5. never published, never handed over
create function app.listing_plate_guard() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare m text;
begin
  if new.status = 'published' and (tg_op = 'INSERT' or old.status is distinct from 'published') then
    m := app.plate_block(new.vehicle_id, 'published');
    if m is not null then raise exception '%', m using errcode = '23514'; end if;
  end if;
  return new;
end $$;
create trigger listing_plate_guard before insert or update of status on vehicle_listings
  for each row execute function app.listing_plate_guard();

select pg_temp.patch_fn('app.listing_auto_publish(uuid, text)'::regprocedure,
  $o$  if v.id_pending then return jsonb_build_object('published', false, 'reason', 'VIN or plate needed'); end if;$o$,
  $n$  if v.id_pending then return jsonb_build_object('published', false, 'reason', 'VIN or plate needed'); end if;
  if app.plate_block(v.id, 'published') is not null then return jsonb_build_object('published', false, 'reason', 'Plate needed'); end if;$n$);

-- a handover: the car goes on rent (a rental entered as already out or a past trip is not a handover)
create function app.booking_plate_guard() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare m text;
begin
  if new.status = 'on_rent' and (tg_op = 'INSERT' or old.status is distinct from 'on_rent')
     and coalesce(new.added_mode, '') not in ('in_progress', 'past') and not coalesce(new.is_placeholder, false) then
    m := app.plate_block(new.vehicle_id, 'handed over');
    if m is not null then raise exception '%', m using errcode = '23514'; end if;
  end if;
  return new;
end $$;
create trigger a00_plate_before before insert or update of status on bookings
  for each row execute function app.booking_plate_guard();

-- the pickup checklist says it; an override cannot skip it
alter function app.override_label(text) rename to override_label_pre5212;
create function app.override_label(p_code text) returns text
language sql immutable as $$
  select case p_code when 'plate' then 'The car has no plate on file: add it on the car page (no override)' else app.override_label_pre5212(p_code) end
$$;
select pg_temp.copy_grants('app.override_label(text)'::regprocedure, 'app.override_label_pre5212(text)'::regprocedure);

alter function app.handover_blockers(uuid, uuid, text, jsonb) rename to handover_blockers_pre5212;
create function app.handover_blockers(p_by uuid, p_booking uuid, p_kind text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare v jsonb := app.handover_blockers_pre5212(p_by, p_booking, p_kind, p);
begin
  if p_kind = 'pickup' and app.plate_block((select vehicle_id from bookings where id = p_booking), 'handed over') is not null then
    v := v || jsonb_build_array(jsonb_build_object('code', 'plate', 'label', app.override_label('plate')));
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.handover_blockers(uuid, uuid, text, jsonb)'::regprocedure, 'app.handover_blockers_pre5212(uuid, uuid, text, jsonb)'::regprocedure);

alter function app.handover_override(uuid, jsonb) rename to handover_override_pre5212;
create function app.handover_override(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare m text;
begin
  if coalesce(p ->> 'kind', '') = 'pickup' then
    m := app.plate_block((select vehicle_id from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) limit 1), 'handed over');
    if m is not null then raise exception '%. A missing plate cannot be overridden', m using errcode = '23514'; end if;
  end if;
  return app.handover_override_pre5212(p_by, p);
end $$;
select pg_temp.copy_grants('app.handover_override(uuid, jsonb)'::regprocedure, 'app.handover_override_pre5212(uuid, jsonb)'::regprocedure);

-- ================================================================ the email of 3 (owner_plate_needed)
-- CATALOGUE 5212 START (generated by supabase/seed/5212_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('owner_plate_needed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Add the plate of your {{vehicle_name}}', 'Once the car is registered, add its plate in your portal. About a minute.', 'Immediate', 'The plate after registration (R51, migration 5212, REQ-141): an owner''s car is with CarmaCars without a real plate on file (empty or a placeholder such as XXXXXXXX), for example a car applied for before it was registered. The application never asks the plate. Once per car; Fleet gets the To do "Plate needed" at the same moment.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"plate_url","type":"url"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_plate_needed.html', 'templates/owner_plate_needed.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 5212 END
update notification_catalogue set emitted_by = 'app.plate_step_sync (5212): an owner''s car with no real plate on file, once per car',
  no_text = true   -- email first (the owner: "go by email ... it's cheaper than text"); never a text
 where code = 'owner_plate_needed';

-- ================================================================ 6. the cars already on file
do $$
declare r record;
begin
  for r in select v.id, v.status from vehicles v where app.plate_needed(v) loop
    perform app.plate_step_sync(r.id, r.status::text in ('onboarding', 'ready_to_list'));
  end loop;
end $$;

-- ================================================================ privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('plate_missing', 'plate_needed', 'plate_block', 'plate_step_sync', 'plate_step_trg', 'vehicle_plate_set',
                    'listing_plate_guard', 'booking_plate_guard', 'door_pre5212', 'override_label_pre5212', 'handover_blockers_pre5212', 'handover_override_pre5212') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
