-- 5150 (r50 hotfix 2, UX: docs/changes/2026-11-27-r50h2-ux.md): the weekly Admin call for the two principals. SCHEMA_MARKER 5150.
-- No applied migration is edited.
--   1. Program settings: the day, the time (Toronto) and the length of the Admin call (Sunday 19:00, 60 minutes by
--      default), edited in Settings > Program settings and on the Admin call page.
--   2. admin_call_decks: one deck a week (the week of the call), built from the live data by the townhall's engine pattern:
--      slides of points, lines and decision items. The job builds it in the day before the call and again in the three
--      hours before (fresh numbers); an Admin builds it again any time. admin_call_decisions: Approve or Deny on an item, once.
--      A decision does what the item's own screens do, never money: a shift claim denied is taken off the shift
--      (app.field_shift_plan_cancel); a To do or a prepared money action denied is closed with the reason (app.complete_task);
--      approved, it stays open, marked approved and urgent; a deposit or a payout decision becomes a Finance To do (the money
--      itself still moves only through the deposit review and the payout screens, with their own checks).
--   3. The call in the site: room admin_call (Admins only), in the 5010 rooms.
--   4. The weekly calendar invite by email (.ics, METHOD:REQUEST, weekly RRULE, Toronto time) to every active Admin, sent
--      again as an update when the day, the time or the length changes; an Admin who leaves gets METHOD:CANCEL. The
--      townhall job runs the sweep every 15 minutes; a settings change runs it at once.
--   5. An alert to the Admins an hour before (staff alert rule admin_call_soon).
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
  if position(p_old in d) = 0 then raise exception '5150: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists admin_call_weekday integer not null default 7 check (admin_call_weekday between 1 and 7),
  add column if not exists admin_call_time text not null default '19:00' check (admin_call_time ~ '^([01]?[0-9]|2[0-3]):[0-5][0-9]$'),
  add column if not exists admin_call_minutes integer not null default 60 check (admin_call_minutes between 15 and 240);
comment on column program_settings.admin_call_weekday is 'Admin call (5150): the day of the weekly Admin call, ISO (1 Monday to 7 Sunday; Sunday by default).';
comment on column program_settings.admin_call_time is 'Admin call (5150): the start of the weekly Admin call, Toronto time HH:MM (19:00 by default).';
comment on column program_settings.admin_call_minutes is 'Admin call (5150): the length of the weekly Admin call in minutes (60 by default).';

