-- 0581_kickbacks_repair_costs.sql
-- Release 29, C2 (docs/changes/2026-11-06-kickbacks-repair-costs.md): partner kickbacks and repair costs in the profit
-- numbers, per car, per owner and for the business.
--   1. Every partner invoice (0547) is tied to a car (vehicle_id) and to a claim when there is one (claim_id): filled by
--      itself from the invoice's booking and claim number (a trigger, and once for the invoices already made); a car
--      picker for the rest (ops_do partner_invoice_car, also on an invoice already sent). The invoices and their
--      payments stay the one source: a kickback is a payment received on a body shop (repair), tow or storage invoice,
--      before HST, on the day it was received.
--   2. vehicle_repair_costs: date, vendor (a partner or free text), what was done, amount, tax, receipt, paid by
--      (CarmaCars, the owner or the insurer), claim. Admin, Finance and Fleet add, change and void them (ops_do
--      repair_cost_save / repair_cost_void), from the car or the claim.
--   3. app.profit_extras(level, id, from, to): the lines Body shop kickback, Tow kickback, Storage kickback, Other
--      kickback and Repair costs (paid by CarmaCars; the owner's and the insurer's shown apart), by car and by owner,
--      with every row (the CSV). Business and owner level: Admin and Finance; car level: also Fleet.
--   4. owners.show_profit_extras ("Show repair costs and kickbacks to this owner"), off by default, set by Admin or
--      Finance only. On: the owner reads the lines of their own cars (ops_read profit_extras_mine), never another's;
--      off: nothing. Statements and every public page are unchanged.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. invoices tied to a car and a claim
alter table partner_invoices
  add column if not exists vehicle_id uuid references vehicles (id) on delete set null,
  add column if not exists claim_id uuid references claims (id) on delete set null;
create index if not exists partner_invoices_vehicle_idx on partner_invoices (vehicle_id);
create index if not exists partner_invoices_claim_idx on partner_invoices (claim_id);
comment on column partner_invoices.vehicle_id is 'The car the kickback belongs to (0581): from the booking or the claim by itself, else picked.';
comment on column partner_invoices.claim_id is 'The claim the invoice is for (0581), matched on the claim number or the insurer''s claim reference.';

create or replace function app.partner_invoice_links() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.claim_id is null and nullif(btrim(coalesce(new.claim_number, '')), '') is not null then
    select c.id into new.claim_id from claims c
     where upper(c.claim_number) = upper(btrim(new.claim_number)) or upper(coalesce(c.insurer_claim_ref, '')) = upper(btrim(new.claim_number))
     order by c.created_at desc limit 1;
  end if;
  if new.vehicle_id is null and new.booking_id is not null then select b.vehicle_id into new.vehicle_id from bookings b where b.id = new.booking_id; end if;
  if new.vehicle_id is null and new.claim_id is not null then select c.vehicle_id into new.vehicle_id from claims c where c.id = new.claim_id; end if;
  return new;
end $$;
drop trigger if exists partner_invoices_links on partner_invoices;
create trigger partner_invoices_links before insert or update of booking_id, claim_number, claim_id, vehicle_id on partner_invoices
  for each row execute function app.partner_invoice_links();
update partner_invoices set claim_number = claim_number where vehicle_id is null or claim_id is null;

create or replace function app.profit_extras_may(p_by uuid, p_level text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_by) or app.user_runs_finance(p_by) or (p_level = 'vehicle' and app.user_va_has(p_by, 'fleet'))
$$;

-- the car (and claim) of an invoice, also one already sent or paid: Admin and Finance
create or replace function app.partner_invoice_car(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare i partner_invoices; v_car uuid := nullif(p ->> 'vehicle_id', '')::uuid; v_claim uuid := nullif(p ->> 'claim_id', '')::uuid;
begin
  if not app.partner_invoice_may(p_by) then raise exception 'Finance or an Admin ties an invoice to a car' using errcode = '42501'; end if;
  select * into i from partner_invoices where id = (p ->> 'id')::uuid for update;
  if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if v_car is not null and not exists (select 1 from vehicles where id = v_car) then raise exception 'Choose a car' using errcode = '22023'; end if;
  if v_claim is not null and not exists (select 1 from claims where id = v_claim) then raise exception 'Claim not found' using errcode = 'P0002'; end if;
  update partner_invoices set vehicle_id = v_car, claim_id = coalesce(v_claim, claim_id), updated_at = now() where id = i.id;
  return jsonb_build_object('id', i.id, 'vehicle_id', v_car);
end $$;

-- the invoice as the builder and the PDF read it, with its car; the builder's draft saves its car too
do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'partner_invoice_json_pre0581') then
    alter function app.partner_invoice_json(uuid) rename to partner_invoice_json_pre0581;
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'partner_invoice_save_pre0581') then
    alter function app.partner_invoice_save(uuid, jsonb) rename to partner_invoice_save_pre0581;
  end if;
