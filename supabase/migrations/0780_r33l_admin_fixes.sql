-- 0780: release 33, part L (docs/changes/2026-11-07-r33-admin-fixes.md).
--   1. The identity review counts and approves the same items: "Approve all (N)" listed one more than the screen showed, and after
--      it ran it still said (1). One rule, app.doc_review_pending, decides which waiting uploads are counted, listed and approved
--      (a waiting image whose file was purged cannot be looked at, so it is neither counted nor approved; one not tied to a
--      driver of the booking is counted and now also listed, under "Other documents"). The Admin, Sales and Field versions use it.
--   2. A renter's expired request or offer that the same renter, for the same car and overlapping dates, replaced by a newer
--      request or offer leaves Requests: it keeps its number and history, bookings.superseded_by points to the newer one. Made
--      when a booking is made or expires, and once for the ones that exist (the backfill). An expired offer of this kind is also
--      no longer made a lead by 0741's job (the newer one speaks for the renter).
--   3. record_manual_payment: the receipt email to the owner is optional (p.receipt false, or app.paid_receipt = off). The
--      "Already paid" paths (a new one on the issued invoice, and First and last month) send no receipt unless it is ticked.
--   4. program_settings.google_drive_api_key (0760) is never written to audit_log (masked in audit_compact; the rows already in
--      the log are masked) and never read back in full (the settings read gives the last 4 characters only).
-- No applied migration is edited.
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

-- ================================================================ 1. the identity review: one rule
-- The waiting uploads of a booking that are counted, listed and approved together. p_kinds null: every kind but the proof of coverage.
create function app.doc_review_pending(p_booking uuid, p_kinds text[] default null) returns table (id uuid, kind text)
language sql stable security definer set search_path = public, app as $$
  select u.id, u.kind::text from verification_uploads u join documents d on d.id = u.document_id
   where u.booking_id = p_booking and u.status = 'submitted' and d.purged_at is null
     and (case when p_kinds is null then u.kind::text <> 'coverage_proof' else u.kind::text = any (p_kinds) end)
   order by u.uploaded_at
$$;
revoke all on function app.doc_review_pending(uuid, text[]) from public, anon, authenticated;
grant execute on function app.doc_review_pending(uuid, text[]) to service_role;

