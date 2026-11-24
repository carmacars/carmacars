-- 3730 (release 50; docs/changes/2026-11-24-r50-connector-owner-cars.md): the Admin connector does what the Admin owner and
-- application pages do for an owner's cars, so Abbas is no longer sent to the portal.
--   1. approve_owner_car {application, cars?} (admin:write): approves an owner's application with each car's terms, through
--      the same app.application_approve as Approve on /admin/applications/<id> (the door's ops_do, as the key's Admin). A
--      fleet supplier's car goes on the fleet lease at the tier the supplier asked for, which makes the Fleet Supplier Lease
--      Agreement and the ServiceOntario forms for e-signing (0710). cars omitted: each car with the terms the page proposes
--      (app.application_approve_plan). The preview shows that plan and changes nothing.
--   2. fleet_lease_car_set {vehicle, tier, delivered_on?, reason?} (admin:write): puts a fleet supplier's car on the lease
--      (app.fleet_lease_car_set, its own preview mode for the preview), as Put on the lease on the owner's Fleet lease card.
--   3. owner_agreements {owner} (admin:read): the owner's agreements checklist, the government forms with their signing
--      status, and the fleet lease, each with its Admin link.
-- Every write is a preview, then a confirm with the same arguments and the preview_id (api_previews), logged in api_calls.
-- Security definer functions run with search_path public, app, pg_temp; the server role alone executes them. SCHEMA_MARKER
-- 3730. No applied migration is edited.
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

-- the cars to approve: as given, else each car of the plan with the terms the page proposes
create or replace function app.api_owner_approve_cars(p_plan jsonb, p_cars jsonb) returns jsonb
language sql stable set search_path = public, app, pg_temp as $$
  select case when jsonb_typeof(p_cars) = 'array' and jsonb_array_length(p_cars) > 0 then p_cars
    else coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('vehicle_id', x ->> 'vehicle_id', 'terms', x -> 'terms', 'invoices', coalesce(x -> 'invoices', '[]'::jsonb),
                                    'first_last', x -> 'first_last', 'delivered_on', x ->> 'delivered_on')))
                     from jsonb_array_elements(coalesce(p_plan -> 'cars', '[]'::jsonb)) x), '[]'::jsonb) end
$$;

alter function app.api_call(text, text, jsonb, text) rename to api_call_pre3730;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  v_write boolean := p_tool <> 'owner_agreements';
  chk jsonb;
  k api_keys;
  v_args jsonb;
  v_confirm boolean;
  pv api_previews;
  v_plan jsonb;
  v_cars jsonb;
  v_owner uuid;
  v_vehicle uuid;
  v_will jsonb;
  v_result jsonb;
  v_target text := left(coalesce(nullif(a ->> 'application', ''), nullif(a ->> 'vehicle', ''), nullif(a ->> 'owner', ''), p_tool), 200);
