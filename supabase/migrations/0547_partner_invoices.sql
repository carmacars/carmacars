-- 0547: invoices to partners (body shops, tow trucks, storage yards, any partner) for their kickback on claim, towing or
-- storage money, and the funds they send (docs/changes/2026-11-07-r28-operations.md, A12).
--
-- The owner: "write invoices to them for when they have a big cheque they are receiving for claim profits or towing
-- profits or storage profits, and they have to give us their kickback ... easily send it off to the respective shop and
-- track the funds that have been sent over from each shop/claim."
--   partner_invoices          numbered (PI-000001, their own sequence), from the company's legal name, to a partner,
--                             linked to a claim (number, insurer, vehicle, renter) and a booking when there is one; due
--                             date; one reminder before and one after the due date (days editable, 0 = none); a private
--                             link to the PDF for the partner; draft, sent, void (paid, partly paid and overdue follow
--                             from the payments and the date).
--   partner_invoice_lines     description (default "Outsourced repair / towing / storage services", editable), quantity,
--                             amount, HST on or off per line (13%, the company's HST number); or a percentage of the
--                             partner's claim, tow or storage total (the partner's default kickback %, editable).
--   partner_invoice_payments  cheque, e-Transfer or cash: amount, date, reference, a photo of the cheque; voidable.
--   Sending: an email to the partner's contact with the link (notification partner_invoice), logged; send again any time.
--   Ledger: per partner and per claim, invoiced, received, outstanding; the Admin dashboard tile; a CSV for the bookkeeper.
--   Admin and Finance build and send them; the partner sees theirs on their partner page (read only, how to pay).
-- No applied migration is edited.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter table referral_partners add column if not exists default_kickback_bps integer check (default_kickback_bps between 0 and 10000);
alter table referral_partners add column if not exists billing_email text check (billing_email is null or billing_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');
comment on column referral_partners.default_kickback_bps is 'The partner''s usual kickback on its claim, towing or storage total, for invoices to it (0547); editable per invoice.';
alter table program_settings add column if not exists partner_invoice_payee text not null default '18122211 Canada Inc.';
alter table program_settings add column if not exists partner_invoice_etransfer text not null default 'rent@carmacars.ca';
alter table program_settings add column if not exists partner_invoice_due_days integer not null default 14 check (partner_invoice_due_days between 0 and 120);
comment on column program_settings.partner_invoice_payee is 'Invoices to partners (0547): who cheques are payable to, and the name the invoice is from.';
comment on column program_settings.partner_invoice_etransfer is 'Invoices to partners (0547): where the partner sends an e-Transfer.';

create sequence if not exists partner_invoice_seq;

create table if not exists partner_invoices (
  id                   uuid primary key default gen_random_uuid(),
  invoice_number       text unique,
  partner_id           uuid not null references referral_partners (id),
  status               text not null default 'draft' check (status in ('draft', 'sent', 'void')),
  kind                 text not null default 'repair' check (kind in ('repair', 'towing', 'storage', 'other')),
  issued_on            date,
  due_on               date,
  claim_number         text check (char_length(claim_number) <= 80),
  insurer_name         text check (char_length(insurer_name) <= 120),
  vehicle              text check (char_length(vehicle) <= 160),
  renter_name          text check (char_length(renter_name) <= 120),
  booking_id           uuid references bookings (id) on delete set null,
  partner_total_cents  bigint check (partner_total_cents >= 0),
  kickback_bps         integer check (kickback_bps between 0 and 10000),
  notes                text check (char_length(notes) <= 2000),
  subtotal_cents       bigint not null default 0,
  hst_cents            bigint not null default 0,
  total_cents          bigint not null default 0,
  paid_cents           bigint not null default 0,
  remind_before_days   integer not null default 3 check (remind_before_days between 0 and 60),
  remind_after_days    integer not null default 7 check (remind_after_days between 0 and 120),
  reminded_before_at   timestamptz,
  reminded_after_at    timestamptz,
  view_token           uuid not null default gen_random_uuid() unique,
  sent_at              timestamptz,
  sent_to              text,
  sends                integer not null default 0,
  voided_at            timestamptz,
  void_reason          text,
  created_by           uuid references users (id) on delete set null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create index if not exists partner_invoices_partner on partner_invoices (partner_id, created_at desc);
create index if not exists partner_invoices_claim on partner_invoices (claim_number) where claim_number is not null;

create table if not exists partner_invoice_lines (
  id           uuid primary key default gen_random_uuid(),
  invoice_id   uuid not null references partner_invoices (id) on delete cascade,
  sort         integer not null default 0,
  description  text not null check (char_length(btrim(description)) between 1 and 300),
  quantity     numeric(10, 2) not null default 1 check (quantity > 0),
  unit_cents   bigint not null default 0,
  percent_bps  integer check (percent_bps between 0 and 10000),
  base_cents   bigint check (base_cents >= 0),
  hst          boolean not null default true,
  amount_cents bigint not null default 0,
  hst_cents    bigint not null default 0
);
create index if not exists partner_invoice_lines_invoice on partner_invoice_lines (invoice_id, sort);

create table if not exists partner_invoice_payments (
  id           uuid primary key default gen_random_uuid(),
  invoice_id   uuid not null references partner_invoices (id),
  method       text not null check (method in ('cheque', 'e_transfer', 'cash')),
  amount_cents bigint not null check (amount_cents > 0),
  received_on  date not null,
  reference    text check (char_length(reference) <= 120),
  photo_path   text check (photo_path is null or photo_path ~ '^partner-invoices/[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|png)$'),
  note         text check (char_length(note) <= 500),
  recorded_by  uuid references users (id) on delete set null,
  recorded_at  timestamptz not null default now(),
  voided_at    timestamptz,
  voided_by    uuid references users (id) on delete set null
);
create index if not exists partner_invoice_payments_invoice on partner_invoice_payments (invoice_id);

do $$
declare t text;
begin
  foreach t in array array['partner_invoices', 'partner_invoice_lines', 'partner_invoice_payments'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('create trigger audit_%s after insert or update or delete on %I for each row execute function app.audit_row()', t, t);
  end loop;
end $$;
comment on table partner_invoices is 'Invoices to referral partners (body shops, tow trucks, storage) for their kickback on a claim, tow or storage total (0547).';
comment on table partner_invoice_lines is 'The lines of a partner invoice (0547): a fixed amount, or a percentage of the partner''s total; HST on or off per line.';
comment on table partner_invoice_payments is 'Money a partner sent for an invoice (0547): cheque, e-Transfer or cash.';

-- ================================================================ the email in the catalogue
-- CATALOGUE 0547 START (generated by supabase/seed/0547_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('partner_invoice', 'partner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', '{{reminder_line}} Invoice {{invoice_number}} from CarmaCars: {{invoice_total}}', 'Claim {{claim_number}}. Due {{due_on}}.', 'When Finance or an Admin sends it; the reminders on their days', 'An invoice to a partner (a body shop, tow truck or storage yard) for its kickback on a claim, towing or storage total is sent from the admin portal (Money > Partner invoices, Send), sent again, or reminded once before and once after its due date (migration 0547). The link opens the invoice PDF.', null, null, '[{"name":"claim_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"due_on","type":"string"},{"name":"etransfer","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_balance","type":"string"},{"name":"invoice_number","type":"string"},{"name":"invoice_total","type":"string"},{"name":"is_reminder","type":"boolean"},{"name":"opening_hours","type":"string","global":true},{"name":"partner_name","type":"string"},{"name":"payee","type":"string"},{"name":"pdf_url","type":"url"},{"name":"reminder_line","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/partner_invoice.html', 'templates/partner_invoice.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0547 END
update notification_catalogue set emitted_by = 'app.partner_invoice_email (0547)' where code = 'partner_invoice';

-- ================================================================ the state a person reads
create or replace function app.partner_invoice_state(i partner_invoices) returns text
language sql stable as $$
  select case when i.status = 'void' then 'void' when i.status = 'draft' then 'draft'
              when i.paid_cents >= i.total_cents and i.total_cents > 0 then 'paid'
              when i.due_on is not null and i.due_on < app.today() then 'overdue'
              when i.paid_cents > 0 then 'partly_paid' else 'sent' end
$$;

create or replace function app.partner_invoice_json(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'status', i.status, 'state', app.partner_invoice_state(i), 'kind', i.kind,
           'partner_id', i.partner_id, 'partner', jsonb_build_object('business_name', p.business_name, 'contact_name', p.contact_name, 'email', coalesce(p.billing_email, p.email),
             'address', concat_ws(', ', p.address_line1, p.city, p.province, p.postal_code), 'kind', p.kind, 'default_kickback_bps', p.default_kickback_bps),
           'issued_on', i.issued_on, 'due_on', i.due_on, 'claim_number', i.claim_number, 'insurer_name', i.insurer_name, 'vehicle', i.vehicle, 'renter_name', i.renter_name,
           'booking_id', i.booking_id, 'booking_number', (select b.booking_number from bookings b where b.id = i.booking_id),
           'partner_total_cents', i.partner_total_cents, 'kickback_bps', i.kickback_bps, 'notes', i.notes,
           'subtotal_cents', i.subtotal_cents, 'hst_cents', i.hst_cents, 'total_cents', i.total_cents, 'paid_cents', i.paid_cents, 'balance_cents', greatest(i.total_cents - i.paid_cents, 0),
           'remind_before_days', i.remind_before_days, 'remind_after_days', i.remind_after_days, 'sent_at', i.sent_at, 'sent_to', i.sent_to, 'sends', i.sends,
           'view_token', i.view_token, 'created_at', i.created_at,
           'lines', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'description', l.description, 'quantity', l.quantity, 'unit_cents', l.unit_cents, 'percent_bps', l.percent_bps,
                      'base_cents', l.base_cents, 'hst', l.hst, 'amount_cents', l.amount_cents, 'hst_cents', l.hst_cents) order by l.sort, l.id) from partner_invoice_lines l where l.invoice_id = i.id), '[]'::jsonb),
           'payments', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'method', x.method, 'amount_cents', x.amount_cents, 'received_on', x.received_on, 'reference', x.reference,
                      'photo_path', x.photo_path, 'voided_at', x.voided_at) order by x.received_on, x.recorded_at) from partner_invoice_payments x where x.invoice_id = i.id), '[]'::jsonb),
           'company', jsonb_build_object('payee', s.partner_invoice_payee, 'etransfer', s.partner_invoice_etransfer, 'hst_number', s.company_hst_number,
             'address', (select nullif(btrim(st.mailing_address), '') from site_settings st where st.singleton limit 1),
             'email', (select st.public_email from site_settings st where st.singleton limit 1), 'phone', (select coalesce(st.phone_display, st.phone) from site_settings st where st.singleton limit 1),
             'logo_key', (select st.logo_light_file_key from site_settings st where st.singleton limit 1)))
    from partner_invoices i join referral_partners p on p.id = i.partner_id cross join lateral (select (app.settings()).*) s
   where i.id = p_id
