-- 0041_sample_cars_not_compared.sql
-- The listing similarity check of 0040 compared the sample cars (vehicles.is_sample, 0035) with each other: their
-- placeholder VINs (SAMPLE01XXXXXXXXX, SAMPLE02XXXXXXXXX, ...) are one character apart, and a few happen to carry a
-- right check digit, so the live backfill opened 20 flags that stop the sample cars from being published again.
-- Sample cars are placeholders, not cars on file: no flag is raised for a pair where either car is a sample, and the
-- open flags of such pairs are removed (they raised no task or email: the backfill was quiet).
-- docs/changes/2026-10-14-operations-gaps.md
set local check_function_bodies = off;

alter function app.similarity_flag(uuid, uuid, text, integer, boolean, text) rename to similarity_flag_0040;
create function app.similarity_flag(p_vehicle uuid, p_other uuid, p_kind text, p_score integer, p_blocking boolean, p_detail text)
returns uuid language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from vehicles v where v.id in (p_vehicle, p_other) and v.is_sample) then return null; end if;
  return app.similarity_flag_0040(p_vehicle, p_other, p_kind, p_score, p_blocking, p_detail);
end $$;
revoke all on function app.similarity_flag(uuid, uuid, text, integer, boolean, text) from public;
grant execute on function app.similarity_flag(uuid, uuid, text, integer, boolean, text) to service_role;
revoke all on function app.similarity_flag_0040(uuid, uuid, text, integer, boolean, text) from public;
grant execute on function app.similarity_flag_0040(uuid, uuid, text, integer, boolean, text) to service_role;

delete from listing_similarity_flags f
 where f.status = 'open'
   and exists (select 1 from vehicles v where v.id in (f.vehicle_id, f.other_vehicle_id) and v.is_sample);
