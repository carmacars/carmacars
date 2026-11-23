-- 3420 (hotfix, Nov 23, CC-10599): paying is never blocked, holds last as long as the offer, alerts stay on.
-- The owner (Nov 23): "make paying and booking easier, never harder".
--   1. The unpaid hold after an accepted offer (or Book it now) ended 2 hours after the approval (2961), even when the
--      offer itself was open longer or the pickup was later that day: CC-10599 lapsed and had to be reopened. Now the
--      hold lasts until the latest of: the approval plus offer_unpaid_hold_minutes, the offer's own expiry, and, for a
--      pickup within 24 hours of the approval, the pickup plus 2 hours. An expiry staff typed for an offer is no longer
--      cut to the pickup cut-off (only the default expiry is), and a default offer for a pickup within 24 hours stays
--      open at least until 2 hours after the pickup. Reopening an expired offer is open, by default, as long as the
--      original offer was (was 24 hours).
--   2. The licence and the OPCF 27 pages move from "before payment" to "before handover" (the handover already refuses
--      a car until every driver's identity is verified and the coverage is confirmed, 0011). Program settings
--      booking_licence_before_payment (new) and opcf27_before_payment: OFF. With the licence setting on, staff
--      recording "Renter approved by phone" still go ahead when the licence photos are there (any status but rejected),
--      and an Admin goes ahead with a reason (override_reason), logged in the history.
--   3. Paying needs no confirmed account any more (the email cap and failed texts left renters unable to confirm): a
--      signed-in renter who signed the agreement can always pay. Accepting still follows signin_confirm_required.
--   4. Phone alerts no longer switch themselves off: a push service refusing a message (400, 401, 403, 413) keeps the
--      device and records the error (before: 3 refusals deleted the device). Only 404/410 (the device is gone) remove it,
--      and the browser subscribes again by itself (3113).
-- No applied migration is edited: functions are patched in place (the patch refuses when the text is not found).
-- SCHEMA_MARKER 3420. docs/changes/2026-11-23-hotfix-offer-hold-pay.md.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '3420: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the hold and the offer's expiry
create or replace function app.unpaid_hold_until(b bookings) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select case
    when b.status = 'pending_payment' and b.booking_type::text <> 'owner' and not coalesce(b.is_placeholder, false)
     and coalesce(b.rental_pay_method, 'card') = 'card' and b.offer_approved_at is not null
     and coalesce((app.settings()).offer_unpaid_hold_minutes, 120) > 0
     and not exists (select 1 from payments p where p.booking_id = b.id and p.kind in ('charge', 'hold')
                       and (p.status in ('succeeded', 'authorized')
                            or (p.status in ('pending', 'requires_action') and p.created_at > now() - interval '30 minutes')))
    then greatest(
      b.offer_approved_at + make_interval(mins => coalesce((app.settings()).offer_unpaid_hold_minutes, 120)),
      -- 3420: never before the offer's own expiry (the accepted version's, as staff set it)
      (select o.expires_at from booking_offers o where o.booking_id = b.id and o.version = b.current_offer_version),
      -- 3420: a pickup within 24 hours of the approval: held until 2 hours after the pickup
      case when b.pickup_at is not null and b.pickup_at <= b.offer_approved_at + interval '24 hours' then b.pickup_at + interval '2 hours' end)
    end
$$;

-- an expiry staff typed is kept as typed; only the default is cut before the pickup, and a default for a pickup within
-- 24 hours stays open at least until 2 hours after the pickup
select pg_temp.patch_fn('app.issue_offer(uuid, uuid, text, timestamptz)'::regprocedure,
  $o$  if b.pickup_at is not null then
    if b.pickup_at - make_interval(mins => coalesce((app.settings()).offer_cutoff_before_pickup_minutes, 60)) > now() then$o$,
  $n$  if b.pickup_at is not null and p_expires_at is null then
    if b.pickup_at <= now() + interval '24 hours' then
      v_expires := greatest(v_expires, b.pickup_at + interval '2 hours');
    elsif b.pickup_at - make_interval(mins => coalesce((app.settings()).offer_cutoff_before_pickup_minutes, 60)) > now() then$n$);

-- reopening: open as long as the original offer was, unless staff give the hours
select pg_temp.patch_fn('app.reopen_offer(uuid, uuid, jsonb)'::regprocedure,
  $o$  v_hours integer := coalesce(nullif(p ->> 'hours', '')::numeric::integer, 24);$o$,
  $n$  v_hours integer := coalesce(nullif(p ->> 'hours', '')::numeric::integer,
    (select least(336, greatest(1, ceil(extract(epoch from (o.expires_at - o.sent_at)) / 3600)::integer)) from booking_offers o
      where o.booking_id = p_booking and o.expires_at > o.sent_at order by o.version desc limit 1),
    (app.settings()).offer_expiry_hours, 12);$n$);

