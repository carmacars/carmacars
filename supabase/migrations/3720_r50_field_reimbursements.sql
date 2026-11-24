-- 3720 (release 50; docs/changes/2026-11-24-r50-field-reimbursements.md): field expenses say whose money it was.
--   1. When field staff add money they spent (Add > Money spent, or a service with a cost), they must choose "My own money
--      (pay me back)" or "Company card/cash": nothing is assumed any more (field_spends.paid_with had a default of own).
--   2. Own money makes a reimbursement owed to that person (staff_reimbursements): pending while Finance checks it, owed
--      once approved, declined with the reason, paid once Finance marks it paid back. It follows the expense itself (a
--      trigger on field_spends), so the existing approve, refuse and paid-back steps keep working unchanged.
--   3. Finance and the Admins approve or decline (with the reason, 3 characters or more, as before). It shows on the
--      person's My shifts ("Owed to you") and on the payroll's payout list (Reimbursements owed), per person.
--   4. Notices (email, in-app and push): staff_expense_submitted to Finance and the Admins when it is added;
--      staff_expense_approved or staff_expense_declined to the person on the decision.
--   5. The connector: add_expense takes paid_with (company | own) and, for own, the staff member to pay back (an Admin's
--      expense is approved by entering it: it is owed at once); list_expenses returns paid_with and the reimbursement, and
--      filters by paid_with.
-- Security definer functions run with search_path public, app, pg_temp; the server role alone executes them. The table is
-- read by Finance and the Admins, and by each person for their own rows, through row-level security; no one writes it but
-- these functions. SCHEMA_MARKER 3720. No applied migration is edited.
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
  if position(p_old in d) = 0 then raise exception '3720: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. whose money: always chosen
alter table field_spends alter column paid_with drop default;

select pg_temp.patch_fn('app.fx_spend_add(uuid, jsonb)'::regprocedure,
  $o$  if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount' using errcode = '22023'; end if;$o$,
  $n$  if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount' using errcode = '22023'; end if;
  if coalesce(p ->> 'paid_with', '') not in ('own', 'company') then
    raise exception 'Choose whose money it was: My own money (pay me back) or Company card/cash' using errcode = '22023';
  end if;$n$);
select pg_temp.patch_fn('app.fx_spend_add(uuid, jsonb)'::regprocedure,
  $o$case when p ->> 'paid_with' = 'company' then 'company' else 'own' end,$o$,
  $n$p ->> 'paid_with',$n$);
select pg_temp.patch_fn('app.fx_service_add(uuid, jsonb)'::regprocedure,
  $o$  if v_cost < 0 or v_cost > 2000000 then raise exception 'Check the cost' using errcode = '22023'; end if;$o$,
  $n$  if v_cost < 0 or v_cost > 2000000 then raise exception 'Check the cost' using errcode = '22023'; end if;
  if v_cost > 0 and coalesce(p ->> 'paid_with', '') not in ('own', 'company') then
    raise exception 'Choose whose money paid for it: My own money (pay me back) or Company card/cash' using errcode = '22023';
  end if;$n$);

