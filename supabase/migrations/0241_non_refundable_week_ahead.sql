-- 0241: the non-refundable discount is only for bookings made at least a week before pickup
-- (docs/changes/2026-10-31-non-refundable-week-ahead.md).
--
-- 1. program_settings.non_refundable_min_days (7): how many days before pickup a booking must be made to choose the
--    non-refundable discount. 0 turns the rule off.
-- 2. The rule holds on the renter's request and on every offer (status requested, offered, tentative, pending payment):
--    a booking that becomes non-refundable with pickup sooner than that, counted from when it was made, is refused with
--    the reason. A rental staff enter that is already confirmed or under way is not checked (its terms were agreed).
-- 3. site_facts carries the number for the request form, which then offers the choice only when the pickup is far enough.

alter table program_settings add column if not exists non_refundable_min_days integer not null default 7
  check (non_refundable_min_days between 0 and 60);
comment on column program_settings.non_refundable_min_days is
  'The non-refundable discount needs the booking made at least this many days before pickup (0241). 0: no minimum.';

create or replace function app.non_refundable_lead_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_days integer := coalesce((app.settings()).non_refundable_min_days, 0);
begin
  if new.booking_type = 'non_refundable'
     and v_days > 0
     and new.status::text in ('requested', 'offered', 'tentative', 'pending_payment')
     and (tg_op = 'INSERT' or old.booking_type is distinct from new.booking_type or old.pickup_at is distinct from new.pickup_at)
     and new.pickup_at < coalesce(new.booked_at, now()) + make_interval(days => v_days) then
    raise exception 'The non-refundable discount is only for bookings made at least % days before pickup. Choose a standard booking.', v_days
      using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function app.non_refundable_lead_guard() from public, anon, authenticated;
grant execute on function app.non_refundable_lead_guard() to service_role;

drop trigger if exists bookings_non_refundable_lead on bookings;
create trigger bookings_non_refundable_lead before insert or update of booking_type, pickup_at, status on bookings
  for each row execute function app.non_refundable_lead_guard();

create or replace function public.site_facts() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.public_site_facts() || jsonb_build_object('non_refundable_min_days', coalesce((app.settings()).non_refundable_min_days, 0))
$$;
