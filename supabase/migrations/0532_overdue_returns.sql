-- 0532: overdue returns, "I've returned the car" (docs/changes/2026-11-06-overdue-returns.md). SCHEMA_MARKER 0532.
--   1. A renter who really has not returned the car keeps getting the escalating overdue notices (return time, T13, T14,
--      their texts and alerts, the staff stages) as before.
--   2. Every one of those notices carries a one-tap link (/returned/<the booking's return_link_token>), and the renter's
--      booking page has the button: a short form (photos from the camera roll, odometer, fuel, the actual return time,
--      all optional). Sending it stops every overdue notice of the booking at once (queued emails, texts and alerts
--      skipped, none emitted while it waits), sets the booking to returned_pending_confirmation, keeps what the renter
--      gave as renter-provided and opens an urgent To do for Fleet.
--   3. Staff (Admin, Fleet, Sales, Customer service, Field: those who check a car in) Confirm (the readings and time
--      may be corrected; the trip is completed as a recorded return; the photos join its check-in report) or Deny
--      (the reason is emailed to the renter and the overdue notices resume).
--   4. A trip completed any other way (the check-in, record now) also stops the overdue notices and settles the report.
--   Also: website crash reports (0433) add one line to the Admins' morning digest per kind per day (one summary email a day).

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. the booking's link and state; the report
alter table bookings add column if not exists return_link_token uuid not null default gen_random_uuid();
create unique index if not exists bookings_return_link_token_key on bookings (return_link_token);
alter table bookings add column if not exists return_state text check (return_state in ('returned_pending_confirmation'));
comment on column bookings.return_link_token is 'The key of the renter''s one-tap "I''ve returned the car" link (0532): /returned/<token>, in every overdue notice.';
comment on column bookings.return_state is 'returned_pending_confirmation while the renter''s "I''ve returned the car" report waits for staff (0532); null otherwise. No overdue notice goes meanwhile.';

create table if not exists return_claims (
  id                    uuid primary key default gen_random_uuid(),
  booking_id            uuid not null references bookings (id) on delete cascade,
  status                text not null default 'pending' check (status in ('pending', 'confirmed', 'denied')),
  claimed_by            uuid references users (id) on delete set null,
  claimed_at            timestamptz not null default now(),
  renter_provided       boolean not null default true,
  returned_at           timestamptz,
  odometer_km           integer check (odometer_km >= 0),
  fuel_pct              smallint check (fuel_pct between 0 and 100),
  note                  text check (char_length(note) <= 1000),
  photos                jsonb not null default '[]'::jsonb check (jsonb_typeof(photos) = 'array' and jsonb_array_length(photos) <= 30),
  decided_by            uuid references users (id) on delete set null,
  decided_at            timestamptz,
  decision_note         text check (char_length(decision_note) <= 1000),
  confirmed_returned_at timestamptz,
  confirmed_odometer_km integer check (confirmed_odometer_km >= 0),
  confirmed_fuel_pct    smallint check (confirmed_fuel_pct between 0 and 100),
  condition_report_id   uuid references condition_reports (id) on delete set null,
  task_id               uuid references tasks (id) on delete set null,
  created_at            timestamptz not null default now(),
  check (status = 'pending' or decided_at is not null)
);
create unique index if not exists return_claims_one_pending on return_claims (booking_id) where status = 'pending';
create index if not exists return_claims_booking on return_claims (booking_id, claimed_at desc);
alter table return_claims enable row level security;
comment on table return_claims is 'The renter''s "I''ve returned the car" reports (0532): what the renter gave (renter-provided), and the staff decision. Written through the server functions only.';
drop policy if exists admin_all on return_claims;
create policy admin_all on return_claims for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop trigger if exists audit_return_claims on return_claims;
create trigger audit_return_claims after insert or update or delete on return_claims for each row execute function app.audit_row();

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('return_claim_review', 'fleet', 'The renter says the car is back', 'urgent', 'opening_minutes', 30,
   'The renter sent "I''ve returned the car" on an overdue booking. The overdue notices are paused. Check the car (place, tracker, photos), then Confirm on the booking (the trip is completed) or Deny (the notices resume and the renter is told why).')
on conflict (task_type) do update set queue = excluded.queue, title = excluded.title, priority = excluded.priority,
  due_kind = excluded.due_kind, due_amount = excluded.due_amount, description = excluded.description;

-- the booking history says so
do $$
declare d text;
begin
  select pg_get_constraintdef(oid) into d from pg_constraint where conrelid = 'booking_events'::regclass and conname = 'booking_events_kind_check';
  if d is not null and d not like '%''return_claimed''%' then
    execute 'alter table booking_events drop constraint booking_events_kind_check';
    execute 'alter table booking_events add constraint booking_events_kind_check '
         || replace(d, 'ARRAY[', 'ARRAY[''return_claimed''::text, ''return_claim_confirmed''::text, ''return_claim_denied''::text, ');
  end if;
end $$;

-- ================================================================ 2. the overdue notices pause and stop
create or replace function app.overdue_codes() returns text[]
language sql immutable as $$
  select array['renter_return_due', 'renter_late_return_first', 'renter_late_return_final', 'staff_late_return_alert']::text[]
$$;

-- Everything of the overdue notices still waiting for this booking (emails, texts, phone alerts) is skipped.
create or replace function app.overdue_quiet(p_booking uuid, p_reason text) returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer := 0; k integer;
begin
  update notification_outbox o set status = 'skipped', status_reason = left(p_reason, 200), locked_at = null
   where o.status in ('queued', 'delayed') and o.code = any (app.overdue_codes())
     and o.event_id in (select e.id from app_events e where e.entity = 'booking' and e.entity_id = p_booking and e.code = any (app.overdue_codes()));
  get diagnostics k = row_count; n := n + k;
  update phone_outbox t set status = 'skipped', status_reason = left(p_reason, 200), locked_at = null
   where t.status = 'queued'
     and t.notification_id in (select x.id from notifications x where x.entity = 'booking' and x.entity_id = p_booking and x.code = any (app.overdue_codes()));
  get diagnostics k = row_count; n := n + k;
  update push_outbox t set status = 'skipped', last_error = left(p_reason, 200), locked_at = null
   where t.status = 'queued'
     and t.notification_id in (select x.id from notifications x where x.entity = 'booking' and x.entity_id = p_booking and x.code = any (app.overdue_codes()));
  get diagnostics k = row_count; n := n + k;
  return n;
end $$;

-- No overdue notice is emitted while the renter's report waits (the reminders job, the late panel's buttons, anything).
-- Not recorded either, so a stage not sent yet goes when the report is denied.
create or replace function app.ntf_emit(p_code text, p_entity text, p_id uuid, p_disc text, p_payload jsonb default '{}'::jsonb) returns bigint
language plpgsql security definer set search_path = public, app as $$
begin
  if p_entity = 'booking' and p_code = any (app.overdue_codes())
     and exists (select 1 from bookings b where b.id = p_id and b.return_state = 'returned_pending_confirmation') then
    return null;
  end if;
  return app.emit_event(p_code, p_entity, p_id, coalesce(p_payload, '{}'::jsonb), p_code || ':' || coalesce(p_id::text, '-') || ':' || p_disc);
end $$;

-- The one-tap link in every overdue email and text ({{returned_url}}).
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0532;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare x jsonb := app.ntf_payload_pre0532(p_code, p_event, p_to);
begin
  if p_code in ('renter_return_due', 'renter_late_return_first', 'renter_late_return_final', 'renter_return_claim_denied') then
    x := coalesce(x, '{}'::jsonb) || jsonb_build_object('returned_url', coalesce((select rtrim((app.settings()).notify_base_url, '/') || '/returned/' || b.return_link_token
                   from bookings b where b.id = coalesce((p_event.payload ->> 'booking_id')::uuid, case when p_event.entity = 'booking' then p_event.entity_id end)), ''));
    if p_code = 'renter_return_claim_denied' then
      x := x || jsonb_build_object('deny_reason', coalesce(nullif(p_event.payload ->> 'deny_reason', ''), 'We could not find the car at the return place.'));
    end if;
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre0532(text, app_events, jsonb)'::regprocedure);

