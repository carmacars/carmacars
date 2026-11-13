-- 2750 (release 43): a Sales person who closed a sale with a customer keeps that customer's conversation for good.
-- A sale is closed when a booking credited to the Sales person (bookings.sales_staff_id, 0057) reached confirmed, on rent,
-- returned or closed. From then on, on every booking of that renter (past, current and future, at any stage), the Sales
-- person reads the booking, its conversation (and replies in it) and its activity log. Nothing that moves money changes:
-- the booking read is the same reduced Sales view (no payments, refunds, statements or emails) and every action keeps its own rules.
-- No applied migration is edited: function bodies are patched in place.
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '2750: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

create function app.sales_owns_customer(p_user uuid, p_renter uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and p_renter is not null and app.user_va_has(p_user, 'sales')
     and exists (select 1 from bookings b
                  where b.renter_id = p_renter and b.sales_staff_id = p_user
                    and b.status::text in ('confirmed', 'on_rent', 'returned', 'closed'))
$$;
comment on function app.sales_owns_customer(uuid, uuid) is 'Release 43 (2750): the Sales person closed a sale with this renter (a booking credited to them reached confirmed or later), so they keep the renter''s conversations on every booking.';
revoke all on function app.sales_owns_customer(uuid, uuid) from public, anon, authenticated;
grant execute on function app.sales_owns_customer(uuid, uuid) to service_role;

-- the conversation (read and reply): the closer passes the Sales stage rule
select pg_temp.patch_fn('app.booking_email_problem(uuid, bookings)'::regprocedure,
  $o$when app.va_active_fn(p_by) = 'sales' and b.status::text not in ('requested', 'offered') then$o$,
  $n$when app.va_active_fn(p_by) = 'sales' and b.status::text not in ('requested', 'offered') and not app.sales_owns_customer(p_by, b.renter_id) then$n$);

-- the booking page: the closer reads the booking as Sales reads a booking waiting for payment
select pg_temp.patch_fn('app.va_booking(uuid, text, jsonb)'::regprocedure,
  $o$and (b.status = 'pending_payment' or (b.added_by_staff and b.created_by = p_user)) then$o$,
  $n$and (b.status = 'pending_payment' or (b.added_by_staff and b.created_by = p_user) or app.sales_owns_customer(p_user, b.renter_id)) then$n$);

-- the activity log of the booking (emails, texts, chat, calls), past the staff customer window too
select pg_temp.patch_fn('app.renter_activity(uuid, jsonb)'::regprocedure,
  $o$(b.renter_id is not null and not app.va_sees_renter(b.renter_id))$o$,
  $n$(b.renter_id is not null and not app.va_sees_renter(b.renter_id) and not app.sales_owns_customer(p_by, b.renter_id))$n$);
