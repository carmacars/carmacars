-- 2430_r40_book_now_choice.sql
-- Release 40: a renter who may book at once (a verified repeat renter, or Gold) had no choice: the request became a booking
-- waiting for payment. Now they choose: "Send request" leaves a request with no payment, as for a first booking, and a second
-- button "Book now" pays the website price. The website asks this function whether to show Book now; app.instant_book_check
-- (1304, 2421) stays the only rule for who is eligible, and public.server_instant_book (1304) is called only when the renter
-- presses Book now. Nothing else changes.
create function public.server_instant_book_available(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((app.instant_book_check((select r.id from renters r where r.user_id = p_user limit 1)) ->> 'eligible')::boolean, false);
$$;
revoke all on function public.server_instant_book_available(uuid) from public, anon, authenticated;
grant execute on function public.server_instant_book_available(uuid) to service_role;
