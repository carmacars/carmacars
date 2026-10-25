-- 0156_owner_hide_revenue.sql
-- Hide a booking's revenue from the owner until it is revealed (docs/changes/2026-10-25-hide-revenue-from-owner.md). The
-- owner: "I just want to make sure that you implemented the thing where we can hide the revenue from a booking from a car
-- owner and they don't see it right away".
--
-- 1. bookings.owner_visibility: shown (the owner sees the booking and its amounts), until_return (hidden until the car is
--    back), until_statement (hidden until the monthly owner statement covering it is approved), never (a booking with no
--    owner revenue: an internal or placeholder booking for insurance, a shareholder's or the owner's own no-cost use; the
--    owner sees only that the car is unavailable for those dates). A new booking takes the Program setting
--    owner_revenue_visibility (right away by default); staff (an Admin, customer service or fleet) override it on Add a
--    rental, on an offer and on the booking page, with an optional reason, logged in booking_owner_visibility_log.
-- 2. app.booking_owner_view: what the owner may see of a booking: full, booked (the dates and status, no amount) or
--    unavailable (the dates only: no booking number, no amount, no renter). "never" on a booking that carries owner revenue
--    is treated as hidden until the statement: an owner is never shown a lower amount than the statement pays.
-- 3. The owner's reads enforce it in the database: owner_portal_bookings (a new column owner_view), the owner_bookings
--    view, the owner's row policies on booking_splits and owner_deductions, and the month to date of 0151 (a hidden
--    booking is left out of the provisional figures; an unavailable one is listed without its number).
-- 4. The statement is never changed: every booking is on it at its true amounts, so payouts are right. Approving the
--    statement reveals every hidden booking on it (an unavailable one, with no owner revenue, stays as it is).
-- 5. The owner emails with amounts (owner_new_booking, owner_booking_changed) leave the amounts out while hidden
--    (show_amounts); the owner booking notices of an unavailable booking are not sent at all.
-- 6. The staff door: the booking's visibility (read and set), the defaults for the forms, and the visibility given when a
--    rental is added or an offer made.
-- 7. Privileges and the guides.
-- 8. Documented owner deductions on a booking (an expense line, a Revenue Share for the booking within the signed terms):
--    itemized on the statement and in the owner portal, in the booking history, worked into the split.
-- No applied migration is edited.

-- ================================================================ 1. the setting, the column, the log
alter table program_settings add column if not exists owner_revenue_visibility text not null default 'right_away';
alter table program_settings drop constraint if exists program_settings_owner_revenue_visibility_check;
alter table program_settings add constraint program_settings_owner_revenue_visibility_check
  check (owner_revenue_visibility in ('right_away', 'after_return', 'statement'));
comment on column program_settings.owner_revenue_visibility is 'When owners see the revenue of a new booking on their car: right_away (default), after_return, statement (when the monthly owner statement covering it is approved). Staff override it per booking (0156).';

alter table bookings add column if not exists owner_visibility text default 'shown';
update bookings set owner_visibility = 'shown' where owner_visibility is null;
alter table bookings alter column owner_visibility set not null;
alter table bookings alter column owner_visibility drop default;
alter table bookings drop constraint if exists bookings_owner_visibility_check;
alter table bookings add constraint bookings_owner_visibility_check check (owner_visibility in ('shown', 'until_return', 'until_statement', 'never'));
alter table bookings add column if not exists owner_visibility_reason text,
  add column if not exists owner_visibility_by uuid references users (id),
  add column if not exists owner_visibility_at timestamptz;
comment on column bookings.owner_visibility is 'What the owner sees of this booking (0156): shown, until_return, until_statement (revealed when the statement covering it is approved), never (no owner revenue: the owner sees only that the car is unavailable).';

create table if not exists booking_owner_visibility_log (
  id              bigint generated always as identity primary key,
  booking_id      uuid not null references bookings (id) on delete cascade,
  visibility_from text,
  visibility_to   text not null,
  reason          text,
  how             text not null default 'staff' check (how in ('staff', 'new_booking', 'statement')),
  changed_by      uuid references users (id),
  changed_at      timestamptz not null default now()
);
create index if not exists booking_owner_visibility_log_booking_idx on booking_owner_visibility_log (booking_id, changed_at);
comment on table booking_owner_visibility_log is 'Every change of what the owner sees of a booking (0156): who, when, from what to what and why. Append-only.';
alter table booking_owner_visibility_log enable row level security;
revoke all on booking_owner_visibility_log from anon, authenticated;
grant select, insert on booking_owner_visibility_log to service_role;
drop policy if exists admin_all on booking_owner_visibility_log;
create policy admin_all on booking_owner_visibility_log for select to authenticated using (app.is_admin());
drop trigger if exists audit_booking_owner_visibility_log on booking_owner_visibility_log;
create trigger audit_booking_owner_visibility_log after insert on booking_owner_visibility_log for each row execute function app.audit_row();

create or replace function app.booking_owner_visibility_log_append_only() returns trigger
language plpgsql as $$
begin
  raise exception 'The owner visibility log is kept as it was recorded' using errcode = '42501';
end $$;
drop trigger if exists booking_owner_visibility_log_append_only on booking_owner_visibility_log;
create trigger booking_owner_visibility_log_append_only before update or delete on booking_owner_visibility_log
  for each row execute function app.booking_owner_visibility_log_append_only();

-- the booking's documented owner deductions (section 8): an expense line, or the booking's own Revenue Share
create table if not exists booking_owner_expenses (
  id           uuid primary key default gen_random_uuid(),
  booking_id   uuid not null references bookings (id) on delete cascade,
  category     text not null check (category in ('cleaning', 'repair', 'fuel', 'platform_fee', 'other')),
  amount_cents bigint not null check (amount_cents > 0),
  reason       text not null check (length(btrim(reason)) >= 5),
  receipt_ref  text,
  created_by   uuid references users (id),
  created_at   timestamptz not null default now(),
  voided_at    timestamptz,
  voided_by    uuid references users (id),
  void_reason  text
);
create index if not exists booking_owner_expenses_booking_idx on booking_owner_expenses (booking_id);
comment on table booking_owner_expenses is 'A documented expense of a booking that comes off before Owner Revenue (0156): itemized on the owner''s statement and in the owner portal. Voided, never deleted.';
create table if not exists booking_owner_shares (
  booking_id        uuid primary key references bookings (id) on delete cascade,
  company_share_bps integer not null check (company_share_bps between 0 and 10000),
  terms_bps         integer not null check (terms_bps between 0 and 10000),
  above_terms       boolean not null default false,
  reason            text not null check (length(btrim(reason)) >= 5),
  set_by            uuid references users (id),
  set_at            timestamptz not null default now()
);
comment on table booking_owner_shares is 'A Revenue Share for one booking (0156): within the car''s signed terms (terms_bps, stored on the booking), above them only by an Admin with a reason. Shown on the statement and in the owner portal.';
alter table booking_owner_expenses enable row level security;
alter table booking_owner_shares enable row level security;
revoke all on booking_owner_expenses, booking_owner_shares from anon, authenticated;
grant select, insert, update, delete on booking_owner_expenses, booking_owner_shares to service_role;
drop policy if exists admin_all on booking_owner_expenses;
create policy admin_all on booking_owner_expenses for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop policy if exists admin_all on booking_owner_shares;
create policy admin_all on booking_owner_shares for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop trigger if exists audit_booking_owner_expenses on booking_owner_expenses;
create trigger audit_booking_owner_expenses after insert or update or delete on booking_owner_expenses for each row execute function app.audit_row();
drop trigger if exists audit_booking_owner_shares on booking_owner_shares;
create trigger audit_booking_owner_shares after insert or update or delete on booking_owner_shares for each row execute function app.audit_row();
alter table booking_splits add column if not exists owner_expense_cents bigint not null default 0,
  add column if not exists booking_share_override boolean not null default false;
alter table booking_splits drop constraint if exists booking_splits_owner_revenue;
alter table booking_splits add constraint booking_splits_owner_revenue
  check (owner_revenue_cents = rental_charge_cents + mileage_overage_cents - kickback_cents - partner_markup_cents - owner_expense_cents);
alter table owner_statement_lines add column if not exists owner_expense_cents bigint not null default 0,
  add column if not exists booking_share_bps integer;
comment on column booking_splits.owner_expense_cents is 'The booking''s documented expenses taken off before Owner Revenue (0156).';
comment on column owner_statement_lines.owner_expense_cents is 'The booking''s documented expenses taken off before Owner Revenue (0156); the description lists each.';
comment on column owner_statement_lines.booking_share_bps is 'The Revenue Share set for this booking, when it differs from the car''s terms (0156).';

-- the booking history's kinds (the 0130 pattern: rebuilt from what is there plus the new ones)
do $$
declare
  c record;
  v_kinds text[];
begin
  select conname, pg_get_constraintdef(oid) as def into strict c from pg_constraint
   where conrelid = 'public.booking_events'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%kind%';
  select array_agg(distinct m[1]) into v_kinds from regexp_matches(c.def, '[''{,]([a-z_0-9]+)(?=[''},])', 'g') m;
  select array_agg(distinct x order by x) into v_kinds from unnest(v_kinds || array['owner_visibility', 'owner_expense', 'owner_share']) x;
  execute format('alter table public.booking_events drop constraint %I', c.conname);
  execute format('alter table public.booking_events add constraint booking_events_kind_check check (kind in (%s))',
                 (select string_agg(quote_literal(x), ', ') from unnest(v_kinds) x));
end $$;

