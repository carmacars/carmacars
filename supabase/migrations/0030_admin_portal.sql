-- 0030: the admin portal (docs/blueprint/03-admin.md).
--
-- The web app reaches the database only through functions in `public`, as the service role, with the
-- Admin's user id; the money and booking rules stay in the functions of 0016 to 0029. This migration
-- adds the door the admin portal goes through, nothing else:
--
--   app.admin_begin(admin)            checks the Admin and makes them the acting user for the
--                                     transaction (auth.uid(), so audit rows, guards and the
--                                     staff-only reads of earlier migrations see the Admin)
--   app.admin_list(admin, rel, p)     one reader for the portal's lists: an allow-list of tables and
--                                     views, filters on real columns only, names added for ids
--   app.admin_read(admin, what, p)    the screens that need more than a list: dashboard, request
--                                     queue, booking, re-pricing preview, calendar, vehicle, listing,
--                                     settings, tolls, statements, exports
--   app.admin_save(admin, table, p)   the settings an Admin changes without a developer: an
--                                     allow-list of tables and columns; program settings as a new
--                                     dated row
--   app.admin_do(admin, action, p)    every admin action, each one a call to the function of the
--                                     earlier migration that owns the rule
--
-- Plus one setting: program_settings.request_response_target_minutes (the 2-hour target for answering
-- a booking request, shown on the dashboard).

alter table program_settings add column if not exists request_response_target_minutes integer not null default 120
  check (request_response_target_minutes between 5 and 1440);

-- A coverage price entered in the evening (Toronto) took effect the next day: the column defaulted to the
-- server's date (UTC). The business date is Toronto's.
alter table coverage_prices alter column effective_from set default app.today();

