-- 4600: the weekly townhall deck, more sections built from live data (release 50). SCHEMA_MARKER 4600. No applied migration
-- is edited: app.townhall_slides (1505's) is wrapped (townhall_slides_pre4600); app.townhall_status (4500) and
-- app.staff_access_facts (1505) are patched; app.door is wrapped (door_pre4600).
--   * Visitors: the average website visitors a day (distinct browsers, Toronto days) this week against last week, and the
--     4-week trend against the 4 weeks before, from visitor_sessions.
--   * Top incident of the week: picked automatically by seriousness from tracker alerts (pound, possible theft, the border,
--     leaving Ontario, speeding), incidents, claims, damage intakes and late returns: the car, what happened and the day,
--     never the renter. An Admin can pick another candidate or describe it (townhall_incident_pick); the deck is rebuilt.
--   * Disputes and chargebacks: from the disputes Stripe's webhooks record (disputes): this week and the month to date,
--     open against won and lost; the amounts on an Admin-only slide. No customer names.
--   * Birthdays: staff_profiles.birthday_month / birthday_day (optional, month and day only), saved by the staff member on
--     their profile or by an Admin on the staff list; the slide shows the birthdays of the townhall's week and the next,
--     and only when there are any.
--   * KPIs hit: one line for every active staff member: their role KPIs met (1504/2330), Sales (bookings closed, the
--     month's tier reached), shifts on time, field shifts worked, Academy sections passed. townhall_status counts a person
--     on this slide as featured, and lists who is missing from it (staff_missing_kpis).
--   * Fleet: this week's added and removed cars by name (year make model).
--   * Socials stay entered by hand: the repository has no social platform API connection.
-- The run stays 30 minutes: sections were rebalanced to make room (opener 1, hires 1, story 2, funnel 2, visitors 1, social 2,
-- fleet 2, investors 2, owners 1, top cars 2, insurer 1, incident 2, disputes 1, leaderboard 2, KPIs 3, dev 1, people 4,
-- or 3 with the birthdays slide at 1).
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '4600: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ birthdays (month and day only)
alter table staff_profiles add column if not exists birthday_month smallint check (birthday_month between 1 and 12),
  add column if not exists birthday_day smallint check (birthday_day between 1 and 31);
alter table staff_profiles drop constraint if exists staff_profiles_birthday_check;
alter table staff_profiles add constraint staff_profiles_birthday_check check ((birthday_month is null) = (birthday_day is null)
  and (birthday_month is null or birthday_day <= extract(day from (make_date(2000, birthday_month, 1) + interval '1 month - 1 day'))::int));
comment on column staff_profiles.birthday_month is 'Townhall (4600): the staff member''s birthday month (optional; no year is kept). Set by them on their profile or by an Admin.';
comment on column staff_profiles.birthday_day is 'Townhall (4600): the day of the birthday month (Feb 29 allowed: shown on Feb 28 in other years).';

-- p: {month, day, user_id (an Admin, for someone else)}; both empty clears it
create function app.staff_birthday_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_user uuid := coalesce(nullif(p ->> 'user_id', '')::uuid, p_by);
  v_m int := nullif(btrim(coalesce(p ->> 'month', '')), '')::int;
  v_d int := nullif(btrim(coalesce(p ->> 'day', '')), '')::int;
begin
  if v_user <> p_by then perform app.assert_admin(p_by); end if;
  if not exists (select 1 from staff_profiles sp where sp.user_id = v_user) then raise exception 'Staff only' using errcode = '42501'; end if;
  if (v_m is null) <> (v_d is null) then raise exception 'Give the month and the day, or neither' using errcode = '22023'; end if;
  if v_m is not null and (v_m not between 1 and 12 or v_d < 1 or v_d > extract(day from (make_date(2000, v_m, 1) + interval '1 month - 1 day'))::int) then
    raise exception 'That day is not in that month' using errcode = '22023';
  end if;
  update staff_profiles set birthday_month = v_m, birthday_day = v_d where user_id = v_user;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'staff_birthday_save', 'staff_profiles', v_user::text, jsonb_build_object('set', v_m is not null));
  return jsonb_build_object('user_id', v_user, 'month', v_m, 'day', v_d);
end $$;

create function app.staff_birthday_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare v_user uuid := coalesce(nullif(p ->> 'user_id', '')::uuid, p_by);
begin
  if v_user <> p_by then perform app.assert_admin(p_by); end if;
  return (select jsonb_build_object('staff', true, 'month', sp.birthday_month, 'day', sp.birthday_day) from staff_profiles sp where sp.user_id = v_user);
end $$;

-- the birthday on a year (Feb 29 is Feb 28 in other years)
create function app.birthday_on(p_year int, p_m int, p_d int) returns date
language sql immutable set search_path = public, app, pg_temp as $$
  select make_date(p_year, p_m, least(p_d, extract(day from (make_date(p_year, p_m, 1) + interval '1 month - 1 day'))::int))
$$;

-- the staff list: the birthday (MM-DD) beside the other facts
select pg_temp.patch_fn('app.staff_access_facts(uuid, jsonb)'::regprocedure,
  $o$'preferred_name', nullif(btrim(u.greeting_name), ''),$o$,
  $n$'preferred_name', nullif(btrim(u.greeting_name), ''), 'birthday', case when sp.birthday_month is not null then lpad(sp.birthday_month::text, 2, '0') || '-' || lpad(sp.birthday_day::text, 2, '0') end,$n$);

-- ================================================================ the incident an Admin picks instead
create table if not exists townhall_incident_picks (
  week_of    date primary key check (extract(isodow from week_of) = 1),
  ref        text check (ref is null or ref ~ '^(tracker|incident|claim|damage|late):[0-9a-f-]{36}$'),
  body       text check (body is null or length(btrim(body)) between 5 and 400),
  picked_by  uuid references users (id),
  picked_at  timestamptz not null default now(),
  check (ref is not null or body is not null)
);
comment on table townhall_incident_picks is 'Townhall (4600): the top incident of a week chosen by an Admin (a candidate or their own words) instead of the automatic pick.';
alter table townhall_incident_picks enable row level security;
revoke all on townhall_incident_picks from anon, authenticated;
grant all on townhall_incident_picks to service_role;
create policy admin_all on townhall_incident_picks for select to authenticated using (app.is_admin());
drop trigger if exists audit_townhall_incident_picks on townhall_incident_picks;
create trigger audit_townhall_incident_picks after insert or update or delete on townhall_incident_picks for each row execute function app.audit_row();

-- the incidents of a week, most serious first: {ref, score, label}; the car and what happened, never the renter
create function app.townhall_incident_candidates(p_week date) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  with w as (select p_week::timestamp at time zone 'America/Toronto' a, (p_week + 7)::timestamp at time zone 'America/Toronto' z),
  c as (
    select 'tracker:' || t.id ref, t.at,
           case t.kind when 'pound' then 100 when 'theft' then 98 when 'left_canada' then 85 when 'left_ontario' then 60
                       else 45 + least(30, greatest(0, coalesce(t.speed_kmh, 0) - 120) / 2) end score,
           coalesce(app.vehicle_name(t.vehicle_id), 'A car') || ': ' || case t.kind
             when 'pound' then 'the tracker shows the car at a pound (impound lot)'
             when 'theft' then 'a possible theft flagged by the tracker'
             when 'left_canada' then 'driven across the border, out of Canada'
             when 'left_ontario' then 'driven out of Ontario'
             else 'driven at ' || coalesce(t.speed_kmh::text || ' km/h', 'speeding') end label
      from tracker_alerts t, w where t.kind in ('pound', 'theft', 'left_canada', 'left_ontario', 'speeding') and t.at >= w.a and t.at < w.z
    union all
    select 'incident:' || i.id, coalesce(i.occurred_at, i.reported_at),
           case i.kind when 'impound' then 100 when 'theft' then 98 when 'non_return' then 95 when 'accident' then 90 when 'vandalism' then 70
                       when 'tracker_tampering' then 60 when 'damage_at_return' then 50 when 'damage_found_later' then 50 when 'late_return' then 40
                       when 'breakdown' then 30 else 20 end,
           coalesce(app.vehicle_name(i.vehicle_id), 'A car') || ': ' || case i.kind
             when 'impound' then 'impounded' when 'theft' then 'reported stolen' when 'non_return' then 'not returned'
             when 'accident' then 'an accident' || case when i.anyone_hurt then ', someone was hurt' else '' end
             when 'vandalism' then 'vandalised' when 'tracker_tampering' then 'the tracker was tampered with'
             when 'damage_at_return' then 'damage found at the return' when 'damage_found_later' then 'damage found after a trip'
             when 'late_return' then 'returned late' when 'breakdown' then 'broke down' else 'an incident was reported' end
      from incidents i, w where i.reported_at >= w.a and i.reported_at < w.z and i.kind <> 'other'
    union all
    select 'claim:' || cl.id, cl.created_at, 80 + least(15, cl.damage_cost_cents / 100000)::int,
           coalesce(app.vehicle_name(cl.vehicle_id), 'A car') || ': an insurance claim was opened' || coalesce(', damage of ' || app.fmt_money(nullif(cl.damage_cost_cents, 0)), '')
      from claims cl, w where cl.created_at >= w.a and cl.created_at < w.z
    union all
    select 'damage:' || di.id, di.found_at, 35 + least(30, coalesce(di.cost_cents, 0) / 50000)::int,
           coalesce(app.vehicle_name(di.vehicle_id), 'A car') || ': damage found' || coalesce(', estimated at ' || app.fmt_money(di.cost_cents), '')
      from damage_intakes di, w where di.found_at >= w.a and di.found_at < w.z
    union all
    select 'late:' || b.id, b.return_at, 30 + least(30, floor(extract(epoch from coalesce(b.checked_in_at, least(w.z, now())) - b.return_at) / 3600))::int,
           coalesce(app.vehicle_name(b.vehicle_id), 'A car') || ': ' || case when b.checked_in_at is null then 'still out, ' else 'returned ' end
             || floor(extract(epoch from coalesce(b.checked_in_at, least(w.z, now())) - b.return_at) / 3600)::int || ' hours late'
      from bookings b, w
     where b.return_at >= w.a and b.return_at < w.z and not coalesce(b.is_placeholder, false) and b.booking_type <> 'owner'
       and ((b.checked_in_at is not null and b.checked_in_at > b.return_at + interval '2 hours')
            or (b.checked_in_at is null and b.status = 'on_rent' and least(w.z, now()) > b.return_at + interval '2 hours')))
  select coalesce(jsonb_agg(jsonb_build_object('ref', ref, 'score', score, 'label', label || ', ' || to_char(at at time zone 'America/Toronto', 'FMDay FMMon FMDD') || '.')
           order by score desc, at desc), '[]'::jsonb)
    from (select * from c order by score desc, at desc limit 8) x
$$;

-- p: {deck, ref (a candidate; empty: automatic), body (their own words)}; the deck is rebuilt with it
create function app.townhall_incident_pick(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_week date;
  v_ref text := nullif(btrim(coalesce(p ->> 'ref', '')), '');
  v_body text := nullif(btrim(coalesce(p ->> 'body', '')), '');
begin
  perform app.assert_admin(p_by);
  select week_of into v_week from townhall_decks where id = nullif(p ->> 'deck', '')::uuid;
  if v_week is null then raise exception 'Deck not found' using errcode = 'P0002'; end if;
  if v_ref is not null and not exists (select 1 from jsonb_array_elements(app.townhall_incident_candidates(v_week)) x where x ->> 'ref' = v_ref) then
    raise exception 'Choose one of the incidents of that week' using errcode = '22023';
  end if;
  if v_body is not null and length(v_body) not between 5 and 400 then raise exception 'Describe it in 5 to 400 characters' using errcode = '22023'; end if;
  if v_ref is null and v_body is null then
    delete from townhall_incident_picks where week_of = v_week;
  else
    insert into townhall_incident_picks (week_of, ref, body, picked_by) values (v_week, case when v_body is null then v_ref end, v_body, p_by)
    on conflict (week_of) do update set ref = excluded.ref, body = excluded.body, picked_by = p_by, picked_at = now();
  end if;
  perform app.townhall_build(v_week, p_by);
  return jsonb_build_object('week_of', v_week, 'ref', v_ref, 'body', v_body, 'automatic', v_ref is null and v_body is null);
end $$;

-- ================================================================ the other sections
-- the average distinct visitors a Toronto day over [p_from, p_to), the days still to come left out
create function app.townhall_visitors_avg(p_from date, p_to date) returns numeric
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case when least(p_to, app.today() + 1) <= p_from then null
              else round(coalesce(sum(n), 0)::numeric / (least(p_to, app.today() + 1) - p_from), 1) end
    from (select app.local_date(s.started_at) d, count(distinct s.visitor_id) n from visitor_sessions s
           where s.started_at >= p_from::timestamp at time zone 'America/Toronto' and s.started_at < least(p_to, app.today() + 1)::timestamp at time zone 'America/Toronto'
           group by 1) x
$$;

create function app.th_change(p_now numeric, p_before numeric) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select case when p_now is null then 'no data yet' when coalesce(p_before, 0) = 0 then case when p_now > 0 then 'up (nothing before)' else 'flat' end
              when p_now = p_before then 'flat'
              else case when p_now > p_before then 'up ' else 'down ' end || abs(round(100 * (p_now - p_before) / p_before))::text || '%' end
$$;

create function app.townhall_visitor_slide(p_week date) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('key', 'visitors', 'title', 'Website visitors', 'admin_only', false, 'minutes', 1,
    'points', jsonb_build_array(app.th_point('Visitors a day this week', coalesce(t.now_::text, '0')), app.th_point('Last week', coalesce(t.last_::text, '0')),
      app.th_point('On last week', app.th_change(t.now_, t.last_)), app.th_point('4-week trend', app.th_change(t.m4, t.p4))),
    'lines', jsonb_build_array(format('The last 4 weeks: %s visitors a day, against %s in the 4 weeks before.', coalesce(t.m4::text, '0'), coalesce(t.p4::text, '0'))))
    from (select app.townhall_visitors_avg(p_week, p_week + 7) now_, app.townhall_visitors_avg(p_week - 7, p_week) last_,
                 app.townhall_visitors_avg(p_week - 21, p_week + 7) m4, app.townhall_visitors_avg(p_week - 49, p_week - 21) p4) t
$$;

create function app.townhall_incident_slide(p_week date) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  with c as (select app.townhall_incident_candidates(p_week) l),
       k as (select * from townhall_incident_picks where week_of = p_week)
  select jsonb_build_object('key', 'incident', 'title', 'Top incident of the week', 'admin_only', false, 'minutes', 2,
    'points', jsonb_build_array(app.th_point('Flagged this week', jsonb_array_length(c.l)::text)),
    'picked', case when k.body is not null or k.ref is not null then 'admin' else 'automatic' end,
    'pick_ref', k.ref,
    'candidates', (select coalesce(jsonb_agg(jsonb_build_object('ref', x ->> 'ref', 'label', x ->> 'label') order by o), '[]'::jsonb) from jsonb_array_elements(c.l) with ordinality t(x, o) where o <= 5),
    'lines', jsonb_build_array(coalesce(k.body, (select x ->> 'label' from jsonb_array_elements(c.l) x where x ->> 'ref' = k.ref), c.l #>> '{0,label}', 'No incident this week.')))
    from c left join k on true
$$;

create function app.townhall_dispute_slides(p_week date) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  with w as (select p_week::timestamp at time zone 'America/Toronto' a, (p_week + 7)::timestamp at time zone 'America/Toronto' z,
                    date_trunc('month', least(p_week + 6, app.today())::timestamp) at time zone 'America/Toronto' m),
  d as (select x.*, x.opened_at >= w.a and x.opened_at < w.z wk, x.opened_at >= w.m and x.opened_at < least(w.z, now()) mtd from disputes x, w where x.opened_at >= least(w.a, w.m)),
  s as (select count(*) filter (where wk) n_w, count(*) filter (where wk and status in ('open', 'evidence_submitted')) o_w, count(*) filter (where wk and status = 'won') won_w,
               count(*) filter (where wk and status = 'lost') lost_w, coalesce(sum(amount_cents) filter (where wk), 0) a_w,
               count(*) filter (where mtd) n_m, count(*) filter (where mtd and status in ('open', 'evidence_submitted')) o_m, count(*) filter (where mtd and status = 'won') won_m,
               count(*) filter (where mtd and status = 'lost') lost_m, coalesce(sum(amount_cents) filter (where mtd), 0) a_m,
               coalesce(sum(amount_cents) filter (where mtd and status = 'lost'), 0) lost_a_m from d)
  select jsonb_build_array(
    jsonb_build_object('key', 'disputes', 'title', 'Disputes and chargebacks', 'admin_only', false, 'minutes', 1,
      'points', jsonb_build_array(app.th_point('This week', format('%s (%s open, %s won, %s lost)', n_w, o_w, won_w, lost_w)),
                                  app.th_point('Month to date', format('%s (%s open, %s won, %s lost)', n_m, o_m, won_m, lost_m)),
                                  app.th_point('Open now', (select count(*) from disputes x where x.status in ('open', 'evidence_submitted'))::text)),
      'lines', jsonb_build_array('From the disputes Stripe reports on our payments.')),
    jsonb_build_object('key', 'disputemoney', 'title', 'Dispute amounts', 'admin_only', true, 'minutes', 0,
      'points', jsonb_build_array(app.th_point('This week', app.fmt_money(a_w)), app.th_point('Month to date', app.fmt_money(a_m)), app.th_point('Lost this month', app.fmt_money(lost_a_m)),
                                  app.th_point('Open now', app.fmt_money((select coalesce(sum(x.amount_cents), 0) from disputes x where x.status in ('open', 'evidence_submitted')))))))
    from s
$$;

-- the birthdays of the townhall's week and the next (the week of the next call from the deck's week, else of today)
create function app.townhall_birthday_lines(p_week date) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  with b as (select (date_trunc('week', coalesce(app.local_date(app.townhall_next(greatest(p_week::timestamp at time zone 'America/Toronto', now()))), app.today())::timestamp))::date w0),
  x as (select coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email) name, dd.d, dd.d >= b.w0 + 7 nxt
          from staff_profiles sp join users u on u.id = sp.user_id, b,
               lateral (select app.birthday_on(y, sp.birthday_month, sp.birthday_day) d from generate_series(extract(year from b.w0)::int, extract(year from b.w0)::int + 1) y) dd
         where sp.birthday_month is not null and app.staff_is_member(sp.user_id) and not app.staff_is_test(sp.user_id) and dd.d >= b.w0 and dd.d < b.w0 + 14)
  select coalesce(jsonb_agg(name || ': ' || to_char(d, 'FMDay, FMMonth FMDD') || case when nxt then ' (next week)' else ' (this week)' end order by d, name), '[]'::jsonb) from x
$$;

-- the KPIs each active staff member hit in the week: {user_id, name, hit[], tracked}
create function app.townhall_staff_kpis(p_week date) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  a timestamptz := p_week::timestamp at time zone 'America/Toronto';
  z timestamptz := least((p_week + 7)::timestamp at time zone 'America/Toronto', now());
  r record;
  out jsonb := '[]'::jsonb;
  v_hit text[];
  v_tracked int;
  k jsonb;
  x jsonb;
  n bigint; n2 bigint;
begin
  for r in select sp.user_id, sp.functions, coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email) name
             from staff_profiles sp join users u on u.id = sp.user_id where app.staff_is_member(sp.user_id)
            order by 3 loop
    v_hit := '{}'; v_tracked := 0;
    begin
      for k in select * from jsonb_array_elements(coalesce(app.role_kpis(r.user_id, p_week), '[]'::jsonb)) loop
        v_tracked := v_tracked + 1;
        if coalesce((k ->> 'met')::boolean, false) then
          v_hit := v_hit || ((k ->> 'label') || coalesce(' (' || (k ->> 'value') || case k ->> 'unit' when 'pct' then '%' else '' end || ')', ''));
        end if;
      end loop;
    exception when others then null;
    end;
    if 'sales' = any (r.functions) then
      v_tracked := v_tracked + 1;
      select count(*) into n from bookings b where b.sales_staff_id = r.user_id and b.booked_at >= a and b.booked_at < z and not coalesce(b.is_placeholder, false);
      if n > 0 then v_hit := v_hit || (n || ' booking' || case when n = 1 then '' else 's' end || ' closed'); end if;
      begin
        x := app.sales_month_progress(r.user_id, (date_trunc('month', (z - interval '1 second') at time zone 'America/Toronto'))::date);
        if x ->> 'scheme' = 'sales_tier' and (x ->> 'days')::int >= (x ->> 'mid_days')::int and (x ->> 'mid_days')::int > 0 then
          v_hit := v_hit || ('Sales tier reached: ' || (x ->> 'days') || ' rental days this month');
        end if;
      exception when others then null;
      end;
    end if;
    if r.functions && array['cs', 'fleet', 'finance'] then
      begin
        select count(*), count(*) filter (where not coalesce((s ->> 'late')::boolean, false) and not coalesce((s ->> 'absent')::boolean, false)) into n, n2
          from generate_series(p_week, least(p_week + 6, app.today()), interval '1 day') d, lateral (select app.staff_day_status(r.user_id, d::date) s) q
         where coalesce((s ->> 'scheduled')::boolean, false);
        if n > 0 then
          v_tracked := v_tracked + 1;
          if n2 = n then v_hit := v_hit || ('On time for every shift (' || n || ')'); end if;
        end if;
      exception when others then null;
      end;
    end if;
    if 'field' = any (r.functions) then
      select count(*) into n from field_shifts f where f.staff_id = r.user_id and f.voided_at is null and f.started_at >= a and f.started_at < z;
      if n > 0 then v_hit := v_hit || (n || ' shift' || case when n = 1 then '' else 's' end || ' worked'); end if;
    end if;
    select count(distinct t.section_id) into n from academy_attempts t where t.user_id = r.user_id and t.passed and t.created_at >= a and t.created_at < z;
    if n > 0 then v_hit := v_hit || ('Academy: ' || n || ' section' || case when n = 1 then '' else 's' end || ' passed'); end if;
    out := out || jsonb_build_array(jsonb_build_object('user_id', r.user_id, 'name', r.name, 'hit', to_jsonb(v_hit), 'tracked', v_tracked));
  end loop;
  return out;
end $$;

create function app.townhall_fleet_names(p_week date) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  with w as (select p_week::timestamp at time zone 'America/Toronto' a, (p_week + 7)::timestamp at time zone 'America/Toronto' z)
  select jsonb_build_array(
    'Added this week: ' || coalesce((select string_agg(app.vehicle_name(v.id), ', ' order by v.created_at) from vehicles v where not coalesce(v.is_sample, false) and v.created_at >= w.a and v.created_at < w.z), 'none'),
    'Removed this week: ' || coalesce((select string_agg(app.vehicle_name(v.id), ', ' order by v.retired_at) from vehicles v where not coalesce(v.is_sample, false) and v.retired_at >= w.a and v.retired_at < w.z), 'none'))
    from w
$$;

-- ================================================================ the deck
create function app.townhall_slides_4600(p_week date) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_old jsonb := app.townhall_slides_pre4600(p_week);
  v_bd jsonb := app.townhall_birthday_lines(p_week);
  v_kpis jsonb := app.townhall_staff_kpis(p_week);
  v_min jsonb := jsonb_build_object('opener', 1, 'hires', 1, 'story', 2, 'funnel', 2, 'social', 2, 'fleet', 2, 'investors', 2, 'owners', 1, 'topcars', 2,
                                    'insurer', 1, 'leaderboard', 2, 'dev', 1, 'people', case when jsonb_array_length(v_bd) > 0 then 3 else 4 end);
  v_add jsonb := jsonb_build_object(
    'hires', case when jsonb_array_length(v_bd) > 0 then jsonb_build_array(jsonb_build_object('key', 'birthdays', 'title', 'Birthdays', 'admin_only', false, 'minutes', 1,
                'points', jsonb_build_array(app.th_point('Birthdays', jsonb_array_length(v_bd)::text)), 'lines', v_bd)) else '[]'::jsonb end,
    'funnel', jsonb_build_array(app.townhall_visitor_slide(p_week)),
    'insurer', jsonb_build_array(app.townhall_incident_slide(p_week)) || app.townhall_dispute_slides(p_week),
    'leaderboard', jsonb_build_array(jsonb_build_object('key', 'kpis', 'title', 'KPIs hit this week', 'admin_only', false, 'minutes', 3,
      'points', jsonb_build_array(app.th_point('Staff', jsonb_array_length(v_kpis)::text),
                                  app.th_point('Hit at least one', (select count(*) from jsonb_array_elements(v_kpis) x where jsonb_array_length(x -> 'hit') > 0)::text)),
      'lines', (select coalesce(jsonb_agg((x ->> 'name') || ': ' || case when jsonb_array_length(x -> 'hit') > 0 then (select string_agg(h, ', ') from jsonb_array_elements_text(x -> 'hit') h)
                                                                         else 'no KPI hit yet this week' end order by o), '[]'::jsonb) from jsonb_array_elements(v_kpis) with ordinality t(x, o)),
      'staff', (select coalesce(jsonb_agg(jsonb_build_object('user_id', x -> 'user_id', 'name', x -> 'name', 'hits', jsonb_array_length(x -> 'hit'))), '[]'::jsonb) from jsonb_array_elements(v_kpis) x))));
  v_out jsonb := '[]'::jsonb;
  v_done text[] := '{}';
  s jsonb;
  k text;
begin
  for s in select x from jsonb_array_elements(v_old) with ordinality t(x, o) order by o loop
    k := s ->> 'key';
    if v_min ? k then s := s || jsonb_build_object('minutes', (v_min ->> k)::int); end if;
    if k = 'fleet' then s := s || jsonb_build_object('lines', coalesce(s -> 'lines', '[]'::jsonb) || app.townhall_fleet_names(p_week)); end if;
    v_out := v_out || jsonb_build_array(s);
    if v_add ? k then v_out := v_out || (v_add -> k); v_done := v_done || k; end if;
  end loop;
  for k in select x from jsonb_object_keys(v_add) x loop
    if not k = any (v_done) then v_out := v_out || (v_add -> k); end if;
  end loop;
  return v_out;
end $$;

alter function app.townhall_slides(date) rename to townhall_slides_pre4600;
create function app.townhall_slides(p_week date) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$ select app.townhall_slides_4600(p_week) $$;
select pg_temp.copy_grants('app.townhall_slides(date)'::regprocedure, 'app.townhall_slides_pre4600(date)'::regprocedure);

-- ================================================================ the connector's status: the KPI slide counts as featured
select pg_temp.patch_fn('app.townhall_status(uuid, jsonb)'::regprocedure,
  $o$v_people := coalesce(v_people, '[]'::jsonb);$o$,
  $n$v_people := coalesce(v_people, '[]'::jsonb) || coalesce((select s3 -> 'staff' from jsonb_array_elements(d.slides) s3 where s3 ->> 'key' = 'kpis'), '[]'::jsonb);$n$);
select pg_temp.patch_fn('app.townhall_status(uuid, jsonb)'::regprocedure,
  $o$'staff_featured', v_featured, 'staff_missing', v_missing,$o$,
  $n$'staff_featured', v_featured, 'staff_missing', v_missing,
    'staff_missing_kpis', case when d.id is null then null else (select coalesce(jsonb_agg(coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email) order by coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email)), '[]'::jsonb)
        from staff_profiles sp join users u on u.id = sp.user_id
       where app.staff_is_member(sp.user_id) and not exists (select 1 from jsonb_array_elements(d.slides) s3, jsonb_array_elements(coalesce(s3 -> 'staff', '[]'::jsonb)) x
                                                              where s3 ->> 'key' = 'kpis' and x ->> 'user_id' = sp.user_id::text)) end,
    'incident', case when d.id is null then null else (select jsonb_build_object('line', s3 #>> '{lines,0}', 'picked', s3 ->> 'picked') from jsonb_array_elements(d.slides) s3 where s3 ->> 'key' = 'incident') end,$n$);

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre4600;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if (p_call in ('ops_do', 'admin_do') and p_name in ('townhall_incident_pick', 'staff_birthday_save'))
     or (p_call in ('ops_read', 'admin_read', 'field_read') and p_name = 'staff_birthday') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'townhall_incident_pick' then app.townhall_incident_pick(p_user, p_)
                       when 'staff_birthday_save' then app.staff_birthday_save(p_user, p_)
                       else app.staff_birthday_read(p_user, p_) end;
  end if;
  return app.door_pre4600(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre4600(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['staff_birthday_save', 'staff_birthday_read', 'birthday_on', 'townhall_incident_candidates', 'townhall_incident_pick',
                    'townhall_visitors_avg', 'th_change', 'townhall_visitor_slide', 'townhall_incident_slide', 'townhall_dispute_slides', 'townhall_birthday_lines',
                    'townhall_staff_kpis', 'townhall_fleet_names', 'townhall_slides_4600', 'townhall_slides_pre4600', 'townhall_slides', 'door_pre4600']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
