-- 0283_placeholder_bookings.sql
-- Placeholder bookings never get mixed up with the real rental (docs/changes/2026-11-05-placeholder-bookings.md). The
-- owner (2026-10-15): "for toll charges to go to the matched renter automatically when staff confirm a notice, that is
-- fine but what if there are 2 bookings on the same car (due to dummy bookings for insurance)".
--
-- 0046 told a placeholder apart by its shape only (it does not block the calendar and was never handed over). Add a
-- rental's "Placeholder" quick start left the calendar switch on, so a placeholder blocked the car, stopped the real
-- rental from being entered and counted as a real rental for tolls. Now a placeholder is said in so many words:
--
-- 1. bookings.is_placeholder (with the reason, who and when). A placeholder never blocks the calendar, is never handed
--    over, sends the renter nothing and takes no money: a booking with money taken, or one already handed over, is a real
--    rental and cannot become a placeholder.
-- 2. app.booking_is_placeholder: the flag, or 0046's shape. Every toll, ticket and damage match, Add a rental's clash
--    check and the commission already ask it, so the real renter is matched and the placeholder never is.
-- 3. Admins mark or unmark a booking (app.set_booking_placeholder, door admin_do booking_placeholder). Marking one
--    turns the calendar switch off, hides it from the owner (they see the dates as unavailable), cancels its field jobs
--    and closes its renter tasks.
-- 4. Add a rental's "placeholder": true makes the booking a placeholder from the start (Admins only).
-- 5. Nothing about running a rental is asked of staff for a placeholder: the renter tasks (offer, verification, deposit,
--    handover, late return, provisional dates and the like) are not raised, and no field job is made.
-- 6. No sales commission on a placeholder.
-- 7. The Live map leaves placeholders out: no pin, not in On the road, not in the numbers.
-- 8. The bookings written by Add a rental's Placeholder quick start before this release become placeholders.
-- No applied migration is edited.

-- ================================================================ 1. the flag
alter table bookings add column if not exists is_placeholder boolean not null default false,
  add column if not exists placeholder_reason text,
  add column if not exists placeholder_by uuid references users (id),
  add column if not exists placeholder_at timestamptz;
comment on column bookings.is_placeholder is 'A placeholder booking (0283): held for an insurer or as a hold, never the real rental. It never blocks the calendar, is never handed over, sends the renter nothing, is never matched to a toll, ticket or damage, earns no commission and is left out of the Live map.';
create index if not exists bookings_placeholder_idx on bookings (vehicle_id) where is_placeholder;

-- the booking history can say so
do $$
declare d text;
begin
  select pg_get_constraintdef(oid) into d from pg_constraint where conrelid = 'booking_events'::regclass and conname = 'booking_events_kind_check';
  if d is not null and d not like '%''placeholder''%' then
    execute 'alter table booking_events drop constraint booking_events_kind_check';
    execute 'alter table booking_events add constraint booking_events_kind_check ' || replace(d, 'ARRAY[', 'ARRAY[''placeholder''::text, ');
  end if;
end $$;

-- the rules, whoever writes the row
create or replace function app.booking_placeholder_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_by uuid;
  v_why text;
begin
  if not new.is_placeholder then return new; end if;
  if tg_op = 'UPDATE' and new.status = 'on_rent' and old.status is distinct from 'on_rent' then
    raise exception 'Booking % is a placeholder, so it is never handed over: hand over the real rental, or make it a real booking first', new.booking_number
      using errcode = '23514';
  end if;
  if new.blocks_calendar then
    v_by := coalesce(new.placeholder_by, new.blocks_calendar_changed_by, app.uid(), new.created_by);
    v_why := 'Placeholder booking' || coalesce(': ' || nullif(btrim(new.placeholder_reason), ''), '');
    if tg_op = 'UPDATE' and v_why is not distinct from old.blocks_calendar_reason then v_why := v_why || ' (again)'; end if;
    new.blocks_calendar := false;
    new.blocks_calendar_reason := v_why;
    new.blocks_calendar_changed_by := v_by;
  end if;
  new.do_not_email := true;
  return new;
end $$;
drop trigger if exists a0_placeholder on bookings;
create trigger a0_placeholder before insert or update on bookings for each row execute function app.booking_placeholder_guard();