-- the visibility a new booking gets from the Program setting (the owner's own booking is always theirs to see)
create or replace function app.owner_visibility_default(p_type booking_type default 'standard') returns text
language sql stable security definer set search_path = public, app as $$
  select case when p_type::text = 'owner' then 'shown'
              else case (app.settings()).owner_revenue_visibility when 'after_return' then 'until_return' when 'statement' then 'until_statement' else 'shown' end end
$$;

create or replace function app.bookings_owner_visibility_default() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.owner_visibility is null then new.owner_visibility := app.owner_visibility_default(new.booking_type); end if;
  return new;
end $$;
drop trigger if exists bookings_owner_visibility_default on bookings;
create trigger bookings_owner_visibility_default before insert on bookings
  for each row execute function app.bookings_owner_visibility_default();

-- ================================================================ 2. what the owner may see
-- A booking carries no owner revenue when its rental charge after discounts is nothing and no split gives the owner anything.
create or replace function app.booking_owner_revenue_zero(b bookings) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(b.rental_charge_cents, 0) - coalesce(b.discount_cents, 0) - coalesce(b.staff_discount_cents, 0) - coalesce(b.promo_discount_cents, 0) <= 0
     and not exists (select 1 from booking_splits s where s.booking_id = b.id and (s.owner_revenue_cents > 0 or s.owner_payout_cents > 0))
$$;

-- full | booked (dates and status, no amount) | unavailable (dates only)
create or replace function app.booking_owner_view(b bookings) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when b.id is null or b.owner_visibility = 'shown' then 'full'
    when b.owner_visibility = 'never' then case when app.booking_owner_revenue_zero(b) then 'unavailable' else 'booked' end
    when b.owner_visibility = 'until_return' and b.status::text in ('returned', 'closed', 'cancelled', 'no_show') then 'full'
    else 'booked' end
$$;
create or replace function app.booking_owner_view_id(p_booking uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce((select app.booking_owner_view(b) from bookings b where b.id = p_booking), 'full')
$$;

-- ================================================================ 3. the owner's reads
-- The owner's bookings (0022): the amount only when the owner may see it; an unavailable booking has no number and no renter.
drop function if exists app.owner_portal_bookings(uuid, timestamptz, timestamptz);
create function app.owner_portal_bookings(p_by uuid, p_from timestamptz default null, p_to timestamptz default null)
returns table (booking_id uuid, booking_number text, booking_type booking_type, status booking_status, vehicle_id uuid, vehicle_name text,
               pickup_at timestamptz, return_at timestamptz, rental_charge_cents bigint, renter_name text, renter_mobile text, owner_view text,
               owner_expenses jsonb, booking_share_bps integer)
language sql stable security definer set search_path = public, app as $$
  select b.id, case when x.v = 'unavailable' then null else b.booking_number end, b.booking_type, b.status, b.vehicle_id, app.vehicle_name(b.vehicle_id),
         b.pickup_at, b.return_at,
         case when x.v = 'full' then b.rental_charge_cents - b.discount_cents - b.staff_discount_cents - b.promo_discount_cents end,
         case when x.v <> 'unavailable' and (b.management_mode = 'self_managed' or b.booking_type = 'owner') then r.legal_name end,
         case when x.v <> 'unavailable' and (b.management_mode = 'self_managed' or b.booking_type = 'owner') then r.mobile end,
         x.v,
         -- the booking's documented owner deductions (section 8), itemized, once the owner sees the booking
         case when x.v = 'full' then (select coalesce(jsonb_agg(jsonb_build_object('category', e.category, 'amount_cents', e.amount_cents, 'reason', e.reason,
                                        'receipt', e.receipt_ref is not null) order by e.created_at, e.id), '[]'::jsonb)
                                        from booking_owner_expenses e where e.booking_id = b.id and e.voided_at is null) else '[]'::jsonb end,
         case when x.v = 'full' then (select o.company_share_bps from booking_owner_shares o where o.booking_id = b.id) end
    from bookings b join vehicles v on v.id = b.vehicle_id join renters r on r.id = b.renter_id
    cross join lateral (select app.booking_owner_view(b) as v) x
   where v.owner_id = app.portal_owner_id(p_by)
     and b.status::text not in ('requested', 'offered', 'tentative', 'expired', 'declined')
     and (p_from is null or b.return_at > p_from) and (p_to is null or b.pickup_at < p_to)
   order by b.pickup_at
$$;

-- The owner's view of their bookings (0025), with the same rule.
create or replace view owner_bookings with (security_barrier = true) as
 select b.id, case when x.v = 'unavailable' then null else b.booking_number end as booking_number, b.booking_type, b.status,
        coalesce(s.vehicle_id, b.vehicle_id) as vehicle_id,
        b.management_mode, b.pickup_at, b.return_at,
        case when x.v = 'unavailable' then null else b.pickup_place end as pickup_place,
        case when x.v = 'unavailable' then null else b.return_place end as return_place, b.billable_days,
        b.handed_over_at, b.checked_in_at,
        case when x.v <> 'full' then null
             when s.booking_id is not null and s.segment_days is distinct from b.billable_days then s.rental_charge_cents
             else b.rental_charge_cents - b.discount_cents - b.staff_discount_cents - b.promo_discount_cents end as rental_charge_cents,
        case when x.v <> 'unavailable' and (b.management_mode = 'self_managed' or b.booking_type = 'owner') then r.legal_name end as renter_name,
        case when x.v <> 'unavailable' and (b.management_mode = 'self_managed' or b.booking_type = 'owner') then r.mobile end as renter_mobile,
        case when x.v = 'full' then s.mileage_overage_cents end as mileage_overage_cents,
        case when x.v = 'full' then s.kickback_cents end as kickback_cents,
        case when x.v = 'full' then s.owner_revenue_cents end as owner_revenue_cents,
        case when x.v = 'full' then s.company_share_cents end as company_share_cents,
        case when x.v = 'full' then s.owner_payout_cents end as owner_payout_cents,
        case when x.v = 'full' then s.payout_month end as payout_month, b.blocks_calendar, b.dates_provisional,
        x.v as owner_view
   from bookings b
   join renters r on r.id = b.renter_id
   left join booking_splits s on s.booking_id = b.id
   cross join lateral (select app.booking_owner_view(b) as v) x
  where app.is_my_owner(coalesce(s.owner_id, b.owner_id))
    and b.status::text <> all (array['requested', 'offered', 'tentative', 'expired', 'declined']);

-- The owner's own rows of the splits and deductions: not those of a booking they may not see the amounts of.
drop policy if exists owner_read on booking_splits;
create policy owner_read on booking_splits for select to authenticated using (app.is_my_owner(owner_id) and app.booking_owner_view_id(booking_id) = 'full');
drop policy if exists owner_read on owner_deductions;
create policy owner_read on owner_deductions for select to authenticated using (app.is_my_owner(owner_id) and (booking_id is null or app.booking_owner_view_id(booking_id) = 'full'));

-- The month to date (0151): built with the hidden bookings' splits set aside (in the build's own savepoint, so nothing is
-- kept), so the provisional figures carry only what the owner may see. The approved statement always carries them all.
-- (the split also takes the booking's documented owner deductions of section 8: its expenses come off before Owner
-- Revenue and its own Revenue Share applies, on every part not paid out yet)
alter function app.compute_booking_split(uuid) rename to compute_booking_split_pre0156;
create or replace function app.compute_booking_split(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_exp bigint;
  v_bps integer;
  v_main uuid;
  s booking_splits;
  v_e bigint; v_rev bigint; v_share bigint;
begin
  -- the parts not paid out go back to their plain figures first (the split below writes them again)
  update booking_splits set owner_revenue_cents = owner_revenue_cents + owner_expense_cents, owner_expense_cents = 0, booking_share_override = false
   where booking_id = p_booking and owner_statement_id is null and (owner_expense_cents <> 0 or booking_share_override);
  perform app.compute_booking_split_pre0156(p_booking);
  select * into b from bookings where id = p_booking;
  if b.id is not null and exists (select 1 from booking_splits x where x.booking_id = p_booking and x.owner_statement_id is null) then
    select coalesce(sum(amount_cents), 0) into v_exp from booking_owner_expenses where booking_id = p_booking and voided_at is null;
    select company_share_bps into v_bps from booking_owner_shares where booking_id = p_booking;
    -- the expenses go on the part of the booking's own car (else the first part)
    select x.vehicle_id into v_main from booking_splits x where x.booking_id = p_booking and x.owner_statement_id is null
     order by (x.vehicle_id = b.vehicle_id) desc, x.segment_starts_at nulls last limit 1;
    for s in select * from booking_splits x where x.booking_id = p_booking and x.owner_statement_id is null loop
      v_e := case when s.vehicle_id = v_main then least(v_exp, greatest(s.owner_revenue_cents, 0)) else 0 end;
      v_rev := s.owner_revenue_cents - v_e;
      v_share := public.calc_bps(v_rev, coalesce(v_bps, s.company_share_bps));
      update booking_splits set owner_expense_cents = v_e, booking_share_override = v_bps is not null,
             owner_revenue_cents = v_rev, company_share_bps = coalesce(v_bps, s.company_share_bps), company_share_cents = v_share, owner_payout_cents = v_rev - v_share
       where booking_id = p_booking and vehicle_id = s.vehicle_id;
    end loop;
  end if;
  if coalesce(current_setting('app.owner_mtd_hide', true), '') = 'on' and app.booking_owner_view_id(p_booking) <> 'full' then
    update booking_splits set payout_month = date '9999-12-01' where booking_id = p_booking and owner_statement_id is null;
  end if;
end $$;

alter function app.owner_month_to_date(uuid, date) rename to owner_month_to_date_pre0156;
create or replace function app.owner_month_to_date(p_by uuid, p_month date default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid := app.portal_owner_id(p_by);
  v_month date := app.month_start(coalesce(p_month, app.today()));
  x jsonb;
  v_held integer;
begin
  perform set_config('app.owner_mtd_hide', 'on', true);
  begin
    x := app.owner_month_to_date_pre0156(p_by, p_month);
  exception when others then
    perform set_config('app.owner_mtd_hide', '', true);
    raise;
  end;
  perform set_config('app.owner_mtd_hide', '', true);
  -- the rentals under way: an unavailable one is listed as the car being unavailable, without its number
  if jsonb_typeof(x -> 'in_progress') = 'array' then
    x := jsonb_set(x, '{in_progress}', coalesce((select jsonb_agg(case when app.booking_owner_view(b) = 'unavailable'
                     then jsonb_build_object('booking_number', null, 'vehicle_name', i ->> 'vehicle_name', 'status', 'unavailable',
                                             'pickup_at', i -> 'pickup_at', 'return_at', i -> 'return_at', 'days', i -> 'days')
                     else i end order by i ->> 'pickup_at')
                   from jsonb_array_elements(x -> 'in_progress') i left join bookings b on b.booking_number = i ->> 'booking_number'), '[]'::jsonb));
  end if;
  -- how many finished rentals of the month are on the statement but not shown yet (their figures come with it)
  if not coalesce((x ->> 'final')::boolean, false) then
    select count(*) into v_held from bookings b
     where b.owner_id = v_owner and b.booking_type::text <> 'owner' and b.status::text in ('returned', 'closed')
       and b.return_at >= app.local_midnight(v_month) and b.return_at < app.local_midnight((v_month + interval '1 month')::date)
       and app.booking_owner_view(b) = 'booked';
    x := x || jsonb_build_object('held_back', v_held);
  end if;
  return x;
end $$;

-- ================================================================ 4. the statement reveals what it covers
alter function app.approve_owner_statement(uuid, uuid) rename to approve_owner_statement_pre0156;
create or replace function app.approve_owner_statement(p_statement uuid, p_admin uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_payout uuid := app.approve_owner_statement_pre0156(p_statement, p_admin);
  v_number text := (select statement_number from owner_statements where id = p_statement);
  v_why text := 'The owner statement ' || coalesce(v_number, '') || ' was approved';
begin
  insert into booking_owner_visibility_log (booking_id, visibility_from, visibility_to, reason, how, changed_by)
  select b.id, b.owner_visibility, 'shown', v_why, 'statement', p_admin
    from bookings b
   where b.id in (select l.booking_id from owner_statement_lines l where l.owner_statement_id = p_statement and l.booking_id is not null)
     and b.owner_visibility <> 'shown' and app.booking_owner_view(b) <> 'unavailable';
  insert into booking_events (booking_id, kind, note, details, actor_type, actor_user_id)
  select b.id, 'owner_visibility', 'Shown to the owner: ' || v_why, jsonb_build_object('from', b.owner_visibility, 'to', 'shown'), 'system', null
    from bookings b
   where b.id in (select l.booking_id from owner_statement_lines l where l.owner_statement_id = p_statement and l.booking_id is not null)
     and b.owner_visibility <> 'shown' and app.booking_owner_view(b) <> 'unavailable';
  update bookings b set owner_visibility = 'shown', owner_visibility_reason = v_why, owner_visibility_by = p_admin, owner_visibility_at = now()
   where b.id in (select l.booking_id from owner_statement_lines l where l.owner_statement_id = p_statement and l.booking_id is not null)
     and b.owner_visibility <> 'shown' and app.booking_owner_view(b) <> 'unavailable';
  return v_payout;
end $$;

-- ================================================================ 5. the owner emails
-- The booking an owner booking notice is about.
create or replace function app.owner_event_booking(p_entity text, p_entity_id uuid, p_payload jsonb) returns uuid
language sql stable security definer set search_path = public, app as $$
  select coalesce(case when coalesce(p_payload ->> 'booking_id', '') ~ '^[0-9a-f-]{36}$' then (p_payload ->> 'booking_id')::uuid end,
                  case when p_entity = 'booking' then p_entity_id end,
                  case when p_entity = 'booking_change_request' then (select c.booking_id from booking_change_requests c where c.id = p_entity_id) end)
$$;

-- The notices of a booking the owner does not see are not sent (processed at once, with the reason).
create or replace function app.app_events_owner_unavailable() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_booking uuid;
begin
  if new.processed_at is null and new.code in ('owner_new_booking', 'owner_booking_changed', 'owner_booking_confirmed') then
    v_booking := app.owner_event_booking(new.entity, new.entity_id, new.payload);
    if v_booking is not null and app.booking_owner_view_id(v_booking) = 'unavailable' then
      new.processed_at := now();
      new.process_note := 'not shown to the owner (0156)';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists app_events_owner_unavailable on app_events;
create trigger app_events_owner_unavailable before insert on app_events for each row execute function app.app_events_owner_unavailable();

-- The amounts in the two owner emails only when the owner may see them (show_amounts in the templates).
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0156;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0156(p_code, p_event, p_to);
  v_view text;
begin
  if p_code not in ('owner_new_booking', 'owner_booking_changed') then return x; end if;
  v_view := app.booking_owner_view_id(app.owner_event_booking(p_event.entity, p_event.entity_id, p_event.payload));
  if v_view = 'full' then return x || jsonb_build_object('show_amounts', true); end if;
  x := x || jsonb_build_object('show_amounts', false);
  if x ? 'rental_charge' then x := x || jsonb_build_object('rental_charge', ''); end if;
  if p_code = 'owner_booking_changed' then x := x || jsonb_build_object('income_before', '', 'income_after', '', 'income_changed', false); end if;
  return x;
end $$;

-- the catalogue rows: the preheaders (also the in-app notice) carry no amount, and the new variable
update notification_catalogue set preheader = 'Booking {{booking_number}}: {{pickup_date}} to {{return_date}}.',
       variables = case when variables @> '[{"name":"show_amounts"}]' then variables else variables || '[{"name":"show_amounts","type":"boolean"}]'::jsonb end
 where code = 'owner_new_booking';
update notification_catalogue set preheader = 'The new details of booking {{booking_number}}.',
       variables = case when variables @> '[{"name":"show_amounts"}]' then variables else variables || '[{"name":"show_amounts","type":"boolean"}]'::jsonb end
 where code = 'owner_booking_changed';

-- ================================================================ 6. the staff door
-- An Admin, or a customer service or fleet assistant (those who edit bookings).
create or replace function app.may_set_owner_visibility(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_user) or exists (
    select 1 from user_roles r join users u on u.id = r.user_id join staff_profiles sp on sp.user_id = r.user_id and sp.staff_type = 'va' and sp.is_active
     where r.user_id = p_user and r.role = 'va' and u.status = 'active'
       and (sp.va_function::text in ('cs', 'fleet') or coalesce(sp.cover_functions::text[], '{}') && array['cs', 'fleet']))
$$;

create or replace function app.owner_visibility_booking(p jsonb) returns bookings
language plpgsql stable security definer set search_path = public, app as $$
declare
  k text := btrim(coalesce(p ->> 'booking', p ->> 'booking_id', ''));
  b bookings;
begin
  if k ~ '^[0-9a-f-]{36}$' then select * into b from bookings where id = k::uuid;
  else select * into b from bookings where booking_number = upper(k); end if;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  return b;
end $$;

-- Set what the owner sees, with the checks. p_how: staff | new_booking.
create or replace function app.booking_owner_visibility_apply(b bookings, p_to text, p_reason text, p_by uuid, p_how text default 'staff') returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_reason text := nullif(left(btrim(coalesce(p_reason, '')), 500), '');
  v_st text;
begin
  if p_to is null or p_to not in ('shown', 'until_return', 'until_statement', 'never') then
    raise exception 'Choose what the owner sees: shown, until_return, until_statement or never' using errcode = '22023';
  end if;
  if b.owner_visibility = p_to then return; end if;
  if p_to <> 'shown' then
    select s.statement_number into v_st from owner_statement_lines l join owner_statements s on s.id = l.owner_statement_id
     where l.booking_id = b.id and s.status in ('approved', 'paid') limit 1;
    if v_st is not null then
      raise exception 'This booking is on the approved owner statement %: the owner already sees it', v_st using errcode = '23514';
    end if;
  end if;
  if p_to = 'never' and not app.booking_owner_revenue_zero(b) then
    raise exception 'Only a booking with no owner revenue (an internal, insurance or own-use booking at no charge) can be not shown to the owner. Hide it until the statement instead.' using errcode = '23514';
  end if;
  insert into booking_owner_visibility_log (booking_id, visibility_from, visibility_to, reason, how, changed_by)
  values (b.id, b.owner_visibility, p_to, v_reason, p_how, p_by);
  insert into booking_events (booking_id, kind, note, details, actor_type, actor_user_id)
  values (b.id, 'owner_visibility', case p_to when 'shown' then 'Shown to the owner' when 'until_return' then 'Hidden from the owner until the return'
                                              when 'until_statement' then 'Hidden from the owner until the statement is approved'
                                              else 'Not shown to the owner (no owner revenue)' end || coalesce(': ' || v_reason, ''),
          jsonb_build_object('from', b.owner_visibility, 'to', p_to), 'staff', p_by);
  update bookings set owner_visibility = p_to, owner_visibility_reason = v_reason, owner_visibility_by = p_by, owner_visibility_at = now() where id = b.id;
  -- a booking the owner does not see: its owner booking notices not sent yet are not sent
  if p_to = 'never' then
    update app_events e set processed_at = now(), process_note = 'not shown to the owner (0156)'
     where e.processed_at is null and e.code in ('owner_new_booking', 'owner_booking_changed', 'owner_booking_confirmed')
       and app.owner_event_booking(e.entity, e.entity_id, e.payload) = b.id;
  end if;
end $$;

-- The booking page: what the owner sees now, in a sentence, and the history.
create or replace function app.booking_owner_visibility_read(p_by uuid, b bookings) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'booking_id', b.id, 'booking_number', b.booking_number, 'has_owner', b.owner_id is not null,
    'owner_name', (select coalesce(o.corporation_name, o.legal_name) from owners o where o.id = b.owner_id),
    'visibility', b.owner_visibility, 'owner_view', app.booking_owner_view(b),
    'label', case app.booking_owner_view(b)
               when 'full' then 'The owner sees this booking and its amounts.'
               when 'unavailable' then 'Not shown to the owner: they see only that the car is unavailable for these dates.'
               else case b.owner_visibility
                      when 'until_return' then 'Hidden from the owner until the return: they see the dates as Booked, not the amounts.'
                      when 'never' then 'Marked not shown to the owner, but it has owner revenue: the owner sees it as Booked, without amounts, until the statement is approved.'
                      else 'Hidden from the owner until the owner statement covering it is approved: they see the dates as Booked, not the amounts.' end end,
    'reason', b.owner_visibility_reason, 'at', b.owner_visibility_at,
    'by', (select u.full_name from users u where u.id = b.owner_visibility_by),
    'may', app.may_set_owner_visibility(p_by), 'no_owner_revenue', app.booking_owner_revenue_zero(b),
    'on_statement', (select s.statement_number from owner_statement_lines l join owner_statements s on s.id = l.owner_statement_id
                      where l.booking_id = b.id and s.status in ('approved', 'paid') limit 1),
    'default', (app.settings()).owner_revenue_visibility,
    'log', (select coalesce(jsonb_agg(jsonb_build_object('from', g.visibility_from, 'to', g.visibility_to, 'reason', g.reason, 'how', g.how,
                      'by', (select u.full_name from users u where u.id = g.changed_by), 'at', g.changed_at) order by g.changed_at desc, g.id desc), '[]'::jsonb)
              from booking_owner_visibility_log g where g.booking_id = b.id))
$$;

create or replace function app.booking_owner_visibility_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings := app.owner_visibility_booking(p);
begin
  if not app.may_set_owner_visibility(p_by) then
    raise exception 'Only an Admin, customer service or fleet change what the owner sees of a booking' using errcode = '42501';
  end if;
  if b.owner_id is null then raise exception 'This car has no owner: there is nobody to hide the booking from' using errcode = '22023'; end if;
  perform app.booking_owner_visibility_apply(b, p ->> 'visibility', p ->> 'reason', p_by, 'staff');
  select * into b from bookings where id = b.id;
  return app.booking_owner_visibility_read(p_by, b);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0156;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_vis text;
  v_reason text;
  x jsonb;
  b bookings;
  e jsonb;
begin
  if p_call = 'ops_read' and p_name in ('booking_owner_visibility', 'owner_visibility_defaults') then
    perform app.door_begin(p_user, p_aal);
    if not (app.user_is_admin(p_user) or app.user_is_staff(p_user)) then raise exception 'Staff only' using errcode = '42501'; end if;
    if p_name = 'owner_visibility_defaults' then
      return jsonb_build_object('default', (app.settings()).owner_revenue_visibility, 'visibility', app.owner_visibility_default('standard'), 'may', app.may_set_owner_visibility(p_user),
                                'may_deduct', app.may_edit_fees(p_user), 'may_override', app.user_is_admin(p_user));
    end if;
    return app.booking_owner_visibility_read(p_user, app.owner_visibility_booking(p_ - '_va'));
  end if;
  if p_call = 'ops_do' and p_name = 'booking_owner_visibility_set' then
    perform app.door_begin(p_user, p_aal);
    return app.booking_owner_visibility_set(p_user, p_ - '_va');
  end if;
  if p_call = 'ops_read' and p_name = 'booking_owner_deductions' then
    perform app.door_begin(p_user, p_aal);
    if not (app.user_is_admin(p_user) or app.user_is_staff(p_user)) then raise exception 'Staff only' using errcode = '42501'; end if;
    return app.booking_owner_deductions_read(p_user, app.owner_visibility_booking(p_ - '_va'));
  end if;
  if p_call = 'ops_do' and p_name in ('booking_owner_expense_add', 'booking_owner_expense_void', 'booking_owner_share_set') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'booking_owner_expense_add' then app.booking_owner_expense_add(p_user, p_ - '_va')
                       when 'booking_owner_expense_void' then app.booking_owner_expense_void(p_user, p_ - '_va')
                       else app.booking_owner_share_set(p_user, p_ - '_va') end;
  end if;
  -- Add a rental and an offer: what the owner sees, chosen on the form (staff who may; the Program setting otherwise), and
  -- on Add a rental the booking's owner deductions (an expense line, the booking's own Revenue Share)
  if p_call = 'ops_do' and p_name in ('manual_rental_create', 'offer_create')
     and (p_ ? 'owner_visibility' or p_ ? 'owner_expenses' or p_ ? 'owner_share') then
    v_vis := nullif(p_ ->> 'owner_visibility', '');
    v_reason := p_ ->> 'owner_visibility_reason';
    x := app.door_pre0156(p_user, p_aal, p_call, p_name, p_ - 'owner_visibility' - 'owner_visibility_reason' - 'owner_expenses' - 'owner_share');
    if (x ->> 'booking_id') ~ '^[0-9a-f-]{36}$' then
      select * into b from bookings where id = (x ->> 'booking_id')::uuid;
      if v_vis is not null and app.may_set_owner_visibility(p_user) and b.id is not null and b.owner_id is not null then
        perform app.booking_owner_visibility_apply(b, v_vis, v_reason, p_user, 'new_booking');
      end if;
      if b.id is not null and jsonb_typeof(p_ -> 'owner_expenses') = 'array' then
        for e in select * from jsonb_array_elements(p_ -> 'owner_expenses') loop
          continue when coalesce(e ->> 'amount_cents', '') = '';
          perform app.booking_owner_expense_add(p_user, e || jsonb_build_object('booking', b.id));
        end loop;
      end if;
      if b.id is not null and jsonb_typeof(p_ -> 'owner_share') = 'object' and coalesce(p_ #>> '{owner_share,bps}', '') <> '' then
        perform app.booking_owner_share_set(p_user, (p_ -> 'owner_share') || jsonb_build_object('booking', b.id));
      end if;
    end if;
    return x;
  end if;
  return app.door_pre0156(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 8. documented owner deductions on a booking
-- An expense line (cleaning, repair, fuel, platform fee, other: the amount, a written reason, a receipt reference) comes
-- off before Owner Revenue; a Revenue Share for one booking applies within the car's signed terms (above them only by an
-- Admin, with a reason). Both are itemized on the statement and, once the owner sees the booking, in the owner portal;
-- both are in the booking history. Added by an Admin, or by customer service or sales while Program settings let them
-- change fees (app.may_edit_fees, 0139).
create or replace function app.booking_owner_deduction_check(b bookings) returns void
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_st text;
begin
  if b.owner_id is null then raise exception 'This car has no owner: a booking expense or Revenue Share is for an owner''s or a partner''s car' using errcode = '22023'; end if;
  if b.booking_type::text = 'owner' then raise exception 'The owner''s own booking has no Owner Revenue to deduct from' using errcode = '22023'; end if;
  select s.statement_number into v_st from owner_statement_lines l join owner_statements s on s.id = l.owner_statement_id
   where l.booking_id = b.id and l.line_type = 'rental' and s.status in ('approved', 'paid') limit 1;
  if v_st is not null then
    raise exception 'This booking is on the approved owner statement %: add an owner cost on the owner''s account instead, for the next statement', v_st using errcode = '23514';
  end if;
end $$;

-- the split of a finished booking not paid out yet is worked out again at once (the next statement and the month to date)
create or replace function app.booking_owner_resplit(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from booking_splits s where s.booking_id = p_booking and s.owner_statement_id is null) then
    perform app.compute_booking_split(p_booking);
  end if;
end $$;

create or replace function app.booking_owner_deductions_read(p_by uuid, b bookings) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'booking_id', b.id, 'booking_number', b.booking_number, 'has_owner', b.owner_id is not null and b.booking_type::text <> 'owner',
    'may', app.may_edit_fees(p_by), 'may_override', app.user_is_admin(p_by),
    'terms_bps', coalesce(b.partner_cut_bps, b.company_share_bps), 'partner', b.partner_cut_bps is not null,
    'share', (select jsonb_build_object('bps', o.company_share_bps, 'terms_bps', o.terms_bps, 'above_terms', o.above_terms, 'reason', o.reason,
                'by', (select u.full_name from users u where u.id = o.set_by), 'at', o.set_at) from booking_owner_shares o where o.booking_id = b.id),
    'expenses', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'category', e.category, 'amount_cents', e.amount_cents, 'reason', e.reason,
                   'receipt_ref', e.receipt_ref, 'by', (select u.full_name from users u where u.id = e.created_by), 'at', e.created_at,
                   'voided_at', e.voided_at, 'void_reason', e.void_reason) order by e.created_at, e.id), '[]'::jsonb)
                   from booking_owner_expenses e where e.booking_id = b.id),
    'split', (select jsonb_build_object('owner_revenue_cents', sum(s.owner_revenue_cents), 'owner_expense_cents', sum(s.owner_expense_cents),
                'company_share_cents', sum(s.company_share_cents), 'owner_payout_cents', sum(s.owner_payout_cents), 'paid_out', bool_or(s.owner_statement_id is not null))
                from booking_splits s where s.booking_id = b.id having count(*) > 0),
    'owner_view', app.booking_owner_view(b),
    'on_statement', (select s.statement_number from owner_statement_lines l join owner_statements s on s.id = l.owner_statement_id
                      where l.booking_id = b.id and l.line_type = 'rental' and s.status in ('approved', 'paid') limit 1))
