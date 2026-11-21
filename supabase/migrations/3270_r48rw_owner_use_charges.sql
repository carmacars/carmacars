-- 3270 (release 48, part RW; docs/changes/2026-11-20-r48-rewards-calendar-notify.md): the charges of an owner-use booking
-- are billed to the OWNER by themselves, due at once.
--
-- The owner (Nov 20): an owner who books their own car (app.owner_book_own_vehicle, app.owner_book_for, 3195) is
-- responsible for every charge during that booking: damage (up to the deductible), tickets, tolls, fuel, kilometres,
-- cleaning, smoking, a late return and every other fee. Until now nothing was assessed on an Owner Booking (only a claim's
-- deductible, as an owner deduction) and every charge function refused it.
--
-- 1. The charges are assessed and added as on any rental (app.assess_check_in, damage_charge_add, return_charge_add,
--    speeding_charge_add, booking_fees_change: each is patched to accept an Owner Booking while owner_use_bill is on), as
--    lines of the booking with the evidence rules of 3190 unchanged: a line that needs evidence waits for it.
-- 2. They are never put on a renter statement or charged to a renter's card (app.issue_booking_statement and
--    app.charge_after_rental are wrapped). app.owner_use_bill puts the lines that are ready on one owner invoice
--    (kind custom, owner_invoices.owner_use_booking_id; booking_line_items.owner_invoice_id), issued and due the same day.
--    Damage (damage at cost and the deductible) is capped at the deductible of Program settings for the booking.
-- 3. Collection, in this order (the owner's correction of Nov 20):
--      a. at once from the payment method on file: the owner's card if one is active, otherwise the pre-authorized debit
--         started the same day (owner_debit_attempts.immediate; not the 15th, no waiting for the notice days);
--      b. no method on file, or the charge fails: the invoice is due now, the owner gets the branded email with the pay
--         link and reminders every owner_use_reminder_days;
--      c. still unpaid at whichever comes first of owner_use_charge_due_days after it was issued (7, as
--         owner_invoice_due_days) and the next statement cut-off (statement_cutoff_day, the 7th): it is deducted from the
--         next statement (collect_by payout; the statement marks it deducted). app.build_owner_statement is wrapped so
--         the statement run on the cut-off day takes every invoice still unpaid that day.
--    The owner is told at each step by the branded email owner_use_charges (and the in-app notice and phone alert it
--    brings), with each charge and the evidence it rests on.
-- 4. app.job_owner_use_charges (every 10 minutes): bills what is ready, reminds, falls back to the statement.
-- No applied migration is edited: functions are patched in place from their current definition or wrapped (_pre3270).
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
  if position(p_old in d) = 0 then raise exception '3270: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. settings and columns
alter table program_settings
  add column if not exists owner_use_bill boolean not null default true,
  add column if not exists owner_use_charge_due_days integer not null default 7 check (owner_use_charge_due_days between 1 and 60),
  add column if not exists owner_use_reminder_days integer not null default 2 check (owner_use_reminder_days between 1 and 30),
  add column if not exists owner_use_settle_minutes integer not null default 15 check (owner_use_settle_minutes between 0 and 1440);
comment on column program_settings.owner_use_bill is 'Owner-use bookings (3270): their charges are billed to the owner by themselves. Off: as before 3270 (nothing is assessed; a claim''s deductible is an owner deduction).';
comment on column program_settings.owner_use_charge_due_days is 'Owner-use charges (3270): days an unpaid invoice of owner-use charges waits before it is deducted from the owner''s next statement (7, as owner_invoice_due_days).';
comment on column program_settings.owner_use_reminder_days is 'Owner-use charges (3270): days between reminders of an unpaid invoice.';
comment on column program_settings.owner_use_settle_minutes is 'Owner-use charges (3270): minutes a new charge waits before the job bills it, so the charges of one return go on one invoice.';

alter table booking_line_items add column if not exists owner_invoice_id uuid references owner_invoices (id) on delete set null;
create index if not exists booking_line_items_owner_invoice_id_fk on booking_line_items (owner_invoice_id) where owner_invoice_id is not null;
comment on column booking_line_items.owner_invoice_id is 'A charge of an owner-use booking (3270): the owner invoice it was billed on. Such a line is never on a renter statement.';

alter table owner_deductions add column if not exists owner_invoice_id uuid references owner_invoices (id) on delete set null;
create index if not exists owner_deductions_owner_invoice_id_fk on owner_deductions (owner_invoice_id) where owner_invoice_id is not null;
alter table owner_deductions drop constraint if exists owner_deductions_status_check;
alter table owner_deductions add constraint owner_deductions_status_check check (status in ('open', 'deducted', 'paid', 'waived', 'invoiced'));
comment on column owner_deductions.owner_invoice_id is 'A toll, ticket or claim deductible of an owner-use booking (3270): the owner invoice it was billed on (status invoiced), so it is collected at once and not deducted from a statement a second time.';

alter table owner_invoices
  add column if not exists owner_use_booking_id uuid references bookings (id) on delete set null,
  add column if not exists owner_use_state text check (owner_use_state in ('card', 'debit', 'pay_now', 'deducting')),
  add column if not exists owner_use_fallback_on date,
  add column if not exists owner_use_reminded_at timestamptz,
  add column if not exists owner_use_reminders integer not null default 0;
create index if not exists owner_invoices_owner_use_booking_id_fk on owner_invoices (owner_use_booking_id) where owner_use_booking_id is not null;
comment on column owner_invoices.owner_use_booking_id is 'The owner-use booking whose charges this invoice bills (3270).';
comment on column owner_invoices.owner_use_state is 'Owner-use charges (3270), how it is being collected: card (charged to the card on file), debit (a bank debit started the same day), pay_now (no method or the charge failed: the owner pays from the link), deducting (unpaid after the due window: deducted from the next statement).';

alter table owner_debit_attempts
  add column if not exists immediate boolean not null default false,
  add column if not exists method_kind text not null default 'pre_authorized_debit' check (method_kind in ('pre_authorized_debit', 'card'));
comment on column owner_debit_attempts.immediate is 'An owner-use charge (3270): taken the day it is billed, outside the monthly run, its notice days and its retry and Late Fee rules.';

create function app.owner_use_bill_on() returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((app.settings()).owner_use_bill, true)
$$;

-- ================================================================ 2. charges are assessed and accepted on an Owner Booking
select pg_temp.patch_fn('app.assess_check_in(uuid, jsonb, uuid)'::regprocedure,
  $o$if b.booking_type <> 'owner' then$o$, $n$if b.booking_type <> 'owner' or app.owner_use_bill_on() then$n$);
-- (damage on an Owner Booking keeps its rule: under the deductible the Owner repairs it; with a claim the deductible is an
-- owner deduction, owner_booking_deductible. app.owner_use_bill takes that deduction, and the tolls and tickets matched to
-- an Owner Booking, owner_booking_toll and owner_booking_ticket, onto the invoice: they are due at once too.)
select pg_temp.patch_fn('app.damage_charge_add(uuid, jsonb)'::regprocedure,
  $o$if b.booking_type = 'owner' then raise$o$, $n$if b.booking_type = 'owner' and not app.owner_use_bill_on() then raise$n$);
select pg_temp.patch_fn('app.return_charge_add(uuid, jsonb)'::regprocedure,
  $o$if b.booking_type::text = 'owner' then raise$o$, $n$if b.booking_type::text = 'owner' and not app.owner_use_bill_on() then raise$n$);
select pg_temp.patch_fn('app.speeding_charge_add(uuid, jsonb)'::regprocedure,
  $o$if b.booking_type::text = 'owner' then raise$o$, $n$if b.booking_type::text = 'owner' and not app.owner_use_bill_on() then raise$n$);
select pg_temp.patch_fn('app.booking_fees_change(uuid, jsonb)'::regprocedure,
  $o$if b.booking_type::text = 'owner' then raise$o$, $n$if b.booking_type::text = 'owner' and not app.owner_use_bill_on() then raise$n$);

-- ================================================================ 3. the email
create function app.owner_use_notify(p_invoice uuid, p_state text, p_key text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  i owner_invoices;
  b bookings;
  s program_settings := app.settings();
  v_first text;
  v_title text;
  v_text text;
  v_how text;
  v_lines jsonb;
  v_evidence jsonb;
begin
  select * into i from owner_invoices where id = p_invoice;
  if i.id is null or i.owner_use_booking_id is null then return; end if;
  select * into b from bookings where id = i.owner_use_booking_id;
  select coalesce(nullif(split_part(btrim(coalesce(u.full_name, o.legal_name, '')), ' ', 1), ''), 'there') into v_first
    from owners o left join users u on u.id = o.user_id where o.id = i.owner_id;
  select jsonb_agg(jsonb_build_object('label', l.description, 'amount', app.fmt_money(l.amount_cents + l.hst_cents)) order by l.sort_order),
         jsonb_agg(jsonb_build_object('label', l.description, 'note', l.note) order by l.sort_order) filter (where nullif(l.note, '') is not null)
    into v_lines, v_evidence
    from owner_invoice_lines l where l.owner_invoice_id = i.id;
  v_title := case p_state
    when 'card' then format('%s charged to your card: your booking %s', app.fmt_money(i.total_cents), b.booking_number)
    when 'debit' then format('%s is being debited from your bank account: your booking %s', app.fmt_money(i.total_cents), b.booking_number)
    when 'pay_now' then format('%s is due now: charges on your booking %s', app.fmt_money(i.balance_cents), b.booking_number)
    when 'reminder' then format('Reminder: %s is still due for your booking %s', app.fmt_money(i.balance_cents), b.booking_number)
    else format('%s will be deducted from your next statement', app.fmt_money(i.balance_cents)) end;
  v_text := format('These charges are from your own booking %s of your %s (%s to %s). You are responsible for the charges of a booking you make for yourself or for someone else.',
    b.booking_number, app.vehicle_name(b.vehicle_id), app.fmt_day(app.local_date(b.pickup_at)), app.fmt_day(app.local_date(b.return_at)));
  v_how := case p_state
    when 'card' then 'We are charging the card you have on file now. There is nothing to do. If the card is declined we will email you a link to pay.'
    when 'debit' then 'We started a pre-authorized debit from your bank account today. There is nothing to do. If the bank returns it we will email you a link to pay.'
    when 'pay_now' then format('We could not take it from a payment method on file. Please pay invoice %s now from the link. If it is not paid by %s, it is deducted from your next statement.',
      i.invoice_number, app.fmt_day(app.owner_use_deduct_on(i.billing_date)))
    when 'reminder' then format('Invoice %s is not paid yet. Please pay it from the link. If it is not paid by %s, it is deducted from your next statement.',
      i.invoice_number, app.fmt_day(app.owner_use_deduct_on(i.billing_date)))
    else format('Invoice %s was not paid, so it comes off your next statement as its own line. There is nothing to do. You can still pay it from the link before the statement.', i.invoice_number) end;
  perform app.emit_event('owner_use_charges', 'owner_invoice', i.id, jsonb_build_object('owner_id', i.owner_id, 'vehicle_id', i.vehicle_id,
    'first_name', v_first, 'charge_title', v_title, 'charge_text', v_text, 'charge_how', v_how, 'charge_lines', coalesce(v_lines, '[]'::jsonb),
    'charge_evidence', coalesce(v_evidence, '[]'::jsonb), 'has_evidence', v_evidence is not null, 'invoice_total', app.fmt_money(i.total_cents), 'invoice_number', i.invoice_number, 'amount', app.fmt_money(greatest(i.balance_cents, 0)),
    'pay_now', p_state in ('pay_now', 'reminder', 'deducting'), 'state', p_state),
    'owner_use_charges:' || i.id || ':' || p_key);
end $$;

-- ================================================================ 4. the bill
-- the evidence a line rests on, in words (what was found by itself or attached, 3190)
create function app.owner_use_evidence(p_line uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v text;
  li booking_line_items;
begin
  select * into li from booking_line_items where id = p_line;
  begin
    select string_agg(app.fee_evidence_label(k), ', ' order by k) into v from jsonb_object_keys(app.fee_evidence_have(p_line)) k;
  exception when others then v := null;
  end;
  if li.evidence_status = 'overridden' then
    v := concat_ws('; ', v, 'approved by an Admin: ' || coalesce(li.evidence_override_reason, 'reason on file'));
  end if;
  return left(nullif(concat_ws('', 'Evidence: ' || nullif(v, '')), ''), 480);
end $$;

create function app.owner_use_bill(p_booking uuid, p_by uuid default null, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  s program_settings := app.settings();
  li booking_line_items;
  od owner_deductions;
  i owner_invoices;
  m jsonb;
  c record;
  v_gate boolean;
  v_n integer := 0;
  v_waiting integer;
  v_cap bigint;
  v_amount bigint;
  v_hst bigint;
  v_note text;
  v_state text;
  v_today date := app.local_date(p_now);
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null or b.booking_type::text <> 'owner' or b.owner_id is null or not s.owner_use_bill then return null; end if;
  v_gate := coalesce(s.fee_evidence_gate, true);
  if v_gate then perform app.fee_evidence_recheck(p_booking); end if;
  select count(*) into v_waiting from booking_line_items x
   where x.booking_id = p_booking and x.voided_at is null and x.owner_invoice_id is null and x.amount_cents > 0 and x.evidence_status = 'needs_evidence' and v_gate;
  -- the damage of this booking already billed, against the deductible
  select greatest(s.deductible_cents - coalesce(sum(x.amount_cents), 0), 0) into v_cap from booking_line_items x
   where x.booking_id = p_booking and x.voided_at is null and x.owner_invoice_id is not null and x.charge_type in ('damage_at_cost', 'deductible');
  v_cap := greatest(v_cap - coalesce((select sum(x.amount_cents) from owner_deductions x
                                       where x.booking_id = p_booking and x.kind = 'owner_booking_deductible' and x.status = 'invoiced'), 0), 0);

  for li in select x.* from booking_line_items x
             where x.booking_id = p_booking and x.voided_at is null and x.owner_invoice_id is null and x.statement_id is null and x.payment_id is null
               and x.amount_cents > 0 and x.charged_to_renter and (not v_gate or x.evidence_status is distinct from 'needs_evidence')
             order by x.created_at, x.id for update loop
    if i.id is null then
      insert into owner_invoices (owner_id, vehicle_id, kind, billing_date, payment_method, status, created_by, title, notes, due_on, owner_use_booking_id)
      values (b.owner_id, b.vehicle_id, 'custom', v_today, 'card', 'draft', p_by, left(format('Charges on your booking %s', b.booking_number), 120),
              format('Charges during the owner-use booking %s (%s to %s). The owner is responsible for the charges of a booking they make for themselves or for someone else.',
                     b.booking_number, app.fmt_day(app.local_date(b.pickup_at)), app.fmt_day(app.local_date(b.return_at))),
              v_today, b.id)
      returning * into i;
    end if;
    v_amount := li.amount_cents; v_hst := coalesce(li.hst_cents, 0); v_note := app.owner_use_evidence(li.id);
    if li.charge_type in ('damage_at_cost', 'deductible') then
      if v_amount > v_cap then
        v_note := left(concat_ws(' ', format('Damage is billed up to the %s deductible for the booking (the full amount was %s).', app.fmt_money(s.deductible_cents), app.fmt_money(li.amount_cents)), v_note), 480);
        v_hst := case when v_amount > 0 then round(v_hst::numeric * v_cap / v_amount) else 0 end;
        v_amount := v_cap;
      end if;
      v_cap := v_cap - v_amount;
    end if;
    update booking_line_items set owner_invoice_id = i.id where id = li.id;
    if v_amount <= 0 then continue; end if;
    v_n := v_n + 1;
    insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents, quantity, unit_amount_cents, note, sort_order)
    values (i.id, 'custom', left(coalesce(nullif(li.description, ''), (select ft.label from fee_types ft where ft.code = li.charge_type), replace(li.charge_type, '_', ' ')), 200),
            v_amount, v_hst > 0, v_hst, 1, v_amount, v_note, v_n);
  end loop;
  -- the tolls, tickets and claim deductible already matched to this Owner Booking as owner deductions: due at once too
  for od in select x.* from owner_deductions x
             where x.booking_id = p_booking and x.status = 'open' and x.owner_statement_id is null
               and x.kind in ('owner_booking_toll', 'owner_booking_ticket', 'owner_booking_deductible')
             order by x.created_at, x.id for update loop
    if i.id is null then
      insert into owner_invoices (owner_id, vehicle_id, kind, billing_date, payment_method, status, created_by, title, notes, due_on, owner_use_booking_id)
      values (b.owner_id, b.vehicle_id, 'custom', v_today, 'card', 'draft', p_by, left(format('Charges on your booking %s', b.booking_number), 120),
              format('Charges during the owner-use booking %s (%s to %s). The owner is responsible for the charges of a booking they make for themselves or for someone else.',
                     b.booking_number, app.fmt_day(app.local_date(b.pickup_at)), app.fmt_day(app.local_date(b.return_at))),
              v_today, b.id)
      returning * into i;
    end if;
    v_amount := od.amount_cents; v_hst := coalesce(od.hst_cents, 0); v_note := null;
    if od.kind = 'owner_booking_deductible' then
      if v_amount > v_cap then
        v_note := format('Damage is billed up to the %s deductible for the booking (the full amount was %s).', app.fmt_money(s.deductible_cents), app.fmt_money(od.amount_cents));
        v_amount := v_cap;
      end if;
      v_cap := v_cap - v_amount;
    end if;
    update owner_deductions set status = 'invoiced', owner_invoice_id = i.id where id = od.id;
    if v_amount <= 0 then continue; end if;
    v_n := v_n + 1;
    insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents, quantity, unit_amount_cents, note, sort_order)
    values (i.id, 'custom', left(od.description, 200), v_amount, v_hst > 0, v_hst, 1, v_amount,
            coalesce(v_note, case od.kind when 'owner_booking_toll' then 'Evidence: the 407 statement line matched to your booking''s dates'
                                           when 'owner_booking_ticket' then 'Evidence: the ticket notice matched to your booking''s dates'
                                           else 'Evidence: the claim, its photos and the repair estimate' end), v_n);
  end loop;
  if i.id is null then return jsonb_build_object('booking_id', p_booking, 'billed', 0, 'waiting_for_evidence', v_waiting); end if;
  if v_n = 0 then
    -- every line was over the deductible already billed: nothing to invoice
    delete from owner_invoices where id = i.id;
    return jsonb_build_object('booking_id', p_booking, 'billed', 0, 'waiting_for_evidence', v_waiting);
  end if;

  -- issued and due today, without the usual "invoice issued" email (the owner gets owner_use_charges instead)
  perform set_config('app.invoice_quiet', i.id::text, true);
  update owner_invoices set status = 'issued', billing_date = v_today, issued_by = p_by, due_on = v_today where id = i.id returning * into i;
  perform set_config('app.invoice_quiet', '', true);

  -- a. the payment method on file, at once: the card, otherwise the pre-authorized debit
  select mth.id, mth.last4, sec.processor_customer_id, sec.processor_method_id into c
    from owner_payment_methods mth join owner_payment_method_secrets sec on sec.owner_payment_method_id = mth.id
   where mth.owner_id = i.owner_id and mth.kind = 'card' and mth.status = 'active'
     and nullif(sec.processor_customer_id, '') is not null and nullif(sec.processor_method_id, '') is not null
   order by mth.is_default desc, mth.created_at desc limit 1;
  m := app.owner_debit_mandate(i.owner_id);
  if i.balance_cents > 0 and app.owner_debit_block(i.id) is null and c.id is not null then
    insert into owner_debit_attempts (owner_invoice_id, owner_id, attempt_no, debit_on, amount_cents, idempotency_key, bank_last4, immediate, method_kind,
                                      processor_customer_id, processor_method_id)
    values (i.id, i.owner_id, 1, v_today, i.balance_cents, 'owner-use:' || gen_random_uuid(), c.last4, true, 'card', c.processor_customer_id, c.processor_method_id);
    v_state := 'card';
  elsif i.balance_cents > 0 and app.owner_debit_block(i.id) is null and m is not null and s.owner_debit_enabled then
    insert into owner_debit_attempts (owner_invoice_id, owner_id, attempt_no, debit_on, amount_cents, idempotency_key, bank_last4, immediate, method_kind,
                                      processor_customer_id, processor_method_id, processor_mandate_id)
    values (i.id, i.owner_id, 1, v_today, i.balance_cents, 'owner-use:' || gen_random_uuid(), m ->> 'last4', true, 'pre_authorized_debit',
            m ->> 'customer_id', m ->> 'processor_method_id', m ->> 'mandate_id');
    update owner_invoices set debit_on = v_today, payment_method = 'pre_authorized_debit' where id = i.id;
    v_state := 'debit';
  else
    v_state := 'pay_now';
  end if;
  update owner_invoices set owner_use_state = v_state, owner_use_reminded_at = case when v_state = 'pay_now' then p_now end where id = i.id;
  perform app.owner_use_notify(i.id, v_state, 'billed');
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'owner_use_bill', 'owner_invoices', i.id::text, jsonb_build_object('booking_id', p_booking, 'lines', v_n, 'total_cents', i.total_cents, 'collect', v_state));
  return jsonb_build_object('booking_id', p_booking, 'billed', v_n, 'invoice_id', i.id, 'invoice_number', i.invoice_number, 'total_cents', i.total_cents,
                            'collect', v_state, 'waiting_for_evidence', v_waiting);
end $$;

-- ================================================================ 5. never a renter statement, never a renter's card
alter function app.issue_booking_statement(uuid, uuid, timestamptz) rename to issue_booking_statement_pre3270;
create function app.issue_booking_statement(p_booking uuid, p_by uuid default null, p_now timestamptz default now()) returns uuid
language plpgsql security definer set search_path = public, app as $$
begin
  if app.owner_use_bill_on() and exists (select 1 from bookings b where b.id = p_booking and b.booking_type::text = 'owner') then
    perform app.owner_use_bill(p_booking, p_by, p_now);
    return null;
  end if;
  return app.issue_booking_statement_pre3270(p_booking, p_by, p_now);
end $$;
select pg_temp.copy_grants('app.issue_booking_statement(uuid, uuid, timestamptz)'::regprocedure, 'app.issue_booking_statement_pre3270(uuid, uuid, timestamptz)'::regprocedure);

alter function app.charge_after_rental(uuid, uuid, timestamptz) rename to charge_after_rental_pre3270;
create function app.charge_after_rental(p_booking uuid, p_by uuid, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if app.owner_use_bill_on() and exists (select 1 from bookings b where b.id = p_booking and b.booking_type::text = 'owner') then
    return jsonb_build_object('statement_id', null, 'settlement', null, 'owner_use', app.owner_use_bill(p_booking, p_by, p_now));
  end if;
  return app.charge_after_rental_pre3270(p_booking, p_by, p_now);
end $$;
select pg_temp.copy_grants('app.charge_after_rental(uuid, uuid, timestamptz)'::regprocedure, 'app.charge_after_rental_pre3270(uuid, uuid, timestamptz)'::regprocedure);

-- ================================================================ 6. the charge at once: claim, request, failure
alter function app.owner_debit_request(owner_debit_attempts, owner_invoices, owners) rename to owner_debit_request_pre3270;
create function app.owner_debit_request(a owner_debit_attempts, i owner_invoices, o owners) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.owner_debit_request_pre3270(a, i, o) || jsonb_build_object('method_kind', a.method_kind)
$$;
select pg_temp.copy_grants('app.owner_debit_request(owner_debit_attempts, owner_invoices, owners)'::regprocedure,
                           'app.owner_debit_request_pre3270(owner_debit_attempts, owner_invoices, owners)'::regprocedure);

alter function app.owner_debit_claim(timestamptz, integer) rename to owner_debit_claim_pre3270;
create function app.owner_debit_claim(p_now timestamptz default now(), p_limit integer default 25) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a owner_debit_attempts;
  i owner_invoices;
  o owners;
  v_out jsonb := '[]'::jsonb;
  v_run uuid;
begin
  -- the owner-use charges first, whatever the hour and whatever the day of the month
  for a in select * from owner_debit_attempts where immediate and status = 'scheduled' order by created_at for update skip locked loop
    select * into i from owner_invoices where id = a.owner_invoice_id for update;
    select * into o from owners where id = a.owner_id;
    if i.status in ('paid', 'deducted', 'void') or i.balance_cents <= 0 or i.collect_by = 'payout' then
      update owner_debit_attempts set status = 'canceled', skip_reason = 'nothing left to collect' where id = a.id;
      continue;
    end if;
    v_run := coalesce(v_run, app.owner_debit_run('debit', app.local_date(p_now)));
    update owner_debit_attempts set status = 'submitting', run_id = v_run, amount_cents = least(amount_cents, i.balance_cents) where id = a.id returning * into a;
    v_out := v_out || jsonb_build_array(app.owner_debit_request(a, i, o));
  end loop;
  return v_out || coalesce(app.owner_debit_claim_pre3270(p_now, p_limit), '[]'::jsonb);
end $$;
select pg_temp.copy_grants('app.owner_debit_claim(timestamptz, integer)'::regprocedure, 'app.owner_debit_claim_pre3270(timestamptz, integer)'::regprocedure);

-- a failed charge of an owner-use invoice: no retry, no Late Fee; the invoice is due now and the owner gets the pay link
alter function app.owner_debit_fail(uuid, text, text) rename to owner_debit_fail_pre3270;
create function app.owner_debit_fail(p_attempt uuid, p_code text, p_message text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a owner_debit_attempts;
  i owner_invoices;
  v_msg text := coalesce(nullif(btrim(p_message), ''), 'The charge was not accepted.');
begin
  select * into a from owner_debit_attempts where id = p_attempt for update;
  if a.id is null or not a.immediate then return app.owner_debit_fail_pre3270(p_attempt, p_code, p_message); end if;
  if a.status in ('failed', 'succeeded', 'canceled', 'skipped') then return jsonb_build_object('ok', true, 'repeat', true, 'status', a.status); end if;
  update owner_debit_attempts set status = 'failed', failure_code = left(p_code, 100), failure_message = left(v_msg, 500), settled_at = now() where id = a.id;
  update payments set status = 'failed', decline_count = decline_count + 1, last_decline_code = left(v_msg, 200), processed_at = now()
   where id = a.payment_id and status = 'pending';
  update owner_debit_runs set failed = failed + 1 where id = a.run_id;
  select * into i from owner_invoices where id = a.owner_invoice_id for update;
  if i.status in ('paid', 'deducted', 'void') then return jsonb_build_object('ok', true, 'status', 'failed', 'invoice_status', i.status); end if;
  if i.status in ('processing', 'retry_processing') then
    perform set_config('app.invoice_quiet', i.id::text, true);
    update owner_invoices set status = 'issued' where id = i.id;
    perform set_config('app.invoice_quiet', '', true);
  end if;
  update owner_invoices set debit_on = null, owner_use_state = 'pay_now', owner_use_reminded_at = now() where id = i.id;
  perform app.owner_use_notify(i.id, 'pay_now', 'failed:' || a.id);
  perform app.ntf_emit('staff_owner_debit_exception', 'owner_debit_attempt', a.id, 'owner_use_failed',
    jsonb_build_object('owner_id', i.owner_id, 'exception', 'returned',
      'reason', format('The %s charge of invoice %s (owner-use charges) failed: %s. The owner was emailed the link to pay; unpaid, it is deducted from the next statement.',
                       case a.method_kind when 'card' then 'card' else 'bank debit' end, i.invoice_number, rtrim(v_msg, '.'))));
  return jsonb_build_object('ok', true, 'status', 'failed', 'invoice_status', 'issued', 'retry', false, 'owner_use', true);
end $$;
select pg_temp.copy_grants('app.owner_debit_fail(uuid, text, text)'::regprocedure, 'app.owner_debit_fail_pre3270(uuid, text, text)'::regprocedure);

-- ================================================================ 7. the job: bill, remind, fall back to the statement
-- when an unpaid invoice of owner-use charges moves to the statement: whichever comes first of owner_use_charge_due_days
-- after it was issued and the next statement cut-off (statement_cutoff_day, the 7th) on or after the day it was issued
create function app.owner_use_deduct_on(p_issued date) returns date
language sql stable security definer set search_path = public, app as $$
  select least(p_issued + s.owner_use_charge_due_days,
               case when extract(day from p_issued)::int <= s.statement_cutoff_day
                    then (date_trunc('month', p_issued)::date + (s.statement_cutoff_day - 1))
                    else ((date_trunc('month', p_issued) + interval '1 month')::date + (s.statement_cutoff_day - 1)) end)
    from app.settings() s
$$;

-- the unpaid invoices whose day has come (of one owner, or of every owner) are handed to the statements
create function app.owner_use_fallback(p_owner uuid default null, p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  i owner_invoices;
  v_today date := app.local_date(p_now);
  v_n integer := 0;
begin
  if not app.owner_use_bill_on() then return 0; end if;
  for i in select x.* from owner_invoices x
            where x.owner_use_booking_id is not null and (p_owner is null or x.owner_id = p_owner)
              and x.status in ('issued', 'failed', 'in_arrears') and x.balance_cents > 0 and x.collect_by = 'bank_debit'
              and v_today >= app.owner_use_deduct_on(x.billing_date)
              and not exists (select 1 from owner_debit_attempts a where a.owner_invoice_id = x.id and a.status in ('submitting', 'processing'))
            for update skip locked loop
    update owner_debit_attempts set status = 'canceled', skip_reason = 'deducted from the statement' where owner_invoice_id = i.id and status = 'scheduled';
    update owner_invoices set collect_by = 'payout', owner_use_state = 'deducting', owner_use_fallback_on = v_today, debit_on = null where id = i.id;
    perform app.owner_use_notify(i.id, 'deducting', 'deducting');
    insert into audit_log (action, entity_table, entity_id, after)
    values ('owner_use_deduct_from_statement', 'owner_invoices', i.id::text,
            jsonb_build_object('balance_cents', i.balance_cents, 'issued_on', i.billing_date, 'due', app.owner_use_deduct_on(i.billing_date)));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- the statement run on its cut-off day takes every invoice still unpaid that day, whatever the job's minute
alter function app.build_owner_statement(uuid, date, uuid) rename to build_owner_statement_pre3270;
create function app.build_owner_statement(p_owner uuid, p_month date, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.owner_use_fallback(p_owner, now());
  return app.build_owner_statement_pre3270(p_owner, p_month, p_by);
end $$;
select pg_temp.copy_grants('app.build_owner_statement(uuid, date, uuid)'::regprocedure, 'app.build_owner_statement_pre3270(uuid, date, uuid)'::regprocedure);

create function app.job_owner_use_charges(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  r record;
  i owner_invoices;
  v_billed integer := 0;
  v_reminded integer := 0;
  v_deducting integer := 0;
begin
  if not s.owner_use_bill then return jsonb_build_object('off', true); end if;
  -- a. charges that are ready
  for r in select li.booking_id from booking_line_items li join bookings b on b.id = li.booking_id
            where b.booking_type::text = 'owner' and b.owner_id is not null and b.status::text in ('on_rent', 'returned', 'closed')
              and li.voided_at is null and li.owner_invoice_id is null and li.statement_id is null and li.payment_id is null and li.amount_cents > 0
              and li.charged_to_renter and li.created_at <= p_now - make_interval(mins => s.owner_use_settle_minutes)
           union
           select d.booking_id from owner_deductions d join bookings b on b.id = d.booking_id
            where b.booking_type::text = 'owner' and d.status = 'open' and d.owner_statement_id is null
              and d.kind in ('owner_booking_toll', 'owner_booking_ticket', 'owner_booking_deductible')
              and d.created_at <= p_now - make_interval(mins => s.owner_use_settle_minutes) loop
    begin
      if coalesce((app.owner_use_bill(r.booking_id, null, p_now) ->> 'billed')::integer, 0) > 0 then v_billed := v_billed + 1; end if;
    exception when others then
      insert into audit_log (action, entity_table, entity_id, after) values ('owner_use_bill_failed', 'bookings', r.booking_id::text, jsonb_build_object('error', sqlerrm));
    end;
  end loop;
  -- c. unpaid past the due window or at the statement cut-off: the statement takes it
  v_deducting := app.owner_use_fallback(null, p_now);
  -- b. reminders while it waits
  for i in select x.* from owner_invoices x
            where x.owner_use_booking_id is not null and x.status in ('issued', 'failed', 'in_arrears') and x.balance_cents > 0 and x.collect_by = 'bank_debit'
              and not exists (select 1 from owner_debit_attempts a where a.owner_invoice_id = x.id and a.status in ('scheduled', 'submitting', 'processing'))
              and coalesce(x.owner_use_reminded_at, x.issued_at, x.created_at) <= p_now - make_interval(days => s.owner_use_reminder_days)
            for update skip locked loop
    update owner_invoices set owner_use_state = 'pay_now', owner_use_reminded_at = p_now, owner_use_reminders = owner_use_reminders + 1 where id = i.id;
    perform app.owner_use_notify(i.id, case when i.owner_use_state = 'pay_now' then 'reminder' else 'pay_now' end, 'reminder:' || (i.owner_use_reminders + 1));
    v_reminded := v_reminded + 1;
  end loop;
  return jsonb_build_object('billed', v_billed, 'reminded', v_reminded, 'deducting', v_deducting);
end $$;

-- what an owner-use booking was billed, for the booking's Money tab and the owner's page
create function app.owner_use_charges_read(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'owner_use', exists (select 1 from bookings b where b.id = p_booking and b.booking_type::text = 'owner'),
    'on', app.owner_use_bill_on(),
    'waiting', coalesce((select jsonb_agg(jsonb_build_object('id', li.id, 'description', coalesce(li.description, li.charge_type), 'amount_cents', li.amount_cents + coalesce(li.hst_cents, 0),
                 'evidence_status', li.evidence_status, 'missing', to_jsonb(li.evidence_missing)) order by li.created_at)
               from booking_line_items li where li.booking_id = p_booking and li.voided_at is null and li.owner_invoice_id is null and li.amount_cents > 0 and li.charged_to_renter
                 and exists (select 1 from bookings b where b.id = p_booking and b.booking_type::text = 'owner')), '[]'::jsonb),
    'invoices', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'status', i.status, 'total_cents', i.total_cents,
                 'balance_cents', i.balance_cents, 'state', i.owner_use_state, 'collect_by', i.collect_by, 'issued_on', i.billing_date,
                 'deduct_after', app.owner_use_deduct_on(i.billing_date), 'reminders', i.owner_use_reminders,
                 'lines', (select coalesce(jsonb_agg(jsonb_build_object('description', l.description, 'amount_cents', l.amount_cents + l.hst_cents, 'note', l.note) order by l.sort_order), '[]'::jsonb)
                             from owner_invoice_lines l where l.owner_invoice_id = i.id)) order by i.created_at)
               from owner_invoices i where i.owner_use_booking_id = p_booking and i.status <> 'void'), '[]'::jsonb))
$$;

-- ================================================================ 8. catalogue, preference type, cron
insert into notification_catalogue (code, audience, category, subject, preheader, timing, trigger_text, link_path, variables, template_html, template_text, emitted_by, pref_type, priority, push_topic)
values ('owner_use_charges', 'owner', 'transactional', '{{charge_title}}', '{{charge_how}}', 'Immediate, once per step',
        'Owner-use charges (3270): the charges of a booking the owner made for themselves or for someone else were billed to the owner (charged to the card on file, a bank debit started, or due now with the pay link); a reminder while unpaid; and when the unpaid invoice moves to the next statement.',
        '/owner/invoices/{{invoice_number}}',
        '[{"name":"first_name","type":"string"},{"name":"charge_title","type":"string"},{"name":"charge_text","type":"string"},{"name":"charge_how","type":"string"},{"name":"charge_lines","type":"list","fields":["label","amount"]},{"name":"charge_evidence","type":"list","fields":["label","note"]},{"name":"has_evidence","type":"boolean"},{"name":"invoice_total","type":"string"},{"name":"invoice_number","type":"string"},{"name":"amount","type":"string"},{"name":"pay_now","type":"boolean"}]'::jsonb,
        'templates/owner_use_charges.html', 'templates/owner_use_charges.txt', 'app.owner_use_notify (3270)', 'charges', 1, 'payments')
on conflict (code) do update set emitted_by = excluded.emitted_by, pref_type = excluded.pref_type, priority = excluded.priority, push_topic = excluded.push_topic;

insert into sms_templates (code, label, body, urgent, sort_order) values
  ('owner_use_charges', 'Owner-use charges', 'CarmaCars: {{charge_title}}. {{link}}', false, 410),
  ('owner_reward_update', 'Owner rewards', 'CarmaCars: {{reward_title}}. {{link}}', false, 411)
on conflict (code) do nothing;

-- a kind that starts off on every channel (New bookings on your cars) leaves no notice in the portal either until the
-- person turns a channel on: owners are not told about new bookings, as before 3260
create function app.notify_pref_notice() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_type text;
  t notify_types;
  f record;
begin
  -- an owner's tracker alert (speed, health) keeps its notice in the portal; only its email, phone alert and text are the owner's choice
  if new.code = 'owner_tracker_alert' then return new; end if;
  v_type := app.notify_type_of(new.code, (select e.payload ->> 'rule' from app_events e where e.id = new.event_id));
  if v_type is null then return new; end if;
  select * into t from notify_types where code = v_type;
  if t.code is null or t.locked or t.push_default or t.email_default or t.text_default then return new; end if;
  select * into f from app.notify_pref_of('user', new.user_id, v_type);
  if f.push or f.email or f.sms then return new; end if;
  return null;
end $$;
revoke all on function app.notify_pref_notice() from public, anon, authenticated;
grant execute on function app.notify_pref_notice() to service_role;
create trigger notifications_a_prefs before insert on notifications for each row execute function app.notify_pref_notice();

create index if not exists owner_reward_ledger_created_by_fk on owner_reward_ledger (created_by);

-- three tables of 3260 and 3264 hold status and are audited like every other (the base test of 03_flows asks for it)
create trigger audit_notify_digest_items after insert or update or delete on notify_digest_items for each row execute function app.audit_row();
create trigger audit_tracker_driving_events after insert or update or delete on tracker_driving_events for each row execute function app.audit_row();
create trigger audit_owner_tracker_weeklies after insert or update or delete on owner_tracker_weeklies for each row execute function app.audit_row();

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('carmacars-owner-use-charges', '*/10 * * * *', $q$select app.job_owner_use_charges()$q$);
  end if;
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('owner_use_bill_on', 'owner_use_notify', 'owner_use_evidence', 'owner_use_bill', 'job_owner_use_charges', 'owner_use_charges_read', 'owner_use_deduct_on', 'owner_use_fallback') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