-- ================================================================ 2. the reimbursement owed
create table if not exists staff_reimbursements (
  id                 uuid primary key default gen_random_uuid(),
  staff_id           uuid not null references users (id),
  field_spend_id     uuid unique references field_spends (id),
  company_expense_id uuid references company_expenses (id),
  amount_cents       bigint not null check (amount_cents > 0),
  description        text not null check (length(description) between 2 and 500),
  status             text not null default 'pending' check (status in ('pending', 'owed', 'declined', 'paid')),
  decided_by         uuid references users (id),
  decided_at         timestamptz,
  decline_reason     text check (decline_reason is null or length(decline_reason) between 3 and 300),
  paid_by            uuid references users (id),
  paid_at            timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (field_spend_id is not null or company_expense_id is not null),
  check (status <> 'declined' or decline_reason is not null),
  check ((status = 'paid') = (paid_at is not null))
);
create index if not exists staff_reimbursements_staff_idx on staff_reimbursements (staff_id, created_at desc);
create index if not exists staff_reimbursements_open_idx on staff_reimbursements (status) where status in ('pending', 'owed');
create index if not exists staff_reimbursements_expense_idx on staff_reimbursements (company_expense_id) where company_expense_id is not null;
create index if not exists staff_reimbursements_decided_by_idx on staff_reimbursements (decided_by) where decided_by is not null;
create index if not exists staff_reimbursements_paid_by_idx on staff_reimbursements (paid_by) where paid_by is not null;
comment on table staff_reimbursements is 'r50 (3720): money a staff member spent for the company with their own money, owed back to them: pending (Finance checks it), owed (approved), declined (with the reason) or paid. Follows field_spends; an Admin''s own-money expense (add_expense paid_with own) is owed at once.';
create trigger staff_reimbursements_updated before update on staff_reimbursements for each row execute function app.set_updated_at();
create trigger audit_staff_reimbursements after insert or update or delete on staff_reimbursements for each row execute function app.audit_row();
alter table staff_reimbursements enable row level security;
create policy finance_read on staff_reimbursements for select to authenticated using (app.is_admin() or app.va_has('finance'));
create policy own_read on staff_reimbursements for select to authenticated using (staff_id = app.uid());
revoke all on staff_reimbursements from public, anon, authenticated;
grant select on staff_reimbursements to authenticated;
grant all on staff_reimbursements to service_role;

alter table company_expenses add column if not exists paid_with text not null default 'company' check (paid_with in ('company', 'own'));
comment on column company_expenses.paid_with is 'r50 (3720): who paid: the company (card or cash), or a staff member''s own money (owed back to staff_user_id: staff_reimbursements).';

create or replace function app.spend_paid_with_words(p text, p_you boolean default false) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select case p when 'own' then case when p_you then 'Your own money' else 'Their own money (pay them back)' end else 'Company card or cash' end
$$;

-- the notice values of one expense
create or replace function app.spend_notice(x field_spends, p_by uuid default null) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('spend_id', x.id, 'staff_id', x.staff_id, 'vehicle_id', x.vehicle_id,
    'staff_name', coalesce((select u.full_name from users u where u.id = x.staff_id), 'Field staff'),
    'expense_amount', app.fmt_money(x.amount_cents + x.hst_cents), 'expense_description', x.description,
    'expense_vehicle', coalesce(app.vehicle_name(x.vehicle_id), 'None'), 'expense_receipt', case when x.receipt_document_id is null then 'Not yet: they have a To do to add it' else 'Attached' end,
    'expense_ref', 'FS-' || upper(left(replace(x.id::text, '-', ''), 6)),
    'decided_by_name', coalesce((select u.full_name from users u where u.id = p_by), 'Finance'),
    'decline_reason', coalesce(x.decision_note, ''))
$$;

-- the expense's money and decisions, followed: the reimbursement and the notices
create or replace function app.field_spends_reimburse() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v jsonb := app.spend_notice(new, new.decided_by);
  v_name text := v ->> 'staff_name';
