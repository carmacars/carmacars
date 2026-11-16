-- 3055 (release 48, part 2): "Licence and selfie verified" ticks when the review screen shows the driver's licence and
-- selfie approved (docs/changes/2026-11-15-r48-review-readiness.md).
--
-- A driver was marked verified (booking_drivers.identity_verified_on, which the readiness, the review screen's
-- "Identity verified" and the pickup read) only when the third of their licence front, back and selfie was approved on
-- this booking. A driver whose licence or selfie was approved on an earlier booking (the reused licence of 0602) and
-- whose other images were approved here stayed unverified, so the checklist line stayed unticked after Approve all.
-- Now app.booking_driver_verify_sync marks a driver verified as soon as each of the three is approved (on this booking,
-- or on the driver's earlier booking when this one has none of that kind) and none is waiting or rejected here; it runs
-- after every approval and for the bookings still to be picked up.
set local check_function_bodies = off;

create or replace function app.booking_driver_verify_sync(p_booking uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  d booking_drivers;
  v_n integer := 0;
  v_ok boolean;
begin
  for d in select * from booking_drivers where booking_id = p_booking and identity_verified_on is null and driver_id is not null loop
    -- the newest upload of each kind on this booking, else the driver's newest approved one anywhere
    select coalesce(bool_and(coalesce(
             (select u.status = 'approved' from verification_uploads u where u.booking_id = p_booking and u.driver_id = d.driver_id and u.kind = k
               and u.status in ('submitted', 'approved', 'rejected') order by u.uploaded_at desc limit 1),
             exists (select 1 from verification_uploads u where u.driver_id = d.driver_id and u.kind = k and u.status = 'approved'))), false)
      into v_ok from unnest(array['licence_front', 'licence_back', 'selfie']) k;
    if v_ok then
      update booking_drivers set identity_verified_on = app.today(), identity_method = coalesce(identity_method, 'staff_review') where id = d.id;
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $$;
revoke all on function app.booking_driver_verify_sync(uuid) from public, anon, authenticated;
grant execute on function app.booking_driver_verify_sync(uuid) to service_role;

create or replace function app.verification_upload_verify_sync() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved' and new.booking_id is not null and new.kind in ('licence_front', 'licence_back', 'selfie') then
    perform app.booking_driver_verify_sync(new.booking_id);
  end if;
  return new;
end $$;
revoke all on function app.verification_upload_verify_sync() from public, anon, authenticated;
drop trigger if exists verification_uploads_verify_sync on verification_uploads;
create trigger verification_uploads_verify_sync after update of status on verification_uploads for each row execute function app.verification_upload_verify_sync();

-- the bookings still to be picked up
select app.booking_driver_verify_sync(b.id) from bookings b
 where b.status::text in ('offered', 'pending_payment', 'tentative', 'confirmed')
   and exists (select 1 from booking_drivers d where d.booking_id = b.id and d.identity_verified_on is null);
