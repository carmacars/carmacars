-- 0012_security.sql
-- Row-level security for the five roles (admin, va, field, owner, renter), the limited views
-- the owner / renter / field portals read, approval and money-limit guards, and privileges.
-- The role matrix is in docs/permissions.md.
--
-- How access works
--   * Browser sessions reach the database as the "authenticated" role; app.uid() is the user.
--   * The server (webhooks, scheduled jobs, money-moving actions) uses "service_role", which
--     bypasses row-level security. Every function that moves money is executable by it alone.
--   * Renters, owners, field staff and investors are read-only at the database: what they
--     change goes through a server action that validates it first.
--   * RLS filters rows, not columns. Where a role may see a row but not all of it (an owner
--     and the renter's contact details, a renter and internal notes), the role has no policy
--     on the table and reads a view below instead.

-- ---------------------------------------------------------------- roles
-- Supabase ships these roles. On any other PostgreSQL host they are created here.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;

-- ---------------------------------------------------------------- who is asking
create or replace function app.has_role(p_role app_role) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from user_roles r join users u on u.id = r.user_id
                  where r.user_id = app.uid() and r.role = p_role and u.status = 'active')
$$;

create or replace function app.is_admin() returns boolean
language sql stable security definer set search_path = public, app as $$ select app.has_role('admin') $$;

-- An active virtual assistant, optionally holding one of the named functions (finance, fleet, cs, sales).
create or replace function app.va_has(variadic p_functions text[] default '{}') returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.has_role('va') and exists (
    select 1 from staff_profiles sp
     where sp.user_id = app.uid() and sp.staff_type = 'va' and sp.is_active
       and (cardinality(p_functions) = 0 or sp.va_function::text = any (p_functions)))
$$;

create or replace function app.is_va() returns boolean
language sql stable security definer set search_path = public, app as $$ select app.va_has() $$;

create or replace function app.is_field() returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.has_role('field') and exists (
    select 1 from staff_profiles sp where sp.user_id = app.uid() and sp.staff_type = 'field' and sp.is_active)
$$;

create or replace function app.is_staff() returns boolean
language sql stable security definer set search_path = public, app as $$ select app.is_admin() or app.is_va() $$;

