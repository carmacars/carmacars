-- 3102 (release 48, part MR; docs/changes/2026-11-20-r48-money-rules.md): speeding charges and named fees added by line.
--
-- 1. Speeding charges (rental agreement section 10.5, a new text version; agreements already signed keep theirs and
--    nobody is asked to sign again): three separate charges, each with its Program setting for the amount:
--      speeding_180  over 180 km/h   speeding_180_fee_cents   ($500 by default)
--      speeding_220  over 220 km/h   speeding_220_fee_cents   ($1,000)
--      speeding_300  over 300 km/h   speeding_300_fee_cents   ($2,500)
--    app.speeding_charge_add (Admin or Finance): one charge per tracker reading, only with the tracker's evidence (a
--    reading of the booking's car during the rental above the limit, from tracker_points or a tracker alert), kept on
--    the line (supporting_refs). After the return it is billed like damage: on a statement, from the deposit first.
-- 2. change_booking_fees (the connector) refused every line shape for adding a fee to a returned booking: the tool
--    said lines is a list, the database took only {key: cents}. It now also takes a list of named fees:
--      lines: [{"op": "add", "fee": "smoking", "amount_cents": 30000, "note": "..."}]
--    (op or action; fee, fee_code, kind or code). Named fees: smoking, cleaning, cleaning_heavy, pet_cleaning, late,
--    km, fuel, ticket, toll, damage (damage needs photos or a document, as Bill damage does). The amount is before HST;
--    empty takes the standard amount of the fee. After the return the fee is billed from the deposit first.
-- No applied migration is edited: app.booking_fees_change and app.door are wrapped (_pre3102).
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

-- ================================================================ 1. speeding
alter table program_settings
  add column if not exists speeding_180_fee_cents bigint not null default 50000 check (speeding_180_fee_cents >= 0),
  add column if not exists speeding_220_fee_cents bigint not null default 100000 check (speeding_220_fee_cents >= 0),
  add column if not exists speeding_300_fee_cents bigint not null default 250000 check (speeding_300_fee_cents >= 0);
comment on column program_settings.speeding_180_fee_cents is 'Speeding charge, over 180 km/h (3102), before HST: one charge per tracker reading, billed from the deposit (rental agreement 10.5)';
comment on column program_settings.speeding_220_fee_cents is 'Speeding charge, over 220 km/h (3102), before HST: one charge per tracker reading, billed from the deposit (rental agreement 10.5)';
comment on column program_settings.speeding_300_fee_cents is 'Speeding charge, over 300 km/h (3102), before HST: one charge per tracker reading, billed from the deposit (rental agreement 10.5)';

insert into fee_types (code, label, family, unit, per_what, revenue_class, hst_applies, hst_as_invoiced, stage, refundable_by_tier, change_default, change_vehicle, change_booking, in_master_spec, sort_order, gl_account)
values ('speeding_180', 'Speeding over 180 km/h (tracker record)', 'fee', 'flat', 'item', 'company_only', true, false, 'after_return', false, false, false, true, true, 205, '4120'),
       ('speeding_220', 'Speeding over 220 km/h (tracker record)', 'fee', 'flat', 'item', 'company_only', true, false, 'after_return', false, false, false, true, true, 206, '4120'),
       ('speeding_300', 'Speeding over 300 km/h (tracker record)', 'fee', 'flat', 'item', 'company_only', true, false, 'after_return', false, false, false, true, true, 207, '4120')
on conflict (code) do nothing;