-- ================================================================ 2. the deck and its decisions
create table if not exists admin_call_decks (
  id          uuid primary key default gen_random_uuid(),
  week_of     date not null unique check (extract(isodow from week_of) = 1),
  call_at     timestamptz not null,
  built_at    timestamptz not null default now(),
  built_by    uuid references users (id),
  slides      jsonb not null default '[]'::jsonb check (jsonb_typeof(slides) = 'array'),
  notes       jsonb not null default '{}'::jsonb check (jsonb_typeof(notes) = 'object'),
  reminded_at timestamptz
);
comment on table admin_call_decks is 'The weekly Admin call deck (5150): week_of is the Monday of the call''s week (Toronto); slides [{key, title, points[{label, value}], lines[], items[{key, kind, label, detail, href, approve, deny}]}]; notes {slide key: text}.';
create table if not exists admin_call_decisions (
  id          uuid primary key default gen_random_uuid(),
  deck_id     uuid not null references admin_call_decks (id) on delete cascade,
  item_key    text not null check (item_key ~ '^(shift|todo|money|deposit|payout):[0-9a-f-]{36}$'),
  decision    text not null check (decision in ('approve', 'deny')),
  note        text check (note is null or length(note) <= 500),
  decided_by  uuid not null references users (id),
  decided_at  timestamptz not null default now(),
  unique (deck_id, item_key)
);
comment on table admin_call_decisions is 'Approve or Deny on an item of the Admin call deck (5150), once per item: who, when, the note.';
do $$
declare t text;
begin
  foreach t in array array['admin_call_decks', 'admin_call_decisions'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from public, anon, authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('drop trigger if exists %I on %I', 'audit_' || t, t);
    execute format('create trigger %I after insert or update or delete on %I for each row execute function app.audit_row()', 'audit_' || t, t);
  end loop;
end $$;

-- the invites and the call rooms know the Admin call
alter table calendar_invites drop constraint if exists calendar_invites_kind_check;
alter table calendar_invites add constraint calendar_invites_kind_check check (kind in ('townhall', 'interview', 'admin_call'));
alter table calendar_invites drop constraint if exists calendar_invites_check1;
alter table calendar_invites add constraint calendar_invites_check1 check (((kind in ('townhall', 'admin_call')) and user_id is not null) or (kind = 'interview' and application_id is not null));
alter table call_rooms drop constraint if exists call_rooms_kind_check;
alter table call_rooms add constraint call_rooms_kind_check check (kind in ('townhall', 'interview', 'staff', 'admin_call'));

insert into staff_alert_rules (rule, label, grp, who, tier, topic, enabled, wired, fixed, hint, sort, pref_type)
values ('admin_call_soon', 'The weekly Admin call starts in an hour', 'Staff', '{admin}', 'normal', 'alerts', true, true, false, 'The Admins, an hour before the weekly Admin call (5150).', 165, 'staff_onboarding')
on conflict (rule) do nothing;

-- ================================================================ 3. when
create or replace function app.admin_call_next(p_now timestamptz default now()) returns timestamptz
language sql stable security definer set search_path = public, app, pg_temp as $$
  select min(t) from (select ((app.local_date(p_now) + d) + s.admin_call_time::time) at time zone 'America/Toronto' t
                        from app.settings() s, generate_series(0, 7) d
                       where extract(isodow from app.local_date(p_now) + d)::int = s.admin_call_weekday) x
   where t > p_now - make_interval(mins => (app.settings()).admin_call_minutes)
$$;

create or replace function app.admin_call_week(p_at timestamptz) returns date
language sql immutable set search_path = public, app, pg_temp as $$ select (date_trunc('week', p_at at time zone 'America/Toronto'))::date $$;

-- ================================================================ 4. the slides
create or replace function app.ac_point(p_label text, p_value text) returns jsonb
language sql immutable set search_path = public, app, pg_temp as $$ select jsonb_build_object('label', p_label, 'value', coalesce(p_value, '0')) $$;
create or replace function app.ac_name(p_user uuid) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(nullif(btrim(u.greeting_name), ''), nullif(btrim(u.full_name), ''), u.email, 'Someone') from users u where u.id = p_user
$$;
create or replace function app.ac_when(p timestamptz) returns text
language sql immutable set search_path = public, app, pg_temp as $$ select to_char(p at time zone 'America/Toronto', 'Dy Mon FMDD, FMHH12:MI am') $$;

-- p_at: the call. Past: the 7 days before it; coming: the 7 days after it. Test records are left out.
create or replace function app.admin_call_slides(p_at timestamptz) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  a timestamptz := p_at - interval '7 days';
  z timestamptz := p_at + interval '7 days';
  v_slides jsonb := '[]'::jsonb;
  v_cars integer;
  v_days numeric;
  v_visits bigint;
  v_bookings bigint;
begin
  -- 1. shifts needed next week and the claims
  v_slides := v_slides || jsonb_build_array(jsonb_build_object('key', 'shifts', 'title', 'Shifts for the coming week',
    'points', jsonb_build_array(
      app.ac_point('Shifts published', (select count(*)::text from field_shift_slots s where s.cancelled_at is null and s.starts_at >= p_at and s.starts_at < z)),
      app.ac_point('Spots still open', (select coalesce(sum(greatest(s.capacity - (select count(*) from field_shift_plans p where p.slot_id = s.id and p.cancelled_at is null), 0)), 0)::text
                                          from field_shift_slots s where s.cancelled_at is null and s.starts_at >= p_at and s.starts_at < z)),
      app.ac_point('Claims', (select count(*)::text from field_shift_plans p where p.cancelled_at is null and p.starts_at >= p_at and p.starts_at < z and not app.staff_is_test(p.staff_id)))),
    'lines', coalesce((select jsonb_agg(app.ac_when(s.starts_at) || ' to ' || to_char(s.ends_at at time zone 'America/Toronto', 'FMHH12:MI am') || ': '
                                        || (s.capacity - n) || ' of ' || s.capacity || ' open' order by s.starts_at)
                         from (select s.*, (select count(*) from field_shift_plans p where p.slot_id = s.id and p.cancelled_at is null) n
                                 from field_shift_slots s where s.cancelled_at is null and s.starts_at >= p_at and s.starts_at < z) s where s.capacity > s.n), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('key', 'shift:' || p.id, 'kind', 'shift', 'label', app.ac_name(p.staff_id),
                                        'detail', app.ac_when(p.starts_at) || ' to ' || to_char(p.ends_at at time zone 'America/Toronto', 'FMHH12:MI am'),
                                        'href', '/admin/field-jobs', 'approve', 'Approve', 'deny', 'Take off the shift') order by p.starts_at)
                         from field_shift_plans p where p.cancelled_at is null and p.starts_at >= p_at and p.starts_at < z and not app.staff_is_test(p.staff_id)), '[]'::jsonb)));

  -- 2. staff hours and pay owed
  v_slides := v_slides || jsonb_build_array(jsonb_build_object('key', 'hours', 'title', 'Staff hours and pay owed',
    'points', jsonb_build_array(
      app.ac_point('Hours worked (7 days)', (select to_char(coalesce(sum(h), 0), 'FM999990.0') from (
          select extract(epoch from (least(coalesce(e.ended_at, now()), p_at) - greatest(e.started_at, a))) / 3600 h from staff_clock_entries e
           where e.voided_at is null and e.started_at < p_at and coalesce(e.ended_at, now()) > a and not app.staff_is_test(e.user_id)
          union all
          select extract(epoch from (least(coalesce(f.ended_at, now()), p_at) - greatest(f.started_at, a))) / 3600 from field_shifts f
           where f.voided_at is null and f.started_at < p_at and coalesce(f.ended_at, now()) > a and not app.staff_is_test(f.staff_id)) x where h > 0)),
      app.ac_point('Staff payouts owed', app.fmt_money(coalesce((select sum(p.amount_cents + p.hst_cents) from payouts p where p.payee_type = 'field_staff' and p.status in ('draft', 'pending_approval', 'approved', 'sent')), 0)))),
    'lines', coalesce((select jsonb_agg(app.ac_name(uid) || ': ' || to_char(h, 'FM999990.0') || ' h'
                                        || case when rate > 0 then ', about ' || app.fmt_money(round(h * rate)) || ' at ' || app.fmt_money(rate) || ' an hour' else '' end
                                        || case when owed > 0 then '. Payouts owed: ' || app.fmt_money(owed) else '' end order by h desc)
                         from (select x.uid, sum(x.h) h, coalesce(max(sp.hourly_rate_cents), 0) rate,
                                      coalesce((select sum(p.amount_cents + p.hst_cents) from payouts p where p.staff_user_id = x.uid and p.status in ('draft', 'pending_approval', 'approved', 'sent')), 0) owed
                                 from (select e.user_id uid, extract(epoch from (least(coalesce(e.ended_at, now()), p_at) - greatest(e.started_at, a))) / 3600 h from staff_clock_entries e
                                        where e.voided_at is null and e.started_at < p_at and coalesce(e.ended_at, now()) > a
                                       union all
                                       select f.staff_id, extract(epoch from (least(coalesce(f.ended_at, now()), p_at) - greatest(f.started_at, a))) / 3600 from field_shifts f
                                        where f.voided_at is null and f.started_at < p_at and coalesce(f.ended_at, now()) > a) x
                                 left join staff_profiles sp on sp.user_id = x.uid
                                where x.h > 0 and not app.staff_is_test(x.uid) group by x.uid) y), '[]'::jsonb)));

  -- 3. academy progress per person
  v_slides := v_slides || jsonb_build_array(jsonb_build_object('key', 'academy', 'title', 'Academy progress',
    'points', jsonb_build_array(app.ac_point('People learning', (select count(distinct e.user_id)::text from academy_enrollments e where app.staff_is_member(e.user_id) and not app.staff_is_test(e.user_id)))),
    'lines', coalesce((select jsonb_agg(app.ac_name(uid) || ': ' || done || ' of ' || total || ' sections (' || round(100.0 * done / greatest(total, 1)) || '%)' order by done::numeric / greatest(total, 1), uid)
                         from (select e.user_id uid, count(distinct ps.section_id) total,
                                      count(distinct ps.section_id) filter (where exists (select 1 from academy_attempts t where t.user_id = e.user_id and t.section_id = ps.section_id and t.passed)) done
                                 from academy_enrollments e join academy_path_sections ps on ps.path_code = e.path_code
                                where app.staff_is_member(e.user_id) and not app.staff_is_test(e.user_id) group by e.user_id) y), '[]'::jsonb)));

  -- 4. hiring pipeline and interview no-shows
  v_slides := v_slides || jsonb_build_array(jsonb_build_object('key', 'hiring', 'title', 'Hiring',
    'points', jsonb_build_array(
      app.ac_point('New this week', (select count(*)::text from job_applications j where j.created_at >= a and j.created_at < p_at and j.purged_at is null)),
      app.ac_point('Interviews booked', (select count(*)::text from job_applications j where j.status = 'booked' and j.purged_at is null)),
      app.ac_point('Waiting for a decision', (select count(*)::text from job_applications j where j.status = 'interviewed' and j.purged_at is null)),
      app.ac_point('Hired this week', (select count(*)::text from job_applications j where j.status = 'hired' and j.decided_at >= a and j.decided_at < p_at)),
      app.ac_point('Interview no-shows', (select count(*)::text from job_applications j where j.status = 'no_show' and j.updated_at >= a and j.updated_at < p_at))),
    'lines', coalesce((select jsonb_agg('No-show: ' || split_part(btrim(j.full_name), ' ', 1) || ' (' || coalesce(r.title, 'a role') || ')' order by j.updated_at)
                         from job_applications j left join hiring_roles r on r.id = j.role_id
                        where j.status = 'no_show' and j.updated_at >= a and j.updated_at < p_at), '[]'::jsonb)));

  -- 5. social media: the coming week's calendar and last week's results
  v_slides := v_slides || jsonb_build_array(jsonb_build_object('key', 'social', 'title', 'Social media',
    'points', jsonb_build_array(
      app.ac_point('Posts planned next week', (select count(*)::text from social_drafts d where d.slot_date >= app.local_date(p_at) and d.slot_date < app.local_date(z) and d.status in ('draft', 'approved'))),
      app.ac_point('Still to approve', (select count(*)::text from social_drafts d where d.slot_date >= app.local_date(p_at) and d.slot_date < app.local_date(z) and d.status = 'draft')),
      app.ac_point('Posted last week', (select count(*)::text from social_drafts d where d.slot_date >= app.local_date(a) and d.slot_date < app.local_date(p_at) and d.status = 'posted')),
      app.ac_point('Views last week', (select coalesce(sum(t.views), 0)::text from townhall_social t where t.week_of = app.admin_call_week(a)))),
    'lines', coalesce((select jsonb_agg(t.platform || ': ' || coalesce(t.followers::text, '-') || ' followers, ' || coalesce(t.posts::text, '-') || ' posts, ' || coalesce(t.views::text, '-') || ' views' order by t.platform)
                         from townhall_social t where t.week_of = app.admin_call_week(a)), '[]'::jsonb)));

  -- 6. the numbers
  select count(*) into v_cars from vehicles v where v.status in ('available', 'on_rent', 'cleaning') and not coalesce(v.is_sample, false);
  select coalesce(sum(extract(epoch from (least(b.return_at, p_at) - greatest(b.pickup_at, a))) / 86400), 0) into v_days
    from bookings b where b.status in ('confirmed', 'on_rent', 'returned', 'closed') and b.pickup_at < p_at and b.return_at > a and not coalesce(b.is_test, false);
  select coalesce(sum(d.visitors), 0) into v_visits from visitor_daily d where d.day >= app.local_date(a) and d.day < app.local_date(p_at);
  select count(*) into v_bookings from bookings b where b.confirmed_at >= a and b.confirmed_at < p_at and not coalesce(b.is_test, false);
  v_slides := v_slides || jsonb_build_array(jsonb_build_object('key', 'numbers', 'title', 'The numbers (last 7 days)',
    'points', jsonb_build_array(
      app.ac_point('Bookings', v_bookings::text),
      app.ac_point('Revenue booked', app.fmt_money(coalesce((select sum(b.total_due_at_booking_cents) from bookings b where b.confirmed_at >= a and b.confirmed_at < p_at and not coalesce(b.is_test, false)), 0))),
      app.ac_point('Occupancy', case when v_cars > 0 then round(100 * v_days / (v_cars * 7))::text || '%' else '-' end),
      app.ac_point('Real visitors', v_visits::text),
      app.ac_point('Conversion', case when v_visits > 0 then to_char(100.0 * v_bookings / v_visits, 'FM990.0') || '%' else '-' end),
      app.ac_point('Leads', (select count(*)::text from leads l where l.created_at >= a and l.created_at < p_at and l.merged_into is null and l.status <> 'spam'))),
    'lines', coalesce((select jsonb_agg(x order by n desc) from (
        select 'Leads from ' || l.src || ': ' || count(*) x, count(*) n
          from (select coalesce(nullif(l.utm_source, ''), nullif(l.source, ''), 'direct') src from leads l
                 where l.created_at >= a and l.created_at < p_at and l.merged_into is null and l.status <> 'spam') l group by l.src
        union all
        select 'Sales by ' || app.ac_name(b.sales_staff_id) || ': ' || count(*) || ' booked, ' || app.fmt_money(sum(b.total_due_at_booking_cents)), count(*) + 100000
          from bookings b where b.sales_staff_id is not null and b.confirmed_at >= a and b.confirmed_at < p_at and not coalesce(b.is_test, false) group by b.sales_staff_id) y), '[]'::jsonb)));

  -- 7. owners: applications, onboarding, statements, payouts due, arrears
  v_slides := v_slides || jsonb_build_array(jsonb_build_object('key', 'owners', 'title', 'Owners',
    'points', jsonb_build_array(
      app.ac_point('New applications', (select count(*)::text from owner_applications o where o.status = 'new')),
      app.ac_point('Waiting on the owner', (select count(*)::text from owner_applications o where o.status = 'waiting_on_owner')),
      app.ac_point('Cars onboarding', (select count(*)::text from vehicles v where v.status in ('onboarding', 'ready_to_list') and not coalesce(v.is_sample, false))),
      app.ac_point('Statements to approve', (select count(*)::text from owner_statements s where s.status = 'draft' and s.voided_at is null)),
      app.ac_point('Payouts due', app.fmt_money(coalesce((select sum(p.amount_cents + p.hst_cents) from payouts p where p.payee_type = 'owner' and p.status in ('draft', 'pending_approval', 'approved')), 0))),
      app.ac_point('Cars in arrears', (select count(*)::text from vehicles v where v.in_arrears))),
    'items', coalesce((select jsonb_agg(jsonb_build_object('key', 'payout:' || p.id, 'kind', 'payout', 'label', coalesce(o.corporation_name, o.legal_name, 'Owner'),
                                        'detail', app.fmt_money(p.amount_cents + p.hst_cents) || coalesce(', due ' || to_char(p.scheduled_for, 'Mon FMDD'), ''),
                                        'href', '/admin/payouts', 'approve', 'Pay it', 'deny', 'Hold it') order by p.scheduled_for nulls last)
                         from payouts p left join owners o on o.id = p.owner_id
                        where p.payee_type = 'owner' and p.status in ('draft', 'pending_approval') and (p.scheduled_for is null or p.scheduled_for < app.local_date(z))), '[]'::jsonb)));

  -- 8. deposits to release or keep (Fleet's check is done, Finance's is not)
  v_slides := v_slides || jsonb_build_array(jsonb_build_object('key', 'deposits', 'title', 'Deposits to release or keep',
    'points', jsonb_build_array(app.ac_point('Waiting for a decision', (select count(*)::text from deposit_reviews r where r.finance_done_at is null and not app.booking_is_test(r.booking_id)))),
    'items', coalesce((select jsonb_agg(jsonb_build_object('key', 'deposit:' || b.id, 'kind', 'deposit', 'label', b.booking_number,
                                        'detail', coalesce(app.fmt_money((select sum(d.amount_cents) from deposits d where d.booking_id = b.id and d.status in ('held', 'captured'))), 'no deposit held')
                                                  || ', returned ' || to_char(r.returned_at at time zone 'America/Toronto', 'Mon FMDD')
                                                  || case when r.fleet_done_at is null then ', Fleet check not done' else '' end,
                                        'href', '/admin/deposit-reviews', 'approve', 'Release', 'deny', 'Keep') order by r.returned_at)
                         from deposit_reviews r join bookings b on b.id = r.booking_id where r.finance_done_at is null and not app.booking_is_test(r.booking_id)), '[]'::jsonb)));

  -- 9. insurance billing and replacement rentals
  v_slides := v_slides || jsonb_build_array(jsonb_build_object('key', 'insurance', 'title', 'Insurance billing and replacement rentals',
    'points', jsonb_build_array(
      app.ac_point('Replacement rentals out', (select count(*)::text from bookings b where b.insurer_id is not null and b.status in ('confirmed', 'on_rent') and not coalesce(b.is_test, false))),
      app.ac_point('Invoices to send', (select count(*)::text from insurer_invoices i where i.status = 'draft')),
      app.ac_point('Owed by insurers', app.fmt_money(coalesce((select sum(i.balance_cents) from insurer_invoices i where i.status in ('sent', 'part_paid')), 0)))),
    'lines', coalesce((select jsonb_agg(coalesce(n.name, 'Insurer') || ' ' || i.invoice_number || ': ' || app.fmt_money(i.balance_cents) || ' open since ' || to_char(i.sent_at at time zone 'America/Toronto', 'Mon FMDD') order by i.sent_at)
                         from insurer_invoices i left join insurers n on n.id = i.insurer_id where i.status in ('sent', 'part_paid') and i.sent_at < now() - interval '30 days'), '[]'::jsonb)));

  -- 10. claims
  v_slides := v_slides || jsonb_build_array(jsonb_build_object('key', 'claims', 'title', 'Claims',
    'points', jsonb_build_array(
      app.ac_point('Open claims', (select count(*)::text from claims c where c.status not in ('closed', 'withdrawn', 'distributed'))),
      app.ac_point('Opened this week', (select count(*)::text from claims c where c.created_at >= a and c.created_at < p_at))),
    'lines', coalesce((select jsonb_agg(c.claim_number || ': ' || replace(c.status, '_', ' ') || coalesce(', ' || app.fmt_money(nullif(c.damage_cost_cents, 0)) || ' damage', '') order by c.created_at)
                         from claims c where c.status not in ('closed', 'withdrawn', 'distributed')), '[]'::jsonb)));

  -- 11. prepared money actions (To dos the connector prepared: never done here)
  v_slides := v_slides || jsonb_build_array(jsonb_build_object('key', 'money', 'title', 'Prepared money actions',
    'points', jsonb_build_array(app.ac_point('Waiting', (select count(*)::text from tasks t where t.task_type = 'api_prepared_money' and t.status in ('open', 'in_progress', 'waiting')))),
    'items', coalesce((select jsonb_agg(jsonb_build_object('key', 'money:' || t.id, 'kind', 'money', 'label', t.title, 'detail', coalesce(t.detail, ''),
                                        'href', coalesce('/admin/bookings/' || b.booking_number, '/admin/tasks'), 'approve', 'Approve', 'deny', 'Decline') order by t.created_at)
                         from tasks t left join bookings b on b.id = t.booking_id where t.task_type = 'api_prepared_money' and t.status in ('open', 'in_progress', 'waiting')), '[]'::jsonb)));

  -- 12. tolls and tickets
  v_slides := v_slides || jsonb_build_array(jsonb_build_object('key', 'tolls', 'title', 'Tolls and tickets',
    'points', jsonb_build_array(
      app.ac_point('To match', (select count(*)::text from toll_tickets t where t.status = 'logged')),
      app.ac_point('Matched, not charged', (select count(*)::text from toll_tickets t where t.status = 'matched')),
      app.ac_point('Due within 14 days', (select count(*)::text from toll_tickets t where t.status in ('logged', 'matched') and t.due_on is not null and t.due_on < app.local_date(p_at) + 14)),
      app.ac_point('Amount open', app.fmt_money(coalesce((select sum(t.amount_cents) from toll_tickets t where t.status in ('logged', 'matched')), 0))))));

  -- 13. the fleet: maintenance, cars with gaps, photos
  v_slides := v_slides || jsonb_build_array(jsonb_build_object('key', 'fleet', 'title', 'Fleet',
    'points', jsonb_build_array(
      app.ac_point('Cars out of service', (select count(*)::text from vehicles v where v.status = 'out_of_service' and not coalesce(v.is_sample, false))),
      app.ac_point('Maintenance To dos', (select count(*)::text from tasks t where t.queue = 'fleet' and t.status in ('open', 'in_progress', 'waiting') and t.task_type ~ '(maint|service|tire|oil|inspection)')),
      app.ac_point('Cars free all next week', (select count(*)::text from vehicles v where v.status = 'available' and not coalesce(v.is_sample, false)
                                                and not exists (select 1 from bookings b where b.vehicle_id = v.id and b.status in ('requested', 'offered', 'pending_payment', 'confirmed', 'on_rent') and b.pickup_at < z and b.return_at > p_at))),
      app.ac_point('Cars missing photos', (select count(*)::text from vehicles v where v.status in ('available', 'ready_to_list', 'onboarding') and not coalesce(v.is_sample, false)
                                            and (select count(*) from vehicle_photos ph where ph.vehicle_id = v.id and ph.replaced_at is null) < 9))),
    'lines', coalesce((select jsonb_agg(concat_ws(' ', v.year::text, v.make, v.model) || coalesce(' (' || v.car_code || ')', '') || ': free all next week' order by v.make, v.model)
                         from vehicles v where v.status = 'available' and not coalesce(v.is_sample, false)
                          and not exists (select 1 from bookings b where b.vehicle_id = v.id and b.status in ('requested', 'offered', 'pending_payment', 'confirmed', 'on_rent') and b.pickup_at < z and b.return_at > p_at)), '[]'::jsonb)));

  -- 14. open To dos that need a decision (the Admin queue, most urgent first)
  v_slides := v_slides || jsonb_build_array(jsonb_build_object('key', 'todos', 'title', 'To dos that need a decision',
    'points', jsonb_build_array(app.ac_point('Open on the Admin queue', (select count(*)::text from tasks t where t.queue = 'admin' and t.status in ('open', 'in_progress', 'waiting') and t.task_type <> 'api_prepared_money'))),
    'items', coalesce((select jsonb_agg(jsonb_build_object('key', 'todo:' || t.id, 'kind', 'todo', 'label', t.title, 'detail', left(coalesce(t.detail, ''), 240),
                                        'href', '/admin/tasks', 'approve', 'Approve', 'deny', 'Decline') order by o)
                         from (select t.*, row_number() over (order by case t.priority when 'urgent' then 0 when 'high' then 1 when 'normal' then 2 else 3 end, t.created_at) o
                                 from tasks t where t.queue = 'admin' and t.status in ('open', 'in_progress', 'waiting') and t.task_type <> 'api_prepared_money') t where o <= 20), '[]'::jsonb)));
  return v_slides;
