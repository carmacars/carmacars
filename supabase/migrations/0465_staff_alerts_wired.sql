-- 0465: every staff alert with a data source is wired (docs/changes/2026-11-07-lead-alerts.md, docs/alerts/matrix.md).
-- The owner: "I'll get alerted for literally everything right?" 0462 made the rule table, the emitter and the feed and
-- wired the first groups; 0464 the tracker, interviews, data health, deletion and the academy quiz. This wires the rest
-- that has data today, each through app.staff_alert (one emitter, the rule's who, tier and topic; never a test account):
--   bookings   offer viewed (Live visitors' offer_viewed event), offer accepted, extension asked or paid, change asked or
--              applied, cancellation, deposit released, insurer booking without a claim number 24 hours before pickup
--   money      deposit hold failed and card declined near pickup (urgent), owner debit failed (urgent), investor money
--   field      handover checklist incomplete, fuel or km off at return
--   customers  complaint words in chat or inbound texts and emails, email unsubscribes and text STOPs (digest)
--   documents  licence to review, agreement signed (digest), agreement unsigned 2 hours before pickup (urgent),
--              insurance proof missing 24 hours before pickup
--   fleet      service or inspection due (digest), car unpublished
--   owners     owner gives notice (urgent), owner banking changed (urgent), investor signed
--   hiring     interview link expired, applicant hired (accepted)
--   academy    lesson finished (digest), quiz failed twice, certified (every section of a path passed)
--   staff      Sales late for their block (15 minutes) or idle for 2 hours inside it (sales_availability, 0174)
--   wins       first booking of a car, record day and record week, an owner's first payout, the month's totals on the 1st
-- Usage over 80% and data health are in-app only (digest), as the owner asked. Time-sensitive customer notices that still
-- had no push topic get one. The scheduled checks are app.sa_scheduled (called by the 5-minute job, 0466).
-- No applied migration is edited.
set local check_function_bodies = off;

-- ================================================================ 1. settings and rules
alter table program_settings
  add column if not exists alert_complaint_words text not null default 'refund, scam, dirty, smell, smells, broken, rude, lawyer, complaint, complain, unacceptable, terrible, worst, police, disgusting, chargeback, ripped off, never again'
    check (length(alert_complaint_words) <= 1000);
comment on column program_settings.alert_complaint_words is 'Staff alerts (0465): words or phrases, comma separated, that make a chat message or an inbound text or email a "complaint words" alert to the Admins and customer service on duty (once per conversation a day).';

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('booking_cancelled', 'Booking cancelled', 'Bookings', '{admin,on_duty:fleet}', 'normal', 'bookings', true, false, null, 57),
  ('owner_debit_failed', 'Owner debit failed', 'Money', '{admin}', 'urgent', 'alerts', true, false, 'A pre-authorized debit from an owner failed at the bank.', 46),
  ('academy_lesson', 'Academy lesson finished', 'Staff', '{admin}', 'digest', 'alerts', true, false, 'A line of the Admin digest, never a push.', 122),
  ('academy_quiz_failed_twice', 'Academy quiz failed twice', 'Staff', '{admin}', 'normal', 'alerts', true, false, null, 123),
  ('academy_certified', 'Academy path finished (certified)', 'Staff', '{admin}', 'normal', 'alerts', true, false, null, 124),
  ('staff_late', 'Sales late for their block', 'Staff', '{admin}', 'normal', 'alerts', true, false, 'A Sales availability block started 15 minutes ago and they have not opened the portal.', 125),
  ('interview_expired', 'AI interview link expired', 'Hiring', '{admin}', 'normal', 'requests', true, false, null, 117),
  ('applicant_hired', 'Applicant accepted the offer (hired)', 'Hiring', '{admin}', 'normal', 'requests', true, false, null, 118)
on conflict (rule) do nothing;

update staff_alert_rules set wired = true, updated_at = now()
 where rule in ('deposit_hold_failed', 'card_declined_pickup', 'investor_money_in', 'offer_viewed', 'offer_accepted', 'extension_paid', 'date_change',
                'deposit_released', 'insurer_claim_missing', 'handover_checklist_incomplete', 'return_fuel_km', 'complaint_keyword', 'opt_out',
                'licence_review', 'agreement_signed', 'agreement_unsigned_pickup', 'insurance_missing', 'maintenance_due', 'car_unpublished',
                'owner_notice', 'owner_banking_changed', 'investor_invested', 'staff_idle', 'win_first_booking', 'win_record_day',
                'win_first_payout', 'win_month_totals');
update staff_alert_rules set label = 'Booking change asked or applied' where rule = 'date_change';
update staff_alert_rules set label = 'Record day or week of payments' where rule = 'win_record_day';
update staff_alert_rules set hint = 'Program setting alert_complaint_words.' where rule = 'complaint_keyword';
update staff_alert_rules set hint = 'Within 2 hours of a Sales availability block with no visit to the portal.' where rule = 'staff_idle';
update staff_alert_rules set label = 'Car due for service or inspection', hint = 'When a service item turns due soon or overdue (Maintenance).' where rule = 'maintenance_due';
update staff_alert_rules set label = 'Insurer booking without a claim number', hint = 'Confirmed insurer booking, pickup within 24 hours, no claim number.' where rule = 'insurer_claim_missing';
-- in the app only, as the owner asked (a digest line, never a push)
update staff_alert_rules set tier = 'digest', hint = 'In the app only (and the daily digest), never a push.' where rule = 'usage_80';
update staff_alert_rules set hint = 'The nightly check (0441) found records that need you: the in-app notice of Admin > To do. In the app only.' where rule = 'data_health';
update notification_catalogue set push_topic = null where code = 'staff_data_health';

-- the time-sensitive customer notices still without a phone-alert topic (no codes, links, games or comeback reminders)
update notification_catalogue c set push_topic = t.topic
  from (values ('owner_schedule_resign', 'documents'), ('owner_pad_confirmed', 'payments'), ('owner_registry_visit', 'documents'),
               ('owner_fee_change_cancelled', 'bookings'), ('renter_recovery_offer', 'requests'), ('renter_recovery_change', 'requests'),
               ('renter_named_to_authority', 'alerts'), ('account_security_notice', 'alerts')) t(code, topic)
 where c.code = t.code and c.push_topic is null and c.category <> 'marketing';

-- ================================================================ 2. helpers
create or replace function app.sa_booking_ok(p_b bookings) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_b.id is not null and not coalesce(p_b.is_placeholder, false) and p_b.booking_type <> 'owner'
     and not coalesce(app.email_is_test((select r.email from renters r where r.id = p_b.renter_id)), false) and not coalesce(app.booking_is_test(p_b.id), false)
$$;
create or replace function app.sa_phone(p_b bookings) returns text
language sql stable security definer set search_path = public, app as $$
  select nullif(regexp_replace(coalesce((select r.mobile from renters r where r.id = p_b.renter_id), ''), '[^0-9+]', '', 'g'), '')
$$;
create or replace function app.sa_owner_test(p_owner uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select o.is_test or app.email_is_test(o.email) from owners o where o.id = p_owner), false)
$$;

-- ================================================================ 3. bookings: the status steps (cancellation and the first booking of a car)
create or replace function app.sa_booking_alert(p_b bookings) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_rule text;
  v_title text;
  v_when timestamptz;
begin
  if not app.sa_booking_ok(p_b) then return; end if;
  select x.r, x.t, x.w into v_rule, v_title, v_when from (values
      ('confirmed', 'booking_confirmed', 'Booking confirmed', p_b.pickup_at),
      ('on_rent', 'booking_out', 'Car going out', p_b.pickup_at),
      ('returned', 'booking_back', 'Car back', p_b.return_at),
      ('closed', 'booking_closed', 'Booking closed', p_b.return_at),
      ('no_show', 'booking_no_show', 'No-show', p_b.pickup_at),
      ('cancelled', 'booking_cancelled', 'Booking cancelled', p_b.pickup_at)) x(s, r, t, w) where x.s = p_b.status::text;
  if v_rule is null then return; end if;
  perform app.staff_alert(v_rule, 'booking', p_b.id, p_b.status::text, v_title || ': ' || app.sa_booking_line(p_b),
    case v_rule when 'booking_back' then 'Return time ' else 'Pickup time ' end || app.fmt_at(v_when),
    app.sa_booking_paths(p_b) || jsonb_build_object('call', app.sa_phone(p_b)));
  -- a win: the first paid booking of a car
  if v_rule = 'booking_confirmed' and not exists (
       select 1 from bookings o where o.vehicle_id = p_b.vehicle_id and o.id <> p_b.id and not coalesce(o.is_placeholder, false)
          and o.booking_type <> 'owner' and o.status in ('confirmed', 'on_rent', 'returned', 'closed')) then
    perform app.staff_alert('win_first_booking', 'vehicle', p_b.vehicle_id, 'first', 'First booking: ' || coalesce(app.vehicle_name(p_b.vehicle_id), 'a car'),
      'Booking ' || p_b.booking_number || ', pickup ' || app.fmt_at(p_b.pickup_at), app.sa_booking_paths(p_b));
  end if;
end $$;

-- fuel lower or more km than allowed at return
create or replace function app.sa_booking_return() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_fuel integer;
  v_km integer;
  v_parts text[] := '{}';
begin
  begin
    if not app.sa_booking_ok(new) then return null; end if;
    v_fuel := coalesce(new.fuel_out_pct, 0) - coalesce(new.fuel_in_pct, coalesce(new.fuel_out_pct, 0));
    v_km := coalesce(new.odometer_in_km, 0) - coalesce(new.odometer_out_km, coalesce(new.odometer_in_km, 0));
    if new.fuel_in_pct is not null and new.fuel_out_pct is not null and v_fuel >= 10 then v_parts := v_parts || format('fuel %s%% lower than at pickup', v_fuel); end if;
    if new.odometer_in_km is not null and new.odometer_out_km is not null and coalesce(new.km_allowance_total, 0) > 0 and v_km > new.km_allowance_total then
      v_parts := v_parts || format('%s km over the %s km allowed', v_km - new.km_allowance_total, new.km_allowance_total);
    end if;
    if cardinality(v_parts) = 0 then return null; end if;
    perform app.staff_alert('return_fuel_km', 'booking', new.id, 'return', 'Check the return: ' || app.sa_booking_line(new), initcap(left(array_to_string(v_parts, '; '), 1)) || substr(array_to_string(v_parts, '; '), 2) || '.',
      app.sa_booking_paths(new) || jsonb_build_object('path_admin', '/admin/bookings/' || new.booking_number || '?tab=money', 'path_staff', '/staff/bookings/' || new.booking_number || '?tab=money'));
  exception when others then
    raise warning 'return alert not made for %: %', new.id, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists bookings_z_staff_alert_return on bookings;
create trigger bookings_z_staff_alert_return after update of fuel_in_pct, odometer_in_km on bookings for each row
  when (new.fuel_in_pct is distinct from old.fuel_in_pct or new.odometer_in_km is distinct from old.odometer_in_km) execute function app.sa_booking_return();

-- the offer: viewed (Live visitors records offer_viewed with consent only, 0060) and accepted
create or replace function app.sa_offer_viewed() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare b bookings;
begin
  begin
    select * into b from bookings where id = new.booking_id;
    if not app.sa_booking_ok(b) or b.status not in ('offered', 'pending_payment') then return null; end if;
    perform app.staff_alert('offer_viewed', 'booking', b.id, app.local_date(new.at)::text, 'Offer viewed: ' || app.sa_booking_line(b),
      'Pickup ' || app.fmt_at(b.pickup_at), app.sa_booking_paths(b) || jsonb_build_object('call', app.sa_phone(b)));
  exception when others then
    raise warning 'offer viewed alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists visitor_events_z_staff_alert on visitor_events;
create trigger visitor_events_z_staff_alert after insert on visitor_events for each row
  when (new.kind = 'offer_viewed' and new.booking_id is not null) execute function app.sa_offer_viewed();

create or replace function app.sa_offer_answer() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare b bookings;
begin
  begin
    select * into b from bookings where id = new.booking_id;
    if not app.sa_booking_ok(b) then return null; end if;
    perform app.staff_alert('offer_accepted', 'booking', b.id, 'v' || new.version, 'Offer accepted: ' || app.sa_booking_line(b),
      app.fmt_money(coalesce(new.renter_due_cents, new.total_cents)) || ', pickup ' || app.fmt_at(b.pickup_at), app.sa_booking_paths(b));
  exception when others then
    raise warning 'offer accepted alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists booking_offers_z_staff_alert on booking_offers;
create trigger booking_offers_z_staff_alert after update of status on booking_offers for each row
  when (new.status = 'approved' and old.status is distinct from 'approved') execute function app.sa_offer_answer();

-- extensions: asked (Approve or Decline on the phone) and paid
create or replace function app.sa_extension() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare b bookings;
begin
  begin
    select * into b from bookings where id = new.booking_id;
    if not app.sa_booking_ok(b) then return null; end if;
    if tg_op = 'INSERT' and new.status = 'requested' then
      perform app.staff_alert('extension_paid', 'booking', b.id, 'asked:' || new.seq, 'Extension asked: ' || app.sa_booking_line(b),
        'New return ' || app.fmt_at(new.new_return_at) || ', ' || app.fmt_money(coalesce(new.total_cents, 0)),
        app.sa_booking_paths(b) || jsonb_build_object('path_admin', '/admin/bookings/' || b.booking_number || '?tab=changes', 'path_staff', '/staff/bookings/' || b.booking_number || '?tab=changes', 'decide', true));
    elsif new.paid_at is not null and (tg_op = 'INSERT' or old.paid_at is null) then
      perform app.staff_alert('extension_paid', 'booking', b.id, 'paid:' || new.seq, 'Extension paid: ' || app.sa_booking_line(b),
        'New return ' || app.fmt_at(new.new_return_at) || ', ' || app.fmt_money(coalesce(new.total_cents, 0)), app.sa_booking_paths(b));
    end if;
  exception when others then
    raise warning 'extension alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists booking_extensions_z_staff_alert on booking_extensions;
create trigger booking_extensions_z_staff_alert after insert or update of paid_at on booking_extensions for each row execute function app.sa_extension();

-- a change (dates, car, extras): asked by the renter, and applied
create or replace function app.sa_change_request() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare b bookings;
begin
  begin
    select * into b from bookings where id = new.booking_id;
    if not app.sa_booking_ok(b) then return null; end if;
    if tg_op = 'INSERT' and new.requested_by_role = 'renter' then
      perform app.staff_alert('date_change', 'booking_change', new.id, 'asked', 'Change asked: ' || app.sa_booking_line(b),
        coalesce(nullif(left(new.note, 160), ''), 'Open the booking to see what they asked.'),
        app.sa_booking_paths(b) || jsonb_build_object('path_admin', '/admin/bookings/' || b.booking_number || '?tab=changes', 'path_staff', '/staff/bookings/' || b.booking_number || '?tab=changes', 'decide', true));
    elsif tg_op = 'UPDATE' and new.status = 'applied' and old.status is distinct from 'applied' then
      perform app.staff_alert('date_change', 'booking_change', new.id, 'applied', 'Change applied: ' || app.sa_booking_line(b),
        'Pickup ' || app.fmt_at(b.pickup_at) || ', return ' || app.fmt_at(b.return_at), app.sa_booking_paths(b));
    end if;
  exception when others then
    raise warning 'change alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists booking_change_requests_z_staff_alert on booking_change_requests;
create trigger booking_change_requests_z_staff_alert after insert or update of status on booking_change_requests for each row execute function app.sa_change_request();

-- ================================================================ 4. money
create or replace function app.sa_deposit() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare b bookings;
begin
  begin
    select * into b from bookings where id = new.booking_id;
    if not app.sa_booking_ok(b) then return null; end if;
    if new.status = 'failed' and (tg_op = 'INSERT' or old.status is distinct from 'failed') then
      perform app.staff_alert('deposit_hold_failed', 'deposit', new.id, 'failed', 'Deposit hold failed: ' || app.sa_booking_line(b),
        app.fmt_money(new.amount_cents) || ', pickup ' || app.fmt_at(b.pickup_at) || '. Ask for another card or take it another way.',
        app.sa_booking_paths(b) || jsonb_build_object('call', app.sa_phone(b)));
    end if;
    if new.released_at is not null and (tg_op = 'INSERT' or old.released_at is null) then
      perform app.staff_alert('deposit_released', 'deposit', new.id, 'released', 'Deposit released: ' || app.sa_booking_line(b),
        app.fmt_money(coalesce(new.released_cents, new.amount_cents)), app.sa_booking_paths(b));
    end if;
  exception when others then
    raise warning 'deposit alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists deposits_z_staff_alert on deposits;
create trigger deposits_z_staff_alert after insert or update of status, released_at on deposits for each row execute function app.sa_deposit();

-- a card refused within 12 hours of the pickup (before or after)
create or replace function app.sa_card_declined() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  p payments;
  b bookings;
begin
  begin
    select * into p from payments where id = new.payment_id;
    select * into b from bookings where id = p.booking_id;
    if not app.sa_booking_ok(b) or b.status not in ('confirmed', 'on_rent', 'pending_payment') then return null; end if;
    if abs(extract(epoch from (b.pickup_at - new.attempted_at))) > 12 * 3600 then return null; end if;
    perform app.staff_alert('card_declined_pickup', 'payment', p.id, 'declined', 'Card declined at pickup: ' || app.sa_booking_line(b),
      app.fmt_money(p.amount_cents) || coalesce(' (' || new.decline_code || ')', '') || ', pickup ' || app.fmt_at(b.pickup_at),
      app.sa_booking_paths(b) || jsonb_build_object('call', app.sa_phone(b)));
  exception when others then
    raise warning 'card declined alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists payment_attempts_z_staff_alert on payment_attempts;
create trigger payment_attempts_z_staff_alert after insert on payment_attempts for each row when (new.outcome = 'declined') execute function app.sa_card_declined();

create or replace function app.sa_owner_debit() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    if app.sa_owner_test(new.owner_id) then return null; end if;
    perform app.staff_alert('owner_debit_failed', 'owner_debit', new.id, 'failed',
      'Owner debit failed: ' || coalesce((select coalesce(o.corporation_name, o.legal_name) from owners o where o.id = new.owner_id), 'an owner'),
      app.fmt_money(new.amount_cents) || coalesce(', ' || nullif(new.failure_message, ''), '') || '.',
      jsonb_build_object('path_admin', '/admin/debits', 'owner_id', new.owner_id));
  exception when others then
    raise warning 'owner debit alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists owner_debit_attempts_z_staff_alert on owner_debit_attempts;
create trigger owner_debit_attempts_z_staff_alert after update of status on owner_debit_attempts for each row
  when (new.status = 'failed' and old.status is distinct from 'failed') execute function app.sa_owner_debit();

create or replace function app.sa_investor_test(p_investor uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select app.email_is_test(i.email) or (i.user_id is not null and app.staff_is_test(i.user_id)) from investors i where i.id = p_investor), false)
$$;
create or replace function app.sa_investment() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    if app.sa_investor_test(new.investor_id) then return null; end if;
    perform app.staff_alert('investor_money_in', 'investment', new.id, 'new',
      'Investor money: ' || app.fmt_money(new.principal_cents) || ' from ' || coalesce((select i.legal_name from investors i where i.id = new.investor_id), 'an investor'),
      'Invested ' || to_char(new.investment_date, 'Mon FMDD, YYYY') || coalesce(', ' || round(new.yearly_bps / 100.0, 2) || '% a year', '') || '.',
      jsonb_build_object('path_admin', '/admin/investors'));
  exception when others then
    raise warning 'investment alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists investments_z_staff_alert on investments;