-- ================================================================ 1. the acting Admin
create or replace function app.admin_begin(p_admin uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  perform set_config('request.jwt.claim.sub', p_admin::text, true);
  perform set_config('request.jwt.claims',
    (coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb || jsonb_build_object('sub', p_admin))::text, true);
end $$;

-- Names for the ids a row carries, so a list never shows a bare uuid.
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
$$;

-- ================================================================ 2. lists
-- p: eq {column: value | [values] | null}, not_null [columns], gte {column: value}, lt {column: value},
--    q (text found anywhere in the row), order (column), asc (boolean), limit (1 to 500), offset.
-- Returns {rows, count}.
create or replace function app.admin_list(p_admin uuid, p_rel text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_allowed constant text[] := array[
    'bookings', 'booking_events', 'booking_offers', 'booking_line_items', 'booking_change_requests', 'booking_extensions',
    'booking_statements', 'booking_drivers', 'booking_info_requests', 'messages', 'condition_reports',
    'payments', 'refunds', 'deposits', 'disputes', 'payouts', 'insurer_invoices', 'insurers', 'owner_invoices',
    'owner_statements', 'owner_deductions', 'company_statements', 'company_expenses', 'company_expense_categories',
    'payout_reconciliations', 'payout_reconciliation_items',
    'tasks', 'toll_tickets', 'toll_work_queue', 'toll_work_queue_summary', 'toll_import_profiles', 'toll_import_batches',
    'damage_intakes', 'damage_work_queue', 'incidents', 'claims', 'reviews', 'review_request_decisions',
    'notification_outbox', 'email_suppressions', 'audit_log', 'data_access_log', 'job_runs',
    'owners', 'renters', 'investors', 'investments', 'investment_returns', 'leads',
    'vehicles', 'vehicle_listings', 'listing_intakes', 'listing_drafts', 'vehicle_photos', 'vehicle_calendar_blocks',
    'rate_cards', 'vehicle_fee_overrides', 'field_jobs', 'turo_trips', 'documents',
    'fee_types', 'fee_defaults', 'deposit_tiers', 'km_allowance_choices', 'vehicle_classes', 'airports', 'coverage_prices',
    'email_aliases', 'email_reply_to', 'site_content_blocks', 'program_settings', 'holidays', 'promo_codes', 'quick_replies',
    'users', 'user_roles', 'staff_profiles', 'staff_directory', 'status_history'];
  v_cols text[];
  v_where text := 'true';
  k text;
  v jsonb;
  v_order text;
  v_limit integer := least(greatest(coalesce((p ->> 'limit')::integer, 100), 1), 500);
  v_offset integer := greatest(coalesce((p ->> 'offset')::integer, 0), 0);
  v_rows jsonb;
  v_count bigint;
begin
  perform app.admin_begin(p_admin);
  p := coalesce(p, '{}'::jsonb);
  if not (p_rel = any (v_allowed)) then
    raise exception 'The admin portal does not list %', p_rel using errcode = '42501';
  end if;
  select array_agg(a.attname::text) into v_cols from pg_attribute a
   where a.attrelid = ('public.' || quote_ident(p_rel))::regclass and a.attnum > 0 and not a.attisdropped;
  for k, v in select * from jsonb_each(coalesce(p -> 'eq', '{}'::jsonb)) loop
    if not (k = any (v_cols)) then raise exception 'Unknown column % of %', k, p_rel using errcode = '22023'; end if;
    if jsonb_typeof(v) = 'null' then
      v_where := v_where || format(' and t.%I is null', k);
    elsif jsonb_typeof(v) = 'array' then
      v_where := v_where || format(' and t.%I::text = any (array(select jsonb_array_elements_text(%L::jsonb)))', k, v::text);
    else
      v_where := v_where || format(' and t.%I::text = %L', k, v #>> '{}');
    end if;
  end loop;
  for k in select jsonb_array_elements_text(coalesce(p -> 'not_null', '[]'::jsonb)) loop
    if not (k = any (v_cols)) then raise exception 'Unknown column % of %', k, p_rel using errcode = '22023'; end if;
    v_where := v_where || format(' and t.%I is not null', k);
  end loop;
  for k, v in select * from jsonb_each(coalesce(p -> 'gte', '{}'::jsonb)) loop
    if not (k = any (v_cols)) then raise exception 'Unknown column % of %', k, p_rel using errcode = '22023'; end if;
    v_where := v_where || format(' and t.%I >= %L', k, v #>> '{}');
  end loop;
  for k, v in select * from jsonb_each(coalesce(p -> 'lt', '{}'::jsonb)) loop
    if not (k = any (v_cols)) then raise exception 'Unknown column % of %', k, p_rel using errcode = '22023'; end if;
    v_where := v_where || format(' and t.%I < %L', k, v #>> '{}');
  end loop;
  if nullif(btrim(p ->> 'q'), '') is not null then
    v_where := v_where || format(' and to_jsonb(t)::text ilike %L', '%' || replace(replace(replace(btrim(p ->> 'q'), '\', '\\'), '%', '\%'), '_', '\_') || '%');
  end if;
  v_order := coalesce(p ->> 'order', case when 'created_at' = any (v_cols) then 'created_at' end, v_cols[1]);
  if not (v_order = any (v_cols)) then raise exception 'Unknown column % of %', v_order, p_rel using errcode = '22023'; end if;
  execute format('select count(*) from public.%I t where %s', p_rel, v_where) into v_count;
  execute format('select coalesce(jsonb_agg(app.admin_enrich(to_jsonb(t)) order by t.%I %s nulls last), ''[]''::jsonb)
                    from (select * from public.%I t where %s order by t.%I %s nulls last limit %s offset %s) t',
                 v_order, case when coalesce((p ->> 'asc')::boolean, false) then 'asc' else 'desc' end,
                 p_rel, v_where, v_order, case when coalesce((p ->> 'asc')::boolean, false) then 'asc' else 'desc' end, v_limit, v_offset)
    into v_rows;
  return jsonb_build_object('rows', v_rows, 'count', v_count);
end $$;

-- ================================================================ 3. settings an Admin changes
-- p: key (the row's key as text; absent or null to add a row), values {column: value}.
-- program_settings: a new dated row (p.effective_from, today by default) copied from the row in force,
-- or the row of that date when one exists; history is never edited.
-- fee_defaults: a new row from p.values.effective_from; the row it replaces is closed the day before.
create or replace function app.admin_save(p_admin uuid, p_table text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_key text := nullif(p ->> 'key', '');
  v_values jsonb := coalesce(p -> 'values', '{}'::jsonb);
  v_keycol text;
  v_allowed text[];
  v_cols text[];
  v_tcols text[];
  v_set text;
  v_out jsonb;
  v_on date;
  v_id uuid;
  v_from date;
begin
  perform app.admin_begin(p_admin);
  if jsonb_typeof(v_values) <> 'object' then raise exception 'Give the values as an object' using errcode = '22023'; end if;
  select array_agg(a.attname::text) into v_tcols from pg_attribute a
   where a.attrelid = to_regclass('public.' || quote_ident(p_table)) and a.attnum > 0 and not a.attisdropped;

  if p_table = 'program_settings' then
    v_on := coalesce((p ->> 'effective_from')::date, app.today());
    if v_on < app.today() then raise exception 'Settings take effect today or later; history is not edited' using errcode = '22023'; end if;
    v_allowed := array(select x from unnest(v_tcols) x where x not in ('id', 'effective_from', 'created_by', 'created_at'));
    if exists (select 1 from jsonb_object_keys(v_values) k where not (k = any (v_allowed))) then
      raise exception 'Not a setting: %', (select string_agg(k, ', ') from jsonb_object_keys(v_values) k where not (k = any (v_allowed))) using errcode = '22023';
    end if;
    select id into v_id from program_settings where effective_from = v_on;
    if v_id is null then
      insert into program_settings
      select (jsonb_populate_record(s, v_values || jsonb_build_object('id', gen_random_uuid(), 'effective_from', v_on,
                                                                      'created_by', p_admin, 'created_at', now()))).*
        from program_settings s where s.id = (app.settings(v_on)).id
      returning id into v_id;
    else
      execute format('update program_settings t set %s from (select (jsonb_populate_record(null::program_settings, $1)).*) r where t.id = $2',
                     (select string_agg(format('%I = r.%I', k, k), ', ') from jsonb_object_keys(v_values) k))
        using v_values, v_id;
    end if;
    return (select to_jsonb(s) from program_settings s where s.id = v_id);
  end if;

  if p_table = 'fee_defaults' then
    v_from := coalesce((v_values ->> 'effective_from')::date, app.today());
    if v_from < app.today() then raise exception 'A new fee default takes effect today or later' using errcode = '22023'; end if;
    if not exists (select 1 from fee_types f where f.code = v_values ->> 'fee_type_code') then
      raise exception 'Choose a fee' using errcode = '22023';
    end if;
    update fee_defaults d set effective_to = v_from
     where d.fee_type_code = v_values ->> 'fee_type_code' and d.vehicle_class is not distinct from nullif(v_values ->> 'vehicle_class', '')::vehicle_class
       and d.effective_from < v_from and (d.effective_to is null or d.effective_to > v_from);
    delete from fee_defaults d
     where d.fee_type_code = v_values ->> 'fee_type_code' and d.vehicle_class is not distinct from nullif(v_values ->> 'vehicle_class', '')::vehicle_class
       and d.effective_from = v_from;
    insert into fee_defaults (fee_type_code, vehicle_class, amount_cents, cap_cents, percent_bps, min_cents, max_cents, grace_minutes, note, effective_from, set_by)
    select r.fee_type_code, r.vehicle_class, r.amount_cents, r.cap_cents, r.percent_bps, r.min_cents, r.max_cents, r.grace_minutes, r.note, v_from, p_admin
      from jsonb_populate_record(null::fee_defaults, v_values - 'effective_from' - 'vehicle_class'
                                 || jsonb_build_object('vehicle_class', nullif(v_values ->> 'vehicle_class', ''))) r
    returning to_jsonb(fee_defaults.*) into v_out;
    return v_out;
  end if;

  v_keycol := case p_table
    when 'site_settings' then 'singleton' when 'site_content_blocks' then 'id' when 'deposit_tiers' then 'amount_cents'
    when 'km_allowance_choices' then 'km_per_day' when 'vehicle_classes' then 'code' when 'airports' then 'id'
    when 'coverage_prices' then 'id' when 'email_aliases' then 'address' when 'email_reply_to' then 'id' when 'insurers' then 'id'
    when 'promo_codes' then 'id' when 'quick_replies' then 'id' when 'holidays' then 'holiday_on' when 'company_expenses' then 'id'
    when 'staff_profiles' then 'user_id' when 'fee_types' then 'code' end;
  if v_keycol is null then raise exception 'The admin portal does not edit %', p_table using errcode = '42501'; end if;
  v_allowed := case p_table
    when 'site_settings' then array(select x from unnest(v_tcols) x where x not in ('id', 'singleton', 'created_at', 'updated_at', 'updated_by', 'legal_name_displayed'))
    when 'site_content_blocks' then array['block_key', 'page', 'kind', 'body', 'data', 'sort_order', 'is_published']
    when 'deposit_tiers' then array['amount_cents', 'label', 'sort_order', 'is_active']
    when 'km_allowance_choices' then array['km_per_day', 'sort_order', 'is_active']
    when 'vehicle_classes' then array['code', 'label', 'sort_order', 'is_active']
    when 'airports' then array['code', 'name', 'latitude', 'longitude', 'distance_km', 'surcharge_cents', 'is_active', 'sort_order']
    when 'coverage_prices' then array['vehicle_id', 'class_code', 'age_band', 'amount_cents', 'per_day', 'effective_from', 'effective_to', 'note']
    when 'email_aliases' then array['address', 'purpose', 'is_active']
    when 'email_reply_to' then array['audience', 'code', 'reply_to', 'note']
    when 'insurers' then array['name', 'billing_contact_name', 'billing_email', 'billing_phone', 'billing_address', 'notes', 'is_active']
    when 'promo_codes' then array['code', 'description', 'percent_bps', 'amount_cents', 'valid_from', 'valid_until', 'max_uses', 'once_per_renter', 'renter_id', 'source', 'is_active']
    when 'quick_replies' then array['title', 'body', 'audience', 'category', 'sort_order', 'is_active']
    when 'holidays' then array['holiday_on', 'name']
    when 'company_expenses' then array['expense_on', 'category', 'description', 'amount_cents', 'hst_cents', 'vehicle_id', 'owner_id', 'staff_user_id', 'document_id']
    when 'staff_profiles' then array['single_limit_cents', 'dual_approval_threshold_cents']
    when 'fee_types' then array['label', 'sort_order'] end;
  if exists (select 1 from jsonb_object_keys(v_values) k where not (k = any (v_allowed))) then
    raise exception 'Not a field of %: %', p_table, (select string_agg(k, ', ') from jsonb_object_keys(v_values) k where not (k = any (v_allowed))) using errcode = '22023';
  end if;
  v_cols := array(select k from jsonb_object_keys(v_values) k);
  if p_table = 'promo_codes' and v_values ? 'code' then
    v_values := v_values || jsonb_build_object('code', upper(btrim(v_values ->> 'code')));
  end if;
  if p_table = 'email_aliases' and v_values ? 'address' then
    v_values := v_values || jsonb_build_object('address', lower(btrim(v_values ->> 'address')));
  end if;
  -- who changed it, where the table records that
  if 'updated_by' = any (v_tcols) then v_values := v_values || jsonb_build_object('updated_by', p_admin); v_cols := array_append(v_cols, 'updated_by'); end if;
  if 'set_by' = any (v_tcols) then v_values := v_values || jsonb_build_object('set_by', p_admin); v_cols := array_append(v_cols, 'set_by'); end if;

  if p_table = 'site_settings' then v_key := 'true'; end if;
  if v_key is not null then
    if cardinality(v_cols) = 0 then raise exception 'Nothing to change' using errcode = '22023'; end if;
    v_set := (select string_agg(format('%I = r.%I', c, c), ', ') from unnest(v_cols) c);
    if p_table = 'company_expenses' then
      raise exception 'An expense is not edited: void it and enter it again' using errcode = '23514';
    end if;
    execute format('update public.%I t set %s from (select (jsonb_populate_record(null::public.%I, $1)).*) r where t.%I::text = $2 returning to_jsonb(t.*)',
                   p_table, v_set, p_table, v_keycol)
      into v_out using v_values, v_key;
    if v_out is null then raise exception 'That record is not there any more' using errcode = 'P0002'; end if;
  else
    if 'created_by' = any (v_tcols) then v_values := v_values || jsonb_build_object('created_by', p_admin); v_cols := array_append(v_cols, 'created_by'); end if;
    execute format('insert into public.%I (%s) select %s from (select (jsonb_populate_record(null::public.%I, $1)).*) r returning to_jsonb(%I.*)',
                   p_table, (select string_agg(format('%I', c), ', ') from unnest(v_cols) c),
                   (select string_agg(format('r.%I', c), ', ') from unnest(v_cols) c), p_table, p_table)
      into v_out using v_values;
  end if;
  return v_out;
end $$;

-- ================================================================ 4. reads
-- The booking as staff see it, with everything the review, money and history tabs show.
create or replace function app.admin_booking_json(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select to_jsonb(b)
    || jsonb_build_object(
      'vehicle', (select jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'fleet_number', v.fleet_number,
                    'allows_18_to_20', v.allows_18_to_20, 'management_mode', v.management_mode, 'status', v.status,
                    'slug', (select l.slug from vehicle_listings l where l.vehicle_id = v.id)) from vehicles v where v.id = b.vehicle_id),
      'renter', (select jsonb_build_object('id', r.id, 'legal_name', r.legal_name, 'email', r.email, 'mobile', r.mobile,
                    'identity_status', r.identity_status, 'is_blocked', r.is_blocked, 'province', r.province,
                    'bookings', (select count(*) from bookings x where x.renter_id = r.id and x.status in ('confirmed', 'on_rent', 'returned', 'closed')))
                   from renters r where r.id = b.renter_id),
      'insurer_name', (select i.name from insurers i where i.id = b.insurer_id),
      'promo_code', (select pc.code from promo_codes pc where pc.id = b.promo_code_id),
      'lines', coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at, l.id) from booking_line_items l where l.booking_id = b.id and l.voided_at is null), '[]'::jsonb),
      'drivers', coalesce((select jsonb_agg(to_jsonb(d) - 'licence_number' || jsonb_build_object('licence_last4', right(d.licence_number, 4)) order by d.role, d.full_name)
                             from booking_drivers d where d.booking_id = b.id), '[]'::jsonb),
      'insurer_share', (select to_jsonb(s) from app.booking_insurer_share(b.id) s),
      'readiness', case when b.status in ('confirmed', 'on_rent') then app.booking_readiness(b.id) end,
      'cancellable', b.status in ('requested', 'offered', 'pending_payment', 'confirmed'))
  from bookings b where b.id = p_booking
$$;

create or replace function app.admin_booking_detail(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.admin_booking_json(b.id) || jsonb_build_object(
    'offers', coalesce((select jsonb_agg(to_jsonb(o) order by o.version) from booking_offers o where o.booking_id = b.id), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(app.admin_enrich(to_jsonb(e)) order by e.created_at, e.id) from booking_events e where e.booking_id = b.id), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(jsonb_build_object('from', h.from_status, 'to', h.to_status, 'at', h.changed_at,
                                   'by', (select u.full_name from users u where u.id = h.changed_by)) order by h.changed_at)
                           from status_history h where h.entity = 'booking' and h.entity_id = b.id), '[]'::jsonb),
    'emails', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'code', n.code, 'to', n.to_address, 'status', n.status,
                                   'sent_at', n.sent_at, 'created_at', n.created_at, 'last_error', n.last_error) order by n.created_at desc)
                          from notification_outbox n where n.booking_id = b.id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at) from payments x where x.booking_id = b.id), '[]'::jsonb),
    'refunds', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at) from refunds x where x.booking_id = b.id), '[]'::jsonb),
    'deposit', (select to_jsonb(d) from deposits d where d.booking_id = b.id order by d.created_at desc limit 1),
    'statements', coalesce((select jsonb_agg(to_jsonb(x) order by x.issued_at) from booking_statements x where x.booking_id = b.id), '[]'::jsonb),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'created_at', d.created_at) order by d.created_at)
                             from documents d where d.booking_id = b.id and d.purged_at is null), '[]'::jsonb),
    'change_requests', coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at) from booking_change_requests c where c.booking_id = b.id), '[]'::jsonb),
    'extensions', coalesce((select jsonb_agg(to_jsonb(x) order by x.seq) from booking_extensions x where x.booking_id = b.id), '[]'::jsonb),
    'info_requests', coalesce((select jsonb_agg(to_jsonb(x) order by x.asked_at) from booking_info_requests x where x.booking_id = b.id), '[]'::jsonb),
    'request_sent', coalesce(b.request_details, '{}'::jsonb) || jsonb_build_object(
        'pickup_at', coalesce((select (e.details ->> 'pickup_at') from booking_events e where e.booking_id = b.id and e.kind = 'requested' order by e.created_at limit 1), b.pickup_at::text),
        'return_at', coalesce((select (e.details ->> 'return_at') from booking_events e where e.booking_id = b.id and e.kind = 'requested' order by e.created_at limit 1), b.original_return_at::text),
        'note', b.request_note),
    'competing', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'booking_number', x.booking_number, 'status', x.status,
                                   'pickup_at', x.pickup_at, 'return_at', x.return_at) order by x.pickup_at)
                             from bookings x where x.vehicle_id = b.vehicle_id and x.id <> b.id
                              and x.status in ('requested', 'offered', 'pending_payment', 'confirmed', 'on_rent')
                              and x.pickup_at < b.return_at and x.return_at > b.pickup_at), '[]'::jsonb),
    'available', app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id),
    'tasks', coalesce((select jsonb_agg(app.admin_enrich(to_jsonb(t)) order by t.created_at) from tasks t where t.booking_id = b.id and t.status in ('open', 'in_progress', 'waiting')), '[]'::jsonb))
  from bookings b where b.id = p_booking
$$;

