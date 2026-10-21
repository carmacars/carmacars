-- 0077_guided_actions.sql
-- The owner's standing rule (October 16 to 21, 2026): "admins and staff must never hunt through menus or remember
-- processes". Every recurring task is prompted to the right person at the right moment and done in one small pop-up,
-- pre-filled, on Admin > Today and on the record itself. (docs/changes/2026-10-21-guided-actions.md; the audit of
-- October 21, 2026, groups A and B.)
--   A. Handover blockers
--      1. "Insurer confirmed": one action marks a car on the fleet insurance policy from a date: its onboarding moves past
--         the insurer step to enrolled (the paperwork steps stay on the checklist), vehicles.on_fleet_policy and the
--         Enrollment Date are set, the owner gets the enrollment notice (T22), audited. One car or several at once (one
--         insurer email often confirms many cars). A program owner's car is on the policy only once this is done.
--      2. The texts of 0070 that pointed to a screen that did not exist now name the button.
--      3. Renter documents (licence images, selfie, proof of coverage, the Protection Plan) are reviewed by an Admin or
--         customer service from the booking itself, with no review task needed.
--   B. Guided To do and task hygiene
--      4. Admin > Today lists each piece of work as a prompt: one line saying what to do and why, and a pop-up that does
--         it in place (app.todo_prompts). Assistant-queue tasks show there while no real assistant holds that function.
--      5. Staff emails for an assistant function nobody real holds also go to the Admin (rent@carmacars.ca), linking to
--         Admin > Today.
--      6. Tasks close by rule: an upfront invoice voided or paid, yesterday's opening and closing checks, a chat answered
--         or closed, a fleet count back above the warning level, a car listed or insured.
-- Functions changed are wrapped (renamed with the suffix _pre0077) or replaced with the same signature. No applied
-- migration is edited.

-- ================================================================ 1. the insurer's confirmation
-- One insurer email may confirm a car before its paperwork is finished (agreements, registry, tracker): the onboarding
-- may move to "on the fleet policy" from any step after the terms. The paperwork stays on the car's checklist.
insert into status_transitions (entity, from_status, to_status, note)
select 'vehicle_onboarding', f, 'on_fleet_policy', 'Insurer confirmed (0077): the insurer confirmed the car before the paperwork was finished; the paperwork stays on the checklist'
  from unnest(array['terms_set', 'documents_sent', 'documents_signed', 'upfront_paid', 'registry_booked', 'registered']) f
 where not exists (select 1 from status_transitions s where s.entity = 'vehicle_onboarding' and s.from_status = f and s.to_status = 'on_fleet_policy');

alter table vehicle_onboardings
  add column if not exists insured_before_paperwork_from vehicle_onboarding_status,
  add column if not exists insurer_confirmed_by uuid references users (id),
  add column if not exists insurer_confirmation_note text;
comment on column vehicle_onboardings.insured_before_paperwork_from is
  'Insurer confirmed (0077): the onboarding step the car was at when the insurer confirmed it. Set: the agreements and the registry visit are judged from their own records, not from the status.';