-- ================================================================ 2. what counts as a placeholder
create or replace function app.booking_is_placeholder(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select b.is_placeholder
      or (not b.blocks_calendar and b.handed_over_at is null and b.status not in ('on_rent', 'returned', 'closed'))
    from bookings b where b.id = p_booking
$$;

-- ================================================================ 5. no renter work for a placeholder
create or replace function app.placeholder_quiet_tasks() returns text[]
language sql immutable as $$
  select array['addon_confirm', 'addon_payment', 'addon_prep', 'agreement_signature_waiting', 'chase_offer', 'chase_verification',
               'collect_balance', 'collect_upfront', 'deposit_capture_failed', 'deposit_declined', 'deposit_hold_lapsed', 'deposit_not_taken',
               'handover_blocked', 'handover_details', 'handover_essentials', 'insurer_provisional', 'job_unacknowledged', 'late_return',
               'late_return_admin', 'offer_approved_paid', 'offer_expired', 'paper_agreement_scan', 'protection_plan_request',
               'release_deposit', 'renew_deposit_hold', 'reoffer_booking', 'review_extension', 'schedule_detail', 'schedule_handover',
               'take_deposit', 'verify_renter']
$$;

alter function app.raise_task(text, text, text, uuid, uuid, uuid, uuid, text, uuid, timestamptz, text, text, text, uuid, text) rename to raise_task_pre0283;
create function app.raise_task(p_type text, p_title text default null, p_detail text default null, p_booking uuid default null,
    p_vehicle uuid default null, p_owner uuid default null, p_renter uuid default null, p_related_table text default null,
    p_related_id uuid default null, p_due_at timestamptz default null, p_priority text default null, p_dedupe text default null,
    p_queue text default null, p_created_by uuid default null, p_escalation_reason text default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_b uuid := coalesce(p_booking, case when p_related_table = 'bookings' then p_related_id end);
begin
  if v_b is not null and p_type = any (app.placeholder_quiet_tasks())
     and exists (select 1 from bookings b where b.id = v_b and b.is_placeholder) then
    return null;
  end if;
  return app.raise_task_pre0283(p_type, p_title, p_detail, p_booking, p_vehicle, p_owner, p_renter, p_related_table, p_related_id,
                                p_due_at, p_priority, p_dedupe, p_queue, p_created_by, p_escalation_reason);
end $$;

-- no field job for a placeholder; the ones already made are cancelled
alter function app.field_jobs_sync(uuid) rename to field_jobs_sync_pre0283;
create function app.field_jobs_sync(p_booking uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from bookings b where b.id = p_booking and b.is_placeholder) then
    update field_jobs set status = 'cancelled', cancel_reason = 'The booking is a placeholder: nobody hands it over'
     where booking_id = p_booking and status in ('scheduled', 'acknowledged');
    return 0;
  end if;
  return app.field_jobs_sync_pre0283(p_booking);
end $$;

-- ================================================================ 6. no commission
alter function app.commission_own_reason(uuid, uuid) rename to commission_own_reason_pre0283;
create function app.commission_own_reason(p_booking uuid, p_staff uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
begin
  if exists (select 1 from bookings b where b.id = p_booking and b.is_placeholder) then return 'Placeholder booking'; end if;
  return app.commission_own_reason_pre0283(p_booking, p_staff);
end $$;

-- ================================================================ 3. mark or unmark
create or replace function app.set_booking_placeholder(p_by uuid, p_booking uuid, p_on boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_tasks integer := 0;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin marks a placeholder booking' using errcode = '42501'; end if;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'No such booking' using errcode = 'P0002'; end if;
  if p_on is not distinct from b.is_placeholder then
    return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'is_placeholder', b.is_placeholder, 'changed', false);
  end if;
  if p_on then
    if b.status in ('on_rent', 'returned', 'closed') or b.handed_over_at is not null then
      raise exception 'Booking % was handed over, so it is a real rental. A placeholder is a booking that never goes out.', b.booking_number using errcode = '23514';
    end if;
    if b.status in ('cancelled', 'declined', 'expired', 'no_show') then
      raise exception 'Booking % is closed already: there is nothing to keep apart', b.booking_number using errcode = '23514';
    end if;
    if exists (select 1 from payments x where x.booking_id = b.id and x.status = 'succeeded' and x.kind in ('charge', 'capture')) then
      raise exception 'Money was taken on booking %, so it is a real rental. Refund it first if it really is a placeholder.', b.booking_number using errcode = '23514';
    end if;
    v_reason := coalesce(v_reason, 'Insurance or a hold');
    update bookings set is_placeholder = true, placeholder_reason = v_reason, placeholder_by = p_by, placeholder_at = now(),
           owner_visibility = 'never', owner_visibility_reason = 'Placeholder booking', owner_visibility_by = p_by, owner_visibility_at = now()
     where id = b.id;
    if b.owner_visibility is distinct from 'never' then
      insert into booking_owner_visibility_log (booking_id, visibility_from, visibility_to, reason, how, changed_by)
      values (b.id, b.owner_visibility, 'never', 'Placeholder booking', 'staff', p_by);
    end if;
    v_tasks := app.resolve_tasks(app.placeholder_quiet_tasks(), b.id, p_by, 'The booking is a placeholder', true);
    perform app.field_jobs_sync(b.id);
  else
    update bookings set is_placeholder = false, placeholder_reason = null, placeholder_by = p_by, placeholder_at = now() where id = b.id;
  end if;
  perform app.log_booking_event(b.id, 'placeholder', b.status::text, b.status::text, null,
    case when p_on then 'Marked as a placeholder booking: ' || v_reason || '. It does not block the calendar and is never matched to a toll or ticket.'
         else 'Made a real booking again' || coalesce(': ' || v_reason, '') || '. Turn the calendar switch on when it should hold the car.' end,
    p_by, 'staff', jsonb_build_object('is_placeholder', p_on, 'reason', v_reason));
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'is_placeholder', p_on, 'changed', true, 'tasks_closed', v_tasks);
end $$;

-- ================================================================ 4. Add a rental
alter function app.manual_rental_create(uuid, jsonb) rename to manual_rental_create_pre0283;
create function app.manual_rental_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
  v_id uuid;
  v_reason text := coalesce(nullif(btrim(coalesce(p ->> 'placeholder_reason', '')), ''), 'Insurance or a hold');
begin
  if coalesce((p ->> 'placeholder')::boolean, false) is not true then
    return app.manual_rental_create_pre0283(p_by, p - 'placeholder' - 'placeholder_reason');
  end if;
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin adds a placeholder booking' using errcode = '42501'; end if;
  if coalesce((p ->> 'past')::boolean, false) then
    raise exception 'A placeholder is never a past rental: add the real rental instead' using errcode = '22023';
  end if;
  v_out := app.manual_rental_create_pre0283(p_by, (p - 'placeholder' - 'placeholder_reason')
             || jsonb_build_object('blocks_calendar', false, 'blocks_calendar_reason', 'Placeholder booking: ' || v_reason));
  if (v_out ->> 'booking_id') !~ '^[0-9a-f-]{36}$' then return v_out; end if;
  v_id := (v_out ->> 'booking_id')::uuid;
  update bookings set is_placeholder = true, placeholder_reason = v_reason, placeholder_by = p_by, placeholder_at = now() where id = v_id;
  perform app.resolve_tasks(app.placeholder_quiet_tasks(), v_id, p_by, 'The booking is a placeholder', true);
  perform app.field_jobs_sync(v_id);
  perform app.log_booking_event(v_id, 'placeholder', null, null, null,
    'Added as a placeholder booking: ' || v_reason || '. It does not block the calendar and is never matched to a toll or ticket.',
    p_by, 'staff', jsonb_build_object('is_placeholder', true, 'reason', v_reason));
  return v_out || jsonb_build_object('blocks_calendar', false, 'is_placeholder', true);
end $$;

-- ================================================================ 7. the Live map
alter function app.live_map(uuid, jsonb) rename to live_map_pre0283;
create function app.live_map(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.live_map_pre0283(p_by, p);
  v_day date := app.local_date(now());
  v_ph text[] := array(select b.booking_number from bookings b where b.is_placeholder and b.status in ('requested', 'offered', 'tentative', 'pending_payment', 'confirmed', 'on_rent'));
begin
  if cardinality(v_ph) = 0 or v is null then return v; end if;
  v := jsonb_set(v, '{pins}', coalesce((select jsonb_agg(x order by n) from jsonb_array_elements(v -> 'pins') with ordinality t(x, n)
                                         where not (x ->> 'booking_number' = any (v_ph))), '[]'::jsonb));
  v := jsonb_set(v, '{kpi,requests_today}', to_jsonb(greatest(0, coalesce((v #>> '{kpi,requests_today}')::integer, 0)
         - (select count(*) from bookings b where b.is_placeholder and b.booked_at >= app.local_midnight(v_day) and b.booking_type <> 'owner')::integer)));
  v := jsonb_set(v, '{kpi,bookings_week}', to_jsonb(greatest(0, coalesce((v #>> '{kpi,bookings_week}')::integer, 0)
         - (select count(*) from bookings b where b.is_placeholder and b.confirmed_at >= app.local_midnight(date_trunc('week', v_day)::date) and b.booking_type <> 'owner')::integer)));
  return v;
end $$;

-- ================================================================ 3. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0283;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_do' and p_name = 'booking_placeholder' then
    perform app.door_begin(p_user, p_aal);
    return app.set_booking_placeholder(p_user, coalesce(nullif(p ->> 'booking', ''), p ->> 'booking_id')::uuid,
                                       coalesce((p ->> 'on')::boolean, true), p ->> 'reason');
  end if;
  return app.door_pre0283(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 8. the placeholders written before this release
update bookings b
   set is_placeholder = true, placeholder_reason = 'Insurance or a hold', placeholder_by = coalesce(b.blocks_calendar_changed_by, b.created_by), placeholder_at = now()
 where not b.is_placeholder
   and b.notes like '%Source: Placeholder booking%'
   and b.status not in ('on_rent', 'returned', 'closed', 'cancelled', 'declined', 'expired', 'no_show')
   and b.handed_over_at is null
   and (not b.blocks_calendar or coalesce(b.blocks_calendar_changed_by, b.created_by) is not null)
   and not exists (select 1 from payments x where x.booking_id = b.id and x.status = 'succeeded' and x.kind in ('charge', 'capture'));
update tasks t set status = 'cancelled', completed_at = now(), completion_note = 'The booking is a placeholder'
 where t.status in ('open', 'in_progress', 'waiting') and t.task_type = any (app.placeholder_quiet_tasks())
   and t.booking_id in (select id from bookings where is_placeholder);
update field_jobs j set status = 'cancelled', cancel_reason = 'The booking is a placeholder: nobody hands it over'
 where j.status in ('scheduled', 'acknowledged') and j.booking_id in (select id from bookings where is_placeholder);

-- ================================================================ privileges
do $$
declare
  g text;
  pair text[];
begin
  foreach pair slice 1 in array array[
      array['app.raise_task(text, text, text, uuid, uuid, uuid, uuid, text, uuid, timestamptz, text, text, text, uuid, text)', 'app.raise_task_pre0283(text, text, text, uuid, uuid, uuid, uuid, text, uuid, timestamptz, text, text, text, uuid, text)'],
      array['app.field_jobs_sync(uuid)', 'app.field_jobs_sync_pre0283(uuid)'],
      array['app.commission_own_reason(uuid, uuid)', 'app.commission_own_reason_pre0283(uuid, uuid)'],
      array['app.manual_rental_create(uuid, jsonb)', 'app.manual_rental_create_pre0283(uuid, jsonb)'],
      array['app.live_map(uuid, jsonb)', 'app.live_map_pre0283(uuid, jsonb)'],
      array['app.door(uuid, text, text, text, jsonb)', 'app.door_pre0283(uuid, text, text, text, jsonb)']] loop
    execute format('revoke all on function %s from public, anon, authenticated', pair[1]);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, pair[2]::regprocedure, 'execute') then execute format('grant execute on function %s to %I', pair[1], g); end if;
    end loop;
    execute format('revoke all on function %s from public, anon, authenticated', pair[2]);
    execute format('grant execute on function %s to service_role', pair[2]);
  end loop;
end $$;
revoke all on function app.set_booking_placeholder(uuid, uuid, boolean, text), app.booking_placeholder_guard(), app.placeholder_quiet_tasks() from public, anon, authenticated;
grant execute on function app.set_booking_placeholder(uuid, uuid, boolean, text), app.booking_placeholder_guard(), app.placeholder_quiet_tasks() to service_role;