end $$;
create or replace function app.partner_invoice_json(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.partner_invoice_json_pre0581(p_id) || jsonb_build_object('vehicle_id', i.vehicle_id, 'claim_id', i.claim_id,
           'car', case when i.vehicle_id is not null then app.vehicle_name(i.vehicle_id) end)
    from partner_invoices i where i.id = p_id
$$;
create or replace function app.partner_invoice_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb := app.partner_invoice_save_pre0581(p_by, p);
begin
  if p ? 'vehicle_id' then
    if nullif(p ->> 'vehicle_id', '') is not null and not exists (select 1 from vehicles where id = (p ->> 'vehicle_id')::uuid) then raise exception 'Choose a car' using errcode = '22023'; end if;
    update partner_invoices set vehicle_id = nullif(p ->> 'vehicle_id', '')::uuid where id = (r ->> 'id')::uuid;
    r := app.partner_invoice_json((r ->> 'id')::uuid);
  end if;
  return r;
end $$;

-- ================================================================ 2. repair costs per car
create table if not exists vehicle_repair_costs (
  id                 uuid primary key default gen_random_uuid(),
  vehicle_id         uuid not null references vehicles (id),
  claim_id           uuid references claims (id) on delete set null,
  spent_on           date not null,
  vendor_partner_id  uuid references referral_partners (id) on delete set null,
  vendor_name        text check (char_length(vendor_name) <= 160),
  description        text not null check (char_length(btrim(description)) between 1 and 500),
  amount_cents       bigint not null check (amount_cents >= 0),
  tax_cents          bigint not null default 0 check (tax_cents >= 0),
  receipt_path       text check (receipt_path is null or receipt_path ~ '^repair-receipts/[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|png|pdf)$'),
  paid_by            text not null check (paid_by in ('company', 'owner', 'insurer')),
  created_by         uuid references users (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_by         uuid references users (id) on delete set null,
  updated_at         timestamptz not null default now(),
  voided_at          timestamptz,
  voided_by          uuid references users (id) on delete set null,
  void_reason        text check (char_length(void_reason) <= 300),
  check (vendor_partner_id is not null or nullif(btrim(coalesce(vendor_name, '')), '') is not null)
);
create index if not exists vehicle_repair_costs_vehicle_idx on vehicle_repair_costs (vehicle_id, spent_on);
create index if not exists vehicle_repair_costs_claim_idx on vehicle_repair_costs (claim_id);
alter table vehicle_repair_costs enable row level security;
create policy admin_all on vehicle_repair_costs for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_vehicle_repair_costs after insert or update or delete on vehicle_repair_costs for each row execute function app.audit_row();
comment on table vehicle_repair_costs is 'Repair costs per car (0581): read and written through ops_read profit_extras and ops_do repair_cost_save / repair_cost_void.';

create or replace function app.repair_cost_may(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_by) or app.user_runs_finance(p_by) or app.user_va_has(p_by, 'fleet')
$$;

create or replace function app.repair_cost_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r vehicle_repair_costs;
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_claim uuid := nullif(p ->> 'claim_id', '')::uuid;
  v_car uuid := nullif(p ->> 'vehicle_id', '')::uuid;
begin
  if not app.repair_cost_may(p_by) then raise exception 'Fleet, Finance or an Admin records repair costs' using errcode = '42501'; end if;
  if v_id is not null then
    select * into r from vehicle_repair_costs where id = v_id for update;
    if r.id is null or r.voided_at is not null then raise exception 'Repair cost not found' using errcode = 'P0002'; end if;
  end if;
  -- from a claim: its car
  if v_car is null and v_claim is not null then select vehicle_id into v_car from claims where id = v_claim; end if;
  v_car := coalesce(v_car, r.vehicle_id);
  if v_car is null or not exists (select 1 from vehicles where id = v_car) then raise exception 'Choose the car' using errcode = '22023'; end if;
  if v_claim is not null and not exists (select 1 from claims where id = v_claim) then raise exception 'Claim not found' using errcode = 'P0002'; end if;
  if coalesce(p ->> 'paid_by', '') not in ('company', 'owner', 'insurer') then raise exception 'Paid by CarmaCars, the owner or the insurer' using errcode = '22023'; end if;
  if nullif(p ->> 'amount_cents', '') is null or (p ->> 'amount_cents')::bigint < 0 then raise exception 'Enter the amount' using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p ->> 'description', '')), '') is null then raise exception 'Say what was done' using errcode = '22023'; end if;
  if nullif(p ->> 'vendor_partner_id', '') is null and nullif(btrim(coalesce(p ->> 'vendor_name', '')), '') is null then raise exception 'Choose the shop or type the vendor' using errcode = '22023'; end if;
  if v_id is null then
    insert into vehicle_repair_costs (vehicle_id, claim_id, spent_on, vendor_partner_id, vendor_name, description, amount_cents, tax_cents, receipt_path, paid_by, created_by, updated_by)
    values (v_car, v_claim, coalesce(nullif(p ->> 'spent_on', '')::date, app.local_date(now())), nullif(p ->> 'vendor_partner_id', '')::uuid,
            nullif(left(btrim(coalesce(p ->> 'vendor_name', '')), 160), ''), left(btrim(p ->> 'description'), 500), (p ->> 'amount_cents')::bigint,
            coalesce(nullif(p ->> 'tax_cents', '')::bigint, 0), nullif(p ->> 'receipt_path', ''), p ->> 'paid_by', p_by, p_by)
    returning * into r;
  else
    update vehicle_repair_costs set vehicle_id = v_car, claim_id = v_claim, spent_on = coalesce(nullif(p ->> 'spent_on', '')::date, spent_on),
           vendor_partner_id = nullif(p ->> 'vendor_partner_id', '')::uuid, vendor_name = nullif(left(btrim(coalesce(p ->> 'vendor_name', '')), 160), ''),
           description = left(btrim(p ->> 'description'), 500), amount_cents = (p ->> 'amount_cents')::bigint, tax_cents = coalesce(nullif(p ->> 'tax_cents', '')::bigint, 0),
           receipt_path = coalesce(nullif(p ->> 'receipt_path', ''), receipt_path), paid_by = p ->> 'paid_by', updated_by = p_by, updated_at = now()
     where id = v_id returning * into r;
  end if;
  return to_jsonb(r);
