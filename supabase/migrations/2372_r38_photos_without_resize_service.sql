-- 2372_r38_photos_without_resize_service.sql (release 38)
-- Owner, Nov 11: listings Failed or stuck "Processing photos" with "rate limited or over the month's allowance" (the image
-- service). Every size is made in the Worker already (r35, integrations/photos/local.ts); only the cut-out uses the
-- service, and a cut-out refused for the quota publishes the photo without it, flagged to redo (0080 queues it again).
--   1. app.listing_photos_reprocess_local(p_by): Admin > Listings, "Process photos without the resize service": every
--      listing not published or cancelled whose photo steps failed or are stuck (queued again and again, or running for
--      more than 30 minutes) is queued again with input.local_only: the worker then makes the sizes here and, when the
--      cut-out is not made at once, publishes the photo without it (flagged background_not_replaced). A failed listing
--      goes back to processing photos. Admin only; audited. Returns how many listings and steps.
--   2. The door: admin_do listing_photos_reprocess_local.
create or replace function app.listing_photos_reprocess_local(p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_jobs integer := 0;
  v_intakes integer := 0;
begin
  perform app.assert_admin(p_by);
  with picked as (
    select j.id from listing_jobs j join listing_intakes i on i.id = j.intake_id
     where j.kind in ('process_photo', 'resize') and i.state not in ('published', 'cancelled')
       and (j.status = 'failed'
            or (j.status = 'queued' and j.attempts > 0)
            or (j.status = 'running' and j.locked_at < now() - interval '30 minutes'))
     for update of j
  ), upd as (
    update listing_jobs j set status = 'queued', attempts = 0, next_attempt_at = now(), error = null, finished_at = null, locked_at = null, locked_by = null,
           input = coalesce(j.input, '{}'::jsonb) || jsonb_build_object('local_only', true)
      from picked where j.id = picked.id
    returning j.intake_id, j.photo_job_id, j.vehicle_photo_id, j.kind
  ), pj as (
    update photo_jobs p set status = 'queued', attempts = 0, next_attempt_at = now(), error = null, finished_at = null
      from upd where p.id = upd.photo_job_id and p.status in ('failed', 'queued', 'running')
    returning p.id
  ), vp as (
    update vehicle_photos v set background_status = 'pending'
      from upd where v.id = upd.vehicle_photo_id and upd.kind = 'process_photo' and v.background_status = 'failed'
    returning v.id
  ), it as (
    update listing_intakes i set state = 'processing_photos', reason = null, failed_at = null, retries = retries + 1
     where i.id in (select intake_id from upd) and i.state = 'failed'
    returning i.id
  )
  select (select count(*) from upd), (select count(distinct intake_id) from upd) into v_jobs, v_intakes;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'listing_photos_reprocess_local', 'listing_jobs', null, jsonb_build_object('steps', v_jobs, 'listings', v_intakes));
  return jsonb_build_object('steps', v_jobs, 'listings', v_intakes);
end $$;
revoke all on function app.listing_photos_reprocess_local(uuid) from public, anon, authenticated;
grant execute on function app.listing_photos_reprocess_local(uuid) to service_role;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2372;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('admin_do', 'ops_do') and p_name = 'listing_photos_reprocess_local' then
    perform app.door_begin(p_user, p_aal);
    return app.listing_photos_reprocess_local(p_user);
  end if;
  return app.door_pre2372(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2372(uuid, text, text, text, jsonb)'::regprocedure);
revoke all on function app.door_pre2372(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.door_pre2372(uuid, text, text, text, jsonb) to service_role;