begin
  if tg_op = 'INSERT' then
    if new.paid_with = 'own' then
      insert into staff_reimbursements (staff_id, field_spend_id, amount_cents, description)
      values (new.staff_id, new.id, new.amount_cents + new.hst_cents, left(new.description, 500)) on conflict (field_spend_id) do nothing;
    end if;
    perform app.ntf_emit('staff_expense_submitted', 'field_spend', new.id, 'submitted',
      v || jsonb_build_object('expense_paid_with', app.spend_paid_with_words(new.paid_with),
        'expense_reimburse_note', case when new.paid_with = 'own' then format('Approving it adds it to what CarmaCars owes %s.', v_name)
                                       else 'Paid with the company card or cash: nothing is owed to anyone.' end));
    return null;
  end if;
  if new.status is distinct from old.status then
    if new.status = 'approved' then
      update staff_reimbursements set status = 'owed', decided_by = new.decided_by, decided_at = coalesce(new.decided_at, now()), company_expense_id = new.company_expense_id
       where field_spend_id = new.id and status = 'pending';
      perform app.ntf_emit('staff_expense_approved', 'field_spend', new.id, 'approved',
        v || jsonb_build_object('expense_paid_with', app.spend_paid_with_words(new.paid_with, true),
          'expense_reimburse_note', case when new.paid_with = 'own' then 'It is added to what CarmaCars owes you, and paid back with your pay.'
                                         else 'It was paid with the company card or cash, so nothing is owed to you.' end));
    elsif new.status = 'refused' then
      update staff_reimbursements set status = 'declined', decided_by = new.decided_by, decided_at = coalesce(new.decided_at, now()),
             decline_reason = left(coalesce(nullif(btrim(new.decision_note), ''), 'Declined by Finance'), 300)
       where field_spend_id = new.id and status in ('pending', 'owed');
      perform app.ntf_emit('staff_expense_declined', 'field_spend', new.id, 'declined',
        v || jsonb_build_object('expense_paid_with', app.spend_paid_with_words(new.paid_with, true)));
    elsif new.status = 'reimbursed' then
      update staff_reimbursements set status = 'paid', paid_by = new.reimbursed_by, paid_at = coalesce(new.reimbursed_at, now())
       where field_spend_id = new.id and status = 'owed';
    end if;
  end if;
  return null;
end $$;
drop trigger if exists field_spends_reimburse on field_spends;
create trigger field_spends_reimburse after insert or update of status on field_spends for each row execute function app.field_spends_reimburse();

-- the expenses already waiting with own money: their reimbursement, as it stands
insert into staff_reimbursements (staff_id, field_spend_id, company_expense_id, amount_cents, description, status, decided_by, decided_at, decline_reason, paid_by, paid_at)
select s.staff_id, s.id, s.company_expense_id, s.amount_cents + s.hst_cents, left(s.description, 500),
       case s.status when 'submitted' then 'pending' when 'approved' then 'owed' when 'refused' then 'declined' else 'paid' end,
       s.decided_by, s.decided_at, case when s.status = 'refused' then left(case when length(btrim(coalesce(s.decision_note, ''))) >= 3 then btrim(s.decision_note) else 'Declined by Finance' end, 300) end,
       s.reimbursed_by, s.reimbursed_at
  from field_spends s
 where s.paid_with = 'own'
on conflict (field_spend_id) do nothing;

-- ================================================================ 3. the views: the person's own, and Finance's payout list
-- p: staff (Finance or an Admin: one person's), or nothing (the caller's own; Finance: everyone's open, by person)
create or replace function app.reimbursements_view(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_fin boolean := app.user_runs_finance(p_by);
  v_staff uuid := coalesce(nullif(p ->> 'staff', '')::uuid, case when coalesce(p ->> 'mine', '') = 'true' or not app.user_runs_finance(p_by) then p_by end);
begin
  if v_staff is not null and v_staff <> p_by and not v_fin then raise exception 'Only Finance or an Admin sees what is owed to someone else' using errcode = '42501'; end if;
  if v_staff is not null then
    return jsonb_build_object('staff_id', v_staff,
      'owed_cents', coalesce((select sum(r.amount_cents) from staff_reimbursements r where r.staff_id = v_staff and r.status = 'owed'), 0),
      'pending_cents', coalesce((select sum(r.amount_cents) from staff_reimbursements r where r.staff_id = v_staff and r.status = 'pending'), 0),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'description', r.description, 'amount_cents', r.amount_cents, 'status', r.status,
                 'decline_reason', r.decline_reason, 'spent_on', s.spent_on, 'created_at', r.created_at, 'paid_at', r.paid_at) order by r.created_at desc)
          from (select * from staff_reimbursements x where x.staff_id = v_staff order by x.created_at desc limit 50) r left join field_spends s on s.id = r.field_spend_id), '[]'::jsonb));
  end if;
  return jsonb_build_object(
    'owed_cents', coalesce((select sum(r.amount_cents) from staff_reimbursements r where r.status = 'owed'), 0),
    'people', coalesce((select jsonb_agg(x order by x ->> 'name') from (
        select jsonb_build_object('staff_id', r.staff_id, 'name', coalesce(u.full_name, u.email),
          'owed_cents', sum(r.amount_cents) filter (where r.status = 'owed'), 'pending_cents', coalesce(sum(r.amount_cents) filter (where r.status = 'pending'), 0),
          'items', jsonb_agg(jsonb_build_object('id', r.id, 'spend_id', r.field_spend_id, 'description', r.description, 'amount_cents', r.amount_cents, 'status', r.status) order by r.created_at)) x
          from staff_reimbursements r join users u on u.id = r.staff_id
         where r.status in ('owed', 'pending')
         group by r.staff_id, u.full_name, u.email) q), '[]'::jsonb));
