-- 0546: the car picked up from its owner and returned to its owner, documented (docs/changes/2026-11-07-r28-operations.md, A4).
--
-- The owner: "a section to document photos of the vehicle when we pick it up from the host". On the vehicle page (and the
-- owner's car page): "Pickup from owner" and "Return to owner" records with the date and time, km, fuel, many photos at
-- once with the same suggested angles as a rental's check-out, notes and who; Admin, Fleet and field staff record them;
-- the owner sees them read only in the owner portal. They are the car's baseline condition for disputes.
-- No applied migration is edited.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

create table if not exists vehicle_owner_handoffs (
  id           uuid primary key default gen_random_uuid(),
  vehicle_id   uuid not null references vehicles (id) on delete cascade,
  owner_id     uuid references owners (id),
  kind         text not null check (kind in ('pickup_from_owner', 'return_to_owner')),
  at           timestamptz not null,
  odometer_km  integer check (odometer_km >= 0),
  fuel_pct     smallint check (fuel_pct between 0 and 100),
  notes        text check (char_length(notes) <= 2000),
  photos       jsonb not null default '[]'::jsonb check (jsonb_typeof(photos) = 'array' and jsonb_array_length(photos) <= 60),
  recorded_by  uuid references users (id) on delete set null,
  recorded_at  timestamptz not null default now(),
  voided_at    timestamptz,
  voided_by    uuid references users (id) on delete set null
);
create index if not exists vehicle_owner_handoffs_vehicle on vehicle_owner_handoffs (vehicle_id, at desc);
alter table vehicle_owner_handoffs enable row level security;
create policy admin_all on vehicle_owner_handoffs for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_vehicle_owner_handoffs after insert or update or delete on vehicle_owner_handoffs for each row execute function app.audit_row();
comment on table vehicle_owner_handoffs is 'The car picked up from its owner or returned to them (0546): time, km, fuel, photos with their angles, notes, who. The baseline condition for disputes; the owner reads them.';

create or replace function app.user_may_owner_handoff(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_user) or app.user_va_has(p_user, 'fleet') or app.user_is_field(p_user)
$$;

create or replace function app.owner_handoff_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  h vehicle_owner_handoffs;
  v_photos jsonb := coalesce(p -> 'photos', '[]'::jsonb);
  v_at timestamptz := least(coalesce(nullif(p ->> 'at', '')::timestamptz, now()), now() + interval '5 minutes');
begin
  if not app.user_may_owner_handoff(p_by) then raise exception 'An Admin, Fleet or field staff record a pickup from or return to the owner' using errcode = '42501'; end if;
  select * into v from vehicles where id = nullif(p ->> 'vehicle', '')::uuid;
  if v.id is null then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
  if p ->> 'kind' not in ('pickup_from_owner', 'return_to_owner') then raise exception 'Pickup from the owner, or return to the owner' using errcode = '22023'; end if;
  if jsonb_typeof(v_photos) <> 'array' or jsonb_array_length(v_photos) > 60 then raise exception 'Up to 60 photos' using errcode = '22023'; end if;
  if exists (select 1 from jsonb_array_elements(v_photos) x where x ->> 'bucket' <> 'condition-photos'
               or coalesce(x ->> 'path', '') !~ ('^vehicles/' || v.id || '/owner-handoff/[0-9a-f-]{36}\.(jpg|png)$')) then
    raise exception 'A photo was not uploaded for this car' using errcode = '22023';
  end if;
  if nullif(p ->> 'id', '') is not null then
    -- photos added onto a record, never taken away (a mistaken record is voided by an Admin)
    select * into h from vehicle_owner_handoffs where id = (p ->> 'id')::uuid and vehicle_id = v.id and voided_at is null for update;
    if h.id is null then raise exception 'Record not found' using errcode = 'P0002'; end if;
    update vehicle_owner_handoffs set photos = h.photos || (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(v_photos) x
                                                             where not h.photos @> jsonb_build_array(jsonb_build_object('path', x ->> 'path'))),
           notes = coalesce(nullif(left(btrim(coalesce(p ->> 'notes', '')), 2000), ''), notes)
     where id = h.id returning * into h;
    return to_jsonb(h);
  end if;
  insert into vehicle_owner_handoffs (vehicle_id, owner_id, kind, at, odometer_km, fuel_pct, notes, photos, recorded_by)
  values (v.id, v.owner_id, p ->> 'kind', v_at, nullif(p ->> 'odometer_km', '')::numeric::integer, nullif(p ->> 'fuel_pct', '')::numeric::smallint,
          nullif(left(btrim(coalesce(p ->> 'notes', '')), 2000), ''),
          (select coalesce(jsonb_agg(jsonb_build_object('bucket', x ->> 'bucket', 'path', x ->> 'path', 'angle', nullif(x ->> 'angle', ''), 'by', p_by)), '[]'::jsonb) from jsonb_array_elements(v_photos) x),
          p_by)
  returning * into h;
  if h.odometer_km is not null then update vehicles set odometer_km = h.odometer_km where id = v.id and coalesce(odometer_km, 0) <= h.odometer_km; end if;
  return to_jsonb(h);
end $$;

create or replace function app.owner_handoff_void(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin voids a record' using errcode = '42501'; end if;
  update vehicle_owner_handoffs set voided_at = now(), voided_by = p_by where id = (p ->> 'id')::uuid and voided_at is null;
  return jsonb_build_object('ok', true);
end $$;

-- the records of a car: staff, or its owner (read only)
create or replace function app.owner_handoffs_list(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'kind', h.kind, 'at', h.at, 'odometer_km', h.odometer_km, 'fuel_pct', h.fuel_pct, 'notes', h.notes,
           'photos', h.photos, 'recorded_by_name', (select u.full_name from users u where u.id = h.recorded_by), 'recorded_at', h.recorded_at) order by h.at desc), '[]'::jsonb)
    from vehicle_owner_handoffs h where h.vehicle_id = p_vehicle and h.voided_at is null
$$;

create or replace function public.server_owner_handoffs(p_by uuid, p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.user_may_owner_handoff(p_by) or app.user_is_staff(p_by)
          or exists (select 1 from vehicles v join owners o on o.id = v.owner_id where v.id = p_vehicle and o.user_id = p_by)) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return app.owner_handoffs_list(p_vehicle);
end $$;
revoke all on function public.server_owner_handoffs(uuid, uuid) from public, anon, authenticated;
grant execute on function public.server_owner_handoffs(uuid, uuid) to service_role;
revoke all on function app.user_may_owner_handoff(uuid), app.owner_handoff_save(uuid, jsonb), app.owner_handoff_void(uuid, jsonb), app.owner_handoffs_list(uuid) from public, anon, authenticated;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0546;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_do', 'admin_do') and p_name in ('owner_handoff_save', 'owner_handoff_void') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    if p_name = 'owner_handoff_save' then return app.owner_handoff_save(p_user, coalesce(p, '{}'::jsonb) - '_va'); end if;
    return app.owner_handoff_void(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0546(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0546(uuid, text, text, text, jsonb)'::regprocedure);
