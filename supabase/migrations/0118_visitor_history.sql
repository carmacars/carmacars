-- 0118_visitor_history.sql
-- The owner's request of October 23, 2026: "i want to be able to see history of visitors".
--
--   A. Visitor history for Admins (Today > Visitor history): past visits with filters (dates, source, landing page,
--      device, country and city, new or returning, converted, contact given, bots shown or not), one visit in full
--      (its pages with the time on each, entry and exit, how it arrived, device, approximate city, games, chats, forms
--      started and left, the renter, leads and bookings it led to) and a daily chart (visits, unique visitors,
--      conversions, top pages and sources). Admins only, like the rest of the Admin area (app.assert_admin).
--   B. Retention, as Admin settings (Settings > Program, "Live visitors and live chat"):
--        visitor_events_keep_days    90   the pages and events of a visit (unchanged; page-level detail)
--        visitor_sessions_keep_days  395  the visit itself, as a summary (13 months; was deleted with its events)
--        visitor_daily_keep_days     1095 the daily totals, which name no one (3 years)
--      The daily housekeeping deletes in batches of 5,000 rows.
--   C. A visit's summary (the exit page, the length, the conversions, whether we have a way to contact them, bot or
--      staff) is worked out once the visit has been quiet for 30 minutes, 300 visits at a time, by the existing job
--      carmacars-visitor-followups (every 15 minutes). The same run fills the daily totals (visitor_daily and
--      visitor_daily_top: today and yesterday again, and up to 7 missing earlier days), so long charts read a row a day.
--   D. Nothing new is collected: the summary is made from what the beacon already keeps under the visitor's consent.
--      Staff are never recorded (app.track_ingest); a visit by someone who is now staff, and automation the Worker's
--      user-agent check let through (many pages, a second or two each), are marked and left out of the list and the
--      totals by default.
--   E. Privacy policy section 1 (the retention table): visit summaries 13 months; flagged for the lawyer.
-- No applied migration is edited.

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists visitor_sessions_keep_days integer not null default 395 check (visitor_sessions_keep_days between 30 and 1095),
  add column if not exists visitor_daily_keep_days integer not null default 1095 check (visitor_daily_keep_days between 90 and 3650);
comment on column program_settings.visitor_sessions_keep_days is 'Visitor history (0118): a visit''s summary (date, how it arrived, device, approximate city, pages viewed, conversions) is kept this many days (395, 13 months, by default). Never less than the page views and events (visitor_events_keep_days).';
comment on column program_settings.visitor_daily_keep_days is 'Visitor history (0118): the daily totals (visits, unique visitors, conversions, top pages and sources; no personal information) are kept this many days (1095, 3 years, by default).';

-- ================================================================ 2. the visit's summary
alter table visitor_sessions
  add column if not exists summary_at     timestamptz,
  add column if not exists exit_path      text,
  add column if not exists duration_s     integer check (duration_s >= 0),
  add column if not exists conversions    text[] not null default '{}',
  add column if not exists has_contact    boolean not null default false,
  add column if not exists exclude_reason text check (exclude_reason in ('bot', 'staff'));
comment on column visitor_sessions.summary_at is 'Visitor history (0118): when the summary below was worked out (30 minutes after the visit went quiet; again if it came back).';
comment on column visitor_sessions.conversions is 'Visitor history (0118): what the visit led to: request (a booking request sent), booking (a booking confirmed during it), signup (an account opened), contact (contact details given in a form, the chat or a game).';
comment on column visitor_sessions.has_contact is 'Visitor history (0118): we have a way to contact this visitor (a known renter or email, or details given in a form, the chat or a game).';
comment on column visitor_sessions.exclude_reason is 'Visitor history (0118): bot (automation the Worker''s check let through) or staff (the account is staff now). Left out of the history and the totals by default.';

-- the list: newest first, a page at a time (keyset on started_at, id)
create index if not exists visitor_sessions_started_idx on visitor_sessions (started_at, id);
-- the job: visits not summarized yet
create index if not exists visitor_sessions_summary_due_idx on visitor_sessions (last_seen_at) where summary_at is null;
-- the two filters that pick a few visits out of many
create index if not exists visitor_sessions_converted_idx on visitor_sessions (started_at, id) where conversions <> '{}';
create index if not exists visitor_sessions_contact_idx on visitor_sessions (started_at, id) where has_contact;

