-- 2540: change a booking's damage protection in one step, for staff and for the renter (Release 41;
-- docs/changes/2026-11-12-r41-protection.md). The owner: "Changing insurance protection options for renters became very easy
-- for staff and admin to do right? If you have [not] simplified that process then please do. And also simplify it for allowing
-- renters themselves to change it." No applied migration is edited.
--
-- 1. app.protection_block(booking, to, side): the one set of rules for both paths (staff and renter). The r35 switch
--    (app.coverage_switch_block, 0890) now asks it too, so a rule changes in one place.
--      everyone: not an Owner Booking, not billed to an insurer, not a car with insurance included, not the option it has,
--                not after damage was reported on the booking (an accident, theft, vandalism or damage incident), the
--                Protection Plan has a price, card coverage only on a credit card in the renter's name.
--      staff:    a request, an offer, a confirmed booking or a rental in progress (0890).
--      renter:   once the offer is approved (pending payment, confirmed) and during the rental; their own insurance or card
--                coverage only while the documents are open (before pickup: app.booking_docs_open, as 0071/0072), so during
--                the rental only the Protection Plan; one request in review at a time.
-- 2. app.protection_change(by, {booking, to: 1|2|3, reason, notify}): staff choose any of the three options with a reason
--    (required, kept in the history and the audit log). It reprices through the r35 switch (a balance to collect or a refund
--    for approval: no money moves by itself), the agreement shows a new version when the rules ask for one (rental terms 15.4,
--    app.agreement_plan), the renter is told once (the revised offer, or renter_coverage_switched).
-- 3. app.renter_protection_change(by, {booking, to, ...}): the renter's own change. To the Protection Plan: at once, the
--    difference is a balance the renter pays on the booking page. Between their own insurance and card coverage (before
--    pickup): at once, as 0071 allowed. Away from the Protection Plan: a request with the proof (a file) that customer service
--    reviews (task protection_change_review); app.protection_review approves (the change is made and the coverage confirmed)
--    or declines with a reason. The renter can withdraw it.
-- 4. app.protection_options: what the dialog shows for each option (price difference, the plan a day, deposit, what to send).
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

-- ================================================================ 1. the records
alter table coverage_switches drop constraint if exists coverage_switches_direction_check;
alter table coverage_switches add constraint coverage_switches_direction_check check (direction in ('to_plan', 'to_card', 'to_own'));
alter table coverage_switches
  add column if not exists side text not null default 'staff' check (side in ('staff', 'renter')),
  add column if not exists request_id uuid;
comment on column coverage_switches.side is 'Who made the change (2540): staff on the booking page, or the renter on their booking page.';