create trigger investments_z_staff_alert after insert on investments for each row when (new.transferred_from_investment_id is null) execute function app.sa_investment();

create or replace function app.sa_investor_signed() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    if app.sa_investor_test(new.investor_id) then return null; end if;
    perform app.staff_alert('investor_invested', 'investment_agreement', new.id, 'signed',
      'Investor signed: ' || coalesce((select i.legal_name from investors i where i.id = new.investor_id), 'an investor'),
      'Agreement ' || coalesce(new.agreement_number, '') || ' signed.', jsonb_build_object('path_admin', '/admin/investors'));
  exception when others then
    raise warning 'investor signed alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists investment_agreements_z_staff_alert on investment_agreements;
create trigger investment_agreements_z_staff_alert after update of status on investment_agreements for each row
  when (new.status = 'signed' and old.status is distinct from 'signed') execute function app.sa_investor_signed();

-- a win: an owner's first payout paid
create or replace function app.sa_payout() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    if new.payee_type <> 'owner' or new.owner_id is null or app.sa_owner_test(new.owner_id) then return null; end if;
    if exists (select 1 from payouts p where p.owner_id = new.owner_id and p.id <> new.id and p.status = 'paid') then return null; end if;
    perform app.staff_alert('win_first_payout', 'owner', new.owner_id, 'first',
      'First payout: ' || coalesce((select coalesce(o.corporation_name, o.legal_name) from owners o where o.id = new.owner_id), 'an owner'),
      app.fmt_money(new.amount_cents) || ' paid.', jsonb_build_object('path_admin', '/admin/payouts'));
  exception when others then
    raise warning 'payout alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists payouts_z_staff_alert on payouts;