-- p: {booking, over: 180 | 220 | 300, at (the reading's time), alert_id (a tracker alert instead of at), note}
create function app.speeding_charge_add(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  s program_settings := app.settings();
  v_over integer := nullif(p ->> 'over', '')::integer;
  v_code text;
  v_amount bigint;
  v_at timestamptz := nullif(p ->> 'at', '')::timestamptz;
  v_end timestamptz;
  v_speed integer;
  v_lat numeric;
  v_lng numeric;
  a tracker_alerts;
  v_key text;
  v_line uuid;
  v_res jsonb;
  v_desc text;
begin
  if not (app.user_is_admin(p_by) or app.user_runs_finance(p_by)) then raise exception 'An Admin or Finance adds a speeding charge' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.booking_type::text = 'owner' then raise exception 'An Owner Booking has no renter charges' using errcode = '23514'; end if;
  if b.status::text not in ('on_rent', 'returned', 'closed') then raise exception 'A speeding charge is for a car that was handed over' using errcode = '23514'; end if;
  v_code := case v_over when 180 then 'speeding_180' when 220 then 'speeding_220' when 300 then 'speeding_300' end;
  if v_code is null then raise exception 'Choose the limit: over 180, over 220 or over 300 km/h' using errcode = '22023'; end if;
  v_amount := case v_over when 180 then s.speeding_180_fee_cents when 220 then s.speeding_220_fee_cents else s.speeding_300_fee_cents end;
  if coalesce(v_amount, 0) <= 0 then raise exception 'The speeding charge over % km/h is $0 in Program settings', v_over using errcode = '23514'; end if;
  v_end := coalesce(b.checked_in_at, greatest(b.return_at, now()));
  -- the tracker's evidence: an alert of the car, or the fastest reading within two minutes of the time given
  if nullif(p ->> 'alert_id', '') is not null then
    select * into a from tracker_alerts where id = (p ->> 'alert_id')::uuid;
    if a.id is null or a.vehicle_id is distinct from b.vehicle_id then raise exception 'That tracker alert is not of this booking''s car' using errcode = '22023'; end if;
    v_at := a.at; v_speed := a.speed_kmh; v_lat := a.lat; v_lng := a.lng;
  elsif v_at is not null then
    select t.speed_kmh, t.lat_e6 / 1e6, t.lng_e6 / 1e6, t.at into v_speed, v_lat, v_lng, v_at from tracker_points t
     where t.vehicle_id = b.vehicle_id and t.at between v_at - interval '2 minutes' and v_at + interval '2 minutes' and t.speed_kmh is not null
     order by t.speed_kmh desc, t.at limit 1;
  else
    raise exception 'Give the tracker reading: its time (at) or the tracker alert' using errcode = '22023';
  end if;
  if v_speed is null then raise exception 'The tracker has no speed reading of this car at that time: the charge needs the tracker''s record' using errcode = '23514'; end if;
  if v_at < b.handed_over_at or v_at < b.pickup_at or v_at > v_end then raise exception 'That reading is outside the rental' using errcode = '23514'; end if;
  if v_speed <= v_over then raise exception 'The tracker read % km/h then: not over %', v_speed, v_over using errcode = '23514'; end if;
  v_key := 'speeding:' || v_over || ':' || to_char(v_at at time zone 'UTC', 'YYYYMMDDHH24MISS');
  if exists (select 1 from booking_line_items li where li.booking_id = b.id and li.assessment_key = v_key and li.voided_at is null) then
    raise exception 'This reading is already charged' using errcode = '23514';
  end if;
  v_desc := format('Speeding over %s km/h: %s km/h on %s (tracker record)', v_over, v_speed, to_char(v_at at time zone 'America/Toronto', 'Mon FMDD, YYYY "at" FMHH12:MI a.m.'));
  v_line := app.set_assessed_line(b.id, v_key, v_code, 1, v_amount, v_amount, v_desc,
    jsonb_strip_nulls(jsonb_build_object('kind', 'speeding', 'over_kmh', v_over, 'speed_kmh', v_speed, 'at', v_at, 'lat', v_lat, 'lng', v_lng,
                                         'alert_id', a.id, 'note', nullif(btrim(coalesce(p ->> 'note', '')), ''), 'added_by', p_by)), p_by);
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('%s: %s plus HST', v_desc, app.fmt_money(v_amount)), p_by, 'staff', jsonb_build_object('line_item_id', v_line, 'speed_kmh', v_speed, 'at', v_at));
  if b.status::text in ('returned', 'closed') then
    if exists (select 1 from booking_statements x where x.booking_id = b.id and x.kind = 'check_in') then
      v_res := app.charge_after_rental(b.id, p_by, now());
      perform app.emit_event('renter_extra_charge', 'booking_line_item', v_line,
        jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'renter_id', b.renter_id, 'charge_kind', 'speeding', 'line_item_id', v_line,
                           'charge_type', v_code, 'amount_cents', v_amount, 'hst_cents', public.calc_hst(v_amount, b.hst_bps), 'total_cents', v_amount + public.calc_hst(v_amount, b.hst_bps),
                           'document_ids', '[]'::jsonb, 'charged_from', case when (select d.status from deposits d where d.booking_id = b.id) in ('held', 'captured') then 'deposit' else 'card_on_file' end),
        'renter_extra_charge:' || v_line || ':speeding');
    end if;
    begin perform app.compute_booking_split(b.id); exception when others then null; end;
  end if;
  return jsonb_build_object('ok', true, 'line_item_id', v_line, 'amount_cents', v_amount, 'speed_kmh', v_speed, 'at', v_at, 'charged', v_res,
    'billed', case when v_res is not null then 'from the deposit first, then the card on file' else 'on the Check-out statement, from the deposit first' end);
end $$;

-- ================================================================ 2. a named fee added by line
create function app.named_fee_code(p_name text) returns text
language sql immutable as $$
  select case lower(btrim(coalesce(p_name, '')))
    when 'smoking' then 'smoking' when 'smoke' then 'smoking'
    when 'cleaning' then 'cleaning' when 'cleaning_heavy' then 'cleaning_heavy' when 'heavy_cleaning' then 'cleaning_heavy' when 'pet_cleaning' then 'pet_cleaning'
    when 'late' then 'late_return_fee' when 'late_return' then 'late_return_fee' when 'late_return_fee' then 'late_return_fee'
    when 'km' then 'mileage_overage' when 'mileage' then 'mileage_overage' when 'mileage_overage' then 'mileage_overage'
    when 'fuel' then 'fuel' when 'ticket' then 'ticket_amount' when 'ticket_amount' then 'ticket_amount' when 'toll' then 'toll_amount' when 'toll_amount' then 'toll_amount'
    when 'damage' then 'damage_at_cost' when 'damage_at_cost' then 'damage_at_cost' end
$$;

create function app.booking_named_fee_add(p_by uuid, b bookings, x jsonb, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_name text := coalesce(x ->> 'fee', x ->> 'fee_code', x ->> 'kind', x ->> 'code');
  v_code text := app.named_fee_code(v_name);
  f fee_types;
  v_amount bigint := nullif(x ->> 'amount_cents', '')::bigint;
  v_note text := nullif(btrim(coalesce(x ->> 'note', x ->> 'description', x ->> 'reason', p_reason, '')), '');
  v_line uuid;
begin
  if v_code is null then
    raise exception 'Unknown fee "%": use smoking, cleaning, cleaning_heavy, pet_cleaning, late, km, fuel, ticket, toll or damage', coalesce(v_name, '') using errcode = '22023';
  end if;
  if v_code = 'damage_at_cost' then
    return app.damage_charge_add(p_by, jsonb_build_object('booking', b.id, 'amount_cents', v_amount, 'reason', v_note, 'photos', coalesce(x -> 'photos', '[]'::jsonb),
                                                          'document', x ->> 'document'));
  end if;
  select * into f from fee_types where code = v_code;
  if v_amount is null then
    select fd.amount_cents into v_amount from fee_defaults fd where fd.fee_type_code = v_code and fd.vehicle_class is null
       and fd.effective_from <= now() and (fd.effective_to is null or fd.effective_to > now()) order by fd.effective_from desc limit 1;
  end if;
  if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount of the % fee (amount_cents, before HST)', lower(f.label) using errcode = '22023'; end if;
  if v_note is null or char_length(v_note) < 5 then raise exception 'Say what the % fee is for (the renter sees it)', lower(f.label) using errcode = '22023'; end if;
  v_line := app.set_assessed_line(b.id, 'fee:' || v_code || ':' || gen_random_uuid(), v_code, 1, v_amount, v_amount, f.label || ': ' || v_note,
                                  jsonb_build_object('kind', 'named_fee', 'fee', v_name, 'note', v_note, 'added_by', p_by), p_by);
  return jsonb_build_object('line_item_id', v_line, 'fee', v_code, 'label', f.label, 'amount_cents', v_amount);
end $$;

alter function app.booking_fees_change(uuid, jsonb) rename to booking_fees_change_pre3102;
create function app.booking_fees_change(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  x jsonb;
  v_op text;
  v_added jsonb := '[]'::jsonb;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_res jsonb;
  a jsonb;
begin
  if jsonb_typeof(p -> 'lines') <> 'array' then return app.booking_fees_change_pre3102(p_by, p); end if;
  if not (app.may_edit_fees(p_by) or app.user_runs_finance(p_by)) then raise exception 'Only an Admin, Finance, or staff while Program settings let them change fees, adds a fee' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.booking_type::text = 'owner' then raise exception 'An owner booking has no fees' using errcode = '23514'; end if;
  if jsonb_array_length(p -> 'lines') = 0 then raise exception 'Give at least one line: {"op": "add", "fee": "smoking", "amount_cents": 30000}' using errcode = '22023'; end if;
  for x in select value from jsonb_array_elements(p -> 'lines') loop
    if jsonb_typeof(x) <> 'object' then raise exception 'Each line is an object: {"op": "add", "fee": "smoking", "amount_cents": 30000}' using errcode = '22023'; end if;
    v_op := lower(coalesce(x ->> 'op', x ->> 'action', 'add'));
    if v_op <> 'add' then
      raise exception 'A line of the list adds a named fee (op "add"). To change or remove a fee already on the booking, send lines as {"<line key>": cents or null}' using errcode = '22023';
    end if;
    if b.status::text not in ('confirmed', 'on_rent', 'returned', 'closed') then
      raise exception 'Booking % is %: a named fee is added to a booking confirmed, on the road or returned', b.booking_number, b.status using errcode = '23514';
    end if;
    v_added := v_added || app.booking_named_fee_add(p_by, b, x, v_reason);
  end loop;
  for a in select value from jsonb_array_elements(v_added) where value ? 'label' loop
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
      format('%s added: %s plus HST%s', a ->> 'label', app.fmt_money((a ->> 'amount_cents')::bigint), coalesce(' (' || v_reason || ')', '')), p_by, 'staff',
      jsonb_build_object('line_item_id', a ->> 'line_item_id', 'fee', a ->> 'fee'));
  end loop;
  perform app.sync_booking_price(b.id);
  -- after the return: on a statement and from the deposit first (as Bill damage does); before it, on the Check-out statement
  if b.status::text in ('returned', 'closed') then
    if exists (select 1 from booking_statements s where s.booking_id = b.id and s.kind = 'check_in') then
      v_res := app.charge_after_rental(b.id, p_by, now());
      for a in select value from jsonb_array_elements(v_added) where value ? 'label' loop
        perform app.emit_event('renter_extra_charge', 'booking_line_item', (a ->> 'line_item_id')::uuid,
          jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'renter_id', b.renter_id, 'charge_kind', lower(a ->> 'label'),
                             'line_item_id', a ->> 'line_item_id', 'charge_type', a ->> 'fee', 'amount_cents', (a ->> 'amount_cents')::bigint,
                             'hst_cents', public.calc_hst((a ->> 'amount_cents')::bigint, b.hst_bps), 'total_cents', (a ->> 'amount_cents')::bigint + public.calc_hst((a ->> 'amount_cents')::bigint, b.hst_bps),
                             'document_ids', '[]'::jsonb, 'charged_from', case when (select d.status from deposits d where d.booking_id = b.id) in ('held', 'captured') then 'deposit' else 'card_on_file' end),
          'renter_extra_charge:' || (a ->> 'line_item_id') || ':fee');
      end loop;
    end if;
    begin perform app.compute_booking_split(b.id); exception when others then null; end;
  end if;
  begin perform app.commission_sync(b.id); exception when others then null; end;
  select * into b from bookings where id = b.id;
  return jsonb_build_object('ok', true, 'booking_number', b.booking_number, 'added', v_added, 'charged', v_res, 'total_cents', b.total_due_at_booking_cents,
    'billed', case when v_res is not null then 'from the deposit first, then the card on file'
                   when b.status::text in ('returned', 'closed') then 'on the Check-out statement, from the deposit first' else 'with the booking''s other charges' end);
end $$;
select pg_temp.copy_grants('app.booking_fees_change(uuid, jsonb)'::regprocedure, 'app.booking_fees_change_pre3102(uuid, jsonb)'::regprocedure);

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3102;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_call = 'ops_do' and p_name = 'speeding_charge_add' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.speeding_charge_add(p_user, v);
  end if;
  return app.door_pre3102(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3102(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.speeding_charge_add(uuid, jsonb), app.named_fee_code(text), app.booking_named_fee_add(uuid, bookings, jsonb, text),
  app.booking_fees_change_pre3102(uuid, jsonb), app.door_pre3102(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.speeding_charge_add(uuid, jsonb), app.named_fee_code(text), app.booking_named_fee_add(uuid, bookings, jsonb, text),
  app.booking_fees_change_pre3102(uuid, jsonb), app.door_pre3102(uuid, text, text, text, jsonb) to service_role;
