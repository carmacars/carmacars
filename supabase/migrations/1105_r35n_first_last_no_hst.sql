-- 1105_r35n_first_last_no_hst.sql
-- Release 35 (docs/changes/2026-11-08-r35-no-hst-on-insurance.md). SCHEMA_MARKER 1105.
-- Admin > Today, "Record the first and last month paid": the amount typed is what the owner paid, tax included. Since 0873
-- the first and last month (the Insurance Fee) carries no HST unless Program settings charge it (insurance_fee_hst), but
-- the record still took HST out of the amount: an owner who paid $678 got an invoice of $600 marked paid. The HST is now
-- taken out only when it is charged; with the setting off the invoice is the amount paid. The body is 0078's with that
-- one change (0780 wraps it as first_last_paid_record_pre0780; its grants are kept by create or replace).
-- The facts of Approve and Add a car carry insurance_fee_hst, so their totals show no HST on the first and last month
-- and the Registration Fee when none is charged (they showed $819.82 for an invoice of $725.50). 0067's body plus that key.

create or replace function app.first_last_paid_record_pre0780(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  v_cars jsonb := coalesce(p -> 'cars', '[]'::jsonb);
  v_ids text[];
  v_total bigint := nullif(p ->> 'total_cents', '')::bigint;
  v_n integer;
  c jsonb;
  v vehicles;
  v_amt bigint;
  v_out jsonb := '[]'::jsonb;
  d jsonb;
  r jsonb;
  i int := 0;
  -- 0873: the first and last month is the Insurance Fee, with no HST unless Program settings charge it
  v_bps integer := case when coalesce((app.settings()).insurance_fee_hst, false) then (app.settings()).hst_bps else 0 end;
  v_fees bigint;
  k int;
begin
  perform app.assert_admin(p_by);
  select * into o from owners where id = nullif(p ->> 'owner_id', '')::uuid;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  if o.is_shareholder then raise exception 'A shareholder pays no first and last month' using errcode = '23514'; end if;
  if coalesce(p ->> 'method', '') not in ('e_transfer', 'cash', 'cheque', 'bank_transfer', 'other') then
    raise exception 'Choose how it was paid' using errcode = '22023';
  end if;
  if v_total is not null then
    v_ids := array(select jsonb_array_elements_text(coalesce(p -> 'vehicle_ids', '[]'::jsonb)));
    v_n := cardinality(v_ids);
    if v_n = 0 then raise exception 'Tick the cars it pays for' using errcode = '22023'; end if;
    if v_total <= 0 then raise exception 'Enter the amount paid' using errcode = '22023'; end if;
    v_cars := (select jsonb_agg(jsonb_build_object('vehicle_id', x, 'amount_cents', v_total / v_n + case when n = 1 then v_total % v_n else 0 end))
                 from unnest(v_ids) with ordinality u(x, n));
  end if;
  for d in select * from jsonb_array_elements(coalesce(p -> 'drafts', '[]'::jsonb)) loop
    if d ->> 'action' = 'void' then
      if not exists (select 1 from owner_invoices x where x.id = nullif(d ->> 'invoice_id', '')::uuid and x.owner_id = o.id and x.status = 'draft') then
        raise exception 'That draft is not this owner''s' using errcode = '22023';
      end if;
      perform app.owner_invoice_void(p_by, jsonb_build_object('id', d ->> 'invoice_id', 'reason', 'Replaced by the first and last month recorded as paid'));
    end if;
  end loop;
  for c in select * from jsonb_array_elements(v_cars) loop
    v_amt := nullif(c ->> 'amount_cents', '')::bigint;
    continue when v_amt is null or v_amt = 0;
    if v_amt < 0 then raise exception 'An amount cannot be negative' using errcode = '22023'; end if;
    select * into v from vehicles where id = nullif(c ->> 'vehicle_id', '')::uuid;
    if v.id is null or v.owner_id is distinct from o.id then raise exception 'That car is not this owner''s' using errcode = '22023'; end if;
    if v.is_shareholder_owned then raise exception '% is shareholder-owned: no first and last month', app.vehicle_name(v.id) using errcode = '23514'; end if;
    if exists (select 1 from owner_invoices x where x.vehicle_id = v.id and x.kind = 'upfront' and x.status not in ('void', 'draft')) then
      raise exception '% already has its first and last month invoice', app.vehicle_name(v.id) using errcode = '23514';
    end if;
    if exists (select 1 from owner_invoices x where x.vehicle_id = v.id and x.kind = 'upfront' and x.status = 'draft') then
      raise exception '% has a draft first and last month invoice (%): void it here to record the payment, or keep it and record nothing for this car',
        app.vehicle_name(v.id), (select x.invoice_number from owner_invoices x where x.vehicle_id = v.id and x.kind = 'upfront' and x.status = 'draft' limit 1) using errcode = '23514';
    end if;
    -- the amount received includes any HST charged: the fees are the amount before tax that adds up to it (to the cent when it can)
    v_fees := round(v_amt * 10000.0 / (10000 + v_bps))::bigint;
    for k in -2..2 loop
      if (v_fees + k) + public.calc_hst((v_fees + k) / 2, v_bps) + public.calc_hst((v_fees + k) - (v_fees + k) / 2, v_bps) = v_amt then v_fees := v_fees + k; exit; end if;
    end loop;
    r := app.oi_plan_invoice(p_by, v.id, app.owner_terms_resolve(v.id), jsonb_build_object('type', 'first_last', 'amount_cents', v_fees, 'action', 'paid',
           'payment', jsonb_strip_nulls(jsonb_build_object('method', p ->> 'method', 'received_on', p ->> 'received_on', 'reference', nullif(btrim(coalesce(p ->> 'reference', '')), ''),
                                                           'note', coalesce(nullif(btrim(coalesce(p ->> 'note', '')), ''), 'First and last month, recorded from Admin > Today')))), null);
    v_out := v_out || jsonb_build_array(r || jsonb_build_object('vehicle_id', v.id, 'name', app.vehicle_name(v.id)));
    i := i + 1;
  end loop;
  if i = 0 then raise exception 'Enter the amount paid for at least one car' using errcode = '22023'; end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'first_last_paid_record', 'owners', o.id::text, jsonb_build_object('invoices', v_out, 'drafts', p -> 'drafts', 'method', p ->> 'method'));
  return jsonb_build_object('owner_id', o.id, 'invoices', v_out, 'count', i);
