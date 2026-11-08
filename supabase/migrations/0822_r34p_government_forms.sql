-- 0822: the government (ServiceOntario) registration forms are made by themselves, and easy to find (Release 34, part P;
-- docs/changes/2026-11-08-r34-owner-onboarding.md). No applied migration is edited.
--
-- What was checked: the forms a car needs (app.vehicle_registry_forms, by its Onboarding Method, who holds it and the
-- owner's situation) were filled by app.fill_vehicle_government_forms at three places only: an Admin setting or
-- approving terms (0029's admin_set_vehicle_terms / admin_approve_vehicle_terms, used by the application's Approve and
-- by Add a car for an owner) and the fleet supplier's car (0710). The gaps:
--   a. a car's method changed on the owner's Terms tab before signing (app.car_terms_change calls app.set_vehicle_terms
--      itself): the car kept the forms of its old method;
--   b. a form made while a value was missing (a RIN, the odometer, the owner's address) stayed a draft listing it after
--      the owner or staff added the value: nothing filled it again;
--   c. app.fill_vehicle_government_forms stopped at the first form already signed or filed (an Admin re-approving terms
--      after the owner signed one form in ink got an error, and the other forms were not filled).
-- The fix: app.registry_forms_refresh makes every form a car needs, now, skipping one signed or filed (kept) and one
-- printed (the owner has it on paper; "Make again" replaces it). It runs by itself at the end of any transaction that
-- changes what the forms say (deferred triggers on vehicle_schedules, vehicle_onboardings, vehicles and owners), once
-- per car, after the explicit fills (a form already made in the same transaction is not made twice), and never stops
-- the change itself (a failure is written to audit_log). A car's forms are made once its terms are set (a current
-- Vehicle Schedule) or, for a fleet supplier, when the car is added; never for a car declined, withdrawn or gone.
-- The reads: app.government_forms_list (the owner, an Admin, customer service, fleet), app.government_form_fill_read
-- (one form, for the staff download), and app.government_forms_make_again (Admin).
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

create function app.registry_forms_due(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
                  where v.id = p_vehicle and v.status not in ('declined', 'exited', 'total_loss') and ob.status not in ('declined', 'withdrawn')
                    and v.supply_type = 'program_owner'
                    and (exists (select 1 from vehicle_schedules s where s.vehicle_id = v.id and s.superseded_by is null and s.withdrawn_at is null)
                         or app.vehicle_fleet_supplier(v.id))) $$;

create function app.registry_forms_refresh(p_vehicle uuid, p_by uuid default null, p_force boolean default false) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_forms text[];
  f text;
  cur government_form_fills;
  v_out jsonb := '[]'::jsonb;
  v_made integer := 0;
  v_id uuid;
begin
  if not app.registry_forms_due(p_vehicle) then return jsonb_build_object('due', false, 'made', 0, 'forms', v_out); end if;
  v_forms := coalesce(app.vehicle_registry_forms(p_vehicle), '{}');
  update vehicle_onboardings ob set government_forms = v_forms where ob.vehicle_id = p_vehicle and ob.government_forms is distinct from v_forms;
  update government_form_fills g set superseded_at = now()
   where g.vehicle_id = p_vehicle and g.superseded_at is null and g.status not in ('signed', 'filed') and not (g.form_code = any (v_forms));
  foreach f in array v_forms loop
    select * into cur from government_form_fills g where g.vehicle_id = p_vehicle and g.form_code = f and g.superseded_at is null;
    if cur.status in ('signed', 'filed') then
      v_out := v_out || jsonb_build_array(jsonb_build_object('form_code', f, 'status', cur.status, 'made', false, 'why', 'kept: ' || cur.status));
    elsif not p_force and cur.status = 'printed' then
      v_out := v_out || jsonb_build_array(jsonb_build_object('form_code', f, 'status', cur.status, 'made', false, 'why', 'kept: printed'));
    elsif not p_force and cur.id is not null and cur.generated_at = now() then
      v_out := v_out || jsonb_build_array(jsonb_build_object('form_code', f, 'status', cur.status, 'made', false, 'why', 'made in this change'));
    elsif not exists (select 1 from pdf_templates t where t.form_code = f and t.is_current) then
      v_out := v_out || jsonb_build_array(jsonb_build_object('form_code', f, 'status', null, 'made', false, 'why', 'no template'));
    else
      v_id := app.fill_government_form(p_vehicle, f, p_by);
      -- a change that does not alter what this form says (a status, a choice, another field) keeps the form as it is:
      -- the new fill is dropped and the current one stays, so a car's forms are not made again on every change
      if not p_force and cur.id is not null and cur.status in ('draft', 'ready')
         and exists (select 1 from government_form_fills g where g.id = v_id and g.pdf_template_id = cur.pdf_template_id and g.mode = cur.mode
                       and g.field_values = cur.field_values and g.data_sheet = cur.data_sheet and g.missing = cur.missing and g.owner_id = cur.owner_id) then
        delete from government_form_fills g where g.id = v_id;
        update government_form_fills g set superseded_at = null where g.id = cur.id;
        v_out := v_out || jsonb_build_array(jsonb_build_object('form_code', f, 'status', cur.status, 'made', false, 'why', 'unchanged'));
        continue;
      end if;
      v_made := v_made + 1;
      v_out := v_out || jsonb_build_array((select jsonb_build_object('form_code', g.form_code, 'status', g.status, 'made', true, 'missing', to_jsonb(g.missing))
                                             from government_form_fills g where g.id = v_id));
    end if;
  end loop;
  return jsonb_build_object('due', true, 'made', v_made, 'forms', v_out);
end $$;

-- c. the explicit fill no longer stops at a signed or filed form: the others are filled
alter function app.fill_vehicle_government_forms(uuid, uuid) rename to fill_vehicle_government_forms_pre0822;
create function app.fill_vehicle_government_forms(p_vehicle uuid, p_by uuid default null)
returns table (form_code text, fill_id uuid, status text, mode text, missing text[])
language plpgsql security definer set search_path = public, app as $$
begin
  if not exists (select 1 from vehicle_onboardings ob where ob.vehicle_id = p_vehicle) then
    raise exception 'This vehicle has no onboarding record' using errcode = 'P0002';
  end if;
  if exists (select 1 from government_form_fills g where g.vehicle_id = p_vehicle and g.superseded_at is null and g.status in ('signed', 'filed')) then
    perform app.registry_forms_refresh(p_vehicle, p_by, true);
    return query select g.form_code, g.id, g.status, g.mode, g.missing from government_form_fills g
                  where g.vehicle_id = p_vehicle and g.superseded_at is null
                    and g.form_code = any (coalesce((select ob.government_forms from vehicle_onboardings ob where ob.vehicle_id = p_vehicle), '{}'));
    return;
  end if;
  return query select * from app.fill_vehicle_government_forms_pre0822(p_vehicle, p_by);
end $$;
select pg_temp.copy_grants('app.fill_vehicle_government_forms(uuid, uuid)'::regprocedure, 'app.fill_vehicle_government_forms_pre0822(uuid, uuid)'::regprocedure);

-- ================================================================ the forms made by themselves
-- one refresh per car per transaction, at the end of it, never stopping it
create function app.registry_forms_after(p_vehicle uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_done text := coalesce(current_setting('app.registry_forms_done', true), '');
begin
  if p_vehicle is null or position(p_vehicle::text in v_done) > 0 then return; end if;
  perform set_config('app.registry_forms_done', v_done || ',' || p_vehicle::text, true);
  if not exists (select 1 from vehicle_onboardings ob where ob.vehicle_id = p_vehicle) then return; end if;
  begin
    perform app.registry_forms_refresh(p_vehicle, null, false);
  exception when others then
    insert into audit_log (action, entity_table, entity_id, after)
    values ('registry_forms_refresh_failed', 'vehicles', p_vehicle::text, jsonb_build_object('error', sqlerrm));
  end;
end $$;

create function app.registry_forms_on_change() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare r record;
begin
  if tg_table_name = 'owners' then
    for r in select v.id from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
              where v.owner_id = new.id and v.status not in ('declined', 'exited', 'total_loss') loop
      perform app.registry_forms_after(r.id);
    end loop;
  elsif tg_table_name = 'vehicles' then
    perform app.registry_forms_after(new.id);
  else
    perform app.registry_forms_after(new.vehicle_id);
  end if;
  return null;
end $$;

create constraint trigger registry_forms_schedule_new after insert on vehicle_schedules deferrable initially deferred
  for each row execute function app.registry_forms_on_change();
create constraint trigger registry_forms_schedule_change after update on vehicle_schedules deferrable initially deferred
  for each row when ((old.management_mode, old.onboarding_method, old.held_by, old.title_status, old.finance_party_name, old.owners_lien, old.superseded_by, old.withdrawn_at, old.odometer_km)
                     is distinct from (new.management_mode, new.onboarding_method, new.held_by, new.title_status, new.finance_party_name, new.owners_lien, new.superseded_by, new.withdrawn_at, new.odometer_km))
  execute function app.registry_forms_on_change();
create constraint trigger registry_forms_onboarding_change after update on vehicle_onboardings deferrable initially deferred
  for each row when ((to_jsonb(old) - array['government_forms', 'checklist_marks', 'updated_at']) is distinct from (to_jsonb(new) - array['government_forms', 'checklist_marks', 'updated_at']))
  execute function app.registry_forms_on_change();
create constraint trigger registry_forms_vehicle_change after update on vehicles deferrable initially deferred
  for each row when ((old.vin, old.plate, old.year, old.make, old.model, old.colour, old.body_type, old.odometer_km, old.owner_id, old.management_mode, old.onboarding_method, old.status, old.supply_type)
                     is distinct from (new.vin, new.plate, new.year, new.make, new.model, new.colour, new.body_type, new.odometer_km, new.owner_id, new.management_mode, new.onboarding_method, new.status, new.supply_type))
  execute function app.registry_forms_on_change();
create constraint trigger registry_forms_owner_change after update on owners deferrable initially deferred
  for each row when ((to_jsonb(old) - array['updated_at', 'last_seen_at']) is distinct from (to_jsonb(new) - array['updated_at', 'last_seen_at']))
  execute function app.registry_forms_on_change();

-- ================================================================ the reads and Make again
create function app.government_forms_can(p_by uuid, p_owner uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_by is not null and (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet') or app.user_is_owner_of(p_by, p_owner)) $$;

-- every car of an owner (or one car): the forms it needs, each made one with its status, what is missing and when it was made
create function app.government_forms_list(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(p ->> 'vehicle_id', '')::uuid;
  v_owner uuid := nullif(p ->> 'owner_id', '')::uuid;
begin
  if v_vehicle is not null then select owner_id into v_owner from vehicles where id = v_vehicle; end if;
  if v_owner is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  if not app.government_forms_can(p_by, v_owner) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return jsonb_build_object('owner_id', v_owner, 'admin', app.user_is_admin(p_by), 'cars', (select coalesce(jsonb_agg(jsonb_build_object(
      'vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'due', app.registry_forms_due(v.id),
      'turo_only', v.management_mode = 'turo_only',
      'method', coalesce((select s.onboarding_method::text from vehicle_schedules s where s.vehicle_id = v.id and s.superseded_by is null), ob.proposed_onboarding_method::text),
      'needed', to_jsonb(coalesce(case when app.registry_forms_due(v.id) then ob.government_forms end, '{}')),
      'forms', (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'form_code', g.form_code, 'title', t.title, 'status', g.status, 'mode', g.mode,
                  'missing', to_jsonb(g.missing), 'generated_at', g.generated_at, 'official', g.mode = 'pdf' and t.file_key is not null,
                  'by', case when g.generated_by is null then 'automatic' else (select coalesce(u.full_name, 'CarmaCars') from users u where u.id = g.generated_by) end,
                  'signed_document_id', g.document_id) order by g.form_code), '[]'::jsonb)
                  from government_form_fills g join pdf_templates t on t.id = g.pdf_template_id
                 where g.vehicle_id = v.id and g.superseded_at is null))
      order by v.created_at, v.id), '[]'::jsonb)
    from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
   where v.owner_id = v_owner and (v_vehicle is null or v.id = v_vehicle) and v.status not in ('declined')));
end $$;

-- one form for the staff download (the data sheet, or the official PDF filled in the browser)
create function app.government_form_fill_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare g government_form_fills;
begin
  select * into g from government_form_fills where id = nullif(p ->> 'fill', '')::uuid;
  if g.id is null or not app.government_forms_can(p_by, g.owner_id) then return null; end if;
  return (select jsonb_build_object('id', g.id, 'form_code', g.form_code, 'title', t.title, 'vehicle_id', g.vehicle_id, 'vehicle_name', app.vehicle_name(g.vehicle_id),
            'owner_id', g.owner_id, 'owner_name', (select o.legal_name from owners o where o.id = g.owner_id), 'status', g.status, 'mode', g.mode,
            'missing', to_jsonb(g.missing), 'data_sheet', g.data_sheet, 'generated_at', g.generated_at, 'current', g.superseded_at is null,
            'official', g.mode = 'pdf' and t.file_key is not null, 'file_key', case when g.mode = 'pdf' then t.file_key end,
            'field_values', g.field_values, 'field_map', t.field_map, 'signed_document_id', g.document_id)
    from pdf_templates t where t.id = g.pdf_template_id);
end $$;

create function app.government_forms_make_again(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  r jsonb;
begin
  perform app.assert_admin(p_by);
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  if not app.registry_forms_due(v.id) then
    raise exception 'This car''s government forms are made once its terms are set (Approve on the application)' using errcode = '23514';
  end if;
  r := app.registry_forms_refresh(v.id, p_by, true);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'government_forms_make_again', 'vehicles', v.id::text, r);
  return r;
end $$;

-- the cars whose forms were never made though due (a template uploaded since, an earlier gap): made once now
do $$
declare r record;
begin
  for r in select v.id from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
            where app.registry_forms_due(v.id)
              and (exists (select 1 from unnest(coalesce(app.vehicle_registry_forms(v.id), '{}')) f
                           where not exists (select 1 from government_form_fills g where g.vehicle_id = v.id and g.form_code = f and g.superseded_at is null)
                             and exists (select 1 from pdf_templates t where t.form_code = f and t.is_current))
                   or exists (select 1 from government_form_fills g where g.vehicle_id = v.id and g.superseded_at is null and g.status = 'draft')) loop
    begin
      perform app.registry_forms_refresh(r.id, null, false);
    exception when others then
      insert into audit_log (action, entity_table, entity_id, after) values ('registry_forms_refresh_failed', 'vehicles', r.id::text, jsonb_build_object('error', sqlerrm));
    end;
  end loop;
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['registry_forms_due', 'registry_forms_refresh', 'fill_vehicle_government_forms_pre0822',
              'registry_forms_after', 'registry_forms_on_change', 'government_forms_can', 'government_forms_list', 'government_form_fill_read', 'government_forms_make_again'])
  loop execute format('revoke all on function %s from public, anon, authenticated', f.sig); end loop;
end $$;
