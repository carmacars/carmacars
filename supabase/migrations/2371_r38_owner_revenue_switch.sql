-- 2371_r38_owner_revenue_switch.sql (release 38)
-- Owner, Nov 11: insurer-billed rentals added by hand get "Counts toward the owner's revenue" (on by default). Off: the
-- booking is left out of the car owner's statements, payouts and earnings; it stays company revenue and stays on the
-- insurer invoice (both read the booking's lines and payments, not the owner split).
--   1. bookings.owner_revenue_excluded (+ _reason, _by, _at). Set on Add a rental (counts_for_owner false) for a rental
--      billed to an insurer, or later on the booking by app.booking_owner_revenue_set (door ops_do
--      booking_owner_revenue_set {booking, counts, reason}). Admin or staff; a reason is required to turn it off. Never
--      once the owner split is on an owner statement. Audited and on the booking's history.
--   2. app.compute_booking_split (wrapped): an excluded booking's splits not yet on a statement give the whole owner
--      revenue to the company (company share 100%, owner payout 0, as a flat arrangement does in 0196) and
--      are kept off every statement (payout month 9999-12, as 0156 does for a hidden booking's month to date). The owner
--      sees the car as unavailable for those dates (owner_visibility never).
-- No applied migration is edited: functions that change are wrapped (_pre2371).
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. the switch on the booking
alter table bookings
  add column if not exists owner_revenue_excluded boolean not null default false,
  add column if not exists owner_revenue_excluded_reason text check (owner_revenue_excluded_reason is null or length(owner_revenue_excluded_reason) <= 500),
  add column if not exists owner_revenue_excluded_by uuid references users (id),
  add column if not exists owner_revenue_excluded_at timestamptz;
comment on column bookings.owner_revenue_excluded is '"Counts toward the owner''s revenue" off (2371): an insurer-billed rental left out of the car owner''s statements, payouts and earnings; still company revenue and on the insurer invoice.';
create index if not exists bookings_owner_revenue_excluded_by_idx on bookings (owner_revenue_excluded_by) where owner_revenue_excluded_by is not null;

-- ================================================================ 2. the split
alter function app.compute_booking_split(uuid) rename to compute_booking_split_pre2371;
create function app.compute_booking_split(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.compute_booking_split_pre2371(p_booking);
  if exists (select 1 from bookings b where b.id = p_booking and b.owner_revenue_excluded) then
    update booking_splits
       set owner_revenue_cents = owner_revenue_cents + owner_expense_cents, owner_expense_cents = 0, booking_share_override = true,
           company_share_bps = 10000, company_share_cents = owner_revenue_cents + owner_expense_cents, owner_payout_cents = 0,
           payout_month = date '9999-12-01'
     where booking_id = p_booking and owner_statement_id is null;
  end if;
end $$;
select pg_temp.copy_grants('app.compute_booking_split(uuid)'::regprocedure, 'app.compute_booking_split_pre2371(uuid)'::regprocedure);

-- ================================================================ 3. set and taken back
create or replace function app.booking_owner_revenue_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_counts boolean := coalesce(nullif(p ->> 'counts', '')::boolean, true);
  v_reason text := btrim(coalesce(p ->> 'reason', ''));
begin
  if p_by is null or not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then
    raise exception 'Only an Admin or staff decide whether a rental counts toward the owner''s revenue' using errcode = '42501';
  end if;
  select * into b from bookings where id::text = coalesce(p ->> 'booking_id', p ->> 'booking') or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v_counts = not b.owner_revenue_excluded then return jsonb_build_object('booking_id', b.id, 'counts', v_counts, 'changed', false); end if;
  if not v_counts and b.bill_to is distinct from 'insurer' then
    raise exception 'Only a rental billed to an insurer can be left out of the owner''s revenue' using errcode = '22023';
  end if;
  if not v_counts and length(v_reason) < 3 then
    raise exception 'Give the reason the rental does not count toward the owner''s revenue' using errcode = '22023';
  end if;
  if exists (select 1 from booking_splits s where s.booking_id = b.id and s.owner_statement_id is not null) then
    raise exception 'Booking % is on an owner statement already: it can no longer change', b.booking_number using errcode = '23514';
  end if;
  update bookings set owner_revenue_excluded = not v_counts, owner_revenue_excluded_reason = case when v_counts then null else left(v_reason, 500) end,
         owner_revenue_excluded_by = case when v_counts then null else p_by end, owner_revenue_excluded_at = case when v_counts then null else now() end,
         owner_visibility = case when not v_counts then 'never' when owner_visibility = 'never' then 'shown' else owner_visibility end
   where id = b.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'owner_revenue_counts', 'bookings', b.id::text, jsonb_build_object('counts', not b.owner_revenue_excluded),
          jsonb_build_object('counts', v_counts, 'reason', nullif(v_reason, '')));
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    case when v_counts then 'Counts toward the owner''s revenue again' else format('Does not count toward the owner''s revenue: %s', left(v_reason, 500)) end, p_by, 'staff');
  if exists (select 1 from booking_splits s where s.booking_id = b.id) then perform app.compute_booking_split(b.id); end if;
  return jsonb_build_object('booking_id', b.id, 'counts', v_counts, 'changed', true);
end $$;

-- Add a rental: counts_for_owner false (with counts_for_owner_reason) on a rental billed to an insurer
alter function app.manual_rental_create(uuid, jsonb) rename to manual_rental_create_pre2371;
create function app.manual_rental_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
  v_off boolean := coalesce(nullif(p ->> 'counts_for_owner', '')::boolean, true) is false;
begin
  if not v_off then return app.manual_rental_create_pre2371(p_by, p - 'counts_for_owner' - 'counts_for_owner_reason'); end if;
  if coalesce(p #>> '{payment,method}', '') <> 'insurer' and jsonb_typeof(p -> 'insurance') is distinct from 'object' then
    raise exception 'Only a rental billed to an insurer can be left out of the owner''s revenue' using errcode = '22023';
  end if;
  if length(btrim(coalesce(p ->> 'counts_for_owner_reason', ''))) < 3 then
    raise exception 'Give the reason the rental does not count toward the owner''s revenue' using errcode = '22023';
  end if;
  v_out := app.manual_rental_create_pre2371(p_by, p - 'counts_for_owner' - 'counts_for_owner_reason');
  perform app.booking_owner_revenue_set(p_by, jsonb_build_object('booking_id', v_out ->> 'booking_id', 'counts', false, 'reason', p ->> 'counts_for_owner_reason'));
  return v_out || jsonb_build_object('counts_for_owner', false);
end $$;
select pg_temp.copy_grants('app.manual_rental_create(uuid, jsonb)'::regprocedure, 'app.manual_rental_create_pre2371(uuid, jsonb)'::regprocedure);

-- ================================================================ 4. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2371;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_do', 'va_do', 'admin_do') and p_name = 'booking_owner_revenue_set' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.booking_owner_revenue_set(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre2371(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2371(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['booking_owner_revenue_set', 'compute_booking_split_pre2371', 'manual_rental_create_pre2371', 'door_pre2371'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