create table protection_requests (
  id              uuid primary key default gen_random_uuid(),
  booking_id      uuid not null references bookings (id),
  from_option     smallint not null check (from_option in (1, 2, 3)),
  to_option       smallint not null check (to_option in (1, 2)),
  status          text not null default 'pending' check (status in ('pending', 'approved', 'declined', 'withdrawn', 'superseded')),
  reason          text check (char_length(reason) <= 500),
  insurer_name    text check (char_length(insurer_name) <= 120),
  policy_number   text check (char_length(policy_number) <= 60),
  policy_expiry   date,
  proof_bucket    text not null default 'documents',
  proof_path      text not null check (char_length(proof_path) <= 300),
  proof_mime      text,
  proof_sha256    text,
  task_id         uuid references tasks (id) on delete set null,
  switch_id       uuid references coverage_switches (id),
  decided_by      uuid references users (id) on delete set null,
  decided_at      timestamptz,
  decision_note   text check (char_length(decision_note) <= 500),
  created_by      uuid references users (id) on delete set null,
  created_at      timestamptz not null default now()
);
create index protection_requests_booking on protection_requests (booking_id, created_at desc);
create unique index protection_requests_one_pending on protection_requests (booking_id) where status = 'pending';
-- the other join paths (a task or switch deleted, a user's account deleted: set null) look these up
create index protection_requests_task on protection_requests (task_id) where task_id is not null;
create index protection_requests_switch on protection_requests (switch_id) where switch_id is not null;
create index protection_requests_decided_by on protection_requests (decided_by) where decided_by is not null;
create index protection_requests_created_by on protection_requests (created_by) where created_by is not null;
alter table protection_requests enable row level security;
create policy admin_all on protection_requests for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_protection_requests after insert or update or delete on protection_requests for each row execute function app.audit_row();
comment on table protection_requests is 'A renter asks to leave the Protection Plan for their own insurance or card coverage, with the proof; customer service reviews it before it takes effect (2540).';

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('protection_change_review', 'cs', 'The renter asks to leave the Protection Plan', 'high', 'opening_minutes', 120, 2, null,
   'The renter sent proof of their own insurance or of their card''s rental coverage and asks to leave the Protection Plan. Open the booking, check the proof under Protection, then Approve (the change is made and the coverage confirmed) or Decline with the reason.')
on conflict (task_type) do nothing;

-- ================================================================ 2. the rules (one function, both paths)
create function app.protection_block(b bookings, p_to integer, p_side text default 'staff') returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_check jsonb;
  v_inc text;
  v_status text := b.status::text;
begin
  if b.id is null then return 'Booking not found'; end if;
  if p_to is null or p_to not in (1, 2, 3) then return 'Choose own insurance (OPCF 27), credit card coverage or the Protection Plan'; end if;
  if b.booking_type = 'owner' then return 'An Owner Booking needs no coverage'; end if;
  if b.bill_to <> 'renter' or b.dates_provisional then return 'A booking billed to an insurer has its coverage from the insurer'; end if;
  if coalesce(p_side, 'staff') = 'renter' then
    if v_status in ('requested', 'offered') then return 'You choose your protection when you approve the offer. To change it before then, message us.'; end if;
    if v_status not in ('pending_payment', 'confirmed', 'on_rent') then
      return format('Booking %s is %s: protection is changed before the car is returned', b.booking_number, replace(v_status, '_', ' '));
    end if;
  elsif v_status not in ('requested', 'offered', 'pending_payment', 'confirmed', 'on_rent') then
    return format('Booking %s is %s: the coverage is switched on a request, an offer, a confirmed booking or a rental in progress', b.booking_number, replace(v_status, '_', ' '));
  end if;
  if b.coverage_option = 4 then return 'This car has coverage included: there is nothing to switch'; end if;
  if b.coverage_option = p_to then
    return case when p_to = 3 then 'This booking is on the Protection Plan already' else format('This booking is on %s already', app.coverage_option_label(p_to)) end;
  end if;
  select i.incident_number into v_inc from incidents i
   where i.booking_id = b.id and i.kind in ('accident', 'theft', 'vandalism', 'damage_at_return', 'damage_found_later')
   order by i.reported_at limit 1;
  if v_inc is not null then
    return format('Damage was reported on this booking (%s): the protection stays as it was when it happened', v_inc);
  end if;
  if coalesce(p_side, 'staff') = 'renter' then
    if p_to in (1, 2) and not app.booking_docs_open(b) then
      return 'Your rental has started: you can still add the Protection Plan, but your own insurance or card coverage is set before pickup';
    end if;
    if exists (select 1 from protection_requests r where r.booking_id = b.id and r.status = 'pending') then
      return 'Your earlier change is waiting for our review. Withdraw it first to ask for another.';
    end if;
  end if;
  if p_to = 3 then
    if coalesce((select t.amount_cents from app.fee_term('coverage_sold', b.vehicle_id, app.local_date(coalesce(b.booked_at, now())), b.id) t), 0) <= 0 then
      return 'The Protection Plan has no price for this car yet: an Admin sets it under Settings > Fees first';
    end if;
  elsif p_to = 2 then
    v_check := app.card_coverage_check(b.id);
    if v_check ->> 'problem' in ('not_credit', 'name_mismatch') then return v_check ->> 'message'; end if;
  end if;
  return null;
end $$;

-- the r35 switch asks the same rules (staff, or the renter's path through app.protection_change)
create or replace function app.coverage_switch_block(b bookings, p_to text) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_side text := coalesce(nullif(current_setting('app.protection_side', true), ''), 'staff');
  v_target integer;
begin
  if b.id is null then return 'Booking not found'; end if;
  if p_to not in ('plan', 'card') then return 'Choose the Protection Plan or card coverage'; end if;
  if p_to = 'plan' then return app.protection_block(b, 3, v_side); end if;
  if b.coverage_option is distinct from 3 then
    return 'This booking is not on the Protection Plan';
  end if;
  v_target := coalesce(nullif(current_setting('app.protection_target', true), '')::integer,
    (select case when c.from_option in (1, 2) then c.from_option else 2 end from coverage_switches c
      where c.booking_id = b.id and c.direction = 'to_plan' order by c.created_at desc limit 1), 2);
  return app.protection_block(b, v_target, v_side);
end $$;

-- the renter's own change goes through the same switch, only after app.renter_protection_change checked it is theirs
create or replace function app.coverage_switch_who(p_by uuid, p_status text) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when p_by is null then 'Sign in first'
    when nullif(current_setting('app.protection_renter', true), '') = p_by::text then null
    when app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet') then null
    when app.user_va_has(p_by, 'sales') then case when p_status in ('requested', 'offered') then null
         else 'Sales switches the coverage of a request or an offer. Customer service, fleet or an Admin switches a booking that is paid or confirmed' end
    else 'Only an Admin, customer service, sales or fleet switches the coverage of a booking' end
$$;

-- ================================================================ 3. between the renter's own insurance and card coverage
create function app.protection_own_switch(p_booking uuid, p_to integer, p_by uuid, p_reason text, p_side text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_lapsed jsonb;
  v_uploads jsonb;
  v_id uuid;
begin
  select * into b from bookings where id = p_booking for update;
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'status', c.status)), '[]'::jsonb) into v_lapsed
    from coverage_proofs c where c.booking_id = b.id and c.status in ('submitted', 'confirmed');
  select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'status', u.status)), '[]'::jsonb) into v_uploads
    from verification_uploads u where u.booking_id = b.id and u.kind = 'coverage_proof' and u.status in ('submitted', 'approved');
  update coverage_proofs set status = 'lapsed' where booking_id = b.id and status in ('submitted', 'confirmed');
  update verification_uploads set status = 'replaced' where booking_id = b.id and kind = 'coverage_proof' and status in ('submitted', 'approved');
  update bookings set coverage_option = p_to, coverage_confirmed_at = null where id = b.id;
  update tasks t set status = 'cancelled', completed_at = now(), completed_by = p_by, completion_note = 'The coverage option changed: the earlier proof is not needed'
   where t.booking_id = b.id and t.status in ('open', 'in_progress', 'waiting') and (t.task_type = 'coverage_review' or t.related_table = 'coverage_proofs');
  if p_side = 'staff' and b.status::text in ('pending_payment', 'confirmed', 'on_rent') then
    perform app.raise_task(p_type => 'coverage_proof_needed',
      p_title => format('Booking %s: get the renter''s %s', b.booking_number, case when p_to = 1 then 'OPCF 27 proof' else 'card coverage proof' end),
      p_detail => 'Staff changed the coverage option. The renter confirms their coverage on the booking page (Coverage); review it when it arrives.',
      p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id,
      p_due_at => least(greatest(b.pickup_at - interval '24 hours', now() + interval '1 hour'), now() + interval '24 hours'),
      p_dedupe => 'coverage_proof_needed:' || b.id, p_created_by => p_by);
  end if;
  insert into coverage_switches (booking_id, direction, from_option, to_option, booking_status, total_before_cents, total_after_cents, plan_cents, note,
                                 lapsed_proofs, lapsed_uploads, prev_confirmed_at, created_by, side)
  values (b.id, 'to_own', b.coverage_option, p_to, b.status::text, b.total_due_at_booking_cents, b.total_due_at_booking_cents, 0, p_reason,
          v_lapsed, v_uploads, b.coverage_confirmed_at, p_by, coalesce(p_side, 'staff'))
  returning id into v_id;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
    format('Coverage changed from %s to %s%s', app.coverage_option_label(b.coverage_option), app.coverage_option_label(p_to), coalesce(' (' || p_reason || ')', '')),
    p_by, coalesce(p_side, 'staff'),
    jsonb_build_object('coverage_switch', v_id, 'direction', 'to_own', 'coverage_option_from', b.coverage_option, 'coverage_option_to', p_to));
  return v_id;
