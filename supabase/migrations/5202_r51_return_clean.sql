-- 5202 (R51 staff, REQ-133; docs/changes/2026-11-27-r51-staff.md): a car goes straight back to available after a return,
-- unless the return report says it needs cleaning. The owner (Nov 27 17:29): "these cleaning jobs seem like a headache".
-- 5195 (REQ-129) already lets a handover take a car in cleaning and puts it back to available when its detail job is done.
--   1. A return (booking returned) sets the car to available, not cleaning, when no return report of that booking says it
--      needs cleaning (cleanliness cleaning, heavy, pet or smoking). A car under exit notice still goes to exit notice.
--   2. A return report written or changed later that says it needs cleaning puts an available car in cleaning, when that
--      booking is its last rental (no rental of the car started since). The detail job then closes it (5195).
-- The status rules gain on_rent to available ("returned clean").
-- No applied migration is edited: booking_after_status is patched in place (the patch refuses when the text is not found).
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '5202: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

insert into status_transitions (entity, from_status, to_status, note) values ('vehicle', 'on_rent', 'available', 'returned clean (5202)')
on conflict do nothing;

-- the return report of this booking says the car needs cleaning (its latest return report)
create function app.return_needs_cleaning(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce((select r.cleanliness in ('cleaning', 'heavy', 'pet', 'smoking') from condition_reports r
                    where r.booking_id = p_booking and r.kind = 'return' and r.cleanliness is not null
                    order by r.performed_at desc, r.created_at desc limit 1), false)
$$;
comment on function app.return_needs_cleaning(uuid) is 'REQ-133 (5202): the latest return report of the booking says cleaning, heavy, pet or smoking.';

select pg_temp.patch_fn('app.booking_after_status()'::regprocedure,
  $o$then 'exit_notice'::vehicle_status else 'cleaning'::vehicle_status end
     where v.id = new.vehicle_id and v.status = 'on_rent';$o$,
  $n$then 'exit_notice'::vehicle_status
                         -- REQ-133 (5202): cleaning only when the return report says so
                         when app.return_needs_cleaning(new.id) then 'cleaning'::vehicle_status else 'available'::vehicle_status end
     where v.id = new.vehicle_id and v.status = 'on_rent';$n$);

-- a return report that says it needs cleaning, after the car is already available again
create function app.return_report_cleaning() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if new.kind = 'return' and new.booking_id is not null and new.cleanliness in ('cleaning', 'heavy', 'pet', 'smoking')
     and (tg_op = 'INSERT' or old.cleanliness is distinct from new.cleanliness)
     and app.return_needs_cleaning(new.booking_id)
     and exists (select 1 from bookings b where b.id = new.booking_id and b.status in ('returned', 'closed'))
     and not exists (select 1 from bookings o join bookings b on b.id = new.booking_id
                      where o.vehicle_id = new.vehicle_id and o.id <> b.id and o.status in ('on_rent', 'returned', 'closed')
                        and coalesce(o.handed_over_at, o.pickup_at) > coalesce(b.checked_in_at, b.return_at)) then
    update vehicles set status = 'cleaning' where id = new.vehicle_id and status = 'available';
  end if;
  return null;
end $$;
create trigger condition_reports_return_cleaning after insert or update of cleanliness on condition_reports
  for each row execute function app.return_report_cleaning();

revoke all on function app.return_needs_cleaning(uuid), app.return_report_cleaning() from public, anon, authenticated;
grant execute on function app.return_needs_cleaning(uuid), app.return_report_cleaning() to service_role;
