-- 1061_r35k_clock_partners_unanswered.sql
-- Release 35, part K (docs/changes/2026-11-08-r35-staff-onboarding.md).
--   1. Clock in and out for customer service, Fleet and Finance (27f): from their portal home, like field shifts; the
--      location is never asked for remote work; their hours on their pay page; a timesheet for Finance and Admin (with
--      hours added or voided by hand, with a reason); a reminder to a person not clocked in 15 minutes after their start
--      time (Program settings va_clock_starts: customer service 9:00, Fleet 11:00, Toronto time; va_clock_days Monday to
--      Saturday).
--   2. Finance gets the whole Partners section (27g): rental partners (list, partner pages, cars, rates, invoices) and
--      referral partners (kickbacks, claims, payments), with every action Admin has there. The door lets a Finance staff
--      member through for exactly those reads and actions, as the Admin screens' own checks do for a delegated assistant
--      (app.va_delegate and app.staff_view, 0031 and 0500).
--   3. Unanswered (31): one queue for Admin and customer service of every customer text with no reply and every missed call
--      not called back (Quo); Mark answered; an urgent alert once a conversation waits past unanswered_sla_minutes (15).
--      WhatsApp has no API here: a morning digest line reminds Admin and customer service to check it.
-- No applied migration is edited: app.door is wrapped.
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

alter table program_settings
  add column if not exists va_clock_starts jsonb not null default '{"cs": "09:00", "fleet": "11:00"}'::jsonb check (jsonb_typeof(va_clock_starts) = 'object'),
  add column if not exists va_clock_days integer[] not null default '{1,2,3,4,5,6}',
  add column if not exists unanswered_sla_minutes integer not null default 15 check (unanswered_sla_minutes between 1 and 1440);
comment on column program_settings.va_clock_starts is 'Clock in (1061): the start time (Toronto, HH:MM) of each office function; a person not clocked in 15 minutes after it is reminded. A function left out gets no reminder.';
comment on column program_settings.va_clock_days is 'Clock in (1061): the days with a start time (ISO: 1 Monday to 7 Sunday).';
comment on column program_settings.unanswered_sla_minutes is 'Unanswered (1061): the minutes a customer text or missed call may wait before Admin and customer service are alerted.';

-- ================================================================ 1. clock in and out for the office staff
create table if not exists staff_clock_entries (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references users (id) on delete cascade,
  started_at  timestamptz not null,
  ended_at    timestamptz check (ended_at is null or ended_at > started_at),
  source      text not null default 'clock' check (source in ('clock', 'manual')),
  note        text check (length(note) <= 300),
  voided_at   timestamptz,
  voided_by   uuid references users (id),
  void_reason text check (length(void_reason) <= 300),
  created_by  uuid references users (id),
  created_at  timestamptz not null default now()
);
comment on table staff_clock_entries is 'Clock in and out of customer service, Fleet and Finance staff (1061). Field staff keep field_shifts. Hours added by hand need a reason; a wrong one is voided, never deleted.';
create unique index if not exists staff_clock_one_open on staff_clock_entries (user_id) where ended_at is null and voided_at is null;
create index if not exists staff_clock_user_idx on staff_clock_entries (user_id, started_at desc);
alter table staff_clock_entries enable row level security;
revoke all on staff_clock_entries from anon, authenticated;
grant all on staff_clock_entries to service_role;
drop trigger if exists audit_staff_clock_entries on staff_clock_entries;
create trigger audit_staff_clock_entries after insert or update or delete on staff_clock_entries for each row execute function app.audit_row();

create table if not exists staff_clock_reminders (
  user_id uuid not null references users (id) on delete cascade,
  day     date not null,
  sent_at timestamptz not null default now(),
  primary key (user_id, day)
);
alter table staff_clock_reminders enable row level security;
revoke all on staff_clock_reminders from anon, authenticated;
grant all on staff_clock_reminders to service_role;