create or replace function app.is_my_owner(p_owner uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.has_role('owner') and exists (select 1 from owners o where o.id = p_owner and o.user_id = app.uid())
$$;

create or replace function app.owns_vehicle(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.has_role('owner') and exists (
    select 1 from vehicles v join owners o on o.id = v.owner_id where v.id = p_vehicle and o.user_id = app.uid())
$$;

create or replace function app.my_renter_id() returns uuid
language sql stable security definer set search_path = public, app as $$
  select r.id from renters r where r.user_id = app.uid() and app.has_role('renter')
$$;

create or replace function app.is_my_booking(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from bookings b where b.id = p_booking and b.renter_id = app.my_renter_id())
$$;

create or replace function app.is_my_investor(p_investor uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from investors i where i.id = p_investor and i.user_id = app.uid())
$$;

-- Field staff see a booking or vehicle only through a job assigned to them, from the day
-- before it is scheduled until 24 hours after it is done.
create or replace function app.field_has_job(p_booking uuid, p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.is_field() and exists (
    select 1 from field_jobs j
     where j.assigned_to = app.uid() and j.status <> 'cancelled'
       and ((p_booking is not null and j.booking_id = p_booking) or (p_vehicle is not null and j.vehicle_id = p_vehicle))
       and j.scheduled_at <= now() + interval '36 hours'
       and (j.completed_at is null or j.completed_at > now() - interval '24 hours'))
$$;

-- ---------------------------------------------------------------- staff access to renter records
-- No bulk path to the customer list: a VA sees a renter's record only while there is work on it.
create table data_access_log (
  id            bigint generated always as identity primary key,
  user_id       uuid not null,
  action        text not null check (action in ('search', 'open')),
  query         text,
  renter_id     uuid references renters (id),
  reason        text,
  results       integer,
  granted_until timestamptz,
  at            timestamptz not null default now()
);
create index data_access_log_grant_idx on data_access_log (user_id, renter_id, granted_until);
create trigger data_access_log_append_only before update or delete on data_access_log
  for each row execute function app.forbid_change();

create or replace function app.va_sees_renter(p_renter uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.is_va() and (
    -- a booking that is live, or ended within the window
    exists (select 1 from bookings b
             where b.renter_id = p_renter
               and (b.status in ('tentative', 'pending_payment', 'confirmed', 'on_rent', 'returned')
                    or greatest(b.return_at, coalesce(b.checked_in_at, b.return_at))
                       > now() - make_interval(days => (app.settings()).staff_customer_window_days)))
    -- an open task about this renter
    or exists (select 1 from tasks t where t.renter_id = p_renter and t.status in ('open', 'in_progress', 'waiting'))
    -- a new lead with no booking yet
    or exists (select 1 from renters r where r.id = p_renter
                and r.created_at > now() - make_interval(days => (app.settings()).staff_customer_window_days)
                and not exists (select 1 from bookings b where b.renter_id = r.id))
    -- a logged, time-limited lookup (app.staff_open_renter)
    or exists (select 1 from data_access_log g
                where g.renter_id = p_renter and g.user_id = app.uid() and g.action = 'open' and g.granted_until > now()))
$$;

-- Find an older customer: at most 10 matches, name and booking number only, always logged.
create or replace function app.staff_find_renter(p_query text)
returns table (renter_id uuid, legal_name text, last_booking_number text)
language plpgsql security definer set search_path = public, app as $$
declare
  n integer;
begin
  if not (app.is_admin() or app.va_has('cs', 'finance', 'fleet')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_query, ''))) < 3 then
    raise exception 'Search needs at least 3 characters' using errcode = '22023';
  end if;
  return query
    select r.id, r.legal_name,
           (select b.booking_number from bookings b where b.renter_id = r.id order by b.pickup_at desc limit 1)
      from renters r
     where r.legal_name ilike '%' || btrim(p_query) || '%'
        or lower(r.email) = lower(btrim(p_query))
        or exists (select 1 from bookings b where b.renter_id = r.id and b.booking_number = btrim(p_query))
     order by r.legal_name limit 10;
  get diagnostics n = row_count;
  insert into data_access_log (user_id, action, query, results) values (app.uid(), 'search', p_query, n);
end $$;

-- Open one older record for 24 hours, with a reason, on the log.
create or replace function app.staff_open_renter(p_renter uuid, p_reason text) returns timestamptz
language plpgsql security definer set search_path = public, app as $$
declare
  v_until timestamptz := now() + interval '24 hours';
begin
  if not (app.is_admin() or app.va_has('cs', 'finance', 'fleet')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then
    raise exception 'Give the reason for opening this record' using errcode = '22023';
  end if;
  insert into data_access_log (user_id, action, renter_id, reason, granted_until)
  values (app.uid(), 'open', p_renter, p_reason, v_until);
  return v_until;
end $$;

-- ---------------------------------------------------------------- guards: approvals and money limits
-- An approval is always the approver's own act: a browser session can only put its own
-- user in an approval column.
create or replace function app.guard_approver() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_col text;
  v_new uuid;
  v_old uuid;
begin
  -- writes made by the schema's own triggers (nested) and by the server are trusted
  if pg_trigger_depth() > 1 or pg_catalog.current_setting('role', true) is distinct from 'authenticated' then
    return new;
  end if;
  foreach v_col in array tg_argv loop
    v_new := (to_jsonb(new) ->> v_col)::uuid;
    v_old := case when tg_op = 'UPDATE' then (to_jsonb(old) ->> v_col)::uuid end;
    if v_new is not null and v_new is distinct from v_old and v_new is distinct from app.uid() then
      raise exception 'You can only record your own approval (%)', v_col using errcode = '42501';
    end if;
  end loop;
  return new;
end $$;

create trigger refunds_guard_approver before insert or update on refunds
  for each row execute function app.guard_approver('approved_by');
create trigger deposits_guard_approver before insert or update on deposits
  for each row execute function app.guard_approver('release_approved_by');
create trigger payouts_guard_approver before insert or update on payouts
  for each row execute function app.guard_approver('approved_by', 'second_approved_by');
create trigger tracker_commands_guard_approver before insert or update on tracker_commands
  for each row execute function app.guard_approver('approved_by');
create trigger owner_statements_guard_approver before insert or update on owner_statements
  for each row execute function app.guard_approver('approved_by');
create trigger claims_guard_approver before insert or update on claims
  for each row execute function app.guard_approver('settled_by', 'second_approved_by');
create trigger line_items_guard_approver before insert or update on booking_line_items
  for each row execute function app.guard_approver('override_by');
create trigger fee_terms_guard_approver before insert or update on booking_fee_terms
  for each row execute function app.guard_approver('override_by');

-- May this user release a payment of this size? An Admin always. A finance VA only inside the
-- Single Limit in their Schedule A, and only for a payment the Procedures provide for.
create or replace function app.may_release_payment(p_user uuid, p_amount_cents bigint, p_inside_procedures boolean)
returns boolean language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from user_roles r join users u on u.id = r.user_id
                  where r.user_id = p_user and r.role = 'admin' and u.status = 'active')
      or (p_inside_procedures and exists (
            select 1 from staff_profiles sp join user_roles r on r.user_id = sp.user_id and r.role = 'va'
             where sp.user_id = p_user and sp.is_active and sp.va_function = 'finance'
               and p_amount_cents <= sp.single_limit_cents))
$$;

create or replace function app.guard_refund_approval() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  -- refunds are paid within 10 business days
  new.due_by := coalesce(new.due_by, app.add_business_days(app.local_date(coalesce(new.created_at, now())),
                                                           (app.settings()).refund_business_days));
  if new.status in ('approved', 'processing', 'paid')
     and (tg_op = 'INSERT' or old.status in ('pending_approval', 'rejected')
          or new.amount_cents is distinct from old.amount_cents or new.approved_by is distinct from old.approved_by) then
    -- a refund outside the cancellation table, or above the limit, is an Admin's decision
    if not app.may_release_payment(new.approved_by, new.amount_cents,
         new.reason in ('cancellation', 'carmacars_cancelled', 'driver_not_verifiable')
         and exists (select 1 from booking_cancellations c
                      where c.booking_id = new.booking_id and c.refund_cents = new.amount_cents)) then
      raise exception 'This refund needs an Admin''s approval' using errcode = '42501';
    end if;
    new.approved_at := coalesce(new.approved_at, now());
  end if;
  return new;
end $$;
create trigger refunds_guard_approval before insert or update on refunds
  for each row execute function app.guard_refund_approval();

create or replace function app.guard_deposit_release() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_delta bigint := new.released_cents - case when tg_op = 'UPDATE' then old.released_cents else 0 end;
begin
  if v_delta > 0 then
    if new.release_approved_by is null or not app.may_release_payment(new.release_approved_by, v_delta, true) then
      raise exception 'This deposit release needs an Admin''s approval' using errcode = '42501';
    end if;
    new.released_at := coalesce(new.released_at, now());
  end if;
  return new;
end $$;
create trigger deposits_guard_release before insert or update on deposits
  for each row execute function app.guard_deposit_release();

-- Payout runs stay Admin-approved for good. A payment needing both Principals needs two admins.
create or replace function app.guard_payout() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status in ('approved', 'sent', 'paid') then
    if not exists (select 1 from user_roles where user_id = new.approved_by and role = 'admin') then
      raise exception 'Only an Admin approves a payout' using errcode = '42501';
    end if;
    if new.requires_both_principals and not exists (
         select 1 from user_roles where user_id = new.second_approved_by and role = 'admin') then
      raise exception 'This payment needs both Principals'' approval' using errcode = '42501';
    end if;
    new.approved_at := coalesce(new.approved_at, now());
  end if;
  if tg_op = 'UPDATE' and old.status in ('approved', 'sent', 'paid')
     and (new.amount_cents, new.owner_id, new.staff_user_id, new.investor_id, new.method)
         is distinct from (old.amount_cents, old.owner_id, old.staff_user_id, old.investor_id, old.method) then
    raise exception 'An approved payout cannot be altered; cancel it and prepare a new one' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger payouts_guard before insert or update on payouts
  for each row execute function app.guard_payout();

-- A per-booking price change (B) is an Admin's decision, and only for charges the catalogue marks B.
create or replace function app.guard_booking_override() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_code text := case when tg_table_name = 'booking_line_items' then (to_jsonb(new) ->> 'charge_type') else (to_jsonb(new) ->> 'fee_type_code') end;
  v_by uuid := (to_jsonb(new) ->> 'override_by')::uuid;
begin
  if v_by is not null and (tg_op = 'INSERT' or v_by is distinct from (to_jsonb(old) ->> 'override_by')::uuid) then
    if not exists (select 1 from user_roles where user_id = v_by and role = 'admin') then
      raise exception 'Only an Admin overrides a price on one booking' using errcode = '42501';
    end if;
    if not exists (select 1 from fee_types f where f.code = v_code and f.change_booking) then
      raise exception 'The charge "%" is fixed and cannot be overridden per booking', v_code using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
create trigger line_items_guard_override before insert or update on booking_line_items
  for each row execute function app.guard_booking_override();
create trigger fee_terms_guard_override before insert or update on booking_fee_terms
  for each row execute function app.guard_booking_override();

-- Columns a browser session may change only as an Admin.
create or replace function app.guard_admin_columns() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_col text;
begin
  -- only a browser session's own statement is checked; the schema's nested triggers are trusted
  if pg_trigger_depth() = 1 and pg_catalog.current_setting('role', true) = 'authenticated' and not app.is_admin() then
    foreach v_col in array tg_argv loop
      if (to_jsonb(new) -> v_col) is distinct from (to_jsonb(old) -> v_col) then
        raise exception 'Only an Admin changes % on %', v_col, tg_table_name using errcode = '42501';
      end if;
    end loop;
  end if;
  return new;
end $$;
create trigger owners_guard_admin_columns before update on owners
  for each row execute function app.guard_admin_columns(
    'user_id', 'is_shareholder', 'payout_method', 'balance_carried_forward_cents', 'hst_number', 'referral_code', 'status');
create trigger vehicles_guard_admin_columns before update on vehicles
  for each row execute function app.guard_admin_columns(
    'owner_id', 'management_mode', 'is_shareholder_owned', 'in_arrears', 'enrollment_date', 'exit_date',
    'on_fleet_policy', 'fleet_policy_added_on', 'fleet_policy_removed_on', 'total_loss_decided_on', 'allows_18_to_20');
create trigger bookings_guard_admin_columns before update on bookings
  for each row execute function app.guard_admin_columns(
    'company_share_bps', 'deductible_cents', 'outside_ontario_consent', 'pets_approved',
    'referrer_type', 'referrer_owner_id', 'referrer_staff_id', 'owner_id', 'management_mode');
-- Field staff work their own job: they may acknowledge, start and finish it, nothing else.
create or replace function app.guard_field_job() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if pg_trigger_depth() = 1 and pg_catalog.current_setting('role', true) = 'authenticated'
     and not app.is_staff()
     and (new.kind, new.booking_id, new.vehicle_id, new.assigned_to, new.dispatched_by, new.scheduled_at, new.place,
          new.instructions, new.reviewed_by, new.reviewed_at)
         is distinct from
         (old.kind, old.booking_id, old.vehicle_id, old.assigned_to, old.dispatched_by, old.scheduled_at, old.place,
          old.instructions, old.reviewed_by, old.reviewed_at) then
    raise exception 'Field staff can only update the progress of their own job' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger field_jobs_guard before update on field_jobs
  for each row execute function app.guard_field_job();

-- ---------------------------------------------------------------- limited views for the portals
-- These views are owned by the migration role and filter by the caller inside the view.

-- A renter's own bookings, without internal notes, the split or the referrer.
create view renter_bookings with (security_barrier = true) as
  select b.id, b.booking_number, b.agreement_number, b.booking_type, b.renews_booking_id, b.status,
         b.vehicle_id, v.year as vehicle_year, v.make as vehicle_make, v.model as vehicle_model, v.colour as vehicle_colour,
         b.booked_at, b.confirmed_at, b.pickup_at, b.return_at, b.original_return_at, b.pickup_place, b.return_place,
         b.pickup_method, b.return_method, b.billable_days, b.handed_over_at, b.checked_in_at,
         b.daily_rate_cents, b.weekend_rate_cents, b.weekly_rate_cents, b.monthly_rate_cents, b.rate_applied,
         b.daily_days, b.weekend_days, b.rental_charge_cents, b.discount_cents,
         b.km_allowance_per_day, b.km_allowance_total, b.overage_cents_per_km, b.deposit_cents, b.deductible_cents,
         b.subtotal_at_booking_cents, b.hst_at_booking_cents, b.total_due_at_booking_cents,
         b.coverage_option, b.coverage_confirmed_at, b.odometer_out_km, b.odometer_in_km,
         b.fuel_out_pct, b.fuel_in_pct, b.minutes_late, b.extra_days, b.agreement_document_id
    from bookings b join vehicles v on v.id = b.vehicle_id
   where b.renter_id = app.my_renter_id();

-- An owner's view of bookings on their own vehicles: dates, status and the rental charge.
-- The renter's name and mobile appear only on a Self-Managed booking (the details needed to
-- hand over the vehicle). Never the renter's identification, address, email or card.
create view owner_bookings with (security_barrier = true) as
  select b.id, b.booking_number, b.booking_type, b.status, b.vehicle_id, b.management_mode,
         b.pickup_at, b.return_at, b.pickup_place, b.return_place, b.billable_days,
         b.handed_over_at, b.checked_in_at,
         b.rental_charge_cents - b.discount_cents as rental_charge_cents,
         case when b.management_mode = 'self_managed' or b.booking_type = 'owner' then r.legal_name end as renter_name,
         case when b.management_mode = 'self_managed' or b.booking_type = 'owner' then r.mobile end as renter_mobile,
         s.mileage_overage_cents, s.kickback_cents, s.owner_revenue_cents, s.company_share_cents, s.owner_payout_cents,
         s.payout_month
    from bookings b
    join renters r on r.id = b.renter_id
    left join booking_splits s on s.booking_id = b.id
   where app.is_my_owner(b.owner_id)
     and b.status not in ('tentative', 'expired', 'declined');

-- "Open claims: vehicle, status" for the owner statement. Claim money is not the Owner's.
create view owner_claims with (security_barrier = true) as
  select c.id, c.claim_number, c.vehicle_id, c.path, c.status, c.created_at,
         case when c.is_shareholder_vehicle or c.path = 'total_loss' then c.owner_result_cents end as owner_result_cents,
         case when c.path = 'total_loss' then c.owner_balance_cents end as owner_balance_cents,
         case when c.path = 'total_loss' then c.owner_balance_due_by end as owner_balance_due_by
    from claims c
   where app.is_my_owner(c.owner_id);

-- What field staff need for an assigned job: who, where, when, and what to match at the door.
create view field_job_details with (security_barrier = true) as
  select j.id as field_job_id, j.kind, j.status, j.scheduled_at, j.place, j.instructions,
         j.vehicle_id, v.year, v.make, v.model, v.colour, v.plate,
         j.booking_id, b.booking_number, b.pickup_at, b.return_at, b.unattended_handover,
         r.legal_name as renter_name, r.mobile as renter_mobile,
         pm.card_brand, pm.card_last4,
         (select jsonb_agg(jsonb_build_object('name', d.full_name, 'role', d.role, 'licence_number', d.licence_number,
                                              'licence_class', d.licence_class, 'licence_expiry', d.licence_expiry)
                           order by d.role desc)
            from booking_drivers d where d.booking_id = b.id) as drivers
    from field_jobs j
    join vehicles v on v.id = j.vehicle_id
    left join bookings b on b.id = j.booking_id
    left join renters r on r.id = b.renter_id
    left join payment_methods pm on pm.id = b.card_on_file_id
   where j.assigned_to = app.uid() and app.is_field() and j.status <> 'cancelled'
     and j.scheduled_at <= now() + interval '36 hours'
     and (j.completed_at is null or j.completed_at > now() - interval '24 hours');

-- Names of staff, for assigning work. No contact details.
create view staff_directory with (security_barrier = true) as
  select u.id as user_id, u.full_name, sp.staff_type, sp.va_function, sp.field_function
    from users u join staff_profiles sp on sp.user_id = u.id
   where sp.is_active and u.status = 'active' and (app.is_staff() or app.is_field());

-- The public site: published vehicles with their current rate card. No owner, VIN or plate.
create view public_vehicle_listings with (security_barrier = true) as
  select l.slug, l.headline, l.description, l.features, l.seats, l.transmission,
         v.id as vehicle_id, v.year, v.make, v.model, v.trim, v.colour, v.fuel, v.class, v.allows_18_to_20,
         rc.daily_rate_cents, rc.weekend_rate_cents, rc.weekly_rate_cents, rc.monthly_rate_cents,
         rc.km_allowance_per_day, rc.overage_cents_per_km, rc.deposit_cents, rc.delivery_fee_cents, rc.pickup_fee_cents
    from vehicle_listings l
    join vehicles v on v.id = l.vehicle_id
    join rate_cards rc on rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())
   where l.status = 'published' and v.management_mode <> 'turo_only'
     and v.bookings_enabled and v.status in ('available', 'on_rent', 'cleaning')
     and not (v.management_mode = 'self_managed' and v.in_arrears);