end $$;

create or replace function app.admin_call_build(p_at timestamptz default null, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_at timestamptz := coalesce(p_at, app.admin_call_next(now()));
  v_id uuid;
begin
  if v_at is null then raise exception 'No Admin call is scheduled' using errcode = '23514'; end if;
  insert into admin_call_decks (week_of, call_at, slides, built_by) values (app.admin_call_week(v_at), v_at, app.admin_call_slides(v_at), p_by)
  on conflict (week_of) do update set slides = excluded.slides, call_at = excluded.call_at, built_at = now(), built_by = excluded.built_by
  returning id into v_id;
  return v_id;
end $$;

-- ================================================================ 5. the page's read and actions
create or replace function app.admin_call_view(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  d admin_call_decks;
  s program_settings := app.settings();
begin
  perform app.assert_admin(p_by);
  select * into d from admin_call_decks where (nullif(p ->> 'week_of', '') is null or week_of = (p ->> 'week_of')::date) order by week_of desc limit 1;
  return jsonb_build_object('next_at', app.admin_call_next(now()), 'weekday', s.admin_call_weekday, 'time', s.admin_call_time, 'minutes', s.admin_call_minutes,
    'in_site', app.calls_in_site(),
    'weeks', coalesce((select jsonb_agg(w.week_of order by w.week_of desc) from (select week_of from admin_call_decks order by week_of desc limit 12) w), '[]'::jsonb),
    'deck', case when d.id is null then null else jsonb_build_object('id', d.id, 'week_of', d.week_of, 'call_at', d.call_at, 'built_at', d.built_at,
      'slides', coalesce((select jsonb_agg(x || jsonb_build_object('note', d.notes ->> (x ->> 'key'),
                  'items', coalesce((select jsonb_agg(i || coalesce((select jsonb_build_object('decision', c.decision, 'decided_by', app.ac_name(c.decided_by), 'decided_at', c.decided_at, 'decision_note', c.note)
                                                                       from admin_call_decisions c where c.deck_id = d.id and c.item_key = i ->> 'key'), '{}'::jsonb) order by o)
                                       from jsonb_array_elements(coalesce(x -> 'items', '[]'::jsonb)) with ordinality t(i, o)), '[]'::jsonb)) order by so)
                           from jsonb_array_elements(d.slides) with ordinality u(x, so)), '[]'::jsonb),
      'decided', (select count(*) from admin_call_decisions c where c.deck_id = d.id)) end);
end $$;

-- p: {deck, key, decision approve|deny, note}
create or replace function app.admin_call_decide(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  d admin_call_decks;
  v_key text := coalesce(p ->> 'key', '');
  v_dec text := coalesce(p ->> 'decision', '');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_kind text;
  v_id uuid;
  v_item jsonb;
  t tasks;
  b bookings;
begin
  perform app.assert_admin(p_by);
  if v_dec not in ('approve', 'deny') then raise exception 'Approve or deny' using errcode = '22023'; end if;
  if v_key !~ '^(shift|todo|money|deposit|payout):[0-9a-f-]{36}$' then raise exception 'Choose an item of the deck' using errcode = '22023'; end if;
  if length(coalesce(v_note, '')) > 500 then raise exception 'The note is at most 500 characters' using errcode = '22023'; end if;
  select * into d from admin_call_decks where id = nullif(p ->> 'deck', '')::uuid for update;
  if d.id is null then raise exception 'Deck not found' using errcode = 'P0002'; end if;
  select i into v_item from jsonb_array_elements(d.slides) x, jsonb_array_elements(coalesce(x -> 'items', '[]'::jsonb)) i where i ->> 'key' = v_key limit 1;
  if v_item is null then raise exception 'That item is not on this deck' using errcode = 'P0002'; end if;
  if exists (select 1 from admin_call_decisions c where c.deck_id = d.id and c.item_key = v_key) then raise exception 'Already decided' using errcode = '23505'; end if;
  v_kind := split_part(v_key, ':', 1);
  v_id := split_part(v_key, ':', 2)::uuid;

  if v_kind = 'shift' and v_dec = 'deny' then
    perform app.field_shift_plan_cancel(p_by, jsonb_build_object('id', v_id));
    update field_shift_plans set cancel_reason = coalesce(v_note, 'Taken off in the Admin call') where id = v_id and cancel_reason is null;
  elsif v_kind in ('todo', 'money') then
    select * into t from tasks where id = v_id;
    if t.id is null or t.status in ('done', 'cancelled') then raise exception 'This To do is already closed' using errcode = '23514'; end if;
    if v_dec = 'deny' then
      -- force only with the Admin's own note (complete_task's rule, 0020): without one, the task's completion problem shows
      perform app.complete_task(v_id, p_by, 'Declined in the Admin call' || coalesce(': ' || v_note, '.'), v_note is not null);
    else
      update tasks set priority = case when v_kind = 'money' then 'urgent' else priority end,
                       detail = left(coalesce(detail || E'\n\n', '') || 'Approved in the Admin call ' || to_char(now() at time zone 'America/Toronto', 'Mon FMDD') || coalesce(': ' || v_note, '.')
                                     || case when v_kind = 'money' then ' Do it in the portal now: no money moved yet.' else '' end, 4000),
                       updated_at = now()
       where id = v_id;
    end if;
  elsif v_kind = 'deposit' then
    select * into b from bookings where id = v_id;
    perform app.raise_task(p_type => 'admin_call_decision',
      p_title => format('Admin call: %s the deposit on %s', case when v_dec = 'approve' then 'release' else 'keep' end, b.booking_number),
      p_detail => format('Decided in the Admin call%s. Do it in Deposit reviews, where the amounts are checked and signed: nothing moved yet.', coalesce(': ' || v_note, '')),
      p_booking => b.id, p_related_table => 'bookings', p_related_id => b.id, p_due_at => now() + interval '1 day', p_priority => 'high',
      p_dedupe => 'admin_call:' || d.id || ':' || v_key, p_queue => 'finance', p_created_by => p_by);
  elsif v_kind = 'payout' then
    perform app.raise_task(p_type => 'admin_call_decision',
      p_title => format('Admin call: %s %s', case when v_dec = 'approve' then 'pay' else 'hold' end, coalesce(v_item ->> 'label', 'the payout')),
      p_detail => format('%s. Decided in the Admin call%s. Do it in Payouts, with its approvals: nothing moved yet.', v_item ->> 'detail', coalesce(': ' || v_note, '')),
      p_related_table => 'payouts', p_related_id => v_id, p_due_at => now() + interval '1 day', p_priority => 'high',
      p_dedupe => 'admin_call:' || d.id || ':' || v_key, p_queue => 'finance', p_created_by => p_by);
  end if;

  insert into admin_call_decisions (deck_id, item_key, decision, note, decided_by) values (d.id, v_key, v_dec, v_note, p_by);
  return jsonb_build_object('key', v_key, 'decision', v_dec);
end $$;

create or replace function app.admin_call_do(p_by uuid, p_action text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_id uuid;
  v_wd integer;
  v_time text;
  v_min integer;
begin
  perform app.assert_admin(p_by);
  if p_action = 'admin_call_build' then
    v_id := app.admin_call_build(coalesce((select c.call_at from admin_call_decks c where c.week_of = nullif(p ->> 'week_of', '')::date), app.admin_call_next(now())), p_by);
  elsif p_action = 'admin_call_note' then
    if coalesce(p ->> 'key', '') !~ '^[a-z]{2,20}$' then raise exception 'Choose the slide' using errcode = '22023'; end if;
    update admin_call_decks set notes = case when nullif(btrim(coalesce(p ->> 'note', '')), '') is null then notes - (p ->> 'key')
                                           else notes || jsonb_build_object(p ->> 'key', left(btrim(p ->> 'note'), 2000)) end
     where id = nullif(p ->> 'deck', '')::uuid returning id into v_id;
    if v_id is null then raise exception 'Deck not found' using errcode = 'P0002'; end if;
  elsif p_action = 'admin_call_decide' then
    return app.admin_call_decide(p_by, p);
  elsif p_action = 'admin_call_schedule' then
    v_wd := nullif(p ->> 'weekday', '')::integer;
    v_time := btrim(coalesce(p ->> 'time', ''));
    v_min := coalesce(nullif(p ->> 'minutes', '')::integer, (app.settings()).admin_call_minutes);
    if v_wd is null or v_wd not between 1 and 7 then raise exception 'Choose the day' using errcode = '22023'; end if;
    if v_time !~ '^([01]?[0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'The time is HH:MM, Toronto time' using errcode = '22023'; end if;
    if v_min not between 15 and 240 then raise exception 'The length is 15 to 240 minutes' using errcode = '22023'; end if;
    update program_settings set admin_call_weekday = v_wd, admin_call_time = v_time, admin_call_minutes = v_min where id = (app.settings()).id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'admin_call_schedule', 'program_settings', null, jsonb_build_object('admin_call_weekday', v_wd, 'admin_call_time', v_time, 'admin_call_minutes', v_min));
  else
    raise exception 'Unknown action %', p_action using errcode = '22023';
  end if;
  return jsonb_build_object('id', v_id);
end $$;

-- ================================================================ 6. the call in the site
do $$ begin
  if to_regprocedure('app.call_join_pre5150(uuid,jsonb)') is null then
    alter function app.call_join(uuid, jsonb) rename to call_join_pre5150;
  end if;
end $$;
create or replace function app.call_join(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_next timestamptz;
  s program_settings := app.settings();
  r call_rooms;
  u users;
begin
  if coalesce(p ->> 'room', '') <> 'admin_call' then return app.call_join_pre5150(p_by, p); end if;
  if not app.user_is_admin(p_by) then raise exception 'The Admin call is for the Admins' using errcode = '42501'; end if;
  v_next := app.admin_call_next(now());
  if v_next is null then raise exception 'No Admin call is scheduled' using errcode = '23514'; end if;
  select * into u from users where id = p_by;
  insert into call_rooms (kind, name, title, meeting_at)
  values ('admin_call', 'admin-call-' || to_char(v_next at time zone 'America/Toronto', 'YYYYMMDD-HH24MI'), 'Admin call, ' || to_char(v_next at time zone 'America/Toronto', 'FMDay, FMMonth FMDD'), v_next)
  on conflict (name) do update set title = excluded.title
  returning * into r;
  return jsonb_build_object('in_site', s.calls_mode = 'in_site', 'room', r.name, 'kind', r.kind, 'title', r.title, 'meeting_at', r.meeting_at,
    'identity', 'u-' || p_by, 'name', coalesce(nullif(btrim(u.greeting_name), ''), nullif(btrim(u.full_name), ''), u.email, 'Admin'),
    'role', 'presenter', 'minutes', s.admin_call_minutes, 'fallback_url', null);
end $$;
select pg_temp.copy_grants('app.call_join(uuid, jsonb)'::regprocedure, 'app.call_join_pre5150(uuid, jsonb)'::regprocedure);

-- who is in the Admin call (the room of the next one, by its name)
do $$ begin
  if to_regprocedure('app.call_live_pre5150(uuid,jsonb)') is null then
    alter function app.call_live(uuid, jsonb) rename to call_live_pre5150;
  end if;
end $$;
create or replace function app.call_live(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  if coalesce(p ->> 'room', '') = 'admin_call' then
    return app.call_live_pre5150(p_by, jsonb_build_object('room', coalesce((select r.name from call_rooms r where r.kind = 'admin_call' and r.meeting_at = app.admin_call_next(now())), 'none')));
  end if;
  return app.call_live_pre5150(p_by, p);
end $$;
select pg_temp.copy_grants('app.call_live(uuid, jsonb)'::regprocedure, 'app.call_live_pre5150(uuid, jsonb)'::regprocedure);

-- ================================================================ 7. the weekly invite
create or replace function app.admin_call_page() returns text
language sql stable security definer set search_path = public, app, pg_temp as $$ select rtrim((app.settings()).notify_base_url, '/') || '/admin/admin-call/live' $$;

create or replace function app.admin_call_series(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('starts_at', n, 'ends_at', n + make_interval(mins => s.admin_call_minutes), 'rrule', 'FREQ=WEEKLY;BYDAY=' || app.ics_byday(s.admin_call_weekday),
    'minutes', s.admin_call_minutes, 'location', app.admin_call_page(),
    'when', 'Every ' || (array['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'])[s.admin_call_weekday] || ' at '
            || to_char(('2000-01-01 ' || s.admin_call_time)::timestamp, 'FMHH12:MI am') || ' Toronto time',
    'sig', s.admin_call_weekday || '|' || s.admin_call_time || '|' || s.admin_call_minutes || '|' || app.admin_call_page())
    from app.settings() s, lateral (select app.admin_call_next(p_now) n) y
   where n is not null
$$;

create or replace function app.admin_call_invitees() returns table (user_id uuid, email text, name text, first_name text)
language sql stable security definer set search_path = public, app, pg_temp as $$
  select u.id, lower(btrim(u.email)), coalesce(nullif(btrim(u.full_name), ''), u.email),
         coalesce(nullif(btrim(u.greeting_name), ''), nullif(split_part(btrim(coalesce(u.full_name, '')), ' ', 1), ''), 'there')
    from users u
   where nullif(btrim(coalesce(u.email, '')), '') is not null and app.user_is_admin(u.id) and coalesce(u.status::text, 'active') = 'active'
$$;

create or replace function app.admin_call_invite_send(p_user uuid, p_email text, p_name text, p_first text, p_method text, p_series jsonb) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  ci calendar_invites;
  v_prev integer;
begin
  select max(seq) into v_prev from calendar_invites where user_id = p_user and kind = 'admin_call';
  insert into calendar_invites (kind, user_id, uid, seq, method, starts_at, ends_at, rrule, summary, description, location, attendee_email, attendee_name, sig)
  values ('admin_call', p_user, 'admin-call@carmacars.ca', coalesce(v_prev + 1, 0), p_method,
          (p_series ->> 'starts_at')::timestamptz, (p_series ->> 'ends_at')::timestamptz, p_series ->> 'rrule',
          'CarmaCars weekly Admin call',
          'The week''s deck, built from the live data: shifts, hours and pay, the academy, hiring, social media, the numbers, owners, deposits, insurance, claims, money, tolls, the fleet and the To dos that need a decision. Join from Admin > Admin call.',
          coalesce(p_series ->> 'location', ''), p_email, p_name, p_series ->> 'sig')
  returning * into ci;
  perform app.emit_event(case when p_method = 'REQUEST' then 'admin_call_invite' else 'admin_call_cancelled' end, 'user', p_user,
    jsonb_build_object('recipient_user_id', p_user, 'first_name', p_first,
      'invite_subject', case when p_method = 'CANCEL' then 'Weekly Admin call: removed from your calendar' when v_prev is null then 'Weekly Admin call: your calendar invite' else 'Weekly Admin call: updated calendar invite' end,
      'invite_title', case when v_prev is null then 'Your Admin call invite' else 'The Admin call invite, updated' end,
      'call_when', coalesce(p_series ->> 'when', ''), 'call_minutes', coalesce(p_series ->> 'minutes', ''), 'is_update', v_prev is not null,
      'call_url', coalesce(p_series ->> 'location', ''), '_ics_id', ci.id),
    'admin_call_invite:' || ci.id);
  return ci.id;
end $$;

create or replace function app.admin_call_invites_sweep(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_series jsonb := app.admin_call_series(p_now);
  r record;
  last calendar_invites;
  n integer := 0;
begin
  if v_series is null then return 0; end if;
  perform pg_advisory_xact_lock(hashtext('admin_call_invites_sweep'));
  for r in select * from app.admin_call_invitees() loop
    select * into last from calendar_invites x where x.user_id = r.user_id and x.kind = 'admin_call' order by x.created_at desc, x.seq desc limit 1;
    if last.id is null or last.method = 'CANCEL' or last.sig is distinct from v_series ->> 'sig' or last.attendee_email <> r.email then
      perform app.admin_call_invite_send(r.user_id, r.email, r.name, r.first_name, 'REQUEST', v_series);
      n := n + 1;
    end if;
  end loop;
  -- no longer an Admin: the series comes off their calendar
  for r in select distinct on (x.user_id) x.* from calendar_invites x where x.kind = 'admin_call' order by x.user_id, x.created_at desc, x.seq desc loop
    if r.method = 'REQUEST' and not exists (select 1 from app.admin_call_invitees() i where i.user_id = r.user_id) then
      perform app.admin_call_invite_send(r.user_id, r.attendee_email, r.attendee_name,
        coalesce((select coalesce(nullif(btrim(u.greeting_name), ''), nullif(split_part(btrim(coalesce(u.full_name, '')), ' ', 1), ''), 'there') from users u where u.id = r.user_id), 'there'),
        'CANCEL', jsonb_build_object('starts_at', r.starts_at, 'ends_at', r.ends_at, 'rrule', r.rrule, 'location', r.location, 'sig', r.sig, 'when', v_series ->> 'when', 'minutes', v_series ->> 'minutes'));
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- the Add to calendar download (/api/admin-call-ics): the same event, METHOD:PUBLISH
create or replace function app.admin_call_ics(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v jsonb := app.admin_call_series(now());
  ci calendar_invites;
begin
  perform app.assert_admin(p_by);
  if v is null then return jsonb_build_object('ics', null); end if;
  select * into ci from calendar_invites x where x.user_id = p_by and x.kind = 'admin_call' order by x.created_at desc, x.seq desc limit 1;
  ci.kind := 'admin_call'; ci.uid := 'admin-call@carmacars.ca'; ci.seq := coalesce(ci.seq, 0); ci.recurrence_id := null; ci.created_at := now(); ci.exdates := '{}';
  ci.starts_at := (v ->> 'starts_at')::timestamptz; ci.ends_at := (v ->> 'ends_at')::timestamptz; ci.rrule := v ->> 'rrule';
  ci.summary := 'CarmaCars weekly Admin call'; ci.location := v ->> 'location'; ci.attendee_email := coalesce(ci.attendee_email, 'hello@carmacars.ca');
  ci.description := 'The week''s deck with the decisions to take. Join from Admin > Admin call.';
  return jsonb_build_object('ics', app.ics_build('PUBLISH', ci));
end $$;

-- the email carries the file under its own name
select pg_temp.patch_fn('app.outbox_inline_files(uuid)'::regprocedure,
  $o$case when ci.kind = 'townhall' then 'carmacars-townhall.ics' else$o$, $n$case when ci.kind = 'townhall' then 'carmacars-townhall.ics' when ci.kind = 'admin_call' then 'carmacars-admin-call.ics' else$n$);

-- a new day, time or length (the Admin call page, or a new Program settings row) goes out at once
create or replace function app.admin_call_invites_now() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  perform app.admin_call_invites_sweep(now());
  return null;
end $$;
drop trigger if exists program_settings_admin_call_invites on program_settings;
create trigger program_settings_admin_call_invites after insert or update of admin_call_weekday, admin_call_time, admin_call_minutes on program_settings
  for each statement execute function app.admin_call_invites_now();

-- ================================================================ 8. the job: the deck, the alert, the invites
create or replace function app.job_admin_call(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_next timestamptz := app.admin_call_next(p_now);
  d admin_call_decks;
  v_built boolean := false;
  v_alert boolean := false;
begin
  if v_next is null then return 'admin call: none'; end if;
  select * into d from admin_call_decks where week_of = app.admin_call_week(v_next);
  -- built in the day before the call, and again in the three hours before so the numbers are fresh
  if v_next > p_now and v_next <= p_now + interval '24 hours'
     and (d.id is null or (v_next <= p_now + interval '3 hours' and d.built_at < v_next - interval '3 hours')) then
    perform app.admin_call_build(v_next, null);
    v_built := true;
    select * into d from admin_call_decks where week_of = app.admin_call_week(v_next);
  end if;
  if d.id is not null and v_next > p_now and v_next <= p_now + interval '60 minutes' and d.reminded_at is null then
    perform app.staff_alert('admin_call_soon', 'admin_call_deck', d.id, 'soon:' || to_char(v_next, 'YYYYMMDDHH24MI'), 'The weekly Admin call starts in an hour',
      'At ' || to_char(v_next at time zone 'America/Toronto', 'FMHH12:MI am') || ' Toronto time. The deck is ready, with the decisions to take.',
      jsonb_build_object('path_admin', '/admin/admin-call'));
    update admin_call_decks set reminded_at = p_now where id = d.id;
    v_alert := true;
  end if;
  return format('admin call: built %s, alert %s, %s invites', v_built, v_alert, app.admin_call_invites_sweep(p_now));
end $$;

do $$ begin
  if to_regprocedure('app.job_townhall_pre5150(timestamptz)') is null then
    alter function app.job_townhall(timestamptz) rename to job_townhall_pre5150;
  end if;
end $$;
create or replace function app.job_townhall(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v text := app.job_townhall_pre5150(p_now);
begin
  return v || '; ' || app.job_admin_call(p_now);
end $$;
select pg_temp.copy_grants('app.job_townhall(timestamptz)'::regprocedure, 'app.job_townhall_pre5150(timestamptz)'::regprocedure);

-- the invite goes by itself, never folded into a digest (the .ics must reach the calendar)
do $$ begin
  if to_regprocedure('app.staff_email_own_pre5150(text)') is null then
    alter function app.staff_email_own(text) rename to staff_email_own_pre5150;
  end if;
end $$;
create or replace function app.staff_email_own(p_code text) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.staff_email_own_pre5150(p_code) or p_code in ('admin_call_invite', 'admin_call_cancelled')
$$;
select pg_temp.copy_grants('app.staff_email_own(text)'::regprocedure, 'app.staff_email_own_pre5150(text)'::regprocedure);

-- ================================================================ 9. the door
do $$ begin
  if to_regprocedure('app.door_pre5150(uuid,text,text,text,jsonb)') is null then
    alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5150;
  end if;
end $$;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_call = 'admin_read' and p_name in ('admin_call', 'admin_call_ics') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'admin_call' then app.admin_call_view(p_user, p_) else app.admin_call_ics(p_user) end;
  end if;
  if p_call = 'admin_do' and p_name in ('admin_call_build', 'admin_call_note', 'admin_call_decide', 'admin_call_schedule') then
    perform app.door_begin(p_user, p_aal);
    return app.admin_call_do(p_user, p_name, p_);
  end if;
  return app.door_pre5150(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5150(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 10. the emails
-- CATALOGUE 5150 START (generated by supabase/seed/5150_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('admin_call_invite', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', '{{invite_subject}}', '{{call_when}}, {{call_minutes}} minutes. Open the invite to add it to your calendar.', 'Immediate: on becoming an Admin, and on every change of the day, time or length', 'R50 hotfix 2 (5150): the weekly Admin call calendar invite (an .ics file, METHOD:REQUEST, repeating every week, Toronto time) to every active Admin: once when they become an Admin, and again as an update whenever the day, the time or the length changes (Admin call page or Program settings). Sent by the townhall job (app.admin_call_invites_sweep).', null, null, '[{"name":"call_minutes","type":"string"},{"name":"call_url","type":"url"},{"name":"call_when","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"invite_subject","type":"string"},{"name":"invite_title","type":"string"},{"name":"is_update","type":"boolean"}]'::jsonb, 'templates/admin_call_invite.html', 'templates/admin_call_invite.txt'),
  ('admin_call_cancelled', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', '{{invite_subject}}', 'The weekly Admin call comes off your calendar.', 'Immediate, when the person is no longer an Admin', 'R50 hotfix 2 (5150): a calendar cancellation of the weekly Admin call (an .ics file, METHOD:CANCEL) to a person who is no longer an Admin. Sent by the townhall job (app.admin_call_invites_sweep).', null, null, '[{"name":"call_url","type":"url"},{"name":"company_address","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"invite_subject","type":"string"}]'::jsonb, 'templates/admin_call_cancelled.html', 'templates/admin_call_cancelled.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 5150 END
update notification_catalogue set emitted_by = 'app.admin_call_invites_sweep (5150): an Admin joins, or the Admin call''s day, time or length changes'
 where code = 'admin_call_invite';
update notification_catalogue set emitted_by = 'app.admin_call_invites_sweep (5150): a person is no longer an Admin'
 where code = 'admin_call_cancelled';
update notification_catalogue set no_text = true, hold_to_merge = false, priority = 3 where code in ('admin_call_invite', 'admin_call_cancelled');

-- ================================================================ privileges
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['admin_call_next', 'admin_call_week', 'ac_point', 'ac_name', 'ac_when', 'admin_call_slides', 'admin_call_build',
                    'admin_call_view', 'admin_call_decide', 'admin_call_do', 'call_join_pre5150', 'call_live_pre5150', 'admin_call_page', 'admin_call_series',
                    'admin_call_invitees', 'admin_call_invite_send', 'admin_call_invites_sweep', 'admin_call_ics', 'admin_call_invites_now', 'job_admin_call',
                    'job_townhall_pre5150', 'staff_email_own_pre5150', 'door_pre5150']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- now: every Admin gets the weekly invite
select app.admin_call_invites_sweep(now());
