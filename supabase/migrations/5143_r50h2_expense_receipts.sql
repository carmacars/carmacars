-- 5143 (R50 hotfix 2, docs/changes/2026-11-27-r50-hotfix2-ops.md): log an expense from its receipt photos.
-- The owner (Nov 27): log an expense by taking or uploading receipt photos (several per expense); the photo is read for the
-- amount, the tax, the date, the vendor, the category and the car; it posts to the car and the owner's statement. Very easy,
-- phone first.
-- 1. expense_entries: one logged expense (its receipt read, what was kept, who logged it) and where it posted: a company
--    expense on the car (company_expenses, CarmaCars pays) or an owner deduction on the car (owner_deductions, kind
--    maintenance: on the owner's next statement). expense_entry_photos: its receipt photos, each a stored document
--    (documents, kind receipt; on the car and its owner when the owner pays, so the owner sees the receipt), in order.
-- 2. The photo is read in the browser by the vision model (purpose receipt_read, added to the vision gate and the AI usage
--    registry, counted in the vision model's daily allowance); what it read is kept with the entry, never trusted alone:
--    the person checks the fields before saving.
-- 3. app.expense_log (the door's ops_do expense_log, 5144): Admin, Finance or Fleet. The car's program owner pays by default
--    (the owner's statement); "CarmaCars pays" makes it a company expense on the car. A final company month refuses a new
--    expense (company_expense_guard), as before. The owner is told when a cost goes on their statement
--    (owner_car_cost_added, 5145). app.expense_context: the categories, the cars with their owner, the vision switch.
--    app.expense_entries_json: the last entries, with their photos.
-- No applied migration is edited. SCHEMA_MARKER 5143.
set local check_function_bodies = off;

create table expense_entries (
  id                 uuid primary key default gen_random_uuid(),
  expense_on         date not null,
  vendor             text check (vendor is null or length(vendor) <= 160),
  category           text not null references company_expense_categories(code),
  description        text not null check (length(description) between 2 and 500),
  amount_cents       bigint not null check (amount_cents > 0),
  hst_cents          bigint not null default 0 check (hst_cents >= 0),
  vehicle_id         uuid references vehicles(id),
  owner_id           uuid references owners(id),
  payer              text not null check (payer in ('company', 'owner')),
  paid_with          text not null default 'company' check (paid_with in ('company', 'own')),
  company_expense_id uuid references company_expenses(id),
  owner_deduction_id uuid references owner_deductions(id),
  read               jsonb not null default '{}'::jsonb,
  created_by         uuid references users(id),
  created_at         timestamptz not null default now(),
  check ((payer = 'company') = (company_expense_id is not null)),
  check ((payer = 'owner') = (owner_deduction_id is not null)),
  check (payer = 'company' or (vehicle_id is not null and owner_id is not null))
);
comment on table expense_entries is 'R50 hotfix 2 (5143): an expense logged from its receipt photos, and where it posted (a company expense on the car, or an owner deduction on the owner''s statement).';
create index expense_entries_vehicle_id_fk on expense_entries (vehicle_id);
create index expense_entries_owner_id_fk on expense_entries (owner_id);
create index expense_entries_category_fk on expense_entries (category);
create index expense_entries_company_expense_id_fk on expense_entries (company_expense_id);
create index expense_entries_owner_deduction_id_fk on expense_entries (owner_deduction_id);
create index expense_entries_created_idx on expense_entries (created_at desc);

create table expense_entry_photos (
  id          uuid primary key default gen_random_uuid(),
  entry_id    uuid not null references expense_entries(id) on delete cascade,
  document_id uuid not null references documents(id),
  sort        smallint not null check (sort between 1 and 20),
  unique (entry_id, sort)
);
comment on table expense_entry_photos is 'R50 hotfix 2 (5143): the receipt photos of a logged expense, in order.';
create index expense_entry_photos_document_id_fk on expense_entry_photos (document_id);

create trigger audit_expense_entries after insert or update or delete on expense_entries for each row execute function app.audit_row();
create trigger audit_expense_entry_photos after insert or update or delete on expense_entry_photos for each row execute function app.audit_row();
alter table expense_entries enable row level security;
alter table expense_entry_photos enable row level security;
create policy admin_all on expense_entries for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on expense_entry_photos for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on expense_entries, expense_entry_photos from public, anon, authenticated;
grant select on expense_entries, expense_entry_photos to authenticated;
grant all on expense_entries, expense_entry_photos to service_role;

-- ---------------------------------------------------------------- the vision model: receipts
alter function app.ai_purposes() rename to ai_purposes_pre5143;
create function app.ai_purposes() returns text[] language sql immutable set search_path = public, app, pg_temp as $$ select app.ai_purposes_pre5143() || array['receipt_read'] $$;
alter function app.ai_kind(text) rename to ai_kind_pre5143;
create function app.ai_kind(p_purpose text) returns text language sql immutable set search_path = public, app, pg_temp as $$
  select case when p_purpose = 'receipt_read' then 'vision' else app.ai_kind_pre5143(p_purpose) end $$;
alter function app.ai_private(text) rename to ai_private_pre5143;
create function app.ai_private(p_purpose text) returns boolean language sql immutable set search_path = public, app, pg_temp as $$
  select p_purpose = 'receipt_read' or app.ai_private_pre5143(p_purpose) $$;
alter function app.ai_tier(text) rename to ai_tier_pre5143;
create function app.ai_tier(p_purpose text) returns text language sql immutable set search_path = public, app, pg_temp as $$
  select case when p_purpose = 'receipt_read' then 'live' else app.ai_tier_pre5143(p_purpose) end $$;
alter function app.ai_feature_label(text) rename to ai_feature_label_pre5143;
create function app.ai_feature_label(p_purpose text) returns text language sql immutable set search_path = public, app, pg_temp as $$
  select case when p_purpose = 'receipt_read' then 'Receipt reading (expenses)' else app.ai_feature_label_pre5143(p_purpose) end $$;

alter function app.ai_vision_gate(uuid, text) rename to ai_vision_gate_pre5143;
create function app.ai_vision_gate(p_by uuid, p_purpose text) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  b jsonb;
  a jsonb;
begin
  if p_purpose is distinct from 'receipt_read' then return app.ai_vision_gate_pre5143(p_by, p_purpose); end if;
  if not app.expense_may_log(p_by) then raise exception 'An Admin, Finance or Fleet logs expenses' using errcode = '42501'; end if;
  b := app.ai_vision_budget();
  if not coalesce((b ->> 'enabled')::boolean, false) then
    return b || jsonb_build_object('allowed', false, 'reason', 'Reading with the vision model is off in Program settings: type the receipt''s details');
  end if;
  if (b ->> 'used')::bigint >= (b ->> 'limit')::bigint or (b ->> 'all_used')::bigint >= (b ->> 'all_limit')::bigint then
    return b || jsonb_build_object('allowed', false, 'reason', 'Today''s allowance for the vision model is used up: type the receipt''s details');
  end if;
  a := app.ai_allow(p_purpose, 300);
  if not (a ->> 'ok')::boolean then return b || jsonb_build_object('allowed', false, 'reason', a ->> 'message'); end if;
  return b || jsonb_build_object('allowed', true);
end $$;

alter function app.ai_call_record(uuid, jsonb) rename to ai_call_record_pre5143;
create function app.ai_call_record(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_id uuid;
begin
  if p ->> 'purpose' is distinct from 'receipt_read' then return app.ai_call_record_pre5143(p_by, p); end if;
  if not app.expense_may_log(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  insert into provider_calls (provider, purpose, vehicle_id, ok, error, duration_ms, cost_microusd, units, unit)
  values (left(coalesce(p ->> 'model', 'workers-ai'), 120), 'receipt_read', nullif(p ->> 'vehicle', '')::uuid, coalesce((p ->> 'ok')::boolean, false),
          left(p ->> 'error', 500), greatest(coalesce((p ->> 'duration_ms')::integer, 0), 0), 0, greatest(coalesce((p ->> 'neurons')::integer, 0), 0), 'neurons')
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'budget', app.ai_vision_budget());
end $$;

-- the vision allowance counts receipts with the notices and the plates
alter function app.ai_vision_budget(timestamptz) rename to ai_vision_budget_pre5143;
create function app.ai_vision_budget(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.ai_vision_budget_pre5143(p_now) || jsonb_build_object('used',
    (select coalesce(sum(c.units), 0) from provider_calls c
      where c.unit = 'neurons' and c.purpose in ('toll_read', 'plate_detect', 'receipt_read')
        and c.created_at >= app.local_midnight(app.local_date(p_now)) and c.created_at < app.local_midnight(app.local_date(p_now) + 1)))
$$;

-- ---------------------------------------------------------------- who, what, where
create function app.expense_may_log(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(app.user_is_admin(p_by), false) or app.user_va_has(p_by, 'finance', 'fleet')
$$;

create function app.expense_context(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  if not app.expense_may_log(p_by) then raise exception 'An Admin, Finance or Fleet logs expenses' using errcode = '42501'; end if;
  return jsonb_build_object(
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'label', c.label) order by c.label), '[]'::jsonb)
                     from company_expense_categories c where c.is_active and c.code not in ('staff_benefit', 'owner_reward', 'staff', 'software', 'marketing', 'processing_fees', 'fleet_insurance')),
    'cars', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'vin', v.vin, 'owner_id', v.owner_id,
                       'owner_name', (select coalesce(nullif(btrim(o.corporation_name), ''), o.legal_name) from owners o where o.id = v.owner_id),
                       'owner_pays', v.supply_type = 'program_owner' and v.owner_id is not null)
                     order by v.make, v.model, v.plate), '[]'::jsonb)
               from vehicles v where not coalesce(v.is_sample, false) and v.status::text not in ('archived', 'removed', 'sold')),
    'vision', (select ai_vision_enabled from app.settings()));
