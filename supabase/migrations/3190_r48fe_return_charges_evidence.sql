-- 3190 (release 48, part FE; docs/changes/2026-11-20-r48-fees-evidence-hiring.md): return charges and evidence for every fee.
--
-- 1. Rental agreement charges next to speeding (10.6 to 10.8 and 11.6, a new text version; amend_without_signature makes
--    the updated agreements apply without signing again). Each has a Program setting, HST is added and they are company
--    revenue (fee_types revenue_class company_only); the actual costs are pass-through lines (not owner revenue):
--      non_return_fee        $1,000 + recovery costs (tow, impound, storage, investigator or repossession)
--      improper_return_fee   $250 + actual costs (wrong place, keys not returned, unlocked or unsecured, unagreed drop)
--      theft_recovery_fee    $1,500 + actual costs; the deductible rules of the claim still apply
--      tire_cost / roadside_callout + roadside_admin_fee ($50): flat tires, blowouts and roadside call-outs (tow, boost,
--                            lockout, fuel delivery) at actual cost plus $50, unless a mechanical fault that is not the
--                            renter's. The site's "roadside assistance included" wording is unchanged (the owner, 10:43).
--    app.return_charge_add (Admin, Finance or Fleet; ops_do return_charge_add). An incident of kind non_return or theft
--    opens a Fleet To do to bill it.
-- 2. The evidence registry (fee_evidence_rules): for each fee type the evidence required (blocks the charge) and gathered
--    (goes into the dispute pack), where it comes from by itself, and which role captures what is missing.
--    booking_line_items.evidence_status: ok | needs_evidence | overridden | not_required, kept by a trigger on every line
--    (so every entry point is covered: the field Checklist and assess_check_in, the deposit review, change_booking_fees,
--    toll_read_auto_charge, booking_return_auto_charges, speeding and the return charges). A line that needs evidence
--    gets a To do for Field (the fleet queue, "Field:"), Fleet or Finance saying exactly what to capture, and stays off
--    every statement (app.issue_booking_statement) until the evidence is attached (app.fee_evidence_attach) or an Admin
--    overrides with the reason (app.fee_evidence_override). Program setting fee_evidence_gate (on).
-- 3. Cleanliness evidence at the return: when the car is not clean, completing the return (app.complete_return: the field
--    Checklist and the staff check-in) needs 3 or more guided photos (shots clean_ash, clean_seats, clean_headliner,
--    clean_cupholders, clean_floor, clean_other; Program setting clean_evidence_min_photos) and a written description
--    (smell, where, how strong); a video is optional (clean_video_ref). The matching fee is drafted by assess_check_in as
--    before (smoking $300, cleaning by grade) and waits for Fleet's review and Finance. On a renter's self check-out
--    confirmed by staff, and on Admin's record-past-return, the fee stays "needs evidence" (a To do) until the photos and
--    description are attached. The Checklist's "Needs cleaning" and "Pet hair" answers saved values the database refused
--    (needs_cleaning, pet_hair): they are mapped to cleaning and pet.
-- No applied migration is edited: app.save_condition_report, app.complete_return, app.door are wrapped (_pre3190);
-- app.issue_booking_statement is replaced (one definition, 0020); app.speeding_charge_add and app.booking_fees_change
-- (3102, this release) are patched so the renter is told of a charge only once it is on a statement.
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
  if position(p_old in d) = 0 then raise exception '3190: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. settings and fee types
alter table program_settings
  add column if not exists non_return_fee_cents bigint not null default 100000 check (non_return_fee_cents >= 0),
  add column if not exists improper_return_fee_cents bigint not null default 25000 check (improper_return_fee_cents >= 0),
  add column if not exists theft_recovery_fee_cents bigint not null default 150000 check (theft_recovery_fee_cents >= 0),
  add column if not exists roadside_admin_fee_cents bigint not null default 5000 check (roadside_admin_fee_cents >= 0),
  add column if not exists fee_evidence_gate boolean not null default true,
  add column if not exists clean_evidence_min_photos integer not null default 3 check (clean_evidence_min_photos between 1 and 12);
comment on column program_settings.non_return_fee_cents is 'Non-return charge (3190, rental agreement 10.6), before HST: not back after the final late notice deadline; plus the recovery costs at cost, the daily rate and per-day fees until recovery, and the late fees.';
comment on column program_settings.improper_return_fee_cents is 'Improper return charge (3190, rental agreement 10.7), before HST: wrong place, keys not returned, unlocked or unsecured, a drop not agreed; plus the actual costs.';
comment on column program_settings.theft_recovery_fee_cents is 'Theft recovery charge (3190, rental agreement 10.8), before HST: the car reported stolen or recovered by police or a repossession; plus the actual costs; the deductible rules still apply.';
comment on column program_settings.roadside_admin_fee_cents is 'Tire and roadside administration fee (3190, rental agreement 11.6), before HST, on top of the actual cost of a flat tire, blowout, tow, boost, lockout or fuel delivery (not for a mechanical fault that is not the renter''s).';
comment on column program_settings.fee_evidence_gate is 'Evidence for every fee (3190): on, a fee whose required evidence is missing is "needs evidence" (a To do says what to capture) and stays off every statement until the evidence is attached or an Admin overrides with the reason.';
comment on column program_settings.clean_evidence_min_photos is 'Return not clean (3190): the guided evidence photos needed to complete the return (ash and butts, burns, seats, headliner, cupholders, floor), with a written description.';

insert into fee_types (code, label, family, unit, per_what, revenue_class, hst_applies, hst_as_invoiced, stage, refundable_by_tier, change_default, change_vehicle, change_booking, in_master_spec, sort_order, gl_account)
values ('non_return_fee', 'Non-return charge (not back after the final notice)', 'fee', 'flat', 'item', 'company_only', true, false, 'after_return', false, false, false, true, true, 208, '4120'),
       ('improper_return_fee', 'Improper return charge', 'fee', 'flat', 'item', 'company_only', true, false, 'after_return', false, false, false, true, true, 209, '4120'),
       ('theft_recovery_fee', 'Theft recovery charge', 'fee', 'flat', 'item', 'company_only', true, false, 'after_return', false, false, false, true, true, 210, '4120'),
       ('tire_cost', 'Tire repair or replacement (at cost)', 'pass_through', 'flat', 'item', 'pass_through', false, true, 'after_return', false, false, false, true, true, 211, '2150'),
       ('roadside_admin_fee', 'Tire and roadside administration fee', 'fee', 'flat', 'item', 'company_only', true, false, 'after_return', false, false, false, true, true, 212, '4120')
on conflict (code) do nothing;

-- ================================================================ 2. the evidence registry
create table if not exists fee_evidence_rules (
  fee_code    text primary key references fee_types (code) on delete cascade,
  requires    text[] not null default '{}',
  gathers     text[] not null default '{}',
  captured_by text not null check (captured_by in ('field', 'fleet', 'finance')),
  capture     text not null,
  sources     text not null
);
comment on table fee_evidence_rules is 'The evidence registry (3190): per fee type, the evidence required before it is charged (requires: missing makes the line "needs evidence"), the evidence gathered for the dispute pack (gathers), where it is found by itself (sources), and the role asked to capture what is missing (captured_by) with the exact words (capture).';
alter table fee_evidence_rules enable row level security;
revoke all on fee_evidence_rules from anon, authenticated;
grant select on fee_evidence_rules to authenticated;
grant all on fee_evidence_rules to service_role;
create policy staff_read on fee_evidence_rules for select to authenticated using (app.is_staff());
create policy admin_all on fee_evidence_rules for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_fee_evidence_rules after insert or update or delete on fee_evidence_rules for each row execute function app.audit_row();

