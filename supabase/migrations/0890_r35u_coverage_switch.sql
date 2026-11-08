-- 0890: switch a booking between the renter's credit card rental coverage and the Protection Plan, offer or active booking
-- (Release 35, part U; docs/changes/2026-11-08-r35-coverage-switch.md). The owner: "there needs to be a way to change bookings from
-- rental card coverage to protection plan, whether an offer or active booking." No applied migration is edited.
--
-- 1. coverage_switches: one row per switch (who, when, from and to, the totals, the proofs and tasks it cleared so the reverse can
--    put them back). The booking history and the audit log get an entry too.
-- 2. app.coverage_switch(by, {booking, to: plan|card, note, notify, plan_cents}): the one action.
--      to plan:  a request or an offer (offered, waiting for payment): the offer is opened, priced with the Protection Plan by the
--                existing coverage_sold rules and sent again as a new version (the renter sees the new price, by the offer email).
--                A confirmed booking or a rental in progress: the Protection Plan fee line is added (priced per rental, as the
--                existing rules price it), the totals follow, the difference is open to collect (Money > Collect, a pay link or the
--                saved card, as every fee), and the agreement job makes the amended version (rental terms 15.4). The renter gets
--                renter_coverage_switched. The card coverage proof, its review task and the verification task that only waited for
--                it are cleared.
--      to card:  the reverse. The Protection Plan line goes (a paid one raises a refund for approval and a finance task), the earlier
--                proof and tasks come back, and when nothing is in review a task asks customer service to get the proof from the renter
--                (the card coverage flow: the renter ticks their card, staff review it).
-- 3. app.coverage_switch_state: what the booking page shows (may, price, difference, history); the renter's coverage read carries the
--    last switch.
-- Who: an Admin, customer service and fleet; sales on a request or an offer (sales does not edit a booking that is paid already).
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

-- ================================================================ 1. the record
create table coverage_switches (
  id                 uuid primary key default gen_random_uuid(),
  booking_id         uuid not null references bookings (id),
  direction          text not null check (direction in ('to_plan', 'to_card')),
  from_option        smallint check (from_option in (1, 2, 3, 4)),
  to_option          smallint not null check (to_option in (1, 2, 3)),
  booking_status     text not null,
  offer_version      integer,
  total_before_cents bigint not null,
  total_after_cents  bigint not null,
  plan_cents         bigint,
  note               text check (char_length(note) <= 500),
  lapsed_proofs      jsonb not null default '[]'::jsonb,
  lapsed_uploads     jsonb not null default '[]'::jsonb,
  cleared_tasks      jsonb not null default '[]'::jsonb,
  prev_confirmed_at  timestamptz,
  refund_id          uuid references refunds (id),
  created_by         uuid references users (id) on delete set null,
  created_at         timestamptz not null default now()
);
create index coverage_switches_booking on coverage_switches (booking_id, created_at desc);
alter table coverage_switches enable row level security;
create policy admin_all on coverage_switches for select to authenticated using (app.is_admin());
create trigger audit_coverage_switches after insert or update or delete on coverage_switches for each row execute function app.audit_row();
comment on table coverage_switches is 'A booking switched between card coverage (or its own policy) and the Protection Plan (0890): the totals before and after, and the proofs, uploads and tasks cleared so the reverse restores them.';

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('coverage_proof_needed', 'cs', 'Get the renter''s coverage proof', 'high', 'opening_minutes', 120, 2, null,
   'The booking went back from the Protection Plan to the renter''s own coverage: ask for the proof (the renter ticks their card or sends the policy on the booking page), then review it.')
on conflict (task_type) do nothing;

-- ================================================================ 2. who, and when it can be done
create function app.coverage_switch_who(p_by uuid, p_status text) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when p_by is null then 'Sign in first'
    when app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet') then null
    when app.user_va_has(p_by, 'sales') then case when p_status in ('requested', 'offered') then null
         else 'Sales switches the coverage of a request or an offer. Customer service, fleet or an Admin switches a booking that is paid or confirmed' end
    else 'Only an Admin, customer service, sales or fleet switches the coverage of a booking' end
$$;

