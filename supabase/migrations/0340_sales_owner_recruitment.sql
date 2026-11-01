-- 0340: Sales staff bring in car owners and ask for a commission on each (Release 26, docs/changes/2026-11-06-sales-owner-recruitment.md).
-- The owner, November 1, 2026: "sales staff dont have a way to add vehicle owners and get commission on that", then: "dont set
-- any values for commission, set it so that the sales person has to request either a flat rate or a percent for each owner
-- they bring on".
--
-- 1. Sourced by. owners.recruited_by (0002) is the owner's "sourced by"; their cars follow the owner. It is set once: by a
--    salesperson's invitation (the signed link, or the address they invited, before the owner applied), by "Start it" (Add a car
--    for an owner, a new owner only), or by an Admin (admin_do owner_sourced_set, with a reason). Nobody else changes it after
--    the fact: a car customer service or fleet add for an owner already on file no longer makes them the owner's sourcer
--    (0067's rule kept for a new owner and for an Admin). owners.recruited_at and recruited_via say when and how; leads.sourced_by keeps the invitation.
-- 2. Invite: va_do sales_owner_invite {name, email, phone, asked} makes an owner lead (owner pipeline, 0217) credited to the
--    salesperson, without the automatic follow-ups; the website sends the invitation link (signed: the lead and the
--    salesperson). Each salesperson also has a personal link (signed: the salesperson). The application made from either
--    credits them (public.server_owner_sales_credit), as does an application from the address they invited earlier.
-- 3. Start it: va_do staff_add_owner_car from a Sales person (as_sales): the same form, the owner new (or one of theirs), "I
--    sourced this owner" always, no terms or invoices (those are Admin's), and always an application for an Admin to approve.
-- 4. Commission request, one per owner (owner_recruit_requests): the salesperson asks for a flat amount, or a percent of the
--    company's share of the owner's cars' rental revenue (default) or of the cars' rental revenue, for a number of months or
--    for as long as the car is with CarmaCars. No amount is set anywhere by default. They may revise it while it is pending.
--    An Admin approves it as asked, approves changed terms, or declines it, with an optional note (admin_do
--    owner_recruit_decide). Nothing accrues before it is approved.
-- 5. Once approved: a flat amount is earned at the owner's first paid rental (the first completed, paid rental of any of the
--    owner's cars); a percent accrues on each completed, paid rental of the owner's cars that ends after the approval, from the
--    month of the first one for the months approved (or with no end). Each is a staff commission (kind owner_recruit) in the
--    usual flow: pending approval, approved by an Admin, paid by hand; a refund or chargeback reverses it (taken off the next
--    payout once paid). One flat commission per owner, ever.
-- 6. Never on a CarmaCars-owned or partner car, a shareholder's car or a shareholder owner, nor on the salesperson's own car.
-- 7. A company expense, never a booking expense: Owner Revenue and the owner's statement are unchanged
--    (app.booking_staff_commission_cents leaves these out). Admin > Staff commissions shows "Paid from: a CarmaCars expense".
-- 8. Privacy: a salesperson reads only the owners they sourced (va_read sales_owners): the owner's name, the cars' names, the
--    stage (invited, applied, approved, car live, first paid rental), their request and their own commissions. No owner
--    contact details beyond the invitations they sent, no terms, revenue or statements. Row security: their own requests only.
-- 9. The door: va_read sales_owners; va_do sales_owner_invite, sales_owner_commission_request (and staff_add_owner_car,
--    staff_vehicle_document as Sales); admin_read sales_owners, owner_recruit_requests, owner_sourced; admin_do owner_recruit_decide,
--    owner_sourced_set. SCHEMA_MARKER 0341 (0341 carries the guide chapters). No applied migration is edited.
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

-- ================================================================ 1. sourced by
alter table owners
  add column if not exists recruited_at timestamptz,
  add column if not exists recruited_via text check (recruited_via is null or recruited_via in ('invite', 'link', 'started', 'staff_entry', 'admin', 'referral_code'));
comment on column owners.recruited_by is 'Sourced by (0002; 0340): the staff member who brought this owner in. Set once (an invitation, Start it, a referral code); only an Admin changes it afterwards (owner_sourced_set). The owner''s cars follow the owner.';
comment on column owners.recruited_via is 'How the owner was credited (0340): invite (the link a salesperson sent, or the address they invited), link (their personal link), started (Start it), staff_entry (Add a car for an owner), admin, referral_code';
update owners set recruited_at = coalesce(recruited_at, created_at), recruited_via = coalesce(recruited_via, 'referral_code') where recruited_by is not null and recruited_at is null;

alter table leads add column if not exists sourced_by uuid references users (id);
create index if not exists leads_sourced_by_idx on leads (sourced_by) where sourced_by is not null;
comment on column leads.sourced_by is 'The salesperson who invited this prospective owner (0340): their application is credited to them.';

drop trigger if exists owners_guard_sourced_by on owners;
create trigger owners_guard_sourced_by before update on owners
  for each row execute function app.guard_admin_columns('recruited_by', 'recruited_at', 'recruited_via');
drop trigger if exists leads_guard_sourced_by on leads;
create trigger leads_guard_sourced_by before update on leads
  for each row execute function app.guard_admin_columns('sourced_by');
drop trigger if exists owner_applications_guard_sourced_by on owner_applications;
create trigger owner_applications_guard_sourced_by before update on owner_applications
  for each row execute function app.guard_admin_columns('sourced_by');

-- ================================================================ 2. the requests
create table if not exists owner_recruit_requests (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null unique references owners (id),
  staff_id        uuid not null references users (id),
  kind            text not null check (kind in ('flat', 'percent')),
  amount_cents    bigint check (amount_cents is null or amount_cents between 1 and 1000000),
  rate_bps        integer check (rate_bps is null or rate_bps between 1 and 10000),
  base            text check (base is null or base in ('company_share', 'car_revenue')),
  months          integer check (months is null or months between 1 and 120),
  while_enrolled  boolean not null default false,
  note            text check (note is null or length(note) <= 1000),
  status          text not null default 'pending' check (status in ('pending', 'approved', 'declined')),
  revisions       integer not null default 0,
  a_kind          text check (a_kind is null or a_kind in ('flat', 'percent')),
  a_amount_cents  bigint check (a_amount_cents is null or a_amount_cents between 1 and 1000000),
  a_rate_bps      integer check (a_rate_bps is null or a_rate_bps between 1 and 10000),
  a_base          text check (a_base is null or a_base in ('company_share', 'car_revenue')),
  a_months        integer check (a_months is null or a_months between 1 and 120),
  a_while_enrolled boolean,
  admin_note      text check (admin_note is null or length(admin_note) <= 1000),
  changed         boolean not null default false,
  decided_at      timestamptz,
  decided_by      uuid references users (id),
  starts_month    date check (starts_month is null or starts_month = date_trunc('month', starts_month)::date),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check ((kind = 'flat') = (amount_cents is not null)),
  check ((kind = 'percent') = (rate_bps is not null and base is not null)),
  check (kind = 'flat' or ((months is not null) <> while_enrolled)),
  check ((status = 'approved') = (a_kind is not null)),
  check (status = 'pending' or decided_at is not null)
);
comment on table owner_recruit_requests is 'A salesperson''s commission request for an owner they brought in (0340), one per owner: a flat amount (earned at the owner''s first paid rental), or a percent of the company''s share (company_share) or of the rental revenue (car_revenue) of the owner''s cars, for months or while the car is with CarmaCars. No default amount. Revised while pending; an Admin approves (a_* the terms approved, changed when they differ from the ask) or declines. Accrues only once approved.';
create index if not exists owner_recruit_requests_staff_idx on owner_recruit_requests (staff_id, status);
alter table owner_recruit_requests enable row level security;
revoke all on owner_recruit_requests from anon, authenticated;
grant select on owner_recruit_requests to authenticated;
grant all on owner_recruit_requests to service_role;
drop policy if exists admin_all on owner_recruit_requests;
create policy admin_all on owner_recruit_requests for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop policy if exists own_select on owner_recruit_requests;
create policy own_select on owner_recruit_requests for select to authenticated using (staff_id = app.uid());
drop trigger if exists audit_owner_recruit_requests on owner_recruit_requests;
create trigger audit_owner_recruit_requests after insert or update or delete on owner_recruit_requests for each row execute function app.audit_row();

-- the commissions the requests earn: staff_commissions of kind owner_recruit, scheme recruit_flat or recruit_percent
alter table staff_commissions add column if not exists owner_recruit_request_id uuid references owner_recruit_requests (id);
alter table staff_commissions drop constraint if exists staff_commissions_kind_check;
alter table staff_commissions add constraint staff_commissions_kind_check check (kind in ('commission', 'clawback', 'adjustment', 'owner_recruit'));
alter table staff_commissions drop constraint if exists staff_commissions_check1;
alter table staff_commissions drop constraint if exists staff_commissions_clawback_of_check;
do $$
declare c record;
begin
  -- 0058's unnamed "kind = 'commission' or clawback_of is not null" check, whatever its generated name
  for c in select conname from pg_constraint where conrelid = 'staff_commissions'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%clawback_of IS NOT NULL%' and pg_get_constraintdef(oid) like '%''commission''%' loop
    execute format('alter table staff_commissions drop constraint %I', c.conname);
  end loop;
  for c in select conname from pg_constraint where conrelid = 'staff_commissions'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%scheme%' and pg_get_constraintdef(oid) like '%sales_tier%' loop
    execute format('alter table staff_commissions drop constraint %I', c.conname);
  end loop;
end $$;
alter table staff_commissions add constraint staff_commissions_clawback_of_check check (kind in ('commission', 'owner_recruit') or clawback_of is not null);
alter table staff_commissions add constraint staff_commissions_scheme_check check (scheme is null or scheme in ('flat', 'sales_tier', 'override', 'recruit_flat', 'recruit_percent'));
alter table staff_commissions add constraint staff_commissions_owner_recruit_check check ((kind = 'owner_recruit') = (owner_recruit_request_id is not null and scheme in ('recruit_flat', 'recruit_percent')) or kind in ('clawback', 'adjustment'));
create unique index if not exists staff_commissions_recruit_booking_idx on staff_commissions (owner_recruit_request_id, booking_id) where kind = 'owner_recruit';
create unique index if not exists staff_commissions_recruit_flat_idx on staff_commissions (owner_recruit_request_id) where kind = 'owner_recruit' and scheme = 'recruit_flat';
comment on column staff_commissions.owner_recruit_request_id is 'The owner commission request this commission comes from (0340, kind owner_recruit): its booking is the rental that earned it. A company expense, never deducted before Owner Revenue.';

-- ================================================================ 3. the rules
-- Why an owner's cars earn the person no owner commission (null: they may).
create or replace function app.owner_recruit_block(p_owner uuid, p_staff uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when o.id is null then 'Owner not found'
              when o.kind = 'company' then 'CarmaCars-owned cars earn no owner commission'
              when o.kind <> 'program' then 'A partner''s cars earn no owner commission'
              when o.is_shareholder then 'A shareholder''s cars earn no owner commission'
              when p_staff is not null and (o.user_id = p_staff or lower(btrim(o.email)) = (select lower(btrim(u.email)) from users u where u.id = p_staff))
                then 'Your own cars earn no owner commission' end
    from (select 1) one left join owners o on o.id = p_owner
$$;

-- An owner's stage for the salesperson: invited, applied, approved, car live, first paid rental (or declined).
create or replace function app.owner_recruit_stage(p_owner uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when exists (select 1 from bookings b join vehicles v on v.id = b.vehicle_id
                  where v.owner_id = p_owner and b.booking_type <> 'owner' and not b.is_placeholder and b.status in ('returned', 'closed')
                    and app.booking_paid_in_full(b.id)) then 'first_paid_rental'
    when exists (select 1 from vehicles v where v.owner_id = p_owner and v.retired_at is null and app.public_listing_row(v.id) is not null) then 'car_live'
    when exists (select 1 from owner_applications a where a.owner_id = p_owner and a.status = 'approved') then 'approved'
    when exists (select 1 from owner_applications a where a.owner_id = p_owner and a.status in ('new', 'waiting_on_owner')) then 'applied'
    when exists (select 1 from owner_applications a where a.owner_id = p_owner and a.status = 'declined') then 'declined'
    else 'applied' end
$$;

-- The terms in words: "CA$150 at the first paid rental", "10% of the company's share for 12 months".
create or replace function app.owner_recruit_words(p_kind text, p_amount bigint, p_rate integer, p_base text, p_months integer, p_while boolean) returns text
language sql immutable as $$
  select case when p_kind = 'flat' then 'CA' || app.fmt_money(p_amount) || ' at the first paid rental'
              when p_kind = 'percent' then app.bps_words(p_rate) || ' of ' || case p_base when 'car_revenue' then 'the cars'' rental revenue' else 'the company''s share' end
                   || case when p_while then ' while the car is with us' when p_months = 1 then ' for 1 month' else ' for ' || p_months || ' months' end end
$$;

-- ================================================================ 4. credit
-- An application credited to a salesperson: the application, the lead and, for a new owner, the owner. The first credit
-- stands; an owner already on file is credited only by an Admin. p_via: invite, link.
create or replace function app.owner_sales_credit(p_application uuid, p_staff uuid, p_lead uuid, p_via text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a owner_applications;
  o owners;
  v_name text := (select coalesce(full_name, email) from users where id = p_staff);
  v_new boolean;
begin
  if p_staff is null or not app.user_va_has(p_staff, 'sales') then return jsonb_build_object('credited', false, 'reason', 'not a salesperson'); end if;
  select * into a from owner_applications where id = p_application for update;
  if a.id is null then return jsonb_build_object('credited', false, 'reason', 'no application'); end if;
  select * into o from owners where id = a.owner_id for update;
  if a.sourced_by is not null and a.sourced_by is distinct from p_staff then return jsonb_build_object('credited', false, 'reason', 'credited already'); end if;
  if o.recruited_by is not null and o.recruited_by is distinct from p_staff then return jsonb_build_object('credited', false, 'reason', 'owner credited already'); end if;
  -- a new owner: nothing before this application
  v_new := not exists (select 1 from owner_applications x where x.owner_id = o.id and x.id <> a.id and x.created_at < a.created_at);
  update owner_applications set sourced_by = p_staff, lead_id = coalesce(lead_id, p_lead) where id = a.id;
  if p_lead is not null then
    update leads set owner_id = coalesce(owner_id, o.id), updated_at = now() where id = p_lead and kind in ('owner_program', 'owner_recruit');
  end if;
  if v_new and o.recruited_by is null then
    update owners set recruited_by = p_staff, recruited_at = now(), recruited_via = p_via where id = o.id;
  end if;
  insert into owner_application_notes (application_id, body, kind, created_by)
  values (a.id, case when v_new or o.recruited_by = p_staff then format('Sourced by %s (%s).', v_name, case p_via when 'link' then 'their personal link' else 'their invitation' end)
                     else format('Applied through %s''s invitation. The owner was on file already: an Admin decides who sourced them.', v_name) end, 'note', null);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (null, 'owner_sales_credit', 'owner_applications', a.id::text, jsonb_build_object('staff', p_staff, 'lead', p_lead, 'via', p_via, 'owner_credited', v_new and o.recruited_by is null));
  return jsonb_build_object('credited', true, 'owner_credited', v_new and o.recruited_by is null);
end $$;

-- An application from an address a salesperson invited before it came in credits them (the latest invitation, 90 days).
create or replace function app.owner_applications_sales_match() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  l leads;
  v_email text;
begin
  if new.sourced_by is not null then return null; end if;
  select lower(btrim(email)) into v_email from owners where id = new.owner_id;
  if v_email is null then return null; end if;
  select * into l from leads x
   where x.sourced_by is not null and x.kind = 'owner_program' and lower(btrim(x.email)) = v_email
     and x.created_at <= new.created_at and x.created_at > new.created_at - interval '90 days'
     and (x.owner_id is null or x.owner_id = new.owner_id) and coalesce(x.pipeline_stage, 'new') <> 'lost'
   order by x.created_at desc limit 1;
  if l.id is not null then perform app.owner_sales_credit(new.id, l.sourced_by, l.id, 'invite'); end if;
  return null;
end $$;
drop trigger if exists owner_applications_sales_match on owner_applications;
create trigger owner_applications_sales_match after insert on owner_applications for each row execute function app.owner_applications_sales_match();

-- The website after an application made from a signed invitation (the token checked there): the salesperson in it.
create or replace function public.server_owner_sales_credit(p_application uuid, p_staff uuid, p_lead uuid default null) returns jsonb
language sql volatile security definer set search_path = public, app as $$
  select app.owner_sales_credit(p_application, p_staff, p_lead, case when p_lead is null then 'link' else 'invite' end)
$$;

-- ================================================================ 5. Sales: invite, start it, ask
create or replace function app.sales_owner_assert(p_by uuid) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.user_va_has(p_by, 'sales') then raise exception 'Sales staff only' using errcode = '42501'; end if;
end $$;

-- p: {name, email, phone, asked: true}. The lead for the invitation the website then sends.
create or replace function app.sales_owner_invite(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_name text := nullif(btrim(coalesce(p ->> 'name', '')), '');
  v_email text := nullif(lower(btrim(coalesce(p ->> 'email', ''))), '');
  v_phone text := nullif(btrim(coalesce(p ->> 'phone', '')), '');
  l leads;
  o owners;
begin
  perform app.sales_owner_assert(p_by);
  if v_name is null then raise exception 'Enter the owner''s name' using errcode = '22023'; end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter the owner''s email address: the invitation goes there' using errcode = '22023'; end if;
  if not coalesce((p ->> 'asked')::boolean, false) then raise exception 'Send it only to an owner who asked you for it: tick the box' using errcode = '22023'; end if;
  select * into o from owners where lower(btrim(email)) = v_email limit 1;
  if o.id is not null then raise exception 'This owner is on file already. Ask an Admin if you brought them in.' using errcode = '23505'; end if;
  select * into l from leads x where x.sourced_by is not null and x.sourced_by <> p_by and x.kind = 'owner_program' and lower(btrim(x.email)) = v_email
     and x.created_at > now() - interval '90 days' and coalesce(x.pipeline_stage, 'new') <> 'lost' limit 1;
  if l.id is not null then raise exception 'Another salesperson invited this owner on %. Ask an Admin.', to_char(app.local_date(l.created_at), 'FMMonth FMDD') using errcode = '23505'; end if;
  select * into l from leads x where x.sourced_by = p_by and x.kind = 'owner_program' and lower(btrim(x.email)) = v_email order by x.created_at desc limit 1;
  if l.id is null then
    insert into leads (kind, name, email, phone, source, assigned_to, pipeline_source, sourced_by, payload, consent_text, consent_at)
    values ('owner_program', v_name, v_email, v_phone, 'manual', p_by, 'manual', p_by,
            jsonb_build_object('added_by', p_by, 'invited_by_sales', p_by),
            'Asked the salesperson for the owner program link (recorded by them)', now())
    returning * into l;
    update leads set followup_stopped_at = now(), followup_next_at = null, followup_stop_reason = 'Invited by Sales: the invitation email only'
     where id = l.id returning * into l;
  else
    update leads set name = v_name, phone = coalesce(v_phone, phone), updated_at = now() where id = l.id returning * into l;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'sales_owner_invite', 'leads', l.id::text, jsonb_build_object('email', v_email));
  return jsonb_build_object('lead_id', l.id, 'name', l.name, 'email', l.email, 'staff_id', p_by);
end $$;

-- 0067's Add a car for an owner, with "sourced by" set once: a car customer service or fleet add for an owner already on
-- file no longer makes them the owner's sourcer (an Admin still may). A new owner credited is recorded with when and how.
alter function app.staff_add_owner_car(uuid, jsonb) rename to staff_add_owner_car_pre0340;
create function app.staff_add_owner_car(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid := nullif(p ->> 'owner_id', '')::uuid;
  v_before uuid;
  v_out jsonb;
  o owners;
begin
  if v_owner is not null then select recruited_by into v_before from owners where id = v_owner; end if;
  v_out := app.staff_add_owner_car_pre0340(p_by, p);
  select * into o from owners where id = (v_out ->> 'owner_id')::uuid;
  if v_owner is not null and v_before is null and o.recruited_by is not null and not app.user_is_admin(p_by) then
    update owners set recruited_by = null where id = o.id;
  elsif v_owner is null and o.recruited_by is not null and o.recruited_at is null then
    update owners set recruited_at = now(), recruited_via = case when coalesce(current_setting('app.sales_start', true), '') = p_by::text then 'started' else 'staff_entry' end where id = o.id;
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.staff_add_owner_car(uuid, jsonb)'::regprocedure, 'app.staff_add_owner_car_pre0340(uuid, jsonb)'::regprocedure);

-- Start it: a salesperson enters the owner and the car for the owner. A new owner (or one they brought in), always sourced
-- by them, no terms or invoices, and always an application for an Admin. 0067's check is for customer service and fleet:
-- the call goes through it as the salesperson for this one entry.
create or replace function app.sales_add_owner_car(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid := nullif(p ->> 'owner_id', '')::uuid;
  v_out jsonb;
begin
  perform app.sales_owner_assert(p_by);
  if v_owner is not null and (select recruited_by from owners where id = v_owner) is distinct from p_by then
    raise exception 'You can add a car only for a new owner or an owner you brought in' using errcode = '42501';
  end if;
  if v_owner is null and nullif(lower(btrim(coalesce(p #>> '{owner,email}', ''))), '') is not null
     and exists (select 1 from owners o where lower(btrim(o.email)) = lower(btrim(p #>> '{owner,email}'))) then
    raise exception 'This owner is on file already. Ask an Admin if you brought them in.' using errcode = '23505';
  end if;
  perform set_config('app.field_as_cs', p_by::text, true);
  perform set_config('app.sales_start', p_by::text, true);
  v_out := app.staff_add_owner_car(p_by, (coalesce(p, '{}'::jsonb) - 'plan' - 'approve' - 'rates' - 'as_sales' - '_va') || jsonb_build_object('sourced', true));
  perform set_config('app.field_as_cs', '', true);
  perform set_config('app.sales_start', '', true);
  return v_out;
end $$;

-- A document for a car the salesperson just added (the permit photo and the rest).
create or replace function app.sales_vehicle_document(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  perform app.sales_owner_assert(p_by);
  if not exists (select 1 from vehicles v join owners o on o.id = v.owner_id
                  where v.id = nullif(p ->> 'vehicle_id', '')::uuid and v.added_by = p_by and o.recruited_by = p_by) then
    raise exception 'Only for a car you added for an owner you brought in' using errcode = '42501';
  end if;
  perform set_config('app.field_as_cs', p_by::text, true);
  v_id := app.staff_register_vehicle_document(p_by, coalesce(p, '{}'::jsonb) - 'as_sales' - '_va');
  perform set_config('app.field_as_cs', '', true);
  return jsonb_build_object('id', v_id);
end $$;

-- The request. p: {owner_id, kind flat | percent, amount_cents | rate_bps, base, months | while_enrolled (or duration
-- months | while), note}. What does not belong to the kind is left out (a form sends every field).
create or replace function app.owner_recruit_terms(p jsonb, p_prefix text default '') returns jsonb
language plpgsql immutable as $$
declare
  v_kind text := nullif(p ->> (p_prefix || 'kind'), '');
  v_amount bigint := nullif(p ->> (p_prefix || 'amount_cents'), '')::bigint;
  v_rate integer := nullif(p ->> (p_prefix || 'rate_bps'), '')::integer;
  v_base text := coalesce(nullif(p ->> (p_prefix || 'base'), ''), 'company_share');
  v_months integer := nullif(p ->> (p_prefix || 'months'), '')::integer;
  v_while boolean := coalesce(nullif(p ->> (p_prefix || 'while_enrolled'), '')::boolean, p ->> (p_prefix || 'duration') = 'while', false);
begin
  if v_kind not in ('flat', 'percent') or v_kind is null then raise exception 'Choose a flat amount or a percent' using errcode = '22023'; end if;
  if v_kind = 'flat' then
    if v_amount is null or v_amount < 1 or v_amount > 1000000 then raise exception 'Enter the flat amount in dollars, up to CA$10,000' using errcode = '22023'; end if;
    return jsonb_build_object('kind', 'flat', 'amount_cents', v_amount, 'rate_bps', null, 'base', null, 'months', null, 'while_enrolled', false);
  end if;
  if v_rate is null or v_rate < 1 or v_rate > 10000 then raise exception 'Enter the percent, from 0.01 to 100' using errcode = '22023'; end if;
  if v_base not in ('company_share', 'car_revenue') then raise exception 'Choose what the percent is of' using errcode = '22023'; end if;
  if not v_while and (v_months is null or v_months < 1 or v_months > 120) then
    raise exception 'Say for how long: a number of months (1 to 120) or as long as the car is with us' using errcode = '22023';
  end if;
  return jsonb_build_object('kind', 'percent', 'amount_cents', null, 'rate_bps', v_rate, 'base', v_base, 'months', case when v_while then null else v_months end, 'while_enrolled', v_while);
end $$;

create or replace function app.owner_recruit_request_json(r owner_recruit_requests) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when r.id is null then null else jsonb_build_object('id', r.id, 'status', r.status, 'kind', r.kind, 'amount_cents', r.amount_cents, 'rate_bps', r.rate_bps,
    'base', r.base, 'months', r.months, 'while_enrolled', r.while_enrolled, 'note', r.note, 'revisions', r.revisions,
    'asked', app.owner_recruit_words(r.kind, r.amount_cents, r.rate_bps, r.base, r.months, r.while_enrolled),
    'approved', case when r.status = 'approved' then app.owner_recruit_words(r.a_kind, r.a_amount_cents, r.a_rate_bps, r.a_base, r.a_months, r.a_while_enrolled) end,
    'changed', r.changed, 'admin_note', r.admin_note, 'decided_at', r.decided_at, 'created_at', r.created_at, 'updated_at', r.updated_at,
    'starts_month', r.starts_month) end
$$;

create or replace function app.sales_owner_commission_request(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  t jsonb;
  r owner_recruit_requests;
  v_block text;
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
begin
  perform app.sales_owner_assert(p_by);
  select * into o from owners where id = nullif(p ->> 'owner_id', '')::uuid;
  if o.id is null or o.recruited_by is distinct from p_by then raise exception 'You can ask only for an owner you brought in' using errcode = '42501'; end if;
  v_block := app.owner_recruit_block(o.id, p_by);
  if v_block is not null then raise exception '%', v_block using errcode = '23514'; end if;
  t := app.owner_recruit_terms(p);
  select * into r from owner_recruit_requests where owner_id = o.id for update;
  if r.id is not null and r.status <> 'pending' then
    raise exception 'An Admin has decided on this request. Ask an Admin to change it.' using errcode = '23514';
  end if;
  if r.id is not null and r.staff_id <> p_by then raise exception 'You can ask only for an owner you brought in' using errcode = '42501'; end if;
  if r.id is null then
    insert into owner_recruit_requests (owner_id, staff_id, kind, amount_cents, rate_bps, base, months, while_enrolled, note)
    values (o.id, p_by, t ->> 'kind', (t ->> 'amount_cents')::bigint, (t ->> 'rate_bps')::integer, t ->> 'base', (t ->> 'months')::integer, (t ->> 'while_enrolled')::boolean, v_note)
    returning * into r;
  else
    update owner_recruit_requests set kind = t ->> 'kind', amount_cents = (t ->> 'amount_cents')::bigint, rate_bps = (t ->> 'rate_bps')::integer, base = t ->> 'base',
           months = (t ->> 'months')::integer, while_enrolled = (t ->> 'while_enrolled')::boolean, note = v_note, revisions = revisions + 1, updated_at = now()
     where id = r.id returning * into r;
  end if;
  perform app.raise_task(p_type => 'owner_recruit_request', p_queue => 'admin',
    p_title => format('Owner commission request: %s for %s', (select coalesce(full_name, email) from users where id = p_by), o.legal_name),
    p_detail => format('%s asks %s for bringing in %s. Approve it, change it or decline it under Money, Staff commissions, Owner requests.',
                       (select coalesce(full_name, email) from users where id = p_by), app.owner_recruit_words(r.kind, r.amount_cents, r.rate_bps, r.base, r.months, r.while_enrolled), o.legal_name),
    p_owner => o.id, p_related_table => 'owner_recruit_requests', p_related_id => r.id, p_dedupe => 'owner_recruit_request:' || r.id);
  return app.owner_recruit_request_json(r);
end $$;

-- ================================================================ 6. the commissions
-- The rentals of an owner's cars that count: completed, not an owner booking or a placeholder, on a car that is neither
-- CarmaCars', a partner's nor a shareholder's.
create or replace function app.owner_recruit_bookings(p_owner uuid) returns table (booking_id uuid, ended_at timestamptz, paid boolean)
language sql stable security definer set search_path = public, app as $$
  select b.id, coalesce(b.checked_in_at, b.return_at), app.booking_paid_in_full(b.id)
    from bookings b join vehicles v on v.id = b.vehicle_id join owners o on o.id = v.owner_id
   where v.owner_id = p_owner and o.kind = 'program' and not o.is_shareholder and not v.is_shareholder_owned
     and b.booking_type <> 'owner' and not b.is_placeholder and b.status in ('returned', 'closed')
$$;

-- One commission of a request on one rental, in step with it: earned (pending approval) when the rental is paid in full;
-- not due any more (p_reason): void, reversed, or a clawback once paid; a change of amount after approval goes back to
-- approval; after payment the difference is a clawback or an adjustment.
create or replace function app.owner_recruit_row(r owner_recruit_requests, p_booking uuid, p_scheme text, p_month date, p_base bigint, p_rate integer,
                                                 p_amount bigint, p_earned boolean, p_reason text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  c staff_commissions;
  v_net bigint;
begin
  select * into c from staff_commissions where owner_recruit_request_id = r.id and booking_id = p_booking and kind = 'owner_recruit' for update;
  if c.id is null then
    if p_reason is not null then return; end if;
    insert into staff_commissions (booking_id, staff_id, kind, scheme, owner_recruit_request_id, month, rental_days, base_cents, rate_bps, amount_cents, status, earned_at, work_mode)
    values (p_booking, r.staff_id, 'owner_recruit', p_scheme, r.id, p_month, 0, coalesce(p_base, 0), coalesce(p_rate, 0), p_amount,
            case when p_earned then 'pending_approval' else 'accruing' end, case when p_earned then now() end,
            (select sp.sales_work_mode from staff_profiles sp where sp.user_id = r.staff_id));
    return;
  end if;
  if c.admin_reversed then return; end if;
  if c.status = 'paid' then
    select c.amount_cents + coalesce(sum(x.amount_cents) filter (where x.status not in ('reversed', 'void')), 0) into v_net from staff_commissions x where x.clawback_of = c.id;
    if p_reason is not null then
      if c.reversed_at is null then update staff_commissions set reason = p_reason, reversed_at = now(), updated_at = now() where id = c.id; end if;
      if v_net > 0 then
        insert into staff_commissions (booking_id, staff_id, kind, clawback_of, scheme, month, base_cents, rate_bps, amount_cents, status, reason, earned_at, work_mode)
        values (c.booking_id, c.staff_id, 'clawback', c.id, c.scheme, c.month, c.base_cents, c.rate_bps, -v_net, 'approved', 'Reversed after it was paid: ' || p_reason, now(), c.work_mode);
      end if;
    elsif p_amount < v_net then
      insert into staff_commissions (booking_id, staff_id, kind, clawback_of, scheme, month, base_cents, rate_bps, amount_cents, status, reason, earned_at, work_mode)
      values (c.booking_id, c.staff_id, 'clawback', c.id, c.scheme, c.month, coalesce(p_base, 0), coalesce(p_rate, 0), p_amount - v_net, 'approved', 'A refund lowered it after it was paid', now(), c.work_mode);
    elsif p_amount > v_net and c.reversed_at is null then
      insert into staff_commissions (booking_id, staff_id, kind, clawback_of, scheme, month, base_cents, rate_bps, amount_cents, status, reason, earned_at, work_mode)
      values (c.booking_id, c.staff_id, 'adjustment', c.id, c.scheme, c.month, coalesce(p_base, 0), coalesce(p_rate, 0), p_amount - v_net, 'pending_approval', 'The base rose after it was paid', now(), c.work_mode);
    end if;
    return;
  end if;
  if p_reason is not null then
    if c.status not in ('void', 'reversed') then
      update staff_commissions set status = case when c.status = 'accruing' then 'void' else 'reversed' end, reason = p_reason, reversed_at = now(), updated_at = now() where id = c.id;
    end if;
    return;
  end if;
  update staff_commissions set
         staff_id = r.staff_id, month = p_month, base_cents = coalesce(p_base, 0), rate_bps = coalesce(p_rate, 0), amount_cents = p_amount,
         status = case when c.status = 'approved' and c.amount_cents = p_amount and p_earned then 'approved' when p_earned then 'pending_approval' else 'accruing' end,
         approved_at = case when c.status = 'approved' and c.amount_cents = p_amount and p_earned then approved_at end,
         approved_by = case when c.status = 'approved' and c.amount_cents = p_amount and p_earned then approved_by end,
         note = case when c.status = 'approved' and (c.amount_cents <> p_amount or not p_earned) then 'The amount changed after it was approved: approve it again' else note end,
         earned_at = case when p_earned then coalesce(earned_at, now()) end,
         reason = null, reversed_at = null, reversed_by = null, updated_at = now()
   where id = c.id;
end $$;

-- Every commission of an owner's approved request, in step with the owner's rentals.
create or replace function app.owner_recruit_sync_owner(p_owner uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  r owner_recruit_requests;
  b record;
  bk bookings;
  v_first uuid;
  v_month date;
  v_base bigint;
  v_amount bigint;
  v_reason text;
  v_earned boolean;
  c staff_commissions;
  v_end date;
begin
  select * into r from owner_recruit_requests where owner_id = p_owner and status = 'approved' for update;
  if r.id is null then return; end if;
  if app.owner_recruit_block(p_owner, r.staff_id) is not null then
    for c in select * from staff_commissions x where x.owner_recruit_request_id = r.id and x.kind = 'owner_recruit' loop
      perform app.owner_recruit_row(r, c.booking_id, c.scheme, c.month, c.base_cents, c.rate_bps, c.amount_cents, false, app.owner_recruit_block(p_owner, r.staff_id));
    end loop;
    return;
  end if;
  if r.a_kind = 'flat' then
    -- the owner's first paid rental, whenever it was; a flat commission not paid yet follows it if that rental stops counting
    select x.booking_id into v_first from app.owner_recruit_bookings(p_owner) x
     where x.paid and not exists (select 1 from disputes d where d.booking_id = x.booking_id and d.status = 'lost')
       and app.commission_base_cents(x.booking_id) > 0
     order by x.ended_at, x.booking_id limit 1;
    select * into c from staff_commissions where owner_recruit_request_id = r.id and kind = 'owner_recruit' and scheme = 'recruit_flat' for update;
    if c.id is not null and c.status = 'paid' then
      v_reason := case when not exists (select 1 from app.owner_recruit_bookings(p_owner) x where x.booking_id = c.booking_id) then 'The first paid rental stopped counting'
                       when exists (select 1 from disputes d where d.booking_id = c.booking_id and d.status = 'lost') then 'Charged back' end;
      perform app.owner_recruit_row(r, c.booking_id, 'recruit_flat', c.month, 0, 0, r.a_amount_cents, true, v_reason);
      return;
    end if;
    if c.id is not null and v_first is not null and c.booking_id <> v_first and not c.admin_reversed then
      update staff_commissions set booking_id = v_first, updated_at = now() where id = c.id;
    end if;
    if v_first is null then
      if c.id is not null then perform app.owner_recruit_row(r, c.booking_id, 'recruit_flat', c.month, 0, 0, r.a_amount_cents, false, 'No paid rental yet'); end if;
      return;
    end if;
    select * into bk from bookings where id = v_first;
    v_month := greatest(app.month_start(app.local_date(coalesce(bk.checked_in_at, bk.return_at))), app.month_start(app.local_date(r.decided_at)));
    v_earned := not exists (select 1 from disputes d where d.booking_id = v_first and d.status in ('open', 'evidence_submitted'));
    perform app.owner_recruit_row(r, v_first, 'recruit_flat', v_month, 0, 0, r.a_amount_cents, v_earned, null);
    return;
  end if;
  -- a percent: from the month of the first rental ending after the approval, for the months approved (or with no end)
  if r.starts_month is null then
    select app.month_start(app.local_date(min(x.ended_at))) into v_month from app.owner_recruit_bookings(p_owner) x where x.ended_at >= r.decided_at;
    if v_month is null then return; end if;
    update owner_recruit_requests set starts_month = v_month, updated_at = now() where id = r.id returning * into r;
  end if;
  v_end := case when r.a_while_enrolled then null else (r.starts_month + make_interval(months => r.a_months))::date end;
  for b in select x.booking_id, x.ended_at, x.paid from app.owner_recruit_bookings(p_owner) x
            where x.ended_at >= r.decided_at and app.month_start(app.local_date(x.ended_at)) >= r.starts_month
              and (v_end is null or app.local_date(x.ended_at) < v_end) loop
    v_month := app.month_start(app.local_date(b.ended_at));
    v_reason := case when exists (select 1 from disputes d where d.booking_id = b.booking_id and d.status = 'lost') then 'Charged back' end;
    v_base := case when r.a_base = 'car_revenue' then app.commission_base_cents(b.booking_id)
                   else (select s.company_share_cents from booking_splits s where s.booking_id = b.booking_id) end;
    if v_reason is null and b.paid and v_base is not null and v_base <= 0 then v_reason := 'Refunded'; end if;
    v_amount := public.calc_bps(coalesce(v_base, 0), r.a_rate_bps);
    v_earned := b.paid and v_base is not null and not exists (select 1 from disputes d where d.booking_id = b.booking_id and d.status in ('open', 'evidence_submitted'));
    perform app.owner_recruit_row(r, b.booking_id, 'recruit_percent', v_month, v_base, r.a_rate_bps, v_amount, v_earned, v_reason);
  end loop;
  -- a rental that stopped counting (cancelled after all, moved to another owner's car)
  for c in select * from staff_commissions x where x.owner_recruit_request_id = r.id and x.kind = 'owner_recruit'
              and x.booking_id not in (select y.booking_id from app.owner_recruit_bookings(p_owner) y) loop
    perform app.owner_recruit_row(r, c.booking_id, c.scheme, c.month, c.base_cents, c.rate_bps, c.amount_cents, false, 'The rental no longer counts');
  end loop;
end $$;

create or replace function app.owner_recruit_sync_booking(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid;
begin
  select v.owner_id into v_owner from bookings b join vehicles v on v.id = b.vehicle_id where b.id = p_booking;
  if v_owner is not null and exists (select 1 from owner_recruit_requests r where r.owner_id = v_owner and r.status = 'approved') then
    perform app.owner_recruit_sync_owner(v_owner);
  end if;
  -- a rental that moved to another owner's car
  for v_owner in select distinct r.owner_id from staff_commissions c join owner_recruit_requests r on r.id = c.owner_recruit_request_id
                  where c.booking_id = p_booking and c.kind = 'owner_recruit' and r.owner_id is distinct from v_owner loop
    perform app.owner_recruit_sync_owner(v_owner);
  end loop;
end $$;

-- 0058's sync of a booking's commissions (called by its payments, refunds, disputes, statements and lines) also brings the
-- owner commissions in step.
alter function app.commission_sync(uuid) rename to commission_sync_pre0340;
create function app.commission_sync(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.commission_sync_pre0340(p_booking);
  perform app.owner_recruit_sync_booking(p_booking);
end $$;
select pg_temp.copy_grants('app.commission_sync(uuid)'::regprocedure, 'app.commission_sync_pre0340(uuid)'::regprocedure);

-- the booking itself (0058's trigger runs only for a sourced booking) and its split (the company's share)
create or replace function app.owner_recruit_trigger() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.owner_recruit_sync_booking(case when tg_table_name = 'bookings' then (to_jsonb(new) ->> 'id')::uuid else (to_jsonb(new) ->> 'booking_id')::uuid end);
  return null;
end $$;
drop trigger if exists bookings_owner_recruit on bookings;
create trigger bookings_owner_recruit after insert or update of status, checked_in_at, return_at, rental_charge_cents, discount_cents, is_placeholder, vehicle_id, booking_type on bookings
  for each row execute function app.owner_recruit_trigger();
drop trigger if exists booking_splits_owner_recruit on booking_splits;
create trigger booking_splits_owner_recruit after insert or update of company_share_cents on booking_splits
  for each row execute function app.owner_recruit_trigger();

-- every hour, every approved request (a safety net for anything the triggers did not see)
create or replace function app.job_owner_recruit() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  n integer := 0;
begin
  for r in select owner_id from owner_recruit_requests where status = 'approved' loop
    perform app.owner_recruit_sync_owner(r.owner_id);
    n := n + 1;
  end loop;
  return n;
end $$;
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-owner-recruit', '41 * * * *', $q$select app.job_owner_recruit()$q$);
  end if;
end $$;

-- A company expense, never a booking expense: the owner commissions stay out of what is deducted before Owner Revenue.
create or replace function app.booking_staff_commission_cents(p_booking uuid) returns bigint
language sql stable security definer set search_path = public, app as $$
  select greatest(coalesce(sum(c.amount_cents), 0), 0)::bigint + app.booking_referral_partner_cents(p_booking)
    from staff_commissions c where c.booking_id = p_booking and c.status not in ('void', 'reversed')
     and coalesce(c.scheme, '') not in ('recruit_flat', 'recruit_percent')
$$;

-- An Admin reverses an owner commission as any other (0058 reverses only kind commission).
alter function app.commission_reverse(uuid, jsonb) rename to commission_reverse_pre0340;
create function app.commission_reverse(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c staff_commissions;
  r owner_recruit_requests;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  perform app.assert_admin(p_by);
  select * into c from staff_commissions where id = nullif(p ->> 'id', '')::uuid for update;
  if c.kind is distinct from 'owner_recruit' then return app.commission_reverse_pre0340(p_by, p); end if;
  if v_reason is null then raise exception 'Say why the commission is reversed' using errcode = '22023'; end if;
  if c.status in ('void', 'reversed') or c.reversed_at is not null then raise exception 'This commission is already reversed' using errcode = '23514'; end if;
  select * into r from owner_recruit_requests where id = c.owner_recruit_request_id;
  perform app.owner_recruit_row(r, c.booking_id, c.scheme, c.month, c.base_cents, c.rate_bps, c.amount_cents, false, v_reason);
  update staff_commissions set admin_reversed = true, reversed_by = p_by where id = c.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'commission_reverse', 'staff_commissions', c.id::text, jsonb_build_object('reason', v_reason, 'status_before', c.status));
  return jsonb_build_object('id', c.id, 'reversed', true);
end $$;
select pg_temp.copy_grants('app.commission_reverse(uuid, jsonb)'::regprocedure, 'app.commission_reverse_pre0340(uuid, jsonb)'::regprocedure);

-- The commission lists say what an owner commission is for, and Admin's that it is a CarmaCars expense.
create or replace function app.owner_recruit_row_label(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('owner', o.legal_name, 'what', 'Owner brought in: ' || o.legal_name || ' (' ||
           case when c.scheme = 'recruit_flat' then 'flat, first paid rental' else app.bps_words(c.rate_bps) || ' of ' || case r.a_base when 'car_revenue' then 'the rental revenue' else 'the company''s share' end end || ')')
    from staff_commissions c0 join staff_commissions c on c.id = coalesce(c0.clawback_of, c0.id)
    join owner_recruit_requests r on r.id = c.owner_recruit_request_id join owners o on o.id = r.owner_id
   where c0.id = p_id
$$;

alter function app.commission_admin(uuid, jsonb) rename to commission_admin_pre0340;
create function app.commission_admin(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.commission_admin_pre0340(p_by, p);
begin
  return v || jsonb_build_object('rows', coalesce((select jsonb_agg(case when l.x is null then e else e || l.x || jsonb_build_object('paid_from', 'carmacars_expense') end order by n)
              from jsonb_array_elements(v -> 'rows') with ordinality as q(e, n) left join lateral (select app.owner_recruit_row_label((e ->> 'id')::uuid) x) l on true), '[]'::jsonb),
    'requests_pending', (select count(*) from owner_recruit_requests where status = 'pending'));
end $$;
select pg_temp.copy_grants('app.commission_admin(uuid, jsonb)'::regprocedure, 'app.commission_admin_pre0340(uuid, jsonb)'::regprocedure);

alter function app.staff_commissions_json(uuid) rename to staff_commissions_json_pre0340;
create function app.staff_commissions_json(p_staff uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.staff_commissions_json_pre0340(p_staff);
begin
  return v || jsonb_build_object('rows', coalesce((select jsonb_agg(case when l.x is null then e else e || l.x end order by n)
              from jsonb_array_elements(v -> 'rows') with ordinality as q(e, n) left join lateral (select app.owner_recruit_row_label((e ->> 'id')::uuid) x) l on true), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.staff_commissions_json(uuid)'::regprocedure, 'app.staff_commissions_json_pre0340(uuid)'::regprocedure);

-- ================================================================ 7. reads
-- A salesperson's owners (an Admin: anyone's, p.staff): the stage, the cars by name, their request and their own
-- commissions. Nothing else about the owner.
create or replace function app.sales_owners_read(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_staff uuid := p_by;
  v_rows jsonb;
  v_invites jsonb;
begin
  if app.user_is_admin(p_by) and nullif(p ->> 'staff', '') is not null then v_staff := (p ->> 'staff')::uuid;
  else perform app.sales_owner_assert(p_by); end if;
  select coalesce(jsonb_agg(x order by x ->> 'since' desc), '[]'::jsonb) into v_rows from (
    select jsonb_build_object('owner_id', o.id, 'name', o.legal_name, 'since', coalesce(o.recruited_at, o.created_at), 'via', o.recruited_via,
             'stage', app.owner_recruit_stage(o.id), 'blocked', app.owner_recruit_block(o.id, v_staff),
             'cars', coalesce((select jsonb_agg(jsonb_build_object('name', nullif(btrim(concat_ws(' ', v.year, v.make, v.model)), ''),
                         'live', v.retired_at is null and app.public_listing_row(v.id) is not null) order by v.created_at)
                       from vehicles v where v.owner_id = o.id), '[]'::jsonb),
             'request', (select app.owner_recruit_request_json(r) from owner_recruit_requests r where r.owner_id = o.id and r.staff_id = v_staff),
             'earned_cents', coalesce((select sum(c.amount_cents) from staff_commissions c join owner_recruit_requests r on r.id = c.owner_recruit_request_id
                                       where r.owner_id = o.id and c.staff_id = v_staff and c.status in ('pending_approval', 'approved', 'paid') and c.reversed_at is null), 0)
                             + coalesce((select sum(c.amount_cents) from staff_commissions c join staff_commissions p0 on p0.id = c.clawback_of join owner_recruit_requests r on r.id = p0.owner_recruit_request_id
                                       where r.owner_id = o.id and c.staff_id = v_staff and c.status not in ('void', 'reversed')), 0),
             'paid_cents', coalesce((select sum(c.amount_cents) from staff_commissions c join owner_recruit_requests r on r.id = c.owner_recruit_request_id
                                       where r.owner_id = o.id and c.staff_id = v_staff and c.status = 'paid'), 0)) x
      from owners o where o.recruited_by = v_staff) q;
  -- their invitations, and the open owner leads they added by hand or were given (the owner pipeline before 0342)
  select coalesce(jsonb_agg(jsonb_build_object('lead_id', l.id, 'name', l.name, 'email', l.email, 'since', l.created_at,
                    'stage', case when l.pipeline_stage = 'lost' then 'lost' when l.sourced_by = v_staff then 'invited' else 'lead' end) order by l.created_at desc), '[]'::jsonb) into v_invites
    from leads l
   where (l.sourced_by = v_staff or (l.sourced_by is null and ((l.payload ->> 'added_by') = v_staff::text or l.assigned_to = v_staff))) and l.kind = 'owner_program'
     and (l.sourced_by = v_staff or l.status in ('new', 'contacted', 'qualified'))
     and not exists (select 1 from owner_applications a where a.lead_id = l.id)
     and (l.owner_id is null or not exists (select 1 from owners o where o.id = l.owner_id and o.recruited_by = v_staff));
  return jsonb_build_object('staff_id', v_staff,
    'counts', jsonb_build_object(
      'invited', jsonb_array_length(v_invites) + jsonb_array_length(v_rows),
      'applied', jsonb_array_length(v_rows),
      'approved', (select count(*) from jsonb_array_elements(v_rows) e where e ->> 'stage' in ('approved', 'car_live', 'first_paid_rental')),
      'car_live', (select count(*) from jsonb_array_elements(v_rows) e where e ->> 'stage' in ('car_live', 'first_paid_rental')),
      'first_paid_rental', (select count(*) from jsonb_array_elements(v_rows) e where e ->> 'stage' = 'first_paid_rental')),
    'owners', v_rows, 'invites', v_invites);
end $$;

-- Admin: every request, with the owner, the person, the stage and what it has earned. p: {status}
create or replace function app.owner_recruit_requests_read(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_status text := nullif(p ->> 'status', '');
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object(
    'requests', coalesce((select jsonb_agg(app.owner_recruit_request_json(r) || jsonb_build_object('owner_id', o.id, 'owner', o.legal_name, 'staff_id', r.staff_id,
                     'staff', (select coalesce(u.full_name, u.email) from users u where u.id = r.staff_id),
                     'mode', (select sp.sales_work_mode from staff_profiles sp where sp.user_id = r.staff_id),
                     'stage', app.owner_recruit_stage(o.id), 'cars', (select count(*) from vehicles v where v.owner_id = o.id and v.retired_at is null),
                     'blocked', app.owner_recruit_block(o.id, r.staff_id),
                     'earned_cents', coalesce((select sum(c.amount_cents) from staff_commissions c where c.owner_recruit_request_id = r.id and c.status in ('pending_approval', 'approved', 'paid') and c.reversed_at is null), 0))
                   order by (r.status = 'pending') desc, r.updated_at desc)
                 from owner_recruit_requests r join owners o on o.id = r.owner_id
                where v_status is null or r.status = v_status), '[]'::jsonb),
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'name', coalesce(u.full_name, u.email)) order by coalesce(u.full_name, u.email)), '[]'::jsonb)
                from users u where app.user_va_has(u.id, 'sales')));
end $$;

-- Admin, the owner page: who sourced the owner, how, and the staff who may be named.
create or replace function app.owner_sourced_read(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
begin
  perform app.assert_admin(p_by);
  select * into o from owners where id = nullif(p ->> 'owner_id', '')::uuid;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('staff_id', o.recruited_by, 'name', (select coalesce(u.full_name, u.email) from users u where u.id = o.recruited_by),
    'via', o.recruited_via, 'at', o.recruited_at, 'request', (select app.owner_recruit_request_json(r) from owner_recruit_requests r where r.owner_id = o.id),
    'options', app.sales_staff_options(p_by));
end $$;

-- ================================================================ 8. Admin: decide, reassign
-- p: {id, decision approve | decline, kind?, amount_cents?, rate_bps?, base?, months?, while_enrolled? (changed terms), note}
create or replace function app.owner_recruit_decide(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r owner_recruit_requests;
  t jsonb;
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_block text;
begin
  perform app.assert_admin(p_by);
  select * into r from owner_recruit_requests where id = nullif(p ->> 'id', '')::uuid for update;
  if r.id is null then raise exception 'Request not found' using errcode = 'P0002'; end if;
  if r.status <> 'pending' then raise exception 'This request has been decided' using errcode = '23514'; end if;
  if p ->> 'decision' = 'decline' then
    update owner_recruit_requests set status = 'declined', admin_note = v_note, decided_at = now(), decided_by = p_by, updated_at = now() where id = r.id returning * into r;
  elsif p ->> 'decision' = 'approve' then
    v_block := app.owner_recruit_block(r.owner_id, r.staff_id);
    if v_block is not null then raise exception '%', v_block using errcode = '23514'; end if;
    t := app.owner_recruit_terms(case when nullif(p ->> 'kind', '') is null then to_jsonb(r) else p end);
    update owner_recruit_requests set status = 'approved', a_kind = t ->> 'kind', a_amount_cents = (t ->> 'amount_cents')::bigint, a_rate_bps = (t ->> 'rate_bps')::integer,
           a_base = t ->> 'base', a_months = (t ->> 'months')::integer, a_while_enrolled = (t ->> 'while_enrolled')::boolean,
           changed = (t ->> 'kind', t ->> 'amount_cents', t ->> 'rate_bps', t ->> 'base', t ->> 'months', (t ->> 'while_enrolled')::boolean)
                     is distinct from (r.kind, r.amount_cents::text, r.rate_bps::text, r.base, r.months::text, r.while_enrolled),
           admin_note = v_note, decided_at = now(), decided_by = p_by, updated_at = now()
     where id = r.id returning * into r;
  else
    raise exception 'Approve or decline' using errcode = '22023';
  end if;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Request ' || r.status
   where related_table = 'owner_recruit_requests' and related_id = r.id and status in ('open', 'in_progress', 'waiting');
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'owner_recruit_decide', 'owner_recruit_requests', r.id::text, p);
  if r.status = 'approved' then perform app.owner_recruit_sync_owner(r.owner_id); end if;
  return app.owner_recruit_request_json(r);
end $$;

-- p: {owner_id, staff_id (empty: nobody), reason}. A pending request of the earlier person is withdrawn; an approved one and
-- its commissions not paid yet go to the new person (what was paid stays with whoever was paid).
create or replace function app.owner_sourced_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  v_staff uuid := nullif(p ->> 'staff_id', '')::uuid;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  r owner_recruit_requests;
begin
  perform app.assert_admin(p_by);
  select * into o from owners where id = nullif(p ->> 'owner_id', '')::uuid for update;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  if v_reason is null then raise exception 'Say why' using errcode = '22023'; end if;
  if v_staff is not null and not app.user_is_sales_staff(v_staff) then raise exception 'Choose a staff member' using errcode = '22023'; end if;
  update owners set recruited_by = v_staff, recruited_at = case when v_staff is null then null else now() end,
         recruited_via = case when v_staff is null then null else 'admin' end where id = o.id;
  update owner_applications set sourced_by = v_staff where owner_id = o.id;
  select * into r from owner_recruit_requests where owner_id = o.id for update;
  if r.id is not null and r.staff_id is distinct from v_staff then
    if r.status <> 'approved' or v_staff is null then
      if exists (select 1 from staff_commissions c where c.owner_recruit_request_id = r.id) then
        update staff_commissions set status = case when status = 'accruing' then 'void' else 'reversed' end, reason = 'Sourced by changed: ' || v_reason, reversed_at = now(), reversed_by = p_by, admin_reversed = true
         where owner_recruit_request_id = r.id and kind = 'owner_recruit' and status in ('accruing', 'pending_approval', 'approved');
        update owner_recruit_requests set status = 'declined', admin_note = 'Sourced by changed: ' || v_reason, decided_at = coalesce(decided_at, now()), decided_by = coalesce(decided_by, p_by),
               a_kind = null, a_amount_cents = null, a_rate_bps = null, a_base = null, a_months = null, a_while_enrolled = null, updated_at = now() where id = r.id;
      else
        delete from owner_recruit_requests where id = r.id;
      end if;
    else
      update owner_recruit_requests set staff_id = v_staff, updated_at = now() where id = r.id returning * into r;
      update staff_commissions set staff_id = v_staff, updated_at = now() where owner_recruit_request_id = r.id and kind = 'owner_recruit' and status in ('accruing', 'pending_approval', 'approved');
    end if;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'owner_sourced_set', 'owners', o.id::text, jsonb_build_object('recruited_by', o.recruited_by), jsonb_build_object('recruited_by', v_staff, 'reason', v_reason));
  return jsonb_build_object('owner_id', o.id, 'staff_id', v_staff);
end $$;

-- ================================================================ 9. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0340;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if (p_call = 'va_read' and p_name = 'sales_owners') or (p_call = 'admin_read' and p_name = 'sales_owners') then
    perform app.door_begin(p_user, p_aal);
    if p_call = 'admin_read' then perform app.assert_admin(p_user); end if;
    return app.sales_owners_read(p_user, p_);
  end if;
  if p_call = 'va_do' and p_name in ('sales_owner_invite', 'sales_owner_commission_request') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'sales_owner_invite' then app.sales_owner_invite(p_user, p_) else app.sales_owner_commission_request(p_user, p_) end;
  end if;
  -- Start it: a salesperson's own entry (from a Sales page, or for someone who is not customer service or fleet)
  if p_call = 'va_do' and p_name in ('staff_add_owner_car', 'staff_vehicle_document') and not app.user_is_admin(p_user) and app.user_va_has(p_user, 'sales')
     and (coalesce((p_ ->> 'as_sales')::boolean, false) or not app.user_va_has(p_user, 'cs', 'fleet')) then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'staff_add_owner_car' then app.sales_add_owner_car(p_user, p_) else app.sales_vehicle_document(p_user, p_) end;
  end if;
  if p_call = 'admin_read' and p_name in ('owner_recruit_requests', 'owner_sourced') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'owner_recruit_requests' then app.owner_recruit_requests_read(p_user, p_) else app.owner_sourced_read(p_user, p_) end;
  end if;
  if p_call = 'admin_do' and p_name in ('owner_recruit_decide', 'owner_sourced_set') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'owner_recruit_decide' then app.owner_recruit_decide(p_user, p_) else app.owner_sourced_set(p_user, p_) end;
  end if;
  return app.door_pre0340(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0340(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ privileges: the database's own functions, never a browser's
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname in ('owner_recruit_block', 'owner_recruit_stage', 'owner_recruit_words', 'owner_sales_credit', 'owner_applications_sales_match',
                     'sales_owner_assert', 'sales_owner_invite', 'staff_add_owner_car_pre0340', 'sales_add_owner_car', 'sales_vehicle_document', 'owner_recruit_terms',
                     'owner_recruit_request_json', 'sales_owner_commission_request', 'owner_recruit_bookings', 'owner_recruit_row', 'owner_recruit_sync_owner',
                     'owner_recruit_sync_booking', 'commission_sync_pre0340', 'owner_recruit_trigger', 'job_owner_recruit', 'commission_reverse_pre0340',
                     'owner_recruit_row_label', 'commission_admin_pre0340', 'staff_commissions_json_pre0340', 'sales_owners_read', 'owner_recruit_requests_read',
                     'owner_recruit_decide', 'owner_sourced_set', 'owner_sourced_read', 'door_pre0340'))
               or (n.nspname = 'public' and p.proname = 'server_owner_sales_credit') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