insert into fee_evidence_rules (fee_code, requires, gathers, captured_by, capture, sources) values
  ('late_return_fee', '{return_time}', '{tracker_at_return,late_notices,signed_clause}', 'fleet', 'Complete the return so its time is recorded; the Tracker location at the return and the late notices are added by themselves.', 'The return time (check-in), the Tracker reading at the return, the late notices sent (T13, T14)'),
  ('late_return_extra_days', '{return_time}', '{tracker_at_return,late_notices,signed_clause}', 'fleet', 'Complete the return so its time is recorded.', 'The return time (check-in), the Tracker reading at the return, the late notices sent'),
  ('mileage_overage', '{readings_km,trip_photos}', '{signed_clause}', 'field', 'The odometer at pickup and at return, and the pickup and return photos (the dashboard shot shows the odometer).', 'The pickup and return readings and photos of the condition reports'),
  ('fuel', '{readings_fuel,trip_photos}', '{receipt,signed_clause}', 'field', 'The fuel level at pickup and at return, and the pickup and return photos (the dashboard shot shows the gauge).', 'The pickup and return readings and photos; the fuel receipt when there is one'),
  ('recharging', '{readings_fuel,trip_photos}', '{signed_clause}', 'field', 'The battery level at pickup and at return, and the pickup and return photos.', 'The pickup and return readings and photos'),
  ('fuel_service_fee', '{readings_fuel,trip_photos}', '{signed_clause}', 'field', 'The fuel level at pickup and at return, and the pickup and return photos.', 'The pickup and return readings and photos'),
  ('cleaning', '{guided_photos,clean_description}', '{clean_video,signed_clause}', 'field', 'At least 3 guided photos of the mess (seats, floor, cupholders, headliner) and a written description (what, where, how bad) on the return.', 'The return checklist''s guided cleanliness photos and description'),
  ('cleaning_heavy', '{guided_photos,clean_description}', '{clean_video,signed_clause}', 'field', 'At least 3 guided photos of the soiling or odour source and a written description (what, where, how strong) on the return.', 'The return checklist''s guided cleanliness photos and description'),
  ('pet_cleaning', '{guided_photos,clean_description}', '{clean_video,signed_clause}', 'field', 'At least 3 guided photos of the pet hair or soiling (seats, floor, trunk) and a written description on the return.', 'The return checklist''s guided cleanliness photos and description'),
  ('smoking', '{guided_photos,clean_description}', '{clean_video,signed_clause}', 'field', 'At least 3 guided photos (ash, butts, burns, residue; seats and headliner; ashtray and cupholders; floor) and a written description (the smell, where, how strong) on the return.', 'The return checklist''s guided cleanliness photos and description'),
  ('toll_amount', '{toll_notice}', '{toll_route,signed_clause}', 'finance', 'The 407 ETR statement line (the notice document) matched to this rental.', 'The toll statement line and its document; the Tracker route at that time'),
  ('toll_admin_fee', '{toll_notice}', '{toll_route,signed_clause}', 'finance', 'The 407 ETR statement line (the notice document) matched to this rental.', 'The toll statement line and its document'),
  ('ticket_amount', '{ticket_notice}', '{toll_route,signed_clause}', 'finance', 'The ticket or fine notice (the municipal PDF).', 'The ticket notice document'),
  ('ticket_admin_fee', '{ticket_notice}', '{signed_clause}', 'finance', 'The ticket or fine notice (the municipal PDF).', 'The ticket notice document'),
  ('speeding_180', '{speed_series}', '{tracker_map,signed_clause}', 'finance', 'The Tracker reading above the limit (its time) or the tracker alert.', 'The Tracker speed readings around the time and the route map'),
  ('speeding_220', '{speed_series}', '{tracker_map,signed_clause}', 'finance', 'The Tracker reading above the limit (its time) or the tracker alert.', 'The Tracker speed readings around the time and the route map'),
  ('speeding_300', '{speed_series}', '{tracker_map,signed_clause}', 'finance', 'The Tracker reading above the limit (its time) or the tracker alert.', 'The Tracker speed readings around the time and the route map'),
  ('damage_at_cost', '{damage_closeups}', '{pickup_photos,receipt,signed_clause}', 'fleet', 'A close-up photo of the new damage at the return (compared with the pickup photos) and the estimate or invoice.', 'The return close-ups and the pickup photos of the same area; the estimate'),
  ('deductible', '{damage_closeups}', '{pickup_photos,receipt,signed_clause}', 'fleet', 'A close-up photo of the damage and the claim''s estimate.', 'The return close-ups, the pickup photos, the claim estimate'),
  ('loss_of_use', '{damage_closeups}', '{pickup_photos,receipt,signed_clause}', 'fleet', 'A close-up photo of the damage and the shop''s days out of service.', 'The return close-ups and the claim'),
  ('admin_fee_claim', '{damage_closeups}', '{pickup_photos,signed_clause}', 'fleet', 'A close-up photo of the damage.', 'The return close-ups'),
  ('lost_key_cost', '{keys_reading,receipt}', '{signed_clause}', 'finance', 'The keys returned (on the return) and the replacement invoice.', 'The keys handed over and returned; the key receipt'),
  ('lost_key_fee', '{keys_reading}', '{signed_clause}', 'field', 'The number of keys returned, on the return.', 'The keys handed over and returned'),
  ('non_return_fee', '{final_notice,tracker_map}', '{late_notices,receipt,signed_clause}', 'fleet', 'The final late notice must have been sent and its deadline passed; the Tracker readings of the car; the tow, impound, storage or repossession receipts.', 'The late notices sent (T14 with its deadline), the Tracker readings and location, the receipts'),
  ('improper_return_fee', '{improper_proof,staff_note}', '{receipt,signed_clause}', 'field', 'Photos of where and how the car was left (or the Tracker location at the return) and a note of what was wrong.', 'The return photos or the Tracker location at the return; the staff note; receipts'),
  ('theft_recovery_fee', '{police_or_incident,tracker_map}', '{receipt,signed_clause}', 'fleet', 'The theft incident (police report number or the date it was reported stolen) and the Tracker readings; the recovery receipts.', 'The incident with the police report, the Tracker readings, the receipts'),
  ('recovery_cost', '{receipt}', '{photos,signed_clause}', 'finance', 'The tow, impound, storage, investigator or repossession receipt.', 'The receipt attached to the line'),
  ('tire_cost', '{receipt}', '{photos,signed_clause}', 'finance', 'The provider''s invoice for the tire repair or replacement, and photos of the tire.', 'The invoice attached to the line'),
  ('roadside_callout', '{receipt}', '{photos,signed_clause}', 'finance', 'The roadside provider''s invoice (tow, boost, lockout, fuel delivery).', 'The invoice attached to the line'),
  ('roadside_admin_fee', '{callout_invoice}', '{photos,signed_clause}', 'finance', 'The invoice of the tire or roadside cost it goes with.', 'The tire or roadside cost line''s invoice'),
  ('delivery', '{booking_record}', '{signed_clause}', 'finance', 'The booking record.', 'The booking and its signed agreement'),
  ('pickup', '{booking_record}', '{signed_clause}', 'finance', 'The booking record.', 'The booking and its signed agreement'),
  ('young_driver_18_20', '{booking_record}', '{signed_clause}', 'finance', 'The booking record.', 'The booking, the driver''s date of birth and the signed agreement'),
  ('young_driver_21_25', '{booking_record}', '{signed_clause}', 'finance', 'The booking record.', 'The booking, the driver''s date of birth and the signed agreement'),
  ('additional_driver', '{booking_record}', '{signed_clause}', 'finance', 'The booking record.', 'The booking and its signed agreement'),
  ('addon', '{booking_record}', '{signed_clause}', 'finance', 'The booking record.', 'The booking and its signed agreement'),
  ('winter_tire', '{booking_record}', '{signed_clause}', 'finance', 'The booking record.', 'The booking and its signed agreement'),
  ('baby_seat', '{booking_record}', '{signed_clause}', 'finance', 'The booking record.', 'The booking and its signed agreement'),
  ('admin_fee_other', '{booking_record}', '{signed_clause}', 'finance', 'The booking record.', 'The booking and its signed agreement'),
  ('declined_payment', '{booking_record}', '{signed_clause}', 'finance', 'The declined payment on the booking.', 'The payment record'),
  ('collection_cost', '{receipt}', '{signed_clause}', 'finance', 'The collection agency''s invoice.', 'The invoice attached to the line')
on conflict (fee_code) do update set requires = excluded.requires, gathers = excluded.gathers, captured_by = excluded.captured_by, capture = excluded.capture, sources = excluded.sources;

-- evidence attached by hand (a document, photos, a note) to a fee line
create table if not exists fee_evidence (
  id           uuid primary key default gen_random_uuid(),
  line_item_id uuid not null references booking_line_items (id) on delete cascade,
  kind         text not null check (kind ~ '^[a-z_]{2,40}$'),
  document_id  uuid references documents (id),
  photo_ids    jsonb not null default '[]'::jsonb check (jsonb_typeof(photo_ids) = 'array'),
  note         text check (char_length(note) <= 2000),
  added_by     uuid references users (id) on delete set null,
  added_at     timestamptz not null default now()
);
create index if not exists fee_evidence_line on fee_evidence (line_item_id);
comment on table fee_evidence is 'Evidence attached by staff to a fee line (3190): a receipt or invoice, photos, a notice, a note; with what was found by itself it satisfies the registry (fee_evidence_rules).';
alter table fee_evidence enable row level security;
revoke all on fee_evidence from anon, authenticated;
grant all on fee_evidence to service_role;
create policy admin_all on fee_evidence for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_fee_evidence after insert or update or delete on fee_evidence for each row execute function app.audit_row();

alter table booking_line_items
  add column if not exists evidence_status text check (evidence_status in ('ok', 'needs_evidence', 'overridden', 'not_required')),
  add column if not exists evidence_missing text[] not null default '{}',
  add column if not exists evidence_checked_at timestamptz,
  add column if not exists evidence_override_by uuid references users (id) on delete set null,
  add column if not exists evidence_override_reason text check (char_length(evidence_override_reason) <= 1000);
comment on column booking_line_items.evidence_status is 'Evidence for every fee (3190): ok, needs_evidence (kept off every statement while fee_evidence_gate is on; a To do asks for it), overridden (an Admin, with the reason), not_required (no registry rule). Null: a line from before 3190.';

