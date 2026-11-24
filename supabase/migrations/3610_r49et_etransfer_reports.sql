-- 3610 (release 49): "Renter sent an e-Transfer" for Sales, checked by Finance (docs/changes/2026-11-24-r49-etransfer-reports.md).
--
-- Sales could not record an e-Transfer a renter sent (only Finance or an Admin records a payment, and that stays so):
-- they messaged the owner. Now:
--   1. Sales, on a booking waiting for payment, reports it (app.etransfer_report): the amount, what it covers (the
--      rental, the deposit or both), the sender's name (optional) and a screenshot or proof (required). It changes no
--      money: it makes a "Check e-Transfer" item (etransfer_reports, status open), one open per booking at a time, a
--      To do for Finance and one for the Admins (etransfer_check), the notice staff_etransfer_reported (email, in-app
--      and push) to Finance and the Admins, a line in the booking's history and an audit row. The booking shows
--      "e-Transfer reported, waiting for Finance".
--   2. Finance or an Admin decides (app.etransfer_decide), never the rep who reported it (unless an Admin):
--      Confirm received records the payment through the same path as Record a payment on screen (the door's
--      record_booking_payment, method e_transfer), so every rule of a payment applies (the single limit, the deposit by
--      e-Transfer, the reference, the confirmation of a booking waiting for payment); the proof is kept on the payment.
--      Not received sends it back to the rep with the reason (staff_etransfer_declined). Either closes both To dos,
--      tells the rep (staff_etransfer_confirmed on confirm), and is audited.
--   3. The Admin connector: etransfer_check (preview, then confirm) decides one report the same way.
-- Security definer functions run with search_path public, app, pg_temp; the server role alone executes them (the
-- door, the connector). The table is read only to Admins, Finance and Sales by row-level security; no one writes it but
-- these functions. SCHEMA_MARKER 3610. No applied migration is edited.
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

-- ================================================================ 1. the table
create sequence if not exists etransfer_report_seq start 1001;
create table if not exists etransfer_reports (
  id                 uuid primary key default gen_random_uuid(),
  report_number      text not null unique default ('ET-' || nextval('etransfer_report_seq')::text),
  booking_id         uuid not null references bookings (id),
  amount_cents       bigint not null check (amount_cents between 1 and 10000000),
  covers             text not null check (covers in ('rental', 'deposit', 'both')),
  sender_name        text check (sender_name is null or length(sender_name) between 1 and 120),
  note               text check (note is null or length(note) <= 500),
  proof_document_id  uuid not null references documents (id),
  status             text not null default 'open' check (status in ('open', 'confirmed', 'declined')),
  reported_by        uuid not null references users (id),
  reported_at        timestamptz not null default now(),
  decided_by         uuid references users (id),
  decided_at         timestamptz,
  decline_reason     text check (decline_reason is null or length(decline_reason) between 5 and 500),
  reference          text check (reference is null or length(reference) between 3 and 120),
  payment_ids        uuid[] not null default '{}',
  todo_task_ids      uuid[] not null default '{}',
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check ((status = 'open') = (decided_at is null)),
  check (status <> 'declined' or decline_reason is not null)
);
-- one open report per booking: a second while one waits is refused (and this index holds under concurrency too)
create unique index if not exists etransfer_reports_one_open on etransfer_reports (booking_id) where status = 'open';
create index if not exists etransfer_reports_booking_idx on etransfer_reports (booking_id, reported_at desc);
create index if not exists etransfer_reports_open_idx on etransfer_reports (reported_at) where status = 'open';
create index if not exists etransfer_reports_proof_idx on etransfer_reports (proof_document_id);
comment on table etransfer_reports is 'Check e-Transfer (3610): a Sales rep says a renter sent an e-Transfer on a booking waiting for payment, with a screenshot. No money is recorded until Finance or an Admin confirms it (then recorded as Record a payment does) or sends it back with the reason.';

create trigger etransfer_reports_updated before update on etransfer_reports for each row execute function app.set_updated_at();
create trigger audit_etransfer_reports after insert or update or delete on etransfer_reports for each row execute function app.audit_row();
alter table etransfer_reports enable row level security;
create policy admin_all on etransfer_reports for select to authenticated using (app.is_admin());
create policy finance_read on etransfer_reports for select to authenticated using (app.va_has('finance'));
create policy sales_read on etransfer_reports for select to authenticated using (app.va_has('sales'));
revoke all on etransfer_reports from public, anon, authenticated;
grant select on etransfer_reports to authenticated;
grant all on etransfer_reports to service_role;
revoke all on sequence etransfer_report_seq from public, anon, authenticated;
grant usage, select on sequence etransfer_report_seq to service_role;

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('etransfer_check', 'finance', 'Check e-Transfer', 'high', 'opening_minutes', 120, 2, 'etransfer_decided',
   'A Sales rep reported that a renter sent an e-Transfer on a booking waiting for payment (3610), with a screenshot. Check the bank: Confirm received records the payment and confirms the booking; Not received sends it back to the rep with the reason. Finance or an Admin; never the rep who reported it.')
