-- 0561_site_search.sql
-- Release 28 (docs/changes/2026-11-06-r28-platform.md, B4): one search box in the header of the site and every portal.
-- The public part (pages, cars, places, guides, the portals' sign-in pages) is a list the browser searches itself
-- (/api/search/index, rebuilt hourly). A signed-in person's own records come from app.search_mine through the server
-- (/api/search/mine): it runs as that person (app.door_begin sets who is asking, as every portal call does) and every
-- group asks the same question as the row-level security policy of its table, so nobody finds a row they could not open:
--   bookings and requests  Admin; VA cs, finance, fleet; VA sales only requests and offers (bookings va_read)
--   renters                Admin; a VA within the customer window (app.va_sees_renter, renters va_read)
--   owners                 Admin; VA cs, finance, fleet (owners va_read)
--   cars                   Admin; any VA; field staff with a job on the car; an owner, their own cars
--   own                    a renter's own bookings; an owner's own cars and their bookings; field staff their jobs
-- A renter's name, email or phone counts as a match only where the renter may be seen, so a booking never answers a
-- search for a person the asker may not see. Matching is a plain contains (lower case; digits only for phones and
-- plates), helped by trigram indexes.

do $$ begin
  create extension if not exists pg_trgm;
exception when others then raise notice 'pg_trgm not available: search runs without its indexes (%)', sqlerrm;
end $$;

-- ================================================================ the normal forms matched (immutable, so indexable)
create or replace function app.search_key(p text) returns text
language sql immutable parallel safe as $$ select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) $$;
create or replace function app.search_digits(p text) returns text
language sql immutable parallel safe as $$ select regexp_replace(coalesce(p, ''), '\D', '', 'g') $$;
create or replace function app.search_like(p text) returns text
language sql immutable parallel safe as $$ select '%' || replace(replace(replace(lower(btrim(coalesce(p, ''))), '\', '\\'), '%', '\%'), '_', '\_') || '%' $$;

-- the trigram indexes, built only when the operator class is there (wherever the extension lives)
do $$
declare
  ops text;
begin
  select quote_ident(n.nspname) || '.gin_trgm_ops' into ops from pg_opclass o join pg_namespace n on n.oid = o.opcnamespace where o.opcname = 'gin_trgm_ops' limit 1;
  if ops is null then return; end if;
  execute format('create index if not exists renters_search_name_trgm on renters using gin (lower(legal_name) %s)', ops);
  execute format('create index if not exists renters_search_email_trgm on renters using gin (lower(coalesce(email, %L)) %s)', '', ops);
  execute format('create index if not exists renters_search_phone_trgm on renters using gin (app.search_digits(mobile) %s)', ops);
  execute format('create index if not exists owners_search_name_trgm on owners using gin (lower(legal_name) %s)', ops);
  execute format('create index if not exists owners_search_email_trgm on owners using gin (lower(coalesce(email, %L)) %s)', '', ops);
  execute format('create index if not exists vehicles_search_plate_trgm on vehicles using gin (app.search_key(plate) %s)', ops);
  execute format('create index if not exists bookings_search_number_trgm on bookings using gin (app.search_key(booking_number) %s)', ops);
end $$;

-- ================================================================ the search
create or replace function app.search_mine(p_user uuid, p_aal text, p_q text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q text := left(btrim(coalesce(p_q, '')), 80);
  l text;
  k text;
  d text;
  v_admin boolean;
  v_va boolean;
  v_bk boolean;      -- bookings of every status (VA cs, finance, fleet)
  v_sales boolean;   -- requests and offers only (VA sales)
  v_field boolean;
  v_renter uuid;
  v_owner boolean;
  v_base text;
  groups jsonb := '[]'::jsonb;
  g jsonb;
begin
  perform app.door_begin(p_user, p_aal);
  if length(q) < 2 then return jsonb_build_object('q', q, 'groups', groups); end if;
  l := app.search_like(q);
  k := app.search_key(q);
  d := app.search_digits(q);
  if length(d) < 4 then d := ''; end if;      -- a phone match needs four digits or more
  if length(k) < 2 then k := ''; end if;
  v_admin := app.is_admin();
  v_va := app.is_va();
  v_bk := v_admin or app.va_has('cs', 'finance', 'fleet');
  v_sales := not v_bk and app.va_has('sales');
  v_field := app.is_field();
  v_renter := app.my_renter_id();
  v_owner := app.has_role('owner');
  v_base := case when v_admin then '/admin' else '/staff' end;

  -- ---------------------------------------------------------------- requests, then bookings (staff)
  if v_bk or v_sales then
    for g in
      select jsonb_build_object('key', grp, 'label', case grp when 'requests' then 'Requests and offers' else 'Bookings' end, 'rows', coalesce(jsonb_agg(x order by at desc), '[]'::jsonb))
        from (select * from (
          select row_number() over (partition by case when b.status::text in ('requested', 'offered', 'tentative') then 1 else 2 end order by b.pickup_at desc) rn,
                 case when b.status::text in ('requested', 'offered', 'tentative') then 'requests' else 'bookings' end grp, b.pickup_at at,
                 jsonb_build_object('title', b.booking_number,
                   'sub', concat_ws(' · ', case when rv.ok then r.legal_name end, app.vehicle_name(b.vehicle_id), nullif(v.plate, ''), replace(b.status::text, '_', ' '),
                                    to_char(b.pickup_at at time zone 'America/Toronto', 'Mon DD')),
                   'href', v_base || '/bookings/' || b.booking_number) x
            from bookings b
            left join renters r on r.id = b.renter_id
            left join vehicles v on v.id = b.vehicle_id
            cross join lateral (select r.id is not null and (v_admin or app.va_sees_renter(r.id)) ok) rv
           where (v_bk or b.status::text in ('requested', 'offered', 'tentative', 'pending_payment'))
             and not coalesce(b.is_placeholder, false)
             and ((k <> '' and app.search_key(b.booking_number) like '%' || k || '%')
               or (k <> '' and length(k) >= 3 and app.search_key(v.plate) like '%' || k || '%')
               or (rv.ok and (lower(r.legal_name) like l or lower(coalesce(r.email, '')) like l or (d <> '' and app.search_digits(r.mobile) like '%' || d || '%'))))
          ) w where rn <= 8) s
       group by grp
       order by grp desc
    loop
      groups := groups || jsonb_build_array(g);
    end loop;
  end if;

  -- ---------------------------------------------------------------- renters (staff, within what they may see)
  if v_admin or v_va then
    g := (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object('title', r.legal_name, 'sub', concat_ws(' · ', r.email, r.mobile),
               'href', case when v_admin then '/admin/renters/' || r.id else '/staff/renters?id=' || r.id || '&q=' || coalesce(r.email, r.legal_name) end) x
        from renters r
       where r.merged_into is null
         and (lower(r.legal_name) like l or lower(coalesce(r.email, '')) like l or (d <> '' and app.search_digits(r.mobile) like '%' || d || '%'))
         and (v_admin or app.va_sees_renter(r.id))
       order by r.created_at desc limit 8) s);
    if jsonb_array_length(g) > 0 then groups := groups || jsonb_build_array(jsonb_build_object('key', 'renters', 'label', 'Renters', 'rows', g)); end if;
  end if;

  -- ---------------------------------------------------------------- owners (Admin; VA cs, finance, fleet)
  if v_bk then
    g := (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object('title', o.legal_name, 'sub', concat_ws(' · ', o.email, o.phone, o.status),
               'href', case when v_admin then '/admin/owners/' || o.id
                            else coalesce('/staff/vehicles/' || (select v.id from vehicles v where v.owner_id = o.id and v.retired_at is null order by v.created_at limit 1), '/staff/owner-pipeline') end) x
        from owners o
       where o.kind = 'program'
         and (lower(o.legal_name) like l or lower(coalesce(o.email, '')) like l or lower(coalesce(o.corporation_name, '')) like l
              or (d <> '' and app.search_digits(o.phone) like '%' || d || '%'))
       order by o.created_at desc limit 8) s);
    if jsonb_array_length(g) > 0 then groups := groups || jsonb_build_array(jsonb_build_object('key', 'owners', 'label', 'Owners', 'rows', g)); end if;
  end if;

  -- ---------------------------------------------------------------- cars (vehicles' policies: admin, VA, field job, own)
  if v_admin or v_va or v_field or v_owner then
    g := (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object('title', app.vehicle_name(v.id),
               'sub', concat_ws(' · ', 'car code ' || v.car_code, case when v_admin or v_va or app.is_my_owner(v.owner_id) then 'plate ' || nullif(v.plate, '') end, replace(v.status::text, '_', ' ')),
               'href', case when v_admin then '/admin/vehicles/' || v.id when v_va or v_field then '/staff/vehicles/' || v.id else '/owner/vehicles/' || v.id end) x
        from vehicles v
       where coalesce(v.is_sample, false) = false
         and (v_admin or v_va or app.field_has_job(null, v.id) or app.is_my_owner(v.owner_id))
         and ((k <> '' and (app.search_key(v.plate) like '%' || k || '%' or upper(coalesce(v.vin, '')) like '%' || k || '%' or upper(coalesce(v.car_code, '')) like '%' || k || '%'))
              or lower(concat_ws(' ', v.year::text, v.make, v.model, v.trim, v.colour)) like l or lower(coalesce(v.fleet_number, '')) like l)
       order by v.created_at desc limit 8) s);
    if jsonb_array_length(g) > 0 then groups := groups || jsonb_build_array(jsonb_build_object('key', 'cars', 'label', 'Cars', 'rows', g)); end if;
  end if;

  -- ---------------------------------------------------------------- an owner's own cars' bookings (no renter details)
  if v_owner and not (v_admin or v_va) then
    g := (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object('title', b.booking_number, 'sub', concat_ws(' · ', app.vehicle_name(b.vehicle_id), replace(b.status::text, '_', ' '),
                 to_char(b.pickup_at at time zone 'America/Toronto', 'Mon DD') || ' to ' || to_char(b.return_at at time zone 'America/Toronto', 'Mon DD')),
               'href', '/owner/vehicles/' || b.vehicle_id || '?tab=bookings') x
        from bookings b join vehicles v on v.id = b.vehicle_id
       where app.is_my_owner(v.owner_id) and not coalesce(b.is_placeholder, false)
         and b.status::text in ('confirmed', 'on_rent', 'returned', 'closed')
         and ((k <> '' and app.search_key(b.booking_number) like '%' || k || '%') or lower(app.vehicle_name(b.vehicle_id)) like l)
       order by b.pickup_at desc limit 8) s);
    if jsonb_array_length(g) > 0 then groups := groups || jsonb_build_array(jsonb_build_object('key', 'own_bookings', 'label', 'Bookings of your cars', 'rows', g)); end if;
  end if;

  -- ---------------------------------------------------------------- a renter's own bookings
  if v_renter is not null then
    g := (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object('title', b.booking_number, 'sub', concat_ws(' · ', app.vehicle_name(b.vehicle_id), replace(b.status::text, '_', ' '),
                 to_char(b.pickup_at at time zone 'America/Toronto', 'Mon DD')), 'href', '/account/bookings/' || b.booking_number) x
        from bookings b
       where b.renter_id = v_renter
         and ((k <> '' and app.search_key(b.booking_number) like '%' || k || '%') or lower(app.vehicle_name(b.vehicle_id)) like l)
       order by b.pickup_at desc limit 8) s);
    if jsonb_array_length(g) > 0 then groups := groups || jsonb_build_array(jsonb_build_object('key', 'my_bookings', 'label', 'Your bookings', 'rows', g)); end if;
  end if;

  -- ---------------------------------------------------------------- field staff: their jobs
  if v_field and not v_admin then
    g := (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object('title', concat_ws(' · ', initcap(replace(j.kind::text, '_', ' ')), app.vehicle_name(j.vehicle_id)),
               'sub', concat_ws(' · ', b.booking_number, to_char(j.scheduled_at at time zone 'America/Toronto', 'Mon DD HH24:MI'), j.status::text),
               'href', '/staff/field/jobs/' || j.id) x
        from field_jobs j left join bookings b on b.id = j.booking_id left join vehicles v on v.id = j.vehicle_id
       where j.assigned_to = p_user and j.status::text <> 'cancelled'
         and ((k <> '' and (app.search_key(b.booking_number) like '%' || k || '%' or app.search_key(v.plate) like '%' || k || '%'))
              or lower(app.vehicle_name(j.vehicle_id)) like l)
       order by j.scheduled_at desc limit 8) s);
    if jsonb_array_length(g) > 0 then groups := groups || jsonb_build_array(jsonb_build_object('key', 'jobs', 'label', 'Your field jobs', 'rows', g)); end if;
  end if;

  return jsonb_build_object('q', q, 'groups', groups);
end $$;

create or replace function public.server_search_mine(p_user uuid, p_aal text, p_q text) returns jsonb
language sql security definer set search_path = public, app as $$ select app.search_mine(p_user, p_aal, p_q) $$;
revoke all on function app.search_mine(uuid, text, text), public.server_search_mine(uuid, text, text) from public, anon, authenticated;
grant execute on function public.server_search_mine(uuid, text, text) to service_role;