create function app.va_clock_is_office(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_va_has(p_user, 'cs', 'fleet', 'finance') and not app.user_is_admin(p_user)
$$;

-- the start time of a person today (the earliest of their functions), or null
create function app.va_clock_start(p_user uuid, p_day date) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select min((p_day + (s.va_clock_starts ->> f)::time) at time zone 'America/Toronto')
    from staff_profiles sp, program_settings s, unnest(sp.functions) f
   where sp.user_id = p_user and f in ('cs', 'fleet', 'finance') and (s.va_clock_starts ->> f) ~ '^\d{1,2}:\d{2}$'
     and extract(isodow from p_day)::int = any (s.va_clock_days)
$$;

create function app.va_clock_minutes(e staff_clock_entries, p_now timestamptz default now()) returns integer
language sql stable as $$ select greatest(0, floor(extract(epoch from (coalesce(e.ended_at, p_now) - e.started_at)) / 60))::int $$;

create function app.va_clock_state(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'open', (select jsonb_build_object('id', e.id, 'started_at', e.started_at, 'minutes', app.va_clock_minutes(e)) from staff_clock_entries e
              where e.user_id = p_user and e.ended_at is null and e.voided_at is null),
    'start_today', app.va_clock_start(p_user, app.today()),
    'today_minutes', coalesce((select sum(app.va_clock_minutes(e)) from staff_clock_entries e where e.user_id = p_user and e.voided_at is null
                                 and app.local_date(e.started_at) = app.today()), 0),
    'week_minutes', coalesce((select sum(app.va_clock_minutes(e)) from staff_clock_entries e where e.user_id = p_user and e.voided_at is null
                                and e.started_at >= date_trunc('week', now() at time zone 'America/Toronto') at time zone 'America/Toronto'), 0),
    'entries', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'started_at', e.started_at, 'ended_at', e.ended_at, 'minutes', app.va_clock_minutes(e),
                           'source', e.source, 'note', e.note) order by e.started_at desc)
                         from (select * from staff_clock_entries e where e.user_id = p_user and e.voided_at is null order by e.started_at desc limit 40) e), '[]'::jsonb))
$$;

create function app.va_clock_in(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.va_clock_is_office(p_user) then raise exception 'Clock in is for customer service, Fleet and Finance staff' using errcode = '42501'; end if;
  if exists (select 1 from staff_clock_entries e where e.user_id = p_user and e.ended_at is null and e.voided_at is null) then
    raise exception 'You are already clocked in' using errcode = '23514';
  end if;
  insert into staff_clock_entries (user_id, started_at, note, created_by) values (p_user, now(), nullif(left(btrim(coalesce(p ->> 'note', '')), 300), ''), p_user);
  return app.va_clock_state(p_user);
end $$;

create function app.va_clock_out(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid;
begin
  update staff_clock_entries set ended_at = greatest(now(), started_at + interval '1 minute'),
         note = coalesce(nullif(left(btrim(coalesce(p ->> 'note', '')), 300), ''), note)
   where user_id = p_user and ended_at is null and voided_at is null returning id into v_id;
  if v_id is null then raise exception 'You are not clocked in' using errcode = '23514'; end if;
  return app.va_clock_state(p_user);
end $$;

-- the timesheet (Finance and Admin): each office staff member's days in a range, and their entries
create function app.va_timesheet(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_from date := coalesce(nullif(p ->> 'from', '')::date, (date_trunc('week', app.today()::timestamp))::date);
  v_to date := coalesce(nullif(p ->> 'to', '')::date, app.today());
begin
  if not app.user_runs_finance(p_by) then raise exception 'The timesheet is for Finance and Admin' using errcode = '42501'; end if;
  if v_to < v_from or v_to - v_from > 62 then raise exception 'Choose up to two months' using errcode = '22023'; end if;
  return jsonb_build_object('from', v_from, 'to', v_to, 'people', coalesce((select jsonb_agg(x order by x ->> 'name') from (
    select jsonb_build_object('user_id', sp.user_id, 'name', coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email), 'functions', to_jsonb(sp.functions),
             'minutes', coalesce((select sum(app.va_clock_minutes(e)) from staff_clock_entries e where e.user_id = sp.user_id and e.voided_at is null
                                    and app.local_date(e.started_at) between v_from and v_to), 0),
             'open', exists (select 1 from staff_clock_entries e where e.user_id = sp.user_id and e.ended_at is null and e.voided_at is null),
             'entries', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'started_at', e.started_at, 'ended_at', e.ended_at, 'minutes', app.va_clock_minutes(e),
                                    'source', e.source, 'note', e.note) order by e.started_at)
                                  from staff_clock_entries e where e.user_id = sp.user_id and e.voided_at is null and app.local_date(e.started_at) between v_from and v_to), '[]'::jsonb)) x
      from staff_profiles sp join users u on u.id = sp.user_id
     where sp.is_active and sp.functions && array['cs', 'fleet', 'finance'] and not app.user_is_admin(sp.user_id)) y), '[]'::jsonb));
