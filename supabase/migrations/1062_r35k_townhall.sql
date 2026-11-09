-- 1062_r35k_townhall.sql
-- Release 35, part K (item 30, the owner at 21:39): the weekly townhall. A web slide deck built every Sunday night from the
-- live data of the week that ended (Monday to Sunday, Toronto): the week's performance, development updates (the web
-- layer adds the releases of docs/releases shipped that week), fleet, staff, sales, finances and claims. Admin > Townhall
-- shows it with editable notes per slide and Build again; every staff portal shows it (the finance and claims slides only
-- to Admin unless townhall_finance_to_staff). Program settings: the day and time (Monday 11:30 Toronto, when every
-- assistant's shift overlaps), the length, the recurring video call link (empty until the owner sets it). The calendar
-- invite is an .ics the staff add once (it repeats weekly); an alert an hour before. Internal only: never in the owner or
-- investor portals.
set local check_function_bodies = off;

alter table program_settings
  add column if not exists townhall_weekday integer not null default 1 check (townhall_weekday between 1 and 7),
  add column if not exists townhall_time text not null default '11:30' check (townhall_time ~ '^([01]?[0-9]|2[0-3]):[0-5][0-9]$'),
  add column if not exists townhall_minutes integer not null default 45 check (townhall_minutes between 15 and 180),
  add column if not exists townhall_call_url text not null default '' check (townhall_call_url = '' or townhall_call_url ~ '^https://[^\s]+$'),
  add column if not exists townhall_finance_to_staff boolean not null default false;
comment on column program_settings.townhall_call_url is 'The weekly townhall''s recurring video call link (1062); empty until set.';
comment on column program_settings.townhall_finance_to_staff is 'Townhall (1062): staff see the finances and claims slides too (off: Admin only).';

create table if not exists townhall_decks (
  id          uuid primary key default gen_random_uuid(),
  week_of     date not null unique check (extract(isodow from week_of) = 1),
  built_at    timestamptz not null default now(),
  built_by    uuid references users (id),
  slides      jsonb not null default '[]'::jsonb check (jsonb_typeof(slides) = 'array'),
  notes       jsonb not null default '{}'::jsonb check (jsonb_typeof(notes) = 'object'),
  reminded_at timestamptz
);
comment on table townhall_decks is 'The weekly townhall deck (1062): week_of is the Monday of the week it reports on; slides [{key, title, admin_only, points[{label, value}], lines[]}]; notes {slide key: text}.';
alter table townhall_decks enable row level security;
revoke all on townhall_decks from anon, authenticated;
grant all on townhall_decks to service_role;
drop trigger if exists audit_townhall_decks on townhall_decks;
create trigger audit_townhall_decks after insert or update or delete on townhall_decks for each row execute function app.audit_row();

create function app.th_point(p_label text, p_value text) returns jsonb language sql immutable as $$ select jsonb_build_object('label', p_label, 'value', p_value) $$;

-- the slides of the week starting p_week (a Monday)
create function app.townhall_slides(p_week date) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  a timestamptz := p_week::timestamp at time zone 'America/Toronto';
  z timestamptz := (p_week + 7)::timestamp at time zone 'America/Toronto';
  n_req integer; n_off integer; n_book integer; n_ret integer; n_cars integer; n_added integer; n_out integer; n_maint integer;
  v_days numeric; v_util numeric; n_hires integer; n_held integer; n_shifts integer; v_minutes bigint; v_rev bigint; v_ref bigint; v_dep bigint;
  n_inv integer; v_inv bigint; n_claims_open integer; n_claims_new integer; n_claims_settled integer;
  v_board jsonb;
begin
  select count(*) into n_req from bookings where created_at >= a and created_at < z and not coalesce(is_placeholder, false);
  select count(*) into n_off from booking_events e where e.created_at >= a and e.created_at < z and e.kind in ('offer_sent', 'offer_updated');
  select count(*) into n_book from bookings where booked_at >= a and booked_at < z and status not in ('requested', 'offered', 'declined', 'expired') and not coalesce(is_placeholder, false);
  select count(*) into n_ret from bookings where checked_in_at >= a and checked_in_at < z;
  select count(*) into n_cars from vehicles where retired_at is null and status not in ('exited', 'total_loss', 'declined') and not coalesce(is_sample, false);
  select count(*) into n_added from vehicles where created_at >= a and created_at < z and coalesce(is_sample, false) = false;
  select count(*) into n_out from bookings where status = 'on_rent';
  select count(*) into n_maint from tasks where task_type like 'maint%' and status in ('open', 'in_progress', 'waiting');
  select coalesce(sum(extract(epoch from (least(coalesce(b.checked_in_at, b.return_at), z) - greatest(coalesce(b.handed_over_at, b.pickup_at), a))) / 86400.0), 0) into v_days
    from bookings b where b.status in ('on_rent', 'returned', 'closed') and coalesce(b.handed_over_at, b.pickup_at) < z and coalesce(b.checked_in_at, b.return_at) > a;
  v_util := case when n_cars > 0 then round(100 * v_days / (n_cars * 7.0)) end;
  select count(*) into n_hires from staff_onboarding where created_at >= a and created_at < z;
  select count(*) into n_held from staff_profiles sp where sp.is_active and app.academy_locked(sp.user_id);
  select count(*) into n_shifts from field_shift_slots s where s.starts_at >= a and s.starts_at < z and s.cancelled_at is null;
  select coalesce((select sum(app.va_clock_minutes(e, z)) from staff_clock_entries e where e.voided_at is null and e.started_at >= a and e.started_at < z), 0)
       + coalesce((select sum(extract(epoch from (coalesce(f.ended_at, f.started_at) - f.started_at)) / 60)::bigint from field_shifts f where f.started_at >= a and f.started_at < z and f.voided_at is null), 0)
    into v_minutes;
  select coalesce(sum(amount_cents), 0) into v_rev from payments where kind = 'charge' and status = 'succeeded' and purpose <> 'deposit' and created_at >= a and created_at < z;
  select coalesce(sum(amount_cents), 0) into v_ref from refunds where status = 'paid' and coalesce(paid_at, created_at) >= a and coalesce(paid_at, created_at) < z;
  select coalesce(sum(amount_cents), 0) into v_dep from deposits where taken_at >= a and taken_at < z;
  select count(*), coalesce(sum(total_cents), 0) into n_inv, v_inv from owner_invoices where billing_date >= p_week and billing_date < p_week + 7 and status <> 'draft';
  select count(*) into n_claims_open from claims where status not in ('closed', 'withdrawn', 'distributed');
  select count(*) into n_claims_new from claims where created_at >= a and created_at < z;
  select count(*) into n_claims_settled from claims where settled_at >= a and settled_at < z;
  select coalesce(jsonb_agg(app.th_point(x.name, x.n || ' booking' || case when x.n = 1 then '' else 's' end) order by x.n desc, x.name), '[]'::jsonb) into v_board
    from (select coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, 'Staff') name, count(*) n from bookings b join users u on u.id = b.sales_staff_id
           where b.booked_at >= a and b.booked_at < z group by 1 order by 2 desc limit 5) x;
  return jsonb_build_array(
    jsonb_build_object('key', 'week', 'title', 'The week', 'admin_only', false, 'points', jsonb_build_array(
      app.th_point('Bookings made', n_book::text), app.th_point('Returns', n_ret::text), app.th_point('Cars out now', n_out::text),
      app.th_point('Requests', n_req::text))),
    jsonb_build_object('key', 'dev', 'title', 'Platform updates', 'admin_only', false, 'points', '[]'::jsonb),
    jsonb_build_object('key', 'fleet', 'title', 'Fleet', 'admin_only', false, 'points', jsonb_build_array(
      app.th_point('Cars in the fleet', n_cars::text), app.th_point('Cars added', n_added::text), app.th_point('Out now', n_out::text),
      app.th_point('Utilization', coalesce(v_util::text || '%', 'No cars')), app.th_point('Maintenance open', n_maint::text))),
    jsonb_build_object('key', 'staff', 'title', 'Staff', 'admin_only', false, 'points', jsonb_build_array(
      app.th_point('Hired', n_hires::text), app.th_point('In the academy', n_held::text), app.th_point('Field shifts', n_shifts::text),
      app.th_point('Hours worked', round(v_minutes / 60.0, 1)::text))),
    jsonb_build_object('key', 'sales', 'title', 'Sales', 'admin_only', false, 'points', jsonb_build_array(
      app.th_point('Requests', n_req::text), app.th_point('Offers sent', n_off::text), app.th_point('Bookings', n_book::text),
      app.th_point('Close rate', case when n_req > 0 then round(100.0 * n_book / n_req) || '%' else 'No requests' end)), 'board', v_board),
    jsonb_build_object('key', 'finance', 'title', 'Finances', 'admin_only', true, 'points', jsonb_build_array(
      app.th_point('Revenue collected', app.fmt_money(v_rev)), app.th_point('Owner invoices', n_inv || ', ' || app.fmt_money(v_inv)),
      app.th_point('Deposits taken', app.fmt_money(v_dep)), app.th_point('Refunds paid', app.fmt_money(v_ref)))),
    jsonb_build_object('key', 'claims', 'title', 'Claims', 'admin_only', true, 'points', jsonb_build_array(
      app.th_point('Open', n_claims_open::text), app.th_point('New', n_claims_new::text), app.th_point('Settled', n_claims_settled::text))));
