-- 2300_r37_unverified_requests.sql (release 37)
-- A booking request from someone whose licence is not verified yet shows "Not bookable until your licence is verified"
-- wherever the request is shown before a sign-in (/my-request, the contact-capture page): one rule in the database, the
-- same as the office's licence chip (0332 booking_cards): the renter's driver on the booking, or the renter, verified.
--   app.booking_licence_state(booking)          'verified' | 'pending' | 'missing'
--   public.server_booking_licence_state(numbers) {number: state} for the server only (service_role), at most 50 numbers

create or replace function app.booking_licence_state(p_booking uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when exists (select 1 from booking_drivers d where d.booking_id = b.id and d.role = 'renter' and d.identity_verified_on is not null) then 'verified'
    when exists (select 1 from booking_drivers d join drivers dr on dr.id = d.driver_id where d.booking_id = b.id and d.role = 'renter' and dr.identity_status = 'verified') then 'verified'
    when r.identity_status = 'verified' then 'verified'
    when exists (select 1 from booking_drivers d join drivers dr on dr.id = d.driver_id where d.booking_id = b.id and d.role = 'renter' and dr.identity_status = 'pending') then 'pending'
    when r.identity_status = 'pending' then 'pending'
    else 'missing' end
    from bookings b left join renters r on r.id = b.renter_id where b.id = p_booking
$$;
comment on function app.booking_licence_state(uuid) is 'Release 37 (2300): the booking''s renter licence state, verified | pending | missing (the 0332 licence chip''s rule). A request is bookable only once verified.';
revoke all on function app.booking_licence_state(uuid) from public, anon, authenticated;
grant execute on function app.booking_licence_state(uuid) to service_role;

create or replace function public.server_booking_licence_state(p_numbers text[]) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if coalesce(cardinality(p_numbers), 0) > 50 then raise exception 'At most 50 bookings' using errcode = '22023'; end if;
  return coalesce((select jsonb_object_agg(b.booking_number, app.booking_licence_state(b.id))
                     from bookings b where b.booking_number = any (coalesce(p_numbers, '{}'::text[]))), '{}'::jsonb);
end $$;
comment on function public.server_booking_licence_state(text[]) is 'Release 37 (2300): the licence state of up to 50 bookings by number, for the server (the unverified session''s /my-request).';
revoke all on function public.server_booking_licence_state(text[]) from public, anon, authenticated;
grant execute on function public.server_booking_licence_state(text[]) to service_role;