end $$;

-- ================================================================ 4. the one change (staff; the renter's direct changes and approvals run it too)
create function app.protection_change(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  b bookings;
  v_to integer := nullif(btrim(coalesce(p_ ->> 'to', '')), '')::integer;
  v_reason text := nullif(left(btrim(coalesce(p_ ->> 'reason', p_ ->> 'note', '')), 500), '');
  v_notify boolean := coalesce((p_ ->> 'notify')::boolean, true);
  v_side text := coalesce(nullif(current_setting('app.protection_side', true), ''), 'staff');
  v_why text;
  v_from smallint;
  v_status text;
  v_offer boolean;
  v_total0 bigint;
  v_default integer;
  v_switch uuid;
  v_version integer;
  v_land boolean := false;
  r jsonb := '{}'::jsonb;
  v_args jsonb;
begin
  select * into b from bookings where id::text = p_ ->> 'booking' or booking_number = upper(btrim(coalesce(p_ ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v_side = 'staff' then
    v_why := app.coverage_switch_who(p_by, b.status::text);
    if v_why is not null then raise exception '%', v_why using errcode = '42501'; end if;
    if v_reason is null or char_length(v_reason) < 3 then
      raise exception 'Give the reason for the change: the renter reads it and it stays in the booking history' using errcode = '22023';
    end if;
  end if;
  v_why := app.protection_block(b, v_to, v_side);
  if v_why is not null then raise exception '%', v_why using errcode = '23514'; end if;
  v_from := b.coverage_option;
  v_status := b.status::text;
  v_total0 := b.total_due_at_booking_cents;
  v_offer := v_status in ('offered', 'pending_payment');

  -- a renter's request still in review is settled by this change
  update protection_requests q set status = 'superseded', decided_by = p_by, decided_at = now(),
         decision_note = coalesce(q.decision_note, 'Settled by a change on the booking page')
   where q.booking_id = b.id and q.status = 'pending';
  perform app.resolve_tasks(array['protection_change_review'], b.id, p_by, 'Settled by a change of protection on the booking');

  v_args := jsonb_build_object('booking', b.id::text, 'note', v_reason, 'notify', v_notify)
            || case when v_to = 3 and p_ ? 'plan_cents' then jsonb_build_object('plan_cents', p_ -> 'plan_cents') else '{}'::jsonb end;
  if v_to = 3 then
    r := app.coverage_switch(p_by, v_args || jsonb_build_object('to', 'plan'));
    v_switch := (r ->> 'switch_id')::uuid;
  elsif v_from = 3 then
    v_default := coalesce((select case when c.from_option in (1, 2) then c.from_option else 2 end from coverage_switches c
                             where c.booking_id = b.id and c.direction = 'to_plan' order by c.created_at desc limit 1), 2);
    perform set_config('app.protection_target', v_to::text, true);
    v_land := v_to <> v_default;
    r := app.coverage_switch(p_by, v_args || jsonb_build_object('to', 'card', 'notify', v_notify and not v_land));
    perform set_config('app.protection_target', '', true);
    v_switch := (r ->> 'switch_id')::uuid;
    if v_land then
      -- the switch went back to the earlier option: land on the one asked for
      if v_offer then perform set_config('app.offer_revising', 'on', true); perform app.offer_reopen_for_edit(b.id, p_by); end if;
      update coverage_proofs set status = 'lapsed' where booking_id = b.id and status in ('submitted', 'confirmed') and coverage_option <> v_to;
      update bookings set coverage_option = v_to, coverage_confirmed_at = null where id = b.id;
      update coverage_switches set to_option = v_to where id = v_switch;
      update tasks set title = format('Booking %s: get the renter''s %s', b.booking_number, case when v_to = 1 then 'OPCF 27 proof' else 'card coverage proof' end)
       where booking_id = b.id and task_type = 'coverage_proof_needed' and status in ('open', 'in_progress', 'waiting');
    end if;
  else
    -- the renter's own switch keeps the offer as it is (the price does not change; 0071 did the same)
    if v_side = 'renter' then v_offer := false; end if;
    if v_offer then perform set_config('app.offer_revising', 'on', true); perform app.offer_reopen_for_edit(b.id, p_by); end if;
    v_switch := app.protection_own_switch(b.id, v_to, p_by, v_reason, v_side);
    v_land := v_side = 'staff';
  end if;

  -- the renter is told once: the revised offer, or the email of the change
  if v_land then
    if v_offer then
      perform app.offer_channels_begin(v_notify, p_ -> 'channels');
      select * into b from bookings where id = b.id;
      v_version := app.send_offer(b.id, p_by, format('Your coverage is now %s.%s', app.coverage_option_label(v_to), coalesce(' ' || v_reason, '')),
        case when b.offer_expires_at > now() + interval '1 hour' then b.offer_expires_at else now() + make_interval(hours => (app.settings()).offer_expiry_hours) end);
      perform app.offer_channels_end();
      perform set_config('app.offer_revising', '', true);
      update coverage_switches set offer_version = v_version where id = v_switch;
    elsif v_notify and v_status in ('confirmed', 'on_rent') then
      perform app.ntf_emit('renter_coverage_switched', 'booking', b.id, 'switch:' || v_switch, jsonb_build_object('booking_id', b.id, 'switch_id', v_switch));
    end if;
  end if;
  update coverage_switches set side = v_side where id = v_switch and side is distinct from v_side;

  select * into b from bookings where id = b.id;
  return r || jsonb_build_object('ok', true, 'switch_id', v_switch, 'booking_number', b.booking_number, 'from_option', v_from, 'to_option', b.coverage_option,
    'to_label', app.coverage_option_label(b.coverage_option), 'status', b.status, 'was', v_status, 'applied', true,
    'total_before_cents', v_total0, 'total_after_cents', b.total_due_at_booking_cents, 'difference_cents', b.total_due_at_booking_cents - v_total0,
    'open_cents', case when b.status::text in ('confirmed', 'on_rent') then app.booking_part_open(b.id, 'balance') else 0 end,
    'offer_version', coalesce(v_version, (r ->> 'offer_version')::integer),
    'refund_id', (select c.refund_id from coverage_switches c where c.id = v_switch));
end $$;

-- ================================================================ 5. what the dialog shows
create function app.protection_options_of(b bookings, p_side text, p_may boolean, p_why text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_plan jsonb;
  v_plan_amt bigint;
  v_plan_hst bigint;
  v_cur_plan bigint;
  v_opts jsonb := '[]'::jsonb;
  v_change bigint;
  v_block text;
  k integer;
  q protection_requests;
begin
  v_cur_plan := coalesce((select sum(li.amount_cents + li.hst_cents) from booking_line_items li where li.booking_id = b.id and li.charge_type = 'coverage_sold' and li.stage = 'booking' and li.voided_at is null), 0);
  if b.coverage_option = 3 and v_cur_plan > 0 then
    v_plan_amt := (select sum(li.amount_cents) from booking_line_items li where li.booking_id = b.id and li.charge_type = 'coverage_sold' and li.stage = 'booking' and li.voided_at is null);
    v_plan_hst := v_cur_plan - v_plan_amt;
  else
    begin
      v_plan := app.coverage_plan_line(b.id);
    exception when others then v_plan := null;
    end;
    v_plan_amt := (v_plan ->> 'amount_cents')::bigint;
    v_plan_hst := coalesce((v_plan ->> 'hst_cents')::bigint, 0);
  end if;
  foreach k in array array[1, 2, 3] loop
    v_block := case when b.coverage_option = k then null else app.protection_block(b, k, p_side) end;
    v_change := case when b.coverage_option = k then 0
                     when k = 3 then case when v_plan_amt is null then null else v_plan_amt + v_plan_hst end
                     when b.coverage_option = 3 then -v_cur_plan
                     else 0 end;
    v_opts := v_opts || jsonb_build_object(
      'option', k, 'label', app.coverage_option_label(k), 'current', b.coverage_option = k,
      'available', p_may and b.coverage_option is distinct from k and v_block is null, 'problem', case when b.coverage_option = k then null else coalesce(p_why, v_block) end,
      'applies', case when p_side = 'renter' and b.coverage_option = 3 and k in (1, 2) then 'review'
                      when p_side = 'renter' and k = 3 and b.status::text = 'pending_payment' then 'ask' else 'now' end,
      'change_cents', v_change, 'new_total_cents', b.total_due_at_booking_cents + coalesce(v_change, 0),
      'deposit_change_cents', 0,
      'needs', case k
        when 1 then 'Proof of the renter''s own auto policy with the OPCF 27 endorsement: the pink slip and the endorsement page, active past the return date'
        when 2 then 'A credit card in the renter''s name that includes rental car coverage (paid with it), and the card''s coverage letter or benefit page'
        else 'Nothing to send: CarmaCars confirms the Protection Plan' end);
  end loop;
  select * into q from protection_requests r where r.booking_id = b.id order by r.created_at desc limit 1;
  return jsonb_build_object(
    'booking_number', b.booking_number, 'status', b.status, 'option', b.coverage_option, 'option_label', app.coverage_option_label(b.coverage_option),
    'side', p_side, 'may', p_may, 'why_not', p_why, 'days', b.billable_days, 'pickup_at', b.pickup_at,
    'plan_cents', v_plan_amt, 'plan_hst_cents', v_plan_hst,
    'plan_daily_cents', case when v_plan_amt is null then null else round(v_plan_amt::numeric / greatest(b.billable_days, 1))::bigint end,
    'deposit_cents', b.deposit_cents, 'total_cents', b.total_due_at_booking_cents,
    'open_cents', case when b.status::text in ('confirmed', 'on_rent') then app.booking_part_open(b.id, 'balance') else 0 end,
    'options', v_opts,
    'request', case when q.id is null then null else jsonb_build_object('id', q.id, 'status', q.status, 'to_option', q.to_option, 'to_label', app.coverage_option_label(q.to_option),
       'reason', q.reason, 'decision_note', q.decision_note, 'created_at', q.created_at, 'decided_at', q.decided_at,
       'insurer_name', q.insurer_name, 'policy_number', q.policy_number, 'policy_expiry', q.policy_expiry,
       'proof_bucket', case when p_side = 'staff' then q.proof_bucket end, 'proof_path', case when p_side = 'staff' then q.proof_path end, 'proof_mime', q.proof_mime) end,
    'history', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'from_label', app.coverage_option_label(c.from_option), 'to_label', app.coverage_option_label(c.to_option),
       'total_before_cents', c.total_before_cents, 'total_after_cents', c.total_after_cents, 'note', c.note, 'side', c.side,
       'by', case when p_side = 'staff' then (select u.full_name from users u where u.id = c.created_by) end, 'at', c.created_at) order by c.created_at desc)
       from coverage_switches c where c.booking_id = b.id), '[]'::jsonb));
end $$;

create function app.protection_options(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_who text;
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  v_who := app.coverage_switch_who(p_by, b.status::text);
  return app.protection_options_of(b, 'staff', v_who is null, v_who)
    || jsonb_build_object('may_review', app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs'));
end $$;

-- ================================================================ 6. the renter's own change
create function app.renter_protection_change(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  b bookings;
  v_to integer := nullif(btrim(coalesce(p_ ->> 'to', '')), '')::integer;
  v_reason text := nullif(left(btrim(coalesce(p_ ->> 'reason', '')), 500), '');
  v_why text;
  v_out jsonb;
  v_insurer text := nullif(left(btrim(coalesce(p_ ->> 'insurer_name', '')), 120), '');
  v_policy text := nullif(left(btrim(coalesce(p_ ->> 'policy_number', '')), 60), '');
  v_expiry date := nullif(p_ ->> 'policy_expiry', '')::date;
  v_path text := nullif(btrim(coalesce(p_ ->> 'proof_path', '')), '');
  v_check jsonb;
  q protection_requests;
  v_task uuid;
begin
  select * into b from bookings where id::text = p_ ->> 'booking' or booking_number = upper(btrim(coalesce(p_ ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  perform app.assert_booking_renter(b.id, p_by);

  if coalesce((p_ ->> 'withdraw')::boolean, false) then
    update protection_requests set status = 'withdrawn', decided_by = p_by, decided_at = now()
     where booking_id = b.id and status = 'pending' returning * into q;
    if q.id is null then raise exception 'There is no change waiting for review' using errcode = '23514'; end if;
    perform app.resolve_tasks(array['protection_change_review'], b.id, p_by, 'The renter withdrew the request');
    perform app.log_booking_event(b.id, 'verification', b.status::text, b.status::text, null, 'The renter withdrew the request to leave the Protection Plan', p_by, 'renter',
      jsonb_build_object('protection_request', q.id, 'status', 'withdrawn'));
    return jsonb_build_object('ok', true, 'withdrawn', true, 'request_id', q.id);
  end if;

  if not app.rate_limit('protection_change:user:' || p_by, 10, interval '1 day') then
    raise exception 'You changed your protection many times today. Message us and we will help.' using errcode = '54000';
  end if;
  v_why := app.protection_block(b, v_to, 'renter');
  if v_why is not null then raise exception '%', v_why using errcode = '23514'; end if;

  if v_to = 3 and b.status::text = 'pending_payment' then
    -- the offer waits for payment: only staff send it again, so the renter's choice reaches customer service (0071's request)
    return app.request_protection_plan(b.id, p_by, coalesce(v_reason, 'The renter chose the Protection Plan on the booking page'))
      || jsonb_build_object('ok', true, 'applied', false, 'asked', true, 'to_option', 3);
  end if;
  if v_to = 3 or b.coverage_option is distinct from 3 then
    -- the Protection Plan, or between their own insurance and card coverage: at once
    perform set_config('app.protection_side', 'renter', true);
    perform set_config('app.protection_renter', p_by::text, true);
    v_out := app.protection_change(p_by, jsonb_build_object('booking', b.id::text, 'to', v_to, 'reason', coalesce(v_reason, 'Changed by the renter'), 'notify', v_to = 3));
    perform set_config('app.protection_side', '', true);
    perform set_config('app.protection_renter', '', true);
    return v_out;
  end if;

  -- away from the Protection Plan: the proof, then customer service reviews it before it takes effect
  if v_path is null or v_path not like 'renters/' || p_by::text || '/' || b.id::text || '/%' then
    raise exception 'Add your proof first: a photo or PDF of your policy or of your card''s coverage letter' using errcode = '22023';
  end if;
  if v_to = 1 then
    if v_insurer is null or v_policy is null or v_expiry is null then
      raise exception 'Add the insurer, the policy number and the policy expiry date' using errcode = '22023';
    end if;
    if v_expiry <= app.local_date(b.return_at) then
      raise exception 'The policy must still be active after your return date (%)', app.fmt_day(app.local_date(b.return_at)) using errcode = '23514';
    end if;
  else
    v_check := app.card_coverage_check(b.id);
    if not coalesce((v_check ->> 'eligible')::boolean, false) then raise exception '%', v_check ->> 'message' using errcode = '23514'; end if;
  end if;
  insert into protection_requests (booking_id, from_option, to_option, reason, insurer_name, policy_number, policy_expiry, proof_bucket, proof_path, proof_mime, proof_sha256, created_by)
  values (b.id, 3, v_to, v_reason, case when v_to = 1 then v_insurer end, case when v_to = 1 then v_policy end, case when v_to = 1 then v_expiry end,
          coalesce(nullif(p_ ->> 'proof_bucket', ''), 'documents'), v_path, left(p_ ->> 'proof_mime', 60), left(p_ ->> 'proof_sha256', 64), p_by)
  returning * into q;
  v_task := app.raise_task(p_type => 'protection_change_review',
    p_title => format('Booking %s: the renter asks to leave the Protection Plan for %s', b.booking_number, case when v_to = 1 then 'their own insurance (OPCF 27)' else 'their card coverage' end),
    p_detail => 'Open the booking, check the proof under Protection, then Approve or Decline with the reason.' || coalesce(' The renter''s note: ' || v_reason, ''),
    p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_related_table => 'protection_requests', p_related_id => q.id,
    p_due_at => least(greatest(b.pickup_at - interval '24 hours', now() + interval '1 hour'), now() + interval '24 hours'),
    p_dedupe => 'protection_change_review:' || b.id);
  update protection_requests set task_id = v_task where id = q.id;
  perform app.log_booking_event(b.id, 'verification', b.status::text, b.status::text, null,
    format('The renter asked to change from the Protection Plan to %s (waiting for review)', app.coverage_option_label(v_to)), p_by, 'renter',
    jsonb_build_object('protection_request', q.id, 'coverage_option_to', v_to));
  return jsonb_build_object('ok', true, 'applied', false, 'request_id', q.id, 'status', 'pending', 'to_option', v_to, 'task_id', v_task);
end $$;

-- ================================================================ 7. customer service reviews the renter's request
create function app.protection_review(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  q protection_requests;
  b bookings;
  v_approve boolean := coalesce((p_ ->> 'approve')::boolean, false);
  v_note text := nullif(left(btrim(coalesce(p_ ->> 'note', '')), 500), '');
  v_why text;
  v_out jsonb;
  v_check jsonb;
  v_proof uuid;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs')) then
    raise exception 'Customer service or an Admin reviews a change of protection' using errcode = '42501';
  end if;
  select * into q from protection_requests where id::text = p_ ->> 'request' for update;
  if q.id is null then raise exception 'Request not found' using errcode = 'P0002'; end if;
  if q.status <> 'pending' then raise exception 'This request is % already', q.status using errcode = '23514'; end if;
  select * into b from bookings where id = q.booking_id for update;
  if not v_approve then
    if v_note is null then raise exception 'Say why it is declined: the renter reads it' using errcode = '22023'; end if;
    update protection_requests set status = 'declined', decided_by = p_by, decided_at = now(), decision_note = v_note where id = q.id;
    perform app.resolve_tasks(array['protection_change_review'], b.id, p_by, 'Declined: ' || v_note);
    perform app.log_booking_event(b.id, 'verification', b.status::text, b.status::text, null, 'The request to leave the Protection Plan was declined: ' || v_note, p_by, 'staff',
      jsonb_build_object('protection_request', q.id, 'status', 'declined'));
    return jsonb_build_object('ok', true, 'status', 'declined', 'request_id', q.id);
  end if;

  update protection_requests set status = 'approved', decided_by = p_by, decided_at = now(), decision_note = v_note where id = q.id;
  -- the renter's rules still hold when it is approved (before pickup, no damage reported, the card in their name)
  v_why := app.protection_block(b, q.to_option, 'renter');
  if v_why is not null then raise exception '%', v_why using errcode = '23514'; end if;
  perform set_config('app.protection_side', 'staff', true);
  v_out := app.protection_change(p_by, jsonb_build_object('booking', b.id::text, 'to', q.to_option,
    'reason', coalesce('The renter asked' || coalesce(': ' || q.reason, '') || coalesce('. ' || v_note, ''), 'The renter asked'), 'notify', true));
  perform set_config('app.protection_side', '', true);
  update coverage_switches set side = 'renter', request_id = q.id where id = (v_out ->> 'switch_id')::uuid;
  update protection_requests set switch_id = (v_out ->> 'switch_id')::uuid where id = q.id;
  -- the proof was reviewed with the request: the coverage is confirmed
  if q.to_option = 1 then
    insert into coverage_proofs (booking_id, coverage_option, status, insurer_name, policy_number, policy_expiry, confirmed_by, confirmed_at, covers_vehicle_and_drivers, submitted_by, submitted_at)
    values (b.id, 1, 'confirmed', q.insurer_name, q.policy_number, q.policy_expiry, p_by, now(), true, q.created_by, q.created_at) returning id into v_proof;
  else
    v_check := app.card_coverage_check(b.id);
    if v_check ->> 'last4' is not null then
      insert into coverage_proofs (booking_id, coverage_option, status, card_issuer, card_last4, payment_method_id, card_brand, cardholder_name, name_matches,
                                   renter_confirmed_at, renter_confirmed_by, confirmed_by, confirmed_at, covers_vehicle_and_drivers, submitted_by, submitted_at)
      values (b.id, 2, 'confirmed', coalesce(initcap(v_check ->> 'brand'), 'Card'), v_check ->> 'last4', (v_check ->> 'payment_method_id')::uuid, v_check ->> 'brand',
              v_check ->> 'cardholder_name', (v_check ->> 'name_matches')::boolean, q.created_at, q.created_by, p_by, now(), true, q.created_by, q.created_at)
      returning id into v_proof;
    end if;
  end if;
  if v_proof is not null then
    update bookings set coverage_confirmed_at = now() where id = b.id;
    perform app.resolve_tasks(array['coverage_proof_needed', 'coverage_review'], b.id, p_by, 'The proof was reviewed with the renter''s change of protection');
  end if;
  return v_out || jsonb_build_object('status', 'approved', 'request_id', q.id, 'proof_id', v_proof);
end $$;

-- ================================================================ 8. the doors
create function public.renter_protection_options(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
begin
  perform app.assert_booking_renter(p_booking, p_by);
  select * into b from bookings where id = p_booking;
  return app.protection_options_of(b, 'renter', true, null);
end $$;
create function public.renter_protection_change(p_booking uuid, p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  return app.renter_protection_change(p_by, coalesce(p, '{}'::jsonb) || jsonb_build_object('booking', p_booking::text));
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2540;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call in ('ops_do', 'va_do', 'admin_do') and p_name in ('protection_change', 'protection_review'))
     or (p_call in ('ops_read', 'va_read', 'admin_read') and p_name = 'protection_options') then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    p_ := p_ - '_va';
    perform app.door_begin(p_user, p_aal);
    perform set_config('app.protection_side', 'staff', true);
    perform set_config('app.protection_renter', '', true);
    if p_name = 'protection_change' then return app.protection_change(p_user, p_); end if;
    if p_name = 'protection_review' then return app.protection_review(p_user, p_); end if;
    return app.protection_options(p_user, p_);
  end if;
  return app.door_pre2540(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2540(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname = any (array['protection_block', 'coverage_switch_block', 'coverage_switch_who', 'protection_own_switch', 'protection_change',
                     'protection_options_of', 'protection_options', 'renter_protection_change', 'protection_review', 'door_pre2540']))
               or (n.nspname = 'public' and p.proname = any (array['renter_protection_options', 'renter_protection_change']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
