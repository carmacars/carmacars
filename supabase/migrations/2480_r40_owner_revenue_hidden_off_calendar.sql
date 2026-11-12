-- 2480_r40_owner_revenue_hidden_off_calendar.sql (release 40)
-- The owner, Nov 12, on the drafts of the November 10 owner statements (period to Nov 7): "these amounts arent fully
-- accurate because there are bookings that say hide from owner and dont block off calendar (such as insurer billed
-- rentals), why are those included in here?"
-- The cause: an owner's revenue was every booking's split. Only "Counts toward the owner's revenue" off (2371) took a
-- booking out; a booking hidden from the owner (0156: "the statement is never changed", approval revealed it) and a booking
-- that does not block the calendar (an insurer-billed rental added by hand, 0016/0046/2310) stayed on the statements, the
-- payouts and the owner's month to date.
-- The rule now, in one place (app.booking_counts_for_owner): a booking is part of its car owner's revenue unless
--   a. "Counts toward the owner's revenue" is off (2371), or
--   b. it is billed to an insurer and does not block the calendar (an insurer rental added off the calendar; a renter's
--      booking added over a clash keeps counting), or
--   c. it is hidden from the owner (owner_visibility not shown) while the owner's rule of 0791 holds (Program setting
--      owner_hide_insurance_only, on by default: only an insurance replacement is hidden from an owner) and it is billed to
--      an insurer (bill_to insurer or split). With that setting off, the 0156 rule stays: "hidden until the return" or
--      "until the statement" only delays what the owner sees, the statement carries it and approval reveals it.
-- Where it applies (every place an owner sees money reads one of these):
--   1. app.compute_booking_split (wrapped): a booking that does not count gives the company all of its owner revenue (company
--      share 100%, owner payout 0) and is kept off every statement (payout month 9999-12), as 2371 does. So the statements,
--      the payouts made from them, "not yet collected" (1702, read from the statement lines), the statement email, the
--      owner's month to date (0151, built from the statement), Admin's and Finance's statement and payout lists follow.
--   2. app.owner_period_rentals (patched): the statement's rental lines leave such a booking out even when its split was
--      worked out before (a split the build does not refresh).
--   3. app.booking_owner_view (replaced, same signature, so the owner_bookings view keeps it): such a booking is
--      "unavailable" to the owner: the dates only, no number, no amount (owner portal bookings, the owner's earnings by
--      month, the owner's rows of booking_splits and owner_deductions, the owner booking emails, which are not sent).
--   4. public.server_owner_referred_cars (patched): a referrer's 3-month revenue of the referred cars left the kept-off
--      splits (payout month 9999-12) in.
--   5. app.booking_owner_visibility_read (wrapped): the booking page says the booking is not part of the owner's revenue
--      and why (counts_for_owner, hide_drops_revenue).
--   6. app.owner_statements_rebuild_drafts(period end): rebuilds the DRAFT statements of a period with the statement
--      builder (approved, paid and void ones are never touched); run once here for the period ending November 7, 2026.
-- No applied migration is edited: functions that change are wrapped (_pre2480) or patched in place.
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
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '2480: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ the rule
create function app.booking_counts_for_owner(b bookings) returns boolean
language sql stable security definer set search_path = public, app as $$
  select not coalesce(b.owner_revenue_excluded, false)
     and (coalesce(b.blocks_calendar, true) or coalesce(b.bill_to::text, 'renter') = 'renter')
     and (coalesce(b.owner_visibility, 'shown') = 'shown'
          or not (coalesce((app.settings()).owner_hide_insurance_only, true) and coalesce(b.bill_to::text, 'renter') <> 'renter'))
$$;
comment on function app.booking_counts_for_owner(bookings) is 'Owner revenue (2480): false for a booking that is not part of its car owner''s revenue: "Counts toward the owner''s revenue" off (2371), not blocking the calendar, or an insurance replacement hidden from the owner (while owner_hide_insurance_only is on). Off every statement and payout; the owner sees the dates only.';
create function app.booking_counts_for_owner_id(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select app.booking_counts_for_owner(b) from bookings b where b.id = p_booking), true)
$$;