alter table condition_reports add column if not exists clean_evidence jsonb not null default '{}'::jsonb check (jsonb_typeof(clean_evidence) = 'object');
comment on column condition_reports.clean_evidence is 'Return not clean (3190): {description: the smell, where, how strong; video_ref: the optional video in storage}. The guided photos are condition_report_photos with the shots clean_*.';

alter table condition_report_photos drop constraint if exists condition_report_photos_shot_check;
alter table condition_report_photos add constraint condition_report_photos_shot_check check (shot = any (array['front', 'front_left', 'left', 'rear_left', 'rear', 'rear_right', 'right', 'front_right', 'roof', 'windshield',
  'wheel_front_left', 'wheel_front_right', 'wheel_rear_left', 'wheel_rear_right', 'instrument_cluster', 'front_seats', 'rear_seats', 'trunk', 'keys', 'damage_closeup', 'licence', 'other',
  'clean_ash', 'clean_seats', 'clean_headliner', 'clean_cupholders', 'clean_floor', 'clean_other']));

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('fee_evidence_needed', 'fleet', 'A fee needs its evidence before it is charged', 'high', 'business_days', 1, 9, null,
   'Every fee is charged only with its evidence (3190). The To do says exactly what to capture: attach it on the booking''s Money tab (Evidence), or an Admin overrides with the reason. Until then the fee stays off the renter''s statement.'),
  ('fee_evidence_ready', 'finance', 'Evidence attached: bill the fee that was waiting', 'normal', 'business_days', 1, 9, null,
   'A fee that was waiting for its evidence now has it. Bill it from the booking''s Money tab (Charge after the return).'),
  ('return_charge_due', 'fleet', 'Bill the non-return or theft recovery charge', 'high', 'business_days', 2, 8, null,
   'A non-return or theft incident is open on a rental. Once the car is recovered, add the charge (Money tab > Return charges) with the tow, impound, storage or repossession receipts (rental agreement 10.6 and 10.8).')
on conflict (task_type) do update set title = excluded.title, description = excluded.description, priority = excluded.priority, queue = excluded.queue;