-- the Protection Plan line a booking would carry, priced by the existing rules (per rental, per period of a long one) or by an amount
create function app.coverage_plan_line(p_booking uuid, p_override bigint default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_spec jsonb;
  v_out jsonb;
begin
  v_spec := app.booking_price_spec(p_booking) || jsonb_build_object('coverage_option', 3, 'managed', true);
  if p_override is not null then
    v_spec := v_spec || jsonb_build_object('line_overrides', coalesce(v_spec -> 'line_overrides', '{}'::jsonb) || jsonb_build_object('coverage_sold', p_override));
  end if;
  v_out := app.price_lines(v_spec);
  return (select l.value from jsonb_array_elements(v_out -> 'lines') l where l.value ->> 'charge_type' = 'coverage_sold' limit 1);
end $$;

-- why a booking cannot be switched this way now; null when it can
create function app.coverage_switch_block(b bookings, p_to text) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_check jsonb;
begin
  if b.id is null then return 'Booking not found'; end if;
  if p_to not in ('plan', 'card') then return 'Choose the Protection Plan or card coverage'; end if;
  if b.booking_type = 'owner' then return 'An Owner Booking needs no coverage'; end if;
  if b.bill_to <> 'renter' or b.dates_provisional then return 'A booking billed to an insurer has its coverage from the insurer'; end if;
  if b.status::text not in ('requested', 'offered', 'pending_payment', 'confirmed', 'on_rent') then
    return format('Booking %s is %s: the coverage is switched on a request, an offer, a confirmed booking or a rental in progress', b.booking_number, replace(b.status::text, '_', ' '));
  end if;
  if b.coverage_option = 4 then return 'This car has coverage included: there is nothing to switch'; end if;
  if p_to = 'plan' then
    if b.coverage_option = 3 then return 'This booking is on the Protection Plan already'; end if;
    if coalesce((select t.amount_cents from app.fee_term('coverage_sold', b.vehicle_id, app.local_date(coalesce(b.booked_at, now())), b.id) t), 0) <= 0 then
      return 'The Protection Plan has no price for this car yet: an Admin sets it under Settings > Fees first';
    end if;
  else
    if b.coverage_option is distinct from 3 then return 'This booking is not on the Protection Plan'; end if;
    v_check := app.card_coverage_check(b.id);
    if coalesce((select c.from_option from coverage_switches c where c.booking_id = b.id and c.direction = 'to_plan' order by c.created_at desc limit 1), 2) = 2
       and v_check ->> 'problem' in ('not_credit', 'name_mismatch') then
      return v_check ->> 'message';
    end if;
  end if;
  return null;
end $$;

-- ================================================================ 3. the switch
create function app.coverage_switch(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  b bookings;
  v_to text := lower(coalesce(nullif(btrim(p_ ->> 'to'), ''), ''));
  v_note text := nullif(left(btrim(coalesce(p_ ->> 'note', '')), 500), '');
  v_notify boolean := coalesce((p_ ->> 'notify')::boolean, true);
  v_plan_cents bigint := nullif(p_ ->> 'plan_cents', '')::bigint;
  v_why text;
  v_status text;
  v_from smallint;
  v_target smallint;
  v_offer boolean;
  v_total0 bigint;
  v_total1 bigint;
  v_version integer;
  v_lapsed jsonb := '[]'::jsonb;
  v_uploads jsonb := '[]'::jsonb;
  v_cleared jsonb := '[]'::jsonb;
  v_prev_confirmed timestamptz;
  v_prior coverage_switches;
  v_line jsonb;
  v_plan bigint := 0;
  v_id uuid;
  v_refund uuid;
  v_restored integer := 0;
  v_open bigint;
  v_msg text;
  l record;
  r record;
  v_pay payments;
begin
  select * into b from bookings where id::text = p_ ->> 'booking' or booking_number = upper(btrim(coalesce(p_ ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  v_why := app.coverage_switch_who(p_by, b.status::text);
  if v_why is not null then raise exception '%', v_why using errcode = '42501'; end if;
  v_why := app.coverage_switch_block(b, v_to);
  if v_why is not null then raise exception '%', v_why using errcode = '23514'; end if;
  if v_plan_cents is not null then
    if v_to <> 'plan' then raise exception 'An amount is set when the booking goes to the Protection Plan' using errcode = '22023'; end if;
    if v_plan_cents <= 0 then raise exception 'The Protection Plan amount is more than $0.00 (before HST)' using errcode = '22023'; end if;
    if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs')) then
      raise exception 'Customer service or an Admin changes the Protection Plan price' using errcode = '42501';
    end if;
  end if;
  v_status := b.status::text;
  v_from := b.coverage_option;
  v_total0 := b.total_due_at_booking_cents;
  v_prev_confirmed := b.coverage_confirmed_at;
  v_offer := v_status in ('offered', 'pending_payment');
  if v_offer then
    perform set_config('app.offer_revising', 'on', true);
    perform app.offer_reopen_for_edit(b.id, p_by);
  end if;

  if v_to = 'plan' then
    -- the card coverage (or policy) proof and what waited for it
    select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'status', c.status)), '[]'::jsonb) into v_lapsed
      from coverage_proofs c where c.booking_id = b.id and c.status in ('submitted', 'confirmed');
    select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'status', u.status)), '[]'::jsonb) into v_uploads
      from verification_uploads u where u.booking_id = b.id and u.kind = 'coverage_proof' and u.status in ('submitted', 'approved');
    update coverage_proofs set status = 'lapsed' where booking_id = b.id and status in ('submitted', 'confirmed');
    update verification_uploads set status = 'replaced' where booking_id = b.id and kind = 'coverage_proof' and status in ('submitted', 'approved');
    update bookings set coverage_option = 3, coverage_confirmed_at = null where id = b.id;
    if v_status = 'on_rent' then
      -- the car is out already: the Protection Plan covers the rest of the rental from now (nothing is left to release)
      insert into coverage_proofs (booking_id, coverage_option, status, terms_sent_at, activation_ref, activated_at, confirmed_by, confirmed_at, covers_vehicle_and_drivers, submitted_by, submitted_at)
      values (b.id, 3, 'confirmed', now(), 'Switched while on rent', now(), p_by, now(), true, p_by, now());
      update bookings set coverage_confirmed_at = now() where id = b.id;
    end if;
    if v_plan_cents is not null then
      insert into booking_line_overrides as o (booking_id, line_key, total_cents, reason, set_by)
      values (b.id, 'coverage_sold', v_plan_cents, coalesce(v_note, 'Set when the booking went to the Protection Plan'), p_by)
      on conflict (booking_id, line_key) do update set total_cents = excluded.total_cents, reason = excluded.reason, set_by = excluded.set_by, set_at = now();
    end if;
    perform app.sync_booking_price(b.id);
    if not exists (select 1 from booking_line_items li where li.booking_id = b.id and li.charge_type = 'coverage_sold' and li.stage = 'booking' and li.voided_at is null) then
      -- a booking staff entered by hand is not priced line by line: the plan is its line, priced by the same rules
      v_line := app.coverage_plan_line(b.id);
      if v_line is null then raise exception 'The Protection Plan has no price for this car yet' using errcode = '23514'; end if;
      insert into booking_line_overrides as o (booking_id, line_key, total_cents, reason, set_by)
      values (b.id, 'coverage_sold', (v_line ->> 'amount_cents')::bigint, 'The Protection Plan, priced by the plan rules', p_by)
      on conflict (booking_id, line_key) do update set total_cents = excluded.total_cents, reason = excluded.reason, set_by = excluded.set_by, set_at = now();
      perform app.sync_booking_price(b.id);
    end if;
    with c as (
      update tasks t set status = 'cancelled', completed_at = now(), completed_by = p_by,
             completion_note = 'Switched to the Protection Plan: no coverage proof is needed'
       where t.booking_id = b.id and t.status in ('open', 'in_progress', 'waiting')
         and (t.task_type in ('coverage_review', 'coverage_proof_needed') or t.related_table = 'coverage_proofs'
              or (t.task_type = 'verify_renter' and not exists (select 1 from verification_uploads u where u.booking_id = b.id and u.status = 'submitted' and u.kind <> 'coverage_proof')))
      returning t.id, t.task_type)
    select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'type', c.task_type)), '[]'::jsonb) into v_cleared from c;
    perform app.resolve_tasks(array['protection_plan_request'], b.id, p_by, 'The booking is on the Protection Plan');
    v_target := 3;
  else
    -- back to the renter's own coverage: the option the booking had (card coverage unless it was OPCF 27)
    select * into v_prior from coverage_switches c where c.booking_id = b.id and c.direction = 'to_plan' order by c.created_at desc limit 1;
    v_target := case when v_prior.from_option in (1, 2) then v_prior.from_option else 2 end;
    -- the Protection Plan line goes; a paid one is given back by the usual refund
    for l in select li.* from booking_line_items li where li.booking_id = b.id and li.charge_type = 'coverage_sold' and li.stage = 'booking' and li.voided_at is null loop
      v_plan := v_plan + l.amount_cents;
      if l.payment_id is not null and v_refund is null then
        select * into v_pay from payments where id = l.payment_id;
        if v_pay.id is not null then
          insert into refunds (booking_id, payment_id, reason, amount_cents, status, requested_by, note)
          values (b.id, case when v_pay.method = 'card' then v_pay.id end, 'other', least(l.amount_cents + l.hst_cents, v_pay.amount_cents), 'pending_approval', p_by,
                  format('Booking %s went back from the Protection Plan to card coverage: the plan was paid', b.booking_number))
          returning id into v_refund;
          perform app.raise_task(p_type => 'change_refund', p_title => format('Booking %s: give back the Protection Plan', b.booking_number),
            p_detail => format('The booking went back from the Protection Plan to the renter''s own coverage. %s was paid for the plan by %s: give it back the way it was paid.',
                               app.fmt_money(l.amount_cents + l.hst_cents), replace(coalesce(v_pay.method, 'card'), '_', ' ')),
            p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_related_table => 'refunds', p_related_id => v_refund,
            p_dedupe => 'change_refund:coverage_switch:' || b.id, p_queue => 'finance', p_created_by => p_by);
        end if;
      end if;
    end loop;
    update booking_line_items set voided_at = now(), void_reason = 'Switched to card coverage'
     where booking_id = b.id and charge_type = 'coverage_sold' and stage = 'booking' and voided_at is null;
    update coverage_proofs set status = 'lapsed' where booking_id = b.id and status in ('submitted', 'confirmed');
    update bookings set coverage_option = v_target, coverage_confirmed_at = null where id = b.id;
    delete from booking_line_overrides where booking_id = b.id and line_key = 'coverage_sold';
    perform app.sync_booking_price(b.id);
    -- the earlier proof and tasks come back
    if v_prior.id is not null then
      for r in select (x ->> 'id')::uuid as id, x ->> 'status' as status from jsonb_array_elements(v_prior.lapsed_proofs) x loop
        update coverage_proofs set status = r.status where id = r.id and booking_id = b.id and status = 'lapsed' and coverage_option = v_target;
        if found then v_restored := v_restored + 1; end if;
      end loop;
      for r in select (x ->> 'id')::uuid as id, x ->> 'status' as status from jsonb_array_elements(v_prior.lapsed_uploads) x loop
        update verification_uploads set status = r.status where id = r.id and booking_id = b.id and status = 'replaced'
           and coverage_proof_id in (select c.id from coverage_proofs c where c.booking_id = b.id and c.status in ('submitted', 'confirmed'));
      end loop;
      if exists (select 1 from coverage_proofs c where c.booking_id = b.id and c.status = 'confirmed') then
        update bookings set coverage_confirmed_at = coalesce(v_prior.prev_confirmed_at, now()) where id = b.id;
      end if;
      for r in select (x ->> 'id')::uuid as id, x ->> 'type' as task_type from jsonb_array_elements(v_prior.cleared_tasks) x loop
        if r.task_type = 'verify_renter' and not exists (select 1 from coverage_proofs c where c.booking_id = b.id and c.status = 'submitted') then continue; end if;
        update tasks t set status = 'open', completed_at = null, completed_by = null, completion_note = null
         where t.id = r.id and t.status = 'cancelled'
           and not exists (select 1 from tasks o where o.dedupe_key is not null and o.dedupe_key = t.dedupe_key and o.status in ('open', 'in_progress', 'waiting') and o.id <> t.id);
        if found then v_restored := v_restored + 1; end if;
      end loop;
    end if;
    if not exists (select 1 from coverage_proofs c where c.booking_id = b.id and c.status in ('submitted', 'confirmed')) then
      perform app.raise_task(p_type => 'coverage_proof_needed',
        p_title => format('Booking %s: get the renter''s %s', b.booking_number, case when v_target = 1 then 'OPCF 27 proof' else 'card coverage proof' end),
        p_detail => 'The booking went back from the Protection Plan. The renter confirms their coverage on the booking page (Coverage); review it when it arrives.',
        p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id,
        p_due_at => least(greatest(b.pickup_at - interval '24 hours', now() + interval '1 hour'), now() + interval '24 hours'),
        p_dedupe => 'coverage_proof_needed:' || b.id, p_created_by => p_by);
      v_restored := v_restored + 1;
    end if;
  end if;

  select * into b from bookings where id = b.id;
  v_total1 := b.total_due_at_booking_cents;
  if v_to = 'plan' then
    v_plan := coalesce((select sum(li.amount_cents) from booking_line_items li where li.booking_id = b.id and li.charge_type = 'coverage_sold' and li.stage = 'booking' and li.voided_at is null), 0);
  end if;

  if v_offer then
    -- the offer goes out again: the renter sees the new price and approves the new version
    perform app.offer_channels_begin(v_notify, p_ -> 'channels');
    v_version := app.send_offer(b.id, p_by,
      format('Your coverage is now %s. The new total with tax is %s (it was %s).%s', app.coverage_option_label(v_target), app.fmt_money(v_total1), app.fmt_money(v_total0),
             coalesce(' ' || v_note, '')),
      case when b.offer_expires_at > now() + interval '1 hour' then b.offer_expires_at else now() + make_interval(hours => (app.settings()).offer_expiry_hours) end);
    perform app.offer_channels_end();
    perform set_config('app.offer_revising', '', true);
  end if;
  insert into coverage_switches (booking_id, direction, from_option, to_option, booking_status, offer_version, total_before_cents, total_after_cents, plan_cents, note,
                                 lapsed_proofs, lapsed_uploads, cleared_tasks, prev_confirmed_at, refund_id, created_by)
  values (b.id, 'to_' || v_to, v_from, v_target, v_status, v_version, v_total0, v_total1, v_plan, v_note, v_lapsed, v_uploads, v_cleared, v_prev_confirmed, v_refund, p_by)
  returning id into v_id;
  v_msg := format('Coverage switched from %s to %s. Total %s to %s%s', app.coverage_option_label(v_from), app.coverage_option_label(v_target),
                  app.fmt_money(v_total0), app.fmt_money(v_total1), coalesce(' (' || v_note || ')', ''));

  perform app.log_booking_event(b.id, 'adjusted', v_status, (select status::text from bookings where id = b.id), coalesce(v_version, b.current_offer_version), v_msg, p_by, 'staff',
    jsonb_build_object('coverage_switch', v_id, 'direction', 'to_' || v_to, 'coverage_option_from', v_from, 'coverage_option_to', v_target,
                       'total_before_cents', v_total0, 'total_after_cents', v_total1, 'refund_id', v_refund));
  if not v_offer and v_status in ('confirmed', 'on_rent') and v_notify then
    perform app.ntf_emit('renter_coverage_switched', 'booking', b.id, 'switch:' || v_id, jsonb_build_object('booking_id', b.id, 'switch_id', v_id));
  end if;
  v_open := case when v_status in ('confirmed', 'on_rent') then app.booking_part_open(b.id, 'balance') else 0 end;
  return jsonb_build_object('ok', true, 'switch_id', v_id, 'booking_number', b.booking_number, 'direction', 'to_' || v_to, 'from_option', v_from, 'to_option', v_target,
    'status', (select status from bookings where id = b.id), 'was', v_status, 'total_before_cents', v_total0, 'total_after_cents', v_total1,
    'difference_cents', v_total1 - v_total0, 'open_cents', v_open, 'offer_version', v_version, 'refund_id', v_refund,
    'tasks_cleared', jsonb_array_length(v_cleared), 'restored', v_restored);