-- What a booking would be after the staff's edits, priced by the database and then rolled back.
-- p: booking, changes (adjust_booking's columns), places (set_booking_places), coverage_cents and
-- coverage_reason (set_coverage_price), fee_terms [{fee, amount_cents, reason}] (set_booking_fee_term),
-- promo_code ('' removes it).
create or replace function app.admin_apply_booking_edit(p_admin uuid, p_booking uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  f jsonb;
  b bookings;
begin
  if jsonb_typeof(p -> 'changes') = 'object' and p -> 'changes' <> '{}'::jsonb then
    perform app.adjust_booking(p_booking, p_admin, p -> 'changes', nullif(btrim(p ->> 'note'), ''));
  end if;
  if jsonb_typeof(p -> 'places') = 'object' and p -> 'places' <> '{}'::jsonb then
    perform app.set_booking_places(p_booking, p_admin, p -> 'places');
  end if;
  if p ? 'promo_code' then
    select * into b from bookings where id = p_booking;
    if nullif(btrim(p ->> 'promo_code'), '') is null then
      if b.promo_code_id is not null then perform app.remove_promo_code(p_booking, p_admin); end if;
    elsif b.promo_code_id is distinct from (select pc.id from promo_codes pc where pc.code = upper(btrim(p ->> 'promo_code'))) then
      if b.promo_code_id is not null then perform app.remove_promo_code(p_booking, p_admin); end if;
      perform app.apply_promo_code(p_booking, upper(btrim(p ->> 'promo_code')), p_admin);
    end if;
  end if;
  for f in select value from jsonb_array_elements(coalesce(p -> 'fee_terms', '[]'::jsonb)) loop
    perform app.set_booking_fee_term(p_booking, f ->> 'fee', p_admin, f ->> 'reason', (f ->> 'amount_cents')::bigint, null, null);
  end loop;
  if nullif(p ->> 'coverage_cents', '') is not null then
    perform app.set_coverage_price(p_booking, p_admin, (p ->> 'coverage_cents')::bigint, coalesce(nullif(btrim(p ->> 'coverage_reason'), ''), 'Set on the review screen'));
  end if;
  if p ? 'blocks_calendar' then
    select * into b from bookings where id = p_booking;
    if b.blocks_calendar is distinct from (p ->> 'blocks_calendar')::boolean then
      perform app.set_blocks_calendar(p_booking, (p ->> 'blocks_calendar')::boolean, p_admin, p ->> 'blocks_calendar_reason');
    end if;
  end if;
end $$;

create or replace function app.admin_booking_preview(p_admin uuid, p_booking uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
begin
  begin
    perform app.admin_apply_booking_edit(p_admin, p_booking, p);
    v_out := jsonb_build_object('ok', true, 'booking', app.admin_booking_json(p_booking),
                                'available', (select app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id) from bookings b where b.id = p_booking));
    raise exception using errcode = 'P0001', message = 'admin-preview-rollback';
  exception when others then
    if sqlerrm <> 'admin-preview-rollback' then
      v_out := jsonb_build_object('ok', false, 'error', sqlerrm);
    end if;
  end;
  return v_out;
end $$;

create or replace function app.admin_dashboard(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_today date := app.today();
  v_month date := app.month_start(app.today());
  v_set program_settings := app.settings();
  v_days record;
begin
  select coalesce(sum(d.in_program), 0) as in_program, coalesce(sum(d.rented), 0) as rented, coalesce(sum(d.blocked), 0) as blocked,
         coalesce(sum(d.owner_days), 0) as owner_days
    into v_days
    from vehicles v cross join lateral app.vehicle_month_days(v.id, v_month) d
   where v.status::text not in ('declined', 'exited', 'onboarding');
  return jsonb_build_object(
    'now', now(), 'today', v_today, 'target_minutes', v_set.request_response_target_minutes,
    'pickups', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'at', b.pickup_at, 'vehicle', app.vehicle_name(b.vehicle_id),
                          'plate', (select v.plate from vehicles v where v.id = b.vehicle_id), 'renter', r.legal_name, 'status', b.status,
                          'missing', app.booking_readiness(b.id) -> 'missing',
                          'staff', (select string_agg(u.full_name, ', ') from field_jobs j join users u on u.id = j.assigned_to
                                     where j.booking_id = b.id and j.kind in ('delivery', 'handover') and j.status <> 'cancelled')) order by b.pickup_at)
                         from bookings b join renters r on r.id = b.renter_id
                        where b.status in ('confirmed', 'on_rent') and app.local_date(b.pickup_at) = v_today), '[]'::jsonb),
    'returns', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'at', b.return_at, 'vehicle', app.vehicle_name(b.vehicle_id),
                          'plate', (select v.plate from vehicles v where v.id = b.vehicle_id), 'renter', r.legal_name, 'status', b.status) order by b.return_at)
                         from bookings b join renters r on r.id = b.renter_id
                        where b.status in ('confirmed', 'on_rent') and app.local_date(b.return_at) = v_today), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'vehicle', app.vehicle_name(b.vehicle_id),
                          'renter', r.legal_name, 'requested_at', b.requested_at, 'pickup_at', b.pickup_at,
                          'waiting_minutes', floor(extract(epoch from now() - coalesce(b.requested_at, b.created_at)) / 60)::integer,
                          'awaiting_renter', b.awaiting_renter_since is not null) order by coalesce(b.requested_at, b.created_at))
                         from bookings b join renters r on r.id = b.renter_id where b.status = 'requested'), '[]'::jsonb),
    'offers', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'vehicle', app.vehicle_name(b.vehicle_id),
                          'renter', r.legal_name, 'status', b.status, 'expires_at', b.offer_expires_at) order by b.offer_expires_at nulls last)
                         from bookings b join renters r on r.id = b.renter_id where b.status in ('offered', 'pending_payment')), '[]'::jsonb),
    'payments_failed', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'amount_cents', p.amount_cents, 'purpose', p.purpose,
                          'booking_number', (select x.booking_number from bookings x where x.id = p.booking_id),
                          'owner', (select o.legal_name from owners o where o.id = p.owner_id),
                          'decline', p.last_decline_code, 'next_retry_at', p.next_retry_at, 'at', p.created_at) order by p.created_at desc)
                         from payments p where p.status = 'failed' and p.created_at > now() - interval '30 days'), '[]'::jsonb),
    'deposits_due', coalesce((select jsonb_agg(x order by x ->> 'due') from (
                          select jsonb_build_object('kind', 'release', 'booking_number', b.booking_number, 'amount_cents', d.amount_cents - d.applied_cents - d.held_back_cents - d.released_cents,
                                                    'due', d.release_due_on) as x
                            from deposits d join bookings b on b.id = d.booking_id
                           where d.status in ('held', 'captured') and d.released_at is null and d.release_due_on <= v_today + 2
                          union all
                          select jsonb_build_object('kind', 'take', 'booking_number', b.booking_number, 'amount_cents', b.deposit_cents, 'due', b.pickup_at)
                            from bookings b
                           where b.status = 'confirmed' and b.pickup_at < now() + interval '24 hours' and b.deposit_cents > 0 and b.deposit_waived_at is null
                             and not exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured', 'settled'))) q), '[]'::jsonb),
    'late', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'vehicle', app.vehicle_name(b.vehicle_id), 'renter', r.legal_name,
                          'return_at', b.return_at, 'minutes_late', floor(extract(epoch from now() - b.return_at) / 60)::integer) order by b.return_at)
                         from bookings b join renters r on r.id = b.renter_id where b.status = 'on_rent' and b.return_at < now()), '[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('queue', q.queue, 'open', q.n, 'overdue', q.overdue, 'escalated', q.esc) order by q.queue)
                         from (select t.queue, count(*) n, count(*) filter (where t.due_at < now()) overdue, count(*) filter (where t.escalated) esc
                                 from tasks t where t.status in ('open', 'in_progress', 'waiting') and (t.wake_at is null or t.wake_at <= now())
                                group by t.queue) q), '[]'::jsonb),
    'escalations', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'title', t.title, 'reason', t.escalation_reason, 'procedure_no', t.procedure_no,
                          'booking_number', (select x.booking_number from bookings x where x.id = t.booking_id)) order by t.escalated_at desc)
                         from tasks t where t.escalated and t.status in ('open', 'in_progress', 'waiting')), '[]'::jsonb),
    'fleet', jsonb_build_object(
        'by_status', (select coalesce(jsonb_object_agg(s, n), '{}'::jsonb) from (select v.status::text s, count(*) n from vehicles v group by v.status) q),
        'fleet_policy', app.fleet_count(v_today, false), 'min_fleet', v_set.min_fleet_count,
        'days_in_program', v_days.in_program, 'days_rented', v_days.rented, 'days_blocked', v_days.blocked,
        'utilization_bps', case when v_days.in_program - v_days.blocked > 0 then round(v_days.rented * 10000 / (v_days.in_program - v_days.blocked))::integer else 0 end),
    'cash', jsonb_build_object(
        'month', v_month,
        'in_cents', coalesce((select sum(p.amount_cents) from payments p where p.status = 'succeeded' and p.kind in ('charge', 'capture')
                                and p.processed_at >= app.local_midnight(v_month)), 0),
        'refunds_cents', coalesce((select sum(p.amount_cents) from payments p where p.status = 'succeeded' and p.kind = 'refund'
                                and p.processed_at >= app.local_midnight(v_month)), 0),
        'payouts_cents', coalesce((select sum(x.amount_cents) from payouts x where x.status = 'paid' and x.paid_at >= app.local_midnight(v_month)), 0),
        'expenses_cents', coalesce((select sum(e.amount_cents + coalesce(e.hst_cents, 0)) from company_expenses e where e.voided_at is null and e.expense_on >= v_month), 0),
        'deposits_held_cents', coalesce((select sum(d.amount_cents - d.applied_cents - d.released_cents) from deposits d where d.status in ('held', 'captured')), 0)),
    'approvals', jsonb_build_object(
        'refunds', (select count(*) from refunds where status = 'pending_approval'),
        'payouts', (select count(*) from payouts where status in ('draft', 'pending_approval')),
        'statements', (select count(*) from owner_statements where status = 'draft'),
        'listings', (select count(*) from listing_intakes where state = 'needs_review'),
        'tolls', (select count(*) from toll_work_queue where bucket in ('needs_review', 'unmatched'))),
    'alerts', coalesce(app.site_setup_problems(), '[]'::jsonb)
      || coalesce((select jsonb_agg(jsonb_build_object('field', 'job', 'message', format('Scheduled job %s failed: %s', j.job_name, left(coalesce(j.error, ''), 140))))
                     from job_runs j where j.status = 'failed' and j.started_at > now() - interval '24 hours'), '[]'::jsonb),
    'email_today', app.outbox_sent_today(now()), 'email_cap', v_set.notify_daily_cap);
end $$;