end $$;

-- an Admin's own-money expense entered elsewhere (the connector's add_expense) is paid back here
create or replace function app.reimbursement_paid(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare r staff_reimbursements;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Only Finance or an Admin pays back' using errcode = '42501'; end if;
  select * into r from staff_reimbursements where id = nullif(p ->> 'id', '')::uuid for update;
  if r.id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  if r.status <> 'owed' then raise exception 'Only an approved reimbursement is paid back (this one is %)', r.status using errcode = '23514'; end if;
  if r.field_spend_id is not null then return app.fx_spend_paid_back(p_by, jsonb_build_object('id', r.field_spend_id, 'note', p ->> 'note')); end if;
  update staff_reimbursements set status = 'paid', paid_by = p_by, paid_at = now() where id = r.id;
  return jsonb_build_object('id', r.id, 'status', 'paid');
end $$;

-- ================================================================ 4. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3720;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call = 'field_read' and p_name = 'my_reimbursements') or (p_call = 'ops_read' and p_name = 'reimbursements') or (p_call = 'ops_do' and p_name = 'reimbursement_paid') then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    p_ := p_ - '_va';
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'my_reimbursements' then app.reimbursements_view(p_user, jsonb_build_object('mine', 'true'))
      when 'reimbursements' then app.reimbursements_view(p_user, p_)
      else app.reimbursement_paid(p_user, p_) end;
  end if;
  return app.door_pre3720(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3720(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 5. the connector: add_expense and list_expenses
create or replace function app.api_expense_add(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_id uuid;
  v_paid text := coalesce(nullif(p ->> 'paid_with', ''), 'company');
  v_staff uuid;
  v_total bigint;
  v_r uuid;
begin
  perform app.assert_admin(p_by);
  if not exists (select 1 from company_expense_categories c where c.code = p ->> 'category' and c.is_active) then
    raise exception 'Unknown expense category: %', coalesce(p ->> 'category', '(none)') using errcode = '22023';
  end if;
  if coalesce((p ->> 'amount_cents')::bigint, 0) <= 0 then raise exception 'The amount, in cents, above zero' using errcode = '22023'; end if;
  if length(btrim(coalesce(p ->> 'description', ''))) < 3 then raise exception 'Describe the expense' using errcode = '22023'; end if;
  if v_paid not in ('company', 'own') then raise exception 'paid_with: company (the company card or cash) or own (a staff member''s own money, paid back)' using errcode = '22023'; end if;
  if v_paid = 'own' then
    select u.id into v_staff from users u
     where (u.id::text = coalesce(p ->> 'staff', '') or lower(u.email) = lower(btrim(coalesce(p ->> 'staff', ''))))
       and exists (select 1 from user_roles r where r.user_id = u.id and r.role in ('va', 'field', 'admin'));
    if v_staff is null then raise exception 'staff: the staff member who paid with their own money (their id or email), to pay them back' using errcode = '22023'; end if;
  end if;
  insert into company_expenses (expense_on, category, description, amount_cents, hst_cents, vehicle_id, staff_user_id, paid_with, created_by)
  values (coalesce(nullif(p ->> 'expense_on', '')::date, app.today()), p ->> 'category', left(btrim(p ->> 'description'), 500), (p ->> 'amount_cents')::bigint,
          coalesce(nullif(p ->> 'hst_cents', '')::bigint, 0), nullif(p ->> 'vehicle_id', '')::uuid, v_staff, v_paid, p_by)
  returning id, amount_cents + hst_cents into v_id, v_total;
  if v_paid = 'own' then
    -- entered by an Admin: approved by entering it, so it is owed at once
    insert into staff_reimbursements (staff_id, company_expense_id, amount_cents, description, status, decided_by, decided_at)
    values (v_staff, v_id, v_total, left(btrim(p ->> 'description'), 500), 'owed', p_by, now()) returning id into v_r;
  end if;
  return jsonb_build_object('id', v_id, 'admin_path', '/admin/expenses', 'paid_with', v_paid, 'reimbursement_id', v_r,
    'owed_to', case when v_staff is not null then (select u.full_name from users u where u.id = v_staff) end);
end $$;

select pg_temp.patch_fn('app.api_row(text, uuid)'::regprocedure,
  $o$when 'list_expenses' then (select to_jsonb(e) || jsonb_build_object('car', case when e.vehicle_id is not null then app.vehicle_name(e.vehicle_id) end) from company_expenses e where e.id = p_id)$o$,
  $n$when 'list_expenses' then (select to_jsonb(e) || jsonb_build_object('car', case when e.vehicle_id is not null then app.vehicle_name(e.vehicle_id) end,
      'paid_with', e.paid_with, 'staff', (select u.full_name from users u where u.id = e.staff_user_id),
      'reimbursement', (select jsonb_build_object('id', r.id, 'status', r.status, 'amount_cents', r.amount_cents, 'decline_reason', r.decline_reason, 'paid_at', r.paid_at)
                          from staff_reimbursements r left join field_spends s on s.id = r.field_spend_id
                         where r.company_expense_id = e.id or s.company_expense_id = e.id order by r.created_at desc limit 1)) from company_expenses e where e.id = p_id)$n$);
select pg_temp.patch_fn('app.api_src(text, jsonb)'::regprocedure,
  $o$and (nullif(a ->> 'category', '') is null or e.category = a ->> 'category');$o$,
  $n$and (nullif(a ->> 'category', '') is null or e.category = a ->> 'category')
       and (nullif(a ->> 'paid_with', '') is null or e.paid_with = a ->> 'paid_with');$n$);

-- an expense a field person paid with their own money: its company expense says so once approved
update company_expenses e set paid_with = 'own' from field_spends s where s.company_expense_id = e.id and s.paid_with = 'own' and e.paid_with <> 'own';
select pg_temp.patch_fn('app.fx_spend_decide(uuid, jsonb)'::regprocedure,
  $o$insert into company_expenses (expense_on, category, description, amount_cents, hst_cents, vehicle_id, owner_id, staff_user_id, document_id, created_by)$o$,
  $n$insert into company_expenses (expense_on, category, description, amount_cents, hst_cents, vehicle_id, owner_id, staff_user_id, document_id, created_by, paid_with)$n$);
select pg_temp.patch_fn('app.fx_spend_decide(uuid, jsonb)'::regprocedure,
  $o$(select v.owner_id from vehicles v where v.id = x.vehicle_id), x.staff_id, x.receipt_document_id, p_by)$o$,
  $n$(select v.owner_id from vehicles v where v.id = x.vehicle_id), x.staff_id, x.receipt_document_id, p_by, x.paid_with)$n$);

-- ================================================================ 6. the notices (email, in-app and push)
-- CATALOGUE 3720 START (generated by supabase/seed/3720_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('staff_expense_submitted', 'staff_va_finance', array['staff_admin']::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'Approve {{expense_amount}} spent by {{staff_name}}: {{expense_paid_with}}', '{{expense_description}}. {{expense_reimburse_note}}', 'Immediate', 'Release 50 (3720): a field staff member adds money they spent for the company (gas, a wash, parts, parking, a service) with the receipt, and says whose money it was: their own (pay me back) or the company card or cash. Immediate, once per expense, to Finance and the Admins.', null, '/staff/field-spending', '[{"name":"company_address","type":"string","global":true},{"name":"expense_amount","type":"string"},{"name":"expense_description","type":"string"},{"name":"expense_paid_with","type":"string"},{"name":"expense_receipt","type":"string"},{"name":"expense_ref","type":"string"},{"name":"expense_reimburse_note","type":"string"},{"name":"expense_vehicle","type":"string"},{"name":"staff_name","type":"string"}]'::jsonb, 'templates/staff_expense_submitted.html', 'templates/staff_expense_submitted.txt'),
  ('staff_expense_approved', 'staff_field', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'Expense approved: {{expense_amount}}', '{{expense_description}}. {{expense_reimburse_note}}', 'Immediate', 'Release 50 (3720): Finance or an Admin approved an expense a field staff member added. One email to that staff member, at their own address. Own money: it is now owed to them and shows on their pay as reimbursable until it is paid back.', null, '/staff/field/shifts', '[{"name":"company_address","type":"string","global":true},{"name":"decided_by_name","type":"string"},{"name":"expense_amount","type":"string"},{"name":"expense_description","type":"string"},{"name":"expense_paid_with","type":"string"},{"name":"expense_ref","type":"string"},{"name":"expense_reimburse_note","type":"string"},{"name":"first_name","type":"string"}]'::jsonb, 'templates/staff_expense_approved.html', 'templates/staff_expense_approved.txt'),
  ('staff_expense_declined', 'staff_field', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'Expense declined: {{expense_amount}}', '{{decided_by_name}}: {{decline_reason}}', 'Immediate', 'Release 50 (3720): Finance or an Admin declined an expense a field staff member added, with the reason. One email to that staff member, at their own address. Nothing is owed for it.', null, '/staff/field/shifts', '[{"name":"company_address","type":"string","global":true},{"name":"decided_by_name","type":"string"},{"name":"decline_reason","type":"string"},{"name":"expense_amount","type":"string"},{"name":"expense_description","type":"string"},{"name":"expense_paid_with","type":"string"},{"name":"expense_ref","type":"string"},{"name":"first_name","type":"string"}]'::jsonb, 'templates/staff_expense_declined.html', 'templates/staff_expense_declined.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 3720 END
update notification_catalogue set emitted_by = 'app.field_spends_reimburse (3720): a field expense is added' where code = 'staff_expense_submitted';
update notification_catalogue set emitted_by = 'app.field_spends_reimburse (3720): Finance approves a field expense' where code = 'staff_expense_approved';
update notification_catalogue set emitted_by = 'app.field_spends_reimburse (3720): Finance declines a field expense' where code = 'staff_expense_declined';
-- Finance acts on it during the day; the person hears the answer. Never a text.
update notification_catalogue set no_text = true, push_topic = 'alerts', hold_to_merge = false, priority = 2 where code = 'staff_expense_submitted';
update notification_catalogue set no_text = true, push_topic = 'bookings', hold_to_merge = false, priority = 2 where code in ('staff_expense_approved', 'staff_expense_declined');
insert into notification_link_paths (key, path) values ('va_finance_field_spending', '/staff/field-spending'), ('field_shifts', '/staff/field/shifts')
  on conflict (key) do update set path = excluded.path;

-- the person who spent it, at their own address (an active staff account only)
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre3720;
create function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  if p_c.code in ('staff_expense_approved', 'staff_expense_declined') then
    return query select 'staff_field'::text, u.id, u.email, u.full_name, null::uuid, null::uuid, true
                   from users u
                  where u.id = nullif(p_event.payload ->> 'staff_id', '')::uuid and u.status = 'active' and u.email is not null
                    and exists (select 1 from user_roles r where r.user_id = u.id and r.role in ('va', 'field', 'admin'));
    return;
  end if;
  return query select * from app.notification_recipients_pre3720(p_event, p_c);
end $$;
select pg_temp.copy_grants('app.notification_recipients(app_events, notification_catalogue)'::regprocedure,
                           'app.notification_recipients_pre3720(app_events, notification_catalogue)'::regprocedure);

-- ================================================================ 7. privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('spend_paid_with_words', 'spend_notice', 'field_spends_reimburse', 'reimbursements_view', 'reimbursement_paid',
              'door_pre3720', 'notification_recipients_pre3720', 'api_expense_add') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