-- ---------------------------------------------------------------- enable RLS everywhere
-- Every table: RLS on, and an Admin may read and write everything. Nothing else is open
-- until a policy below says so.
do $$
declare
  t record;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t.tablename);
    execute format('create policy admin_all on public.%I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t.tablename);
  end loop;
end $$;

-- Helper for the policies below (dropped at the end of this file).
create or replace function app._policy(p_table text, p_name text, p_cmd text, p_using text, p_check text default null)
returns void language plpgsql as $$
begin
  execute format('create policy %I on public.%I for %s to authenticated %s %s',
    p_name, p_table, p_cmd,
    case when p_cmd = 'insert' then '' else 'using (' || p_using || ')' end,
    case when p_cmd in ('insert', 'update', 'all') then 'with check (' || coalesce(p_check, p_using) || ')' else '' end);
end $$;

-- ............................................................ reference data: any signed-in user
select app._policy(t, 'read_all', 'select', 'true')
  from unnest(array['fee_types', 'holidays', 'status_transitions', 'onboarding_method_info']) t;
select app._policy(t, 'staff_read', 'select', 'app.is_va() or app.is_field()')
  from unnest(array['program_settings', 'message_templates']) t;
select app._policy(t, 'va_read', 'select', 'app.is_va()')
  from unnest(array['fee_defaults', 'vehicle_fee_overrides', 'owner_fee_grid', 'status_history']) t;

-- ............................................................ people
select app._policy('users', 'self_read', 'select', 'id = app.uid()');
select app._policy('user_roles', 'self_read', 'select', 'user_id = app.uid()');
select app._policy('staff_profiles', 'self_read', 'select', 'user_id = app.uid()');

select app._policy('renters', 'self_read', 'select', 'id = app.my_renter_id()');
select app._policy('renters', 'va_read', 'select', 'app.va_sees_renter(id)');
select app._policy('renters', 'va_insert', 'insert', null, $$app.va_has('cs', 'sales')$$);
select app._policy('renters', 'va_update', 'update', $$app.va_has('cs') and app.va_sees_renter(id)$$);

select app._policy('drivers', 'self_read', 'select', 'renter_id = app.my_renter_id()');
select app._policy('drivers', 'cs_read', 'select', $$app.va_has('cs') and app.va_sees_renter(renter_id)$$);
select app._policy('drivers', 'cs_insert', 'insert', null, $$app.va_has('cs')$$);
select app._policy('drivers', 'cs_update', 'update', $$app.va_has('cs') and app.va_sees_renter(renter_id)$$);

select app._policy('payment_methods', 'self_read', 'select', 'renter_id = app.my_renter_id()');
select app._policy('payment_methods', 'va_read', 'select', $$app.va_has('finance', 'cs') and app.va_sees_renter(renter_id)$$);
-- payment_method_secrets, payment_processor_details, owner_payment_method_secrets: admin only (no further policy)

select app._policy('identity_verifications', 'self_read', 'select',
  'exists (select 1 from drivers d where d.id = driver_id and d.renter_id = app.my_renter_id())');
select app._policy('identity_verifications', 'cs_read', 'select',
  $$app.va_has('cs') and exists (select 1 from drivers d where d.id = driver_id and app.va_sees_renter(d.renter_id))$$);
select app._policy('identity_verifications', 'cs_insert', 'insert', null, $$app.va_has('cs')$$);
select app._policy('identity_verifications', 'cs_update', 'update',
  $$app.va_has('cs') and exists (select 1 from drivers d where d.id = driver_id and app.va_sees_renter(d.renter_id))$$);

select app._policy('consents', 'self_read', 'select', 'user_id = app.uid()');
select app._policy('consents', 'cs_read', 'select', $$app.va_has('cs') and booking_id is not null$$);

-- ............................................................ owners
select app._policy('owners', 'self_read', 'select', 'user_id = app.uid() and app.has_role(''owner'')');
select app._policy('owners', 'va_read', 'select', $$app.va_has('cs', 'finance', 'fleet')$$);
select app._policy('owners', 'cs_insert', 'insert', null, $$app.va_has('cs') and not is_shareholder and balance_carried_forward_cents = 0$$);
select app._policy('owners', 'cs_update', 'update', $$app.va_has('cs')$$);

-- bank details: the Owner and an Admin only. Only an Admin changes a payee's bank details.
select app._policy('owner_payout_accounts', 'owner_read', 'select', 'app.is_my_owner(owner_id)');
select app._policy('owner_payment_methods', 'owner_read', 'select', 'app.is_my_owner(owner_id)');
select app._policy('owner_payment_methods', 'finance_read', 'select', $$app.va_has('finance')$$);

select app._policy(t, 'owner_read', 'select', 'app.is_my_owner(owner_id)')
  from unnest(array['owner_agreements', 'owner_invoices', 'owner_deductions', 'vehicle_prepaids', 'toll_tickets']) t;
select app._policy('owner_agreements', 'va_read', 'select', $$app.va_has('cs', 'finance', 'fleet')$$);
select app._policy('owner_agreements', 'cs_insert', 'insert', null, $$app.va_has('cs') and status in ('draft', 'sent')$$);
select app._policy('owner_agreements', 'cs_update', 'update', $$app.va_has('cs') and status in ('draft', 'sent')$$);
select app._policy('owner_agreement_forms', 'owner_read', 'select',
  'exists (select 1 from owner_agreements a where a.id = owner_agreement_id and app.is_my_owner(a.owner_id))');
select app._policy('owner_agreement_forms', 'va_read', 'select', $$app.va_has('cs', 'finance', 'fleet')$$);
select app._policy('owner_agreement_forms', 'cs_insert', 'insert', null, $$app.va_has('cs')$$);
select app._policy('owner_agreement_forms', 'cs_update', 'update', $$app.va_has('cs')$$);

-- ............................................................ vehicles
select app._policy('vehicles', 'owner_read', 'select', 'app.is_my_owner(owner_id)');
select app._policy('vehicles', 'va_read', 'select', 'app.is_va()');
select app._policy('vehicles', 'field_read', 'select', 'app.field_has_job(null, id)');
select app._policy('vehicles', 'fleet_insert', 'insert', null,
  $$app.va_has('fleet') and status = 'onboarding' and not is_shareholder_owned and not in_arrears and enrollment_date is null$$);
select app._policy('vehicles', 'fleet_update', 'update', $$app.va_has('fleet')$$);

select app._policy(t, 'owner_read', 'select', 'app.owns_vehicle(vehicle_id)')
  from unnest(array['vehicle_schedules', 'vehicle_fee_history', 'vehicle_onboardings', 'vehicle_registrations', 'vehicle_exits',
                    'vehicle_buyouts', 'turo_listings', 'turo_trips', 'vehicle_calendar_blocks', 'vehicle_listings',
                    'vehicle_photos', 'rate_cards', 'tracker_devices', 'tracker_access_blocks']) t;
-- what every VA needs to quote and schedule: the calendar, the listing, the rates
select app._policy(t, 'va_read', 'select', 'app.is_va()')
  from unnest(array['vehicle_calendar_blocks', 'vehicle_listings', 'vehicle_photos', 'photo_jobs', 'rate_cards']) t;
-- owner terms and onboarding: not the sales role
select app._policy(t, 'va_read', 'select', $$app.va_has('cs', 'finance', 'fleet')$$)
  from unnest(array['vehicle_schedules', 'vehicle_fee_history', 'vehicle_onboardings', 'vehicle_registrations', 'vehicle_exits',
                    'vehicle_buyouts', 'turo_listings']) t;
-- where a car is: Fleet runs the tracker; Finance uses it as proof for tolls and tickets
select app._policy(t, 'va_read', 'select', $$app.va_has('fleet', 'finance')$$)
  from unnest(array['tracker_devices', 'tracker_access_blocks', 'tracker_status']) t;
-- Admin sets Fees, Revenue Share and Management Mode: vehicle_schedules and vehicle_fee_history are admin-write only.
select app._policy(t, 'va_insert', 'insert', null, $$app.va_has('fleet', 'cs')$$)
  from unnest(array['vehicle_onboardings', 'vehicle_registrations', 'vehicle_exits', 'vehicle_calendar_blocks',
                    'vehicle_listings', 'vehicle_photos', 'photo_jobs', 'turo_listings']) t;
select app._policy(t, 'va_update', 'update', $$app.va_has('fleet', 'cs')$$)
  from unnest(array['vehicle_onboardings', 'vehicle_registrations', 'vehicle_exits', 'vehicle_calendar_blocks',
                    'vehicle_listings', 'vehicle_photos', 'photo_jobs', 'turo_listings']) t;
select app._policy('rate_cards', 'fleet_insert', 'insert', null, $$app.va_has('fleet')$$);   -- Admin sets, Fleet enters
select app._policy('rate_cards', 'fleet_update', 'update', $$app.va_has('fleet')$$);
select app._policy('turo_trips', 'va_read', 'select', $$app.va_has('finance', 'fleet')$$);
select app._policy('turo_trips', 'finance_insert', 'insert', null, $$app.va_has('finance')$$);
select app._policy('turo_trips', 'finance_update', 'update', $$app.va_has('finance') and owner_statement_id is null$$);
select app._policy('vehicle_photos', 'field_read', 'select', 'app.field_has_job(null, vehicle_id)');
select app._policy('vehicle_photos', 'field_insert', 'insert', null, 'app.field_has_job(null, vehicle_id) and uploaded_by = app.uid()');

-- ............................................................ tracker
select app._policy('tracker_status', 'owner_read', 'select',   -- the Owner keeps live location at all times
  'exists (select 1 from tracker_devices d where d.id = tracker_device_id and app.owns_vehicle(d.vehicle_id))');
select app._policy('tracker_devices', 'fleet_insert', 'insert', null, $$app.va_has('fleet')$$);
select app._policy('tracker_devices', 'fleet_update', 'update', $$app.va_has('fleet')$$);
select app._policy('tracker_devices', 'field_read', 'select', 'app.field_has_job(null, vehicle_id)');
select app._policy('tracker_access_blocks', 'fleet_insert', 'insert', null, $$app.va_has('fleet')$$);
select app._policy('tracker_access_blocks', 'fleet_update', 'update', $$app.va_has('fleet')$$);
select app._policy('tracker_commands', 'fleet_read', 'select', $$app.va_has('fleet')$$);
select app._policy('tracker_commands', 'fleet_insert', 'insert', null,
  $$app.va_has('fleet') and requested_by = app.uid() and actor_type = 'staff' and approved_by is null$$);
select app._policy('tracker_commands', 'fleet_update', 'update', $$app.va_has('fleet')$$);
select app._policy('tracker_commands', 'owner_read', 'select', $$actor_type = 'owner' and requested_by = app.uid()$$);
select app._policy('tracker_commands', 'owner_insert', 'insert', null,
  $$actor_type = 'owner' and requested_by = app.uid() and app.owns_vehicle(vehicle_id) and approved_by is null
    and reason_code = 'owner_protecting_vehicle' and booking_id is null and status in ('requested', 'blocked')$$);

-- ............................................................ bookings (renters, owners and field staff read the views)
select app._policy('bookings', 'va_read', 'select',
  $$app.va_has('cs', 'finance', 'fleet') or (app.va_has('sales') and status in ('tentative', 'pending_payment'))$$);
select app._policy('bookings', 'cs_insert', 'insert', null, $$app.va_has('cs') and status in ('tentative', 'pending_payment')$$);
select app._policy('bookings', 'sales_insert', 'insert', null, $$app.va_has('sales') and status = 'tentative'$$);
select app._policy('bookings', 'va_update', 'update', $$app.va_has('cs', 'fleet')$$);
select app._policy('bookings', 'sales_update', 'update', $$app.va_has('sales') and status = 'tentative'$$);

select app._policy(t, 'renter_read', 'select', 'app.is_my_booking(booking_id)')
  from unnest(array['booking_drivers', 'booking_fee_terms', 'coverage_proofs', 'booking_statements', 'booking_extensions',
                    'deposits', 'refunds', 'booking_cancellations', 'payments', 'condition_reports']) t;
select app._policy('booking_renewals', 'renter_read', 'select', 'app.is_my_booking(new_booking_id) or app.is_my_booking(previous_booking_id)');
select app._policy('booking_line_items', 'renter_read', 'select', 'charged_to_renter and voided_at is null and app.is_my_booking(booking_id)');
select app._policy('deposit_events', 'renter_read', 'select',
  'exists (select 1 from deposits d where d.id = deposit_id and app.is_my_booking(d.booking_id))');
select app._policy('toll_tickets', 'renter_read', 'select', $$matched_to = 'renter' and app.is_my_booking(booking_id)$$);

select app._policy(t, 'va_read', 'select', $$app.va_has('cs', 'finance', 'fleet')$$)
  from unnest(array['booking_fee_terms', 'coverage_proofs', 'booking_extensions', 'booking_renewals',
                    'booking_vehicle_swaps', 'booking_line_items', 'booking_cancellations', 'condition_reports',
                    'condition_report_damages', 'condition_report_photos', 'field_jobs', 'incidents', 'incident_events']) t;
select app._policy('booking_drivers', 'va_read', 'select', $$app.va_has('cs', 'fleet')$$);
select app._policy(t, 'cs_insert', 'insert', null, $$app.va_has('cs')$$)
  from unnest(array['booking_drivers', 'coverage_proofs', 'booking_extensions', 'booking_renewals', 'booking_cancellations']) t;
select app._policy(t, 'cs_update', 'update', $$app.va_has('cs')$$)
  from unnest(array['booking_drivers', 'coverage_proofs', 'booking_extensions']) t;
select app._policy('booking_vehicle_swaps', 'fleet_insert', 'insert', null, $$app.va_has('fleet')$$);

-- ............................................................ money in (renters)
-- Payment rows are written by the server from the processor's webhooks; finance reads them.
select app._policy(t, 'va_read', 'select', $$app.va_has('finance', 'cs')$$)
  from unnest(array['payments', 'booking_statements', 'deposits', 'deposit_events', 'refunds', 'refund_allocations']) t;
select app._policy('payment_attempts', 'finance_read', 'select', $$app.va_has('finance')$$);
select app._policy('disputes', 'finance_read', 'select', $$app.va_has('finance')$$);
select app._policy('disputes', 'finance_update', 'update', $$app.va_has('finance')$$);
select app._policy('booking_line_items', 'finance_insert', 'insert', null, $$app.va_has('finance') and created_by = app.uid()$$);
select app._policy('booking_line_items', 'finance_update', 'update', $$app.va_has('finance')$$);
select app._policy('booking_statements', 'finance_insert', 'insert', null, $$app.va_has('finance')$$);
select app._policy('booking_statements', 'finance_update', 'update', $$app.va_has('finance')$$);
select app._policy('deposits', 'finance_update', 'update', $$app.va_has('finance')$$);          -- release limits: guard_deposit_release
select app._policy('deposit_events', 'finance_insert', 'insert', null, $$app.va_has('finance') and created_by = app.uid()$$);
select app._policy('refunds', 'finance_insert', 'insert', null, $$app.va_has('finance') and requested_by = app.uid()$$);
select app._policy('refunds', 'finance_update', 'update', $$app.va_has('finance')$$);            -- approval limits: guard_refund_approval
select app._policy('refund_allocations', 'finance_insert', 'insert', null, $$app.va_has('finance')$$);
select app._policy('booking_splits', 'finance_read', 'select', $$app.va_has('finance')$$);
select app._policy('booking_splits', 'owner_read', 'select', 'app.is_my_owner(owner_id)');

-- ............................................................ field work
select app._policy('field_jobs', 'field_read', 'select', 'assigned_to = app.uid() and app.is_field()');
select app._policy('field_jobs', 'field_update', 'update', 'assigned_to = app.uid() and app.is_field()');
select app._policy('field_jobs', 'fleet_insert', 'insert', null, $$app.va_has('fleet')$$);
select app._policy('field_jobs', 'fleet_update', 'update', $$app.va_has('fleet')$$);

select app._policy('condition_reports', 'field_read', 'select', 'performed_by = app.uid() and app.field_has_job(booking_id, vehicle_id)');
select app._policy('condition_reports', 'field_insert', 'insert', null, 'performed_by = app.uid() and app.field_has_job(booking_id, vehicle_id)');
select app._policy('condition_reports', 'field_update', 'update', 'performed_by = app.uid() and app.field_has_job(booking_id, vehicle_id) and reviewed_at is null');
select app._policy('condition_reports', 'fleet_insert', 'insert', null, $$app.va_has('fleet')$$);
select app._policy('condition_reports', 'fleet_update', 'update', $$app.va_has('fleet')$$);
-- the Owner sees the baseline and exit reports of their own vehicle, and reports the Owner made (Self-Managed handover)
select app._policy('condition_reports', 'owner_read', 'select',
  $$app.owns_vehicle(vehicle_id) and (kind in ('baseline', 'exit') or performed_by = app.uid())$$);
-- photos and damages follow the report they belong to (the subquery runs under the caller's own policies)
select app._policy(t, 'via_report_read', 'select', 'exists (select 1 from condition_reports c where c.id = condition_report_id)')
  from unnest(array['condition_report_damages', 'condition_report_photos']) t;
select app._policy(t, 'via_report_insert', 'insert', null,
  $$(app.va_has('fleet') or app.is_field()) and exists (select 1 from condition_reports c where c.id = condition_report_id)$$)
  from unnest(array['condition_report_damages', 'condition_report_photos']) t;
select app._policy('condition_report_damages', 'fleet_update', 'update', $$app.va_has('fleet')$$);

-- ............................................................ queues, messages, daily checks
select app._policy('tasks', 'va_read', 'select',
  $$app.is_va() and (assigned_to = app.uid() or created_by = app.uid() or app.va_has(queue))$$);
select app._policy('tasks', 'va_insert', 'insert', null, 'app.is_va() and created_by = app.uid()');
select app._policy('tasks', 'va_update', 'update', $$app.is_va() and (assigned_to = app.uid() or app.va_has(queue))$$);
select app._policy('messages', 'va_read', 'select',
  $$app.va_has('cs', 'finance', 'fleet') and (renter_id is null or app.va_sees_renter(renter_id))$$);
select app._policy('messages', 'va_insert', 'insert', null, $$app.va_has('cs', 'finance', 'fleet') and sent_by = app.uid()$$);
select app._policy('messages', 'own_read', 'select',
  $$(user_id = app.uid() or renter_id = app.my_renter_id() or app.is_my_owner(owner_id))
    and not exists (select 1 from message_templates mt where mt.code = template_code and mt.audience = 'internal')$$);
select app._policy('daily_checks', 'va_all', 'all', $$app.va_has('fleet', 'cs', 'finance')$$);

-- ............................................................ incidents, claims, tolls
select app._policy('incidents', 'fleet_insert', 'insert', null, $$app.va_has('fleet')$$);
select app._policy('incidents', 'fleet_update', 'update', $$app.va_has('fleet')$$);
select app._policy('incident_events', 'va_insert', 'insert', null, $$app.va_has('fleet', 'cs') and actor_user_id = app.uid()$$);
select app._policy('incident_costs', 'va_read', 'select', $$app.va_has('finance', 'fleet')$$);
select app._policy('incident_costs', 'va_insert', 'insert', null, $$app.va_has('finance', 'fleet') and created_by = app.uid()$$);
select app._policy('claims', 'va_read', 'select', $$app.va_has('finance', 'fleet')$$);          -- Admin runs the claim
select app._policy('claim_ledger_entries', 'finance_read', 'select', $$app.va_has('finance')$$);
select app._policy('toll_tickets', 'va_read', 'select', $$app.va_has('finance', 'fleet')$$);
select app._policy('toll_tickets', 'finance_insert', 'insert', null, $$app.va_has('finance')$$);
select app._policy('toll_tickets', 'finance_update', 'update', $$app.va_has('finance')$$);

-- ............................................................ owner billing
select app._policy(t, 'finance_read', 'select', $$app.va_has('finance')$$)
  from unnest(array['owner_invoices', 'owner_invoice_lines', 'vehicle_prepaids', 'owner_deductions', 'referral_kickbacks',
                    'owner_statements', 'owner_statement_vehicles', 'owner_statement_lines',
                    'fleet_reports', 'fleet_report_vehicles', 'fleet_counts']) t;
select app._policy('owner_invoices', 'cs_read', 'select', $$app.va_has('cs')$$);
select app._policy('owner_invoice_lines', 'owner_read', 'select',
  'exists (select 1 from owner_invoices i where i.id = owner_invoice_id and app.is_my_owner(i.owner_id))');
select app._policy('owner_deductions', 'finance_insert', 'insert', null,
  $$app.va_has('finance') and created_by = app.uid() and status = 'open' and kind <> 'agreed_in_writing'$$);
select app._policy(t, 'finance_write', 'insert', null, $$app.va_has('finance')$$)
  from unnest(array['fleet_reports', 'fleet_report_vehicles', 'fleet_counts']) t;
select app._policy(t, 'finance_update', 'update', $$app.va_has('finance')$$)
  from unnest(array['fleet_reports', 'fleet_counts']) t;
select app._policy(t, 'fleet_read', 'select', $$app.va_has('fleet')$$)
  from unnest(array['fleet_reports', 'fleet_report_vehicles', 'fleet_counts']) t;
-- an Owner sees a statement once it is approved, never a draft
select app._policy('owner_statements', 'owner_read', 'select', $$app.is_my_owner(owner_id) and status in ('approved', 'paid')$$);
select app._policy(t, 'owner_read', 'select',
  $$exists (select 1 from owner_statements s where s.id = owner_statement_id and app.is_my_owner(s.owner_id) and s.status in ('approved', 'paid'))$$)
  from unnest(array['owner_statement_vehicles', 'owner_statement_lines']) t;
-- kickbacks: the referrer sees what they earned
select app._policy('referral_kickbacks', 'referrer_read', 'select',
  'app.is_my_owner(referrer_owner_id) or (referrer_staff_id = app.uid() and app.is_field())');

-- payouts: finance prepares Owner and payroll payouts and can never approve one (guard_payout)
select app._policy('payouts', 'payee_read', 'select',
  $$app.is_my_owner(owner_id) or (staff_user_id = app.uid() and app.is_field()) or app.is_my_investor(investor_id)$$);
select app._policy('payouts', 'finance_read', 'select', $$app.va_has('finance') and payee_type in ('owner', 'field_staff')$$);
select app._policy('payouts', 'finance_insert', 'insert', null,
  $$app.va_has('finance') and payee_type in ('owner', 'field_staff') and status in ('draft', 'pending_approval')
    and prepared_by = app.uid() and approved_by is null$$);
select app._policy('payouts', 'finance_update', 'update',
  $$app.va_has('finance') and payee_type in ('owner', 'field_staff') and status in ('draft', 'pending_approval')$$,
  $$app.va_has('finance') and payee_type in ('owner', 'field_staff') and status in ('draft', 'pending_approval', 'cancelled')$$);

-- ............................................................ investors: admin, and the investor's own records
select app._policy('investors', 'self_read', 'select', 'user_id = app.uid()');
select app._policy(t, 'self_read', 'select', 'app.is_my_investor(investor_id)')
  from unnest(array['investor_bank_accounts', 'investment_agreements', 'investments']) t;
select app._policy('investment_elections', 'self_read', 'select',
  'exists (select 1 from investment_agreements a where a.id = agreement_id and app.is_my_investor(a.investor_id))');
select app._policy(t, 'self_read', 'select',
  'exists (select 1 from investments i where i.id = investment_id and app.is_my_investor(i.investor_id))')
  from unnest(array['investment_returns', 'investment_redemptions']) t;
select app._policy('investment_transfers', 'self_read', 'select',
  'app.is_my_investor(to_investor_id) or exists (select 1 from investments i where i.id = from_investment_id and app.is_my_investor(i.investor_id))');

-- ............................................................ documents and signatures
-- Identification images: the person themselves, CS for a renter in their working window, an Admin.
-- Investor, staff and shareholder documents: admin-only folder. An Owner never sees a renter's documents.
select app._policy('documents', 'renter_read', 'select',
  $$(renter_id = app.my_renter_id() or app.is_my_booking(booking_id))
    and kind in ('rental_agreement', 'condition_report', 'renter_statement', 'coverage_proof', 'coverage_terms',
                 'coverage_activation', 'id_front', 'id_back', 'face_photo', 'toll_ticket_notice', 'receipt',
                 'repair_estimate', 'repair_invoice', 'notice')$$);
select app._policy('documents', 'owner_read', 'select',
  $$(app.is_my_owner(owner_id) or app.owns_vehicle(vehicle_id)) and renter_id is null and booking_id is null
    and kind in ('enrollment_agreement', 'title_agreement', 'vehicle_schedule', 'additional_vehicle_schedule', 'title_schedule',
                 'form_a_trust_declaration', 'form_b_lease_summary', 'form_c_finance_permission_ack', 'form_d_power_of_attorney',
                 'form_e_exit_checklist', 'finance_party_permission', 'ownership_permit', 'insurer_confirmation',
                 'owner_insurance_proof', 'safety_certificate', 'appraisal', 'registry_form', 'owner_invoice',
                 'owner_statement', 'receipt', 'notice')$$);
select app._policy('documents', 'investor_read', 'select',
  $$app.is_my_investor(investor_id) and kind in ('investment_agreement', 'investment_schedule_a', 'investment_schedule_c',
                                                  'investment_schedule_d', 'investor_statement', 'securities_form', 'notice')$$);
select app._policy('documents', 'va_read', 'select',
  $$app.va_has('cs', 'finance', 'fleet')
    and investor_id is null
    and kind not in ('investment_agreement', 'investment_schedule_a', 'investment_schedule_c', 'investment_schedule_d',
                     'investor_statement', 'securities_form', 'staff_agreement')
    and (kind not in ('id_front', 'id_back', 'face_photo') or app.va_has('cs'))
    and (renter_id is null or app.va_sees_renter(renter_id))$$);
select app._policy('documents', 'va_insert', 'insert', null,
  $$app.va_has('cs', 'finance', 'fleet') and uploaded_by = app.uid() and investor_id is null
    and kind not in ('investment_agreement', 'investment_schedule_a', 'investment_schedule_c', 'investment_schedule_d',
                     'investor_statement', 'securities_form', 'staff_agreement')$$);
select app._policy('documents', 'field_read', 'select',
  $$uploaded_by = app.uid() and app.is_field() and kind = 'condition_report' and app.field_has_job(booking_id, vehicle_id)$$);
select app._policy('documents', 'field_insert', 'insert', null,
  $$uploaded_by = app.uid() and app.is_field() and kind in ('condition_report', 'id_front', 'id_back')
    and app.field_has_job(booking_id, vehicle_id)$$);
-- a signature request is visible to whoever may see its document; a signer sees their own record
select app._policy('signature_requests', 'via_document_read', 'select', 'exists (select 1 from documents d where d.id = document_id)');
select app._policy('signature_requests', 'va_insert', 'insert', null,     -- send only; an Admin countersigns
  $$app.va_has('cs', 'fleet', 'finance') and created_by = app.uid() and exists (select 1 from documents d where d.id = document_id)$$);
select app._policy('signature_records', 'via_request_read', 'select',
  'signer_user_id = app.uid() or exists (select 1 from signature_requests s where s.id = signature_request_id)');

-- audit_log, job_runs, data_access_log, payment and bank secrets: admin only (no further policy).

drop function app._policy(text, text, text, text, text);

-- ---------------------------------------------------------------- privileges
-- Tables: signed-in users may read, insert and update what the policies allow. Nobody deletes
-- from a browser session, and the anonymous role reads one view.
revoke all on all tables in schema public from anon, authenticated;
grant select, insert, update on all tables in schema public to authenticated;
revoke insert, update on renter_bookings, owner_bookings, owner_claims, field_job_details, staff_directory, public_vehicle_listings from authenticated;
grant select on public_vehicle_listings to anon;
grant usage on all sequences in schema public to authenticated;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;

-- Tables added by later migrations start closed too (Supabase grants everything to these roles by default).
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke delete, truncate, references, trigger on tables from authenticated;

-- Append-only and system tables: no direct writes from a browser session at all.
revoke insert, update on audit_log, status_history, status_transitions, job_runs, data_access_log,
  payment_method_secrets, payment_processor_details, owner_payment_method_secrets from authenticated;

-- Functions in the app schema: closed by default. Signed-in users may call only the predicates
-- the policies use and the two logged lookups. Everything that moves money, builds a statement
-- or settles a claim is for the server alone.
grant usage on schema app to authenticated, anon, service_role;
revoke execute on all functions in schema app from public;
grant execute on all functions in schema app to service_role;
grant execute on function
  app.uid(), app.tz(), app.today(), app.local_date(timestamptz), app.month_start(date), app.days_in_month(date),
  app.local_midnight(date), app.is_business_day(date), app.add_business_days(date, integer),
  app.settings(date), app.has_role(app_role), app.is_admin(), app.va_has(text[]), app.is_va(), app.is_field(),
  app.is_staff(), app.is_my_owner(uuid), app.owns_vehicle(uuid), app.my_renter_id(), app.is_my_booking(uuid),
  app.is_my_investor(uuid), app.field_has_job(uuid, uuid), app.va_sees_renter(uuid),
  app.staff_find_renter(text), app.staff_open_renter(uuid, text),
  app.owner_controls_blocked(uuid, timestamptz), app.vehicle_bookable(uuid), app.vehicle_terms(uuid, date),
  app.billing_date(date), app.retry_date(date), app.payout_date(date), app.fleet_count(date, boolean)
  to authenticated;
grant execute on function app.uid(), app.is_admin(), app.has_role(app_role), app.my_renter_id(), app.is_field(), app.is_staff(), app.va_has(text[]) to anon;
alter default privileges in schema app revoke execute on functions from public;
