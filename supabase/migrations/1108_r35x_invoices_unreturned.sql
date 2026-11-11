-- 1108_r35x_invoices_unreturned.sql
-- Release 35, UX batch (docs/changes/2026-11-09-r35-ux-batch.md). SCHEMA_MARKER 1109 (1106 to 1109 are one batch).
-- The owner, November 9:
--   1. Insurer invoices: "if its for insurer billing then it can't say carmacars or have the carmacars logo, it needs to say
--      blindspotcarrental. also instead of it saying fees charged at booking ... it needs to say what fees are being
--      charged." An insurer invoice's PDF facts now carry the Blind Spot Car Rental block (Program settings bs_billing_*:
--      the name, an email and a phone; the legal entity stays 18122211 Canada Inc.; no CarmaCars name, email, domain or
--      logo; any value naming CarmaCars is left out), file name blindspot-invoice-<number>.pdf, and fee_items: every fee
--      of the booking by name (the Protection Plan, young driver, delivery ...). A draft's "Fees charged at booking" line
--      is replaced by those named lines when they add up to it; an issued invoice's stored line is itemized on the PDF.
--   2. "invoices also need to have the direct deposit info on the bottom of the invoice as well as the etransfer details":
--      Program settings cc_pay_* (CarmaCars invoices) and bs_pay_* (Blind Spot: insurer invoices; CarmaCars' are used only
--      when Blind Spot's are all empty), every one empty by default. Owner, insurer and partner invoices carry the block
--      'pay'; a section with nothing entered is left out of the PDF.
--   3. "include somewhere discrete and hidden for renters how much renters have to pay for not returning the addon stuff
--      like a charger, make it expensive": Program settings unreturned_* (EV charger $150, phone mount $75, child car seat
--      $450, booster seat $200, any other add-on 3 times its rental charge, at least $100). Stated in the agreement's fine
--      print (after the Schedule, on a booking with add-ons in the car: app.agreement_extra's unreturned) and in the FAQ
--      (Payment and deposit), never in the booking flow. The deposit review gains an "Add-ons returned" item on a booking
--      with add-ons in the car, its facts listing each add-on with its suggested charge: a suggestion only, never charged
--      by itself (Fleet and Finance sign it like the other items, and Finance bills what is owed as before).
-- No applied migration is edited: functions are wrapped (_pre1108).
set local check_function_bodies = off;

create or replace function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 0. Program settings
alter table program_settings
  add column if not exists bs_billing_name text not null default 'Blind Spot Car Rental',
  add column if not exists bs_billing_email text,
  add column if not exists bs_billing_phone text,
  add column if not exists bs_pay_account_name text,
  add column if not exists bs_pay_institution text,
  add column if not exists bs_pay_institution_number text,
  add column if not exists bs_pay_transit_number text,
  add column if not exists bs_pay_account_number text,
  add column if not exists bs_pay_etransfer_email text default 'rent@carmacars.ca',
  add column if not exists cc_pay_account_name text,
  add column if not exists cc_pay_institution text,
  add column if not exists cc_pay_institution_number text,
  add column if not exists cc_pay_transit_number text,
  add column if not exists cc_pay_account_number text,
  add column if not exists cc_pay_etransfer_email text default 'rent@carmacars.ca',
  add column if not exists unreturned_ev_charger_cents bigint not null default 15000 check (unreturned_ev_charger_cents >= 0),
  add column if not exists unreturned_phone_mount_cents bigint not null default 7500 check (unreturned_phone_mount_cents >= 0),
  add column if not exists unreturned_child_seat_cents bigint not null default 45000 check (unreturned_child_seat_cents >= 0),
  add column if not exists unreturned_booster_seat_cents bigint not null default 20000 check (unreturned_booster_seat_cents >= 0),
  add column if not exists unreturned_other_times numeric(5, 2) not null default 3 check (unreturned_other_times >= 0),
  add column if not exists unreturned_other_min_cents bigint not null default 10000 check (unreturned_other_min_cents >= 0);
comment on column program_settings.bs_billing_name is 'Insurer invoices (1108): the name they are issued under (Blind Spot Car Rental). The legal entity line stays the company''s legal name.';
comment on column program_settings.bs_billing_email is 'Insurer invoices (1108): the contact email printed on them. Empty: none printed. A value naming CarmaCars is never printed.';
comment on column program_settings.bs_billing_phone is 'Insurer invoices (1108): the contact phone printed on them. Empty: none printed.';
comment on column program_settings.bs_pay_account_name is 'Insurer invoices (1108), direct deposit: the account name. Empty with every other bs_pay_ setting: the CarmaCars details (cc_pay_) are used.';
comment on column program_settings.bs_pay_institution is 'Insurer invoices (1108), direct deposit: the bank.';
comment on column program_settings.bs_pay_institution_number is 'Insurer invoices (1108), direct deposit: the institution number (3 digits).';
comment on column program_settings.bs_pay_transit_number is 'Insurer invoices (1108), direct deposit: the transit number (5 digits).';
comment on column program_settings.bs_pay_account_number is 'Insurer invoices (1108), direct deposit: the account number.';
comment on column program_settings.bs_pay_etransfer_email is 'Insurer invoices (1108): the Interac e-Transfer email (the invoice number goes in the message).';
comment on column program_settings.cc_pay_account_name is 'CarmaCars invoices (1108), direct deposit: the account name. Empty: the direct deposit section is left out.';
comment on column program_settings.cc_pay_institution is 'CarmaCars invoices (1108), direct deposit: the bank.';
comment on column program_settings.cc_pay_institution_number is 'CarmaCars invoices (1108), direct deposit: the institution number (3 digits).';
comment on column program_settings.cc_pay_transit_number is 'CarmaCars invoices (1108), direct deposit: the transit number (5 digits).';
comment on column program_settings.cc_pay_account_number is 'CarmaCars invoices (1108), direct deposit: the account number.';
comment on column program_settings.cc_pay_etransfer_email is 'CarmaCars invoices (1108): the Interac e-Transfer email (the invoice number goes in the message). Empty: the section is left out.';
comment on column program_settings.unreturned_ev_charger_cents is 'Add-ons not returned (1108): an EV charger or charging cable ($150). In the agreement''s fine print and the FAQ; the deposit review suggests it.';
comment on column program_settings.unreturned_phone_mount_cents is 'Add-ons not returned (1108): a phone mount ($75).';
comment on column program_settings.unreturned_child_seat_cents is 'Add-ons not returned (1108): a child car seat, baby seat included ($450).';
comment on column program_settings.unreturned_booster_seat_cents is 'Add-ons not returned (1108): a booster seat ($200).';
comment on column program_settings.unreturned_other_times is 'Add-ons not returned (1108): any other add-on costs this many times its rental charge (3) ...';
comment on column program_settings.unreturned_other_min_cents is '... and at least this much ($100).';

-- ================================================================ 1. the schedule of add-ons not returned
create or replace function app.unreturned_schedule() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('ev_charger_cents', s.unreturned_ev_charger_cents, 'phone_mount_cents', s.unreturned_phone_mount_cents,
    'child_seat_cents', s.unreturned_child_seat_cents, 'booster_seat_cents', s.unreturned_booster_seat_cents,
    'other_times', s.unreturned_other_times, 'other_min_cents', s.unreturned_other_min_cents)
    from (select * from app.settings()) s
$$;

-- which line of the schedule an add-on is (by its code or name)
create or replace function app.unreturned_kind(p_code text, p_name text) returns text
language sql immutable as $$
  select case
    when lower(coalesce(p_code, '') || ' ' || coalesce(p_name, '')) ~ '(ev|electric|level ?2|j1772|tesla)[ _-]*(car )?charg|charging cable|ev_charger' then 'ev_charger'
    when lower(coalesce(p_code, '') || ' ' || coalesce(p_name, '')) ~ 'phone[ _-]*mount|phone[ _-]*holder' then 'phone_mount'
    when lower(coalesce(p_code, '') || ' ' || coalesce(p_name, '')) ~ 'booster' then 'booster_seat'
    when lower(coalesce(p_code, '') || ' ' || coalesce(p_name, '')) ~ '(baby|child|car|infant)[ _-]*seat' then 'child_seat'
    else 'other' end
$$;

-- the charge for one unit not returned: its fixed amount, or the other rule (times its rental charge a unit, at least the minimum)
create or replace function app.unreturned_unit_cents(p_kind text, p_rental_unit_cents bigint) returns bigint
language sql stable security definer set search_path = public, app as $$
  select case p_kind
    when 'ev_charger' then s.unreturned_ev_charger_cents
    when 'phone_mount' then s.unreturned_phone_mount_cents
    when 'child_seat' then s.unreturned_child_seat_cents
    when 'booster_seat' then s.unreturned_booster_seat_cents
    else greatest(round(coalesce(p_rental_unit_cents, 0) * s.unreturned_other_times)::bigint, s.unreturned_other_min_cents) end
    from (select * from app.settings()) s
$$;

-- the add-ons of a booking that go in the car, each with what it costs if not returned
create or replace function app.unreturned_addons(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'quantity', x.quantity, 'kind', x.kind, 'unit_cents', x.unit_cents,
                                               'suggested_cents', x.unit_cents * x.quantity) order by x.sort_order, x.name), '[]'::jsonb)
    from (select ba.id, ba.name, ba.quantity, a.sort_order, app.unreturned_kind(a.code, ba.name) as kind,
                 app.unreturned_unit_cents(app.unreturned_kind(a.code, ba.name),
                   (select round(li.amount_cents::numeric / greatest(ba.quantity, 1))::bigint from booking_line_items li where li.id = ba.line_item_id and li.voided_at is null)) as unit_cents
            from booking_addons ba join addons a on a.id = ba.addon_id
           where ba.booking_id = p_booking and ba.status = 'confirmed' and not a.prepaid_fuel and ba.pricing_unit <> 'per_hour'
             and a.code not in ('flowers', 'winter_tire')) x
