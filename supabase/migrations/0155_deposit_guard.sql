-- 0155_deposit_guard.sql
-- The deposit guard (docs/changes/2026-10-25-deposit-guard.md). The owner, October 25, 2026: "tickets and tolls may take
-- up to seven days to come in. And if a car is damaged, then I have to keep the entire deposit. Just make sure there's no
-- situation where we get screwed out of money. The deposit is not being released automatically, but instead it is very
-- important to allow us to bill tickets tolls gas late return additional usage and damages."
--
-- The audit (every path a deposit can be returned or lapse, every way money owed is billed) found:
--   a. app.charge_after_rental (0021), run when a toll, ticket or damage found later is charged, called
--      app.settle_deposit with an empty plan: on a booking not settled yet it released the rest of the deposit by itself.
--   b. Nothing executed the money app.settle_deposit decided: its captures, card charges, hold releases and refunds stayed
--      "pending" payments for a server that never ran them. A captured hold was never captured at Stripe (it lapsed after
--      about 7 days: the money was lost) and a balance charged to the card on file was never charged.
--   c. A card hold that lapsed (Stripe cancels an authorization after about 7 days) was not noticed: the deposit still
--      read "held", and nothing captured a hold before it lapsed on a rental still on the road or not settled yet.
--   d. "Release the hold" and a part capture (which releases the rest) were open to Finance at any time, past an open
--      incident, claim, unmatched toll or card dispute, and during the toll window.
--   e. A balance with no card on file (a deposit in cash or by e-Transfer, no deposit) made the settlement fail; a pay link
--      for a later charge was refused on a closed booking; a later charge paid by pay link did not mark its lines paid.
--
-- 1. Settings: the suggested hold-back window after the return (7 days; the limit stays deposit_holdback_days, 30), how
--    long before a hold lapses it is captured (36 hours), automatic capture and balance collection (both on).
-- 2. What blocks releasing any of a deposit: an open incident or claim, damage at the return not priced, damage found
--    later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, charges
--    not on a statement yet. An Admin overrides with a reason (deposit_overrides, append-only, audited).
-- 3. app.settle_deposit: "apply only" for the charges after the return (never releases), the blockers, the overrides,
--    each money step marked for the server (payments.server_action); a balance with no card stays open (followed up).
-- 4. The Settle screen: the window warning and the pre-filled hold-back, "Release now anyway", Keep the whole deposit
--    (damage), the damage charge (amount, reason, photos), the hold actions guarded.
-- 5. The money runner: what the server executes at Stripe (capture, release, refund, charge) and records; the card hold
--    captured in full before it lapses; a lapsed hold recorded and the deposit charged to the saved card; the balance
--    after the deposit (card on file, else a pay link by email and text, else an open balance with a Finance task).
-- 6. The daily job (server_jobs_due "deposits"), the door, privileges and the guides.
-- No applied migration is edited.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0155: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. settings and columns
alter table program_settings
  add column if not exists deposit_toll_window_days integer not null default 7 check (deposit_toll_window_days between 0 and 30),
  add column if not exists deposit_hold_capture_hours integer not null default 36 check (deposit_hold_capture_hours between 6 and 120),
  add column if not exists deposit_auto_capture boolean not null default true,
  add column if not exists balance_auto_collect boolean not null default true,
  add column if not exists deposit_auto_max_age_days integer not null default 14 check (deposit_auto_max_age_days between 1 and 90);
comment on column program_settings.deposit_toll_window_days is 'Tolls and tickets can take this many days after the return to come in (0155): settling a deposit sooner warns and suggests a hold-back. The limit of a hold-back stays deposit_holdback_days.';
comment on column program_settings.deposit_hold_capture_hours is 'A card hold on a rental on the road, returned and not settled, or with an open claim or toll is captured in full this many hours before it lapses (0155). Captured is not released: the settlement refunds the rest.';
comment on column program_settings.deposit_auto_capture is 'Capture card holds before they lapse, and charge the deposit to the saved card when a hold lapsed anyway (0155).';
comment on column program_settings.deposit_auto_max_age_days is 'Money steps older than this many days are never run by themselves (0155): a step left pending, a balance on statements older than this, a hold that lapsed longer ago. Finance gets a task to review them instead.';
comment on column program_settings.balance_auto_collect is 'What is owed after the deposit goes to the card on file, else a pay link to the renter, else an open balance with a Finance task (0155).';

alter table payments
  add column if not exists server_action text,
  add column if not exists server_attempts integer not null default 0,
  add column if not exists server_last_error text,
  add column if not exists server_attempted_at timestamptz;
alter table payments drop constraint if exists payments_server_action_check;
alter table payments add constraint payments_server_action_check
  check (server_action is null or server_action in ('capture_deposit', 'release_hold', 'refund_deposit', 'charge_card', 'protect_capture', 'deposit_charge', 'balance_charge'));
comment on column payments.server_action is 'A step the server executes at Stripe and records (0155): a deposit capture, a hold release, a deposit refund, a card charge, the capture before a hold lapses, the deposit charged to the saved card, a balance charge.';
create index if not exists payments_server_pending on payments (created_at) where status = 'pending' and server_action is not null;

-- a pay link the system sends (the balance after the rental) has no staff member behind it
alter table payment_requests alter column created_by drop not null;

-- ================================================================ 2. overrides (append-only, audited)
create table if not exists deposit_overrides (
  id           uuid primary key default gen_random_uuid(),
  booking_id   uuid not null references bookings (id),
  deposit_id   uuid references deposits (id),
  kind         text not null check (kind in ('release_past_blockers', 'release_in_window', 'hold_action')),
  amount_cents bigint not null default 0 check (amount_cents >= 0),
  blockers     jsonb not null default '[]'::jsonb,
  reason       text not null check (length(btrim(reason)) >= 10),
  created_by   uuid not null references users (id),
  created_at   timestamptz not null default now()
);
comment on table deposit_overrides is 'A deposit released while something could still be owed (0155): past an open incident, claim, toll or dispute (an Admin, with the reason), or inside the toll window ("Release now anyway"). Append-only.';
create index if not exists deposit_overrides_booking on deposit_overrides (booking_id, created_at);
create trigger audit_deposit_overrides after insert or update or delete on deposit_overrides for each row execute function app.audit_row();
create or replace function app.deposit_overrides_append_only() returns trigger
language plpgsql as $$
begin
  raise exception 'An override is kept as it was recorded' using errcode = '42501';
end $$;
create trigger deposit_overrides_append_only before update or delete on deposit_overrides for each row execute function app.deposit_overrides_append_only();
alter table deposit_overrides enable row level security;
create policy admin_all on deposit_overrides for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on deposit_overrides from anon, authenticated;
grant all on deposit_overrides to service_role;

-- the balance after the rental: what was last done for each booking (the job follows up once a day)
create table if not exists balance_followups (
  booking_id   uuid primary key references bookings (id) on delete cascade,
  last_step    text not null check (last_step in ('charge_card', 'pay_link', 'task', 'paid')),
  last_at      timestamptz not null default now(),
  open_cents   bigint not null default 0,
  attempts     integer not null default 0,
  note         text,
  manual       boolean not null default false   -- older than the automatic limit when first seen: Finance collects it by hand
);
create trigger audit_balance_followups after insert or update or delete on balance_followups for each row execute function app.audit_row();
comment on table balance_followups is 'The balance owed after the deposit, per booking (0155): the card on file charged, a pay link sent, or a Finance task. The deposit job follows up once a day until it is paid.';
alter table balance_followups enable row level security;
create policy admin_all on balance_followups for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on balance_followups from anon, authenticated;
grant all on balance_followups to service_role;

create table if not exists deposit_guard_state (
  id            boolean primary key default true check (id),
  last_sweep_at timestamptz
);
insert into deposit_guard_state (id) values (true) on conflict do nothing;
create trigger audit_deposit_guard_state after insert or update or delete on deposit_guard_state for each row execute function app.audit_row();
alter table deposit_guard_state enable row level security;
create policy admin_all on deposit_guard_state for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on deposit_guard_state from anon, authenticated;
grant all on deposit_guard_state to service_role;

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('collect_balance',        'finance', 'Money still owed after the rental',                'high',   'business_days', 1,    5, null, 'The card on file was declined or there is none: a pay link went to the renter. Follow up until it is paid (0155)'),
  ('deposit_hold_lapsed',    'finance', 'A deposit hold lapsed',                            'urgent', 'minutes',       0,    5, null, 'Charge the deposit to the saved card, or ask the renter to pay it (0155)'),
  ('deposit_capture_failed', 'finance', 'A deposit could not be captured',                  'urgent', 'minutes',       0,    5, null, 'Stripe refused the capture: charge the saved card or send a pay link (0155)'),
  ('renew_deposit_hold',     'finance', 'A deposit hold lapses before the pickup',          'high',   'none',          null, 3, null, 'Release it and place a new hold at the pickup (0155)'),
  ('deposit_money_review',   'finance', 'Old money step to review',                         'high',   'business_days', 1,    5, null, 'A deposit step or balance older than the automatic limit (14 days): it is not run by itself. Check it in Stripe and do it by hand, or leave it (0155)'),
  ('deposit_money_stuck',    'finance', 'A deposit step did not go through at Stripe',      'high',   'business_days', 1,    5, null, 'A capture, release, refund or charge failed several times: do it by hand and record it (0155)')
on conflict (task_type) do nothing;