end $$;

create function app.expense_log(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v vehicles;
  v_on date := coalesce(nullif(p ->> 'expense_on', '')::date, app.today());
  v_cat text := nullif(btrim(coalesce(p ->> 'category', '')), '');
  v_vendor text := nullif(btrim(coalesce(p ->> 'vendor', '')), '');
  v_desc text := nullif(btrim(coalesce(p ->> 'description', '')), '');
  v_amount bigint;
  v_hst bigint;
  v_payer text := nullif(p ->> 'payer', '');
  v_paid text := coalesce(nullif(p ->> 'paid_with', ''), 'company');
  v_id uuid := gen_random_uuid();
  v_doc uuid;
  v_docs uuid[] := '{}';
  v_ce uuid;
  v_od uuid;
  x jsonb;
  n integer := 0;
begin
  if not app.expense_may_log(p_by) then raise exception 'An Admin, Finance or Fleet logs expenses' using errcode = '42501'; end if;
  begin
    v_amount := (p ->> 'amount_cents')::numeric::bigint; v_hst := coalesce(nullif(p ->> 'hst_cents', '')::numeric::bigint, 0);
  exception when others then raise exception 'Type the amount and the tax in dollars and cents' using errcode = '22023';
  end;
  if v_amount is null or v_amount <= 0 then raise exception 'Type the amount before tax' using errcode = '22023'; end if;
  if v_hst < 0 or v_hst > v_amount then raise exception 'The tax is more than the amount: check the receipt' using errcode = '22023'; end if;
  if v_on > app.today() then raise exception 'The receipt date is in the future' using errcode = '22023'; end if;
  if v_on < app.today() - 400 then raise exception 'The receipt is more than 400 days old: enter it on Expenses by hand' using errcode = '22023'; end if;
  if v_cat is null or not exists (select 1 from company_expense_categories c where c.code = v_cat and c.is_active) then
    raise exception 'Choose the category' using errcode = '22023';
  end if;
  if v_paid not in ('company', 'own') then raise exception 'Paid with the company''s money or your own' using errcode = '22023'; end if;
  if jsonb_typeof(p -> 'photos') is distinct from 'array' or jsonb_array_length(p -> 'photos') = 0 then
    raise exception 'Add at least one photo of the receipt' using errcode = '22023';
  end if;
  if jsonb_array_length(p -> 'photos') > 10 then raise exception 'At most 10 photos for one expense' using errcode = '22023'; end if;
  if nullif(p ->> 'vehicle_id', '') is not null then
    select * into v from vehicles where id = (p ->> 'vehicle_id')::uuid;
    if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  end if;
  v_payer := coalesce(v_payer, case when v.supply_type = 'program_owner' and v.owner_id is not null then 'owner' else 'company' end);
  if v_payer not in ('company', 'owner') then raise exception 'Who pays: CarmaCars or the car''s owner' using errcode = '22023'; end if;
  if v_payer = 'owner' and (v.id is null or v.owner_id is null or v.supply_type <> 'program_owner') then
    raise exception 'Only a car with a program owner puts a cost on an owner''s statement: choose the car, or CarmaCars pays' using errcode = '23514';
  end if;
  if v_payer = 'owner' and v_paid = 'own' then raise exception 'A cost on the owner''s statement is paid by CarmaCars first: choose paid with the company''s money' using errcode = '23514'; end if;
  v_desc := coalesce(v_desc, concat_ws(': ', (select c.label from company_expense_categories c where c.code = v_cat), v_vendor));

  -- the receipt photos: the server stored each under expenses/ and sends the key it built
  for x in select value from jsonb_array_elements(p -> 'photos') loop
    n := n + 1;
    if coalesce(x ->> 'path', '') !~ '^expenses/\d{4}/[0-9a-f-]{36}\.(jpg|png|pdf)$' then raise exception 'Unknown receipt file' using errcode = '22023'; end if;
    insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, uploaded_by, vehicle_id, owner_id)
    values ('receipt', left(format('Receipt %s of %s: %s', n, jsonb_array_length(p -> 'photos'), v_desc), 200), 'documents', x ->> 'path',
            nullif(x ->> 'mime', ''), nullif(x ->> 'sha256', ''), 'records_7y', p_by,
            -- on the car and its owner only when the owner pays: the owner's portal lists the documents of their cars
            case when v_payer = 'owner' then v.id end, case when v_payer = 'owner' then v.owner_id end)
    returning id into v_doc;
    v_docs := v_docs || v_doc;
  end loop;

  if v_payer = 'company' then
    insert into company_expenses (expense_on, category, description, amount_cents, hst_cents, vehicle_id, owner_id, document_id, paid_with, staff_user_id, created_by)
    values (v_on, v_cat, left(v_desc, 500), v_amount, v_hst, v.id, v.owner_id, v_docs[1], v_paid, case when v_paid = 'own' then p_by end, p_by)
    returning id into v_ce;
  else
    insert into owner_deductions (owner_id, vehicle_id, kind, description, amount_cents, hst_cents, incurred_on, receipt_document_id, status, created_by)
    values (v.owner_id, v.id, 'maintenance', left(v_desc, 500), v_amount + v_hst, v_hst, v_on, v_docs[1], 'open', p_by)
    returning id into v_od;
  end if;
  insert into expense_entries (id, expense_on, vendor, category, description, amount_cents, hst_cents, vehicle_id, owner_id, payer, paid_with,
                               company_expense_id, owner_deduction_id, read, created_by)
  values (v_id, v_on, left(v_vendor, 160), v_cat, left(v_desc, 500), v_amount, v_hst, v.id, v.owner_id, v_payer, v_paid, v_ce, v_od,
          coalesce(p -> 'read', '{}'::jsonb), p_by);
  insert into expense_entry_photos (entry_id, document_id, sort) select v_id, d, o from unnest(v_docs) with ordinality u(d, o);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'expense_log', 'expense_entries', v_id::text,
          jsonb_build_object('payer', v_payer, 'amount_cents', v_amount, 'hst_cents', v_hst, 'vehicle_id', v.id, 'company_expense_id', v_ce, 'owner_deduction_id', v_od, 'photos', cardinality(v_docs)));
  if v_payer = 'owner' then
    perform app.ntf_emit('owner_car_cost_added', 'owner', v.owner_id, 'expense:' || v_id,
      jsonb_build_object('owner_id', v.owner_id, 'vehicle_id', v.id, 'vehicle_name', app.vehicle_name(v.id), 'cost_description', left(v_desc, 200),
                         'cost_vendor', coalesce(v_vendor, ''), 'cost_date', to_char(v_on, 'Dy, Mon FMDD, YYYY'), 'cost_amount', app.fmt_money(v_amount + v_hst),
                         'cost_tax', app.fmt_money(v_hst), 'receipt_count', cardinality(v_docs)::text));
  end if;
  return jsonb_build_object('id', v_id, 'payer', v_payer, 'company_expense_id', v_ce, 'owner_deduction_id', v_od, 'photos', cardinality(v_docs),
                            'vehicle_name', app.vehicle_name(v.id), 'total_cents', v_amount + v_hst);