-- the texts carry the link too (an Admin's own wording is kept: the line is added once)
update sms_templates set body = body || ' Returned it already? Tap: {{returned_url}}', updated_at = now()
 where code in ('renter_return_due', 'renter_late_return_first', 'renter_late_return_final')
   and strpos(body, '{{returned_url}}') = 0 and length(body) <= 270;

-- ================================================================ 3. the renter's report
-- what the link's page shows (null: an unknown link)
create or replace function public.server_return_claim_read(p_token uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('booking_id', b.id, 'number', b.booking_number, 'car', app.vehicle_name(b.vehicle_id), 'return_at', b.return_at,
           'return_place', nullif(b.return_place, ''), 'status', b.status, 'return_state', b.return_state,
           'can_report', b.status in ('on_rent', 'confirmed') and app.booking_is_out(b, now()) and b.return_state is null,
           'done', b.status in ('returned', 'closed'),
           'claim', (select jsonb_build_object('status', c.status, 'claimed_at', c.claimed_at, 'decision_note', case when c.status = 'denied' then c.decision_note end)
                       from return_claims c where c.booking_id = b.id order by c.claimed_at desc limit 1))
    from bookings b where b.return_link_token = p_token and not coalesce(b.is_placeholder, false)
$$;

-- the link of the signed-in renter's own booking (the booking page's button)
create or replace function public.server_return_link(p_booking uuid, p_user uuid) returns uuid
language sql stable security definer set search_path = public, app as $$
  select b.return_link_token from bookings b join renters r on r.id = b.renter_id
   where b.id = p_booking and r.user_id = p_user
$$;

create or replace function public.server_return_claim_submit(p_token uuid, p jsonb, p_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  c return_claims;
  v_at timestamptz := nullif(p ->> 'returned_at', '')::timestamptz;
  v_km integer := nullif(p ->> 'odometer_km', '')::numeric::integer;
  v_fuel integer := nullif(p ->> 'fuel_pct', '')::numeric::integer;
  v_note text := nullif(left(btrim(coalesce(p ->> 'note', '')), 1000), '');
  v_photos jsonb := coalesce(p -> 'photos', '[]'::jsonb);
  v_task uuid;
  v_n integer;
begin
  select * into b from bookings where return_link_token = p_token and not coalesce(is_placeholder, false) for update;
  if b.id is null then raise exception 'This link is not valid' using errcode = 'P0002'; end if;
  if b.status in ('returned', 'closed') then return jsonb_build_object('status', 'done'); end if;
  if b.return_state = 'returned_pending_confirmation' then return jsonb_build_object('status', 'pending', 'already', true); end if;
  if b.status not in ('on_rent', 'confirmed') or not app.booking_is_out(b, now()) then
    raise exception 'Booking % is not out with you, so there is no return to report', b.booking_number using errcode = '23514';
  end if;
  if v_at is not null and v_at > now() + interval '5 minutes' then raise exception 'The return time cannot be in the future' using errcode = '22023'; end if;
  if v_at is not null and v_at < coalesce(b.handed_over_at, b.pickup_at) then raise exception 'The return time cannot be before the pickup' using errcode = '22023'; end if;
  if v_km is not null and (v_km < 0 or v_km > 2000000) then raise exception 'Check the odometer reading' using errcode = '22023'; end if;
  if v_km is not null and b.odometer_out_km is not null and v_km < b.odometer_out_km then
    raise exception 'The odometer reading (% km) is lower than at pickup (% km)', v_km, b.odometer_out_km using errcode = '22023';
  end if;
  if v_fuel is not null and v_fuel not between 0 and 100 then raise exception 'The fuel level is 0 to 100%%' using errcode = '22023'; end if;
  if jsonb_typeof(v_photos) <> 'array' or jsonb_array_length(v_photos) > 30 then raise exception 'Up to 30 photos' using errcode = '22023'; end if;
  -- only the photos this booking's link uploaded (the upload route writes them under this prefix)
  select count(*) into v_n from jsonb_array_elements(v_photos) x
   where jsonb_typeof(x) <> 'object' or x ->> 'bucket' <> 'condition-photos'
      or coalesce(x ->> 'path', '') !~ ('^bookings/' || b.id || '/return-claim/[0-9a-f-]{36}\.(jpg|png)$');
  if v_n > 0 then raise exception 'A photo was not uploaded through this link' using errcode = '22023'; end if;

  insert into return_claims (booking_id, claimed_by, returned_at, odometer_km, fuel_pct, note, photos)
  values (b.id, p_user, least(coalesce(v_at, now()), now()), v_km, v_fuel::smallint, v_note,
          (select coalesce(jsonb_agg(jsonb_build_object('bucket', x ->> 'bucket', 'path', x ->> 'path')), '[]'::jsonb) from jsonb_array_elements(v_photos) x))
  returning * into c;
  update bookings set return_state = 'returned_pending_confirmation' where id = b.id;
  perform app.overdue_quiet(b.id, 'the renter reported the car returned');
  v_task := app.raise_task(p_type => 'return_claim_review',
    p_title => left(format('%s: the renter says the %s is back', b.booking_number, coalesce(app.vehicle_name(b.vehicle_id), 'car')), 200),
    p_detail => left(format('Returned %s (renter-provided). Odometer: %s. Fuel: %s. Photos: %s.%s Check the car, then Confirm or Deny on the booking. The overdue notices are paused until then.',
                  app.fmt_at(c.returned_at), coalesce(c.odometer_km || ' km', 'not given'), coalesce(c.fuel_pct || '%', 'not given'),
                  jsonb_array_length(c.photos), coalesce(' Note: ' || c.note || '.', '')), 2000),
    p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_related_table => 'return_claims', p_related_id => c.id,
    p_dedupe => 'return_claim:' || c.id);
  update return_claims set task_id = v_task where id = c.id;
  perform app.log_booking_event(b.id, 'return_claimed', b.status::text, b.status::text, null,
    format('The renter reported the car returned (%s); waiting for staff to confirm', app.fmt_at(c.returned_at)), p_user, 'renter',
    jsonb_build_object('return_claim_id', c.id, 'odometer_km', c.odometer_km, 'fuel_pct', c.fuel_pct, 'photos', jsonb_array_length(c.photos), 'renter_provided', true));
  return jsonb_build_object('status', 'pending', 'claim_id', c.id);
end $$;

-- ================================================================ 4. staff: Confirm or Deny
create or replace function app.return_claim_view(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', c.id, 'status', c.status, 'claimed_at', c.claimed_at, 'returned_at', c.returned_at,
           'odometer_km', c.odometer_km, 'fuel_pct', c.fuel_pct, 'note', c.note, 'photos', c.photos, 'renter_provided', c.renter_provided,
           'decided_at', c.decided_at, 'decided_by_name', (select u.full_name from users u where u.id = c.decided_by), 'decision_note', c.decision_note,
           'confirmed_returned_at', c.confirmed_returned_at, 'confirmed_odometer_km', c.confirmed_odometer_km, 'confirmed_fuel_pct', c.confirmed_fuel_pct,
           'odometer_out_km', b.odometer_out_km, 'return_at', b.return_at)
    from return_claims c join bookings b on b.id = c.booking_id
   where c.booking_id = p_booking order by c.claimed_at desc limit 1
$$;

create or replace function app.return_claim_decide(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  c return_claims;
  v_decision text := p ->> 'decision';
  v_note text := nullif(left(btrim(coalesce(p ->> 'reason', '')), 1000), '');
  v_at timestamptz;
  v_km integer;
  v_fuel integer;
  r jsonb;
  v_seq integer;
  ph jsonb;
begin
  if not app.user_may_handover(p_by) then
    raise exception 'Only an Admin, Fleet, Sales, Customer service or field staff confirm a return' using errcode = '42501';
  end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  select * into c from return_claims where booking_id = b.id and status = 'pending' for update;
  if c.id is null then raise exception 'No return report of booking % waits for a decision', b.booking_number using errcode = '23514'; end if;
  if v_decision = 'confirm' then
    v_at := coalesce(nullif(p ->> 'returned_at', '')::timestamptz, c.returned_at, now());
    v_km := coalesce(nullif(p ->> 'odometer_km', '')::numeric::integer, c.odometer_km);
    v_fuel := coalesce(nullif(p ->> 'fuel_pct', '')::numeric::integer, c.fuel_pct);
    -- the report is settled first, so the trip's completion below finds nothing pending
    update bookings set return_state = null where id = b.id;
    update return_claims set status = 'confirmed', decided_by = p_by, decided_at = now(), decision_note = v_note,
           confirmed_returned_at = v_at, confirmed_odometer_km = v_km, confirmed_fuel_pct = v_fuel::smallint
     where id = c.id;
    r := app.handover_record_now(p_by, jsonb_strip_nulls(jsonb_build_object('booking', b.id, 'kind', 'return', 'at', v_at, 'odometer_km', v_km, 'fuel_pct', v_fuel,
           'reason', 'Reported returned by the renter (renter-provided readings and photos), confirmed by staff' || coalesce(': ' || v_note, ''))));
    -- the renter's photos join the check-in report, marked as the renter's
    select coalesce(max(seq), 0) into v_seq from condition_report_photos where condition_report_id = (r ->> 'report_id')::uuid;
    for ph in select * from jsonb_array_elements(c.photos) loop
      v_seq := v_seq + 1;
      insert into condition_report_photos (condition_report_id, seq, shot, storage_bucket, storage_path, uploaded_by)
      values ((r ->> 'report_id')::uuid, v_seq, 'other', ph ->> 'bucket', ph ->> 'path', c.claimed_by);
    end loop;
    update condition_reports set notes = left(concat_ws(' ', notes, format('Renter-provided at the return report (%s): odometer %s, fuel %s, %s photos.',
             app.fmt_at(c.claimed_at), coalesce(c.odometer_km || ' km', 'not given'), coalesce(c.fuel_pct || '%', 'not given'), jsonb_array_length(c.photos))), 4000)
     where id = (r ->> 'report_id')::uuid;
    update return_claims set condition_report_id = (r ->> 'report_id')::uuid where id = c.id;
    perform app.resolve_tasks(array['return_claim_review'], b.id, p_by, 'Confirmed: the trip is completed');
    perform app.log_booking_event(b.id, 'return_claim_confirmed', b.status::text, 'returned', null,
      format('The renter''s return report was confirmed (returned %s)', app.fmt_at(v_at)), p_by, 'staff',
      jsonb_build_object('return_claim_id', c.id, 'condition_report_id', r ->> 'report_id'));
    return jsonb_build_object('status', 'confirmed', 'report_id', r ->> 'report_id', 'booking_status', (select status from bookings where id = b.id));
  elsif v_decision = 'deny' then
    if v_note is null or length(v_note) < 5 then raise exception 'Say why (at least 5 characters): the renter reads it' using errcode = '22023'; end if;
    update return_claims set status = 'denied', decided_by = p_by, decided_at = now(), decision_note = v_note where id = c.id;
    update bookings set return_state = null where id = b.id;
    perform app.resolve_tasks(array['return_claim_review'], b.id, p_by, 'Denied: ' || v_note);
    perform app.ntf_emit('renter_return_claim_denied', 'booking', b.id, c.id::text, jsonb_build_object('booking_id', b.id, 'deny_reason', v_note));
    perform app.log_booking_event(b.id, 'return_claim_denied', b.status::text, b.status::text, null,
      'The renter''s return report was denied: ' || v_note, p_by, 'staff', jsonb_build_object('return_claim_id', c.id));
    return jsonb_build_object('status', 'denied');
  end if;
  raise exception 'Confirm or Deny' using errcode = '22023';
end $$;

-- ================================================================ 5. a trip completed any other way
create or replace function app.return_claim_trip_done() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status is distinct from old.status and new.status in ('returned', 'closed', 'cancelled') then
    perform app.overdue_quiet(new.id, 'the trip is completed');
    if new.return_state is not null then
      update bookings set return_state = null where id = new.id;
    end if;
    update return_claims set status = 'confirmed', decided_at = now(), decided_by = coalesce(decided_by, app.uid()),
           decision_note = coalesce(decision_note, 'Settled by the check-in of the trip'), confirmed_returned_at = coalesce(confirmed_returned_at, new.checked_in_at)
     where booking_id = new.id and status = 'pending';
    perform app.resolve_tasks(array['return_claim_review'], new.id, null, 'The trip is completed');
  end if;
  return null;
end $$;
drop trigger if exists bookings_return_claim_done on bookings;
create trigger bookings_return_claim_done after update of status on bookings for each row execute function app.return_claim_trip_done();

-- ================================================================ 6. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0532;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_do' and p_name = 'return_claim_decide' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.return_claim_decide(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call = 'ops_read' and p_name = 'return_claim' then
    perform app.door_begin(p_user, p_aal);
    if not app.user_may_handover(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.return_claim_view((select id from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) limit 1));
  end if;
  return app.door_pre0532(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0532(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 7. website crashes: one digest line per kind per day
-- 0433 opens one Admin To do per kind of crash a day; the Admins' morning digest (one email a day) lists it once too.
alter function public.server_client_error(jsonb) rename to server_client_error_pre0532;
create function public.server_client_error(p jsonb) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v text := public.server_client_error_pre0532(p);
  v_msg text := left(coalesce(nullif(btrim(p ->> 'message'), ''), 'Unknown error'), 200);
  v_path text := left(coalesce(nullif(btrim(p ->> 'path'), ''), '/'), 120);
begin
  if v = 'ok' then
    insert into staff_digest_items (role, code, digest_slot, line, meta, url, dedupe_key)
    values ('admin', 'staff_site_alert', 'morning', left('Website crash on ' || v_path || ': ' || v_msg, 300), 'Kept 30 days in client_errors',
            rtrim((app.settings()).notify_base_url, '/') || '/admin/todo',
            'client_error_digest:' || md5(v_msg || '|' || regexp_replace(v_path, '/[A-Za-z0-9_-]{8,}', '/x', 'g')) || ':' || to_char(app.local_date(now()), 'YYYY-MM-DD'))
    on conflict (dedupe_key) do nothing;
  end if;
  return v;
end $$;
select pg_temp.copy_grants('public.server_client_error(jsonb)'::regprocedure, 'public.server_client_error_pre0532(jsonb)'::regprocedure);

-- ================================================================ 8. privileges
revoke all on function app.overdue_codes(), app.overdue_quiet(uuid, text), app.return_claim_view(uuid), app.return_claim_decide(uuid, jsonb),
  app.return_claim_trip_done(), public.server_return_claim_read(uuid), public.server_return_link(uuid, uuid),
  public.server_return_claim_submit(uuid, jsonb, uuid) from public, anon, authenticated;
grant execute on function app.overdue_codes(), app.overdue_quiet(uuid, text), app.return_claim_view(uuid), app.return_claim_decide(uuid, jsonb), app.return_claim_trip_done(),
  public.server_return_claim_read(uuid), public.server_return_link(uuid, uuid), public.server_return_claim_submit(uuid, jsonb, uuid) to service_role;

-- CATALOGUE 0532 START (generated by supabase/seed/0532_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_return_due', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Your booking ended at {{return_time}}', 'Please return the {{vehicle_name}} now, or extend if you need more time.', 'At the return time', 'Reminders job (every 5 minutes, migration 0430): the return time of a booking that is out has come and no return is recorded. Each one carries the renter''s one-tap "I''ve returned the car" link (migration 0532), and none is sent while the renter''s report waits for staff. Sent once per return time, in the first 15 minutes (T13 follows at 15 minutes late). Only between 7 am and 10 pm Toronto time. Off with notify_return_due.', null, '/account/bookings/{{booking_number}}/extend', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"extend_offer","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"late_fee_hourly","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"returned_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_return_due.html', 'templates/renter_return_due.txt'),
  ('renter_late_return_first', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Your rental ended at {{return_time}}. Please return the car now', 'Return the {{vehicle_name}} or call {{support_phone}} to extend.', '15 minutes after the return time', 'Reminders job (every 5 minutes): the return time has passed, the booking is still out (on rent, or confirmed with its pickup time passed and no handover recorded, migration 0430) and no paid extension covers the time. Each one carries the renter''s one-tap "I''ve returned the car" link (migration 0532), and none is sent while the renter''s report waits for staff. Sent once per return time, 15 minutes late (notify_late_first_minutes; renter_return_due goes at the return time). Between 7 am and 10 pm Toronto time; overnight it waits until 7 am. The late panel sends the same notice by hand, never twice. (Message template T13.)', 'T13', '/account/bookings/{{booking_number}}/extend', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"late_fee_hourly","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"returned_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_late_return_first.html', 'templates/renter_late_return_first.txt'),
  ('renter_late_return_final', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Final notice: return the {{vehicle_name}} by {{final_deadline}}', 'The car is 2 hours overdue. Return it or pay for an extension now.', '2 hours after the return time', 'Carries the one-tap "I''ve returned the car" link (0532); not sent while the renter''s report waits for staff. Reminders job (every 5 minutes): the booking is 2 hours past its return time (late_admin_minutes), still out (on rent, or confirmed with no handover recorded, migration 0430), with no paid extension, and T13 went at least 30 minutes ago. Between 7 am and 10 pm Toronto time; overnight it waits until 7 am. The late panel sends the same notice by hand, never twice. The deadline shown is 1 hour after this email is sent. (Message template T14.)', 'T14', '/account/bookings/{{booking_number}}/extend', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"final_deadline","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"return_place","type":"string"},{"name":"returned_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_late_return_final.html', 'templates/renter_late_return_final.txt'),
  ('renter_return_claim_denied', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'We could not confirm the return of the {{vehicle_name}}', 'The car is not checked in yet. Please return it now or call {{support_phone}}.', 'Immediate', 'Staff press Deny on the renter''s "I''ve returned the car" report (migration 0532): the car is not back. The booking is overdue again, so the late return notices resume.', null, '/account/bookings/{{booking_number}}/extend', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deny_reason","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"returned_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_return_claim_denied.html', 'templates/renter_return_claim_denied.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0532 END

update notification_catalogue set emitted_by = 'app.return_claim_decide (0532)' where code = 'renter_return_claim_denied';

-- the text of the denial (the link page and the one-tap link)
insert into sms_templates (code, label, body, urgent, sort_order) values
  ('renter_return_claim_denied', 'Return not confirmed', 'CarmaCars: we could not confirm the return of booking {{booking_number}}. It is still overdue. Please return the car or call us. Details: {{link}}', true, 65)
on conflict (code) do nothing;

-- GUIDES 0532 START (generated by supabase/seed/0532_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('renter', 'during-your-trip', 'chapter', 'before-pickup', 'Plans change. You can ask for more days, ask to change dates, answer a change we suggest, or cancel, all from your booking.

## Extend your rental

1. On your booking, press **Extend**.
2. Pick how long: **1 hour**, **3 hours**, **1 day**, **3 days**, **1 week** or **1 month**. Each shows the new return, the price with the regular price struck through, and what you save. An option the car cannot take is greyed out with the reason, and the page says until when the car is free.
3. Press **Pay** to pay with your card on file. When the car is free it is approved at once and the page shows your new return. No card on file, or the card is declined? The secure payment page opens: enter a card there. Otherwise the request goes to our team, and once approved you pay on the same page.
4. For another date, open **Another date and time**, choose it, press **See the price**, then **Request extension**.

![](/guides/img/renter-11-extend-desktop-957274cc.jpg "desktop; size: 960 552; address: carmacars.ca/account/bookings/CC-10003/extend; pins: 2 34.4 62.9, 3 15.1 77.2")

> Tip: Extending costs less than being late: a day or more is 5% off, and 1 or 3 hours are 10% off the late fee. Already past your return time and still have the car? You can still extend. It counts from your original return time, and the late charges stay owed until the extension is paid.

## Ask to change dates

1. On your booking, press **Ask to change dates**.
2. Set the new pickup and return, then press **See the difference** to see what you would pay or get back.
3. Press **Ask to change dates** to send it. Nothing changes until you agree to our answer.

![](/guides/img/renter-12-change-desktop-09f6b563.jpg "desktop; size: 960 552; address: carmacars.ca/account/bookings/CC-10003/change; pins: 2 15.1 91.8")

## A change we suggest

Sometimes we need to change your booking, for example another car of the same class. You decide.

1. You get an email, and your booking says "We suggest a change to your booking". Press **Review and answer**.
2. Read what changes (before and after), the reason, the money and the time left to answer.
3. To agree, press **Accept and sign the amendment**, sign, then press **Accept and sign**.
4. Anything more to pay is charged to your Card on File. If the card is declined, press **Pay and apply the change**.
5. To say no, press **Decline this change**. Your booking stays as it was.

> Tip: You have 48 hours to answer, and we send one reminder. CarmaCars signs the amendment at the moment you sign it, and the signed copy is saved under Documents. If the change costs less, the refund goes back to your card within 10 business days after the amendment is signed.

## Cancel a booking

1. On your booking, press **Cancel booking**.
2. Read What you get back. It shows the rule that applies and your refund.
3. Type the booking number to confirm (for example CC-10021), then press **Cancel booking**.

![](/guides/img/renter-13-cancel-desktop-d0bb2c67.jpg "desktop; size: 1440 692; address: carmacars.ca/account/bookings/CC-10003/cancel; pins: 2 36.1 67.2, 3 95.8 45.1")

| Standard booking: when you cancel | Refund of what you paid |
| --- | --- |
| Within 24 hours of booking, and 48 hours or more before pickup | 95% back |
| 48 hours or more before pickup | 75% back |
| 24 to 48 hours before pickup | 50% back |
| Less than 24 hours before pickup | No refund |

A Non-refundable booking gets no refund. The deposit is taken at pickup, so none is held when you cancel before it.

## Messages, tolls and tickets

- On a rental of 2 days or more we check in after the first day: "How is the car?" If anything is off, reply to the email or text, or call us.
- Write to us about a booking at the bottom of its page: type in Your message and press Send.
- Tolls and tickets are yours to pay, including Highway 407 ETR. If one reaches us, we pay it and charge the amount plus our fee to your Card on File, and email you a copy of the notice.
- Running late? Extend in your booking, even after the return time while you still have the car, or call us at 289-312-5991. The late fee is 17.5% of the daily rate for each started hour (at least $25) after a 30 minute grace.
- Before your return we remind you: the day before, about 3 hours before (with an Extend link) and at the return time. If the car is late we send a notice at 15 minutes and a final notice at 2 hours. No late notices between 10 pm and 7 am.
- Something wrong with the car? While you have it, press **Report a problem** on your booking: it calls roadside help, or opens a message to us.
- Someone else will drive too? Press **Add a driver**: write their name in the message and we add them; they sign with their own link.
', 'During your trip', 'Extend, change dates, answer a change we suggest, or cancel.',
  'Plans change. You can ask for more days, ask to change dates, answer a change we suggest, or cancel, all from your booking.

## Extend your rental

1. On your booking, press **Extend**.
2. Pick how long: **1 hour**, **3 hours**, **1 day**, **3 days**, **1 week** or **1 month**. Each shows the new return, the price with the regular price struck through, and what you save. An option the car cannot take is greyed out with the reason, and the page says until when the car is free.
3. Press **Pay** to pay with your card on file. When the car is free it is approved at once and the page shows your new return. No card on file, or the card is declined? The secure payment page opens: enter a card there. Otherwise the request goes to our team, and once approved you pay on the same page.
4. For another date, open **Another date and time**, choose it, press **See the price**, then **Request extension**.

![](/guides/img/renter-11-extend-desktop-957274cc.jpg "desktop; size: 960 552; address: carmacars.ca/account/bookings/CC-10003/extend; pins: 2 34.4 62.9, 3 15.1 77.2")

> Tip: Extending costs less than being late: a day or more is 5% off, and 1 or 3 hours are 10% off the late fee. Already past your return time and still have the car? You can still extend. It counts from your original return time, and the late charges stay owed until the extension is paid.

## Ask to change dates

1. On your booking, press **Ask to change dates**.
2. Set the new pickup and return, then press **See the difference** to see what you would pay or get back.
3. Press **Ask to change dates** to send it. Nothing changes until you agree to our answer.

![](/guides/img/renter-12-change-desktop-09f6b563.jpg "desktop; size: 960 552; address: carmacars.ca/account/bookings/CC-10003/change; pins: 2 15.1 91.8")

## A change we suggest

Sometimes we need to change your booking, for example another car of the same class. You decide.

1. You get an email, and your booking says "We suggest a change to your booking". Press **Review and answer**.
2. Read what changes (before and after), the reason, the money and the time left to answer.
3. To agree, press **Accept and sign the amendment**, sign, then press **Accept and sign**.
4. Anything more to pay is charged to your Card on File. If the card is declined, press **Pay and apply the change**.
5. To say no, press **Decline this change**. Your booking stays as it was.

> Tip: You have 48 hours to answer, and we send one reminder. CarmaCars signs the amendment at the moment you sign it, and the signed copy is saved under Documents. If the change costs less, the refund goes back to your card within 10 business days after the amendment is signed.

## Cancel a booking

1. On your booking, press **Cancel booking**.
2. Read What you get back. It shows the rule that applies and your refund.
3. Type the booking number to confirm (for example CC-10021), then press **Cancel booking**.

![](/guides/img/renter-13-cancel-desktop-d0bb2c67.jpg "desktop; size: 1440 692; address: carmacars.ca/account/bookings/CC-10003/cancel; pins: 2 36.1 67.2, 3 95.8 45.1")

| Standard booking: when you cancel | Refund of what you paid |
| --- | --- |
| Within 24 hours of booking, and 48 hours or more before pickup | 95% back |
| 48 hours or more before pickup | 75% back |
| 24 to 48 hours before pickup | 50% back |
| Less than 24 hours before pickup | No refund |

A Non-refundable booking gets no refund. The deposit is taken at pickup, so none is held when you cancel before it.

## Messages, tolls and tickets

- On a rental of 2 days or more we check in after the first day: "How is the car?" If anything is off, reply to the email or text, or call us.
- Write to us about a booking at the bottom of its page: type in Your message and press Send.
- Tolls and tickets are yours to pay, including Highway 407 ETR. If one reaches us, we pay it and charge the amount plus our fee to your Card on File, and email you a copy of the notice.
- Running late? Extend in your booking, even after the return time while you still have the car, or call us at 289-312-5991. The late fee is 17.5% of the daily rate for each started hour (at least $25) after a 30 minute grace.
- Before your return we remind you: the day before, about 3 hours before (with an Extend link) and at the return time. If the car is late we send a notice at 15 minutes and a final notice at 2 hours. No late notices between 10 pm and 7 am.
- Already brought the car back but still getting late notices? Tap **I''ve returned the car** in the notice, or press it on your booking. Add photos of the car where you left it (pick several at once from your camera roll), the odometer, the fuel level and the time you returned it: all optional. The late notices stop at once while we check. When we confirm, your trip is complete. If we cannot find the car, we tell you why and the notices start again.
- Something wrong with the car? While you have it, press **Report a problem** on your booking: it calls roadside help, or opens a message to us.
- Someone else will drive too? Press **Add a driver**: write their name in the message and we add them; they sign with their own link.
',
  '<p class="gd-p">Plans change. You can ask for more days, ask to change dates, answer a change we suggest, or cancel, all from your booking.</p><section class="gd-task" id="during-your-trip-extend-your-rental" data-gd-task><h2 class="gd-h2">Extend your rental</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On your booking, press <b class="gd-ui">Extend</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Pick how long: <b class="gd-ui">1 hour</b>, <b class="gd-ui">3 hours</b>, <b class="gd-ui">1 day</b>, <b class="gd-ui">3 days</b>, <b class="gd-ui">1 week</b> or <b class="gd-ui">1 month</b>. Each shows the new return, the price with the regular price struck through, and what you save. An option the car cannot take is greyed out with the reason, and the page says until when the car is free.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Pay</b> to pay with your card on file. When the car is free it is approved at once and the page shows your new return. No card on file, or the card is declined? The secure payment page opens: enter a card there. Otherwise the request goes to our team, and once approved you pay on the same page.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">For another date, open <b class="gd-ui">Another date and time</b>, choose it, press <b class="gd-ui">See the price</b>, then <b class="gd-ui">Request extension</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10003/extend</span></div><div class="gd-imgwrap" style="aspect-ratio:960/552"><img src="/guides/img/renter-11-extend-desktop-957274cc.jpg" alt="" loading="lazy" decoding="async" width="960" height="552"><span class="gd-pin" style="left:34.4%;top:62.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:15.1%;top:77.2%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Extending costs less than being late: a day or more is 5% off, and 1 or 3 hours are 10% off the late fee. Already past your return time and still have the car? You can still extend. It counts from your original return time, and the late charges stay owed until the extension is paid.</div></aside></section><section class="gd-task" id="during-your-trip-ask-to-change-dates" data-gd-task><h2 class="gd-h2">Ask to change dates</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On your booking, press <b class="gd-ui">Ask to change dates</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Set the new pickup and return, then press <b class="gd-ui">See the difference</b> to see what you would pay or get back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Ask to change dates</b> to send it. Nothing changes until you agree to our answer.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10003/change</span></div><div class="gd-imgwrap" style="aspect-ratio:960/552"><img src="/guides/img/renter-12-change-desktop-09f6b563.jpg" alt="" loading="lazy" decoding="async" width="960" height="552"><span class="gd-pin" style="left:15.1%;top:91.8%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="during-your-trip-a-change-we-suggest" data-gd-task><h2 class="gd-h2">A change we suggest</h2><p class="gd-p">Sometimes we need to change your booking, for example another car of the same class. You decide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">You get an email, and your booking says &quot;We suggest a change to your booking&quot;. Press <b class="gd-ui">Review and answer</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read what changes (before and after), the reason, the money and the time left to answer.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To agree, press <b class="gd-ui">Accept and sign the amendment</b>, sign, then press <b class="gd-ui">Accept and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Anything more to pay is charged to your Card on File. If the card is declined, press <b class="gd-ui">Pay and apply the change</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">To say no, press <b class="gd-ui">Decline this change</b>. Your booking stays as it was.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>You have 48 hours to answer, and we send one reminder. CarmaCars signs the amendment at the moment you sign it, and the signed copy is saved under Documents. If the change costs less, the refund goes back to your card within 10 business days after the amendment is signed.</div></aside></section><section class="gd-task" id="during-your-trip-cancel-a-booking" data-gd-task><h2 class="gd-h2">Cancel a booking</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On your booking, press <b class="gd-ui">Cancel booking</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read What you get back. It shows the rule that applies and your refund.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Type the booking number to confirm (for example CC-10021), then press <b class="gd-ui">Cancel booking</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10003/cancel</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/692"><img src="/guides/img/renter-13-cancel-desktop-d0bb2c67.jpg" alt="" loading="lazy" decoding="async" width="1440" height="692"><span class="gd-pin" style="left:36.1%;top:67.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:95.8%;top:45.1%" aria-hidden="true">3</span></div></div></figure></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Standard booking: when you cancel</th><th scope="col">Refund of what you paid</th></tr></thead><tbody><tr><td>Within 24 hours of booking, and 48 hours or more before pickup</td><td>95% back</td></tr><tr><td>48 hours or more before pickup</td><td>75% back</td></tr><tr><td>24 to 48 hours before pickup</td><td>50% back</td></tr><tr><td>Less than 24 hours before pickup</td><td>No refund</td></tr></tbody></table></div><p class="gd-p">A Non-refundable booking gets no refund. The deposit is taken at pickup, so none is held when you cancel before it.</p></section><section class="gd-task" id="during-your-trip-messages-tolls-and-tickets" data-gd-task><h2 class="gd-h2">Messages, tolls and tickets</h2><ul class="gd-ul"><li>On a rental of 2 days or more we check in after the first day: &quot;How is the car?&quot; If anything is off, reply to the email or text, or call us.</li><li>Write to us about a booking at the bottom of its page: type in Your message and press Send.</li><li>Tolls and tickets are yours to pay, including Highway 407 ETR. If one reaches us, we pay it and charge the amount plus our fee to your Card on File, and email you a copy of the notice.</li><li>Running late? Extend in your booking, even after the return time while you still have the car, or call us at 289-312-5991. The late fee is 17.5% of the daily rate for each started hour (at least $25) after a 30 minute grace.</li><li>Before your return we remind you: the day before, about 3 hours before (with an Extend link) and at the return time. If the car is late we send a notice at 15 minutes and a final notice at 2 hours. No late notices between 10 pm and 7 am.</li><li>Already brought the car back but still getting late notices? Tap <b class="gd-ui">I&#39;ve returned the car</b> in the notice, or press it on your booking. Add photos of the car where you left it (pick several at once from your camera roll), the odometer, the fuel level and the time you returned it: all optional. The late notices stop at once while we check. When we confirm, your trip is complete. If we cannot find the car, we tell you why and the notices start again.</li><li>Something wrong with the car? While you have it, press <b class="gd-ui">Report a problem</b> on your booking: it calls roadside help, or opens a message to us.</li><li>Someone else will drive too? Press <b class="gd-ui">Add a driver</b>: write their name in the message and we add them; they sign with their own link.</li></ul></section>');
select app.guide_release_section('admin', 'requests-offers-and-bookings', 'chapter', 'people-and-access', 'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.

## Bookings now: what is out, coming back and owed

Open **Bookings**. It opens on **Now**, one screen that refreshes by itself every 30 seconds. Every time is Toronto time.

1. The numbers at the top: cars out now, due back today, overdue, going out in the next 72 hours, payments due in the next 7 days (with the total) and free cars. Tap one to jump to its list.
2. **Out now**: every car on rent, overdue returns first in red. Each shows the car (photo, code, plate), the renter with **Call** and **Text**, when it was picked up, when it is due back with a countdown, the payment plan and the next payment, the deposit held, and the km and fuel at pickup. Filter by Overdue, Due today or Payment due.
3. A confirmed booking whose pickup time has passed with no check-out recorded is listed as out, with **Out (pickup not recorded)**. The car most likely left. Press **Mark picked up**: it records the pickup at the booked time (change it if the car left at another time), the booking goes on rent, and Fleet gets a task to add the photos, km and fuel. The usual checks stay: the deposit taken (or an Admin waives it with the reason), the renter''s signature (or an Admin''s reason), the agreement''s details, every driver verified and the coverage confirmed. If one is missing, the reason is shown.
4. **Coming back**: overdue, today and tomorrow, by the time each is due.
5. **Going out**: confirmed pickups in the next 72 hours, delivery or pickup, with ticks and crosses for the licence, the signed agreement, the payment, the deposit (a clock until the morning of the pickup day, when the hold is placed on the card on file) and the check-out photos (done at the handover).
6. **Money due**: every rental payment due in the next 7 days or overdue, the amount, the plan and which payment it is (for example 3 of 4).
7. **Free now**: cars available and not out, the longest idle first, with the next pickup; then the cars in maintenance or cleaning. Partners'' cars are counted apart.

> Good to know: Placeholder bookings never show on Now.

### Payment plans

A rental is paid in full at pickup, weekly, every 2 weeks, or monthly. A rental longer than one period (30 days) pays each period by itself. To change it, open the booking, then the **Payment plan** card on Overview or Money, and press **Change the plan**. Each payment is its share of the total by its days, due on the day it starts. An insurer-billed rental shows **Insurer billed** and is never in Money due unless the renter owes a part. Admins, customer service and finance change the plan; fleet sees it.

## All bookings

The **All bookings** tab of Bookings has the search (booking number, name, email, phone, plate or car code), the status (All, Out now, Booked, Returned, Closed, Cancelled) and **Bill to** (All, Renter, Insurer). **Out now** shows the bookings on rent and those whose pickup passed without a check-out, together. Each booking is one row: its number and status in plain words, the car with its photo, the renter with **Call** and **Text**, the dates, the money (paid up, to pay, overdue, insurer billed) and Bill to.

## The request queue

Open **Bookings** > **Requests and offers**. The oldest waiting request is at the top.

1. The numbers at the top: waiting for an offer, past the reply target (red), offers out, accepted but not paid, and offers expired.
2. One queue, the most urgent first: the longest wait, then offers accepted but not paid, then offers out by when they expire. Each row has the car with its photo, the dates, the price, the renter with **Call** and **Text**, the licence (verified, to review, or not uploaded yet), who is answering it, and one button: **Send offer**, **Follow up** or **Open**. **Decline** sits beside **Send offer**.
3. Waiting shows how long the renter has waited ("12 min", "3 h", "2 days"); red means past the first reply target (5 minutes, set in Program settings). **Promise** counts down the 2 hours the site promises the renter.
4. Filter by Active, New, Asked the renter, Changes asked, Offer out, Not paid or Expired. An expired offer leaves the active queue 48 hours after it expired, or once its pickup time passed; Expired lists them all. An offer still out when its pickup time passes expires by itself.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 38.9 29.9, 2 22.2 43.3")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates (under **Show rate card**) and fees, the deposit and extras. A place changed away from a delivery or a collection takes its fee box and its fee with it.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-353f3707.jpg "desktop; size: 1200 1550; address: carmacars.ca/admin/bookings/CC-10069?tab=review; pins: 1 5.0 6.5, 2 7.5 45.8, 3 74.2 42.6, 4 76.7 98.1")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-4dd4ed06.jpg "desktop; size: 500 80; address: carmacars.ca/admin/bookings/CC-10069?tab=review; pins: 6 41.2 52.5, 7 18.0 52.5")

Opening a request takes it for you: everyone else sees "Being answered by" your name and since when, with Send the offer and Decline off, until you send, decline or leave (20 minutes, renewed while you work; Program settings). Press **Take over** to answer one someone else holds; it is noted in the history. A second answer is refused with who answered and when. A request from the website opens to Sales after 15 minutes (Program settings); until then Admins, customer service and fleet answer it.

## Send an offer without a request

Press **Send an offer** at the top of Bookings, or **Send an offer without a request** on Requests and offers. For a customer on the phone, by text or at the counter: no request needed.

The screen is seven short steps, each with one line saying what to do, and the price beside it (on a phone the total sits at the bottom of the screen: press **See every line**). What most offers never need is under each step''s **More options**, which stays open while something in it is used.

1. **Who is renting and when**: find the renter by name, phone or email, or press **Not on file? Add a new customer** (full legal name, mobile, email for the offer link, date of birth). A customer already on file with the same email or phone is shown with Use: one person, one record. Then the pickup and the return.
2. **Which car**: search by car code, plate or name; each car says Free or Not free for the dates. More options: the rate card and the type and free-only filters.
3. **Where they pick up and return**: at our location, we deliver or collect (the address and distance), an airport or the owner''s location. The fee each one makes shows under it, Automatic or Set by hand.
4. **How damage is covered**: the renter''s own insurance, a credit card or the Protection Plan. More options: another Protection Plan price.
5. **Extras**: add-ons, when the car has any.
6. **The price**: the rate sheet price is filled in. More options: another price (a total for the trip or a rate a day, with why), Amounts I type (before or after HST), the total the renter pays, kilometres, a promo code, the deposit and a discount (an Admin), and **Fees**: press **Change** to set one by hand, **Reset to automatic** to undo it. Below: how it is paid (card online and a card hold unless you change it under More options).
7. **Send it**: who found this client (sales and customer service), a message, and Text or Email. More options: how long the offer is open, the owner''s view, who found the client (an Admin) and the internal note. Above the button, **Ready to send** or **Missing:** with what is left; press Send and each missing field says what it needs. Press **Send the offer to** the renter, or **Save without sending** to keep it as a request for later. **The offer as the renter sees it** is under the price.

> Good to know: Choices drive the charges. Take off a delivery, a collection, the Protection Plan or an add-on and its fee goes with it, even a fee set by hand: there is nothing to remove in a second place. Choose it again and the fee starts from the automatic amount.

> Good to know: It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.

## Change an offer that is out

The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Open **More actions** on the booking and press **Edit the offer**.

1. Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed. Amounts I type (Before tax or After tax) and the Total the renter pays (after tax) work as on Send an offer.
2. Write what changed in Message to the renter and choose how long the offer is open.
3. Press **Save and send the update**: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press **Save without telling the renter** and tell them yourself.
4. A confirmed booking is changed with **Change the booking** (Propose a change, below).

> Tip: No need to withdraw first. **Withdraw the offer** is only for taking it back for good; **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## Edit a booking that has started

On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, **Edit the booking**, **Edit**.

1. Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking''s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.
2. Type why, if you like, and tick **Email the renter what changed**, or leave it off for a silent correction. Press **Save the changes**.
3. What is open now shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, **Charge** the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.

> Good to know: Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking''s history. A closed booking''s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.

## Fees, a forgotten fee and the balance

On the booking''s Money tab, Fees lists each fee. Press **Change or add a fee**.

1. Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.
2. Press **Save the fees**. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.
3. The renter sees the balance on their booking with a Pay button, and pays by card on Stripe''s form.

> Good to know: Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.

## A renter with only a debit or prepaid card

A credit card is required by default: the deposit must be on a credit card so the deductible can be charged. The pay page tells a renter with only a debit or prepaid card to contact us.

1. On the booking''s Money tab, press **Allow debit and prepaid cards for this booking** and type the reason. Who and when are kept, and the change is in the booking''s history.
2. The booking''s pay page, staff pay links and deposit hold then take a debit or prepaid card, and the renter is told the hold lowers the money available on the card until it is released, which can take several business days.
3. **Require a credit card again** turns it off.

The Money tab shows each card used and its type (credit, debit, prepaid). A booking on credit card rental coverage is always paid on the credit card that carries the coverage, and cannot be allowed. Program settings, **Card types accepted**, can open debit and prepaid cards to every booking.

## Correct a renter''s details

On the renter''s page (People, Renters) or on any of their bookings, **Edit renter**.

1. Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.
2. A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick **Email the renter a link to set a password** to send one there. Unsigned agreements and offers go to the new address.
3. Press **Save the renter**. An email that another renter has is refused with their name; the same phone is a warning.
4. The same person entered twice? Possible duplicates (same email, same phone, or same name and date of birth) shows under the renter. **Merge into this record** moves the other record''s bookings, licences, cards, payments, documents and messages here and fills any detail missing here; the other record stays, blocked, with the merge in both histories.

## Payments by part: the rental, the deposit and later charges

On the booking''s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.

1. **Record a payment**: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press **Record it**. The renter gets a receipt; **Print** prints one to hand over.
2. **Collect a card**: a payment (Everything open by default: the rental, the fees and any later charge in one), the deposit hold or saving the card. The renter types the card in Stripe''s secure form: on this device (**Open the card form**, then hand it over) or by a link texted or emailed to them (**Send the link**; by text first when the renter has a mobile number). Staff never type a card number.
3. Before every pickup the deposit hold link is texted to the renter on its own: 24 hours before (at once when the pickup is sooner), for a confirmed booking whose deposit is a card hold with no hold yet. The Money tab says **Deposit link texted** and when it was opened; the ready check shows it too. The hold is still needed before the keys. No mobile number, or the text not sent: a task **Deposit link not sent**. **Settings**, then Site settings, Deposit link by text: on or off, and the hours.
4. A deposit hold lasts about 7 days and shows the days left; while the car is out it is collected by itself before it lapses. After the return, settle the deposit (below). **Capture the hold** for all of it keeps the money; a part capture or **Release the hold** waits for the settlement while the car is out or something is open (an Admin may do it with the reason).
5. **Charge the saved card** (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter''s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.
6. An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press **Confirm the booking**).
7. A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press **Returned** with the reference or receipt number.

> Good to know: Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.

## Settle the deposit

The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking''s Money tab, under Deposit, press **Settle the deposit**. Issue the Check-in statement first.

1. The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.
2. Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.
3. Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.
4. Damage: **Keep the whole deposit (damage)** turns what is left of the deposit into a damage charge, with what was damaged and the photos; the renter is told. **Bill damage** adds a damage charge up to the $2,500 deductible (more goes through a claim): the deposit pays first, then the card on file.
5. Press **Settle**. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.

> Good to know: A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Email the renter** and **More actions**, the menu with **Edit the offer**, **Stop blocking the calendar**, **Cancel for the renter**, **Cancel by CarmaCars** and the rest.
5. Under the booking number: **Next step**, what happens next and who does it, with one button for that step (for example **Send the offer**, **Sign on this device** or **Check out the car**); then where the booking is on its way, from Request to Closed, with the dates, the days, the total and who pays.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10065; pins: 2 50.0 46.6, 4 85.4 14.5, 5 22.9 26.8")

## Check a car out or in

From the booking, with your phone or a tablet: the same checklist field staff use.

1. A confirmed booking shows **Check out (pickup)** under Check-out, check-in and signing; a booking on rent shows **Check in (return)**. Today lists the check-outs and check-ins due, each with **Check out** or **Check in**.
2. The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.
3. Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.
4. A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press **See the photo report**.

> Tip: Fleet, Sales and Customer service check cars out and in the same way from their own booking page.

## The photo report, late returns and the return charges

Under Check-out, check-in and signing, press **Photo report**.

1. The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.
2. At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.
3. Not charging one? Press **Waive** beside it and give the reason: it stays waived if the charges are worked out again.
4. The time was wrong? Press **Correct the check-in time** (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.
5. The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.

## Signatures on the spot, or by link

The renter or an additional driver signs the rental agreement on your device, or on their own phone.

1. While a signature is missing, the booking shows **Sign now on this device**, **Email the signing link** and **Text the signing link**.
2. No agreement made yet (the renter has not saved their details at home)? **Sign now on this device** still shows: press **Prepare the agreement to sign now** and it is made on the spot.
3. **Sign now on this device**: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press **Hand the device to** and their name.
4. They read both agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign. Then **Back to the staff view** for the next signer.
5. The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy''s signature record page.

## Rental agreements: every version, every field

The booking''s Rental agreements card: the current version of CarmaCars'' and Blind Spot''s agreements, every earlier one, and what is still blank.

1. Once the agreement is signed and countersigned, any change to what it prints makes a new version of both documents by itself: the dates, the price lines, the car, a driver added or corrected, the coverage, the deposit or how it was paid, an address.
2. A change to the dates, the price, the car, the drivers or the coverage option is signed again: the renter (and each driver it affects) gets their link by email and text, and the card shows "Agreement v3 waiting for signature". A correction (a typo in an address, a plate written differently) is filed without signing; the renter gets the corrected copy by email.
3. Check-out makes the "as picked up" copy (time out, km out, fuel out, the car''s plate and VIN, the check-out report), countersigned by whoever checked the car out; check-in makes the closing copy (time in, km in, driven and charged, fuel in, late hours, damage, the return charges, the final totals). Both go to the renter by email.
4. **Every version** lists each one with what changed and both PDFs. **Resend the signing links**, or press the button with their first name beside it to have them sign on your phone or tablet.
5. The card lists what the agreements still print blank (a licence expiry, the insurer''s policy number, the insured vehicle, a VIN). Type the values and press **Save the missing fields**: the agreements follow.
6. Check-out stops while a field a claim needs is blank. An Admin can let it go ahead: type the reason and press **Override**; the reason is in the booking''s history.
7. **Make the agreements again** checks both against the booking at once (they also follow every change by themselves).
8. **Edit the wording** (Admin only) changes CarmaCars'' agreement text for this booking: press **Change** beside a clause, edit its text, say why and press **Save the wording**; **Add** writes Additional terms at the end of Part 2. Only clauses not required by law or the insurer can be removed; the consents are fixed, and Blind Spot''s form (the insurer''s official form) is never changed. Before the renter signs, the agreement is made again; after, the change is a new version they sign, and **Every version** shows each clause before and after.

## Signing that holds up in a dispute

Every signature on the site is made the same way: rental agreements, amendments and new versions (remotely or on your device), and the owner agreements, schedules and forms, a co-owner''s link, the partner, investment and staff agreements.

1. The licence on file is shown. A 6-digit code to their phone or email on file is optional: the signer may press **Verify by code (optional)**, and Program settings, E-signing, **ask for a one-time code** makes it a required first step again (off by default). Without the code, the certificate says the identity was not confirmed by a code.
2. They say they read the documents, initial the key terms (each initials box is saved with **Save initials**; **Clear** takes it back to initial again) (damage and the deductible, the deposit and later charges, fuel, kilometres and late returns, their coverage, cancellation), give three consents (to sign electronically, to receive records electronically, to card charges under the agreement) and draw their signature.
3. Owners, partners, investors and staff do the same for their documents: the code, the reading, the key terms of their documents initialled (for example the Enrollment Agreement''s three confirmations, Form C''s acknowledgments, Schedule C, the staff agreement''s confidentiality), two consents and the drawn signature. Form C''s witness still types their name beside the owner.
4. Each step is recorded with its time, IP address and device, and the place when the device shares it. The signed PDFs end with a certificate of completion; anyone can check a signed file at `carmacars.ca/verify`.
5. Typed names are off. For a signer who cannot draw, an Admin can turn on the accessibility fallback: **Settings** > **Program**, Esign typed fallback.

## Card disputes: the evidence pack

Everything that proves the rental, in one PDF for Stripe.

1. When a card payment is disputed, the evidence pack is built by itself: the signed agreements with their certificates, the check-out and check-in reports with photos, kilometres and fuel, the licence, the payments and charges, every message to the renter, and the card checks from Stripe. It is staged in Stripe as the dispute''s evidence, and To do gets an urgent task.
2. Open the booking: the Rental agreements card shows the pack. Press **Download** to check it, then **Submit to Stripe** before the evidence date.
3. **Build the dispute evidence pack** makes one at any time (an Admin or Finance).

## The licence before an offer is accepted

Front, back and a selfie, from the request on.

1. After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.
2. The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.
3. Review the images as usual with **Review documents**: the card Renter documents is on Review and offer too.
4. The switch is in **Settings** > **Program**, Booking requests and offers: Booking licence required (on), with the selfie (on).

## Renter documents: licence and proof of coverage

A renter''s licence photos, selfie and proof of coverage (OPCF 27 or a credit card''s rental coverage) are checked before the handover. You check them yourself; no task is needed.

1. A booking with documents waiting is a line on To do: "Check ''s documents for booking ", marked Now when the pickup is within two days. Press **Review documents**.
2. The pop-up shows each driver''s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.
3. What to check is written once at the top. One wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**: they are asked for a new one.
4. Then press **Approve all**: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. Anything the system refuses is named with the reason.
5. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-out (photos and four checks): the history says "checked in person". Field staff also review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from My jobs, with the same Approve all or a reason to reject: the history says the reviewer''s role, field. Sales review the licence images (not the coverage) of any booking being arranged or under way from their To do or the booking, with the same Approve all or a reason to reject: the history says the role, sales.

## Payments by day

**Money** > **Payments**, the **By day** tab: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.

1. Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press **Show**.
2. Totals by method and for each day; cards read as the card and its last four digits, never a code.
3. The cash drawer: expected (cash in less cash given back) against the count Finance records with **Record the count**; a difference shows over or short.
4. Refunds waiting: every refund asked for anywhere with the policy maths. **Approve** or **Decline** with the reason in the row, then **Issue the refund**.
5. **Export CSV** for the bookkeeper.

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-97008b21.jpg "desktop; size: 1200 520; address: carmacars.ca/admin/bookings/CC-10065?tab=changes; pins: 1 17.5 33.7, 2 9.2 50.0, 3 38.3 71.2, 4 12.9 91.9")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Good to know: A request keeps the lead-time adjustment of the moment it came in ("Short-notice pricing +10%" or "Booked ahead −5%"), through the offer and the payment. To change it, open the booking''s review screen, **More options**, **Lead-time pricing (%)**: a number (0 for none), or empty for the tier of the request. A price typed by hand replaces it.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.

## Review requests

Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.

| Message | When |
| --- | --- |
| Mid-trip check-in | Rentals of 2 days or more, 24 hours after the pickup: "How is the car? Reply or call if anything is off." No review ask. |
| Review request | 1 hour after the check-in. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google. |
| Reminder | 24 hours after the request. |
| Final follow-up | 7 days after the request. Nothing more after it. |

1. The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.
2. **Ask for a review** sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.
3. On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press **Send anyway** to send it now.
4. **Mark reviewed** stops the messages when the renter tells you they already reviewed.

The messages also stop by themselves when the renter presses "I already left a review", leaves a review on the site, unsubscribes, or a Google review is matched to them. **Bookings** > **Reviews** has the numbers (requests sent, on hold, reviews detected, the average rating), the hold list and the Google reviews to match.

> Tip: The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees "Something wasn''t right? Tell us directly".

## What the owner sees, and owner deductions

Each booking on an owner''s or partner''s car shows the card What the owner sees at the top of its page.

1. **Hide from the owner** keeps the booking''s revenue from the owner until the car is returned, or until the owner statement covering it is approved. The owner sees the booking as Booked with its dates, and the calendar still shows the car busy. Add a reason if you like: it is kept in the history.
2. **Show to the owner** shows it now. Approving the statement shows every hidden booking on it by itself.
3. Not shown to the owner is for a booking with no owner revenue (an insurance placeholder, a shareholder''s or the owner''s own use at no charge): the owner sees only that the car is unavailable for those dates. A booking with revenue cannot be set this way.
4. Add a rental and Send an offer have What the owner sees. It starts from Settings > Program, Owners and fleet: Owners see a booking''s revenue (right away by default).
5. On the Money tab, Owner deductions on this booking: **Add a booking expense** (cleaning, repair, fuel, platform fee or other, the amount, the reason the owner reads, a receipt number) comes off before Owner Revenue.
6. **Set the Revenue Share for this booking** applies within the car''s signed terms. Above the terms only an Admin can, with Above the signed terms ticked and the reason. **Back to the car''s terms** undoes it.
7. Add a rental has the same under The car''s owner.

> Good to know: The owner''s statement always includes every booking at its true amounts and lists each deduction with its reason, so the payout is always right. Customer service and sales add deductions only while Program settings let them change fees.

## Email the renter or the adjuster

Press **Email the renter** at the top of a booking, or open its **Messages** tab.

1. Write a **Subject** and a **Message**, or pick a **Quick reply** to start from (Settings > Quick replies keeps them).
2. Press **Email the renter**. It goes from CarmaCars (bookings@carmacars.ca) and replies come back to the bookings inbox. The renter also sees it in their account and can answer there.
3. On a booking an insurer pays, choose **From**: CarmaCars, or Blind Spot Car Rental (insurance). **Email the adjuster** writes to the adjuster''s email on the booking (Insurance claim), always from Blind Spot Car Rental.

The Messages tab shows what you and the renter wrote, newest first, with who wrote it, and every email of the booking with its state (waiting, sent, failed). Each email you send is also in the History tab with your name.

> Good to know: Emails go out through the same daily limit as every email (the line under the form shows today''s use). A message to a renter goes before digests and marketing; past the limit it waits until midnight. To write to a renter from **People** > **Renters**, open the renter: Email the renter is at the bottom, about their latest booking or the one you pick.

### Record the pickup or the return now (details later)
When the car went out or came back but the checklist could not be done (no photos, no time, the renter dropped the keys), the booking''s **Check-out, check-in and signing** card has **Record the pickup now (details later)** on a confirmed booking and **Record the return now (details later)** while the car is on rent. Give the actual time (now, or earlier), the odometer and fuel if you know them, and why. The booking moves on (on rent, or returned), late return charges follow the actual time, and Fleet gets the task **Add the photos and readings for CC-...**. Once returned, the statement can be issued and the deposit settled; releasing the deposit before the photos are in needs an Admin and a reason. A pickup without the deposit taken needs an Admin to waive it with a reason, and without the renter''s signature on the check-out report an Admin''s reason too. Later, **Add the check-out (or check-in) photos and readings** opens the usual checklist (photos, readings, your signature): the task closes when it is saved.

The Agreement card says **Waiting for the renter''s details** when the renter still has blanks to fill (date of birth, address, mobile, licence, coverage): their account asks for them before signing and paying. No email or text is sent.

### Find a booking
**Bookings** has one search box: type the booking number (CC-1042, cc1042 or just 1042), the renter''s or a driver''s name, an email, a phone number in any format, a plate (spaces do not matter) or a car code, then press Enter. The status filters still apply to what is found.

### Record a card payment taken outside the site
A card taken in the Stripe Dashboard, or on a card reader, is recorded on the booking''s **Money** tab with **Record card payment**.

1. Choose what it paid: **Rental and fees**, **Rental**, **Fees**, **Later charges** or **Deposit hold**, and where it was taken.
2. Type the **Last 4 digits** and the amount. A Stripe payment id (pi_... or ch_..., from the payment in the Stripe Dashboard) is optional for a payment: press **Look up** and the amount and last 4 digits are checked against Stripe.
3. Press **Record it**. A payment confirms a booking waiting for payment, as any payment does.

> Good to know: A deposit hold needs its Stripe payment id, so it can be captured or released from **Settle the deposit**. It is recorded as held, with the usual release reminders. A hold on a reader lapses after 2 days, one made online after 7.

### Charge or hold the deposit on the card reader
With the S700 paired (Settings > Card reader), the **Money** tab has **Charge on reader** (everything open, the rental, the fees or a later charge) and **Hold deposit on reader**. Press **Send to the reader**: the amount shows on the reader and the renter taps, inserts or swipes the card. The screen updates by itself; **Cancel** stops the reader and nothing is charged. A deposit hold is captured or released from Settle the deposit like any hold.

### Credit card coverage: the same card
When the renter''s coverage is their credit card, the whole rental (rental and fees) is paid on that same card. The Money tab says which card. Another card on the pay page is refused and refunded at once; on the reader it is refused before the money is taken; a payment by e-Transfer, cash or the like is refused; a card typed by hand needs its last 4 digits and the box **This is the same card**. Deposits and later charges can go on any card. If the renter truly has to use another card or method, press **Allow another card** and give the reason (an Admin).', 'Requests, offers and bookings', 'See what is out, coming back and owed now; send an offer with or without a request, change it in place, take payments by part, run a booking.',
  'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.

## Bookings now: what is out, coming back and owed

Open **Bookings**. It opens on **Now**, one screen that refreshes by itself every 30 seconds. Every time is Toronto time.

1. The numbers at the top: cars out now, due back today, overdue, going out in the next 72 hours, payments due in the next 7 days (with the total) and free cars. Tap one to jump to its list.
2. **Out now**: every car on rent, overdue returns first in red. Each shows the car (photo, code, plate), the renter with **Call** and **Text**, when it was picked up, when it is due back with a countdown, the payment plan and the next payment, the deposit held, and the km and fuel at pickup. Filter by Overdue, Due today or Payment due.
3. A confirmed booking whose pickup time has passed with no check-out recorded is listed as out, with **Out (pickup not recorded)**. The car most likely left. Press **Mark picked up**: it records the pickup at the booked time (change it if the car left at another time), the booking goes on rent, and Fleet gets a task to add the photos, km and fuel. The usual checks stay: the deposit taken (or an Admin waives it with the reason), the renter''s signature (or an Admin''s reason), the agreement''s details, every driver verified and the coverage confirmed. If one is missing, the reason is shown.
4. **Coming back**: overdue, today and tomorrow, by the time each is due.
5. **Going out**: confirmed pickups in the next 72 hours, delivery or pickup, with ticks and crosses for the licence, the signed agreement, the payment, the deposit (a clock until the morning of the pickup day, when the hold is placed on the card on file) and the check-out photos (done at the handover).
6. **Money due**: every rental payment due in the next 7 days or overdue, the amount, the plan and which payment it is (for example 3 of 4).
7. **Free now**: cars available and not out, the longest idle first, with the next pickup; then the cars in maintenance or cleaning. Partners'' cars are counted apart.

> Good to know: Placeholder bookings never show on Now.

### Payment plans

A rental is paid in full at pickup, weekly, every 2 weeks, or monthly. A rental longer than one period (30 days) pays each period by itself. To change it, open the booking, then the **Payment plan** card on Overview or Money, and press **Change the plan**. Each payment is its share of the total by its days, due on the day it starts. An insurer-billed rental shows **Insurer billed** and is never in Money due unless the renter owes a part. Admins, customer service and finance change the plan; fleet sees it.

## All bookings

The **All bookings** tab of Bookings has the search (booking number, name, email, phone, plate or car code), the status (All, Out now, Booked, Returned, Closed, Cancelled) and **Bill to** (All, Renter, Insurer). **Out now** shows the bookings on rent and those whose pickup passed without a check-out, together. Each booking is one row: its number and status in plain words, the car with its photo, the renter with **Call** and **Text**, the dates, the money (paid up, to pay, overdue, insurer billed) and Bill to.

## The request queue

Open **Bookings** > **Requests and offers**. The oldest waiting request is at the top.

1. The numbers at the top: waiting for an offer, past the reply target (red), offers out, accepted but not paid, and offers expired.
2. One queue, the most urgent first: the longest wait, then offers accepted but not paid, then offers out by when they expire. Each row has the car with its photo, the dates, the price, the renter with **Call** and **Text**, the licence (verified, to review, or not uploaded yet), who is answering it, and one button: **Send offer**, **Follow up** or **Open**. **Decline** sits beside **Send offer**.
3. Waiting shows how long the renter has waited ("12 min", "3 h", "2 days"); red means past the first reply target (5 minutes, set in Program settings). **Promise** counts down the 2 hours the site promises the renter.
4. Filter by Active, New, Asked the renter, Changes asked, Offer out, Not paid or Expired. An expired offer leaves the active queue 48 hours after it expired, or once its pickup time passed; Expired lists them all. An offer still out when its pickup time passes expires by itself.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 38.9 29.9, 2 22.2 43.3")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates (under **Show rate card**) and fees, the deposit and extras. A place changed away from a delivery or a collection takes its fee box and its fee with it.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-353f3707.jpg "desktop; size: 1200 1550; address: carmacars.ca/admin/bookings/CC-10069?tab=review; pins: 1 5.0 6.5, 2 7.5 45.8, 3 74.2 42.6, 4 76.7 98.1")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-4dd4ed06.jpg "desktop; size: 500 80; address: carmacars.ca/admin/bookings/CC-10069?tab=review; pins: 6 41.2 52.5, 7 18.0 52.5")

Opening a request takes it for you: everyone else sees "Being answered by" your name and since when, with Send the offer and Decline off, until you send, decline or leave (20 minutes, renewed while you work; Program settings). Press **Take over** to answer one someone else holds; it is noted in the history. A second answer is refused with who answered and when. A request from the website opens to Sales after 15 minutes (Program settings); until then Admins, customer service and fleet answer it.

## Send an offer without a request

Press **Send an offer** at the top of Bookings, or **Send an offer without a request** on Requests and offers. For a customer on the phone, by text or at the counter: no request needed.

The screen is seven short steps, each with one line saying what to do, and the price beside it (on a phone the total sits at the bottom of the screen: press **See every line**). What most offers never need is under each step''s **More options**, which stays open while something in it is used.

1. **Who is renting and when**: find the renter by name, phone or email, or press **Not on file? Add a new customer** (full legal name, mobile, email for the offer link, date of birth). A customer already on file with the same email or phone is shown with Use: one person, one record. Then the pickup and the return.
2. **Which car**: search by car code, plate or name; each car says Free or Not free for the dates. More options: the rate card and the type and free-only filters.
3. **Where they pick up and return**: at our location, we deliver or collect (the address and distance), an airport or the owner''s location. The fee each one makes shows under it, Automatic or Set by hand.
4. **How damage is covered**: the renter''s own insurance, a credit card or the Protection Plan. More options: another Protection Plan price.
5. **Extras**: add-ons, when the car has any.
6. **The price**: the rate sheet price is filled in. More options: another price (a total for the trip or a rate a day, with why), Amounts I type (before or after HST), the total the renter pays, kilometres, a promo code, the deposit and a discount (an Admin), and **Fees**: press **Change** to set one by hand, **Reset to automatic** to undo it. Below: how it is paid (card online and a card hold unless you change it under More options).
7. **Send it**: who found this client (sales and customer service), a message, and Text or Email. More options: how long the offer is open, the owner''s view, who found the client (an Admin) and the internal note. Above the button, **Ready to send** or **Missing:** with what is left; press Send and each missing field says what it needs. Press **Send the offer to** the renter, or **Save without sending** to keep it as a request for later. **The offer as the renter sees it** is under the price.

> Good to know: Choices drive the charges. Take off a delivery, a collection, the Protection Plan or an add-on and its fee goes with it, even a fee set by hand: there is nothing to remove in a second place. Choose it again and the fee starts from the automatic amount.

> Good to know: It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.

## Change an offer that is out

The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Open **More actions** on the booking and press **Edit the offer**.

1. Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed. Amounts I type (Before tax or After tax) and the Total the renter pays (after tax) work as on Send an offer.
2. Write what changed in Message to the renter and choose how long the offer is open.
3. Press **Save and send the update**: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press **Save without telling the renter** and tell them yourself.
4. A confirmed booking is changed with **Change the booking** (Propose a change, below).

> Tip: No need to withdraw first. **Withdraw the offer** is only for taking it back for good; **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## Edit a booking that has started

On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, **Edit the booking**, **Edit**.

1. Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking''s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.
2. Type why, if you like, and tick **Email the renter what changed**, or leave it off for a silent correction. Press **Save the changes**.
3. What is open now shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, **Charge** the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.

> Good to know: Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking''s history. A closed booking''s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.

## Fees, a forgotten fee and the balance

On the booking''s Money tab, Fees lists each fee. Press **Change or add a fee**.

1. Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.
2. Press **Save the fees**. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.
3. The renter sees the balance on their booking with a Pay button, and pays by card on Stripe''s form.

> Good to know: Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.

## A renter with only a debit or prepaid card

A credit card is required by default: the deposit must be on a credit card so the deductible can be charged. The pay page tells a renter with only a debit or prepaid card to contact us.

1. On the booking''s Money tab, press **Allow debit and prepaid cards for this booking** and type the reason. Who and when are kept, and the change is in the booking''s history.
2. The booking''s pay page, staff pay links and deposit hold then take a debit or prepaid card, and the renter is told the hold lowers the money available on the card until it is released, which can take several business days.
3. **Require a credit card again** turns it off.

The Money tab shows each card used and its type (credit, debit, prepaid). A booking on credit card rental coverage is always paid on the credit card that carries the coverage, and cannot be allowed. Program settings, **Card types accepted**, can open debit and prepaid cards to every booking.

## Correct a renter''s details

On the renter''s page (People, Renters) or on any of their bookings, **Edit renter**.

1. Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.
2. A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick **Email the renter a link to set a password** to send one there. Unsigned agreements and offers go to the new address.
3. Press **Save the renter**. An email that another renter has is refused with their name; the same phone is a warning.
4. The same person entered twice? Possible duplicates (same email, same phone, or same name and date of birth) shows under the renter. **Merge into this record** moves the other record''s bookings, licences, cards, payments, documents and messages here and fills any detail missing here; the other record stays, blocked, with the merge in both histories.

## Payments by part: the rental, the deposit and later charges

On the booking''s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.

1. **Record a payment**: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press **Record it**. The renter gets a receipt; **Print** prints one to hand over.
2. **Collect a card**: a payment (Everything open by default: the rental, the fees and any later charge in one), the deposit hold or saving the card. The renter types the card in Stripe''s secure form: on this device (**Open the card form**, then hand it over) or by a link texted or emailed to them (**Send the link**; by text first when the renter has a mobile number). Staff never type a card number.
3. Before every pickup the deposit hold link is texted to the renter on its own: 24 hours before (at once when the pickup is sooner), for a confirmed booking whose deposit is a card hold with no hold yet. The Money tab says **Deposit link texted** and when it was opened; the ready check shows it too. The hold is still needed before the keys. No mobile number, or the text not sent: a task **Deposit link not sent**. **Settings**, then Site settings, Deposit link by text: on or off, and the hours.
4. A deposit hold lasts about 7 days and shows the days left; while the car is out it is collected by itself before it lapses. After the return, settle the deposit (below). **Capture the hold** for all of it keeps the money; a part capture or **Release the hold** waits for the settlement while the car is out or something is open (an Admin may do it with the reason).
5. **Charge the saved card** (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter''s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.
6. An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press **Confirm the booking**).
7. A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press **Returned** with the reference or receipt number.

> Good to know: Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.

## Settle the deposit

The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking''s Money tab, under Deposit, press **Settle the deposit**. Issue the Check-in statement first.

1. The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.
2. Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.
3. Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.
4. Damage: **Keep the whole deposit (damage)** turns what is left of the deposit into a damage charge, with what was damaged and the photos; the renter is told. **Bill damage** adds a damage charge up to the $2,500 deductible (more goes through a claim): the deposit pays first, then the card on file.
5. Press **Settle**. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.

> Good to know: A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Email the renter** and **More actions**, the menu with **Edit the offer**, **Stop blocking the calendar**, **Cancel for the renter**, **Cancel by CarmaCars** and the rest.
5. Under the booking number: **Next step**, what happens next and who does it, with one button for that step (for example **Send the offer**, **Sign on this device** or **Check out the car**); then where the booking is on its way, from Request to Closed, with the dates, the days, the total and who pays.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10065; pins: 2 50.0 46.6, 4 85.4 14.5, 5 22.9 26.8")

## Check a car out or in

From the booking, with your phone or a tablet: the same checklist field staff use.

1. A confirmed booking shows **Check out (pickup)** under Check-out, check-in and signing; a booking on rent shows **Check in (return)**. Today lists the check-outs and check-ins due, each with **Check out** or **Check in**.
2. The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.
3. Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.
4. A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press **See the photo report**.

> Tip: Fleet, Sales and Customer service check cars out and in the same way from their own booking page.

## The photo report, late returns and the return charges

Under Check-out, check-in and signing, press **Photo report**.

1. The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.
2. At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.
3. Not charging one? Press **Waive** beside it and give the reason: it stays waived if the charges are worked out again.
4. The time was wrong? Press **Correct the check-in time** (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.
5. The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.

### The renter says the car is back

Every overdue email, text and alert (at the return time, at 15 minutes and the final notice) has a one-tap **I''ve returned the car** link, and the renter''s booking page has the button. The renter can add photos, the odometer, the fuel level and the time they returned it. Sending it stops every overdue notice of the booking at once, the booking shows **Returned, waiting for confirmation**, and Fleet gets an urgent To do: "The renter says the car is back".

1. Open the booking. The card **The renter says the car is back** shows what the renter gave, marked renter-provided, with their photos.
2. Check the car: the return place, the tracker, the photos.
3. Press **Confirm** to complete the trip. Correct the odometer, fuel or return time first if they are wrong: the late charges follow the time you confirm. The renter''s photos join the check-in report.
4. Or press **Deny** and say why. The renter gets your reason by email and text, and the overdue notices start again.

Checking the car in the usual way also completes the trip and stops the notices. Admins, Fleet, Sales, Customer service and field staff can Confirm or Deny.

## Signatures on the spot, or by link

The renter or an additional driver signs the rental agreement on your device, or on their own phone.

1. While a signature is missing, the booking shows **Sign now on this device**, **Email the signing link** and **Text the signing link**.
2. No agreement made yet (the renter has not saved their details at home)? **Sign now on this device** still shows: press **Prepare the agreement to sign now** and it is made on the spot.
3. **Sign now on this device**: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press **Hand the device to** and their name.
4. They read both agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign. Then **Back to the staff view** for the next signer.
5. The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy''s signature record page.

## Rental agreements: every version, every field

The booking''s Rental agreements card: the current version of CarmaCars'' and Blind Spot''s agreements, every earlier one, and what is still blank.

1. Once the agreement is signed and countersigned, any change to what it prints makes a new version of both documents by itself: the dates, the price lines, the car, a driver added or corrected, the coverage, the deposit or how it was paid, an address.
2. A change to the dates, the price, the car, the drivers or the coverage option is signed again: the renter (and each driver it affects) gets their link by email and text, and the card shows "Agreement v3 waiting for signature". A correction (a typo in an address, a plate written differently) is filed without signing; the renter gets the corrected copy by email.
3. Check-out makes the "as picked up" copy (time out, km out, fuel out, the car''s plate and VIN, the check-out report), countersigned by whoever checked the car out; check-in makes the closing copy (time in, km in, driven and charged, fuel in, late hours, damage, the return charges, the final totals). Both go to the renter by email.
4. **Every version** lists each one with what changed and both PDFs. **Resend the signing links**, or press the button with their first name beside it to have them sign on your phone or tablet.
5. The card lists what the agreements still print blank (a licence expiry, the insurer''s policy number, the insured vehicle, a VIN). Type the values and press **Save the missing fields**: the agreements follow.
6. Check-out stops while a field a claim needs is blank. An Admin can let it go ahead: type the reason and press **Override**; the reason is in the booking''s history.
7. **Make the agreements again** checks both against the booking at once (they also follow every change by themselves).
8. **Edit the wording** (Admin only) changes CarmaCars'' agreement text for this booking: press **Change** beside a clause, edit its text, say why and press **Save the wording**; **Add** writes Additional terms at the end of Part 2. Only clauses not required by law or the insurer can be removed; the consents are fixed, and Blind Spot''s form (the insurer''s official form) is never changed. Before the renter signs, the agreement is made again; after, the change is a new version they sign, and **Every version** shows each clause before and after.

## Signing that holds up in a dispute

Every signature on the site is made the same way: rental agreements, amendments and new versions (remotely or on your device), and the owner agreements, schedules and forms, a co-owner''s link, the partner, investment and staff agreements.

1. The licence on file is shown. A 6-digit code to their phone or email on file is optional: the signer may press **Verify by code (optional)**, and Program settings, E-signing, **ask for a one-time code** makes it a required first step again (off by default). Without the code, the certificate says the identity was not confirmed by a code.
2. They say they read the documents, initial the key terms (each initials box is saved with **Save initials**; **Clear** takes it back to initial again) (damage and the deductible, the deposit and later charges, fuel, kilometres and late returns, their coverage, cancellation), give three consents (to sign electronically, to receive records electronically, to card charges under the agreement) and draw their signature.
3. Owners, partners, investors and staff do the same for their documents: the code, the reading, the key terms of their documents initialled (for example the Enrollment Agreement''s three confirmations, Form C''s acknowledgments, Schedule C, the staff agreement''s confidentiality), two consents and the drawn signature. Form C''s witness still types their name beside the owner.
4. Each step is recorded with its time, IP address and device, and the place when the device shares it. The signed PDFs end with a certificate of completion; anyone can check a signed file at `carmacars.ca/verify`.
5. Typed names are off. For a signer who cannot draw, an Admin can turn on the accessibility fallback: **Settings** > **Program**, Esign typed fallback.

## Card disputes: the evidence pack

Everything that proves the rental, in one PDF for Stripe.

1. When a card payment is disputed, the evidence pack is built by itself: the signed agreements with their certificates, the check-out and check-in reports with photos, kilometres and fuel, the licence, the payments and charges, every message to the renter, and the card checks from Stripe. It is staged in Stripe as the dispute''s evidence, and To do gets an urgent task.
2. Open the booking: the Rental agreements card shows the pack. Press **Download** to check it, then **Submit to Stripe** before the evidence date.
3. **Build the dispute evidence pack** makes one at any time (an Admin or Finance).

## The licence before an offer is accepted

Front, back and a selfie, from the request on.

1. After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.
2. The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.
3. Review the images as usual with **Review documents**: the card Renter documents is on Review and offer too.
4. The switch is in **Settings** > **Program**, Booking requests and offers: Booking licence required (on), with the selfie (on).

## Renter documents: licence and proof of coverage

A renter''s licence photos, selfie and proof of coverage (OPCF 27 or a credit card''s rental coverage) are checked before the handover. You check them yourself; no task is needed.

1. A booking with documents waiting is a line on To do: "Check ''s documents for booking ", marked Now when the pickup is within two days. Press **Review documents**.
2. The pop-up shows each driver''s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.
3. What to check is written once at the top. One wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**: they are asked for a new one.
4. Then press **Approve all**: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. Anything the system refuses is named with the reason.
5. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-out (photos and four checks): the history says "checked in person". Field staff also review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from My jobs, with the same Approve all or a reason to reject: the history says the reviewer''s role, field. Sales review the licence images (not the coverage) of any booking being arranged or under way from their To do or the booking, with the same Approve all or a reason to reject: the history says the role, sales.

## Payments by day

**Money** > **Payments**, the **By day** tab: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.

1. Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press **Show**.
2. Totals by method and for each day; cards read as the card and its last four digits, never a code.
3. The cash drawer: expected (cash in less cash given back) against the count Finance records with **Record the count**; a difference shows over or short.
4. Refunds waiting: every refund asked for anywhere with the policy maths. **Approve** or **Decline** with the reason in the row, then **Issue the refund**.
5. **Export CSV** for the bookkeeper.

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-97008b21.jpg "desktop; size: 1200 520; address: carmacars.ca/admin/bookings/CC-10065?tab=changes; pins: 1 17.5 33.7, 2 9.2 50.0, 3 38.3 71.2, 4 12.9 91.9")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Good to know: A request keeps the lead-time adjustment of the moment it came in ("Short-notice pricing +10%" or "Booked ahead −5%"), through the offer and the payment. To change it, open the booking''s review screen, **More options**, **Lead-time pricing (%)**: a number (0 for none), or empty for the tier of the request. A price typed by hand replaces it.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.

## Review requests

Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.

| Message | When |
| --- | --- |
| Mid-trip check-in | Rentals of 2 days or more, 24 hours after the pickup: "How is the car? Reply or call if anything is off." No review ask. |
| Review request | 1 hour after the check-in. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google. |
| Reminder | 24 hours after the request. |
| Final follow-up | 7 days after the request. Nothing more after it. |

1. The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.
2. **Ask for a review** sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.
3. On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press **Send anyway** to send it now.
4. **Mark reviewed** stops the messages when the renter tells you they already reviewed.

The messages also stop by themselves when the renter presses "I already left a review", leaves a review on the site, unsubscribes, or a Google review is matched to them. **Bookings** > **Reviews** has the numbers (requests sent, on hold, reviews detected, the average rating), the hold list and the Google reviews to match.

> Tip: The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees "Something wasn''t right? Tell us directly".

## What the owner sees, and owner deductions

Each booking on an owner''s or partner''s car shows the card What the owner sees at the top of its page.

1. **Hide from the owner** keeps the booking''s revenue from the owner until the car is returned, or until the owner statement covering it is approved. The owner sees the booking as Booked with its dates, and the calendar still shows the car busy. Add a reason if you like: it is kept in the history.
2. **Show to the owner** shows it now. Approving the statement shows every hidden booking on it by itself.
3. Not shown to the owner is for a booking with no owner revenue (an insurance placeholder, a shareholder''s or the owner''s own use at no charge): the owner sees only that the car is unavailable for those dates. A booking with revenue cannot be set this way.
4. Add a rental and Send an offer have What the owner sees. It starts from Settings > Program, Owners and fleet: Owners see a booking''s revenue (right away by default).
5. On the Money tab, Owner deductions on this booking: **Add a booking expense** (cleaning, repair, fuel, platform fee or other, the amount, the reason the owner reads, a receipt number) comes off before Owner Revenue.
6. **Set the Revenue Share for this booking** applies within the car''s signed terms. Above the terms only an Admin can, with Above the signed terms ticked and the reason. **Back to the car''s terms** undoes it.
7. Add a rental has the same under The car''s owner.

> Good to know: The owner''s statement always includes every booking at its true amounts and lists each deduction with its reason, so the payout is always right. Customer service and sales add deductions only while Program settings let them change fees.

## Email the renter or the adjuster

Press **Email the renter** at the top of a booking, or open its **Messages** tab.

1. Write a **Subject** and a **Message**, or pick a **Quick reply** to start from (Settings > Quick replies keeps them).
2. Press **Email the renter**. It goes from CarmaCars (bookings@carmacars.ca) and replies come back to the bookings inbox. The renter also sees it in their account and can answer there.
3. On a booking an insurer pays, choose **From**: CarmaCars, or Blind Spot Car Rental (insurance). **Email the adjuster** writes to the adjuster''s email on the booking (Insurance claim), always from Blind Spot Car Rental.

The Messages tab shows what you and the renter wrote, newest first, with who wrote it, and every email of the booking with its state (waiting, sent, failed). Each email you send is also in the History tab with your name.

> Good to know: Emails go out through the same daily limit as every email (the line under the form shows today''s use). A message to a renter goes before digests and marketing; past the limit it waits until midnight. To write to a renter from **People** > **Renters**, open the renter: Email the renter is at the bottom, about their latest booking or the one you pick.

### Record the pickup or the return now (details later)
When the car went out or came back but the checklist could not be done (no photos, no time, the renter dropped the keys), the booking''s **Check-out, check-in and signing** card has **Record the pickup now (details later)** on a confirmed booking and **Record the return now (details later)** while the car is on rent. Give the actual time (now, or earlier), the odometer and fuel if you know them, and why. The booking moves on (on rent, or returned), late return charges follow the actual time, and Fleet gets the task **Add the photos and readings for CC-...**. Once returned, the statement can be issued and the deposit settled; releasing the deposit before the photos are in needs an Admin and a reason. A pickup without the deposit taken needs an Admin to waive it with a reason, and without the renter''s signature on the check-out report an Admin''s reason too. Later, **Add the check-out (or check-in) photos and readings** opens the usual checklist (photos, readings, your signature): the task closes when it is saved.

The Agreement card says **Waiting for the renter''s details** when the renter still has blanks to fill (date of birth, address, mobile, licence, coverage): their account asks for them before signing and paying. No email or text is sent.

### Find a booking
**Bookings** has one search box: type the booking number (CC-1042, cc1042 or just 1042), the renter''s or a driver''s name, an email, a phone number in any format, a plate (spaces do not matter) or a car code, then press Enter. The status filters still apply to what is found.

### Record a card payment taken outside the site
A card taken in the Stripe Dashboard, or on a card reader, is recorded on the booking''s **Money** tab with **Record card payment**.

1. Choose what it paid: **Rental and fees**, **Rental**, **Fees**, **Later charges** or **Deposit hold**, and where it was taken.
2. Type the **Last 4 digits** and the amount. A Stripe payment id (pi_... or ch_..., from the payment in the Stripe Dashboard) is optional for a payment: press **Look up** and the amount and last 4 digits are checked against Stripe.
3. Press **Record it**. A payment confirms a booking waiting for payment, as any payment does.

> Good to know: A deposit hold needs its Stripe payment id, so it can be captured or released from **Settle the deposit**. It is recorded as held, with the usual release reminders. A hold on a reader lapses after 2 days, one made online after 7.

### Charge or hold the deposit on the card reader
With the S700 paired (Settings > Card reader), the **Money** tab has **Charge on reader** (everything open, the rental, the fees or a later charge) and **Hold deposit on reader**. Press **Send to the reader**: the amount shows on the reader and the renter taps, inserts or swipes the card. The screen updates by itself; **Cancel** stops the reader and nothing is charged. A deposit hold is captured or released from Settle the deposit like any hold.

### Credit card coverage: the same card
When the renter''s coverage is their credit card, the whole rental (rental and fees) is paid on that same card. The Money tab says which card. Another card on the pay page is refused and refunded at once; on the reader it is refused before the money is taken; a payment by e-Transfer, cash or the like is refused; a card typed by hand needs its last 4 digits and the box **This is the same card**. Deposits and later charges can go on any card. If the renter truly has to use another card or method, press **Allow another card** and give the reason (an Admin).',
  '<p class="gd-p">A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.</p><section class="gd-task" id="requests-offers-and-bookings-bookings-now-what-is-out-coming-back-and-owed" data-gd-task><h2 class="gd-h2">Bookings now: what is out, coming back and owed</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b>. It opens on <b class="gd-ui">Now</b>, one screen that refreshes by itself every 30 seconds. Every time is Toronto time.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The numbers at the top: cars out now, due back today, overdue, going out in the next 72 hours, payments due in the next 7 days (with the total) and free cars. Tap one to jump to its list.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Out now</b>: every car on rent, overdue returns first in red. Each shows the car (photo, code, plate), the renter with <b class="gd-ui">Call</b> and <b class="gd-ui">Text</b>, when it was picked up, when it is due back with a countdown, the payment plan and the next payment, the deposit held, and the km and fuel at pickup. Filter by Overdue, Due today or Payment due.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A confirmed booking whose pickup time has passed with no check-out recorded is listed as out, with <b class="gd-ui">Out (pickup not recorded)</b>. The car most likely left. Press <b class="gd-ui">Mark picked up</b>: it records the pickup at the booked time (change it if the car left at another time), the booking goes on rent, and Fleet gets a task to add the photos, km and fuel. The usual checks stay: the deposit taken (or an Admin waives it with the reason), the renter&#39;s signature (or an Admin&#39;s reason), the agreement&#39;s details, every driver verified and the coverage confirmed. If one is missing, the reason is shown.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Coming back</b>: overdue, today and tomorrow, by the time each is due.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Going out</b>: confirmed pickups in the next 72 hours, delivery or pickup, with ticks and crosses for the licence, the signed agreement, the payment, the deposit (a clock until the morning of the pickup day, when the hold is placed on the card on file) and the check-out photos (done at the handover).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Money due</b>: every rental payment due in the next 7 days or overdue, the amount, the plan and which payment it is (for example 3 of 4).</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><b class="gd-ui">Free now</b>: cars available and not out, the longest idle first, with the next pickup; then the cars in maintenance or cleaning. Partners&#39; cars are counted apart.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Placeholder bookings never show on Now.</div></aside><h3 class="gd-h3">Payment plans</h3><p class="gd-p">A rental is paid in full at pickup, weekly, every 2 weeks, or monthly. A rental longer than one period (30 days) pays each period by itself. To change it, open the booking, then the <b class="gd-ui">Payment plan</b> card on Overview or Money, and press <b class="gd-ui">Change the plan</b>. Each payment is its share of the total by its days, due on the day it starts. An insurer-billed rental shows <b class="gd-ui">Insurer billed</b> and is never in Money due unless the renter owes a part. Admins, customer service and finance change the plan; fleet sees it.</p></section><section class="gd-task" id="requests-offers-and-bookings-all-bookings" data-gd-task><h2 class="gd-h2">All bookings</h2><p class="gd-p">The <b class="gd-ui">All bookings</b> tab of Bookings has the search (booking number, name, email, phone, plate or car code), the status (All, Out now, Booked, Returned, Closed, Cancelled) and <b class="gd-ui">Bill to</b> (All, Renter, Insurer). <b class="gd-ui">Out now</b> shows the bookings on rent and those whose pickup passed without a check-out, together. Each booking is one row: its number and status in plain words, the car with its photo, the renter with <b class="gd-ui">Call</b> and <b class="gd-ui">Text</b>, the dates, the money (paid up, to pay, overdue, insurer billed) and Bill to.</p></section><section class="gd-task" id="requests-offers-and-bookings-the-request-queue" data-gd-task><h2 class="gd-h2">The request queue</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests and offers</b>. The oldest waiting request is at the top.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The numbers at the top: waiting for an offer, past the reply target (red), offers out, accepted but not paid, and offers expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">One queue, the most urgent first: the longest wait, then offers accepted but not paid, then offers out by when they expire. Each row has the car with its photo, the dates, the price, the renter with <b class="gd-ui">Call</b> and <b class="gd-ui">Text</b>, the licence (verified, to review, or not uploaded yet), who is answering it, and one button: <b class="gd-ui">Send offer</b>, <b class="gd-ui">Follow up</b> or <b class="gd-ui">Open</b>. <b class="gd-ui">Decline</b> sits beside <b class="gd-ui">Send offer</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Waiting shows how long the renter has waited (&quot;12 min&quot;, &quot;3 h&quot;, &quot;2 days&quot;); red means past the first reply target (5 minutes, set in Program settings). <b class="gd-ui">Promise</b> counts down the 2 hours the site promises the renter.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Filter by Active, New, Asked the renter, Changes asked, Offer out, Not paid or Expired. An expired offer leaves the active queue 48 hours after it expired, or once its pickup time passed; Expired lists them all. An offer still out when its pickup time passes expires by itself.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-02-requests-desktop-6521282d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:38.9%;top:29.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:22.2%;top:43.3%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless &quot;Email the renter when their request expires that way&quot; is on in Program settings.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-answer-a-request-with-an-offer" data-gd-task><h2 class="gd-h2">Answer a request with an offer</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The Review and offer tab shows the request as the renter sent it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Adjust the car, the dates, the rate type, the places, the rates (under <b class="gd-ui">Show rate card</b>) and fees, the deposit and extras. A place changed away from a delivery or a collection takes its fee box and its fee with it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Price on the right updates as you change things.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a message, choose how long the offer stays open, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10069?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1200/1550"><img src="/guides/img/admin-03-booking-review-desktop-353f3707.jpg" alt="" loading="lazy" decoding="async" width="1200" height="1550"><span class="gd-pin" style="left:5%;top:6.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:7.5%;top:45.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:74.2%;top:42.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:76.7%;top:98.1%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Changed fields but not ready to send? Press <b class="gd-ui">Save changes</b>. The panel &quot;The offer as the renter sees it&quot; shows the result.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? Press <b class="gd-ui">Decline</b> and fill in Reason and any alternative.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Need an answer first? Press <b class="gd-ui">Ask the renter</b> to send a question.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10069?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:500/80"><img src="/guides/img/admin-03-booking-review-desktop-4dd4ed06.jpg" alt="" loading="lazy" decoding="async" width="500" height="80"><span class="gd-pin" style="left:41.2%;top:52.5%" aria-hidden="true">6</span><span class="gd-pin" style="left:18%;top:52.5%" aria-hidden="true">7</span></div></div></figure></div><p class="gd-p">Opening a request takes it for you: everyone else sees &quot;Being answered by&quot; your name and since when, with Send the offer and Decline off, until you send, decline or leave (20 minutes, renewed while you work; Program settings). Press <b class="gd-ui">Take over</b> to answer one someone else holds; it is noted in the history. A second answer is refused with who answered and when. A request from the website opens to Sales after 15 minutes (Program settings); until then Admins, customer service and fleet answer it.</p></section><section class="gd-task" id="requests-offers-and-bookings-send-an-offer-without-a-request" data-gd-task><h2 class="gd-h2">Send an offer without a request</h2><p class="gd-p">Press <b class="gd-ui">Send an offer</b> at the top of Bookings, or <b class="gd-ui">Send an offer without a request</b> on Requests and offers. For a customer on the phone, by text or at the counter: no request needed.</p><p class="gd-p">The screen is seven short steps, each with one line saying what to do, and the price beside it (on a phone the total sits at the bottom of the screen: press <b class="gd-ui">See every line</b>). What most offers never need is under each step&#39;s <b class="gd-ui">More options</b>, which stays open while something in it is used.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Who is renting and when</b>: find the renter by name, phone or email, or press <b class="gd-ui">Not on file? Add a new customer</b> (full legal name, mobile, email for the offer link, date of birth). A customer already on file with the same email or phone is shown with Use: one person, one record. Then the pickup and the return.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Which car</b>: search by car code, plate or name; each car says Free or Not free for the dates. More options: the rate card and the type and free-only filters.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Where they pick up and return</b>: at our location, we deliver or collect (the address and distance), an airport or the owner&#39;s location. The fee each one makes shows under it, Automatic or Set by hand.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">How damage is covered</b>: the renter&#39;s own insurance, a credit card or the Protection Plan. More options: another Protection Plan price.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Extras</b>: add-ons, when the car has any.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">The price</b>: the rate sheet price is filled in. More options: another price (a total for the trip or a rate a day, with why), Amounts I type (before or after HST), the total the renter pays, kilometres, a promo code, the deposit and a discount (an Admin), and <b class="gd-ui">Fees</b>: press <b class="gd-ui">Change</b> to set one by hand, <b class="gd-ui">Reset to automatic</b> to undo it. Below: how it is paid (card online and a card hold unless you change it under More options).</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><b class="gd-ui">Send it</b>: who found this client (sales and customer service), a message, and Text or Email. More options: how long the offer is open, the owner&#39;s view, who found the client (an Admin) and the internal note. Above the button, <b class="gd-ui">Ready to send</b> or <b class="gd-ui">Missing:</b> with what is left; press Send and each missing field says what it needs. Press <b class="gd-ui">Send the offer to</b> the renter, or <b class="gd-ui">Save without sending</b> to keep it as a request for later. <b class="gd-ui">The offer as the renter sees it</b> is under the price.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Choices drive the charges. Take off a delivery, a collection, the Protection Plan or an add-on and its fee goes with it, even a fee set by hand: there is nothing to remove in a second place. Choose it again and the fee starts from the automatic amount.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No &quot;request received&quot; email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-change-an-offer-that-is-out" data-gd-task><h2 class="gd-h2">Change an offer that is out</h2><p class="gd-p">The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Open <b class="gd-ui">More actions</b> on the booking and press <b class="gd-ui">Edit the offer</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed. Amounts I type (Before tax or After tax) and the Total the renter pays (after tax) work as on Send an offer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Write what changed in Message to the renter and choose how long the offer is open.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save and send the update</b>: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press <b class="gd-ui">Save without telling the renter</b> and tell them yourself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A confirmed booking is changed with <b class="gd-ui">Change the booking</b> (Propose a change, below).</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>No need to withdraw first. <b class="gd-ui">Withdraw the offer</b> is only for taking it back for good; <b class="gd-ui">Send again, later expiry</b> gives the renter more time, and <b class="gd-ui">Renter approved by phone</b> records a yes given on a call.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-edit-a-booking-that-has-started" data-gd-task><h2 class="gd-h2">Edit a booking that has started</h2><p class="gd-p">On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, <b class="gd-ui">Edit the booking</b>, <b class="gd-ui">Edit</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking&#39;s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Type why, if you like, and tick <b class="gd-ui">Email the renter what changed</b>, or leave it off for a silent correction. Press <b class="gd-ui">Save the changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What is open now shows at once: <b class="gd-ui">Email a pay link</b> or <b class="gd-ui">Text a pay link</b> for exactly that amount, <b class="gd-ui">Charge</b> the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking&#39;s history. A closed booking&#39;s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-fees-a-forgotten-fee-and-the-balance" data-gd-task><h2 class="gd-h2">Fees, a forgotten fee and the balance</h2><p class="gd-p">On the booking&#39;s Money tab, Fees lists each fee. Press <b class="gd-ui">Change or add a fee</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Save the fees</b>. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The renter sees the balance on their booking with a Pay button, and pays by card on Stripe&#39;s form.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-a-renter-with-only-a-debit-or-prepaid-card" data-gd-task><h2 class="gd-h2">A renter with only a debit or prepaid card</h2><p class="gd-p">A credit card is required by default: the deposit must be on a credit card so the deductible can be charged. The pay page tells a renter with only a debit or prepaid card to contact us.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the booking&#39;s Money tab, press <b class="gd-ui">Allow debit and prepaid cards for this booking</b> and type the reason. Who and when are kept, and the change is in the booking&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The booking&#39;s pay page, staff pay links and deposit hold then take a debit or prepaid card, and the renter is told the hold lowers the money available on the card until it is released, which can take several business days.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Require a credit card again</b> turns it off.</div></li></ol></div><p class="gd-p">The Money tab shows each card used and its type (credit, debit, prepaid). A booking on credit card rental coverage is always paid on the credit card that carries the coverage, and cannot be allowed. Program settings, <b class="gd-ui">Card types accepted</b>, can open debit and prepaid cards to every booking.</p></section><section class="gd-task" id="requests-offers-and-bookings-correct-a-renter-s-details" data-gd-task><h2 class="gd-h2">Correct a renter&#39;s details</h2><p class="gd-p">On the renter&#39;s page (People, Renters) or on any of their bookings, <b class="gd-ui">Edit renter</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick <b class="gd-ui">Email the renter a link to set a password</b> to send one there. Unsigned agreements and offers go to the new address.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the renter</b>. An email that another renter has is refused with their name; the same phone is a warning.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The same person entered twice? Possible duplicates (same email, same phone, or same name and date of birth) shows under the renter. <b class="gd-ui">Merge into this record</b> moves the other record&#39;s bookings, licences, cards, payments, documents and messages here and fills any detail missing here; the other record stays, blocked, with the merge in both histories.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-payments-by-part-the-rental-the-deposit-and-later-charges" data-gd-task><h2 class="gd-h2">Payments by part: the rental, the deposit and later charges</h2><p class="gd-p">On the booking&#39;s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Record a payment</b>: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press <b class="gd-ui">Record it</b>. The renter gets a receipt; <b class="gd-ui">Print</b> prints one to hand over.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Collect a card</b>: a payment (Everything open by default: the rental, the fees and any later charge in one), the deposit hold or saving the card. The renter types the card in Stripe&#39;s secure form: on this device (<b class="gd-ui">Open the card form</b>, then hand it over) or by a link texted or emailed to them (<b class="gd-ui">Send the link</b>; by text first when the renter has a mobile number). Staff never type a card number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Before every pickup the deposit hold link is texted to the renter on its own: 24 hours before (at once when the pickup is sooner), for a confirmed booking whose deposit is a card hold with no hold yet. The Money tab says <b class="gd-ui">Deposit link texted</b> and when it was opened; the ready check shows it too. The hold is still needed before the keys. No mobile number, or the text not sent: a task <b class="gd-ui">Deposit link not sent</b>. <b class="gd-ui">Settings</b>, then Site settings, Deposit link by text: on or off, and the hours.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A deposit hold lasts about 7 days and shows the days left; while the car is out it is collected by itself before it lapses. After the return, settle the deposit (below). <b class="gd-ui">Capture the hold</b> for all of it keeps the money; a part capture or <b class="gd-ui">Release the hold</b> waits for the settlement while the car is out or something is open (an Admin may do it with the reason).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Charge the saved card</b> (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter&#39;s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press <b class="gd-ui">Confirm the booking</b>).</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press <b class="gd-ui">Returned</b> with the reference or receipt number.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-settle-the-deposit" data-gd-task><h2 class="gd-h2">Settle the deposit</h2><p class="gd-p">The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking&#39;s Money tab, under Deposit, press <b class="gd-ui">Settle the deposit</b>. Issue the Check-in statement first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Damage: <b class="gd-ui">Keep the whole deposit (damage)</b> turns what is left of the deposit into a damage charge, with what was damaged and the photos; the renter is told. <b class="gd-ui">Bill damage</b> adds a damage charge up to the $2,500 deductible (more goes through a claim): the deposit pays first, then the card on file.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Settle</b>. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-a-booking" data-gd-task><h2 class="gd-h2">A booking</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Bookings</b>, then a booking number. Or type the number in the search box.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Tabs: Overview, Money, Changes, History, and Drivers and documents.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Overview shows the trip, the renter, what is still missing for the handover, and the price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open tasks for this booking, with the queue and the due time.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Top right: <b class="gd-ui">Email the renter</b> and <b class="gd-ui">More actions</b>, the menu with <b class="gd-ui">Edit the offer</b>, <b class="gd-ui">Stop blocking the calendar</b>, <b class="gd-ui">Cancel for the renter</b>, <b class="gd-ui">Cancel by CarmaCars</b> and the rest.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Under the booking number: <b class="gd-ui">Next step</b>, what happens next and who does it, with one button for that step (for example <b class="gd-ui">Send the offer</b>, <b class="gd-ui">Sign on this device</b> or <b class="gd-ui">Check out the car</b>); then where the booking is on its way, from Request to Closed, with the dates, the days, the total and who pays.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10065</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/960"><img src="/guides/img/admin-04-booking-desktop-b56b668a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="960"><span class="gd-pin" style="left:50%;top:46.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:85.4%;top:14.5%" aria-hidden="true">4</span><span class="gd-pin" style="left:22.9%;top:26.8%" aria-hidden="true">5</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-check-a-car-out-or-in" data-gd-task><h2 class="gd-h2">Check a car out or in</h2><p class="gd-p">From the booking, with your phone or a tablet: the same checklist field staff use.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A confirmed booking shows <b class="gd-ui">Check out (pickup)</b> under Check-out, check-in and signing; a booking on rent shows <b class="gd-ui">Check in (return)</b>. Today lists the check-outs and check-ins due, each with <b class="gd-ui">Check out</b> or <b class="gd-ui">Check in</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press <b class="gd-ui">See the photo report</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Fleet, Sales and Customer service check cars out and in the same way from their own booking page.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-the-photo-report-late-returns-and-the-return-charges" data-gd-task><h2 class="gd-h2">The photo report, late returns and the return charges</h2><p class="gd-p">Under Check-out, check-in and signing, press <b class="gd-ui">Photo report</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not charging one? Press <b class="gd-ui">Waive</b> beside it and give the reason: it stays waived if the charges are worked out again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The time was wrong? Press <b class="gd-ui">Correct the check-in time</b> (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.</div></li></ol></div><h3 class="gd-h3">The renter says the car is back</h3><p class="gd-p">Every overdue email, text and alert (at the return time, at 15 minutes and the final notice) has a one-tap <b class="gd-ui">I&#39;ve returned the car</b> link, and the renter&#39;s booking page has the button. The renter can add photos, the odometer, the fuel level and the time they returned it. Sending it stops every overdue notice of the booking at once, the booking shows <b class="gd-ui">Returned, waiting for confirmation</b>, and Fleet gets an urgent To do: &quot;The renter says the car is back&quot;.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking. The card <b class="gd-ui">The renter says the car is back</b> shows what the renter gave, marked renter-provided, with their photos.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the car: the return place, the tracker, the photos.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Confirm</b> to complete the trip. Correct the odometer, fuel or return time first if they are wrong: the late charges follow the time you confirm. The renter&#39;s photos join the check-in report.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Or press <b class="gd-ui">Deny</b> and say why. The renter gets your reason by email and text, and the overdue notices start again.</div></li></ol></div><p class="gd-p">Checking the car in the usual way also completes the trip and stops the notices. Admins, Fleet, Sales, Customer service and field staff can Confirm or Deny.</p></section><section class="gd-task" id="requests-offers-and-bookings-signatures-on-the-spot-or-by-link" data-gd-task><h2 class="gd-h2">Signatures on the spot, or by link</h2><p class="gd-p">The renter or an additional driver signs the rental agreement on your device, or on their own phone.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">While a signature is missing, the booking shows <b class="gd-ui">Sign now on this device</b>, <b class="gd-ui">Email the signing link</b> and <b class="gd-ui">Text the signing link</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">No agreement made yet (the renter has not saved their details at home)? <b class="gd-ui">Sign now on this device</b> still shows: press <b class="gd-ui">Prepare the agreement to sign now</b> and it is made on the spot.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Sign now on this device</b>: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press <b class="gd-ui">Hand the device to</b> and their name.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">They read both agreements (CarmaCars&#39; and Blind Spot&#39;s), tick the statements and sign. Then <b class="gd-ui">Back to the staff view</b> for the next signer.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy&#39;s signature record page.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-rental-agreements-every-version-every-field" data-gd-task><h2 class="gd-h2">Rental agreements: every version, every field</h2><p class="gd-p">The booking&#39;s Rental agreements card: the current version of CarmaCars&#39; and Blind Spot&#39;s agreements, every earlier one, and what is still blank.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Once the agreement is signed and countersigned, any change to what it prints makes a new version of both documents by itself: the dates, the price lines, the car, a driver added or corrected, the coverage, the deposit or how it was paid, an address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A change to the dates, the price, the car, the drivers or the coverage option is signed again: the renter (and each driver it affects) gets their link by email and text, and the card shows &quot;Agreement v3 waiting for signature&quot;. A correction (a typo in an address, a plate written differently) is filed without signing; the renter gets the corrected copy by email.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check-out makes the &quot;as picked up&quot; copy (time out, km out, fuel out, the car&#39;s plate and VIN, the check-out report), countersigned by whoever checked the car out; check-in makes the closing copy (time in, km in, driven and charged, fuel in, late hours, damage, the return charges, the final totals). Both go to the renter by email.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Every version</b> lists each one with what changed and both PDFs. <b class="gd-ui">Resend the signing links</b>, or press the button with their first name beside it to have them sign on your phone or tablet.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The card lists what the agreements still print blank (a licence expiry, the insurer&#39;s policy number, the insured vehicle, a VIN). Type the values and press <b class="gd-ui">Save the missing fields</b>: the agreements follow.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Check-out stops while a field a claim needs is blank. An Admin can let it go ahead: type the reason and press <b class="gd-ui">Override</b>; the reason is in the booking&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><b class="gd-ui">Make the agreements again</b> checks both against the booking at once (they also follow every change by themselves).</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t"><b class="gd-ui">Edit the wording</b> (Admin only) changes CarmaCars&#39; agreement text for this booking: press <b class="gd-ui">Change</b> beside a clause, edit its text, say why and press <b class="gd-ui">Save the wording</b>; <b class="gd-ui">Add</b> writes Additional terms at the end of Part 2. Only clauses not required by law or the insurer can be removed; the consents are fixed, and Blind Spot&#39;s form (the insurer&#39;s official form) is never changed. Before the renter signs, the agreement is made again; after, the change is a new version they sign, and <b class="gd-ui">Every version</b> shows each clause before and after.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-signing-that-holds-up-in-a-dispute" data-gd-task><h2 class="gd-h2">Signing that holds up in a dispute</h2><p class="gd-p">Every signature on the site is made the same way: rental agreements, amendments and new versions (remotely or on your device), and the owner agreements, schedules and forms, a co-owner&#39;s link, the partner, investment and staff agreements.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The licence on file is shown. A 6-digit code to their phone or email on file is optional: the signer may press <b class="gd-ui">Verify by code (optional)</b>, and Program settings, E-signing, <b class="gd-ui">ask for a one-time code</b> makes it a required first step again (off by default). Without the code, the certificate says the identity was not confirmed by a code.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">They say they read the documents, initial the key terms (each initials box is saved with <b class="gd-ui">Save initials</b>; <b class="gd-ui">Clear</b> takes it back to initial again) (damage and the deductible, the deposit and later charges, fuel, kilometres and late returns, their coverage, cancellation), give three consents (to sign electronically, to receive records electronically, to card charges under the agreement) and draw their signature.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Owners, partners, investors and staff do the same for their documents: the code, the reading, the key terms of their documents initialled (for example the Enrollment Agreement&#39;s three confirmations, Form C&#39;s acknowledgments, Schedule C, the staff agreement&#39;s confidentiality), two consents and the drawn signature. Form C&#39;s witness still types their name beside the owner.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Each step is recorded with its time, IP address and device, and the place when the device shares it. The signed PDFs end with a certificate of completion; anyone can check a signed file at <span class="gd-url">carmacars.ca/verify</span>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Typed names are off. For a signer who cannot draw, an Admin can turn on the accessibility fallback: <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, Esign typed fallback.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-card-disputes-the-evidence-pack" data-gd-task><h2 class="gd-h2">Card disputes: the evidence pack</h2><p class="gd-p">Everything that proves the rental, in one PDF for Stripe.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When a card payment is disputed, the evidence pack is built by itself: the signed agreements with their certificates, the check-out and check-in reports with photos, kilometres and fuel, the licence, the payments and charges, every message to the renter, and the card checks from Stripe. It is staged in Stripe as the dispute&#39;s evidence, and To do gets an urgent task.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open the booking: the Rental agreements card shows the pack. Press <b class="gd-ui">Download</b> to check it, then <b class="gd-ui">Submit to Stripe</b> before the evidence date.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Build the dispute evidence pack</b> makes one at any time (an Admin or Finance).</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-the-licence-before-an-offer-is-accepted" data-gd-task><h2 class="gd-h2">The licence before an offer is accepted</h2><p class="gd-p">Front, back and a selfie, from the request on.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Review the images as usual with <b class="gd-ui">Review documents</b>: the card Renter documents is on Review and offer too.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The switch is in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, Booking requests and offers: Booking licence required (on), with the selfie (on).</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-renter-documents-licence-and-proof-of-coverage" data-gd-task><h2 class="gd-h2">Renter documents: licence and proof of coverage</h2><p class="gd-p">A renter&#39;s licence photos, selfie and proof of coverage (OPCF 27 or a credit card&#39;s rental coverage) are checked before the handover. You check them yourself; no task is needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A booking with documents waiting is a line on To do: &quot;Check &#39;s documents for booking &quot;, marked Now when the pickup is within two days. Press <b class="gd-ui">Review documents</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The pop-up shows each driver&#39;s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What to check is written once at the top. One wrong? Open <b class="gd-ui">Reject this one</b> under it, type the reason the renter reads and press <b class="gd-ui">Reject</b>: they are asked for a new one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Then press <b class="gd-ui">Approve all</b>: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. Anything the system refuses is named with the reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The same pop-up is on the booking: the card Renter documents (<b class="gd-ui">Review documents</b>) on Overview and on Drivers and documents.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening of a renter&#39;s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-out (photos and four checks): the history says &quot;checked in person&quot;. Field staff also review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from My jobs, with the same Approve all or a reason to reject: the history says the reviewer&#39;s role, field. Sales review the licence images (not the coverage) of any booking being arranged or under way from their To do or the booking, with the same Approve all or a reason to reject: the history says the role, sales.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-payments-by-day" data-gd-task><h2 class="gd-h2">Payments by day</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Payments</b>, the <b class="gd-ui">By day</b> tab: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press <b class="gd-ui">Show</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Totals by method and for each day; cards read as the card and its last four digits, never a code.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The cash drawer: expected (cash in less cash given back) against the count Finance records with <b class="gd-ui">Record the count</b>; a difference shows over or short.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Refunds waiting: every refund asked for anywhere with the policy maths. <b class="gd-ui">Approve</b> or <b class="gd-ui">Decline</b> with the reason in the row, then <b class="gd-ui">Issue the refund</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Export CSV</b> for the bookkeeper.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-propose-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">Propose a change to a confirmed booking</h2><p class="gd-p">The renter gets an email and answers on their booking. The calendar moves only when they accept.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking&#39;s Changes tab. Under Propose a change, set the new pickup, return or car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To price it by hand, type a New rental charge before tax. Leave it empty to use the car&#39;s rates.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the Reason, for the renter. They read it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10065?tab=changes</span></div><div class="gd-imgwrap" style="aspect-ratio:1200/520"><img src="/guides/img/admin-05-booking-changes-desktop-97008b21.jpg" alt="" loading="lazy" decoding="async" width="1200" height="520"><span class="gd-pin" style="left:17.5%;top:33.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:9.2%;top:50%" aria-hidden="true">2</span><span class="gd-pin" style="left:38.3%;top:71.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:12.9%;top:91.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-who-a-booking-is-credited-to" data-gd-task><h2 class="gd-h2">Who a booking is credited to</h2><p class="gd-p">Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To give it to someone else, press <b class="gd-ui">Reassign</b>, choose who (or Nobody), say whether they sourced the client and write the reason. The booking&#39;s history and the audit log keep it, and the deal stays in the same week and month.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Someone said they sourced a website request? The credit line shows the claim: press <b class="gd-ui">Credit them</b> or <b class="gd-ui">Not theirs</b>, with a reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press <b class="gd-ui">Mark reviewed</b> once you have looked at it.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A request keeps the lead-time adjustment of the moment it came in (&quot;Short-notice pricing +10%&quot; or &quot;Booked ahead −5%&quot;), through the offer and the payment. To change it, open the booking&#39;s review screen, <b class="gd-ui">More options</b>, <b class="gd-ui">Lead-time pricing (%)</b>: a number (0 for none), or empty for the tier of the request. A price typed by hand replaces it.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-review-requests" data-gd-task><h2 class="gd-h2">Review requests</h2><p class="gd-p">Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Message</th><th scope="col">When</th></tr></thead><tbody><tr><td>Mid-trip check-in</td><td>Rentals of 2 days or more, 24 hours after the pickup: &quot;How is the car? Reply or call if anything is off.&quot; No review ask.</td></tr><tr><td>Review request</td><td>1 hour after the check-in. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google.</td></tr><tr><td>Reminder</td><td>24 hours after the request.</td></tr><tr><td>Final follow-up</td><td>7 days after the request. Nothing more after it.</td></tr></tbody></table></div><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Ask for a review</b> sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press <b class="gd-ui">Send anyway</b> to send it now.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Mark reviewed</b> stops the messages when the renter tells you they already reviewed.</div></li></ol></div><p class="gd-p">The messages also stop by themselves when the renter presses &quot;I already left a review&quot;, leaves a review on the site, unsubscribes, or a Google review is matched to them. <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Reviews</b> has the numbers (requests sent, on hold, reviews detected, the average rating), the hold list and the Google reviews to match.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees &quot;Something wasn&#39;t right? Tell us directly&quot;.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-what-the-owner-sees-and-owner-deductions" data-gd-task><h2 class="gd-h2">What the owner sees, and owner deductions</h2><p class="gd-p">Each booking on an owner&#39;s or partner&#39;s car shows the card What the owner sees at the top of its page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Hide from the owner</b> keeps the booking&#39;s revenue from the owner until the car is returned, or until the owner statement covering it is approved. The owner sees the booking as Booked with its dates, and the calendar still shows the car busy. Add a reason if you like: it is kept in the history.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Show to the owner</b> shows it now. Approving the statement shows every hidden booking on it by itself.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not shown to the owner is for a booking with no owner revenue (an insurance placeholder, a shareholder&#39;s or the owner&#39;s own use at no charge): the owner sees only that the car is unavailable for those dates. A booking with revenue cannot be set this way.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a rental and Send an offer have What the owner sees. It starts from Settings &gt; Program, Owners and fleet: Owners see a booking&#39;s revenue (right away by default).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">On the Money tab, Owner deductions on this booking: <b class="gd-ui">Add a booking expense</b> (cleaning, repair, fuel, platform fee or other, the amount, the reason the owner reads, a receipt number) comes off before Owner Revenue.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Set the Revenue Share for this booking</b> applies within the car&#39;s signed terms. Above the terms only an Admin can, with Above the signed terms ticked and the reason. <b class="gd-ui">Back to the car&#39;s terms</b> undoes it.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Add a rental has the same under The car&#39;s owner.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The owner&#39;s statement always includes every booking at its true amounts and lists each deduction with its reason, so the payout is always right. Customer service and sales add deductions only while Program settings let them change fees.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-email-the-renter-or-the-adjuster" data-gd-task><h2 class="gd-h2">Email the renter or the adjuster</h2><p class="gd-p">Press <b class="gd-ui">Email the renter</b> at the top of a booking, or open its <b class="gd-ui">Messages</b> tab.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Write a <b class="gd-ui">Subject</b> and a <b class="gd-ui">Message</b>, or pick a <b class="gd-ui">Quick reply</b> to start from (Settings &gt; Quick replies keeps them).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Email the renter</b>. It goes from CarmaCars (bookings@carmacars.ca) and replies come back to the bookings inbox. The renter also sees it in their account and can answer there.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On a booking an insurer pays, choose <b class="gd-ui">From</b>: CarmaCars, or Blind Spot Car Rental (insurance). <b class="gd-ui">Email the adjuster</b> writes to the adjuster&#39;s email on the booking (Insurance claim), always from Blind Spot Car Rental.</div></li></ol></div><p class="gd-p">The Messages tab shows what you and the renter wrote, newest first, with who wrote it, and every email of the booking with its state (waiting, sent, failed). Each email you send is also in the History tab with your name.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Emails go out through the same daily limit as every email (the line under the form shows today&#39;s use). A message to a renter goes before digests and marketing; past the limit it waits until midnight. To write to a renter from <b class="gd-ui">People</b> &gt; <b class="gd-ui">Renters</b>, open the renter: Email the renter is at the bottom, about their latest booking or the one you pick.</div></aside><h3 class="gd-h3">Record the pickup or the return now (details later)</h3><p class="gd-p">When the car went out or came back but the checklist could not be done (no photos, no time, the renter dropped the keys), the booking&#39;s <b class="gd-ui">Check-out, check-in and signing</b> card has <b class="gd-ui">Record the pickup now (details later)</b> on a confirmed booking and <b class="gd-ui">Record the return now (details later)</b> while the car is on rent. Give the actual time (now, or earlier), the odometer and fuel if you know them, and why. The booking moves on (on rent, or returned), late return charges follow the actual time, and Fleet gets the task <b class="gd-ui">Add the photos and readings for CC-...</b>. Once returned, the statement can be issued and the deposit settled; releasing the deposit before the photos are in needs an Admin and a reason. A pickup without the deposit taken needs an Admin to waive it with a reason, and without the renter&#39;s signature on the check-out report an Admin&#39;s reason too. Later, <b class="gd-ui">Add the check-out (or check-in) photos and readings</b> opens the usual checklist (photos, readings, your signature): the task closes when it is saved.</p><p class="gd-p">The Agreement card says <b class="gd-ui">Waiting for the renter&#39;s details</b> when the renter still has blanks to fill (date of birth, address, mobile, licence, coverage): their account asks for them before signing and paying. No email or text is sent.</p><h3 class="gd-h3">Find a booking</h3><p class="gd-p"><b class="gd-ui">Bookings</b> has one search box: type the booking number (CC-1042, cc1042 or just 1042), the renter&#39;s or a driver&#39;s name, an email, a phone number in any format, a plate (spaces do not matter) or a car code, then press Enter. The status filters still apply to what is found.</p><h3 class="gd-h3">Record a card payment taken outside the site</h3><p class="gd-p">A card taken in the Stripe Dashboard, or on a card reader, is recorded on the booking&#39;s <b class="gd-ui">Money</b> tab with <b class="gd-ui">Record card payment</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose what it paid: <b class="gd-ui">Rental and fees</b>, <b class="gd-ui">Rental</b>, <b class="gd-ui">Fees</b>, <b class="gd-ui">Later charges</b> or <b class="gd-ui">Deposit hold</b>, and where it was taken.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Type the <b class="gd-ui">Last 4 digits</b> and the amount. A Stripe payment id (pi_... or ch_..., from the payment in the Stripe Dashboard) is optional for a payment: press <b class="gd-ui">Look up</b> and the amount and last 4 digits are checked against Stripe.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Record it</b>. A payment confirms a booking waiting for payment, as any payment does.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A deposit hold needs its Stripe payment id, so it can be captured or released from <b class="gd-ui">Settle the deposit</b>. It is recorded as held, with the usual release reminders. A hold on a reader lapses after 2 days, one made online after 7.</div></aside><h3 class="gd-h3">Charge or hold the deposit on the card reader</h3><p class="gd-p">With the S700 paired (Settings &gt; Card reader), the <b class="gd-ui">Money</b> tab has <b class="gd-ui">Charge on reader</b> (everything open, the rental, the fees or a later charge) and <b class="gd-ui">Hold deposit on reader</b>. Press <b class="gd-ui">Send to the reader</b>: the amount shows on the reader and the renter taps, inserts or swipes the card. The screen updates by itself; <b class="gd-ui">Cancel</b> stops the reader and nothing is charged. A deposit hold is captured or released from Settle the deposit like any hold.</p><h3 class="gd-h3">Credit card coverage: the same card</h3><p class="gd-p">When the renter&#39;s coverage is their credit card, the whole rental (rental and fees) is paid on that same card. The Money tab says which card. Another card on the pay page is refused and refunded at once; on the reader it is refused before the money is taken; a payment by e-Transfer, cash or the like is refused; a card typed by hand needs its last 4 digits and the box <b class="gd-ui">This is the same card</b>. Deposits and later charges can go on any card. If the renter truly has to use another card or method, press <b class="gd-ui">Allow another card</b> and give the reason (an Admin).</p></section>');
select app.guide_release_section('admin', 'quick-reference', 'reference', 'data-health', '### Where things are

| Item | What it is for |
| --- | --- |
| **To do** | What needs you now, most urgent first |
| **Search** | Any booking, plate, VIN, name or email |
| **Bookings** | What is out and coming back now, every booking, requests and offers, the calendar |
| **Cars** | Vehicles, listings, calendar sync, sample photos |
| **Money** | Owner invoices and debits, payments, statements, tolls |
| **People** | Applications, owners, partners, owner forms; renters, staff, investors, View as |
| **Marketing** | Ad text for each channel, posted ads, social drafts, bookings by channel, owner recruitment |
| **Settings** | Site, program, forms, guides, emails, audit log |

### Top tasks

1. *Answer an application:* **People** > **Applications**, then **Approve**, **Ask for something** or **Decline**
2. *Send an offer:* **Bookings** > **Requests and offers**, the booking, then **Send the offer**
3. *Change a booking:* The booking''s Changes tab, then **Send to the renter**
4. *Publish a car:* To do, the car''s line, then **Set rates and publish**
5. *Mark a car insured:* To do, the car''s line, then **Mark insured**
6. *Check renter documents:* To do, the booking''s line, then **Review documents**
7. *Let someone in:* **People** > **Portals and view as**, then **Invite**
8. *Help someone sign in:* **Send password link**
9. *Read a toll notice:* **Money** > **Tolls and tickets**, then **Read a notice**
10. *Monthly statements:* **Build all for a month**, Approve, Issue

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **You can''t change anything** | You are viewing as someone. Press Exit on the red banner. |
| **Asked for a 6-digit code** | Open your authenticator app. Lost phone: remove the factor in the Supabase dashboard. |
', 'Quick reference', 'One page with the essentials.',
  '### Where things are

| Item | What it is for |
| --- | --- |
| **To do** | What needs you now, most urgent first |
| **Search** | Any booking, plate, VIN, name or email |
| **Bookings** | What is out and coming back now, every booking, requests and offers, the calendar |
| **Cars** | Vehicles, listings, calendar sync, sample photos |
| **Money** | Owner invoices and debits, payments, statements, tolls |
| **People** | Applications, owners, partners, owner forms; renters, staff, investors, View as |
| **Marketing** | Ad text for each channel, posted ads, social drafts, bookings by channel, owner recruitment |
| **Settings** | Site, program, forms, guides, emails, audit log |

### Top tasks

1. *Answer an application:* **People** > **Applications**, then **Approve**, **Ask for something** or **Decline**
2. *Send an offer:* **Bookings** > **Requests and offers**, the booking, then **Send the offer**
3. *Change a booking:* The booking''s Changes tab, then **Send to the renter**
4. *Publish a car:* To do, the car''s line, then **Set rates and publish**
5. *Mark a car insured:* To do, the car''s line, then **Mark insured**
6. *Check renter documents:* To do, the booking''s line, then **Review documents**
7. *Let someone in:* **People** > **Portals and view as**, then **Invite**
8. *Help someone sign in:* **Send password link**
9. *Read a toll notice:* **Money** > **Tolls and tickets**, then **Read a notice**
10. *Monthly statements:* **Build all for a month**, Approve, Issue

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **You can''t change anything** | You are viewing as someone. Press Exit on the red banner. |
| **Asked for a 6-digit code** | Open your authenticator app. Lost phone: ask an Admin with server access to remove the factor in the sign-in service''s console. |
',
  '<h3 class="gd-h3">Where things are</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Item</th><th scope="col">What it is for</th></tr></thead><tbody><tr><td><b class="gd-ui">To do</b></td><td>What needs you now, most urgent first</td></tr><tr><td><b class="gd-ui">Search</b></td><td>Any booking, plate, VIN, name or email</td></tr><tr><td><b class="gd-ui">Bookings</b></td><td>What is out and coming back now, every booking, requests and offers, the calendar</td></tr><tr><td><b class="gd-ui">Cars</b></td><td>Vehicles, listings, calendar sync, sample photos</td></tr><tr><td><b class="gd-ui">Money</b></td><td>Owner invoices and debits, payments, statements, tolls</td></tr><tr><td><b class="gd-ui">People</b></td><td>Applications, owners, partners, owner forms; renters, staff, investors, View as</td></tr><tr><td><b class="gd-ui">Marketing</b></td><td>Ad text for each channel, posted ads, social drafts, bookings by channel, owner recruitment</td></tr><tr><td><b class="gd-ui">Settings</b></td><td>Site, program, forms, guides, emails, audit log</td></tr></tbody></table></div><h3 class="gd-h3">Top tasks</h3><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><em>Answer an application:</em> <b class="gd-ui">People</b> &gt; <b class="gd-ui">Applications</b>, then <b class="gd-ui">Approve</b>, <b class="gd-ui">Ask for something</b> or <b class="gd-ui">Decline</b></div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><em>Send an offer:</em> <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests and offers</b>, the booking, then <b class="gd-ui">Send the offer</b></div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><em>Change a booking:</em> The booking&#39;s Changes tab, then <b class="gd-ui">Send to the renter</b></div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><em>Publish a car:</em> To do, the car&#39;s line, then <b class="gd-ui">Set rates and publish</b></div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><em>Mark a car insured:</em> To do, the car&#39;s line, then <b class="gd-ui">Mark insured</b></div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><em>Check renter documents:</em> To do, the booking&#39;s line, then <b class="gd-ui">Review documents</b></div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><em>Let someone in:</em> <b class="gd-ui">People</b> &gt; <b class="gd-ui">Portals and view as</b>, then <b class="gd-ui">Invite</b></div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t"><em>Help someone sign in:</em> <b class="gd-ui">Send password link</b></div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t"><em>Read a toll notice:</em> <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Tolls and tickets</b>, then <b class="gd-ui">Read a notice</b></div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t"><em>Monthly statements:</em> <b class="gd-ui">Build all for a month</b>, Approve, Issue</div></li></ol></div><h3 class="gd-h3">If something goes wrong</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">What you see</th><th scope="col">What to do</th></tr></thead><tbody><tr><td><b class="gd-ui">A link says it expired</b></td><td>Links in our emails work for 24 hours, once. Press <b class="gd-ui">Send me a new link</b> on that page.</td></tr><tr><td><b class="gd-ui">&quot;Error 1102&quot; on a page</b></td><td>A short limit on our web host. Reload the page. You are still signed in.</td></tr><tr><td><b class="gd-ui">&quot;That email and password do not match an account.&quot;</b></td><td>Check the address, or use <b class="gd-ui">Set a new password</b> on the sign-in page.</td></tr><tr><td><b class="gd-ui">You can&#39;t change anything</b></td><td>You are viewing as someone. Press Exit on the red banner.</td></tr><tr><td><b class="gd-ui">Asked for a 6-digit code</b></td><td>Open your authenticator app. Lost phone: ask an Admin with server access to remove the factor in the sign-in service&#39;s console.</td></tr></tbody></table></div>');
select app.guide_release_section('va', 'fleet', 'chapter', 'finance', 'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listings with their duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Field hours, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

Every confirmed booking gets its handover (or delivery) and return (or pickup) jobs by itself, at the booking''s times and place, given to the field staff member with the fewest jobs that day. You check and change them.

1. Jobs, next three days: each with its place, its field staff and whether they acknowledged it. "Made from the booking" marks the ones made by themselves; when the booking moves, they move too, unless you changed them.
2. Change a job with **Assign**, **Reassign**, **Move** (time and place) or **Cancel**.
3. Handovers and returns without a job (when the automatic jobs are off, or one was cancelled) are listed first: press **Schedule**, the place filled in from the booking.
4. An Admin turns the automatic jobs or the assignment off in Settings > Program.

![](/guides/img/va-fleet-02-field-jobs-desktop-8e721230.jpg "desktop; size: 1230 565; address: carmacars.ca/va/fleet; pins: 1 17.9 51.3")

## Fleet map

At the top of **Field jobs**: every car on the map with its renter, booking, due-back time and state, the alerts, and the trips by booking, the same as the Admin''s. Only Admins and fleet staff see positions.

1. Press a car for its card: last report, odometer, fuel, tracker battery and the trip under way.
2. An alert (speeding, left Ontario or the zone, still driving after the return time, low or unplugged tracker, not reporting) also comes to your bell and as an urgent phone alert. Call the renter, then press **Seen**.
3. A car still driving after its return time: call, send the late notice and offer a paid extension, as for any late return.

## Field hours

Field staff clock in and out on their phones. You see who is clocked in and every shift of the two-week pay period, and you fix what they cannot.

1. Open **Field hours**. **Clocked in now** lists who is on, since when. **Earlier period** and **Later period** move between pay periods.
2. Someone forgot to clock out: press **Clock out for them**, set the time they finished and write the reason.
3. Someone forgot to clock in, or a time is wrong: **Add hours** enters a shift, **Change** fixes one and **Remove** takes one out. Each needs a reason; the change is kept in a log with what it was before.
4. Once an Admin approves the pay run of a period, its shifts are locked: ask the Admin. You see hours only, not rates or pay.

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Check a car out or in

Fleet, Sales and Customer service check cars out and in from the booking.

1. On a confirmed booking press **Check out (pickup)**; on a booking on rent, **Check in (return)**. Today lists the ones due, each with its button.
2. The checklist field staff use opens: readings (km and fuel or charge), the photo set with the plate and the gauges, damage close-ups and both signatures.
3. Afterwards press **Photo report**: times, Late by, kilometres, fuel, photos and the return charges. Fleet waives a charge with **Waive** and a reason.

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate never keeps a car off the site: it shows on the car''s checklist until you decide. Only Same car takes it off.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Rates and kilometres

From a listing, press **The car and its rates**, or open the car from Field jobs.

1. Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.
2. Keep **Use the defaults** for the kilometres, or choose **Custom for this car**.
3. Check What renters pay under the fields, then press **Save the rates**. Rates, kilometres and deposit save together.

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. The listing''s Steps to go live says what is next: 1 Photos, 2 Cover plates, 3 Review, 4 Live on the site, each with its button. The plate box is suggested by itself on every outside photo as the listing opens (Box suggested). Press **Cover the plate** and check it; **Suggest the plate** asks again. A photo filed under the wrong shot: **Remove** under it on the Photos card, then take the right one.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Publish now

Customer service and fleet publish a car themselves; nothing has to be finished first.

1. Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press **Publish now**. With no rates yet it uses the suggested rates (similar cars, else the class defaults).
2. What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.
3. New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.

> Tip: A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. Turo has no calendar link: Turo''s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.
2. An email the reader cannot place waits as "Which car is this?": press **Which car is this?** and press the right car (best guesses first). It is remembered for that car''s next emails. If the dates or trip number are missing: **Add as a Turo trip** (choose the car, check the dates) or **Dismiss**. A trip whose email did not come: **Add a Turo trip** on the car.
3. Each Turo trip shows the guest''s name and phone when Turo''s email includes them. Contact a Turo guest only about their trip, never with promotions.
4. Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car''s Turo calendar, then press **Done on Turo**. Dates that changed or a booking cancelled here show the dates to free on Turo.
5. Getaround, Google Calendar or another platform with a calendar (iCal) link: open **Add a calendar link**, choose the platform, paste it and press **Add the link**. Copy the car''s CarmaCars link for that platform with **Copy** and paste it into the platform''s calendar import.
6. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.

### Add the photos and readings
A pickup or return recorded with the details later gives Fleet the task **Add the photos and readings for CC-...**. Open the booking and press **Add the check-out (or check-in) photos and readings**: the usual checklist opens without the ready check or the renter''s signature. Take the photos, the odometer, fuel, keys (and cleanliness at a return), sign and save. The task closes by itself; it cannot be closed by hand before.

## Bookings now

**Rentals** > **Bookings** opens on Now for fleet and customer service: the cars out with their renter and due-back countdown, coming back today and tomorrow (overdue first, in red), going out in the next 72 hours with what is ready, the money due in 7 days and the free cars. It refreshes by itself every 30 seconds. A booking listed as **Out (pickup not recorded)** left without a check-out: press **Mark picked up**, then add the photos, km and fuel from the task. The search above it finds any booking.
', 'Fleet', 'Field jobs, daily checks, photo reviews, similar cars and listings.',
  'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listings with their duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Field hours, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

Every confirmed booking gets its handover (or delivery) and return (or pickup) jobs by itself, at the booking''s times and place, given to the field staff member with the fewest jobs that day. You check and change them.

1. Jobs, next three days: each with its place, its field staff and whether they acknowledged it. "Made from the booking" marks the ones made by themselves; when the booking moves, they move too, unless you changed them.
2. Change a job with **Assign**, **Reassign**, **Move** (time and place) or **Cancel**.
3. Handovers and returns without a job (when the automatic jobs are off, or one was cancelled) are listed first: press **Schedule**, the place filled in from the booking.
4. An Admin turns the automatic jobs or the assignment off in Settings > Program.

![](/guides/img/va-fleet-02-field-jobs-desktop-8e721230.jpg "desktop; size: 1230 565; address: carmacars.ca/va/fleet; pins: 1 17.9 51.3")

## Fleet map

At the top of **Field jobs**: every car on the map with its renter, booking, due-back time and state, the alerts, and the trips by booking, the same as the Admin''s. Only Admins and fleet staff see positions.

1. Press a car for its card: last report, odometer, fuel, tracker battery and the trip under way.
2. An alert (speeding, left Ontario or the zone, still driving after the return time, low or unplugged tracker, not reporting) also comes to your bell and as an urgent phone alert. Call the renter, then press **Seen**.
3. A car still driving after its return time: call, send the late notice and offer a paid extension, as for any late return.

## Field hours

Field staff clock in and out on their phones. You see who is clocked in and every shift of the two-week pay period, and you fix what they cannot.

1. Open **Field hours**. **Clocked in now** lists who is on, since when. **Earlier period** and **Later period** move between pay periods.
2. Someone forgot to clock out: press **Clock out for them**, set the time they finished and write the reason.
3. Someone forgot to clock in, or a time is wrong: **Add hours** enters a shift, **Change** fixes one and **Remove** takes one out. Each needs a reason; the change is kept in a log with what it was before.
4. Once an Admin approves the pay run of a period, its shifts are locked: ask the Admin. You see hours only, not rates or pay.

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Check a car out or in

Fleet, Sales and Customer service check cars out and in from the booking.

1. On a confirmed booking press **Check out (pickup)**; on a booking on rent, **Check in (return)**. Today lists the ones due, each with its button.
2. The checklist field staff use opens: readings (km and fuel or charge), the photo set with the plate and the gauges, damage close-ups and both signatures.
3. Afterwards press **Photo report**: times, Late by, kilometres, fuel, photos and the return charges. Fleet waives a charge with **Waive** and a reason.

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate never keeps a car off the site: it shows on the car''s checklist until you decide. Only Same car takes it off.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Rates and kilometres

From a listing, press **The car and its rates**, or open the car from Field jobs.

1. Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.
2. Keep **Use the defaults** for the kilometres, or choose **Custom for this car**.
3. Check What renters pay under the fields, then press **Save the rates**. Rates, kilometres and deposit save together.

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. The listing''s Steps to go live says what is next: 1 Photos, 2 Cover plates, 3 Review, 4 Live on the site, each with its button. The plate box is suggested by itself on every outside photo as the listing opens (Box suggested). Press **Cover the plate** and check it; **Suggest the plate** asks again. A photo filed under the wrong shot: **Remove** under it on the Photos card, then take the right one.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Publish now

Customer service and fleet publish a car themselves; nothing has to be finished first.

1. Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press **Publish now**. With no rates yet it uses the suggested rates (similar cars, else the class defaults).
2. What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.
3. New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.

> Tip: A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. Turo has no calendar link: Turo''s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.
2. An email the reader cannot place waits as "Which car is this?": press **Which car is this?** and press the right car (best guesses first). It is remembered for that car''s next emails. If the dates or trip number are missing: **Add as a Turo trip** (choose the car, check the dates) or **Dismiss**. A trip whose email did not come: **Add a Turo trip** on the car.
3. Each Turo trip shows the guest''s name and phone when Turo''s email includes them. Contact a Turo guest only about their trip, never with promotions.
4. Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car''s Turo calendar, then press **Done on Turo**. Dates that changed or a booking cancelled here show the dates to free on Turo.
5. Getaround, Google Calendar or another platform with a calendar (iCal) link: open **Add a calendar link**, choose the platform, paste it and press **Add the link**. Copy the car''s CarmaCars link for that platform with **Copy** and paste it into the platform''s calendar import.
6. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.

### Add the photos and readings
A pickup or return recorded with the details later gives Fleet the task **Add the photos and readings for CC-...**. Open the booking and press **Add the check-out (or check-in) photos and readings**: the usual checklist opens without the ready check or the renter''s signature. Take the photos, the odometer, fuel, keys (and cleanliness at a return), sign and save. The task closes by itself; it cannot be closed by hand before.

## Bookings now

**Rentals** > **Bookings** opens on Now for fleet and customer service: the cars out with their renter and due-back countdown, coming back today and tomorrow (overdue first, in red), going out in the next 72 hours with what is ready, the money due in 7 days and the free cars. It refreshes by itself every 30 seconds. A booking listed as **Out (pickup not recorded)** left without a check-out: press **Mark picked up**, then add the photos, km and fuel from the task. The search above it finds any booking.

### The renter says the car is back

An urgent To do "The renter says the car is back" means the renter pressed **I''ve returned the car** on an overdue booking. Their overdue notices are paused. Open the booking, check the car (place, tracker, the renter''s photos), then press **Confirm** (correct the odometer, fuel or time first if needed; the trip is completed) or **Deny** with the reason (the renter is told and the notices start again).
',
  '<p class="gd-p">You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listings with their duplicate check and plate covering.</p><p class="gd-p">Your rail: Queue, Today, Field jobs, Field hours, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.</p><section class="gd-task" id="fleet-schedule-field-jobs" data-gd-task><h2 class="gd-h2">Schedule field jobs</h2><p class="gd-p">Every confirmed booking gets its handover (or delivery) and return (or pickup) jobs by itself, at the booking&#39;s times and place, given to the field staff member with the fewest jobs that day. You check and change them.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Jobs, next three days: each with its place, its field staff and whether they acknowledged it. &quot;Made from the booking&quot; marks the ones made by themselves; when the booking moves, they move too, unless you changed them.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Change a job with <b class="gd-ui">Assign</b>, <b class="gd-ui">Reassign</b>, <b class="gd-ui">Move</b> (time and place) or <b class="gd-ui">Cancel</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Handovers and returns without a job (when the automatic jobs are off, or one was cancelled) are listed first: press <b class="gd-ui">Schedule</b>, the place filled in from the booking.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">An Admin turns the automatic jobs or the assignment off in Settings &gt; Program.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/fleet</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/565"><img src="/guides/img/va-fleet-02-field-jobs-desktop-8e721230.jpg" alt="" loading="lazy" decoding="async" width="1230" height="565"><span class="gd-pin" style="left:17.9%;top:51.3%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="fleet-fleet-map" data-gd-task><h2 class="gd-h2">Fleet map</h2><p class="gd-p">At the top of <b class="gd-ui">Field jobs</b>: every car on the map with its renter, booking, due-back time and state, the alerts, and the trips by booking, the same as the Admin&#39;s. Only Admins and fleet staff see positions.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press a car for its card: last report, odometer, fuel, tracker battery and the trip under way.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">An alert (speeding, left Ontario or the zone, still driving after the return time, low or unplugged tracker, not reporting) also comes to your bell and as an urgent phone alert. Call the renter, then press <b class="gd-ui">Seen</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A car still driving after its return time: call, send the late notice and offer a paid extension, as for any late return.</div></li></ol></div></section><section class="gd-task" id="fleet-field-hours" data-gd-task><h2 class="gd-h2">Field hours</h2><p class="gd-p">Field staff clock in and out on their phones. You see who is clocked in and every shift of the two-week pay period, and you fix what they cannot.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Field hours</b>. <b class="gd-ui">Clocked in now</b> lists who is on, since when. <b class="gd-ui">Earlier period</b> and <b class="gd-ui">Later period</b> move between pay periods.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Someone forgot to clock out: press <b class="gd-ui">Clock out for them</b>, set the time they finished and write the reason.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Someone forgot to clock in, or a time is wrong: <b class="gd-ui">Add hours</b> enters a shift, <b class="gd-ui">Change</b> fixes one and <b class="gd-ui">Remove</b> takes one out. Each needs a reason; the change is kept in a log with what it was before.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Once an Admin approves the pay run of a period, its shifts are locked: ask the Admin. You see hours only, not rates or pay.</div></li></ol></div></section><section class="gd-task" id="fleet-daily-checks" data-gd-task><h2 class="gd-h2">Daily checks</h2><p class="gd-p">Twice a day: the opening check by 9:00 and the closing check by 18:00.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Daily checks</b> and choose <b class="gd-ui">Opening check</b> or <b class="gd-ui">Closing check</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line shows what was found. Tick OK, or Problem with a note.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the opening check</b> (or <b class="gd-ui">Save the closing check</b>). You can save it again.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/checks</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/820"><img src="/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg" alt="" loading="lazy" decoding="async" width="1230" height="820"><span class="gd-pin" style="left:6.5%;top:15.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:44.7%;top:42%" aria-hidden="true">2</span><span class="gd-pin" style="left:64.2%;top:94%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-check-a-car-out-or-in" data-gd-task><h2 class="gd-h2">Check a car out or in</h2><p class="gd-p">Fleet, Sales and Customer service check cars out and in from the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On a confirmed booking press <b class="gd-ui">Check out (pickup)</b>; on a booking on rent, <b class="gd-ui">Check in (return)</b>. Today lists the ones due, each with its button.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The checklist field staff use opens: readings (km and fuel or charge), the photo set with the plate and the gauges, damage close-ups and both signatures.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Afterwards press <b class="gd-ui">Photo report</b>: times, Late by, kilometres, fuel, photos and the return charges. Fleet waives a charge with <b class="gd-ui">Waive</b> and a reason.</div></li></ol></div></section><section class="gd-task" id="fleet-photo-reviews-after-a-return" data-gd-task><h2 class="gd-h2">Photo reviews after a return</h2><p class="gd-p">After each return, the field photo set waits under <b class="gd-ui">Photo reviews</b>. Compare it with the pickup set. Press <b class="gd-ui">Review done</b>, or <b class="gd-ui">Ask for a re-shoot</b> if a photo is missing or unclear.</p></section><section class="gd-task" id="fleet-similar-cars" data-gd-task><h2 class="gd-h2">Similar cars</h2><p class="gd-p">A possible duplicate never keeps a car off the site: it shows on the car&#39;s checklist until you decide. Only Same car takes it off.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Compare the permit, the plate and the photos.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Not a duplicate</b> with a note when they are different cars, or <b class="gd-ui">Same car</b> when they are.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/similar-cars</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/460"><img src="/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg" alt="" loading="lazy" decoding="async" width="1230" height="460"><span class="gd-pin" style="left:23.6%;top:30.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.8%;top:30.4%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-rates-and-kilometres" data-gd-task><h2 class="gd-h2">Rates and kilometres</h2><p class="gd-p">From a listing, press <b class="gd-ui">The car and its rates</b>, or open the car from Field jobs.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Keep <b class="gd-ui">Use the defaults</b> for the kilometres, or choose <b class="gd-ui">Custom for this car</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check What renters pay under the fields, then press <b class="gd-ui">Save the rates</b>. Rates, kilometres and deposit save together.</div></li></ol></div></section><section class="gd-task" id="fleet-listings-and-covering-plates" data-gd-task><h2 class="gd-h2">Listings and covering plates</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Listings</b>. A draft waiting shows Needs review. Open it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/listings</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/340"><img src="/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="340"><span class="gd-pin" style="left:54.5%;top:49.1%" aria-hidden="true">1</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The listing&#39;s Steps to go live says what is next: 1 Photos, 2 Cover plates, 3 Review, 4 Live on the site, each with its button. The plate box is suggested by itself on every outside photo as the listing opens (Box suggested). Press <b class="gd-ui">Cover the plate</b> and check it; <b class="gd-ui">Suggest the plate</b> asks again. A photo filed under the wrong shot: <b class="gd-ui">Remove</b> under it on the Photos card, then take the right one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Drag over a plate to draw a box; drag a box to move it, its corner to resize it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Choose <b class="gd-ui">A CarmaCars plate</b>, <b class="gd-ui">Pixelation</b> or <b class="gd-ui">Blur</b>, then <b class="gd-ui">Save the covered photo</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">No plate in the shot? <b class="gd-ui">No plate visible on this photo</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/776"><img src="/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg" alt="" loading="lazy" decoding="async" width="390" height="776"><span class="gd-pin" style="left:52.6%;top:78.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:50%;top:43.8%" aria-hidden="true">4</span><span class="gd-pin" style="left:61.5%;top:62.1%" aria-hidden="true">5</span><span class="gd-pin" style="left:43.1%;top:92.3%" aria-hidden="true">6</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.</div></aside></section><section class="gd-task" id="fleet-publish-now" data-gd-task><h2 class="gd-h2">Publish now</h2><p class="gd-p">Customer service and fleet publish a car themselves; nothing has to be finished first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press <b class="gd-ui">Publish now</b>. With no rates yet it uses the suggested rates (similar cars, else the class defaults).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.</div></aside></section><section class="gd-task" id="fleet-calendar-sync-with-turo-and-other-platforms" data-gd-task><h2 class="gd-h2">Calendar sync with Turo and other platforms</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Calendar sync</b>: a car listed on Turo or Getaround must never be booked twice.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turo has no calendar link: Turo&#39;s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">An email the reader cannot place waits as &quot;Which car is this?&quot;: press <b class="gd-ui">Which car is this?</b> and press the right car (best guesses first). It is remembered for that car&#39;s next emails. If the dates or trip number are missing: <b class="gd-ui">Add as a Turo trip</b> (choose the car, check the dates) or <b class="gd-ui">Dismiss</b>. A trip whose email did not come: <b class="gd-ui">Add a Turo trip</b> on the car.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each Turo trip shows the guest&#39;s name and phone when Turo&#39;s email includes them. Contact a Turo guest only about their trip, never with promotions.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Turo cannot read our calendar: under &quot;Block on Turo&quot;, block each CarmaCars booking on the car&#39;s Turo calendar, then press <b class="gd-ui">Done on Turo</b>. Dates that changed or a booking cancelled here show the dates to free on Turo.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Getaround, Google Calendar or another platform with a calendar (iCal) link: open <b class="gd-ui">Add a calendar link</b>, choose the platform, paste it and press <b class="gd-ui">Add the link</b>. Copy the car&#39;s CarmaCars link for that platform with <b class="gd-ui">Copy</b> and paste it into the platform&#39;s calendar import.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.</div></li></ol></div><h3 class="gd-h3">Add the photos and readings</h3><p class="gd-p">A pickup or return recorded with the details later gives Fleet the task <b class="gd-ui">Add the photos and readings for CC-...</b>. Open the booking and press <b class="gd-ui">Add the check-out (or check-in) photos and readings</b>: the usual checklist opens without the ready check or the renter&#39;s signature. Take the photos, the odometer, fuel, keys (and cleanliness at a return), sign and save. The task closes by itself; it cannot be closed by hand before.</p></section><section class="gd-task" id="fleet-bookings-now" data-gd-task><h2 class="gd-h2">Bookings now</h2><p class="gd-p"><b class="gd-ui">Rentals</b> &gt; <b class="gd-ui">Bookings</b> opens on Now for fleet and customer service: the cars out with their renter and due-back countdown, coming back today and tomorrow (overdue first, in red), going out in the next 72 hours with what is ready, the money due in 7 days and the free cars. It refreshes by itself every 30 seconds. A booking listed as <b class="gd-ui">Out (pickup not recorded)</b> left without a check-out: press <b class="gd-ui">Mark picked up</b>, then add the photos, km and fuel from the task. The search above it finds any booking.</p><h3 class="gd-h3">The renter says the car is back</h3><p class="gd-p">An urgent To do &quot;The renter says the car is back&quot; means the renter pressed <b class="gd-ui">I&#39;ve returned the car</b> on an overdue booking. Their overdue notices are paused. Open the booking, check the car (place, tracker, the renter&#39;s photos), then press <b class="gd-ui">Confirm</b> (correct the odometer, fuel or time first if needed; the trip is completed) or <b class="gd-ui">Deny</b> with the reason (the renter is told and the notices start again).</p></section>');
select app.guide_release_section('field', 'a-return', 'chapter', 'a-handover', 'The return mirrors the handover. You record the car as it comes back and compare it with the pickup.

## Take the car back

1. Car and keys received: confirm you have the car and its keys.
2. Odometer, then Fuel or charge, as at pickup.
3. Keys and extras: count what came back.
4. Cleanliness: inside and out.
5. Photo set: the same shots, in the same order, as at pickup.
6. Compare with pickup: for new damage, tap the diagram, fill in Where and What it is, press **Add the damage** and take a close-up photo.
7. Belongings: check the seats, the trunk, the glovebox and the door pockets.
8. Renter reviews and signs. Then you sign.
9. Press **Complete the return**. The check-in time is the moment you press it: a late return, the kilometres over the allowance and the fuel or charge used are charged from it automatically. The deposit is not given back at the return: Finance settles it once tolls and tickets have had time to come in (about 7 days), and new damage you mark keeps it held.
10. The closing copy of both rental agreements follows by itself: time and date in, kilometres in, driven and charged, fuel in, the hours late, the new damage, the return charges and the totals, countersigned with your name, emailed to the renter.

> Watch out: New damage needs a close-up photo and a clear note. Finance uses your photos and notes to bill the renter, so take your time.
', 'A return', 'Odometer, fuel, keys, cleanliness, photos, new damage, belongings and signatures.',
  'The return mirrors the handover. You record the car as it comes back and compare it with the pickup.

## Take the car back

1. Car and keys received: confirm you have the car and its keys.
2. Odometer, then Fuel or charge, as at pickup.
3. Keys and extras: count what came back.
4. Cleanliness: inside and out.
5. Photo set: the same shots, in the same order, as at pickup.
6. Compare with pickup: for new damage, tap the diagram, fill in Where and What it is, press **Add the damage** and take a close-up photo.
7. Belongings: check the seats, the trunk, the glovebox and the door pockets.
8. Renter reviews and signs. Then you sign.
9. Press **Complete the return**. The check-in time is the moment you press it: a late return, the kilometres over the allowance and the fuel or charge used are charged from it automatically. The deposit is not given back at the return: Finance settles it once tolls and tickets have had time to come in (about 7 days), and new damage you mark keeps it held.
10. The closing copy of both rental agreements follows by itself: time and date in, kilometres in, driven and charged, fuel in, the hours late, the new damage, the return charges and the totals, countersigned with your name, emailed to the renter.

> Watch out: New damage needs a close-up photo and a clear note. Finance uses your photos and notes to bill the renter, so take your time.

> Tip: If the renter already pressed I''ve returned the car, the booking shows **The renter says the car is back** with their photos and readings. Check the car in as usual: that completes the trip and settles their report.
',
  '<p class="gd-p">The return mirrors the handover. You record the car as it comes back and compare it with the pickup.</p><section class="gd-task" id="a-return-take-the-car-back" data-gd-task><h2 class="gd-h2">Take the car back</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Car and keys received: confirm you have the car and its keys.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Odometer, then Fuel or charge, as at pickup.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Keys and extras: count what came back.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Cleanliness: inside and out.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Photo set: the same shots, in the same order, as at pickup.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Compare with pickup: for new damage, tap the diagram, fill in Where and What it is, press <b class="gd-ui">Add the damage</b> and take a close-up photo.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Belongings: check the seats, the trunk, the glovebox and the door pockets.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Renter reviews and signs. Then you sign.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Press <b class="gd-ui">Complete the return</b>. The check-in time is the moment you press it: a late return, the kilometres over the allowance and the fuel or charge used are charged from it automatically. The deposit is not given back at the return: Finance settles it once tolls and tickets have had time to come in (about 7 days), and new damage you mark keeps it held.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">The closing copy of both rental agreements follows by itself: time and date in, kilometres in, driven and charged, fuel in, the hours late, the new damage, the return charges and the totals, countersigned with your name, emailed to the renter.</div></li></ol></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>New damage needs a close-up photo and a clear note. Finance uses your photos and notes to bill the renter, so take your time.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>If the renter already pressed I&#39;ve returned the car, the booking shows <b class="gd-ui">The renter says the car is back</b> with their photos and readings. Check the car in as usual: that completes the trip and settles their report.</div></aside></section>');
-- GUIDES 0532 END
