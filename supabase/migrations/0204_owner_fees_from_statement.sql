-- 0204: owner fees taken from the revenue statement (Release 21, item 5). SCHEMA_MARKER 0204.
-- docs/changes/2026-10-31-owner-fees-from-statement.md.
--   Per owner, "How fees are paid": Bank debit (the default, as before) or Take from revenue statement. An owner on the
--   statement has their invoices (monthly, adjustment, tracker install, custom; never the upfront invoice, due before the
--   first rental) marked "from statement": no automatic debit; the next owner statement takes each one from the payout
--   ("Invoice INV-1050, paid from statement"), as far as the payout goes. Approved, the invoice is Paid from statement
--   (deducted), or part paid, the rest carried to the next statement. An invoice still owing 2 months after its billing
--   date falls back to the bank debit (with the usual notice) and Admin gets a task.
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

-- ================================================================ 1. the setting and the mark
alter table owners add column if not exists fees_paid_from text not null default 'debit' check (fees_paid_from in ('debit', 'statement'));
alter table owners add column if not exists fees_paid_from_set_at timestamptz;
alter table owners add column if not exists fees_paid_from_set_by uuid references users (id);
comment on column owners.fees_paid_from is 'How the owner''s fees are paid (0204): debit (pre-authorized debit, the default) or statement (taken from the revenue statement).';
alter table owner_invoices add column if not exists from_statement boolean not null default false;
alter table owner_invoices add column if not exists from_statement_fallback_at timestamptz;
comment on column owner_invoices.from_statement is 'Taken from the owner''s revenue statement instead of the debit (0204).';

insert into status_transitions (entity, from_status, to_status)
select 'owner_invoice', x.f, x.t from (values ('issued', 'deducted'), ('issued', 'partially_deducted'), ('partially_deducted', 'issued')) x(f, t)
 where not exists (select 1 from status_transitions s where s.entity = 'owner_invoice' and s.from_status = x.f and s.to_status = x.t);

insert into task_rules (task_type, queue, title, priority, description)
values ('owner_fees_statement_fallback', 'admin', 'Owner fees back to the bank debit', 'normal',
        'An invoice of an owner whose fees are taken from the revenue statement was still owing 2 months after its billing date: it goes back to the pre-authorized debit (0204).')
on conflict (task_type) do nothing;

create function app.owner_invoice_from_statement_mark() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'issued' and new.kind in ('monthly', 'adjustment', 'tracker_install', 'custom') and new.from_statement_fallback_at is null
     and (tg_op = 'INSERT' or old.status = 'draft')
     and exists (select 1 from owners o where o.id = new.owner_id and o.fees_paid_from = 'statement') then
    new.from_statement := true;
  end if;
  return new;
end $$;
create trigger owner_invoices_from_statement before insert or update of status on owner_invoices
  for each row execute function app.owner_invoice_from_statement_mark();

-- p: owner, fees_paid_from (debit | statement); an Admin. Invoices still due follow the choice.
create function app.owner_fees_paid_from_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  v_to text := p ->> 'fees_paid_from';
  v_n integer := 0;
begin
  perform app.assert_admin(p_by);
  select * into o from owners where id::text = p ->> 'owner' for update;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  if v_to not in ('debit', 'statement') then raise exception 'Choose Bank debit or Take from revenue statement' using errcode = '22023'; end if;
  if o.kind <> 'program' then raise exception 'Only a program owner pays fees' using errcode = '23514'; end if;
  update owners set fees_paid_from = v_to, fees_paid_from_set_at = now(), fees_paid_from_set_by = p_by where id = o.id;
  update owner_invoices i set from_statement = (v_to = 'statement'), from_statement_fallback_at = case when v_to = 'statement' then null else i.from_statement_fallback_at end
   where i.owner_id = o.id and i.status in ('issued', 'partially_deducted') and i.balance_cents > 0
     and i.kind in ('monthly', 'adjustment', 'tracker_install', 'custom') and i.from_statement is distinct from (v_to = 'statement')
     and not exists (select 1 from payments x where x.owner_invoice_id = i.id and x.status = 'pending');
  get diagnostics v_n = row_count;
  -- an invoice part taken from a statement and switched back to the debit is debited for the rest
  update owner_invoices set status = 'issued', debit_on = greatest(coalesce(debit_on, app.today()), app.today() + (app.settings()).owner_debit_notice_days)
   where owner_id = o.id and v_to = 'debit' and status = 'partially_deducted' and balance_cents > 0 and not from_statement;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'owner_fees_paid_from', 'owners', o.id::text, jsonb_build_object('fees_paid_from', o.fees_paid_from), jsonb_build_object('fees_paid_from', v_to, 'invoices', v_n));
  return jsonb_build_object('ok', true, 'fees_paid_from', v_to, 'invoices', v_n);
end $$;