end $$;

-- ================================================================ 4. what the booking page shows
create function app.coverage_switch_state(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_who text;
  v_plan jsonb;
  v_block_plan text;
  v_block_card text;
  v_diff bigint;
  v_prior coverage_switches;
  v_target smallint;
  v_paid boolean;
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  v_who := app.coverage_switch_who(p_by, b.status::text);
  v_block_plan := app.coverage_switch_block(b, 'plan');
  v_block_card := app.coverage_switch_block(b, 'card');
  v_plan := case when v_block_plan is null then app.coverage_plan_line(b.id, nullif(p ->> 'plan_cents', '')::bigint) end;
  select * into v_prior from coverage_switches c where c.booking_id = b.id and c.direction = 'to_plan' order by c.created_at desc limit 1;
  v_target := case when v_prior.from_option in (1, 2) then v_prior.from_option else 2 end;
  v_paid := exists (select 1 from booking_line_items li where li.booking_id = b.id and li.charge_type = 'coverage_sold' and li.stage = 'booking' and li.voided_at is null and li.payment_id is not null);
  return jsonb_build_object(
    'booking_number', b.booking_number, 'status', b.status, 'option', b.coverage_option, 'option_label', app.coverage_option_label(b.coverage_option),
    'may', v_who is null, 'why_not', v_who,
    'is_offer', b.status::text in ('requested', 'offered', 'pending_payment'),
    'to_plan', jsonb_build_object('available', v_who is null and v_block_plan is null, 'problem', v_block_plan,
       'amount_cents', (v_plan ->> 'amount_cents')::bigint, 'hst_cents', (v_plan ->> 'hst_cents')::bigint,
       'total_cents', (v_plan ->> 'amount_cents')::bigint + (v_plan ->> 'hst_cents')::bigint,
       'new_total_cents', b.total_due_at_booking_cents + (v_plan ->> 'amount_cents')::bigint + (v_plan ->> 'hst_cents')::bigint),
    'to_card', jsonb_build_object('available', v_who is null and v_block_card is null, 'problem', v_block_card, 'option', v_target,
       'option_label', app.coverage_option_label(v_target), 'plan_paid', v_paid,
       'removes_cents', coalesce((select sum(li.amount_cents + li.hst_cents) from booking_line_items li where li.booking_id = b.id and li.charge_type = 'coverage_sold' and li.stage = 'booking' and li.voided_at is null), 0)),
    'total_cents', b.total_due_at_booking_cents,
    'open_cents', case when b.status::text in ('confirmed', 'on_rent') then app.booking_part_open(b.id, 'balance') else 0 end,
    'history', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'direction', c.direction, 'from_label', app.coverage_option_label(c.from_option), 'to_label', app.coverage_option_label(c.to_option),
                           'status', c.booking_status, 'total_before_cents', c.total_before_cents, 'total_after_cents', c.total_after_cents, 'note', c.note,
                           'by', (select u.full_name from users u where u.id = c.created_by), 'at', c.created_at) order by c.created_at desc)
                          from coverage_switches c where c.booking_id = b.id), '[]'::jsonb));