-- Admin and customer service (0151's body, the list of items from the one rule); 0169's wrapper calls it for them
create or replace function app.doc_review_approve_all_pre0169(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  u record;
  cp coverage_proofs;
  v_ok integer := 0;
  v_refused jsonb := '[]'::jsonb;
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = p ->> 'booking';
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if not app.doc_review_can(p_by, b.id) then
    raise exception 'Only an Admin or customer service reviews identity and coverage documents' using errcode = '42501';
  end if;
  for u in select x.id, x.kind from app.doc_review_pending(b.id) x loop
    begin
      perform app.review_verification_upload(u.id, p_by, true, null);
      v_ok := v_ok + 1;
    exception when others then
      v_refused := v_refused || jsonb_build_object('item', replace(u.kind, '_', ' '), 'message', sqlerrm);
    end;
  end loop;
  cp := app.current_coverage_proof(b.id);
  if cp.id is not null and cp.status = 'submitted' and cp.coverage_option in (1, 2) then
    begin
      perform app.review_coverage_proof(cp.id, p_by, true, null, jsonb_build_object('active_to_return', true, 'covers', true));
      v_ok := v_ok + 1;
    exception when others then
      v_refused := v_refused || jsonb_build_object('item', 'proof of coverage', 'message', sqlerrm);
    end;
  end if;
  if b.coverage_option = 3 and b.coverage_confirmed_at is null and b.status = 'confirmed'
     and exists (select 1 from booking_line_items li where li.booking_id = b.id and li.charge_type = 'coverage_sold' and li.voided_at is null) then
    begin
      perform app.confirm_protection_plan(b.id, p_by, null);
      v_ok := v_ok + 1;
    exception when others then
      v_refused := v_refused || jsonb_build_object('item', 'Protection Plan', 'message', sqlerrm);
    end;
  end if;
  return jsonb_build_object('approved', v_ok, 'refused', v_refused, 'readiness', app.booking_readiness(b.id));
end $$;

-- Sales (0169): the licence images and the selfie only
create or replace function app.doc_review_approve_all(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_b uuid;
  u record;
  v_ok integer := 0;
  v_refused jsonb := '[]'::jsonb;
begin
  select b.id into v_b from bookings b where b.id::text = p ->> 'booking' or b.booking_number = p ->> 'booking';
  if v_b is null or app.doc_review_can(p_by, v_b) or not app.sales_licence_can(p_by, v_b) then
    return app.doc_review_approve_all_pre0169(p_by, p);
  end if;
  for u in select x.id, x.kind from app.doc_review_pending(v_b, array['licence_front', 'licence_back', 'selfie']) x loop
    begin
      perform app.sales_licence_decide(p_by, u.id, true, null);
      v_ok := v_ok + 1;
    exception when others then
      v_refused := v_refused || jsonb_build_object('item', replace(u.kind, '_', ' '), 'message', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('approved', v_ok, 'refused', v_refused,
    'readiness', jsonb_build_object('all_drivers_verified', app.booking_readiness(v_b) -> 'all_drivers_verified'));
end $$;

-- Field staff (0162)
create or replace function app.field_licence_approve_all(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  j field_jobs := app.field_licence_job(p_user, nullif(p ->> 'job', '')::uuid);
  u record;
  v_ok integer := 0;
  v_refused jsonb := '[]'::jsonb;
begin
  for u in select x.id, x.kind from app.doc_review_pending(j.booking_id, array['licence_front', 'licence_back', 'selfie']) x loop
    begin
      perform app.field_licence_decide(p_user, u.id, true, null);
      v_ok := v_ok + 1;
    exception when others then
      v_refused := v_refused || jsonb_build_object('item', replace(u.kind, '_', ' '), 'message', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('approved', v_ok, 'refused', v_refused,
    'readiness', jsonb_build_object('all_drivers_verified', app.booking_readiness(j.booking_id) -> 'all_drivers_verified'));
end $$;

-- ================================================================ 2. duplicate expired requests and offers
alter table bookings add column superseded_by uuid references bookings (id);
comment on column bookings.superseded_by is 'A request or offer that expired and was replaced by a newer one of the same renter for the same car and overlapping dates (0780): hidden from Requests, the newer booking is this one. Nothing else about the booking changes.';
create index bookings_superseded_by on bookings (superseded_by) where superseded_by is not null;

-- Links the expired bookings of one renter and car to the newest booking of theirs that overlaps their dates.
create function app.expired_duplicates_archive(p_renter uuid default null, p_vehicle uuid default null) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  n integer := 0;
begin
  for r in
    select o.id as old_id, o.booking_number as old_number, k.id as keep_id, k.booking_number as keep_number
      from bookings o
      join lateral (select x.id, x.booking_number from bookings x
                     where x.renter_id = o.renter_id and x.vehicle_id = o.vehicle_id and x.id <> o.id
                       and x.status::text not in ('cancelled', 'no_show', 'declined')
                       and (x.created_at > o.created_at or (x.created_at = o.created_at and x.id > o.id))
                       and tstzrange(x.pickup_at, x.return_at) && tstzrange(o.pickup_at, o.return_at)
                     order by x.created_at desc, x.id desc limit 1) k on true
     where o.status::text = 'expired' and o.superseded_by is null and o.booking_type <> 'owner' and not o.is_placeholder
       and (p_renter is null or o.renter_id = p_renter) and (p_vehicle is null or o.vehicle_id = p_vehicle)
  loop
    update bookings set superseded_by = r.keep_id where id = r.old_id and superseded_by is null;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (null, 'booking_duplicate_archived', 'bookings', r.old_id::text, jsonb_build_object('booking_number', r.old_number, 'superseded_by', r.keep_id, 'newer_booking_number', r.keep_number));
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function app.expired_duplicates_archive(uuid, uuid) from public, anon, authenticated;
grant execute on function app.expired_duplicates_archive(uuid, uuid) to service_role;

create function app.bookings_expired_dupes() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'INSERT' or new.status::text = 'expired' then
    perform app.expired_duplicates_archive(new.renter_id, new.vehicle_id);
  end if;
  return null;
end $$;
create trigger bookings_zz_expired_dupes after insert or update of status on bookings for each row execute function app.bookings_expired_dupes();

-- Requests and offers (Admin and staff, one read): the linked ones are not listed
alter function app.admin_requests(uuid, jsonb) rename to admin_requests_pre0780;
create function app.admin_requests(p_admin uuid, p jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x order by n), '[]'::jsonb)
    from jsonb_array_elements(app.admin_requests_pre0780(p_admin, p)) with ordinality t(x, n)
   where not exists (select 1 from bookings b where b.id::text = x ->> 'id' and b.superseded_by is not null)
$$;
select pg_temp.copy_grants('app.admin_requests(uuid, jsonb)'::regprocedure, 'app.admin_requests_pre0780(uuid, jsonb)'::regprocedure);

-- 0741's job: no lead for a linked duplicate
create or replace function app.expired_offers_to_leads(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  v_lead uuid;
  v_task uuid;
  v_assignee uuid;
  v_car text;
  v_expired timestamptz;
  n integer := 0;
begin
  for r in
    select b.id, b.booking_number, b.vehicle_id, b.pickup_at, b.return_at, b.renter_id, b.updated_at,
           (select max(e.created_at) from booking_events e where e.booking_id = b.id and e.kind in ('offer_expired', 'request_expired')) as expired_at
      from bookings b
     where b.status = 'expired' and b.booking_type <> 'owner' and not b.is_placeholder
       and b.superseded_by is null
       and not exists (select 1 from leads l where l.source = 'expired_offer' and l.payload ->> 'booking_id' = b.id::text)
     order by b.id
  loop
    v_expired := coalesce(r.expired_at, r.updated_at);
    continue when v_expired > p_now - interval '7 days';
    declare
      rn renters;
    begin
      select * into rn from renters x where x.id = r.renter_id;
      continue when rn.id is null or rn.is_blocked or rn.merged_into is not null;
      continue when rn.email is null and rn.mobile is null;
      continue when app.email_is_test(rn.email);
      -- the renter booked anyway after the offer expired: nothing to win back
      continue when exists (select 1 from bookings x where x.renter_id = r.renter_id and x.id <> r.id
                              and x.status in ('confirmed', 'on_rent', 'returned', 'closed') and x.created_at > v_expired);
      v_car := coalesce(app.vehicle_name(r.vehicle_id), 'a car');
      v_assignee := app.lead_real_assignee();
      insert into leads (kind, name, email, phone, message, payload, source, vehicle_text, assigned_to, status)
      values ('contact', nullif(btrim(rn.legal_name), ''), nullif(lower(btrim(rn.email)), ''), nullif(btrim(rn.mobile), ''),
              format('Offer for the %s, %s to %s, expired on %s without an answer (booking %s).', v_car,
                     to_char(r.pickup_at at time zone 'America/Toronto', 'Mon FMDD, YYYY'), to_char(r.return_at at time zone 'America/Toronto', 'Mon FMDD, YYYY'),
                     to_char(v_expired at time zone 'America/Toronto', 'Mon FMDD, YYYY'), r.booking_number),
              jsonb_build_object('form', 'expired_offer', 'booking_id', r.id, 'booking_number', r.booking_number, 'renter_id', r.renter_id,
                                 'vehicle', v_car, 'pickup_at', r.pickup_at, 'return_at', r.return_at, 'expired_at', v_expired),
              'expired_offer', v_car, v_assignee, 'new')
      returning id into v_lead;
      v_task := app.raise_task(p_type => 'expired_offer_lead',
                               p_title => left(format('Win back %s: the offer for the %s expired', coalesce(nullif(btrim(rn.legal_name), ''), 'the renter'), v_car), 200),
                               p_detail => format('Wanted %s to %s. Booking %s. Call or text, then mark the lead contacted or closed.',
                                                  to_char(r.pickup_at at time zone 'America/Toronto', 'Mon FMDD'), to_char(r.return_at at time zone 'America/Toronto', 'Mon FMDD, YYYY'), r.booking_number),
                               p_renter => r.renter_id, p_related_table => 'leads', p_related_id => v_lead,
                               p_dedupe => 'expired_offer_lead:' || r.id);
      if v_task is not null and v_assignee is not null then
        update tasks set assigned_to = v_assignee where id = v_task;
      end if;
      n := n + 1;
    end;
  end loop;
  return n;
end $$;

-- the backfill (an offer expired 7 days or more ago that is a duplicate does not get a lead now)
select app.expired_duplicates_archive();

-- ================================================================ 3. the owner receipt is optional
create or replace function app.record_manual_payment(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i owner_invoices;
  b bookings;
  v_method text := coalesce(nullif(p ->> 'method', ''), 'e_transfer');
  v_ref text := nullif(btrim(coalesce(p ->> 'reference', '')), '');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_on date := coalesce(nullif(p ->> 'received_on', '')::date, app.today());
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_refuse text;
  v_pay uuid;
  v_doc uuid;
  v_id uuid;
  v_before text;
  v_after text;
  v_settles payments;
  v_key text;
  v_purpose text;
begin
  if p_by is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if v_method not in ('e_transfer', 'cheque', 'cash', 'bank_transfer', 'other') then
    raise exception 'Choose how it was paid: e-Transfer, cheque, cash, bank transfer or another way' using errcode = '22023';
  end if;
  if v_method in ('e_transfer', 'cheque', 'bank_transfer') and (v_ref is null or length(v_ref) < 3) then
    raise exception '%', case v_method when 'cheque' then 'Enter the reference (the cheque number)' when 'e_transfer' then 'Enter the reference (the e-Transfer reference number)'
                                       else 'Enter the reference of the bank transfer' end using errcode = '22023';
  end if;
  if v_method = 'other' and v_note is null then raise exception 'Say how it was paid in the note' using errcode = '22023'; end if;
  if v_on > app.today() then raise exception 'The date received cannot be in the future' using errcode = '22023'; end if;
  if v_on < app.today() - 400 then raise exception 'The date received is more than a year ago: check it' using errcode = '22023'; end if;

  if nullif(p ->> 'invoice', '') is not null then
    select * into i from owner_invoices where id::text = p ->> 'invoice' or invoice_number = upper(btrim(p ->> 'invoice')) for update;
    if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
    -- the same reference twice on one invoice is the same payment
    if v_ref is not null then
      select m.id into v_id from manual_payments m where m.owner_invoice_id = i.id and m.method = v_method and lower(m.reference) = lower(v_ref) and m.voided_at is null;
      if v_id is not null then
        if app.manual_payment_allowed(p_by, 1) is not null then raise exception '%', app.manual_payment_allowed(p_by, 1) using errcode = '42501'; end if;
        return jsonb_build_object('ok', true, 'repeat', true, 'id', v_id, 'invoice_status', i.status, 'balance_cents', i.balance_cents);
      end if;
    end if;
    v_amount := coalesce(v_amount, i.balance_cents);
    if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount received' using errcode = '22023'; end if;
    v_refuse := app.manual_payment_allowed(p_by, v_amount);
    if v_refuse is not null then raise exception '%', v_refuse using errcode = '42501'; end if;
    if i.status in ('processing', 'retry_processing') then
      raise exception 'A debit of invoice % is processing: wait for its result before recording another payment', i.invoice_number using errcode = '23514';
    end if;
    if i.status not in ('issued', 'failed', 'in_arrears', 'partially_deducted') or i.balance_cents <= 0 then
      raise exception 'Invoice % is % and owes nothing', i.invoice_number, i.status using errcode = '23514';
    end if;
    v_before := i.status;
  elsif nullif(p ->> 'booking', '') is not null then
    select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(p ->> 'booking')) for update;
    if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
    if nullif(p ->> 'settles_payment', '') is not null then
      select * into v_settles from payments where id = (p ->> 'settles_payment')::uuid and booking_id = b.id for update;
      if v_settles.id is null then raise exception 'That charge is not on this booking' using errcode = 'P0002'; end if;
      if v_settles.status <> 'failed' then raise exception 'That charge is % and is not waiting for payment', v_settles.status using errcode = '23514'; end if;
      v_amount := coalesce(v_amount, v_settles.amount_cents);
    end if;
    if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount received' using errcode = '22023'; end if;
    v_refuse := app.manual_payment_allowed(p_by, v_amount);
    if v_refuse is not null then raise exception '%', v_refuse using errcode = '42501'; end if;
    v_purpose := coalesce(nullif(p ->> 'purpose', ''), v_settles.purpose, 'post_rental');
    if v_purpose not in ('booking_total', 'extension', 'post_rental', 'toll_ticket', 'damage', 'deductible', 'other') then
      raise exception 'Unknown purpose %', v_purpose using errcode = '22023';
    end if;
    if v_ref is not null then
      select m.id into v_id from manual_payments m where m.booking_id = b.id and m.method = v_method and lower(m.reference) = lower(v_ref) and m.voided_at is null;
      if v_id is not null then return jsonb_build_object('ok', true, 'repeat', true, 'id', v_id); end if;
    end if;
  else
    raise exception 'Choose the invoice or the booking the payment is for' using errcode = '22023';
  end if;

  if p ? 'proof' and jsonb_typeof(p -> 'proof') = 'object' then
    if lower(coalesce(p #>> '{proof,sha256}', '')) !~ '^[0-9a-f]{64}$' or coalesce(p #>> '{proof,path}', '') !~ '^payments/' then
      raise exception 'The proof file is missing' using errcode = '22023';
    end if;
    insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, uploaded_by)
    values ('receipt', format('Proof of payment, %s %s', app.payment_method_label(v_method), coalesce(i.invoice_number, b.booking_number)),
            'documents', p #>> '{proof,path}', p #>> '{proof,mime}', lower(p #>> '{proof,sha256}'), p_by)
    returning id into v_doc;
  end if;

  v_key := v_method || ':' || coalesce(v_ref, gen_random_uuid()::text);
  insert into payments (owner_id, owner_invoice_id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_by)
  values (i.owner_id, i.id, b.id, b.renter_id,
          case when i.id is not null then case when i.kind = 'upfront' then 'owner_upfront' else 'owner_fees' end else v_purpose end,
          'charge', v_method, v_amount, 'succeeded', app.local_midnight(v_on) + interval '12 hours', p_by)
  returning id into v_pay;
  insert into payment_processor_details (payment_id, processor, processor_payment_id, raw)
  values (v_pay, 'offline', v_key, jsonb_strip_nulls(jsonb_build_object('reference', v_ref, 'received_on', v_on, 'note', v_note, 'recorded_by', p_by)));

  insert into manual_payments (payment_id, target, owner_invoice_id, booking_id, owner_id, renter_id, settles_payment_id, method, amount_cents, received_on,
                               reference, proof_document_id, note, recorded_by, invoice_status_before)
  values (v_pay, case when i.id is not null then 'owner_invoice' else 'booking' end, i.id, b.id, i.owner_id, b.renter_id, v_settles.id, v_method, v_amount, v_on,
          v_ref, v_doc, v_note, p_by, v_before)
  returning id into v_id;

  if i.id is not null then
    -- the receipt is this payment's own email (owner_payment_recorded), not the processor's "payment received"
    perform set_config('app.manual_payment', v_id::text, true);
    v_after := app.owner_invoice_apply_payment(i.id, v_amount, v_method, v_pay);
    perform set_config('app.manual_payment', '', true);
    select * into i from owner_invoices where id = i.id;
    update manual_payments set invoice_status_after = v_after where id = v_id;
    -- the automatic debit: nothing left, nothing debited; a smaller balance, a smaller debit (never more than the notice said)
    if i.status = 'paid' or i.balance_cents <= 0 then
      update owner_debit_attempts set status = 'canceled', skip_reason = format('paid by %s on %s', app.payment_method_label(v_method), app.fmt_day(v_on))
       where owner_invoice_id = i.id and status = 'scheduled';
      update owner_invoices set debit_on = null where id = i.id and debit_on is not null;
    else
      update owner_debit_attempts set amount_cents = i.balance_cents where owner_invoice_id = i.id and status = 'scheduled' and amount_cents > i.balance_cents;
    end if;
    -- 0780: the receipt email is optional. p.receipt false (or the setting app.paid_receipt = off, set by the paid-outside paths) records the payment quietly
    if coalesce(nullif(lower(p ->> 'receipt'), ''), nullif(current_setting('app.paid_receipt', true), ''), 'on') not in ('false', 'off', 'no') then
      perform app.ntf_emit('owner_payment_recorded', 'manual_payment', v_id, 'recorded',
        jsonb_build_object('owner_id', i.owner_id, 'vehicle_id', i.vehicle_id, 'owner_invoice_id', i.id));
    end if;
  else
    if v_settles.id is not null then
      update payments set next_retry_at = null where id = v_settles.id;
      update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Paid by ' || app.payment_method_label(v_method)
       where related_table = 'payments' and related_id = v_settles.id and status in ('open', 'in_progress', 'waiting');
    end if;
  end if;

  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'record_manual_payment', case when i.id is not null then 'owner_invoices' else 'bookings' end, coalesce(i.id, b.id)::text,
          jsonb_build_object('status', coalesce(v_before, b.status::text)),
          jsonb_build_object('manual_payment_id', v_id, 'payment_id', v_pay, 'method', v_method, 'amount_cents', v_amount, 'received_on', v_on,
                             'reference', v_ref, 'status', coalesce(v_after, b.status::text), 'proof_document_id', v_doc, 'note', v_note,
                             'receipt_emailed', i.id is not null and coalesce(nullif(lower(p ->> 'receipt'), ''), nullif(current_setting('app.paid_receipt', true), ''), 'on') not in ('false', 'off', 'no')));
  return jsonb_build_object('ok', true, 'id', v_id, 'payment_id', v_pay, 'invoice_status', v_after, 'balance_cents', i.balance_cents);
end $$;


-- The Approve step and First and last month "Already paid": quiet unless the receipt is asked for (payment.receipt true)
alter function app.oi_plan_invoice(uuid, uuid, jsonb, jsonb, uuid) rename to oi_plan_invoice_pre0780;
create function app.oi_plan_invoice(p_by uuid, p_vehicle uuid, p_terms jsonb, inv jsonb, p_application uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb;
  v_quiet boolean := coalesce(nullif(inv ->> 'action', ''), 'draft') = 'paid' and lower(coalesce(inv #>> '{payment,receipt}', '')) not in ('true', 'on', 'yes')
                     and coalesce(current_setting('app.paid_receipt', true), '') <> 'on';
begin
  if v_quiet then perform set_config('app.paid_receipt', 'off', true); end if;
  v := app.oi_plan_invoice_pre0780(p_by, p_vehicle, p_terms, inv, p_application);
  if v_quiet then perform set_config('app.paid_receipt', '', true); end if;
  return v;
end $$;
select pg_temp.copy_grants('app.oi_plan_invoice(uuid, uuid, jsonb, jsonb, uuid)'::regprocedure, 'app.oi_plan_invoice_pre0780(uuid, uuid, jsonb, jsonb, uuid)'::regprocedure);

-- First and last month recorded as paid (Admin > Today): p.receipt true sends the owner the receipt
alter function app.first_last_paid_record(uuid, jsonb) rename to first_last_paid_record_pre0780;
create function app.first_last_paid_record(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb;
  v_on boolean := lower(coalesce(p ->> 'receipt', '')) in ('true', 'on', 'yes');
begin
  if v_on then perform set_config('app.paid_receipt', 'on', true); end if;
  v := app.first_last_paid_record_pre0780(p_by, p);
  if v_on then perform set_config('app.paid_receipt', '', true); end if;
  return v;
end $$;
select pg_temp.copy_grants('app.first_last_paid_record(uuid, jsonb)'::regprocedure, 'app.first_last_paid_record_pre0780(uuid, jsonb)'::regprocedure);

-- ================================================================ 4. the Drive API key is never logged or shown in full
create or replace function app.audit_compact(p jsonb) returns jsonb
language sql immutable set search_path = public, app as $$
  select case when p is null or jsonb_typeof(p) <> 'object' then p
    else (select coalesce(jsonb_object_agg(e.key,
            case when e.key = any (array['google_drive_api_key']) and jsonb_typeof(e.value) <> 'null' then to_jsonb('[hidden]'::text)
                 when octet_length(e.value::text) > 4096
                 then jsonb_build_object('omitted', 'larger than 4 KB', 'md5', md5(e.value::text), 'bytes', octet_length(e.value::text))
                 else e.value end), '{}'::jsonb)
          from jsonb_each(p) e) end
$$;

-- the entries already in the log (append only: the guard is lifted for this one statement)
alter table audit_log disable trigger audit_log_append_only;
update audit_log set before = jsonb_set(before, '{google_drive_api_key}', to_jsonb('[hidden]'::text))
 where entity_table = 'program_settings' and before ? 'google_drive_api_key' and jsonb_typeof(before -> 'google_drive_api_key') <> 'null' and before ->> 'google_drive_api_key' <> '[hidden]';
update audit_log set after = jsonb_set(after, '{google_drive_api_key}', to_jsonb('[hidden]'::text))
 where entity_table = 'program_settings' and after ? 'google_drive_api_key' and jsonb_typeof(after -> 'google_drive_api_key') <> 'null' and after ->> 'google_drive_api_key' <> '[hidden]';
alter table audit_log enable trigger audit_log_append_only;

-- the settings read: the key itself is left out, with whether one is set and its last 4 characters
alter function app.admin_settings() rename to admin_settings_pre0780;
create function app.admin_settings() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_set(v, '{program}', (v -> 'program') - 'google_drive_api_key'
           || jsonb_build_object('google_drive_api_key_set', k is not null, 'google_drive_api_key_last4', right(k, 4)))
    from (select app.admin_settings_pre0780() v, (select nullif(btrim(google_drive_api_key), '') from program_settings where id = (app.settings()).id) k) x
$$;
select pg_temp.copy_grants('app.admin_settings()'::regprocedure, 'app.admin_settings_pre0780()'::regprocedure);

-- a saved row and a listed row do not carry it back either
alter function app.admin_save(uuid, text, jsonb) rename to admin_save_pre0780;
create function app.admin_save(p_admin uuid, p_table text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := app.admin_save_pre0780(p_admin, p_table, p);
begin
  if p_table = 'program_settings' and jsonb_typeof(v) = 'object' then v := v - 'google_drive_api_key'; end if;
  return v;
end $$;
select pg_temp.copy_grants('app.admin_save(uuid, text, jsonb)'::regprocedure, 'app.admin_save_pre0780(uuid, text, jsonb)'::regprocedure);

alter function app.admin_enrich(jsonb) rename to admin_enrich_pre0780;
create function app.admin_enrich(r jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.admin_enrich_pre0780(case when jsonb_typeof(r) = 'object' and r ? 'google_drive_api_key' then r - 'google_drive_api_key' else r end)
$$;
select pg_temp.copy_grants('app.admin_enrich(jsonb)'::regprocedure, 'app.admin_enrich_pre0780(jsonb)'::regprocedure);
