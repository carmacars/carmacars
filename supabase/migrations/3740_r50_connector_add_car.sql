-- 3740 (release 50; docs/changes/2026-11-24-r50-connector-owner-cars.md): the Admin connector adds a car for an owner, as Admin
-- > Owners > Add a car for an owner does, so Abbas is not sent to the portal.
--   add_car {owner (id or email; the company fleet too), vin, year, make, model, trim, plate, odometer_km, colour, class,
--   title_status, finance_party_name, tier (a fleet supplier's car), terms} (admin:write, preview then confirm):
--     - the VIN is cleaned and its check digit checked (app.vin_check_ok), a car already with CarmaCars is refused, and
--       the year, make, model and trim come from the vPIC decode the website records (vin_decodes; the connector decodes
--       it before this call), each overridable;
--     - the confirm runs the door's staff_add_owner_car as the key's Admin, the path of the Add a car page: one owner
--       application, the car in onboarding with its photo jobs, the default rates (car_defaults_rates_on_add) and every
--       gate of that path. With terms (or for a fleet supplier, its lease at the tier) it is approved at once as the
--       page does; without terms it waits for the Admin's approval of its terms.
-- Security definer functions run with search_path public, app, pg_temp; the server role alone executes them. SCHEMA_MARKER
-- 3740. No applied migration is edited.
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

-- what add_car would send to staff_add_owner_car, checked: {owner_id, owner_name, vehicle, payload, decoded}
create or replace function app.api_add_car_plan(a jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  o owners;
  d vin_decodes;
  v_vin text := app.clean_vin(upper(regexp_replace(coalesce(a ->> 'vin', ''), '[\s-]', '', 'g')));
  v_taken text;
  v_fleet boolean;
  v_tier text := nullif(lower(btrim(coalesce(a ->> 'tier', ''))), '');
  v_title text := coalesce(nullif(a ->> 'title_status', ''), 'owned_outright');
  v_year integer;
  v_make text;
  v_model text;
  v_vehicle jsonb;
  v_terms boolean := jsonb_typeof(a -> 'terms') = 'object';
begin
  select * into o from owners where id::text = coalesce(a ->> 'owner', '') or (nullif(btrim(coalesce(a ->> 'owner', '')), '') is not null and lower(email) = lower(btrim(a ->> 'owner')));
  if o.id is null then raise exception 'owner: the owner''s id or email (the company fleet: its owner id)' using errcode = 'P0002'; end if;
  if v_vin is null then raise exception 'vin: 17 letters and digits, never I, O or Q' using errcode = '22023'; end if;
  if not app.vin_check_ok(v_vin) then raise exception 'The VIN''s check digit (the 9th character) does not match: check the VIN for a typo' using errcode = '22023'; end if;
  select app.vehicle_name(z.id) into v_taken from vehicles z where upper(z.vin) = v_vin limit 1;
  if v_taken is not null then raise exception 'Already with CarmaCars: %', v_taken using errcode = '23505'; end if;
  select * into d from vin_decodes z where z.vin = v_vin and z.ok order by z.decoded_at desc limit 1;
  v_year := coalesce(nullif(a ->> 'year', '')::integer, d.year);
  v_make := coalesce(nullif(btrim(coalesce(a ->> 'make', '')), ''), nullif(btrim(coalesce(d.make, '')), ''));
  v_model := coalesce(nullif(btrim(coalesce(a ->> 'model', '')), ''), nullif(btrim(coalesce(d.model, '')), ''));
  if v_year is null or v_make is null or v_model is null then
    raise exception 'The year, make and model could not be read from this VIN: give year, make and model' using errcode = '22023';
  end if;
  if v_title not in ('owned_outright', 'financed', 'leased') then raise exception 'title_status: owned_outright, financed or leased' using errcode = '22023'; end if;
  if v_title <> 'owned_outright' and nullif(btrim(coalesce(a ->> 'finance_party_name', '')), '') is null then
    raise exception 'finance_party_name: the % of a % car', case v_title when 'leased' then 'lease company' else 'lender' end, v_title using errcode = '22023';
  end if;
  v_fleet := coalesce(o.onboarding_route, '') = 'fleet_supplier' or app.fleet_supplier(o.id);
  if v_fleet and coalesce(v_tier, '') not in ('regular', 'troubled') then raise exception 'tier: a fleet supplier''s car needs its tier, regular or troubled' using errcode = '22023'; end if;
  if not v_fleet and v_tier is not null then raise exception 'tier: only a fleet supplier''s car has a lease tier' using errcode = '22023'; end if;
  v_vehicle := jsonb_strip_nulls(jsonb_build_object('vin', v_vin, 'year', v_year, 'make', v_make, 'model', v_model,
    'trim', coalesce(nullif(btrim(coalesce(a ->> 'trim', '')), ''), app.decode_trim(d.trim)), 'plate', nullif(upper(btrim(coalesce(a ->> 'plate', ''))), ''),
    'odometer_km', nullif(a ->> 'odometer_km', ''), 'colour', nullif(btrim(coalesce(a ->> 'colour', '')), ''), 'class', nullif(btrim(coalesce(a ->> 'class', '')), ''),
    'title_status', v_title, 'finance_party_name', nullif(btrim(coalesce(a ->> 'finance_party_name', '')), ''),
    'held_by', case when o.kind = 'program' then o.owner_type end, 'management_mode', case when o.kind = 'program' then 'managed' end, 'lease_tier', v_tier));
  return jsonb_build_object('owner_id', o.id, 'owner_name', coalesce(o.corporation_name, o.legal_name), 'fleet_supplier', v_fleet, 'decoded', d.id is not null,
    'vehicle', v_vehicle,
    'payload', jsonb_strip_nulls(jsonb_build_object('owner_id', o.id, 'vehicle', v_vehicle, 'signing', 'email', 'note', 'Added through the Admin connector',
      'plan', case when v_fleet then jsonb_build_object('invoices', '[]'::jsonb) when v_terms then jsonb_build_object('terms', a -> 'terms', 'invoices', '[]'::jsonb) end,
      'approve', v_fleet or v_terms)));
end $$;

alter function app.api_call(text, text, jsonb, text) rename to api_call_pre3740;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  chk jsonb;
  k api_keys;
  v_args jsonb;
  v_confirm boolean;
  pv api_previews;
  v_plan jsonb;
  v_result jsonb;
  v_target text := left(coalesce(nullif(a ->> 'vin', ''), p_tool), 200);
begin
  if p_tool <> 'add_car' then return app.api_call_pre3740(p_hash, p_tool, p_args, p_client); end if;
  chk := app.api_key_check(p_hash, 'admin:write', p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  v_confirm := coalesce((a ->> 'confirm')::boolean, false);
  v_args := a - 'confirm' - 'preview_id';
  begin
    perform app.assert_admin(k.user_id);
    v_plan := app.api_add_car_plan(v_args);
    if not v_confirm then
      insert into api_previews (key_id, user_id, tool, args, before, after) values (k.id, k.user_id, p_tool, v_args, null, v_plan - 'payload') returning * into pv;
      v_result := jsonb_build_object('preview', true, 'preview_id', pv.id, 'tool', p_tool, 'expires_at', pv.created_at + interval '10 minutes',
        'owner', v_plan ->> 'owner_name', 'car', v_plan -> 'vehicle', 'decoded_from_vin', v_plan -> 'decoded',
        'will_do', format('Add the %s %s %s (VIN %s) for %s as Add a car for an owner does: an application, the car in onboarding with its photo jobs and default rates%s.',
          v_plan #>> '{vehicle,year}', v_plan #>> '{vehicle,make}', v_plan #>> '{vehicle,model}', v_plan #>> '{vehicle,vin}', v_plan ->> 'owner_name',
          case when (v_plan ->> 'fleet_supplier')::boolean then ', approved on the fleet lease at the ' || (v_plan #>> '{vehicle,lease_tier}') || ' tier'
               when (v_plan #>> '{payload,approve}')::boolean then ', approved with the terms given' else '; its terms wait for an Admin''s approval' end),
        'next', 'Nothing was changed. To do it, call this tool again with exactly the same arguments plus "confirm": true and "preview_id": "' || pv.id || '".');
    else
      select * into pv from api_previews where id = nullif(a ->> 'preview_id', '')::uuid for update;
      if pv.id is null or pv.key_id <> k.id or pv.tool <> p_tool then raise exception 'Preview first: call without confirm, then confirm with its preview_id' using errcode = '22023'; end if;
      if pv.used_at is not null then raise exception 'This preview was already used: preview again' using errcode = '22023'; end if;
      if pv.created_at < now() - interval '10 minutes' then raise exception 'This preview is more than 10 minutes old: preview again' using errcode = '22023'; end if;
      if pv.args is distinct from v_args then raise exception 'The arguments differ from the preview: preview again with these' using errcode = '22023'; end if;
      update api_previews set used_at = now() where id = pv.id;
      v_result := app.door(k.user_id, 'aal2', 'ops_do', 'staff_add_owner_car', v_plan -> 'payload')
        || jsonb_build_object('done', true, 'run', 'car_added', 'actor', k.user_id);
    end if;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, v_target, v_args, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 when '23505' then 409 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, ok, client)
  values (k.id, k.user_id, case when not v_confirm then p_tool || ':preview' else p_tool end, v_target, v_args, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre3740(text, text, jsonb, text)'::regprocedure);

revoke all on function app.api_call_pre3740(text, text, jsonb, text), app.api_add_car_plan(jsonb) from public, anon, authenticated;
grant execute on function app.api_call_pre3740(text, text, jsonb, text), app.api_add_car_plan(jsonb) to service_role;