-- what is found by itself for a line: {kind: detail} for each kind present
create function app.fee_evidence_have(p_line uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  li booking_line_items;
  b bookings;
  s program_settings := app.settings();
  pr condition_reports;
  rr condition_reports;
  tt toll_tickets;
  v jsonb := '{}'::jsonb;
  n integer;
  m integer;
  v_at timestamptz;
  v_refs jsonb;
begin
  select * into li from booking_line_items where id = p_line;
  if li.id is null then return v; end if;
  select * into b from bookings where id = li.booking_id;
  v_refs := coalesce(li.supporting_refs, '{}'::jsonb);
  select * into pr from condition_reports c where c.booking_id = b.id and c.kind = 'pickup' order by c.completed_at desc nulls last, c.created_at desc limit 1;
  select * into rr from condition_reports c where c.booking_id = b.id and c.kind = 'return' order by c.completed_at desc nulls last, c.created_at desc limit 1;
  v := v || jsonb_build_object('booking_record', jsonb_build_object('booking_number', b.booking_number));
  if exists (select 1 from rental_agreements a where a.booking_id = b.id and a.voided_at is null and (a.renter_signed_at is not null or a.completed_at is not null)) then
    v := v || jsonb_build_object('signed_clause', (select jsonb_build_object('agreement_number', a.agreement_number, 'template_version', a.template_version, 'signed_at', coalesce(a.renter_signed_at, a.completed_at))
                                                  from rental_agreements a where a.booking_id = b.id and a.voided_at is null order by coalesce(a.renter_signed_at, a.completed_at) desc nulls last limit 1));
  end if;
  if b.checked_in_at is not null then v := v || jsonb_build_object('return_time', jsonb_build_object('at', b.checked_in_at)); end if;
  if b.checked_in_at is not null then
    select count(*) into n from tracker_points t where t.vehicle_id = b.vehicle_id and t.at between b.checked_in_at - interval '30 minutes' and b.checked_in_at + interval '30 minutes';
    if n > 0 then v := v || jsonb_build_object('tracker_at_return', jsonb_build_object('readings', n)); end if;
  end if;
  select count(*) into n from tracker_points t where t.vehicle_id = b.vehicle_id
     and t.at between coalesce(b.handed_over_at, b.pickup_at) and coalesce(b.checked_in_at, now());
  if n > 0 then v := v || jsonb_build_object('tracker_map', jsonb_build_object('readings', n)); end if;
  select count(*) into n from notification_outbox o where o.booking_id = b.id and o.code like 'renter_late_return%' and o.status not in ('failed', 'cancelled', 'skipped');
  if n > 0 then v := v || jsonb_build_object('late_notices', jsonb_build_object('notices', n)); end if;
  -- the final notice (T14) gives one hour: its deadline must have passed before the car was back (or now)
  select min(coalesce(o.sent_at, o.created_at)) into v_at from notification_outbox o
   where o.booking_id = b.id and o.code = 'renter_late_return_final' and o.status not in ('failed', 'cancelled', 'skipped');
  if v_at is not null and v_at + interval '1 hour' < coalesce(b.checked_in_at, now()) then
    v := v || jsonb_build_object('final_notice', jsonb_build_object('sent_at', v_at, 'deadline', v_at + interval '1 hour'));
  end if;
  if b.odometer_out_km is not null and b.odometer_in_km is not null or (pr.odometer_km is not null and rr.odometer_km is not null) then
    v := v || jsonb_build_object('readings_km', jsonb_build_object('out', coalesce(b.odometer_out_km, pr.odometer_km), 'in', coalesce(b.odometer_in_km, rr.odometer_km)));
  end if;
  if b.fuel_out_pct is not null and b.fuel_in_pct is not null or (pr.fuel_pct is not null and rr.fuel_pct is not null) then
    v := v || jsonb_build_object('readings_fuel', jsonb_build_object('out', coalesce(b.fuel_out_pct, pr.fuel_pct), 'in', coalesce(b.fuel_in_pct, rr.fuel_pct)));
  end if;
  if rr.id is not null and rr.keys_count is not null then v := v || jsonb_build_object('keys_reading', jsonb_build_object('out', pr.keys_count, 'in', rr.keys_count)); end if;
  select count(*) into n from condition_report_photos p where p.condition_report_id = pr.id;
  select count(*) into m from condition_report_photos p where p.condition_report_id = rr.id and p.shot not like 'clean_%';
  if n > 0 then v := v || jsonb_build_object('pickup_photos', jsonb_build_object('photos', n)); end if;
  if n > 0 and m > 0 then v := v || jsonb_build_object('trip_photos', jsonb_build_object('pickup', n, 'return', m)); end if;
  -- the guided cleanliness photos, and photos or documents attached by hand
  select count(*) into n from condition_report_photos p where p.condition_report_id = rr.id and p.shot like 'clean_%';
  n := n + coalesce((select sum(jsonb_array_length(e.photo_ids)) from fee_evidence e where e.line_item_id = li.id), 0)
         + (select count(*) from fee_evidence e where e.line_item_id = li.id and e.kind = 'photo' and e.document_id is not null)
         + case when jsonb_typeof(v_refs -> 'photo_ids') = 'array' then jsonb_array_length(v_refs -> 'photo_ids') else 0 end;
  if n >= s.clean_evidence_min_photos then v := v || jsonb_build_object('guided_photos', jsonb_build_object('photos', n)); end if;
  if n > 0 then v := v || jsonb_build_object('photos', jsonb_build_object('photos', n)); end if;
  if char_length(btrim(coalesce(rr.clean_evidence ->> 'description', ''))) >= 15
     or exists (select 1 from fee_evidence e where e.line_item_id = li.id and e.kind = 'description' and char_length(btrim(coalesce(e.note, ''))) >= 15) then
    v := v || jsonb_build_object('clean_description', jsonb_build_object('text', left(coalesce(nullif(rr.clean_evidence ->> 'description', ''),
                                   (select e.note from fee_evidence e where e.line_item_id = li.id and e.kind = 'description' order by e.added_at desc limit 1)), 300)));
  end if;
  if nullif(rr.clean_evidence ->> 'video_ref', '') is not null then v := v || jsonb_build_object('clean_video', jsonb_build_object('ref', rr.clean_evidence ->> 'video_ref')); end if;
  -- damage: a close-up at the return or later, a photo or document on the line
  if exists (select 1 from condition_report_photos p join condition_reports c on c.id = p.condition_report_id
              where c.booking_id = b.id and c.kind <> 'pickup' and p.shot = 'damage_closeup')
     or li.supporting_document_id is not null and li.charge_type in ('damage_at_cost', 'deductible', 'loss_of_use', 'admin_fee_claim')
     or (jsonb_typeof(v_refs -> 'photos') = 'array' and jsonb_array_length(v_refs -> 'photos') > 0)
     or exists (select 1 from fee_evidence e where e.line_item_id = li.id and e.kind in ('photo', 'damage_closeup')) then
    v := v || jsonb_build_object('damage_closeups', true);
  end if;
  -- a receipt or invoice: the line's document, its documents, or one attached
  if li.supporting_document_id is not null
     or (jsonb_typeof(v_refs -> 'document_ids') = 'array' and jsonb_array_length(v_refs -> 'document_ids') > 0)
     or nullif(v_refs ->> 'receipt_document_id', '') is not null or nullif(v_refs ->> 'fuel_receipt_document_id', '') is not null or nullif(v_refs ->> 'key_receipt_document_id', '') is not null
     or exists (select 1 from fee_evidence e where e.line_item_id = li.id and e.kind in ('receipt', 'invoice') and e.document_id is not null) then
    v := v || jsonb_build_object('receipt', jsonb_build_object('document_id', coalesce(li.supporting_document_id,
                 (select e.document_id from fee_evidence e where e.line_item_id = li.id and e.document_id is not null order by e.added_at desc limit 1))));
  end if;
  if li.charge_type = 'roadside_admin_fee' and exists (select 1 from booking_line_items x where x.booking_id = b.id and x.voided_at is null
        and x.charge_type in ('tire_cost', 'roadside_callout') and (x.supporting_document_id is not null
             or exists (select 1 from fee_evidence e where e.line_item_id = x.id and e.document_id is not null))
        and (x.supporting_refs ->> 'group') is not distinct from (v_refs ->> 'group')) then
    v := v || jsonb_build_object('callout_invoice', true);
  end if;
  -- tolls and tickets
  select * into tt from toll_tickets t where t.id = coalesce(li.toll_ticket_id, nullif(v_refs ->> 'toll_ticket_id', '')::uuid);
  if tt.id is null and jsonb_typeof(v_refs -> 'toll_ticket_ids') = 'array' then
    select * into tt from toll_tickets t where t.id = (v_refs -> 'toll_ticket_ids' ->> 0)::uuid;
  end if;
  if tt.id is not null and tt.document_id is not null then
    v := v || jsonb_build_object(case when tt.kind = 'toll_invoice' then 'toll_notice' else 'ticket_notice' end,
                                 jsonb_build_object('toll_ticket_id', tt.id, 'document_id', tt.document_id, 'notice_number', tt.notice_number));
  end if;
  if li.charge_type like 'ticket%' and li.supporting_document_id is not null then v := v || jsonb_build_object('ticket_notice', jsonb_build_object('document_id', li.supporting_document_id)); end if;
  if li.charge_type like 'toll%' and li.supporting_document_id is not null and not v ? 'toll_notice' then v := v || jsonb_build_object('toll_notice', jsonb_build_object('document_id', li.supporting_document_id)); end if;
  if tt.id is not null and (tt.tracker_proof_document_id is not null or exists (select 1 from tracker_points t where t.vehicle_id = b.vehicle_id
        and t.at between tt.occurred_at - interval '15 minutes' and tt.occurred_at + interval '15 minutes')) then
    v := v || jsonb_build_object('toll_route', jsonb_build_object('document_id', tt.tracker_proof_document_id));
  end if;
  -- speeding: the reading kept on the line and the Tracker's series around it
  if v_refs ? 'speed_kmh' and (nullif(v_refs ->> 'alert_id', '') is not null or exists (select 1 from tracker_points t where t.vehicle_id = b.vehicle_id
        and t.at between (v_refs ->> 'at')::timestamptz - interval '5 minutes' and (v_refs ->> 'at')::timestamptz + interval '5 minutes' and t.speed_kmh is not null)) then
    v := v || jsonb_build_object('speed_series', jsonb_build_object('speed_kmh', (v_refs ->> 'speed_kmh')::int, 'at', v_refs ->> 'at'));
  end if;
  -- non-return, improper return, theft
  if exists (select 1 from incidents i where i.booking_id = b.id and i.kind in ('theft', 'non_return')
              and (i.police_report_number is not null or i.reported_stolen_at is not null))
     or nullif(v_refs ->> 'police_report', '') is not null then
    v := v || jsonb_build_object('police_or_incident', true);
  end if;
  if v ? 'tracker_at_return' or (rr.id is not null and m > 0) or exists (select 1 from fee_evidence e where e.line_item_id = li.id and e.kind = 'photo')
     or (jsonb_typeof(v_refs -> 'photo_ids') = 'array' and jsonb_array_length(v_refs -> 'photo_ids') > 0) then
    v := v || jsonb_build_object('improper_proof', true);
  end if;
  if char_length(btrim(coalesce(v_refs ->> 'note', ''))) >= 5 or exists (select 1 from fee_evidence e where e.line_item_id = li.id and char_length(btrim(coalesce(e.note, ''))) >= 5) then
    v := v || jsonb_build_object('staff_note', true);
  end if;
  return v;
end $$;

create function app.fee_evidence_label(p_kind text) returns text
language sql immutable as $$
  select case p_kind
    when 'return_time' then 'the return time' when 'tracker_at_return' then 'the Tracker location at the return' when 'late_notices' then 'the late notices sent'
    when 'final_notice' then 'the final late notice with its deadline passed' when 'readings_km' then 'the odometer at pickup and at return'
    when 'readings_fuel' then 'the fuel or battery level at pickup and at return' when 'trip_photos' then 'the pickup and return photos'
    when 'guided_photos' then 'the guided evidence photos' when 'clean_description' then 'a written description' when 'clean_video' then 'a video'
    when 'toll_notice' then 'the 407 statement line' when 'toll_route' then 'the Tracker route' when 'ticket_notice' then 'the ticket notice PDF'
    when 'speed_series' then 'the Tracker speed readings' when 'tracker_map' then 'the Tracker readings and map' when 'damage_closeups' then 'the damage close-ups'
    when 'pickup_photos' then 'the pickup photos' when 'receipt' then 'the receipt or invoice' when 'callout_invoice' then 'the tire or roadside invoice'
    when 'keys_reading' then 'the keys returned' when 'police_or_incident' then 'the theft incident with the police report'
    when 'improper_proof' then 'photos or the Tracker location at the return' when 'staff_note' then 'a note of what was wrong'
    when 'booking_record' then 'the booking record' when 'signed_clause' then 'the signed clause' when 'photos' then 'photos'
    else replace(p_kind, '_', ' ') end
$$;

-- check one line: its status, what is missing, the To do (opened or closed)
create function app.fee_evidence_check(p_line uuid) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  li booking_line_items;
  r fee_evidence_rules;
  b bookings;
  v_have jsonb;
  v_missing text[];
  v_status text;
  v_was text;
begin
  select * into li from booking_line_items where id = p_line;
  if li.id is null then return null; end if;
  v_was := li.evidence_status;
  if li.voided_at is not null or li.evidence_status = 'overridden' then
    update tasks set status = 'done', completed_at = now(), completion_note = 'No longer needed'
     where dedupe_key = 'fee_evidence:' || li.id and status in ('open', 'in_progress', 'waiting');
    return li.evidence_status;
  end if;
  select * into r from fee_evidence_rules where fee_code = li.charge_type;
  if r.fee_code is null then
    v_status := 'not_required'; v_missing := '{}';
  else
    v_have := app.fee_evidence_have(li.id);
    select coalesce(array_agg(k order by k), '{}') into v_missing from unnest(r.requires) k where not v_have ? k;
    v_status := case when cardinality(v_missing) = 0 then 'ok' else 'needs_evidence' end;
  end if;
  update booking_line_items set evidence_status = v_status, evidence_missing = v_missing, evidence_checked_at = now() where id = li.id;
  if v_status = 'needs_evidence' and li.statement_id is null then
    select * into b from bookings where id = li.booking_id;
    perform app.raise_task(p_type => 'fee_evidence_needed', p_queue => case r.captured_by when 'finance' then 'finance' else 'fleet' end, p_priority => 'high',
      p_title => left(format('%sEvidence needed: %s on %s', case when r.captured_by = 'field' then 'Field: ' else '' end, coalesce(li.description, li.charge_type), b.booking_number), 200),
      p_detail => left(format('Missing: %s. Capture: %s Attach it on the booking''s Money tab (Evidence). The fee is not charged until then, or until an Admin overrides with the reason.',
                              (select string_agg(app.fee_evidence_label(k), ', ') from unnest(v_missing) k), r.capture), 900),
      p_booking => li.booking_id, p_related_table => 'booking_line_items', p_related_id => li.id, p_dedupe => 'fee_evidence:' || li.id);
  elsif v_status in ('ok', 'not_required') then
    update tasks set status = 'done', completed_at = now(), completion_note = 'Evidence attached'
     where dedupe_key = 'fee_evidence:' || li.id and status in ('open', 'in_progress', 'waiting');
    -- a fee that waited for its evidence after the Check-out statement: Finance bills it
    if v_was = 'needs_evidence' and li.statement_id is null and exists (select 1 from booking_statements x where x.booking_id = li.booking_id and x.kind = 'check_in') then
      select * into b from bookings where id = li.booking_id;
      perform app.raise_task(p_type => 'fee_evidence_ready', p_queue => 'finance',
        p_title => left(format('Evidence attached: bill %s on %s', coalesce(li.description, li.charge_type), b.booking_number), 200),
        p_booking => li.booking_id, p_related_table => 'booking_line_items', p_related_id => li.id, p_dedupe => 'fee_evidence_ready:' || li.id);
    end if;
  end if;
  return v_status;
end $$;

create function app.fee_evidence_recheck(p_booking uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare l record; n integer := 0;
begin
  for l in select li.id from booking_line_items li where li.booking_id = p_booking and li.voided_at is null and li.statement_id is null
             and coalesce(li.evidence_status, '') <> 'overridden' loop
    perform app.fee_evidence_check(l.id); n := n + 1;
  end loop;
  return n;
end $$;

-- every line, from every entry point
create function app.fee_evidence_on_line() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    perform app.fee_evidence_check(new.id);
  exception when others then
    raise warning 'fee evidence not checked for line %: %', new.id, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists fee_evidence_line on booking_line_items;
create trigger fee_evidence_line after insert or update of amount_cents, supporting_document_id, supporting_refs, voided_at, toll_ticket_id
  on booking_line_items for each row when (new.statement_id is null) execute function app.fee_evidence_on_line();

-- evidence that arrives later: a photo of the booking's reports, a document of the booking, evidence attached, a notice
create function app.fee_evidence_on_source() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v_b uuid;
begin
  begin
    -- the row as json: each table has its own columns
    v_b := case tg_table_name
      when 'condition_report_photos' then (select c.booking_id from condition_reports c where c.id = (to_jsonb(new) ->> 'condition_report_id')::uuid)
      when 'fee_evidence' then (select li.booking_id from booking_line_items li where li.id = (to_jsonb(new) ->> 'line_item_id')::uuid)
      else (to_jsonb(new) ->> 'booking_id')::uuid end;
    if v_b is not null and exists (select 1 from booking_line_items li where li.booking_id = v_b and li.statement_id is null and li.evidence_status = 'needs_evidence') then
      perform app.fee_evidence_recheck(v_b);
    end if;
  exception when others then
    raise warning 'fee evidence recheck: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists fee_evidence_source on condition_report_photos;
create trigger fee_evidence_source after insert on condition_report_photos for each row execute function app.fee_evidence_on_source();
drop trigger if exists fee_evidence_source on condition_reports;
create trigger fee_evidence_source after update of clean_evidence, odometer_km, fuel_pct, keys_count, completed_at on condition_reports for each row execute function app.fee_evidence_on_source();
drop trigger if exists fee_evidence_source on fee_evidence;
create trigger fee_evidence_source after insert on fee_evidence for each row execute function app.fee_evidence_on_source();
drop trigger if exists fee_evidence_source on toll_tickets;
create trigger fee_evidence_source after update of document_id, tracker_proof_document_id on toll_tickets for each row execute function app.fee_evidence_on_source();

-- staff attach evidence to a line: {line, kind (receipt, invoice, photo, notice, description, note, police_report, other), document_id, photo_ids, note}
create function app.fee_evidence_attach(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  li booking_line_items;
  v_kind text := lower(coalesce(nullif(p ->> 'kind', ''), case when p ? 'document_id' then 'receipt' else 'note' end));
  v_doc uuid := nullif(p ->> 'document_id', '')::uuid;
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_status text;
begin
  if not (app.user_is_admin(p_by) or app.user_runs_finance(p_by) or app.user_runs_fleet(p_by) or app.user_is_field(p_by)) then
    raise exception 'Staff of Field, Fleet, Finance or an Admin attach evidence' using errcode = '42501';
  end if;
  select * into li from booking_line_items where id = nullif(p ->> 'line', '')::uuid for update;
  if li.id is null then raise exception 'Fee line not found' using errcode = 'P0002'; end if;
  if v_kind not in ('receipt', 'invoice', 'photo', 'notice', 'description', 'note', 'police_report', 'damage_closeup', 'other') then
    raise exception 'Evidence kind: receipt, invoice, photo, notice, description, note, police_report, damage_closeup or other' using errcode = '22023';
  end if;
  -- a file the site stored for this line (the Money tab's Evidence upload): registered as a document of the booking
  if v_doc is null and nullif(p ->> 'path', '') is not null then
    if (p ->> 'path') !~ ('^evidence/' || li.booking_id || '/') then raise exception 'Unknown file' using errcode = '22023'; end if;
    insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, booking_id, uploaded_by)
    values ((case v_kind when 'receipt' then 'receipt' when 'invoice' then 'repair_invoice' when 'police_report' then 'police_report' when 'notice' then 'notice' else 'other' end)::document_kind,
            left(coalesce(nullif(btrim(coalesce(p ->> 'title', '')), ''), initcap(replace(v_kind, '_', ' ')) || ': ' || coalesce(li.description, li.charge_type)), 200),
            'documents', p ->> 'path', nullif(p ->> 'mime', ''), nullif(p ->> 'sha256', ''), 'records_7y', li.booking_id, p_by)
    returning id into v_doc;
  end if;
  if v_doc is null and v_note is null and jsonb_array_length(coalesce(p -> 'photo_ids', '[]'::jsonb)) = 0 then
    raise exception 'Attach a document, photos or a note' using errcode = '22023';
  end if;
  if v_doc is not null and not exists (select 1 from documents d where d.id = v_doc and (d.booking_id = li.booking_id or d.booking_id is null)) then
    raise exception 'That document is not of this booking' using errcode = '22023';
  end if;
  if v_kind = 'police_report' then
    update booking_line_items set supporting_refs = coalesce(supporting_refs, '{}'::jsonb) || jsonb_build_object('police_report', v_note) where id = li.id;
  end if;
  insert into fee_evidence (line_item_id, kind, document_id, photo_ids, note, added_by)
  values (li.id, case when v_kind = 'invoice' then 'invoice' when v_kind = 'notice' then 'receipt' else v_kind end, v_doc, coalesce(p -> 'photo_ids', '[]'::jsonb), v_note, p_by);
  v_status := app.fee_evidence_check(li.id);
  perform app.log_booking_event(li.booking_id, 'adjusted', null, null, null,
    format('Evidence attached to %s (%s): %s', coalesce(li.description, li.charge_type), v_kind, case when v_status = 'ok' then 'complete' else 'still missing ' || array_to_string((select evidence_missing from booking_line_items where id = li.id), ', ') end),
    p_by, 'staff', jsonb_build_object('line_item_id', li.id, 'document_id', v_doc));
  return jsonb_build_object('ok', true, 'line_item_id', li.id, 'evidence_status', v_status,
    'missing', (select to_jsonb(evidence_missing) from booking_line_items where id = li.id));
end $$;

-- an Admin charges a fee without the evidence the registry asks, with the reason
create function app.fee_evidence_override(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  li booking_line_items;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin overrides the evidence of a fee' using errcode = '42501'; end if;
  if v_reason is null or char_length(v_reason) < 10 then raise exception 'Say why the fee is charged without its evidence (10 characters or more)' using errcode = '22023'; end if;
  select * into li from booking_line_items where id = nullif(p ->> 'line', '')::uuid for update;
  if li.id is null then raise exception 'Fee line not found' using errcode = 'P0002'; end if;
  if li.evidence_status is distinct from 'needs_evidence' then raise exception 'This fee does not wait for evidence' using errcode = '23514'; end if;
  update booking_line_items set evidence_status = 'overridden', evidence_override_by = p_by, evidence_override_reason = v_reason, evidence_checked_at = now() where id = li.id;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Overridden by an Admin: ' || left(v_reason, 200)
   where dedupe_key = 'fee_evidence:' || li.id and status in ('open', 'in_progress', 'waiting');
  perform app.log_booking_event(li.booking_id, 'adjusted', null, null, null,
    format('Evidence overridden for %s (missing %s): %s', coalesce(li.description, li.charge_type), array_to_string(li.evidence_missing, ', '), v_reason), p_by, 'staff',
    jsonb_build_object('line_item_id', li.id, 'missing', li.evidence_missing));
  return jsonb_build_object('ok', true, 'line_item_id', li.id, 'evidence_status', 'overridden');
end $$;

-- the Money tab: each fee line with its evidence
create function app.booking_fee_evidence(p_by uuid, p_booking uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then raise exception 'Staff only' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('line_item_id', li.id, 'charge_type', li.charge_type, 'description', li.description, 'amount_cents', li.amount_cents,
      'on_statement', li.statement_id is not null, 'status', coalesce(li.evidence_status, 'not_required'), 'missing', to_jsonb(li.evidence_missing),
      'missing_text', (select string_agg(app.fee_evidence_label(k), ', ') from unnest(li.evidence_missing) k),
      'requires', to_jsonb(r.requires), 'gathers', to_jsonb(r.gathers), 'capture', r.capture, 'captured_by', r.captured_by, 'sources', r.sources,
      'have', app.fee_evidence_have(li.id), 'override_reason', li.evidence_override_reason,
      'attached', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'document_id', e.document_id, 'photos', jsonb_array_length(e.photo_ids), 'note', e.note, 'at', e.added_at) order by e.added_at)
                              from fee_evidence e where e.line_item_id = li.id), '[]'::jsonb)) order by li.created_at)
    from booking_line_items li left join fee_evidence_rules r on r.fee_code = li.charge_type
   where li.booking_id = p_booking and li.voided_at is null and r.fee_code is not null), '[]'::jsonb);
