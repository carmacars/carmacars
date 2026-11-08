-- 0824: add cars from a list of VINs (Release 34, part P; docs/changes/2026-11-08-r34-owner-onboarding.md).
-- No applied migration is edited.
--
-- app.owner_add_vins: an owner adds several cars at once from their portal (Cars > Add cars), and an Admin, customer
-- service or fleet does it on the owner's page. The website reads the list (pasted or a CSV or text file), decodes each
-- VIN with the decoder the app already uses (vPIC, recorded in vin_decodes; src/server/actions/vin.ts) and shows a
-- preview; this call checks it again and, without preview, makes every good car in one step: one owner application with
-- all of them (app.submit_owner_application, as the owner's own application or Add a car for an owner), each car
-- Managed, owned outright unless the row says financed or leased (with the lender), waiting for the Admin's approval of
-- its terms like any new car. Reported and not made: a VIN that is not 17 letters and digits, one whose check digit
-- (the 9th character) does not match, one listed twice, one already with CarmaCars, one the decoder could not read, and
-- a financed or leased car with no lender. At most 50 a time. A fleet supplier adds each car with its tier and plate
-- (Add a car), not from a list.
set local check_function_bodies = off;

create function app.owner_add_vins(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  v_staff boolean;
  v_preview boolean := coalesce((p ->> 'preview')::boolean, false);
  x jsonb;
  v_vin text;
  v_raw text;
  v_seen text[] := '{}';
  v_title text;
  v_lender text;
  d vin_decodes;
  v_taken text;
  v_rows jsonb := '[]'::jsonb;
  v_cars jsonb := '[]'::jsonb;
  v_why text;
  res jsonb;
  n integer := 0;
begin
  select * into o from owners where id = nullif(p ->> 'owner_id', '')::uuid;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  v_staff := app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet');
  if not v_staff and not app.user_is_owner_of(p_by, o.id) then
    raise exception 'Not permitted: an owner adds cars to their own account; staff add them on the owner''s page' using errcode = '42501';
  end if;
  if coalesce(o.kind, 'program') <> 'program' then raise exception 'Cars are added from a VIN list for an owner in the owner program only' using errcode = '23514'; end if;
  if coalesce(o.onboarding_route, '') = 'fleet_supplier' or app.fleet_supplier(o.id) then
    raise exception 'A fleet supplier adds each car with its tier and plate: use Add a car' using errcode = '23514';
  end if;
  if jsonb_typeof(coalesce(p -> 'cars', 'null')) <> 'array' or jsonb_array_length(p -> 'cars') = 0 then
    raise exception 'Paste or upload at least one VIN' using errcode = '22023';
  end if;
  if jsonb_array_length(p -> 'cars') > 50 then raise exception 'At most 50 VINs at a time' using errcode = '22023'; end if;

  for x in select * from jsonb_array_elements(p -> 'cars') loop
    v_raw := upper(regexp_replace(coalesce(x ->> 'vin', ''), '[\s-]', '', 'g'));
    v_vin := app.clean_vin(v_raw);
    v_title := coalesce(nullif(x ->> 'title_status', ''), 'owned_outright');
    v_lender := nullif(btrim(coalesce(x ->> 'finance_party_name', '')), '');
    v_why := null; v_taken := null; d := null;
    if v_vin is null then v_why := 'Not a VIN: 17 letters and digits, never I, O or Q';
    elsif not app.vin_check_ok(v_vin) then v_why := 'The check digit (the 9th character) does not match: check the VIN for a typo';
    elsif v_vin = any (v_seen) then v_why := 'Listed twice';
    else
      select app.vehicle_name(z.id) into v_taken from vehicles z where upper(z.vin) = v_vin limit 1;
      if v_taken is not null then v_why := 'Already with CarmaCars: ' || v_taken;
      else
        select * into d from vin_decodes z where z.vin = v_vin and z.ok order by z.decoded_at desc limit 1;
        if d.id is null or d.year is null or nullif(btrim(coalesce(d.make, '')), '') is null or nullif(btrim(coalesce(d.model, '')), '') is null then
          v_why := 'The year, make and model could not be read from this VIN: add the car with Add a car';
        elsif v_title not in ('owned_outright', 'financed', 'leased') then v_why := 'Say whether the car is owned outright, financed or leased';
        elsif v_title <> 'owned_outright' and v_lender is null then v_why := 'Name the ' || case v_title when 'leased' then 'lease company' else 'lender' end;
        end if;
      end if;
    end if;
    if v_vin is not null then v_seen := v_seen || v_vin; end if;
    v_rows := v_rows || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('vin', coalesce(v_vin, v_raw), 'ok', v_why is null, 'why', v_why,
      'year', d.year, 'make', d.make, 'model', d.model, 'trim', app.decode_trim(d.trim), 'title_status', v_title, 'finance_party_name', v_lender)));
    if v_why is null then
      v_cars := v_cars || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('vin', v_vin, 'year', d.year, 'make', d.make, 'model', d.model,
        'trim', app.decode_trim(d.trim), 'title_status', v_title, 'finance_party_name', v_lender, 'held_by', o.owner_type, 'management_mode', 'managed')));
      n := n + 1;
    end if;
  end loop;

  if v_preview or n = 0 then
    return jsonb_build_object('preview', true, 'rows', v_rows, 'good', n, 'bad', jsonb_array_length(v_rows) - n);
  end if;
  res := app.submit_owner_application(jsonb_build_object('owner_id', o.id, 'vehicles', v_cars, 'source', case when v_staff then 'staff' else 'web' end,
           'note', format('Added from a VIN list (%s car%s)', n, case when n = 1 then '' else 's' end)), p_by);
  if v_staff then
    update owner_applications set entered_by = p_by, entered_by_name = (select coalesce(u.full_name, u.email) from users u where u.id = p_by)
     where id = (res ->> 'application_id')::uuid;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'owner_add_vins', 'owner_applications', res ->> 'application_id', jsonb_build_object('owner_id', o.id, 'made', n,
          'vins', (select jsonb_agg(c ->> 'vin') from jsonb_array_elements(v_cars) c),
          'skipped', (select coalesce(jsonb_agg(jsonb_build_object('vin', r ->> 'vin', 'why', r ->> 'why')), '[]'::jsonb) from jsonb_array_elements(v_rows) r where not (r ->> 'ok')::boolean)));
  return jsonb_build_object('preview', false, 'rows', v_rows, 'good', n, 'bad', jsonb_array_length(v_rows) - n,
    'application_id', res ->> 'application_id', 'application_number', res ->> 'application_number',
    'vehicles', (select coalesce(jsonb_agg(jsonb_build_object('vehicle_id', z ->> 'vehicle_id', 'vin', z ->> 'vin')), '[]'::jsonb) from jsonb_array_elements(res -> 'vehicles') z));
end $$;

revoke all on function app.owner_add_vins(uuid, jsonb) from public, anon, authenticated;
