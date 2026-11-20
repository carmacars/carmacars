-- 3100 (release 48, part MR: money rules; docs/changes/2026-11-20-r48-money-rules.md): owner payouts follow each owner's
-- agreed split.
--
-- 1. The term in force on each rental day. A booking's Revenue Share was the one stamped the day it was booked
--    (bookings.company_share_bps); a car whose terms were set or corrected later kept the old split on every booking
--    made before. Now the open part of a booking's split (not yet on an approved statement) takes the Revenue Share in
--    force on each of its rental days (app.vehicle_split_terms of that day), averaged over the days, on a program owner's
--    car. A Revenue Share set for one booking (booking_owner_shares), a flat monthly arrangement, a partner's listed
--    rate and a booking left out of the owner's revenue keep their own rules.
-- 2. Shareholder cars (an owner with is_shareholder, or a car marked shareholder-owned): the shareholder keeps 90% (the
--    Program setting shareholder_company_share_bps, 10% to CarmaCars) of the TOTAL charged on the booking before tax:
--    the rental, every fee (young driver, Protection Plan, delivery, late, km, fuel, cleaning, smoking, ...) and every
--    amount kept from the deposit (incidentals, damage, tickets, fees billed from the deposit: these are charge lines
--    paid from the deposit). HST is left out (it is remitted). Referral kickbacks and staff commissions are still taken
--    off first as a booking expense (0058: on a program owner's car, shared by rental charge), as before.
-- 3. A versioned correction of a car's terms from any date since its start (app.car_terms_correct): the periods from
--    that date take the corrected values, the values replaced are kept (vehicle_terms_corrections), and the owner signs
--    an updated Vehicle Schedule only when the correction gives them less (a higher management fee or Fee). The
--    connector's change_owner_terms takes correction: true for it.
-- 4. app.owner_statement_recompute: an approved statement not paid out is voided and built again on the corrected
--    terms, then approved again, with an audit line (audit_log owner_statement_recompute: before and after).
-- 5. The connector's get_car and get_owner show each car's terms: Revenue Share, Fees, since when, every period.
-- No applied migration is edited: app.compute_booking_split_pre2371 is wrapped (_pre3100), app.owner_terms_save is
-- wrapped (_pre3100), app.api_vehicle_row and app.api_owner_row are replaced with the same signature.
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

-- ================================================================ 1. the Revenue Share of each rental day
create function app.split_day_share_bps(p_vehicle uuid, p_start timestamptz, p_days integer, p_type text, p_fallback integer) returns integer
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_sum bigint := 0;
  v_n integer := 0;
  v_bps integer;
  v_first date := app.local_date(p_start);
  i integer;
begin
  if p_vehicle is null or p_start is null or coalesce(p_days, 0) <= 0 then return p_fallback; end if;
  for i in 0 .. least(p_days, 400) - 1 loop
    v_bps := coalesce((select t.company_share_bps from app.vehicle_split_terms(p_vehicle, v_first + i, coalesce(p_type, 'standard')) t), p_fallback);
    if v_bps is null then continue; end if;
    v_sum := v_sum + v_bps;
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then return p_fallback; end if;
  return round(v_sum::numeric / v_n)::integer;
end $$;
comment on function app.split_day_share_bps(uuid, timestamptz, integer, text, integer) is
  'Release 48 MR (3100): the Revenue Share of a car over a rental''s days, each day at the term in force that day (app.vehicle_split_terms), averaged; p_fallback when nothing is set.';

-- the shareholder rule: the owner is a shareholder, or the car is marked shareholder-owned
create function app.is_shareholder_car(p_vehicle uuid, p_owner uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select v.is_shareholder_owned from vehicles v where v.id = p_vehicle), false)
      or coalesce((select o.is_shareholder from owners o where o.id = p_owner), false)
$$;