create trigger payouts_z_staff_alert after update of status on payouts for each row
  when (new.status = 'paid' and old.status is distinct from 'paid') execute function app.sa_payout();

-- ================================================================ 5. field work: the handover checklist
create or replace function app.sa_condition_report() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_miss text[] := '{}';
begin
  begin
    if new.completed_at is null or (tg_op = 'UPDATE' and old.completed_at is not null) or new.kind not in ('pickup', 'return') then return null; end if;
    select * into b from bookings where id = new.booking_id;
    if not app.sa_booking_ok(b) then return null; end if;
    if coalesce(new.details_pending, false) then v_miss := v_miss || 'details still to fill in'::text; end if;
    if new.kind = 'pickup' and not coalesce(new.licence_seen, false) then v_miss := v_miss || 'licence not seen'::text; end if;
    if new.kind = 'pickup' and not coalesce(new.card_seen, false) then v_miss := v_miss || 'card not seen'::text; end if;
    if new.renter_signed_at is null and not coalesce(new.renter_declined_to_sign, false) and coalesce(new.renter_present, true) then v_miss := v_miss || 'renter did not sign'::text; end if;
    if new.fuel_pct is null then v_miss := v_miss || 'no fuel level'::text; end if;
    if new.odometer_km is null then v_miss := v_miss || 'no km'::text; end if;
    if cardinality(v_miss) = 0 then return null; end if;
    perform app.staff_alert('handover_checklist_incomplete', 'condition_report', new.id, new.kind,
      'Checklist incomplete (' || new.kind || '): ' || app.sa_booking_line(b), initcap(left(array_to_string(v_miss, ', '), 1)) || substr(array_to_string(v_miss, ', '), 2) || '.',
      app.sa_booking_paths(b));
  exception when others then
    raise warning 'checklist alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists condition_reports_z_staff_alert on condition_reports;
