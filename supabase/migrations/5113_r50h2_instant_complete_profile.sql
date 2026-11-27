-- 5113 (r50 hotfix2): Instant booking for every renter with a complete profile, whatever their Rewards tier (2421 had
-- made it a Gold perk), and never on a sample car or a car of an owner kept off it (01 Motors). It shows as a filter on
-- the cars page (the fleet read's instant_book) and as Book instantly on the car page and in the booking form.
--   1. owners.instant_book_off (false by default; true for 01 Motors, matched by its owner or partner name).
--   2. app.renter_profile_complete(renter): legal name, date of birth, home address (line 1, city, postal code), mobile,
--      email and a verified licence.
--   3. app.instant_book_check: complete profile instead of the tier (the switch, an Admin taking it away, a blocked
--      renter, a damage or claim, money owing: as before).
--   4. app.vehicle_instant_ok(vehicle): not a sample car, its owner not kept off; public.server_instant_book refuses others
--      (the request stays a request); app.public_fleet_trending and app.booking_cars return instant_book.

alter table owners add column if not exists instant_book_off boolean not null default false;
comment on column owners.instant_book_off is 'Instant booking off for this owner''s cars (5113): renters always send a request. 01 Motors from the start.';
-- data: 01 Motors (its owner or partner record, by its exact name) starts with the flag on; afterwards the flag is the only
-- rule, changed by an Admin under Admin > Owners > the owner (owner_instant_book_set below)
update owners o set instant_book_off = true
 where o.instant_book_off = false
   and (lower(btrim(coalesce(o.corporation_name, ''))) in ('01 motors', '01 motors inc.') or lower(btrim(coalesce(o.legal_name, ''))) in ('01 motors', '01 motors inc.')
        or exists (select 1 from partners p where p.owner_id = o.id and (lower(btrim(coalesce(p.business_name, ''))) in ('01 motors', '01 motors inc.') or lower(btrim(coalesce(p.legal_name, ''))) in ('01 motors', '01 motors inc.'))));

create function app.renter_profile_complete(p_renter uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce((select nullif(btrim(r.legal_name), '') is not null and r.date_of_birth is not null
                          and nullif(btrim(coalesce(r.address_line1, '')), '') is not null and nullif(btrim(coalesce(r.city, '')), '') is not null
                          and nullif(btrim(coalesce(r.postal_code, '')), '') is not null and nullif(btrim(coalesce(r.mobile, '')), '') is not null
                          and nullif(btrim(coalesce(r.email, '')), '') is not null and r.identity_status::text = 'verified'
                     from renters r where r.id = p_renter), false)
$$;

create function app.vehicle_instant_ok(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce((select not coalesce(v.is_sample, false) and not coalesce(o.instant_book_off, false)
                     from vehicles v left join owners o on o.id = v.owner_id where v.id = p_vehicle), false)
$$;

create or replace function app.instant_book_check(p_renter uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  s program_settings := app.settings();
  r renters;
  v_done integer;
  v_why text;
begin
  select * into r from renters where id = p_renter;
  if r.id is null then return jsonb_build_object('eligible', false, 'reason', 'No renter'); end if;
  select count(*) into v_done from bookings b where b.renter_id = r.id and b.status = 'closed' and b.booking_type <> 'owner';
  v_why := case
    when not coalesce(s.instant_book_repeat_enabled, false) then 'Instant booking is switched off'
    when r.instant_book_revoked_at is not null then 'Taken away by an Admin' || coalesce(': ' || r.instant_book_revoked_reason, '')
    when coalesce(r.is_blocked, false) then 'The renter is blocked'
    when r.identity_status::text <> 'verified' then 'The licence is not verified'
    when not app.renter_profile_complete(r.id) then 'The profile is not complete (name, date of birth, home address, mobile and email)'
    when exists (select 1 from bookings b join incidents i on i.booking_id = b.id where b.renter_id = r.id) then 'A damage or claim on a past rental'
    when exists (select 1 from bookings b join booking_line_items li on li.booking_id = b.id where b.renter_id = r.id and li.voided_at is null and li.amount_cents > 0
                   and li.charge_type in ('damage_at_cost', 'deductible', 'loss_of_use', 'recovery_cost')) then 'A damage or claim on a past rental'
    when exists (select 1 from bookings b where b.renter_id = r.id and b.status in ('returned', 'closed') and app.booking_balance_open(b.id) > 0) then 'Money owing on a past rental'
  end;
  return jsonb_build_object('eligible', v_why is null, 'reason', v_why, 'completed', v_done, 'needed', 0, 'profile_complete', app.renter_profile_complete(r.id),
    'revoked_at', r.instant_book_revoked_at, 'revoked_reason', r.instant_book_revoked_reason);
end $$;

-- the car first: a sample car or an owner kept off it stays a request
-- the Rewards tiers no longer list Instant Book (it is not a Gold perk now); the row stays, switched off
update reward_tier_perks set enabled = false, updated_at = now() where code = 'instant_book' and enabled;

alter function public.server_instant_book(text, uuid) rename to server_instant_book_pre5113;
create function public.server_instant_book(p_number text, p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare b bookings;
begin
  select * into b from bookings where booking_number = upper(btrim(coalesce(p_number, '')));
  if b.id is not null and p_user is not null and app.is_booking_renter(b.id, p_user) and not app.vehicle_instant_ok(b.vehicle_id) then
    return jsonb_build_object('instant', false, 'reason', 'This car is booked by request');
  end if;
  return public.server_instant_book_pre5113(p_number, p_user);
end $$;

alter function app.public_fleet_trending(jsonb) rename to public_fleet_trending_pre5113;
create function app.public_fleet_trending(p_filters jsonb default '{}'::jsonb) returns setof jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select r || jsonb_build_object('instant_book', coalesce((app.settings()).instant_book_repeat_enabled, false) and app.vehicle_instant_ok((r ->> 'vehicle_id')::uuid))
    from app.public_fleet_trending_pre5113(p_filters) with ordinality t(r, n) order by n
$$;

alter function app.booking_cars() rename to booking_cars_pre5113;
create function app.booking_cars() returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(jsonb_agg(x || jsonb_build_object('instant_book', coalesce((app.settings()).instant_book_repeat_enabled, false) and app.vehicle_instant_ok((x ->> 'vehicle_id')::uuid)) order by n), '[]'::jsonb)
    from jsonb_array_elements(app.booking_cars_pre5113()) with ordinality t(x, n)
$$;

-- Admin > Owners > the owner: Instant booking on or off for all of the owner's cars, with the reason in the audit log
create function app.owner_instant_book_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  o owners;
  v_off boolean := coalesce((p ->> 'off')::boolean, true);
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin turns instant booking on or off for an owner' using errcode = '42501'; end if;
  if v_reason is null then raise exception 'Say why' using errcode = '22023'; end if;
  select * into o from owners where id::text = coalesce(p ->> 'owner_id', p ->> 'owner') for update;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  update owners set instant_book_off = v_off where id = o.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'owner_instant_book_set', 'owners', o.id::text, jsonb_build_object('instant_book_off', o.instant_book_off), jsonb_build_object('instant_book_off', v_off, 'reason', v_reason));
  return jsonb_build_object('owner_id', o.id, 'instant_book_off', v_off);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5113;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_call = 'admin_do' and p_name = 'owner_instant_book_set' then
    perform app.door_begin(p_user, p_aal);
    return app.owner_instant_book_set(p_user, p);
  end if;
  if p_call = 'admin_read' and p_name = 'owner_instant_book' then
    perform app.door_begin(p_user, p_aal);
    if not app.user_is_admin(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return (select jsonb_build_object('owner_id', o.id, 'instant_book_off', o.instant_book_off) from owners o where o.id::text = coalesce(p ->> 'owner_id', p ->> 'owner'));
  end if;
  return app.door_pre5113(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare f record; g text;
begin
  -- the renamed ones keep their grants; the new ones get the same
  for f in select * from (values ('public.server_instant_book(text, uuid)', 'public.server_instant_book_pre5113(text, uuid)'), ('app.door(uuid, text, text, text, jsonb)', 'app.door_pre5113(uuid, text, text, text, jsonb)'),
                                 ('app.public_fleet_trending(jsonb)', 'app.public_fleet_trending_pre5113(jsonb)'),
                                 ('app.booking_cars()', 'app.booking_cars_pre5113()')) v(n, o) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.n);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, f.o::regprocedure, 'execute') then execute format('grant execute on function %s to %I', f.n, g); end if;
    end loop;
  end loop;
  -- the old server_instant_book is reached through the new one only
  revoke all on function public.server_instant_book_pre5113(text, uuid) from public, anon, authenticated;
  revoke all on function app.renter_profile_complete(uuid), app.vehicle_instant_ok(uuid), app.owner_instant_book_set(uuid, jsonb) from public, anon, authenticated;
  grant execute on function app.renter_profile_complete(uuid), app.vehicle_instant_ok(uuid), app.owner_instant_book_set(uuid, jsonb) to service_role;
end $$;