on conflict (task_type) do nothing;

-- ================================================================ 2. small rules
create or replace function app.etransfer_covers_words(p_covers text) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select case p_covers when 'rental' then 'the rental and fees' when 'deposit' then 'the deposit' when 'both' then 'the rental and the deposit' else p_covers end
$$;

create or replace function app.etransfer_find(p jsonb) returns etransfer_reports
language sql stable security definer set search_path = public, app, pg_temp as $$
  select r.* from etransfer_reports r
   where r.id::text = coalesce(p ->> 'id', p ->> 'report', '')
      or r.report_number = upper(btrim(coalesce(p ->> 'report', p ->> 'id', '')))
      or (r.status = 'open' and r.booking_id = (select b.id from bookings b where b.id::text = coalesce(p ->> 'booking', '') or b.booking_number = upper(btrim(coalesce(p ->> 'booking', '')))))
   order by (r.status = 'open') desc, r.reported_at desc limit 1
$$;

-- What Confirm received would record: the rental and fees part and the deposit part, beside what is open on the booking.
-- p_deposit: for "both", the deposit part (empty: the deposit still owed by e-Transfer, at most the amount).
create or replace function app.etransfer_plan(p_report uuid, p_deposit bigint default null) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  r etransfer_reports;
  b bookings;
  d deposits;
  v_open bigint;
  v_owed bigint := 0;
  v_dep bigint := 0;
  v_rent bigint := 0;
  v_problem text;
begin
  select * into r from etransfer_reports where id = p_report;
  if r.id is null then return null; end if;
  select * into b from bookings where id = r.booking_id;
  v_open := app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees');
  if coalesce(b.deposit_cents, 0) > 0 and b.booking_type <> 'owner' then
    select * into d from deposits where booking_id = b.id;
    v_owed := case when d.id is null or d.status in ('pending', 'failed') then app.deposit_for_method(b, 'e_transfer')
                   when d.method = 'offline' and d.status = 'captured' then greatest(app.deposit_for_method(b, 'e_transfer') - d.amount_cents, 0)
                   else 0 end;
  end if;
  if r.covers = 'rental' then v_rent := r.amount_cents;
  elsif r.covers = 'deposit' then v_dep := r.amount_cents;
  else
    v_dep := coalesce(p_deposit, least(v_owed, r.amount_cents));
    v_rent := r.amount_cents - v_dep;
  end if;
  v_problem := case
    when r.covers = 'both' and (v_dep <= 0 or v_rent <= 0) then
      format('It covers the rental and the deposit, but %s cannot be split into both (deposit owed %s, rental and fees open %s): send it back, or give the deposit part',
             app.fmt_money(r.amount_cents), app.fmt_money(v_owed), app.fmt_money(v_open))
    when v_rent > 0 and v_open <= 0 then 'Nothing is open for the rental and fees on this booking any more: it was paid another way. Send it back with that reason'
    when v_dep > 0 and v_owed <= 0 and r.covers = 'both' then 'No deposit is owed by e-Transfer on this booking: send it back with that reason'
    when v_dep > 0 and (coalesce(b.deposit_cents, 0) <= 0 or b.booking_type = 'owner') then 'This booking has no deposit to take: send it back with that reason' end;
  return jsonb_build_object('report_id', r.id, 'amount_cents', r.amount_cents, 'covers', r.covers,
    'rental_cents', v_rent, 'deposit_cents', v_dep, 'rental_open_cents', v_open, 'deposit_owed_cents', v_owed,
    'over_cents', greatest(v_rent - v_open, 0) + case when r.covers = 'deposit' then greatest(v_dep - v_owed, 0) else 0 end,
    'problem', v_problem);
end $$;

-- the open To dos of a report are done (or cancelled) with the decision
create or replace function app.etransfer_close_todos(r etransfer_reports, p_by uuid, p_note text) returns void
language sql security definer set search_path = public, app, pg_temp as $$
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = left(p_note, 500), wake_at = null
   where id = any (r.todo_task_ids) and status in ('open', 'in_progress', 'waiting')
$$;