create trigger condition_reports_z_staff_alert after insert or update of completed_at on condition_reports for each row execute function app.sa_condition_report();

-- ================================================================ 6. customers: complaint words, unsubscribes
create or replace function app.sa_complaint_match(p_text text) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  w text;
begin
  foreach w in array regexp_split_to_array(lower((app.settings()).alert_complaint_words), '\s*,\s*') loop
    w := btrim(w);
    if length(w) >= 3 and lower(coalesce(p_text, '')) ~ ('\m' || regexp_replace(w, '([.^$*+?()\[\]{}|\\])', '\\\1', 'g') || '\M') then return w; end if;
  end loop;
  return null;
end $$;

create or replace function app.sa_chat_complaint() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  c chat_conversations;
  v_word text;
begin
  begin
    v_word := app.sa_complaint_match(new.body);
    if v_word is null then return null; end if;
    select * into c from chat_conversations where id = new.conversation_id;
    if c.id is null or app.email_is_test(c.email) or (c.user_id is not null and app.staff_is_test(c.user_id)) then return null; end if;
    perform app.staff_alert('complaint_keyword', 'chat', c.id, app.local_date(new.at)::text, 'Complaint words in chat: "' || v_word || '"',
      coalesce(nullif(c.name, ''), 'A visitor') || ': ' || left(new.body, 180),
      jsonb_build_object('path_admin', '/admin/chat?c=' || c.number, 'path_staff', '/staff/chat?c=' || c.number, 'assigned_to', c.assigned_to,
                         'call', nullif(regexp_replace(coalesce(c.phone, ''), '[^0-9+]', '', 'g'), '')));
  exception when others then
    raise warning 'complaint alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists chat_messages_z_staff_alert on chat_messages;