end $$;

-- ================================================================ 5. the renter sees it
alter function app.renter_coverage(uuid) rename to renter_coverage_pre0890;
create function app.renter_coverage(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.renter_coverage_pre0890(p_booking);
  c coverage_switches;
begin
  if x is null then return null; end if;
  select * into c from coverage_switches s where s.booking_id = p_booking order by s.created_at desc limit 1;
  return x || jsonb_build_object('last_switch', case when c.id is null then null else jsonb_build_object(
    'at', c.created_at, 'direction', c.direction, 'from_label', app.coverage_option_label(c.from_option), 'to_label', app.coverage_option_label(c.to_option),
    'total_before_cents', c.total_before_cents, 'total_after_cents', c.total_after_cents, 'note', c.note) end);
end $$;
select pg_temp.copy_grants('app.renter_coverage(uuid)'::regprocedure, 'app.renter_coverage_pre0890(uuid)'::regprocedure);

-- ================================================================ 6. the email
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0890;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0890(p_code, p_event, p_to);
  s coverage_switches;
  b bookings;
  v_diff bigint;
  v_open bigint;
begin
  if p_code = 'renter_coverage_switched' then
    select * into s from coverage_switches where id = (p_event.payload ->> 'switch_id')::uuid;
    select * into b from bookings where id = s.booking_id;
    v_diff := s.total_after_cents - s.total_before_cents;
    v_open := app.booking_part_open(b.id, 'balance');
    x := coalesce(x, '{}'::jsonb) || jsonb_build_object(
      'booking_number', b.booking_number,
      'change_rows', jsonb_build_array(
        jsonb_build_object('label', 'Coverage', 'before', initcap(left(app.coverage_option_label(s.from_option), 1)) || substr(app.coverage_option_label(s.from_option), 2),
                           'after', initcap(left(app.coverage_option_label(s.to_option), 1)) || substr(app.coverage_option_label(s.to_option), 2)),
        jsonb_build_object('label', 'Total with HST', 'before', app.fmt_money(s.total_before_cents), 'after', app.fmt_money(s.total_after_cents))),
      'coverage_title', case when s.to_option = 3 then 'Your booking now has the Protection Plan' else 'Your booking now uses your own coverage' end,
      'coverage_now', initcap(left(app.coverage_option_label(s.to_option), 1)) || substr(app.coverage_option_label(s.to_option), 2),
      'money_text', case when v_diff > 0 and v_open > 0 then format('You have %s more to pay. We will send you a secure payment link, or you can pay from your booking page.', app.fmt_money(v_open))
                         when v_diff > 0 then format('The extra %s is covered by what you paid already.', app.fmt_money(v_diff))
                         when v_diff < 0 then format('%s comes off your booking. If you paid it already, it goes back to you; refunds reach your account 5 to 10 business days after we send them.', app.fmt_money(-v_diff))
                         else 'The price of your booking stays the same.' end,
      'next_step', case when s.to_option = 3 and s.booking_status = 'on_rent' then 'The Protection Plan covers the rest of your rental. There is nothing for you to send.'
                        when s.to_option = 3 then 'You do not need to send a card coverage document any more. We confirm the Protection Plan for you before pickup.'
                        when s.to_option = 2 then 'Please confirm your card coverage on your booking page, under Coverage, so we can check it before pickup.'
                        else 'Please send your policy details on your booking page, under Coverage, so we can check them before pickup.' end,
      'has_reason', s.note is not null, 'switch_reason', coalesce(s.note, ''),
      '_url', app.ntf_link('booking', jsonb_build_object('booking_number', b.booking_number)));
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre0890(text, app_events, jsonb)'::regprocedure);

-- CATALOGUE 0890 START (generated by supabase/seed/0890_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_coverage_switched', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Your coverage on booking {{booking_number}} changed', 'Here is the new price and what to do next.', 'Immediate', 'Staff (an Admin, customer service, sales or fleet) switch a confirmed or active booking between the renter''s credit card rental coverage and the CarmaCars Protection Plan. Sent once the switch is saved, with what changed, the new price and what the renter does next. A booking that is still an offer gets the revised offer email instead.', null, '/account/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"change_rows","type":"list","fields":["label","before","after"]},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"coverage_now","type":"string"},{"name":"coverage_title","type":"string"},{"name":"first_name","type":"string"},{"name":"has_reason","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"money_text","type":"string"},{"name":"next_step","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"switch_reason","type":"string"},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_coverage_switched.html', 'templates/renter_coverage_switched.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0890 END
update notification_catalogue set emitted_by = 'app.coverage_switch (0890)', push_topic = 'bookings' where code = 'renter_coverage_switched';

-- ================================================================ 7. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0890;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call in ('ops_do', 'va_do', 'admin_do') and p_name = 'coverage_switch') or (p_call in ('ops_read', 'va_read', 'admin_read') and p_name = 'coverage_switch_state') then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    p_ := p_ - '_va';
    perform app.door_begin(p_user, p_aal);
    if p_name = 'coverage_switch' then return app.coverage_switch(p_user, p_); end if;
    return app.coverage_switch_state(p_user, p_);
  end if;
  return app.door_pre0890(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0890(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['coverage_switch_who', 'coverage_plan_line', 'coverage_switch_block', 'coverage_switch', 'coverage_switch_state',
              'renter_coverage_pre0890', 'ntf_payload_pre0890', 'door_pre0890'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