-- ================================================================ 3. Sales reports it
-- p: booking, amount_cents, covers (rental | deposit | both), sender_name, note, proof {path, sha256, mime} (the web
-- layer stored the file under etransfer/ and checked its real type)
create or replace function app.etransfer_report(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  r etransfer_reports;
  o etransfer_reports;
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_covers text := nullif(btrim(coalesce(p ->> 'covers', '')), '');
  v_sender text := nullif(btrim(coalesce(p ->> 'sender_name', '')), '');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_doc uuid;
  v_name text := coalesce((select u.full_name from users u where u.id = p_by), 'A Sales rep');
  v_fin uuid;
  v_adm uuid;
begin
  if app.user_is_admin(p_by) and not app.user_va_has(p_by, 'sales') then
    raise exception 'An Admin records the payment directly: Money, Record a payment' using errcode = '42501';
  end if;
  if not app.user_va_has(p_by, 'sales') then raise exception 'Only Sales reports an e-Transfer a renter sent' using errcode = '42501'; end if;
  select * into b from bookings where id::text = coalesce(p ->> 'booking', '') or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status <> 'pending_payment' then
    raise exception 'Booking % is %: an e-Transfer is reported on a booking waiting for payment', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
  end if;
  select * into o from etransfer_reports where booking_id = b.id and status = 'open';
  if o.id is not null then
    raise exception 'An e-Transfer report is already waiting for Finance on booking % (%): wait for it, or ask Finance', b.booking_number, o.report_number using errcode = '23505';
  end if;
  if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount the renter sent' using errcode = '22023'; end if;
  if v_amount > 10000000 then raise exception 'That amount is too large for one e-Transfer: check it' using errcode = '22023'; end if;
  if v_covers is null or v_covers not in ('rental', 'deposit', 'both') then raise exception 'Choose what it covers: the rental, the deposit or both' using errcode = '22023'; end if;
  if v_covers in ('deposit', 'both') and (coalesce(b.deposit_cents, 0) <= 0 or b.booking_type = 'owner') then
    raise exception 'Booking % has no deposit: choose the rental', b.booking_number using errcode = '22023';
  end if;
  if v_sender is not null and length(v_sender) > 120 then raise exception 'The sender''s name is too long' using errcode = '22023'; end if;
  if v_note is not null and length(v_note) > 500 then raise exception 'The note is too long (500 characters at most)' using errcode = '22023'; end if;
  if jsonb_typeof(p -> 'proof') <> 'object' or lower(coalesce(p #>> '{proof,sha256}', '')) !~ '^[0-9a-f]{64}$'
     or coalesce(p #>> '{proof,path}', '') !~ '^etransfer/[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|png|pdf)$'
     or coalesce(p #>> '{proof,mime}', '') not in ('image/jpeg', 'image/png', 'application/pdf') then
    raise exception 'Add the screenshot or proof of the e-Transfer' using errcode = '22023';
  end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, uploaded_by)
  values ('receipt', format('e-Transfer proof, %s', b.booking_number), 'documents', p #>> '{proof,path}', p #>> '{proof,mime}', lower(p #>> '{proof,sha256}'), p_by)
  returning id into v_doc;
  begin
    insert into etransfer_reports (booking_id, amount_cents, covers, sender_name, note, proof_document_id, reported_by)
    values (b.id, v_amount, v_covers, v_sender, v_note, v_doc, p_by) returning * into r;
  exception when unique_violation then
    raise exception 'An e-Transfer report is already waiting for Finance on booking %: wait for it, or ask Finance', b.booking_number using errcode = '23505';
  end;
  -- the To dos: Finance's queue, and the Admins' (each closes with the decision)
  v_fin := app.raise_task(p_type => 'etransfer_check',
    p_title => format('Check e-Transfer: %s on %s', app.fmt_money(v_amount), b.booking_number),
    p_detail => format('%s reported that %s was sent for %s%s (%s). Check the bank, then Confirm received or Not received on the booking''s Money tab.',
                       v_name, app.fmt_money(v_amount), app.etransfer_covers_words(v_covers), coalesce(' by ' || v_sender, ''), r.report_number),
    p_booking => b.id, p_related_table => 'etransfer_reports', p_related_id => r.id, p_dedupe => 'etransfer_check:' || r.id || ':finance', p_queue => 'finance', p_created_by => p_by);
  -- (with nobody holding Finance, the Admins already see Finance's To do: no second one)
  if app.va_function_staffed('finance') then
    v_adm := app.raise_task(p_type => 'etransfer_check',
      p_title => format('Check e-Transfer: %s on %s', app.fmt_money(v_amount), b.booking_number),
      p_detail => format('%s reported that %s was sent for %s%s (%s). Confirm received records it; Not received sends it back with the reason.',
                         v_name, app.fmt_money(v_amount), app.etransfer_covers_words(v_covers), coalesce(' by ' || v_sender, ''), r.report_number),
      p_booking => b.id, p_related_table => 'etransfer_reports', p_related_id => r.id, p_dedupe => 'etransfer_check:' || r.id || ':admin', p_queue => 'admin', p_created_by => p_by);
  end if;
  update etransfer_reports set todo_task_ids = array_remove(array[v_fin, v_adm], null) where id = r.id returning * into r;
  perform app.ntf_emit('staff_etransfer_reported', 'booking', b.id, r.id::text,
    jsonb_build_object('booking_id', b.id, 'report_id', r.id, 'etransfer_amount', app.fmt_money(v_amount), 'etransfer_covers', app.etransfer_covers_words(v_covers),
                       'etransfer_sender', coalesce(v_sender, 'Not given'), 'etransfer_number', r.report_number, 'reporter_name', v_name));
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
    format('e-Transfer of %s for %s reported by %s (%s): waiting for Finance. Nothing is recorded yet', app.fmt_money(v_amount), app.etransfer_covers_words(v_covers), v_name, r.report_number),
    p_by, 'staff', jsonb_build_object('etransfer_report_id', r.id, 'amount_cents', v_amount, 'covers', v_covers));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'etransfer_report', 'etransfer_reports', r.id::text, jsonb_build_object('booking_id', b.id, 'report_number', r.report_number, 'amount_cents', v_amount,
          'covers', v_covers, 'sender_name', v_sender, 'proof_document_id', v_doc));
  return jsonb_build_object('ok', true, 'id', r.id, 'report_number', r.report_number, 'status', r.status, 'booking_number', b.booking_number);
end $$;

-- ================================================================ 4. Finance or an Admin decides
-- p: id | report (ET-...) | booking, decision (confirm | decline), reason (decline, 5 characters or more), reference (the
-- bank's e-Transfer reference; empty: the report number), received_on, deposit_cents (both: the deposit part).
-- p_aal: the caller's assurance level, for the payment's own door call.
create or replace function app.etransfer_decide(p_by uuid, p jsonb, p_aal text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r etransfer_reports;
  b bookings;
  v_decision text := lower(btrim(coalesce(p ->> 'decision', '')));
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_ref text := nullif(btrim(coalesce(p ->> 'reference', '')), '');
  v_on date := nullif(p ->> 'received_on', '')::date;
  v_plan jsonb;
  v_res jsonb;
  v_ids uuid[] := '{}';
  v_name text := coalesce((select u.full_name from users u where u.id = p_by), 'Finance');
  v_rep text;
  v_status text;
  v_note text;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Only Finance or an Admin confirms an e-Transfer' using errcode = '42501'; end if;
  if v_decision in ('received', 'confirm_received', 'confirmed') then v_decision := 'confirm'; end if;
  if v_decision in ('not_received', 'declined', 'send_back') then v_decision := 'decline'; end if;
  if v_decision not in ('confirm', 'decline') then raise exception 'Choose Confirm received or Not received' using errcode = '22023'; end if;
  r := app.etransfer_find(p);
  if r.id is null then raise exception 'e-Transfer report not found' using errcode = 'P0002'; end if;
  select * into r from etransfer_reports where id = r.id for update;
  if r.status <> 'open' then
    raise exception 'e-Transfer report % was already %', r.report_number, case r.status when 'confirmed' then 'confirmed' else 'sent back' end using errcode = '23514';
  end if;
  if r.reported_by = p_by and not app.user_is_admin(p_by) then
    raise exception 'You reported this e-Transfer: another Finance member or an Admin checks it' using errcode = '42501';
  end if;
  select * into b from bookings where id = r.booking_id;
  v_rep := coalesce((select u.full_name from users u where u.id = r.reported_by), 'the rep');

  if v_decision = 'decline' then
    if v_reason is null or length(v_reason) < 5 then raise exception 'Say why it was not received (5 characters or more): the rep sees it' using errcode = '22023'; end if;
    if length(v_reason) > 500 then raise exception 'The reason is too long (500 characters at most)' using errcode = '22023'; end if;
    update etransfer_reports set status = 'declined', decided_by = p_by, decided_at = now(), decline_reason = v_reason where id = r.id returning * into r;
    perform app.etransfer_close_todos(r, p_by, 'Not received: ' || v_reason);
    perform app.ntf_emit('staff_etransfer_declined', 'booking', b.id, r.id::text || ':declined',
      jsonb_build_object('booking_id', b.id, 'report_id', r.id, 'staff_id', r.reported_by, 'etransfer_amount', app.fmt_money(r.amount_cents),
                         'etransfer_number', r.report_number, 'decline_reason', v_reason, 'decided_by_name', v_name));
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
      format('e-Transfer of %s (%s) not received, sent back to %s by %s: %s', app.fmt_money(r.amount_cents), r.report_number, v_rep, v_name, v_reason),
      p_by, 'staff', jsonb_build_object('etransfer_report_id', r.id, 'decision', 'decline'));
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (p_by, 'etransfer_decline', 'etransfer_reports', r.id::text, jsonb_build_object('status', 'open'),
            jsonb_build_object('status', 'declined', 'reason', v_reason, 'booking_id', b.id, 'amount_cents', r.amount_cents));
    return jsonb_build_object('ok', true, 'id', r.id, 'report_number', r.report_number, 'status', r.status, 'booking_number', b.booking_number);
  end if;

  -- confirm: through the payment's own path (the door's record_booking_payment), part by part, all or nothing
  v_plan := app.etransfer_plan(r.id, nullif(p ->> 'deposit_cents', '')::bigint);
  if v_plan ->> 'problem' is not null then raise exception '%', v_plan ->> 'problem' using errcode = '23514'; end if;
  if v_ref is not null and length(v_ref) < 3 then raise exception 'Enter the e-Transfer reference number (3 characters or more), or leave it empty' using errcode = '22023'; end if;
  v_ref := left(coalesce(v_ref, r.report_number), 100);
  v_note := format('e-Transfer reported by %s (%s)%s, confirmed by %s', v_rep, r.report_number, coalesce(', sent by ' || r.sender_name, ''), v_name);
  if (v_plan ->> 'rental_cents')::bigint > 0 then
    v_res := app.door(p_by, p_aal, 'ops_do', 'record_booking_payment', jsonb_strip_nulls(jsonb_build_object('booking', b.id, 'covers', 'both', 'method', 'e_transfer',
      'amount_cents', (v_plan ->> 'rental_cents')::bigint, 'reference', v_ref, 'received_on', v_on, 'note', v_note)));
    if coalesce((v_res ->> 'repeat')::boolean, false) then
      raise exception 'An e-Transfer with the reference % is already recorded on %: enter the bank''s reference', v_ref, b.booking_number using errcode = '23505';
    end if;
    v_ids := v_ids || coalesce((select array_agg((x ->> 'payment_id')::uuid) from jsonb_array_elements(coalesce(v_res -> 'parts', '[]'::jsonb)) x where x ->> 'payment_id' is not null), '{}')
                   || case when v_res -> 'parts' is null and v_res ->> 'payment_id' is not null then array[(v_res ->> 'payment_id')::uuid] else '{}'::uuid[] end;
  end if;
  if (v_plan ->> 'deposit_cents')::bigint > 0 then
    v_res := app.door(p_by, p_aal, 'ops_do', 'record_booking_payment', jsonb_strip_nulls(jsonb_build_object('booking', b.id, 'covers', 'deposit', 'method', 'e_transfer',
      'amount_cents', (v_plan ->> 'deposit_cents')::bigint, 'reference', case when r.covers = 'both' then left(v_ref, 90) || ' (deposit)' else v_ref end,
      'received_on', v_on, 'note', v_note)));
    if coalesce((v_res ->> 'repeat')::boolean, false) then
      raise exception 'A deposit e-Transfer with this reference is already recorded on %: enter the bank''s reference', b.booking_number using errcode = '23505';
    end if;
    if v_res ->> 'payment_id' is not null then v_ids := v_ids || (v_res ->> 'payment_id')::uuid; end if;
  end if;
  -- the screenshot is the proof of each payment recorded (Finance opens it from the payments received another way)
  update manual_payments set proof_document_id = r.proof_document_id where payment_id = any (v_ids) and proof_document_id is null;
  update etransfer_reports set status = 'confirmed', decided_by = p_by, decided_at = now(), reference = v_ref, payment_ids = v_ids where id = r.id returning * into r;
  perform app.etransfer_close_todos(r, p_by, 'Confirmed received: recorded as an e-Transfer');
  select status::text into v_status from bookings where id = b.id;
  perform app.ntf_emit('staff_etransfer_confirmed', 'booking', b.id, r.id::text || ':confirmed',
    jsonb_build_object('booking_id', b.id, 'report_id', r.id, 'staff_id', r.reported_by, 'etransfer_amount', app.fmt_money(r.amount_cents),
                       'etransfer_covers', app.etransfer_covers_words(r.covers), 'etransfer_number', r.report_number, 'decided_by_name', v_name,
                       'booking_status', initcap(replace(v_status, '_', ' '))));
  perform app.log_booking_event(b.id, 'adjusted', v_status, v_status, b.current_offer_version,
    format('e-Transfer of %s (%s, reported by %s) confirmed received by %s and recorded', app.fmt_money(r.amount_cents), r.report_number, v_rep, v_name),
    p_by, 'staff', jsonb_build_object('etransfer_report_id', r.id, 'decision', 'confirm', 'payment_ids', to_jsonb(v_ids)));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'etransfer_confirm', 'etransfer_reports', r.id::text, jsonb_build_object('status', 'open', 'booking_status', b.status),
          jsonb_build_object('status', 'confirmed', 'booking_id', b.id, 'booking_status', v_status, 'amount_cents', r.amount_cents, 'plan', v_plan,
                             'reference', v_ref, 'payment_ids', to_jsonb(v_ids)));
  return jsonb_build_object('ok', true, 'id', r.id, 'report_number', r.report_number, 'status', r.status, 'booking_number', b.booking_number,
                            'booking_status', v_status, 'payment_ids', to_jsonb(v_ids), 'plan', v_plan);
end $$;

-- ================================================================ 5. reads
-- p: booking (one booking's reports, what the viewer may do, the plan of the open one), or nothing (the open reports)
create or replace function app.etransfer_reports_view(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  o etransfer_reports;
  v_fin boolean := app.user_runs_finance(p_by);
  v_sales boolean := app.user_va_has(p_by, 'sales');
  v_proof boolean;
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then raise exception 'Staff only' using errcode = '42501'; end if;
  v_proof := v_fin or v_sales;
  if nullif(p ->> 'booking', '') is null then
    if not v_fin then raise exception 'Finance or an Admin' using errcode = '42501'; end if;
    return jsonb_build_object('open', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'report_number', r.report_number, 'booking_number', x.booking_number,
              'amount_cents', r.amount_cents, 'covers', r.covers, 'sender_name', r.sender_name, 'reported_by_name', u.full_name, 'reported_at', r.reported_at) order by r.reported_at)
           from etransfer_reports r join bookings x on x.id = r.booking_id left join users u on u.id = r.reported_by where r.status = 'open'), '[]'::jsonb));
  end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then return null; end if;
  select * into o from etransfer_reports where booking_id = b.id and status = 'open';
  return jsonb_build_object(
    'booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'has_deposit', coalesce(b.deposit_cents, 0) > 0 and b.booking_type <> 'owner',
    'may_report', v_sales and b.status = 'pending_payment' and o.id is null,
    'may_decide', v_fin and o.id is not null and (o.reported_by <> p_by or app.user_is_admin(p_by)),
    'own_report', o.id is not null and o.reported_by = p_by,
    'plan', case when v_fin and o.id is not null then app.etransfer_plan(o.id) end,
    'reports', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'report_number', r.report_number, 'amount_cents', r.amount_cents, 'covers', r.covers,
        'sender_name', r.sender_name, 'note', r.note, 'status', r.status, 'reported_at', r.reported_at, 'reported_by_name', ur.full_name,
        'decided_at', r.decided_at, 'decided_by_name', ud.full_name, 'decline_reason', r.decline_reason, 'reference', r.reference,
        'proof_document_id', case when v_proof then r.proof_document_id end) order by r.reported_at desc)
      from (select * from etransfer_reports x where x.booking_id = b.id order by x.reported_at desc limit 10) r
      left join users ur on ur.id = r.reported_by left join users ud on ud.id = r.decided_by), '[]'::jsonb));