$$;
comment on function app.unreturned_addons(uuid) is 'Add-ons not returned (1108): the add-ons of a booking that go in the car, each with its charge if not returned (Program settings unreturned_*). A suggestion for the deposit review only.';

-- the public facts (the FAQ's tokens)
alter function app.site_facts_live() rename to site_facts_live_pre1108;
create function app.site_facts_live() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.site_facts_live_pre1108() || jsonb_build_object('unreturned', app.unreturned_schedule())
$$;
select pg_temp.copy_grants('app.site_facts_live()'::regprocedure, 'app.site_facts_live_pre1108()'::regprocedure);
delete from app.public_read_cache where key = 'site_facts';

-- the agreement's fine print: on a booking with add-ons in the car
alter function app.agreement_extra(uuid) rename to agreement_extra_pre1108;
create function app.agreement_extra(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.agreement_extra_pre1108(p_booking);
begin
  if v is not null and jsonb_array_length(app.unreturned_addons(p_booking)) > 0 then
    v := v || jsonb_build_object('unreturned', app.unreturned_schedule());
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.agreement_extra(uuid)'::regprocedure, 'app.agreement_extra_pre1108(uuid)'::regprocedure);

-- the FAQ (Payment and deposit): one answer, with the amounts as tokens
update site_content_blocks
   set data = jsonb_set(data, '{items}', (data -> 'items') || jsonb_build_array(jsonb_build_object(
     'question', 'What if an add-on is not returned?',
     'answer', 'Add-ons go back with the car. One that is not returned is charged at its replacement cost: {{unretCharger}} for an EV charger, {{unretMount}} for a phone mount, {{unretSeat}} for a child car seat and {{unretBooster}} for a booster seat. Any other add-on is {{unretTimes}} times its rental charge, at least {{unretMin}}. It is taken from the deposit or charged to the card on file, with the statement.'))),
       updated_at = now()
 where block_key = 'faq.payment' and jsonb_typeof(data -> 'items') = 'array'
   and not exists (select 1 from jsonb_array_elements(data -> 'items') q where q ->> 'question' = 'What if an add-on is not returned?');

-- ================================================================ 2. the deposit review: Add-ons returned
alter table deposit_review_items drop constraint if exists deposit_review_items_item_check;
alter table deposit_review_items add constraint deposit_review_items_item_check
  check (item in ('fuel', 'km', 'damage', 'late', 'cleaning', 'tickets', 'tolls', 'addons'));

-- the order of the items; 'addons' is on a review only when the booking had add-ons in the car
create or replace function app.drr_items() returns text[]
language sql immutable as $$ select array['fuel', 'km', 'damage', 'late', 'cleaning', 'tickets', 'tolls', 'addons'] $$;

create or replace function app.drr_item_label(p text) returns text
language sql immutable as $$
  select case p when 'fuel' then 'Fuel' when 'km' then 'Kilometres' when 'damage' then 'Damage' when 'late' then 'Late return'
                when 'cleaning' then 'Cleaning' when 'tickets' then 'Tickets' when 'tolls' then 'Highway tolls' when 'addons' then 'Add-ons returned' else p end
$$;

-- a review made from now on gets the item on a booking with add-ons in the car (the other seven as before)
alter function app.drr_ensure(uuid) rename to drr_ensure_pre1108;
create function app.drr_ensure(p_booking uuid) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  v boolean;
begin
  -- 0: the seven items as before; the add-ons item is added below, the count follows the rows (drr_state)
  v := app.drr_ensure_pre1108(p_booking);
  if v then
    delete from deposit_review_items where booking_id = p_booking and item = 'addons';
    if jsonb_array_length(app.unreturned_addons(p_booking)) > 0 then
      insert into deposit_review_items (booking_id, item) values (p_booking, 'addons') on conflict (booking_id, item) do nothing;
    end if;
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.drr_ensure(uuid)'::regprocedure, 'app.drr_ensure_pre1108(uuid)'::regprocedure);

-- 1010's drr_ensure inserts every item of drr_items(): the add-ons item is not one of a fresh review by itself
create or replace function app.drr_items_base() returns text[]
language sql immutable as $$ select array['fuel', 'km', 'damage', 'late', 'cleaning', 'tickets', 'tolls'] $$;
do $$
declare d text := pg_get_functiondef('app.drr_ensure_pre1108(uuid)'::regprocedure);
begin
  if position('unnest(app.drr_items())' in d) = 0 then raise exception '1108: drr_ensure changed'; end if;
  execute replace(d, 'unnest(app.drr_items())', 'unnest(app.drr_items_base())');
end $$;

-- the count is the review's own rows (seven, or eight with the add-ons)
alter function app.drr_state(uuid) rename to drr_state_pre1108;
create function app.drr_state(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when s is null then null
              else s || jsonb_build_object('items', (select count(*) from deposit_review_items i where i.booking_id = p_booking)) end
    from app.drr_state_pre1108(p_booking) s
$$;
select pg_temp.copy_grants('app.drr_state(uuid)'::regprocedure, 'app.drr_state_pre1108(uuid)'::regprocedure);

-- the facts: each add-on with its suggested charge if not returned (suggest only)
alter function app.drr_facts(uuid) rename to drr_facts_pre1108;
create function app.drr_facts(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_items jsonb := app.unreturned_addons(p_booking);
begin
  return app.drr_facts_pre1108(p_booking) || jsonb_build_object('addons', jsonb_build_object('items', v_items,
    'suggested_cents', (select coalesce(sum((x ->> 'suggested_cents')::bigint), 0) from jsonb_array_elements(v_items) x),
    'charged_cents', coalesce((select sum(li.amount_cents + li.hst_cents) from booking_line_items li
                                 where li.booking_id = p_booking and li.voided_at is null and li.amount_cents > 0 and li.stage in ('check_in', 'after_return')
                                   and (li.assessment_key = 'addon_not_returned' or li.description ilike '%not returned%')), 0),
    'suggest', 'ok'));
end $$;
select pg_temp.copy_grants('app.drr_facts(uuid)'::regprocedure, 'app.drr_facts_pre1108(uuid)'::regprocedure);

-- signing an item the review does not have (the add-ons item on a booking without add-ons) is refused
alter function app.drr_sign(uuid, jsonb) rename to drr_sign_pre1108;
create function app.drr_sign(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings := app.drr_booking(p);
begin
  if b.id is not null and coalesce(p ->> 'item', '') = 'addons'
     and not exists (select 1 from deposit_review_items i where i.booking_id = b.id and i.item = 'addons') then
    raise exception 'This booking had no add-ons in the car' using errcode = '22023';
  end if;
  return app.drr_sign_pre1108(p_user, p);
end $$;
select pg_temp.copy_grants('app.drr_sign(uuid, jsonb)'::regprocedure, 'app.drr_sign_pre1108(uuid, jsonb)'::regprocedure);

-- reviews still open for Fleet whose booking had add-ons in the car get the item now
insert into deposit_review_items (booking_id, item)
select r.booking_id, 'addons' from deposit_reviews r
 where r.fleet_done_at is null and jsonb_array_length(app.unreturned_addons(r.booking_id)) > 0
on conflict (booking_id, item) do nothing;

-- ================================================================ 3. invoices: the Blind Spot block, the named fees, how to pay
-- a value that names CarmaCars is never printed on an insurer invoice
create or replace function app.no_carmacars(p text) returns text
language sql immutable as $$ select case when p is null or btrim(p) = '' or p ~* 'carma' then null else btrim(p) end $$;

-- how to pay: direct deposit and Interac e-Transfer; p_brand 'blindspot' takes Blind Spot's, else CarmaCars'
create or replace function app.invoice_pay(p_brand text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  bs boolean := p_brand = 'blindspot' and coalesce(nullif(btrim(coalesce(s.bs_pay_account_name, '')), ''), nullif(btrim(coalesce(s.bs_pay_institution, '')), ''),
                  nullif(btrim(coalesce(s.bs_pay_institution_number, '')), ''), nullif(btrim(coalesce(s.bs_pay_transit_number, '')), ''),
                  nullif(btrim(coalesce(s.bs_pay_account_number, '')), ''), nullif(btrim(coalesce(s.bs_pay_etransfer_email, '')), '')) is not null;
  v jsonb;
begin
  v := jsonb_build_object(
    'account_name', case when bs then s.bs_pay_account_name else s.cc_pay_account_name end,
    'institution', case when bs then s.bs_pay_institution else s.cc_pay_institution end,
    'institution_number', case when bs then s.bs_pay_institution_number else s.cc_pay_institution_number end,
    'transit_number', case when bs then s.bs_pay_transit_number else s.cc_pay_transit_number end,
    'account_number', case when bs then s.bs_pay_account_number else s.cc_pay_account_number end,
    'etransfer_email', case when bs then s.bs_pay_etransfer_email else s.cc_pay_etransfer_email end);
  -- Blind Spot's invoice falls back to CarmaCars' details without any CarmaCars wording (an account name naming it is left out).
  -- The e-Transfer email is the owner's own choice for both sets (November 11: rent@carmacars.ca, the default), so it is kept.
  if p_brand = 'blindspot' then
    v := (select coalesce(jsonb_object_agg(k, to_jsonb(case when k = 'etransfer_email' then nullif(btrim(coalesce(x, '')), '') else app.no_carmacars(x) end)), '{}'::jsonb) from jsonb_each_text(v) e(k, x));
  else
    v := (select coalesce(jsonb_object_agg(k, to_jsonb(nullif(btrim(coalesce(x, '')), ''))), '{}'::jsonb) from jsonb_each_text(v) e(k, x));
  end if;
  return v;
end $$;
comment on function app.invoice_pay(text) is 'How to pay an invoice (1108): direct deposit and Interac e-Transfer from Program settings (bs_pay_* for Blind Spot, falling back to cc_pay_*). Empty values are null; the PDF leaves out an empty section.';

-- every fee of a booking by name (the rental charge and the insurer''s own fee lines apart), for the insurer invoice
create or replace function app.insurer_fee_items(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('description', x.label, 'amount_cents', x.cents) order by x.first, x.label), '[]'::jsonb)
    from (select coalesce(nullif(btrim(li.description), ''), ft.label, initcap(replace(li.charge_type, '_', ' '))) as label,
                 sum(li.amount_cents) as cents, min(ft.sort_order) as first
            from booking_line_items li join fee_types ft on ft.code = li.charge_type
           where li.booking_id = p_booking and li.voided_at is null and li.charged_to_renter and li.stage in ('booking', 'extension')
             and ft.family <> 'rental' and not (li.charge_type = any (app.insurer_fee_codes()))
           group by 1 having sum(li.amount_cents) <> 0) x
$$;

-- a draft: "Fees charged at booking" becomes the named fees when they add up to it
alter function app.draft_insurer_invoice(uuid, uuid) rename to draft_insurer_invoice_pre1108;
create function app.draft_insurer_invoice(p_booking uuid, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := app.draft_insurer_invoice_pre1108(p_booking, p_by);
  v_items jsonb := app.insurer_fee_items(p_booking);
  v_n bigint;
  v_amount bigint;
begin
  select e.n, (e.l ->> 'amount_cents')::bigint into v_n, v_amount
    from insurer_invoices ii cross join lateral jsonb_array_elements(ii.lines) with ordinality e(l, n)
   where ii.id = v_id and e.l ->> 'description' like 'Fees charged at booking%' limit 1;
  if v_n is null or jsonb_array_length(v_items) = 0
     or v_amount <> (select sum((x ->> 'amount_cents')::bigint) from jsonb_array_elements(v_items) x) then
    return v_id;
  end if;
  update insurer_invoices ii
     set lines = (select jsonb_agg(q.l order by q.k) from (
                    select e.l, e.n * 100 as k from jsonb_array_elements(ii.lines) with ordinality e(l, n) where e.n <> v_n
                    union all
                    select f.value, v_n * 100 + f.ord from jsonb_array_elements(v_items) with ordinality f(value, ord)) q)
   where ii.id = v_id;
  return v_id;
end $$;
select pg_temp.copy_grants('app.draft_insurer_invoice(uuid, uuid)'::regprocedure, 'app.draft_insurer_invoice_pre1108(uuid, uuid)'::regprocedure);

-- the PDF facts: the insurer invoice as Blind Spot Car Rental; how to pay on every invoice
alter function app.pdf_facts(text, text, uuid) rename to pdf_facts_pre1108;
create function app.pdf_facts(p_kind text, p_key text, p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  f jsonb := app.pdf_facts_pre1108(p_kind, p_key, p_user);
  s program_settings := app.settings();
  ii insurer_invoices;
begin
  if f is null then return f; end if;
  if p_kind = 'insurer_invoice' then
    select * into ii from insurer_invoices where id = app.file_key_id(p_key);
    f := f || jsonb_build_object(
      'billed_as', 'blindspot',
      'file_name', 'blindspot-invoice-' || coalesce(ii.invoice_number, 'draft') || '.pdf',
      'company', jsonb_build_object('brand', coalesce(app.no_carmacars(s.bs_billing_name), 'Blind Spot Car Rental'),
        'legal_name', s.company_legal_name,
        'address', app.no_carmacars(coalesce(nullif(s.company_address, ''), (select nullif(ss.mailing_address, '') from site_settings ss order by ss.created_at limit 1))),
        'hst_number', s.company_hst_number, 'phone', app.no_carmacars(s.bs_billing_phone), 'email', app.no_carmacars(s.bs_billing_email), 'site', null, 'logo_key', null),
      'fee_items', case when ii.booking_id is not null then app.insurer_fee_items(ii.booking_id) else '[]'::jsonb end,
      'pay', app.invoice_pay('blindspot'));
  elsif p_kind = 'owner_invoice' then
    f := f || jsonb_build_object('pay', app.invoice_pay('carmacars'));
  end if;
  return f;
end $$;
select pg_temp.copy_grants('app.pdf_facts(text, text, uuid)'::regprocedure, 'app.pdf_facts_pre1108(text, text, uuid)'::regprocedure);

-- a partner invoice (0547) is CarmaCars'
alter function app.partner_invoice_json(uuid) rename to partner_invoice_json_pre1108;
create function app.partner_invoice_json(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.partner_invoice_json_pre1108(p_id) || jsonb_build_object('pay', app.invoice_pay('carmacars'))
$$;
select pg_temp.copy_grants('app.partner_invoice_json(uuid)'::regprocedure, 'app.partner_invoice_json_pre1108(uuid)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['unreturned_schedule', 'unreturned_kind', 'unreturned_unit_cents', 'unreturned_addons', 'site_facts_live_pre1108',
                    'agreement_extra_pre1108', 'drr_items_base', 'drr_ensure_pre1108', 'drr_state_pre1108', 'drr_facts_pre1108', 'drr_sign_pre1108', 'no_carmacars', 'invoice_pay',
                    'insurer_fee_items', 'draft_insurer_invoice_pre1108', 'pdf_facts_pre1108', 'partner_invoice_json_pre1108'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