-- the shareholder's fees and amounts kept: their own column, so Owner Revenue stays rental, km and these, less the expenses
alter table booking_splits add column if not exists shareholder_extra_cents bigint not null default 0;
comment on column booking_splits.shareholder_extra_cents is 'A shareholder car (3100): every fee and amount kept from the deposit charged on the booking before tax (company_only and pass_through lines), added to Owner Revenue, so the shareholder keeps 90% of the total.';
alter table booking_splits drop constraint if exists booking_splits_owner_revenue;
alter table booking_splits add constraint booking_splits_owner_revenue
  check (owner_revenue_cents = rental_charge_cents + mileage_overage_cents + shareholder_extra_cents - kickback_cents - partner_markup_cents - owner_expense_cents);

alter function app.compute_booking_split_pre2371(uuid) rename to compute_booking_split_pre3100;
create function app.compute_booking_split_pre2371(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  s booking_splits;
  v_bps integer;
  v_rev bigint;
  v_share bigint;
  v_sh_bps integer;
begin
  -- the parts not paid out go back to their plain figures first (the split below writes them again)
  update booking_splits set owner_revenue_cents = owner_revenue_cents - shareholder_extra_cents, shareholder_extra_cents = 0
   where booking_id = p_booking and owner_statement_id is null and shareholder_extra_cents <> 0;
  perform app.compute_booking_split_pre3100(p_booking);
  select * into b from bookings where id = p_booking;
  if b.id is null or b.booking_type::text = 'owner' then return; end if;
  for s in select x.* from booking_splits x join vehicles v on v.id = x.vehicle_id
            where x.booking_id = p_booking and x.owner_statement_id is null and not x.booking_share_override
              and x.flat_arrangement_id is null and not x.partner_rate_basis and v.supply_type = 'program_owner' loop
    if app.is_shareholder_car(s.vehicle_id, s.owner_id) then
      -- 2: 90% of everything charged before tax, the expenses (kickbacks, commissions, documented owner expenses) first
      v_sh_bps := (app.settings(app.local_date(coalesce(s.segment_starts_at, b.pickup_at)))).shareholder_company_share_bps;
      v_rev := s.owner_revenue_cents + s.company_only_cents + s.pass_through_cents;
      v_share := public.calc_bps(greatest(v_rev, 0), v_sh_bps);
      update booking_splits set shareholder_extra_cents = s.company_only_cents + s.pass_through_cents, owner_revenue_cents = v_rev,
             company_share_bps = v_sh_bps, company_share_cents = v_share, owner_payout_cents = v_rev - v_share
       where booking_id = p_booking and vehicle_id = s.vehicle_id;
    else
      -- 1: the term in force on each rental day
      v_bps := app.split_day_share_bps(s.vehicle_id, coalesce(s.segment_starts_at, b.pickup_at), coalesce(s.segment_days, b.billable_days), b.booking_type::text, s.company_share_bps);
      if v_bps is distinct from s.company_share_bps then
        v_share := public.calc_bps(s.owner_revenue_cents, v_bps);
        update booking_splits set company_share_bps = v_bps, company_share_cents = v_share, owner_payout_cents = s.owner_revenue_cents - v_share
         where booking_id = p_booking and vehicle_id = s.vehicle_id;
      end if;
    end if;
  end loop;
end $$;
select pg_temp.copy_grants('app.compute_booking_split_pre2371(uuid)'::regprocedure, 'app.compute_booking_split_pre3100(uuid)'::regprocedure);

-- ================================================================ 3. a versioned correction of a car's terms
create table if not exists vehicle_terms_corrections (
  id               uuid primary key default gen_random_uuid(),
  vehicle_id       uuid not null references vehicles (id),
  owner_id         uuid references owners (id),
  effective_from   date not null,
  reason           text not null check (char_length(reason) between 10 and 500),
  values_set       jsonb not null,
  periods_before   jsonb not null,
  periods_after    jsonb not null,
  owner_gets_less  boolean not null,
  resign_change_id uuid references vehicle_term_changes (id),
  statements       jsonb not null default '[]'::jsonb,
  created_by       uuid references users (id),
  created_at       timestamptz not null default now()
);
create index if not exists vehicle_terms_corrections_vehicle_idx on vehicle_terms_corrections (vehicle_id, created_at);
create index if not exists vehicle_terms_corrections_owner_idx on vehicle_terms_corrections (owner_id);
create index if not exists vehicle_terms_corrections_resign_idx on vehicle_terms_corrections (resign_change_id);
alter table vehicle_terms_corrections enable row level security;
create policy admin_all on vehicle_terms_corrections for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on vehicle_terms_corrections from anon;
create trigger audit_vehicle_terms_corrections after insert or update or delete on vehicle_terms_corrections for each row execute function app.audit_row();
comment on table vehicle_terms_corrections is 'Release 48 MR (3100): each correction of a car''s terms from a date (app.car_terms_correct): the values set, the periods before and after, whether the owner gets less (an updated Vehicle Schedule to sign) and the statements recomputed. Append-only.';

create function app.car_terms_periods(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('from', h.effective_from, 'to', h.effective_to, 'revenue_share_bps', h.revenue_share_bps,
           'insurance_fee_cents', h.insurance_fee_cents, 'tracker_fee_cents', h.tracker_fee_cents, 'source', h.source) order by h.effective_from), '[]'::jsonb)
    from vehicle_fee_history h where h.vehicle_id = p_vehicle