-- The request queue: requests, offers out, awaiting signature and payment, offers expired lately.
create or replace function app.admin_requests(p_admin uuid, p jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x order by x ->> 'sort'), '[]'::jsonb) from (
    select jsonb_build_object('id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'vehicle', app.vehicle_name(b.vehicle_id),
      'vehicle_id', b.vehicle_id, 'renter', r.legal_name, 'returning', exists (select 1 from bookings y where y.renter_id = r.id and y.id <> b.id and y.status in ('returned', 'closed')),
      'pickup_at', b.pickup_at, 'return_at', b.return_at, 'days', b.billable_days, 'total_cents', b.total_due_at_booking_cents,
      'requested_at', coalesce(b.requested_at, b.created_at), 'offer_expires_at', b.offer_expires_at,
      'waiting_minutes', floor(extract(epoch from now() - coalesce(b.requested_at, b.created_at)) / 60)::integer,
      'state', case when b.status = 'requested' and b.awaiting_renter_since is not null then 'waiting_on_renter'
                    when b.status = 'requested' and exists (select 1 from booking_events e where e.booking_id = b.id and e.kind = 'pushed_back') then 'pushed_back'
                    when b.status = 'requested' then 'new' when b.status = 'offered' then 'offer_out'
                    when b.status = 'pending_payment' then 'awaiting_payment' else 'expired' end,
      'drivers', (select coalesce(jsonb_agg(d.age_band), '[]'::jsonb) from booking_drivers d where d.booking_id = b.id),
      'assigned', (select u.full_name from tasks t join users u on u.id = t.assigned_to where t.booking_id = b.id and t.status in ('open', 'in_progress') limit 1),
      'flags', to_jsonb(array_remove(array[
         case when exists (select 1 from bookings y where y.vehicle_id = b.vehicle_id and y.id <> b.id and y.status in ('requested', 'offered', 'pending_payment', 'confirmed', 'on_rent')
                            and y.pickup_at < b.return_at and y.return_at > b.pickup_at) then 'Conflict' end,
         case when exists (select 1 from booking_drivers d where d.booking_id = b.id and d.age_at_pickup < 21) then 'Under 21' end,
         case when r.province is not null and r.province <> 'ON' then 'Non-Ontario address' end,
         case when b.pickup_method = 'delivered' or b.return_method = 'picked_up' then 'Delivery' end,
         case when r.is_blocked then 'Blocked renter' end,
         case when b.bill_to <> 'renter' then 'Insurer' end,
         case when b.renews_booking_id is not null then 'Renewal' end,
         case when b.management_mode = 'self_managed' then 'Self-Managed car' end,
         case when b.outside_ontario_consent then 'Outside Ontario' end,
         case when not b.blocks_calendar then 'Not blocking' end], null)),
      'sort', case when b.status = 'requested' then '0' else '1' end || to_char(coalesce(b.requested_at, b.created_at), 'YYYYMMDDHH24MISS')) as x
      from bookings b join renters r on r.id = b.renter_id
     where b.status in ('requested', 'offered', 'pending_payment')
        or (b.status = 'expired' and b.updated_at > now() - interval '14 days')) q
$$;

-- The master calendar: every vehicle with its entries in the range.
create or replace function app.admin_calendar(p_from timestamptz, p_to timestamptz, p_vehicle uuid default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('from', p_from, 'to', p_to, 'now', now(),
    'vehicles', coalesce(jsonb_agg(v order by v ->> 'fleet_number' nulls last, v ->> 'label'), '[]'::jsonb))
  from (
    select jsonb_build_object('id', m.vehicle_id, 'label', min(m.vehicle_label), 'plate', min(m.plate), 'fleet_number', min(m.fleet_number),
             'status', min(m.vehicle_status),
             'class', (select vv.class::text from vehicles vv where vv.id = m.vehicle_id),
             'owner', (select o.legal_name from vehicles vv join owners o on o.id = vv.owner_id where vv.id = m.vehicle_id),
             'mode', (select vv.management_mode::text from vehicles vv where vv.id = m.vehicle_id),
             'entries', coalesce(jsonb_agg(jsonb_build_object('type', m.entry_type, 'id', m.entry_id, 'booking_id', m.booking_id,
                 'booking_number', m.booking_number, 'booking_type', m.booking_type, 'status', m.status, 'state', m.calendar_state,
                 'starts_at', m.starts_at, 'ends_at', m.ends_at, 'blocks', m.blocks_calendar, 'blocking', m.is_blocking, 'bill_to', m.bill_to,
                 'provisional', m.dates_provisional, 'insurer', m.insurer_name, 'renter', m.renter_name, 'reason', m.block_reason,
                 'note', m.note, 'assignee', m.assignee_name, 'detail', m.detail) order by m.starts_at) filter (where m.entry_id is not null), '[]'::jsonb)) as v
      from app.master_calendar(p_from, p_to) m
     where p_vehicle is null or m.vehicle_id = p_vehicle
     group by m.vehicle_id) q
$$;

create or replace function app.admin_vehicle(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select to_jsonb(v) || jsonb_build_object(
    'name', app.vehicle_name(v.id),
    'owner', (select jsonb_build_object('id', o.id, 'legal_name', o.legal_name, 'email', o.email, 'phone', o.phone) from owners o where o.id = v.owner_id),
    'listing', (select to_jsonb(l) from vehicle_listings l where l.vehicle_id = v.id),
    'rate_card', (select to_jsonb(r) from rate_cards r where r.vehicle_id = v.id and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now())),
    'rate_history', coalesce((select jsonb_agg(app.admin_enrich(to_jsonb(r) || jsonb_build_object('set_by_name', (select u.full_name from users u where u.id = r.set_by))) order by r.effective_from desc)
                                from rate_cards r where r.vehicle_id = v.id), '[]'::jsonb),
    'fee_overrides', coalesce((select jsonb_agg(to_jsonb(f) || jsonb_build_object('label', (select t.label from fee_types t where t.code = f.fee_type_code)) order by f.effective_from desc)
                                 from vehicle_fee_overrides f where f.vehicle_id = v.id and (f.effective_to is null or f.effective_to > app.today())), '[]'::jsonb),
    'fee_types', coalesce((select jsonb_agg(jsonb_build_object('code', t.code, 'label', t.label, 'unit', t.unit,
                             'default', (select jsonb_build_object('amount_cents', ft.amount_cents, 'percent_bps', ft.percent_bps, 'cap_cents', ft.cap_cents, 'source', ft.source)
                                           from app.fee_term(t.code, v.id, app.today(), null) ft limit 1)) order by t.sort_order, t.code)
                             from fee_types t where t.change_vehicle), '[]'::jsonb),
    'classes', to_jsonb(app.vehicle_class_list(v.id)),
    'coverage_prices', coalesce((select jsonb_agg(to_jsonb(c) order by c.age_band) from coverage_prices c
                                  where (c.vehicle_id = v.id or c.class_code = v.class::text) and (c.effective_to is null or c.effective_to > app.today())), '[]'::jsonb),
    'schedule', (select to_jsonb(s) from vehicle_schedules s where s.vehicle_id = v.id order by s.created_at desc limit 1),
    'terms', (select to_jsonb(h) from app.vehicle_terms(v.id, app.today()) h),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'created_at', d.created_at) order by d.created_at desc)
                             from documents d where d.vehicle_id = v.id and d.purged_at is null), '[]'::jsonb),
    'tracker', (select jsonb_build_object('device', to_jsonb(t), 'status', (select to_jsonb(s) from tracker_status s where s.tracker_device_id = t.id))
                  from tracker_devices t where t.vehicle_id = v.id and t.removed_at is null order by t.installed_at desc nulls last limit 1),
    'bookings', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at, 'return_at', b.return_at,
                             'renter', (select r.legal_name from renters r where r.id = b.renter_id), 'total_cents', b.total_due_at_booking_cents) order by b.pickup_at desc)
                            from bookings b where b.vehicle_id = v.id and b.return_at > now() - interval '120 days'), '[]'::jsonb),
    'transitions', coalesce((select jsonb_agg(t.to_status) from status_transitions t where t.entity = 'vehicle' and t.from_status = v.status::text), '[]'::jsonb),
    'intake', (select to_jsonb(i) from listing_intakes i where i.vehicle_id = v.id order by i.created_at desc limit 1))
  from vehicles v where v.id = p_vehicle
$$;

create or replace function app.admin_listing(p_intake uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select to_jsonb(i) || jsonb_build_object(
    'vehicle', (select to_jsonb(v) || jsonb_build_object('name', app.vehicle_name(v.id)) from vehicles v where v.id = i.vehicle_id),
    'listing', (select to_jsonb(l) from vehicle_listings l where l.vehicle_id = i.vehicle_id),
    'draft', (select to_jsonb(d) from listing_drafts d where d.intake_id = i.id order by d.created_at desc limit 1),
    'photos', coalesce((select jsonb_agg(to_jsonb(ph) || jsonb_build_object('shot_label', (select st.label from listing_shot_types st where st.code = ph.shot_type))
                                         order by ph.sort_order, ph.created_at)
                          from vehicle_photos ph where ph.vehicle_id = i.vehicle_id and ph.replaced_at is null), '[]'::jsonb),
    'jobs', coalesce((select jsonb_agg(jsonb_build_object('kind', j.kind, 'status', j.status, 'attempts', j.attempts, 'error', j.error) order by j.created_at)
                        from listing_jobs j where j.intake_id = i.id), '[]'::jsonb),
    'problems', jsonb_build_object(
       'copy', (select to_jsonb(app.listing_copy_problems(l.headline, l.description, l.features, l.faq)) from vehicle_listings l where l.vehicle_id = i.vehicle_id),
       'photos', to_jsonb(app.listing_photo_problems(i.vehicle_id)), 'specs', to_jsonb(app.listing_spec_problems(i.vehicle_id)),
       'missing_shots', to_jsonb(app.listing_missing_shots(i.vehicle_id))))
  from listing_intakes i where i.id = p_intake
$$;

create or replace function app.admin_settings() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'site', (select to_jsonb(s) from site_settings s limit 1),
    'program', to_jsonb(app.settings()),
    'program_rows', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'effective_from', p.effective_from, 'created_at', p.created_at) order by p.effective_from desc) from program_settings p), '[]'::jsonb),
    'content', coalesce((select jsonb_agg(to_jsonb(c) order by c.page, c.sort_order, c.block_key) from site_content_blocks c), '[]'::jsonb),
    'fee_types', coalesce((select jsonb_agg(to_jsonb(t) order by t.sort_order, t.code) from fee_types t), '[]'::jsonb),
    'fee_defaults', coalesce((select jsonb_agg(to_jsonb(d) order by d.fee_type_code, d.vehicle_class nulls first, d.effective_from desc) from fee_defaults d
                                where d.effective_to is null or d.effective_to > app.today()), '[]'::jsonb),
    'deposit_tiers', coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order, x.amount_cents) from deposit_tiers x), '[]'::jsonb),
    'km_choices', coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order, x.km_per_day) from km_allowance_choices x), '[]'::jsonb),
    'classes', coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order, x.code) from vehicle_classes x), '[]'::jsonb),
    'airports', coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order, x.code) from airports x), '[]'::jsonb),
    'coverage', coalesce((select jsonb_agg(app.admin_enrich(to_jsonb(x)) order by x.class_code nulls last, x.age_band, x.effective_from desc) from coverage_prices x
                            where x.effective_to is null or x.effective_to > app.today()), '[]'::jsonb),
    'email_aliases', coalesce((select jsonb_agg(to_jsonb(x) order by x.address) from email_aliases x), '[]'::jsonb),
    'reply_to', coalesce((select jsonb_agg(to_jsonb(x) order by x.audience nulls first, x.code nulls first) from email_reply_to x), '[]'::jsonb),
    'insurers', coalesce((select jsonb_agg(to_jsonb(x) || jsonb_build_object(
                            'open_bookings', (select count(*) from bookings b where b.insurer_id = x.id and b.status in ('requested', 'offered', 'pending_payment', 'confirmed', 'on_rent')),
                            'unpaid_cents', (select coalesce(sum(i.balance_cents), 0) from insurer_invoices i where i.insurer_id = x.id and i.status in ('sent', 'part_paid')))
                          order by x.name) from insurers x), '[]'::jsonb),
    'promo_codes', coalesce((select jsonb_agg(to_jsonb(x) || jsonb_build_object('uses', (select count(*) from promo_redemptions r where r.promo_code_id = x.id))
                               order by x.created_at desc) from promo_codes x where x.source is distinct from 'followup_7d' and x.source is distinct from 'followup_30d'), '[]'::jsonb),
    'quick_replies', coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order, x.title) from quick_replies x), '[]'::jsonb),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'email', u.email, 'full_name', u.full_name, 'status', u.status,
                          'roles', (select jsonb_agg(r.role) from user_roles r where r.user_id = u.id), 'last_sign_in_at', u.last_sign_in_at,
                          'profile', (select to_jsonb(sp) from staff_profiles sp where sp.user_id = u.id)) order by u.full_name)
                         from users u where exists (select 1 from user_roles r where r.user_id = u.id and r.role in ('admin', 'va', 'field'))), '[]'::jsonb),
    'expense_categories', coalesce((select jsonb_agg(to_jsonb(x) order by x.label) from company_expense_categories x where x.is_active), '[]'::jsonb),
    'problems', coalesce(app.site_setup_problems(), '[]'::jsonb))