end $$;

create or replace function app.repair_cost_void(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.repair_cost_may(p_by) then raise exception 'Fleet, Finance or an Admin records repair costs' using errcode = '42501'; end if;
  update vehicle_repair_costs set voided_at = now(), voided_by = p_by, void_reason = nullif(left(btrim(coalesce(p ->> 'reason', '')), 300), '')
   where id = (p ->> 'id')::uuid and voided_at is null;
  if not found then raise exception 'Repair cost not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ 3. the lines
-- a kickback: a payment received (not voided) on an invoice that is not void, before HST (its share of the total)
create or replace function app.kickback_rows(p_from date, p_to date)
returns table (vehicle_id uuid, owner_id uuid, claim_id uuid, invoice_id uuid, invoice_number text, partner text, kind text, line text, on_date date, amount_cents bigint)
language sql stable security definer set search_path = public, app as $$
  select i.vehicle_id, v.owner_id, i.claim_id, i.id, i.invoice_number, rp.business_name, i.kind,
         case i.kind when 'repair' then 'Body shop kickback' when 'towing' then 'Tow kickback' when 'storage' then 'Storage kickback' else 'Other kickback' end,
         pay.received_on,
         case when i.total_cents > 0 then round(pay.amount_cents::numeric * i.subtotal_cents / i.total_cents)::bigint else pay.amount_cents end
    from partner_invoice_payments pay
    join partner_invoices i on i.id = pay.invoice_id and i.status <> 'void'
    join referral_partners rp on rp.id = i.partner_id
    left join vehicles v on v.id = i.vehicle_id
   where pay.voided_at is null and pay.received_on between p_from and p_to
$$;

create or replace function app.repair_rows(p_from date, p_to date)
returns table (id uuid, vehicle_id uuid, owner_id uuid, claim_id uuid, claim_number text, on_date date, vendor text, description text, amount_cents bigint, tax_cents bigint, paid_by text, receipt text)
language sql stable security definer set search_path = public, app as $$
  select r.id, r.vehicle_id, v.owner_id, r.claim_id, c.claim_number, r.spent_on, coalesce(rp.business_name, r.vendor_name), r.description, r.amount_cents, r.tax_cents, r.paid_by, r.receipt_path
    from vehicle_repair_costs r join vehicles v on v.id = r.vehicle_id
    left join referral_partners rp on rp.id = r.vendor_partner_id left join claims c on c.id = r.claim_id
   where r.voided_at is null and r.spent_on between p_from and p_to
$$;

-- level business | owner | vehicle; p_id the owner or the car; the period inclusive (default: this year to today);
-- p_staff false (the owner's own view): no partner names, invoices, claim ids or receipts
create or replace function app.profit_extras(p_level text, p_id uuid, p_from date, p_to date, p_staff boolean default true) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_from date := coalesce(p_from, date_trunc('year', app.local_date(now()))::date);
  v_to date := coalesce(p_to, app.local_date(now()));
  k jsonb; r jsonb;
begin
  if p_level not in ('business', 'owner', 'vehicle') then raise exception 'Business, owner or car' using errcode = '22023'; end if;
  if v_to < v_from then raise exception 'The period ends before it starts' using errcode = '22023'; end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.on_date, x.invoice_number), '[]'::jsonb) into k from app.kickback_rows(v_from, v_to) x
   where p_level = 'business' or (p_level = 'owner' and x.owner_id = p_id) or (p_level = 'vehicle' and x.vehicle_id = p_id);
  select coalesce(jsonb_agg(to_jsonb(x) order by x.on_date, x.id), '[]'::jsonb) into r from app.repair_rows(v_from, v_to) x
   where p_level = 'business' or (p_level = 'owner' and x.owner_id = p_id) or (p_level = 'vehicle' and x.vehicle_id = p_id);
  return app.profit_extras_build(p_level, p_id, v_from, v_to, k, r, p_staff);