end $$;

create function app.expense_entries_json(p_by uuid, p_limit integer default 30) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  if not app.expense_may_log(p_by) then raise exception 'An Admin, Finance or Fleet logs expenses' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'expense_on', e.expense_on, 'vendor', e.vendor, 'category', e.category,
            'category_label', (select c.label from company_expense_categories c where c.code = e.category), 'description', e.description,
            'amount_cents', e.amount_cents, 'hst_cents', e.hst_cents, 'payer', e.payer, 'vehicle_id', e.vehicle_id, 'vehicle_name', app.vehicle_name(e.vehicle_id),
            'owner_status', (select d.status from owner_deductions d where d.id = e.owner_deduction_id),
            'voided', (select x.voided_at is not null from company_expenses x where x.id = e.company_expense_id),
            'photos', (select coalesce(jsonb_agg(ph.document_id order by ph.sort), '[]'::jsonb) from expense_entry_photos ph where ph.entry_id = e.id),
            'by', (select u.full_name from users u where u.id = e.created_by), 'created_at', e.created_at) order by e.created_at desc), '[]'::jsonb)
            from (select * from expense_entries order by created_at desc limit least(greatest(coalesce(p_limit, 30), 1), 200)) e);
end $$;

-- grants: each wrapped function as its old one was (ai_tier and ai_feature_label are plain helpers anyone may call; the old
-- ones keep theirs, as the wrapper calls them with the caller's rights); the new definer functions to the server only
do $$
declare
  f record;
  g text;
begin
  for f in select p.oid::regprocedure as sig, (select q.oid from pg_proc q where q.pronamespace = p.pronamespace and q.proname = p.proname || '_pre5143') as old
             from pg_proc p where p.pronamespace = 'app'::regnamespace
              and p.proname in ('ai_purposes', 'ai_kind', 'ai_private', 'ai_tier', 'ai_feature_label', 'ai_vision_gate', 'ai_call_record', 'ai_vision_budget')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, f.old, 'execute') then execute format('grant execute on function %s to %I', f.sig, g); end if;
    end loop;
  end loop;
  for f in select p.oid::regprocedure as sig from pg_proc p
            where p.pronamespace = 'app'::regnamespace and p.proname in ('expense_may_log', 'expense_context', 'expense_log', 'expense_entries_json') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