$$;

create or replace function app.owner_expense_label(p_category text) returns text
language sql immutable as $$
  select case p_category when 'cleaning' then 'Cleaning' when 'repair' then 'Repair' when 'fuel' then 'Fuel' when 'platform_fee' then 'Platform fee' else 'Other' end
$$;

-- p: booking, category, amount_cents, reason, receipt_ref
create or replace function app.booking_owner_expense_add(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings := app.owner_visibility_booking(p);
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_reason text := btrim(coalesce(p ->> 'reason', ''));
  v_cat text := coalesce(nullif(p ->> 'category', ''), 'other');
begin
  if not app.may_edit_fees(p_by) then
    raise exception 'Only an Admin (or customer service and sales while Program settings let them change fees) adds an owner deduction' using errcode = '42501';
  end if;
  perform app.booking_owner_deduction_check(b);
  if v_cat not in ('cleaning', 'repair', 'fuel', 'platform_fee', 'other') then raise exception 'Choose the category: cleaning, repair, fuel, platform fee or other' using errcode = '22023'; end if;
  if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount of the expense' using errcode = '22023'; end if;
  if length(v_reason) < 5 then raise exception 'Write the reason the owner will read (5 characters or more)' using errcode = '22023'; end if;
  insert into booking_owner_expenses (booking_id, category, amount_cents, reason, receipt_ref, created_by)
  values (b.id, v_cat, v_amount, left(v_reason, 500), nullif(left(btrim(coalesce(p ->> 'receipt_ref', '')), 300), ''), p_by);
  insert into booking_events (booking_id, kind, note, details, actor_type, actor_user_id)
  values (b.id, 'owner_expense', format('Booking expense for the owner: %s %s, %s', app.owner_expense_label(v_cat), app.fmt_money(v_amount), left(v_reason, 500)),
          jsonb_build_object('category', v_cat, 'amount_cents', v_amount), 'staff', p_by);
  perform app.booking_owner_resplit(b.id);
  return app.booking_owner_deductions_read(p_by, b);
end $$;

-- p: id, reason
create or replace function app.booking_owner_expense_void(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  e booking_owner_expenses;
  b bookings;
  v_reason text := btrim(coalesce(p ->> 'reason', ''));
begin
  if not app.may_edit_fees(p_by) then raise exception 'Only an Admin (or customer service and sales while Program settings let them change fees) removes an owner deduction' using errcode = '42501'; end if;
  select * into e from booking_owner_expenses where id = nullif(p ->> 'id', '')::uuid;
  if e.id is null or e.voided_at is not null then raise exception 'That expense is not on the booking' using errcode = 'P0002'; end if;
  select * into b from bookings where id = e.booking_id;
  perform app.booking_owner_deduction_check(b);
  if length(v_reason) < 5 then raise exception 'Write why it is removed (5 characters or more)' using errcode = '22023'; end if;
  update booking_owner_expenses set voided_at = now(), voided_by = p_by, void_reason = left(v_reason, 500) where id = e.id;
  insert into booking_events (booking_id, kind, note, details, actor_type, actor_user_id)
  values (b.id, 'owner_expense', format('Booking expense removed: %s %s, %s', app.owner_expense_label(e.category), app.fmt_money(e.amount_cents), left(v_reason, 500)),
          jsonb_build_object('category', e.category, 'amount_cents', e.amount_cents, 'voided', true), 'staff', p_by);
  perform app.booking_owner_resplit(b.id);
  return app.booking_owner_deductions_read(p_by, b);
end $$;

-- p: booking, bps (empty: back to the car's terms), reason, above_terms (an Admin only)
create or replace function app.booking_owner_share_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings := app.owner_visibility_booking(p);
  v_bps integer := nullif(btrim(coalesce(p ->> 'bps', '')), '')::integer;
  v_terms integer;
  v_reason text := btrim(coalesce(p ->> 'reason', ''));
  v_above boolean;
  o booking_owner_shares;
begin
  if not app.may_edit_fees(p_by) then
    raise exception 'Only an Admin (or customer service and sales while Program settings let them change fees) sets the Revenue Share of a booking' using errcode = '42501';
  end if;
  perform app.booking_owner_deduction_check(b);
  v_terms := coalesce(b.partner_cut_bps, b.company_share_bps);
  select * into o from booking_owner_shares where booking_id = b.id;
  if v_bps is null then
    if o.booking_id is null then return app.booking_owner_deductions_read(p_by, b); end if;
    delete from booking_owner_shares where booking_id = b.id;
    insert into booking_events (booking_id, kind, note, details, actor_type, actor_user_id)
    values (b.id, 'owner_share', format('Revenue Share of this booking back to the car''s terms (%s)', app.fmt_pct(v_terms)) || coalesce(': ' || nullif(v_reason, ''), ''),
            jsonb_build_object('from', o.company_share_bps, 'to', v_terms), 'staff', p_by);
    perform app.booking_owner_resplit(b.id);
    return app.booking_owner_deductions_read(p_by, b);
  end if;
  if v_bps < 0 or v_bps > 10000 then raise exception 'A Revenue Share is between 0%% and 100%%' using errcode = '22023'; end if;
  if length(v_reason) < 5 then raise exception 'Write the reason the owner will read (5 characters or more)' using errcode = '22023'; end if;
  v_above := v_bps > v_terms;
  if v_above and not (app.user_is_admin(p_by) and coalesce((p ->> 'above_terms')::boolean, false)) then
    raise exception 'That is above the car''s signed terms (%): only an Admin can, with "Above the signed terms" ticked and the reason', app.fmt_pct(v_terms) using errcode = '42501';
  end if;
  insert into booking_owner_shares (booking_id, company_share_bps, terms_bps, above_terms, reason, set_by)
  values (b.id, v_bps, v_terms, v_above, left(v_reason, 500), p_by)
  on conflict (booking_id) do update set company_share_bps = excluded.company_share_bps, terms_bps = excluded.terms_bps, above_terms = excluded.above_terms,
     reason = excluded.reason, set_by = excluded.set_by, set_at = now();
  insert into booking_events (booking_id, kind, note, details, actor_type, actor_user_id)
  values (b.id, 'owner_share', format('Revenue Share of this booking: %s (the car''s terms: %s)%s, %s', app.fmt_pct(v_bps), app.fmt_pct(v_terms),
                                      case when v_above then ', above the terms by an Admin' else '' end, left(v_reason, 500)),
          jsonb_build_object('from', coalesce(o.company_share_bps, v_terms), 'to', v_bps, 'above_terms', v_above), 'staff', p_by);
  perform app.booking_owner_resplit(b.id);
  return app.booking_owner_deductions_read(p_by, b);
end $$;

-- The statement itemizes them on the booking's rental line: each expense and the booking's own Revenue Share.
alter function app.build_owner_statement(uuid, date, uuid) rename to build_owner_statement_pre0156;
create or replace function app.build_owner_statement(p_owner uuid, p_month date, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := app.build_owner_statement_pre0156(p_owner, p_month, p_by);
begin
  if v_id is null then return v_id; end if;
  update owner_statement_lines l
     set owner_expense_cents = s.owner_expense_cents,
         booking_share_bps = case when s.booking_share_override then s.company_share_bps end,
         description = l.description
           || case when s.owner_expense_cents > 0 then format('; booking expenses %s (%s)%s', app.fmt_money(s.owner_expense_cents),
                (select string_agg(format('%s %s: %s', app.owner_expense_label(e.category), app.fmt_money(e.amount_cents), e.reason), '; ' order by e.created_at, e.id)
                   from booking_owner_expenses e where e.booking_id = s.booking_id and e.voided_at is null),
                case when s.owner_expense_cents < (select coalesce(sum(e.amount_cents), 0) from booking_owner_expenses e where e.booking_id = s.booking_id and e.voided_at is null)
                     then ', limited to the Owner Revenue' else '' end) else '' end
           || case when s.booking_share_override then format('; Revenue Share for this booking %s (%s)', app.fmt_pct(s.company_share_bps),
                (select o.reason from booking_owner_shares o where o.booking_id = s.booking_id)) else '' end
    from booking_splits s
   where l.owner_statement_id = v_id and l.line_type = 'rental' and s.booking_id = l.booking_id and s.vehicle_id = l.vehicle_id
     and (s.owner_expense_cents > 0 or s.booking_share_override);
  return v_id;
end $$;

-- ================================================================ 7. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['door', 'door_pre0156', 'owner_visibility_default', 'bookings_owner_visibility_default', 'booking_owner_revenue_zero',
             'owner_portal_bookings', 'compute_booking_split', 'compute_booking_split_pre0156', 'owner_month_to_date', 'owner_month_to_date_pre0156',
             'approve_owner_statement', 'approve_owner_statement_pre0156', 'owner_event_booking', 'app_events_owner_unavailable', 'notification_payload', 'ntf_payload_pre0156',
             'may_set_owner_visibility', 'owner_visibility_booking', 'booking_owner_visibility_apply', 'booking_owner_visibility_read', 'booking_owner_visibility_set',
             'booking_owner_visibility_log_append_only', 'booking_owner_deduction_check', 'booking_owner_resplit', 'booking_owner_deductions_read', 'owner_expense_label',
             'booking_owner_expense_add', 'booking_owner_expense_void', 'booking_owner_share_set', 'build_owner_statement', 'build_owner_statement_pre0156'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- the owners' row policies and view call these (a label only, never an amount)
revoke all on function app.booking_owner_view(bookings), app.booking_owner_view_id(uuid) from public, anon;
grant execute on function app.booking_owner_view(bookings), app.booking_owner_view_id(uuid) to authenticated, service_role;

-- ================================================================ the guides
-- GUIDES 0156 START (generated by supabase/seed/0156_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('owner', 'bookings-and-your-own-use', 'chapter', 'home-and-your-vehicles', 'See every booking in your cars on a calendar, and book a car for yourself when it is free.

## See your bookings

1. Bookings shows two months of your cars on a calendar. Each block is a booking number.
2. All bookings lists every trip with its car, dates, amount and status.

![](/guides/img/owner-04-calendar-desktop-be31cbae.jpg "desktop; size: 980 1092; address: carmacars.ca/owner/bookings; pins: 1 53.1 15.8, 2 12.2 94.5")

## Book your own car

You pay no rental charge, fee or deposit. A renter''s confirmed booking comes first.

1. Open Bookings and use **Book my own car** on the right (or **Book it for myself** on the car''s page).
2. Choose the Vehicle, then the Pickup and Return date and time.
3. Add a Note (optional) for our team.
4. Press **Book my car**. You sign the same agreement a renter signs.

![](/guides/img/owner-04-calendar-desktop-a4500851.jpg "desktop; size: 450 570; address: carmacars.ca/owner/bookings; pins: 2 92.2 14.6, 3 92.2 64.9, 4 42.2 89.6")

> Good to know: No price and no deposit apply to you. One booking can be 30 days at most, and you sign the rental agreement before pickup.
', 'Bookings and your own use', 'The bookings calendar and booking your own car.',
  'See every booking in your cars on a calendar, and book a car for yourself when it is free.

## See your bookings

1. Bookings shows two months of your cars on a calendar. Each block is a booking number.
2. All bookings lists every trip with its car, dates, amount and status.

![](/guides/img/owner-04-calendar-desktop-be31cbae.jpg "desktop; size: 980 1092; address: carmacars.ca/owner/bookings; pins: 1 53.1 15.8, 2 12.2 94.5")

> Good to know: A booking can show as Booked, with its dates and no amount: its amounts show once we approve the statement that covers it, and your statement always includes every booking. Unavailable is time your car is in use by us with no revenue for you (for example an insurance hold). A booking expense or a Revenue Share set for one booking is listed on that booking with the reason, and on your statement.

## Book your own car

You pay no rental charge, fee or deposit. A renter''s confirmed booking comes first.

1. Open Bookings and use **Book my own car** on the right (or **Book it for myself** on the car''s page).
2. Choose the Vehicle, then the Pickup and Return date and time.
3. Add a Note (optional) for our team.
4. Press **Book my car**. You sign the same agreement a renter signs.

![](/guides/img/owner-04-calendar-desktop-a4500851.jpg "desktop; size: 450 570; address: carmacars.ca/owner/bookings; pins: 2 92.2 14.6, 3 92.2 64.9, 4 42.2 89.6")

> Good to know: No price and no deposit apply to you. One booking can be 30 days at most, and you sign the rental agreement before pickup.
',
  '<p class="gd-p">See every booking in your cars on a calendar, and book a car for yourself when it is free.</p><section class="gd-task" id="bookings-and-your-own-use-see-your-bookings" data-gd-task><h2 class="gd-h2">See your bookings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Bookings shows two months of your cars on a calendar. Each block is a booking number.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">All bookings lists every trip with its car, dates, amount and status.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/bookings</span></div><div class="gd-imgwrap" style="aspect-ratio:980/1092"><img src="/guides/img/owner-04-calendar-desktop-be31cbae.jpg" alt="" loading="lazy" decoding="async" width="980" height="1092"><span class="gd-pin" style="left:53.1%;top:15.8%" aria-hidden="true">1</span><span class="gd-pin" style="left:12.2%;top:94.5%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A booking can show as Booked, with its dates and no amount: its amounts show once we approve the statement that covers it, and your statement always includes every booking. Unavailable is time your car is in use by us with no revenue for you (for example an insurance hold). A booking expense or a Revenue Share set for one booking is listed on that booking with the reason, and on your statement.</div></aside></section><section class="gd-task" id="bookings-and-your-own-use-book-your-own-car" data-gd-task><h2 class="gd-h2">Book your own car</h2><p class="gd-p">You pay no rental charge, fee or deposit. A renter&#39;s confirmed booking comes first.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Bookings and use <b class="gd-ui">Book my own car</b> on the right (or <b class="gd-ui">Book it for myself</b> on the car&#39;s page).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Vehicle, then the Pickup and Return date and time.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Add a Note (optional) for our team.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Book my car</b>. You sign the same agreement a renter signs.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/bookings</span></div><div class="gd-imgwrap" style="aspect-ratio:450/570"><img src="/guides/img/owner-04-calendar-desktop-a4500851.jpg" alt="" loading="lazy" decoding="async" width="450" height="570"><span class="gd-pin" style="left:92.2%;top:14.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:92.2%;top:64.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:42.2%;top:89.6%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>No price and no deposit apply to you. One booking can be 30 days at most, and you sign the rental agreement before pickup.</div></aside></section>');
select app.guide_release_section('admin', 'requests-offers-and-bookings', 'chapter', 'people-and-access', 'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 18.5 21.2, 2 25.3 31.7")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-84570463.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 1 21.7 16.4, 2 20.0 45.4, 3 65.0 45.4, 4 96.5 98.8")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg "desktop; size: 620 810; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 5 91.9 33.6")

## Send an offer without a request

**Bookings** > **Send an offer**, or **Send an offer** on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.

1. The customer: type a name, phone or email and choose them. Not on file? Press **Add a new customer**: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.
2. The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).
3. The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason and can be plus tax or tax included. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.
4. How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).
5. Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.
6. The right side is the offer as the renter will see it, priced by the database as you type. Press **Send the offer**. **Save without sending** keeps it as a request for later.

> Good to know: It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.

## Change an offer that is out

The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press **Edit the offer** on the booking.

1. Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed.
2. Write what changed in Message to the renter and choose how long the offer is open.
3. Press **Save and send the update**: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press **Save without telling the renter** and tell them yourself.
4. A confirmed booking is changed with **Change the booking** (Propose a change, below).

> Tip: No need to withdraw first. **Withdraw the offer** is only for taking it back for good; **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## Edit a booking that has started

On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, **Edit the booking**, **Edit**.

1. Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking''s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.
2. Type why, if you like, and tick **Email the renter what changed**, or leave it off for a silent correction. Press **Save the changes**.
3. What is open now shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, **Charge** the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.

> Good to know: Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking''s history. A closed booking''s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.

## Fees, a forgotten fee and the balance

On the booking''s Money tab, Fees lists each fee. Press **Change or add a fee**.

1. Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.
2. Press **Save the fees**. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.
3. The renter sees the balance on their booking with a Pay button, and pays by card on Stripe''s form.

> Good to know: Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.

## Correct a renter''s details

On the renter''s page (People, Renters) or on any of their bookings, **Edit renter**.

1. Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.
2. A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick **Email the renter a link to set a password** to send one there. Unsigned agreements and offers go to the new address.
3. Press **Save the renter**. An email that another renter has is refused with their name; the same phone is a warning.

## Payments by part: the rental, the deposit and later charges

On the booking''s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.

1. **Record a payment**: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press **Record it**. The renter gets a receipt; **Print** prints one to hand over.
2. **Collect a card**: a payment, the deposit hold or saving the card. The renter types the card in Stripe''s secure form: on this device (**Open the card form**, then hand it over) or by a link texted or emailed to them (**Send the link**). Staff never type a card number.
3. A deposit hold lasts about 7 days and shows the days left. After the return, **Capture the hold** (all or part, with the reason) or **Release the hold**.
4. **Charge the saved card** (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter''s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.
5. An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press **Confirm the booking**).
6. A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press **Returned** with the reference or receipt number.

> Good to know: Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10057; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

## Check a car out or in

From the booking, with your phone or a tablet: the same checklist field staff use.

1. A confirmed booking shows **Check out (pickup)** under Check-out, check-in and signing; a booking on rent shows **Check in (return)**. Today lists the check-outs and check-ins due, each with **Check out** or **Check in**.
2. The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.
3. Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.
4. A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press **See the photo report**.

> Tip: Fleet, Sales and Customer service check cars out and in the same way from their own booking page.

## The photo report, late returns and the return charges

Under Check-out, check-in and signing, press **Photo report**.

1. The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.
2. At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.
3. Not charging one? Press **Waive** beside it and give the reason: it stays waived if the charges are worked out again.
4. The time was wrong? Press **Correct the check-in time** (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.
5. The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.

## Signatures on the spot, or by link

The renter or an additional driver signs the rental agreement on your device, or on their own phone.

1. While a signature is missing, the booking shows **Sign now on this device**, **Email the signing link** and **Text the signing link**.
2. **Sign now on this device**: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press **Hand the device to** and their name.
3. They read both agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign. Then **Back to the staff view** for the next signer.
4. The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy''s signature record page.

## The licence before an offer is accepted

Front, back and a selfie, from the request on.

1. After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.
2. The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.
3. Review the images as usual with **Review documents**: the card Renter documents is on Review and offer too.
4. The switch is in **Settings** > **Program**, Booking requests and offers: Booking licence required (on), with the selfie (on).

## Renter documents: licence and proof of coverage

A renter''s licence photos, selfie and proof of coverage (OPCF 27 or a credit card''s rental coverage) are checked before the handover. You check them yourself; no task is needed.

1. A booking with documents waiting is a line on To do: "Check ''s documents for booking ", marked Now when the pickup is within two days. Press **Review documents**.
2. The pop-up shows each driver''s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.
3. What to check is written once at the top. One wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**: they are asked for a new one.
4. Then press **Approve all**: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. Anything the system refuses is named with the reason.
5. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-out (photos and four checks): the history says "checked in person".

## Payments by day

**Money** > **Payments by day**: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.

1. Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press **Show**.
2. Totals by method and for each day; cards read as the card and its last four digits, never a code.
3. The cash drawer: expected (cash in less cash given back) against the count Finance records with **Record the count**; a difference shows over or short.
4. Refunds waiting: every refund asked for anywhere with the policy maths. **Approve** or **Decline** with the reason in the row, then **Issue the refund**.
5. **Export CSV** for the bookkeeper.

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg "desktop; size: 1230 530; address: carmacars.ca/admin/bookings/CC-10057?tab=changes; pins: 1 12.9 15.3, 2 35.0 30.6, 3 49.8 59.1, 4 30.9 73.2")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.

## Review requests

Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.

| Message | When |
| --- | --- |
| Mid-trip check-in | Rentals of 2 days or more, 24 hours after the pickup: "How is the car? Reply or call if anything is off." No review ask. |
| Review request | 1 hour after the check-in. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google. |
| Reminder | 24 hours after the request. |
| Final follow-up | 7 days after the request. Nothing more after it. |

1. The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.
2. **Ask for a review** sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.
3. On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press **Send anyway** to send it now.
4. **Mark reviewed** stops the messages when the renter tells you they already reviewed.

The messages also stop by themselves when the renter presses "I already left a review", leaves a review on the site, unsubscribes, or a Google review is matched to them. **Bookings** > **Reviews** has the numbers (requests sent, on hold, reviews detected, the average rating), the hold list and the Google reviews to match.

> Tip: The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees "Something wasn''t right? Tell us directly".
', 'Requests, offers and bookings', 'Send an offer with or without a request, change it in place, take payments by part, run a booking, propose a change.',
  'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 18.5 21.2, 2 25.3 31.7")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-84570463.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 1 21.7 16.4, 2 20.0 45.4, 3 65.0 45.4, 4 96.5 98.8")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg "desktop; size: 620 810; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 5 91.9 33.6")

## Send an offer without a request

**Bookings** > **Send an offer**, or **Send an offer** on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.

1. The customer: type a name, phone or email and choose them. Not on file? Press **Add a new customer**: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.
2. The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).
3. The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason and can be plus tax or tax included. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.
4. How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).
5. Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.
6. The right side is the offer as the renter will see it, priced by the database as you type. Press **Send the offer**. **Save without sending** keeps it as a request for later.

> Good to know: It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.

## Change an offer that is out

The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press **Edit the offer** on the booking.

1. Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed.
2. Write what changed in Message to the renter and choose how long the offer is open.
3. Press **Save and send the update**: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press **Save without telling the renter** and tell them yourself.
4. A confirmed booking is changed with **Change the booking** (Propose a change, below).

> Tip: No need to withdraw first. **Withdraw the offer** is only for taking it back for good; **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## Edit a booking that has started

On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, **Edit the booking**, **Edit**.

1. Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking''s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.
2. Type why, if you like, and tick **Email the renter what changed**, or leave it off for a silent correction. Press **Save the changes**.
3. What is open now shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, **Charge** the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.

> Good to know: Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking''s history. A closed booking''s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.

## Fees, a forgotten fee and the balance

On the booking''s Money tab, Fees lists each fee. Press **Change or add a fee**.

1. Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.
2. Press **Save the fees**. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.
3. The renter sees the balance on their booking with a Pay button, and pays by card on Stripe''s form.

> Good to know: Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.

## Correct a renter''s details

On the renter''s page (People, Renters) or on any of their bookings, **Edit renter**.

1. Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.
2. A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick **Email the renter a link to set a password** to send one there. Unsigned agreements and offers go to the new address.
3. Press **Save the renter**. An email that another renter has is refused with their name; the same phone is a warning.

## Payments by part: the rental, the deposit and later charges

On the booking''s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.

1. **Record a payment**: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press **Record it**. The renter gets a receipt; **Print** prints one to hand over.
2. **Collect a card**: a payment, the deposit hold or saving the card. The renter types the card in Stripe''s secure form: on this device (**Open the card form**, then hand it over) or by a link texted or emailed to them (**Send the link**). Staff never type a card number.
3. A deposit hold lasts about 7 days and shows the days left. After the return, **Capture the hold** (all or part, with the reason) or **Release the hold**.
4. **Charge the saved card** (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter''s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.
5. An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press **Confirm the booking**).
6. A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press **Returned** with the reference or receipt number.

> Good to know: Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10057; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

## Check a car out or in

From the booking, with your phone or a tablet: the same checklist field staff use.

1. A confirmed booking shows **Check out (pickup)** under Check-out, check-in and signing; a booking on rent shows **Check in (return)**. Today lists the check-outs and check-ins due, each with **Check out** or **Check in**.
2. The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.
3. Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.
4. A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press **See the photo report**.

> Tip: Fleet, Sales and Customer service check cars out and in the same way from their own booking page.

## The photo report, late returns and the return charges

Under Check-out, check-in and signing, press **Photo report**.

1. The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.
2. At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.
3. Not charging one? Press **Waive** beside it and give the reason: it stays waived if the charges are worked out again.
4. The time was wrong? Press **Correct the check-in time** (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.
5. The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.

## Signatures on the spot, or by link

The renter or an additional driver signs the rental agreement on your device, or on their own phone.

1. While a signature is missing, the booking shows **Sign now on this device**, **Email the signing link** and **Text the signing link**.
2. **Sign now on this device**: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press **Hand the device to** and their name.
3. They read both agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign. Then **Back to the staff view** for the next signer.
4. The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy''s signature record page.

## The licence before an offer is accepted

Front, back and a selfie, from the request on.

1. After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.
2. The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.
3. Review the images as usual with **Review documents**: the card Renter documents is on Review and offer too.
4. The switch is in **Settings** > **Program**, Booking requests and offers: Booking licence required (on), with the selfie (on).

## Renter documents: licence and proof of coverage

A renter''s licence photos, selfie and proof of coverage (OPCF 27 or a credit card''s rental coverage) are checked before the handover. You check them yourself; no task is needed.

1. A booking with documents waiting is a line on To do: "Check ''s documents for booking ", marked Now when the pickup is within two days. Press **Review documents**.
2. The pop-up shows each driver''s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.
3. What to check is written once at the top. One wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**: they are asked for a new one.
4. Then press **Approve all**: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. Anything the system refuses is named with the reason.
5. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-out (photos and four checks): the history says "checked in person".

## Payments by day

**Money** > **Payments by day**: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.

1. Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press **Show**.
2. Totals by method and for each day; cards read as the card and its last four digits, never a code.
3. The cash drawer: expected (cash in less cash given back) against the count Finance records with **Record the count**; a difference shows over or short.
4. Refunds waiting: every refund asked for anywhere with the policy maths. **Approve** or **Decline** with the reason in the row, then **Issue the refund**.
5. **Export CSV** for the bookkeeper.

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg "desktop; size: 1230 530; address: carmacars.ca/admin/bookings/CC-10057?tab=changes; pins: 1 12.9 15.3, 2 35.0 30.6, 3 49.8 59.1, 4 30.9 73.2")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.

## Review requests

Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.

| Message | When |
| --- | --- |
| Mid-trip check-in | Rentals of 2 days or more, 24 hours after the pickup: "How is the car? Reply or call if anything is off." No review ask. |
| Review request | 1 hour after the check-in. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google. |
| Reminder | 24 hours after the request. |
| Final follow-up | 7 days after the request. Nothing more after it. |

1. The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.
2. **Ask for a review** sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.
3. On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press **Send anyway** to send it now.
4. **Mark reviewed** stops the messages when the renter tells you they already reviewed.

The messages also stop by themselves when the renter presses "I already left a review", leaves a review on the site, unsubscribes, or a Google review is matched to them. **Bookings** > **Reviews** has the numbers (requests sent, on hold, reviews detected, the average rating), the hold list and the Google reviews to match.

> Tip: The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees "Something wasn''t right? Tell us directly".

## What the owner sees, and owner deductions

Each booking on an owner''s or partner''s car shows the card What the owner sees at the top of its page.

1. **Hide from the owner** keeps the booking''s revenue from the owner until the car is returned, or until the owner statement covering it is approved. The owner sees the booking as Booked with its dates, and the calendar still shows the car busy. Add a reason if you like: it is kept in the history.
2. **Show to the owner** shows it now. Approving the statement shows every hidden booking on it by itself.
3. Not shown to the owner is for a booking with no owner revenue (an insurance placeholder, a shareholder''s or the owner''s own use at no charge): the owner sees only that the car is unavailable for those dates. A booking with revenue cannot be set this way.
4. Add a rental and Send an offer have What the owner sees. It starts from Settings > Program, Owners and fleet: Owners see a booking''s revenue (right away by default).
5. On the Money tab, Owner deductions on this booking: **Add a booking expense** (cleaning, repair, fuel, platform fee or other, the amount, the reason the owner reads, a receipt number) comes off before Owner Revenue.
6. **Set the Revenue Share for this booking** applies within the car''s signed terms. Above the terms only an Admin can, with Above the signed terms ticked and the reason. **Back to the car''s terms** undoes it.
7. Add a rental has the same under The car''s owner.

> Good to know: The owner''s statement always includes every booking at its true amounts and lists each deduction with its reason, so the payout is always right. Customer service and sales add deductions only while Program settings let them change fees.
',
  '<p class="gd-p">A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.</p><section class="gd-task" id="requests-offers-and-bookings-the-request-queue" data-gd-task><h2 class="gd-h2">The request queue</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests</b>. The oldest waiting request is at the top.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-02-requests-desktop-6521282d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:18.5%;top:21.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.3%;top:31.7%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless &quot;Email the renter when their request expires that way&quot; is on in Program settings.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-answer-a-request-with-an-offer" data-gd-task><h2 class="gd-h2">Answer a request with an offer</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The Review and offer tab shows the request as the renter sent it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Price on the right updates as you change things.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a message, choose how long the offer stays open, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1060"><img src="/guides/img/admin-03-booking-review-desktop-84570463.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1060"><span class="gd-pin" style="left:21.7%;top:16.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:20%;top:45.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:65%;top:45.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:96.5%;top:98.8%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Changed fields but not ready to send? Press <b class="gd-ui">Save changes</b>. The panel &quot;The offer as the renter sees it&quot; shows the result.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? Press <b class="gd-ui">Decline</b> and fill in Reason and any alternative.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Need an answer first? Press <b class="gd-ui">Ask the renter</b> to send a question.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:620/810"><img src="/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg" alt="" loading="lazy" decoding="async" width="620" height="810"><span class="gd-pin" style="left:91.9%;top:33.6%" aria-hidden="true">5</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-send-an-offer-without-a-request" data-gd-task><h2 class="gd-h2">Send an offer without a request</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Send an offer</b>, or <b class="gd-ui">Send an offer</b> on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The customer: type a name, phone or email and choose them. Not on file? Press <b class="gd-ui">Add a new customer</b>: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason and can be plus tax or tax included. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">The right side is the offer as the renter will see it, priced by the database as you type. Press <b class="gd-ui">Send the offer</b>. <b class="gd-ui">Save without sending</b> keeps it as a request for later.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No &quot;request received&quot; email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-change-an-offer-that-is-out" data-gd-task><h2 class="gd-h2">Change an offer that is out</h2><p class="gd-p">The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press <b class="gd-ui">Edit the offer</b> on the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Write what changed in Message to the renter and choose how long the offer is open.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save and send the update</b>: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press <b class="gd-ui">Save without telling the renter</b> and tell them yourself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A confirmed booking is changed with <b class="gd-ui">Change the booking</b> (Propose a change, below).</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>No need to withdraw first. <b class="gd-ui">Withdraw the offer</b> is only for taking it back for good; <b class="gd-ui">Send again, later expiry</b> gives the renter more time, and <b class="gd-ui">Renter approved by phone</b> records a yes given on a call.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-edit-a-booking-that-has-started" data-gd-task><h2 class="gd-h2">Edit a booking that has started</h2><p class="gd-p">On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, <b class="gd-ui">Edit the booking</b>, <b class="gd-ui">Edit</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking&#39;s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Type why, if you like, and tick <b class="gd-ui">Email the renter what changed</b>, or leave it off for a silent correction. Press <b class="gd-ui">Save the changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What is open now shows at once: <b class="gd-ui">Email a pay link</b> or <b class="gd-ui">Text a pay link</b> for exactly that amount, <b class="gd-ui">Charge</b> the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking&#39;s history. A closed booking&#39;s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-fees-a-forgotten-fee-and-the-balance" data-gd-task><h2 class="gd-h2">Fees, a forgotten fee and the balance</h2><p class="gd-p">On the booking&#39;s Money tab, Fees lists each fee. Press <b class="gd-ui">Change or add a fee</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Save the fees</b>. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The renter sees the balance on their booking with a Pay button, and pays by card on Stripe&#39;s form.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-correct-a-renter-s-details" data-gd-task><h2 class="gd-h2">Correct a renter&#39;s details</h2><p class="gd-p">On the renter&#39;s page (People, Renters) or on any of their bookings, <b class="gd-ui">Edit renter</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick <b class="gd-ui">Email the renter a link to set a password</b> to send one there. Unsigned agreements and offers go to the new address.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the renter</b>. An email that another renter has is refused with their name; the same phone is a warning.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-payments-by-part-the-rental-the-deposit-and-later-charges" data-gd-task><h2 class="gd-h2">Payments by part: the rental, the deposit and later charges</h2><p class="gd-p">On the booking&#39;s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Record a payment</b>: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press <b class="gd-ui">Record it</b>. The renter gets a receipt; <b class="gd-ui">Print</b> prints one to hand over.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Collect a card</b>: a payment, the deposit hold or saving the card. The renter types the card in Stripe&#39;s secure form: on this device (<b class="gd-ui">Open the card form</b>, then hand it over) or by a link texted or emailed to them (<b class="gd-ui">Send the link</b>). Staff never type a card number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A deposit hold lasts about 7 days and shows the days left. After the return, <b class="gd-ui">Capture the hold</b> (all or part, with the reason) or <b class="gd-ui">Release the hold</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Charge the saved card</b> (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter&#39;s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press <b class="gd-ui">Confirm the booking</b>).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press <b class="gd-ui">Returned</b> with the reference or receipt number.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-a-booking" data-gd-task><h2 class="gd-h2">A booking</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Bookings</b>, then a booking number. Or type the number in the search box.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Tabs: Overview, Money, Changes, History, and Drivers and documents.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Overview shows the trip, the renter, what is still missing for the handover, and the price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open tasks for this booking, with the queue and the due time.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Top right: <b class="gd-ui">Stop blocking the calendar</b>, <b class="gd-ui">Cancel for the renter</b> and <b class="gd-ui">Cancel by CarmaCars</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/960"><img src="/guides/img/admin-04-booking-desktop-b56b668a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="960"><span class="gd-pin" style="left:20.1%;top:24%" aria-hidden="true">1</span><span class="gd-pin" style="left:34.7%;top:58.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:20.1%;top:72.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:90.3%;top:18.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-check-a-car-out-or-in" data-gd-task><h2 class="gd-h2">Check a car out or in</h2><p class="gd-p">From the booking, with your phone or a tablet: the same checklist field staff use.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A confirmed booking shows <b class="gd-ui">Check out (pickup)</b> under Check-out, check-in and signing; a booking on rent shows <b class="gd-ui">Check in (return)</b>. Today lists the check-outs and check-ins due, each with <b class="gd-ui">Check out</b> or <b class="gd-ui">Check in</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press <b class="gd-ui">See the photo report</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Fleet, Sales and Customer service check cars out and in the same way from their own booking page.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-the-photo-report-late-returns-and-the-return-charges" data-gd-task><h2 class="gd-h2">The photo report, late returns and the return charges</h2><p class="gd-p">Under Check-out, check-in and signing, press <b class="gd-ui">Photo report</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not charging one? Press <b class="gd-ui">Waive</b> beside it and give the reason: it stays waived if the charges are worked out again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The time was wrong? Press <b class="gd-ui">Correct the check-in time</b> (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-signatures-on-the-spot-or-by-link" data-gd-task><h2 class="gd-h2">Signatures on the spot, or by link</h2><p class="gd-p">The renter or an additional driver signs the rental agreement on your device, or on their own phone.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">While a signature is missing, the booking shows <b class="gd-ui">Sign now on this device</b>, <b class="gd-ui">Email the signing link</b> and <b class="gd-ui">Text the signing link</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Sign now on this device</b>: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press <b class="gd-ui">Hand the device to</b> and their name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">They read both agreements (CarmaCars&#39; and Blind Spot&#39;s), tick the statements and sign. Then <b class="gd-ui">Back to the staff view</b> for the next signer.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy&#39;s signature record page.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-the-licence-before-an-offer-is-accepted" data-gd-task><h2 class="gd-h2">The licence before an offer is accepted</h2><p class="gd-p">Front, back and a selfie, from the request on.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Review the images as usual with <b class="gd-ui">Review documents</b>: the card Renter documents is on Review and offer too.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The switch is in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, Booking requests and offers: Booking licence required (on), with the selfie (on).</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-renter-documents-licence-and-proof-of-coverage" data-gd-task><h2 class="gd-h2">Renter documents: licence and proof of coverage</h2><p class="gd-p">A renter&#39;s licence photos, selfie and proof of coverage (OPCF 27 or a credit card&#39;s rental coverage) are checked before the handover. You check them yourself; no task is needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A booking with documents waiting is a line on To do: &quot;Check &#39;s documents for booking &quot;, marked Now when the pickup is within two days. Press <b class="gd-ui">Review documents</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The pop-up shows each driver&#39;s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What to check is written once at the top. One wrong? Open <b class="gd-ui">Reject this one</b> under it, type the reason the renter reads and press <b class="gd-ui">Reject</b>: they are asked for a new one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Then press <b class="gd-ui">Approve all</b>: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. Anything the system refuses is named with the reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The same pop-up is on the booking: the card Renter documents (<b class="gd-ui">Review documents</b>) on Overview and on Drivers and documents.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening of a renter&#39;s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-out (photos and four checks): the history says &quot;checked in person&quot;.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-payments-by-day" data-gd-task><h2 class="gd-h2">Payments by day</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Payments by day</b>: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press <b class="gd-ui">Show</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Totals by method and for each day; cards read as the card and its last four digits, never a code.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The cash drawer: expected (cash in less cash given back) against the count Finance records with <b class="gd-ui">Record the count</b>; a difference shows over or short.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Refunds waiting: every refund asked for anywhere with the policy maths. <b class="gd-ui">Approve</b> or <b class="gd-ui">Decline</b> with the reason in the row, then <b class="gd-ui">Issue the refund</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Export CSV</b> for the bookkeeper.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-propose-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">Propose a change to a confirmed booking</h2><p class="gd-p">The renter gets an email and answers on their booking. The calendar moves only when they accept.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking&#39;s Changes tab. Under Propose a change, set the new pickup, return or car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To price it by hand, type a New rental charge before tax. Leave it empty to use the car&#39;s rates.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the Reason, for the renter. They read it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057?tab=changes</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/530"><img src="/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="530"><span class="gd-pin" style="left:12.9%;top:15.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:35%;top:30.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:49.8%;top:59.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:30.9%;top:73.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-who-a-booking-is-credited-to" data-gd-task><h2 class="gd-h2">Who a booking is credited to</h2><p class="gd-p">Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To give it to someone else, press <b class="gd-ui">Reassign</b>, choose who (or Nobody), say whether they sourced the client and write the reason. The booking&#39;s history and the audit log keep it, and the deal stays in the same week and month.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Someone said they sourced a website request? The credit line shows the claim: press <b class="gd-ui">Credit them</b> or <b class="gd-ui">Not theirs</b>, with a reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press <b class="gd-ui">Mark reviewed</b> once you have looked at it.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-review-requests" data-gd-task><h2 class="gd-h2">Review requests</h2><p class="gd-p">Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Message</th><th scope="col">When</th></tr></thead><tbody><tr><td>Mid-trip check-in</td><td>Rentals of 2 days or more, 24 hours after the pickup: &quot;How is the car? Reply or call if anything is off.&quot; No review ask.</td></tr><tr><td>Review request</td><td>1 hour after the check-in. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google.</td></tr><tr><td>Reminder</td><td>24 hours after the request.</td></tr><tr><td>Final follow-up</td><td>7 days after the request. Nothing more after it.</td></tr></tbody></table></div><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Ask for a review</b> sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press <b class="gd-ui">Send anyway</b> to send it now.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Mark reviewed</b> stops the messages when the renter tells you they already reviewed.</div></li></ol></div><p class="gd-p">The messages also stop by themselves when the renter presses &quot;I already left a review&quot;, leaves a review on the site, unsubscribes, or a Google review is matched to them. <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Reviews</b> has the numbers (requests sent, on hold, reviews detected, the average rating), the hold list and the Google reviews to match.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees &quot;Something wasn&#39;t right? Tell us directly&quot;.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-what-the-owner-sees-and-owner-deductions" data-gd-task><h2 class="gd-h2">What the owner sees, and owner deductions</h2><p class="gd-p">Each booking on an owner&#39;s or partner&#39;s car shows the card What the owner sees at the top of its page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Hide from the owner</b> keeps the booking&#39;s revenue from the owner until the car is returned, or until the owner statement covering it is approved. The owner sees the booking as Booked with its dates, and the calendar still shows the car busy. Add a reason if you like: it is kept in the history.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Show to the owner</b> shows it now. Approving the statement shows every hidden booking on it by itself.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not shown to the owner is for a booking with no owner revenue (an insurance placeholder, a shareholder&#39;s or the owner&#39;s own use at no charge): the owner sees only that the car is unavailable for those dates. A booking with revenue cannot be set this way.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a rental and Send an offer have What the owner sees. It starts from Settings &gt; Program, Owners and fleet: Owners see a booking&#39;s revenue (right away by default).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">On the Money tab, Owner deductions on this booking: <b class="gd-ui">Add a booking expense</b> (cleaning, repair, fuel, platform fee or other, the amount, the reason the owner reads, a receipt number) comes off before Owner Revenue.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Set the Revenue Share for this booking</b> applies within the car&#39;s signed terms. Above the terms only an Admin can, with Above the signed terms ticked and the reason. <b class="gd-ui">Back to the car&#39;s terms</b> undoes it.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Add a rental has the same under The car&#39;s owner.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The owner&#39;s statement always includes every booking at its true amounts and lists each deduction with its reason, so the payout is always right. Customer service and sales add deductions only while Program settings let them change fees.</div></aside></section>');
-- GUIDES 0156 END