end $$;

create or replace function app.profit_extras_build(p_level text, p_id uuid, p_from date, p_to date, k jsonb, r jsonb, p_staff boolean) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with kr as (select (e ->> 'vehicle_id')::uuid as vehicle_id, (e ->> 'owner_id')::uuid as owner_id, e ->> 'line' as line, (e ->> 'amount_cents')::bigint as cents, e from jsonb_array_elements(k) e),
       rr as (select (e ->> 'vehicle_id')::uuid as vehicle_id, (e ->> 'owner_id')::uuid as owner_id, e ->> 'paid_by' as paid_by, (e ->> 'amount_cents')::bigint as cents, e from jsonb_array_elements(r) e),
       cars as (select vehicle_id from kr where vehicle_id is not null union select vehicle_id from rr),
       kick as (select coalesce(sum(cents), 0) as c from kr), rep as (select coalesce(sum(cents) filter (where paid_by = 'company'), 0) as c from rr)
  select jsonb_build_object('level', p_level, 'id', p_id, 'from', p_from, 'to', p_to,
    'lines', jsonb_build_array(
      jsonb_build_object('line', 'Body shop kickback', 'kind', 'revenue', 'cents', (select coalesce(sum(cents), 0) from kr where line = 'Body shop kickback')),
      jsonb_build_object('line', 'Tow kickback', 'kind', 'revenue', 'cents', (select coalesce(sum(cents), 0) from kr where line = 'Tow kickback')),
      jsonb_build_object('line', 'Storage kickback', 'kind', 'revenue', 'cents', (select coalesce(sum(cents), 0) from kr where line = 'Storage kickback')),
      jsonb_build_object('line', 'Other kickback', 'kind', 'revenue', 'cents', (select coalesce(sum(cents), 0) from kr where line = 'Other kickback')),
      jsonb_build_object('line', 'Repair costs', 'kind', 'cost', 'cents', (select c from rep)),
      jsonb_build_object('line', 'Repairs paid by the owner', 'kind', 'memo', 'cents', (select coalesce(sum(cents), 0) from rr where paid_by = 'owner')),
      jsonb_build_object('line', 'Repairs paid by the insurer', 'kind', 'memo', 'cents', (select coalesce(sum(cents), 0) from rr where paid_by = 'insurer'))),
    'kickback_cents', (select c from kick), 'repair_cents', (select c from rep), 'net_cents', (select c from kick) - (select c from rep),
    'unassigned_kickback_cents', case when p_staff then (select coalesce(sum(cents), 0) from kr where vehicle_id is null) end,
    'by_car', (select coalesce(jsonb_agg(jsonb_build_object('vehicle_id', c.vehicle_id, 'name', app.vehicle_name(c.vehicle_id),
                 'body_shop_cents', (select coalesce(sum(cents), 0) from kr where kr.vehicle_id = c.vehicle_id and line = 'Body shop kickback'),
                 'tow_cents', (select coalesce(sum(cents), 0) from kr where kr.vehicle_id = c.vehicle_id and line = 'Tow kickback'),
                 'storage_cents', (select coalesce(sum(cents), 0) from kr where kr.vehicle_id = c.vehicle_id and line = 'Storage kickback'),
                 'other_cents', (select coalesce(sum(cents), 0) from kr where kr.vehicle_id = c.vehicle_id and line = 'Other kickback'),
                 'repair_cents', (select coalesce(sum(cents), 0) from rr where rr.vehicle_id = c.vehicle_id and paid_by = 'company')) order by app.vehicle_name(c.vehicle_id)), '[]'::jsonb) from cars c),
    'by_owner', case when p_level = 'business' then (select coalesce(jsonb_agg(jsonb_build_object('owner_id', o.id, 'name', o.legal_name,
                 'kickback_cents', (select coalesce(sum(cents), 0) from kr where kr.owner_id = o.id),
                 'repair_cents', (select coalesce(sum(cents), 0) from rr where rr.owner_id = o.id and paid_by = 'company')) order by o.legal_name), '[]'::jsonb)
               from owners o where o.id in (select owner_id from kr union select owner_id from rr)) end,
    'kickbacks', (select coalesce(jsonb_agg(jsonb_build_object('on_date', e ->> 'on_date', 'vehicle_id', vehicle_id, 'car', case when vehicle_id is not null then app.vehicle_name(vehicle_id) end,
                 'line', line, 'cents', cents) || case when p_staff then jsonb_build_object('invoice_id', e ->> 'invoice_id', 'invoice_number', e ->> 'invoice_number',
                 'partner', e ->> 'partner', 'claim_id', e ->> 'claim_id') else '{}'::jsonb end), '[]'::jsonb) from kr),
    'repairs', (select coalesce(jsonb_agg(jsonb_build_object('id', e ->> 'id', 'on_date', e ->> 'on_date', 'vehicle_id', vehicle_id, 'car', app.vehicle_name(vehicle_id),
                 'vendor', e ->> 'vendor', 'description', e ->> 'description', 'cents', cents, 'tax_cents', (e ->> 'tax_cents')::bigint, 'paid_by', paid_by,
                 'claim_number', e ->> 'claim_number') || case when p_staff then jsonb_build_object('claim_id', e ->> 'claim_id', 'receipt', e ->> 'receipt') else '{}'::jsonb end), '[]'::jsonb) from rr))