-- On the fleet policy, so it may be handed over: a program owner's car once the insurer confirmed it (Insurer confirmed,
-- or the onboarding reached that step); a car with no onboarding (CarmaCars-owned, a partner's, a sample) once it has
-- left onboarding, as in 0070.
create or replace function app.vehicle_on_policy(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((
    select case
             when v.supply_type = 'program_owner' and not coalesce(v.on_fleet_policy, false)
                  and exists (select 1 from vehicle_onboardings ob where ob.vehicle_id = v.id
                                and ob.status not in ('on_fleet_policy', 'enrolled', 'declined', 'withdrawn'))
               then false
             else v.status <> 'onboarding' end
      from vehicles v where v.id = p_vehicle), false)
$$;

-- 0011's trigger, word for word, except a car already out of onboarding (listed and Available, or on a rental) keeps its
-- status at enrollment: only a car still in onboarding becomes ready to list (0070 makes that Available when listed).
create or replace function app.vehicle_onboarding_after_status() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  s vehicle_schedules;
  v_on date;
begin
  if new.status = old.status then return null; end if;
  select * into v from vehicles where id = new.vehicle_id;

  if new.status = 'on_fleet_policy' then
    update vehicles set on_fleet_policy = true, fleet_policy_added_on = app.local_date(new.on_fleet_policy_at)
     where id = v.id;
  elsif new.status = 'enrolled' then
    -- the date of the written confirmation is the Enrollment Date
    v_on := app.local_date(new.enrolled_confirmed_at);
    update vehicles set enrollment_date = v_on,
           status = case when status = 'onboarding' then 'ready_to_list'::vehicle_status else status end
     where id = v.id;
    select * into s from vehicle_schedules where vehicle_id = v.id and superseded_by is null;
    if s.id is not null then
      update vehicle_schedules set enrollment_date = v_on where id = s.id and enrollment_date is null;
    end if;
    -- open the fee terms that billing and the split read
    if not exists (select 1 from vehicle_fee_history h where h.vehicle_id = v.id) then
      if v.is_shareholder_owned then
        insert into vehicle_fee_history (vehicle_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from)
        values (v.id, 'shareholder', 0, 0, (app.settings(v_on)).shareholder_company_share_bps, v_on);
      elsif s.id is not null then
        insert into vehicle_fee_history (vehicle_id, vehicle_schedule_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from)
        values (v.id, s.id, 'signed_schedule', s.insurance_fee_cents, s.tracker_fee_cents, s.revenue_share_bps, v_on);
      end if;
    end if;
  elsif new.status in ('declined', 'withdrawn') then
    update vehicles set status = 'declined' where id = v.id and status = 'onboarding';
  end if;
  return null;
end $$;

-- The onboarding checklist: a car insured before its paperwork is finished keeps the agreements and the registry visit
-- open until they are really done (the status no longer says).
alter function app.onboarding_checklist(uuid) rename to onboarding_checklist_pre0077;
create or replace function app.onboarding_checklist(p_vehicle uuid)
returns table (code text, label text, sort_order integer, status text, waits_on text, next_action text, owner_action text, staff_action text)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  ob vehicle_onboardings;
  v_done boolean;
begin
  select * into v from vehicles where id = p_vehicle;
  select * into ob from vehicle_onboardings where vehicle_id = p_vehicle;
  for code, label, sort_order, status, waits_on, next_action, owner_action, staff_action in
    select * from app.onboarding_checklist_pre0077(p_vehicle) c loop
    if ob.insured_before_paperwork_from is not null and not (ob.checklist_marks ? code) then
      if code = 'signatures' then
        v_done := ob.insured_before_paperwork_from in ('documents_signed', 'upfront_paid', 'registry_booked', 'registered')
                  or (v.is_shareholder_owned is true)
                  or exists (select 1 from vehicle_schedules s where s.vehicle_id = v.id and s.superseded_by is null and s.signed_at is not null);
        status := case when v_done then 'done' else 'open' end;
        waits_on := case when v_done then null else 'owner' end;
        next_action := case when v_done then null else coalesce(owner_action, staff_action) end;
      elsif code = 'registry_visit' and v.management_mode <> 'turo_only' then
        v_done := ob.permit_filed_at is not null or ob.insured_before_paperwork_from = 'registered';
        status := case when v_done then 'done' else 'open' end;
        waits_on := case when v_done then null else 'carmacars' end;
        next_action := case when v_done then null else coalesce(staff_action, owner_action) end;
      end if;
    end if;
    return next;
  end loop;
end $$;

-- Insurer confirmed: one car on the fleet policy from a date (default today, never in the future). Moves the onboarding
-- to "on the fleet policy" then "enrolled" (the T22 email to the owner, the Enrollment Date, the fee terms), sets the
-- car's flag and date, closes the tasks that waited for it, and records who did it. An Admin or fleet.
-- p: {vehicle_id, on (date), note}. Already on the policy: returns already = true and changes nothing.
create or replace function app.confirm_fleet_policy(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(coalesce(p ->> 'vehicle_id', p ->> 'vehicle'), '')::uuid;
  v_on date := coalesce(nullif(p ->> 'on', '')::date, app.today());
  v_note text := nullif(left(btrim(coalesce(p ->> 'note', '')), 500), '');
  v vehicles;
  ob vehicle_onboardings;
  v_at timestamptz;
  v_from text;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')) then
    raise exception 'An Admin or fleet marks a car insured' using errcode = '42501';
  end if;
  select * into v from vehicles where id = v_vehicle for update;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  if v_on > app.today() then raise exception 'The insurer''s confirmation date cannot be in the future' using errcode = '22023'; end if;
  if v_on < app.today() - 366 then raise exception 'Check the date: it is more than a year ago' using errcode = '22023'; end if;
  if v.management_mode = 'turo_only' then raise exception 'A Turo-only car is not on the CarmaCars fleet policy' using errcode = '23514'; end if;
  if v.retired_at is not null or v.status in ('exited', 'total_loss', 'declined') then
    raise exception '% is no longer in the fleet', app.vehicle_name(v.id) using errcode = '23514';
  end if;
  select * into ob from vehicle_onboardings where vehicle_id = v.id for update;
  if ob.id is not null and ob.status in ('intake', 'declined', 'withdrawn') then
    raise exception 'Approve the owner''s application for % first (its terms are not set)', app.vehicle_name(v.id) using errcode = '23514';
  end if;
  if coalesce(v.on_fleet_policy, false) and (ob.id is null or ob.status in ('on_fleet_policy', 'enrolled')) then
    return jsonb_build_object('vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'already', true, 'on', v.fleet_policy_added_on);
  end if;
  v_at := case when v_on >= app.today() then now() else (v_on + time '12:00') at time zone 'America/Toronto' end;
  if ob.id is not null then
    v_from := ob.status::text;
    if ob.status <> 'on_fleet_policy' then
      update vehicle_onboardings
         set insured_before_paperwork_from = case when status in ('terms_set', 'documents_sent', 'documents_signed', 'upfront_paid', 'registry_booked', 'registered')
                                                  then status end,
             insurer_confirmed_by = p_by, insurer_confirmation_note = v_note, on_fleet_policy_at = v_at, status = 'on_fleet_policy'
       where id = ob.id;
    end if;
    update vehicle_onboardings set enrolled_confirmed_at = v_at, status = 'enrolled' where id = ob.id;
  else
    -- a car with no onboarding (CarmaCars-owned, a partner's): the flag, the date and the status
    update vehicles set on_fleet_policy = true, fleet_policy_added_on = v_on, enrollment_date = coalesce(enrollment_date, v_on),
           status = case when status = 'onboarding' then 'ready_to_list'::vehicle_status else status end
     where id = v.id;
  end if;
  update vehicles set on_fleet_policy = true, fleet_policy_added_on = v_on where id = v.id;
  -- what waited for it
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Insurer confirmed'
   where vehicle_id = v.id and task_type in ('live_rental_insurance', 'insurer_confirmation') and status in ('open', 'in_progress', 'waiting');
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Already on the site'
   where vehicle_id = v.id and task_type = 'list_vehicle' and status in ('open', 'in_progress', 'waiting')
     and exists (select 1 from vehicle_listings l where l.vehicle_id = v.id and l.status = 'published');
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'insurer_confirmed', 'vehicles', v.id::text,
          jsonb_build_object('on', v_on, 'note', v_note, 'onboarding_from', v_from, 'onboarding_id', ob.id));
  select * into v from vehicles where id = v.id;
  return jsonb_build_object('vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'already', false, 'on', v_on,
                            'enrollment_date', v.enrollment_date, 'status', v.status, 'owner_notified', ob.id is not null);
end $$;

-- Several cars on one insurer email. p: {vehicle_ids: [...], on, note}. Each car on its own: one that cannot be marked
-- is named with the reason and the others go through.
create or replace function app.confirm_fleet_policy_bulk(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id text;
  v_done jsonb := '[]'::jsonb;
  v_failed jsonb := '[]'::jsonb;
  r jsonb;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')) then
    raise exception 'An Admin or fleet marks a car insured' using errcode = '42501';
  end if;
  if jsonb_typeof(p -> 'vehicle_ids') <> 'array' or jsonb_array_length(p -> 'vehicle_ids') = 0 then
    raise exception 'Tick the cars the insurer confirmed' using errcode = '22023';
  end if;
  for v_id in select jsonb_array_elements_text(p -> 'vehicle_ids') loop
    begin
      r := app.confirm_fleet_policy(p_by, jsonb_build_object('vehicle_id', v_id, 'on', p ->> 'on', 'note', p ->> 'note'));
      v_done := v_done || jsonb_build_array(r);
    exception when others then
      v_failed := v_failed || jsonb_build_array(jsonb_build_object('vehicle_id', v_id, 'name', app.vehicle_name(v_id::uuid), 'error', sqlerrm));
    end;
  end loop;
  if jsonb_array_length(v_done) = 0 then
    raise exception '%', (select string_agg((f ->> 'name') || ': ' || (f ->> 'error'), '; ') from jsonb_array_elements(v_failed) f) using errcode = '23514';
  end if;
  return jsonb_build_object('done', v_done, 'failed', v_failed, 'count', jsonb_array_length(v_done));
end $$;

-- ================================================================ 2. the texts that named a screen that did not exist
-- 0070 told staff to "confirm it in the car's onboarding (Insurer confirmation, then the enrollment)". The button is
-- Insurer confirmed: on the car (Listing tab) and on Admin > Today.
alter function app.listing_checklist(uuid) rename to listing_checklist_pre0077;
create or replace function app.listing_checklist(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  g jsonb := app.listing_checklist_pre0077(p_vehicle);
begin
  return coalesce((select jsonb_agg(case when x ->> 'code' = 'insurance'
                                         then x || jsonb_build_object('action', 'Requests, offers and payment are fine; no handover until the insurer confirms it. When the insurer confirms the car in writing, press Insurer confirmed', 'act', 'insurer_confirm')
                                         else x end order by n)
                     from jsonb_array_elements(g) with ordinality e(x, n)), '[]'::jsonb);
end $$;

alter function app.listing_state(uuid, jsonb) rename to listing_state_pre0077;
create or replace function app.listing_state(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.listing_state_pre0077(p_by, p);
begin
  if x is null then return null; end if;
  return x || jsonb_build_object(
    'can_insure', (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')) and not coalesce((x ->> 'on_policy')::boolean, false),
    'handover_note', case when not coalesce((x ->> 'on_policy')::boolean, false)
                          then 'Not on the fleet insurance policy yet: you can send the offer and take payment, but the car cannot be handed over until the insurer confirms it. Press Insurer confirmed on the car (or on Admin > Today) when the insurer confirms it in writing.' end);
end $$;

create or replace function app.booking_handover_on_policy() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'on_rent' and old.status is distinct from 'on_rent' and not app.vehicle_on_policy(new.vehicle_id) then
    raise exception 'This car is not on the fleet insurance policy yet: it cannot be handed over. When the insurer confirms it in writing, press Insurer confirmed on the car (or on Admin > Today), or move the booking to another car'
      using errcode = '23514';
  end if;
  return new;
end $$;

-- ================================================================ 3. renter documents, reviewed from the booking
-- An Admin, or customer service, reviews the licence images, the selfie and the proof of coverage of a booking from the
-- booking itself: no review task is needed. Customer service sees a booking that is being arranged or under way, or one
-- with a document waiting; every opening is logged (data_access_log) as before.
create or replace function app.doc_review_can(p_by uuid, p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_by)
      or (app.user_va_has(p_by, 'cs') and exists (
            select 1 from bookings b where b.id = p_booking
               and (b.status in ('pending_payment', 'confirmed', 'on_rent')
                    or exists (select 1 from verification_uploads u where u.booking_id = b.id and u.status = 'submitted'))))
$$;

create or replace function app.doc_review_read(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  select * into b from bookings where id::text = coalesce(p ->> 'booking', p ->> 'booking_id') or booking_number = coalesce(p ->> 'booking', p ->> 'booking_number');
  if b.id is null then return null; end if;
  if not app.doc_review_can(p_by, b.id) then
    raise exception 'Only an Admin or customer service reviews identity and coverage documents' using errcode = '42501';
  end if;
  insert into data_access_log (user_id, action, renter_id, reason, results)
  values (p_by, 'open', b.renter_id, 'identity and coverage review, booking ' || b.booking_number,
          (select count(*) from verification_uploads u where u.booking_id = b.id and u.status = 'submitted'));
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at,
    'return_at', b.return_at, 'coverage_option', b.coverage_option, 'renter_name', (select r.legal_name from renters r where r.id = b.renter_id),
    'vehicle_name', app.vehicle_name(b.vehicle_id), 'readiness', app.booking_readiness(b.id),
    'drivers', coalesce((select jsonb_agg(jsonb_build_object('driver_id', d.driver_id, 'full_name', d.full_name, 'role', d.role, 'date_of_birth', d.date_of_birth,
                           'licence_number', d.licence_number, 'licence_class', d.licence_class, 'licence_expiry', d.licence_expiry, 'verified_on', d.identity_verified_on)
                           order by d.role desc, d.full_name) from booking_drivers d where d.booking_id = b.id), '[]'::jsonb),
    'uploads', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'kind', u.kind, 'driver_id', u.driver_id, 'status', u.status, 'uploaded_at', u.uploaded_at,
                           'reject_reason', u.reject_reason, 'bucket', doc.storage_bucket, 'path', doc.storage_path, 'mime_type', doc.mime_type) order by u.uploaded_at)
                           from verification_uploads u join documents doc on doc.id = u.document_id
                          where u.booking_id = b.id and u.kind <> 'coverage_proof' and u.status in ('submitted', 'approved', 'rejected') and doc.purged_at is null), '[]'::jsonb),
    'coverage', app.coverage_review_facts(b.id),
    'waiting', (select count(*) from verification_uploads u where u.booking_id = b.id and u.status = 'submitted'));
end $$;

-- p: {upload, approve, reason}
create or replace function app.doc_review_upload(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  u verification_uploads;
begin
  select * into u from verification_uploads where id = nullif(p ->> 'upload', '')::uuid;
  if u.id is null then raise exception 'Document not found' using errcode = 'P0002'; end if;
  if not app.doc_review_can(p_by, u.booking_id) then
    raise exception 'Only an Admin or customer service reviews identity and coverage documents' using errcode = '42501';
  end if;
  return app.review_verification_upload(u.id, p_by, (p ->> 'approve')::boolean, nullif(btrim(coalesce(p ->> 'reason', '')), ''));
end $$;

-- p: {proof, approve, reason, checks}
create or replace function app.doc_review_coverage(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  cp coverage_proofs;
begin
  select * into cp from coverage_proofs where id = nullif(p ->> 'proof', '')::uuid;
  if cp.id is null then raise exception 'Proof not found' using errcode = 'P0002'; end if;
  if not app.doc_review_can(p_by, cp.booking_id) then
    raise exception 'Only an Admin or customer service reviews identity and coverage documents' using errcode = '42501';
  end if;
  return app.review_coverage_proof(cp.id, p_by, (p ->> 'approve')::boolean, nullif(btrim(coalesce(p ->> 'reason', '')), ''), p -> 'checks');
end $$;

-- p: {booking, ref}
create or replace function app.doc_review_plan(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_b uuid;
begin
  select b.id into v_b from bookings b where b.id::text = p ->> 'booking' or b.booking_number = p ->> 'booking';
  if v_b is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if not app.doc_review_can(p_by, v_b) then
    raise exception 'Only an Admin or customer service confirms the Protection Plan' using errcode = '42501';
  end if;
  return app.confirm_protection_plan(v_b, p_by, p ->> 'ref');
end $$;

-- The assistants' identity screen (/va/verify) and its actions: no review task needed any more (0031 and 0071 asked for
-- one); the same rule as the Admin's booking page.
alter function app.va_read(uuid, text, jsonb) rename to va_read_pre0077;
create or replace function app.va_read(p_user uuid, p_what text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_what = 'verification' and app.va_fn(p_user) = 'cs' then
    return app.doc_review_read(p_user, coalesce(p, '{}'::jsonb));
  end if;
  return app.va_read_pre0077(p_user, p_what, p);
end $$;

alter function app.va_do(uuid, text, jsonb) rename to va_do_pre0077;
create or replace function app.va_do(p_user uuid, p_action text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if p_action in ('verify_upload', 'coverage_review', 'protection_plan_confirm') then
    if app.va_fn(p_user) <> 'cs' then raise exception 'Identity and coverage documents are reviewed by customer service' using errcode = '42501'; end if;
    if p_action = 'verify_upload' then perform app.doc_review_upload(p_user, p_); return jsonb_build_object('ok', true); end if;
    if p_action = 'coverage_review' then return app.doc_review_coverage(p_user, p_); end if;
    return app.doc_review_plan(p_user, p_);
  end if;
  return app.va_do_pre0077(p_user, p_action, p);
end $$;

-- ================================================================ 4. who is really on staff
-- The live verification's accounts (verify-...@carmacars.ca, and the Admin test addresses of 0054) are not real staff.
create or replace function app.staff_is_test(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select lower(u.email) like 'verify-%@carmacars.ca'
                       or lower(u.email) = any (select lower(x) from site_settings s, unnest(s.admin_test_emails) x where s.singleton)
                     from users u where u.id = p_user), false)
$$;

-- Does a real, active assistant hold this function (as their own or one they cover)?
create or replace function app.va_function_staffed(p_fn text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from staff_profiles sp join users u on u.id = sp.user_id join user_roles r on r.user_id = u.id and r.role = 'va'
                  where sp.staff_type = 'va' and sp.is_active and u.status = 'active' and not app.staff_is_test(u.id)
                    and (sp.va_function::text = p_fn or p_fn = any (sp.cover_functions::text[])))
$$;

-- ================================================================ 5. the guided To do: one prompt per piece of work
-- Each prompt: {key, kind, priority (1 now, 2 today, 3 when you can), title (what to do, one line), why (one line),
-- since, and what its pop-up needs}. A prompt disappears when its work is done: every one is computed from the records.
-- Kinds: insurer, insurer_bulk, publish, documents, chat, requests, changes, applications, invoice_payment, invoice_draft,
-- paper, forms, plates, photos, task (an Admin task, or an assistant task while no real assistant holds the function).
create or replace function app.todo_prompts(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_today date := app.today();
  v_out jsonb := '[]'::jsonb;
  v_ins jsonb;
  v_staffed jsonb;
begin
  if not app.user_is_admin(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  v_staffed := jsonb_build_object('cs', app.va_function_staffed('cs'), 'sales', app.va_function_staffed('sales'),
                                  'finance', app.va_function_staffed('finance'), 'fleet', app.va_function_staffed('fleet'));

  -- cars waiting for the insurer's confirmation
  select coalesce(jsonb_agg(x order by (x ->> 'priority')::int, x ->> 'since'), '[]'::jsonb) into v_ins from (
    select jsonb_build_object('key', 'insurer:' || v.id, 'kind', 'insurer', 'vehicle_id', v.id, 'name', app.vehicle_name(v.id),
             'priority', case when nb.status = 'on_rent' or nb.pickup_at < now() + interval '3 days' then 1 else 2 end,
             'since', coalesce(ob.terms_set_at, ob.created_at, v.created_at),
             'title', format('Insurer has not confirmed %s: mark it insured', app.vehicle_name(v.id)),
             'why', case when nb.status = 'on_rent' then format('It is out on rental %s without confirmed insurance.', nb.booking_number)
                         when nb.id is not null then format('Booking %s picks it up %s, and it cannot be handed over until the insurer confirms it.', nb.booking_number, app.fmt_at(nb.pickup_at))
                         else 'It cannot be handed over to a renter until it is on the fleet policy. Press this once the insurer confirms it in writing.' end,
             'booking_number', nb.booking_number, 'plate', v.plate, 'onboarding_status', ob.status) x
      from vehicles v
      left join vehicle_onboardings ob on ob.vehicle_id = v.id
      left join lateral (select b.id, b.booking_number, b.pickup_at, b.status from bookings b
                          where b.vehicle_id = v.id and b.status in ('pending_payment', 'confirmed', 'on_rent')
                          order by (b.status = 'on_rent') desc, b.pickup_at limit 1) nb on true
     where v.supply_type = 'program_owner' and not coalesce(v.is_sample, false) and v.retired_at is null
       and v.management_mode <> 'turo_only' and v.status not in ('exited', 'total_loss', 'declined')
       and not coalesce(v.on_fleet_policy, false)
       and (ob.id is null and v.status = 'onboarding' or ob.status in ('terms_set', 'documents_sent', 'documents_signed', 'upfront_paid', 'registry_booked', 'registered', 'tracker_installed'))) s;
  if jsonb_array_length(v_ins) >= 2 then
    v_out := v_out || jsonb_build_array(jsonb_build_object('key', 'insurer_bulk', 'kind', 'insurer_bulk',
      'priority', (select min((x ->> 'priority')::int) from jsonb_array_elements(v_ins) x), 'since', (select min(x ->> 'since') from jsonb_array_elements(v_ins) x),
      'title', format('%s cars wait for the insurer: mark the ones it confirmed insured, all at once', jsonb_array_length(v_ins)),
      'why', 'One insurer email often confirms several cars. None of them can be handed over until it is on the fleet policy.',
      'cars', (select jsonb_agg(jsonb_build_object('vehicle_id', x -> 'vehicle_id', 'name', x -> 'name', 'plate', x -> 'plate')) from jsonb_array_elements(v_ins) x)));
  end if;
  v_out := v_out || v_ins;

  -- real cars that are not on the site and need only their rates (or nothing) to go on it
  v_out := v_out || coalesce((select jsonb_agg(jsonb_build_object('key', 'publish:' || v.id, 'kind', 'publish', 'vehicle_id', v.id, 'name', app.vehicle_name(v.id),
             'priority', 2, 'since', v.created_at,
             'title', format('%s is not on the site: check its rates and publish it', app.vehicle_name(v.id)),
             'why', case when rc.id is null then 'Renters cannot find or book it. It has no rates yet: the suggested daily rate is filled in.'
                         else 'Renters cannot find or book it until it is published.' end,
             'suggested', app.listing_default_daily(v.id),
             'rates', case when rc.id is not null then jsonb_build_object('daily', rc.daily_rate_cents, 'weekend', rc.weekend_rate_cents,
                                                                         'weekly', rc.weekly_rate_cents, 'monthly', rc.monthly_rate_cents) end) order by v.created_at)
      from vehicles v
      left join vehicle_listings l on l.vehicle_id = v.id
      left join lateral (select * from rate_cards r where r.vehicle_id = v.id and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now()) limit 1) rc on true
     where not coalesce(v.is_sample, false) and v.retired_at is null and v.management_mode <> 'turo_only' and v.bookings_enabled
       and v.status in ('onboarding', 'ready_to_list', 'available', 'cleaning')
       and not exists (select 1 from public_vehicle_listings p where p.vehicle_id = v.id)
       and coalesce(l.status::text, 'draft') not in ('paused', 'unpublished', 'published')
       and not (l.publish_at is not null and l.publish_at > now())
       and not exists (select 1 from jsonb_array_elements(app.listing_basics_missing(v.id)) m where m ->> 'code' <> 'rates')
       and not app.listing_waits_for_decision(v.id)), '[]'::jsonb);

  -- renter documents waiting for review
  v_out := v_out || coalesce((select jsonb_agg(jsonb_build_object('key', 'documents:' || b.id, 'kind', 'documents', 'booking_number', b.booking_number,
             'priority', case when b.pickup_at < now() + interval '2 days' then 1 else 2 end,
             'since', coalesce((select min(u.uploaded_at) from verification_uploads u where u.booking_id = b.id and u.status = 'submitted'), b.confirmed_at, b.created_at),
             'title', format('Check %s''s documents for booking %s', r.legal_name, b.booking_number),
             'why', format('The car is not handed over until the licence and the proof of coverage are approved. Pickup %s.', app.fmt_at(b.pickup_at))) order by b.pickup_at)
      from bookings b join renters r on r.id = b.renter_id
     where b.status in ('pending_payment', 'confirmed', 'on_rent')
       and (exists (select 1 from verification_uploads u where u.booking_id = b.id and u.status = 'submitted')
            or (b.coverage_option = 3 and b.coverage_confirmed_at is null and b.status = 'confirmed'
                and exists (select 1 from booking_line_items li where li.booking_id = b.id and li.charge_type = 'coverage_sold' and li.voided_at is null)))), '[]'::jsonb);

  -- visitors waiting for a person in live chat
  v_out := v_out || coalesce((select jsonb_agg(jsonb_build_object('key', 'chat:' || c.id, 'kind', 'chat', 'chat_id', c.id, 'priority', 1,
             'since', coalesce(c.human_requested_at, c.last_message_at),
             'title', format('%s asked for a person in live chat %s: reply', coalesce(nullif(btrim(c.name), ''), 'A visitor'), c.number),
             'why', format('Waiting since %s%s.', app.fmt_at(coalesce(c.human_requested_at, c.last_message_at)),
                           case when nullif(btrim(c.human_reason), '') is not null then ': ' || left(c.human_reason, 120) else '' end)) order by c.human_requested_at)
      from chat_conversations c where c.status = 'waiting'), '[]'::jsonb);

  -- booking requests waiting for an offer
  v_out := v_out || coalesce((select jsonb_agg(jsonb_build_object('key', 'request:' || b.id, 'kind', 'requests', 'booking_number', b.booking_number, 'priority', 1,
             'since', b.created_at,
             'title', format('Answer %s''s request for %s, %s to %s', r.legal_name, app.vehicle_name(b.vehicle_id), app.fmt_at(b.pickup_at), app.fmt_at(b.return_at)),
             'why', format('Renters are promised an answer %s. Send the offer or decline it.', coalesce((select s.reply_wording from site_settings s where s.singleton), 'within 2 hours'))) order by b.created_at)
      from bookings b join renters r on r.id = b.renter_id
     where b.status = 'requested' and b.awaiting_renter_since is null), '[]'::jsonb);

  -- changes renters asked for
  v_out := v_out || coalesce((select jsonb_agg(jsonb_build_object('key', 'change:' || c.id, 'kind', 'changes', 'request_id', c.id, 'booking_number', b.booking_number, 'priority', 1,
             'since', c.created_at,
             'title', format('%s asked to change booking %s: approve or decline', r.legal_name, b.booking_number),
             'why', coalesce(nullif(left(btrim(c.note), 160), ''), 'The renter waits for your answer.')
                    || case when c.total_difference_cents is not null and c.total_difference_cents <> 0 then format(' Difference %s.', app.rc_money(c.total_difference_cents, true)) else '' end) order by c.created_at)
      from booking_change_requests c join bookings b on b.id = c.booking_id join renters r on r.id = b.renter_id
     where c.status = 'requested' and c.requested_by_role = 'renter'), '[]'::jsonb);

  -- owner applications to decide
  v_out := v_out || coalesce((select jsonb_agg(jsonb_build_object('key', 'application:' || a.id, 'kind', 'applications', 'application_id', a.id, 'priority', 2,
             'since', a.created_at,
             'title', format('Decide %s''s owner application (%s)', o.legal_name,
                             coalesce((select string_agg(app.vehicle_name(ob.vehicle_id), ', ') from vehicle_onboardings ob where ob.application_id = a.id), a.vehicle_count || ' cars')),
             'why', 'Set the terms and approve it, or decline it. Its cars are not published by themselves until you decide.') order by a.created_at)
      from owner_applications a join owners o on o.id = a.owner_id
     where a.status = 'new' and not coalesce(o.is_test, false)), '[]'::jsonb);

  -- owner invoices waiting for payment (paid another way: e-Transfer, cash, cheque)
  v_out := v_out || coalesce((select jsonb_agg(jsonb_build_object('key', 'invoice:' || i.id, 'kind', 'invoice_payment', 'invoice_id', i.id, 'invoice_number', i.invoice_number,
             'balance_cents', i.balance_cents, 'owner', o.legal_name, 'priority', case when i.status in ('failed', 'in_arrears') then 1 else 2 end,
             'since', coalesce(i.issued_at, i.created_at),
             'title', format('%s from %s: %s waiting for payment. Record it if paid by e-Transfer, cash or cheque', i.invoice_number, o.legal_name, app.rc_money(i.balance_cents, true)),
             'why', case when i.status = 'failed' then 'The automatic debit failed: collect it another way, or the debit retries by itself.'
                         when i.status = 'in_arrears' then 'It is in arrears.'
                         else format('Issued %s. A card or debit payment records itself; anything else is recorded here.', app.fmt_day(app.local_date(i.issued_at))) end) order by i.issued_at)
      from owner_invoices i join owners o on o.id = i.owner_id
     where i.status in ('issued', 'failed', 'in_arrears') and i.balance_cents > 0 and not coalesce(o.is_test, false)
       and (i.kind = 'upfront' or i.status in ('failed', 'in_arrears') or (i.due_on is not null and i.due_on < v_today))), '[]'::jsonb);

  -- first and last month drafts to decide
  v_out := v_out || coalesce((select jsonb_agg(jsonb_build_object('key', 'draft:' || i.id, 'kind', 'invoice_draft', 'invoice_number', i.invoice_number, 'priority', 3,
             'since', i.created_at,
             'title', format('Draft %s for %s (%s): send it or void it', i.invoice_number, o.legal_name, app.rc_money(i.total_cents, true)),
             'why', 'A draft bills nobody until it is sent. Void it if it is not needed.') order by i.created_at)
      from owner_invoices i join owners o on o.id = i.owner_id
     where i.status = 'draft' and i.kind = 'upfront' and not coalesce(o.is_test, false)), '[]'::jsonb);

  -- owners whose agreements were sent two days ago or more and are not signed: a signature on paper is recorded here
  v_out := v_out || coalesce((select jsonb_agg(jsonb_build_object('key', 'paper:' || o.id, 'kind', 'paper', 'owner_id', o.id, 'owner', o.legal_name, 'priority', 3,
             'since', x.sent_at, 'docs', x.docs,
             'title', format('%s has not signed %s document%s sent %s: record a paper signature if they signed on paper', o.legal_name,
                             jsonb_array_length(x.docs), case when jsonb_array_length(x.docs) = 1 then '' else 's' end, app.fmt_day(app.local_date(x.sent_at))),
             'why', 'Their cars stay in onboarding until the agreements are signed. If they will sign online, nothing to do yet.') order by x.sent_at)
      from owners o
      cross join lateral (select min(ob.documents_sent_at) sent_at,
                                 (select coalesce(jsonb_agg(it), '[]'::jsonb) from jsonb_array_elements(app.owner_signables(o.id)) it
                                   where it ->> 'group' = 'sign' and it ->> 'status' = 'open' and coalesce(it ->> 'detail', '') <> 'Not prepared yet (terms not set)') docs
                            from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
                           where v.owner_id = o.id and ob.status = 'documents_sent') x
     where not coalesce(o.is_test, false) and x.sent_at is not null and x.sent_at < now() - interval '2 days' and jsonb_array_length(x.docs) > 0), '[]'::jsonb);

  -- the official ServiceOntario forms not checked yet
  v_out := v_out || coalesce((select jsonb_agg(jsonb_build_object('key', 'form:' || t.id, 'kind', 'forms', 'template_id', t.id, 'form_code', t.form_code, 'priority', 3,
             'since', t.created_at,
             'title', format('Check the official form %s and use it for owners', coalesce(nullif(t.title, ''), t.form_code)),
             'why', 'Until it is checked, owners get a plain data sheet instead of the official ServiceOntario form.') order by t.form_code)
      from pdf_templates t where t.is_current and not t.verified and t.file_key is not null), '[]'::jsonb);

  -- real cars with photos held back for the plate check
  v_out := v_out || coalesce((select jsonb_agg(jsonb_build_object('key', 'plates:' || v.id, 'kind', 'plates', 'vehicle_id', v.id, 'priority', 3, 'since', x.first_at,
             'title', format('Check the plate on %s photo%s of %s', x.n, case when x.n = 1 then '' else 's' end, app.vehicle_name(v.id)),
             'why', 'Those photos stay off the site until the plate is covered or marked not visible.') order by x.first_at)
      from vehicles v
      join lateral (select count(*) n, min(ph.created_at) first_at from vehicle_photos ph
                     where ph.vehicle_id = v.id and ph.replaced_at is null and ph.status = 'approved' and ph.processed_path is not null and ph.plate_status = 'unchecked') x on x.n > 0
     where not coalesce(v.is_sample, false) and v.retired_at is null and v.status <> 'exited'), '[]'::jsonb);

  -- real cars on the site with sample photos
  v_out := v_out || coalesce((select jsonb_agg(jsonb_build_object('key', 'photos:' || u.vehicle_id, 'kind', 'photos', 'vehicle_id', u.vehicle_id, 'priority', 3, 'since', null,
             'title', format('Add real photos of %s', app.vehicle_name(u.vehicle_id)),
             'why', 'It shows sample photos on the site; approved real photos replace them at once.'))
      from app.vehicles_using_sample_photos() u join vehicles v on v.id = u.vehicle_id
     where u.listing_status in ('published', 'paused') and not coalesce(v.is_sample, false)), '[]'::jsonb);

  -- tasks: the Admin's, and an assistant queue's while no real assistant holds that function (the prompts above already
  -- cover the kinds left out here)
  v_out := v_out || coalesce((select jsonb_agg(jsonb_build_object('key', 'task:' || t.id, 'kind', 'task', 'task_id', t.id, 'task_type', t.task_type, 'queue', t.queue,
             'priority', case t.priority when 'urgent' then 1 when 'high' then 1 when 'normal' then 2 else 3 end,
             'since', t.created_at, 'due_at', t.due_at, 'title', t.title,
             'why', coalesce(nullif(btrim(t.detail), ''), nullif(btrim(r.description), ''), r.completion_rule,
                             case when t.queue <> 'admin' then format('An assistant task (%s): no assistant holds that function yet, so it comes to you.', t.queue) end),
             'booking_number', b.booking_number, 'vehicle_id', t.vehicle_id, 'name', case when t.vehicle_id is not null then app.vehicle_name(t.vehicle_id) end,
             'owner_id', t.owner_id, 'related_table', t.related_table, 'related_id', t.related_id,
             'invoice_number', case when t.related_table = 'owner_invoices' then (select i.invoice_number from owner_invoices i where i.id = t.related_id) end,
             'from_queue', t.queue <> 'admin') order by t.due_at nulls last, t.created_at)
      from tasks t left join task_rules r on r.task_type = t.task_type left join bookings b on b.id = t.booking_id
     where t.status in ('open', 'in_progress')
       and (t.queue = 'admin' or (t.queue in ('cs', 'sales', 'finance', 'fleet') and not coalesce((v_staffed ->> t.queue)::boolean, false)))
       and t.task_type not in ('collect_upfront', 'debit_failed', 'arrears', 'live_chat_waiting', 'verify_renter', 'chase_verification', 'opening_checks',
                               'closing_checks', 'live_rental_insurance', 'insurer_confirmation', 'list_vehicle', 'owner_intake', 'booking_request',
                               'review_listing', 'match_toll', 'fleet_minimum')), '[]'::jsonb);
  -- the fleet minimum: only while it is still true
  v_out := v_out || coalesce((select jsonb_agg(jsonb_build_object('key', 'task:' || t.id, 'kind', 'task', 'task_id', t.id, 'task_type', t.task_type, 'queue', t.queue,
             'priority', 1, 'since', t.created_at, 'title', t.title, 'why', t.detail, 'from_queue', false))
      from tasks t where t.task_type = 'fleet_minimum' and t.status in ('open', 'in_progress') and not app.fleet_minimum_ok()), '[]'::jsonb);

  return jsonb_build_object('prompts', (select coalesce(jsonb_agg(x order by (x ->> 'priority')::int, x ->> 'since' nulls last), '[]'::jsonb) from jsonb_array_elements(v_out) x),
                            'staffed', v_staffed);
end $$;

-- The franchise minimum (0015's Monday recount): still below the warning level today?
create or replace function app.fleet_minimum_ok() returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.fleet_count(app.today(), true) > (app.settings()).fleet_warning_count
$$;

-- Admin To do (0054 to 0063) with the prompts; the plate count leaves out the sample cars (their photos are never
-- checked, 0070) and the sample photo count points at the cars, not the photo library.
alter function app.admin_todo(uuid) rename to admin_todo_pre0077;
create or replace function app.admin_todo(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.admin_todo_pre0077(p_admin);
  pr jsonb := app.todo_prompts(p_admin);
begin
  v := jsonb_set(v, '{items}', (select coalesce(jsonb_agg(case
      when i ->> 'key' = 'plates' then i || jsonb_build_object('count', (select count(distinct ph.vehicle_id) from vehicle_photos ph join vehicles v on v.id = ph.vehicle_id
                                    where ph.replaced_at is null and ph.status = 'approved' and ph.processed_path is not null and ph.plate_status = 'unchecked'
                                      and v.retired_at is null and v.status <> 'exited' and not coalesce(v.is_sample, false)))
      when i ->> 'key' = 'samples' then i || jsonb_build_object('label', 'Real cars showing sample photos', 'button', 'Add real photos',
                                    'href', coalesce((select '/admin/vehicles/' || u.vehicle_id || '?tab=listing' from app.vehicles_using_sample_photos() u join vehicles v on v.id = u.vehicle_id
                                                       where u.listing_status in ('published', 'paused') and not coalesce(v.is_sample, false) limit 1), '/admin/vehicles'),
                                    'count', (select count(*) from app.vehicles_using_sample_photos() u join vehicles v on v.id = u.vehicle_id
                                               where u.listing_status in ('published', 'paused') and not coalesce(v.is_sample, false)))
      else i end order by n), '[]'::jsonb) from jsonb_array_elements(v -> 'items') with ordinality x(i, n)));
  return v || pr;
end $$;

-- ================================================================ 6. tasks close by rule
-- An upfront invoice voided closes its collection task (0020 raised it; 0029 closed it only on payment).
create or replace function app.owner_invoice_tasks_close() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status is not distinct from old.status then return null; end if;
  if new.status in ('void', 'paid') then
    update tasks set status = case when new.status = 'paid' then 'done' else 'cancelled' end,
           completed_at = case when new.status = 'paid' then now() else completed_at end,
           completion_note = coalesce(completion_note, case when new.status = 'paid' then 'The invoice is paid' else 'The invoice was voided' end)
     where related_id = new.id and task_type in ('collect_upfront', 'debit_failed', 'arrears') and status in ('open', 'in_progress', 'waiting');
  end if;
  return null;
end $$;
drop trigger if exists owner_invoices_tasks_close on owner_invoices;
create trigger owner_invoices_tasks_close after update of status on owner_invoices
  for each row execute function app.owner_invoice_tasks_close();

-- The sweep (hourly, and once now): every rule above for tasks already open, plus the ones whose record changed without
-- passing through a function that closes them. Returns what it closed, by kind.
create or replace function app.job_task_hygiene(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_today date := app.local_date(p_now);
  n_inv integer; n_checks integer; n_chat integer; n_fleet integer; n_list integer; n_ins integer;
begin
  update tasks t set status = case when i.status = 'paid' then 'done' else 'cancelled' end,
         completed_at = case when i.status = 'paid' then p_now else t.completed_at end,
         completion_note = coalesce(t.completion_note, case when i.status = 'paid' then 'The invoice is paid' else 'The invoice was voided' end)
    from owner_invoices i
   where i.id = t.related_id and t.task_type in ('collect_upfront', 'debit_failed', 'arrears') and t.status in ('open', 'in_progress', 'waiting')
     and i.status in ('void', 'paid');
  get diagnostics n_inv = row_count;
  -- a day's opening or closing checks are for that day only
  update tasks set status = 'cancelled', completion_note = coalesce(completion_note, 'The day passed')
   where task_type in ('opening_checks', 'closing_checks') and status in ('open', 'in_progress', 'waiting')
     and app.local_date(coalesce(due_at, created_at)) < v_today;
  get diagnostics n_checks = row_count;
  update tasks t set status = 'done', completed_at = p_now, completion_note = coalesce(t.completion_note, case when c.status = 'closed' then 'The chat was closed' else 'Answered in Live chat' end)
    from chat_conversations c
   where c.id = t.related_id and t.task_type = 'live_chat_waiting' and t.status in ('open', 'in_progress', 'waiting')
     and (c.status = 'closed' or c.first_human_reply_at is not null or c.status = 'ai');
  get diagnostics n_chat = row_count;
  if app.fleet_minimum_ok() then
    update tasks set status = 'done', completed_at = p_now, completion_note = coalesce(completion_note, format('The fleet count is back above the warning level (%s on the policy)', app.fleet_count(v_today, true)))
     where task_type = 'fleet_minimum' and status in ('open', 'in_progress', 'waiting');
    get diagnostics n_fleet = row_count;
  else
    n_fleet := 0;
  end if;
  update tasks t set status = 'done', completed_at = p_now, completion_note = coalesce(t.completion_note, 'On the site')
   where t.task_type = 'list_vehicle' and t.status in ('open', 'in_progress', 'waiting')
     and exists (select 1 from vehicle_listings l where l.vehicle_id = t.vehicle_id and l.status = 'published');
  get diagnostics n_list = row_count;
  update tasks t set status = 'done', completed_at = p_now, completion_note = coalesce(t.completion_note, 'Insurer confirmed')
   where t.task_type in ('live_rental_insurance', 'insurer_confirmation') and t.status in ('open', 'in_progress', 'waiting')
     and app.vehicle_on_policy(t.vehicle_id);
  get diagnostics n_ins = row_count;
  return jsonb_build_object('invoices', n_inv, 'checks', n_checks, 'chats', n_chat, 'fleet_minimum', n_fleet, 'listed', n_list, 'insured', n_ins);
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-task-hygiene', '41 * * * *', 'select app.job_task_hygiene()');
  end if;
end $$;

-- ================================================================ 7. staff emails while nobody real holds a function
-- A staff email or digest line for customer service, sales, finance or fleet also goes to the Admin while no real,
-- active assistant holds that function (the live verification's accounts do not count), and its link opens Admin > Today.
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre0077;
create or replace function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
declare
  r record;
  v_fallback boolean := false;
  v_immediate boolean := false;
  v_admins uuid[] := '{}';
begin
  for r in select * from app.notification_recipients_pre0077(p_event, p_c) x loop
    if r.audience like 'staff_va_%' and not app.va_function_staffed(substr(r.audience, 10)) then
      v_fallback := true;
      v_immediate := v_immediate or coalesce(r.immediate, false);
    end if;
    if r.audience = 'staff_admin' and r.user_id is not null then v_admins := v_admins || r.user_id; end if;
    audience := r.audience; user_id := r.user_id; email := r.email; name := r.name; renter_id := r.renter_id; owner_id := r.owner_id; immediate := r.immediate;
    return next;
  end loop;
  -- also when the function has nobody at all (the original returns no row then)
  if not v_fallback and not exists (select 1 from app.notification_recipients_pre0077(p_event, p_c) x where x.audience like 'staff_va_%') then
    v_fallback := (p_c.audience like 'staff_va_%' and not app.va_function_staffed(substr(p_c.audience, 10)))
               or exists (select 1 from unnest(coalesce(p_c.also_sent_to, '{}')) a where a like 'staff_va_%' and not app.va_function_staffed(substr(a, 10)));
    v_immediate := v_fallback and not p_c.is_digest;
  end if;
  if v_fallback then
    return query
      select 'staff_admin'::text, u.id, u.email, u.full_name, null::uuid, null::uuid, v_immediate
        from users u
       where u.status = 'active' and not (u.id = any (v_admins)) and not app.staff_is_test(u.id)
         and exists (select 1 from user_roles x where x.user_id = u.id and x.role = 'admin')
         and lower(u.email) = any (select lower(e) from site_settings s, unnest(s.admin_allowed_emails) e where s.singleton);
  end if;
end $$;

-- ... and its link opens Admin > Today (the assistant screen it names is not the Admin's)
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0077;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0077(p_code, p_event, p_to);
  c notification_catalogue;
begin
  if p_to ->> 'audience' = 'staff_admin' then
    select * into c from notification_catalogue where code = p_code;
    if c.audience like 'staff_va_%' and coalesce(c.link_path, '') not like '/admin%' then
      x := x || jsonb_build_object('_url', (app.settings()).notify_base_url || '/admin');
    end if;
  end if;
  return x;
end $$;

-- ================================================================ 8. the pop-ups' own actions
-- Rates and Publish now in one step (the To do's "not on the site" prompt). p: {vehicle_id, daily, weekend, weekly,
-- monthly} in cents; the kilometres, deposit and fees stay as on the current card (the defaults for a car with none).
-- Rates unchanged: only Publish now. An Admin, customer service or fleet.
create or replace function app.todo_publish(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(coalesce(p ->> 'vehicle_id', p ->> 'vehicle'), '')::uuid;
  v vehicles;
  cur rate_cards;
  v_rates jsonb;
  v_set boolean := false;
  v_out jsonb;
  k text;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then
    raise exception 'An Admin, customer service or fleet publishes a car' using errcode = '42501';
  end if;
  select * into v from vehicles where id = v_vehicle;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  select * into cur from rate_cards r where r.vehicle_id = v.id and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now());
  if nullif(btrim(coalesce(p ->> 'daily', '')), '') is not null then
    foreach k in array array['daily', 'weekend', 'weekly', 'monthly'] loop
      if nullif(btrim(coalesce(p ->> k, '')), '') is distinct from (case k when 'daily' then cur.daily_rate_cents when 'weekend' then cur.weekend_rate_cents
                                                                         when 'weekly' then cur.weekly_rate_cents else cur.monthly_rate_cents end)::text then
        v_set := true;
      end if;
    end loop;
    if cur.id is null then v_set := true; end if;
    if v_set then
      v_rates := jsonb_build_object('vehicle', v.id, 'daily', p ->> 'daily', 'weekend', p ->> 'weekend', 'weekly', p ->> 'weekly', 'monthly', p ->> 'monthly');
      if cur.id is not null then
        v_rates := v_rates || jsonb_strip_nulls(jsonb_build_object('deposit', cur.deposit_cents::text, 'delivery', cur.delivery_fee_cents::text, 'pickup', cur.pickup_fee_cents::text));
        if not coalesce(cur.km_uses_defaults, false) then
          v_rates := v_rates || jsonb_build_object('km_mode', 'custom', 'km_per_day', cur.km_allowance_per_day::text, 'overage', cur.overage_cents_per_km::text);
        end if;
      end if;
      perform app.rate_card_save_pre0070(p_by, v_rates);
    end if;
  end if;
  v_out := app.listing_publish_now(p_by, jsonb_build_object('vehicle_id', v.id));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'todo_publish', 'vehicles', v.id::text, jsonb_build_object('rates_set', v_set, 'rates', v_rates, 'path', v_out ->> 'path'));
  return v_out || jsonb_build_object('rates_set', v_set);
end $$;

-- "Checked: use for owners" for one official form, with the mapping it already has (Admin > Settings > Forms has the
-- full editor). p: {template}
create or replace function app.form_verify(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  t pdf_templates;
begin
  perform app.assert_admin(p_by);
  select * into t from pdf_templates where id = nullif(p ->> 'template', '')::uuid;
  if t.id is null then raise exception 'That form is not there' using errcode = 'P0002'; end if;
  return app.form_template_map(p_by, jsonb_build_object('template', t.id, 'field_map', t.field_map, 'verify', true));
end $$;

-- ================================================================ 9. the doors
create or replace function app.ops77(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'todo_prompts' then return app.todo_prompts(p_user);
  when 'doc_review' then return app.doc_review_read(p_user, p);
  when 'doc_review_upload' then return app.doc_review_upload(p_user, p);
  when 'doc_review_coverage' then return app.doc_review_coverage(p_user, p);
  when 'doc_review_plan' then return app.doc_review_plan(p_user, p);
  when 'insurer_confirm' then return app.confirm_fleet_policy(p_user, p);
  when 'insurer_confirm_bulk' then return app.confirm_fleet_policy_bulk(p_user, p);
  when 'todo_publish' then return app.todo_publish(p_user, p);
  when 'form_verify' then return app.form_verify(p_user, p);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0077;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call in ('ops_read', 'admin_read') and p_name in ('todo_prompts', 'doc_review'))
     or (p_call in ('ops_do', 'admin_do') and p_name in ('doc_review_upload', 'doc_review_coverage', 'doc_review_plan', 'insurer_confirm',
                                                           'insurer_confirm_bulk', 'todo_publish', 'form_verify')) then
    perform app.door_begin(p_user, p_aal);
    return app.ops77(p_user, p_call, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0077(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 10. privileges
-- The new functions and the wrappers: the server only (the wrappers then get what the function they wrap had).
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['vehicle_on_policy', 'vehicle_onboarding_after_status', 'onboarding_checklist',
              'confirm_fleet_policy', 'confirm_fleet_policy_bulk', 'listing_checklist', 'listing_state', 'booking_handover_on_policy',
              'doc_review_can', 'doc_review_read', 'doc_review_upload', 'doc_review_coverage', 'doc_review_plan', 'va_read', 'va_do',
              'staff_is_test', 'va_function_staffed', 'todo_prompts', 'fleet_minimum_ok', 'admin_todo', 'owner_invoice_tasks_close',
              'job_task_hygiene', 'notification_recipients', 'notification_payload', 'todo_publish', 'form_verify', 'ops77', 'door'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- Each renamed function keeps its privileges; the function in its place gets the same.
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('door_pre0077', 'door'), ('onboarding_checklist_pre0077', 'onboarding_checklist'), ('listing_checklist_pre0077', 'listing_checklist'),
                          ('listing_state_pre0077', 'listing_state'), ('va_read_pre0077', 'va_read'), ('va_do_pre0077', 'va_do'),
                          ('admin_todo_pre0077', 'admin_todo'), ('notification_recipients_pre0077', 'notification_recipients'),
                          ('ntf_payload_pre0077', 'notification_payload')) m(old_name, new_name) on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

-- ================================================================ 11. the data today
-- The tasks that no longer stand (the 8 collection tasks of the voided invoices INV-1044 to INV-1051, the opening and
-- closing checks of past days, a chat closed, the fleet count back above the warning level): closed by the same rules.
select app.job_task_hygiene();
