-- 1304_r35a_instant_book.sql
-- Release 35, part A (helper A), task 8 (docs/changes/2026-11-11-r35a-request-offers.md). The owner: instant booking for
-- verified repeat renters only. A renter with at least one completed rental, a verified licence on file, and no damage,
-- claims or unpaid balances books an available car at once (payment and agreement at checkout, the normal deposit rules);
-- everyone else keeps request to book. Program settings: instant_book_repeat_enabled (on by default) and
-- instant_book_min_rentals (1 by default). Staff see "Instant (repeat renter)" on the booking. An Admin can take a renter's
-- instant booking away (and give it back).
--   1. app.instant_book_check(renter): eligible or the first reason not (switched off, taken away by an Admin, too few
--      completed rentals, licence not verified, a damage or claim, money owing).
--   2. public.server_instant_book(booking number, user): right after the request (the web layer calls it for a signed-in
--      renter). When the renter is eligible, the request is a standard rental of theirs, the car is free and the licence
--      gate passes, the request becomes an offer accepted at once (the system's offer, approved by the renter): the booking
--      waits for payment and the renter goes to Sign and pay. The offer email is skipped (they are at checkout), the request's
--      To do closes, the booking says Instant (repeat renter) (bookings.instant_book). Anything else leaves the request as
--      it is, for staff as usual.
--   3. app.instant_book_set (ops_do instant_book_set, an Admin): take away or give back a renter's instant booking, with why.
--   4. app.instant_book_state (ops_read instant_book_state, staff): a renter's eligibility and the reason, for their page.
-- No applied migration is edited.
set local check_function_bodies = off;

alter table program_settings add column if not exists instant_book_repeat_enabled boolean not null default true;
alter table program_settings add column if not exists instant_book_min_rentals integer not null default 1 check (instant_book_min_rentals between 1 and 50);
comment on column program_settings.instant_book_repeat_enabled is 'Verified repeat renters book an available car at once, without a request (1304).';
comment on column program_settings.instant_book_min_rentals is 'Completed rentals a renter needs before instant booking (1304).';

alter table renters add column if not exists instant_book_revoked_at timestamptz;
alter table renters add column if not exists instant_book_revoked_by uuid references users(id) on delete set null;
alter table renters add column if not exists instant_book_revoked_reason text;
alter table bookings add column if not exists instant_book boolean not null default false;
comment on column bookings.instant_book is 'Booked at once by a verified repeat renter (1304): the request became an accepted offer without staff.';

create function app.instant_book_check(p_renter uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  r renters;
  v_done integer;
  v_why text;
begin
  select * into r from renters where id = p_renter;
  if r.id is null then return jsonb_build_object('eligible', false, 'reason', 'No renter'); end if;
  select count(*) into v_done from bookings b where b.renter_id = r.id and b.status = 'closed' and b.booking_type <> 'owner';
  v_why := case
    when not coalesce(s.instant_book_repeat_enabled, false) then 'Instant booking is switched off'
    when r.instant_book_revoked_at is not null then 'Taken away by an Admin' || coalesce(': ' || r.instant_book_revoked_reason, '')
    when coalesce(r.is_blocked, false) then 'The renter is blocked'
    when v_done < s.instant_book_min_rentals then format('%s of %s completed rentals', v_done, s.instant_book_min_rentals)
    when r.identity_status::text <> 'verified' then 'The licence is not verified'
    when exists (select 1 from bookings b join incidents i on i.booking_id = b.id where b.renter_id = r.id) then 'A damage or claim on a past rental'
    when exists (select 1 from bookings b join booking_line_items li on li.booking_id = b.id where b.renter_id = r.id and li.voided_at is null and li.amount_cents > 0
                   and li.charge_type in ('damage_at_cost', 'deductible', 'loss_of_use', 'recovery_cost')) then 'A damage or claim on a past rental'
    when exists (select 1 from bookings b where b.renter_id = r.id and b.status in ('returned', 'closed') and app.booking_balance_open(b.id) > 0) then 'Money owing on a past rental'
  end;
  return jsonb_build_object('eligible', v_why is null, 'reason', v_why, 'completed', v_done, 'needed', s.instant_book_min_rentals,
    'revoked_at', r.instant_book_revoked_at, 'revoked_reason', r.instant_book_revoked_reason);
end $$;

-- right after the request: p_number the booking, p_user the signed-in renter
create function public.server_instant_book(p_number text, p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  c jsonb;
  v_version integer;
begin
  select * into b from bookings where booking_number = upper(btrim(coalesce(p_number, ''))) for update;
  if b.id is null or p_user is null or not app.is_booking_renter(b.id, p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
  if b.status <> 'requested' or b.booking_type <> 'standard' or b.bill_to <> 'renter' or coalesce(b.is_placeholder, false) then
    return jsonb_build_object('instant', false, 'reason', 'Not a standard request');
  end if;
  c := app.instant_book_check(b.renter_id);
  if not (c ->> 'eligible')::boolean then return jsonb_build_object('instant', false, 'reason', c ->> 'reason'); end if;
  if cardinality(app.licence_gate(b.id)) > 0 then return jsonb_build_object('instant', false, 'reason', 'Licence needed'); end if;
  if not app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id) then return jsonb_build_object('instant', false, 'reason', 'The car is not free'); end if;
  begin
    v_version := app.issue_offer(b.id, null, 'Instant booking (repeat renter)', null);
    perform app.approve_offer(b.id, v_version, p_user);
  exception when others then
    -- anything refused: the request stays a request, for staff as usual
    return jsonb_build_object('instant', false, 'reason', sqlerrm);
  end;
  update bookings set instant_book = true where id = b.id;
  update notification_outbox set status = 'skipped', status_reason = 'Instant booking: the renter is at checkout (1304)'
   where booking_id = b.id and code = 'renter_offer_ready' and status in ('queued', 'delayed');
  update tasks set status = 'done', completed_at = now(), completion_note = 'Instant booking (repeat renter)'
   where booking_id = b.id and task_type = 'booking_request' and status in ('open', 'in_progress', 'waiting');
  perform app.log_booking_event(b.id, 'offer_approved', 'pending_payment', 'pending_payment', v_version,
    'Instant (repeat renter): booked at once, waiting for payment and the agreement at checkout', p_user, 'renter', jsonb_build_object('instant_book', true));
  return jsonb_build_object('instant', true, 'status', 'approved', 'booking_id', b.id, 'booking_number', b.booking_number, 'renter_user_id', p_user);
end $$;

-- an Admin: p {renter, revoke: true|false, reason}
create function app.instant_book_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r renters;
  v_revoke boolean := coalesce((p ->> 'revoke')::boolean, true);
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  if not app.user_is_admin(p_by) then raise exception 'An Admin takes away or gives back instant booking' using errcode = '42501'; end if;
  select * into r from renters where id::text = p ->> 'renter';
  if r.id is null then raise exception 'Renter not found' using errcode = 'P0002'; end if;
  if v_revoke and (v_reason is null or length(v_reason) < 5) then raise exception 'Say why (5 characters or more)' using errcode = '22023'; end if;
  update renters set instant_book_revoked_at = case when v_revoke then now() end, instant_book_revoked_by = case when v_revoke then p_by end,
         instant_book_revoked_reason = case when v_revoke then v_reason end where id = r.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, case when v_revoke then 'instant_book_revoked' else 'instant_book_restored' end, 'renters', r.id::text,
          jsonb_build_object('revoked_at', r.instant_book_revoked_at), jsonb_build_object('revoked', v_revoke, 'reason', v_reason));
  return app.instant_book_check(r.id);
end $$;

-- staff: p {renter} or {booking}
create function app.instant_book_state(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_renter uuid;
begin
  if not app.user_is_staff(p_by) then raise exception 'Staff only' using errcode = '42501'; end if;
  v_renter := coalesce((select id from renters where id::text = p ->> 'renter'),
                       (select renter_id from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')))));
  if v_renter is null then raise exception 'Renter not found' using errcode = 'P0002'; end if;
  return app.instant_book_check(v_renter) || jsonb_build_object('renter_id', v_renter, 'may_change', app.user_is_admin(p_by));
end $$;

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['instant_book_check', 'instant_book_set', 'instant_book_state']))
        or (n.nspname = 'public' and p.proname = 'server_instant_book')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