$$;

-- ================================================================ 4. the owner sees them only when staff turn it on
alter table owners add column if not exists show_profit_extras boolean not null default false;
comment on column owners.show_profit_extras is 'Show repair costs and kickbacks to this owner (0581): off by default; Admin or Finance turn it on; the owner then sees the lines of their own cars only.';

create or replace function app.owner_profit_extras_visibility(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not (app.user_is_admin(p_by) or app.user_runs_finance(p_by)) then raise exception 'Finance or an Admin decides what an owner sees' using errcode = '42501'; end if;
  update owners set show_profit_extras = coalesce((p ->> 'on')::boolean, false) where id = (p ->> 'owner')::uuid;
  if not found then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('owner', p ->> 'owner', 'on', coalesce((p ->> 'on')::boolean, false));
end $$;

-- the signed-in owner's own lines (no partner names, invoices, claims' internal ids or receipts), or visible false
create or replace function app.profit_extras_mine(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare o owners;
begin
  select * into o from owners where user_id = p_by and app.user_is_owner_of(p_by, id) order by created_at limit 1;
  if o.id is null then raise exception 'Not permitted' using errcode = '42501'; end if;
  if not o.show_profit_extras then return jsonb_build_object('visible', false); end if;
  return app.profit_extras('owner', o.id, nullif(p ->> 'from', '')::date, nullif(p ->> 'to', '')::date, false) - 'by_owner' - 'unassigned_kickback_cents' || jsonb_build_object('visible', true);
end $$;

create or replace function app.profit_extras_read(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_level text := coalesce(nullif(p ->> 'level', ''), 'business'); v_id uuid := nullif(p ->> 'id', '')::uuid; r jsonb;
begin
  if not app.profit_extras_may(p_by, v_level) then raise exception 'Not permitted' using errcode = '42501'; end if;
  if v_level <> 'business' and v_id is null then raise exception 'Choose the % first', case v_level when 'owner' then 'owner' else 'car' end using errcode = '22023'; end if;
  r := app.profit_extras(v_level, v_id, nullif(p ->> 'from', '')::date, nullif(p ->> 'to', '')::date, true);
  return r || jsonb_build_object(
    'show_to_owner', case when v_level = 'owner' then (select show_profit_extras from owners where id = v_id) end,
    'partners', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', business_name) order by business_name), '[]'::jsonb) from referral_partners where status <> 'declined'),
    'claims', case when v_level = 'vehicle' then (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'claim_number', claim_number) order by created_at desc), '[]'::jsonb) from claims where vehicle_id = v_id) end,
    'cars', case when v_level <> 'vehicle' then (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id)) order by app.vehicle_name(v.id)), '[]'::jsonb)
                                                from vehicles v where not coalesce(v.is_sample, false) and (v_level = 'business' or v.owner_id = v_id)) end);
