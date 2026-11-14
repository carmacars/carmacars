-- 2912 (release 48): "the card must be in the renter's name" no longer breaks bookings.
--
-- The owner's report (Nov 14): bookings broke because the name on the card and the name on the licence differ a little
-- (a middle name, a longer or shorter first name, an initial, accents, the order, a hyphen). Root causes: the payment
-- step (web/src/server/portal/payment.ts) compared the cardholder name with the legal name ignoring only case and
-- spaces, and voided the card hold when they differed ("The card must be in the renter's name. Nothing was charged");
-- app.card_coverage_check (0071, app.same_person_name: punctuation and spaces only) refused credit card coverage the same way.
--
-- Now:
-- 1. app.card_name_matches: the names of 2910 (app.person_names_match: last name plus the first name or its initial,
--    middle names, order, accents, hyphens ignored) and a shortened first name ("Alex" for "Alexander").
-- 2. A card that still differs never blocks the renter: the payment goes through (the page no longer voids it), card
--    coverage is accepted, and staff get a To do "Check the name on the card" (card_name_review) on the booking.
-- 3. "Accept this card" (public.staff_accept_card_name): an Admin, or staff who verify bookings, accepts the card with
--    a short reason; it is logged on the booking's history and the To do is closed.
-- 4. Program setting card_name_check (on by default): off turns the rule off entirely (no To do, always a match).
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '2912: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
  execute replace(d, p_old, p_new);
end $$;

alter table program_settings add column if not exists card_name_check boolean not null default true;
comment on column program_settings.card_name_check is
  'The card must be in the renter''s name (2912): on, names are compared tolerantly and a card that still differs goes to staff review (never blocks); off, no check.';

alter table bookings add column if not exists card_name_accepted_at timestamptz,
                     add column if not exists card_name_accepted_by uuid references users (id),
                     add column if not exists card_name_accepted_reason text;
comment on column bookings.card_name_accepted_at is 'Staff accepted the card although its name differs from the renter''s (2912, "Accept this card").';

-- x's last word is in y and x's first word is y's first word shortened ("alex" of "alexander", at least 2 letters).
create or replace function app.person_name_short_covers(x text[], y text[]) returns boolean
language sql immutable as $$
  select cardinality(x) >= 2 and cardinality(y) >= 2 and x[cardinality(x)] = any (y)
     and exists (select 1 from unnest(y) t where t <> x[cardinality(x)] and length(x[1]) >= 2 and length(t) > length(x[1]) and left(t, length(x[1])) = x[1])
$$;

-- Is the card in this person's name? Tolerant (2910's rules and a shortened first name).
create or replace function app.card_name_matches(p_card text, p_name text) returns boolean
language sql immutable as $$
  select app.person_names_match(p_card, p_name)
      or app.person_name_short_covers(app.person_name_tokens(p_card), app.person_name_tokens(p_name))
      or app.person_name_short_covers(app.person_name_tokens(p_name), app.person_name_tokens(p_card))
$$;

-- The card's name is fine for this booking: the rule is off, staff accepted it, or it matches tolerantly.
create or replace function app.card_name_ok(p_booking uuid, p_card text, p_name text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select not coalesce((app.settings()).card_name_check, true)
      or exists (select 1 from bookings b where b.id = p_booking and b.card_name_accepted_at is not null)
      or app.card_name_matches(p_card, p_name)
$$;

-- Credit card coverage: tolerant, and a name that still differs is not a refusal (staff check it).
select pg_temp.patch_fn('app.card_coverage_check(uuid)'::regprocedure,
  $o$v_match := app.same_person_name(pm.cardholder_name, r.legal_name);$o$,
  $n$v_match := app.card_name_ok(b.id, pm.cardholder_name, r.legal_name);$n$);
select pg_temp.patch_fn('app.card_coverage_check(uuid)'::regprocedure,
  $o$elsif not v_match then v_problem := 'name_mismatch';$o$,
  $n$elsif false then v_problem := 'name_mismatch'; -- 2912: a name that differs goes to staff review, never refused$n$);

-- The card on file changes (a payment, a payment link): a name that still differs raises the To do.
create or replace function app.card_name_review() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_card text;
  v_name text;
begin
  if new.card_on_file_id is null or new.card_on_file_id is not distinct from old.card_on_file_id then return new; end if;
  select pm.cardholder_name into v_card from payment_methods pm where pm.id = new.card_on_file_id;
  select r.legal_name into v_name from renters r where r.id = new.renter_id;
  if nullif(btrim(coalesce(v_card, '')), '') is null or app.card_name_ok(new.id, v_card, v_name) then return new; end if;
  perform app.raise_task(p_type => 'card_name_review', p_title => 'Check the name on the card',
    p_detail => format('The card is in the name "%s"; the renter is "%s". The booking went ahead. Check the card and the licence at pickup, then press Accept this card with a short reason, or contact the renter.', left(v_card, 120), v_name),
    p_booking => new.id, p_renter => new.renter_id, p_queue => 'cs', p_priority => 'normal', p_dedupe => 'card_name_review:' || new.id || ':' || new.card_on_file_id);
  return new;
end $$;
drop trigger if exists bookings_card_name_review on bookings;
create trigger bookings_card_name_review after update of card_on_file_id on bookings for each row execute function app.card_name_review();

-- "Accept this card": an Admin, or staff who verify bookings, with a short reason; logged; the To do is closed.
create or replace function public.staff_accept_card_name(p_by uuid, p_booking uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_card text;
begin
  if p_by is null or not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then
    raise exception 'Only an Admin or staff who verify bookings accept a card' using errcode = '42501';
  end if;
  if v_reason is null or length(v_reason) < 4 then raise exception 'Say in a few words why this card is fine' using errcode = '22023'; end if;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  select pm.cardholder_name into v_card from payment_methods pm where pm.id = b.card_on_file_id;
  update bookings set card_name_accepted_at = now(), card_name_accepted_by = p_by, card_name_accepted_reason = left(v_reason, 300) where id = b.id;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by
   where booking_id = b.id and task_type = 'card_name_review' and status in ('open', 'in_progress', 'waiting');
  perform app.log_booking_event(b.id, 'verification', b.status::text, b.status::text, null, 'Card accepted: ' || left(v_reason, 300), p_by, 'staff',
    jsonb_build_object('what', 'card_name_accepted', 'cardholder_name', v_card, 'reason', left(v_reason, 300)));
  return jsonb_build_object('accepted', true, 'at', now());
end $$;

revoke all on function public.staff_accept_card_name(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.staff_accept_card_name(uuid, uuid, text) to service_role;
revoke all on function app.card_name_review() from public;
grant execute on function app.card_name_review() to service_role;
grant execute on function app.card_name_matches(text, text), app.person_name_short_covers(text[], text[]) to authenticated, service_role;

comment on function app.card_name_matches(text, text) is
  'The card is in this person''s name (2912): app.person_names_match or a shortened first name; nicknames are left to staff.';
