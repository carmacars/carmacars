-- 0810_r34o_book_now_connector.sql
-- Release 34 part O (docs/changes/2026-11-08-r34-book-now-connector.md). SCHEMA_MARKER 0811. No applied migration is edited.
--   1. Book it now (0770) from Claude's connector and the in-app assistant. The connector's send_offer and create_offer and the
--      assistant's create_offer already reach app.door, which books the offer when it carries book_now (app.offer_book_now); the
--      web layer lists the field and makes the renter's agreement after the confirmed call. New here: booking an offer that is
--      already out, by one door action (ops_do offer_book_now) that calls the same app.offer_book_now: the connector tool
--      book_offer_now (two steps: preview, then confirm) and the assistant tool book_offer_now (a card, then Confirm). An Admin
--      books at once; staff (the assistant) ask, and an Admin approves in one tap (alert and To do), as on the screens.
--   2. A booking that superseded a duplicate expired request (bookings.superseded_by, 0780): the read booking_chain answers
--      "replaced by" and "replaces" with the numbers, for both bookings' Admin and staff pages.
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

-- ================================================================ 1. book an offer that is already out
-- p {booking: id or number, reason?}: an Admin books it at once; staff ask (app.offer_book_now decides)
create function app.offer_book_now_door(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid;
begin
  select id into v_id from bookings
   where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', p ->> 'booking_number', '')));
  if v_id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  return app.offer_book_now(p_by, v_id, coalesce(p ->> 'reason', p ->> 'book_now_reason'));
end $$;

-- ================================================================ 2. the chain of a superseded request
-- p {booking: id or number}: {number, replaced_by: {id, number, status} | null, replaces: [{id, number, status}]}
create function app.booking_chain(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare b bookings;
begin
  if not app.user_is_staff(p_by) then raise exception 'Staff only' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', p ->> 'booking_number', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('number', b.booking_number,
    'replaced_by', (select jsonb_build_object('id', n.id, 'number', n.booking_number, 'status', n.status) from bookings n where n.id = b.superseded_by),
    'replaces', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'number', o.booking_number, 'status', o.status) order by o.created_at) from bookings o where o.superseded_by = b.id), '[]'::jsonb));
end $$;

-- ================================================================ 3. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0810;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call = 'ops_do' and p_name = 'offer_book_now') or (p_call = 'ops_read' and p_name = 'booking_chain') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name when 'offer_book_now' then app.offer_book_now_door(p_user, p) else app.booking_chain(p_user, p) end;
  end if;
  return app.door_pre0810(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0810(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 4. the connector's tool and the assistant's tool
alter function app.api_action(text) rename to api_action_pre0810;
create function app.api_action(p_tool text) returns jsonb
language sql immutable as $$
  select case p_tool
    when 'book_offer_now' then '{"call":"ops_do","name":"offer_book_now","target":"booking"}'::jsonb
    else app.api_action_pre0810(p_tool) end
$$;

alter function app.assistant_action_door(text, text, text) rename to assistant_action_door_pre0810;
create function app.assistant_action_door(p_tool text, p_portal text, p_name text) returns text
language sql immutable as $$
  select case
    when p_tool = 'book_offer_now' and p_name = 'offer_book_now' and p_portal in ('admin', 'va') then 'ops_do'
    else app.assistant_action_door_pre0810(p_tool, p_portal, p_name) end
$$;

-- ================================================================ 5. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['offer_book_now_door', 'booking_chain', 'door_pre0810', 'api_action_pre0810', 'assistant_action_door_pre0810'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
select pg_temp.copy_grants('app.api_action(text)'::regprocedure, 'app.api_action_pre0810(text)'::regprocedure);
select pg_temp.copy_grants('app.assistant_action_door(text, text, text)'::regprocedure, 'app.assistant_action_door_pre0810(text, text, text)'::regprocedure);