$$;

-- p: what, and its arguments. Each branch is one screen.
create or replace function app.admin_read(p_admin uuid, p_what text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_id uuid;
  v_month date;
begin
  perform app.admin_begin(p_admin);
  case p_what
  when 'dashboard' then return app.admin_dashboard(p_admin);
  when 'requests' then return app.admin_requests(p_admin, p_);
  when 'booking' then
    select b.id into v_id from bookings b where b.booking_number = p_ ->> 'number' or b.id::text = p_ ->> 'id';
    return case when v_id is null then null else app.admin_booking_detail(v_id) end;
  when 'booking_preview' then
    return app.admin_booking_preview(p_admin, (p_ ->> 'booking')::uuid, p_);
  when 'quote_vehicles' then
    -- bookable vehicles for the dates with whether each is free (the review screen's car picker)
    return (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'class', v.class,
              'allows_18_to_20', v.allows_18_to_20,
              'free', app.vehicle_is_available(v.id, (p_ ->> 'pickup_at')::timestamptz, (p_ ->> 'return_at')::timestamptz, (p_ ->> 'booking')::uuid),
              'daily_rate_cents', (select r.daily_rate_cents from rate_cards r where r.vehicle_id = v.id and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now())))
              order by v.make, v.model, v.year), '[]'::jsonb)
              from vehicles v where app.vehicle_bookable(v.id));
  when 'calendar' then
    return app.admin_calendar((p_ ->> 'from')::timestamptz, (p_ ->> 'to')::timestamptz, nullif(p_ ->> 'vehicle', '')::uuid);
  when 'calendar_preview' then
    return app.calendar_preview_change((p_ ->> 'booking')::uuid, coalesce(p_ -> 'changes', '{}'::jsonb), now());
  when 'cancellation_preview' then
    return app.preview_cancellation((p_ ->> 'booking')::uuid, coalesce((p_ ->> 'at')::timestamptz, now()), coalesce(p_ ->> 'reason', 'renter_request'));
  when 'vehicles' then
    return (select coalesce(jsonb_agg(to_jsonb(v) || jsonb_build_object('name', app.vehicle_name(v.id),
              'owner_name', (select o.legal_name from owners o where o.id = v.owner_id),
              'listing_status', (select l.status from vehicle_listings l where l.vehicle_id = v.id),
              'slug', (select l.slug from vehicle_listings l where l.vehicle_id = v.id),
              'daily_rate_cents', (select r.daily_rate_cents from rate_cards r where r.vehicle_id = v.id and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now())),
              'next_booking', (select jsonb_build_object('booking_number', b.booking_number, 'pickup_at', b.pickup_at, 'status', b.status) from bookings b
                                where b.vehicle_id = v.id and b.status in ('confirmed', 'on_rent') and b.return_at > now() order by b.pickup_at limit 1),
              'tracker_seen', (select max(t.last_seen_at) from tracker_devices t where t.vehicle_id = v.id and t.removed_at is null))
              order by v.fleet_number nulls last, v.make, v.model), '[]'::jsonb) from vehicles v);
  when 'vehicle' then return app.admin_vehicle((p_ ->> 'id')::uuid);
  when 'listings' then
    return (select coalesce(jsonb_agg(to_jsonb(i) || jsonb_build_object('vehicle_name', app.vehicle_name(i.vehicle_id),
              'plate', (select v.plate from vehicles v where v.id = i.vehicle_id),
              'listing_status', (select l.status from vehicle_listings l where l.vehicle_id = i.vehicle_id),
              'photos', (select count(*) from vehicle_photos ph where ph.vehicle_id = i.vehicle_id and ph.replaced_at is null),
              'started_by_name', (select u.full_name from users u where u.id = i.started_by))
              order by case i.state when 'needs_review' then 0 when 'failed' then 1 when 'approved' then 2 else 3 end, i.updated_at desc), '[]'::jsonb)
              from listing_intakes i where i.state <> 'cancelled' and (i.state not in ('published') or i.updated_at > now() - interval '30 days'));
  when 'listing' then return app.admin_listing((p_ ->> 'id')::uuid);
  when 'settings' then return app.admin_settings();
  when 'bulk_rate_preview' then
    return (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from app.preview_bulk_rate_change(coalesce(p_ -> 'filter', '{}'::jsonb), p_ -> 'change') x);
  when 'tolls' then
    return jsonb_build_object(
      'queue', coalesce((select jsonb_agg(app.admin_enrich(to_jsonb(q)) order by q.age_days desc) from toll_work_queue q
                          where p_ ->> 'bucket' is null or q.bucket = p_ ->> 'bucket'), '[]'::jsonb),
      'summary', coalesce((select jsonb_agg(to_jsonb(s)) from toll_work_queue_summary s), '[]'::jsonb),
      'profiles', coalesce((select jsonb_agg(to_jsonb(x) order by x.operator, x.name) from toll_import_profiles x), '[]'::jsonb),
      'batches', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (select * from toll_import_batches order by created_at desc limit 10) x), '[]'::jsonb));
  when 'toll' then
    v_id := (p_ ->> 'id')::uuid;
    return (select app.admin_enrich(to_jsonb(t)) || jsonb_build_object(
              'candidates', case when t.vehicle_id is not null then app.match_toll_candidates(t.id) end,
              'statement', (select to_jsonb(s) from booking_statements s where s.id = t.booking_statement_id))
              from toll_tickets t where t.id = v_id);
  when 'toll_profile' then
    return (select to_jsonb(x) from app.find_toll_import_profile(p_ ->> 'operator', p_ ->> 'header_signature') x where x.id is not null);
  when 'damages' then
    return (select coalesce(jsonb_agg(app.admin_enrich(to_jsonb(q)) order by q.found_at desc), '[]'::jsonb) from damage_work_queue q);
  when 'damage' then
    v_id := (p_ ->> 'id')::uuid;
    return (select app.admin_enrich(to_jsonb(d)) || jsonb_build_object('candidates', app.match_damage_candidates(d.id),
              'before', (select to_jsonb(c) from condition_reports c where c.id = d.before_report_id),
              'after', (select to_jsonb(c) from condition_reports c where c.id = d.after_report_id),
              'reports', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'performed_at', c.performed_at,
                              'booking_number', (select b.booking_number from bookings b where b.id = c.booking_id)) order by c.performed_at desc)
                              from condition_reports c where c.vehicle_id = d.vehicle_id and c.performed_at > d.found_at - interval '60 days'), '[]'::jsonb),
              'threshold_cents', 250000)
              from damage_intakes d where d.id = v_id);
  when 'owner_statement' then
    return app.owner_statement_breakdown((p_ ->> 'id')::uuid, p_admin) || jsonb_build_object('row', (select app.admin_enrich(to_jsonb(s)) from owner_statements s where s.id = (p_ ->> 'id')::uuid));
  when 'company_statement' then
    v_month := app.month_start((p_ ->> 'month')::date);
    return (select jsonb_build_object('statement', to_jsonb(s),
              'total', (select to_jsonb(l) from company_statement_lines l where l.statement_id = s.id and l.level = 'total' limit 1),
              'owners', coalesce((select jsonb_agg(app.admin_enrich(to_jsonb(l)) order by l.owner_id) from company_statement_lines l where l.statement_id = s.id and l.level = 'owner'), '[]'::jsonb),
              'vehicles', coalesce((select jsonb_agg(app.admin_enrich(to_jsonb(l)) order by l.vehicle_id) from company_statement_lines l where l.statement_id = s.id and l.level = 'vehicle'), '[]'::jsonb))
              from company_statements s where s.statement_month = v_month);
  when 'csv' then
    return jsonb_build_object('csv', case p_ ->> 'kind'
      when 'company' then app.company_statement_csv(app.month_start((p_ ->> 'month')::date), coalesce(p_ ->> 'level', 'vehicle'))
      when 'ledger' then app.company_ledger_csv(app.month_start((p_ ->> 'month')::date))
      when 'owner_statement' then app.owner_statement_csv((p_ ->> 'id')::uuid) end);
  when 'reconciliation' then
    return (select coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object('items', coalesce((select jsonb_agg(app.admin_enrich(to_jsonb(i)) order by i.occurred_at)
              from payout_reconciliation_items i where i.reconciliation_id = r.id), '[]'::jsonb)) order by r.paid_on desc), '[]'::jsonb)
              from (select * from payout_reconciliations order by paid_on desc limit 30) r);
  when 'investor' then
    v_id := (p_ ->> 'id')::uuid;
    return (select to_jsonb(i) || jsonb_build_object(
              'investments', coalesce((select jsonb_agg(to_jsonb(x) order by x.investment_date) from investments x where x.investor_id = i.id), '[]'::jsonb),
              'returns', coalesce((select jsonb_agg(to_jsonb(r) order by r.return_month desc) from investment_returns r join investments x on x.id = r.investment_id where x.investor_id = i.id), '[]'::jsonb),
              'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'created_at', d.created_at)) from documents d where d.investor_id = i.id), '[]'::jsonb),
              'payouts', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from payouts x where x.investor_id = i.id), '[]'::jsonb))
              from investors i where i.id = v_id);
  when 'owner_records' then
    v_id := (p_ ->> 'id')::uuid;
    return jsonb_build_object(
      'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'created_at', d.created_at) order by d.created_at desc) from documents d where d.owner_id = v_id), '[]'::jsonb),
      'statements', coalesce((select jsonb_agg(to_jsonb(s) order by s.statement_month desc, s.version desc) from owner_statements s where s.owner_id = v_id), '[]'::jsonb),
      'payouts', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from payouts x where x.owner_id = v_id), '[]'::jsonb),
      'deductions', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from owner_deductions x where x.owner_id = v_id), '[]'::jsonb));
  else
    raise exception 'Unknown admin read %', p_what using errcode = '22023';
  end case;
