-- 5186 (R50 hotfix 2): the server's door to Add old photos (5185), and the report shows those photos.
--   ops_read old_photo_bookings     the past bookings of the window, searchable (q)
--   ops_read old_photo_suggest      the bulk flow's suggestion for each group of photos
--   ops_read old_photo_gate         before an upload is stored
--   ops_read old_photo_plate_gate   before a plate is read by the vision model
--   ops_do   old_photo_attach       one photo on the check-in or check-out report
--   ops_do   old_photo_plate_record the vision call, recorded with its model and neurons (never the photo or the plate)
-- app.handover_report: each photo says whether it was added later, by whom and when; a check-in or check-out report not
-- completed yet is shown when it has photos added later (otherwise those photos would show nowhere).
-- The renter's copy (server_renter_handover_report) drops the photos added later and any report not completed (an owner's
-- browser session never reads those photos: the restrictive policy of 5185). A capture time shows only when the phone's
-- time was inside the booking's own dates (5185 keeps the claim as the device time and the capture time apart).
-- No applied migration is edited: the door is wrapped (_pre5186), handover_report is patched in place (its grants kept).

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '5186: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5186;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if (p_call = 'ops_read' and p_name in ('old_photo_bookings', 'old_photo_suggest', 'old_photo_gate', 'old_photo_plate_gate'))
     or (p_call = 'ops_do' and p_name in ('old_photo_attach', 'old_photo_plate_record')) then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'old_photo_bookings' then app.old_photo_bookings(p_user, p_)
      when 'old_photo_suggest' then app.old_photo_suggest(p_user, p_)
      when 'old_photo_gate' then app.old_photo_gate(p_user, p_)
      when 'old_photo_plate_gate' then app.old_photo_plate_gate(p_user)
      when 'old_photo_attach' then app.old_photo_attach(p_user, p_)
      else app.old_photo_plate_record(p_user, p_) end;
  end if;
  return app.door_pre5186(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5186(uuid, text, text, text, jsonb)'::regprocedure);
revoke all on function app.door_pre5186(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.door_pre5186(uuid, text, text, text, jsonb) to service_role;

-- the report: "Added later by <name>" with the capture time, and a report with such photos shown before it is completed
select pg_temp.patch_fn('app.handover_report(uuid)'::regprocedure,
  $o$'angle', p.angle,$o$,
  $n$'angle', p.angle, 'added_later_at', p.added_later_at,
                                     'added_later_by', case when p.added_later_at is not null then (select u.full_name from users u where u.id = p.uploaded_by) end,$n$);
select pg_temp.patch_fn('app.handover_report(uuid)'::regprocedure,
  $o$c.kind in ('pickup', 'return', 'swap_out', 'swap_in') and c.completed_at is not null)$o$,
  $n$c.kind in ('pickup', 'return', 'swap_out', 'swap_in')
         and (c.completed_at is not null or exists (select 1 from condition_report_photos lp where lp.condition_report_id = c.id and lp.added_later_at is not null)))$n$);

-- an added-later photo shows its capture time only when it was accepted (taken_at is the device time); otherwise none
select pg_temp.patch_fn('app.handover_report(uuid)'::regprocedure,
  $o$'taken_at', coalesce(p.device_taken_at, p.taken_at),$o$,
  $n$'taken_at', case when p.added_later_at is not null and p.device_taken_at is not null and p.device_taken_at <> p.taken_at then null
                                                 else coalesce(p.device_taken_at, p.taken_at) end,$n$);

-- the renter sees the completed check-in and check-out, without the photos added later
create or replace function public.server_renter_handover_report(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare r jsonb;
begin
  perform app.assert_booking_renter(p_booking, p_by);
  r := app.handover_report(p_booking) - 'waivers';
  return jsonb_set(r, '{reports}', coalesce((
    select jsonb_agg(jsonb_set(x, '{photos}', coalesce((select jsonb_agg(ph) from jsonb_array_elements(x -> 'photos') ph where ph ->> 'added_later_at' is null), '[]'::jsonb)) order by o)
      from jsonb_array_elements(r -> 'reports') with ordinality t(x, o) where x ->> 'completed_at' is not null), '[]'::jsonb));
end $$;