create trigger chat_messages_z_staff_alert after insert on chat_messages for each row when (new.sender = 'visitor') execute function app.sa_chat_complaint();

create or replace function app.sa_message_complaint() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_word text;
begin
  begin
    v_word := app.sa_complaint_match(coalesce(new.subject, '') || ' ' || coalesce(new.body, ''));
    if v_word is null or app.email_is_test(new.from_address) then return null; end if;
    perform app.staff_alert('complaint_keyword', 'message', coalesce(new.renter_id, new.owner_id, new.id), app.local_date(coalesce(new.occurred_at, new.created_at))::text,
      'Complaint words in a ' || case new.channel when 'sms' then 'text' else new.channel end || ': "' || v_word || '"',
      left(coalesce(nullif(new.subject, ''), new.body, ''), 200),
      case when new.booking_id is not null then (select app.sa_booking_paths(b) from bookings b where b.id = new.booking_id)
           else jsonb_build_object('path_admin', '/admin/messages', 'path_staff', '/staff/messages') end);
  exception when others then
    raise warning 'complaint alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists messages_z_staff_alert on messages;
create trigger messages_z_staff_alert after insert on messages for each row when (new.direction = 'inbound') execute function app.sa_message_complaint();

create or replace function app.sa_opt_out() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    if tg_table_name = 'email_suppressions' then
      if new.reason not in ('unsubscribe', 'complaint') or app.email_is_test(new.email) then return null; end if;
      perform app.staff_alert('opt_out', 'email_suppression', new.id, new.reason,
        case new.reason when 'complaint' then 'Marked our email as spam' else 'Unsubscribed from ' || case new.scope when 'marketing' then 'marketing emails' else 'all emails' end end,
        'An email address was added to the do-not-send list.', jsonb_build_object('path_admin', '/admin/logs?tab=blocked'));
    else
      if new.action <> 'stop' then return null; end if;
      perform app.staff_alert('opt_out', 'sms_opt_out', null, 'stop:' || new.id, 'Texted STOP', 'A phone number asked for no more texts.',
        jsonb_build_object('path_admin', '/admin/messages'));
    end if;
  exception when others then
    raise warning 'opt-out alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists email_suppressions_z_staff_alert on email_suppressions;
create trigger email_suppressions_z_staff_alert after insert on email_suppressions for each row execute function app.sa_opt_out();
drop trigger if exists sms_opt_out_log_z_staff_alert on sms_opt_out_log;
create trigger sms_opt_out_log_z_staff_alert after insert on sms_opt_out_log for each row execute function app.sa_opt_out();

-- ================================================================ 7. documents
create or replace function app.sa_licence_upload() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare b bookings;
begin
  begin
    select * into b from bookings where id = new.booking_id;
    if not app.sa_booking_ok(b) then return null; end if;
    perform app.staff_alert('licence_review', 'verification_upload', new.id, 'new', 'Licence to review: ' || app.sa_booking_line(b),
      'Pickup ' || app.fmt_at(b.pickup_at), app.sa_booking_paths(b) || jsonb_build_object('path_admin', '/admin/bookings/' || b.booking_number || '?tab=documents'));
  exception when others then
    raise warning 'licence alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists verification_uploads_z_staff_alert on verification_uploads;
create trigger verification_uploads_z_staff_alert after insert on verification_uploads for each row
  when (new.kind = 'licence_front' and new.status = 'submitted') execute function app.sa_licence_upload();