begin
  if p_tool not in ('approve_owner_car', 'fleet_lease_car_set', 'owner_agreements') then return app.api_call_pre3730(p_hash, p_tool, p_args, p_client); end if;
  chk := app.api_key_check(p_hash, case when v_write then 'admin:write' else 'admin:read' end, p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  v_confirm := coalesce((a ->> 'confirm')::boolean, false);
  v_args := a - 'confirm' - 'preview_id';
  begin
    perform app.assert_admin(k.user_id);
    if p_tool = 'owner_agreements' then
      select o.id into v_owner from owners o where o.id::text = coalesce(v_args ->> 'owner', '') or lower(o.email) = lower(btrim(coalesce(v_args ->> 'owner', '')));
      if v_owner is null then raise exception 'owner: the owner''s id or email' using errcode = 'P0002'; end if;
      v_result := jsonb_build_object('owner_id', v_owner, 'admin_path', '/admin/owners/' || v_owner,
        'agreements', app.owner_agreements_checklist(k.user_id, jsonb_build_object('owner', v_owner)),
        'government_forms', app.government_forms_list(k.user_id, jsonb_build_object('owner_id', v_owner)),
        'fleet_lease', case when app.fleet_supplier(v_owner) then app.fleet_lease_read(k.user_id, jsonb_build_object('owner', v_owner)) end);
    else
      -- the target and what the confirm would do (the same checks run again on the confirm)
      if p_tool = 'approve_owner_car' then
        if nullif(v_args ->> 'application', '') is null then raise exception 'application: the owner''s application id (the page /admin/applications/<id>)' using errcode = '22023'; end if;
        v_plan := app.application_approve_plan(k.user_id, jsonb_build_object('id', v_args ->> 'application'));
        if v_plan is null then raise exception 'Application not found' using errcode = 'P0002'; end if;
        if v_plan ->> 'status' = 'approved' then raise exception 'This application is approved already' using errcode = '23514'; end if;
        v_cars := app.api_owner_approve_cars(v_plan, v_args -> 'cars');
        if jsonb_array_length(v_cars) = 0 then raise exception 'This application has no car to approve' using errcode = '23514'; end if;
        v_will := jsonb_build_object('plan', v_plan, 'cars', v_cars,
          'will_do', case when coalesce((v_plan ->> 'fleet_supplier')::boolean, false)
            then format('Approve the application with %s car(s): each goes on the fleet lease at the tier the supplier asked for, and the Fleet Supplier Lease Agreement and the ServiceOntario forms are made for e-signing.', jsonb_array_length(v_cars))
            else format('Approve the application with %s car(s) and these terms, as Approve on the application page does (its first invoices are issued as the plan shows).', jsonb_array_length(v_cars)) end);
      else
        select v.id into v_vehicle from vehicles v where v.id::text = coalesce(v_args ->> 'vehicle', '') or upper(v.plate) = upper(btrim(coalesce(v_args ->> 'vehicle', '')));
        if v_vehicle is null then raise exception 'vehicle: the car''s id or plate' using errcode = 'P0002'; end if;
        v_will := app.fleet_lease_car_set(k.user_id, jsonb_build_object('vehicle_id', v_vehicle, 'tier', v_args ->> 'tier', 'delivered_on', v_args ->> 'delivered_on',
                                                                       'reason', v_args ->> 'reason', 'preview', true));
      end if;
      if not v_confirm then
        insert into api_previews (key_id, user_id, tool, args, before, after) values (k.id, k.user_id, p_tool, v_args, null, v_will) returning * into pv;
        v_result := jsonb_build_object('preview', true, 'preview_id', pv.id, 'tool', p_tool, 'expires_at', pv.created_at + interval '10 minutes') || v_will
          || jsonb_build_object('next', 'Nothing was changed. To do it, call this tool again with exactly the same arguments plus "confirm": true and "preview_id": "' || pv.id || '".');
      else
        select * into pv from api_previews where id = nullif(a ->> 'preview_id', '')::uuid for update;
        if pv.id is null or pv.key_id <> k.id or pv.tool <> p_tool then raise exception 'Preview first: call without confirm, then confirm with its preview_id' using errcode = '22023'; end if;
        if pv.used_at is not null then raise exception 'This preview was already used: preview again' using errcode = '22023'; end if;
        if pv.created_at < now() - interval '10 minutes' then raise exception 'This preview is more than 10 minutes old: preview again' using errcode = '22023'; end if;
        if pv.args is distinct from v_args then raise exception 'The arguments differ from the preview: preview again with these' using errcode = '22023'; end if;
        update api_previews set used_at = now() where id = pv.id;
        if p_tool = 'approve_owner_car' then
          -- the door's own path, as the key's Admin (its checks, the fleet lease and forms of 0710)
          -- a fleet supplier's cars take their lease from the application itself (0710): sent only when given
          v_result := app.door(k.user_id, 'aal2', 'ops_do', 'application_approve', jsonb_build_object('id', v_args ->> 'application')
            || case when jsonb_typeof(v_args -> 'cars') = 'array' or not coalesce((v_plan ->> 'fleet_supplier')::boolean, false) then jsonb_build_object('cars', v_cars) else '{}'::jsonb end);
          v_result := v_result || jsonb_build_object('done', true, 'run', 'owner_setup', 'application_id', v_args ->> 'application', 'actor', k.user_id);
        else
          v_result := app.door(k.user_id, 'aal2', 'ops_do', 'fleet_lease_car_set', jsonb_build_object('vehicle_id', v_vehicle, 'tier', v_args ->> 'tier',
                                                                       'delivered_on', v_args ->> 'delivered_on', 'reason', v_args ->> 'reason'))
                      || jsonb_build_object('done', true, 'vehicle_id', v_vehicle);
          perform app.fleet_supplier_car_forms(v_vehicle);
        end if;
      end if;
    end if;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, v_target, v_args, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, ok, client)
  values (k.id, k.user_id, case when v_write and not v_confirm then p_tool || ':preview' else p_tool end, v_target, v_args, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre3730(text, text, jsonb, text)'::regprocedure);

revoke all on function app.api_call_pre3730(text, text, jsonb, text), app.api_owner_approve_cars(jsonb, jsonb) from public, anon, authenticated;
grant execute on function app.api_call_pre3730(text, text, jsonb, text), app.api_owner_approve_cars(jsonb, jsonb) to service_role;
