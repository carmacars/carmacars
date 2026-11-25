-- 4730 (release 50, live incident CC-10597): the return is never blocked, and an approved licence covers every booking.
-- SCHEMA_MARKER stays 5011 (the highest migration).
--
-- 1. An approved licence and selfie belong to the renter's driver, not to one booking. The licence set is copied to a new
--    booking (app.licence_reuse) with its status at the time of the copy: a set still in review stayed "in review" on
--    the new booking after staff approved it on the earlier one (approval synced only the booking it was made on). Now
--    a review decision follows the same document onto every booking that carries it, the reused verification follows
--    its source, and every open booking of the driver is synced. A one-off, idempotent re-link fixes the existing rows.
--    Coverage proof keeps its own per-booking rule.
-- 2. Documents gate the pickup, never the return. A renter who has the car but whose pickup was never recorded (still
--    confirmed after the pickup time) can report the return: the pickup is recorded at the booked time as "not recorded
--    at the time" (an audited override of the pickup checks: licence, coverage, deposit, signatures, agreement details,
--    tracker), Admin and Fleet are told, and what is still owed or unreviewed becomes To dos collected afterwards.
--    Staff have the same as one tap (ops action pickup_record_booked_time).
-- 3. The readiness says which licence state the renter is in (verified, in_review, missing), so the renter's page asks
--    only for what is genuinely missing.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. the licence belongs to the driver
-- The driver's licence approved anywhere (front, back and selfie), with a licence valid past this booking's return.
create or replace function app.driver_licence_approved_for(p_driver uuid, p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select p_driver is not null
     and (select count(distinct u.kind) from verification_uploads u
           where u.driver_id = p_driver and u.status = 'approved' and u.kind in ('licence_front', 'licence_back', 'selfie'))
         >= case when coalesce((app.settings()).booking_licence_selfie_required, true) then 3 else 2 end
     and coalesce((select bd.licence_expiry from booking_drivers bd where bd.booking_id = p_booking and bd.driver_id = p_driver),
                  (select d.licence_expiry from drivers d where d.id = p_driver))
         > (select app.local_date(b.return_at) from bookings b where b.id = p_booking)
$$;

-- Each kind: the newest upload on this booking approved, or (nothing refused on this booking) approved for the driver.
create or replace function app.booking_driver_verify_sync(p_booking uuid) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  d booking_drivers;
  v_n integer := 0;
  v_ok boolean;
  v_any boolean;
begin
  for d in select * from booking_drivers where booking_id = p_booking and identity_verified_on is null and driver_id is not null loop
    v_any := app.driver_licence_approved_for(d.driver_id, p_booking);
    select coalesce(bool_and(coalesce(
             (select case when u.status = 'approved' then true when u.status = 'rejected' then false else null end
                from verification_uploads u where u.booking_id = p_booking and u.driver_id = d.driver_id and u.kind = k
                 and u.status in ('submitted', 'approved', 'rejected') order by u.uploaded_at desc limit 1),
             v_any)), false)
      into v_ok from unnest(array['licence_front', 'licence_back', 'selfie']) k;
    if v_ok then
      update booking_drivers set identity_verified_on = app.today(), identity_method = coalesce(identity_method, 'staff_review') where id = d.id;
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $$;

-- A decision on a licence upload follows the same document onto the driver's other bookings; then every open booking of
-- the driver is synced.
create or replace function app.verification_upload_follow() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare x record;
begin
  if new.kind not in ('licence_front', 'licence_back', 'selfie') or new.driver_id is null then return new; end if;
  if new.status in ('approved', 'rejected') and old.status = 'submitted' and pg_trigger_depth() < 3 then
    update verification_uploads u set status = new.status, reviewed_by = new.reviewed_by, reviewed_at = coalesce(new.reviewed_at, now()),
           reject_reason = case when new.status = 'rejected' then new.reject_reason else u.reject_reason end
     where u.id <> new.id and u.driver_id = new.driver_id and u.kind = new.kind and u.document_id = new.document_id and u.status = 'submitted';
  end if;
  if new.status = 'approved' and old.status is distinct from 'approved' then
    for x in select distinct bd.booking_id from booking_drivers bd join bookings b on b.id = bd.booking_id
              where bd.driver_id = new.driver_id and bd.identity_verified_on is null
                and b.status in ('requested', 'offered', 'pending_payment', 'confirmed', 'on_rent') loop
      perform app.booking_driver_verify_sync(x.booking_id);
    end loop;
  end if;
  return new;
end $$;
drop trigger if exists verification_uploads_follow on verification_uploads;
create trigger verification_uploads_follow after update of status on verification_uploads
  for each row execute function app.verification_upload_follow();

-- A reused verification follows its source's decision.
create or replace function app.identity_verification_follow() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if new.status in ('verified', 'failed') and old.status is distinct from new.status and pg_trigger_depth() < 3 then
    update identity_verifications v set status = new.status, verified_by = coalesce(new.verified_by, v.verified_by), verified_at = coalesce(new.verified_at, v.verified_at)
     where v.checks ->> 'reused_from' = new.id::text and v.status = 'pending';
  end if;
  return new;
end $$;
drop trigger if exists identity_verifications_follow on identity_verifications;
create trigger identity_verifications_follow after update of status on identity_verifications
  for each row execute function app.identity_verification_follow();

-- The licence states the renter sees: an upload in review elsewhere approved reads approved once the booking is verified.
alter function app.licence_status(uuid, uuid) rename to licence_status_pre4730;
create function app.licence_status(p_booking uuid, p_driver uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v jsonb := app.licence_status_pre4730(p_booking, p_driver);
  k text;
begin
  if coalesce((v ->> 'verified')::boolean, false) or app.driver_licence_approved_for(p_driver, p_booking) then
    foreach k in array array['licence_front', 'licence_back', 'selfie'] loop
      if coalesce(v ->> k, 'submitted') = 'submitted' then v := v || jsonb_build_object(k, 'approved'); end if;
    end loop;
    v := v || jsonb_build_object('missing', coalesce((select jsonb_agg(m) from jsonb_array_elements_text(v -> 'missing') m
                                                       where m not in ('licence front', 'licence back', 'selfie with the licence')), '[]'::jsonb));
    v := v || jsonb_build_object('complete', jsonb_array_length(v -> 'missing') = 0);
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.licence_status(uuid, uuid)'::regprocedure, 'app.licence_status_pre4730(uuid, uuid)'::regprocedure);

-- The renter's licence state on the readiness: verified, in_review (everything sent, not decided) or missing.
alter function app.booking_readiness(uuid) rename to booking_readiness_pre4730;
create function app.booking_readiness(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  r jsonb := app.booking_readiness_pre4730(p_booking);
  d booking_drivers;
  s jsonb;
begin
  if r is null then return r; end if;
  select * into d from booking_drivers where booking_id = p_booking and role = 'renter' limit 1;
  if d.id is null then return r || jsonb_build_object('identity_state', 'missing'); end if;
  if d.identity_verified_on is not null then return r || jsonb_build_object('identity_state', 'verified'); end if;
  s := app.licence_status(p_booking, d.driver_id);
  return r || jsonb_build_object('identity_state',
    case when coalesce((s ->> 'verified')::boolean, false) then 'verified'
         when not exists (select 1 from jsonb_array_elements_text(s -> 'missing') m where m in ('licence front', 'licence back', 'selfie with the licence'))
              and 'submitted' in (s ->> 'licence_front', s ->> 'licence_back', s ->> 'selfie') then 'in_review'
         when not exists (select 1 from jsonb_array_elements_text(s -> 'missing') m where m in ('licence front', 'licence back', 'selfie with the licence')) then 'verified'
         else 'missing' end,
    'identity_missing', coalesce((select jsonb_agg(m) from jsonb_array_elements_text(s -> 'missing') m), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.booking_readiness(uuid)'::regprocedure, 'app.booking_readiness_pre4730(uuid)'::regprocedure);

-- The one-off re-link (idempotent): copies still in review whose document was decided on another booking, reused
-- verifications behind their source, then every open booking with an unverified driver.
update identity_verifications v set status = s.status, verified_by = coalesce(s.verified_by, v.verified_by), verified_at = coalesce(s.verified_at, v.verified_at)
  from identity_verifications s
 where v.checks ->> 'reused_from' = s.id::text and v.status = 'pending' and s.status in ('verified', 'failed');
update verification_uploads u set status = o.status, reviewed_by = o.reviewed_by, reviewed_at = o.reviewed_at
  from (select distinct on (driver_id, kind, document_id) driver_id, kind, document_id, status, reviewed_by, reviewed_at
          from verification_uploads where status = 'approved' and kind in ('licence_front', 'licence_back', 'selfie') and driver_id is not null
         order by driver_id, kind, document_id, reviewed_at desc nulls last) o
 where u.status = 'submitted' and u.driver_id = o.driver_id and u.kind = o.kind and u.document_id = o.document_id;
do $$
declare x record;
begin
  for x in select b.id from bookings b
            where b.status in ('requested', 'offered', 'pending_payment', 'confirmed', 'on_rent')
              and exists (select 1 from booking_drivers bd where bd.booking_id = b.id and bd.identity_verified_on is null and bd.driver_id is not null) loop
    perform app.booking_driver_verify_sync(x.id);
  end loop;
end $$;

-- ================================================================ 2. the return is never blocked
insert into task_rules (task_type, queue, title, priority) values
  ('pickup_not_recorded', 'fleet', 'Pickup not recorded at the time: check what is still owed', 'high'),
  ('docs_review_after_return', 'fleet', 'Review the renter''s documents (the car went out or came back before they were checked)', 'high')
on conflict (task_type) do nothing;
insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort, pref_type) values
  ('pickup_not_recorded', 'A pickup was recorded late, at the booked time', 'Field work', '{admin,fn:fleet}', 'urgent', 'handovers', true, false,
   'Return gate (4730): the renter had the car but the pickup was never recorded; it was recorded at the booked time so the return could go ahead.', 75, 'staff_fleet')
on conflict (rule) do nothing;

-- What the pickup still lacks, in plain words, for the To do.
create or replace function app.pickup_outstanding(p_booking uuid) returns text[]
language sql stable security definer set search_path = public, app, pg_temp as $$
  select array_remove(array[
    case when exists (select 1 from booking_drivers d where d.booking_id = b.id and d.identity_verified_on is null)
           or not exists (select 1 from booking_drivers d where d.booking_id = b.id and d.role = 'renter')
         then 'the driver''s licence and selfie are not reviewed' end,
    case when b.booking_type <> 'owner' and (b.coverage_confirmed_at is null
           or not exists (select 1 from coverage_proofs c where c.booking_id = b.id and c.status = 'confirmed'))
         then 'the coverage is not confirmed' end,
    case when b.booking_type <> 'owner' and b.deposit_cents > 0 and b.deposit_waived_at is null
           and not exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured'))
         then format('the deposit (%s) is not taken', to_char(b.deposit_cents / 100.0, 'FM$999,990.00')) end,
    case when b.booking_type <> 'owner' and not exists (select 1 from signature_requests s where s.id = b.signature_request_id and s.status = 'completed')
         then 'the rental agreement is not signed' end
  ], null)
  from bookings b where b.id = p_booking
$$;

-- The pickup recorded at the booked time, for a car the renter already has. p_source: renter_return, staff.
create or replace function app.pickup_record_booked_time(p_by uuid, p_booking uuid, p_source text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  o booking_overrides;
  v_actor uuid;
  v_left text[];
  v_reason text;
  r jsonb;
  v_task uuid;
  v_docs uuid;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if p_source = 'staff' then
    if not app.user_may_handover_pre0545(p_by) then
      raise exception 'Only an Admin, Fleet, Sales, Customer service or field staff record a pickup' using errcode = '42501';
    end if;
    v_actor := p_by;
  else
    v_actor := coalesce(p_by, (select r2.user_id from renters r2 where r2.id = b.renter_id));
    if v_actor is null or not coalesce(app.is_booking_renter(b.id, v_actor), false) then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  end if;
  if b.status <> 'confirmed' or b.handed_over_at is not null then
    return jsonb_build_object('status', 'skipped', 'booking_status', b.status);
  end if;
  if b.pickup_at > now() then
    raise exception 'The pickup of booking % is %: it is recorded at the booked time once that time has passed', b.booking_number, app.fmt_at(b.pickup_at) using errcode = '23514';
  end if;
  v_left := app.pickup_outstanding(b.id);
  v_reason := case p_source when 'staff' then 'Pickup not recorded at the time: recorded at the booked time by staff'
                            else 'Pickup not recorded at the time: recorded at the booked time when the renter returned the car' end;
  update booking_overrides set status = 'cancelled', decision_note = 'Superseded: the pickup was recorded at the booked time (4730)', decided_at = now()
   where booking_id = b.id and action = 'pickup' and status in ('requested', 'applying');
  insert into booking_overrides (booking_id, action, checks, reason, payload, status, requested_by, decided_by, decided_at)
  values (b.id, 'pickup', array['identity', 'coverage', 'deposit', 'payment', 'report_signature', 'agreement_details', 'tracker', 'addons', 'agreement'],
          v_reason, jsonb_build_object('source', p_source, 'at', b.pickup_at, 'outstanding', to_jsonb(v_left)), 'applying', v_actor, v_actor, now())
  returning * into o;
  perform set_config('app.booking_override', o.id::text, true);
  if p_source <> 'staff' then perform set_config('app.self_handover_by', v_actor::text, true); end if;
  update bookings set unattended_handover = true where id = b.id and not coalesce(unattended_handover, false);
  r := app.handover_record_now(v_actor, jsonb_build_object('booking', b.id, 'kind', 'pickup', 'at', b.pickup_at, 'reason', v_reason));
  perform set_config('app.booking_override', '', true);
  perform set_config('app.self_handover_by', '', true);
  update condition_reports set recorded_now = coalesce(recorded_now, '{}'::jsonb) || jsonb_build_object('not_recorded_at_the_time', true, 'source', p_source)
   where id = (r ->> 'report_id')::uuid;
  update booking_overrides set status = 'used', used_at = now(), result = r where id = o.id;
  -- the trip started long ago for the renter: no "your rental started" message now
  if p_source = 'renter_return' then
    update notification_outbox set status = 'skipped', status_reason = 'Pickup recorded at the return (4730)'
     where booking_id = b.id and code = 'renter_rental_started' and status in ('queued', 'delayed');
  end if;

  v_task := app.raise_task(p_type => 'pickup_not_recorded',
    p_title => left(format('%s: pickup recorded late, at the booked time', b.booking_number), 200),
    p_detail => left(format('The pickup was not recorded at the time; it was recorded at the booked time (%s) %s. Still to do: %s. Collect what is owed after the return; the renter is not stopped from returning the car.',
                  app.fmt_at(b.pickup_at), case p_source when 'staff' then 'by staff' else 'when the renter reported the return' end,
                  coalesce(nullif(array_to_string(v_left, '; '), ''), 'nothing')), 2000),
    p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_related_table => 'booking_overrides', p_related_id => o.id,
    p_dedupe => 'pickup_not_recorded:' || b.id, p_created_by => case when p_source = 'staff' then p_by end);
  if exists (select 1 from booking_drivers d where d.booking_id = b.id and d.identity_verified_on is null) then
    v_docs := app.raise_task(p_type => 'docs_review_after_return',
      p_title => left(format('%s: review the renter''s licence and selfie', b.booking_number), 200),
      p_detail => 'The trip went ahead before the documents were checked. Review them on the booking; ask the renter for anything missing.',
      p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_dedupe => 'docs_review_after_return:' || b.id);
  end if;
  perform app.staff_alert('pickup_not_recorded', 'booking', b.id, b.id::text,
    format('%s: pickup recorded late, at the booked time', b.booking_number),
    coalesce('Still to do: ' || nullif(array_to_string(v_left, '; '), ''), 'Nothing else is outstanding.'));
  perform app.log_booking_event(b.id, 'adjusted', 'on_rent', 'on_rent', null,
    format('Pickup not recorded at the time: recorded at the booked time (%s)%s', app.fmt_at(b.pickup_at),
           coalesce('. Still to do: ' || nullif(array_to_string(v_left, '; '), ''), '')),
    v_actor, case when p_source = 'staff' then 'staff' else 'renter' end,
    jsonb_build_object('override_id', o.id, 'source', p_source, 'outstanding', to_jsonb(v_left), 'task_id', v_task, 'docs_task_id', v_docs, 'report_id', r ->> 'report_id'));
  return jsonb_build_object('status', 'recorded', 'booking_status', (select status from bookings where id = b.id), 'report_id', r ->> 'report_id',
                            'outstanding', to_jsonb(v_left), 'task_id', v_task);
end $$;

-- The renter's return report: a car out with a pickup never recorded gets it recorded first; never refused for
-- documents, deposit, agreement, payment or coverage. Unreviewed documents at the return become Fleet's To do.
alter function public.server_return_claim_submit(uuid, jsonb, uuid) rename to server_return_claim_submit_pre4730;
create function public.server_return_claim_submit(p_token uuid, p jsonb, p_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  r jsonb;
begin
  select * into b from bookings where return_link_token = p_token and not coalesce(is_placeholder, false);
  if b.id is not null and b.status = 'confirmed' and b.handed_over_at is null and app.booking_is_out(b, now())
     and b.return_state is distinct from 'returned_pending_confirmation' then
    begin
      perform app.pickup_record_booked_time(coalesce(p_user, (select r2.user_id from renters r2 where r2.id = b.renter_id)), b.id, 'renter_return');
    exception when others then
      -- the report is still taken: staff confirm it, and the confirm records the pickup first
      raise warning '4730 pickup at the booked time of %: %', b.booking_number, sqlerrm;
    end;
  end if;
  r := public.server_return_claim_submit_pre4730(p_token, p, p_user);
  if b.id is not null and exists (select 1 from booking_drivers d where d.booking_id = b.id and d.identity_verified_on is null) then
    perform app.raise_task(p_type => 'docs_review_after_return',
      p_title => left(format('%s: review the renter''s licence and selfie', b.booking_number), 200),
      p_detail => 'The car came back before the documents were checked. Review them on the booking; ask the renter for anything missing.',
      p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_dedupe => 'docs_review_after_return:' || b.id);
  end if;
  return r;
end $$;
select pg_temp.copy_grants('public.server_return_claim_submit(uuid, jsonb, uuid)'::regprocedure, 'public.server_return_claim_submit_pre4730(uuid, jsonb, uuid)'::regprocedure);

-- Staff confirming a return report on a booking whose pickup was never recorded: the pickup is recorded first.
alter function app.return_claim_decide(uuid, jsonb) rename to return_claim_decide_pre4730;
create function app.return_claim_decide(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare b bookings;
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is not null and coalesce(p ->> 'decision', '') = 'confirm' and b.status = 'confirmed' and b.handed_over_at is null
     and exists (select 1 from return_claims c where c.booking_id = b.id and c.status = 'pending') then
    if coalesce(current_setting('app.self_handover_by', true), '') <> '' then
      perform app.pickup_record_booked_time(p_by, b.id, 'renter_return');
    else
      perform app.pickup_record_booked_time(p_by, b.id, 'staff');
    end if;
  end if;
  return app.return_claim_decide_pre4730(p_by, p);
end $$;
select pg_temp.copy_grants('app.return_claim_decide(uuid, jsonb)'::regprocedure, 'app.return_claim_decide_pre4730(uuid, jsonb)'::regprocedure);

-- The staff one tap: ops_do pickup_record_booked_time {booking}.
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre4730;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
  v_b uuid;
begin
  if p_call in ('ops_do', 'admin_do', 'va_do') and p_name = 'pickup_record_booked_time' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    select id into v_b from bookings where id::text = p_ ->> 'booking' or booking_number = upper(btrim(coalesce(p_ ->> 'booking', '')));
    if v_b is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
    return app.pickup_record_booked_time(p_user, v_b, 'staff');
  end if;
  return app.door_pre4730(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre4730(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['driver_licence_approved_for', 'booking_driver_verify_sync', 'verification_upload_follow',
                    'identity_verification_follow', 'pickup_outstanding', 'pickup_record_booked_time'])
               or (n.nspname = 'app' and p.proname in ('licence_status_pre4730', 'booking_readiness_pre4730', 'return_claim_decide_pre4730', 'door_pre4730'))
               or (n.nspname = 'public' and p.proname = 'server_return_claim_submit_pre4730')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
