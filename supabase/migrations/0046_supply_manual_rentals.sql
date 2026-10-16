-- 0046_supply_manual_rentals.sql
-- Vehicle supply types, partner rental companies, rentals added by hand, retiring and deleting cars, toll matching
-- around insurer placeholder bookings (docs/changes/2026-10-16-supply-manual-rentals.md).
--
--   1. supply types: every vehicle is a program owner's car (as before), a CarmaCars-owned car (the company fleet) or a
--      partner rental company's car (brokered). The vehicle's owners row stays the ledger party: a company car belongs
--      to the one owners row of kind 'company' (never an owner with a portal, invoices, statements or payouts), a partner
--      car to the partner's own owners row of kind 'partner' (its payout account, statements, payouts and optional
--      portal are an owner's, without fees or invoices). The split reads the Revenue Share through app.vehicle_terms(),
--      which now answers 100% for a company car and the partner's commission for a partner car.
--   2. partners: the partner record (business, contacts, commission, its own insurance), the partner agreement signed
--      in the portal or recorded as signed on paper, Admin > Partners.
--   3. rentals added by hand (Admin, and customer service or Sales within their limits): car, dates, renter (found or
--      created), drivers, price, extras, Deposit, coverage, source and how it is paid; confirmed at once (awaiting
--      payment for a payment link) or recorded as a completed past rental; the agreement signed in the renter's portal
--      or on paper; the renter's email (unless "do not email"); the owner's or partner's notice; audited.
--   4. retiring (soft, restorable) and deleting (only a car with nothing tied to money) cars; delete every sample car.
--   5. toll matching: a placeholder booking (a booking that does not block the calendar and was never handed over, for
--      example the insurer bookings) is never a candidate; two or more real rentals at the time of a notice are never
--      charged automatically and go to the exceptions with every candidate.
-- No earlier migration is edited. Functions that change are wrapped (renamed _0045 or with their migration number) or
-- replaced with the same signature, as 0029 to 0045 did.

-- ================================================================ 1. types, settings
alter type document_kind add value if not exists 'partner_agreement';
alter type document_kind add value if not exists 'partner_insurance';

alter table program_settings
  add column partner_commission_bps integer not null default 2000 check (partner_commission_bps between 0 and 10000),
  add column manual_rental_va_payment_modes text[] not null default array['other_way', 'link', 'card'],
  add column manual_rental_va_promo boolean not null default true,
  add column manual_rental_past_max_days integer not null default 400 check (manual_rental_past_max_days between 1 and 3650),
  add column partner_insurance_warn_days integer not null default 30 check (partner_insurance_warn_days between 0 and 365);
comment on column program_settings.partner_commission_bps is 'What CarmaCars keeps of a partner car''s rental revenue unless the partner or the car has its own (0046)';
comment on column program_settings.manual_rental_va_payment_modes is 'How customer service and Sales may take payment on a rental they add by hand: other_way, link, card, unpaid (0046). Admins: every way';
comment on column program_settings.manual_rental_va_promo is 'Customer service and Sales may apply a promo code to a rental they add by hand (0046); they never type a price';
comment on column program_settings.manual_rental_past_max_days is 'How far back a past rental may be recorded, in days (0046)';
comment on column program_settings.partner_insurance_warn_days is 'Days before a partner''s insurance expires that Admin > Partners and the daily check warn (0046)';

-- ================================================================ 2. owners rows by kind, partners, supply type
alter table owners add column kind text not null default 'program' check (kind in ('program', 'partner', 'company'));
comment on column owners.kind is 'program: an owner in the owner program. partner: the ledger row of a partner rental company (0046). company: the one row CarmaCars-owned cars belong to (0046)';
create unique index owners_one_company on owners (kind) where kind = 'company';

create table partners (
  id                 uuid primary key default gen_random_uuid(),
  owner_id           uuid not null unique references owners (id),
  partner_number     text not null unique,
  business_name      text not null check (length(btrim(business_name)) between 2 and 200),
  legal_name         text,
  contact_name       text,
  contact_title      text,
  email              text,
  phone              text,
  contacts           jsonb not null default '[]'::jsonb check (jsonb_typeof(contacts) = 'array'),
  address_line1      text,
  city               text,
  province           text default 'ON',
  postal_code        text,
  hst_number         text,
  commission_bps     integer check (commission_bps between 0 and 10000),
  insurance_company  text,
  insurance_policy   text,
  insurance_expiry   date,
  insurance_document_id uuid references documents (id),
  agreement_status   text not null default 'not_sent' check (agreement_status in ('not_sent', 'sent', 'signed')),
  agreement_signed_at timestamptz,
  agreement_method   text check (agreement_method in ('typed', 'drawn', 'paper')),
  agreement_document_id uuid references documents (id),
  status             text not null default 'active' check (status in ('active', 'paused', 'ended')),
  notes              text,
  created_by         uuid references users (id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create sequence partner_number_seq start 101;
alter table partners alter column partner_number set default ('PR-' || nextval('partner_number_seq'));
create trigger partners_updated before update on partners for each row execute function app.set_updated_at();
comment on table partners is 'A partner rental company whose cars CarmaCars rents out on commission (0046). Its owners row (kind partner) carries the payout account, statements, payouts and the optional portal sign-in.';

alter table vehicles
  add column supply_type text not null default 'program_owner' check (supply_type in ('program_owner', 'company', 'partner')),
  add column partner_id uuid references partners (id),
  add column commission_bps integer check (commission_bps between 0 and 10000),
  add column retired_at timestamptz,
  add column retired_by uuid references users (id),
  add column retired_reason text,
  add column added_by uuid references users (id),
  add constraint vehicles_partner_supply check ((supply_type = 'partner') = (partner_id is not null)),
  add constraint vehicles_commission_partner check (commission_bps is null or supply_type = 'partner');
create index vehicles_partner_idx on vehicles (partner_id) where partner_id is not null;
comment on column vehicles.supply_type is 'program_owner: an owner in the program (fees, owner statements). company: owned by CarmaCars, 100% of revenue to CarmaCars. partner: a partner rental company''s car, brokered on commission (0046)';
comment on column vehicles.retired_at is 'Retired (0046): unlisted, not bookable, off the calendars from then on; history kept; restorable';

-- The one owners row a CarmaCars-owned car belongs to (created the first time it is needed).
create or replace function app.company_owner_id() returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v uuid;
begin
  select id into v from owners where kind = 'company';
  if v is null then
    insert into owners (owner_type, legal_name, corporation_name, status, kind, email)
    values ('corporation', coalesce(nullif((app.settings()).company_trade_name, ''), 'CarmaCars') || ' company fleet',
            nullif((app.settings()).company_legal_name, ''), 'active', 'company', nullif((app.settings()).company_email, ''))
    on conflict do nothing;
    select id into v from owners where kind = 'company';
  end if;
  return v;
end $$;

-- A car's supply type decides its owners row: the company row for a company car, the partner's row for a partner car.
create or replace function app.vehicles_supply_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  k text;
begin
  if new.supply_type = 'company' then
    new.owner_id := app.company_owner_id();
    new.partner_id := null; new.commission_bps := null;
  elsif new.supply_type = 'partner' then
    select p.owner_id into new.owner_id from partners p where p.id = new.partner_id;
    if new.owner_id is null then raise exception 'Choose the partner rental company' using errcode = '22023'; end if;
  else
    select o.kind into k from owners o where o.id = new.owner_id;
    if k is distinct from 'program' then
      raise exception 'A program owner''s car belongs to an owner in the owner program' using errcode = '23514';
    end if;
  end if;
  if new.supply_type <> 'program_owner' and new.is_shareholder_owned then
    raise exception 'Only a program owner''s car is shareholder-owned' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger vehicles_a1_supply before insert or update of supply_type, partner_id, owner_id, commission_bps, is_shareholder_owned on vehicles
  for each row execute function app.vehicles_supply_before();

-- What CarmaCars keeps of a partner car's rental revenue on a day: the car's own, the partner's, or the setting.
create or replace function app.partner_commission_bps(p_vehicle uuid, p_on date default app.today()) returns integer
language sql stable security definer set search_path = public, app as $$
  select coalesce(v.commission_bps, p.commission_bps, (app.settings(p_on)).partner_commission_bps)
    from vehicles v left join partners p on p.id = v.partner_id where v.id = p_vehicle
$$;

-- 0002's terms on a day, now by supply type: a company car has no fees and a 100% Revenue Share; a partner car has no
-- fees and the commission as its Revenue Share (the split then pays the partner the rest, as it pays an owner). A
-- program owner's car is read from vehicle_fee_history as before. The synthetic row has no id.
create or replace function app.vehicle_terms(p_vehicle uuid, p_on date)
returns vehicle_fee_history language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  r vehicle_fee_history;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.supply_type in ('company', 'partner') then
    r.vehicle_id := p_vehicle;
    r.source := 'correction';
    r.insurance_fee_cents := 0;
    r.tracker_fee_cents := 0;
    r.revenue_share_bps := case when v.supply_type = 'company' then 10000 else app.partner_commission_bps(p_vehicle, p_on) end;
    r.effective_from := coalesce(v.enrollment_date, app.local_date(v.created_at));
    r.created_at := v.created_at;
    return r;
  end if;
  select * into r from vehicle_fee_history
   where vehicle_id = p_vehicle and effective_from <= p_on and (effective_to is null or effective_to > p_on)
   limit 1;
  return r;
end $$;

create or replace function app.supply_label(p_type text) returns text
language sql immutable as $$
  select case p_type when 'company' then 'CarmaCars-owned' when 'partner' then 'Partner rental company' else 'Program owner' end
$$;

-- No owner fee invoice for a company or partner car (they pay no fees).
alter function app.generate_owner_invoice(uuid, date, uuid) rename to generate_owner_invoice_0029;
create or replace function app.generate_owner_invoice(p_vehicle uuid, p_month date, p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
begin
  if (select supply_type from vehicles where id = p_vehicle) <> 'program_owner' then return null; end if;
  return app.generate_owner_invoice_0029(p_vehicle, p_month, p_by);
end $$;
alter function app.issue_upfront_invoice(uuid, uuid) rename to issue_upfront_invoice_0029;
create or replace function app.issue_upfront_invoice(p_vehicle uuid, p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
begin
  if (select supply_type from vehicles where id = p_vehicle) <> 'program_owner' then
    raise exception 'A % car has no upfront invoice', lower(app.supply_label((select supply_type from vehicles where id = p_vehicle))) using errcode = '23514';
  end if;
  return app.issue_upfront_invoice_0029(p_vehicle, p_by);
end $$;

-- No owner statement for the company row: its cars' revenue is CarmaCars' own (the company statement has it).
alter function app.build_owner_statement(uuid, date, uuid) rename to build_owner_statement_0025;
create or replace function app.build_owner_statement(p_owner uuid, p_month date, p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
begin
  if (select kind from owners where id = p_owner) = 'company' then return null; end if;
  return app.build_owner_statement_0025(p_owner, p_month, p_by);
end $$;

-- A retired car is not open for new bookings (0011's rule otherwise).
create or replace function app.vehicle_bookable(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select v.bookings_enabled
     and v.retired_at is null
     and v.management_mode <> 'turo_only'
     and v.status in ('available', 'on_rent', 'cleaning', 'out_of_service', 'exit_notice')
     and not (v.management_mode = 'self_managed' and v.in_arrears)
    from vehicles v where v.id = p_vehicle
$$;

-- 0020's master calendar without retired cars from their retirement on.
create or replace function app.master_calendar(p_from timestamptz, p_to timestamptz)
returns table (vehicle_id uuid, vehicle_label text, plate text, fleet_number text, vehicle_status text,
               entry_type text, entry_id uuid, booking_id uuid, booking_number text, booking_type text, status text,
               calendar_state text, starts_at timestamptz, ends_at timestamptz, blocks_calendar boolean, is_blocking boolean,
               bill_to text, dates_provisional boolean, insurer_name text, renter_name text, block_reason text, note text,
               related_booking_id uuid, assigned_to uuid, assignee_name text, detail text)
language sql stable security definer set search_path = public, app as $$
  select v.id, v.year || ' ' || v.make || ' ' || v.model, v.plate, v.fleet_number, v.status::text,
         e.entry_type, e.entry_id, e.booking_id, e.booking_number, e.booking_type, e.status,
         e.calendar_state, e.starts_at, e.ends_at, e.blocks_calendar, e.is_blocking,
         e.bill_to, e.dates_provisional, e.insurer_name, e.renter_name, e.block_reason, e.note,
         e.related_booking_id, e.assigned_to, e.assignee_name, e.detail
    from vehicles v
    left join calendar_entries e
      on e.vehicle_id = v.id and e.starts_at < p_to and (e.ends_at is null or e.ends_at > p_from)
   where (app.is_staff() or app.owns_vehicle(v.id))
     and v.status::text not in ('declined', 'exited')
     and (v.retired_at is null or v.retired_at > p_from)
   order by v.fleet_number nulls last, v.id, e.starts_at, e.entry_id
$$;

-- ================================================================ 3. bookings: sources, the manual flag, placeholders
alter table bookings drop constraint if exists bookings_source_check;
alter table bookings add constraint bookings_source_check
  check (source in ('web', 'phone', 'email', 'whatsapp', 'owner', 'staff', 'walk_in', 'turo', 'partner', 'insurer', 'other'));
alter table bookings
  add column added_by_staff boolean not null default false,
  add column added_mode text check (added_mode in ('future', 'past')),
  add column payment_mode text check (payment_mode in ('other_way', 'link', 'card', 'unpaid')),
  add column do_not_email boolean not null default false,
  add column clash_override_reason text;
comment on column bookings.added_by_staff is 'Added by hand in Admin > Bookings > Add a rental or its VA equivalent (0046)';
comment on column bookings.payment_mode is 'How a rental added by hand is paid: paid another way, a payment link, the saved card, or unpaid to invoice later (0046)';

alter table booking_events drop constraint if exists booking_events_kind_check;
alter table booking_events add constraint booking_events_kind_check check (kind = any (array[
  'adjusted', 'agreement_completed', 'agreement_opened', 'agreement_signed', 'agreement_voided', 'booking_change',
  'calendar_switch', 'cancelled', 'change_requested', 'confirmed', 'declined', 'deposit_waived', 'extension',
  'info_replied', 'info_requested', 'offer_approved', 'offer_expired', 'offer_sent', 'offer_withdrawn', 'payment_refused',
  'promo_applied', 'promo_removed', 'pushed_back', 'requested', 'verification', 'reopened', 'review_request',
  'added_by_staff']));

alter table booking_drivers drop constraint if exists booking_drivers_identity_method_check;
alter table booking_drivers add constraint booking_drivers_identity_method_check
  check (identity_method in ('identity_check_service', 'staff_review', 'in_person'));

-- A placeholder booking: one that exists without blocking the car and was never handed over (an insurer's booking whose
-- dates are not right yet, or a booking the business keeps for its insurance). It may overlap real rentals; it is never
-- the renter of a toll or ticket.
create or replace function app.booking_is_placeholder(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select not b.blocks_calendar and b.handed_over_at is null and b.status not in ('on_rent', 'returned', 'closed')
    from bookings b where b.id = p_booking
$$;

-- ================================================================ 4. partners: record, list, detail
-- Create or change a partner. p: {id?, business_name, legal_name, contact_name, contact_title, email, phone, contacts[],
-- address_line1, city, province, postal_code, hst_number, commission_bps (empty: the setting), insurance_company,
-- insurance_policy, insurance_expiry, status, notes}. A new partner gets its owners row (kind partner) for the payout
-- account, statements, payouts and the optional portal.
create or replace function app.partner_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r partners;
  v_owner uuid;
  v_name text := nullif(btrim(coalesce(p ->> 'business_name', '')), '');
  v_email text := lower(nullif(btrim(coalesce(p ->> 'email', '')), ''));
  v_comm integer := nullif(p ->> 'commission_bps', '')::integer;
begin
  perform app.assert_admin(p_by);
  if nullif(p ->> 'id', '') is not null then
    select * into r from partners where id = (p ->> 'id')::uuid for update;
    if r.id is null then raise exception 'Partner not found' using errcode = 'P0002'; end if;
  end if;
  v_name := coalesce(v_name, r.business_name);
  if v_name is null or length(v_name) < 2 then raise exception 'Enter the partner''s business name' using errcode = '22023'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address' using errcode = '22023'; end if;
  if v_comm is not null and (v_comm < 0 or v_comm > 10000) then raise exception 'The commission is between 0%% and 100%%' using errcode = '22023'; end if;
  if coalesce(p ->> 'status', 'active') not in ('active', 'paused', 'ended') then raise exception 'Unknown status' using errcode = '22023'; end if;
  if jsonb_typeof(coalesce(p -> 'contacts', '[]'::jsonb)) <> 'array' then raise exception 'The contacts are not readable' using errcode = '22023'; end if;
  if r.id is null then
    if exists (select 1 from partners x where lower(x.business_name) = lower(v_name)) then
      raise exception 'A partner named % is already on file', v_name using errcode = '23505';
    end if;
    insert into owners (owner_type, legal_name, corporation_name, email, phone, address_line1, city, province, postal_code, hst_number, status, kind)
    values ('corporation', coalesce(nullif(btrim(p ->> 'legal_name'), ''), v_name), coalesce(nullif(btrim(p ->> 'legal_name'), ''), v_name),
            v_email, nullif(btrim(p ->> 'phone'), ''), nullif(btrim(p ->> 'address_line1'), ''), nullif(btrim(p ->> 'city'), ''),
            coalesce(nullif(btrim(p ->> 'province'), ''), 'ON'), upper(nullif(btrim(p ->> 'postal_code'), '')), nullif(btrim(p ->> 'hst_number'), ''),
            'active', 'partner')
    returning id into v_owner;
    insert into partners (owner_id, business_name, legal_name, contact_name, contact_title, email, phone, contacts, address_line1, city, province,
                          postal_code, hst_number, commission_bps, insurance_company, insurance_policy, insurance_expiry, status, notes, created_by)
    values (v_owner, v_name, nullif(btrim(p ->> 'legal_name'), ''), nullif(btrim(p ->> 'contact_name'), ''), nullif(btrim(p ->> 'contact_title'), ''),
            v_email, nullif(btrim(p ->> 'phone'), ''), coalesce(p -> 'contacts', '[]'::jsonb), nullif(btrim(p ->> 'address_line1'), ''),
            nullif(btrim(p ->> 'city'), ''), coalesce(nullif(btrim(p ->> 'province'), ''), 'ON'), upper(nullif(btrim(p ->> 'postal_code'), '')),
            nullif(btrim(p ->> 'hst_number'), ''), v_comm, nullif(btrim(p ->> 'insurance_company'), ''), nullif(btrim(p ->> 'insurance_policy'), ''),
            nullif(p ->> 'insurance_expiry', '')::date, coalesce(p ->> 'status', 'active'), nullif(btrim(p ->> 'notes'), ''), p_by)
    returning * into r;
  else
    update partners set business_name = v_name,
           legal_name = case when p ? 'legal_name' then nullif(btrim(p ->> 'legal_name'), '') else legal_name end,
           contact_name = case when p ? 'contact_name' then nullif(btrim(p ->> 'contact_name'), '') else contact_name end,
           contact_title = case when p ? 'contact_title' then nullif(btrim(p ->> 'contact_title'), '') else contact_title end,
           email = case when p ? 'email' then v_email else email end,
           phone = case when p ? 'phone' then nullif(btrim(p ->> 'phone'), '') else phone end,
           contacts = case when p ? 'contacts' then coalesce(p -> 'contacts', '[]'::jsonb) else contacts end,
           address_line1 = case when p ? 'address_line1' then nullif(btrim(p ->> 'address_line1'), '') else address_line1 end,
           city = case when p ? 'city' then nullif(btrim(p ->> 'city'), '') else city end,
           province = case when p ? 'province' then coalesce(nullif(btrim(p ->> 'province'), ''), 'ON') else province end,
           postal_code = case when p ? 'postal_code' then upper(nullif(btrim(p ->> 'postal_code'), '')) else postal_code end,
           hst_number = case when p ? 'hst_number' then nullif(btrim(p ->> 'hst_number'), '') else hst_number end,
           commission_bps = case when p ? 'commission_bps' then v_comm else commission_bps end,
           insurance_company = case when p ? 'insurance_company' then nullif(btrim(p ->> 'insurance_company'), '') else insurance_company end,
           insurance_policy = case when p ? 'insurance_policy' then nullif(btrim(p ->> 'insurance_policy'), '') else insurance_policy end,
           insurance_expiry = case when p ? 'insurance_expiry' then nullif(p ->> 'insurance_expiry', '')::date else insurance_expiry end,
           status = coalesce(nullif(p ->> 'status', ''), status),
           notes = case when p ? 'notes' then nullif(btrim(p ->> 'notes'), '') else notes end
     where id = r.id returning * into r;
    update owners set legal_name = coalesce(r.legal_name, r.business_name), corporation_name = coalesce(r.legal_name, r.business_name),
           email = r.email, phone = r.phone, address_line1 = r.address_line1, city = r.city, province = r.province, postal_code = r.postal_code,
           hst_number = r.hst_number, status = case when r.status = 'ended' then 'exited' else 'active' end
     where id = r.owner_id;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, case when nullif(p ->> 'id', '') is null then 'partner_create' else 'partner_update' end, 'partners', r.id::text,
          jsonb_build_object('business_name', r.business_name, 'commission_bps', r.commission_bps, 'status', r.status));
  return to_jsonb(r);
end $$;

create or replace function app.partner_row(r partners) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select to_jsonb(r) || jsonb_build_object(
    'commission_effective_bps', coalesce(r.commission_bps, (app.settings()).partner_commission_bps),
    'commission_is_default', r.commission_bps is null,
    'insurance_warning', case when r.insurance_expiry is null then 'No insurance expiry on file'
                              when r.insurance_expiry < app.today() then 'Insurance expired ' || app.fmt_day(r.insurance_expiry)
                              when r.insurance_expiry <= app.today() + (app.settings()).partner_insurance_warn_days then 'Insurance expires ' || app.fmt_day(r.insurance_expiry) end,
    'vehicles', (select count(*) from vehicles v where v.partner_id = r.id and v.retired_at is null),
    'has_portal', (select o.user_id is not null from owners o where o.id = r.owner_id),
    'portal_user_id', (select o.user_id from owners o where o.id = r.owner_id))
$$;

create or replace function app.partners_list(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return coalesce((select jsonb_agg(app.partner_row(r) order by r.status, r.business_name) from partners r), '[]'::jsonb);
end $$;

create or replace function app.partner_detail(p_by uuid, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r partners;
begin
  perform app.assert_admin(p_by);
  select * into r from partners where id = p_id;
  if r.id is null then return null; end if;
  return app.partner_row(r) || jsonb_build_object(
    'cars', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'status', v.status,
                        'retired_at', v.retired_at, 'commission_bps', v.commission_bps, 'commission_effective_bps', app.partner_commission_bps(v.id),
                        'listing_status', (select l.status from vehicle_listings l where l.vehicle_id = v.id)) order by v.make, v.model)
                      from vehicles v where v.partner_id = r.id), '[]'::jsonb),
    'bookings', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at,
                            'return_at', b.return_at, 'vehicle', app.vehicle_name(b.vehicle_id), 'total_cents', b.total_due_at_booking_cents) order by b.pickup_at desc)
                          from (select * from bookings b where b.owner_id = r.owner_id and b.status not in ('requested', 'declined', 'expired') order by b.pickup_at desc limit 50) b), '[]'::jsonb),
    'statements', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'statement_number', s.statement_number, 'statement_month', s.statement_month,
                              'status', s.status, 'payout_cents', s.payout_cents) order by s.statement_month desc)
                            from owner_statements s where s.owner_id = r.owner_id), '[]'::jsonb),
    'payouts', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from payouts x where x.owner_id = r.owner_id), '[]'::jsonb),
    'payout_accounts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'method', a.method, 'account_holder', a.account_holder,
                                   'institution_no', a.institution_no, 'transit_no', a.transit_no, 'account_last4', a.account_last4,
                                   'e_transfer_email', a.e_transfer_email, 'is_current', a.is_current, 'verified_at', a.verified_at, 'created_at', a.created_at)
                                   order by a.created_at desc) from owner_payout_accounts a where a.owner_id = r.owner_id), '[]'::jsonb),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'created_at', d.created_at) order by d.created_at desc)
                             from documents d where d.owner_id = r.owner_id and d.purged_at is null), '[]'::jsonb),
    'agreement', (select jsonb_build_object('id', s.id, 'status', s.status, 'method', s.method, 'signed_at', s.signed_at, 'document_id', s.document_id,
                                            'signed_document_id', s.signed_document_id)
                    from sign_requests s where s.owner_id = r.owner_id and s.doc_type = 'partner_agreement' order by s.sent_at desc limit 1),
    'paper', (select jsonb_build_object('id', ps.id, 'signed_on', ps.signed_on, 'signer_name', ps.signer_name, 'document_id', ps.document_id)
                from paper_signatures ps where ps.doc_type = 'partner_agreement' and ps.owner_id = r.owner_id and ps.voided_at is null
               order by ps.recorded_at desc limit 1));