create function app.owner_fees_paid_from(p_by uuid, p jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('fees_paid_from', o.fees_paid_from, 'set_at', o.fees_paid_from_set_at,
           'open_from_statement', (select count(*) from owner_invoices i where i.owner_id = o.id and i.from_statement and i.balance_cents > 0 and i.status in ('issued', 'partially_deducted')))
    from owners o where o.id::text = p ->> 'owner' and (app.user_is_admin(p_by) or app.user_is_staff(p_by))
$$;

-- ================================================================ 2. no debit
alter function app.owner_debit_block(uuid) rename to owner_debit_block_pre0204;
create function app.owner_debit_block(p_invoice uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when (select i.from_statement from owner_invoices i where i.id = p_invoice) then 'taken from the revenue statement'
              else app.owner_debit_block_pre0204(p_invoice) end
$$;
select pg_temp.copy_grants('app.owner_debit_block(uuid)'::regprocedure, 'app.owner_debit_block_pre0204(uuid)'::regprocedure);

-- ================================================================ 3. the statement takes them
-- After the statement is built (every rule before this one), each invoice from the statement still due (billed by the end
-- of the month) is taken from the payout: from its own car's amount first, then from the owner's other cars, never more
-- than the payout. Approving the statement records it on the invoice (approve_owner_statement: fees_deducted lines).
create function app.owner_statement_take_fees(p_statement uuid) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  st owner_statements;
  inv record;
  sv record;
  v_month_end date;
  v_room bigint;
  v_need bigint;
  v_take bigint;
  v_fee bigint;
  v_total bigint := 0;
begin
  select * into st from owner_statements where id = p_statement for update;
  if st.id is null then return 0; end if;
  v_month_end := (date_trunc('month', st.statement_month) + interval '1 month - 1 day')::date;
  v_room := greatest(st.payout_cents, 0);
  for inv in select i.* from owner_invoices i
              where i.owner_id = st.owner_id and i.from_statement and i.status = 'issued' and i.balance_cents > 0 and i.billing_date <= v_month_end
                and not exists (select 1 from owner_statement_lines l where l.owner_statement_id = st.id and l.owner_invoice_id = i.id)
              order by i.billing_date, i.invoice_number
  loop
    v_need := inv.balance_cents;
    for sv in select x.vehicle_id, x.payable_cents - coalesce((select sum(-l.amount_cents) from owner_statement_lines l
                       where l.owner_statement_id = st.id and l.vehicle_id = x.vehicle_id and l.line_type = 'arrears_moved'), 0) as free
                from owner_statement_vehicles x where x.owner_statement_id = st.id
               order by (x.vehicle_id = inv.vehicle_id) desc, x.payable_cents desc
    loop
      exit when v_need <= 0 or v_room <= 0;
      v_take := least(v_need, greatest(sv.free, 0), v_room);
      continue when v_take <= 0;
      v_fee := least(v_take, greatest(inv.fees_cents + inv.hst_cents - inv.paid_cents - inv.deducted_cents - (inv.balance_cents - v_need), 0));
      insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_invoice_id, fee_cents, late_fee_cents, amount_cents)
      values (st.id, sv.vehicle_id, 'fees_deducted', 'Invoice ' || inv.invoice_number || ', paid from statement', inv.id, v_fee, v_take - v_fee, -v_take);
      update owner_statement_vehicles set fees_deducted_cents = fees_deducted_cents + v_fee, late_fees_deducted_cents = late_fees_deducted_cents + (v_take - v_fee),
             payable_cents = payable_cents - v_take
       where owner_statement_id = st.id and vehicle_id = sv.vehicle_id;
      v_need := v_need - v_take; v_room := v_room - v_take; v_total := v_total + v_take;
    end loop;
  end loop;
  if v_total > 0 then
    update owner_statements
       set deductions_cents = deductions_cents + v_total, vehicles_payable_cents = vehicles_payable_cents - v_total,
           payout_cents = greatest(payout_cents + balance_carried_forward_cents - v_total, 0),
           balance_carried_forward_cents = least(payout_cents + balance_carried_forward_cents - v_total, 0)
     where id = st.id;
  end if;
  return v_total;
end $$;

alter function app.build_owner_statement(uuid, date, uuid) rename to build_owner_statement_pre0204;
create function app.build_owner_statement(p_owner uuid, p_month date, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  perform app.owner_fees_statement_fallback(p_owner);
  v_id := app.build_owner_statement_pre0204(p_owner, p_month, p_by);
  if v_id is not null and exists (select 1 from owner_invoices i where i.owner_id = p_owner and i.from_statement and i.status = 'issued' and i.balance_cents > 0) then
    perform app.owner_statement_take_fees(v_id);
  end if;
  return v_id;
end $$;
select pg_temp.copy_grants('app.build_owner_statement(uuid, date, uuid)'::regprocedure, 'app.build_owner_statement_pre0204(uuid, date, uuid)'::regprocedure);

-- ================================================================ 4. after 2 months: back to the debit
create function app.owner_fees_statement_fallback(p_owner uuid default null) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  inv record;
  v_n integer := 0;
begin
  for inv in select i.* from owner_invoices i
              where i.from_statement and i.balance_cents > 0 and i.status in ('issued', 'partially_deducted')
                and i.billing_date <= (app.today() - interval '2 months')::date and (p_owner is null or i.owner_id = p_owner)
              for update
  loop
    update owner_invoices
       set from_statement = false, from_statement_fallback_at = now(),
           status = case when status = 'partially_deducted' then 'issued' else status end,
           debit_on = greatest(coalesce(debit_on, app.today()), app.today() + (app.settings()).owner_debit_notice_days)
     where id = inv.id;
    perform app.raise_task(p_type => 'owner_fees_statement_fallback',
      p_title => format('Invoice %s back to the bank debit', inv.invoice_number),
      p_detail => format('%s still owed 2 months after the billing date: the revenue statements did not cover it. It is debited after the usual notice. Check the owner''s debit agreement, or record a payment.', app.fmt_money(inv.balance_cents)),
      p_owner => inv.owner_id, p_vehicle => inv.vehicle_id, p_related_table => 'owner_invoices', p_related_id => inv.id,
      p_dedupe => 'owner_fees_statement_fallback:' || inv.id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
-- every day as well, with the owner debit notices (a statement may not be built for a month with nothing in it)
alter function app.job_owner_debit_notices(timestamptz) rename to job_owner_debit_notices_pre0204;
create function app.job_owner_debit_notices(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_fallback integer := app.owner_fees_statement_fallback(null);
begin
  return concat_ws('; ', app.job_owner_debit_notices_pre0204(p_now), case when v_fallback > 0 then v_fallback || ' invoice(s) back to the bank debit' end);
end $$;
select pg_temp.copy_grants('app.job_owner_debit_notices(timestamptz)'::regprocedure, 'app.job_owner_debit_notices_pre0204(timestamptz)'::regprocedure);

-- ================================================================ 5. the owner portal says so
alter function app.owner_portal_home(uuid) rename to owner_portal_home_pre0204;
create function app.owner_portal_home(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.owner_portal_home_pre0204(p_by);
begin
  if v is null or jsonb_typeof(v -> 'invoices') <> 'array' then return v; end if;
  return jsonb_set(v, '{invoices}', coalesce((select jsonb_agg(x || jsonb_build_object('from_statement', coalesce(i.from_statement, false)) order by n)
                                               from jsonb_array_elements(v -> 'invoices') with ordinality t(x, n) left join owner_invoices i on i.id::text = x ->> 'id'), '[]'::jsonb))
         || jsonb_build_object('fees_paid_from', (select o.fees_paid_from from owners o where o.id::text = v #>> '{owner,id}'));
end $$;
select pg_temp.copy_grants('app.owner_portal_home(uuid)'::regprocedure, 'app.owner_portal_home_pre0204(uuid)'::regprocedure);
alter function app.owner_portal_invoice(uuid, text) rename to owner_portal_invoice_pre0204;
create function app.owner_portal_invoice(p_by uuid, p_number text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.owner_portal_invoice_pre0204(p_by, p_number);
begin
  if v is null then return v; end if;
  return v || jsonb_build_object('from_statement', coalesce((select i.from_statement from owner_invoices i where i.invoice_number = p_number), false));
end $$;
select pg_temp.copy_grants('app.owner_portal_invoice(uuid, text)'::regprocedure, 'app.owner_portal_invoice_pre0204(uuid, text)'::regprocedure);

-- the invoice rows of Admin's lists and invoice page
alter function app.oi_row(owner_invoices) rename to oi_row_pre0204;
create function app.oi_row(i owner_invoices) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.oi_row_pre0204(i) || jsonb_build_object('from_statement', i.from_statement)
$$;
select pg_temp.copy_grants('app.oi_row(owner_invoices)'::regprocedure, 'app.oi_row_pre0204(owner_invoices)'::regprocedure);

-- ================================================================ 6. the door, privileges
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0204;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call = 'ops_do' and p_name = 'owner_fees_paid_from') or (p_call = 'ops_read' and p_name = 'owner_fees_paid_from') then
    perform app.door_begin(p_user, p_aal);
    return case when p_call = 'ops_do' then app.owner_fees_paid_from_set(p_user, coalesce(p, '{}'::jsonb) - '_va')
                else app.owner_fees_paid_from(p_user, coalesce(p, '{}'::jsonb) - '_va') end;
  end if;
  return app.door_pre0204(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0204(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['owner_invoice_from_statement_mark', 'owner_fees_paid_from_set', 'owner_fees_paid_from', 'owner_debit_block_pre0204',
             'owner_statement_take_fees', 'build_owner_statement_pre0204', 'owner_fees_statement_fallback', 'job_owner_debit_notices_pre0204',
             'owner_portal_home_pre0204', 'owner_portal_invoice_pre0204', 'oi_row_pre0204', 'door_pre0204'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