end $$;

-- the statement leaves out a fee that needs evidence (one definition before this: 0020)
create or replace function app.issue_booking_statement(p_booking uuid, p_by uuid default null, p_now timestamptz default now())
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_kind text;
  v_id uuid;
  v_n integer;
  v_charges bigint; v_hst bigint;
  v_bad text;
  v_gate boolean := coalesce((app.settings()).fee_evidence_gate, true);
  v_held text;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.status not in ('returned', 'closed') then
    raise exception 'Booking % is %: a statement is issued after the return', b.booking_number, b.status using errcode = '23514';
  end if;
  if p_by is not null and not app.user_runs_finance(p_by) then
    raise exception 'Finance or an Admin issues a statement' using errcode = '42501';
  end if;
  v_kind := case when exists (select 1 from booking_statements s where s.booking_id = p_booking and s.kind = 'check_in')
                 then 'later_charge' else 'check_in' end;
  if v_kind = 'check_in' and not exists (
       select 1 from condition_reports c where c.booking_id = p_booking and c.kind = 'return' and c.reviewed_at is not null) then
    raise exception 'The return of booking % has not been reviewed yet: Fleet confirms the findings first', b.booking_number using errcode = '23514';
  end if;
  -- 3190: the evidence as it stands now (Tracker readings and notices arrive after a line is made)
  perform app.fee_evidence_recheck(p_booking);

  select count(*), coalesce(sum(li.amount_cents), 0), coalesce(sum(li.hst_cents), 0),
         string_agg(li.charge_type, ', ') filter (where li.supporting_document_id is null
                                                    and (li.supporting_refs is null or li.supporting_refs = '{}'::jsonb))
    into v_n, v_charges, v_hst, v_bad
    from booking_line_items li
   where li.booking_id = p_booking and li.statement_id is null and li.voided_at is null and li.charged_to_renter
     and li.stage in ('check_in', 'after_return', 'on_decline')
     and not (v_gate and li.evidence_status is not distinct from 'needs_evidence');
  select string_agg(coalesce(li.description, li.charge_type) || ' (missing ' || (select string_agg(app.fee_evidence_label(k), ', ') from unnest(li.evidence_missing) k) || ')', '; ')
    into v_held from booking_line_items li
   where li.booking_id = p_booking and li.statement_id is null and li.voided_at is null and li.charged_to_renter
     and li.stage in ('check_in', 'after_return', 'on_decline') and v_gate and li.evidence_status = 'needs_evidence';
  if v_kind = 'later_charge' and v_n = 0 then
    if v_held is not null then
      raise exception 'Waiting for evidence before it is charged: %. Attach it on the Money tab (Evidence), or an Admin overrides with the reason', v_held using errcode = '23514';
    end if;
    raise exception 'There is no new charge to put on a statement for booking %', b.booking_number using errcode = '23514';
  end if;
  if v_bad is not null then
    raise exception 'A charge cannot be issued without its supporting record: %', v_bad using errcode = '23514';
  end if;
  if (p_by is null or not app.user_is_admin(p_by)) and exists (
       select 1 from booking_line_items li join fee_types ft on ft.code = li.charge_type
        where li.booking_id = p_booking and li.statement_id is null and li.voided_at is null and ft.family = 'damage'
          and not (v_gate and li.evidence_status is not distinct from 'needs_evidence')) then
    raise exception 'A statement with a damage line needs an Admin' using errcode = '42501';
  end if;

  insert into booking_statements (booking_id, statement_number, kind, issued_at, charges_cents, hst_cents, interest_starts_on, created_by)
  values (p_booking, 'RS-' || nextval('renter_statement_number_seq'), v_kind, p_now, v_charges, v_hst,
          app.local_date(p_now) + (app.settings(app.local_date(p_now))).statement_interest_days, p_by)
  returning id into v_id;
  update booking_line_items li set statement_id = v_id
   where li.booking_id = p_booking and li.statement_id is null and li.voided_at is null and li.charged_to_renter
     and li.stage in ('check_in', 'after_return', 'on_decline')
     and not (v_gate and li.evidence_status is not distinct from 'needs_evidence');
  perform app.resolve_tasks(array['price_findings'], p_booking, p_by, 'Statement issued');
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Billed'
   where task_type = 'fee_evidence_ready' and booking_id = p_booking and status in ('open', 'in_progress', 'waiting')
     and related_id in (select li.id from booking_line_items li where li.statement_id = v_id);
  if v_held is not null then
    perform app.log_booking_event(p_booking, 'adjusted', null, null, null, 'Held back from the statement until its evidence is attached: ' || v_held, p_by, 'system');
  end if;
  return v_id;