create or replace function app.sa_agreement_signed() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare b bookings;
begin
  begin
    select * into b from bookings where id = new.booking_id;
    if not app.sa_booking_ok(b) then return null; end if;
    perform app.staff_alert('agreement_signed', 'rental_agreement', new.id, 'signed', 'Agreement signed: ' || app.sa_booking_line(b),
      'Pickup ' || app.fmt_at(b.pickup_at), app.sa_booking_paths(b));
  exception when others then
    raise warning 'agreement alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists rental_agreements_z_staff_alert on rental_agreements;
create trigger rental_agreements_z_staff_alert after update of renter_signed_at on rental_agreements for each row
  when (new.renter_signed_at is not null and old.renter_signed_at is null) execute function app.sa_agreement_signed();

-- ================================================================ 8. fleet and cars
create or replace function app.sa_service_due() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    if new.status not in ('due_soon', 'overdue') then return null; end if;
    if app.subject_is_test(p_vehicle => new.vehicle_id) then return null; end if;
    perform app.staff_alert('maintenance_due', 'vehicle', new.vehicle_id, new.item_code || ':' || new.status || ':' || coalesce(new.next_due_on::text, ''),
      case new.status when 'overdue' then 'Overdue: ' else 'Due soon: ' end || replace(new.item_code, '_', ' ') || ', ' || coalesce(app.vehicle_name(new.vehicle_id), 'a car'),
      coalesce('Due ' || to_char(new.next_due_on, 'Mon FMDD'), '') || coalesce(' or at ' || new.next_due_km || ' km', ''),
      jsonb_build_object('path_admin', '/admin/maintenance', 'path_staff', '/staff/maintenance'));
  exception when others then
    raise warning 'service alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists vehicle_service_items_z_staff_alert on vehicle_service_items;
create trigger vehicle_service_items_z_staff_alert after insert or update of status on vehicle_service_items for each row execute function app.sa_service_due();

create or replace function app.sa_listing_off() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    if app.subject_is_test(p_vehicle => new.vehicle_id) then return null; end if;
    perform app.staff_alert('car_unpublished', 'vehicle', new.vehicle_id, new.status || ':' || to_char(now(), 'YYYYMMDDHH24MI'),
      case new.status when 'paused' then 'Car paused: ' else 'Car unpublished: ' end || coalesce(app.vehicle_name(new.vehicle_id), 'a car'),
      coalesce(nullif(new.unpublished_reason, ''), 'No reason given.'), jsonb_build_object('path_admin', '/admin/vehicles/' || new.vehicle_id || '?tab=listing'));
  exception when others then
    raise warning 'listing alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists vehicle_listings_z_staff_alert on vehicle_listings;
create trigger vehicle_listings_z_staff_alert after update of status on vehicle_listings for each row
  when (old.status = 'published' and new.status in ('paused', 'unpublished')) execute function app.sa_listing_off();

-- ================================================================ 9. owners
create or replace function app.sa_owner_exit() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v_owner uuid;
begin
  begin
    select v.owner_id into v_owner from vehicles v where v.id = new.vehicle_id;
    if app.sa_owner_test(v_owner) then return null; end if;
    perform app.staff_alert('owner_notice', 'vehicle_exit', new.id, 'notice', 'Owner gave notice: ' || coalesce(app.vehicle_name(new.vehicle_id), 'a car'),
      coalesce('Notice ends ' || to_char(new.notice_ends_on, 'Mon FMDD, YYYY') || '. ', '') || coalesce(nullif(left(new.reason, 140), ''), ''),
      jsonb_build_object('path_admin', '/admin/vehicles/' || new.vehicle_id));
  exception when others then
    raise warning 'owner notice alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists vehicle_exits_z_staff_alert on vehicle_exits;
create trigger vehicle_exits_z_staff_alert after insert on vehicle_exits for each row when (new.initiated_by = 'owner') execute function app.sa_owner_exit();

create or replace function app.sa_owner_banking() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    if app.sa_owner_test(new.owner_id) then return null; end if;
    -- the first account is the set-up, not a change
    if not exists (select 1 from owner_payout_accounts a where a.owner_id = new.owner_id and a.id <> new.id) then return null; end if;
    perform app.staff_alert('owner_banking_changed', 'owner_payout_account', new.id, 'new',
      'Owner banking changed: ' || coalesce((select coalesce(o.corporation_name, o.legal_name) from owners o where o.id = new.owner_id), 'an owner'),
      case new.method when 'e_transfer' then 'Now paid by e-Transfer.' else 'New account ending ' || coalesce(new.account_last4, '????') || '.' end || ' Confirm with the owner by phone before the next payout.',
      jsonb_build_object('path_admin', '/admin/owners/' || new.owner_id));
  exception when others then
    raise warning 'banking alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists owner_payout_accounts_z_staff_alert on owner_payout_accounts;
create trigger owner_payout_accounts_z_staff_alert after insert on owner_payout_accounts for each row execute function app.sa_owner_banking();

-- ================================================================ 10. hiring
create or replace function app.sa_interview_expired() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare a job_applications;
begin
  begin
    select * into a from job_applications where id = new.application_id;
    if a.id is null or app.email_is_test(a.email) then return null; end if;
    perform app.staff_alert('interview_expired', 'job_application', a.id, 'expired:' || coalesce(new.links_sent, 0), 'Interview link expired: ' || coalesce(a.full_name, 'an applicant'),
      'They did not finish the AI interview in time. Send a new link or decide.', jsonb_build_object('path_admin', '/admin/hiring'));
  exception when others then
    raise warning 'interview expired alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists ai_interviews_z_staff_alert_expired on ai_interviews;
create trigger ai_interviews_z_staff_alert_expired after update of state on ai_interviews for each row
  when (new.state = 'expired' and old.state is distinct from 'expired') execute function app.sa_interview_expired();

