-- 0470_person_roles.sql
-- One answer to "what is this person to us": owner, partner, investor, staff, renter. A visitor, lead or map pin used to
-- say "renter" (Known customer, Renter page) as soon as the browser was linked to a renters row, even for an owner who
-- only has a renters row because they signed in. The roles now come from every record: the owners row (by user, email or
-- phone), an owner-program lead, investors, partners, staff roles and the renters row. A renters row only makes a person
-- a renter when they have rented (a booking that is not an owner's, not cancelled, declined or expired) or have no other
-- role. The Live visitors read, the Live map read and the captured contacts read carry roles and owner_id on each row.

create or replace function app.person_tags(p_user uuid, p_renter uuid, p_email text, p_phone text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_ren renters;
  v_user uuid;
  v_emails text[];
  v_phones text[];
  v_owner uuid;
  v_roles text[] := '{}';
  v_renter uuid;
begin
  if p_renter is not null then select * into v_ren from renters where id = p_renter; end if;
  v_user := coalesce(p_user, v_ren.user_id);
  v_emails := array(select distinct e from unnest(array[lower(btrim(coalesce(p_email, ''))), lower(btrim(coalesce(v_ren.email, '')))]) e where e <> '');
  v_phones := array(select distinct x from unnest(array[app.phone_e164(p_phone), app.phone_e164(v_ren.mobile)]) x where x is not null);

  select o.id into v_owner from owners o
   where (v_user is not null and o.user_id = v_user) or lower(btrim(coalesce(o.email, ''))) = any (v_emails) or app.phone_e164(o.phone) = any (v_phones)
   order by (o.user_id is not distinct from v_user) desc, (o.status = 'active') desc, o.created_at limit 1;
  if v_owner is not null or exists (select 1 from leads l where l.kind = 'owner_program' and lower(btrim(coalesce(l.email, ''))) = any (v_emails)) then
    v_roles := array_append(v_roles, 'owner');
  end if;
  if exists (select 1 from partners pa where (v_owner is not null and pa.owner_id = v_owner) or lower(btrim(coalesce(pa.email, ''))) = any (v_emails)
                or app.phone_e164(pa.phone) = any (v_phones)) then
    v_roles := array_append(v_roles, 'partner');
  end if;
  if exists (select 1 from investors i where (v_user is not null and i.user_id = v_user) or lower(btrim(coalesce(i.email, ''))) = any (v_emails)
              or app.phone_e164(i.phone) = any (v_phones)) then
    v_roles := array_append(v_roles, 'investor');
  end if;
  if v_user is not null and exists (select 1 from user_roles ur where ur.user_id = v_user and ur.role in ('admin', 'va', 'field')) then
    v_roles := array_append(v_roles, 'staff');
  end if;
  select r.id into v_renter from renters r
   where r.merged_into is null
     and (r.id = p_renter or (v_user is not null and r.user_id = v_user) or lower(btrim(coalesce(r.email, ''))) = any (v_emails) or app.phone_e164(r.mobile) = any (v_phones))
   order by (r.id = p_renter) desc nulls last, r.created_at limit 1;
  if v_renter is not null and (cardinality(v_roles) = 0 or exists (select 1 from bookings b where b.renter_id = v_renter and b.booking_type <> 'owner'
                                                                     and b.status not in ('cancelled', 'declined', 'expired'))) then
    v_roles := array_append(v_roles, 'renter');
  end if;
  return jsonb_build_object('roles', to_jsonb(v_roles), 'owner_id', v_owner);
end $$;
revoke all on function app.person_tags(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function app.person_tags(uuid, uuid, text, text) to service_role;

-- ---------------------------------------------------------------- Live visitors: roles on each visit and each hot visit
alter function app.live_visitors(uuid, jsonb) rename to live_visitors_pre0470;
create function app.live_visitors(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.live_visitors_pre0470(p_by, p);
begin
  if v is null then return v; end if;
  v := jsonb_set(v, '{now}', coalesce((select jsonb_agg(x || app.person_tags(s.user_id, nullif(x ->> 'renter_id', '')::uuid, coalesce(nullif(x ->> 'email', ''), s.known_email), null) order by n)
                                         from jsonb_array_elements(v -> 'now') with ordinality t(x, n)
                                         left join visitor_sessions s on s.id = nullif(x ->> 'id', '')::uuid), '[]'::jsonb));
  v := jsonb_set(v, '{hot}', coalesce((select jsonb_agg(x || app.person_tags(s.user_id, nullif(x ->> 'renter_id', '')::uuid, s.known_email, null) order by n)
                                         from jsonb_array_elements(coalesce(v -> 'hot', '[]'::jsonb)) with ordinality t(x, n)
                                         left join visitor_sessions s on s.id = nullif(x ->> 'id', '')::uuid), '[]'::jsonb));
  return v;
end $$;

-- ---------------------------------------------------------------- Live map: roles on each pin
alter function app.live_map(uuid, jsonb) rename to live_map_pre0470;
create function app.live_map(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.live_map_pre0470(p_by, p);
begin
  if v is null then return v; end if;
  return jsonb_set(v, '{pins}', coalesce((select jsonb_agg(x || app.person_tags(s.user_id, nullif(x ->> 'renter_id', '')::uuid, x ->> 'email', x ->> 'phone') order by n)
                                           from jsonb_array_elements(coalesce(v -> 'pins', '[]'::jsonb)) with ordinality t(x, n)
                                           left join visitor_sessions s on s.id = nullif(x ->> 'session_id', '')::uuid), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- captured contacts (Renter leads page): roles on each row
alter function app.captured_contacts(uuid, jsonb) rename to captured_contacts_pre0470;
create function app.captured_contacts(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.captured_contacts_pre0470(p_by, p);
begin
  if v is null then return v; end if;
  return jsonb_set(v, '{rows}', coalesce((select jsonb_agg(x || app.person_tags(c.user_id, nullif(x ->> 'renter_id', '')::uuid, x ->> 'email', x ->> 'phone') order by n)
                                           from jsonb_array_elements(coalesce(v -> 'rows', '[]'::jsonb)) with ordinality t(x, n)
                                           left join contact_captures c on c.id = nullif(x ->> 'id', '')::uuid), '[]'::jsonb));
end $$;

revoke all on function app.live_visitors(uuid, jsonb), app.live_visitors_pre0470(uuid, jsonb), app.live_map(uuid, jsonb), app.live_map_pre0470(uuid, jsonb),
  app.captured_contacts(uuid, jsonb), app.captured_contacts_pre0470(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.live_visitors(uuid, jsonb), app.live_visitors_pre0470(uuid, jsonb), app.live_map(uuid, jsonb), app.live_map_pre0470(uuid, jsonb),
  app.captured_contacts(uuid, jsonb), app.captured_contacts_pre0470(uuid, jsonb) to service_role;

-- ---------------------------------------------------------------- Visitor history: roles, score, cars, the page trail and the chat on each visit
create or replace function app.visit_history_extra(s visitor_sessions) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.person_tags(s.user_id, s.renter_id, s.known_email, null) || jsonb_build_object(
    'score', s.score,
    'cars_n', coalesce(cardinality(s.cars_viewed), 0),
    'cars', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', app.vehicle_name(c.id),
                        'photo', (select jsonb_build_object('path', ph.processed_path, 'variants', ph.variants, 'alt', ph.alt_text)
                                    from vehicle_photos ph where ph.vehicle_id = c.id and ph.is_cover and ph.is_public and ph.status = 'approved'
                                     and ph.replaced_at is null and ph.processed_path is not null limit 1)) order by c.ord)
                        from (select u.id, u.ord from unnest(s.cars_viewed) with ordinality u(id, ord) where u.ord <= 3) c), '[]'::jsonb),
    'trail', coalesce((select jsonb_agg(jsonb_build_object('at', e.at, 'path', e.path, 'page', app.path_label(e.path)) order by e.at)
                         from (select x.at, x.path from visitor_events x where x.session_id = s.id and x.kind = any (app.visit_page_kinds()) order by x.at limit 12) e), '[]'::jsonb),
    'chat', exists (select 1 from chat_conversations c where c.session_id = s.id))
$$;

alter function app.visitor_history(uuid, jsonb) rename to visitor_history_pre0470;
create function app.visitor_history(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.visitor_history_pre0470(p_by, p);
begin
  if v is null then return v; end if;
  return jsonb_set(v, '{rows}', coalesce((select jsonb_agg(x || coalesce(app.visit_history_extra(s), '{}'::jsonb) order by n)
                                           from jsonb_array_elements(coalesce(v -> 'rows', '[]'::jsonb)) with ordinality t(x, n)
                                           left join visitor_sessions s on s.id = nullif(x ->> 'id', '')::uuid), '[]'::jsonb));
end $$;
revoke all on function app.visit_history_extra(visitor_sessions), app.visitor_history(uuid, jsonb), app.visitor_history_pre0470(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.visit_history_extra(visitor_sessions), app.visitor_history(uuid, jsonb), app.visitor_history_pre0470(uuid, jsonb) to service_role;