$$;

create or replace function app.partner_invoice_totals(p_id uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare v_bps integer := (app.settings()).hst_bps;
begin
  update partner_invoice_lines l
     set amount_cents = case when l.percent_bps is not null and l.base_cents is not null then round(l.base_cents * l.percent_bps / 10000.0)::bigint
                             else round(l.quantity * l.unit_cents)::bigint end
   where l.invoice_id = p_id;
  update partner_invoice_lines l set hst_cents = case when l.hst then round(l.amount_cents * v_bps / 10000.0)::bigint else 0 end where l.invoice_id = p_id;
  update partner_invoices i
     set subtotal_cents = coalesce((select sum(amount_cents) from partner_invoice_lines where invoice_id = p_id), 0),
         hst_cents = coalesce((select sum(hst_cents) from partner_invoice_lines where invoice_id = p_id), 0),
         paid_cents = coalesce((select sum(amount_cents) from partner_invoice_payments where invoice_id = p_id and voided_at is null), 0),
         updated_at = now()
   where i.id = p_id;
  update partner_invoices set total_cents = subtotal_cents + hst_cents where id = p_id;
end $$;

create or replace function app.partner_invoice_may(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app as $$ select app.user_is_admin(p_by) or app.user_runs_finance(p_by) $$;

create or replace function app.partner_invoice_default_line(p_kind text) returns text
language sql immutable as $$
  select case p_kind when 'towing' then 'Outsourced towing services' when 'storage' then 'Outsourced storage services'
                     when 'other' then 'Outsourced services' else 'Outsourced repair services' end
$$;

-- a draft made or changed: the header and every line (lines replace the draft's lines)
create or replace function app.partner_invoice_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i partner_invoices;
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  pt referral_partners;
  l jsonb;
  n integer := 0;
  v_kind text := coalesce(nullif(p ->> 'kind', ''), 'repair');
begin
  if not app.partner_invoice_may(p_by) then raise exception 'Finance or an Admin writes invoices to partners' using errcode = '42501'; end if;
  if v_id is not null then
    select * into i from partner_invoices where id = v_id for update;
    if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
    if i.status <> 'draft' then raise exception 'Invoice % is %: only a draft is changed (void it and make a new one)', i.invoice_number, i.status using errcode = '23514'; end if;
  end if;
  select * into pt from referral_partners where id = coalesce(nullif(p ->> 'partner_id', '')::uuid, i.partner_id);
  if pt.id is null then raise exception 'Choose the partner' using errcode = '22023'; end if;
  if v_kind not in ('repair', 'towing', 'storage', 'other') then raise exception 'Repair, towing, storage or other' using errcode = '22023'; end if;
  if v_id is null then
    insert into partner_invoices (partner_id, kind, created_by, kickback_bps) values (pt.id, v_kind, p_by, pt.default_kickback_bps) returning * into i;
  end if;
  update partner_invoices set
    partner_id = pt.id, kind = v_kind,
    due_on = nullif(p ->> 'due_on', '')::date,
    claim_number = nullif(left(btrim(coalesce(p ->> 'claim_number', '')), 80), ''), insurer_name = nullif(left(btrim(coalesce(p ->> 'insurer_name', '')), 120), ''),
    vehicle = nullif(left(btrim(coalesce(p ->> 'vehicle', '')), 160), ''), renter_name = nullif(left(btrim(coalesce(p ->> 'renter_name', '')), 120), ''),
    booking_id = (select b.id from bookings b where b.id::text = p ->> 'booking' or b.booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) limit 1),
    partner_total_cents = nullif(p ->> 'partner_total_cents', '')::bigint,
    kickback_bps = coalesce(nullif(p ->> 'kickback_bps', '')::integer, i.kickback_bps, pt.default_kickback_bps),
    notes = nullif(left(btrim(coalesce(p ->> 'notes', '')), 2000), ''),
    remind_before_days = coalesce(nullif(p ->> 'remind_before_days', '')::integer, i.remind_before_days),
    remind_after_days = coalesce(nullif(p ->> 'remind_after_days', '')::integer, i.remind_after_days)
   where id = i.id returning * into i;
  if p ? 'lines' then
    delete from partner_invoice_lines where invoice_id = i.id;
    for l in select * from jsonb_array_elements(coalesce(p -> 'lines', '[]'::jsonb)) loop
      n := n + 1;
      insert into partner_invoice_lines (invoice_id, sort, description, quantity, unit_cents, percent_bps, base_cents, hst)
      values (i.id, n, coalesce(nullif(btrim(l ->> 'description'), ''), app.partner_invoice_default_line(i.kind)),
              coalesce(nullif(l ->> 'quantity', '')::numeric, 1), coalesce(nullif(l ->> 'unit_cents', '')::bigint, 0),
              nullif(l ->> 'percent_bps', '')::integer,
              case when nullif(l ->> 'percent_bps', '') is not null then coalesce(nullif(l ->> 'base_cents', '')::bigint, i.partner_total_cents) end,
              coalesce((l ->> 'hst')::boolean, true));
    end loop;
  end if;
  perform app.partner_invoice_totals(i.id);
  return app.partner_invoice_json(i.id);
end $$;

-- sent: numbered on the first send, the email to the partner's contact (every send logged), due date set
create or replace function app.partner_invoice_send(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i partner_invoices;
  pt referral_partners;
  v_to text;
  s program_settings := app.settings();
begin
  if not app.partner_invoice_may(p_by) then raise exception 'Finance or an Admin sends invoices to partners' using errcode = '42501'; end if;
  select * into i from partner_invoices where id = (p ->> 'id')::uuid for update;
  if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if i.status = 'void' then raise exception 'This invoice is void' using errcode = '23514'; end if;
  if i.total_cents <= 0 then raise exception 'The invoice has no amount yet' using errcode = '23514'; end if;
  select * into pt from referral_partners where id = i.partner_id;
  v_to := coalesce(nullif(btrim(p ->> 'to'), ''), pt.billing_email, pt.email);
  if v_to is null or v_to !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'The partner has no email: add it on the partner, or type one' using errcode = '22023'; end if;
  if i.status = 'draft' then
    update partner_invoices set status = 'sent', invoice_number = coalesce(invoice_number, 'PI-' || lpad(nextval('partner_invoice_seq')::text, 6, '0')),
           issued_on = app.today(), due_on = coalesce(due_on, app.today() + s.partner_invoice_due_days)
     where id = i.id returning * into i;
  end if;
  if not coalesce((p ->> 'email')::boolean, true) then
    return app.partner_invoice_json(i.id);
  end if;
  perform app.partner_invoice_email(i.id, v_to, 'invoice');
  update partner_invoices set sent_at = now(), sent_to = v_to, sends = sends + 1 where id = i.id;
  return app.partner_invoice_json(i.id);
end $$;

-- the email (catalogue partner_invoice), straight into the outbox: the link to the PDF, the total, how to pay
create or replace function app.partner_invoice_email(p_id uuid, p_to text, p_why text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  j jsonb := app.partner_invoice_json(p_id);
  v_id uuid;
  v_base text := rtrim(coalesce((app.settings()).notify_base_url, 'https://carmacars.ca'), '/');
begin
  insert into notification_outbox (code, category, priority, audience, to_address, to_name, entity, entity_id, payload, missing_variables, dedupe_key, status, send_after)
  values ('partner_invoice', 'transactional', 2, 'partner', p_to, j -> 'partner' ->> 'business_name', 'partner_invoice', p_id,
    jsonb_build_object('invoice_number', j ->> 'invoice_number', 'partner_name', j -> 'partner' ->> 'business_name', 'first_name', coalesce(split_part(j -> 'partner' ->> 'contact_name', ' ', 1), 'there'),
      'invoice_total', app.fmt_money((j ->> 'total_cents')::bigint), 'invoice_balance', app.fmt_money((j ->> 'balance_cents')::bigint),
      'due_on', to_char((j ->> 'due_on')::date, 'Mon FMDD, YYYY'), 'claim_number', coalesce(j ->> 'claim_number', 'none'),
      'payee', j -> 'company' ->> 'payee', 'etransfer', j -> 'company' ->> 'etransfer',
      'pdf_url', v_base || '/api/partner-invoice/' || (j ->> 'view_token'), 'is_reminder', p_why <> 'invoice',
      'reminder_line', case p_why when 'before' then 'A reminder: this invoice is due soon.' when 'after' then 'This invoice is past its due date.' else '' end),
    '{}'::text[], 'partner_invoice:' || p_id || ':' || p_why || ':' || extract(epoch from now())::bigint, 'queued', now())
  returning id into v_id;
  return v_id;
exception when others then
  raise exception 'The email could not be queued: %', sqlerrm using errcode = '23514';
end $$;

create or replace function app.partner_invoice_pay(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i partner_invoices;
begin
  if not app.partner_invoice_may(p_by) then raise exception 'Finance or an Admin records partner payments' using errcode = '42501'; end if;
  select * into i from partner_invoices where id = (p ->> 'id')::uuid for update;
  if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if nullif(p ->> 'void_payment', '') is not null then
    update partner_invoice_payments set voided_at = now(), voided_by = p_by where id = (p ->> 'void_payment')::uuid and invoice_id = i.id and voided_at is null;
  else
    if i.status <> 'sent' then raise exception 'Record a payment on a sent invoice' using errcode = '23514'; end if;
    if p ->> 'method' not in ('cheque', 'e_transfer', 'cash') then raise exception 'Cheque, e-Transfer or cash' using errcode = '22023'; end if;
    if coalesce(nullif(p ->> 'amount_cents', '')::bigint, 0) <= 0 then raise exception 'Enter the amount received' using errcode = '22023'; end if;
    insert into partner_invoice_payments (invoice_id, method, amount_cents, received_on, reference, photo_path, note, recorded_by)
    values (i.id, p ->> 'method', (p ->> 'amount_cents')::bigint, coalesce(nullif(p ->> 'received_on', '')::date, app.today()),
            nullif(left(btrim(coalesce(p ->> 'reference', '')), 120), ''), nullif(p ->> 'photo_path', ''), nullif(left(btrim(coalesce(p ->> 'note', '')), 500), ''), p_by);
  end if;
  perform app.partner_invoice_totals(i.id);
  return app.partner_invoice_json(i.id);
end $$;

create or replace function app.partner_invoice_void(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.partner_invoice_may(p_by) then raise exception 'Finance or an Admin voids partner invoices' using errcode = '42501'; end if;
  if nullif(btrim(coalesce(p ->> 'reason', '')), '') is null then raise exception 'Give the reason' using errcode = '22023'; end if;
  update partner_invoices set status = 'void', voided_at = now(), void_reason = btrim(p ->> 'reason') where id = (p ->> 'id')::uuid and status <> 'void';
  if not found then raise exception 'Invoice not found or already void' using errcode = '23514'; end if;
  return app.partner_invoice_json((p ->> 'id')::uuid);
end $$;

-- the list and the ledger: every invoice (optionally one partner's or one claim's), the totals per partner and per claim
create or replace function app.partner_invoices_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_partner uuid := nullif(p ->> 'partner', '')::uuid;
  v_claim text := nullif(btrim(coalesce(p ->> 'claim', '')), '');
begin
  if not app.partner_invoice_may(p_by) then raise exception 'Finance or an Admin sees partner invoices' using errcode = '42501'; end if;
  if nullif(p ->> 'id', '') is not null then return app.partner_invoice_json((p ->> 'id')::uuid); end if;
  return jsonb_build_object(
    'invoices', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'state', app.partner_invoice_state(i), 'partner', p2.business_name, 'partner_id', i.partner_id,
                  'claim_number', i.claim_number, 'kind', i.kind, 'issued_on', i.issued_on, 'due_on', i.due_on, 'total_cents', i.total_cents, 'paid_cents', i.paid_cents,
                  'balance_cents', case when i.status = 'void' then 0 else greatest(i.total_cents - i.paid_cents, 0) end, 'created_at', i.created_at) order by i.created_at desc)
                 from partner_invoices i join referral_partners p2 on p2.id = i.partner_id
                where (v_partner is null or i.partner_id = v_partner) and (v_claim is null or i.claim_number = v_claim)), '[]'::jsonb),
    'by_partner', coalesce((select jsonb_agg(x order by x ->> 'partner') from (
                  select jsonb_build_object('partner_id', p2.id, 'partner', p2.business_name, 'invoiced_cents', sum(i.total_cents), 'received_cents', sum(i.paid_cents),
                         'outstanding_cents', sum(greatest(i.total_cents - i.paid_cents, 0))) as x
                    from partner_invoices i join referral_partners p2 on p2.id = i.partner_id where i.status = 'sent' group by p2.id, p2.business_name) q), '[]'::jsonb),
    'by_claim', coalesce((select jsonb_agg(x order by x ->> 'claim_number') from (
                  select jsonb_build_object('claim_number', i.claim_number, 'invoiced_cents', sum(i.total_cents), 'received_cents', sum(i.paid_cents),
                         'outstanding_cents', sum(greatest(i.total_cents - i.paid_cents, 0)), 'invoices', count(*)) as x
                    from partner_invoices i where i.status = 'sent' and i.claim_number is not null group by i.claim_number) q), '[]'::jsonb),
    'totals', (select jsonb_build_object('invoiced_cents', coalesce(sum(i.total_cents), 0), 'received_cents', coalesce(sum(i.paid_cents), 0),
                  'outstanding_cents', coalesce(sum(greatest(i.total_cents - i.paid_cents, 0)), 0),
                  'overdue', count(*) filter (where app.partner_invoice_state(i) = 'overdue')) from partner_invoices i
                where i.status = 'sent' and (v_partner is null or i.partner_id = v_partner) and (v_claim is null or i.claim_number = v_claim)),
    'partners', coalesce((select jsonb_agg(jsonb_build_object('id', p2.id, 'name', p2.business_name, 'kind', p2.kind, 'default_kickback_bps', p2.default_kickback_bps,
                  'email', coalesce(p2.billing_email, p2.email)) order by p2.business_name) from referral_partners p2), '[]'::jsonb));
end $$;

-- one reminder before and one after the due date
create or replace function app.partner_invoice_reminders(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  n integer := 0;
  v_today date := app.local_date(p_now);
begin
  for r in select i.id, i.sent_to, i.due_on, i.remind_before_days, i.remind_after_days, i.reminded_before_at, i.reminded_after_at
             from partner_invoices i where i.status = 'sent' and i.sent_to is not null and i.due_on is not null and i.paid_cents < i.total_cents loop
    if r.remind_before_days > 0 and r.reminded_before_at is null and v_today >= r.due_on - r.remind_before_days and v_today < r.due_on then
      perform app.partner_invoice_email(r.id, r.sent_to, 'before');
      update partner_invoices set reminded_before_at = p_now where id = r.id; n := n + 1;
    elsif r.remind_after_days > 0 and r.reminded_after_at is null and v_today >= r.due_on + r.remind_after_days then
      perform app.partner_invoice_email(r.id, r.sent_to, 'after');
      update partner_invoices set reminded_after_at = p_now where id = r.id; n := n + 1;
    end if;
  end loop;
  return n;
end $$;

alter function app.notify_booking_staff(timestamptz) rename to notify_booking_staff_pre0547;
create function app.notify_booking_staff(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v integer := app.notify_booking_staff_pre0547(p_now);
begin
  begin
    v := v + app.partner_invoice_reminders(p_now);
  exception when others then
    raise warning '0547 partner_invoice_reminders: %', sqlerrm;
  end;
  return v;
end $$;
select pg_temp.copy_grants('app.notify_booking_staff(timestamptz)'::regprocedure, 'app.notify_booking_staff_pre0547(timestamptz)'::regprocedure);

-- the partner's own: the PDF by its link, and their page (after the page checked its key)
create or replace function public.server_partner_invoice_by_token(p_token uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.partner_invoice_json(i.id) from partner_invoices i where i.view_token = p_token and i.status = 'sent'
$$;
create or replace function public.server_partner_invoices_of(p_partner uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('invoice_number', i.invoice_number, 'state', app.partner_invoice_state(i), 'issued_on', i.issued_on, 'due_on', i.due_on,
           'claim_number', i.claim_number, 'total_cents', i.total_cents, 'paid_cents', i.paid_cents, 'balance_cents', greatest(i.total_cents - i.paid_cents, 0),
           'view_token', i.view_token) order by i.issued_on desc), '[]'::jsonb)
    from partner_invoices i where i.partner_id = p_partner and i.status = 'sent'
$$;
revoke all on function public.server_partner_invoice_by_token(uuid), public.server_partner_invoices_of(uuid) from public, anon, authenticated;
grant execute on function public.server_partner_invoice_by_token(uuid), public.server_partner_invoices_of(uuid) to service_role;
revoke all on function app.partner_invoice_json(uuid), app.partner_invoice_totals(uuid), app.partner_invoice_may(uuid), app.partner_invoice_save(uuid, jsonb),
  app.partner_invoice_send(uuid, jsonb), app.partner_invoice_email(uuid, text, text), app.partner_invoice_pay(uuid, jsonb), app.partner_invoice_void(uuid, jsonb),
  app.partner_invoices_read(uuid, jsonb), app.partner_invoice_reminders(timestamptz) from public, anon, authenticated;

-- the partner's details for invoices
create or replace function app.partner_billing_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.partner_invoice_may(p_by) then raise exception 'Finance or an Admin sets a partner''s billing' using errcode = '42501'; end if;
  update referral_partners set default_kickback_bps = nullif(p ->> 'default_kickback_bps', '')::integer, billing_email = nullif(btrim(coalesce(p ->> 'billing_email', '')), ''), updated_at = now()
   where id = (p ->> 'partner')::uuid;
  if not found then raise exception 'Partner not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function app.partner_billing_save(uuid, jsonb) from public, anon, authenticated;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0547;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_call in ('ops_do', 'admin_do') and p_name in ('partner_invoice_save', 'partner_invoice_send', 'partner_invoice_pay', 'partner_invoice_void', 'partner_billing_save') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'partner_invoice_save' then app.partner_invoice_save(p_user, v) when 'partner_invoice_send' then app.partner_invoice_send(p_user, v)
                       when 'partner_invoice_pay' then app.partner_invoice_pay(p_user, v) when 'partner_billing_save' then app.partner_billing_save(p_user, v)
                       else app.partner_invoice_void(p_user, v) end;
  end if;
  if p_call = 'ops_read' and p_name = 'partner_invoices' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.partner_invoices_read(p_user, v);
  end if;
  return app.door_pre0547(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0547(uuid, text, text, text, jsonb)'::regprocedure);

-- the server runs every function of release 28 (0540 to 0547 revoked them from the public role, which service_role used)
do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and not has_function_privilege('service_role', p.oid, 'execute') loop
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