-- ================================================================ 3. the daily totals (no personal information)
create table visitor_daily (
  day              date primary key,                 -- Toronto day the visits started
  visits           integer not null default 0,
  visitors         integer not null default 0,       -- distinct browsers that day
  new_visits       integer not null default 0,
  returning_visits integer not null default 0,
  known_visits     integer not null default 0,
  page_views       integer not null default 0,
  bounces          integer not null default 0,       -- one page or none
  seconds          bigint  not null default 0,       -- the visits' lengths added up
  converted        integer not null default 0,
  requests         integer not null default 0,
  bookings         integer not null default 0,
  signups          integer not null default 0,
  contacts         integer not null default 0,
  phone            integer not null default 0,
  tablet           integer not null default 0,
  desktop          integer not null default 0,
  left_out         integer not null default 0,       -- bots and staff, not in the figures above
  computed_at      timestamptz not null default now()
);
comment on table visitor_daily is 'Visitor history (0118): one row per Toronto day, worked out from the visits by the visitor job. Counts only; kept visitor_daily_keep_days.';

create table visitor_daily_top (
  day  date not null references visitor_daily (day) on delete cascade,
  dim  text not null check (dim in ('page', 'source', 'landing', 'country')),
  key  text not null,
  n    integer not null,                             -- page: views; the others: visits
  primary key (day, dim, key)
);
comment on table visitor_daily_top is 'Visitor history (0118): the 20 most viewed pages and the 20 first sources, landing pages and countries of each day. Counts only.';

