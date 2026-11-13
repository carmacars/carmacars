-- 2819 (release 44, part B): the server's door to this release's actions (one wrapper for 2810 to 2815).
--   ops_do booking_total_set      an Admin sets a booking's total at booking (2810)
--   ops_do agreement_after_trip   an Admin makes a signable agreement for a rental that has ended (2812); the site then
--                                 renders and opens it as staff
--   ops_do agreement_regenerate   "Make the agreements again": on a returned or closed booking with no agreement, an
--                                 Admin's click does the same as agreement_after_trip (it did nothing before); otherwise
--                                 as before (0154)
--   ops_read handover_missing     the past check-ins and check-outs missing their photos and readings (2815)
--   ops_do handover_missing_assign  an Admin or Fleet gives one to a field staff member (2815)
-- No applied migration is edited: the door is wrapped (_pre2819).

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2819;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
  b bookings;
begin
  if (p_call = 'ops_read' and p_name = 'handover_missing') or (p_call = 'ops_do' and p_name = 'handover_missing_assign') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    if p_name = 'handover_missing' then return app.handover_missing(p_user, p_); end if;
    return app.handover_missing_assign(p_user, p_);
  end if;
  if p_call = 'ops_do' and p_name in ('booking_total_set', 'agreement_after_trip', 'agreement_regenerate') then
    if p_name = 'agreement_regenerate' then
      select * into b from bookings where id::text = p_ ->> 'booking' or booking_number = p_ ->> 'booking' limit 1;
      if b.id is null or b.status::text not in ('returned', 'closed') or b.booking_type = 'owner'
         or exists (select 1 from rental_agreements a where a.booking_id = b.id and a.status in ('open', 'signed', 'completed')) then
        return app.door_pre2819(p_user, p_aal, p_call, p_name, p);
      end if;
    end if;
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    if p_name = 'booking_total_set' then return app.booking_total_set(p_user, p_); end if;
    if b.id is null then
      select * into b from bookings where id::text = p_ ->> 'booking' or booking_number = p_ ->> 'booking' limit 1;
    end if;
    return app.agreement_after_trip_start(p_user, coalesce(b.id, '00000000-0000-0000-0000-000000000000'::uuid))
           || jsonb_build_object('after_trip', true, 'renter_user_id', (select r.user_id from renters r where r.id = b.renter_id));
  end if;
  return app.door_pre2819(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2819(uuid, text, text, text, jsonb)'::regprocedure);
revoke all on function app.door_pre2819(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.door_pre2819(uuid, text, text, text, jsonb) to service_role;
