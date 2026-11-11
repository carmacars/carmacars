-- 1309_r35a_door.sql
-- Release 35, part A (helper A): the staff door's new reads (docs/changes/2026-11-11-r35a-request-offers.md).
--   ops_read request_history   the original request, every offer version and the coverage card (1300)
--   ops_read offer_revert      the changes that bring the review back to an old offer version, to send (1300)
--   ops_read secondary_contact the booking's secondary contact (1302)
--   ops_read rideshare_docs    the rideshare documents asked for and the letters' facts (1303)
--   ops_read instant_book_state a renter's instant booking: eligible or why not (1304)
--   ops_do   instant_book_set   an Admin takes a renter's instant booking away or gives it back (1304)
-- Each function checks who may call it. No applied migration is edited.
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

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1309;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_read' and p_name in ('request_history', 'offer_revert', 'secondary_contact', 'rideshare_docs', 'instant_book_state') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name
      when 'request_history' then app.request_history(p_user, p)
      when 'offer_revert' then app.offer_revert_prepare(p_user, p)
      when 'secondary_contact' then app.booking_secondary_contact(p_user, p)
      when 'instant_book_state' then app.instant_book_state(p_user, p)
      else app.rideshare_docs_staff(p_user, p) end;
  end if;
  if p_call = 'ops_do' and p_name = 'instant_book_set' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.instant_book_set(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre1309(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1309(uuid, text, text, text, jsonb)'::regprocedure);
revoke all on function app.door_pre1309(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.door_pre1309(uuid, text, text, text, jsonb) to service_role;