end $$;

-- charging after the return with only fees that wait for evidence: nothing is issued yet (the caller's fee stays added)
alter function app.charge_after_rental(uuid, uuid, timestamptz) rename to charge_after_rental_pre3190;
create function app.charge_after_rental(p_booking uuid, p_by uuid, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, app as $$
begin
  if coalesce((app.settings()).fee_evidence_gate, true)
     and exists (select 1 from booking_statements s where s.booking_id = p_booking and s.kind = 'check_in') then
    perform app.fee_evidence_recheck(p_booking);
    if not exists (select 1 from booking_line_items li where li.booking_id = p_booking and li.statement_id is null and li.voided_at is null and li.charged_to_renter
                     and li.stage in ('check_in', 'after_return', 'on_decline') and li.evidence_status is distinct from 'needs_evidence')
       and exists (select 1 from booking_line_items li where li.booking_id = p_booking and li.statement_id is null and li.voided_at is null and li.charged_to_renter
                     and li.stage in ('check_in', 'after_return', 'on_decline') and li.evidence_status = 'needs_evidence') then
      return jsonb_build_object('statement_id', null, 'settlement', null, 'waiting_for', 'evidence');
    end if;
  end if;
  return app.charge_after_rental_pre3190(p_booking, p_by, p_now);
end $$;
select pg_temp.copy_grants('app.charge_after_rental(uuid, uuid, timestamptz)'::regprocedure, 'app.charge_after_rental_pre3190(uuid, uuid, timestamptz)'::regprocedure);
revoke all on function app.charge_after_rental_pre3190(uuid, uuid, timestamptz) from public, anon, authenticated;
grant execute on function app.charge_after_rental_pre3190(uuid, uuid, timestamptz) to service_role;

-- the renter is told of a speeding charge or an added fee once it is on a statement (a fee waiting for evidence is not)
select pg_temp.patch_fn('app.speeding_charge_add(uuid, jsonb)'::regprocedure,
  $o$      v_res := app.charge_after_rental(b.id, p_by, now());
      perform app.emit_event('renter_extra_charge', 'booking_line_item', v_line,$o$,
  $n$      v_res := app.charge_after_rental(b.id, p_by, now());
      if (select li.statement_id from booking_line_items li where li.id = v_line) is not null then perform app.emit_event('renter_extra_charge', 'booking_line_item', v_line,$n$);
select pg_temp.patch_fn('app.speeding_charge_add(uuid, jsonb)'::regprocedure,
  $o$        'renter_extra_charge:' || v_line || ':speeding');$o$,
  $n$        'renter_extra_charge:' || v_line || ':speeding'); end if;$n$);
select pg_temp.patch_fn('app.speeding_charge_add(uuid, jsonb)'::regprocedure,
  $o$  return jsonb_build_object('ok', true, 'line_item_id', v_line,$o$,
  $n$  return jsonb_build_object('ok', true, 'line_item_id', v_line, 'evidence_status', (select li.evidence_status from booking_line_items li where li.id = v_line),$n$);
select pg_temp.patch_fn('app.booking_fees_change(uuid, jsonb)'::regprocedure,
  $o$      for a in select value from jsonb_array_elements(v_added) where value ? 'label' loop
        perform app.emit_event($o$,
  $n$      for a in select value from jsonb_array_elements(v_added) a0 where a0.value ? 'label'
                 and (select li.statement_id from booking_line_items li where li.id = (a0.value ->> 'line_item_id')::uuid) is not null loop
        perform app.emit_event($n$);
select pg_temp.patch_fn('app.booking_fees_change(uuid, jsonb)'::regprocedure,
  $o$  return jsonb_build_object('ok', true, 'booking_number', b.booking_number, 'added', v_added,$o$,
  $n$  return jsonb_build_object('ok', true, 'booking_number', b.booking_number,
    'added', coalesce((select jsonb_agg(a0.value || jsonb_build_object('evidence_status', li.evidence_status, 'evidence_missing', to_jsonb(li.evidence_missing)))
                         from jsonb_array_elements(v_added) a0 left join booking_line_items li on li.id = (a0.value ->> 'line_item_id')::uuid), '[]'::jsonb),$n$);

-- ================================================================ 3. the return charges
-- p: {booking, kind: non_return | improper_return | theft_recovery | tire | roadside, reason (improper: wrong_place, keys_not_returned,
--     unlocked, unsecured, unagreed_drop), note, costs: [{label, amount_cents, document_id}], mechanical_fault, police_report, incident_id, amount_cents}
create function app.return_charge_add(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  s program_settings := app.settings();
  v_kind text := lower(btrim(coalesce(p ->> 'kind', '')));
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_reason text := lower(nullif(btrim(coalesce(p ->> 'reason', '')), ''));
  v_code text;
  v_cost_code text;
  v_amount bigint;
  v_line uuid;
  v_lines jsonb := '[]'::jsonb;
  v_group text := gen_random_uuid()::text;
  c jsonb;
  v_res jsonb;
  v_desc text;
  v_refs jsonb;
  v_cost bigint;
  v_doc uuid;
  v_total bigint := 0;
begin
  if not (app.user_is_admin(p_by) or app.user_runs_finance(p_by) or app.user_runs_fleet(p_by)) then
    raise exception 'An Admin, Finance or Fleet adds a return charge' using errcode = '42501';
  end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.booking_type::text = 'owner' then raise exception 'An Owner Booking has no renter charges' using errcode = '23514'; end if;
  if b.status::text not in ('on_rent', 'returned', 'closed') then raise exception 'A return charge is for a car that was handed over' using errcode = '23514'; end if;
  if v_kind not in ('non_return', 'improper_return', 'theft_recovery', 'tire', 'roadside') then
    raise exception 'Choose the charge: non_return, improper_return, theft_recovery, tire or roadside' using errcode = '22023';
  end if;
  if v_kind in ('tire', 'roadside') and coalesce((p ->> 'mechanical_fault')::boolean, false) then
    raise exception 'A mechanical fault that is not the renter''s is not charged (rental agreement 11.3): the roadside service is included' using errcode = '23514';
  end if;
  if v_kind = 'improper_return' and (v_reason is null or v_reason not in ('wrong_place', 'keys_not_returned', 'unlocked', 'unsecured', 'unagreed_drop')) then
    raise exception 'Say what was wrong: wrong_place, keys_not_returned, unlocked, unsecured or unagreed_drop' using errcode = '22023';
  end if;
  if v_kind = 'improper_return' and b.status::text = 'on_rent' then raise exception 'An improper return is charged once the return is recorded' using errcode = '23514'; end if;
  if v_note is null or char_length(v_note) < 5 then raise exception 'Say what happened (the renter sees it)' using errcode = '22023'; end if;
  if v_kind in ('tire', 'roadside') and jsonb_array_length(coalesce(p -> 'costs', '[]'::jsonb)) = 0 then
    raise exception 'Give the actual cost: costs [{"label": "Tow", "amount_cents": 18000, "document_id": "<the invoice>"}]' using errcode = '22023';
  end if;
  v_code := case v_kind when 'non_return' then 'non_return_fee' when 'improper_return' then 'improper_return_fee' when 'theft_recovery' then 'theft_recovery_fee' else 'roadside_admin_fee' end;
  v_cost_code := case v_kind when 'tire' then 'tire_cost' when 'roadside' then 'roadside_callout' else 'recovery_cost' end;
  v_amount := case v_kind when 'non_return' then s.non_return_fee_cents when 'improper_return' then s.improper_return_fee_cents
                          when 'theft_recovery' then s.theft_recovery_fee_cents else s.roadside_admin_fee_cents end;
  if exists (select 1 from booking_line_items li where li.booking_id = b.id and li.charge_type = v_code and li.voided_at is null) and v_kind in ('non_return', 'theft_recovery') then
    raise exception 'This booking already has the % charge: add the costs to it with evidence', replace(v_kind, '_', ' ') using errcode = '23514';
  end if;
  v_refs := jsonb_strip_nulls(jsonb_build_object('kind', v_kind, 'reason', v_reason, 'note', v_note, 'group', v_group, 'incident_id', nullif(p ->> 'incident_id', ''),
                                                 'police_report', nullif(btrim(coalesce(p ->> 'police_report', '')), ''), 'photo_ids', p -> 'photo_ids', 'added_by', p_by));
  v_desc := case v_kind
    when 'non_return' then 'Non-return charge (rental agreement 10.6): ' || v_note
    when 'improper_return' then format('Improper return charge (rental agreement 10.7, %s): %s', replace(v_reason, '_', ' '), v_note)
    when 'theft_recovery' then 'Theft recovery charge (rental agreement 10.8): ' || v_note
    else format('%s administration fee (rental agreement 11.6): %s', case v_kind when 'tire' then 'Tire' else 'Roadside' end, v_note) end;
  if coalesce(v_amount, 0) > 0 then
    v_line := app.set_assessed_line(b.id, v_kind || ':' || v_group, v_code, 1, v_amount, v_amount, v_desc, v_refs, p_by);
    v_lines := v_lines || jsonb_build_object('line_item_id', v_line, 'fee', v_code, 'amount_cents', v_amount);
    v_total := v_total + v_amount;
  end if;
  for c in select value from jsonb_array_elements(coalesce(p -> 'costs', '[]'::jsonb)) loop
    v_cost := nullif(c ->> 'amount_cents', '')::bigint;
    v_doc := nullif(c ->> 'document_id', '')::uuid;
    if v_cost is null or v_cost <= 0 then raise exception 'Each cost needs its amount (amount_cents)' using errcode = '22023'; end if;
    if v_doc is not null and not exists (select 1 from documents d where d.id = v_doc and (d.booking_id = b.id or d.booking_id is null)) then
      raise exception 'The receipt is not a document of this booking' using errcode = '22023';
    end if;
    v_line := app.set_assessed_line(b.id, v_kind || ':cost:' || gen_random_uuid(), v_cost_code, 1, v_cost, v_cost,
      format('%s (at cost): %s', case v_kind when 'tire' then 'Tire repair or replacement' when 'roadside' then 'Roadside call-out' else 'Recovery cost' end,
             coalesce(nullif(btrim(coalesce(c ->> 'label', '')), ''), v_note)),
      v_refs || jsonb_strip_nulls(jsonb_build_object('receipt_document_id', v_doc)), p_by, null, v_doc);
    v_lines := v_lines || jsonb_build_object('line_item_id', v_line, 'fee', v_cost_code, 'amount_cents', v_cost);
    v_total := v_total + v_cost;
  end loop;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('%s: %s plus HST where it applies', v_desc, app.fmt_money(v_total)), p_by, 'staff', jsonb_build_object('lines', v_lines));
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Charge added'
   where task_type = 'return_charge_due' and booking_id = b.id and status in ('open', 'in_progress', 'waiting') and v_kind in ('non_return', 'theft_recovery');
  if b.status::text in ('returned', 'closed') and exists (select 1 from booking_statements x where x.booking_id = b.id and x.kind = 'check_in') then
    begin
      v_res := app.charge_after_rental(b.id, p_by, now());
    exception when sqlstate '23514' then
      v_res := jsonb_build_object('waiting', sqlerrm);
    end;
    if exists (select 1 from booking_line_items li where li.id in (select (x ->> 'line_item_id')::uuid from jsonb_array_elements(v_lines) x) and li.statement_id is not null) then
      perform app.emit_event('renter_extra_charge', 'booking', b.id,
        jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'renter_id', b.renter_id, 'charge_kind', v_kind, 'charge_type', v_code,
                           'amount_cents', v_total, 'hst_cents', public.calc_hst(v_amount, b.hst_bps), 'total_cents', v_total + public.calc_hst(v_amount, b.hst_bps),
                           'document_ids', '[]'::jsonb, 'charged_from', case when (select d.status from deposits d where d.booking_id = b.id) in ('held', 'captured') then 'deposit' else 'card_on_file' end),
        'renter_extra_charge:' || b.id || ':' || v_group);
    end if;
  end if;
  if b.status::text in ('returned', 'closed') then begin perform app.compute_booking_split(b.id); exception when others then null; end; end if;
  return jsonb_build_object('ok', true, 'lines', (select jsonb_agg(x || jsonb_build_object('evidence_status', li.evidence_status, 'missing', to_jsonb(li.evidence_missing)))
                                                   from jsonb_array_elements(v_lines) x join booking_line_items li on li.id = (x ->> 'line_item_id')::uuid),
    'total_cents', v_total, 'charged', v_res,
    'billed', case when v_res ? 'statement_id' and v_res ->> 'statement_id' is not null then 'from the deposit first, then the card on file'
                   when b.status::text = 'on_rent' then 'after the return, from the deposit first' else 'on the Check-out statement, from the deposit first, once its evidence is complete' end);
end $$;

-- a non-return or theft incident on a rental: Fleet bills the charge once the car is recovered
create function app.return_charge_on_incident() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare b bookings;
begin
  begin
    if new.booking_id is not null and new.kind in ('non_return', 'theft') then
      select * into b from bookings where id = new.booking_id;
      if b.id is not null and b.booking_type::text <> 'owner' then
        perform app.raise_task(p_type => 'return_charge_due', p_queue => 'fleet',
          p_title => left(format('%s on %s: add the %s charge once the car is recovered', case new.kind when 'theft' then 'Theft' else 'Non-return' end, b.booking_number,
                                 case new.kind when 'theft' then 'theft recovery ($' || ((app.settings()).theft_recovery_fee_cents / 100) || ')' else 'non-return ($' || ((app.settings()).non_return_fee_cents / 100) || ')' end), 200),
          p_detail => 'Money tab > Return charges: the charge plus the tow, impound, storage or repossession receipts. The evidence (Tracker readings, the final notice, the police report) is gathered by itself; what is missing becomes a To do.',
          p_booking => b.id, p_related_table => 'incidents', p_related_id => new.id, p_dedupe => 'return_charge_due:' || b.id || ':' || new.kind);
      end if;
    end if;
  exception when others then
    raise warning 'return charge To do not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists return_charge_due on incidents;
create trigger return_charge_due after insert on incidents for each row execute function app.return_charge_on_incident();

-- ================================================================ 4. cleanliness evidence at the return
alter function app.save_condition_report(uuid, text, uuid, jsonb, uuid, uuid) rename to save_condition_report_pre3190;
create function app.save_condition_report(p_booking uuid, p_kind text, p_by uuid, p_report jsonb default '{}'::jsonb, p_job uuid default null, p_vehicle uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  d jsonb := coalesce(p_report, '{}'::jsonb);
  v_id uuid;
begin
  -- the Checklist's answers "Needs cleaning" and "Pet hair"
  if d ->> 'cleanliness' = 'needs_cleaning' then d := d || '{"cleanliness": "cleaning"}'::jsonb; end if;
  if d ->> 'cleanliness' = 'pet_hair' then d := d || '{"cleanliness": "pet"}'::jsonb; end if;
  v_id := app.save_condition_report_pre3190(p_booking, p_kind, p_by, d - 'clean_description' - 'clean_video_ref', p_job, p_vehicle);
  if d ? 'clean_description' or d ? 'clean_video_ref' then
    update condition_reports set clean_evidence = clean_evidence
      || case when d ? 'clean_description' then jsonb_build_object('description', left(btrim(coalesce(d ->> 'clean_description', '')), 2000)) else '{}'::jsonb end
      || case when d ? 'clean_video_ref' then jsonb_build_object('video_ref', left(coalesce(d ->> 'clean_video_ref', ''), 300)) else '{}'::jsonb end
     where id = v_id and completed_at is null;
  end if;
  return v_id;
end $$;
select pg_temp.copy_grants('app.save_condition_report(uuid, text, uuid, jsonb, uuid, uuid)'::regprocedure, 'app.save_condition_report_pre3190(uuid, text, uuid, jsonb, uuid, uuid)'::regprocedure);

-- the shots a return that is not clean asks for (the Checklist and the guide name the same)
create function app.clean_evidence_shots() returns jsonb
language sql immutable as $$
  select '[{"shot": "clean_ash", "label": "Ash, butts, burns or residue"}, {"shot": "clean_seats", "label": "Seats"}, {"shot": "clean_headliner", "label": "Headliner"},
           {"shot": "clean_cupholders", "label": "Ashtray and cupholders"}, {"shot": "clean_floor", "label": "Floor and mats"}, {"shot": "clean_other", "label": "Anything else"}]'::jsonb
$$;

-- what a return that is not clean still lacks (null: nothing)
create function app.clean_evidence_missing(p_report uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  c condition_reports;
  n integer;
  v_min integer := (app.settings()).clean_evidence_min_photos;
begin
  select * into c from condition_reports where id = p_report;
  if c.id is null or coalesce(c.cleanliness, 'clean') = 'clean' then return null; end if;
  select count(*) into n from condition_report_photos p where p.condition_report_id = c.id and p.shot like 'clean_%';
  if n < v_min then
    return format('The car is not clean: take %s or more evidence photos (ash, butts and burns; seats and headliner; ashtray and cupholders; floor) before completing the return (%s taken)', v_min, n);
  end if;
  if char_length(btrim(coalesce(c.clean_evidence ->> 'description', ''))) < 15 then
    return 'The car is not clean: describe it in writing (the smell, where, how strong) before completing the return';
  end if;
  return null;
end $$;

alter function app.complete_return(uuid, uuid, jsonb, uuid, timestamptz) rename to complete_return_pre3190;
create function app.complete_return(p_booking uuid, p_by uuid, p_report jsonb default '{}'::jsonb, p_job uuid default null, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  d jsonb := coalesce(p_report, '{}'::jsonb);
  c condition_reports;
  v_why text;
  v_out jsonb;
begin
  if d ->> 'cleanliness' = 'needs_cleaning' then d := d || '{"cleanliness": "cleaning"}'::jsonb; end if;
  if d ->> 'cleanliness' = 'pet_hair' then d := d || '{"cleanliness": "pet"}'::jsonb; end if;
  -- the description and video ride on the report: save them first, then check the evidence of a return that is not clean
  if d ? 'clean_description' or d ? 'clean_video_ref' or d ? 'cleanliness' then
    perform app.save_condition_report(p_booking, 'return', p_by, jsonb_strip_nulls(jsonb_build_object('cleanliness', d ->> 'cleanliness',
      'clean_description', d ->> 'clean_description', 'clean_video_ref', d ->> 'clean_video_ref')), p_job);
  end if;
  -- the return as before (its own checks first: the photo set, the signatures, the readings), then the evidence of a car
  -- that is not clean, on the completed report; refused, the whole return is undone
  v_out := app.complete_return_pre3190(p_booking, p_by, d - 'clean_description' - 'clean_video_ref', p_job, p_now);
  select * into c from condition_reports r where r.booking_id = p_booking and r.kind = 'return' order by r.created_at desc limit 1;
  if c.id is not null and not coalesce(c.details_pending, false) then
    v_why := app.clean_evidence_missing(c.id);
    if v_why is not null then raise exception '%', v_why using errcode = '23514'; end if;
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.complete_return(uuid, uuid, jsonb, uuid, timestamptz)'::regprocedure, 'app.complete_return_pre3190(uuid, uuid, jsonb, uuid, timestamptz)'::regprocedure);

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3190;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_call = 'ops_do' and p_name in ('return_charge_add', 'fee_evidence_attach', 'fee_evidence_override') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'return_charge_add' then app.return_charge_add(p_user, v)
      when 'fee_evidence_attach' then app.fee_evidence_attach(p_user, v)
      else app.fee_evidence_override(p_user, v) end;
  end if;
  if p_call = 'ops_read' and p_name = 'fee_evidence' then
    perform app.door_begin(p_user, p_aal);
    return jsonb_build_object('lines', app.booking_fee_evidence(p_user, (select b.id from bookings b where b.id::text = v ->> 'booking' or b.booking_number = upper(btrim(coalesce(v ->> 'booking', ''))))),
                              'clean_shots', app.clean_evidence_shots());
  end if;
  return app.door_pre3190(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3190(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.fee_evidence_have(uuid), app.fee_evidence_label(text), app.fee_evidence_check(uuid), app.fee_evidence_recheck(uuid), app.fee_evidence_on_line(),
  app.fee_evidence_on_source(), app.fee_evidence_attach(uuid, jsonb), app.fee_evidence_override(uuid, jsonb), app.booking_fee_evidence(uuid, uuid), app.return_charge_add(uuid, jsonb),
  app.return_charge_on_incident(), app.save_condition_report_pre3190(uuid, text, uuid, jsonb, uuid, uuid), app.clean_evidence_shots(), app.clean_evidence_missing(uuid),
  app.complete_return_pre3190(uuid, uuid, jsonb, uuid, timestamptz), app.door_pre3190(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.fee_evidence_have(uuid), app.fee_evidence_label(text), app.fee_evidence_check(uuid), app.fee_evidence_recheck(uuid), app.fee_evidence_on_line(),
  app.fee_evidence_on_source(), app.fee_evidence_attach(uuid, jsonb), app.fee_evidence_override(uuid, jsonb), app.booking_fee_evidence(uuid, uuid), app.return_charge_add(uuid, jsonb),
  app.return_charge_on_incident(), app.save_condition_report_pre3190(uuid, text, uuid, jsonb, uuid, uuid), app.clean_evidence_shots(), app.clean_evidence_missing(uuid),
  app.complete_return_pre3190(uuid, uuid, jsonb, uuid, timestamptz), app.door_pre3190(uuid, text, text, text, jsonb) to service_role;

-- the lines already waiting for a statement get their status (no To do for a line made before this release)
update booking_line_items li set evidence_status = 'not_required'
 where li.evidence_status is null and li.statement_id is null and li.voided_at is null
   and not exists (select 1 from fee_evidence_rules r where r.fee_code = li.charge_type);