create or replace function app.sa_applicant_hired() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    if app.email_is_test(new.email) then return null; end if;
    perform app.staff_alert('applicant_hired', 'job_application', new.id, 'hired', 'Offer accepted: ' || coalesce(new.full_name, 'an applicant'),
      'Their staff account is ready. Set their function and first day.', jsonb_build_object('path_admin', '/admin/hiring'));
  exception when others then
    raise warning 'hired alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists job_applications_z_staff_alert_hired on job_applications;
create trigger job_applications_z_staff_alert_hired after update of status on job_applications for each row
  when (new.status = 'hired' and old.status is distinct from 'hired') execute function app.sa_applicant_hired();

-- ================================================================ 11. the academy
create or replace function app.sa_academy_lesson() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare u users;
begin
  begin
    select * into u from users where id = new.user_id;
    if u.id is null or app.staff_is_test(u.id) then return null; end if;
    perform app.staff_alert('academy_lesson', 'academy_lesson', new.lesson_id, u.id::text, 'Lesson finished: ' || coalesce(u.full_name, 'a staff member'),
      coalesce((select l.title from academy_lessons l where l.id = new.lesson_id), 'a lesson'), jsonb_build_object('path_admin', '/admin/academy'));
  exception when others then
    raise warning 'lesson alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists academy_lesson_views_z_staff_alert on academy_lesson_views;
create trigger academy_lesson_views_z_staff_alert after insert on academy_lesson_views for each row execute function app.sa_academy_lesson();

create or replace function app.sa_academy_more() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  u users;
  v_fails integer;
  p record;
begin
  begin
    select * into u from users where id = new.user_id;
    if u.id is null or app.staff_is_test(u.id) then return null; end if;
    if not new.passed then
      select count(*) into v_fails from academy_attempts a where a.user_id = new.user_id and a.section_id = new.section_id and not a.passed;
      if v_fails = 2 then
        perform app.staff_alert('academy_quiz_failed_twice', 'academy_attempt', new.id, 'twice', 'Quiz failed twice: ' || coalesce(u.full_name, 'a staff member'),
          coalesce((select s.title from academy_sections s where s.id = new.section_id), 'a section') || '. A short call may help.', jsonb_build_object('path_admin', '/admin/academy'));
      end if;
      return null;
    end if;
    -- certified: every section of a path holding this section is passed
    for p in select ap.code, ap.title from academy_paths ap
              where exists (select 1 from academy_path_sections ps where ps.path_code = ap.code and ps.section_id = new.section_id)
                and not exists (select 1 from academy_path_sections ps where ps.path_code = ap.code
                                   and not exists (select 1 from academy_attempts a where a.user_id = new.user_id and a.section_id = ps.section_id and a.passed)) loop
      perform app.staff_alert('academy_certified', 'user', u.id, 'path:' || p.code, 'Certified: ' || coalesce(u.full_name, 'a staff member'),
        'Passed every section of ' || p.title || '.', jsonb_build_object('path_admin', '/admin/academy'));
    end loop;
  exception when others then
    raise warning 'academy alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists academy_attempts_z_staff_alert_more on academy_attempts;
create trigger academy_attempts_z_staff_alert_more after insert on academy_attempts for each row execute function app.sa_academy_more();

