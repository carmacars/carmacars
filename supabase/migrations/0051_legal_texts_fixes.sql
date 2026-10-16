-- 0051_legal_texts_fixes.sql
-- The defects found while collecting the legal texts for the lawyer (docs/changes/2026-10-16-legal-texts-fixes.md):
--   1. one Late Fee rule everywhere, the one the code applies and section 4.4 of the Enrollment Agreement sets ("If a
--      charge fails, CarmaCars adds the Late Fee for each Vehicle affected and retries on the Retry Date"): the Late
--      Fee is added once to an invoice when the bank returns its automatic debit (0007's trigger, unchanged), then the
--      debit is tried again from the retry day. app.owner_debit_terms() gives the sentence; the PAD agreement, the
--      Banking page and every owner billing email print it. An invoice merely unpaid, or a debit the owner started
--      from an invoice page, never had a Late Fee in the code; the "no debit on file" email said it did, and no longer
--   2. the program settings in words for every email (the debit, retry and payout days, notice and retention days,
--      the deductible and the other values the copy used to type): the copy reads them, never a typed "15th"
--   3. the PAD notice days: at least 10 (Payments Canada Rule H1 pre-notification; no owner agreement waives it),
--      enforced by the column's check; the default stays 10
--   4. CarmaCars' own PAD confirmation email when a debit mandate becomes active, with the payee as the business
--      name setting (the numbered company only when owner_debit_show_legal_name is on), address and phone from the
--      settings, the account's last 4, the timing, how to cancel and the recourse rights
--   5. the booking amendment countersigned automatically in CarmaCars' name, in the name of the staff member who
--      proposed or approved the change, when the renter signs (as the rental agreement of 0019 and 0046)
--   6. a paper signature recorded by staff: CarmaCars' automatic countersignature is dated when staff recorded it,
--      not the owner's paper date (the owner's record keeps the owner's date)
--   7. a rental added by hand is "awaiting signature" until the renter has signed (in the portal, or on paper recorded
--      by an Admin): the readiness, the field ready check, the Admin lists and the handover itself say so and refuse to
--      release the car. A past rental recorded for history is not concerned.
-- No earlier migration is edited. Function bodies are checked when called.

-- ================================================================ 1. settings
-- Rule H1: the payor gets the pre-notification of a variable amount at least 10 days before the debit. The owner PAD
-- agreement does not waive it, so the setting cannot go below 10.
update program_settings set owner_debit_notice_days = 10 where owner_debit_notice_days < 10;
do $$
declare
  c text;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.program_settings'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%owner_debit_notice_days%' loop
    execute format('alter table program_settings drop constraint %I', c);
  end loop;
end $$;
alter table program_settings add constraint program_settings_owner_debit_notice_days_check check (owner_debit_notice_days between 10 and 30);
comment on column program_settings.owner_debit_notice_days is
  'Days between the pre-debit notice and the debit: 10 to 30. Payments Canada Rule H1 asks for at least 10 days for a variable amount, and the owner PAD agreement does not waive it.';
alter table program_settings add column owner_debit_show_legal_name boolean not null default false;
comment on column program_settings.owner_debit_show_legal_name is
  'Off (default): the PAD agreement and its confirmation name the payee by the business name (company_trade_name). On: "<company_legal_name>, operating as <company_trade_name>".';

-- ================================================================ 2. the debit terms: one Late Fee rule, the payee
-- The one Late Fee rule, in the owner's words. Section 4.4 of the Enrollment Agreement and 0007's trigger: the Late Fee
-- once per invoice (each vehicle has its own invoice) when its automatic debit is returned, then the retry.
create or replace function app.owner_late_fee_rule() returns text
language sql stable security definer set search_path = public, app as $$
  select case when s.owner_debit_max_attempts > 1
              then format('If your bank returns the automatic debit of an invoice, we add the %s Late Fee to that invoice once and try again from the %s, as section 4.4 of your Enrollment Agreement sets out.',
                          app.fmt_money(s.owner_late_fee_cents), app.ordinal(s.retry_day))
              else format('If your bank returns the automatic debit of an invoice, we add the %s Late Fee to that invoice once and deduct what is owed from your next payout, as section 4.4 of your Enrollment Agreement sets out.',
                          app.fmt_money(s.owner_late_fee_cents)) end
    from app.settings() s
$$;

-- Who the owner authorizes: the business name (the numbered company only when the setting says so), the address and
-- phone of the settings (the same as the emails' footer), and the billing address that takes a cancellation.
create or replace function app.owner_debit_payee() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'name', case when s.owner_debit_show_legal_name and nullif(btrim(s.company_legal_name), '') is not null
                 then s.company_legal_name || ', operating as ' || s.company_trade_name else s.company_trade_name end,
    'address', coalesce(c ->> 'company_address', ''),
    'phone', coalesce(c ->> 'support_phone', ''),
    'email', 'billing@carmacars.ca')
    from app.settings() s cross join lateral (select app.ntf_contact() as c) k
$$;

create or replace function app.owner_debit_terms() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('debit_day', s.billing_day, 'retry_day', s.retry_day, 'notice_days', s.owner_debit_notice_days,
    'max_attempts', s.owner_debit_max_attempts, 'retry_gap_days', s.owner_debit_retry_gap_days, 'late_fee_cents', s.owner_late_fee_cents,
    'late_fee', app.fmt_money(s.owner_late_fee_cents), 'debit_day_text', app.ordinal(s.billing_day), 'retry_day_text', app.ordinal(s.retry_day),
    'payout_day_text', app.ordinal(s.payout_day),
    'interval_description', format('On the %s of each month for the fees on your CarmaCars invoices, with notice %s days before; a returned debit is tried again from the %s',
                                   app.ordinal(s.billing_day), s.owner_debit_notice_days, app.ordinal(s.retry_day)),
    'late_fee_rule', app.owner_late_fee_rule(),
    'own_debit_rule', 'A debit you start yourself from an invoice page that your bank returns adds no Late Fee: the invoice stays due and you can pay it again from its page.',
    'payee', app.owner_debit_payee())
    from app.settings() s
$$;

-- The numbers the owner application shows, with the debit and payout days in words (the wizard no longer types them).
create or replace function app.owner_program_facts() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'install_fee_cents', (app.settings()).install_fee_cents,
    'hst_bps', (app.settings()).hst_bps,
    'late_fee_cents', (app.settings()).owner_late_fee_cents,
    'trackers_available', coalesce((app.settings()).trackers_available, false),
    'debit_day_text', app.ordinal((app.settings()).billing_day),
    'payout_day_text', app.ordinal((app.settings()).payout_day),
    'grid', (select coalesce(jsonb_agg(jsonb_build_object('min_vehicles', g.min_vehicles, 'max_vehicles', g.max_vehicles,
                    'insurance_fee_cents', g.insurance_fee_cents, 'tracker_fee_cents', g.tracker_fee_cents, 'revenue_share_bps', g.revenue_share_bps)
                    order by g.min_vehicles), '[]'::jsonb)
               from owner_fee_grid g
              where g.effective_from = (select max(x.effective_from) from owner_fee_grid x where x.effective_from <= app.today())),
    'methods', (select coalesce(jsonb_agg(jsonb_build_object('method', i.method, 'label', i.label, 'open_to', i.open_to,
                    'estimate_cents', i.estimate_cents, 'estimate_with_lien_cents', i.estimate_with_lien_cents, 'plus_tax', i.plus_tax,
                    'typical_items', i.typical_items) order by i.estimate_cents), '[]'::jsonb) from onboarding_method_info i))
$$;

-- ================================================================ 3. the settings in words, for every email
create or replace function app.ntf_setting_words() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'debit_day', app.ordinal(s.billing_day), 'retry_day', app.ordinal(s.retry_day), 'payout_day', app.ordinal(s.payout_day),
    'approve_by_day', app.ordinal(greatest(s.payout_day - 1, 1)),
    'arrears_removal_days', s.owner_arrears_removal_days::text, 'notice_period_days', s.notice_period_days::text,
    'deductible_amount', app.fmt_money(s.deductible_cents), 'safety_certificate_days', s.safety_certificate_days::text,
    'retransfer_business_days', s.retransfer_business_days::text, 'refund_days', s.refund_business_days::text,
    'deposit_release_days', s.deposit_release_business_days::text, 'holdback_days', s.deposit_holdback_days::text,
    'min_renter_age', s.min_renter_age::text, 'id_retention_days', s.retention_id_face_days::text,
    'non_refundable_percent', trim_scale(s.non_refundable_discount_bps / 100.0)::text || '%',
    'incident_report_hours', s.incident_report_hours::text, 'interest_after_days', s.statement_interest_days::text)
    from app.settings() s