end $$;

-- The partner portal is the owner portal with this flag: what kind of account is signed in, and for a partner its
-- agreement and commission.
create or replace function app.owner_kind_facts(p_owner uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('kind', o.kind,
    'partner', (select jsonb_build_object('id', r.id, 'business_name', r.business_name, 'partner_number', r.partner_number,
                  'commission_effective_bps', coalesce(r.commission_bps, (app.settings()).partner_commission_bps),
                  'agreement_status', r.agreement_status, 'agreement_signed_at', r.agreement_signed_at, 'agreement_method', r.agreement_method,
                  'agreement_document_id', r.agreement_document_id, 'insurance_expiry', r.insurance_expiry)
                  from partners r where r.owner_id = o.id))
    from owners o where o.id = p_owner
$$;
alter function app.owner_portal_home(uuid) rename to owner_portal_home_0037;
create or replace function app.owner_portal_home(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  return app.owner_portal_home_0037(p_by) || coalesce(app.owner_kind_facts(app.portal_owner_id(p_by)), '{}'::jsonb);
end $$;

-- ================================================================ 5. Admin > Vehicles > Add a car
-- p: {supply_type: program_owner | company | partner, owner_id (program owner), partner_id (partner), commission_bps (partner,
-- empty: the partner's), vin, plate, year, make, model, trim, colour, fuel, odometer_km, class, body_type, home_location,
-- allows_18_to_20, rates: {daily, weekend, weekly, monthly, km_per_day, overage, deposit} (cents; optional),
-- and for a program owner the onboarding facts of 0022's app.add_owner_vehicle (title_status, held_by, ...)}.
-- A company or partner car is in the fleet at once (no owner onboarding): it can take a rental added by hand, and its
-- listing is published through the listing pipeline as usual. A program owner's car starts its onboarding.
create or replace function app.vehicle_add(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_type text := coalesce(nullif(p ->> 'supply_type', ''), 'program_owner');
  v_vin text := app.clean_vin(p ->> 'vin');
  v_plate text := nullif(upper(regexp_replace(coalesce(p ->> 'plate', ''), '\s', '', 'g')), '');
  x vehicles;
  pr partners;
  d vin_decodes;
  v_id uuid := gen_random_uuid();
  v_res jsonb;
  r jsonb := coalesce(p -> 'rates', '{}'::jsonb);
  v_year smallint; v_make text; v_model text;
begin
  perform app.assert_admin(p_by);
  if v_type not in ('program_owner', 'company', 'partner') then raise exception 'Choose who supplies the car' using errcode = '22023'; end if;
  if v_vin is null then raise exception 'Enter the 17-character VIN' using errcode = '22023'; end if;
  -- the duplicate check, the same for the three kinds: one VIN once in the fleet; a plate on another active car is named
  select * into x from vehicles where upper(vin) = v_vin;
  if x.id is not null then
    raise exception 'This VIN is already in the fleet: % (%)%', app.vehicle_name(x.id), lower(app.supply_label(x.supply_type)),
      case when x.retired_at is not null then '. It is retired: restore it instead of adding it again' else '' end using errcode = '23505';
  end if;
  if v_plate is not null then
    select * into x from vehicles where app.norm_plate(plate) = app.norm_plate(v_plate) and retired_at is null
       and status not in ('exited', 'total_loss', 'declined') limit 1;
    if x.id is not null then
      raise exception 'Plate % is on another car in the fleet: % (%)', v_plate, app.vehicle_name(x.id), lower(app.supply_label(x.supply_type)) using errcode = '23505';
    end if;
  end if;

  if v_type = 'program_owner' then
    if nullif(p ->> 'owner_id', '') is null or (select kind from owners where id = (p ->> 'owner_id')::uuid) is distinct from 'program' then
      raise exception 'Choose the owner (an owner in the owner program)' using errcode = '22023';
    end if;
    v_res := app.add_owner_vehicle((p ->> 'owner_id')::uuid, p - 'supply_type' - 'owner_id' - 'rates', p_by, null);
    update vehicles set added_by = p_by where id = (v_res ->> 'vehicle_id')::uuid;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'vehicle_add', 'vehicles', v_res ->> 'vehicle_id', jsonb_build_object('supply_type', v_type, 'owner_id', p ->> 'owner_id', 'vin', v_vin));
    return v_res || jsonb_build_object('supply_type', v_type);
  end if;

  if v_type = 'partner' then
    select * into pr from partners where id = nullif(p ->> 'partner_id', '')::uuid;
    if pr.id is null then raise exception 'Choose the partner rental company' using errcode = '22023'; end if;
    if pr.status = 'ended' then raise exception 'The partnership with % has ended', pr.business_name using errcode = '23514'; end if;
  end if;
  select * into d from vin_decodes z where z.vin = v_vin and z.ok order by z.decoded_at desc limit 1;
  v_year := coalesce(nullif(p ->> 'year', '')::smallint, d.year);
  v_make := coalesce(nullif(btrim(p ->> 'make'), ''), d.make);
  v_model := coalesce(nullif(btrim(p ->> 'model'), ''), d.model);
  if v_year is null or v_make is null or v_model is null then
    raise exception 'Enter the year, make and model' using errcode = '22023';
  end if;
  insert into vehicles (id, owner_id, supply_type, partner_id, commission_bps, year, make, model, trim, colour, fuel, vin, plate, odometer_km, class,
                        status, management_mode, enrollment_date, home_location, body_type, allows_18_to_20, title_brand_clear, added_by)
  values (v_id, case when v_type = 'company' then app.company_owner_id() else pr.owner_id end, v_type, pr.id,
          case when v_type = 'partner' then nullif(p ->> 'commission_bps', '')::integer end,
          v_year, v_make, v_model, coalesce(nullif(btrim(p ->> 'trim'), ''), d.trim), nullif(btrim(p ->> 'colour'), ''),
          coalesce(nullif(p ->> 'fuel', '')::fuel_type, d.fuel, 'gasoline'), v_vin, v_plate, nullif(p ->> 'odometer_km', '')::integer,
          coalesce(nullif(p ->> 'class', '')::vehicle_class, 'standard'), 'available', 'managed', app.today(),
          nullif(btrim(p ->> 'home_location'), ''), coalesce(nullif(btrim(p ->> 'body_type'), ''), d.body_class),
          coalesce((p ->> 'allows_18_to_20')::boolean, false), true, p_by);
  if nullif(r ->> 'daily', '') is not null then
    insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day,
                            overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from, set_by)
    values (v_id, (r ->> 'daily')::bigint, coalesce(nullif(r ->> 'weekend', '')::bigint, (r ->> 'daily')::bigint),
            coalesce(nullif(r ->> 'weekly', '')::bigint, (r ->> 'daily')::bigint * 6), coalesce(nullif(r ->> 'monthly', '')::bigint, (r ->> 'daily')::bigint * 22),
            coalesce(nullif(r ->> 'km_per_day', '')::integer, 200), coalesce(nullif(r ->> 'overage', '')::bigint, 25),
            coalesce(nullif(r ->> 'deposit', '')::bigint, 50000), coalesce(nullif(r ->> 'delivery', '')::bigint, 0),
            coalesce(nullif(r ->> 'delivery', '')::bigint, 0), now(), p_by);
  end if;
  perform app.ensure_listing(v_id);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'vehicle_add', 'vehicles', v_id::text, jsonb_build_object('supply_type', v_type, 'partner_id', pr.id, 'vin', v_vin, 'plate', v_plate));
  return jsonb_build_object('vehicle_id', v_id, 'supply_type', v_type, 'name', app.vehicle_name(v_id),
                            'similar', (select count(*) from listing_similarity_flags f where f.vehicle_id = v_id and f.status = 'open'));
end $$;

-- Change a car's supply type (an Admin's correction, for example a car first added as a program owner's). Not on a car
-- with a booking that is not over, or with owner invoices or statements.
create or replace function app.vehicle_set_supply(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_type text := p ->> 'supply_type';
begin
  perform app.assert_admin(p_by);
  select * into v from vehicles where id = (p ->> 'vehicle_id')::uuid for update;
  if v.id is null then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
  if v_type not in ('program_owner', 'company', 'partner') then raise exception 'Choose who supplies the car' using errcode = '22023'; end if;
  if v_type = v.supply_type and v_type <> 'partner' then
    return jsonb_build_object('vehicle_id', v.id, 'supply_type', v.supply_type);
  end if;
  if exists (select 1 from bookings b where b.vehicle_id = v.id and b.status in ('requested', 'offered', 'pending_payment', 'confirmed', 'on_rent', 'returned')) then
    raise exception 'Finish or cancel this car''s open bookings first: the split of a booking follows who supplied the car when it was booked' using errcode = '23514';
  end if;
  if v.supply_type = 'program_owner' and (exists (select 1 from owner_invoices i where i.vehicle_id = v.id and i.status <> 'void')
                                          or exists (select 1 from vehicle_schedules s where s.vehicle_id = v.id and s.signed_at is not null)) then
    raise exception 'This car has a signed owner schedule or owner invoices: end it through the owner''s exit instead' using errcode = '23514';
  end if;
  if v_type = 'program_owner' and (nullif(p ->> 'owner_id', '') is null or (select kind from owners where id = (p ->> 'owner_id')::uuid) <> 'program') then
    raise exception 'Choose the owner (an owner in the owner program)' using errcode = '22023';
  end if;
  update vehicles set supply_type = v_type,
         partner_id = case when v_type = 'partner' then nullif(p ->> 'partner_id', '')::uuid end,
         commission_bps = case when v_type = 'partner' then nullif(p ->> 'commission_bps', '')::integer end,
         owner_id = case when v_type = 'program_owner' then (p ->> 'owner_id')::uuid else owner_id end,
         enrollment_date = case when v_type <> 'program_owner' then coalesce(enrollment_date, app.today()) else enrollment_date end
   where id = v.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'vehicle_set_supply', 'vehicles', v.id::text, jsonb_build_object('supply_type', v.supply_type, 'partner_id', v.partner_id, 'owner_id', v.owner_id),
          jsonb_build_object('supply_type', v_type, 'partner_id', p ->> 'partner_id', 'commission_bps', p ->> 'commission_bps'));
  return jsonb_build_object('vehicle_id', v.id, 'supply_type', v_type);
end $$;

-- A partner car's own commission (empty: the partner's).
create or replace function app.vehicle_set_commission(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_bps integer := nullif(p ->> 'commission_bps', '')::integer;
begin
  perform app.assert_admin(p_by);
  select * into v from vehicles where id = (p ->> 'vehicle_id')::uuid for update;
  if v.supply_type <> 'partner' then raise exception 'Only a partner car has a commission' using errcode = '23514'; end if;
  update vehicles set commission_bps = v_bps where id = v.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'vehicle_set_commission', 'vehicles', v.id::text, jsonb_build_object('commission_bps', v.commission_bps), jsonb_build_object('commission_bps', v_bps));
  return jsonb_build_object('vehicle_id', v.id, 'commission_effective_bps', app.partner_commission_bps(v.id));
end $$;

-- ================================================================ 6. retire, restore, delete
-- Retire (soft): any car with no confirmed or on-rent booking ahead (cancel or move them first). The listing is unlisted
-- (its address keeps what it earned), the car leaves the calendars from now on and takes no new booking; every booking,
-- statement and payment stays. Requests and offers still open on it go back to customer service.
create or replace function app.vehicle_retire(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_ahead text;
  r record;
  n integer := 0;
begin
  perform app.assert_admin(p_by);
  select * into v from vehicles where id = (p ->> 'vehicle_id')::uuid for update;
  if v.id is null then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
  if v.retired_at is not null then raise exception 'This car was retired on %', app.fmt_day(app.local_date(v.retired_at)) using errcode = '23514'; end if;
  if v_reason is null then raise exception 'Give the reason for retiring the car' using errcode = '22023'; end if;
  select string_agg(b.booking_number || ' (' || app.fmt_day(app.local_date(b.pickup_at)) || ')', ', ' order by b.pickup_at) into v_ahead
    from bookings b where b.vehicle_id = v.id and b.status in ('confirmed', 'on_rent') and b.return_at > now();
  if v_ahead is not null then
    raise exception 'Cancel or move these bookings to another car first: %', v_ahead using errcode = '23514';
  end if;
  if exists (select 1 from vehicle_listings l where l.vehicle_id = v.id and l.status in ('published', 'paused')) then
    perform app.unlist_listing(v.id, p_by, 'Car retired: ' || v_reason);
  end if;
  update listing_intakes set state = 'cancelled' where vehicle_id = v.id and state not in ('published', 'cancelled');
  update vehicles set retired_at = now(), retired_by = p_by, retired_reason = v_reason where id = v.id;
  -- requests and offers that were waiting on the car go back to customer service with a task
  for r in select b.id, b.booking_number from bookings b where b.vehicle_id = v.id and b.status in ('requested', 'offered', 'pending_payment') loop
    perform app.raise_task(p_type => 'reoffer_booking', p_title => format('Offer another car for %s: %s was retired', r.booking_number, app.vehicle_name(v.id)),
        p_booking => r.id, p_vehicle => v.id, p_queue => 'cs', p_created_by => p_by, p_dedupe => 'retired_car:' || r.id);
    n := n + 1;
  end loop;
  -- calendar blocks ahead end now
  update vehicle_calendar_blocks set ends_at = now() where vehicle_id = v.id and removed_at is null and (ends_at is null or ends_at > now()) and starts_at < now();
  update vehicle_calendar_blocks set removed_at = now(), removed_by = p_by, removed_reason = 'Car retired'
   where vehicle_id = v.id and removed_at is null and starts_at >= now();
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'vehicle_retire', 'vehicles', v.id::text, jsonb_build_object('status', v.status), jsonb_build_object('reason', v_reason, 'requests_back_to_staff', n));
  return jsonb_build_object('vehicle_id', v.id, 'retired', true, 'requests_back_to_staff', n);
end $$;

create or replace function app.vehicle_restore(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
begin
  perform app.assert_admin(p_by);
  select * into v from vehicles where id = (p ->> 'vehicle_id')::uuid for update;
  if v.id is null then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
  if v.retired_at is null then raise exception 'This car is not retired' using errcode = '23514'; end if;
  update vehicles set retired_at = null, retired_by = null, retired_reason = null where id = v.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'vehicle_restore', 'vehicles', v.id::text, jsonb_build_object('retired_at', v.retired_at, 'reason', v.retired_reason), jsonb_build_object('restored', true));
  return jsonb_build_object('vehicle_id', v.id, 'restored', true, 'note', 'Restored. Publish the listing again when the car is ready.');
end $$;

-- Delete (hard): only a car with nothing tied to money. What blocks a delete, in words (empty: it may be deleted).
-- Tied to money: any booking, payment, owner invoice that was issued or has a payment, owner or company statement line,
-- booking split, payout, toll or ticket, damage intake, incident, Turo trip, expense, owner deduction, investor link,
-- a signed vehicle schedule (unless the car is a sample car) and any stored document except listing photos.
create or replace function app.vehicle_delete_blockers(p_vehicle uuid) returns text[]
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  b text[] := '{}';
  n bigint;
  t record;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return array['Vehicle not found']; end if;
  select count(*) into n from bookings where vehicle_id = v.id;
  if n > 0 then b := b || format('%s booking(s)', n); end if;
  select count(*) into n from booking_vehicle_swaps where from_vehicle_id = v.id or to_vehicle_id = v.id;
  if n > 0 then b := b || format('%s vehicle swap(s)', n); end if;
  select count(*) into n from payments p where p.booking_id in (select id from bookings where vehicle_id = v.id);
  if n > 0 then b := b || format('%s payment(s)', n); end if;
  select count(*) into n from owner_invoices i where i.vehicle_id = v.id and (i.status not in ('draft', 'void') or i.paid_cents > 0);
  if n > 0 then b := b || format('%s owner invoice(s) issued', n); end if;
  for t in select * from (values
      ('owner_statement_vehicles', 'owner statement line(s)'), ('booking_splits', 'booking split(s)'), ('company_statement_lines', 'company statement line(s)'),
      ('toll_tickets', 'toll or ticket notice(s)'), ('damage_intakes', 'damage intake(s)'), ('incidents', 'incident(s)'), ('turo_trips', 'Turo trip(s)'),
      ('company_expenses', 'expense(s)'), ('owner_deductions', 'owner deduction(s)'), ('vehicle_prepaids', 'prepaid month(s)'),
      ('referral_kickbacks', 'referral kickback(s)'), ('fleet_report_vehicles', 'fleet report line(s)')) x(tbl, label) loop
    if to_regclass('public.' || t.tbl) is not null then
      execute format('select count(*) from public.%I where vehicle_id = $1', t.tbl) into n using v.id;
      if n > 0 then b := b || format('%s %s', n, t.label); end if;
    end if;
  end loop;
  if not coalesce(v.is_sample, false) then
    select count(*) into n from vehicle_schedules s where s.vehicle_id = v.id and (s.signed_at is not null or s.document_id is not null);
    if n > 0 then b := b || format('%s signed vehicle schedule(s)', n); end if;
  end if;
  select count(*) into n from documents d where d.vehicle_id = v.id and d.purged_at is null;
  if n > 0 then b := b || format('%s stored document(s)', n); end if;
  return b;
end $$;

-- Delete every row that hangs off the car (children first), then the car. The tables are found from the foreign keys,
-- so a table added later is covered; a referencing table that holds money is never in the way here because
-- app.vehicle_delete_blockers refused the car first. Returns the storage objects to remove (listing photos).
create or replace function app.purge_rows(p_table regclass, p_where text, p_depth integer default 0) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  f record;
  n integer := 0;
  k integer;
begin
  if p_depth > 6 then raise exception 'Too many levels of records under this car: delete refused' using errcode = '23514'; end if;
  for f in
    select c.conrelid::regclass as child, a.attname as col, pa.attname as pcol
      from pg_constraint c
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
      join pg_attribute pa on pa.attrelid = c.confrelid and pa.attnum = c.confkey[1]
     where c.contype = 'f' and c.confrelid = p_table and cardinality(c.conkey) = 1 and c.conrelid <> p_table
  loop
    -- a child row of a child is removed first; nullable links to a row that goes are cleared rather than deleted
    if (select attnotnull from pg_attribute where attrelid = f.child and attname = f.col) then
      n := n + app.purge_rows(f.child, format('%I in (select %I from %s where %s)', f.col, f.pcol, p_table, p_where), p_depth + 1);
    else
      execute format('update %s set %I = null where %I in (select %I from %s where %s)', f.child, f.col, f.col, f.pcol, p_table, p_where);
    end if;
  end loop;
  execute format('delete from %s where %s', p_table, p_where);
  get diagnostics k = row_count;
  return n + k;
end $$;

create or replace function app.vehicle_delete(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_block text[];
  v_files jsonb;
  v_confirm text := upper(regexp_replace(coalesce(p ->> 'confirm', ''), '\s', '', 'g'));
  n integer;
begin
  perform app.assert_admin(p_by);
  select * into v from vehicles where id = (p ->> 'vehicle_id')::uuid for update;
  if v.id is null then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
  if not coalesce((p ->> 'bulk')::boolean, false)
     and v_confirm not in (upper(regexp_replace(coalesce(v.plate, '-'), '\s', '', 'g')), upper(regexp_replace(app.vehicle_name(v.id), '\s', '', 'g'))) then
    raise exception 'Type the plate (or the car''s name, %) to confirm', app.vehicle_name(v.id) using errcode = '22023';
  end if;
  v_block := app.vehicle_delete_blockers(v.id);
  if cardinality(v_block) > 0 then
    raise exception 'This car cannot be deleted: it has %. Retire it instead', array_to_string(v_block, ', ') using errcode = '23514';
  end if;
  -- the files to remove from storage (the server removes them after the delete)
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_files from (
    select jsonb_build_object('bucket', 'vehicle-public', 'path', ph.processed_path) as x from vehicle_photos ph where ph.vehicle_id = v.id and ph.processed_path is not null
    union all select jsonb_build_object('bucket', 'vehicle-originals', 'path', ph.original_path) from vehicle_photos ph where ph.vehicle_id = v.id and ph.original_path is not null
    union all select jsonb_build_object('bucket', 'vehicle-originals', 'path', ph.uncovered_path) from vehicle_photos ph where ph.vehicle_id = v.id and ph.uncovered_path is not null
    union all select jsonb_build_object('bucket', 'vehicle-public', 'path', vv ->> 'path')
                from vehicle_photos ph cross join lateral jsonb_array_elements(case when jsonb_typeof(ph.variants) = 'array' then ph.variants else '[]'::jsonb end) vv
               where ph.vehicle_id = v.id and vv ->> 'path' is not null) q;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before)
  values (p_by, 'vehicle_delete', 'vehicles', v.id::text,
          jsonb_build_object('name', app.vehicle_name(v.id), 'vin', v.vin, 'plate', v.plate, 'supply_type', v.supply_type, 'is_sample', v.is_sample, 'status', v.status));
  perform set_config('app.vehicle_delete', v.id::text, true);
  n := app.purge_rows('public.vehicles'::regclass, format('id = %L', v.id));
  perform set_config('app.vehicle_delete', '', true);
  return jsonb_build_object('vehicle_id', v.id, 'deleted', true, 'rows', n, 'files', v_files);
end $$;

-- Delete every sample car (vehicles.is_sample) that meets the rule; the others are listed with why they stay.
create or replace function app.vehicles_delete_samples(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  v_done jsonb := '[]'::jsonb;
  v_kept jsonb := '[]'::jsonb;
  v_files jsonb := '[]'::jsonb;
  v_res jsonb;
  v_block text[];
begin
  perform app.assert_admin(p_by);
  if upper(coalesce(p ->> 'confirm', '')) <> 'DELETE SAMPLE CARS' then
    raise exception 'Type DELETE SAMPLE CARS to confirm' using errcode = '22023';
  end if;
  for r in select id from vehicles where is_sample order by fleet_number nulls last, id loop
    v_block := app.vehicle_delete_blockers(r.id);
    if cardinality(v_block) > 0 then
      v_kept := v_kept || jsonb_build_object('vehicle_id', r.id, 'name', app.vehicle_name(r.id), 'why', array_to_string(v_block, ', '));
    else
      v_res := app.vehicle_delete(p_by, jsonb_build_object('vehicle_id', r.id, 'bulk', true));
      v_done := v_done || jsonb_build_object('vehicle_id', r.id);
      v_files := v_files || (v_res -> 'files');
    end if;
  end loop;
  -- the sample owner, agreement and renter go too when nothing else is theirs
  return jsonb_build_object('deleted', jsonb_array_length(v_done), 'kept', v_kept, 'files', v_files);
end $$;

-- ================================================================ 7. the partner agreement: signed in the portal or on paper
alter table sign_requests drop constraint if exists sign_requests_doc_type_check;
alter table sign_requests add constraint sign_requests_doc_type_check
  check (doc_type in ('form_a', 'form_b', 'investment_agreement', 'staff_agreement', 'partner_agreement'));
alter table sign_requests drop constraint if exists sign_requests_signer_role_check;
alter table sign_requests add constraint sign_requests_signer_role_check
  check (signer_role in ('owner_individual', 'owner_corporation', 'investor', 'staff', 'partner'));
alter table sign_requests add constraint sign_requests_partner_owner check (doc_type <> 'partner_agreement' or owner_id is not null);
alter table signature_records drop constraint if exists signature_records_signer_role_check;
alter table signature_records add constraint signature_records_signer_role_check check (signer_role in (
  'renter', 'additional_driver', 'carmacars', 'owner_individual', 'owner_corporation', 'lessor', 'investor', 'witness', 'staff', 'partner'));
alter table paper_signatures drop constraint if exists paper_signatures_doc_type_check;
alter table paper_signatures add constraint paper_signatures_doc_type_check check (doc_type in (
  'owner_agreement', 'debit_agreement', 'form_a', 'form_b', 'form_c', 'form_d', 'registry_form',
  'rental_agreement', 'rental_amendment', 'investment_agreement', 'staff_agreement', 'partner_agreement'));

create or replace function app.paper_doc_kind(p_type text) returns text
language sql immutable as $$
  select case p_type when 'owner_agreement' then 'enrollment_agreement' when 'form_a' then 'form_a_trust_declaration' when 'form_b' then 'form_b_lease_summary'
                     when 'form_c' then 'form_c_finance_permission_ack' when 'form_d' then 'form_d_power_of_attorney' when 'registry_form' then 'registry_form'
                     when 'rental_agreement' then 'rental_agreement' when 'rental_amendment' then 'rental_amendment'
                     when 'investment_agreement' then 'investment_agreement' when 'staff_agreement' then 'staff_agreement'
                     when 'partner_agreement' then 'partner_agreement' else 'other' end
$$;
create or replace function app.paper_doc_title(p_type text) returns text
language sql immutable as $$
  select case p_type when 'owner_agreement' then 'Owner agreements and schedules' when 'debit_agreement' then 'Pre-authorized debit agreement'
                     when 'form_a' then 'Form A, trust declaration' when 'form_b' then 'Form B, lease summary'
                     when 'form_c' then 'Form C, lender or lessor permission acknowledgment' when 'form_d' then 'Form D, limited power of attorney'
                     when 'registry_form' then 'Registry form' when 'rental_agreement' then 'Rental agreement' when 'rental_amendment' then 'Booking amendment'
                     when 'investment_agreement' then 'Investment agreement' when 'staff_agreement' then 'Staff agreement'
                     when 'partner_agreement' then 'Partner agreement' else 'Document' end
$$;

-- What the partner agreement is filled with: the partner, its cars, the commission, its insurance, the company.
create or replace function app.partner_agreement_facts(p_owner uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('owner_id', r.owner_id, 'partner_id', r.id, 'partner_number', r.partner_number,
    'partner', jsonb_build_object('business_name', r.business_name, 'legal_name', coalesce(r.legal_name, r.business_name),
                                  'signer_name', coalesce(r.contact_name, r.legal_name, r.business_name), 'signer_title', r.contact_title,
                                  'address', concat_ws(', ', nullif(r.address_line1, ''), nullif(r.city, ''), nullif(r.province, ''), nullif(r.postal_code, '')),
                                  'email', r.email, 'phone', r.phone, 'hst_number', r.hst_number),
    'commission_bps', coalesce(r.commission_bps, (app.settings()).partner_commission_bps),
    'insurance', jsonb_build_object('company', r.insurance_company, 'policy', r.insurance_policy, 'expiry', r.insurance_expiry),
    'payout_day', (select extract(day from app.payout_date(app.month_start(app.today())))::integer),
    'cars', coalesce((select jsonb_agg(jsonb_build_object('name', app.vehicle_name(v.id), 'plate', v.plate, 'vin', v.vin,
                        'commission_bps', app.partner_commission_bps(v.id)) order by v.make, v.model)
                      from vehicles v where v.partner_id = r.id and v.retired_at is null), '[]'::jsonb),
    'company', app.doc_company_brand())
    from partners r where r.owner_id = p_owner
$$;

-- The partner opens its agreement in the portal: the server rendered it from the facts and stored it privately.
create or replace function app.partner_agreement_open(p_by uuid, p_sha256 text, p_path text, p_template_version text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid := app.portal_owner_id(p_by);
  pr partners;
  r sign_requests;
  v_doc uuid;
  v_req uuid;
begin
  select * into pr from partners where owner_id = v_owner;
  if pr.id is null then raise exception 'Only a partner account signs the partner agreement' using errcode = '42501'; end if;
  if pr.agreement_status = 'signed' then raise exception 'Your partner agreement is already signed' using errcode = '23514'; end if;
  if lower(coalesce(p_sha256, '')) !~ '^[0-9a-f]{64}$' or coalesce(p_path, '') !~ ('^owners/' || v_owner || '/') then
    raise exception 'The agreement document is missing' using errcode = '22023';
  end if;
  select * into r from sign_requests where owner_id = v_owner and doc_type = 'partner_agreement' and status = 'sent' for update;
  if r.id is not null and r.document_sha256 = lower(p_sha256) then return to_jsonb(r); end if;
  if r.id is not null then
    update sign_requests set status = 'voided', voided_at = now(), voided_by = p_by, void_reason = 'The agreement was made again' where id = r.id;
    update signature_requests set status = 'voided' where id = r.signature_request_id;
  end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version, owner_id, uploaded_by)
  values ('partner_agreement'::document_kind, 'Partner agreement', 'agreements', p_path, 'application/pdf', lower(p_sha256), p_template_version, v_owner, p_by)
  returning id into v_doc;
  insert into signature_requests (document_id, provider, status, sent_at, created_by) values (v_doc, 'builtin', 'sent', now(), p_by) returning id into v_req;
  insert into sign_requests (doc_type, owner_id, signer_user_id, signer_name, signer_email, signer_role, title, document_id, document_sha256, template_version,
                             signature_request_id, sent_by)
  values ('partner_agreement', v_owner, p_by, coalesce(pr.contact_name, pr.legal_name, pr.business_name), pr.email, 'partner',
          'Partner agreement, ' || pr.business_name, v_doc, lower(p_sha256), p_template_version, v_req, p_by)
  returning * into r;
  update partners set agreement_status = 'sent' where id = pr.id and agreement_status = 'not_sent';
  return to_jsonb(r);
end $$;

create or replace function app.partner_agreement_state(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_owner uuid := app.portal_owner_id(p_by);
begin
  return (select jsonb_build_object('status', r.agreement_status, 'method', r.agreement_method, 'signed_at', r.agreement_signed_at,
                                    'document_id', r.agreement_document_id) from partners r where r.owner_id = v_owner);
end $$;

-- The partner signs (0044's signing, then what follows for a partner agreement): CarmaCars countersigns automatically.
alter function app.sign_request_sign(uuid, uuid, jsonb) rename to sign_request_sign_0044;
create or replace function app.sign_request_sign(p_user uuid, p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.sign_request_sign_0044(p_user, p_id, p);
  r sign_requests;
begin
  select * into r from sign_requests where id = p_id;
  if r.doc_type = 'partner_agreement' then
    insert into signature_records (signature_request_id, signer_role, signer_name, signer_title, signer_email, status, signed_at, method,
                                   typed_name, consent_text, document_sha256)
    select r.signature_request_id, 'carmacars', coalesce(ps.signing_officer_name, ps.company_trade_name), coalesce(ps.signing_officer_title, 'for ' || ps.company_trade_name),
           ps.company_email, 'signed', now(), 'automatic', coalesce(ps.signing_officer_name, ps.company_trade_name),
           format('Countersigned for %s automatically when the partner signed.', ps.company_trade_name), r.document_sha256
      from (select (app.settings()).*) ps;
    update partners set agreement_status = 'signed', agreement_signed_at = r.signed_at, agreement_method = r.method, agreement_document_id = r.document_id
     where owner_id = r.owner_id;
  end if;
  return v_out;
end $$;

alter function app.sign_request_attach(uuid, text, text) rename to sign_request_attach_0044;
create or replace function app.sign_request_attach(p_id uuid, p_path text, p_sha256 text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_doc uuid := app.sign_request_attach_0044(p_id, p_path, p_sha256);
  r sign_requests;
begin
  select * into r from sign_requests where id = p_id;
  if r.doc_type = 'partner_agreement' then
    update partners set agreement_document_id = v_doc where owner_id = r.owner_id;
  end if;
  return v_doc;
end $$;

-- A partner agreement signed on paper (Admins): target_id is the partner. The scan becomes the partner's document.
alter function app.record_paper_signature(uuid, jsonb) rename to record_paper_signature_0044;
create or replace function app.record_paper_signature(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  pr partners;
  v_doc uuid;
  v_id uuid;
  v_signer text := nullif(btrim(coalesce(p ->> 'signer_name', '')), '');
  v_on date := nullif(p ->> 'signed_on', '')::date;
  v_out jsonb;
  b bookings;
begin
  if p ->> 'doc_type' is distinct from 'partner_agreement' then
    v_out := app.record_paper_signature_0044(p_by, p);
    -- a rental added by hand is already confirmed: its agreement is completed (countersigned) once the renter has signed
    if p ->> 'doc_type' = 'rental_agreement' then
      select * into b from bookings where id = nullif(p ->> 'target_id', '')::uuid;
      if b.added_by_staff then perform app.manual_agreement_complete(b.id); end if;
    end if;
    return v_out;
  end if;
  perform app.assert_admin(p_by);
  select * into pr from partners where id = nullif(p ->> 'target_id', '')::uuid for update;
  if pr.id is null then raise exception 'Choose the partner' using errcode = '22023'; end if;
  if v_signer is null then raise exception 'Enter the name of the person who signed' using errcode = '22023'; end if;
  if v_on is null or v_on > app.today() then raise exception 'Enter the date it was signed (not in the future)' using errcode = '22023'; end if;
  if lower(coalesce(p #>> '{scan,sha256}', '')) !~ '^[0-9a-f]{64}$' or coalesce(p #>> '{scan,path}', '') !~ '^paper/' then
    raise exception 'Upload the scan of the signed document' using errcode = '22023';
  end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, owner_id, uploaded_by)
  values ('partner_agreement'::document_kind, 'Partner agreement, signed on paper', 'agreements', p #>> '{scan,path}', coalesce(p #>> '{scan,mime}', 'application/pdf'),
          lower(p #>> '{scan,sha256}'), pr.owner_id, p_by)
  returning id into v_doc;
  insert into paper_signatures (doc_type, target_id, owner_id, document_id, signer_name, signed_on, note, effect, recorded_by)
  values ('partner_agreement', pr.id, pr.owner_id, v_doc, v_signer, v_on, nullif(btrim(coalesce(p ->> 'note', '')), ''),
          jsonb_build_object('status_before', pr.agreement_status, 'signed_at_before', pr.agreement_signed_at, 'method_before', pr.agreement_method,
                             'document_before', pr.agreement_document_id), p_by)
  returning id into v_id;
  update sign_requests set status = 'voided', voided_at = now(), voided_by = p_by, void_reason = 'Signed on paper instead'
   where owner_id = pr.owner_id and doc_type = 'partner_agreement' and status = 'sent';
  update partners set agreement_status = 'signed', agreement_signed_at = app.local_midnight(v_on) + interval '12 hours', agreement_method = 'paper',
         agreement_document_id = v_doc where id = pr.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'record_paper_signature', 'paper_signatures', v_id::text, jsonb_build_object('doc_type', 'partner_agreement', 'partner_id', pr.id, 'document_id', v_doc));
  return jsonb_build_object('id', v_id, 'document_id', v_doc, 'doc_type', 'partner_agreement');
end $$;

alter function app.void_paper_signature(uuid, uuid, text) rename to void_paper_signature_0044;
create or replace function app.void_paper_signature(p_by uuid, p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps paper_signatures;
begin
  select * into ps from paper_signatures where id = p_id for update;
  if ps.doc_type is distinct from 'partner_agreement' then return app.void_paper_signature_0044(p_by, p_id, p_reason); end if;
  perform app.assert_admin(p_by);
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason for voiding the paper signature' using errcode = '22023'; end if;
  if ps.voided_at is not null then raise exception 'This paper signature was already voided' using errcode = '23514'; end if;
  update paper_signatures set voided_at = now(), voided_by = p_by, void_reason = btrim(p_reason) where id = ps.id;
  update partners set agreement_status = coalesce(ps.effect ->> 'status_before', 'not_sent'), agreement_signed_at = nullif(ps.effect ->> 'signed_at_before', '')::timestamptz,
         agreement_method = nullif(ps.effect ->> 'method_before', ''), agreement_document_id = nullif(ps.effect ->> 'document_before', '')::uuid
   where id = ps.target_id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'void_paper_signature', 'paper_signatures', ps.id::text, jsonb_build_object('doc_type', ps.doc_type, 'reason', btrim(p_reason)));
  return jsonb_build_object('id', ps.id, 'voided', true);
end $$;

-- ================================================================ 8. rentals added by hand
-- Who may add one: an Admin (everything), customer service and Sales (the rate-sheet price, the promo codes the setting
-- allows, the payment ways the setting allows, never over a clash, never a past rental). Returns 'admin', 'va' or null.
create or replace function app.manual_rental_role(p_by uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when app.user_is_admin(p_by) then 'admin' when app.user_va_has(p_by, 'cs', 'sales') then 'va' end
$$;

-- Renters to choose from (name, email or phone; three characters at least).
create or replace function app.manual_rental_renters(p_by uuid, p_q text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  q text := lower(btrim(coalesce(p_q, '')));
begin
  if app.manual_rental_role(p_by) is null then raise exception 'Not permitted' using errcode = '42501'; end if;
  if length(q) < 3 then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(x order by x ->> 'legal_name') from (
    select jsonb_build_object('id', r.id, 'legal_name', r.legal_name, 'email', r.email, 'mobile', r.mobile, 'date_of_birth', r.date_of_birth,
             'is_blocked', r.is_blocked, 'identity_status', r.identity_status,
             'licence_number', (select d.licence_number from drivers d where d.renter_id = r.id and d.is_account_holder limit 1),
             'card', (select jsonb_build_object('id', pm.id, 'brand', pm.card_brand, 'last4', pm.card_last4) from payment_methods pm
                       join payment_method_secrets s on s.payment_method_id = pm.id
                      where pm.renter_id = r.id and pm.status = 'active' and s.processor_method_id is not null order by pm.created_at desc limit 1),
             'bookings', (select count(*) from bookings b where b.renter_id = r.id)) as x
      from renters r
     where lower(r.legal_name) like '%' || q || '%' or lower(coalesce(r.email, '')) like q || '%'
        or regexp_replace(coalesce(r.mobile, ''), '\D', '', 'g') like regexp_replace(q, '\D', '', 'g') || '%' and length(regexp_replace(q, '\D', '', 'g')) >= 3
     limit 20) s), '[]'::jsonb);
end $$;

-- What staff see before adding: whether the car is free (the turnaround included) with whatever is in the way, the
-- price from the rate sheet, line by line, the Deposit, and the ways the person may take payment.
-- p: {vehicle_id, pickup_at, return_at, booking_type, drivers [{date_of_birth}], extras, coverage_option, promo_code,
--     pickup_method, return_method, renter_id, past}
create or replace function app.manual_rental_quote(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_role text := app.manual_rental_role(p_by);
  v vehicles;
  v_from timestamptz := (p ->> 'pickup_at')::timestamptz;
  v_to timestamptz := (p ->> 'return_at')::timestamptz;
  v_buffer interval := make_interval(mins => coalesce(app.turnaround_minutes(nullif(p ->> 'vehicle_id', '')::uuid), 0));
  v_quote jsonb;
  v_clash jsonb;
  s program_settings := app.settings();
  v_past boolean := coalesce((p ->> 'past')::boolean, false);
begin
  if v_role is null then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is null then raise exception 'Choose the car' using errcode = '22023'; end if;
  if v_from is null or v_to is null or v_to <= v_from then raise exception 'The return must be after the pickup' using errcode = '22023'; end if;
  v_quote := app.price_quote(v.id, v_from, v_to, jsonb_build_object('booking_type', coalesce(p ->> 'booking_type', 'standard'),
               'pickup_method', coalesce(p ->> 'pickup_method', 'collected'), 'return_method', coalesce(p ->> 'return_method', 'returned'),
               'drivers', coalesce(p -> 'drivers', '[]'::jsonb), 'extras', coalesce(p -> 'extras', '{}'::jsonb),
               'coverage_option', coalesce(nullif(p ->> 'coverage_option', '')::integer, 1),
               'promo_code', case when v_role = 'admin' or s.manual_rental_va_promo then nullif(p ->> 'promo_code', '') end));
  -- what is in the way: blocking bookings and calendar blocks, with the turnaround either side; real rentals for a past one
  select coalesce(jsonb_agg(x order by x ->> 'starts_at'), '[]'::jsonb) into v_clash from (
    select jsonb_build_object('kind', 'booking', 'booking_number', b.booking_number, 'status', b.status, 'starts_at', b.pickup_at, 'ends_at', b.return_at,
                              'renter', (select split_part(r.legal_name, ' ', 1) from renters r where r.id = b.renter_id),
                              'overlaps', b.pickup_at < v_to and b.return_at > v_from) as x
      from bookings b
     where b.vehicle_id = v.id and not app.booking_is_placeholder(b.id)
       and ((not v_past and b.status in ('confirmed', 'on_rent') and b.blocks_calendar) or (v_past and b.status in ('confirmed', 'on_rent', 'returned', 'closed')))
       and b.pickup_at < v_to + v_buffer and coalesce(b.checked_in_at, b.return_at) > v_from - v_buffer
    union all
    select jsonb_build_object('kind', 'block', 'reason', k.reason, 'starts_at', k.starts_at, 'ends_at', k.ends_at, 'overlaps', true)
      from vehicle_calendar_blocks k
     where not v_past and k.vehicle_id = v.id and k.removed_at is null and k.starts_at < v_to and coalesce(k.ends_at, 'infinity'::timestamptz) > v_from) q;
  return jsonb_build_object(
    'role', v_role, 'vehicle', jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'supply_type', v.supply_type, 'retired', v.retired_at is not null,
                                                  'bookable', app.vehicle_bookable(v.id)),
    'free', jsonb_array_length(v_clash) = 0, 'clashes', v_clash, 'turnaround_minutes', extract(epoch from v_buffer) / 60,
    'quote', v_quote,
    'payment_modes', case when v_role = 'admin' then to_jsonb(array['other_way', 'link', 'card', 'unpaid']) else to_jsonb(s.manual_rental_va_payment_modes) end,
    'may_override_price', v_role = 'admin', 'may_override_clash', v_role = 'admin', 'may_record_past', v_role = 'admin',
    'may_promo', v_role = 'admin' or s.manual_rental_va_promo,
    'single_limit_cents', (select sp.single_limit_cents from staff_profiles sp where sp.user_id = p_by),
    'card', case when nullif(p ->> 'renter_id', '') is not null then
              (select jsonb_build_object('id', pm.id, 'brand', pm.card_brand, 'last4', pm.card_last4) from payment_methods pm
                 join payment_method_secrets sc on sc.payment_method_id = pm.id
                where pm.renter_id = (p ->> 'renter_id')::uuid and pm.status = 'active' and sc.processor_method_id is not null
                order by pm.created_at desc limit 1) end);
end $$;

-- Add the rental. p: {vehicle_id, pickup_at, return_at, pickup_method, pickup_place, return_method, return_place,
--   renter_id | renter: {full_name, email, mobile, date_of_birth, licence_number, licence_class, licence_issuer, licence_expiry,
--   address_line1, city, province, postal_code}, additional_drivers [{full_name, date_of_birth, email, licence_number}],
--   booking_type, extras {winter_tire, baby_seats}, coverage_option, promo_code, deposit_cents (Admin), rental_charge_cents
--   (Admin, with price_reason), clash_reason (Admin, over a clash), source (phone, walk_in, turo, partner, insurer, other),
--   source_note, note, past (Admin: dates in the past, kept as completed), do_not_email,
--   payment: {mode: other_way | link | card | unpaid, method, reference, received_on, amount_cents, note}}
-- Returns the booking, and for the saved card what the server charges (the card is charged by the server, which then
-- calls app.manual_rental_card_result).
create or replace function app.manual_rental_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_role text := app.manual_rental_role(p_by);
  s program_settings := app.settings();
  v vehicles;
  rc rate_cards;
  u users;
  rn renters;
  dr drivers;
  b bookings;
  pm payment_methods;
  r jsonb := coalesce(p -> 'renter', '{}'::jsonb);
  pay jsonb := coalesce(p -> 'payment', '{}'::jsonb);
  v_mode text := coalesce(nullif(p #>> '{payment,mode}', ''), 'unpaid');
  v_from timestamptz := (p ->> 'pickup_at')::timestamptz;
  v_to timestamptz := (p ->> 'return_at')::timestamptz;
  v_past boolean := coalesce((p ->> 'past')::boolean, false);
  v_type text := coalesce(nullif(p ->> 'booking_type', ''), 'standard');
  v_source text := coalesce(nullif(p ->> 'source', ''), 'phone');
  v_clash_reason text := nullif(btrim(coalesce(p ->> 'clash_reason', '')), '');
  v_price_reason text := nullif(btrim(coalesce(p ->> 'price_reason', '')), '');
  v_override bigint := nullif(p ->> 'rental_charge_cents', '')::bigint;
  v_deposit bigint := nullif(p ->> 'deposit_cents', '')::bigint;
  v_cover integer := coalesce(nullif(p ->> 'coverage_option', '')::integer, 1);
  v_seats integer := coalesce((p -> 'extras' ->> 'baby_seats')::integer, 0);
  v_adds jsonb := case when jsonb_typeof(p -> 'additional_drivers') = 'array' then p -> 'additional_drivers' else '[]'::jsonb end;
  v_free boolean;
  v_overlap boolean;
  v_days integer;
  v_rate record;
  v_rental bigint;
  v_id uuid := gen_random_uuid();
  v_number text;
  v_email text := lower(nullif(btrim(coalesce(r ->> 'email', '')), ''));
  v_name text := nullif(btrim(coalesce(r ->> 'full_name', '')), '');
  v_dob date := nullif(r ->> 'date_of_birth', '')::date;
  v_age integer;
  a jsonb;
  v_a_age integer;
  v_driver uuid;
  v_status booking_status;
  v_pay uuid;
  v_amount bigint;
  v_method text;
  v_ref text := nullif(btrim(coalesce(pay ->> 'reference', '')), '');
  v_on date := coalesce(nullif(pay ->> 'received_on', '')::date, app.today());
  v_limit bigint;
  v_version integer;
  v_charge jsonb;
  v_promo_problem text;
begin
  if v_role is null then raise exception 'Only an Admin, customer service or Sales adds a rental' using errcode = '42501'; end if;
  -- what an assistant may not do
  if v_role = 'va' then
    if v_past then raise exception 'Recording a past rental is for an Admin' using errcode = '42501'; end if;
    if v_override is not null or v_deposit is not null then raise exception 'The price and the Deposit come from the rate sheet: an Admin changes them' using errcode = '42501'; end if;
    if v_clash_reason is not null then raise exception 'The car is not free for these dates: an Admin decides on a clash' using errcode = '42501'; end if;
    if not v_mode = any (s.manual_rental_va_payment_modes) then
      raise exception 'Taking payment that way on a rental added by hand is for an Admin' using errcode = '42501';
    end if;
    if nullif(p ->> 'promo_code', '') is not null and not s.manual_rental_va_promo then
      raise exception 'Promo codes on a rental added by hand are for an Admin' using errcode = '42501';
    end if;
  end if;
  if v_mode not in ('other_way', 'link', 'card', 'unpaid') then raise exception 'Choose how the rental is paid' using errcode = '22023'; end if;
  if v_past and v_mode in ('link', 'card') then raise exception 'A past rental is paid another way or recorded as unpaid' using errcode = '22023'; end if;
  if v_mode = 'link' and coalesce((p ->> 'do_not_email')::boolean, false) then
    raise exception 'A payment link is sent by email: untick "Do not email the renter", or record the payment another way' using errcode = '22023';
  end if;
  if v_source not in ('phone', 'walk_in', 'turo', 'partner', 'insurer', 'email', 'other') then raise exception 'Choose where the rental came from' using errcode = '22023'; end if;
  if v_source = 'other' and nullif(btrim(coalesce(p ->> 'source_note', '')), '') is null then raise exception 'Say where the rental came from' using errcode = '22023'; end if;
  if v_type not in ('standard', 'non_refundable') then raise exception 'A rental is standard or non-refundable' using errcode = '22023'; end if;
  if v_cover not in (1, 2, 3) then raise exception 'Choose how damage to the car is covered (option 1, 2 or 3)' using errcode = '22023'; end if;
  if v_override is not null and (v_override < 0 or v_price_reason is null) then raise exception 'A price typed by hand needs its reason' using errcode = '22023'; end if;

  -- the dates
  if v_from is null or v_to is null or v_to <= v_from then raise exception 'The return must be after the pickup' using errcode = '22023'; end if;
  v_days := public.calc_billable_days(v_from, v_to);
  if v_days > s.max_rental_days then
    raise exception 'A rental is 1 to % days; % asked. Longer stays renew with a new booking.', s.max_rental_days, v_days using errcode = '22023';
  end if;
  if v_past then
    if v_to > now() then raise exception 'A past rental has its return in the past' using errcode = '22023'; end if;
    if v_from < now() - make_interval(days => s.manual_rental_past_max_days) then
      raise exception 'A past rental goes back at most % days', s.manual_rental_past_max_days using errcode = '22023';
    end if;
  elsif v_to <= now() then
    raise exception 'The return is in the past: tick "Record a past rental" to keep it as completed' using errcode = '22023';
  elsif v_from < now() - interval '1 hour' then
    raise exception 'The pickup is more than an hour ago: record it as a past rental, or start it now' using errcode = '22023';
  end if;

  -- the car
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid for no key update;
  if v.id is null then raise exception 'Choose the car' using errcode = '22023'; end if;
  if not v_past and not coalesce(app.vehicle_bookable(v.id), false) then
    raise exception '% is not open for new bookings (%)', app.vehicle_name(v.id), case when v.retired_at is not null then 'retired' else replace(v.status::text, '_', ' ') end using errcode = '23514';
  end if;
  select * into rc from rate_cards x where x.vehicle_id = v.id and x.effective_from <= now() and (x.effective_to is null or x.effective_to > now());
  if rc.id is null and v_override is null then raise exception 'This car has no rates set: set its rates first' using errcode = '23514'; end if;

  -- free for the dates, the turnaround included (a past rental: no other real rental at the same time)
  if v_past then
    v_free := not exists (select 1 from bookings x where x.vehicle_id = v.id and x.status in ('on_rent', 'returned', 'closed', 'confirmed')
                             and not app.booking_is_placeholder(x.id) and x.pickup_at < v_to and coalesce(x.checked_in_at, x.return_at) > v_from);
    v_overlap := false;
  else
    v_free := app.vehicle_is_available(v.id, v_from, v_to);
    v_overlap := exists (select 1 from bookings x where x.vehicle_id = v.id and x.status in ('confirmed', 'on_rent') and x.blocks_calendar
                            and x.rental_window && tstzrange(v_from, v_to, '[)'));
  end if;
  if not v_free and v_clash_reason is null then
    raise exception 'The car is not free for these dates (another rental, a calendar block or the turnaround between trips)%',
      case when v_role = 'admin' then ': give the reason to add it over the clash' else '' end using errcode = '23P01';
  end if;

  -- the renter: found, or made from what staff typed
  if nullif(p ->> 'renter_id', '') is not null then
    select * into rn from renters where id = (p ->> 'renter_id')::uuid;
    if rn.id is null then raise exception 'Renter not found' using errcode = 'P0002'; end if;
    select * into u from users where id = rn.user_id;
    select * into dr from drivers where renter_id = rn.id and is_account_holder;
  else
    if v_name is null or v_dob is null then raise exception 'Enter the renter''s full legal name and date of birth' using errcode = '22023'; end if;
    if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter the renter''s email address' using errcode = '22023'; end if;
    if nullif(btrim(coalesce(r ->> 'mobile', '')), '') is null then raise exception 'Enter the renter''s phone number' using errcode = '22023'; end if;
    select * into u from users where lower(email) = v_email;
    if u.id is null then
      insert into users (email, phone, full_name) values (v_email, btrim(r ->> 'mobile'), v_name) returning * into u;
    end if;
    insert into user_roles (user_id, role) values (u.id, 'renter') on conflict do nothing;
    select * into rn from renters where user_id = u.id;
    if rn.id is null then
      insert into renters (user_id, legal_name, date_of_birth, mobile, email, address_line1, city, province, postal_code)
      values (u.id, v_name, v_dob, btrim(r ->> 'mobile'), v_email, nullif(btrim(r ->> 'address_line1'), ''), nullif(btrim(r ->> 'city'), ''),
              nullif(btrim(r ->> 'province'), ''), upper(nullif(btrim(r ->> 'postal_code'), '')))
      returning * into rn;
    end if;
    select * into dr from drivers where renter_id = rn.id and is_account_holder;
  end if;
  if rn.is_blocked then raise exception '% is blocked from renting: an Admin lifts the block first', rn.legal_name using errcode = '23514'; end if;
  if dr.id is null then
    insert into drivers (renter_id, is_account_holder, user_id, full_name, date_of_birth, licence_number, licence_class, licence_issuer, licence_expiry, mobile, email)
    values (rn.id, true, rn.user_id, rn.legal_name, coalesce(rn.date_of_birth, v_dob), nullif(btrim(r ->> 'licence_number'), ''),
            upper(coalesce(nullif(btrim(r ->> 'licence_class'), ''), 'G')), coalesce(nullif(btrim(r ->> 'licence_issuer'), ''), 'ON'),
            nullif(r ->> 'licence_expiry', '')::date, rn.mobile, rn.email)
    returning * into dr;
  elsif nullif(btrim(r ->> 'licence_number'), '') is not null and dr.licence_number is null then
    update drivers set licence_number = btrim(r ->> 'licence_number'), licence_class = upper(coalesce(nullif(btrim(r ->> 'licence_class'), ''), licence_class, 'G')),
           licence_issuer = coalesce(nullif(btrim(r ->> 'licence_issuer'), ''), licence_issuer, 'ON'),
           licence_expiry = coalesce(nullif(r ->> 'licence_expiry', '')::date, licence_expiry)
     where id = dr.id returning * into dr;
  end if;
  v_age := app.age_on(coalesce(dr.date_of_birth, rn.date_of_birth), app.local_date(v_from));
  if v_age < s.min_renter_age then raise exception 'Every driver must be % or older at pickup', s.min_renter_age using errcode = '23514'; end if;
  if app.age_band(v_age) = '18_to_20' and not v.allows_18_to_20 then raise exception 'This car is for drivers % and over', s.standard_min_age using errcode = '23514'; end if;
  if jsonb_array_length(v_adds) > s.max_additional_drivers then
    raise exception 'A booking may name up to % additional drivers', s.max_additional_drivers using errcode = '22023';
  end if;

  -- the booking, with the rate sheet (or the Admin's price) and the source
  if v_clash_reason is not null and v_role = 'admin' and not v_past then
    perform set_config('app.manual_rental_override', 'on', true);
  end if;
  select * into v_rate from public.calc_rental_charge(v_from, v_days, coalesce(rc.daily_rate_cents, 0), coalesce(rc.weekend_rate_cents, 0),
                                                       coalesce(rc.weekly_rate_cents, 0), coalesce(rc.monthly_rate_cents, 0));
  v_rental := coalesce(v_override, v_rate.rental_charge_cents);
  v_number := 'CC-' || nextval('booking_number_seq');
  v_status := case when v_past then 'closed' when v_mode = 'link' then 'requested' else 'confirmed' end;
  insert into bookings (id, booking_number, booking_type, status, vehicle_id, renter_id, source, booked_at, requested_at, request_note,
      pickup_at, return_at, original_return_at, pickup_method, return_method, pickup_place, return_place, billable_days,
      rate_card_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, daily_days, weekend_days,
      rental_charge_cents, discount_cents, km_allowance_per_day, km_allowance_total, overage_cents_per_km,
      deposit_cents, deductible_cents, hst_bps, created_by, coverage_option,
      blocks_calendar, blocks_calendar_reason, blocks_calendar_changed_by, blocks_calendar_changed_at,
      confirmed_at, handed_over_at, checked_in_at,
      added_by_staff, added_mode, payment_mode, do_not_email, clash_override_reason, notes, request_details)
  values (v_id, v_number, v_type::booking_type, v_status, v.id, rn.id,
      case when v_source in ('walk_in', 'turo', 'partner', 'insurer', 'phone', 'email', 'other') then v_source else 'staff' end,
      now(), now(), nullif(btrim(coalesce(p ->> 'note', '')), ''),
      v_from, v_to, v_to, coalesce(nullif(p ->> 'pickup_method', ''), 'collected'), coalesce(nullif(p ->> 'return_method', ''), 'returned'),
      nullif(btrim(coalesce(p ->> 'pickup_place', '')), ''), nullif(btrim(coalesce(p ->> 'return_place', '')), ''), v_days,
      rc.id, coalesce(rc.daily_rate_cents, 0), coalesce(rc.weekend_rate_cents, 0), coalesce(rc.weekly_rate_cents, 0), coalesce(rc.monthly_rate_cents, 0),
      v_rate.rate_applied, v_rate.daily_days, v_rate.weekend_days,
      v_rental, case when v_type = 'non_refundable' then public.calc_bps(v_rental, s.non_refundable_discount_bps) else 0 end,
      coalesce(rc.km_allowance_per_day, 0), coalesce(rc.km_allowance_per_day, 0) * v_days, coalesce(rc.overage_cents_per_km, 0),
      coalesce(v_deposit, rc.deposit_cents, 0), s.deductible_cents, s.hst_bps, p_by, v_cover,
      not (v_overlap and v_clash_reason is not null),
      case when v_overlap and v_clash_reason is not null then 'Added over a clash: ' || v_clash_reason end,
      case when v_overlap and v_clash_reason is not null then p_by end,
      case when v_overlap and v_clash_reason is not null then now() end,
      case when v_status in ('confirmed', 'closed') then now() end,
      case when v_past then v_from end, case when v_past then v_to end,
      true, case when v_past then 'past' else 'future' end, v_mode, coalesce((p ->> 'do_not_email')::boolean, false), v_clash_reason,
      concat_ws(E'\n', case when v_price_reason is not null then 'Price set by an Admin: ' || v_price_reason end,
                       case when nullif(btrim(coalesce(p ->> 'source_note', '')), '') is not null then 'Source: ' || btrim(p ->> 'source_note') end),
      jsonb_build_object('added_by_staff', true, 'source', v_source, 'source_note', nullif(btrim(coalesce(p ->> 'source_note', '')), ''),
                         'extras', jsonb_build_object('winter_tire', coalesce((p -> 'extras' ->> 'winter_tire')::boolean, false), 'baby_seats', v_seats),
                         'coverage_option', v_cover, 'price_reason', v_price_reason, 'clash_reason', v_clash_reason, 'past', v_past))
  returning * into b;

  -- drivers, as the agreement will print them
  insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_issuer, licence_expiry, age_at_pickup, age_band)
  values (b.id, dr.id, 'renter', dr.full_name, dr.date_of_birth, dr.licence_number, dr.licence_class, dr.licence_issuer, dr.licence_expiry, v_age, app.age_band(v_age));
  for a in select value from jsonb_array_elements(v_adds) loop
    if nullif(btrim(coalesce(a ->> 'full_name', '')), '') is null or nullif(a ->> 'date_of_birth', '') is null then
      raise exception 'Each additional driver needs a full name and a date of birth' using errcode = '22023';
    end if;
    v_a_age := app.age_on((a ->> 'date_of_birth')::date, app.local_date(v_from));
    if v_a_age < s.min_renter_age then raise exception 'Every driver must be % or older at pickup', s.min_renter_age using errcode = '23514'; end if;
    if app.age_band(v_a_age) = '18_to_20' and not v.allows_18_to_20 then raise exception 'This car is for drivers % and over', s.standard_min_age using errcode = '23514'; end if;
    select d.id into v_driver from drivers d where d.renter_id = rn.id and not d.is_account_holder and d.date_of_birth = (a ->> 'date_of_birth')::date
       and lower(regexp_replace(d.full_name, '\s+', ' ', 'g')) = lower(regexp_replace(btrim(a ->> 'full_name'), '\s+', ' ', 'g')) limit 1;
    if v_driver is null then
      insert into drivers (renter_id, full_name, date_of_birth, licence_number, licence_class, licence_issuer, email)
      values (rn.id, btrim(a ->> 'full_name'), (a ->> 'date_of_birth')::date, nullif(btrim(a ->> 'licence_number'), ''), 'G', 'ON',
              lower(nullif(btrim(a ->> 'email'), '')))
      returning id into v_driver;
    end if;
    insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_issuer, licence_expiry, age_at_pickup, age_band)
    select b.id, d.id, 'additional', d.full_name, d.date_of_birth, d.licence_number, d.licence_class, d.licence_issuer, d.licence_expiry, v_a_age, app.age_band(v_a_age)
      from drivers d where d.id = v_driver;
    v_driver := null;
  end loop;

  -- the fee terms of today, the places, the price lines
  insert into booking_fee_terms (booking_id, fee_type_code, amount_cents, cap_cents, percent_bps, source)
  select b.id, x.code, t.amount_cents, t.cap_cents, t.percent_bps, t.source
    from unnest(array['young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'winter_tire', 'baby_seat', 'coverage_sold']) x(code)
    cross join lateral public.effective_fee(x.code, v.id, app.today()) t
  on conflict (booking_id, fee_type_code) do nothing;
  perform app.apply_booking_places(b.id, p);
  if nullif(btrim(coalesce(p ->> 'promo_code', '')), '') is not null then
    v_promo_problem := app.promo_code_problem(p ->> 'promo_code', rn.id, b.id);
    if v_promo_problem is not null then raise exception 'Promo code: %', v_promo_problem using errcode = '23514'; end if;
    perform app.apply_promo_code(b.id, p ->> 'promo_code', p_by);
  end if;
  perform app.sync_booking_price(b.id);
  select * into b from bookings where id = b.id;
  perform app.log_booking_event(b.id, 'added_by_staff', null, b.status::text, null, nullif(btrim(coalesce(p ->> 'note', '')), ''), p_by, 'staff',
    jsonb_build_object('source', v_source, 'payment_mode', v_mode, 'past', v_past, 'price_reason', v_price_reason, 'clash_reason', v_clash_reason,
                       'total_cents', b.total_due_at_booking_cents));

  -- payment
  if v_mode = 'other_way' then
    v_method := coalesce(nullif(pay ->> 'method', ''), 'e_transfer');
    v_amount := coalesce(nullif(pay ->> 'amount_cents', '')::bigint, b.renter_due_at_booking_cents);
    if v_method not in ('e_transfer', 'cheque', 'cash', 'bank_transfer', 'other') then
      raise exception 'Choose how it was paid: e-Transfer, cheque, cash, bank transfer or another way' using errcode = '22023';
    end if;
    if v_method in ('e_transfer', 'cheque', 'bank_transfer') and (v_ref is null or length(v_ref) < 3) then
      raise exception 'Enter the reference of the payment' using errcode = '22023';
    end if;
    if v_method = 'other' and nullif(btrim(coalesce(pay ->> 'note', '')), '') is null then raise exception 'Say how it was paid' using errcode = '22023'; end if;
    if v_on > app.today() then raise exception 'The date received cannot be in the future' using errcode = '22023'; end if;
    if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount received' using errcode = '22023'; end if;
    if v_role = 'va' then
      v_limit := coalesce((select sp.single_limit_cents from staff_profiles sp where sp.user_id = p_by), 0);
      if v_amount > v_limit then
        raise exception '% is above your single limit of %: an Admin records it', app.fmt_money(v_amount), app.fmt_money(v_limit) using errcode = '42501';
      end if;
    end if;
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_by)
    values (b.id, rn.id, 'booking_total', 'charge', v_method, v_amount, 'succeeded', app.local_midnight(v_on) + interval '12 hours', p_by)
    returning id into v_pay;
    insert into payment_processor_details (payment_id, processor, processor_payment_id, raw)
    values (v_pay, 'offline', v_method || ':' || coalesce(v_ref, v_pay::text), jsonb_strip_nulls(jsonb_build_object('reference', v_ref, 'received_on', v_on,
            'note', nullif(btrim(coalesce(pay ->> 'note', '')), ''), 'recorded_by', p_by, 'manual_rental', true)));
    insert into manual_payments (payment_id, target, booking_id, renter_id, method, amount_cents, received_on, reference, note, recorded_by)
    values (v_pay, 'booking', b.id, rn.id, v_method, v_amount, v_on, v_ref, nullif(btrim(coalesce(pay ->> 'note', '')), ''), p_by);
    -- the booking's charges are paid by it (in full: every line; a part payment leaves them to collect)
    if v_amount >= b.renter_due_at_booking_cents then
      update booking_line_items set payment_id = v_pay where booking_id = b.id and stage = 'booking' and charged_to_renter and voided_at is null and payment_id is null;
    end if;
  elsif v_mode = 'card' then
    select x.* into pm from payment_methods x join payment_method_secrets sc on sc.payment_method_id = x.id
     where x.renter_id = rn.id and x.status = 'active' and sc.processor_method_id is not null order by x.created_at desc limit 1;
    if pm.id is null then raise exception '% has no saved card: send a payment link instead', rn.legal_name using errcode = '23514'; end if;
    update bookings set card_on_file_id = pm.id where id = b.id;
    if b.renter_due_at_booking_cents > 0 then
      v_charge := (select jsonb_build_object('customer_id', sc.processor_customer_id, 'method_id', sc.processor_method_id, 'amount_cents', b.renter_due_at_booking_cents,
                                             'brand', pm.card_brand, 'last4', pm.card_last4)
                     from payment_method_secrets sc where sc.payment_method_id = pm.id);
    end if;
  elsif v_mode = 'link' then
    -- the standard flow from here: the offer (the email with the link), the renter signs and pays online
    v_version := app.send_offer(b.id, p_by, nullif(btrim(coalesce(p ->> 'message', '')), ''),
                                now() + make_interval(hours => least(s.offer_expiry_hours, 72)));
    perform app.approve_offer(b.id, v_version, p_by);
  end if;

  -- a past rental: its split, so the owner's or partner's statement and the company statement include it
  if v_past then
    perform app.compute_booking_split(b.id);
    if b.booking_type <> 'owner' then
      update renters set first_completed_booking_id = coalesce(first_completed_booking_id, b.id) where id = rn.id;
    end if;
  end if;
  -- a confirmed rental: requests and offers that wanted the same dates go back to customer service with a task
  if b.status = 'confirmed' and b.blocks_calendar then
    perform app.raise_task(p_type => 'reoffer_booking', p_title => format('Offer another car or dates for %s: %s was booked by staff', x.booking_number, app.vehicle_name(v.id)),
        p_booking => x.id, p_vehicle => v.id, p_queue => 'cs', p_created_by => p_by, p_dedupe => 'manual_rental_clash:' || x.id)
      from bookings x where x.vehicle_id = v.id and x.id <> b.id and x.status in ('requested', 'offered', 'pending_payment')
       and x.pickup_at < b.return_at and x.return_at > b.pickup_at;
  end if;

  -- the renter's email and the owner's or partner's notice
  if b.status = 'confirmed' and not b.do_not_email then
    perform app.ntf_emit('renter_rental_added', 'booking', b.id, 'added', jsonb_build_object('booking_id', b.id, 'renter_id', rn.id));
  end if;
  if b.status = 'confirmed' and v.supply_type <> 'company' and b.booking_type <> 'owner' then
    perform app.ntf_emit('owner_new_booking', 'booking', b.id, 'confirmed', jsonb_build_object('booking_id', b.id, 'owner_id', b.owner_id));
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'manual_rental_create', 'bookings', b.id::text,
          jsonb_build_object('booking_number', b.booking_number, 'status', b.status, 'vehicle_id', v.id, 'supply_type', v.supply_type, 'renter_id', rn.id,
                             'source', v_source, 'payment_mode', v_mode, 'past', v_past, 'total_cents', b.total_due_at_booking_cents,
                             'rental_charge_cents', b.rental_charge_cents, 'price_reason', v_price_reason, 'clash_reason', v_clash_reason,
                             'blocks_calendar', b.blocks_calendar, 'payment_id', v_pay, 'do_not_email', b.do_not_email, 'role', v_role));
  select * into b from bookings where id = b.id;
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'total_cents', b.total_due_at_booking_cents,
                            'due_cents', b.renter_due_at_booking_cents, 'blocks_calendar', b.blocks_calendar, 'payment_id', v_pay, 'charge', v_charge,
                            'renter_id', rn.id, 'renter_has_account', exists (select 1 from users au where au.id = rn.user_id and au.email_verified_at is not null));
end $$;

-- The saved card's charge came back (the server charged it off-session with the key manual-rental:<booking>).
-- p: {booking, ok, processor: {payment_id, charge_id}, amount_cents, error}
create or replace function app.manual_rental_card_result(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_pay uuid;
  pm payment_methods;
begin
  if app.manual_rental_role(p_by) is null then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into b from bookings where id = (p ->> 'booking')::uuid for update;
  if b.id is null or not b.added_by_staff or b.payment_mode <> 'card' then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  select * into pm from payment_methods where id = b.card_on_file_id;
  select id into v_pay from payments where booking_id = b.id and purpose = 'booking_total' and status = 'succeeded' limit 1;
  if v_pay is not null then return jsonb_build_object('payment_id', v_pay, 'repeat', true); end if;
  if coalesce((p ->> 'ok')::boolean, false) then
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, payment_method_id, card_brand, card_last4, processed_at, created_by)
    values (b.id, b.renter_id, 'booking_total', 'charge', 'card', (p ->> 'amount_cents')::bigint, 'succeeded', pm.id, pm.card_brand, pm.card_last4, now(), p_by)
    returning id into v_pay;
    insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, raw)
    values (v_pay, 'stripe', p #>> '{processor,payment_id}', p #>> '{processor,charge_id}', jsonb_build_object('manual_rental', true));
    update booking_line_items set payment_id = v_pay where booking_id = b.id and stage = 'booking' and charged_to_renter and voided_at is null and payment_id is null;
  else
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, payment_method_id, card_brand, card_last4, decline_count,
                          last_decline_code, processed_at, created_by)
    values (b.id, b.renter_id, 'booking_total', 'charge', 'card', greatest(coalesce((p ->> 'amount_cents')::bigint, b.renter_due_at_booking_cents), 1), 'failed',
            pm.id, pm.card_brand, pm.card_last4, 1, left(coalesce(p ->> 'error', 'declined'), 200), now(), p_by)
    returning id into v_pay;
    perform app.raise_task(p_type => 'manual_rental_unpaid', p_title => format('The saved card was declined for %s', b.booking_number),
        p_detail => coalesce(p ->> 'error', 'The card was declined') || '. Send a payment link or record a payment received another way.',
        p_booking => b.id, p_queue => 'finance', p_created_by => p_by, p_dedupe => 'manual_rental_unpaid:' || b.id);
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'manual_rental_card_result', 'bookings', b.id::text, jsonb_build_object('ok', coalesce((p ->> 'ok')::boolean, false), 'payment_id', v_pay));
  return jsonb_build_object('payment_id', v_pay, 'ok', coalesce((p ->> 'ok')::boolean, false));
end $$;

-- A driver's identity checked in person by an Admin (the licence in hand, the face matched), with a note.
create or replace function app.verify_driver_in_person(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d booking_drivers;
  b bookings;
begin
  perform app.assert_admin(p_by);
  if nullif(btrim(coalesce(p ->> 'note', '')), '') is null then raise exception 'Say what was checked (the licence seen, its number)' using errcode = '22023'; end if;
  select * into d from booking_drivers where id = (p ->> 'booking_driver_id')::uuid for update;
  if d.id is null then raise exception 'Driver not found' using errcode = 'P0002'; end if;
  select * into b from bookings where id = d.booking_id;
  if b.status not in ('confirmed', 'pending_payment') then raise exception 'Booking % is %', b.booking_number, b.status using errcode = '23514'; end if;
  update booking_drivers set identity_method = 'in_person', identity_verified_on = app.today() where id = d.id;
  update drivers set identity_status = 'verified' where id = d.driver_id;
  if d.role = 'renter' then update renters set identity_status = 'verified' where id = b.renter_id; end if;
  perform app.log_booking_event(b.id, 'verification', b.status::text, b.status::text, null, btrim(p ->> 'note'), p_by, 'staff',
    jsonb_build_object('booking_driver_id', d.id, 'decision', 'verified_in_person'));
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Verified in person'
   where booking_id = b.id and task_type in ('verify_identity', 'verification_due', 'identity_review') and status in ('open', 'in_progress', 'waiting')
     and not exists (select 1 from booking_drivers x where x.booking_id = b.id and x.identity_verified_on is null);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'verify_driver_in_person', 'booking_drivers', d.id::text, jsonb_build_object('booking_id', b.id, 'note', btrim(p ->> 'note')));
  return jsonb_build_object('booking_driver_id', d.id, 'verified', true);
end $$;

-- ---------------------------------------------------------------- the agreement of a rental added by hand
-- It is confirmed already, so the agreement is opened on the confirmed booking (no offer to approve) and CarmaCars
-- countersigns as soon as the renter has signed (in the portal, or on paper as recorded by staff).
alter function app.open_rental_agreement(uuid, uuid, text, text, text, text) rename to open_rental_agreement_0019;
create or replace function app.open_rental_agreement(p_booking uuid, p_by uuid, p_template_version text, p_document_sha256 text,
                                                     p_storage_path text, p_storage_bucket text default 'agreements')
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  a rental_agreements;
  rn renters;
  v_set program_settings := app.settings();
  v_sha text := lower(btrim(coalesce(p_document_sha256, '')));
  v_reissue boolean;
  v_number text;
  v_cs_name text;
  v_doc uuid;
  v_req uuid;
  v_id uuid := gen_random_uuid();
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null or not (b.added_by_staff and b.status = 'confirmed') then
    return app.open_rental_agreement_0019(p_booking, p_by, p_template_version, p_document_sha256, p_storage_path, p_storage_bucket);
  end if;
  if p_by is null or not (app.is_booking_renter(p_booking, p_by) or app.user_is_staff(p_by)) then
    raise exception 'Only the renter of this booking, or staff, opens its agreement' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_template_version, '')), '') is null or nullif(btrim(coalesce(p_storage_path, '')), '') is null or v_sha !~ '^[0-9a-f]{64}$' then
    raise exception 'An agreement needs its text version, its file and the SHA-256 of the rendered document' using errcode = '22023';
  end if;
  select * into a from rental_agreements where booking_id = p_booking and status in ('open', 'signed', 'completed');
  if a.id is not null then
    if a.status in ('completed', 'signed') then return a.id; end if;
    if a.document_sha256 = v_sha and a.template_version = p_template_version then return a.id; end if;
    perform app.void_rental_agreements(p_booking, 'A new version of the agreement was issued');
  end if;
  v_reissue := exists (select 1 from rental_agreements x where x.booking_id = p_booking);
  select * into rn from renters where id = b.renter_id;
  v_number := coalesce(b.agreement_number, 'RA-' || nextval('rental_agreement_number_seq'));
  v_cs_name := coalesce((select u.full_name from users u where u.id = b.created_by), v_set.company_trade_name);
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version, retention, uploaded_by, renter_id, booking_id)
  values ('rental_agreement', format('Rental agreement %s', v_number), p_storage_bucket, p_storage_path, 'application/pdf', v_sha,
          p_template_version, 'records_7y', p_by, b.renter_id, p_booking)
  returning id into v_doc;
  insert into signature_requests (document_id, provider, provider_envelope, status, sent_at, created_by)
  values (v_doc, 'builtin', v_id::text, 'sent', now(), p_by) returning id into v_req;
  insert into rental_agreements (id, booking_id, offer_version, agreement_number, template_version, document_id, document_sha256,
                                 signature_request_id, countersigner_user_id, countersigner_name, opened_by)
  values (v_id, p_booking, null, v_number, p_template_version, v_doc, v_sha, v_req, b.created_by, v_cs_name, p_by);
  insert into rental_agreement_signers (agreement_id, signer_role, booking_driver_id, driver_id, user_id, signer_name, signer_email, required_before_payment)
  select v_id, 'renter', d.id, d.driver_id, rn.user_id, coalesce(d.full_name, rn.legal_name), coalesce(rn.email, (select u.email from users u where u.id = rn.user_id)), true
    from (select 1) one left join booking_drivers d on d.booking_id = p_booking and d.role = 'renter';
  insert into rental_agreement_signers (agreement_id, signer_role, booking_driver_id, driver_id, user_id, signer_name, signer_email)
  select v_id, 'additional_driver', d.id, d.driver_id, dv.user_id, d.full_name, dv.email
    from booking_drivers d join drivers dv on dv.id = d.driver_id where d.booking_id = p_booking and d.role = 'additional';
  insert into rental_agreement_signers (agreement_id, signer_role, user_id, signer_name, signer_email)
  values (v_id, 'carmacars', b.created_by, v_cs_name, v_set.company_email);
  update bookings set agreement_number = v_number, agreement_document_id = v_doc, signature_request_id = v_req where id = p_booking;
  perform app.log_booking_event(p_booking, 'agreement_opened', b.status::text, b.status::text, null, null, p_by, null,
    jsonb_build_object('agreement_id', v_id, 'agreement_number', v_number, 'template_version', p_template_version, 'document_sha256', v_sha,
                       'reissued', v_reissue, 'added_by_staff', true));
  return v_id;
end $$;

-- Complete it: the countersignature of CarmaCars, once the renter has signed (no payment is waited for: staff took the
-- payment, sent a link, or left it to invoice). The wording is recorded with the signature.
create or replace function app.manual_agreement_complete(p_booking uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  a rental_agreements;
  b bookings;
  v_set program_settings := app.settings();
  v_rec uuid;
begin
  select * into b from bookings where id = p_booking;
  select * into a from rental_agreements where booking_id = p_booking and status = 'signed' for update;
  if a.id is null or not b.added_by_staff then return null; end if;
  if exists (select 1 from rental_agreement_signers g where g.agreement_id = a.id and g.required_before_payment and g.signed_at is null) then return null; end if;
  insert into signature_records (signature_request_id, signer_role, signer_user_id, signer_name, signer_title, signer_email, status, signed_at,
                                 method, typed_name, consent_text, document_sha256)
  values (a.signature_request_id, 'carmacars', a.countersigner_user_id, a.countersigner_name, 'for ' || v_set.company_trade_name, v_set.company_email,
          'signed', now(), 'automatic', a.countersigner_name,
          format('Countersigned for %s automatically when the renter signed, in the name of the staff member who added the rental.', v_set.company_trade_name),
          a.document_sha256)
  returning id into v_rec;
  update rental_agreement_signers set signature_record_id = v_rec, signed_at = now() where agreement_id = a.id and signer_role = 'carmacars';
  update signature_requests set status = 'completed', completed_at = now() where id = a.signature_request_id;
  update rental_agreements set status = 'completed', completed_at = now() where id = a.id;
  perform app.log_booking_event(b.id, 'agreement_completed', b.status::text, b.status::text, null, null, a.countersigner_user_id, 'system',
    jsonb_build_object('agreement_id', a.id, 'agreement_number', a.agreement_number, 'countersigned_by', a.countersigner_name, 'signature_record_id', v_rec));
  if not b.do_not_email then
    perform app.emit_event('renter_agreement_signed', 'rental_agreement', a.id,
      jsonb_build_object('booking_id', a.booking_id, 'booking_number', b.booking_number, 'agreement_number', a.agreement_number,
                         'signature_request_id', a.signature_request_id, 'countersigned_by', a.countersigner_name,
                         'signers', (select jsonb_agg(jsonb_build_object('signer_role', g.signer_role, 'signer_name', g.signer_name, 'signer_email', g.signer_email,
                                                                         'signed_at', g.signed_at) order by g.created_at, g.id)
                                       from rental_agreement_signers g where g.agreement_id = a.id and g.signed_at is not null)),
      'renter_agreement_signed:' || a.id || ':completed');
  end if;
  return a.id;
end $$;

-- 0019's signing, with the renter of a confirmed rental added by hand allowed to sign (then completed at once).
alter function app.record_signature(uuid, uuid, text, text, inet, text, text, text, jsonb) rename to record_signature_0019;
create or replace function app.record_signature(p_request uuid, p_signer uuid, p_typed_name text, p_drawn_signature text,
                                                p_ip inet, p_user_agent text, p_consent_text text,
                                                p_document_sha256 text default null, p_consents jsonb default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  a rental_agreements;
  g rental_agreement_signers;
  b bookings;
  v_typed text := nullif(btrim(coalesce(p_typed_name, '')), '');
  v_drawn text := nullif(btrim(coalesce(p_drawn_signature, '')), '');
  v_rec uuid;
  k jsonb;
begin
  select * into a from rental_agreements where signature_request_id = p_request;
  select * into b from bookings where id = a.booking_id;
  select * into g from rental_agreement_signers where id = p_signer and agreement_id = a.id;
  if not (coalesce(b.added_by_staff, false) and b.status = 'confirmed' and g.signer_role = 'renter') then
    v_rec := app.record_signature_0019(p_request, p_signer, p_typed_name, p_drawn_signature, p_ip, p_user_agent, p_consent_text, p_document_sha256, p_consents);
    if coalesce(b.added_by_staff, false) and b.status = 'confirmed' then perform app.manual_agreement_complete(b.id); end if;
    return v_rec;
  end if;
  perform 1 from rental_agreements where id = a.id for update;
  if a.status <> 'open' then raise exception 'This agreement is not open for the renter''s signature' using errcode = '23514'; end if;
  if g.signed_at is not null then raise exception '% has already signed this agreement', g.signer_name using errcode = '23514'; end if;
  if p_document_sha256 is not null and lower(btrim(p_document_sha256)) <> a.document_sha256 then
    raise exception 'The document changed after it was opened: reload and sign the current version' using errcode = '23514';
  end if;
  if v_typed is null and v_drawn is null then raise exception 'Sign by drawing a signature or by typing your full legal name' using errcode = '22023'; end if;
  if v_drawn is null and lower(regexp_replace(v_typed, '\s+', '', 'g')) <> lower(regexp_replace(g.signer_name, '\s+', '', 'g')) then
    raise exception 'The typed name must be the signer''s full legal name (%)', g.signer_name using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p_consent_text, '')), '') is null then
    raise exception 'The statement the signer agreed to is recorded with the signature' using errcode = '22023';
  end if;
  insert into signature_records (signature_request_id, signer_role, signer_user_id, signer_name, signer_email, status, signed_at, method,
                                 ip_address, user_agent, provider_signature, typed_name, consent_text, document_sha256)
  values (p_request, 'renter', g.user_id, g.signer_name, g.signer_email, 'signed', now(), case when v_drawn is not null then 'drawn' else 'typed' end,
          p_ip, p_user_agent, v_drawn, v_typed, p_consent_text, a.document_sha256)
  returning id into v_rec;
  update rental_agreement_signers set signature_record_id = v_rec, signed_at = now() where id = g.id;
  if jsonb_typeof(p_consents) = 'array' then
    for k in select value from jsonb_array_elements(p_consents) loop
      insert into consents (user_id, driver_id, booking_id, consent_code, text_version, text_shown, ip_address, user_agent)
      values (g.user_id, g.driver_id, a.booking_id, k ->> 'code', k ->> 'version', k ->> 'text', p_ip, p_user_agent);
    end loop;
  end if;
  update rental_agreements set status = 'signed', renter_signed_at = now() where id = a.id;
  update signature_requests set status = 'partially_signed' where id = p_request;
  perform app.log_booking_event(a.booking_id, 'agreement_signed', b.status::text, b.status::text, null, null, g.user_id, 'renter',
    jsonb_build_object('agreement_id', a.id, 'signer_id', g.id, 'signer_role', 'renter', 'signer_name', g.signer_name, 'signature_record_id', v_rec));
  perform app.manual_agreement_complete(b.id);
  return v_rec;
end $$;

-- ================================================================ 9. tolls and damage: placeholders, two rentals, company and partner cars
-- A company car outside a rental: CarmaCars pays (matched to 'company'). A partner car outside a rental: the partner
-- (its owners row, forwarded like an owner's notice).
alter table toll_tickets drop constraint if exists toll_tickets_matched_to_check;
alter table toll_tickets add constraint toll_tickets_matched_to_check check (matched_to in (
  'unmatched', 'renter', 'owner_booking', 'owner_outside_program', 'turo_only', 'staff', 'company'));
alter table damage_intakes drop constraint if exists damage_intakes_matched_to_check;
alter table damage_intakes add constraint damage_intakes_matched_to_check check (matched_to in (
  'unmatched', 'renter', 'owner_booking', 'staff', 'owner_outside_program', 'turo_only', 'company'));

-- 0021's candidates for one car at one time, with three changes: a placeholder booking (app.booking_is_placeholder) is
-- never a candidate; two or more real rentals at that time are a conflict (never automatic: every candidate listed);
-- a company or partner car outside a rental is CarmaCars' or the partner's.
create or replace function app.match_toll_candidates(p_vehicle uuid, p_at timestamptz, p_time_unknown boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  v_margin integer;
  v_day date := app.local_date(p_at);
  v_from timestamptz;
  v_to timestamptz;
  v_c jsonb := '[]'::jsonb;
  v_real jsonb;
  v_n integer;
  v_pending integer;
  r record;
  v_depth numeric;
  v_near boolean;
  v_conf text;
  v_decision text;
  v_reason text;
  v_best jsonb;
  v_kinds text;
begin
  v_margin := (app.settings(v_day)).toll_boundary_margin_minutes;
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then
    return jsonb_build_object('vehicle_id', p_vehicle, 'at', p_at, 'time_unknown', p_time_unknown, 'margin_minutes', v_margin,
                              'candidates', '[]'::jsonb, 'decision', 'unmatched', 'confidence', 'none', 'suggested', null,
                              'reason', 'The plate is not on any vehicle in the fleet');
  end if;
  if p_time_unknown then
    v_from := app.local_midnight(v_day); v_to := app.local_midnight(v_day + 1);
  else
    v_from := p_at; v_to := p_at;
  end if;

  -- bookings actually on rent on this car (each car's part of a swapped booking)
  for r in
    with sw as (
      select s.booking_id, s.from_vehicle_id, s.to_vehicle_id, s.swapped_at,
             row_number() over (partition by s.booking_id order by s.swapped_at, s.id) as n,
             lead(s.swapped_at) over (partition by s.booking_id order by s.swapped_at, s.id) as next_at
        from booking_vehicle_swaps s
       where s.booking_id in (select x.booking_id from booking_vehicle_swaps x where p_vehicle in (x.from_vehicle_id, x.to_vehicle_id))),
    base as (
      select b.*, coalesce(b.handed_over_at, b.pickup_at) as start_at,
             case when b.status = 'on_rent' then coalesce(b.checked_in_at, 'infinity'::timestamptz)
                  else coalesce(b.checked_in_at, b.return_at) end as end_at
        from bookings b
       where b.status in ('on_rent', 'returned', 'closed')
         and not app.booking_is_placeholder(b.id)
         and (b.vehicle_id = p_vehicle or b.id in (select booking_id from sw))),
    seg as (
      select bs.id, bs.vehicle_id as seg_vehicle, bs.start_at as seg_start, bs.end_at as seg_end, false as swapped
        from base bs where not exists (select 1 from sw where sw.booking_id = bs.id)
      union all
      select bs.id, sw.from_vehicle_id, bs.start_at, least(sw.swapped_at, bs.end_at), false
        from base bs join sw on sw.booking_id = bs.id and sw.n = 1
      union all
      select bs.id, sw.to_vehicle_id, sw.swapped_at, coalesce(least(sw.next_at, bs.end_at), bs.end_at), true
        from base bs join sw on sw.booking_id = bs.id)
    select b.id as booking_id, b.booking_number, b.booking_type, b.status::text as status, b.owner_id, b.return_at, b.checked_in_at,
           split_part(btrim(rn.legal_name), ' ', 1) as first_name, sg.seg_start, sg.seg_end, sg.swapped,
           exists (select 1 from booking_extensions e where e.booking_id = b.id and e.status = 'confirmed') as extended
      from seg sg join base b on b.id = sg.id left join renters rn on rn.id = b.renter_id
     where sg.seg_vehicle = p_vehicle and sg.seg_start < sg.seg_end
       and (case when p_time_unknown then sg.seg_start < v_to and sg.seg_end > v_from
                 else sg.seg_start <= p_at and p_at < sg.seg_end end)
  loop
    v_depth := case when p_time_unknown then null
                    when r.seg_end = 'infinity'::timestamptz then extract(epoch from p_at - r.seg_start) / 60
                    else least(extract(epoch from p_at - r.seg_start), extract(epoch from r.seg_end - p_at)) / 60 end;
    v_c := v_c || jsonb_build_object(
      'kind', case when r.booking_type = 'owner' then 'owner_booking' else 'renter' end,
      'booking_id', r.booking_id, 'booking_number', r.booking_number,
      'renter_first_name', case when r.booking_type = 'owner' then null else r.first_name end,
      'owner_id', r.owner_id, 'booking_status', r.status,
      'window_start', r.seg_start, 'window_end', case when r.seg_end = 'infinity'::timestamptz then null else r.seg_end end,
      'minutes_from_start', case when p_time_unknown then null else round(extract(epoch from p_at - r.seg_start) / 60) end,
      'minutes_to_end', case when p_time_unknown or r.seg_end = 'infinity'::timestamptz then null else round(extract(epoch from r.seg_end - p_at) / 60) end,
      'position_pct', case when p_time_unknown or r.seg_end = 'infinity'::timestamptz then null
                           else round(100 * extract(epoch from p_at - r.seg_start) / nullif(extract(epoch from r.seg_end - r.seg_start), 0)) end,
      'depth_minutes', round(v_depth),
      'near_boundary', coalesce(v_depth < v_margin, false),
      'late_return', r.checked_in_at is not null and r.checked_in_at > r.return_at and p_at > r.return_at,
      'extended', r.extended, 'swapped', r.swapped, 'still_on_rent', r.status = 'on_rent', 'not_handed_over', false);
  end loop;

  -- a booking confirmed for that time but never handed over: low confidence, never automatic
  for r in select b.id, b.booking_number, b.booking_type, b.owner_id, b.pickup_at, b.return_at, split_part(btrim(rn.legal_name), ' ', 1) as first_name
             from bookings b left join renters rn on rn.id = b.renter_id
            where b.vehicle_id = p_vehicle and b.status in ('confirmed', 'pending_payment') and b.handed_over_at is null
              and not app.booking_is_placeholder(b.id)
              and b.pickup_at < greatest(v_to, p_at + interval '1 microsecond') and b.return_at > v_from
  loop
    v_c := v_c || jsonb_build_object('kind', case when r.booking_type = 'owner' then 'owner_booking' else 'renter' end,
      'booking_id', r.id, 'booking_number', r.booking_number, 'renter_first_name', case when r.booking_type = 'owner' then null else r.first_name end,
      'owner_id', r.owner_id, 'window_start', r.pickup_at, 'window_end', r.return_at, 'near_boundary', false,
      'not_handed_over', true, 'reason', 'Booked for that time but never handed over');
  end loop;

  -- staff moves (0020)
  for r in select m.id, m.staff_user_id, u.full_name, m.purpose, m.started_at, m.ended_at, m.booking_id, m.field_job_id
             from vehicle_moves m left join users u on u.id = m.staff_user_id
            where m.vehicle_id = p_vehicle
              and (case when p_time_unknown then m.started_at < v_to and coalesce(m.ended_at, 'infinity'::timestamptz) > v_from
                        else m.started_at <= p_at and p_at < coalesce(m.ended_at, 'infinity'::timestamptz) end)
  loop
    v_depth := case when p_time_unknown then null
                    when r.ended_at is null then extract(epoch from p_at - r.started_at) / 60
                    else least(extract(epoch from p_at - r.started_at), extract(epoch from r.ended_at - p_at)) / 60 end;
    v_c := v_c || jsonb_build_object('kind', 'staff', 'staff_user_id', r.staff_user_id, 'staff_name', r.full_name, 'purpose', r.purpose,
      'move_id', r.id, 'booking_id', r.booking_id, 'field_job_id', r.field_job_id, 'window_start', r.started_at, 'window_end', r.ended_at,
      'minutes_from_start', case when p_time_unknown then null else round(extract(epoch from p_at - r.started_at) / 60) end,
      'depth_minutes', round(v_depth), 'near_boundary', coalesce(v_depth < v_margin, false), 'not_handed_over', false);
  end loop;

  -- the Owner: a Turo-Only car, an owner-use block, a Self-Managed car outside a CarmaCars rental,
  -- before the Enrollment Date or after the Exit Date
  if v.supply_type = 'company' and jsonb_array_length(v_c) = 0 then
    v_c := v_c || jsonb_build_object('kind', 'company', 'owner_id', null, 'near_boundary', false, 'not_handed_over', false,
      'reason', 'A CarmaCars-owned car outside a rental: CarmaCars pays');
  elsif v.supply_type = 'partner' and jsonb_array_length(v_c) = 0 then
    v_c := v_c || jsonb_build_object('kind', 'owner_outside_program', 'owner_id', v.owner_id, 'partner_id', v.partner_id, 'near_boundary', false,
      'not_handed_over', false, 'reason', 'The partner rental company had the car (outside a CarmaCars rental)');
  elsif v.supply_type <> 'program_owner' then
    null;
  elsif v.management_mode = 'turo_only' then
    v_c := v_c || jsonb_build_object('kind', 'turo_only', 'owner_id', v.owner_id, 'near_boundary', false, 'not_handed_over', false,
      'reason', 'Turo-Only car', 'turo_trip_ref', (select t.turo_trip_ref from turo_trips t where t.vehicle_id = p_vehicle
                                                     and t.starts_at <= v_to and t.ends_at >= v_from order by t.starts_at limit 1));
  elsif v.enrollment_date is null or v_day < v.enrollment_date or (app.vehicle_fee_end(v.id) is not null and v_day > app.vehicle_fee_end(v.id)) then
    v_c := v_c || jsonb_build_object('kind', 'owner_outside_program', 'owner_id', v.owner_id, 'near_boundary', false, 'not_handed_over', false,
      'reason', case when v.enrollment_date is null or v_day < v.enrollment_date then 'Before the Enrollment Date' else 'After the Exit Date' end);
  else
    for r in select k.id, k.reason, k.starts_at, k.ends_at from vehicle_calendar_blocks k
              where k.vehicle_id = p_vehicle and k.reason in ('owner_unavailable', 'turo_owner_use')
                and k.starts_at < greatest(v_to, p_at + interval '1 microsecond') and coalesce(k.ends_at, 'infinity'::timestamptz) > v_from
    loop
      v_c := v_c || jsonb_build_object('kind', 'owner_outside_program', 'owner_id', v.owner_id, 'block_id', r.id, 'window_start', r.starts_at,
        'window_end', r.ends_at, 'near_boundary', false, 'not_handed_over', false, 'reason', 'The Owner had the car (calendar block: ' || r.reason || ')');
    end loop;
    if v.management_mode = 'self_managed' and jsonb_array_length(v_c) = 0 then
      v_c := v_c || jsonb_build_object('kind', 'owner_outside_program', 'owner_id', v.owner_id, 'near_boundary', false, 'not_handed_over', false,
        'reason', 'Self-Managed car outside a CarmaCars rental');
    end if;
  end if;

  select coalesce(jsonb_agg(c order by (c ->> 'not_handed_over')::boolean, coalesce((c ->> 'depth_minutes')::numeric, 1e9) desc), '[]'::jsonb)
    into v_c from jsonb_array_elements(v_c) c;
  select coalesce(jsonb_agg(c), '[]'::jsonb) into v_real from jsonb_array_elements(v_c) c where not (c ->> 'not_handed_over')::boolean;
  v_n := jsonb_array_length(v_real);
  v_pending := jsonb_array_length(v_c) - v_n;
  select string_agg(c ->> 'kind', ',' order by c ->> 'kind') into v_kinds from jsonb_array_elements(v_real) c;

  if v_n = 0 and v_pending = 0 then
    v_decision := 'unmatched'; v_conf := 'none';
    v_reason := 'The car was in the program and not on a booking, a staff move or an owner block at that time';
  elsif v_n = 1 and v_pending = 0 then
    v_best := v_real -> 0;
    v_near := coalesce((v_best ->> 'near_boundary')::boolean, false);
    v_conf := case when p_time_unknown or v_near then 'medium' else 'high' end;
    v_decision := case when v_conf = 'high' then 'auto' else 'review' end;
    v_reason := case when p_time_unknown then 'Time not stated: one party had the car that day'
                     when v_near then format('Within %s minutes of the start or end of the window', v_margin)
                     else 'One clear candidate' end;
  elsif (select count(*) from jsonb_array_elements(v_real) c where c ->> 'kind' in ('renter', 'owner_booking')) >= 2 then
    v_best := null;
    v_conf := 'low'; v_decision := 'conflict';
    v_reason := 'Two or more rentals overlap this time: '
      || (select string_agg(coalesce(c ->> 'booking_number', '') || coalesce(' (' || (c ->> 'renter_first_name') || ')', ''), ' and ')
            from jsonb_array_elements(v_real) c where c ->> 'kind' in ('renter', 'owner_booking'))
      || '. Choose who had the car; nothing is charged automatically';
  elsif v_n = 2 and v_pending = 0 and v_kinds = 'renter,staff' and not p_time_unknown then
    v_best := v_real -> 0;
    v_conf := 'medium'; v_decision := 'review';
    v_reason := 'A staff move touches the rental (a delivery or collection leg): confirm with the tracker';
  else
    v_best := case when v_n > 0 then v_real -> 0 else v_c -> 0 end;
    v_conf := 'low'; v_decision := 'review';
    v_reason := case when v_n = 0 then 'A booking was confirmed for that time but never handed over'
                     when p_time_unknown then 'Time not stated and more than one party had the car that day'
                     else 'More than one party had the car at that time' end;
  end if;
  return jsonb_build_object('vehicle_id', p_vehicle, 'plate', v.plate, 'at', p_at, 'time_unknown', p_time_unknown,
    'margin_minutes', v_margin, 'candidates', v_c, 'decision', v_decision, 'confidence', v_conf,
    'suggested', v_best, 'reason', v_reason);
end $$;


-- 0021's match applied, with 'company' (CarmaCars pays, no owner, no booking).
create or replace function app.apply_toll_match(p_ticket uuid, p_candidate jsonb, p_by uuid, p_how text, p_confidence text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  k text := p_candidate ->> 'kind';
  b bookings;
begin
  if k not in ('renter', 'owner_booking', 'staff', 'turo_only', 'owner_outside_program', 'company') then
    raise exception 'Unknown match "%"', k using errcode = '22023';
  end if;
  if k in ('renter', 'owner_booking') then
    select * into b from bookings where id = (p_candidate ->> 'booking_id')::uuid;
    if b.id is null then raise exception 'Choose the booking' using errcode = '22023'; end if;
    if (k = 'owner_booking') <> (b.booking_type = 'owner') then
      raise exception 'Booking % is %an Owner Booking', b.booking_number, case when b.booking_type = 'owner' then '' else 'not ' end using errcode = '22023';
    end if;
    if app.booking_is_placeholder(b.id) then
      raise exception 'Booking % is a placeholder (it does not block the calendar and was never handed over): choose the real rental', b.booking_number
        using errcode = '23514';
    end if;
  end if;
  if k = 'staff' and (p_candidate ->> 'staff_user_id') is null then
    raise exception 'Name the member of staff' using errcode = '22023';
  end if;
  if k = 'company' and (select v.supply_type from vehicles v join toll_tickets t on t.vehicle_id = v.id where t.id = p_ticket) is distinct from 'company' then
    raise exception 'Only a CarmaCars-owned car is matched to CarmaCars outside a rental' using errcode = '23514';
  end if;
  update toll_tickets
     set matched_to = k,
         booking_id = case when k in ('renter', 'owner_booking') then b.id end,
         owner_id = case when k in ('renter', 'owner_booking') then b.owner_id
                         when k in ('turo_only', 'owner_outside_program') then coalesce((p_candidate ->> 'owner_id')::uuid,
                              (select v.owner_id from vehicles v where v.id = toll_tickets.vehicle_id)) end,
         staff_user_id = case when k = 'staff' then (p_candidate ->> 'staff_user_id')::uuid end,
         vehicle_id = coalesce(vehicle_id, b.vehicle_id),
         admin_fee_cents = 0,
         matched_by = p_by, matched_at = now(), matched_how = p_how,
         match_confidence = coalesce(p_confidence, match_confidence),
         tracker_proof_document_id = coalesce((p_candidate ->> 'tracker_proof_document_id')::uuid, tracker_proof_document_id),
         status = 'matched'
   where id = p_ticket;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Matched'
   where related_table = 'toll_tickets' and related_id = p_ticket and task_type in ('match_toll', 'review_toll_match', 'toll_unmatched', 'toll_two_rentals')
     and status in ('open', 'in_progress', 'waiting');
end $$;

-- 0021's matcher run, with the conflict: two or more real rentals at that time become an exception for Finance naming
-- every candidate (never matched or charged automatically).
create or replace function app.run_toll_match(p_ticket uuid, p_by uuid default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  t toll_tickets;
  m jsonb;
  r record;
begin
  select * into t from toll_tickets where id = p_ticket for update;
  if t.id is null then raise exception 'Toll or ticket % not found', p_ticket; end if;
  if t.status <> 'logged' then return t.match_evidence; end if;
  if t.vehicle_id is null then
    select * into r from app.resolve_toll_vehicle(t.plate, t.transponder, app.local_date(t.occurred_at));
    if r.vehicle_id is not null then
      update toll_tickets set vehicle_id = r.vehicle_id, vehicle_found_by = r.found_by where id = p_ticket;
      t.vehicle_id := r.vehicle_id;
    end if;
  end if;
  m := app.match_toll_candidates(t.vehicle_id, t.occurred_at, t.time_unknown);
  update toll_tickets set match_evidence = m, match_confidence = m ->> 'confidence' where id = p_ticket;
  if m ->> 'decision' = 'auto' then
    perform app.apply_toll_match(p_ticket, m -> 'suggested', null, 'auto', 'high');
  elsif m ->> 'decision' = 'conflict' then
    perform app.raise_task(p_type => 'toll_two_rentals', p_queue => 'finance',
        p_title => format('Two rentals had plate %s on %s: choose who had the car', t.plate, to_char(t.occurred_at at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI')),
        p_detail => m ->> 'reason', p_vehicle => t.vehicle_id, p_related_table => 'toll_tickets', p_related_id => p_ticket,
        p_due_at => app.local_midnight(coalesce(t.charge_by, app.today()) + 1), p_dedupe => 'toll_two_rentals:' || p_ticket, p_created_by => p_by);
  elsif m ->> 'decision' = 'review' then
    perform app.raise_task(p_type => 'review_toll_match',
        p_title => format('Confirm who had plate %s on %s', t.plate, to_char(t.occurred_at at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI')),
        p_detail => (m ->> 'reason') || '. Candidates: ' || jsonb_array_length(m -> 'candidates'),
        p_vehicle => t.vehicle_id, p_related_table => 'toll_tickets', p_related_id => p_ticket,
        p_due_at => app.local_midnight(coalesce(t.charge_by, app.today()) + 1), p_dedupe => 'review_toll_match:' || p_ticket, p_created_by => p_by);
  else
    perform app.raise_task(p_type => 'match_toll',
        p_title => format('No match for plate %s on %s', t.plate, to_char(t.occurred_at at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI')),
        p_detail => m ->> 'reason', p_vehicle => t.vehicle_id, p_related_table => 'toll_tickets', p_related_id => p_ticket,
        p_due_at => app.local_midnight(coalesce(t.charge_by, app.today()) + 1), p_dedupe => 'match_toll:' || p_ticket, p_created_by => p_by);
  end if;
  return m;
end $$;

-- CarmaCars pays a notice matched to staff (0021) or to a company car outside a rental (0046).
create or replace function app.mark_toll_company_paid(p_id uuid, p_by uuid, p_reference text default null, p_paid_at timestamptz default now(),
                                                      p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  t toll_tickets;
begin
  if not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin records a company-paid notice' using errcode = '42501';
  end if;
  select * into t from toll_tickets where id = p_id for update;
  if t.matched_to not in ('staff', 'company') or t.status <> 'matched' then
    raise exception 'Only a confirmed staff or company-car match is paid by CarmaCars' using errcode = '23514';
  end if;
  update toll_tickets set status = 'company_paid', paid_by_company_at = p_paid_at, payment_reference = coalesce(p_reference, payment_reference),
                          note = coalesce(p_note, note)
   where id = p_id;
end $$;

-- 0021's work queue, with two more buckets: two rentals at the time (the conflict) and a company car's notice.
create or replace view toll_work_queue with (security_barrier = true) as
  select t.id, t.kind, t.authority, t.notice_number, t.external_ref, t.plate, t.vehicle_id, v.fleet_number,
         t.occurred_at, t.time_unknown, t.amount_cents, t.admin_fee_cents, t.received_on, t.due_on, t.charge_by,
         t.matched_to, t.booking_id, b.booking_number, t.match_confidence, t.match_evidence ->> 'reason' as match_reason,
         t.status, t.charged_from, t.notified_at, t.import_batch_id,
         case when t.status = 'logged' and t.match_evidence ->> 'decision' = 'conflict' then 'two_rentals'
              when t.status = 'logged' and coalesce(t.match_confidence, 'none') = 'none' then 'unmatched'
              when t.status = 'logged' then 'needs_review'
              when t.status = 'matched' and t.matched_to = 'renter' then 'matched_not_charged'
              when t.status = 'matched' and t.matched_to in ('owner_booking', 'owner_outside_program', 'turo_only') then 'matched_not_billed'
              when t.status = 'matched' and t.matched_to in ('staff', 'company') then 'matched_staff'
              when t.status = 'charged' and t.notified_at is null then 'charged_not_notified'
              when t.status = 'disputed' then 'disputed'
         end as bucket,
         app.today() - t.received_on as age_days,
         case when app.today() - t.received_on <= 2 then '0-2 days' when app.today() - t.received_on <= 7 then '3-7 days'
              when app.today() - t.received_on <= 30 then '8-30 days' else 'over 30 days' end as age_band,
         (t.due_on is not null and t.due_on <= app.today() + (app.settings()).toll_due_soon_days and t.paid_by_company_at is null) as due_soon,
         (t.charge_by is not null and t.charge_by < app.today() and t.status in ('logged', 'matched')) as past_charge_by
    from toll_tickets t
    left join vehicles v on v.id = t.vehicle_id
    left join bookings b on b.id = t.booking_id
   where (t.status in ('logged', 'matched', 'disputed') or (t.status = 'charged' and t.notified_at is null))
     and (app.is_admin() or app.va_has('finance', 'fleet'));

-- A read's lines whose notice had two rentals at its time: imported, not charged, and listed with every candidate.
alter function app.toll_read_import_lines(uuid, uuid, uuid[], boolean) rename to toll_read_import_lines_0042;
create or replace function app.toll_read_import_lines(p_by uuid, p_read uuid, p_lines uuid[], p_charge boolean) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_res jsonb := app.toll_read_import_lines_0042(p_by, p_read, p_lines, p_charge);
  v_conf jsonb;
begin
  with c as (
    update toll_notice_read_lines l
       set result_reason = 'Imported, not charged: ' || (t.match_evidence ->> 'reason')
      from toll_tickets t
     where l.read_id = p_read and l.id = any (p_lines) and l.status = 'imported' and t.id = l.toll_ticket_id
       and t.match_evidence ->> 'decision' = 'conflict'
    returning l.line_no, t.id as toll_ticket_id, t.match_evidence -> 'candidates' as candidates, t.match_evidence ->> 'reason' as reason)
  select coalesce(jsonb_agg(jsonb_build_object('line_no', line_no, 'toll_ticket_id', toll_ticket_id, 'reason', reason,
                                               'candidates', (select jsonb_agg(jsonb_build_object('booking_number', x ->> 'booking_number', 'renter_first_name', x ->> 'renter_first_name',
                                                                                                    'window_start', x ->> 'window_start', 'window_end', x ->> 'window_end'))
                                                                from jsonb_array_elements(candidates) x where x ->> 'kind' in ('renter', 'owner_booking')))
                            order by line_no), '[]'::jsonb)
    into v_conf from c;
  return v_res || jsonb_build_object('conflicts', v_conf);
end $$;

-- 0021's damage match, with 'company' (a CarmaCars-owned car outside a rental).
create or replace function app.apply_damage_match(p_intake uuid, p_candidate jsonb, p_by uuid, p_confidence text)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  k text := p_candidate ->> 'kind';
begin
  if k not in ('renter', 'owner_booking', 'staff', 'owner_outside_program', 'turo_only', 'company') then
    raise exception 'Unknown match "%"', k using errcode = '22023';
  end if;
  if k in ('renter', 'owner_booking') and app.booking_is_placeholder((p_candidate ->> 'booking_id')::uuid) then
    raise exception 'That booking is a placeholder: choose the real rental' using errcode = '23514';
  end if;
  update damage_intakes
     set matched_to = k,
         booking_id = case when k in ('renter', 'owner_booking') then (p_candidate ->> 'booking_id')::uuid end,
         staff_user_id = case when k = 'staff' then (p_candidate ->> 'staff_user_id')::uuid end,
         route = case when k = 'company' then 'company' else route end,
         matched_by = p_by, matched_at = now(), match_confidence = coalesce(p_confidence, match_confidence), status = 'matched'
   where id = p_intake;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Matched'
   where related_table = 'damage_intakes' and related_id = p_intake and status in ('open', 'in_progress', 'waiting');
end $$;

-- ================================================================ 10. statements, reports and Admin reads by supply type
-- Admin > Owners > Paid and signed lists owners in the owner program only (partners have Admin > Partners).
create or replace function app.owner_checklists(p_by uuid, p_owner uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'finance', 'cs')) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('owner_id', o.id, 'legal_name', o.legal_name, 'items', s.items,
             'open', (select count(*) from jsonb_array_elements(s.items) i where i ->> 'status' = 'open'),
             'done', (select count(*) from jsonb_array_elements(s.items) i where i ->> 'status' = 'done'),
             'paper', (select count(*) from paper_signatures ps where ps.owner_id = o.id and ps.voided_at is null))
             order by o.legal_name), '[]'::jsonb)
            from owners o cross join lateral (select app.owner_signables(o.id) items) s
           where (p_owner is null or o.id = p_owner) and o.kind = 'program' and exists (select 1 from vehicles v where v.owner_id = o.id));
end $$;

-- The company statement's section by supply type: program owners' cars, CarmaCars-owned cars, partner cars; for each
-- the rental revenue, what CarmaCars keeps, what goes to the owners or partners, the fees and the company-paid costs.
create or replace function app.company_supply_section(p_month date) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  cs company_statements;
  g record;
  v_rows jsonb := '[]'::jsonb;
begin
  select * into cs from company_statements where statement_month = app.month_start(p_month);
  if cs.id is null then return app.company_section('supply', 'By supply type', '[]'::jsonb, 'No statement for this month yet.'); end if;
  for g in
    select k.kind, k.label,
           coalesce(sum(l.rental_revenue_cents + l.mileage_cents), 0) as revenue, coalesce(sum(l.revenue_share_cents), 0) as kept,
           coalesce(sum(l.owner_share_out_cents), 0) as paid_out, coalesce(sum(l.company_fees_cents), 0) as fees,
           coalesce(sum(l.company_paid_tolls_cents + l.expenses_cents + greatest(-l.claim_surplus_cents, 0)), 0) as costs,
           count(l.vehicle_id) as cars, coalesce(sum(l.rentals_ended), 0) as rentals
      from (values ('program_owner', 'Program owners'' cars'), ('company', 'CarmaCars-owned cars (company fleet)'), ('partner', 'Partner rental companies'' cars')) k(kind, label)
      left join (company_statement_lines l join vehicles v on v.id = l.vehicle_id) on l.statement_id = cs.id and l.level = 'vehicle' and v.supply_type = k.kind
     group by k.kind, k.label
  loop
    v_rows := v_rows || jsonb_build_array(
      app.csr(g.label || format(': %s cars, %s rentals', g.cars, g.rentals), null, null, true),
      app.csr('Rental revenue (rental charge and kilometres)', g.revenue),
      app.csr(case g.kind when 'company' then 'Kept by CarmaCars (100%)' when 'partner' then 'Commission kept by CarmaCars' else 'Revenue Share kept by CarmaCars' end, g.kept),
      app.csr(case g.kind when 'company' then 'Paid to owners (none)' when 'partner' then 'Owed to the partners' else 'Owed to the owners' end, g.paid_out),
      app.csr('Renter fees kept by CarmaCars', g.fees),
      app.csr(case g.kind when 'company' then 'Costs CarmaCars paid for these cars' else 'Costs CarmaCars paid' end, -g.costs));
  end loop;
  return app.company_section('supply', 'By supply type', v_rows,
    'Program owners are paid their share and pay fees; CarmaCars-owned cars keep every dollar and carry their own costs; partners are paid what is left after the commission.');
end $$;

alter function app.build_company_statement(date, uuid) rename to build_company_statement_0037;
create or replace function app.build_company_statement(p_month date, p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := app.build_company_statement_0037(p_month, p_by);
begin
  if coalesce(current_setting('app.company_probe', true), '') <> 'on' then
    update company_statements set sections = coalesce(sections, '[]'::jsonb) || jsonb_build_array(app.company_supply_section(p_month)) where id = v_id;
  end if;
  return v_id;
end $$;

-- Admin reads: the fleet with who supplies each car; one car with its supply, partner, commission and what blocks a delete.
alter function app.admin_read(uuid, text, jsonb) rename to admin_read_0043;
create or replace function app.admin_read(p_admin uuid, p_what text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.admin_read_0043(p_admin, p_what, p);
begin
  if p_what = 'vehicles' then
    return (select coalesce(jsonb_agg(x || jsonb_build_object(
              'supply_type', v.supply_type, 'supply_label', app.supply_label(v.supply_type), 'partner_id', v.partner_id,
              'partner_name', (select r.business_name from partners r where r.id = v.partner_id), 'retired_at', v.retired_at,
              'owner_name', case v.supply_type when 'company' then 'CarmaCars' when 'partner' then (select r.business_name from partners r where r.id = v.partner_id)
                                               else x ->> 'owner_name' end)
              order by ordinality), '[]'::jsonb)
              from jsonb_array_elements(v_out) with ordinality e(x, ordinality) join vehicles v on v.id = (e.x ->> 'id')::uuid);
  elsif p_what = 'vehicle' and v_out is not null then
    return v_out || (select jsonb_build_object('supply_label', app.supply_label(v.supply_type),
              'partner', (select jsonb_build_object('id', r.id, 'business_name', r.business_name, 'partner_number', r.partner_number,
                                                    'commission_bps', r.commission_bps) from partners r where r.id = v.partner_id),
              'commission_effective_bps', case when v.supply_type = 'partner' then app.partner_commission_bps(v.id) end,
              'delete_blockers', to_jsonb(app.vehicle_delete_blockers(v.id)),
              'bookings_ahead', (select count(*) from bookings b where b.vehicle_id = v.id and b.status in ('confirmed', 'on_rent') and b.return_at > now()))
              from vehicles v where v.id = (v_out ->> 'id')::uuid);
  end if;
  return v_out;
end $$;

-- 0030's calendar data with who supplies each car (the calendar's filter).
create or replace function app.admin_calendar(p_from timestamptz, p_to timestamptz, p_vehicle uuid default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('from', p_from, 'to', p_to, 'now', now(),
    'vehicles', coalesce(jsonb_agg(v order by v ->> 'fleet_number' nulls last, v ->> 'label'), '[]'::jsonb))
  from (
    select jsonb_build_object('id', m.vehicle_id, 'label', min(m.vehicle_label), 'plate', min(m.plate), 'fleet_number', min(m.fleet_number),
             'status', min(m.vehicle_status),
             'class', (select vv.class::text from vehicles vv where vv.id = m.vehicle_id),
             'owner', (select case vv.supply_type when 'company' then 'CarmaCars' when 'partner' then (select r.business_name from partners r where r.id = vv.partner_id)
                                  else o.legal_name end from vehicles vv join owners o on o.id = vv.owner_id where vv.id = m.vehicle_id),
             'supply_type', (select vv.supply_type from vehicles vv where vv.id = m.vehicle_id),
             'mode', (select vv.management_mode::text from vehicles vv where vv.id = m.vehicle_id),
             'entries', coalesce(jsonb_agg(jsonb_build_object('type', m.entry_type, 'id', m.entry_id, 'booking_id', m.booking_id,
                 'booking_number', m.booking_number, 'booking_type', m.booking_type, 'status', m.status, 'state', m.calendar_state,
                 'starts_at', m.starts_at, 'ends_at', m.ends_at, 'blocks', m.blocks_calendar, 'blocking', m.is_blocking, 'bill_to', m.bill_to,
                 'provisional', m.dates_provisional, 'insurer', m.insurer_name, 'renter', m.renter_name, 'reason', m.block_reason,
                 'note', m.note, 'assignee', m.assignee_name, 'detail', m.detail) order by m.starts_at) filter (where m.entry_id is not null), '[]'::jsonb)) as v
      from app.master_calendar(p_from, p_to) m
     where p_vehicle is null or m.vehicle_id = p_vehicle
     group by m.vehicle_id) q
$$;

-- Bookings by supply type (the Bookings page filter) and the rentals added by hand.
create or replace function app.bookings_by_supply(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'sales', 'finance')) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at,
            'return_at', b.return_at, 'vehicle', app.vehicle_name(b.vehicle_id), 'supply_type', v.supply_type,
            'renter', (select r.legal_name from renters r where r.id = b.renter_id), 'total_cents', b.total_due_at_booking_cents,
            'added_by_staff', b.added_by_staff, 'added_mode', b.added_mode, 'payment_mode', b.payment_mode, 'source', b.source,
            'paid_cents', (select coalesce(sum(x.amount_cents), 0) from payments x where x.booking_id = b.id and x.purpose = 'booking_total' and x.status = 'succeeded'))
            order by b.pickup_at desc)
            from (select b.* from bookings b join vehicles v2 on v2.id = b.vehicle_id
                   where (nullif(p ->> 'supply', '') is null or v2.supply_type = p ->> 'supply')
                     and (not coalesce((p ->> 'added')::boolean, false) or b.added_by_staff)
                     and (nullif(p ->> 'status', '') is null or b.status::text = p ->> 'status')
                   order by b.pickup_at desc limit coalesce(nullif(p ->> 'limit', '')::integer, 200)) b
            join vehicles v on v.id = b.vehicle_id), '[]'::jsonb);
end $$;

-- The renter's booking page knows a rental staff added by hand (it is confirmed before the agreement is signed: the
-- portal asks the renter to sign it, with no payment step).
create or replace function app.booking_added_flag(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select b.added_by_staff from bookings b where b.id = p_booking and app.is_booking_renter(b.id, app.uid())
$$;
alter function public.my_booking(text) set schema app;
alter function app.my_booking(text) rename to my_booking_0028;
create or replace function public.my_booking(p_number text) returns jsonb
language sql stable security invoker set search_path = public, app as $$
  select case when x is null then null
              else x || jsonb_build_object('added_by_staff', coalesce(app.booking_added_flag((x ->> 'id')::uuid), false)) end
    from (select app.my_booking_0028(p_number) as x) q
$$;
revoke all on function public.my_booking(text) from public, anon;
grant execute on function public.my_booking(text) to authenticated, service_role;
revoke all on function app.booking_added_flag(uuid) from public, anon;
grant execute on function app.booking_added_flag(uuid) to authenticated, service_role;

-- ================================================================ 11. the renter's email for a rental added by hand
insert into notification_link_paths (key, path) values ('booking_sign', '/account/bookings/{{booking_number}}/sign')
on conflict (key) do update set path = excluded.path;

-- CATALOGUE 0046 START (generated by supabase/seed/0046_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_rental_added', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Booked: {{vehicle_name}}, {{pickup_date}}', 'Booking {{booking_number}}. {{payment_line}} Next: sign your rental agreement.', 'Immediate', 'CarmaCars staff add a rental by hand (Admin > Bookings > Add a rental, or the VA equivalent) and it is confirmed at once: paid another way, charged to the saved card, or to be invoiced later. Not sent when staff tick "Do not email the renter", for a past rental, or for a payment link (the offer email carries the link).', null, '/account/bookings/{{booking_number}}/sign', '[{"name":"balance_line","type":"string"},{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deposit_amount","type":"string"},{"name":"first_name","type":"string"},{"name":"has_balance","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"km_allowance","type":"string"},{"name":"line_items","type":"list","fields":["label","amount"]},{"name":"needs_verification","type":"boolean"},{"name":"opening_hours","type":"string","global":true},{"name":"overage_rate","type":"string"},{"name":"payment_line","type":"string"},{"name":"pickup_date","type":"string"},{"name":"pickup_place","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"total_amount","type":"string"},{"name":"vehicle_image_url","type":"url"},{"name":"vehicle_name","type":"string"},{"name":"verify_by","type":"string"}]'::jsonb, 'templates/renter_rental_added.html', 'templates/renter_rental_added.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0046 END
update notification_catalogue set emitted_by = 'app.manual_rental_create (0046)' where code = 'renter_rental_added';

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_0044;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_0044(p_code, p_event, p_to);
  b bookings;
  m manual_payments;
  v_paid bigint;
begin
  if p_code = 'renter_rental_added' then
    select * into b from bookings where id = p_event.entity_id;
    select * into m from manual_payments where booking_id = b.id and voided_at is null order by recorded_at limit 1;
    select coalesce(sum(p.amount_cents), 0) into v_paid from payments p
     where p.booking_id = b.id and p.purpose = 'booking_total' and p.kind = 'charge' and p.status = 'succeeded';
    x := x || jsonb_build_object(
      'payment_line', case when m.id is not null then format('Paid by %s on %s.', app.payment_method_label(m.method), app.fmt_day(m.received_on))
                           when b.payment_mode = 'card' and v_paid > 0 then 'Charged to your saved card.'
                           when b.payment_mode = 'card' then 'To be charged to your saved card.'
                           else 'We will send you an invoice for this rental.' end,
      'has_balance', b.renter_due_at_booking_cents - v_paid > 0 and v_paid > 0,
      'balance_line', format('%s is still owing on this booking.', app.fmt_money(greatest(b.renter_due_at_booking_cents - v_paid, 0))),
      '_url', app.ntf_link('booking_sign', jsonb_build_object('booking_number', b.booking_number)));
  end if;
  return x;
end $$;

-- ================================================================ 12. the doors
create or replace function app.ops46(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  -- partners
  when 'partners' then return app.partners_list(p_user);
  when 'partner' then return app.partner_detail(p_user, (p ->> 'id')::uuid);
  when 'partner_save' then return app.partner_save(p_user, p);
  when 'partner_payout_account' then
    perform app.assert_admin(p_user);
    return jsonb_build_object('id', app.submit_payout_account((select r.owner_id from partners r where r.id = (p ->> 'partner_id')::uuid), p_user, p));
  when 'partner_payout_verify' then
    perform app.verify_payout_account((p ->> 'account_id')::uuid, p_user, p ->> 'method');
    return jsonb_build_object('ok', true);
  -- cars
  when 'vehicle_add' then return app.vehicle_add(p_user, p);
  when 'vehicle_set_supply' then return app.vehicle_set_supply(p_user, p);
  when 'vehicle_set_commission' then return app.vehicle_set_commission(p_user, p);
  when 'vehicle_retire' then return app.vehicle_retire(p_user, p);
  when 'vehicle_restore' then return app.vehicle_restore(p_user, p);
  when 'vehicle_delete' then return app.vehicle_delete(p_user, p);
  when 'vehicles_delete_samples' then return app.vehicles_delete_samples(p_user, p);
  when 'vehicle_delete_blockers' then
    perform app.assert_admin(p_user);
    return to_jsonb(app.vehicle_delete_blockers((p ->> 'vehicle_id')::uuid));
  when 'sample_cars' then
    perform app.assert_admin(p_user);
    return coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate,
                       'blockers', to_jsonb(app.vehicle_delete_blockers(v.id))) order by v.fleet_number nulls last) from vehicles v where v.is_sample), '[]'::jsonb);
  -- rentals added by hand
  when 'manual_rental_renters' then return app.manual_rental_renters(p_user, p ->> 'q');
  when 'manual_rental_quote' then return app.manual_rental_quote(p_user, p);
  when 'manual_rental_create' then return app.manual_rental_create(p_user, p);
  when 'manual_rental_card_result' then return app.manual_rental_card_result(p_user, p);
  when 'manual_rental_vehicles' then
    if app.manual_rental_role(p_user) is null then raise exception 'Not permitted' using errcode = '42501'; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'supply_type', v.supply_type,
                       'bookable', app.vehicle_bookable(v.id), 'retired', v.retired_at is not null,
                       'daily_rate_cents', (select r.daily_rate_cents from rate_cards r where r.vehicle_id = v.id and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now())))
                       order by app.vehicle_bookable(v.id) desc, v.make, v.model, v.year)
                      from vehicles v where v.status not in ('declined', 'exited') and (app.user_is_admin(p_user) or (v.retired_at is null and not coalesce(v.is_sample, false)))), '[]'::jsonb);
  when 'verify_driver_in_person' then return app.verify_driver_in_person(p_user, p);
  when 'bookings_by_supply' then return app.bookings_by_supply(p_user, p);
  -- the partner portal
  when 'supply_settings' then
    if app.manual_rental_role(p_user) is null then raise exception 'Not permitted' using errcode = '42501'; end if;
    return (select jsonb_build_object('partner_commission_bps', s.partner_commission_bps, 'manual_rental_va_payment_modes', to_jsonb(s.manual_rental_va_payment_modes),
                                      'manual_rental_va_promo', s.manual_rental_va_promo, 'manual_rental_past_max_days', s.manual_rental_past_max_days,
                                      'partner_insurance_warn_days', s.partner_insurance_warn_days, 'sample_cars', (select count(*) from vehicles where is_sample))
              from (select (app.settings()).*) s);
  when 'partner_agreement_facts' then
    perform app.assert_admin(p_user);
    return app.partner_agreement_facts((select r.owner_id from partners r where r.id = (p ->> 'partner_id')::uuid));
  else
    raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_0044;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_read', 'ops_do')
     and p_name in ('partners', 'partner', 'partner_save', 'partner_payout_account', 'partner_payout_verify', 'vehicle_add', 'vehicle_set_supply',
                    'vehicle_set_commission', 'vehicle_retire', 'vehicle_restore', 'vehicle_delete', 'vehicles_delete_samples', 'vehicle_delete_blockers',
                    'sample_cars', 'manual_rental_renters', 'manual_rental_quote', 'manual_rental_create', 'manual_rental_card_result',
                    'manual_rental_vehicles', 'verify_driver_in_person', 'bookings_by_supply', 'partner_agreement_facts', 'supply_settings') then
    perform app.door_begin(p_user, p_aal);
    if p_call = 'ops_read' and p_name not in ('partners', 'partner', 'vehicle_delete_blockers', 'sample_cars', 'manual_rental_renters', 'manual_rental_quote',
                                              'manual_rental_vehicles', 'bookings_by_supply', 'partner_agreement_facts', 'supply_settings') then
      raise exception 'Unknown read %', p_name using errcode = '22023';
    end if;
    if p_call = 'ops_do' and p_name in ('partners', 'partner', 'vehicle_delete_blockers', 'sample_cars', 'manual_rental_renters', 'manual_rental_quote',
                                        'manual_rental_vehicles', 'bookings_by_supply', 'partner_agreement_facts', 'supply_settings') then
      raise exception 'Unknown action %', p_name using errcode = '22023';
    end if;
    return app.ops46(p_user, p_call, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_0044(p_user, p_aal, p_call, p_name, p);
end $$;

-- The partner portal's own calls (the server, as the service role, with the signed-in person's id).
create or replace function public.partner_agreement_facts(p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.partner_agreement_facts(app.portal_owner_id(p_by)) $$;
create or replace function public.partner_agreement_open(p_by uuid, p_sha256 text, p_path text, p_template_version text) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.partner_agreement_open(p_by, p_sha256, p_path, p_template_version) $$;
create or replace function public.partner_agreement_state(p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.partner_agreement_state(p_by) $$;

-- ================================================================ 13. row-level security, privileges, audit
alter table partners enable row level security;
create policy admin_all on partners for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy own_read on partners for select to authenticated using (app.is_my_owner(owner_id));
revoke all on partners from anon, authenticated;
grant select on partners to authenticated;
grant all on partners to service_role;
grant usage on sequence partner_number_seq to service_role;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array[
              'company_owner_id', 'vehicles_supply_before', 'partner_commission_bps', 'generate_owner_invoice', 'issue_upfront_invoice',
              'build_owner_statement', 'booking_is_placeholder', 'partner_save', 'partner_row', 'partners_list', 'partner_detail', 'owner_kind_facts',
              'owner_portal_home', 'vehicle_add', 'vehicle_set_supply', 'vehicle_set_commission', 'vehicle_retire', 'vehicle_restore',
              'vehicle_delete_blockers', 'purge_rows', 'vehicle_delete', 'vehicles_delete_samples', 'partner_agreement_facts', 'partner_agreement_open',
              'partner_agreement_state', 'sign_request_sign', 'sign_request_attach', 'record_paper_signature', 'void_paper_signature',
              'manual_rental_role', 'manual_rental_renters', 'manual_rental_quote', 'manual_rental_create', 'manual_rental_card_result',
              'verify_driver_in_person', 'open_rental_agreement', 'manual_agreement_complete', 'record_signature', 'toll_read_import_lines', 'company_supply_section', 'build_company_statement', 'admin_read', 'bookings_by_supply', 'notification_payload', 'ops46', 'door']))
        or (n.nspname = 'public' and p.proname = any (array['partner_agreement_facts', 'partner_agreement_open', 'partner_agreement_state']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- pure functions and what the browser's own reads use keep their earlier grants
grant execute on function app.supply_label(text), app.paper_doc_kind(text), app.paper_doc_title(text) to service_role;
revoke execute on function app.supply_label(text) from public, anon, authenticated;

-- Each renamed function keeps its privileges; the function in its place gets the same (a browser session that could run
-- the old one may run the new one, as in 0044).
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('generate_owner_invoice_0029', 'generate_owner_invoice'), ('issue_upfront_invoice_0029', 'issue_upfront_invoice'),
                          ('build_owner_statement_0025', 'build_owner_statement'), ('owner_portal_home_0037', 'owner_portal_home'),
                          ('sign_request_sign_0044', 'sign_request_sign'), ('sign_request_attach_0044', 'sign_request_attach'),
                          ('record_paper_signature_0044', 'record_paper_signature'), ('void_paper_signature_0044', 'void_paper_signature'),
                          ('open_rental_agreement_0019', 'open_rental_agreement'), ('record_signature_0019', 'record_signature'),
                          ('toll_read_import_lines_0042', 'toll_read_import_lines'), ('build_company_statement_0037', 'build_company_statement'),
                          ('admin_read_0043', 'admin_read'), ('ntf_payload_0044', 'notification_payload'), ('door_0044', 'door')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;
-- the functions replaced with the same signature keep their grants (create or replace keeps them)
select app.attach_audit();