$$;

-- p: {vehicle_id, effective_from (default: the car's start), revenue_share_bps?, insurance_fee_cents?, tracker_fee_cents?,
--     reason (10 characters or more), preview?, recompute_statements?}
create function app.car_terms_correct(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  s vehicle_schedules;
  r vehicle_fee_history;
  v_start date;
  v_from date;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', p ->> 'note', '')), '');
  v_share integer := app.ct_int(p, 'revenue_share_bps')::integer;
  v_ins bigint := app.ct_int(p, 'insurance_fee_cents');
  v_trk bigint := app.ct_int(p, 'tracker_fee_cents');
  v_less boolean := false;
  v_changed boolean := false;
  v_before jsonb;
  v_after jsonb;
  v_change uuid;
  v_corr uuid;
  v_now jsonb;
  v_stmts jsonb := '[]'::jsonb;
  v_st owner_statements;
  v_new uuid;
  x record;
begin
  perform app.assert_admin(p_by);
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid for update;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  if v.supply_type <> 'program_owner' then raise exception 'A % car has no owner terms', lower(app.supply_label(v.supply_type)) using errcode = '23514'; end if;
  if app.is_shareholder_car(v.id, v.owner_id) then raise exception 'A shareholder car has fixed terms: 90/10 and no Fees' using errcode = '23514'; end if;
  if v_share is not null and v_share > 10000 then raise exception 'The management fee (Revenue Share) is between 0%% and 100%%' using errcode = '22023'; end if;
  if v_share is null and v_ins is null and v_trk is null then raise exception 'Give the corrected management fee or Fees' using errcode = '22023'; end if;
  if v_reason is null or char_length(v_reason) < 10 then raise exception 'Say why the terms are corrected (10 characters or more): it is kept with the correction' using errcode = '22023'; end if;
  if v.management_mode = 'self_managed' and coalesce(v_share, 0) <> 0 then raise exception 'A Self-Managed car has no management fee (Revenue Share)' using errcode = '23514'; end if;

  -- not enrolled yet (no periods): the terms editor applies them at once, before the schedule is signed
  if not exists (select 1 from vehicle_fee_history h where h.vehicle_id = v.id) then
    if coalesce((p ->> 'preview')::boolean, false) then
      return app.car_terms_change(p_by, jsonb_strip_nulls(jsonb_build_object('vehicle_id', v.id, 'revenue_share_bps', v_share, 'insurance_fee_cents', v_ins,
        'tracker_fee_cents', v_trk, 'reason', v_reason, 'preview', true)));
    end if;
    return app.car_terms_change(p_by, jsonb_strip_nulls(jsonb_build_object('vehicle_id', v.id, 'revenue_share_bps', v_share, 'insurance_fee_cents', v_ins,
      'tracker_fee_cents', v_trk, 'reason', v_reason))) || jsonb_build_object('correction', false);
  end if;

  select min(h.effective_from) into v_start from vehicle_fee_history h where h.vehicle_id = v.id;
  v_from := coalesce(nullif(p ->> 'effective_from', '')::date, v_start);
  if v_from < v_start then
    raise exception 'The car''s terms start on %: a correction starts that day or later', app.fmt_day(v_start) using errcode = '22023';
  end if;
  v_before := app.car_terms_periods(v.id);
  for r in select * from vehicle_fee_history h where h.vehicle_id = v.id and (h.effective_to is null or h.effective_to > v_from) loop
    if (v_share is not null and v_share <> r.revenue_share_bps) or (v_ins is not null and v_ins <> r.insurance_fee_cents) or (v_trk is not null and v_trk <> r.tracker_fee_cents) then
      v_changed := true;
    end if;
    if (v_share is not null and v_share > r.revenue_share_bps) or (v_ins is not null and v_ins > r.insurance_fee_cents) or (v_trk is not null and v_trk > r.tracker_fee_cents) then
      v_less := true;
    end if;
  end loop;
  if not v_changed then
    raise exception 'These are the terms already in place from %', app.fmt_day(v_from) using errcode = '22023';
  end if;
  if coalesce((p ->> 'preview')::boolean, false) then
    return jsonb_build_object('correction', true, 'preview', true, 'effective_from', v_from, 'owner_gets_less', v_less, 'periods_before', v_before,
      'steps', jsonb_build_array(format('The periods from %s take the corrected values; the values replaced are kept with the reason.', app.fmt_day(v_from)),
        case when v_less then 'The correction gives the owner less: the owner is sent an updated Vehicle Schedule to sign (it confirms the corrected terms).'
             else 'The correction gives the owner the same or more: no new signature is needed.' end,
        'Bookings not yet on an approved statement are worked out again on the corrected terms.'));
  end if;

  -- the period running on the date is cut there; every period from the date takes the corrected values
  for r in select * from vehicle_fee_history h where h.vehicle_id = v.id and h.effective_from < v_from and (h.effective_to is null or h.effective_to > v_from) loop
    update vehicle_fee_history set effective_to = v_from where id = r.id;
    insert into vehicle_fee_history (vehicle_id, vehicle_schedule_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from, effective_to, created_by)
    values (v.id, r.vehicle_schedule_id, 'correction', coalesce(v_ins, r.insurance_fee_cents), coalesce(v_trk, r.tracker_fee_cents), coalesce(v_share, r.revenue_share_bps),
            v_from, r.effective_to, p_by);
  end loop;
  update vehicle_fee_history h set source = 'correction', insurance_fee_cents = coalesce(v_ins, h.insurance_fee_cents), tracker_fee_cents = coalesce(v_trk, h.tracker_fee_cents),
         revenue_share_bps = coalesce(v_share, h.revenue_share_bps), notice_sent_on = null
   where h.vehicle_id = v.id and h.effective_from >= v_from;
  -- the negotiated terms of the car (what a new schedule starts from) follow the correction
  update owner_terms t set revenue_share_bps = coalesce(v_share, t.revenue_share_bps), insurance_fee_cents = coalesce(v_ins, t.insurance_fee_cents),
         tracker_fee_cents = coalesce(v_trk, t.tracker_fee_cents)
   where t.vehicle_id = v.id and t.owner_id = v.owner_id and (t.effective_to is null or t.effective_to > v_from);
  v_after := app.car_terms_periods(v.id);

  -- the owner gets less: an updated Vehicle Schedule to sign, confirming the corrected terms (applying it changes nothing)
  select * into s from vehicle_schedules where vehicle_id = v.id and superseded_by is null;
  if v_less and s.id is not null and s.signed_at is not null then
    -- the terms of the open period (the corrected values the owner confirms)
    select jsonb_build_object('insurance_fee_cents', h.insurance_fee_cents, 'tracker_fee_cents', h.tracker_fee_cents, 'revenue_share_bps', h.revenue_share_bps) into v_now
      from vehicle_fee_history h where h.vehicle_id = v.id order by (h.effective_to is null) desc, h.effective_from desc limit 1;
    update vehicle_term_changes set status = 'cancelled', cancelled_reason = 'Replaced by a correction of the terms'
     where vehicle_id = v.id and status = 'awaiting_signature';
    insert into vehicle_term_changes (vehicle_id, kind, status, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, install_fee_cents, first_last_cents,
                                      previous, notice_sent_on, effective_from, reason, created_by)
    values (v.id, 'new_schedule', 'awaiting_signature', (v_now ->> 'insurance_fee_cents')::bigint, (v_now ->> 'tracker_fee_cents')::bigint, (v_now ->> 'revenue_share_bps')::integer,
            s.install_fee_cents, s.first_last_cents,
            jsonb_build_object('schedule_id', s.id, 'schedule_number', s.schedule_number, 'insurance_fee_cents', s.insurance_fee_cents, 'tracker_fee_cents', s.tracker_fee_cents,
                               'revenue_share_bps', s.revenue_share_bps, 'install_fee_cents', s.install_fee_cents, 'first_last_cents', s.first_last_cents, 'correction', true),
            app.today(), app.today(), 'Correction of the agreed terms from ' || app.fmt_day(v_from) || ': ' || v_reason, p_by)
    returning id into v_change;
    perform app.ntf_emit('owner_schedule_resign', 'vehicle_term_change', v_change, 'sent', jsonb_build_object('owner_id', v.owner_id, 'vehicle_id', v.id));
  end if;

  insert into vehicle_terms_corrections (vehicle_id, owner_id, effective_from, reason, values_set, periods_before, periods_after, owner_gets_less, resign_change_id, created_by)
  values (v.id, v.owner_id, v_from, v_reason, jsonb_strip_nulls(jsonb_build_object('revenue_share_bps', v_share, 'insurance_fee_cents', v_ins, 'tracker_fee_cents', v_trk)),
          v_before, v_after, v_less, v_change, p_by)
  returning id into v_corr;

  -- the bookings on this car not yet on an approved statement are worked out again
  for x in select distinct b.id from bookings b
            where b.booking_type::text <> 'owner'
              and (b.vehicle_id = v.id or exists (select 1 from booking_splits s2 where s2.booking_id = b.id and s2.vehicle_id = v.id))
              and exists (select 1 from booking_splits s3 where s3.booking_id = b.id and s3.owner_statement_id is null) loop
    perform app.compute_booking_split(x.id);
  end loop;

  -- the statements of the owner approved and not paid out: built again when asked
  if coalesce((p ->> 'recompute_statements')::boolean, false) then
    for v_st in select st.* from owner_statements st where st.owner_id = v.owner_id and st.status = 'approved'
                   and not exists (select 1 from payouts po where po.owner_statement_id = st.id and po.status in ('sent', 'paid')) order by st.statement_month loop
      v_new := app.owner_statement_recompute(v_st.id, p_by, 'Terms corrected from ' || app.fmt_day(v_from) || ': ' || v_reason);
      v_stmts := v_stmts || jsonb_build_object('voided', v_st.statement_number, 'new', (select statement_number from owner_statements where id = v_new));
    end loop;
    update vehicle_terms_corrections set statements = v_stmts where id = v_corr;
  end if;

  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'car_terms_correct', 'vehicles', v.id::text, jsonb_build_object('periods', v_before),
          jsonb_build_object('periods', v_after, 'from', v_from, 'reason', v_reason, 'owner_gets_less', v_less, 'resign_change_id', v_change, 'statements', v_stmts));
  return jsonb_build_object('correction', true, 'done', true, 'correction_id', v_corr, 'effective_from', v_from, 'owner_gets_less', v_less,
    'resign_change_id', v_change, 'periods', v_after, 'statements', v_stmts);
end $$;

-- ================================================================ 4. an approved statement built again
create function app.owner_statement_recompute(p_statement uuid, p_by uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  st owner_statements;
  v_new uuid;
  n owner_statements;
begin
  perform app.assert_admin(p_by);
  select * into st from owner_statements where id = p_statement;
  if st.id is null then raise exception 'Statement not found' using errcode = 'P0002'; end if;
  if st.status <> 'approved' then raise exception 'Statement % is %: only an approved statement not paid out is recomputed', st.statement_number, st.status using errcode = '23514'; end if;
  v_new := app.reissue_owner_statement(st.id, p_by, p_reason);
  perform app.approve_owner_statement(v_new, p_by);
  select * into n from owner_statements where id = v_new;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'owner_statement_recompute', 'owner_statements', st.id::text,
          jsonb_build_object('statement_number', st.statement_number, 'owner_revenue_cents', st.owner_revenue_cents, 'revenue_share_cents', st.revenue_share_cents,
                             'kickbacks_earned_cents', st.kickbacks_earned_cents, 'payout_cents', st.payout_cents),
          jsonb_build_object('statement_id', n.id, 'statement_number', n.statement_number, 'owner_revenue_cents', n.owner_revenue_cents, 'revenue_share_cents', n.revenue_share_cents,
                             'kickbacks_earned_cents', n.kickbacks_earned_cents, 'payout_cents', n.payout_cents, 'reason', p_reason));
  return v_new;
end $$;

-- the connector's change_owner_terms (ops_do owner_terms_save) with correction: true
alter function app.owner_terms_save(uuid, jsonb) rename to owner_terms_save_pre3100;
create function app.owner_terms_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if coalesce((p ->> 'correction')::boolean, false) then
    if nullif(p ->> 'vehicle_id', '') is null then raise exception 'A correction is made per car: give vehicle_id' using errcode = '22023'; end if;
    return app.car_terms_correct(p_by, p);
  end if;
  return app.owner_terms_save_pre3100(p_by, p);
end $$;
select pg_temp.copy_grants('app.owner_terms_save(uuid, jsonb)'::regprocedure, 'app.owner_terms_save_pre3100(uuid, jsonb)'::regprocedure);

-- ================================================================ 5. the terms on the connector's get_car and get_owner
create function app.car_terms_json(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when v.id is null then null else
    jsonb_build_object('state', n ->> 'state', 'revenue_share_bps', (n ->> 'revenue_share_bps')::integer,
      'insurance_fee_cents', (n ->> 'insurance_fee_cents')::bigint, 'tracker_fee_cents', (n ->> 'tracker_fee_cents')::bigint,
      'install_fee_cents', (n ->> 'install_fee_cents')::bigint, 'effective_from', n ->> 'since', 'schedule_number', n ->> 'schedule_number',
      'schedule_signed_at', n ->> 'signed_at', 'shareholder', app.is_shareholder_car(v.id, v.owner_id),
      'fees_paid_from', (select o.fees_paid_from from owners o where o.id = v.owner_id),
      'periods', app.car_terms_periods(v.id),
      'awaiting_signature', (select jsonb_agg(jsonb_build_object('change_id', c.id, 'revenue_share_bps', c.revenue_share_bps, 'insurance_fee_cents', c.insurance_fee_cents,
                                 'tracker_fee_cents', c.tracker_fee_cents, 'from', c.effective_from)) from vehicle_term_changes c where c.vehicle_id = v.id and c.status = 'awaiting_signature'),
      'referral', (select jsonb_agg(jsonb_build_object('referrer_owner_id', l.referrer_owner_id, 'share_bps', l.share_bps, 'from', l.effective_from))
                     from owner_referral_links l where l.referred_owner_id = v.owner_id and l.effective_to is null)) end
    from vehicles v cross join lateral (select app.ct_now(v.id) as n) t where v.id = p_vehicle
$$;

create or replace function app.api_vehicle_row(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('vehicle_id', v.id, 'car', app.vehicle_name(v.id), 'plate', v.plate, 'vin', v.vin, 'status', v.status, 'bookings_enabled', v.bookings_enabled,
           'owner_id', v.owner_id, 'owner', (select o.legal_name from owners o where o.id = v.owner_id), 'class', v.class, 'retired_at', v.retired_at,
           'rates', (select jsonb_build_object('daily_cents', r.daily_rate_cents, 'weekend_cents', r.weekend_rate_cents, 'weekly_cents', r.weekly_rate_cents,
                                               'monthly_cents', r.monthly_rate_cents, 'km_per_day', r.km_allowance_per_day, 'deposit_cents', r.deposit_cents, 'from', r.effective_from)
                       from rate_cards r where r.vehicle_id = v.id and (r.effective_to is null or r.effective_to > now()) order by r.effective_from desc limit 1),
           'fee_overrides', coalesce((select jsonb_agg(jsonb_build_object('fee', f.fee_type_code, 'amount_cents', f.amount_cents, 'percent_bps', f.percent_bps, 'cap_cents', f.cap_cents, 'from', f.effective_from))
                                        from vehicle_fee_overrides f where f.vehicle_id = v.id and (f.effective_to is null or f.effective_to > app.today())), '[]'::jsonb),
           'terms', case when v.supply_type = 'program_owner' then app.car_terms_json(v.id) end,
           'admin_path', '/admin/vehicles/' || v.id)
    from vehicles v where v.id = p_id
$$;

create or replace function app.api_owner_row(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select to_jsonb(o) - 'balance_carried_forward_cents' - 'registrant_identification_number' - 'corporation_number'
         || jsonb_build_object('cars', coalesce((select jsonb_agg(jsonb_build_object('vehicle_id', v.id, 'car', app.vehicle_name(v.id), 'plate', v.plate, 'status', v.status,
                                                                     'terms', case when v.supply_type = 'program_owner' then app.car_terms_json(v.id) end) order by v.created_at)
                                           from vehicles v where v.owner_id = o.id and v.retired_at is null), '[]'::jsonb),
                               'referral_links', coalesce((select jsonb_agg(jsonb_build_object('referrer_owner_id', l.referrer_owner_id, 'referred_owner_id', l.referred_owner_id,
                                                                     'share_bps', l.share_bps, 'sees_cars', l.sees_cars, 'from', l.effective_from))
                                                     from owner_referral_links l where (l.referrer_owner_id = o.id or l.referred_owner_id = o.id) and l.effective_to is null), '[]'::jsonb),
                               'admin_path', '/admin/owners/' || o.id)
    from owners o where o.id = p_id
$$;

-- ================================================================ 6. the terms audit (scripts/owner-terms-audit.mjs reads it)
-- The terms agreed with each owner, from the owner's notes; one row per owner (every car of the owner) or per car.
create table if not exists owner_terms_agreed (
  id                    uuid primary key default gen_random_uuid(),
  owner_id              uuid not null references owners (id),
  vehicle_id            uuid references vehicles (id),
  revenue_share_bps     integer check (revenue_share_bps between 0 and 10000),   -- null: not agreed in the notes, left as it is
  insurance_fee_cents   bigint check (insurance_fee_cents >= 0),
  costs_from_earnings   boolean,
  shareholder           boolean not null default false,
  referrer_owner_id     uuid references owners (id),
  referral_share_bps    integer check (referral_share_bps between 0 and 5000),
  note                  text,
  created_at            timestamptz not null default now(),
  unique (owner_id, vehicle_id)
);
create index if not exists owner_terms_agreed_vehicle_idx on owner_terms_agreed (vehicle_id);
create index if not exists owner_terms_agreed_referrer_idx on owner_terms_agreed (referrer_owner_id);
alter table owner_terms_agreed enable row level security;
create policy admin_all on owner_terms_agreed for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on owner_terms_agreed from anon;
create trigger audit_owner_terms_agreed after insert or update or delete on owner_terms_agreed for each row execute function app.audit_row();
comment on table owner_terms_agreed is 'Release 48 MR (3100): the terms agreed with each owner (management fee, Insurance Fee per car a month, costs out of earnings, shareholder, referral), from the owner''s notes; app.owner_terms_audit compares every car with them.';

-- every car of every program owner: the terms in force today against the agreed ones
create function app.owner_terms_audit() returns table (owner_id uuid, owner text, vehicle_id uuid, car text, plate text,
    revenue_share_bps integer, agreed_share_bps integer, insurance_fee_cents bigint, agreed_insurance_cents bigint,
    fees_paid_from text, agreed_costs_from_earnings boolean, shareholder boolean, effective_from date, status text, flags text[])
language sql stable security definer set search_path = public, app as $$
  with c as (
    select o.id as owner_id, o.legal_name as owner, v.id as vehicle_id, app.vehicle_name(v.id) as car, v.plate, o.fees_paid_from,
           app.is_shareholder_car(v.id, o.id) as shareholder, app.ct_now(v.id) as n,
           case when a1.id is not null then a1 else a2 end as a
      from vehicles v join owners o on o.id = v.owner_id
      left join owner_terms_agreed a1 on a1.vehicle_id = v.id
      left join owner_terms_agreed a2 on a2.owner_id = o.id and a2.vehicle_id is null
     where v.supply_type = 'program_owner' and v.retired_at is null and v.status::text not in ('declined', 'exited', 'total_loss')
       and not coalesce(o.is_test, false)
  )
  select c.owner_id, c.owner, c.vehicle_id, c.car, c.plate,
         (c.n ->> 'revenue_share_bps')::integer, (c.a).revenue_share_bps, (c.n ->> 'insurance_fee_cents')::bigint, (c.a).insurance_fee_cents,
         c.fees_paid_from, (c.a).costs_from_earnings, c.shareholder, (c.n ->> 'since')::date,
         case when (c.a).owner_id is null then 'no agreed terms'
              when array_length(array_remove(f.flags, 'management fee not in the notes: left as it is'), 1) is not null then 'mismatch'
              when array_length(f.flags, 1) is not null then 'matches (management fee to confirm)' else 'matches' end,
         f.flags
    from c cross join lateral (select array_remove(array[
           case when (c.a).revenue_share_bps is null and not (c.a).shareholder and (c.a).owner_id is not null then 'management fee not in the notes: left as it is' end,
           case when (c.a).revenue_share_bps is not null and not (c.a).shareholder and (c.n ->> 'revenue_share_bps')::integer is distinct from (c.a).revenue_share_bps then 'management fee' end,
           case when (c.a).insurance_fee_cents is not null and not (c.a).shareholder and (c.n ->> 'insurance_fee_cents')::bigint is distinct from (c.a).insurance_fee_cents then 'insurance' end,
           case when (c.a).costs_from_earnings is not null and (c.fees_paid_from = 'statement') is distinct from (c.a).costs_from_earnings then 'costs from earnings' end,
           case when (c.a).shareholder and not c.shareholder then 'shareholder' end,
           case when (c.a).shareholder and (c.n ->> 'insurance_fee_cents')::bigint <> 0 then 'shareholder insurance' end], null) as flags) f
   order by c.owner, c.car
$$;

revoke all on function app.split_day_share_bps(uuid, timestamptz, integer, text, integer), app.is_shareholder_car(uuid, uuid), app.car_terms_periods(uuid),
  app.car_terms_correct(uuid, jsonb), app.owner_statement_recompute(uuid, uuid, text), app.car_terms_json(uuid), app.owner_terms_audit(),
  app.owner_terms_save_pre3100(uuid, jsonb), app.compute_booking_split_pre3100(uuid) from public, anon, authenticated;
grant execute on function app.split_day_share_bps(uuid, timestamptz, integer, text, integer), app.is_shareholder_car(uuid, uuid), app.car_terms_periods(uuid),
  app.car_terms_correct(uuid, jsonb), app.owner_statement_recompute(uuid, uuid, text), app.car_terms_json(uuid), app.owner_terms_audit(),
  app.owner_terms_save_pre3100(uuid, jsonb), app.compute_booking_split_pre3100(uuid) to service_role;