-- ================================================================ 3. what blocks releasing any of a deposit
-- Each item: {kind, label} in plain words. Empty: nothing known is still owed.
create or replace function app.deposit_blockers(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v jsonb := '[]'::jsonb;
  v_from timestamptz;
  v_to timestamptz;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return v; end if;
  v_from := coalesce(b.handed_over_at, b.pickup_at);
  v_to := coalesce(b.checked_in_at, greatest(b.return_at, now()));
  v := v || coalesce((select jsonb_agg(jsonb_build_object('kind', 'incident', 'label',
             format('Incident %s (%s) is still open', i.incident_number, replace(i.kind, '_', ' '))) order by i.reported_at)
        from incidents i where i.booking_id = b.id and i.status in ('open', 'assessing', 'claim_open')), '[]'::jsonb);
  v := v || coalesce((select jsonb_agg(jsonb_build_object('kind', 'claim', 'label', format('Claim %s is not settled yet', c.claim_number)) order by c.claim_number)
        from claims c join incidents ci on ci.id = c.incident_id
       where c.booking_id = b.id and c.status not in ('closed', 'withdrawn', 'distributed')
         -- damage at cost already billed to the renter: what is owed is known (it is on the statement)
         and not (c.path = 'at_cost' and ci.status in ('billed', 'closed'))), '[]'::jsonb);
  v := v || coalesce((select jsonb_agg(jsonb_build_object('kind', 'damage', 'label',
             format('New damage %s at the return (%s) is not priced yet', dm.label, dm.location)) order by dm.label)
        from condition_report_damages dm join condition_reports cr on cr.id = dm.condition_report_id
       where cr.booking_id = b.id and cr.kind = 'return' and dm.is_new and dm.incident_id is null), '[]'::jsonb);
  v := v || coalesce((select jsonb_agg(jsonb_build_object('kind', 'damage', 'label',
             format('Damage found after the rental (%s) is not billed yet', di.intake_number)) order by di.found_at)
        from damage_intakes di
       where di.status in ('logged', 'matched')
         and (di.booking_id = b.id
              or (di.matched_to = 'unmatched' and di.vehicle_id = b.vehicle_id
                  and coalesce(di.occurred_at, di.window_to, di.found_at) >= v_from
                  and coalesce(di.occurred_at, di.window_from, di.found_at) <= v_to + interval '2 days'))), '[]'::jsonb);
  v := v || coalesce((select jsonb_agg(jsonb_build_object('kind', 'toll', 'label',
             format('A %s on the car during the rental (%s) is %s', case when t.kind = 'toll_invoice' then 'toll' else 'ticket' end,
                    to_char(t.occurred_at at time zone 'America/Toronto', 'Mon FMDD'),
                    case when t.status = 'disputed' then 'disputed' when t.matched_to = 'unmatched' then 'not matched yet' else 'not charged yet' end)) order by t.occurred_at)
        from toll_tickets t
       where (t.booking_id = b.id and t.matched_to = 'renter' and (t.status = 'disputed' or (t.status = 'matched' and t.amount_line_item_id is null)))
          or (t.matched_to = 'unmatched' and t.status = 'logged' and t.vehicle_id = b.vehicle_id and t.occurred_at between v_from and v_to)), '[]'::jsonb);
  v := v || coalesce((select jsonb_agg(jsonb_build_object('kind', 'dispute', 'label', format('A card dispute of %s is open', app.fmt_money(d.amount_cents))))
        from disputes d where d.booking_id = b.id and d.status in ('open', 'evidence_submitted')), '[]'::jsonb);
  v := v || coalesce((select jsonb_agg(jsonb_build_object('kind', 'charges', 'label',
             format('%s in charges are not on a statement yet', app.fmt_money(x.total))))
        from (select sum(l.amount_cents + l.hst_cents) as total from booking_line_items l
               where l.booking_id = b.id and l.statement_id is null and l.voided_at is null and l.charged_to_renter
                 and l.stage in ('check_in', 'after_return') and l.amount_cents > 0) x where x.total > 0), '[]'::jsonb);
  return v;
end $$;

-- the deposit's facts for the Settle screen and the guard: what is still available, the window, the blockers
create or replace function app.deposit_guard_facts(p_booking uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  d deposits;
  s program_settings := app.settings();
  v_available bigint := 0;
  v_due bigint := 0;
  v_window date;
  v_blockers jsonb;
begin
  select * into b from bookings where id = p_booking;
  select * into d from deposits where booking_id = p_booking;
  if d.id is not null and d.status not in ('pending', 'failed', 'carried_forward') then
    v_available := d.amount_cents - d.applied_cents - d.released_cents;
  end if;
  select coalesce(sum(x.open_cents), 0) into v_due from (
    select l2.amount_cents + l2.hst_cents - coalesce((select sum(e.amount_cents) from deposit_events e where e.line_item_id = l2.id and e.kind = 'applied'), 0) as open_cents
      from booking_line_items l2
     where l2.booking_id = p_booking and l2.statement_id is not null and l2.payment_id is null and l2.voided_at is null and l2.charged_to_renter) x
   where x.open_cents > 0;
  v_window := case when b.checked_in_at is not null then app.local_date(b.checked_in_at) + s.deposit_toll_window_days end;
  v_blockers := app.deposit_blockers(p_booking);
  return jsonb_build_object(
    'available_cents', v_available, 'due_cents', v_due, 'remaining_cents', greatest(v_available - least(v_due, v_available), 0),
    'toll_window_days', s.deposit_toll_window_days, 'toll_window_ends_on', v_window,
    'within_window', v_window is not null and app.local_date(p_now) < v_window,
    'blockers', v_blockers, 'blocked', jsonb_array_length(v_blockers) > 0,
    'suggested_hold_back_cents', case when jsonb_array_length(v_blockers) > 0 or (v_window is not null and app.local_date(p_now) < v_window)
                                      then greatest(v_available - least(v_due, v_available), 0) else 0 end,
    'suggested_hold_back_until', case when jsonb_array_length(v_blockers) > 0 then app.local_date(b.checked_in_at) + s.deposit_holdback_days else v_window end,
    'hold_expires_at', case when d.method = 'card_hold' and d.status = 'held' then d.hold_expires_at end,
    'deposit_method', d.method, 'deposit_status', d.status,
    'card_on_file', exists (select 1 from payment_methods pm join payment_method_secrets sc on sc.payment_method_id = pm.id
                             where pm.renter_id = b.renter_id and pm.status = 'active' and sc.processor_method_id is not null),
    'deposit_to_charge', b.deposit_cents > 0 and b.booking_type <> 'owner' and (d.id is null or d.status in ('pending', 'failed')),
    'deposit_cents', b.deposit_cents,
    'balance_open_cents', app.booking_balance_open(p_booking),
    'is_admin', false);
end $$;

-- ================================================================ 4. the balance after the rental
-- What a line still owes: its amount less what the deposit covered (an application whose capture failed covers nothing)
-- and less its own payment when that payment went through or is under way.
create or replace function app.line_open_cents(p_line uuid) returns bigint
language sql stable security definer set search_path = public, app as $$
  select greatest(0, l.amount_cents + l.hst_cents
         - coalesce((select sum(e.amount_cents) from deposit_events e left join payments px on px.id = e.payment_id
                      where e.line_item_id = l.id and e.kind = 'applied' and (px.id is null or px.status not in ('failed', 'cancelled'))), 0)
         - case when p.id is not null and p.purpose <> 'deposit' and p.status in ('succeeded', 'pending', 'authorized', 'requires_action')
                then l.amount_cents + l.hst_cents else 0 end)
    from booking_line_items l left join payments p on p.id = l.payment_id
   where l.id = p_line
$$;

-- Everything still owed on issued statements after the rental (less a later payment not tied to a line yet).
create or replace function app.booking_balance_open(p_booking uuid) returns bigint
language sql stable security definer set search_path = public, app as $$
  select greatest(0,
           coalesce((select sum(app.line_open_cents(l.id)) from booking_line_items l
                      where l.booking_id = p_booking and l.stage <> 'booking' and l.statement_id is not null and l.voided_at is null and l.charged_to_renter
                        and l.amount_cents > 0), 0)
         - coalesce((select sum(p.amount_cents) from payments p
                      where p.booking_id = p_booking and p.purpose = 'post_rental' and p.kind = 'charge' and p.status = 'succeeded'
                        and not exists (select 1 from booking_line_items l where l.payment_id = p.id)), 0))
$$;

-- A later payment ties the lines it pays, oldest first, while it covers them (0129's tie waited for the whole part, so a
-- pay link for a later charge left its lines open). Lines whose card charge failed are taken again.
create or replace function app.tie_later_lines(p_booking uuid, p_payment uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_left bigint;
  l record;
  v_n integer := 0;
begin
  select amount_cents into v_left from payments where id = p_payment;
  for l in select l2.id, app.line_open_cents(l2.id) as open_cents
             from booking_line_items l2 left join payments p on p.id = l2.payment_id join fee_types ft on ft.code = l2.charge_type
            where l2.booking_id = p_booking and l2.stage <> 'booking' and l2.statement_id is not null and l2.voided_at is null and l2.charged_to_renter
              and l2.amount_cents > 0 and (l2.payment_id is null or p.status in ('failed', 'cancelled'))
            order by l2.created_at, ft.sort_order, l2.id
  loop
    continue when l.open_cents <= 0;
    exit when l.open_cents > v_left;
    update booking_line_items set payment_id = p_payment where id = l.id;
    v_left := v_left - l.open_cents;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
alter function app.booking_tie_lines(uuid, text, uuid) rename to booking_tie_lines_pre0155;
create or replace function app.booking_tie_lines(p_booking uuid, p_covers text, p_payment uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if p_covers = 'later' then
    perform app.tie_later_lines(p_booking, p_payment);
  else
    perform app.booking_tie_lines_pre0155(p_booking, p_covers, p_payment);
  end if;
end $$;

-- the saved card of a booking's renter, with Stripe's ids (none: no card to charge)
create or replace function app.booking_saved_card(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('payment_method_id', pm.id, 'customer_id', sc.processor_customer_id, 'method_id', sc.processor_method_id,
                            'brand', pm.card_brand, 'last4', pm.card_last4)
    from bookings b join payment_methods pm on pm.renter_id = b.renter_id and pm.status = 'active'
    join payment_method_secrets sc on sc.payment_method_id = pm.id and sc.processor_method_id is not null
   where b.id = p_booking
   order by (pm.id = b.card_on_file_id) desc, pm.created_at desc limit 1
$$;

-- ================================================================ 5. the settlement
-- 0020's settlement charged the balance to the card on file or failed; with no card (a deposit in cash or by e-Transfer,
-- no deposit) the balance now stays open on its lines and the money runner follows it up (pay link, Finance task).
select pg_temp.patch_fn('app.settle_deposit_pre0129(uuid, uuid, jsonb, timestamptz)'::regprocedure,
  $o$  if v_shortfall > 0 then
    if b.card_on_file_id is null then
      raise exception 'Booking % has no Card on File to charge the balance of % cents to', b.booking_number, v_shortfall using errcode = '23514';
    end if;$o$,
  $n$  if v_shortfall > 0 and b.card_on_file_id is not null then$n$);
select pg_temp.patch_fn('app.settle_deposit_pre0129(uuid, uuid, jsonb, timestamptz)'::regprocedure,
  $o$    if v_open > 0 then
      update booking_statements set charged_to_card_cents = charged_to_card_cents + v_open where id = li.statement_id;
    end if;$o$,
  $n$    if v_open > 0 and v_card_pay is not null then
      update booking_statements set charged_to_card_cents = charged_to_card_cents + v_open where id = li.statement_id;
    end if;$n$);

-- p_plan, beyond 0020's: mode 'apply_only' (a charge after the return: take what is owed from the deposit, keep the rest
-- held; never a release), override_reason (an Admin releasing past what blocks it), release_in_window (the person chose
-- to release inside the toll window). Every money step it decides is marked for the server (payments.server_action).
alter function app.settle_deposit(uuid, uuid, jsonb, timestamptz) rename to settle_deposit_pre0155;
create or replace function app.settle_deposit(p_booking uuid, p_by uuid, p_plan jsonb default '{}'::jsonb, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  pl jsonb := coalesce(p_plan, '{}'::jsonb);
  b bookings;
  d deposits;
  f jsonb;
  v_remaining bigint;
  v_release bigint;
  v_blockers jsonb;
  v_override text := nullif(btrim(coalesce(p_plan ->> 'override_reason', '')), '');
  v_out jsonb;
  a jsonb;
  v_apply_only boolean := coalesce(p_plan ->> 'mode', '') = 'apply_only';
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  select * into d from deposits where booking_id = p_booking;
  f := app.deposit_guard_facts(p_booking, p_now);
  v_remaining := (f ->> 'remaining_cents')::bigint;
  if v_apply_only then
    -- a toll, ticket or damage charged after the return: the deposit pays it, the rest stays held as it was
    pl := (pl - 'mode' - 'override_reason' - 'release_in_window');
    if v_remaining > 0 then
      pl := pl || jsonb_build_object('hold_back_cents', v_remaining,
                                     'hold_back_reason', coalesce(d.held_back_reason, 'Kept until the deposit is settled: tolls, tickets and damage can still come in'));
      if d.held_back_until is not null then pl := pl || jsonb_build_object('hold_back_until', d.held_back_until); end if;
    else
      pl := pl || jsonb_build_object('hold_back_cents', 0);
    end if;
  else
    pl := pl - 'mode' - 'override_reason' - 'release_in_window';
  end if;

  -- 0020's own checks come first (the statement, the reason and the date of a hold-back, who may release)
  v_out := app.settle_deposit_pre0155(p_booking, p_by, pl, p_now);
  v_release := greatest(coalesce((v_out ->> 'released_cents')::bigint, 0), coalesce((v_out #>> '{proposed,released_cents}')::bigint, 0));
  if not v_apply_only and d.id is not null and v_release > 0 then
    v_blockers := f -> 'blockers';
    if jsonb_array_length(v_blockers) > 0 then
      -- raising here undoes the settlement above: nothing is released, captured or proposed
      if not app.user_is_admin(p_by) or v_override is null or length(v_override) < 10 then
        raise exception 'The whole deposit stays held: %. An Admin can release part of it with the reason (10 characters or more).',
          (select string_agg(x ->> 'label', '; ') from jsonb_array_elements(v_blockers) x) using errcode = '23514';
      end if;
      insert into deposit_overrides (booking_id, deposit_id, kind, amount_cents, blockers, reason, created_by)
      values (b.id, d.id, 'release_past_blockers', v_release, v_blockers, v_override, p_by);
      perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
        format('An Admin released %s of the deposit past: %s. Reason: %s', app.fmt_money(v_release),
               (select string_agg(x ->> 'label', '; ') from jsonb_array_elements(v_blockers) x), v_override), p_by, 'staff',
        jsonb_build_object('override', true, 'blockers', v_blockers));
    elsif coalesce((p_plan ->> 'release_in_window')::boolean, false) and coalesce((f ->> 'within_window')::boolean, false) then
      insert into deposit_overrides (booking_id, deposit_id, kind, amount_cents, blockers, reason, created_by)
      values (b.id, d.id, 'release_in_window', v_release, '[]'::jsonb,
              coalesce(v_override, format('Released before the %s-day toll window ended (%s)', f ->> 'toll_window_days', f ->> 'toll_window_ends_on')), p_by);
    end if;
  end if;
  for a in select value from jsonb_array_elements(coalesce(v_out -> 'server_actions', '[]'::jsonb)) loop
    update payments set server_action = a ->> 'action' where id = (a ->> 'payment_id')::uuid and status = 'pending' and server_action is null;
  end loop;
  -- with no card on file the balance was not charged: it stays owed (the follow-up sends a pay link)
  return v_out || jsonb_build_object('blockers', coalesce(f -> 'blockers', '[]'::jsonb), 'apply_only', v_apply_only,
    'charged_to_card_cents', coalesce((select sum((a2 ->> 'amount_cents')::bigint) from jsonb_array_elements(coalesce(v_out -> 'server_actions', '[]'::jsonb)) a2 where a2 ->> 'action' = 'charge_card'), 0),
    'balance_open_cents', app.booking_balance_open(p_booking));
end $$;

-- a toll, ticket or damage found later is charged: from the deposit, never releasing the rest (it released it before)
select pg_temp.patch_fn('app.charge_after_rental(uuid, uuid, timestamptz)'::regprocedure,
  $o$    v_settle := app.settle_deposit(p_booking, p_by, '{}'::jsonb, p_now);$o$,
  $n$    v_settle := app.settle_deposit(p_booking, p_by, '{"mode": "apply_only"}'::jsonb, p_now);$n$);

-- a pay link for a later charge on a closed booking (tickets arrive weeks later)
select pg_temp.patch_fn('app.payreq_create(uuid, jsonb)'::regprocedure,
  $o$  if b.status in ('cancelled', 'declined', 'expired', 'closed') then raise exception$o$,
  $n$  if b.status in ('cancelled', 'declined', 'expired', 'closed') and not (b.status = 'closed' and v_kind = 'charge' and v_covers = 'later') then raise exception$n$);

-- ================================================================ 6. the Settle screen
alter function app.deposit_preview(uuid, uuid) rename to deposit_preview_pre0155;
create or replace function app.deposit_preview(p_by uuid, p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.deposit_preview_pre0155(p_by, p_booking);
begin
  return v || jsonb_build_object('guard', app.deposit_guard_facts(p_booking) || jsonb_build_object('is_admin', app.user_is_admin(p_by)),
    'deductible_cents', (app.settings()).deductible_cents);
end $$;

-- the screen's settle: inside the toll window a release needs a hold-back or "Release now anyway"
create or replace function app.deposit_settle_screen(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  b bookings;
  f jsonb;
  v_hold bigint := coalesce(nullif(p_ ->> 'hold_back_cents', '')::bigint, 0);
  v_now_ok boolean := coalesce((p_ ->> 'release_now')::boolean, false);
begin
  if not app.user_runs_finance(p_user) then raise exception 'Finance or an Admin settles a Deposit' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p_ ->> 'booking' or booking_number = upper(btrim(coalesce(p_ ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  f := app.deposit_guard_facts(b.id);
  -- (no Check-in statement yet: the settlement says so itself)
  if exists (select 1 from booking_statements x where x.booking_id = b.id and x.kind = 'check_in') and (f ->> 'remaining_cents')::bigint > v_hold and coalesce((f ->> 'within_window')::boolean, false) and not coalesce((f ->> 'blocked')::boolean, false) and not v_now_ok then
    raise exception 'Tolls and tickets can take up to % days to come in (until %). Hold back an amount until then, or choose Release now anyway.',
      f ->> 'toll_window_days', to_char((f ->> 'toll_window_ends_on')::date, 'FMMonth FMDD') using errcode = '23514';
  end if;
  return app.settle_deposit(b.id, p_user,
    jsonb_strip_nulls(jsonb_build_object('hold_back_cents', v_hold,
                                         'hold_back_reason', nullif(btrim(coalesce(p_ ->> 'hold_back_reason', '')), ''),
                                         'hold_back_until', nullif(p_ ->> 'hold_back_until', ''),
                                         'override_reason', nullif(btrim(coalesce(p_ ->> 'override_reason', '')), ''),
                                         'release_in_window', case when v_now_ok then true end)), now());
end $$;

-- A damage charge (an Admin): the amount (up to the deductible), what happened and the photos; the renter is told. After
-- the return it is put on a statement and taken from the deposit first, then the card on file, then the balance follow-up.
create or replace function app.damage_charge_add(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  f fee_types;
  s program_settings := app.settings();
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_photos jsonb := coalesce(p -> 'photos', '[]'::jsonb);
  v_doc uuid := nullif(p ->> 'document', '')::uuid;
  v_line uuid;
  v_res jsonb;
begin
  if not app.user_is_admin(p_by) then raise exception 'An Admin bills damage' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.booking_type = 'owner' then raise exception 'An Owner Booking''s damage is billed to the owner' using errcode = '23514'; end if;
  if b.status not in ('on_rent', 'returned', 'closed') then raise exception 'Damage is billed once the car has been handed over' using errcode = '23514'; end if;
  if v_reason is null or length(v_reason) < 10 then raise exception 'Say what was damaged (10 characters or more): the renter sees it' using errcode = '22023'; end if;
  if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount of the damage' using errcode = '22023'; end if;
  if v_amount > s.deductible_cents then
    raise exception 'Damage above % goes through a claim (Incidents): the renter pays at most the deductible here', app.fmt_money(s.deductible_cents) using errcode = '23514';
  end if;
  if jsonb_typeof(v_photos) <> 'array' then raise exception 'The photos are a list' using errcode = '22023'; end if;
  if jsonb_array_length(v_photos) = 0 and v_doc is null then raise exception 'Add the damage photos or the estimate: the renter is charged only with them' using errcode = '22023'; end if;
  select * into f from fee_types where code = 'damage_at_cost';
  insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents,
                                  revenue_class, stage, supporting_document_id, supporting_refs, assessment_key, created_by)
  values (b.id, f.code, 'Damage: ' || v_reason, 1, v_amount, v_amount, f.hst_applies, case when f.hst_applies then public.calc_hst(v_amount, b.hst_bps) else 0 end,
          f.revenue_class, 'after_return', v_doc,
          jsonb_build_object('kind', 'damage_direct', 'reason', v_reason, 'photos', v_photos, 'added_by', p_by, 'kept_whole', coalesce((p ->> 'kept_whole')::boolean, false)),
          'damage:direct:' || gen_random_uuid(), p_by)
  returning id into v_line;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('Damage charge of %s: %s', app.fmt_money(v_amount), v_reason), p_by, 'staff', jsonb_build_object('line_item_id', v_line, 'photos', v_photos));
  -- after the return, with the Check-in statement: a statement and the deposit first (0021's charge, never a release)
  if b.status in ('returned', 'closed') and exists (select 1 from booking_statements x where x.booking_id = b.id and x.kind = 'check_in') then
    v_res := app.charge_after_rental(b.id, p_by, now());
  end if;
  perform app.emit_event('renter_extra_charge', 'booking_line_item', v_line,
    jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'renter_id', b.renter_id,
                       'charge_kind', 'damage', 'line_item_id', v_line, 'charge_type', f.code,
                       'amount_cents', v_amount, 'hst_cents', 0, 'total_cents', v_amount,
                       'document_ids', case when v_doc is not null then jsonb_build_array(v_doc) else '[]'::jsonb end,
                       'charged_from', case when (select d.status from deposits d where d.booking_id = b.id) in ('held', 'captured') then 'deposit' else 'card_on_file' end),
    'renter_extra_charge:' || v_line || ':damage');
  return jsonb_build_object('ok', true, 'line_item_id', v_line, 'booking_id', b.id, 'charged', v_res);
end $$;

-- Keep the whole deposit (damage), an Admin: what is left of the deposit after the other charges becomes a damage line
-- (with the reason and the photos), put on a statement and applied. Nothing is released.
create or replace function app.deposit_keep_whole(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  d deposits;
  f jsonb;
  v_amount bigint;
  v_out jsonb;
begin
  if not app.user_is_admin(p_by) then raise exception 'An Admin keeps a deposit for damage' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status not in ('returned', 'closed') then raise exception 'The deposit is kept after the return' using errcode = '23514'; end if;
  if not exists (select 1 from booking_statements x where x.booking_id = b.id and x.kind = 'check_in') then
    raise exception 'Issue the Check-in statement first (it needs the return reviewed)' using errcode = '23514';
  end if;
  select * into d from deposits where booking_id = b.id;
  if d.id is null or d.status not in ('held', 'captured', 'settled') then raise exception 'No deposit was taken on this booking' using errcode = '23514'; end if;
  f := app.deposit_guard_facts(b.id);
  v_amount := (f ->> 'remaining_cents')::bigint;
  if v_amount <= 0 then raise exception 'Nothing is left of the deposit to keep: the charges already use it' using errcode = '23514'; end if;
  v_out := app.damage_charge_add(p_by, p || jsonb_build_object('booking', b.id, 'amount_cents', least(v_amount, (app.settings()).deductible_cents), 'kept_whole', true));
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('The whole deposit was kept for damage (%s)', app.fmt_money(v_amount)), p_by, 'staff', jsonb_build_object('kept_whole', true));
  return v_out || jsonb_build_object('kept_cents', v_amount);
end $$;

-- A hold released, or captured in part (which releases the rest), while the car is out, returned inside the toll window,
-- or with anything still open: an Admin, with the reason.
alter function app.hold_action_begin(uuid, jsonb) rename to hold_action_begin_pre0155;
create or replace function app.hold_action_begin(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  d deposits;
  f jsonb;
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_frees boolean;
  v_reason text := nullif(btrim(coalesce(p ->> 'override_reason', p ->> 'reason', '')), '');
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  select * into d from deposits where booking_id = b.id;
  if b.id is not null and d.id is not null and d.method = 'card_hold' and d.status = 'held' then
    v_frees := p ->> 'action' = 'release' or (p ->> 'action' = 'capture' and v_amount is not null and v_amount < d.amount_cents);
    if v_frees and b.status in ('on_rent', 'returned', 'closed') then
      f := app.deposit_guard_facts(b.id);
      if b.status = 'on_rent' or coalesce((f ->> 'blocked')::boolean, false) or coalesce((f ->> 'within_window')::boolean, false) then
        if not app.user_is_admin(p_by) or v_reason is null or length(v_reason) < 10 then
          raise exception 'The deposit stays held: %. Settle it after the return (Settle the deposit), or an Admin releases it with the reason.',
            coalesce((select string_agg(x ->> 'label', '; ') from jsonb_array_elements(f -> 'blockers') x),
                     case when b.status = 'on_rent' then 'the car is still on the road' else format('tolls and tickets can come in until %s', f ->> 'toll_window_ends_on') end)
            using errcode = '23514';
        end if;
        insert into deposit_overrides (booking_id, deposit_id, kind, amount_cents, blockers, reason, created_by)
        values (b.id, d.id, 'hold_action', case when p ->> 'action' = 'release' then d.amount_cents else d.amount_cents - v_amount end, coalesce(f -> 'blockers', '[]'::jsonb), v_reason, p_by);
      end if;
    end if;
  end if;
  return app.hold_action_begin_pre0155(p_by, p);
end $$;

-- ================================================================ 7. the money runner (the server executes, the database records)
-- What the server needs to execute one marked payment at Stripe.
create or replace function public.server_money_action(p_payment uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  p payments;
  b bookings;
  par payments;
  pd payment_processor_details;
  v_card jsonb;
  v_skip boolean := false;
begin
  select * into p from payments where id = p_payment;
  if p.id is null or p.server_action is null then return null; end if;
  -- older than the automatic limit: never run by itself (the sweep gives Finance a task to review it)
  if p.created_at < now() - make_interval(days => (app.settings()).deposit_auto_max_age_days) then return null; end if;
  select * into b from bookings where id = p.booking_id;
  select * into par from payments where id = p.parent_payment_id;
  if p.server_action in ('capture_deposit', 'protect_capture', 'release_hold', 'refund_deposit') then
    -- the hold, or the deposit's charge (or the capture that took it) for a refund
    select * into pd from payment_processor_details where payment_id = coalesce(par.id, (select d.hold_payment_id from deposits d where d.booking_id = p.booking_id));
  end if;
  if p.server_action = 'release_hold' then
    -- a capture of the same hold (whole or in part) already ended it: Stripe released the rest with the capture
    v_skip := exists (select 1 from payments c where c.parent_payment_id = p.parent_payment_id and c.kind = 'capture' and c.id <> p.id and c.status in ('succeeded', 'pending'))
              or par.status in ('succeeded', 'cancelled');
  end if;
  if p.server_action in ('charge_card', 'deposit_charge', 'balance_charge') then
    v_card := coalesce((select jsonb_build_object('payment_method_id', pm.id, 'customer_id', sc.processor_customer_id, 'method_id', sc.processor_method_id)
                          from payment_methods pm join payment_method_secrets sc on sc.payment_method_id = pm.id
                         where pm.id = p.payment_method_id and sc.processor_method_id is not null), app.booking_saved_card(p.booking_id));
  end if;
  return jsonb_build_object('payment_id', p.id, 'action', p.server_action, 'status', p.status, 'amount_cents', p.amount_cents,
    'booking_id', b.id, 'booking_number', b.booking_number, 'intent_id', pd.processor_payment_id, 'charge_id', pd.processor_charge_id,
    'customer_id', v_card ->> 'customer_id', 'method_id', v_card ->> 'method_id', 'skip_processor', v_skip,
    'idempotency_key', 'money:' || p.id, 'attempts', p.server_attempts);
end $$;

-- A lapsed hold: recorded as lost; on a rental on the road or after it, the deposit is charged to the saved card when
-- the setting allows (the renter agreed to it in the rental agreement), else Finance is told at once.
create or replace function app.deposit_hold_lapsed(p_deposit uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d deposits;
  b bookings;
  v_card jsonb;
  v_pay uuid;
  v_amount bigint;
begin
  select * into d from deposits where id = p_deposit for update;
  if d.id is null or d.status <> 'held' then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  select * into b from bookings where id = d.booking_id;
  v_amount := d.amount_cents - d.applied_cents - d.released_cents;
  update deposits set status = 'failed' where id = d.id;
  update payments set status = 'cancelled' where id = d.hold_payment_id and status = 'authorized';
  insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note) values (d.id, 'failed', d.amount_cents, d.hold_payment_id, coalesce(p_note, 'The card hold lapsed'));
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null, format('The deposit hold of %s lapsed at the bank', app.fmt_money(d.amount_cents)), null, 'system');
  if b.status = 'confirmed' then
    perform app.raise_task(p_type => 'renew_deposit_hold', p_title => format('Booking %s: the deposit hold lapsed before the pickup: place a new one', b.booking_number),
      p_booking => b.id, p_renter => b.renter_id, p_dedupe => 'renew_deposit_hold:' || b.id);
    return jsonb_build_object('ok', true, 'lapsed', true, 'next', null);
  end if;
  v_card := app.booking_saved_card(b.id);
  if (app.settings()).deposit_auto_capture and v_card is not null and v_amount > 0 and b.status in ('on_rent', 'returned', 'closed')
     and coalesce(d.hold_expires_at, now()) > now() - make_interval(days => (app.settings()).deposit_auto_max_age_days) then
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, payment_method_id, card_brand, card_last4, server_action)
    values (b.id, b.renter_id, 'deposit', 'charge', 'card', d.amount_cents, 'pending', (v_card ->> 'payment_method_id')::uuid, v_card ->> 'brand', v_card ->> 'last4', 'deposit_charge')
    returning id into v_pay;
  end if;
  perform app.raise_task(p_type => 'deposit_hold_lapsed',
    p_title => format('Booking %s: the deposit hold of %s lapsed%s', b.booking_number, app.fmt_money(d.amount_cents),
                      case when v_pay is not null then ': it is being charged to the saved card' else ': charge the saved card or ask the renter to pay' end),
    p_detail => 'Money tab: Charge the saved card, The deposit. With no card, Collect a card sends the renter a pay link.',
    p_booking => b.id, p_renter => b.renter_id, p_dedupe => 'deposit_hold_lapsed:' || d.id, p_escalation_reason => 'deposit hold lapsed');
  return jsonb_build_object('ok', true, 'lapsed', true, 'next', case when v_pay is not null then public.server_money_action(v_pay) end);
end $$;

-- Stripe's answer for one marked payment. p: {ok, error, intent_status, charge_id, refund_id, refund_status}
create or replace function public.server_money_action_finish(p_payment uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x payments;
  d deposits;
  b bookings;
  v_ok boolean := coalesce((p ->> 'ok')::boolean, false);
  v_err text := left(nullif(btrim(coalesce(p ->> 'error', '')), ''), 300);
  v_lapsed boolean := coalesce(p ->> 'intent_status', '') = 'canceled';
  v_next jsonb;
  v_dep uuid;
begin
  select * into x from payments where id = p_payment for update;
  if x.id is null or x.server_action is null then raise exception 'Not a payment for the server' using errcode = '22023'; end if;
  if x.status <> 'pending' then return jsonb_build_object('ok', true, 'repeat', true, 'status', x.status); end if;
  select * into b from bookings where id = x.booking_id;
  select * into d from deposits where booking_id = x.booking_id for update;
  update payments set server_attempts = server_attempts + 1, server_attempted_at = now(), server_last_error = v_err where id = x.id;

  if v_ok then
    if x.server_action in ('charge_card', 'balance_charge') then
      insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, raw)
      values (x.id, 'stripe', p ->> 'intent_id', p ->> 'charge_id', jsonb_build_object('server_action', x.server_action)) on conflict (payment_id) do nothing;
      -- a balance charge pays the open lines, oldest first; 0023 sends the receipt of a charge after the rental
      if x.server_action = 'balance_charge' then perform app.tie_later_lines(x.booking_id, x.id); end if;
      perform app.post_rental_payment_result(x.id, true, null);
    elsif x.server_action = 'refund_deposit' then
      insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_refund_id, raw)
      values (x.id, 'stripe', p ->> 'intent_id', p ->> 'refund_id', jsonb_build_object('server_action', x.server_action, 'status', p ->> 'refund_status'))
      on conflict (payment_id) do update set processor_refund_id = coalesce(payment_processor_details.processor_refund_id, excluded.processor_refund_id);
      -- a refund the bank confirms later is settled by the refund webhook (0132); it is not sent again
      update payments set status = case when coalesce(p ->> 'refund_status', 'succeeded') = 'succeeded' then 'succeeded' else 'pending' end, processed_at = now(),
             server_attempts = case when coalesce(p ->> 'refund_status', 'succeeded') = 'succeeded' then server_attempts else 99 end
       where id = x.id;
    elsif x.server_action = 'release_hold' then
      update payments set status = 'succeeded', processed_at = now() where id = x.id;
      update payments set status = 'cancelled' where id = x.parent_payment_id and status = 'authorized';
    elsif x.server_action in ('capture_deposit', 'protect_capture') then
      update payments set status = 'succeeded', processed_at = now() where id = x.id;
      update payments set status = 'succeeded' where id = x.parent_payment_id and status = 'authorized';
      insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, raw)
      values (x.id, 'stripe', p ->> 'intent_id', p ->> 'charge_id', jsonb_build_object('server_action', x.server_action)) on conflict (payment_id) do nothing;
      if x.server_action = 'protect_capture' and d.status = 'held' then
        update deposits set status = 'captured', captured_cents = x.amount_cents where id = d.id;
        insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note)
        values (d.id, 'captured', x.amount_cents, x.id, 'Captured in full before the card hold lapsed (protection: the settlement refunds what is not owed)');
        perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
          format('Deposit of %s captured before the card hold lapsed; what is not owed is refunded at the settlement', app.fmt_money(x.amount_cents)), null, 'system',
          jsonb_build_object('payment_id', x.id));
      end if;
    elsif x.server_action = 'deposit_charge' then
      update payments set status = 'succeeded', processed_at = now() where id = x.id;
      insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, raw)
      values (x.id, 'stripe', p ->> 'intent_id', p ->> 'charge_id', jsonb_build_object('server_action', x.server_action)) on conflict (payment_id) do nothing;
      insert into deposits as dd (booking_id, amount_cents, method, status, hold_payment_id, taken_at, captured_cents)
      values (x.booking_id, x.amount_cents, 'charged', 'captured', x.id, now(), x.amount_cents)
      on conflict (booking_id) do update set amount_cents = excluded.amount_cents, method = 'charged', paid_method = null, status = 'captured',
             hold_payment_id = excluded.hold_payment_id, taken_at = excluded.taken_at, hold_expires_at = null, captured_cents = excluded.captured_cents,
             applied_cents = 0, held_back_cents = 0, held_back_reason = null, held_back_until = null, released_cents = 0
       where dd.status in ('pending', 'failed')
      returning id into v_dep;
      if v_dep is not null then
        insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note) values (v_dep, 'taken', x.amount_cents, x.id, 'charged to the saved card after the hold lapsed');
        perform app.resolve_tasks(array['deposit_hold_lapsed', 'take_deposit', 'deposit_declined'], x.booking_id, null, 'Deposit charged to the saved card');
      end if;
      perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null, format('Deposit of %s charged to the saved card', app.fmt_money(x.amount_cents)), null, 'system');
    end if;
    return jsonb_build_object('ok', true, 'payment_id', x.id);
  end if;

  -- refused
  if x.server_action in ('capture_deposit', 'protect_capture') and (v_lapsed or x.server_attempts + 1 >= 3) then
    update payments set status = 'failed', last_decline_code = left(coalesce(v_err, 'refused'), 60), processed_at = now() where id = x.id;
    if x.server_action = 'protect_capture' then
      v_next := app.deposit_hold_lapsed(d.id, coalesce('Capture refused: ' || v_err, 'The card hold lapsed'));
    else
      -- the settlement's capture: what it applied is open again (the balance follow-up charges the card or sends a pay link)
      update deposits set status = 'failed', captured_cents = greatest(captured_cents - x.amount_cents, 0) where id = d.id;
      insert into deposit_events (deposit_id, kind, amount_cents, payment_id, note) values (d.id, 'failed', x.amount_cents, x.id, coalesce('Capture refused: ' || v_err, 'Capture refused'));
      perform app.raise_task(p_type => 'deposit_capture_failed',
        p_title => format('Booking %s: the deposit capture of %s was refused%s', b.booking_number, app.fmt_money(x.amount_cents), coalesce(' (' || v_err || ')', '')),
        p_detail => 'What the deposit was to pay is open again: the card on file is charged, else the renter gets a pay link. Check the Money tab.',
        p_booking => b.id, p_renter => b.renter_id, p_dedupe => 'deposit_capture_failed:' || x.id, p_escalation_reason => 'deposit capture refused');
      v_next := jsonb_build_object('balance', true);
    end if;
    return jsonb_build_object('ok', false, 'payment_id', x.id, 'next', v_next);
  end if;
  if x.server_action in ('charge_card', 'balance_charge') then
    perform app.post_rental_payment_result(x.id, false, left(coalesce(v_err, 'declined'), 60));
    return jsonb_build_object('ok', false, 'payment_id', x.id, 'next', jsonb_build_object('balance', true));
  end if;
  if x.server_action = 'deposit_charge' then
    update payments set status = 'failed', last_decline_code = left(coalesce(v_err, 'declined'), 60), processed_at = now() where id = x.id;
    return jsonb_build_object('ok', false, 'payment_id', x.id);
  end if;
  if x.server_attempts + 1 >= 5 then
    update payments set status = 'failed', last_decline_code = left(coalesce(v_err, 'refused'), 60), processed_at = now() where id = x.id;
    perform app.raise_task(p_type => 'deposit_money_stuck',
      p_title => format('Booking %s: %s of %s did not go through at Stripe', b.booking_number,
                        case x.server_action when 'release_hold' then 'the hold release' when 'refund_deposit' then 'the deposit refund' else 'a deposit step' end, app.fmt_money(x.amount_cents)),
      p_detail => coalesce('Stripe: ' || v_err || '. ', '') || 'Do it in Stripe or give it back another way, then record it on the booking (Money).',
      p_booking => b.id, p_renter => b.renter_id, p_related_table => 'payments', p_related_id => x.id, p_dedupe => 'deposit_money_stuck:' || x.id);
  end if;
  return jsonb_build_object('ok', false, 'payment_id', x.id);
end $$;

-- The capture before a hold lapses: a pending capture of the whole hold for the server.
create or replace function public.server_deposit_capture_begin(p_deposit uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d deposits;
  b bookings;
  v_pay uuid;
begin
  select * into d from deposits where id = p_deposit for update;
  if d.id is null or d.method <> 'card_hold' or d.status <> 'held' then return null; end if;
  select * into b from bookings where id = d.booking_id;
  select id into v_pay from payments where parent_payment_id = d.hold_payment_id and server_action = 'protect_capture' and status = 'pending';
  if v_pay is null then
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, parent_payment_id, payment_method_id, server_action)
    values (b.id, b.renter_id, 'deposit', 'capture', 'card', d.amount_cents, 'pending', d.hold_payment_id, b.card_on_file_id, 'protect_capture')
    returning id into v_pay;
  end if;
  return public.server_money_action(v_pay);
end $$;

-- Stripe canceled a hold (payment_intent.canceled, cancellation_reason automatic): the hold lapsed.
create or replace function public.server_deposit_hold_lapsed(p_intent text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_dep uuid;
begin
  select d.id into v_dep from deposits d join payment_processor_details pd on pd.payment_id = d.hold_payment_id
   where pd.processor_payment_id = p_intent and d.method = 'card_hold' and d.status = 'held' limit 1;
  if v_dep is null then return jsonb_build_object('ignored', 'no deposit hold of ours is held on that intent'); end if;
  return app.deposit_hold_lapsed(v_dep, 'Stripe canceled the card hold (it lapsed)');
end $$;

-- a deposit refund issued by the runner, reported by Stripe's refund webhook before the runner recorded it: kept on the
-- runner's own payment (metadata refund_id is that payment), never recorded as a refund made outside the site
alter function public.server_stripe_refund_event(jsonb) rename to server_stripe_refund_event_pre0155;
create or replace function public.server_stripe_refund_event(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  rp payments;
begin
  select * into rp from payments where id::text = coalesce(p ->> 'site_refund_id', '') and kind = 'refund' and purpose = 'deposit' and server_action is not null;
  if rp.id is not null and not exists (select 1 from payment_processor_details pd where pd.payment_id = rp.id) then
    insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, processor_refund_id, raw)
    values (rp.id, 'stripe', nullif(p ->> 'intent_id', ''), nullif(p ->> 'charge_id', ''), nullif(p ->> 'refund_id', ''), jsonb_build_object('source', 'webhook'))
    on conflict (payment_id) do nothing;
    if coalesce(p ->> 'status', '') = 'succeeded' then update payments set status = 'succeeded', processed_at = now() where id = rp.id and status = 'pending'; end if;
    return jsonb_build_object('refund', p ->> 'refund_id', 'deposit_refund', rp.id);
  end if;
  return public.server_stripe_refund_event_pre0155(p);
end $$;

-- ================================================================ 8. the balance after the deposit
-- The next step for a booking's balance: the card on file (once, unless it was declined in the last 3 days), else a pay
-- link (one open at a time, by email and text), else a Finance task. A Finance task stays open until it is paid.
create or replace function public.server_balance_next(p_booking uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  rn renters;
  v_open bigint;
  v_card jsonb;
  v_pay uuid;
  v_tried text := '';
  s program_settings := app.settings();
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then return null; end if;
  v_open := app.booking_balance_open(b.id);
  if v_open <= 0 then
    perform app.resolve_tasks(array['collect_balance', 'deposit_money_review'], b.id, null, 'Paid');
    update balance_followups set last_step = 'paid', last_at = now(), open_cents = 0 where booking_id = b.id and last_step <> 'paid';
    return jsonb_build_object('action', 'none', 'open_cents', 0);
  end if;
  if exists (select 1 from payments p where p.booking_id = b.id and p.purpose in ('post_rental', 'deposit') and p.status = 'pending' and p.server_action is not null
              and p.created_at >= now() - make_interval(days => s.deposit_auto_max_age_days)) then
    return jsonb_build_object('action', 'wait', 'open_cents', v_open);
  end if;
  -- a balance older than the automatic limit when first seen (no statement with an open line issued since): never charged
  -- or chased by itself; Finance reviews it. One the guard started in time is followed up to the end.
  if exists (select 1 from balance_followups f where f.booking_id = b.id and f.manual)
     or (not exists (select 1 from balance_followups f where f.booking_id = b.id)
         and not exists (select 1 from booking_line_items l join booking_statements st on st.id = l.statement_id
                          where l.booking_id = b.id and l.voided_at is null and l.charged_to_renter and l.stage <> 'booking' and l.amount_cents > 0
                            and app.line_open_cents(l.id) > 0 and st.issued_at >= now() - make_interval(days => s.deposit_auto_max_age_days))) then
    perform app.raise_task(p_type => 'deposit_money_review',
      p_title => format('Booking %s: %s still owed on statements older than %s days: not collected by itself, review it', b.booking_number, app.fmt_money(v_open), s.deposit_auto_max_age_days),
      p_detail => 'Money tab: Charge the saved card, Collect a card (pay link), Record a payment received another way, or leave it.',
      p_booking => b.id, p_renter => b.renter_id, p_dedupe => 'deposit_money_review:balance:' || b.id);
    insert into balance_followups as f (booking_id, last_step, open_cents, attempts, manual) values (b.id, 'task', v_open, 1, true)
    on conflict (booking_id) do update set last_step = 'task', last_at = now(), open_cents = v_open, manual = true;
    return jsonb_build_object('action', 'review', 'open_cents', v_open);
  end if;
  v_card := app.booking_saved_card(b.id);
  if s.balance_auto_collect and v_card is not null
     and not exists (select 1 from payments p where p.booking_id = b.id and p.purpose = 'post_rental' and p.kind = 'charge' and p.status = 'failed'
                      and p.updated_at > now() - interval '3 days') then
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, payment_method_id, card_brand, card_last4, server_action)
    values (b.id, b.renter_id, 'post_rental', 'charge', 'card', v_open, 'pending', (v_card ->> 'payment_method_id')::uuid, v_card ->> 'brand', v_card ->> 'last4', 'balance_charge')
    returning id into v_pay;
    insert into balance_followups as f (booking_id, last_step, open_cents, attempts) values (b.id, 'charge_card', v_open, 1)
    on conflict (booking_id) do update set last_step = 'charge_card', last_at = now(), open_cents = v_open, attempts = f.attempts + 1;
    return jsonb_build_object('action', 'charge_card', 'open_cents', v_open, 'payment', public.server_money_action(v_pay));
  end if;
  if v_card is not null then v_tried := 'The card on file was declined. '; else v_tried := 'There is no card on file. '; end if;
  select * into rn from renters where id = b.renter_id;
  if s.balance_auto_collect and (coalesce(rn.email, (select u.email from users u where u.id = rn.user_id)) is not null or app.phone_e164(rn.mobile) is not null)
     and not exists (select 1 from payment_requests q where q.booking_id = b.id and q.kind = 'charge' and q.covers = 'later' and q.status = 'open' and q.expires_at > now()) then
    return jsonb_build_object('action', 'pay_link', 'open_cents', v_open, 'booking_id', b.id, 'booking_number', b.booking_number, 'vehicle_name', app.vehicle_name(b.vehicle_id),
      'renter', jsonb_build_object('id', rn.id, 'legal_name', rn.legal_name, 'email', coalesce(rn.email, (select u.email from users u where u.id = rn.user_id)),
                                   'customer_id', v_card ->> 'customer_id'), 'tried', v_tried);
  end if;
  perform app.balance_task(b.id, v_open, v_tried || case when exists (select 1 from payment_requests q where q.booking_id = b.id and q.covers = 'later' and q.status = 'open' and q.expires_at > now())
                                                         then 'A pay link is waiting for the renter.' else 'No pay link could be sent (no email or mobile).' end);
  insert into balance_followups as f (booking_id, last_step, open_cents, attempts) values (b.id, 'task', v_open, 1)
  on conflict (booking_id) do update set last_step = 'task', last_at = now(), open_cents = v_open, attempts = f.attempts + 1;
  return jsonb_build_object('action', 'task', 'open_cents', v_open);
end $$;

create or replace function app.balance_task(p_booking uuid, p_open bigint, p_note text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_id uuid;
begin
  select * into b from bookings where id = p_booking;
  v_id := app.raise_task(p_type => 'collect_balance', p_title => format('Booking %s: %s still owed after the rental', b.booking_number, app.fmt_money(p_open)),
    p_detail => p_note || ' Money tab: Charge the saved card, Collect a card (pay link), or Record a payment received another way.',
    p_booking => b.id, p_renter => b.renter_id, p_dedupe => 'collect_balance:' || b.id);
  update tasks set title = format('Booking %s: %s still owed after the rental', b.booking_number, app.fmt_money(p_open)),
                   detail = p_note || ' Money tab: Charge the saved card, Collect a card (pay link), or Record a payment received another way.'
   where id = v_id;
  return v_id;
end $$;

-- the pay link of a balance (the server made the token; the database keeps its hash)
create or replace function public.server_balance_payreq(p_booking uuid, p_token_sha256 text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_id uuid;
begin
  if p_token_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'The link token is missing' using errcode = '22023'; end if;
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Nothing is owed' using errcode = '22023'; end if;
  update payment_requests set status = 'cancelled' where booking_id = b.id and status = 'open' and kind = 'charge' and covers = 'later';
  insert into payment_requests (booking_id, renter_id, kind, covers, amount_cents, reason, token_sha256, channel, expires_at, created_by)
  values (b.id, b.renter_id, 'charge', 'later', p_amount, 'Charges after the rental', p_token_sha256, 'email', now() + interval '7 days', null)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'booking_id', b.id, 'booking_number', b.booking_number);
end $$;

-- the link sent: by email (the booking's message) and by text when the renter has a mobile; the Finance task records it
create or replace function public.server_balance_payreq_send(p_id uuid, p_link text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q payment_requests;
  b bookings;
  rn renters;
  v_email text;
  v_text boolean := false;
  o phone_outbox;
begin
  select * into q from payment_requests where id = p_id;
  if q.id is null or q.status <> 'open' then raise exception 'That payment request is not open' using errcode = '23514'; end if;
  if p_link is null or p_link !~ '^https?://[^ ]+/pay/[A-Za-z0-9_-]{20,}$'
     or encode(sha256(convert_to(regexp_replace(p_link, '^.*/pay/', ''), 'UTF8')), 'hex') <> q.token_sha256 then
    raise exception 'That link is not this request''s' using errcode = '22023';
  end if;
  select * into b from bookings where id = q.booking_id;
  select * into rn from renters where id = b.renter_id;
  v_email := coalesce(rn.email, (select u.email from users u where u.id = rn.user_id));
  if v_email is not null then
    perform app.staff_send_message(null, b.id, 'Payment for booking ' || b.booking_number,
      format('Hi %s, %s is owed for charges after your rental (they are on your statement). Please pay with this secure link: %s. The card is entered in Stripe''s own form; CarmaCars never sees the card number.',
             coalesce(nullif(split_part(btrim(rn.legal_name), ' ', 1), ''), 'there'), app.fmt_money(q.amount_cents), p_link));
  end if;
  if app.phone_e164(rn.mobile) is not null then
    o := app.phone_outbox_put(rn.mobile, format('CarmaCars: booking %s, %s owed for charges after the rental. Pay securely: %s', b.booking_number, app.fmt_money(q.amount_cents), p_link),
                              'staff', b.id, rn.id, 'pay_link', null, 'payreq:' || q.id, now(), 'queued', null);
    v_text := o.status <> 'skipped';
  end if;
  perform app.balance_task(b.id, q.amount_cents,
    case when exists (select 1 from payments p where p.booking_id = b.id and p.purpose = 'post_rental' and p.status = 'failed') then 'The card on file was declined. '
         when app.booking_saved_card(b.id) is null then 'There is no card on file. ' else '' end
    || format('A pay link for %s went to the renter on %s%s.', app.fmt_money(q.amount_cents), to_char(now() at time zone 'America/Toronto', 'Mon FMDD'),
              case when v_email is not null and v_text then ' by email and text' when v_text then ' by text' when v_email is not null then ' by email' else '' end));
  insert into balance_followups as f (booking_id, last_step, open_cents, attempts) values (b.id, 'pay_link', q.amount_cents, 1)
  on conflict (booking_id) do update set last_step = 'pay_link', last_at = now(), open_cents = q.amount_cents, attempts = f.attempts + 1;
  return jsonb_build_object('ok', true, 'email', v_email is not null, 'text', v_text);
end $$;

-- ================================================================ 9. the daily job
-- What the job does: tasks first (in the database), then the lists for the server: holds to capture now, marked
-- payments still waiting, balances to follow up (once a day each).
create or replace function public.server_deposit_guard_sweep() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  r record;
  v_captures jsonb := '[]'::jsonb;
begin
  -- a hold that lapses before the pickup of a booking not on the road yet: Finance places a new one at the pickup
  for r in select d.id, b.id as booking_id, b.booking_number, b.renter_id, d.hold_expires_at from deposits d join bookings b on b.id = d.booking_id
            where d.method = 'card_hold' and d.status = 'held' and b.status = 'confirmed' and d.hold_expires_at < b.pickup_at
              and d.hold_expires_at <= now() + make_interval(hours => s.deposit_hold_capture_hours) loop
    perform app.raise_task(p_type => 'renew_deposit_hold',
      p_title => format('Booking %s: the deposit hold lapses %s, before the pickup: place a new one at the pickup', r.booking_number,
                        to_char(r.hold_expires_at at time zone 'America/Toronto', 'Mon FMDD')),
      p_booking => r.booking_id, p_renter => r.renter_id, p_dedupe => 'renew_deposit_hold:' || r.booking_id);
  end loop;
  -- the holds to capture now: on the road, returned, or closed with anything still held
  if s.deposit_auto_capture then
    select coalesce(jsonb_agg(jsonb_build_object('deposit_id', d.id, 'booking_number', b.booking_number) order by d.hold_expires_at), '[]'::jsonb) into v_captures
      from deposits d join bookings b on b.id = d.booking_id
     where d.method = 'card_hold' and d.status = 'held' and b.status in ('on_rent', 'returned', 'closed')
       and d.hold_expires_at > now() and d.hold_expires_at <= now() + make_interval(hours => s.deposit_hold_capture_hours);
  end if;
  -- a hold the records still call held after it lapsed: never captured or charged by itself; Finance reviews it
  for r in select d.id, b.id as booking_id, b.booking_number, b.renter_id, d.hold_expires_at from deposits d join bookings b on b.id = d.booking_id
            where d.method = 'card_hold' and d.status = 'held' and b.status in ('on_rent', 'returned', 'closed') and d.hold_expires_at <= now() loop
    perform app.raise_task(p_type => 'deposit_money_review',
      p_title => format('Booking %s: the deposit hold lapsed on %s but is still recorded as held: check Stripe, then settle or charge by hand', r.booking_number,
                        to_char(r.hold_expires_at at time zone 'America/Toronto', 'Mon FMDD')),
      p_booking => r.booking_id, p_renter => r.renter_id, p_dedupe => 'deposit_money_review:hold:' || r.id);
  end loop;
  -- a money step left pending longer than the automatic limit: never run by itself; Finance reviews it
  for r in select p.id, p.booking_id, b.booking_number, b.renter_id, p.server_action, p.amount_cents, p.created_at from payments p join bookings b on b.id = p.booking_id
            where p.status = 'pending' and p.server_action is not null and p.created_at < now() - make_interval(days => s.deposit_auto_max_age_days) loop
    perform app.raise_task(p_type => 'deposit_money_review',
      p_title => format('Booking %s: %s of %s from %s was never done: check Stripe and do it by hand, or cancel it', r.booking_number,
                        case r.server_action when 'release_hold' then 'a hold release' when 'refund_deposit' then 'a deposit refund' when 'capture_deposit' then 'a deposit capture'
                                             when 'protect_capture' then 'a deposit capture' else 'a card charge' end,
                        app.fmt_money(r.amount_cents), to_char(r.created_at at time zone 'America/Toronto', 'Mon FMDD, YYYY')),
      p_booking => r.booking_id, p_renter => r.renter_id, p_related_table => 'payments', p_related_id => r.id, p_dedupe => 'deposit_money_review:payment:' || r.id);
  end loop;
  -- a balance paid since: its task closes
  for r in select f.booking_id from balance_followups f where f.last_step <> 'paid' loop
    if app.booking_balance_open(r.booking_id) <= 0 then
      perform app.resolve_tasks(array['collect_balance', 'deposit_money_review'], r.booking_id, null, 'Paid');
      update balance_followups set last_step = 'paid', last_at = now(), open_cents = 0 where booking_id = r.booking_id;
    end if;
  end loop;
  update deposit_guard_state set last_sweep_at = now() where id;
  return jsonb_build_object(
    'captures', v_captures,
    'payments', coalesce((select jsonb_agg(p.id order by case p.server_action when 'capture_deposit' then 0 when 'protect_capture' then 0 else 1 end, p.created_at)
                            from payments p where p.status = 'pending' and p.server_action is not null and p.server_attempts < 5
                             and p.created_at >= now() - make_interval(days => s.deposit_auto_max_age_days)
                             and coalesce(p.server_attempted_at, p.created_at) < now() - interval '5 minutes'), '[]'::jsonb),
    'balances', coalesce((select jsonb_agg(b.id) from bookings b
                           where b.status in ('returned', 'closed') and b.booking_type <> 'owner'
                             and exists (select 1 from booking_line_items l left join payments p on p.id = l.payment_id
                                          where l.booking_id = b.id and l.statement_id is not null and l.voided_at is null and l.charged_to_renter and l.stage <> 'booking'
                                            and l.amount_cents > 0 and (l.payment_id is null or p.status in ('failed', 'cancelled')
                                                                        or exists (select 1 from deposit_events e join payments px on px.id = e.payment_id
                                                                                    where e.line_item_id = l.id and e.kind = 'applied' and px.status in ('failed', 'cancelled'))))
                             and app.booking_balance_open(b.id) > 0
                             and not exists (select 1 from balance_followups f where f.booking_id = b.id and f.last_at > now() - interval '20 hours')), '[]'::jsonb));
end $$;

-- the cron gate: a hold to capture, a payment waiting for the server, or the day's sweep not done
create or replace function app.deposit_guard_due() returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from deposits d join bookings b on b.id = d.booking_id
                  where d.method = 'card_hold' and d.status = 'held' and b.status in ('on_rent', 'returned', 'closed')
                    and d.hold_expires_at > now() and d.hold_expires_at <= now() + make_interval(hours => (app.settings()).deposit_hold_capture_hours))
      or exists (select 1 from payments p where p.status = 'pending' and p.server_action is not null and p.server_attempts < 5
                   and p.created_at >= now() - make_interval(days => (app.settings()).deposit_auto_max_age_days)
                   and coalesce(p.server_attempted_at, p.created_at) < now() - interval '5 minutes')
      or coalesce((select last_sweep_at from deposit_guard_state where id), '-infinity'::timestamptz) < now() - interval '20 hours'
$$;
alter function app.server_jobs_due() rename to server_jobs_due_pre0155;
create or replace function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  return app.server_jobs_due_pre0155() || jsonb_build_object('deposits', app.deposit_guard_due());
end $$;

-- ================================================================ 10. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0155;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if (p_call = 'ops_do' and p_name in ('deposit_settle', 'deposit_keep_whole', 'damage_charge_add'))
     or (p_call = 'admin_do' and p_name = 'settle_deposit') or (p_call = 'va_do' and p_name = 'settle_deposit') then
    perform app.door_begin(p_user, p_aal);
    if p_call = 'admin_do' and not app.user_is_admin(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return case p_name
      when 'deposit_keep_whole' then app.deposit_keep_whole(p_user, p_)
      when 'damage_charge_add' then app.damage_charge_add(p_user, p_)
      else app.deposit_settle_screen(p_user, case when p_ ? 'plan' then (p_ - 'plan') || (p_ -> 'plan') else p_ end) end;
  end if;
  return app.door_pre0155(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 11. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['door', 'door_pre0155', 'deposit_blockers', 'deposit_guard_facts', 'line_open_cents', 'booking_balance_open',
              'tie_later_lines', 'booking_tie_lines', 'booking_tie_lines_pre0155', 'booking_saved_card', 'settle_deposit', 'settle_deposit_pre0155', 'settle_deposit_pre0129',
              'charge_after_rental', 'payreq_create', 'deposit_preview', 'deposit_preview_pre0155', 'deposit_settle_screen', 'damage_charge_add', 'deposit_keep_whole',
              'hold_action_begin', 'hold_action_begin_pre0155', 'deposit_hold_lapsed', 'balance_task', 'deposit_guard_due', 'server_jobs_due', 'server_jobs_due_pre0155',
              'deposit_overrides_append_only']))
        or (n.nspname = 'public' and p.proname = any (array['server_money_action', 'server_money_action_finish', 'server_deposit_capture_begin', 'server_deposit_hold_lapsed',
              'server_stripe_refund_event', 'server_stripe_refund_event_pre0155', 'server_balance_next', 'server_balance_payreq', 'server_balance_payreq_send',
              'server_deposit_guard_sweep']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ the guides
-- GUIDES 0155 START (generated by supabase/seed/0155_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'requests-offers-and-bookings', 'chapter', 'people-and-access', 'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 18.5 21.2, 2 25.3 31.7")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-84570463.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 1 21.7 16.4, 2 20.0 45.4, 3 65.0 45.4, 4 96.5 98.8")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg "desktop; size: 620 810; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 5 91.9 33.6")

## Send an offer without a request

**Bookings** > **Send an offer**, or **Send an offer** on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.

1. The customer: type a name, phone or email and choose them. Not on file? Press **Add a new customer**: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.
2. The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).
3. The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason and can be plus tax or tax included. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.
4. How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).
5. Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.
6. The right side is the offer as the renter will see it, priced by the database as you type. Press **Send the offer**. **Save without sending** keeps it as a request for later.

> Good to know: It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.

## Change an offer that is out

The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press **Edit the offer** on the booking.

1. Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed.
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

## Correct a renter''s details

On the renter''s page (People, Renters) or on any of their bookings, **Edit renter**.

1. Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.
2. A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick **Email the renter a link to set a password** to send one there. Unsigned agreements and offers go to the new address.
3. Press **Save the renter**. An email that another renter has is refused with their name; the same phone is a warning.

## Payments by part: the rental, the deposit and later charges

On the booking''s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.

1. **Record a payment**: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press **Record it**. The renter gets a receipt; **Print** prints one to hand over.
2. **Collect a card**: a payment, the deposit hold or saving the card. The renter types the card in Stripe''s secure form: on this device (**Open the card form**, then hand it over) or by a link texted or emailed to them (**Send the link**). Staff never type a card number.
3. A deposit hold lasts about 7 days and shows the days left. After the return, **Capture the hold** (all or part, with the reason) or **Release the hold**.
4. **Charge the saved card** (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter''s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.
5. An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press **Confirm the booking**).
6. A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press **Returned** with the reference or receipt number.

> Good to know: Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10057; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

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
2. **Sign now on this device**: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press **Hand the device to** and their name.
3. They read both agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign. Then **Back to the staff view** for the next signer.
4. The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy''s signature record page.

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

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-out (photos and four checks): the history says "checked in person".

## Payments by day

**Money** > **Payments by day**: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.

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

![](/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg "desktop; size: 1230 530; address: carmacars.ca/admin/bookings/CC-10057?tab=changes; pins: 1 12.9 15.3, 2 35.0 30.6, 3 49.8 59.1, 4 30.9 73.2")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

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
', 'Requests, offers and bookings', 'Send an offer with or without a request, change it in place, take payments by part, run a booking, propose a change.',
  'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 18.5 21.2, 2 25.3 31.7")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-84570463.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 1 21.7 16.4, 2 20.0 45.4, 3 65.0 45.4, 4 96.5 98.8")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg "desktop; size: 620 810; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 5 91.9 33.6")

## Send an offer without a request

**Bookings** > **Send an offer**, or **Send an offer** on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.

1. The customer: type a name, phone or email and choose them. Not on file? Press **Add a new customer**: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.
2. The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).
3. The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason and can be plus tax or tax included. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.
4. How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).
5. Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.
6. The right side is the offer as the renter will see it, priced by the database as you type. Press **Send the offer**. **Save without sending** keeps it as a request for later.

> Good to know: It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.

## Change an offer that is out

The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press **Edit the offer** on the booking.

1. Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed.
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

## Correct a renter''s details

On the renter''s page (People, Renters) or on any of their bookings, **Edit renter**.

1. Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.
2. A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick **Email the renter a link to set a password** to send one there. Unsigned agreements and offers go to the new address.
3. Press **Save the renter**. An email that another renter has is refused with their name; the same phone is a warning.

## Payments by part: the rental, the deposit and later charges

On the booking''s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.

1. **Record a payment**: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press **Record it**. The renter gets a receipt; **Print** prints one to hand over.
2. **Collect a card**: a payment, the deposit hold or saving the card. The renter types the card in Stripe''s secure form: on this device (**Open the card form**, then hand it over) or by a link texted or emailed to them (**Send the link**). Staff never type a card number.
3. A deposit hold lasts about 7 days and shows the days left; while the car is out it is collected by itself before it lapses. After the return, settle the deposit (below). **Capture the hold** for all of it keeps the money; a part capture or **Release the hold** waits for the settlement while the car is out or something is open (an Admin may do it with the reason).
4. **Charge the saved card** (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter''s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.
5. An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press **Confirm the booking**).
6. A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press **Returned** with the reference or receipt number.

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
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10057; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

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
2. **Sign now on this device**: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press **Hand the device to** and their name.
3. They read both agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign. Then **Back to the staff view** for the next signer.
4. The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy''s signature record page.

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

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-out (photos and four checks): the history says "checked in person".

## Payments by day

**Money** > **Payments by day**: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.

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

![](/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg "desktop; size: 1230 530; address: carmacars.ca/admin/bookings/CC-10057?tab=changes; pins: 1 12.9 15.3, 2 35.0 30.6, 3 49.8 59.1, 4 30.9 73.2")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

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
',
  '<p class="gd-p">A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.</p><section class="gd-task" id="requests-offers-and-bookings-the-request-queue" data-gd-task><h2 class="gd-h2">The request queue</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests</b>. The oldest waiting request is at the top.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-02-requests-desktop-6521282d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:18.5%;top:21.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.3%;top:31.7%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless &quot;Email the renter when their request expires that way&quot; is on in Program settings.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-answer-a-request-with-an-offer" data-gd-task><h2 class="gd-h2">Answer a request with an offer</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The Review and offer tab shows the request as the renter sent it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Price on the right updates as you change things.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a message, choose how long the offer stays open, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1060"><img src="/guides/img/admin-03-booking-review-desktop-84570463.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1060"><span class="gd-pin" style="left:21.7%;top:16.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:20%;top:45.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:65%;top:45.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:96.5%;top:98.8%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Changed fields but not ready to send? Press <b class="gd-ui">Save changes</b>. The panel &quot;The offer as the renter sees it&quot; shows the result.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? Press <b class="gd-ui">Decline</b> and fill in Reason and any alternative.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Need an answer first? Press <b class="gd-ui">Ask the renter</b> to send a question.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:620/810"><img src="/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg" alt="" loading="lazy" decoding="async" width="620" height="810"><span class="gd-pin" style="left:91.9%;top:33.6%" aria-hidden="true">5</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-send-an-offer-without-a-request" data-gd-task><h2 class="gd-h2">Send an offer without a request</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Send an offer</b>, or <b class="gd-ui">Send an offer</b> on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The customer: type a name, phone or email and choose them. Not on file? Press <b class="gd-ui">Add a new customer</b>: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason and can be plus tax or tax included. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">The right side is the offer as the renter will see it, priced by the database as you type. Press <b class="gd-ui">Send the offer</b>. <b class="gd-ui">Save without sending</b> keeps it as a request for later.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No &quot;request received&quot; email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-change-an-offer-that-is-out" data-gd-task><h2 class="gd-h2">Change an offer that is out</h2><p class="gd-p">The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press <b class="gd-ui">Edit the offer</b> on the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Write what changed in Message to the renter and choose how long the offer is open.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save and send the update</b>: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press <b class="gd-ui">Save without telling the renter</b> and tell them yourself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A confirmed booking is changed with <b class="gd-ui">Change the booking</b> (Propose a change, below).</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>No need to withdraw first. <b class="gd-ui">Withdraw the offer</b> is only for taking it back for good; <b class="gd-ui">Send again, later expiry</b> gives the renter more time, and <b class="gd-ui">Renter approved by phone</b> records a yes given on a call.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-edit-a-booking-that-has-started" data-gd-task><h2 class="gd-h2">Edit a booking that has started</h2><p class="gd-p">On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, <b class="gd-ui">Edit the booking</b>, <b class="gd-ui">Edit</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking&#39;s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Type why, if you like, and tick <b class="gd-ui">Email the renter what changed</b>, or leave it off for a silent correction. Press <b class="gd-ui">Save the changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What is open now shows at once: <b class="gd-ui">Email a pay link</b> or <b class="gd-ui">Text a pay link</b> for exactly that amount, <b class="gd-ui">Charge</b> the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking&#39;s history. A closed booking&#39;s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-fees-a-forgotten-fee-and-the-balance" data-gd-task><h2 class="gd-h2">Fees, a forgotten fee and the balance</h2><p class="gd-p">On the booking&#39;s Money tab, Fees lists each fee. Press <b class="gd-ui">Change or add a fee</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Save the fees</b>. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The renter sees the balance on their booking with a Pay button, and pays by card on Stripe&#39;s form.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-correct-a-renter-s-details" data-gd-task><h2 class="gd-h2">Correct a renter&#39;s details</h2><p class="gd-p">On the renter&#39;s page (People, Renters) or on any of their bookings, <b class="gd-ui">Edit renter</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick <b class="gd-ui">Email the renter a link to set a password</b> to send one there. Unsigned agreements and offers go to the new address.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the renter</b>. An email that another renter has is refused with their name; the same phone is a warning.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-payments-by-part-the-rental-the-deposit-and-later-charges" data-gd-task><h2 class="gd-h2">Payments by part: the rental, the deposit and later charges</h2><p class="gd-p">On the booking&#39;s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Record a payment</b>: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press <b class="gd-ui">Record it</b>. The renter gets a receipt; <b class="gd-ui">Print</b> prints one to hand over.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Collect a card</b>: a payment, the deposit hold or saving the card. The renter types the card in Stripe&#39;s secure form: on this device (<b class="gd-ui">Open the card form</b>, then hand it over) or by a link texted or emailed to them (<b class="gd-ui">Send the link</b>). Staff never type a card number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A deposit hold lasts about 7 days and shows the days left; while the car is out it is collected by itself before it lapses. After the return, settle the deposit (below). <b class="gd-ui">Capture the hold</b> for all of it keeps the money; a part capture or <b class="gd-ui">Release the hold</b> waits for the settlement while the car is out or something is open (an Admin may do it with the reason).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Charge the saved card</b> (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter&#39;s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press <b class="gd-ui">Confirm the booking</b>).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press <b class="gd-ui">Returned</b> with the reference or receipt number.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-settle-the-deposit" data-gd-task><h2 class="gd-h2">Settle the deposit</h2><p class="gd-p">The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking&#39;s Money tab, under Deposit, press <b class="gd-ui">Settle the deposit</b>. Issue the Check-in statement first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Damage: <b class="gd-ui">Keep the whole deposit (damage)</b> turns what is left of the deposit into a damage charge, with what was damaged and the photos; the renter is told. <b class="gd-ui">Bill damage</b> adds a damage charge up to the $2,500 deductible (more goes through a claim): the deposit pays first, then the card on file.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Settle</b>. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-a-booking" data-gd-task><h2 class="gd-h2">A booking</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Bookings</b>, then a booking number. Or type the number in the search box.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Tabs: Overview, Money, Changes, History, and Drivers and documents.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Overview shows the trip, the renter, what is still missing for the handover, and the price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open tasks for this booking, with the queue and the due time.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Top right: <b class="gd-ui">Stop blocking the calendar</b>, <b class="gd-ui">Cancel for the renter</b> and <b class="gd-ui">Cancel by CarmaCars</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/960"><img src="/guides/img/admin-04-booking-desktop-b56b668a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="960"><span class="gd-pin" style="left:20.1%;top:24%" aria-hidden="true">1</span><span class="gd-pin" style="left:34.7%;top:58.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:20.1%;top:72.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:90.3%;top:18.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-check-a-car-out-or-in" data-gd-task><h2 class="gd-h2">Check a car out or in</h2><p class="gd-p">From the booking, with your phone or a tablet: the same checklist field staff use.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A confirmed booking shows <b class="gd-ui">Check out (pickup)</b> under Check-out, check-in and signing; a booking on rent shows <b class="gd-ui">Check in (return)</b>. Today lists the check-outs and check-ins due, each with <b class="gd-ui">Check out</b> or <b class="gd-ui">Check in</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press <b class="gd-ui">See the photo report</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Fleet, Sales and Customer service check cars out and in the same way from their own booking page.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-the-photo-report-late-returns-and-the-return-charges" data-gd-task><h2 class="gd-h2">The photo report, late returns and the return charges</h2><p class="gd-p">Under Check-out, check-in and signing, press <b class="gd-ui">Photo report</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not charging one? Press <b class="gd-ui">Waive</b> beside it and give the reason: it stays waived if the charges are worked out again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The time was wrong? Press <b class="gd-ui">Correct the check-in time</b> (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-signatures-on-the-spot-or-by-link" data-gd-task><h2 class="gd-h2">Signatures on the spot, or by link</h2><p class="gd-p">The renter or an additional driver signs the rental agreement on your device, or on their own phone.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">While a signature is missing, the booking shows <b class="gd-ui">Sign now on this device</b>, <b class="gd-ui">Email the signing link</b> and <b class="gd-ui">Text the signing link</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Sign now on this device</b>: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press <b class="gd-ui">Hand the device to</b> and their name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">They read both agreements (CarmaCars&#39; and Blind Spot&#39;s), tick the statements and sign. Then <b class="gd-ui">Back to the staff view</b> for the next signer.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy&#39;s signature record page.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-the-licence-before-an-offer-is-accepted" data-gd-task><h2 class="gd-h2">The licence before an offer is accepted</h2><p class="gd-p">Front, back and a selfie, from the request on.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Review the images as usual with <b class="gd-ui">Review documents</b>: the card Renter documents is on Review and offer too.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The switch is in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, Booking requests and offers: Booking licence required (on), with the selfie (on).</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-renter-documents-licence-and-proof-of-coverage" data-gd-task><h2 class="gd-h2">Renter documents: licence and proof of coverage</h2><p class="gd-p">A renter&#39;s licence photos, selfie and proof of coverage (OPCF 27 or a credit card&#39;s rental coverage) are checked before the handover. You check them yourself; no task is needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A booking with documents waiting is a line on To do: &quot;Check &#39;s documents for booking &quot;, marked Now when the pickup is within two days. Press <b class="gd-ui">Review documents</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The pop-up shows each driver&#39;s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What to check is written once at the top. One wrong? Open <b class="gd-ui">Reject this one</b> under it, type the reason the renter reads and press <b class="gd-ui">Reject</b>: they are asked for a new one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Then press <b class="gd-ui">Approve all</b>: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. Anything the system refuses is named with the reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The same pop-up is on the booking: the card Renter documents (<b class="gd-ui">Review documents</b>) on Overview and on Drivers and documents.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening of a renter&#39;s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-out (photos and four checks): the history says &quot;checked in person&quot;.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-payments-by-day" data-gd-task><h2 class="gd-h2">Payments by day</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Payments by day</b>: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press <b class="gd-ui">Show</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Totals by method and for each day; cards read as the card and its last four digits, never a code.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The cash drawer: expected (cash in less cash given back) against the count Finance records with <b class="gd-ui">Record the count</b>; a difference shows over or short.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Refunds waiting: every refund asked for anywhere with the policy maths. <b class="gd-ui">Approve</b> or <b class="gd-ui">Decline</b> with the reason in the row, then <b class="gd-ui">Issue the refund</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Export CSV</b> for the bookkeeper.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-propose-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">Propose a change to a confirmed booking</h2><p class="gd-p">The renter gets an email and answers on their booking. The calendar moves only when they accept.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking&#39;s Changes tab. Under Propose a change, set the new pickup, return or car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To price it by hand, type a New rental charge before tax. Leave it empty to use the car&#39;s rates.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the Reason, for the renter. They read it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057?tab=changes</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/530"><img src="/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="530"><span class="gd-pin" style="left:12.9%;top:15.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:35%;top:30.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:49.8%;top:59.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:30.9%;top:73.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-who-a-booking-is-credited-to" data-gd-task><h2 class="gd-h2">Who a booking is credited to</h2><p class="gd-p">Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To give it to someone else, press <b class="gd-ui">Reassign</b>, choose who (or Nobody), say whether they sourced the client and write the reason. The booking&#39;s history and the audit log keep it, and the deal stays in the same week and month.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Someone said they sourced a website request? The credit line shows the claim: press <b class="gd-ui">Credit them</b> or <b class="gd-ui">Not theirs</b>, with a reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press <b class="gd-ui">Mark reviewed</b> once you have looked at it.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-review-requests" data-gd-task><h2 class="gd-h2">Review requests</h2><p class="gd-p">Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Message</th><th scope="col">When</th></tr></thead><tbody><tr><td>Mid-trip check-in</td><td>Rentals of 2 days or more, 24 hours after the pickup: &quot;How is the car? Reply or call if anything is off.&quot; No review ask.</td></tr><tr><td>Review request</td><td>1 hour after the check-in. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google.</td></tr><tr><td>Reminder</td><td>24 hours after the request.</td></tr><tr><td>Final follow-up</td><td>7 days after the request. Nothing more after it.</td></tr></tbody></table></div><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Ask for a review</b> sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press <b class="gd-ui">Send anyway</b> to send it now.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Mark reviewed</b> stops the messages when the renter tells you they already reviewed.</div></li></ol></div><p class="gd-p">The messages also stop by themselves when the renter presses &quot;I already left a review&quot;, leaves a review on the site, unsubscribes, or a Google review is matched to them. <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Reviews</b> has the numbers (requests sent, on hold, reviews detected, the average rating), the hold list and the Google reviews to match.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees &quot;Something wasn&#39;t right? Tell us directly&quot;.</div></aside></section>');
select app.guide_release_section('admin', 'settings', 'chapter', 'search-car-pages-landing-pages-and-guides', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task).
9. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
10. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
11. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record paper signature**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.

## Reviews: review requests and Google

**Settings** > **Reviews**: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.

1. When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.
2. The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile''s own review link.
3. Google Business Profile: press **Connect Google** and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.
4. A clear match stops that renter''s reminders at once. A possible match waits in Reviews: press **Confirm**, **Not this renter** or **Match to a booking**.

> Tip: Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.
', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.
9. Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task).
10. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
11. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
12. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record paper signature**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.

## Reviews: review requests and Google

**Settings** > **Reviews**: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.

1. When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.
2. The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile''s own review link.
3. Google Business Profile: press **Connect Google** and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.
4. A clear match stops that renter''s reminders at once. A possible match waits in Reviews: press **Confirm**, **Not this renter** or **Match to a booking**.

> Tip: Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.
',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: Blind Spot&#39;s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company&#39;s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task).</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;Signed here by hand, in ink&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with <b class="gd-ui">Record paper signature</b>. Each form not checked yet is also a line on To do with the same button and Preview it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form&#39;s notes list what to tick or choose at the counter.</div></aside></section><section class="gd-task" id="settings-blind-spot-rental-agreement" data-gd-task><h2 class="gd-h2">Blind Spot rental agreement</h2><p class="gd-p">We rent under Blind Spot Car Rental&#39;s insurance, so every booking has two agreements: CarmaCars&#39; rental agreement and Blind Spot&#39;s own. Blind Spot&#39;s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. The Blind Spot Car Rental agreement card is first. Press <b class="gd-ui">Upload Blind Spot&#39;s PDF</b> and choose Blind Spot&#39;s blank form (2 pages, A4).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled sample</b>: a made-up booking on the form. <b class="gd-ui">Sample billed to an insurer</b> also fills the claim number, the adjuster and the insurance company. Check every box.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars&#39; HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative&#39;s signature instead of Sam&#39;s.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for bookings</b>. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A new version of Blind Spot&#39;s form? Upload it the same way: it waits for <b class="gd-ui">Checked: use for bookings</b>, and bookings keep the version in use until then.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.</div></aside><p class="gd-p">The renter&#39;s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking&#39;s Drivers and documents tab, in the renter&#39;s Documents, and the signed Blind Spot agreement is attached to the &quot;Your signed rental agreement&quot; email. Admin &gt; Today lists the HST number, the upload and the check until they are done.</p></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section><section class="gd-task" id="settings-card-coverage-which-credit-cards-include-rental-car-coverage" data-gd-task><h2 class="gd-h2">Card coverage: which credit cards include rental car coverage</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Card coverage</b> is the list renters see at <span class="gd-url">carmacars.ca/credit-card-rental-coverage</span> and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer&#39;s own document, and when it was last checked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a card under Change a card, open its official guide, correct what changed and press <b class="gd-ui">Save</b>. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A card whose numbers come from a published summary has Read in the issuer&#39;s own document unticked and the summary&#39;s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer&#39;s guide.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer&#39;s guide.</div></aside></section><section class="gd-task" id="settings-reviews-review-requests-and-google" data-gd-task><h2 class="gd-h2">Reviews: review requests and Google</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Reviews</b>: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile&#39;s own review link.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Google Business Profile: press <b class="gd-ui">Connect Google</b> and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A clear match stops that renter&#39;s reminders at once. A possible match waits in Reviews: press <b class="gd-ui">Confirm</b>, <b class="gd-ui">Not this renter</b> or <b class="gd-ui">Match to a booking</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and &quot;I already left a review&quot;, Mark reviewed and on-site reviews still stop the messages.</div></aside></section>');
select app.guide_release_section('va', 'finance', 'chapter', 'chauffeur-requests', 'You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips.

Your rail: Queue, Today, Payments, deposits, refunds, Tolls and tickets, Reconciliation, Turo trips, Find a renter, Calendar and Scorecard.

## Your queue

Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.

![The type filters show what Finance handles: collect upfront, debit failed, match toll, refund cancellation and review statements.](/guides/img/va-finance-01-queue-desktop-295e545d.jpg "desktop; size: 1440 560; address: carmacars.ca/va; pins: 1 26.4 45.4")

## Payments by day

**Payments by day** is your day in one screen: every payment and refund, by method, with the cash drawer and the refunds to decide.

1. Choose From and To (today by default) and tick the methods you want (card, e-Transfer, cash, cheque, platform payout, insurer and others; none ticked shows all), then press **Show**.
2. Totals by method: received, refunded and net. Each day: the same by method, the cash expected in the drawer (cash received less cash given back) and the cash counted.
3. At the end of the day count the drawer and press **Record the count**. The difference shows "balanced", or "over" or "short" with the amount.
4. Refunds waiting: every refund asked for anywhere (a cancellation, a booking, Finance), with the policy maths (paid, the tier, the percentage back, what is kept). Press **Approve** or **Decline** with the reason in the same row; above your limit it says an Admin approves. Approved: **Issue the refund**.
5. **Export CSV** gives the same rows for the bank or the bookkeeper: refunds as negative amounts, holds marked as not money in.

## Payments, deposits, refunds

1. Failed payments: each with the purpose, amount and the bank''s reason.
2. Deposits to take before pickup, and deposits due back.
3. Refunds in progress. Press **Request the refund** and choose What it refunds (the rental charge, delivery or pickup, kilometres, add-ons or other charges); above your limit it waits for an Admin. Then **Issue the refund**.
4. Owner invoices that failed, and owner statements to prepare.

![](/guides/img/va-finance-02-money-desktop-70fea0c7.jpg "desktop; size: 1230 1060; address: carmacars.ca/va/money; pins: 1 10.6 6.6, 2 12.2 19.2, 3 10.6 57.3, 4 13.0 73.2")

## A payment received another way

An owner or renter paid by e-Transfer, cheque, cash or bank transfer.

1. Owner invoice: on **Payments, deposits, refunds**, find it under Owner invoices owing and press **Record payment**.
2. Renter: beside the failed payment, press **Paid another way**. Or open the booking''s Money tab: under Money by part press **Record a payment**, choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid, then **Record it**.
3. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.
4. Add the proof if you have it (a screenshot or a photo of the cheque), then press **Record payment**.

The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.

Each month''s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.

## Cards, holds and deposits given back

On the booking''s Money tab.

1. **Charge the saved card**: a later charge (extra kilometres, fuel, damage, a late return) with the reason on the renter''s receipt, or the deposit of a rental over 7 days.
2. A deposit hold: **Capture the hold** for all or part of it, with the reason (the rest is released), or **Release the hold**.
3. A deposit taken in cash or by e-Transfer is given back the same way: the task Give the deposit back the way it came; then press **Returned** with the reference or receipt number.

## Read a toll notice

1. Open **Tolls and tickets** and press **Read a notice**.
2. Choose the file: a PDF, a photo or a CSV, under 15 MB. Leave the reading profile to find it from the text.
3. Press **Read it**. Then check each line beside the notice and fix what was read wrong.
4. Press **Checked against the notice** on each line (**Leave out** to skip one), then **Save as checked** and **Confirm and import**.

![](/guides/img/va-finance-04-tolls-read-desktop-aa04a6b2.jpg "desktop; size: 1230 580; address: carmacars.ca/va/tolls/read; pins: 2 19.5 44.1, 3 4.1 64.8, 4 4.1 89.7")

> Tip: In the work queue, **Match again** retries the match after a fix, and **Dispute** marks a notice you think is wrong. Renters matched with high confidence are charged at import, with the notice and our fee.

![The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice''s plate, date, amount and match.](/guides/img/va-finance-03-tolls-desktop-37b6f99c.jpg "desktop; size: 1230 540; address: carmacars.ca/va/tolls; pins: 1 23.6 12.2")

## Reconciliation and Turo trips

1. **Reconciliation**: press **Record a processor payout**, then **Match** it to the payments it contains. Anything still unmatched at the closing check goes to an Admin.
2. **Turo trips**: press **Add a trip** for one trip, or paste CSV rows and press **Import**.

![](/guides/img/va-finance-06-turo-desktop-b59cc7f9.jpg "desktop; size: 1230 540; address: carmacars.ca/va/turo; pins: 2 95.1 14.8")
', 'Finance', 'Payments, deposits and refunds, tolls and tickets, reconciliation and Turo trips.',
  'You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips.

Your rail: Queue, Today, Payments, deposits, refunds, Tolls and tickets, Reconciliation, Turo trips, Find a renter, Calendar and Scorecard.

## Your queue

Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.

![The type filters show what Finance handles: collect upfront, debit failed, match toll, refund cancellation and review statements.](/guides/img/va-finance-01-queue-desktop-295e545d.jpg "desktop; size: 1440 560; address: carmacars.ca/va; pins: 1 26.4 45.4")

## Payments by day

**Payments by day** is your day in one screen: every payment and refund, by method, with the cash drawer and the refunds to decide.

1. Choose From and To (today by default) and tick the methods you want (card, e-Transfer, cash, cheque, platform payout, insurer and others; none ticked shows all), then press **Show**.
2. Totals by method: received, refunded and net. Each day: the same by method, the cash expected in the drawer (cash received less cash given back) and the cash counted.
3. At the end of the day count the drawer and press **Record the count**. The difference shows "balanced", or "over" or "short" with the amount.
4. Refunds waiting: every refund asked for anywhere (a cancellation, a booking, Finance), with the policy maths (paid, the tier, the percentage back, what is kept). Press **Approve** or **Decline** with the reason in the same row; above your limit it says an Admin approves. Approved: **Issue the refund**.
5. **Export CSV** gives the same rows for the bank or the bookkeeper: refunds as negative amounts, holds marked as not money in.

## Payments, deposits, refunds

1. Failed payments: each with the purpose, amount and the bank''s reason.
2. Deposits to take before pickup, and deposits due back.
3. Refunds in progress. Press **Request the refund** and choose What it refunds (the rental charge, delivery or pickup, kilometres, add-ons or other charges); above your limit it waits for an Admin. Then **Issue the refund**.
4. Owner invoices that failed, and owner statements to prepare.

![](/guides/img/va-finance-02-money-desktop-70fea0c7.jpg "desktop; size: 1230 1060; address: carmacars.ca/va/money; pins: 1 10.6 6.6, 2 12.2 19.2, 3 10.6 57.3, 4 13.0 73.2")

## A payment received another way

An owner or renter paid by e-Transfer, cheque, cash or bank transfer.

1. Owner invoice: on **Payments, deposits, refunds**, find it under Owner invoices owing and press **Record payment**.
2. Renter: beside the failed payment, press **Paid another way**. Or open the booking''s Money tab: under Money by part press **Record a payment**, choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid, then **Record it**.
3. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.
4. Add the proof if you have it (a screenshot or a photo of the cheque), then press **Record payment**.

The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.

Each month''s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.

## Cards, holds and deposits given back

On the booking''s Money tab.

1. **Charge the saved card**: a later charge (extra kilometres, fuel, damage, a late return) with the reason on the renter''s receipt, or the deposit of a rental over 7 days.
2. A deposit hold: **Capture the hold** for all of it, with the reason. A part capture (the rest is released) or **Release the hold** waits for the settlement while the car is out, inside the toll window or while something is open; an Admin may do it with the reason.
3. A deposit taken in cash or by e-Transfer is given back the same way: the task Give the deposit back the way it came; then press **Returned** with the reference or receipt number.

## Settle a deposit

The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking''s Money tab, under Deposit, press **Settle the deposit**. Issue the Check-in statement first.

1. The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.
2. Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.
3. Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.
4. Damage: an Admin keeps the whole deposit (**Keep the whole deposit (damage)**) or bills a damage charge up to the $2,500 deductible. Ask an Admin, with the photos.
5. Press **Settle**. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.

> Good to know: A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.

## Read a toll notice

1. Open **Tolls and tickets** and press **Read a notice**.
2. Choose the file: a PDF, a photo or a CSV, under 15 MB. Leave the reading profile to find it from the text.
3. Press **Read it**. Then check each line beside the notice and fix what was read wrong.
4. Press **Checked against the notice** on each line (**Leave out** to skip one), then **Save as checked** and **Confirm and import**.

![](/guides/img/va-finance-04-tolls-read-desktop-aa04a6b2.jpg "desktop; size: 1230 580; address: carmacars.ca/va/tolls/read; pins: 2 19.5 44.1, 3 4.1 64.8, 4 4.1 89.7")

> Tip: In the work queue, **Match again** retries the match after a fix, and **Dispute** marks a notice you think is wrong. Renters matched with high confidence are charged at import, with the notice and our fee.

![The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice''s plate, date, amount and match.](/guides/img/va-finance-03-tolls-desktop-37b6f99c.jpg "desktop; size: 1230 540; address: carmacars.ca/va/tolls; pins: 1 23.6 12.2")

## Reconciliation and Turo trips

1. **Reconciliation**: press **Record a processor payout**, then **Match** it to the payments it contains. Anything still unmatched at the closing check goes to an Admin.
2. **Turo trips**: press **Add a trip** for one trip, or paste CSV rows and press **Import**.

![](/guides/img/va-finance-06-turo-desktop-b59cc7f9.jpg "desktop; size: 1230 540; address: carmacars.ca/va/turo; pins: 2 95.1 14.8")
',
  '<p class="gd-p">You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips.</p><p class="gd-p">Your rail: Queue, Today, Payments, deposits, refunds, Tolls and tickets, Reconciliation, Turo trips, Find a renter, Calendar and Scorecard.</p><section class="gd-task" id="finance-your-queue" data-gd-task><h2 class="gd-h2">Your queue</h2><p class="gd-p">Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.</p><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/va-finance-01-queue-desktop-295e545d.jpg" alt="The type filters show what Finance handles: collect upfront, debit failed, match toll, refund cancellation and review statements." loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:26.4%;top:45.4%" aria-hidden="true">1</span></div></div><figcaption>The type filters show what Finance handles: collect upfront, debit failed, match toll, refund cancellation and review statements.</figcaption></figure></div></section><section class="gd-task" id="finance-payments-by-day" data-gd-task><h2 class="gd-h2">Payments by day</h2><p class="gd-p"><b class="gd-ui">Payments by day</b> is your day in one screen: every payment and refund, by method, with the cash drawer and the refunds to decide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose From and To (today by default) and tick the methods you want (card, e-Transfer, cash, cheque, platform payout, insurer and others; none ticked shows all), then press <b class="gd-ui">Show</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Totals by method: received, refunded and net. Each day: the same by method, the cash expected in the drawer (cash received less cash given back) and the cash counted.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">At the end of the day count the drawer and press <b class="gd-ui">Record the count</b>. The difference shows &quot;balanced&quot;, or &quot;over&quot; or &quot;short&quot; with the amount.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Refunds waiting: every refund asked for anywhere (a cancellation, a booking, Finance), with the policy maths (paid, the tier, the percentage back, what is kept). Press <b class="gd-ui">Approve</b> or <b class="gd-ui">Decline</b> with the reason in the same row; above your limit it says an Admin approves. Approved: <b class="gd-ui">Issue the refund</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Export CSV</b> gives the same rows for the bank or the bookkeeper: refunds as negative amounts, holds marked as not money in.</div></li></ol></div></section><section class="gd-task" id="finance-payments-deposits-refunds" data-gd-task><h2 class="gd-h2">Payments, deposits, refunds</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Failed payments: each with the purpose, amount and the bank&#39;s reason.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Deposits to take before pickup, and deposits due back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Refunds in progress. Press <b class="gd-ui">Request the refund</b> and choose What it refunds (the rental charge, delivery or pickup, kilometres, add-ons or other charges); above your limit it waits for an Admin. Then <b class="gd-ui">Issue the refund</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Owner invoices that failed, and owner statements to prepare.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/money</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/1060"><img src="/guides/img/va-finance-02-money-desktop-70fea0c7.jpg" alt="" loading="lazy" decoding="async" width="1230" height="1060"><span class="gd-pin" style="left:10.6%;top:6.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:12.2%;top:19.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:10.6%;top:57.3%" aria-hidden="true">3</span><span class="gd-pin" style="left:13%;top:73.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="finance-a-payment-received-another-way" data-gd-task><h2 class="gd-h2">A payment received another way</h2><p class="gd-p">An owner or renter paid by e-Transfer, cheque, cash or bank transfer.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Owner invoice: on <b class="gd-ui">Payments, deposits, refunds</b>, find it under Owner invoices owing and press <b class="gd-ui">Record payment</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Renter: beside the failed payment, press <b class="gd-ui">Paid another way</b>. Or open the booking&#39;s Money tab: under Money by part press <b class="gd-ui">Record a payment</b>, choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid, then <b class="gd-ui">Record it</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add the proof if you have it (a screenshot or a photo of the cheque), then press <b class="gd-ui">Record payment</b>.</div></li></ol></div><p class="gd-p">The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.</p><p class="gd-p">Each month&#39;s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.</p></section><section class="gd-task" id="finance-cards-holds-and-deposits-given-back" data-gd-task><h2 class="gd-h2">Cards, holds and deposits given back</h2><p class="gd-p">On the booking&#39;s Money tab.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Charge the saved card</b>: a later charge (extra kilometres, fuel, damage, a late return) with the reason on the renter&#39;s receipt, or the deposit of a rental over 7 days.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A deposit hold: <b class="gd-ui">Capture the hold</b> for all of it, with the reason. A part capture (the rest is released) or <b class="gd-ui">Release the hold</b> waits for the settlement while the car is out, inside the toll window or while something is open; an Admin may do it with the reason.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A deposit taken in cash or by e-Transfer is given back the same way: the task Give the deposit back the way it came; then press <b class="gd-ui">Returned</b> with the reference or receipt number.</div></li></ol></div></section><section class="gd-task" id="finance-settle-a-deposit" data-gd-task><h2 class="gd-h2">Settle a deposit</h2><p class="gd-p">The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking&#39;s Money tab, under Deposit, press <b class="gd-ui">Settle the deposit</b>. Issue the Check-in statement first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Damage: an Admin keeps the whole deposit (<b class="gd-ui">Keep the whole deposit (damage)</b>) or bills a damage charge up to the $2,500 deductible. Ask an Admin, with the photos.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Settle</b>. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.</div></aside></section><section class="gd-task" id="finance-read-a-toll-notice" data-gd-task><h2 class="gd-h2">Read a toll notice</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Tolls and tickets</b> and press <b class="gd-ui">Read a notice</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the file: a PDF, a photo or a CSV, under 15 MB. Leave the reading profile to find it from the text.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Read it</b>. Then check each line beside the notice and fix what was read wrong.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked against the notice</b> on each line (<b class="gd-ui">Leave out</b> to skip one), then <b class="gd-ui">Save as checked</b> and <b class="gd-ui">Confirm and import</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/tolls/read</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/580"><img src="/guides/img/va-finance-04-tolls-read-desktop-aa04a6b2.jpg" alt="" loading="lazy" decoding="async" width="1230" height="580"><span class="gd-pin" style="left:19.5%;top:44.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:4.1%;top:64.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:4.1%;top:89.7%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>In the work queue, <b class="gd-ui">Match again</b> retries the match after a fix, and <b class="gd-ui">Dispute</b> marks a notice you think is wrong. Renters matched with high confidence are charged at import, with the notice and our fee.</div></aside><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/tolls</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/540"><img src="/guides/img/va-finance-03-tolls-desktop-37b6f99c.jpg" alt="The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice&#39;s plate, date, amount and match." loading="lazy" decoding="async" width="1230" height="540"><span class="gd-pin" style="left:23.6%;top:12.2%" aria-hidden="true">1</span></div></div><figcaption>The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice&#39;s plate, date, amount and match.</figcaption></figure></div></section><section class="gd-task" id="finance-reconciliation-and-turo-trips" data-gd-task><h2 class="gd-h2">Reconciliation and Turo trips</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Reconciliation</b>: press <b class="gd-ui">Record a processor payout</b>, then <b class="gd-ui">Match</b> it to the payments it contains. Anything still unmatched at the closing check goes to an Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Turo trips</b>: press <b class="gd-ui">Add a trip</b> for one trip, or paste CSV rows and press <b class="gd-ui">Import</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/turo</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/540"><img src="/guides/img/va-finance-06-turo-desktop-b59cc7f9.jpg" alt="" loading="lazy" decoding="async" width="1230" height="540"><span class="gd-pin" style="left:95.1%;top:14.8%" aria-hidden="true">2</span></div></div></figure></div></section>');
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
9. Press **Complete the return**. The check-in time is the moment you press it: a late return, the kilometres over the allowance and the fuel or charge used are charged from it automatically.

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

> Watch out: New damage needs a close-up photo and a clear note. Finance uses your photos and notes to bill the renter, so take your time.
',
  '<p class="gd-p">The return mirrors the handover. You record the car as it comes back and compare it with the pickup.</p><section class="gd-task" id="a-return-take-the-car-back" data-gd-task><h2 class="gd-h2">Take the car back</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Car and keys received: confirm you have the car and its keys.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Odometer, then Fuel or charge, as at pickup.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Keys and extras: count what came back.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Cleanliness: inside and out.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Photo set: the same shots, in the same order, as at pickup.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Compare with pickup: for new damage, tap the diagram, fill in Where and What it is, press <b class="gd-ui">Add the damage</b> and take a close-up photo.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Belongings: check the seats, the trunk, the glovebox and the door pockets.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Renter reviews and signs. Then you sign.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Press <b class="gd-ui">Complete the return</b>. The check-in time is the moment you press it: a late return, the kilometres over the allowance and the fuel or charge used are charged from it automatically. The deposit is not given back at the return: Finance settles it once tolls and tickets have had time to come in (about 7 days), and new damage you mark keeps it held.</div></li></ol></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>New damage needs a close-up photo and a clear note. Finance uses your photos and notes to bill the renter, so take your time.</div></aside></section>');
-- GUIDES 0155 END