end $$;

-- ================================================================ 5. actions
create or replace function app.admin_do(p_admin uuid, p_action text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  b bookings;
  v_id uuid;
  v_n integer;
  v_out jsonb;
  v_ids uuid[];
  v_month date;
  r record;
  v_rows jsonb;
begin
  perform app.admin_begin(p_admin);
  if p_ ? 'booking' then
    select * into b from bookings where id::text = p_ ->> 'booking' or booking_number = p_ ->> 'booking';
    if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  end if;
  case p_action
  -- ---------------------------------------------------------------- requests and bookings
  when 'booking_save' then
    perform app.admin_apply_booking_edit(p_admin, b.id, p_);
    if p_ ? 'internal_note' then update bookings set notes = nullif(btrim(p_ ->> 'internal_note'), '') where id = b.id; end if;
    return app.admin_booking_json(b.id);
  when 'send_offer' then
    if p_ ? 'changes' or p_ ? 'places' or p_ ? 'fee_terms' or p_ ? 'coverage_cents' or p_ ? 'promo_code' then
      perform app.admin_apply_booking_edit(p_admin, b.id, p_);
    end if;
    v_n := app.send_offer(b.id, p_admin, nullif(btrim(p_ ->> 'message'), ''), (p_ ->> 'expires_at')::timestamptz);
    return jsonb_build_object('version', v_n);
  when 'withdraw_offer' then
    perform app.withdraw_offer(b.id, p_admin, nullif(btrim(p_ ->> 'note'), ''));
  when 'resend_offer' then
    perform app.withdraw_offer(b.id, p_admin, 'Sent again with a later expiry');
    v_n := app.send_offer(b.id, p_admin, nullif(btrim(p_ ->> 'message'), ''), (p_ ->> 'expires_at')::timestamptz);
    return jsonb_build_object('version', v_n);
  when 'approve_offer_by_phone' then
    perform app.approve_offer(b.id, b.current_offer_version, p_admin, now());
  when 'ask_info' then
    v_id := app.ask_booking_info(b.id, p_admin, p_ ->> 'question', (p_ ->> 'reply_by')::timestamptz);
    return jsonb_build_object('id', v_id);
  when 'decline_request' then
    perform app.decline_booking_request(b.id, p_admin, nullif(btrim(p_ ->> 'note'), ''));
  when 'reopen_expired' then
    perform app.reopen_expired_request(b.id, p_admin, nullif(btrim(p_ ->> 'note'), ''));
  when 'blocks_calendar' then
    perform app.set_blocks_calendar(b.id, (p_ ->> 'blocks')::boolean, p_admin, p_ ->> 'reason');
  when 'cancel_booking' then
    return app.cancel_booking(b.id, p_admin, coalesce(p_ ->> 'reason', 'renter_request'), nullif(btrim(p_ ->> 'note'), ''),
                              coalesce(p_ ->> 'channel', 'email'), coalesce((p_ ->> 'at')::timestamptz, now()));
  when 'approve_change' then return app.approve_booking_change((p_ ->> 'request')::uuid, p_admin);
  when 'decline_change' then perform app.decline_booking_change((p_ ->> 'request')::uuid, p_admin, p_ ->> 'reason');
  when 'approve_extension' then return app.approve_extension((p_ ->> 'extension')::uuid, p_admin);
  when 'decline_extension' then perform app.decline_extension((p_ ->> 'extension')::uuid, p_admin, p_ ->> 'reason');
  when 'swap_vehicle' then
    v_id := app.swap_vehicle(b.id, (p_ ->> 'vehicle')::uuid, p_admin, p_ ->> 'reason', p_admin);
    return jsonb_build_object('swap_id', v_id);
  when 'calendar_apply' then
    return app.calendar_apply_change(b.id, p_admin, coalesce(p_ -> 'changes', '{}'::jsonb), p_ ->> 'reason',
                                     coalesce((p_ ->> 'renter_agreed')::boolean, false), nullif(btrim(p_ ->> 'message'), ''), now());
  when 'waive_deposit' then perform app.waive_deposit(b.id, p_admin, p_ ->> 'reason');
  when 'settle_deposit' then return app.settle_deposit(b.id, p_admin, coalesce(p_ -> 'plan', '{}'::jsonb), now());
  when 'issue_booking_statement' then
    v_id := app.issue_booking_statement(b.id, p_admin, now());
    return jsonb_build_object('statement_id', v_id);
  when 'draft_insurer_invoice' then
    v_id := app.draft_insurer_invoice(b.id, p_admin);
    return jsonb_build_object('id', v_id);
  when 'review_request_decide' then
    return app.decide_review_request(b.id, p_admin, (p_ ->> 'send')::boolean, nullif(btrim(p_ ->> 'note'), ''));
  when 'request_refund' then
    insert into refunds (booking_id, payment_id, reason, amount_cents, status, requested_by, note)
    values (b.id, coalesce((p_ ->> 'payment')::uuid, (select x.id from payments x where x.booking_id = b.id and x.status = 'succeeded' and x.kind in ('charge', 'capture') order by x.created_at desc limit 1)),
            coalesce(p_ ->> 'reason', 'other'), (p_ ->> 'amount_cents')::bigint, 'pending_approval', p_admin, nullif(btrim(p_ ->> 'note'), ''))
    returning id into v_id;
    return jsonb_build_object('id', v_id);

  -- ---------------------------------------------------------------- calendar blocks
  when 'block_create' then
    if (p_ ->> 'reason') = 'admin' and nullif(btrim(p_ ->> 'note'), '') is null then
      raise exception 'Say why the car is blocked (a note is required for an admin block)' using errcode = '22023';
    end if;
    select jsonb_agg(jsonb_build_object('booking_number', x.booking_number, 'status', x.status, 'pickup_at', x.pickup_at, 'return_at', x.return_at))
      into v_rows from bookings x
     where x.vehicle_id = (p_ ->> 'vehicle')::uuid and x.blocks_calendar and x.status in ('confirmed', 'on_rent')
       and x.pickup_at < coalesce((p_ ->> 'ends_at')::timestamptz, 'infinity') and x.return_at > (p_ ->> 'starts_at')::timestamptz;
    if v_rows is not null and not coalesce((p_ ->> 'force')::boolean, false) then
      return jsonb_build_object('conflicts', v_rows);
    end if;
    insert into vehicle_calendar_blocks (vehicle_id, reason, starts_at, ends_at, note, created_by)
    values ((p_ ->> 'vehicle')::uuid, p_ ->> 'reason', (p_ ->> 'starts_at')::timestamptz, (p_ ->> 'ends_at')::timestamptz, nullif(btrim(p_ ->> 'note'), ''), p_admin)
    returning id into v_id;
    for r in select x.id, x.booking_number from bookings x
              where x.vehicle_id = (p_ ->> 'vehicle')::uuid and x.blocks_calendar and x.status in ('confirmed', 'on_rent')
                and x.pickup_at < coalesce((p_ ->> 'ends_at')::timestamptz, 'infinity') and x.return_at > (p_ ->> 'starts_at')::timestamptz loop
      perform app.raise_task('calendar_block_conflict', format('Block over booking %s: move the renter to another car', r.booking_number),
                             p_ ->> 'note', r.id, (p_ ->> 'vehicle')::uuid, null, null, 'vehicle_calendar_blocks', v_id, null, 'urgent',
                             'block_conflict:' || v_id || ':' || r.id, 'fleet', p_admin);
    end loop;
    return jsonb_build_object('id', v_id, 'conflicts', coalesce(v_rows, '[]'::jsonb));
  when 'block_update' then
    update vehicle_calendar_blocks set starts_at = coalesce((p_ ->> 'starts_at')::timestamptz, starts_at),
           ends_at = case when p_ ? 'ends_at' then (p_ ->> 'ends_at')::timestamptz else ends_at end,
           note = case when p_ ? 'note' then nullif(btrim(p_ ->> 'note'), '') else note end
     where id = (p_ ->> 'block')::uuid and removed_at is null;
    if not found then raise exception 'That block is not there any more' using errcode = 'P0002'; end if;
  when 'block_end' then
    update vehicle_calendar_blocks set ends_at = greatest(now(), starts_at + interval '1 minute') where id = (p_ ->> 'block')::uuid and removed_at is null;
  when 'block_remove' then
    if nullif(btrim(p_ ->> 'reason'), '') is null then raise exception 'Give the reason for removing the block' using errcode = '22023'; end if;
    update vehicle_calendar_blocks set removed_at = now(), removed_by = p_admin, removed_reason = btrim(p_ ->> 'reason')
     where id = (p_ ->> 'block')::uuid and removed_at is null;
    if not found then raise exception 'That block is not there any more' using errcode = 'P0002'; end if;
  when 'field_job_create' then
    v_id := app.create_field_job(p_ ->> 'kind', (p_ ->> 'vehicle')::uuid, (p_ ->> 'scheduled_at')::timestamptz, p_admin, b.id,
                                 nullif(p_ ->> 'assigned_to', '')::uuid, nullif(btrim(p_ ->> 'place'), ''), nullif(btrim(p_ ->> 'instructions'), ''));
    return jsonb_build_object('id', v_id);

  -- ---------------------------------------------------------------- fleet
  when 'rate_card' then
    v_id := app.set_rate_card((p_ ->> 'vehicle')::uuid, (p_ ->> 'daily_rate_cents')::bigint, (p_ ->> 'weekend_rate_cents')::bigint,
                              (p_ ->> 'weekly_rate_cents')::bigint, (p_ ->> 'monthly_rate_cents')::bigint,
                              coalesce((p_ ->> 'effective_from')::timestamptz, now()), p_admin, coalesce(p_ -> 'other', '{}'::jsonb));
    return jsonb_build_object('id', v_id);
  when 'fee_override' then
    v_id := app.set_vehicle_fee_override((p_ ->> 'vehicle')::uuid, p_ ->> 'fee', p_admin, p_ ->> 'reason', (p_ ->> 'amount_cents')::bigint,
                                         (p_ ->> 'cap_cents')::bigint, (p_ ->> 'percent_bps')::integer, coalesce((p_ ->> 'effective_from')::date, app.today()));
    return jsonb_build_object('id', v_id);
  when 'fee_override_end' then
    v_n := app.end_vehicle_fee_override((p_ ->> 'vehicle')::uuid, p_ ->> 'fee', p_admin, coalesce((p_ ->> 'on')::date, app.today()));
    return jsonb_build_object('ended', v_n);
  when 'vehicle_classes' then
    return to_jsonb(app.set_vehicle_classes((p_ ->> 'vehicle')::uuid, p_admin, array(select jsonb_array_elements_text(p_ -> 'classes'))));
  when 'vehicle_save' then
    if exists (select 1 from jsonb_object_keys(coalesce(p_ -> 'values', '{}'::jsonb)) k
                where k not in ('plate', 'colour', 'odometer_km', 'trim', 'allows_18_to_20', 'bookings_enabled', 'home_location', 'fleet_number', 'class',
                                'owner_pickup_address')) then
      raise exception 'Those vehicle fields are changed through their own steps' using errcode = '22023';
    end if;
    update vehicles v set plate = coalesce(x.plate, v.plate), colour = coalesce(x.colour, v.colour), odometer_km = coalesce(x.odometer_km, v.odometer_km),
           trim = case when p_ -> 'values' ? 'trim' then x.trim else v.trim end, allows_18_to_20 = coalesce(x.allows_18_to_20, v.allows_18_to_20),
           bookings_enabled = coalesce(x.bookings_enabled, v.bookings_enabled), home_location = case when p_ -> 'values' ? 'home_location' then x.home_location else v.home_location end,
           fleet_number = case when p_ -> 'values' ? 'fleet_number' then x.fleet_number else v.fleet_number end, class = coalesce(x.class, v.class),
           owner_pickup_address = case when p_ -> 'values' ? 'owner_pickup_address' then x.owner_pickup_address else v.owner_pickup_address end
      from jsonb_populate_record(null::vehicles, p_ -> 'values') x
     where v.id = (p_ ->> 'vehicle')::uuid;
  when 'vehicle_status' then
    update vehicles set status = (p_ ->> 'status')::vehicle_status where id = (p_ ->> 'vehicle')::uuid;
  when 'vehicle_deposit' then
    v_id := app.set_vehicle_deposit((p_ ->> 'vehicle')::uuid, p_admin, (p_ ->> 'amount_cents')::bigint, now());
    return jsonb_build_object('id', v_id);
  when 'bulk_rate_apply' then
    v_n := app.apply_bulk_rate_change(coalesce(p_ -> 'filter', '{}'::jsonb), p_ -> 'change', p_admin, coalesce((p_ ->> 'effective_from')::timestamptz, now()));
    return jsonb_build_object('changed', v_n,
      'slugs', (select coalesce(jsonb_agg(l.slug), '[]'::jsonb) from vehicle_listings l where l.vehicle_id in (select app.bulk_rate_vehicles(coalesce(p_ -> 'filter', '{}'::jsonb)))));
  when 'fee_change_notice' then
    v_id := app.give_fee_change_notice((p_ ->> 'vehicle')::uuid, p_admin, (p_ ->> 'insurance_fee_cents')::bigint, (p_ ->> 'tracker_fee_cents')::bigint,
                                       (p_ ->> 'effective_from')::date, nullif(btrim(p_ ->> 'reason'), ''));
    return jsonb_build_object('id', v_id);

  -- ---------------------------------------------------------------- listings
  when 'listing_start' then
    return app.start_listing_intake(p_admin, p_ - 'booking');
  when 'listing_review' then
    return app.review_listing(p_admin, (p_ ->> 'intake')::uuid, (p_ ->> 'approve')::boolean, coalesce(p_ -> 'edits', '{}'::jsonb), nullif(btrim(p_ ->> 'note'), ''));
  when 'listing_classes' then
    return to_jsonb(app.review_listing_classes((p_ ->> 'draft')::uuid, p_admin, (p_ ->> 'approve')::boolean,
                                               case when p_ ? 'classes' then array(select jsonb_array_elements_text(p_ -> 'classes')) end));
  when 'listing_publish' then return app.publish_listing((p_ ->> 'vehicle')::uuid, p_admin);
  when 'listing_unlist' then return app.unlist_listing((p_ ->> 'vehicle')::uuid, p_admin, p_ ->> 'reason', nullif(btrim(p_ ->> 'to_path'), ''));
  when 'listing_retry' then return app.retry_listing_intake(p_admin, (p_ ->> 'intake')::uuid);

  -- ---------------------------------------------------------------- staff
  when 'staff_add' then
    insert into users (id, email, full_name, status) values ((p_ ->> 'user_id')::uuid, lower(btrim(p_ ->> 'email')), btrim(p_ ->> 'full_name'), 'active')
    on conflict (id) do update set full_name = excluded.full_name, status = 'active';
    insert into user_roles (user_id, role, granted_by) values ((p_ ->> 'user_id')::uuid, (p_ ->> 'role')::app_role, p_admin) on conflict do nothing;
    if p_ ->> 'role' in ('va', 'field') then
      insert into staff_profiles (user_id, staff_type, va_function, field_function, started_on, is_active)
      values ((p_ ->> 'user_id')::uuid, p_ ->> 'role', nullif(p_ ->> 'va_function', '')::va_function, nullif(p_ ->> 'field_function', '')::field_function,
              coalesce((p_ ->> 'started_on')::date, app.today()), true)
      on conflict (user_id) do update set is_active = true, ended_on = null, va_function = excluded.va_function, field_function = excluded.field_function;
    end if;
    return jsonb_build_object('user_id', p_ ->> 'user_id');
  when 'staff_end' then
    if (p_ ->> 'user')::uuid = p_admin then raise exception 'You cannot end your own access' using errcode = '23514'; end if;
    update staff_profiles set is_active = false, ended_on = app.today() where user_id = (p_ ->> 'user')::uuid;
    update users set status = 'suspended' where id = (p_ ->> 'user')::uuid;
    if not found then raise exception 'That person is not on file' using errcode = 'P0002'; end if;
  when 'staff_restore' then
    update users set status = 'active' where id = (p_ ->> 'user')::uuid;
    update staff_profiles set is_active = true, ended_on = null where user_id = (p_ ->> 'user')::uuid;

  -- ---------------------------------------------------------------- money
  when 'refund_approve' then
    update refunds set status = 'approved', approved_by = p_admin, approved_at = now() where id = (p_ ->> 'id')::uuid and status = 'pending_approval';
    if not found then raise exception 'That refund is not waiting for approval' using errcode = '23514'; end if;
  when 'refund_reject' then
    if nullif(btrim(p_ ->> 'reason'), '') is null then raise exception 'Give the reason' using errcode = '22023'; end if;
    update refunds set status = 'rejected', note = concat_ws(' | ', note, 'Rejected: ' || btrim(p_ ->> 'reason')) where id = (p_ ->> 'id')::uuid and status = 'pending_approval';
    if not found then raise exception 'That refund is not waiting for approval' using errcode = '23514'; end if;
  when 'payout_approve' then
    select * into r from payouts where id = (p_ ->> 'id')::uuid for update;
    if r.id is null or r.status not in ('draft', 'pending_approval') then raise exception 'That payout is not waiting for approval' using errcode = '23514'; end if;
    if r.requires_both_principals and r.approved_by is null then
      update payouts set approved_by = p_admin, approved_at = now(), status = 'pending_approval' where id = r.id;
      return jsonb_build_object('status', 'pending_approval', 'needs', 'a second Admin');
    elsif r.requires_both_principals then
      update payouts set second_approved_by = p_admin, status = 'approved' where id = r.id;
    else
      update payouts set approved_by = p_admin, approved_at = now(), status = 'approved' where id = r.id;
    end if;
  when 'payout_paid' then
    select * into r from payouts where id = (p_ ->> 'id')::uuid;
    if r.id is null then raise exception 'Payout not found' using errcode = 'P0002'; end if;
    if nullif(btrim(p_ ->> 'reference'), '') is null then raise exception 'Enter the transfer reference' using errcode = '22023'; end if;
    if r.owner_statement_id is not null then
      v_id := app.record_owner_payout(r.owner_statement_id, p_admin, btrim(p_ ->> 'reference'), coalesce((p_ ->> 'paid_at')::timestamptz, now()));
    else
      update payouts set status = 'paid', reference = btrim(p_ ->> 'reference'), paid_at = coalesce((p_ ->> 'paid_at')::timestamptz, now())
       where id = r.id and status in ('approved', 'sent');
      if not found then raise exception 'Approve the payout first' using errcode = '23514'; end if;
    end if;
  when 'payout_cancel' then
    update payouts set status = 'cancelled', failure_reason = p_ ->> 'reason' where id = (p_ ->> 'id')::uuid and status in ('draft', 'pending_approval', 'approved');
  when 'owner_invoices_run' then
    v_n := app.generate_owner_invoices(app.month_start(coalesce((p_ ->> 'month')::date, app.today())), p_admin);
    return jsonb_build_object('issued', v_n);
  when 'statement_build' then
    v_id := app.build_owner_statement((p_ ->> 'owner')::uuid, app.month_start((p_ ->> 'month')::date), p_admin);
    return jsonb_build_object('id', v_id);
  when 'statements_build_all' then
    v_month := app.month_start((p_ ->> 'month')::date);
    v_n := 0; v_rows := '{}'::jsonb;
    for r in select o.id, o.legal_name from owners o
              where o.status in ('active', 'in_default', 'exited')
                and exists (select 1 from vehicles v where v.owner_id = o.id and v.enrollment_date is not null and v.enrollment_date < v_month + interval '1 month')
                and not exists (select 1 from owner_statements s where s.owner_id = o.id and s.statement_month = v_month and s.status <> 'draft')
              order by o.legal_name loop
      begin
        perform app.build_owner_statement(r.id, v_month, p_admin);
        v_n := v_n + 1;
      exception when others then
        v_rows := v_rows || jsonb_build_object(r.legal_name, sqlerrm);
      end;
    end loop;
    return jsonb_build_object('built', v_n, 'errors', v_rows);
  when 'statement_approve' then
    v_id := app.approve_owner_statement((p_ ->> 'id')::uuid, p_admin);
    return jsonb_build_object('payout_id', v_id);
  when 'statement_issue' then perform app.issue_owner_statement((p_ ->> 'id')::uuid, p_admin, null, now());
  when 'statement_reissue' then
    v_id := app.reissue_owner_statement((p_ ->> 'id')::uuid, p_admin, p_ ->> 'reason');
    return jsonb_build_object('id', v_id);
  when 'company_build' then
    v_id := app.build_company_statement(app.month_start((p_ ->> 'month')::date), p_admin);
    return (select jsonb_build_object('id', s.id, 'ties_ok', s.ties_ok, 'tie_problems', s.tie_problems) from company_statements s where s.id = v_id);
  when 'company_finalize' then
    v_id := app.finalize_company_statement(app.month_start((p_ ->> 'month')::date), p_admin);
    return jsonb_build_object('id', v_id);
  when 'expense_void' then
    if nullif(btrim(p_ ->> 'reason'), '') is null then raise exception 'Give the reason' using errcode = '22023'; end if;
    update company_expenses set voided_at = now(), void_reason = btrim(p_ ->> 'reason') where id = (p_ ->> 'id')::uuid and voided_at is null;
  when 'insurer_invoice_send' then
    update insurer_invoices set status = 'sent', sent_at = now(), sent_by = p_admin where id = (p_ ->> 'id')::uuid and status = 'draft';
    if not found then raise exception 'Only a draft is sent' using errcode = '23514'; end if;
  when 'insurer_payment' then
    return jsonb_build_object('status', app.record_insurer_payment((p_ ->> 'id')::uuid, (p_ ->> 'amount_cents')::bigint, p_admin,
                              coalesce(p_ ->> 'method', 'bank_transfer'), coalesce((p_ ->> 'paid_at')::timestamptz, now()), nullif(btrim(p_ ->> 'reference'), '')));
  when 'insurer_write_off' then
    if nullif(btrim(p_ ->> 'reason'), '') is null then raise exception 'Give the reason' using errcode = '22023'; end if;
    update insurer_invoices set status = 'written_off', written_off_at = now(), written_off_by = p_admin, written_off_reason = btrim(p_ ->> 'reason')
     where id = (p_ ->> 'id')::uuid and status in ('sent', 'part_paid');
    if not found then raise exception 'Only a sent invoice is written off' using errcode = '23514'; end if;
  when 'dispute_submitted' then
    update disputes set evidence_submitted_at = now() where id = (p_ ->> 'id')::uuid;
  when 'reconcile_record' then
    v_id := app.record_processor_payout(p_ ->> 'payout_ref', (p_ ->> 'paid_on')::date, (p_ ->> 'amount_cents')::bigint,
                                        coalesce(p_ -> 'items', '[]'::jsonb), coalesce(p_ ->> 'processor', 'stripe'), p_admin);
    return jsonb_build_object('id', v_id);
  when 'reconcile_match' then
    return jsonb_build_object('status', app.match_payout_item((p_ ->> 'item')::uuid, p_admin, nullif(p_ ->> 'payment', '')::uuid, nullif(btrim(p_ ->> 'note'), '')));

  -- ---------------------------------------------------------------- tolls, tickets and damage
  when 'toll_log' then
    v_id := app.log_toll_ticket(p_ -> 'row', p_admin);
    return (select app.admin_enrich(to_jsonb(t)) from toll_tickets t where t.id = v_id);
  when 'toll_import' then return app.import_toll_batch(p_ -> 'batch', p_admin);
  when 'toll_profile_save' then
    v_id := app.save_toll_import_profile(p_ -> 'profile', p_admin);
    return jsonb_build_object('id', v_id);
  when 'toll_confirm' then perform app.confirm_toll_match((p_ ->> 'id')::uuid, p_admin, p_ -> 'choice');
  when 'toll_bulk_confirm' then
    return app.bulk_confirm_toll_matches(array(select jsonb_array_elements_text(p_ -> 'ids'))::uuid[], p_admin);
  when 'toll_charge' then
    return app.charge_toll_ticket(array(select jsonb_array_elements_text(p_ -> 'ids'))::uuid[], p_admin, now());
  when 'toll_bill_owner' then
    v_id := app.bill_toll_to_owner((p_ ->> 'id')::uuid, p_admin);
    return jsonb_build_object('id', v_id);
  when 'toll_dispute' then perform app.dispute_toll_ticket((p_ ->> 'id')::uuid, p_admin, p_ ->> 'reason');
  when 'toll_close' then perform app.close_toll_ticket((p_ ->> 'id')::uuid, p_admin, p_ ->> 'reason');
  when 'toll_rematch' then return app.run_toll_match((p_ ->> 'id')::uuid, p_admin);
  when 'toll_company_paid' then
    perform app.mark_toll_company_paid((p_ ->> 'id')::uuid, p_admin, p_ ->> 'reference', coalesce((p_ ->> 'paid_at')::timestamptz, now()), nullif(btrim(p_ ->> 'note'), ''));
  when 'toll_authority_paid' then
    perform app.record_toll_authority_payment((p_ ->> 'id')::uuid, p_admin, p_ ->> 'reference', coalesce((p_ ->> 'paid_at')::timestamptz, now()));
  when 'damage_log' then
    v_id := app.log_damage(p_ -> 'damage', p_admin);
    return jsonb_build_object('id', v_id);
  when 'damage_confirm' then perform app.confirm_damage_match((p_ ->> 'id')::uuid, p_admin, p_ -> 'choice');
  when 'damage_bill' then return app.bill_damage((p_ ->> 'id')::uuid, p_admin, now(), nullif(btrim(p_ ->> 'override_reason'), ''));

  -- ---------------------------------------------------------------- incidents, claims, tasks
  when 'incident_open' then
    v_id := app.open_incident(p_ ->> 'kind', (p_ ->> 'vehicle')::uuid, p_admin, coalesce(p_ -> 'details', '{}'::jsonb), b.id, 'staff', now());
    return jsonb_build_object('id', v_id);
  when 'claim_open' then
    v_id := app.open_claim((p_ ->> 'incident')::uuid, p_admin);
    return jsonb_build_object('id', v_id);
  when 'claim_status' then
    update claims set status = p_ ->> 'status', denied_reason = case when p_ ->> 'status' = 'denied' then p_ ->> 'reason' else denied_reason end
     where id = (p_ ->> 'id')::uuid;
  when 'claim_settle' then perform app.settle_claim((p_ ->> 'id')::uuid, p_admin, nullif(p_ ->> 'second_admin', '')::uuid);
  when 'task_assign' then perform app.assign_task((p_ ->> 'id')::uuid, coalesce(nullif(p_ ->> 'to', '')::uuid, p_admin), p_admin);
  when 'task_snooze' then perform app.snooze_task((p_ ->> 'id')::uuid, p_admin, (p_ ->> 'until')::timestamptz, coalesce(nullif(btrim(p_ ->> 'reason'), ''), 'Snoozed'));
  when 'task_complete' then perform app.complete_task((p_ ->> 'id')::uuid, p_admin, nullif(btrim(p_ ->> 'note'), ''), coalesce((p_ ->> 'force')::boolean, false));
  when 'task_escalate' then
    v_id := app.escalate_task((p_ ->> 'id')::uuid, p_admin, p_ ->> 'reason');
    return jsonb_build_object('id', v_id);
  when 'task_cancel' then perform app.cancel_task((p_ ->> 'id')::uuid, p_admin, p_ ->> 'reason');

  -- ---------------------------------------------------------------- reviews, messages
  when 'review_publish' then
    update reviews set status = 'published', published_at = coalesce(published_at, now()), moderated_by = p_admin where id = (p_ ->> 'id')::uuid;
    return (select jsonb_build_object('slug', l.slug) from reviews rv join vehicle_listings l on l.vehicle_id = rv.vehicle_id where rv.id = (p_ ->> 'id')::uuid);
  when 'review_hide' then
    if coalesce(p_ ->> 'reason', '') not in ('personal_information', 'abusive', 'not_about_the_rental') then
      raise exception 'Hide a review only for personal information, abuse, or when it is not about the rental' using errcode = '22023';
    end if;
    update reviews set status = 'hidden', moderated_by = p_admin where id = (p_ ->> 'id')::uuid;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_admin, 'hide_review', 'reviews', p_ ->> 'id', jsonb_build_object('reason', p_ ->> 'reason'));
    return (select jsonb_build_object('slug', l.slug) from reviews rv join vehicle_listings l on l.vehicle_id = rv.vehicle_id where rv.id = (p_ ->> 'id')::uuid);
  when 'review_reply' then
    update reviews set staff_reply = nullif(btrim(p_ ->> 'reply'), ''), staff_reply_by = p_admin, staff_reply_at = now() where id = (p_ ->> 'id')::uuid;
  when 'outbox_resend' then
    select * into r from notification_outbox where id = (p_ ->> 'id')::uuid;
    if r.id is null then raise exception 'Message not found' using errcode = 'P0002'; end if;
    if r.status in ('failed', 'delayed') then
      update notification_outbox set status = 'queued', attempts = 0, send_after = now(), last_error = null, locked_at = null where id = r.id;
      return jsonb_build_object('id', r.id);
    end if;
    insert into notification_outbox
    select (jsonb_populate_record(o, jsonb_build_object('id', gen_random_uuid(), 'status', 'queued', 'status_reason', 'resent by an Admin', 'attempts', 0,
              'send_after', now(), 'locked_at', null, 'provider_id', null, 'sent_at', null, 'last_error', null, 'message_id', null,
              'dedupe_key', o.dedupe_key || ':resend:' || extract(epoch from now())::bigint,
              'unsubscribe_token', case when o.unsubscribe_token is not null then gen_random_uuid() end,
              'created_at', now(), 'updated_at', now()))).*
      from notification_outbox o where o.id = r.id
    returning id into v_id;
    return jsonb_build_object('id', v_id);
  when 'outbox_cancel' then
    update notification_outbox set status = 'skipped', status_reason = 'cancelled by an Admin' where id = (p_ ->> 'id')::uuid and status in ('queued', 'delayed');
    if not found then raise exception 'Only a queued message is cancelled' using errcode = '23514'; end if;
  when 'suppression_lift' then
    if nullif(btrim(p_ ->> 'reason'), '') is null then raise exception 'Give the reason' using errcode = '22023'; end if;
    update email_suppressions set lifted_at = now(), lifted_by = p_admin, lift_reason = btrim(p_ ->> 'reason') where id = (p_ ->> 'id')::uuid and lifted_at is null;
  when 'suppression_add' then
    insert into email_suppressions (email, scope, reason, detail, created_by)
    values (lower(btrim(p_ ->> 'email')), coalesce(p_ ->> 'scope', 'all'), 'manual', nullif(btrim(p_ ->> 'detail'), ''), p_admin)
    returning id into v_id;
    return jsonb_build_object('id', v_id);
  when 'investor_returns_accrue' then
    return jsonb_build_object('accrued', app.accrue_investment_returns(app.month_start((p_ ->> 'month')::date)));
  else
    raise exception 'Unknown admin action %', p_action using errcode = '22023';
  end case;
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ 6. the API
create or replace function public.admin_list(p_admin uuid, p_rel text, p jsonb default '{}'::jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.admin_list(p_admin, p_rel, p) $$;
create or replace function public.admin_read(p_admin uuid, p_what text, p jsonb default '{}'::jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.admin_read(p_admin, p_what, p) $$;
create or replace function public.admin_save(p_admin uuid, p_table text, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.admin_save(p_admin, p_table, p) $$;
create or replace function public.admin_do(p_admin uuid, p_action text, p jsonb default '{}'::jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.admin_do(p_admin, p_action, p) $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['admin_begin', 'admin_enrich', 'admin_list', 'admin_save', 'admin_booking_json',
              'admin_booking_detail', 'admin_apply_booking_edit', 'admin_booking_preview', 'admin_dashboard', 'admin_requests', 'admin_calendar',
              'admin_vehicle', 'admin_listing', 'admin_settings', 'admin_read', 'admin_do']))
        or (n.nspname = 'public' and p.proname = any (array['admin_list', 'admin_read', 'admin_save', 'admin_do']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