$$;

-- The merge values: the settings in words under every email (an emitter's own value wins), the Late Fee rule in every
-- owner email, the invoice's due date, and the PAD confirmation.
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_0046;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_0046(p_code, p_event, p_to);
  t jsonb;
  inv owner_invoices;
  m owner_payment_methods;
  o owners;
  s program_settings := app.settings();
begin
  x := app.ntf_setting_words() || coalesce(x, '{}'::jsonb);
  if p_code like 'owner\_%' then
    t := app.owner_debit_terms();
    x := x || jsonb_build_object('late_fee_rule', t ->> 'late_fee_rule');
  end if;
  if p_code = 'owner_fee_invoice' then
    select * into inv from owner_invoices where id = p_event.entity_id;
    x := x || jsonb_build_object('due_date', app.fmt_day(inv.billing_date));
  elsif p_code = 'owner_pad_confirmed' then
    select * into m from owner_payment_methods where id = p_event.entity_id;
    select * into o from owners where id = m.owner_id;
    x := x || jsonb_build_object(
      'first_name', coalesce(nullif(x ->> 'first_name', ''), o.first_name, split_part(o.legal_name, ' ', 1)),
      'payee_name', t #>> '{payee,name}', 'payee_address', t #>> '{payee,address}', 'payee_phone', t #>> '{payee,phone}',
      'payee_email', t #>> '{payee,email}',
      'bank_name', coalesce(nullif(btrim(m.brand_or_bank), ''), 'Bank'), 'bank_last4', coalesce(nullif(m.last4, ''), '----'),
      'agreement_type', case when o.owner_type = 'corporation' then 'Business' else 'Personal' end,
      'accepted_on', app.fmt_day(app.local_date(coalesce(m.authorized_at, m.created_at))),
      'first_debit_date', app.fmt_day(app.owner_debit_next_date(app.today())),
      'notice_days', s.owner_debit_notice_days::text,
      '_url', app.ntf_link('owner_banking'));
  end if;
  return x;
end $$;

-- ================================================================ 4. the PAD confirmation
-- A debit mandate becomes active: set up under Banking (at once, or after the micro-deposits), or saved with a debit
-- paid from an invoice page. Once per mandate (the dedupe key). Checked at the end of the transaction, on the row as it
-- stands then: a setup saved first and marked pending for its micro-deposits in the same call sends nothing yet.
create or replace function app.owner_pad_confirmed_emit() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  m owner_payment_methods;
begin
  select * into m from owner_payment_methods where id = new.id;
  if m.kind = 'pre_authorized_debit' and m.status = 'active' then
    perform app.ntf_emit('owner_pad_confirmed', 'owner_payment_method', m.id, 'active', jsonb_build_object('owner_id', m.owner_id));
  end if;
  return null;
end $$;
create constraint trigger owner_payment_methods_pad_confirmed after insert or update of status on owner_payment_methods
  deferrable initially deferred for each row execute function app.owner_pad_confirmed_emit();

-- ================================================================ 5. the booking amendment, countersigned
alter table booking_amendments add column countersignature_record_id uuid references signature_records (id);
comment on column booking_amendments.countersignature_record_id is
  'CarmaCars'' automatic countersignature (0051), made when the renter signs, in the name of the staff member who proposed or approved the change.';

-- Who signs the amendment for CarmaCars: the staff member who proposed the change or approved the renter's request,
-- else the signing officer of the settings, else the business name.
create or replace function app.amendment_countersigner(p_request uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('user_id', u.id,
           'name', coalesce(nullif(btrim(u.full_name), ''), nullif(btrim(s.signing_officer_name), ''), s.company_trade_name),
           'title', 'for ' || s.company_trade_name)
    from app.settings() s
    left join booking_change_requests c on c.id = p_request
    left join users u on u.id = c.decided_by
$$;

alter function app.sign_booking_amendment(uuid, uuid, text, text, text, text, inet, text) rename to sign_booking_amendment_0040;
create or replace function app.sign_booking_amendment(p_amendment uuid, p_by uuid, p_consent_text text, p_document_sha256 text,
    p_typed_name text default null, p_drawn_signature text default null, p_ip inet default null, p_user_agent text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.sign_booking_amendment_0040(p_amendment, p_by, p_consent_text, p_document_sha256, p_typed_name, p_drawn_signature, p_ip, p_user_agent);
  am booking_amendments;
  s program_settings := app.settings();
  v_cs jsonb;
  v_rec uuid;
begin
  select * into am from booking_amendments where id = p_amendment for update;
  if am.status = 'signed' and am.countersignature_record_id is null then
    v_cs := app.amendment_countersigner(am.change_request_id);
    insert into signature_records (signature_request_id, signer_role, signer_user_id, signer_name, signer_title, signer_email, status, signed_at,
                                   method, typed_name, consent_text, document_sha256)
    values (am.signature_request_id, 'carmacars', (v_cs ->> 'user_id')::uuid, v_cs ->> 'name', v_cs ->> 'title', s.company_email, 'signed', now(),
            'automatic', v_cs ->> 'name',
            format('Countersigned for %s automatically when the renter signed, in the name of the staff member who proposed or approved the change.', s.company_trade_name),
            am.document_sha256)
    returning id into v_rec;
    update booking_amendments set countersignature_record_id = v_rec where id = am.id;
  end if;
  return (select to_jsonb(x) from booking_amendments x where x.id = p_amendment);
end $$;

-- The amendment's facts name who will countersign (the unsigned document shows it).
alter function app.booking_change_facts(uuid, uuid) rename to booking_change_facts_0040;
create or replace function app.booking_change_facts(p_request uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  return app.booking_change_facts_0040(p_request, p_by) || jsonb_build_object('countersigner', app.amendment_countersigner(p_request));
end $$;

-- The signed copy prints both signatures.
create or replace function public.server_amendment_record(p_amendment uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('amendment', to_jsonb(a),
           'record', (select jsonb_build_object('signer_name', r.signer_name, 'method', r.method, 'signed_at', r.signed_at, 'ip_address', host(r.ip_address),
                                                'user_agent', r.user_agent, 'provider_signature', r.provider_signature, 'typed_name', r.typed_name,
                                                'consent_text', r.consent_text, 'document_sha256', r.document_sha256)
                        from signature_records r where r.id = a.signature_record_id),
           'countersign', (select jsonb_build_object('signer_name', r.signer_name, 'signer_title', r.signer_title, 'method', r.method, 'signed_at', r.signed_at,
                                                     'consent_text', r.consent_text, 'document_sha256', r.document_sha256)
                             from signature_records r where r.id = a.countersignature_record_id),
           'document', (select jsonb_build_object('bucket', d.storage_bucket, 'path', d.storage_path) from documents d where d.id = a.document_id))
    from booking_amendments a where a.id = p_amendment $$;

-- ================================================================ 6. paper signatures: CarmaCars signs when staff record it
-- While a paper signature is being recorded, CarmaCars' automatic countersignature takes the time of the recording;
-- the signer's and witnesses' records keep the date signed on paper (0044's app.paper_records).
create or replace function app.signature_records_countersign_now() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.signer_role = 'carmacars' and new.method = 'automatic' and coalesce(current_setting('app.paper_recording', true), '') = 'on' then
    new.signed_at := now();
  end if;
  return new;
end $$;
create trigger signature_records_countersign_now before insert on signature_records
  for each row execute function app.signature_records_countersign_now();

alter function app.record_paper_signature(uuid, jsonb) rename to record_paper_signature_0046;
create or replace function app.record_paper_signature(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
begin
  perform set_config('app.paper_recording', 'on', true);
  v_out := app.record_paper_signature_0046(p_by, p);
  perform set_config('app.paper_recording', '', true);
  return v_out;
end $$;

-- ================================================================ 7. rentals added by hand: awaiting signature
-- A rental staff added by hand is confirmed at once, but the renter has not signed yet: awaiting signature until the
-- agreement is completed (the renter signed in the portal, or an Admin recorded the paper copy, and CarmaCars
-- countersigned). A past rental recorded for history and an Owner Booking are not concerned.
create or replace function app.booking_awaiting_signature(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select b.status = 'confirmed' and b.added_by_staff and coalesce(b.added_mode, 'future') <> 'past' and b.booking_type <> 'owner'
                          and not exists (select 1 from signature_requests s where s.id = b.signature_request_id and s.status = 'completed')
                     from bookings b where b.id = p_booking), false)
$$;

alter function app.booking_readiness(uuid) rename to booking_readiness_0019;
create or replace function app.booking_readiness(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.booking_readiness_0019(p_booking);
  v_wait boolean := app.booking_awaiting_signature(p_booking);
begin
  return r || jsonb_build_object('awaiting_signature', v_wait,
                                 'ready_for_handover', coalesce((r ->> 'ready_for_handover')::boolean, false) and not v_wait);
end $$;

-- The handover itself: no car is released on a rental added by hand before the renter has signed.
create or replace function app.booking_signature_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'on_rent' and old.status is distinct from 'on_rent' and new.added_by_staff
     and coalesce(new.added_mode, 'future') <> 'past' and new.booking_type <> 'owner'
     and not exists (select 1 from signature_requests s where s.id = new.signature_request_id and s.status = 'completed') then
    raise exception 'Do not release the car: the renter has not signed the rental agreement yet (in the portal, or on paper recorded by an Admin)'
      using errcode = '23514';
  end if;
  return new;
end $$;
-- named to fire before the other handover checks (BEFORE triggers run in name order), so the reason given is this one
create trigger bookings_awaiting_signature_guard before update of status on bookings
  for each row execute function app.booking_signature_guard();

-- The field ready check says it too.
alter function app.field_read(uuid, text, jsonb) rename to field_read_0031;
create or replace function app.field_read(p_user uuid, p_what text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x jsonb := app.field_read_0031(p_user, p_what, p);
begin
  if p_what = 'job' and x is not null and jsonb_typeof(x -> 'ready') = 'object' and (x #>> '{booking,id}') is not null then
    x := jsonb_set(x, '{ready,signed}', to_jsonb(not app.booking_awaiting_signature((x #>> '{booking,id}')::uuid)));
    x := jsonb_set(x, '{booking,awaiting_signature}', to_jsonb(app.booking_awaiting_signature((x #>> '{booking,id}')::uuid)));
  end if;
  return x;
end $$;

-- The Admin lists of bookings show it (0030's enrichment, plus the flag on a booking row).
create or replace function app.admin_enrich(r jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select r
    || case when r ? 'vehicle_id' and r ->> 'vehicle_id' is not null and not r ? 'vehicle_name'
            then jsonb_build_object('vehicle_name', app.vehicle_name((r ->> 'vehicle_id')::uuid)) else '{}'::jsonb end
    || case when r ? 'booking_id' and r ->> 'booking_id' is not null and not r ? 'booking_number'
            then jsonb_build_object('booking_number', (select b.booking_number from bookings b where b.id = (r ->> 'booking_id')::uuid)) else '{}'::jsonb end
    || case when r ? 'renter_id' and r ->> 'renter_id' is not null and not r ? 'renter_name'
            then jsonb_build_object('renter_name', (select x.legal_name from renters x where x.id = (r ->> 'renter_id')::uuid)) else '{}'::jsonb end
    || case when r ? 'owner_id' and r ->> 'owner_id' is not null and not r ? 'owner_name'
            then jsonb_build_object('owner_name', (select o.legal_name from owners o where o.id = (r ->> 'owner_id')::uuid)) else '{}'::jsonb end
    || case when r ? 'insurer_id' and r ->> 'insurer_id' is not null and not r ? 'insurer_name'
            then jsonb_build_object('insurer_name', (select i.name from insurers i where i.id = (r ->> 'insurer_id')::uuid)) else '{}'::jsonb end
    || case when r ? 'assigned_to' and r ->> 'assigned_to' is not null
            then jsonb_build_object('assignee_name', (select u.full_name from users u where u.id = (r ->> 'assigned_to')::uuid)) else '{}'::jsonb end
    || case when r ? 'actor_user_id' and r ->> 'actor_user_id' is not null
            then jsonb_build_object('actor_name', (select u.full_name from users u where u.id = (r ->> 'actor_user_id')::uuid)) else '{}'::jsonb end
    || case when r ? 'investor_id' and r ->> 'investor_id' is not null and not r ? 'investor_name'
            then jsonb_build_object('investor_name', (select i.legal_name from investors i where i.id = (r ->> 'investor_id')::uuid)) else '{}'::jsonb end
    || case when r ? 'added_by_staff' and r ? 'booking_number' and r ? 'pickup_at' and r ->> 'id' is not null
            then jsonb_build_object('awaiting_signature', app.booking_awaiting_signature((r ->> 'id')::uuid)) else '{}'::jsonb end
$$;

-- ================================================================ 8. the email catalogue
-- the PAD confirmation, and the emails whose copy now reads the settings (their templates are loaded by the deploy)
-- CATALOGUE 0051 START (generated by supabase/seed/0051_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('owner_pad_confirmed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Your pre-authorized debit agreement with {{payee_name}}', 'Your confirmation for the account ending {{bank_last4}}. Keep it for your records.', 'Immediate, when the debit mandate becomes active', 'An owner''s pre-authorized debit mandate becomes active (set up under Banking, confirmed by micro-deposits, or saved with a debit paid from an invoice page). CarmaCars'' own confirmation of the pre-authorized debit agreement (Payments Canada Rule H1): the agreement, the payee and how to reach it, the account, the timing, how to cancel and the recourse rights. Sent once per debit mandate. An automatic debit is scheduled only with its notice, the notice days ahead, so this confirmation comes before the first automatic debit.', null, '/owner/banking', '[{"name":"accepted_on","type":"string"},{"name":"agreement_type","type":"string"},{"name":"bank_last4","type":"string"},{"name":"bank_name","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"debit_day","type":"string"},{"name":"first_debit_date","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"late_fee_rule","type":"string"},{"name":"notice_days","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_address","type":"string"},{"name":"payee_email","type":"string"},{"name":"payee_name","type":"string"},{"name":"payee_phone","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_pad_confirmed.html', 'templates/owner_pad_confirmed.txt'),
  ('owner_debit_notice', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Pre-authorized debit on {{debit_date}}: {{debit_total}}', '{{debit_count_text}} from your account ending {{bank_last4}}. Nothing to do if your account is up to date.', 'The notice days before the debit day (the 5th for the 15th by default)', 'Owner debit notice job, on the notice day (the debit day less the notice days in Program settings, 10 by default): the owner has issued invoices that will be debited automatically on the debit day from their pre-authorized debit account. One email per owner, listing every invoice in the debit. Required notice under the pre-authorized debit agreement.', null, '/owner/billing', '[{"name":"bank_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"debit_count_text","type":"string"},{"name":"debit_date","type":"string"},{"name":"debit_items","type":"list","fields":["invoice_number","vehicle","covers","amount"]},{"name":"debit_total","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"late_fee_rule","type":"string"},{"name":"notice_days","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_debit_notice.html', 'templates/owner_debit_notice.txt'),
  ('owner_debit_setup_needed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Set up your bank debit for {{debit_total}} due {{debit_date}}', 'We have no pre-authorized debit for your account, so nothing was scheduled. It takes two minutes.', 'The notice day, or the debit day when the agreement was cancelled since the notice', 'Owner debit notice job (or the debit run itself): the owner has invoices due for the automatic debit but no active pre-authorized debit agreement on file, or it was cancelled at the bank. Nothing is debited. One email per owner per debit date. An Admin gets the exception at the same time.', null, '/owner/banking', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"debit_date","type":"string"},{"name":"debit_day","type":"string"},{"name":"debit_items","type":"list","fields":["invoice_number","vehicle","covers","amount"]},{"name":"debit_total","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"late_fee_rule","type":"string"},{"name":"notice_days","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_debit_setup_needed.html', 'templates/owner_debit_setup_needed.txt'),
  ('owner_fee_invoice', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Invoice {{invoice_number}}: {{invoice_month}} fees for your {{vehicle_name}}, {{invoice_total}}', 'Due on {{due_date}}. Pay from the invoice page by card or pre-authorized debit.', '15th of each month', 'Owner-billing job on the 15th: a monthly owner invoice for a vehicle is issued and its pre-authorized debit is submitted. One invoice and one email per vehicle. Not sent for Turo-Only vehicles or vehicles owned personally by the two principals. (Message template T24.)', 'T24', '/owner/invoices/{{invoice_number}}', '[{"name":"bank_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"due_date","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_lines","type":"list","fields":["label","amount"]},{"name":"invoice_month","type":"string"},{"name":"invoice_number","type":"string"},{"name":"invoice_period","type":"string"},{"name":"invoice_total","type":"string"},{"name":"late_fee_rule","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"},{"name":"vehicle_plate","type":"string"}]'::jsonb, 'templates/owner_fee_invoice.html', 'templates/owner_fee_invoice.txt'),
  ('owner_payment_failed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Your {{amount}} payment for the {{vehicle_name}} failed', 'A {{late_fee}} late fee applies. We retry on {{retry_date}}.', 'The day the bank reports the failed debit', 'Debit-results job (15th to 25th, daily): the debit for a monthly owner invoice is returned and the invoice status becomes failed, which adds the Late Fee to that vehicle. One email per vehicle. (Message template T25.)', 'T25', '/owner/billing', '[{"name":"amount","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_month","type":"string"},{"name":"invoice_number","type":"string"},{"name":"late_fee","type":"string"},{"name":"late_fee_rule","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"retry_amount","type":"string"},{"name":"retry_date","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_payment_failed.html', 'templates/owner_payment_failed.txt'),
  ('owner_in_arrears', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'In arrears: {{arrears_amount}} owing on your {{vehicle_name}}', 'The retry failed. Pay by {{removal_date}} to keep the vehicle in the program.', 'The day the bank reports the failed retry (18th or after)', 'Debit-retry job on the 18th: the retry of a failed owner invoice also fails and the invoice status becomes in_arrears (the vehicle''s arrears flag is set).', null, '/owner/invoices/{{invoice_number}}', '[{"name":"amount","type":"string"},{"name":"arrears_amount","type":"string"},{"name":"arrears_removal_days","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_number","type":"string"},{"name":"is_self_managed","type":"boolean"},{"name":"late_fee","type":"string"},{"name":"next_payout_date","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"removal_date","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_in_arrears.html', 'templates/owner_in_arrears.txt'),
  ('owner_fee_change_notice', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Notice of a change to your terms for the {{vehicle_name}}, from {{effective_date}}', '{{fee_change_summary}}', 'Immediate, at least 30 days before the effective date', 'An admin schedules a change to a vehicle''s Insurance Fee or Tracker Fee (a fee history row with a future effective date), or proposes a new Revenue Share (a new Vehicle Schedule opened for signature). One email per vehicle. A fee change must be sent at least 30 days before its effective date. is_share_change is true when the Revenue Share changes, which needs the owner''s signature.', null, '/owner/agreements', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"debit_day","type":"string"},{"name":"effective_date","type":"string"},{"name":"fee_change_reason","type":"string"},{"name":"fee_change_summary","type":"string"},{"name":"fee_changes","type":"list","fields":["label","before","after"]},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"is_share_change","type":"boolean"},{"name":"notice_days","type":"string"},{"name":"notice_period_days","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_id","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_fee_change_notice.html', 'templates/owner_fee_change_notice.txt'),
  ('owner_payout_sent', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Payout sent: {{payout_amount}} for {{statement_month}}', 'By bank transfer to your account ending {{bank_last4}}.', '10th of each month, when the transfer is sent', 'A payout row for an owner changes to paid (an admin sent the bank transfer and recorded its reference). Normally the 10th. Not sent when the statement shows a balance owing instead of a payout. (Message template T26, payment part.)', 'T26', '/owner/statements/{{statement_number}}', '[{"name":"bank_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"payment_date","type":"string"},{"name":"payout_amount","type":"string"},{"name":"payout_day","type":"string"},{"name":"payout_reference","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"statement_month","type":"string"},{"name":"statement_number","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_payout_sent.html', 'templates/owner_payout_sent.txt'),
  ('owner_vehicle_enrolled', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Written confirmation: your {{vehicle_name}} is on the fleet policy', 'Enrollment Date {{enrollment_date}}. You may now cancel your own insurance on it.', 'Immediate', 'Vehicle onboarding status changes to enrolled (the insurer''s confirmation is filed and the vehicle is on the fleet policy). This email is the written confirmation that sets the Enrollment Date. (Message template T22.)', 'T22', '/owner/vehicles/{{vehicle_id}}', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"debit_day","type":"string"},{"name":"enrollment_date","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_id","type":"string"},{"name":"vehicle_name","type":"string"},{"name":"vehicle_plate","type":"string"},{"name":"vehicle_vin","type":"string"}]'::jsonb, 'templates/owner_vehicle_enrolled.html', 'templates/owner_vehicle_enrolled.txt'),
  ('owner_vehicle_listed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Your {{vehicle_name}} is live and open for bookings', 'Approved and listed on carmacars.ca. Check the rates and block any dates you need.', 'Immediate', 'Vehicle status changes from ready_to_list to available and its listing is published (staff approved the listing).', null, '/owner/vehicles/{{vehicle_id}}/calendar', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"daily_rate","type":"string"},{"name":"deposit_amount","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"km_per_day","type":"string"},{"name":"monthly_rate","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payout_day","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_id","type":"string"},{"name":"vehicle_image_url","type":"url"},{"name":"vehicle_name","type":"string"},{"name":"weekend_rate","type":"string"},{"name":"weekly_rate","type":"string"}]'::jsonb, 'templates/owner_vehicle_listed.html', 'templates/owner_vehicle_listed.txt'),
  ('owner_booking_confirmed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Confirmed: your own booking of the {{vehicle_name}}, {{pickup_date}}', 'No rental charge or deposit. Booking {{booking_number}}.', 'Immediate', 'A booking of type owner (an Owner Booking: the owner driving their own vehicle) changes to confirmed, after the owner signs the Owner Rental agreement and staff confirm the licence is valid.', null, '/owner/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deductible_amount","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_place","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_booking_confirmed.html', 'templates/owner_booking_confirmed.txt'),
  ('owner_onboarding_steps', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Next steps to enrol your {{vehicle_name}}', 'What to get, what to bring, and what the registry will cost you.', 'Immediate', 'Vehicle onboarding status changes to upfront_paid (or straight from documents_signed for a shareholder-owned vehicle). Lists the steps and documents for that vehicle''s onboarding method.', null, '/owner/vehicles/{{vehicle_id}}/onboarding', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"documents_needed","type":"list","fields":["name","status"]},{"name":"first_name","type":"string"},{"name":"government_forms","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"onboarding_estimate","type":"string"},{"name":"onboarding_method","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"owner_to_obtain","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"safety_certificate_days","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_id","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_onboarding_steps.html', 'templates/owner_onboarding_steps.txt'),
  ('owner_registry_visit', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Registry visit booked: {{visit_date}} at {{visit_time}}', 'For your {{vehicle_name}}. Bring the items on this list.', 'Immediate', 'Vehicle onboarding status changes to registry_booked (Fleet booked the registry visit), and again if the date, time or place changes. (Message template T21.)', 'T21', '/owner/vehicles/{{vehicle_id}}/onboarding', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"onboarding_estimate","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"safety_certificate_days","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_id","type":"string"},{"name":"vehicle_name","type":"string"},{"name":"visit_date","type":"string"},{"name":"visit_items","type":"list","fields":["name"]},{"name":"visit_place","type":"string"},{"name":"visit_time","type":"string"}]'::jsonb, 'templates/owner_registry_visit.html', 'templates/owner_registry_visit.txt'),
  ('owner_exit_notice_received', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Exit notice received for your {{vehicle_name}}. Exit Date {{exit_date}}', 'What happens between now and then, and what we need from you.', 'Immediate', 'Vehicle status changes to exit_notice (the owner''s written notice naming the vehicle is logged, or an admin decides to remove it) and the Exit Date is set. This email confirms the Exit Date in writing.', null, '/owner/vehicles/{{vehicle_id}}/exit', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"exit_date","type":"string"},{"name":"exit_date_basis","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"notice_date","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"retransfer_business_days","type":"string"},{"name":"retransfer_fee_note","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_id","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_exit_notice_received.html', 'templates/owner_exit_notice_received.txt'),
  ('staff_owner_invoice_failed', 'staff_va_finance', array['staff_admin']::text[], 'transactional', true, 'next', 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'Owner debit {{failure_stage}}: {{owner_name}}, {{vehicle_name}}, {{amount}}', 'Invoice {{invoice_number}}. {{failure_next_step}}', 'Next digest. Immediate to admins when the retry fails', 'An owner invoice changes to failed (first debit returned) or in_arrears (retry on the 18th returned). Queued for the next finance digest. The in_arrears case is also sent immediately to both admins.', null, '/va/finance/owner-invoices/{{invoice_number}}', '[{"name":"amount","type":"string"},{"name":"arrears_amount","type":"string"},{"name":"bank_reason","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"failure_next_step","type":"string"},{"name":"failure_stage","type":"string"},{"name":"invoice_month","type":"string"},{"name":"invoice_number","type":"string"},{"name":"late_fee","type":"string"},{"name":"owner_name","type":"string"},{"name":"payout_day","type":"string"},{"name":"retry_day","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_owner_invoice_failed.html', 'templates/staff_owner_invoice_failed.txt'),
  ('staff_statements_ready_for_approval', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', '{{statement_month}} owner statements are ready for approval', '{{statement_count}} statements, {{payout_total}} to pay on the {{payout_day}}. Approve by the {{approve_by_day}}.', '5th of each month, reminder on the 8th', 'Statements-draft job on the 5th at 06:00: the draft owner statements for last month are built and an approval task is raised. One email to both admins. A reminder is sent on the 8th at 09:00 if the run is still not approved.', null, '/admin/statements', '[{"name":"approve_by_day","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"deductions_total","type":"string"},{"name":"kickbacks_earned","type":"string"},{"name":"negative_balances","type":"string"},{"name":"owner_revenue_total","type":"string"},{"name":"payout_day","type":"string"},{"name":"payout_total","type":"string"},{"name":"revenue_share_total","type":"string"},{"name":"staff_kickbacks","type":"string"},{"name":"statement_count","type":"string"},{"name":"statement_flags","type":"string"},{"name":"statement_month","type":"string"}]'::jsonb, 'templates/staff_statements_ready_for_approval.html', 'templates/staff_statements_ready_for_approval.txt'),
  ('renter_booking_cancelled', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Booking {{booking_number}} is cancelled. Refund {{refund_amount}}', 'Received {{cancellation_received_at}}. {{refund_percent}} of {{amount_paid}} is refunded.', 'Immediate', 'Booking status changes from confirmed to cancelled or no_show with a booking cancellation row where cancelled_by is renter (the database computes the tier, percent and refund). (Message template T12.)', 'T12', '/terms#cancellation', '[{"name":"amount_paid","type":"string"},{"name":"booking_number","type":"string"},{"name":"cancellation_received_at","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"has_refund","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_time","type":"string"},{"name":"refund_amount","type":"string"},{"name":"refund_days","type":"string"},{"name":"refund_percent","type":"string"},{"name":"refund_tier","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_booking_cancelled.html', 'templates/renter_booking_cancelled.txt'),
  ('renter_booking_cancelled_by_us', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'We have had to cancel booking {{booking_number}}. Full refund', '{{refund_amount}} is going back to your card. We are sorry.', 'Immediate', 'Booking status changes from confirmed to cancelled with a booking cancellation row where the cancelling party is CarmaCars (no car or accepted substitute), or where the reason is that a driver could not be verified. The refund is 100%, including non-refundable bookings.', null, '/cars', '[{"name":"booking_number","type":"string"},{"name":"cancel_reason","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"refund_amount","type":"string"},{"name":"refund_days","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_booking_cancelled_by_us.html', 'templates/renter_booking_cancelled_by_us.txt'),
  ('renter_offer_withdrawn', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'We have withdrawn your offer for the {{vehicle_name}}', 'Nothing was booked. We are checking what else we can offer for your dates.', 'Immediate', 'A booking_offers row becomes withdrawn: staff take the offer back (booking event offer_withdrawn), or the system pushes the booking back from offered or pending_payment to requested because another booking was confirmed for the same car on overlapping dates (booking event pushed_back). Not sent when staff replace the offer with a revised one in the same action; renter_offer_ready covers that.', null, '/account/bookings/{{booking_number}}/request', '[{"name":"amount_paid","type":"string"},{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"has_amount_paid","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_time","type":"string"},{"name":"refund_days","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"},{"name":"withdraw_reason","type":"string"}]'::jsonb, 'templates/renter_offer_withdrawn.html', 'templates/renter_offer_withdrawn.txt'),
  ('renter_refund_issued', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Refund of {{refund_amount}} sent, booking {{booking_number}}', 'Back to your {{card_brand}} ending {{card_last4}}. Allow up to 10 business days.', 'Immediate', 'A refund row reaches status succeeded at the processor, for any refund except one already reported by a cancellation email sent in the same hour. Covers refunds for unused time after a breakdown, corrections and a charged deposit returned.', null, '/account/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"card_brand","type":"string"},{"name":"card_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"payment_date","type":"string"},{"name":"refund_amount","type":"string"},{"name":"refund_days","type":"string"},{"name":"refund_reason","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_refund_issued.html', 'templates/renter_refund_issued.txt'),
  ('renter_return_complete', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Returned. Thanks for renting the {{vehicle_name}}', 'Checked in at {{checkin_time}}. Your statement follows within 7 business days.', 'Immediate', 'Booking status changes to returned (keys taken, return condition report signed).', null, '/account/bookings/{{booking_number}}/condition-report', '[{"name":"booking_number","type":"string"},{"name":"checkin_date","type":"string"},{"name":"checkin_time","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deposit_amount","type":"string"},{"name":"deposit_release_days","type":"string"},{"name":"first_name","type":"string"},{"name":"fuel_in","type":"string"},{"name":"fuel_out","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"km_allowance","type":"string"},{"name":"km_driven","type":"string"},{"name":"odometer_in","type":"string"},{"name":"odometer_out","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"return_findings","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_return_complete.html', 'templates/renter_return_complete.txt'),
  ('renter_final_statement', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Your final statement for booking {{booking_number}}', 'Charges {{charges_total}}. Deposit returned {{deposit_returned}}.', 'When the statement is issued, within 7 business days of check-in', 'A renter statement for a returned booking is issued (statement sent_at is set by Finance), which captures charges from the deposit and releases the balance. Due within 7 business days of check-in. (Message template T9.)', 'T9', '/account/bookings/{{booking_number}}/statement', '[{"name":"booking_number","type":"string"},{"name":"card_charged","type":"string"},{"name":"card_last4","type":"string"},{"name":"charges_total","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deposit_amount","type":"string"},{"name":"deposit_applied","type":"string"},{"name":"deposit_held_back","type":"string"},{"name":"deposit_return_note","type":"string"},{"name":"deposit_returned","type":"string"},{"name":"first_name","type":"string"},{"name":"has_card_charge","type":"boolean"},{"name":"has_charges","type":"boolean"},{"name":"has_holdback","type":"boolean"},{"name":"holdback_days","type":"string"},{"name":"holdback_reason","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"statement_lines","type":"list","fields":["label","amount"]},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_final_statement.html', 'templates/renter_final_statement.txt'),
  ('renter_identity_needed', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Upload your licence and coverage proof for {{pickup_date}}', 'We need them by {{verify_by}}. No car is released without them.', 'On confirmation, then 48 hours before pickup if still missing', 'Booking status becomes confirmed while any driver has identity_status other than verified or the booking has no confirmed coverage option (skipped when renter_booking_confirmed already carried the notice in the same minute). Sent again 48 hours before pickup if anything is still missing.', null, '/account/bookings/{{booking_number}}/verify', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"coverage_for_sale","type":"boolean"},{"name":"first_name","type":"string"},{"name":"id_retention_days","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"min_renter_age","type":"string"},{"name":"missing_items","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"},{"name":"verify_by","type":"string"}]'::jsonb, 'templates/renter_identity_needed.html', 'templates/renter_identity_needed.txt'),
  ('renter_booking_confirmed', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Confirmed: {{vehicle_name}}, {{pickup_date}}', 'Booking {{booking_number}}. {{amount_paid}} paid. Next: licence and coverage check.', 'Immediate', 'Booking status changes from pending_payment to confirmed (the offer was approved, the agreement signed, the booking total paid and the car still free for the dates).', null, '/account/bookings/{{booking_number}}/verify', '[{"name":"amount_paid","type":"string"},{"name":"booking_number","type":"string"},{"name":"card_brand","type":"string"},{"name":"card_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deposit_amount","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"is_non_refundable","type":"boolean"},{"name":"km_allowance","type":"string"},{"name":"line_items","type":"list","fields":["label","amount"]},{"name":"needs_verification","type":"boolean"},{"name":"non_refundable_percent","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"overage_rate","type":"string"},{"name":"pickup_date","type":"string"},{"name":"pickup_place","type":"string"},{"name":"pickup_time","type":"string"},{"name":"receipt_number","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_image_url","type":"url"},{"name":"vehicle_name","type":"string"},{"name":"verify_by","type":"string"}]'::jsonb, 'templates/renter_booking_confirmed.html', 'templates/renter_booking_confirmed.txt'),
  ('renter_accident_instructions', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'What to do now, booking {{booking_number}}', 'If anyone is hurt call 911. Then follow these steps. Report due by {{report_due}}.', 'Immediate', 'An incident of type accident, theft or vandalism is opened on an on_rent booking (Fleet logs the renter''s call). (Message template T16.)', 'T16', '/account/bookings/{{booking_number}}/incident', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"incident_number","type":"string"},{"name":"incident_report_hours","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"report_due","type":"string"},{"name":"roadside_phone","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_accident_instructions.html', 'templates/renter_accident_instructions.txt'),
  ('renter_payment_failed', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Payment of {{amount}} did not go through, booking {{booking_number}}', 'Your card ending {{card_last4}} was declined. {{next_step_short}}', 'Immediate', 'A renter payment attempt fails. Two cases, set by is_booking_payment: (true) the checkout payment for an approved offer fails, no fee, the booking stays pending_payment and does not block the car; (false) a charge to the Card on File is declined, the declined payment fee is added once per charge and retries are scheduled after 1, 3 and 7 days. Sent on the first decline and again after each failed retry. (Message template T10.)', 'T10', '/account/bookings/{{booking_number}}/pay', '[{"name":"amount","type":"string"},{"name":"amount_due","type":"string"},{"name":"booking_number","type":"string"},{"name":"card_brand","type":"string"},{"name":"card_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"declined_fee","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"interest_after_days","type":"string"},{"name":"interest_rate","type":"string"},{"name":"is_booking_payment","type":"boolean"},{"name":"next_retry_date","type":"string"},{"name":"next_step_short","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"pay_by","type":"string"},{"name":"payment_reason","type":"string"},{"name":"pickup_date","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_payment_failed.html', 'templates/renter_payment_failed.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0051 END
update notification_catalogue set emitted_by = 'owner_payment_methods_pad_confirmed (0051)' where code = 'owner_pad_confirmed';

-- ================================================================ 9. privileges
-- the new functions: the server only
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array[
              'owner_late_fee_rule', 'owner_debit_payee', 'ntf_setting_words', 'owner_pad_confirmed_emit', 'amendment_countersigner',
              'signature_records_countersign_now', 'booking_awaiting_signature', 'booking_signature_guard'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- Each renamed function keeps its privileges; the function in its place gets the same.
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('ntf_payload_0046', 'notification_payload'), ('sign_booking_amendment_0040', 'sign_booking_amendment'),
                          ('booking_change_facts_0040', 'booking_change_facts'), ('record_paper_signature_0046', 'record_paper_signature'),
                          ('booking_readiness_0019', 'booking_readiness'), ('field_read_0031', 'field_read')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;
-- the functions replaced with the same signature keep their grants (create or replace keeps them)
select app.attach_audit();