do $$
declare t text;
begin
  foreach t in array array['visitor_daily', 'visitor_daily_top'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('grant select, insert, update, delete on %I to service_role', t);
  end loop;
end $$;

-- ================================================================ 4. helpers
-- the page events (the others are actions on a page)
create or replace function app.visit_page_kinds() returns text[]
language sql immutable as $$ select array['page_view', 'car_view', 'offer_viewed', 'change_viewed', 'pay_viewed', 'request_submitted'] $$;

-- where a visit came from, in words: the campaign's source, the referring site, or direct
create or replace function app.visit_source(s visitor_sessions) returns text
language sql immutable as $$
  select coalesce(nullif(lower(s.utm ->> 'source'), ''), nullif(lower(s.referrer), ''),
                  case when s.consent = 'analytics' then 'direct' else 'not recorded' end)
$$;

-- automation the Worker's user-agent check let through: many pages, a second or two each
create or replace function app.visit_is_bot(p_pages integer, p_seconds integer) returns boolean
language sql immutable as $$ select coalesce(p_pages, 0) >= 200 or (coalesce(p_pages, 0) >= 30 and coalesce(p_seconds, 0) < p_pages * 2) $$;

-- One visit's summary, from what was kept of it. The window: the visit, and 10 minutes after its last sign of life
-- (a request is sent, an account confirmed, just after the last page).
create or replace function app.visit_summarize(p_id uuid, p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  s visitor_sessions;
  v_from timestamptz;
  v_to timestamptz;
  v_conv text[];
  v_contact boolean;
  v_secs integer;
  v_exit text;
  v_reason text;
begin
  select * into s from visitor_sessions where id = p_id;
  if s.id is null then return; end if;
  v_from := s.started_at - interval '1 minute';
  v_to := s.last_seen_at + interval '10 minutes';
  v_secs := greatest(0, floor(extract(epoch from s.last_seen_at - s.started_at)))::integer;
  v_exit := coalesce((select e.path from visitor_events e where e.session_id = s.id and e.kind = any (app.visit_page_kinds())
                       order by e.at desc, e.id desc limit 1), s.current_path);
  v_conv := array_remove(array[
    case when exists (select 1 from visitor_events e where e.session_id = s.id and e.kind = 'request_submitted')
           or (s.renter_id is not null and exists (select 1 from bookings b where b.renter_id = s.renter_id and b.booking_type <> 'owner'
                                                   and coalesce(b.requested_at, b.created_at) between v_from and v_to)) then 'request' end,
    case when s.renter_id is not null and exists (select 1 from bookings b where b.renter_id = s.renter_id and b.booking_type <> 'owner'
                                                  and b.booked_at between v_from and v_to) then 'booking' end,
    case when (s.user_id is not null and exists (select 1 from users u where u.id = s.user_id and u.created_at between v_from and v_to))
           or exists (select 1 from capture_accounts ca where ca.visitor_id = s.visitor_id and ca.opened_by_capture and ca.opened_at between v_from and v_to) then 'signup' end,
    case when exists (select 1 from contact_captures c where c.visitor_id = s.visitor_id and c.first_at between v_from and v_to and (c.email is not null or c.phone is not null))
           or exists (select 1 from chat_conversations c where c.visitor_id = s.visitor_id and c.created_at <= v_to and coalesce(c.last_message_at, c.created_at) >= v_from
                       and (c.email is not null or c.phone is not null))
           or exists (select 1 from game_claims g where g.visitor_id = s.visitor_id and g.created_at between v_from and v_to) then 'contact' end], null);
  v_contact := s.renter_id is not null or s.known_email is not null
    or exists (select 1 from contact_captures c where c.visitor_id = s.visitor_id and c.first_at <= v_to and (c.email is not null or c.phone is not null))
    or exists (select 1 from game_claims g where g.visitor_id = s.visitor_id and g.created_at <= v_to)
    or exists (select 1 from chat_conversations c where c.visitor_id = s.visitor_id and c.created_at <= v_to and (c.email is not null or c.phone is not null));
  v_reason := case
    when s.user_id is not null and (app.user_is_admin(s.user_id) or app.user_is_staff(s.user_id) or app.user_is_field(s.user_id)) then 'staff'
    when app.visit_is_bot(s.page_views, v_secs) then 'bot' end;
  update visitor_sessions set summary_at = p_now, exit_path = v_exit, duration_s = v_secs, conversions = coalesce(v_conv, '{}'),
         has_contact = v_contact, exclude_reason = v_reason
   where id = p_id;
end $$;

-- One Toronto day's totals, from its visits (and its page views while they are kept). Run again freely.
create or replace function app.visitor_daily_compute(p_day date, p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_from timestamptz := app.local_midnight(p_day);
  v_to timestamptz := app.local_midnight(p_day + 1);
  v_pages boolean := p_day > app.local_date(p_now) - (app.settings(app.local_date(p_now))).visitor_events_keep_days;
begin
  insert into visitor_daily as d (day, visits, visitors, new_visits, returning_visits, known_visits, page_views, bounces, seconds, converted,
                                  requests, bookings, signups, contacts, phone, tablet, desktop, left_out, computed_at)
  select p_day,
         count(*) filter (where s.exclude_reason is null),
         count(distinct s.visitor_id) filter (where s.exclude_reason is null),
         count(*) filter (where s.exclude_reason is null and s.visit_number <= 1),
         count(*) filter (where s.exclude_reason is null and s.visit_number > 1),
         count(*) filter (where s.exclude_reason is null and s.renter_id is not null),
         coalesce(sum(s.page_views) filter (where s.exclude_reason is null), 0),
         count(*) filter (where s.exclude_reason is null and s.page_views <= 1),
         coalesce(sum(greatest(0, floor(extract(epoch from s.last_seen_at - s.started_at)))::bigint) filter (where s.exclude_reason is null), 0),
         count(*) filter (where s.exclude_reason is null and s.conversions <> '{}'),
         count(*) filter (where s.exclude_reason is null and 'request' = any (s.conversions)),
         count(*) filter (where s.exclude_reason is null and 'booking' = any (s.conversions)),
         count(*) filter (where s.exclude_reason is null and 'signup' = any (s.conversions)),
         count(*) filter (where s.exclude_reason is null and 'contact' = any (s.conversions)),
         count(*) filter (where s.exclude_reason is null and s.device = 'phone'),
         count(*) filter (where s.exclude_reason is null and s.device = 'tablet'),
         count(*) filter (where s.exclude_reason is null and s.device = 'desktop'),
         count(*) filter (where s.exclude_reason is not null),
         p_now
    from visitor_sessions s where s.started_at >= v_from and s.started_at < v_to
  on conflict (day) do update set visits = excluded.visits, visitors = excluded.visitors, new_visits = excluded.new_visits,
    returning_visits = excluded.returning_visits, known_visits = excluded.known_visits, page_views = excluded.page_views, bounces = excluded.bounces,
    seconds = excluded.seconds, converted = excluded.converted, requests = excluded.requests, bookings = excluded.bookings, signups = excluded.signups,
    contacts = excluded.contacts, phone = excluded.phone, tablet = excluded.tablet, desktop = excluded.desktop, left_out = excluded.left_out,
    computed_at = excluded.computed_at;

  -- the top lists; a day whose page views are gone keeps the pages it had
  delete from visitor_daily_top where day = p_day and (dim <> 'page' or v_pages);
  insert into visitor_daily_top (day, dim, key, n)
  select p_day, 'source', k, n from (
    select app.visit_source(s) as k, count(*)::integer as n from visitor_sessions s
     where s.started_at >= v_from and s.started_at < v_to and s.exclude_reason is null group by 1 order by 2 desc, 1 limit 20) x
  union all
  select p_day, 'landing', k, n from (
    select coalesce(nullif(s.landing_path, ''), '(not recorded)') as k, count(*)::integer as n from visitor_sessions s
     where s.started_at >= v_from and s.started_at < v_to and s.exclude_reason is null group by 1 order by 2 desc, 1 limit 20) x
  union all
  select p_day, 'country', k, n from (
    select coalesce(nullif(s.country, ''), '--') as k, count(*)::integer as n from visitor_sessions s
     where s.started_at >= v_from and s.started_at < v_to and s.exclude_reason is null group by 1 order by 2 desc, 1 limit 20) x;
  if v_pages then
    insert into visitor_daily_top (day, dim, key, n)
    select p_day, 'page', k, n from (
      select e.path as k, count(*)::integer as n from visitor_sessions s join visitor_events e on e.session_id = s.id
       where s.started_at >= v_from and s.started_at < v_to and s.exclude_reason is null and e.kind = any (app.visit_page_kinds()) and e.path is not null
       group by 1 order by 2 desc, 1 limit 20) x;
  end if;
end $$;

-- ================================================================ 5. the job (inside carmacars-visitor-followups, every 15 minutes)
-- Small batches: at most p_limit visits summarized (quiet for 30 minutes; again when one came back), today's and
-- yesterday's totals again, and up to 7 missing earlier days (the first runs fill the past this way).
create or replace function app.job_visitor_history(p_now timestamptz default now(), p_limit integer default 300) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_today date := app.local_date(p_now);
  v_first date;
  x uuid;
  d date;
  v_s integer := 0;
  v_d integer := 0;
begin
  for x in select s.id from visitor_sessions s
            where s.summary_at is null and s.last_seen_at < p_now - interval '30 minutes'
            order by s.last_seen_at limit p_limit loop
    perform app.visit_summarize(x, p_now); v_s := v_s + 1;
  end loop;
  for x in select s.id from visitor_sessions s
            where s.last_seen_at > p_now - interval '1 day' and s.last_seen_at < p_now - interval '30 minutes' and s.summary_at < s.last_seen_at
            order by s.last_seen_at limit p_limit loop
    perform app.visit_summarize(x, p_now); v_s := v_s + 1;
  end loop;

  perform app.visitor_daily_compute(v_today, p_now);
  perform app.visitor_daily_compute(v_today - 1, p_now);
  v_d := 2;
  -- the earliest visit kept (null: none, nothing to fill)
  v_first := app.local_date((select min(started_at) from visitor_sessions));
  if v_first is not null then v_first := greatest(v_first, v_today - greatest(ps.visitor_sessions_keep_days, ps.visitor_events_keep_days)); end if;
  if v_first is not null and v_first < v_today - 1 then
    for d in select g::date from generate_series(v_today - 2, v_first, interval '-1 day') g
              where not exists (select 1 from visitor_daily v where v.day = g::date) limit 7 loop
      perform app.visitor_daily_compute(d, p_now); v_d := v_d + 1;
    end loop;
  end if;
  return format('visits %s, days %s', v_s, v_d);
end $$;

alter function app.job_visitor_followups(timestamptz) rename to job_visitor_followups_pre0118;
create or replace function app.job_visitor_followups(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v text := app.job_visitor_followups_pre0118(p_now);
  v_h text;
begin
  -- the history never stops the follow-ups, and the job's answer stays the follow-ups' own
  begin
    v_h := app.job_visitor_history(p_now);
    raise log 'visitor history: %', v_h;
  exception when others then
    raise warning 'visitor history failed: %', sqlerrm;
  end;
  return v;
end $$;

-- ================================================================ 6. housekeeping (daily): page detail 90 days, visits 13 months, totals 3 years
-- 0060's job, with the visit kept as a summary after its events, every delete in batches of 5,000 rows (at most
-- 200,000 a run, so a lowered setting catches up over a few days without a long lock), and the old totals.
create or replace function app.job_visitor_housekeeping(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_events_before timestamptz := p_now - make_interval(days => ps.visitor_events_keep_days);
  v_visits_before timestamptz := p_now - make_interval(days => greatest(ps.visitor_sessions_keep_days, ps.visitor_events_keep_days));
  v_e integer := 0; v_s integer := 0; v_c integer; v_d integer; n integer; i integer;
begin
  for i in 1..40 loop
    delete from visitor_events where id in (select id from visitor_events where at < v_events_before order by at limit 5000);
    get diagnostics n = row_count; v_e := v_e + n;
    exit when n < 5000;
  end loop;
  delete from visitor_signals where last_at < v_events_before;
  delete from chat_conversations c where c.renter_id is null and c.booking_id is null
     and coalesce(c.closed_at, c.last_message_at) < p_now - make_interval(days => ps.chat_keep_days);
  get diagnostics v_c = row_count;
  for i in 1..40 loop
    delete from visitor_sessions where id in (
      select s.id from visitor_sessions s where s.last_seen_at < v_visits_before
         and not exists (select 1 from chat_conversations c where c.session_id = s.id)
       order by s.last_seen_at limit 5000);
    get diagnostics n = row_count; v_s := v_s + n;
    exit when n < 5000;
  end loop;
  delete from visitor_daily where day < app.local_date(p_now) - ps.visitor_daily_keep_days;
  get diagnostics v_d = row_count;
  -- the assistant's chat, quiet for 12 hours: over
  update chat_conversations set status = 'closed', closed_at = p_now
   where status in ('ai') and last_message_at < p_now - interval '12 hours';
  return format('events %s, sessions %s, chats %s, days %s', v_e, v_s, v_c, v_d);
end $$;

-- ================================================================ 7. reads for Admins
create or replace function app.visit_history_row(s visitor_sessions) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', s.id, 'who', app.visitor_who(s), 'known', s.renter_id is not null or s.known_email is not null, 'renter_id', s.renter_id,
    'started_at', s.started_at, 'last_seen_at', s.last_seen_at,
    'duration_s', coalesce(s.duration_s, greatest(0, floor(extract(epoch from s.last_seen_at - s.started_at)))::integer),
    'device', s.device, 'city', s.city, 'region', s.region, 'country', s.country, 'consent', s.consent,
    'source', app.visit_source(s), 'referrer', s.referrer, 'utm_source', s.utm ->> 'source', 'utm_medium', s.utm ->> 'medium', 'utm_campaign', s.utm ->> 'campaign',
    'from_ad', s.from_ad, 'landing_path', s.landing_path, 'landing', app.path_label(s.landing_path),
    'exit_path', coalesce(s.exit_path, s.current_path), 'exit', app.path_label(coalesce(s.exit_path, s.current_path)),
    'page_views', s.page_views, 'cars_viewed', cardinality(s.cars_viewed), 'visit_number', s.visit_number, 'returning', s.visit_number > 1,
    'conversions', to_jsonb(s.conversions), 'has_contact', s.has_contact, 'exclude_reason', s.exclude_reason, 'summarized', s.summary_at is not null)
$$;

-- p: from, to (Toronto dates; the last 30 days by default), source, landing, device, country, city, visitor ('new' or
-- 'returning'), converted ('any', 'none', 'request', 'booking', 'signup', 'contact'), contact ('1'), known ('1'), bots
-- ('1': bots and staff shown too), cursor ('<started_at>|<id>' of the last row of the page before), limit (50, at
-- most 100), summary ('0': the list only). One bounded read: the dates, then the index, newest first.
create or replace function app.visitor_history(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_today date := app.local_date(now());
  v_oldest date := v_today - greatest(ps.visitor_sessions_keep_days, ps.visitor_events_keep_days);
  v_from date;
  v_to date;
  v_limit integer := least(greatest(coalesce(nullif(p ->> 'limit', '')::integer, 50), 1), 100);
  v_source text := lower(nullif(btrim(left(p ->> 'source', 120)), ''));
  v_landing text := lower(nullif(btrim(left(p ->> 'landing', 300)), ''));
  v_device text := case when p ->> 'device' in ('phone', 'tablet', 'desktop') then p ->> 'device' end;
  v_country text := upper(nullif(btrim(left(p ->> 'country', 2)), ''));
  v_city text := lower(nullif(btrim(left(p ->> 'city', 80)), ''));
  v_kind text := case when p ->> 'visitor' in ('new', 'returning') then p ->> 'visitor' end;
  v_conv text := case when p ->> 'converted' in ('any', 'none', 'request', 'booking', 'signup', 'contact') then p ->> 'converted' end;
  v_contact boolean := coalesce(p ->> 'contact', '') in ('1', 'true');
  v_known boolean := coalesce(p ->> 'known', '') in ('1', 'true');
  v_bots boolean := coalesce(p ->> 'bots', '') in ('1', 'true');
  v_cur_at timestamptz;
  v_cur_id uuid;
  v_rows jsonb;
  v_n integer;
  v_out jsonb;
begin
  perform app.assert_admin(p_by);
  begin
    v_from := nullif(p ->> 'from', '')::date;
    v_to := nullif(p ->> 'to', '')::date;
  exception when others then
    raise exception 'Dates are written YYYY-MM-DD' using errcode = '22007';
  end;
  v_to := least(coalesce(v_to, v_today), v_today);
  v_from := greatest(coalesce(v_from, v_to - 29), v_oldest);
  if v_from > v_to then v_from := v_to; end if;
  if coalesce(p ->> 'cursor', '') ~ '^[0-9T:. +-]{19,40}\|[0-9a-f-]{36}$' then
    v_cur_at := split_part(p ->> 'cursor', '|', 1)::timestamptz;
    v_cur_id := split_part(p ->> 'cursor', '|', 2)::uuid;
  end if;

  select coalesce(jsonb_agg(app.visit_history_row(s) order by s.started_at desc, s.id desc), '[]'::jsonb), count(*) into v_rows, v_n from (
    select s.* from visitor_sessions s
     where s.started_at >= app.local_midnight(v_from) and s.started_at < app.local_midnight(v_to + 1)
       and (v_cur_at is null or (s.started_at, s.id) < (v_cur_at, v_cur_id))
       and (v_bots or s.exclude_reason is null)
       and (v_source is null or strpos(app.visit_source(s), v_source) > 0 or strpos(lower(coalesce(s.utm ->> 'medium', '')), v_source) > 0
            or strpos(lower(coalesce(s.utm ->> 'campaign', '')), v_source) > 0)
       and (v_landing is null or strpos(lower(coalesce(s.landing_path, '')), v_landing) > 0)
       and (v_device is null or s.device = v_device)
       and (v_country is null or s.country = v_country)
       and (v_city is null or strpos(lower(coalesce(s.city, '')), v_city) > 0)
       and (v_kind is null or (v_kind = 'new' and s.visit_number <= 1) or (v_kind = 'returning' and s.visit_number > 1))
       and (v_conv is null or (v_conv = 'any' and s.conversions <> '{}') or (v_conv = 'none' and s.conversions = '{}') or v_conv = any (s.conversions))
       and (not v_contact or s.has_contact)
       and (not v_known or s.renter_id is not null or s.known_email is not null)
     order by s.started_at desc, s.id desc
     limit v_limit + 1) s;

  if v_n > v_limit then
    v_rows := v_rows - v_limit;
    v_out := jsonb_build_object('next', (v_rows -> (v_limit - 1) ->> 'started_at') || '|' || (v_rows -> (v_limit - 1) ->> 'id'));
  else
    v_out := jsonb_build_object('next', null);
  end if;
  v_out := v_out || jsonb_build_object('rows', v_rows, 'from', v_from, 'to', v_to, 'oldest', v_oldest, 'limit', v_limit,
    'keep', jsonb_build_object('visits_days', greatest(ps.visitor_sessions_keep_days, ps.visitor_events_keep_days), 'pages_days', ps.visitor_events_keep_days,
                               'daily_days', ps.visitor_daily_keep_days),
    'filtered', v_source is not null or v_landing is not null or v_device is not null or v_country is not null or v_city is not null
                or v_kind is not null or v_conv is not null or v_contact or v_known or v_bots);
  if coalesce(p ->> 'summary', '1') <> '0' and v_cur_at is null then
    v_out := v_out || jsonb_build_object('summary', app.visitor_history_summary(v_from, v_to));
  end if;
  return v_out;
end $$;

-- The chart and the totals of a range, from the daily rows only (one row a day, whatever the traffic), and the
-- distinct visitors of the range from the visits when the range is 3 months or less.
create or replace function app.visitor_history_summary(p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with d as (select * from visitor_daily where day between p_from and p_to),
  t as (select dim, key, sum(n)::integer as n, row_number() over (partition by dim order by sum(n) desc, key) as r
          from visitor_daily_top where day between p_from and p_to group by dim, key)
  select jsonb_build_object(
    'days', coalesce((select jsonb_agg(jsonb_build_object('day', g::date, 'visits', coalesce(d.visits, 0), 'visitors', coalesce(d.visitors, 0),
                        'converted', coalesce(d.converted, 0), 'page_views', coalesce(d.page_views, 0)) order by g)
                        from generate_series(p_from, p_to, interval '1 day') g left join d on d.day = g::date), '[]'::jsonb),
    'totals', (select jsonb_build_object('visits', coalesce(sum(visits), 0), 'visitor_days', coalesce(sum(visitors), 0), 'new_visits', coalesce(sum(new_visits), 0),
                 'returning_visits', coalesce(sum(returning_visits), 0), 'known_visits', coalesce(sum(known_visits), 0), 'page_views', coalesce(sum(page_views), 0),
                 'bounces', coalesce(sum(bounces), 0), 'seconds', coalesce(sum(seconds), 0), 'converted', coalesce(sum(converted), 0),
                 'requests', coalesce(sum(requests), 0), 'bookings', coalesce(sum(bookings), 0), 'signups', coalesce(sum(signups), 0),
                 'contacts', coalesce(sum(contacts), 0), 'phone', coalesce(sum(phone), 0), 'tablet', coalesce(sum(tablet), 0), 'desktop', coalesce(sum(desktop), 0),
                 'left_out', coalesce(sum(left_out), 0)) from d),
    'visitors', case when p_to - p_from <= 92 then (select count(distinct s.visitor_id) from visitor_sessions s
                   where s.started_at >= app.local_midnight(p_from) and s.started_at < app.local_midnight(p_to + 1) and s.exclude_reason is null) end,
    'computed_at', (select max(computed_at) from d),
    'top', jsonb_build_object(
      'page', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'label', app.path_label(key), 'n', n) order by r) from t where dim = 'page' and r <= 10), '[]'::jsonb),
      'source', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'n', n) order by r) from t where dim = 'source' and r <= 10), '[]'::jsonb),
      'landing', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'label', app.path_label(nullif(key, '(not recorded)')), 'n', n) order by r) from t where dim = 'landing' and r <= 10), '[]'::jsonb),
      'country', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'n', n) order by r) from t where dim = 'country' and r <= 10), '[]'::jsonb)))