end $$;

-- the cars an invoice can be tied to (the invoice builder's picker)
create or replace function app.profit_cars(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.partner_invoice_may(p_by) or app.repair_cost_may(p_by)) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id)) order by app.vehicle_name(v.id)), '[]'::jsonb)
            from vehicles v where not coalesce(v.is_sample, false));
end $$;

-- a repair cost's receipt (the route serves it from private storage)
create or replace function app.repair_receipt(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.repair_cost_may(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return (select jsonb_build_object('path', receipt_path) from vehicle_repair_costs where id = (p ->> 'id')::uuid and receipt_path is not null);
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0581;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if (p_call in ('ops_do', 'admin_do') and p_name in ('partner_invoice_car', 'repair_cost_save', 'repair_cost_void', 'owner_profit_extras_visibility'))
     or (p_call in ('ops_read', 'admin_read') and p_name in ('profit_extras', 'profit_extras_mine', 'profit_cars', 'repair_receipt')) then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'partner_invoice_car' then app.partner_invoice_car(p_user, v)
      when 'repair_cost_save' then app.repair_cost_save(p_user, v)
      when 'repair_cost_void' then app.repair_cost_void(p_user, v)
      when 'owner_profit_extras_visibility' then app.owner_profit_extras_visibility(p_user, v)
      when 'profit_extras' then app.profit_extras_read(p_user, v)
      when 'profit_extras_mine' then app.profit_extras_mine(p_user, v)
      when 'repair_receipt' then app.repair_receipt(p_user, v)
      else app.profit_cars(p_user) end;
  end if;
  return app.door_pre0581(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0581(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f text;
begin
  foreach f in array array['app.partner_invoice_links()', 'app.partner_invoice_json(uuid)', 'app.partner_invoice_save(uuid, jsonb)', 'app.profit_extras_may(uuid, text)', 'app.partner_invoice_car(uuid, jsonb)', 'app.repair_cost_may(uuid)',
    'app.repair_cost_save(uuid, jsonb)', 'app.repair_cost_void(uuid, jsonb)', 'app.kickback_rows(date, date)', 'app.repair_rows(date, date)',
    'app.profit_extras(text, uuid, date, date, boolean)', 'app.profit_extras_build(text, uuid, date, date, jsonb, jsonb, boolean)', 'app.owner_profit_extras_visibility(uuid, jsonb)', 'app.profit_extras_mine(uuid, jsonb)',
    'app.profit_extras_read(uuid, jsonb)', 'app.profit_cars(uuid)', 'app.repair_receipt(uuid, jsonb)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