-- ================================================================ 12. the scheduled checks (called every 5 minutes by app.job_staff_alerts, 0466)
create or replace function app.sa_scheduled(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  bk bookings;
  n integer := 0;
  v_hour integer := app.local_hour(p_now);
  v_today date := app.local_date(p_now);
  v_min integer := extract(hour from (p_now at time zone 'America/Toronto'))::integer * 60 + extract(minute from (p_now at time zone 'America/Toronto'))::integer;
  v_sum bigint; v_best bigint; v_cnt integer; v_days integer;
  v_m0 date; v_m1 date;
begin
  -- agreement not signed 2 hours before pickup
  for bk in select b.* from bookings b where b.status = 'confirmed' and b.pickup_at > p_now and b.pickup_at <= p_now + interval '2 hours'
              and not exists (select 1 from rental_agreements a where a.booking_id = b.id and (a.renter_signed_at is not null or a.status in ('signed', 'completed')))
              and not exists (select 1 from signature_requests s where s.id = b.signature_request_id and s.status = 'completed') loop
    if app.sa_booking_ok(bk) and app.staff_alert('agreement_unsigned_pickup', 'booking', bk.id, 'unsigned', 'Agreement not signed: ' || app.sa_booking_line(bk),
         'Pickup ' || app.fmt_at(bk.pickup_at) || '. Send the signing link again or sign in person.', app.sa_booking_paths(bk) || jsonb_build_object('call', app.sa_phone(bk))) is not null then n := n + 1; end if;
  end loop;
  -- proof of insurance missing 24 hours before pickup
  for bk in select b.* from bookings b where b.status = 'confirmed' and b.pickup_at > p_now and b.pickup_at <= p_now + interval '24 hours'
              and b.coverage_confirmed_at is null and b.insurer_id is null loop
    if app.sa_booking_ok(bk) and app.staff_alert('insurance_missing', 'booking', bk.id, 'missing', 'Insurance proof missing: ' || app.sa_booking_line(bk),
         'Pickup ' || app.fmt_at(bk.pickup_at) || '.', app.sa_booking_paths(bk) || jsonb_build_object('call', app.sa_phone(bk))) is not null then n := n + 1; end if;
  end loop;
  -- insurer booking with no claim number 24 hours before pickup
  for bk in select b.* from bookings b where b.status in ('confirmed', 'pending_payment') and b.insurer_id is not null and nullif(btrim(b.insurer_claim_number), '') is null
              and b.pickup_at > p_now and b.pickup_at <= p_now + interval '24 hours' loop
    if app.sa_booking_ok(bk) and app.staff_alert('insurer_claim_missing', 'booking', bk.id, 'claim', 'No claim number: ' || app.sa_booking_line(bk),
         'Pickup ' || app.fmt_at(bk.pickup_at) || '. Ask the adjuster for it.', app.sa_booking_paths(bk)) is not null then n := n + 1; end if;
  end loop;
  -- Sales late for their block, or idle for 2 hours inside it
  for r in select a.*, u.full_name, cp.last_seen_at from sales_availability a join users u on u.id = a.staff_id and u.status = 'active'
             left join chat_staff_prefs cp on cp.user_id = a.staff_id
            where a.day = v_today and a.from_minute <= v_min - 15 and a.until_minute > v_min and not app.staff_is_test(a.staff_id) loop
    if r.last_seen_at is null or r.last_seen_at < (v_today::timestamp + make_interval(mins => r.from_minute)) at time zone 'America/Toronto' then
      if app.staff_alert('staff_late', 'user', r.staff_id, v_today || ':' || r.from_minute, 'Not started: ' || coalesce(r.full_name, 'a Sales rep'),
           format('Their block started at %s:%s.', r.from_minute / 60, lpad((r.from_minute % 60)::text, 2, '0')), jsonb_build_object('path_admin', '/admin/staff')) is not null then n := n + 1; end if;
    elsif r.from_minute <= v_min - 120 and r.last_seen_at < p_now - interval '2 hours' then
      if app.staff_alert('staff_idle', 'user', r.staff_id, v_today || ':' || r.from_minute, 'Idle for 2 hours: ' || coalesce(r.full_name, 'a Sales rep'),
           'Inside their availability block and no visit to the portal since ' || app.fmt_at(r.last_seen_at) || '.', jsonb_build_object('path_admin', '/admin/staff')) is not null then n := n + 1; end if;
    end if;
  end loop;
  -- wins at 21:00: a record day (and on Sunday a record week) of payments received
  if v_hour = 21 then
    select coalesce(sum(p.amount_cents), 0) into v_sum from payments p where p.status = 'succeeded' and p.kind in ('charge', 'capture') and app.local_date(p.created_at) = v_today;
    select coalesce(max(d.s), 0), count(*) into v_best, v_days from (select app.local_date(p.created_at) d0, sum(p.amount_cents) s from payments p
       where p.status = 'succeeded' and p.kind in ('charge', 'capture') and p.created_at >= p_now - interval '366 days' and app.local_date(p.created_at) < v_today group by 1) d;
    if v_sum > v_best and v_best > 0 and v_days >= 7 then
      if app.staff_alert('win_record_day', 'brief', null, 'day:' || v_today, 'Record day: ' || app.fmt_money(v_sum) || ' received',
           'The best day before was ' || app.fmt_money(v_best) || '.', jsonb_build_object('path_admin', '/admin/payments')) is not null then n := n + 1; end if;
    end if;
    if extract(isodow from v_today) = 7 then
      select coalesce(sum(p.amount_cents), 0) into v_sum from payments p where p.status = 'succeeded' and p.kind in ('charge', 'capture')
         and app.local_date(p.created_at) between v_today - 6 and v_today;
      select coalesce(max(w.s), 0), count(*) into v_best, v_days from (select date_trunc('week', app.local_date(p.created_at)) w0, sum(p.amount_cents) s from payments p
         where p.status = 'succeeded' and p.kind in ('charge', 'capture') and p.created_at >= p_now - interval '371 days' and app.local_date(p.created_at) < v_today - 6 group by 1) w;
      if v_sum > v_best and v_best > 0 and v_days >= 4 then
        if app.staff_alert('win_record_day', 'brief', null, 'week:' || v_today, 'Record week: ' || app.fmt_money(v_sum) || ' received',
             'The best week before was ' || app.fmt_money(v_best) || '.', jsonb_build_object('path_admin', '/admin/payments')) is not null then n := n + 1; end if;
      end if;
    end if;
  end if;
  -- the month's totals on the 1st at 8:00
  if v_hour = 8 and extract(day from v_today) = 1 then
    v_m1 := v_today; v_m0 := (v_today - interval '1 month')::date;
    select coalesce(sum(p.amount_cents), 0), count(*) into v_sum, v_cnt from payments p where p.status = 'succeeded' and p.kind in ('charge', 'capture')
       and app.local_date(p.created_at) >= v_m0 and app.local_date(p.created_at) < v_m1;
    select count(*) into v_days from bookings b where not coalesce(b.is_placeholder, false) and b.booking_type <> 'owner'
       and b.status in ('confirmed', 'on_rent', 'returned', 'closed') and app.local_date(b.pickup_at) >= v_m0 and app.local_date(b.pickup_at) < v_m1;
    if app.staff_alert('win_month_totals', 'brief', null, 'month:' || v_m0, to_char(v_m0, 'FMMonth') || ': ' || app.fmt_money(v_sum) || ' received',
         format('%s payments, %s rentals started.', v_cnt, v_days), jsonb_build_object('path_admin', '/admin/reports')) is not null then n := n + 1; end if;
  end if;
  return n;
end $$;

-- ================================================================ 13. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['sa_booking_ok', 'sa_phone', 'sa_owner_test', 'sa_booking_alert', 'sa_booking_return', 'sa_offer_viewed',
              'sa_offer_answer', 'sa_extension', 'sa_change_request', 'sa_deposit', 'sa_card_declined', 'sa_owner_debit', 'sa_investor_test', 'sa_investment',
              'sa_investor_signed', 'sa_payout', 'sa_condition_report', 'sa_complaint_match', 'sa_chat_complaint', 'sa_message_complaint', 'sa_opt_out',
              'sa_licence_upload', 'sa_agreement_signed', 'sa_service_due', 'sa_listing_off', 'sa_owner_exit', 'sa_owner_banking', 'sa_interview_expired',
              'sa_applicant_hired', 'sa_academy_lesson', 'sa_academy_more', 'sa_scheduled', 'sa_interview', 'sa_account_deletion', 'sa_academy_attempt'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