$$;

-- One visit in full: its pages in order with the time on each, the other events, the games, chats and forms of the
-- visit, and what it is linked to. Page-level detail is gone after visitor_events_keep_days; the summary stays.
create or replace function app.visitor_visit(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s visitor_sessions;
  v_from timestamptz;
  v_to timestamptz;
begin
  perform app.assert_admin(p_by);
  if coalesce(p ->> 'id', '') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'That visit is no longer kept' using errcode = 'P0002';
  end if;
  select * into s from visitor_sessions where id = (p ->> 'id')::uuid;
  if s.id is null then raise exception 'That visit is no longer kept' using errcode = 'P0002'; end if;
  v_from := s.started_at - interval '1 minute';
  v_to := s.last_seen_at + interval '10 minutes';
  return app.visit_history_row(s) || jsonb_build_object(
    'email', s.known_email, 'identified_by', s.identified_by, 'assigned', (select u.full_name from users u where u.id = s.assigned_to),
    'score', s.score, 'pages_kept', s.last_seen_at > now() - make_interval(days => (app.settings()).visitor_events_keep_days),
    'pages_keep_days', (app.settings()).visitor_events_keep_days,
    'timeline', coalesce((
      select jsonb_agg(jsonb_build_object('at', e.at, 'kind', e.kind, 'path', e.path, 'page', app.path_label(e.path), 'is_page', e.is_page,
               'car', case when e.vehicle_id is not null then app.vehicle_name(e.vehicle_id) end, 'booking_number', e.data ->> 'booking_number',
               'pickup', e.data ->> 'pickup', 'return', e.data ->> 'return', 'detail', app.visitor_event_detail(e.kind, e.data),
               -- the time on a page: until the next page; on the last page, what the page said when it was left, or until
               -- the visit's last sign of life (capped at 2 hours: a tab left open is not reading)
               'seconds', case when e.is_page then least(7200, greatest(0, coalesce(
                            floor(extract(epoch from e.next_at - e.at)),
                            (select l.ms / 1000 from visitor_events l where l.session_id = s.id and l.kind = 'page_leave' and l.at >= e.at and l.ms is not null
                              order by l.at limit 1),
                            floor(extract(epoch from s.last_seen_at - e.at)))))::integer end) order by e.at, e.id)
        from (select x.*, x.kind = any (app.visit_page_kinds()) as is_page,
                     case when x.kind = any (app.visit_page_kinds()) then
                       (select min(y.at) from visitor_events y where y.session_id = s.id and y.kind = any (app.visit_page_kinds()) and (y.at, y.id) > (x.at, x.id)) end as next_at
                from visitor_events x where x.session_id = s.id and x.kind <> 'page_leave' order by x.at, x.id limit 300) e), '[]'::jsonb),
    'games', coalesce((select jsonb_agg(jsonb_build_object('game', g.game, 'at', g.created_at, 'trigger', g.trigger, 'prize', app.game_prize_label(g.prize),
                         'revealed_at', g.revealed_at, 'claimed_at', g.claimed_at,
                         'code', (select pc.code from game_claims c join promo_codes pc on pc.id = c.promo_code_id where c.play_id = g.id)) order by g.created_at)
                         from game_plays g where g.visitor_id = s.visitor_id and (g.session_id = s.id or g.created_at between v_from and v_to)), '[]'::jsonb),
    'chats', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'number', c.number, 'status', c.status, 'at', c.created_at,
                         'messages', (select count(*) from chat_messages m where m.conversation_id = c.id),
                         'first', coalesce((select jsonb_agg(jsonb_build_object('at', m.at, 'sender', m.sender, 'body', left(m.body, 600)) order by m.id)
                                              from (select * from chat_messages m where m.conversation_id = c.id and m.sender <> 'system' order by m.id limit 20) m), '[]'::jsonb))
                         order by c.created_at)
                         from chat_conversations c where c.visitor_id = s.visitor_id and (c.session_id = s.id or c.created_at between v_from and v_to)), '[]'::jsonb),
    'forms', coalesce((select jsonb_agg(jsonb_build_object('form', app.capture_form_label(c.form), 'first_at', c.first_at, 'last_at', c.last_at,
                         'sent', c.done_at is not null, 'done_reason', c.done_reason, 'name', c.name, 'email', c.email, 'phone', c.phone, 'lead_id', c.lead_id,
                         'renter_id', c.renter_id) order by c.first_at)
                         from contact_captures c where c.visitor_id = s.visitor_id and c.first_at between v_from and v_to), '[]'::jsonb),
    'bookings', coalesce((select jsonb_agg(jsonb_build_object('number', b.booking_number, 'status', b.status, 'requested_at', coalesce(b.requested_at, b.created_at),
                            'booked_at', b.booked_at) order by coalesce(b.requested_at, b.created_at))
                            from bookings b where s.renter_id is not null and b.renter_id = s.renter_id and b.booking_type <> 'owner'
                              and (coalesce(b.requested_at, b.created_at) between v_from and v_to or b.booked_at between v_from and v_to)), '[]'::jsonb),
    'renter', case when s.renter_id is not null then (select jsonb_build_object('id', r.id, 'name', r.legal_name) from renters r where r.id = s.renter_id) end,
    'signed_in', s.user_id is not null,
    'other_visits', jsonb_build_object(
      'count', (select count(*) from visitor_sessions o where o.visitor_id = s.visitor_id),
      'recent', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'started_at', o.started_at, 'page_views', o.page_views, 'conversions', to_jsonb(o.conversions))
                                           order by o.started_at desc)
                            from (select * from visitor_sessions o where o.visitor_id = s.visitor_id and o.id <> s.id order by o.started_at desc limit 10) o), '[]'::jsonb)));
