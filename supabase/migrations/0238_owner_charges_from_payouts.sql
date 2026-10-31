-- 0238: owner charges deducted from payouts (docs/changes/2026-11-03-owner-charges-from-payouts.md). The owner, Release 23:
-- an owner invoice (the first and last month, a one-off fee such as the registration costs) could only be debited from the
-- owner's bank on the 15th, marked paid, kept as a draft or skipped; it could not be taken out of the owner's revenue.
--
-- 1. owner_invoices.collect_by: 'bank_debit' (as before: debited on the 15th) or 'payout' (deducted from payouts). An
--    invoice deducted from payouts is never debited (app.owner_debit_block says why) and gets no debit email: it is issued
--    quietly.
-- 2. The monthly statement (app.build_owner_statement_0025) deducts it like an unpaid invoice: a "fees_deducted" line on
--    its car (Fees with HST first) for as much as that car's payout allows, the rest as "arrears_moved" lines from the
--    owner's other cars, and anything still left waits for the next statement, until paid (approving the statement records
--    what was taken: partially_deducted, then deducted). The owner sees each as an itemized deduction (the invoice and the
--    amount); Admin sees the balance on the invoice.
-- 3. How it's paid, chosen: on an invoice (app.owner_invoice_collect_by, Admin: "Deduct from payouts" or "Bank debit on the
--    15th"; a draft deducted from payouts is issued quietly, scheduled debits are cancelled), on the first and last month
--    decision (first_last_choose action 'deduct'), and for the one-off fees agreed on the owner's terms
--    (app.owner_one_off_charge: the fees chosen, one invoice per car in one step, deducted from payouts or debited).
-- Existing invoices are not changed by this migration: an Admin converts them (the invoice screen, How it's paid).
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
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0238: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

alter table owner_invoices add column if not exists collect_by text not null default 'bank_debit' check (collect_by in ('bank_debit', 'payout'));
comment on column owner_invoices.collect_by is 'How it is paid (0238): bank_debit, debited on the 15th (0037); payout, deducted from the owner''s monthly payouts until paid, never debited.';

-- ================================================================ 1. never debited
alter function app.owner_debit_block(uuid) rename to owner_debit_block_pre0238;
create function app.owner_debit_block(p_invoice uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when (select i.collect_by from owner_invoices i where i.id = p_invoice) = 'payout' then 'deducted from payouts'
              else app.owner_debit_block_pre0238(p_invoice) end
$$;
select pg_temp.copy_grants('app.owner_debit_block(uuid)'::regprocedure, 'app.owner_debit_block_pre0238(uuid)'::regprocedure);

-- ================================================================ 2. deducted on the statements
select pg_temp.patch_fn('app.build_owner_statement_0025(uuid, date, uuid)'::regprocedure,
  $o$i.status in ('in_arrears', 'partially_deducted')$o$,
  $n$(i.status in ('in_arrears', 'partially_deducted') or (i.collect_by = 'payout' and i.status in ('issued', 'failed')))$n$);

-- ================================================================ 3. how it's paid
create or replace function app.owner_invoice_collect_by(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i owner_invoices;
  v_to text := p ->> 'collect_by';
begin
  perform app.assert_admin(p_by);
  if v_to not in ('bank_debit', 'payout') then raise exception 'Choose Bank debit on the 15th or Deduct from payouts' using errcode = '22023'; end if;
  select * into i from owner_invoices where id::text = p ->> 'id' for update;
  if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if i.status in ('paid', 'deducted', 'void') or i.kind = 'credit_note' then raise exception 'This invoice is %: nothing left to collect', i.status using errcode = '23514'; end if;
  if v_to = 'bank_debit' and i.status = 'partially_deducted' then raise exception 'Part of it was deducted already: the rest is deducted from the next payouts' using errcode = '23514'; end if;
  if exists (select 1 from owner_debit_attempts a where a.owner_invoice_id = i.id and a.status in ('submitting', 'processing')) then
    raise exception 'A bank debit of this invoice is in progress: wait for its result' using errcode = '23514';
  end if;
  update owner_invoices set collect_by = v_to, updated_at = now() where id = i.id;
  if v_to = 'payout' then
    update owner_debit_attempts set status = 'canceled', skip_reason = 'deducted from payouts' where owner_invoice_id = i.id and status = 'scheduled';
    -- a draft is issued quietly (no debit email): the statements take it from here
    if i.status = 'draft' then perform app.owner_invoice_issue(p_by, jsonb_build_object('id', i.id, 'quiet', true)); end if;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'owner_invoice_collect_by', 'owner_invoices', i.id::text, jsonb_build_object('collect_by', i.collect_by), jsonb_build_object('collect_by', v_to));
  select * into i from owner_invoices where id = i.id;
  return jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'collect_by', i.collect_by, 'status', i.status, 'balance_cents', i.balance_cents);
end $$;

-- an invoice planned with action 'deduct' (the first and last month, a one-off fee): issued quietly, deducted from payouts
select pg_temp.patch_fn('app.oi_plan_invoice(uuid, uuid, jsonb, jsonb, uuid)'::regprocedure,
  $o$  if v_action not in ('send', 'draft', 'paid') then raise exception 'Choose send now, save as a draft or already paid' using errcode = '22023'; end if;$o$,
  $n$  if v_action not in ('send', 'draft', 'paid', 'deduct') then raise exception 'Choose send now, save as a draft, already paid or deduct from payouts' using errcode = '22023'; end if;$n$);
select pg_temp.patch_fn('app.oi_plan_invoice(uuid, uuid, jsonb, jsonb, uuid)'::regprocedure,
  $o$  elsif v_action = 'paid' then$o$,
  $n$  elsif v_action = 'deduct' then
    perform app.owner_invoice_collect_by(p_by, jsonb_build_object('id', v_id, 'collect_by', 'payout'));
  elsif v_action = 'paid' then$n$);

alter table vehicle_onboardings drop constraint if exists vehicle_onboardings_first_last_choice_check;
alter table vehicle_onboardings add constraint vehicle_onboardings_first_last_choice_check check (first_last_choice in ('send', 'draft', 'paid', 'none', 'deduct'));
select pg_temp.patch_fn('app.first_last_choose(uuid, jsonb)'::regprocedure,
  $o$  if v_action is null or v_action not in ('send', 'draft', 'paid', 'none') then
    raise exception 'Choose Send invoice now, Draft only, Already paid or No invoice' using errcode = '22023';$o$,
  $n$  if v_action is null or v_action not in ('send', 'draft', 'paid', 'none', 'deduct') then
    raise exception 'Choose Send invoice now (bank debit on the 15th), Deduct from payouts, Draft only, Already paid or No invoice' using errcode = '22023';$n$);

-- deducted from payouts: nothing to wait for after signing, as with No invoice (the car is not held back for months)
select pg_temp.patch_fn('app.first_last_choose(uuid, jsonb)'::regprocedure,
  $o$  if v_action = 'none' and ob.status = 'documents_signed' then$o$,
  $n$  if v_action in ('none', 'deduct') and ob.status = 'documents_signed' then$n$);

-- the one-off fees agreed on the owner's terms, as one invoice per car in one step
create or replace function app.owner_one_off_charge(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  t jsonb;
  v_lines jsonb;
  v_pick jsonb := coalesce(p -> 'fees', 'null'::jsonb);
  v_how text := coalesce(nullif(p ->> 'collect_by', ''), 'payout');
  r jsonb;
begin
  perform app.assert_admin(p_by);
  if v_how not in ('payout', 'bank_debit') then raise exception 'Choose Deduct from payouts or Bank debit on the 15th' using errcode = '22023'; end if;
  select * into v from vehicles where id::text = p ->> 'vehicle_id';
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  t := app.owner_terms_resolve(v.id);
  -- the fees chosen by their description (all the agreed ones when none is named)
  select coalesce(jsonb_agg(jsonb_build_object('kind', 'custom', 'description', f ->> 'description', 'quantity', 1,
           'unit_amount_cents', (f ->> 'amount_cents')::bigint, 'hst', coalesce((f ->> 'hst')::boolean, true)) order by n), '[]'::jsonb)
    into v_lines
    from jsonb_array_elements(coalesce(t -> 'one_off_fees', '[]'::jsonb)) with ordinality e(f, n)
   where coalesce((f ->> 'amount_cents')::bigint, 0) > 0
     and (jsonb_typeof(v_pick) <> 'array' or jsonb_array_length(v_pick) = 0 or exists (select 1 from jsonb_array_elements_text(v_pick) x where lower(x) = lower(f ->> 'description')));
  if jsonb_array_length(v_lines) = 0 then raise exception 'No agreed one-off fee to charge on this car (the owner''s Terms tab)' using errcode = '23514'; end if;
  r := app.oi_plan_invoice(p_by, v.id, t, jsonb_build_object('type', 'custom', 'title', coalesce(nullif(p ->> 'title', ''), 'One-off fees'),
         'notes', nullif(p ->> 'notes', ''), 'lines', v_lines, 'action', case when v_how = 'payout' then 'deduct' else 'send' end), null);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'owner_one_off_charge', 'vehicles', v.id::text, jsonb_build_object('invoice', r, 'collect_by', v_how));
  return r;
end $$;

-- the invoice screen shows how it is paid
alter function app.owner_invoice_admin(uuid, jsonb) rename to owner_invoice_admin_pre0238;
create function app.owner_invoice_admin(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := app.owner_invoice_admin_pre0238(p_by, p);
begin
  if v is null or not (v ? 'id') then return v; end if;
  return v || (select jsonb_build_object('collect_by', i.collect_by, 'deducted_cents', i.deducted_cents) from owner_invoices i where i.id = (v ->> 'id')::uuid);
end $$;
select pg_temp.copy_grants('app.owner_invoice_admin(uuid, jsonb)'::regprocedure, 'app.owner_invoice_admin_pre0238(uuid, jsonb)'::regprocedure);

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0238;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_do' and p_name in ('owner_invoice_collect_by', 'owner_one_off_charge') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'owner_invoice_collect_by' then app.owner_invoice_collect_by(p_user, coalesce(p, '{}'::jsonb))
                       else app.owner_one_off_charge(p_user, coalesce(p, '{}'::jsonb)) end;
  end if;
  return app.door_pre0238(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0238(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('owner_debit_block_pre0238', 'owner_invoice_collect_by', 'owner_one_off_charge', 'door_pre0238', 'owner_invoice_admin_pre0238') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