end $$;

-- build (or build again) the deck of a week; the notes typed so far stay
create function app.townhall_build(p_week date default null, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_week date := coalesce(p_week, (date_trunc('week', app.today()::timestamp) - interval '7 days')::date);
  v_id uuid;
begin
  v_week := (date_trunc('week', v_week::timestamp))::date;
  insert into townhall_decks (week_of, slides, built_by) values (v_week, app.townhall_slides(v_week), p_by)
  on conflict (week_of) do update set slides = excluded.slides, built_at = now(), built_by = excluded.built_by
  returning id into v_id;
  return v_id;
end $$;

-- the next meeting (Toronto)
create function app.townhall_next(p_now timestamptz default now()) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select min(t) from (select ((app.local_date(p_now) + d) + s.townhall_time::time) at time zone 'America/Toronto' t
                        from program_settings s, generate_series(0, 7) d
                       where extract(isodow from app.local_date(p_now) + d)::int = s.townhall_weekday) x
   where t > p_now - make_interval(mins => (app.settings()).townhall_minutes)
$$;

create function app.townhall_view(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_admin boolean := app.user_is_admin(p_by);
  d townhall_decks;
  s program_settings := app.settings();
  v_all boolean;
begin
  if not (v_admin or app.user_is_staff(p_by) or app.user_is_field(p_by)) then raise exception 'Staff only' using errcode = '42501'; end if;
  v_all := v_admin or s.townhall_finance_to_staff;
  select * into d from townhall_decks where (nullif(p ->> 'week_of', '') is null or week_of = (p ->> 'week_of')::date) order by week_of desc limit 1;
  return jsonb_build_object('admin', v_admin, 'next_at', app.townhall_next(now()), 'minutes', s.townhall_minutes, 'call_url', nullif(s.townhall_call_url, ''),
    'weekday', s.townhall_weekday, 'time', s.townhall_time, 'finance_to_staff', s.townhall_finance_to_staff,
    'weeks', coalesce((select jsonb_agg(w.week_of order by w.week_of desc) from (select week_of from townhall_decks order by week_of desc limit 12) w), '[]'::jsonb),
    'deck', case when d.id is null then null else jsonb_build_object('id', d.id, 'week_of', d.week_of, 'built_at', d.built_at,
      'slides', coalesce((select jsonb_agg(x || jsonb_build_object('note', d.notes ->> (x ->> 'key'))) from jsonb_array_elements(d.slides) x
                           where v_all or not coalesce((x ->> 'admin_only')::boolean, false)), '[]'::jsonb)) end);
end $$;

create function app.townhall_do(p_by uuid, p_action text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid;
begin
  perform app.assert_admin(p_by);
  if p_action = 'townhall_build' then
    v_id := app.townhall_build(nullif(p ->> 'week_of', '')::date, p_by);
  else
    if coalesce(p ->> 'key', '') !~ '^[a-z]{2,20}$' then raise exception 'Choose the slide' using errcode = '22023'; end if;
    update townhall_decks set notes = case when nullif(btrim(coalesce(p ->> 'note', '')), '') is null then notes - (p ->> 'key')
                                          else notes || jsonb_build_object(p ->> 'key', left(btrim(p ->> 'note'), 2000)) end
     where id = nullif(p ->> 'deck', '')::uuid returning id into v_id;
    if v_id is null then raise exception 'Deck not found' using errcode = 'P0002'; end if;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

-- every 15 minutes: Sunday from 9 pm Toronto, the deck of the week that ends; an hour before the call, the alert
create function app.job_townhall(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_local timestamp := p_now at time zone 'America/Toronto';
  v_week date := (date_trunc('week', v_local))::date;
  v_next timestamptz := app.townhall_next(p_now);
  v_built boolean := false;
  v_alert boolean := false;
  d townhall_decks;
begin
  if extract(isodow from v_local) = 7 and extract(hour from v_local) >= 21 and not exists (select 1 from townhall_decks where week_of = v_week) then
    perform app.townhall_build(v_week, null);
    v_built := true;
  end if;
  if v_next is not null and v_next > p_now and v_next <= p_now + interval '60 minutes' then
    select * into d from townhall_decks order by week_of desc limit 1;
    if d.id is not null and (d.reminded_at is null or d.reminded_at < v_next - interval '2 hours') then
      perform app.staff_alert('townhall_soon', 'townhall_deck', d.id, 'soon:' || to_char(v_next, 'YYYYMMDD'), 'The weekly townhall starts in an hour',
        'At ' || to_char(v_next at time zone 'America/Toronto', 'FMHH12:MI am') || ' Toronto time. The deck is ready.',
        jsonb_build_object('path_admin', '/admin/townhall', 'path_staff', '/staff/townhall'));
      update townhall_decks set reminded_at = p_now where id = d.id;
      v_alert := true;
    end if;
  end if;
  return format('built %s, alert %s', v_built, v_alert);
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-townhall', '*/15 * * * *', 'select app.job_townhall()');
  end if;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1062;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call = 'ops_read' and p_name = 'townhall') or (p_call = 'admin_do' and p_name in ('townhall_build', 'townhall_note')) then
    perform app.door_begin(p_user, p_aal);
    if p_call = 'ops_read' then return app.townhall_view(p_user, coalesce(p, '{}'::jsonb) - '_va'); end if;
    return app.townhall_do(p_user, p_name, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre1062(p_user, p_aal, p_call, p_name, p);
end $$;
revoke all on function app.door(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.door(uuid, text, text, text, jsonb) to service_role;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['th_point', 'townhall_slides', 'townhall_build', 'townhall_next', 'townhall_view', 'townhall_do', 'job_townhall', 'door_pre1062'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