end $$;

-- ================================================================ 8. the door: Admins only
create or replace function app.ops0118(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'visitor_history' then return app.visitor_history(p_user, p);
  when 'visitor_visit' then return app.visitor_visit(p_user, p);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0118;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_name in ('visitor_history', 'visitor_visit') then
    if p_call <> 'admin_read' then raise exception 'Visitor history is for Admins' using errcode = '42501'; end if;
    perform app.door_begin(p_user, p_aal);
    return app.ops0118(p_user, p_call, p_name, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre0118(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare
  f record;
  r record;
  g text;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['visit_page_kinds', 'visit_source', 'visit_is_bot', 'visit_summarize', 'visitor_daily_compute',
             'job_visitor_history', 'job_visitor_followups', 'job_visitor_housekeeping', 'visit_history_row', 'visitor_history', 'visitor_history_summary',
             'visitor_visit', 'ops0118'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  -- each renamed function keeps its privileges; the function in its place gets the same
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('door_pre0118', 'door'), ('job_visitor_followups_pre0118', 'job_visitor_followups')) m(old_name, new_name) on m.old_name = p.proname
            where n.nspname = 'app' loop
    execute format('revoke all on function %s from public, anon, authenticated', format('app.%I(%s)', r.new_name, r.args)::regprocedure);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', format('app.%I(%s)', r.new_name, r.args)::regprocedure, g); end if;
    end loop;
  end loop;
end $$;

-- ================================================================ 9. the privacy policy (section 1, retention), flagged for the lawyer
-- The live copy changes only where it still carries our text; an Admin's own edit is left as it is.
update site_content_blocks
   set body = replace(body,
     '| Site visit records (pages, events) | 90 days; daily counts per car without personal information are kept |',
     '| Site visit records (pages, events) | 90 days; daily counts per car without personal information are kept |
| Site visit summaries (date, the site or campaign that sent you, first and last page, device, approximate city, number of pages, whether you sent a request or gave contact details) | 13 months; daily totals without personal information are kept |')
 where block_key = 'legal.privacy' and body like '%| Site visit records (pages, events) | 90 days; daily counts per car without personal information are kept |%'
   and body not like '%| Site visit summaries%';