end $$;

-- the proof file, for the staff document link: Finance, Sales and the Admins
create or replace function app.etransfer_proof(p_by uuid, p jsonb) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('bucket', d.storage_bucket, 'path', d.storage_path, 'mime_type', d.mime_type)
    from documents d
   where d.id = nullif(p ->> 'document', '')::uuid and d.storage_path is not null and d.purged_at is null
     and exists (select 1 from etransfer_reports r where r.proof_document_id = d.id)
     and (app.user_runs_finance(p_by) or app.user_va_has(p_by, 'sales'))
$$;

-- ================================================================ 6. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3610;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call in ('ops_read', 'va_read', 'admin_read') and p_name in ('etransfer_reports', 'etransfer_proof'))
     or (p_call in ('ops_do', 'va_do', 'admin_do') and p_name in ('etransfer_report', 'etransfer_decide')) then
    -- the onboarding gate of 1151, which sits further down the door, holds here too
    if p_user is not null and app.staff_is_member(p_user) and not app.staff_fully_onboarded(p_user) then
      raise exception 'Finish your onboarding first: the academy, your staff agreement, then the WhatsApp groups (Welcome shows the next step)' using errcode = '42501';
    end if;
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    p_ := p_ - '_va';
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'etransfer_reports' then app.etransfer_reports_view(p_user, p_)
      when 'etransfer_proof' then app.etransfer_proof(p_user, p_)
      when 'etransfer_report' then app.etransfer_report(p_user, p_)
      else app.etransfer_decide(p_user, p_, p_aal) end;
  end if;
  return app.door_pre3610(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3610(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 7. the connector: etransfer_check, previewed then confirmed
-- etransfer_check {report (ET-...) or booking, decision received | not_received, reason, reference, received_on,
-- deposit_cents}: the preview says what would be recorded (or why it cannot be) and changes nothing; the confirm runs
-- app.etransfer_decide as the key's person (Finance or an Admin), exactly as the booking page does.
alter function app.api_call(text, text, jsonb, text) rename to api_call_pre3610;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  chk jsonb;
  k api_keys;
  v_args jsonb;
  v_confirm boolean;
  pv api_previews;
  r etransfer_reports;
  b bookings;
  v_dec text;
  v_plan jsonb;
  v_view jsonb;
  v_result jsonb;
  v_target text := left(coalesce(nullif(a ->> 'report', ''), nullif(a ->> 'booking', ''), p_tool), 200);
begin
  if p_tool <> 'etransfer_check' then return app.api_call_pre3610(p_hash, p_tool, p_args, p_client); end if;
  chk := app.api_key_check(p_hash, 'admin:write', p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  v_confirm := coalesce((a ->> 'confirm')::boolean, false);
  v_args := a - 'confirm' - 'preview_id';
  begin
    if not app.user_runs_finance(k.user_id) then raise exception 'Only Finance or an Admin confirms an e-Transfer' using errcode = '42501'; end if;
    if nullif(v_args ->> 'report', '') is null and nullif(v_args ->> 'booking', '') is null then
      raise exception 'report: the report number (ET-...), or booking: the booking with the open report' using errcode = '22023';
    end if;
    r := app.etransfer_find(v_args);
    if r.id is null then raise exception 'No e-Transfer report found for %', v_target using errcode = 'P0002'; end if;
    select * into b from bookings where id = r.booking_id;
    v_target := r.report_number;
    v_dec := lower(btrim(coalesce(v_args ->> 'decision', '')));
    if v_dec not in ('received', 'not_received') then raise exception 'decision: received (Confirm received) or not_received (Not received)' using errcode = '22023'; end if;
    if r.status <> 'open' then raise exception 'e-Transfer report % was already %', r.report_number, case r.status when 'confirmed' then 'confirmed' else 'sent back' end using errcode = '23514'; end if;
    if v_dec = 'not_received' and length(btrim(coalesce(v_args ->> 'reason', ''))) < 5 then
      raise exception 'reason: say why it was not received (5 characters or more): the rep sees it' using errcode = '22023';
    end if;
    v_plan := app.etransfer_plan(r.id, nullif(v_args ->> 'deposit_cents', '')::bigint);
    v_view := jsonb_build_object('report_number', r.report_number, 'booking_number', b.booking_number, 'booking_status', b.status, 'amount_cents', r.amount_cents,
      'covers', r.covers, 'sender_name', r.sender_name, 'reported_by', (select u.full_name from users u where u.id = r.reported_by), 'reported_at', r.reported_at,
      'proof_document_id', r.proof_document_id, 'plan', v_plan);
    if not v_confirm then
      if v_dec = 'received' and v_plan ->> 'problem' is not null then raise exception '%', v_plan ->> 'problem' using errcode = '23514'; end if;
      insert into api_previews (key_id, user_id, tool, args, before, after)
      values (k.id, k.user_id, p_tool, v_args, v_view || jsonb_build_object('status', 'open'),
              v_view || jsonb_build_object('status', case v_dec when 'received' then 'confirmed' else 'declined' end)) returning * into pv;
      v_result := jsonb_build_object('preview', true, 'preview_id', pv.id, 'tool', p_tool, 'expires_at', pv.created_at + interval '10 minutes', 'report', v_view,
        'will_do', case v_dec
          when 'received' then format('Confirm received: record %s by e-Transfer on booking %s (%s), as Record a payment does%s. The rep is told; the To dos close.',
            app.fmt_money(r.amount_cents), b.booking_number,
            concat_ws(' and ', case when (v_plan ->> 'rental_cents')::bigint > 0 then app.fmt_money((v_plan ->> 'rental_cents')::bigint) || ' for the rental and fees' end,
                               case when (v_plan ->> 'deposit_cents')::bigint > 0 then app.fmt_money((v_plan ->> 'deposit_cents')::bigint) || ' for the deposit' end),
            case when b.status = 'pending_payment' and (v_plan ->> 'rental_cents')::bigint > 0 then '; a booking waiting for payment with nothing open is confirmed' else '' end)
          else format('Not received: send report %s back to %s with the reason "%s". Nothing is recorded.', r.report_number,
            coalesce((select u.full_name from users u where u.id = r.reported_by), 'the rep'), btrim(v_args ->> 'reason')) end,
        'next', 'Nothing was changed. To do it, call this tool again with exactly the same arguments plus "confirm": true and "preview_id": "' || pv.id || '".');
    else
      select * into pv from api_previews where id = nullif(a ->> 'preview_id', '')::uuid for update;
      if pv.id is null or pv.key_id <> k.id or pv.tool <> p_tool then raise exception 'Preview first: call without confirm, then confirm with its preview_id' using errcode = '22023'; end if;
      if pv.used_at is not null then raise exception 'This preview was already used: preview again' using errcode = '22023'; end if;
      if pv.created_at < now() - interval '10 minutes' then raise exception 'This preview is more than 10 minutes old: preview again' using errcode = '22023'; end if;
      if pv.args is distinct from v_args then raise exception 'The arguments differ from the preview: preview again with these' using errcode = '22023'; end if;
      update api_previews set used_at = now() where id = pv.id;
      v_result := app.etransfer_decide(k.user_id, jsonb_strip_nulls(jsonb_build_object('id', r.id, 'decision', case v_dec when 'received' then 'confirm' else 'decline' end,
        'reason', v_args ->> 'reason', 'reference', v_args ->> 'reference', 'received_on', v_args ->> 'received_on', 'deposit_cents', v_args ->> 'deposit_cents')), 'aal2');
      v_result := v_result || jsonb_build_object('done', true);
    end if;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, v_target, v_args, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, ok, client)
  values (k.id, k.user_id, case when not v_confirm then p_tool || ':preview' else p_tool end, v_target, v_args, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre3610(text, text, jsonb, text)'::regprocedure);

-- ================================================================ 8. the notices (email, in-app and push)
-- CATALOGUE 3610 START (generated by supabase/seed/3610_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('staff_etransfer_reported', 'staff_va_finance', array['staff_admin']::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'Check e-Transfer: {{etransfer_amount}} on booking {{booking_number}}', '{{reporter_name}} says {{renter_name}} sent it for {{etransfer_covers}}. Confirm it once it is in the bank.', 'Immediate', 'Release 49 (3610): a Sales rep reports on a booking waiting for payment that the renter sent an e-Transfer (Renter sent an e-Transfer, with the amount, what it covers, the sender and a screenshot). Nothing is recorded: a Check e-Transfer To do is raised for Finance and the Admins. Immediate, once per report, to Finance and the Admins.', null, '/staff/bookings/{{booking_number}}?tab=money', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"etransfer_amount","type":"string"},{"name":"etransfer_covers","type":"string"},{"name":"etransfer_number","type":"string"},{"name":"etransfer_sender","type":"string"},{"name":"renter_name","type":"string"},{"name":"reporter_name","type":"string"}]'::jsonb, 'templates/staff_etransfer_reported.html', 'templates/staff_etransfer_reported.txt'),
  ('staff_etransfer_confirmed', 'staff_va_sales', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'e-Transfer confirmed: {{etransfer_amount}} on booking {{booking_number}}', '{{decided_by_name}} found it in the bank. The payment is recorded.', 'Immediate', 'Release 49 (3610): Finance or an Admin pressed Confirm received on an e-Transfer a Sales rep reported (Check e-Transfer): the payment was recorded as an e-Transfer and the booking confirmed as a payment recorded on screen does. One email to the rep who reported it, at their own address.', null, '/staff/bookings/{{booking_number}}?tab=money', '[{"name":"booking_number","type":"string"},{"name":"booking_status","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"decided_by_name","type":"string"},{"name":"etransfer_amount","type":"string"},{"name":"etransfer_covers","type":"string"},{"name":"first_name","type":"string"},{"name":"renter_name","type":"string"}]'::jsonb, 'templates/staff_etransfer_confirmed.html', 'templates/staff_etransfer_confirmed.txt'),
  ('staff_etransfer_declined', 'staff_va_sales', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'e-Transfer not received: booking {{booking_number}}', '{{decided_by_name}}: {{decline_reason}}', 'Immediate', 'Release 49 (3610): Finance or an Admin pressed Not received on an e-Transfer a Sales rep reported (Check e-Transfer), with the reason. One email to the rep who reported it, at their own address. Nothing was recorded; the booking still waits for payment and the rep may report it again.', null, '/staff/bookings/{{booking_number}}?tab=money', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"decided_by_name","type":"string"},{"name":"decline_reason","type":"string"},{"name":"etransfer_amount","type":"string"},{"name":"etransfer_number","type":"string"},{"name":"first_name","type":"string"},{"name":"renter_name","type":"string"}]'::jsonb, 'templates/staff_etransfer_declined.html', 'templates/staff_etransfer_declined.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 3610 END
update notification_catalogue set emitted_by = 'app.etransfer_report (3610): a Sales rep reports an e-Transfer' where code = 'staff_etransfer_reported';
update notification_catalogue set emitted_by = 'app.etransfer_decide (3610): Confirm received' where code = 'staff_etransfer_confirmed';
update notification_catalogue set emitted_by = 'app.etransfer_decide (3610): Not received' where code = 'staff_etransfer_declined';
-- Finance acts on it at once (the alerts topic, pushed at any hour); the rep hears the answer with their booking changes. Never a text.
update notification_catalogue set no_text = true, push_topic = 'alerts', hold_to_merge = false, priority = 2 where code = 'staff_etransfer_reported';
update notification_catalogue set no_text = true, push_topic = 'bookings', hold_to_merge = false, priority = 2 where code in ('staff_etransfer_confirmed', 'staff_etransfer_declined');
insert into notification_link_paths (key, path) values ('va_finance_booking_money', '/staff/bookings/{{booking_number}}?tab=money'),
  ('va_sales_booking_money', '/staff/bookings/{{booking_number}}?tab=money') on conflict (key) do update set path = excluded.path;

-- the rep who reported it, at their own address (an active staff account only)
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre3610;
create function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  if p_c.code in ('staff_etransfer_confirmed', 'staff_etransfer_declined') then
    return query select 'staff_va_sales'::text, u.id, u.email, u.full_name, null::uuid, null::uuid, true
                   from users u
                  where u.id = nullif(p_event.payload ->> 'staff_id', '')::uuid and u.status = 'active' and u.email is not null
                    and (app.user_is_staff(u.id) or app.user_is_admin(u.id));
    return;
  end if;
  return query select * from app.notification_recipients_pre3610(p_event, p_c);
end $$;
select pg_temp.copy_grants('app.notification_recipients(app_events, notification_catalogue)'::regprocedure,
                           'app.notification_recipients_pre3610(app_events, notification_catalogue)'::regprocedure);

-- ================================================================ 9. privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('etransfer_covers_words', 'etransfer_find', 'etransfer_plan', 'etransfer_close_todos', 'etransfer_report',
              'etransfer_decide', 'etransfer_reports_view', 'etransfer_proof', 'door_pre3610', 'api_call_pre3610', 'notification_recipients_pre3610') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