-- ================================================================ 1. the split
alter function app.compute_booking_split(uuid) rename to compute_booking_split_pre2480;
create function app.compute_booking_split(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.compute_booking_split_pre2480(p_booking);
  if exists (select 1 from bookings b where b.id = p_booking and b.booking_type::text <> 'owner' and not app.booking_counts_for_owner(b)) then
    update booking_splits
       set owner_revenue_cents = owner_revenue_cents + owner_expense_cents, owner_expense_cents = 0, booking_share_override = true,
           company_share_bps = 10000, company_share_cents = owner_revenue_cents + owner_expense_cents, owner_payout_cents = 0,
           payout_month = date '9999-12-01'
     where booking_id = p_booking and owner_statement_id is null;
  end if;
end $$;
select pg_temp.copy_grants('app.compute_booking_split(uuid)'::regprocedure, 'app.compute_booking_split_pre2480(uuid)'::regprocedure);

-- ================================================================ 2. the statement's rental lines
select pg_temp.patch_fn('app.owner_period_rentals(uuid, uuid, date)'::regprocedure,
  $o$and x.payout_month < date '9999-01-01'$o$,
  $n$and x.payout_month < date '9999-01-01'
       -- 2480: a booking that is not part of the owner's revenue (hidden insurance replacement, off the calendar, switched off)
       and app.booking_counts_for_owner(b)$n$);

-- ================================================================ 3. what the owner sees of the booking
-- (create or replace, not a wrapper: the owner_bookings view holds this function itself)
create or replace function app.booking_owner_view(b bookings) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when b.id is null then 'full'
    -- 2480: not part of the owner's revenue: the dates only
    when b.booking_type::text <> 'owner' and not app.booking_counts_for_owner(b) then 'unavailable'
    when b.owner_visibility = 'shown' then 'full'
    when b.owner_visibility = 'never' then case when app.booking_owner_revenue_zero(b) then 'unavailable' else 'booked' end
    when b.owner_visibility = 'until_return' and b.status::text in ('returned', 'closed', 'cancelled', 'no_show') then 'full'
    else 'booked' end
$$;

-- ================================================================ 4. a referrer's view of the referred cars
select pg_temp.patch_fn('public.server_owner_referred_cars(uuid)'::regprocedure,
  $o$s.payout_month >= (v_month - interval '3 months')::date and s.status <> 'reversed'$o$,
  $n$s.payout_month >= (v_month - interval '3 months')::date and s.payout_month < date '9999-01-01' and s.status <> 'reversed'$n$);

-- ================================================================ 5. the booking page
alter function app.booking_owner_visibility_read(uuid, bookings) rename to booking_owner_visibility_read_pre2480;
create function app.booking_owner_visibility_read(p_by uuid, b bookings) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when x.r is null or jsonb_typeof(x.r) <> 'object' then x.r
    else x.r || jsonb_build_object('counts_for_owner', x.c,
      'hide_drops_revenue', coalesce((app.settings()).owner_hide_insurance_only, true) and coalesce(b.bill_to::text, 'renter') <> 'renter')
      || case when x.c then '{}'::jsonb else jsonb_build_object('label',
           'Not part of the owner''s revenue (' ||
           case when coalesce(b.owner_revenue_excluded, false) then 'it does not count toward the owner''s revenue'
                when not coalesce(b.blocks_calendar, true) then 'an insurer rental that does not block the calendar'
                else 'an insurance replacement hidden from the owner' end ||
           '): it stays off their statements and payouts, and they see only that the car is unavailable for these dates.') end end
    from (select app.booking_owner_visibility_read_pre2480(p_by, b) as r, (b.booking_type::text = 'owner' or app.booking_counts_for_owner(b)) as c) x
$$;
select pg_temp.copy_grants('app.booking_owner_visibility_read(uuid, bookings)'::regprocedure, 'app.booking_owner_visibility_read_pre2480(uuid, bookings)'::regprocedure);

-- ================================================================ 6. rebuild the drafts of a period
create function app.owner_statements_rebuild_drafts(p_period_end date, p_by uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s record;
  v_n integer := 0;
  v_err jsonb := '{}'::jsonb;
  v_out jsonb;
begin
  for s in select st.id, st.owner_id, st.statement_month, st.statement_number from owner_statements st
            where st.status = 'draft' and coalesce(st.period_ends_on, app.statement_period_end(st.statement_month)) = p_period_end
              and coalesce(st.statement_number, '') not like 'MTD-%'
            order by st.statement_number, st.id
  loop
    begin
      perform app.build_owner_statement(s.owner_id, s.statement_month, p_by);
      v_n := v_n + 1;
    exception when others then
      v_err := v_err || jsonb_build_object(coalesce(s.statement_number, s.id::text), sqlerrm);
    end;
  end loop;
  v_out := jsonb_build_object('period_ends_on', p_period_end, 'rebuilt', v_n, 'errors', v_err);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'owner_statements_rebuild_drafts', 'owner_statements', p_period_end::text, v_out);
  return v_out;
end $$;
comment on function app.owner_statements_rebuild_drafts(date, uuid) is 'Owner statements (2480): rebuilds every draft statement whose period ends on the date, with app.build_owner_statement; approved, paid and void statements are never touched. Audited with the count and any error per statement.';

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['booking_counts_for_owner', 'booking_counts_for_owner_id', 'compute_booking_split_pre2480',
                                                       'booking_owner_visibility_read_pre2480', 'owner_statements_rebuild_drafts'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- the drafts of the November 10 payout (period ending November 7, 2026), once
select app.owner_statements_rebuild_drafts(date '2026-11-07', null);