end $$;

create or replace function app.owner_add_car_facts(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  o owners;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into o from owners where id = nullif(p ->> 'owner_id', '')::uuid;
  return jsonb_build_object('admin', app.user_is_admin(p_by), 'trackers_available', coalesce((app.settings()).trackers_available, false), 'today', app.today(),
    'hst_bps', (app.settings()).hst_bps, 'insurance_fee_hst', coalesce((app.settings()).insurance_fee_hst, false),
    'owner', case when o.id is not null then jsonb_build_object('id', o.id, 'legal_name', o.legal_name, 'email', o.email, 'phone', o.phone, 'owner_type', o.owner_type,
                     'has_account', o.user_id is not null, 'corporation_name', o.corporation_name) end,
    'terms', case when o.id is not null then app.owner_terms_resolve(null, null, o.id, coalesce(nullif(p ->> 'mode', '')::management_mode, 'managed')) end,
    'standard', (select jsonb_build_object('insurance_fee_cents', g.insurance_fee_cents, 'tracker_fee_cents', g.tracker_fee_cents, 'revenue_share_bps', g.revenue_share_bps,
                         'install_fee_cents', (app.settings()).install_fee_cents)
                   from owner_fee_grid g where g.min_vehicles <= 1 and g.effective_from <= app.today() order by g.effective_from desc, g.min_vehicles limit 1));
end $$;