-- ================================================================ 2. the licence and OPCF 27: before handover, not payment
alter table program_settings add column if not exists booking_licence_before_payment boolean not null default false;
comment on column program_settings.booking_licence_before_payment is
  'Off (3420, the default): the licence is checked before handover, never before accepting or paying. On: the licence is needed before an offer is accepted or paid (0130).';
alter table program_settings alter column opcf27_before_payment set default false;
update program_settings set opcf27_before_payment = false where opcf27_before_payment;

select pg_temp.patch_fn('app.licence_gate(uuid)'::regprocedure,
  $o$or not coalesce((app.settings()).booking_licence_required, true) then$o$,
  $n$or not coalesce((app.settings()).booking_licence_required, true)
     or not coalesce((app.settings()).booking_licence_before_payment, false) then$n$);

-- the licence photos on file for the booking's renter (any status but rejected), front and back
create or replace function app.licence_photos_on_file(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from booking_drivers bd where bd.booking_id = p_booking and bd.role = 'renter'
                   and bd.identity_verified_on is not null)
      or (select count(distinct u.kind) = 2 from booking_drivers bd
            join lateral (select distinct on (x.kind) x.kind, x.status from verification_uploads x
                           where x.booking_id = p_booking and x.driver_id = bd.driver_id and x.kind in ('licence_front', 'licence_back')
                             and x.status in ('submitted', 'approved', 'rejected') order by x.kind, x.uploaded_at desc) u on u.status <> 'rejected'
           where bd.booking_id = p_booking and bd.role = 'renter')
$$;
revoke all on function app.licence_photos_on_file(uuid) from public, anon, authenticated;
grant execute on function app.licence_photos_on_file(uuid) to service_role;

create or replace function app.approve_offer(p_booking uuid, p_version integer, p_by uuid, p_now timestamptz default now())
returns void language plpgsql security definer set search_path = public, app as $$
declare
  v_missing text[] := app.licence_gate(p_booking);
  v_reason text := nullif(btrim(coalesce(current_setting('app.licence_override_reason', true), '')), '');
  v_staff boolean := p_by is not null and app.user_is_staff(p_by)
                     and not exists (select 1 from bookings b join renters r on r.id = b.renter_id where b.id = p_booking and r.user_id = p_by);
  v_status text := (select b.status::text from bookings b where b.id = p_booking);
begin
  if cardinality(v_missing) > 0 then
    if v_staff and app.licence_photos_on_file(p_booking) then
      -- staff on the renter's word: the photos are there, the rest is checked before handover
      perform app.log_booking_event(p_booking, 'adjusted', v_status, v_status, p_version,
        format('Accepted by staff with the licence photos on file; still to check before handover: %s', array_to_string(v_missing, ', ')), p_by, 'staff');
    elsif v_staff and app.user_is_admin(p_by) and v_reason is not null then
      perform app.log_booking_event(p_booking, 'adjusted', v_status, v_status, p_version,
        format('Admin accepted without the licence (%s still needed): %s', array_to_string(v_missing, ', '), v_reason), p_by, 'staff');
    else
      raise exception 'Upload the driver''s licence before accepting the offer: % still needed%', array_to_string(v_missing, ', '),
        case when v_staff and app.user_is_admin(p_by) then ' (an Admin can accept anyway with a reason)' else '' end using errcode = '23514';
    end if;
  end if;
  perform app.approve_offer_pre0130(p_booking, p_version, p_by, p_now);
end $$;

-- Renter approved by phone: an Admin's reason (override_reason) lets the acceptance through without the licence
select pg_temp.patch_fn('app.admin_do_0030(uuid, text, jsonb)'::regprocedure,
  $o$    perform app.approve_offer(b.id, b.current_offer_version, p_admin, now());$o$,
  $n$    perform set_config('app.licence_override_reason', coalesce(nullif(btrim(p_ ->> 'override_reason'), ''), ''), true);
    perform app.approve_offer(b.id, b.current_offer_version, p_admin, now());
    perform set_config('app.licence_override_reason', '', true);$n$);

-- ================================================================ 3. paying needs no confirmed account
select pg_temp.patch_fn('app.account_gate(uuid, text)'::regprocedure,
  $o$if p_step <> 'sign' and s.signin_confirm_required and not app.account_confirmed(u.id) then$o$,
  $n$if p_step = 'accept' and s.signin_confirm_required and not app.account_confirmed(u.id) then$n$);

-- ================================================================ 4. alerts stay on
select pg_temp.patch_fn('app.server_push_result_pre3113(jsonb)'::regprocedure,
  $o$        delete from push_subscriptions where id = v_sub and refusals >= 3;
$o$,
  $n$        -- 3420: a refusal never removes the device (it switched alerts off on their own); the error stays on the row
$n$);

comment on function app.unpaid_hold_until(bookings) is
  'An accepted unpaid card booking holds the car until the latest of approval + offer_unpaid_hold_minutes, the offer''s expiry, and pickup + 2 hours for a pickup within 24 hours (2961, 3420).';