end $$;

-- p {user_id, started_at, ended_at, reason} adds hours; p {id, void: true, reason} voids an entry
create function app.va_clock_fix(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_reason text := btrim(coalesce(p ->> 'reason', ''));
  v_user uuid;
  v_from timestamptz := nullif(p ->> 'started_at', '')::timestamptz;
  v_to timestamptz := nullif(p ->> 'ended_at', '')::timestamptz;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Hours are fixed by Finance or an Admin' using errcode = '42501'; end if;
  if length(v_reason) < 3 then raise exception 'Give the reason' using errcode = '22023'; end if;
  if coalesce((p ->> 'void')::boolean, false) then
    update staff_clock_entries set voided_at = now(), voided_by = p_by, void_reason = left(v_reason, 300)
     where id = nullif(p ->> 'id', '')::uuid and voided_at is null returning user_id into v_user;
    if v_user is null then raise exception 'Entry not found' using errcode = 'P0002'; end if;
    return jsonb_build_object('ok', true);
  end if;
  v_user := nullif(p ->> 'user_id', '')::uuid;
  if not exists (select 1 from staff_profiles sp where sp.user_id = v_user and sp.functions && array['cs', 'fleet', 'finance']) then raise exception 'Choose a customer service, Fleet or Finance staff member' using errcode = '22023'; end if;
  if v_from is null or v_to is null or v_to <= v_from or v_to > now() + interval '5 minutes' or v_to - v_from > interval '16 hours' then
    raise exception 'Give a start and an end in the past, at most 16 hours apart' using errcode = '22023';
  end if;
  insert into staff_clock_entries (user_id, started_at, ended_at, source, note, created_by) values (v_user, v_from, v_to, 'manual', left(v_reason, 300), p_by);
  return jsonb_build_object('ok', true);
end $$;

-- every 15 minutes: a person not clocked in 15 minutes after their start time (within 3 hours of it), once a day
create function app.job_va_clock_reminders(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  n integer := 0;
  v_day date := app.local_date(p_now);
begin
  for r in select sp.user_id, app.va_clock_start(sp.user_id, v_day) start_at from staff_profiles sp
            where sp.is_active and sp.functions && array['cs', 'fleet', 'finance'] and app.va_clock_is_office(sp.user_id)
              and not exists (select 1 from staff_clock_reminders x where x.user_id = sp.user_id and x.day = v_day) loop
    if r.start_at is null or p_now < r.start_at + interval '15 minutes' or p_now > r.start_at + interval '3 hours' then continue; end if;
    if exists (select 1 from staff_clock_entries e where e.user_id = r.user_id and e.voided_at is null and (e.ended_at is null or e.started_at >= r.start_at - interval '2 hours')) then continue; end if;
    perform app.staff_alert('staff_clock_reminder', 'user', r.user_id, 'clock:' || v_day, 'You have not clocked in yet',
      format('Your day started at %s. Clock in on your portal home.', to_char(r.start_at at time zone 'America/Toronto', 'FMHH12:MI am')),
      jsonb_build_object('assigned_to', r.user_id, 'path_staff', '/staff'));
    insert into staff_clock_reminders (user_id, day) values (r.user_id, v_day) on conflict do nothing;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ================================================================ 3. unanswered
alter table phone_threads
  add column if not exists answered_mark_at timestamptz,
  add column if not exists answered_mark_by uuid references users (id),
  add column if not exists unanswered_alerted_at timestamptz;
comment on column phone_threads.answered_mark_at is 'Unanswered (1061): marked answered (by another channel, or nothing to answer); the conversation leaves the queue until the customer writes or calls again.';

-- the conversations waiting for us: the last thing from the customer (a text in, or a missed call) is newer than our last
-- text or call out and than Mark answered; customers only (never staff), the last 14 days
create function app.unanswered_rows(p_now timestamptz default now()) returns table (thread_id uuid, waiting_since timestamptz, kind text, preview text)
language sql stable security definer set search_path = public, app as $$
  select t.id, x.at, x.kind, x.preview
    from phone_threads t
    join lateral (select a.started_at at, case when a.kind = 'call' then 'missed_call' else 'text' end kind,
                         case when a.kind = 'call' then coalesce('Voicemail: ' || left(a.voicemail_text, 140), 'Missed call') else left(a.body, 160) end preview
                    from phone_activity a
                   where a.thread_id = t.id and a.direction = 'in' and (a.kind = 'text' or (a.missed and not a.missed_handled))
                   order by a.started_at desc limit 1) x on true
   where t.last_at > p_now - interval '14 days' and t.match_kind <> 'staff' and t.opted_out_at is null
     and x.at > coalesce(t.answered_mark_at, '-infinity'::timestamptz)
     and not exists (select 1 from phone_activity o where o.thread_id = t.id and o.direction = 'out' and o.started_at >= x.at)
$$;

create function app.unanswered_allowed(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$ select app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs') $$;

create function app.unanswered_view(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_sla integer := (app.settings()).unanswered_sla_minutes;
begin
  if not app.unanswered_allowed(p_by) then raise exception 'Unanswered is for customer service and Admin' using errcode = '42501'; end if;
  return jsonb_build_object('sla_minutes', v_sla, 'rows', coalesce((select jsonb_agg(jsonb_build_object('thread_id', u.thread_id, 'waiting_since', u.waiting_since, 'kind', u.kind,
      'preview', u.preview, 'minutes', floor(extract(epoch from now() - u.waiting_since) / 60)::int, 'late', u.waiting_since < now() - make_interval(mins => v_sla),
      'name', coalesce(t.name, (select r.legal_name from renters r where r.id = t.renter_id), 'Unknown caller'), 'number', t.number, 'match', t.match_kind,
      'booking_number', (select b.booking_number from bookings b where b.id = t.booking_id)) order by u.waiting_since)
    from app.unanswered_rows(now()) u join phone_threads t on t.id = u.thread_id), '[]'::jsonb));
end $$;

create function app.unanswered_done(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid := nullif(p ->> 'thread_id', '')::uuid;
begin
  if not app.unanswered_allowed(p_by) then raise exception 'Unanswered is for customer service and Admin' using errcode = '42501'; end if;
  update phone_threads set answered_mark_at = now(), answered_mark_by = p_by where id = v_id;
  if not found then raise exception 'Conversation not found' using errcode = 'P0002'; end if;
  update phone_activity set missed_handled = true where thread_id = v_id and missed and not missed_handled;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'unanswered_marked', 'phone_threads', v_id::text, '{}'::jsonb);
  return jsonb_build_object('ok', true);
end $$;

-- every 5 minutes: an urgent alert per conversation waiting past the time, once per message; the WhatsApp line each morning
create function app.job_unanswered(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  n integer := 0;
  v_sla integer := (app.settings()).unanswered_sla_minutes;
  v_day text := to_char(app.local_date(p_now), 'YYYY-MM-DD');
begin
  for r in select u.*, coalesce(t.name, t.number) who from app.unanswered_rows(p_now) u join phone_threads t on t.id = u.thread_id
            where u.waiting_since < p_now - make_interval(mins => v_sla) and (t.unanswered_alerted_at is null or t.unanswered_alerted_at < u.waiting_since) loop
    perform app.staff_alert('staff_unanswered', 'phone_thread', r.thread_id, 'wait:' || to_char(r.waiting_since, 'YYYYMMDDHH24MI'),
      left(format('%s is waiting for an answer', r.who), 140),
      left(format('%s, %s minutes ago: %s', case r.kind when 'missed_call' then 'Missed call' else 'Text' end, floor(extract(epoch from p_now - r.waiting_since) / 60), coalesce(r.preview, '')), 240),
      jsonb_build_object('path_admin', '/admin/unanswered', 'path_staff', '/staff/unanswered'));
    update phone_threads set unanswered_alerted_at = p_now where id = r.thread_id;
    n := n + 1;
  end loop;
  if extract(hour from p_now at time zone 'America/Toronto') >= 5 then
    insert into staff_digest_items (role, code, digest_slot, line, meta, url, dedupe_key)
    select x.role, 'staff_expiry_watch', 'morning', 'Check WhatsApp: answer every message waiting there (WhatsApp is not in the Unanswered queue)',
           'Every conversation answered', rtrim((app.settings()).notify_base_url, '/') || x.path, 'whatsapp_check:' || x.role || ':' || v_day
      from (values ('admin', '/admin/unanswered'), ('va_cs', '/staff/unanswered')) x(role, path)
    on conflict (dedupe_key) do nothing;
  end if;
  return n;
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-va-clock', '*/15 * * * *', 'select app.job_va_clock_reminders()');
    perform cron.schedule('carmacars-unanswered', '*/5 * * * *', 'select app.job_unanswered()');
  end if;
end $$;

-- ================================================================ 2 and the door
-- the Partners section's reads and actions, as an Admin has them, for Finance
create function app.partner_section_names() returns text[]
language sql immutable as $$
  select array['partners', 'partner', 'partner_save', 'partner_car_save', 'partner_billing_save', 'partner_pricing_save', 'partner_payout_verify',
               'partner_payout_account', 'partner_agreement_facts', 'partner_signup', 'chauffeur_vehicle_save', 'profit_cars', 'referral_partners', 'referral_partner',
               'referral_earnings', 'referral_partner_save', 'referral_partner_decide', 'referral_partner_credit', 'referral_partner_payout', 'referral_partner_link_new',
               'referral_earning_approve', 'referral_earning_reverse', 'partner_invoices', 'partner_invoice_car', 'partner_invoice_pay', 'partner_invoice_send',
               'partner_invoice_void']
$$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1061;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
  v jsonb;
begin
  if p_call = 'ops_read' and p_name in ('va_clock', 'va_timesheet', 'unanswered') or p_call = 'ops_do' and p_name in ('va_clock_in', 'va_clock_out', 'va_clock_fix', 'unanswered_done') then
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'va_clock' then app.va_clock_state(p_user)
      when 'va_clock_in' then app.va_clock_in(p_user, p_)
      when 'va_clock_out' then app.va_clock_out(p_user, p_)
      when 'va_timesheet' then app.va_timesheet(p_user, p_)
      when 'va_clock_fix' then app.va_clock_fix(p_user, p_)
      when 'unanswered' then app.unanswered_view(p_user, p_)
      else app.unanswered_done(p_user, p_) end;
  end if;
  -- Finance in the Partners section: the Admin's reads and actions, delegated for this one call
  if p_name = any (app.partner_section_names()) and p_call in ('admin_read', 'admin_do', 'va_read', 'va_do', 'ops_read', 'ops_do')
     and not app.user_is_admin(p_user) and app.user_va_has(p_user, 'finance') then
    perform app.door_begin(p_user, p_aal);
    perform app.va_delegate(p_user);
    perform app.staff_view(p_user);
    v := app.door_pre1061(p_user, p_aal, case when p_call in ('va_read', 'admin_read') then 'admin_read' when p_call in ('va_do', 'admin_do') then 'admin_do' else p_call end, p_name, p_);
    perform app.staff_view(null);
    perform set_config('app.door_va', '', true);
    return v;
  end if;
  return app.door_pre1061(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1061(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['va_clock_is_office', 'va_clock_start', 'va_clock_minutes', 'va_clock_state', 'va_clock_in', 'va_clock_out',
                    'va_timesheet', 'va_clock_fix', 'job_va_clock_reminders', 'unanswered_rows', 'unanswered_allowed', 'unanswered_view', 'unanswered_done', 'job_unanswered',
                    'partner_section_names', 'door_pre1061'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
