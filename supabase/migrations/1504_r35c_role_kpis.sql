-- 1504_r35c_role_kpis.sql
-- Release 35, part C (item 2): KPIs for each role, on the person's scorecard (the Admin sees everyone's on Admin > Team >
-- KPIs). Every target is a Program setting (kpi_*). A week is Monday to Sunday, Toronto.
--   Customer service  first reply within kpi_cs_first_reply_minutes (5) for kpi_rate_target_pct (90%) of the conversations;
--                     conversations handled, licences reviewed, booking requests answered (weekly minimums)
--   Fleet             handovers on time (the team's handovers and deliveries done within kpi_on_time_grace_minutes of the
--                     time set), photo reviews, the next-day list (the closing check) on each scheduled day, field jobs
--                     dispatched, calls (weekly minimums)
--   Finance           deposits reviewed within kpi_finance_deposit_review_hours of the Fleet check, owner statements sent by
--                     their payout day and owner invoices issued by their billing day, tolls and tickets checked on at
--                     least kpi_finance_toll_checks_week days (2 to 3 a week)
--   Sales             unchanged (the month's rental days target, 0057)
--   Field             jobs done, jobs on time, photos complete (a condition report with at least kpi_field_min_photos)
-- Each KPI: {key, label, value, target, unit ('count', 'pct', 'min', 'days'), met}. A rate with no cases is not met nor missed.
-- No applied migration is edited: app.staff_scorecard is wrapped, app.door wrapped.
set local check_function_bodies = off;

alter table program_settings
  add column if not exists kpi_rate_target_pct integer not null default 90 check (kpi_rate_target_pct between 1 and 100),
  add column if not exists kpi_on_time_grace_minutes integer not null default 15 check (kpi_on_time_grace_minutes between 0 and 240),
  add column if not exists kpi_cs_first_reply_minutes integer not null default 5 check (kpi_cs_first_reply_minutes between 1 and 240),
  add column if not exists kpi_cs_conversations_week integer not null default 40 check (kpi_cs_conversations_week >= 0),
  add column if not exists kpi_cs_licences_week integer not null default 5 check (kpi_cs_licences_week >= 0),
  add column if not exists kpi_cs_requests_week integer not null default 10 check (kpi_cs_requests_week >= 0),
  add column if not exists kpi_fleet_photo_reviews_week integer not null default 10 check (kpi_fleet_photo_reviews_week >= 0),
  add column if not exists kpi_fleet_dispatch_week integer not null default 10 check (kpi_fleet_dispatch_week >= 0),
  add column if not exists kpi_fleet_calls_week integer not null default 20 check (kpi_fleet_calls_week >= 0),
  add column if not exists kpi_finance_deposit_review_hours integer not null default 48 check (kpi_finance_deposit_review_hours between 1 and 720),
  add column if not exists kpi_finance_toll_checks_week integer not null default 2 check (kpi_finance_toll_checks_week between 0 and 7),
  add column if not exists kpi_field_jobs_week integer not null default 10 check (kpi_field_jobs_week >= 0),
  add column if not exists kpi_field_min_photos integer not null default 8 check (kpi_field_min_photos between 1 and 60);
comment on column program_settings.kpi_rate_target_pct is 'KPIs (1504): the share a rate KPI must reach (on-time, first reply, within deadline).';
comment on column program_settings.kpi_cs_first_reply_minutes is 'KPIs (1504): customer service''s first reply target, in minutes.';
comment on column program_settings.kpi_field_min_photos is 'KPIs (1504): the photos a field job''s condition report needs to count as complete.';

create function app.kpi_item(p_key text, p_label text, p_value numeric, p_target numeric, p_unit text, p_met boolean, p_detail text default null) returns jsonb
language sql immutable as $$
  select jsonb_build_object('key', p_key, 'label', p_label, 'value', p_value, 'target', p_target, 'unit', p_unit, 'met', p_met, 'detail', p_detail)
$$;
create function app.kpi_rate(p_key text, p_label text, p_ok bigint, p_total bigint, p_detail text default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.kpi_item(p_key, p_label, case when p_total > 0 then round(100.0 * p_ok / p_total) end, (app.settings()).kpi_rate_target_pct, 'pct',
    case when p_total > 0 then round(100.0 * p_ok / p_total) >= (app.settings()).kpi_rate_target_pct end,
    coalesce(p_detail || ' · ', '') || p_ok || ' of ' || p_total)
$$;
create function app.kpi_count(p_key text, p_label text, p_n bigint, p_target integer) returns jsonb
language sql immutable as $$ select app.kpi_item(p_key, p_label, p_n, p_target, 'count', case when p_target > 0 then p_n >= p_target end) $$;

-- the KPIs of one person for the week starting p_week (a Monday, Toronto)
create function app.role_kpis(p_user uuid, p_week date) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  a timestamptz := p_week::timestamp at time zone 'America/Toronto';
  z timestamptz := least((p_week + 7)::timestamp at time zone 'America/Toronto', now());
  fns text[] := coalesce((select sp.functions from staff_profiles sp where sp.user_id = p_user), '{}');
  out jsonb := '[]'::jsonb;
  n1 bigint; n2 bigint; v numeric; n3 bigint; n4 bigint;
  v_grace interval := make_interval(mins => s.kpi_on_time_grace_minutes);
begin
  if 'cs' = any (fns) then
    -- first replies: this person's reply that came first after a customer's message (the wait from that message)
    select count(*) filter (where w <= s.kpi_cs_first_reply_minutes * 60), count(*), round(avg(w) / 60.0, 1) into n1, n2, v
      from (select extract(epoch from o.started_at - i.started_at) w
              from phone_activity o
              join lateral (select max(x.started_at) started_at from phone_activity x where x.thread_id = o.thread_id and x.direction = 'in' and x.started_at < o.started_at) i on i.started_at is not null
             where o.staff_user_id = p_user and o.direction = 'out' and o.started_at >= a and o.started_at < z
               and not exists (select 1 from phone_activity y where y.thread_id = o.thread_id and y.direction = 'out' and y.started_at > i.started_at and y.started_at < o.started_at)) q;
    out := out || jsonb_build_array(
      app.kpi_rate('cs_first_reply', format('First reply within %s minutes', s.kpi_cs_first_reply_minutes), n1, n2, case when v is not null then 'average ' || v || ' min' end),
      app.kpi_count('cs_conversations', 'Conversations handled', (select count(distinct o.thread_id) from phone_activity o where o.staff_user_id = p_user and o.direction = 'out' and o.started_at >= a and o.started_at < z), s.kpi_cs_conversations_week),
      app.kpi_count('cs_licences', 'Licences reviewed', (select count(*) from identity_verifications iv where iv.verified_by = p_user and iv.verified_at >= a and iv.verified_at < z), s.kpi_cs_licences_week),
      app.kpi_count('cs_requests', 'Booking requests answered', (select count(distinct e.booking_id) from booking_events e where e.actor_user_id = p_user and e.kind in ('offer_sent', 'declined', 'info_requested')
                                                                    and e.created_at >= a and e.created_at < z), s.kpi_cs_requests_week));
  end if;
  if 'fleet' = any (fns) then
    -- the team's handovers and deliveries done in the week: on time when done within the grace of the time set
    select count(*) filter (where j.completed_at <= j.scheduled_at + v_grace), count(*) into n1, n2
      from field_jobs j where j.kind in ('handover', 'delivery') and j.status = 'done' and j.completed_at >= a and j.completed_at < z;
    -- the scheduled days of the week so far, and the closing checks (the next-day list) this person submitted on them
    select count(*), count(*) filter (where exists (select 1 from daily_checks c where c.kind = 'closing' and c.check_date = d::date and c.completed_by = p_user and c.completed_at is not null))
      into n3, n4
      from generate_series(p_week, least(p_week + 6, app.today()), interval '1 day') d
     where exists (select 1 from app.staff_shifts_on(p_user, d::date) x where x.function = 'fleet');
    out := out || jsonb_build_array(
      app.kpi_rate('fleet_handovers_on_time', 'Handovers on time (the team)', n1, n2),
      app.kpi_count('fleet_photo_reviews', 'Photo reviews', (select count(*) from field_jobs j where j.reviewed_by = p_user and j.reviewed_at >= a and j.reviewed_at < z)
                                                              + (select count(*) from condition_reports r where r.reviewed_by = p_user and r.reviewed_at >= a and r.reviewed_at < z), s.kpi_fleet_photo_reviews_week),
      app.kpi_item('fleet_next_day_list', 'Next-day list submitted (the closing check)', n4, n3, 'days', case when n3 > 0 then n4 >= n3 end, n4 || ' of ' || n3 || ' scheduled days'),
      app.kpi_count('fleet_dispatched', 'Field jobs dispatched', (select count(*) from field_jobs j where j.dispatched_by = p_user and j.created_at >= a and j.created_at < z), s.kpi_fleet_dispatch_week),
      app.kpi_count('fleet_calls', 'Calls', (select count(*) from phone_activity o where o.staff_user_id = p_user and o.kind = 'call' and o.started_at >= a and o.started_at < z), s.kpi_fleet_calls_week));
  end if;
  if 'finance' = any (fns) then
    -- deposits: the reviews whose deadline (the Fleet check, else the return, plus the hours) fell in the week
    select count(*) filter (where r.finance_done_at is not null and r.finance_done_at <= coalesce(r.fleet_done_at, r.returned_at) + make_interval(hours => s.kpi_finance_deposit_review_hours)), count(*)
      into n1, n2
      from deposit_reviews r
     where coalesce(r.fleet_done_at, r.returned_at) + make_interval(hours => s.kpi_finance_deposit_review_hours) >= a
       and coalesce(r.fleet_done_at, r.returned_at) + make_interval(hours => s.kpi_finance_deposit_review_hours) < z;
    -- statements sent by their payout day, invoices issued by their billing day (those due in the week)
    select (select count(*) filter (where st.sent_at is not null and st.sent_at < app.local_midnight(st.payout_date + 1)) from owner_statements st
             where st.voided_at is null and st.payout_date between p_week and least(p_week + 6, app.today()))
         + (select count(*) filter (where i.issued_at is not null and i.issued_at < app.local_midnight(i.billing_date + 1)) from owner_invoices i
             where i.status <> 'draft' and i.status <> 'void' and i.billing_date between p_week and least(p_week + 6, app.today())),
           (select count(*) from owner_statements st where st.voided_at is null and st.payout_date between p_week and least(p_week + 6, app.today()))
         + (select count(*) from owner_invoices i where i.status <> 'draft' and i.status <> 'void' and i.billing_date between p_week and least(p_week + 6, app.today()))
      into n3, n4;
    out := out || jsonb_build_array(
      app.kpi_rate('finance_deposits', format('Deposits reviewed within %s hours', s.kpi_finance_deposit_review_hours), n1, n2),
      app.kpi_rate('finance_statements', 'Statements and invoices on time', n3, n4),
      app.kpi_item('finance_toll_checks', 'Tolls and tickets checked (days)', (select count(distinct app.local_date(c.checked_at)) from deposit_review_ticket_checks c where c.checked_by = p_user and c.checked_at >= a and c.checked_at < z),
        s.kpi_finance_toll_checks_week, 'days',
        case when s.kpi_finance_toll_checks_week > 0 then (select count(distinct app.local_date(c.checked_at)) from deposit_review_ticket_checks c where c.checked_by = p_user and c.checked_at >= a and c.checked_at < z) >= s.kpi_finance_toll_checks_week end,
        '2 to 3 times a week'));
  end if;
  if 'field' = any (fns) then
    select count(*), count(*) filter (where j.completed_at <= j.scheduled_at + v_grace),
           count(*) filter (where j.kind in ('handover', 'delivery', 'return_check_in', 'pickup_from_renter')),
           count(*) filter (where j.kind in ('handover', 'delivery', 'return_check_in', 'pickup_from_renter')
                              and exists (select 1 from condition_reports r where r.field_job_id = j.id
                                           and (select count(*) from condition_report_photos ph where ph.condition_report_id = r.id) >= s.kpi_field_min_photos))
      into n1, n2, n3, n4
      from field_jobs j where j.assigned_to = p_user and j.status = 'done' and j.completed_at >= a and j.completed_at < z;
    out := out || jsonb_build_array(
      app.kpi_count('field_jobs', 'Jobs done', n1, s.kpi_field_jobs_week),
      app.kpi_rate('field_on_time', 'Jobs on time', n2, n1),
      app.kpi_rate('field_photos', format('Photos complete (at least %s)', s.kpi_field_min_photos), n4, n3));
  end if;
  return out;
end $$;

-- the weeks of KPIs (newest first) for a scorecard
create function app.role_kpi_weeks(p_user uuid, p_weeks integer default 4) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('week_start', w, 'items', app.role_kpis(p_user, w)) order by w desc), '[]'::jsonb)
    from (select (date_trunc('week', app.today()::timestamp) - make_interval(days => 7 * k))::date w from generate_series(0, greatest(1, least(coalesce(p_weeks, 4), 8)) - 1) k) x
