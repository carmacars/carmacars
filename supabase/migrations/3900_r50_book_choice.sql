-- 3900_r50_book_choice.sql
-- Release 50 (docs/changes/2026-11-24-r50-book-choice.md). The renter chooses, on the car page and in the
-- booking flow, "Book instantly" (pay now and it is confirmed) or "Request to book" (no charge; staff approve, then send a
-- pay link or an offer). This builds on the one instant system there is (1304, 2421, 2430): app.instant_book_check stays the
-- only rule for who may book at once, public.server_instant_book the only way a request becomes an instant booking. Nothing
-- about who is eligible changes. What is new is that the choice is recorded on the booking, with why an instant choice was
-- sent as a request when the database refused it, so staff see what the renter asked for.
--   1. bookings.book_choice ('instant' | 'request'; null for bookings staff made and those before r50) and
--      bookings.book_choice_note (why "Book instantly" became a request). The bookings audit trigger (0005) logs both.
--   2. app.book_choice(number, choice, user) / public.server_book_choice: right after the request, from the website.
--      request: recorded (a visitor's own fresh request, or the signed-in renter's). instant: recorded, then
--      server_instant_book; booked at once, the "We have your request" email and its text (still queued) are skipped,
--      since the renter is at Sign and pay; refused, the request stays in the staff queue as usual with the reason.
--      The first choice recorded stands (a second send of the same request changes nothing).
--   3. app.request_history (1300) carries book_choice and book_choice_note for the staff booking page.
-- No applied migration is edited.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '3900: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the choice on the booking
alter table bookings add column if not exists book_choice text check (book_choice in ('instant', 'request'));
alter table bookings add column if not exists book_choice_note text check (char_length(book_choice_note) <= 300);
comment on column bookings.book_choice is 'What the renter chose on the website (3900): instant (Book instantly: pay now, confirmed) or request (Request to book: staff approve first). Null: made by staff, or before r50.';
comment on column bookings.book_choice_note is 'Why a Book instantly choice was sent as a request (3900), for staff.';

-- ================================================================ 2. recording the choice (and booking at once)
create function app.book_choice(p_number text, p_choice text, p_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v text := nullif(btrim(lower(coalesce(p_choice, ''))), '');
  b bookings;
  r jsonb;
  v_note text;
begin
  if v is null or v not in ('instant', 'request') then raise exception 'Choose Book instantly or Request to book' using errcode = '22023'; end if;
  select * into b from bookings where booking_number = upper(btrim(coalesce(p_number, ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  -- the signed-in renter's own request; a visitor only their own fresh request, and only as a request (instant needs sign-in)
  if p_user is not null and not app.is_booking_renter(b.id, p_user) then return jsonb_build_object('ok', false, 'error', 'not_yours'); end if;
  if p_user is null and (v = 'instant' or b.created_at < now() - interval '30 minutes') then return jsonb_build_object('ok', false, 'error', 'not_permitted'); end if;
  -- the first answer stands (the request key makes a second send of the same request safe)
  if b.book_choice is not null then
    return jsonb_build_object('ok', true, 'choice', b.book_choice, 'instant', coalesce(b.instant_book, false), 'reason', b.book_choice_note, 'repeat', true);
  end if;
  update bookings set book_choice = v where id = b.id;
  if v = 'request' then return jsonb_build_object('ok', true, 'choice', 'request', 'instant', false); end if;

  r := public.server_instant_book(b.booking_number, p_user);
  if coalesce((r ->> 'instant')::boolean, false) then
    -- booked at once: "We have your request, nothing is booked" would be wrong; the renter is at Sign and pay
    update phone_outbox set status = 'skipped', status_reason = 'Booked instantly: the renter is at checkout (3900)'
     where status = 'queued' and notification_id in (select id from notification_outbox where booking_id = b.id and code = 'renter_request_received' and status in ('queued', 'delayed'));
    update notification_outbox set status = 'skipped', status_reason = 'Booked instantly: the renter is at checkout (3900)'
     where booking_id = b.id and code = 'renter_request_received' and status in ('queued', 'delayed');
    return r || jsonb_build_object('ok', true, 'choice', 'instant');
  end if;
  v_note := left('Asked to book instantly; sent as a request: ' || coalesce(r ->> 'reason', 'not allowed'), 300);
  update bookings set book_choice_note = v_note where id = b.id;
  return jsonb_build_object('ok', true, 'choice', 'instant', 'instant', false, 'reason', r ->> 'reason');
end $$;

create function public.server_book_choice(p_number text, p_choice text, p_user uuid default null) returns jsonb
language sql volatile security definer set search_path = public, app, pg_temp as $$ select app.book_choice(p_number, p_choice, p_user) $$;

-- ================================================================ 3. staff see the choice
select pg_temp.patch_fn('app.request_history(uuid, jsonb)'::regprocedure,
  '''instant_book'', coalesce((to_jsonb(b) ->> ''instant_book'')::boolean, false),',
  '''instant_book'', coalesce((to_jsonb(b) ->> ''instant_book'')::boolean, false), ''book_choice'', b.book_choice, ''book_choice_note'', b.book_choice_note,');

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['book_choice', 'request_history']))
        or (n.nspname = 'public' and p.proname = 'server_book_choice')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