$$;

alter function app.staff_scorecard(uuid, integer) rename to staff_scorecard_pre1504;
create function app.staff_scorecard(p_staff uuid, p_weeks integer default 6) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.staff_scorecard_pre1504(p_staff, p_weeks) || jsonb_build_object('kpis', app.role_kpi_weeks(p_staff, least(p_weeks, 4)))
$$;

-- Admin: every staff member's KPIs of a week (default this week); the field staff's on their own portal too
create function app.kpi_board(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_week date := (date_trunc('week', coalesce(nullif(p ->> 'week', '')::date, app.today())::timestamp))::date;
  v_fn text := nullif(p ->> 'function', '');
begin
  if not app.user_is_admin(p_by) then
    -- a staff member: their own only
    if not (app.user_is_staff(p_by) or app.user_is_field(p_by)) then raise exception 'Staff only' using errcode = '42501'; end if;
    return jsonb_build_object('week', v_week, 'people', jsonb_build_array(jsonb_build_object('user_id', p_by, 'items', app.role_kpis(p_by, v_week))));
  end if;
  return jsonb_build_object('week', v_week, 'prev', v_week - 7, 'next', case when v_week + 7 <= app.today() then v_week + 7 end,
    'people', coalesce((select jsonb_agg(jsonb_build_object('user_id', sp.user_id, 'name', coalesce(u.full_name, u.email),
                 'functions', to_jsonb(sp.functions), 'items', app.role_kpis(sp.user_id, v_week)) order by coalesce(u.full_name, u.email))
               from staff_profiles sp join users u on u.id = sp.user_id
              where sp.is_active and u.status = 'active' and sp.functions && array['cs', 'fleet', 'finance', 'field']
                and (v_fn is null or v_fn = any (sp.functions)) and not app.staff_is_test(sp.user_id)), '[]'::jsonb),
    'settings', (select jsonb_build_object('rate_target_pct', s.kpi_rate_target_pct, 'grace_minutes', s.kpi_on_time_grace_minutes) from (select (app.settings()).*) s));
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1504;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_read', 'admin_read', 'field_read') and p_name = 'kpi_board' then
    perform app.door_begin(p_user, p_aal);
    return app.kpi_board(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre1504(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['kpi_item', 'kpi_rate', 'kpi_count', 'role_kpis', 'role_kpi_weeks', 'staff_scorecard_pre1504', 'staff_scorecard',
                    'kpi_board', 'door_pre1504', 'door'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
