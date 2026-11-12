-- Release 41 (2590): reminders for the townhall and the interview calls, and AI interviews that decide by themselves
-- (docs/changes/2026-11-12-r41-reminders.md). The owner, November 12: "Remind everybody about the town hall and about the
-- interviews, including myself, through notifications and the actual staff portal"; "notify me when a new applicant comes
-- through, when an AI interview gets done and when a live call gets booked, but make sure there's no action required other
-- than when an actual interview gets booked. Make the interviews difficult, a pre-screening to the academy."
--
-- A. Townhall reminders (staff alerts, every active staff member and every Admin): the day before at 10:00 Toronto, the
--    morning of at 9:00, an hour before (1068's townhall_soon, as before) and 15 minutes before ("check in now", the join
--    link; not to anyone already checked in). Each step once per person and call (the alert's dedupe key). The frame read
--    townhall_link carries what the portals' townhall card needs: shown from the day before until the call ends, checked
--    in, and the warning for whoever missed the last one.
-- B. Interview call reminders (Admins): the morning of (9:00, the day's calls), an hour before the first call of the day,
--    and 10 minutes before each call with the candidate, the role and the call link (the phone number of a phone call).
--    admin_read interviews_today: the day's calls for Admin Today. Applicants' own reminders are unchanged.
-- C. A live call booked is the only hiring event that needs a person: a staff alert and an Admin To-do (task
--    interview_call, due at the call; done when the call is no longer booked, a new one when it is rebooked).
-- D. AI interviews decide by themselves (app.hiring_ai_auto_decide, every hiring job run): at or over the bar
--    (Program settings hiring_auto_hire_mark, now 80 by default; Hiring > Roles and links > Interview settings) with no
--    knock-out (the screening's or one the AI found) the remote roles are hired with the one-step Hire (1060's auto-hire,
--    now every remote role: the account, the agreement and onboarding, which starts with the academy) and field
--    applicants are invited to book their live call; under the bar the decline email or the Sales referral goes, once
--    (hiring_decisions, dedupe per application). The "waiting for your decision" line is gone; the interviews waiting today
--    are decided by the same rule once, at the end of this migration. New applicant, AI interview done (score and outcome)
--    and auto-hire stay as alerts that need nothing.
-- E. A harder interview: questions on reliability, written English and (Sales) an objection, scored as their own topics;
--    up to 4 probing follow-ups (hiring_ai_followups, now 0 to 6); the AI lists knock-out answers, any of which fails.
-- No applied migration is edited: app.townhall_link, app.job_hiring, app.ai_interview_questions,
-- public.server_ai_interview_scored, app.hiring_read, app.hiring_ai_settings and app.door are wrapped; app.staff_alert,
-- app.hiring_field_to_call and public.server_hire_auto_done are patched; app.hire_auto_mark, public.server_hire_auto_due,
-- app.k_jobs_due, app.ai_interview_topics, app.sa_application and app.sa_interview are replaced. SCHEMA_MARKER 2591 (2591 carries the guide chapters).
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
  if position(p_old in d) = 0 then raise exception '2590: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ settings
alter table program_settings add column if not exists hiring_ai_auto_decide boolean not null default true,
  add column if not exists hiring_ai_harder boolean not null default true;
comment on column program_settings.hiring_ai_harder is 'Hiring (2590): the AI interview adds the reliability question, the typed customer message and (Sales) an objection to answer.';
comment on column program_settings.hiring_ai_auto_decide is 'Hiring (2590): a scored AI interview is decided by itself: at or over hiring_auto_hire_mark with no knock-out, hired (remote roles) or invited to the live call (field); under it, the decline or Sales referral email. Admins are told, never asked.';
update program_settings set hiring_auto_hire_mark = 80 where hiring_auto_hire_mark is null;
alter table program_settings alter column hiring_auto_hire_mark set default 80;
comment on column program_settings.hiring_auto_hire_mark is 'Hiring (1060, 2590): the bar of the AI interview (0 to 100, 80): at or over it with no knock-out the applicant passes (hired, or the live call for field roles); under it, declined or referred to Sales.';
update program_settings set hiring_auto_hire_sales = true where not hiring_auto_hire_sales;
comment on column program_settings.hiring_auto_hire_sales is 'Hiring (1060, 2590): an applicant of a remote role who passes the AI interview is hired with one-step Hire by itself (every remote role since 2590, not only Sales).';

do $$
declare c text;
begin
  for c in select conname from pg_constraint where conrelid = 'program_settings'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%hiring_ai_followups%' loop
    execute format('alter table program_settings drop constraint %I', c);
  end loop;
end $$;
alter table program_settings add constraint program_settings_hiring_ai_followups_check check (hiring_ai_followups between 0 and 6);
alter table program_settings alter column hiring_ai_followups set default 4;
update program_settings set hiring_ai_followups = 4 where hiring_ai_followups < 4;

-- ================================================================ alert rules
insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('townhall_reminder', 'Townhall reminders: the day before, the morning of, 15 minutes before', 'Staff', '{assigned}', 'normal', 'alerts', true, false,
   'Every active staff member and every Admin (2590); the hour before is "The weekly townhall starts in an hour".', 165),
  ('interview_reminder', 'Interview call reminders', 'Hiring', '{admin}', 'normal', 'requests', true, false,
   'The morning of, an hour before the first call of the day, and 10 minutes before each call, with the call link (2590).', 119),
  ('live_call_booked', 'Live call booked (needs you)', 'Hiring', '{admin}', 'normal', 'requests', true, false,
   'An applicant booked a live interview call: the one hiring event that needs a person; also a To-do at the call time (2590).', 110)
on conflict (rule) do update set label = excluded.label, who = excluded.who, wired = true, hint = excluded.hint;
update staff_alert_rules set label = 'New applicant (for your information)', tier = 'normal',
       hint = 'Nothing to do: the AI interview and the decision run by themselves (2590).' where rule = 'application_new';
update staff_alert_rules set label = 'AI interview done: score and outcome (for your information)', wired = true,
       hint = 'The score, the bar and what happened by itself: hired, invited to a live call, referred to Sales or declined (2590).' where rule = 'interview_finished';

-- a reminder to everyone at once is one alert a person, never folded into "N or more alerts" without a push
select pg_temp.patch_fn('app.staff_alert(text, text, uuid, text, text, text, jsonb)'::regprocedure,
  $o$if r.tier <> 'urgent' and p_rule <> 'alert_group' then$o$,
  $n$if r.tier <> 'urgent' and p_rule <> all (array['alert_group', 'townhall_soon', 'townhall_reminder', 'interview_reminder']) then$n$);

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('interview_call', 'admin', 'Interview call booked', 'high', 'none', null,
   'An applicant booked a live interview call (2590): take the call at its time. Done by itself when the call is no longer booked (scored, decided, cancelled or rebooked).')
on conflict (task_type) do nothing;

-- ================================================================ A. townhall reminders
create function app.townhall_people_to_remind() returns setof uuid
language sql stable security definer set search_path = public, app as $$
  select sp.user_id from staff_profiles sp where app.staff_is_member(sp.user_id)
  union select ur.user_id from user_roles ur join users u on u.id = ur.user_id where ur.role = 'admin' and coalesce(u.status, 'active') = 'active'
$$;

create function app.townhall_reminders(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_next timestamptz := app.townhall_next(p_now);
  v_day date;
  v_step text;
  v_title text;
  v_body text;
  v_when text;
  v_link boolean := (app.settings()).townhall_call_url <> '';
  u uuid;
  n integer := 0;
begin
  if v_next is null then return 0; end if;
  v_day := (v_next at time zone 'America/Toronto')::date;
  v_when := to_char(v_next at time zone 'America/Toronto', 'FMHH12:MI am');
  if p_now >= v_next - interval '15 minutes' and p_now < v_next + interval '10 minutes' then
    v_step := 'checkin';
    v_title := 'Townhall: check in now';
    v_body := 'It starts at ' || v_when || ' Toronto time. ' || case when v_link then 'Join from the townhall card or the Join button: that checks you in.' else 'Check in on the townhall card.' end
           || ' Two missed townhalls in a row lock your account.';
  elsif p_now >= ((v_day::timestamp + time '09:00') at time zone 'America/Toronto') and p_now < v_next - interval '60 minutes' then
    v_step := 'morning';
    v_title := 'Townhall today at ' || v_when;
    v_body := 'The weekly townhall is today at ' || v_when || ' Toronto time. Join from the townhall card: that counts as your attendance.';
  elsif p_now >= (((v_day - 1)::timestamp + time '10:00') at time zone 'America/Toronto') and p_now < ((v_day::timestamp + time '09:00') at time zone 'America/Toronto')
        and p_now < v_next - interval '60 minutes' then
    v_step := 'day_before';
    v_title := 'Townhall tomorrow at ' || v_when;
    v_body := 'The weekly townhall is tomorrow, ' || to_char(v_day, 'FMDay') || ', at ' || v_when || ' Toronto time. Add it to your calendar from the townhall card.';
  else
    return 0;
  end if;
  for u in select x from app.townhall_people_to_remind() x loop
    if v_step = 'checkin' and app.townhall_attended(v_next, u) then continue; end if;
    perform app.staff_alert('townhall_reminder', 'user', u, v_step || ':' || to_char(v_next, 'YYYYMMDDHH24MI'), v_title, v_body,
      jsonb_build_object('assigned_to', u, 'path_admin', '/admin/townhall', 'path_staff', case when v_step = 'checkin' and v_link then '/api/townhall-join' else '/staff/townhall' end));
    n := n + 1;
  end loop;
  return n;
end $$;

-- the frame read: what the townhall card shows
alter function app.townhall_link(uuid) rename to townhall_link_pre2590;
create function app.townhall_link(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.townhall_link_pre2590(p_by);
  v_next timestamptz := app.townhall_next(now());
  v_staff boolean := exists (select 1 from staff_profiles sp where sp.user_id = p_by and app.staff_is_member(sp.user_id));
begin
  if v_next is null then return v || jsonb_build_object('card', false); end if;
  return v || jsonb_build_object(
    'card', now() >= ((((v_next at time zone 'America/Toronto')::date - 1)::timestamp) at time zone 'America/Toronto'),
    'ends_at', v_next + make_interval(mins => (app.settings()).townhall_minutes),
    'checked_in', app.townhall_attended(v_next, p_by),
    'missed_last', v_staff and exists (select 1 from townhall_meetings m where p_by = any (m.absent)
                                        and m.meeting_at = (select max(x.meeting_at) from townhall_meetings x where x.meeting_at < v_next)));
end $$;
select pg_temp.copy_grants('app.townhall_link(uuid)'::regprocedure, 'app.townhall_link_pre2590(uuid)'::regprocedure);

-- ================================================================ B. interview call reminders
-- the booked calls of a Toronto day
create function app.interview_calls_of(p_day date) returns table (application_id uuid, starts_at timestamptz, full_name text, role_title text, mode text, link text,
  phone text, booking_seq integer, status text)
language sql stable security definer set search_path = public, app as $$
  select a.id, s.starts_at, a.full_name, coalesce(r.short_title, r.title), d.mode,
         coalesce(nullif(btrim(coalesce(a.meet_url, '')), ''), case when d.mode = 'phone' and nullif(btrim(coalesce(a.phone, '')), '') is not null then 'tel:' || btrim(a.phone) end),
         a.phone, a.booking_seq, a.status
    from job_applications a join interview_slots s on s.id = a.slot_id join interview_days d on d.id = s.day_id join hiring_roles r on r.id = a.role_id
   where a.purged_at is null and a.status in ('booked', 'interviewed', 'no_show') and (s.starts_at at time zone 'America/Toronto')::date = p_day
     and not app.email_is_test(a.email)
   order by s.starts_at, a.full_name
$$;

create function app.interview_reminders(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date := (p_now at time zone 'America/Toronto')::date;
  v_first timestamptz;
  v_count integer;
  v_list text;
  c record;
  n integer := 0;
begin
  select min(x.starts_at), count(*) into v_first, v_count from app.interview_calls_of(v_day) x where x.status = 'booked' and x.starts_at > p_now;
  if v_count > 0 then
    v_list := array_to_string(array(select to_char(x.starts_at at time zone 'America/Toronto', 'FMHH12:MI') || ' ' || x.full_name || ' (' || x.role_title || ')'
                                      from app.interview_calls_of(v_day) x where x.status = 'booked' and x.starts_at > p_now), ', ');
    -- the morning of
    if p_now >= ((v_day::timestamp + time '09:00') at time zone 'America/Toronto') and p_now < v_first - interval '60 minutes' then
      perform app.staff_alert('interview_reminder', 'interview_day', null, 'morning:' || to_char(v_day, 'YYYYMMDD'),
        format('%s interview %s today', v_count, case when v_count = 1 then 'call' else 'calls' end), v_list,
        jsonb_build_object('path_admin', '/admin'));
      n := n + 1;
    end if;
    -- an hour before the first call of the day
    if p_now >= v_first - interval '60 minutes' and p_now < v_first
       and not exists (select 1 from app.interview_calls_of(v_day) x where x.status in ('booked', 'interviewed', 'no_show') and x.starts_at < v_first and x.starts_at >= p_now - interval '12 hours') then
      perform app.staff_alert('interview_reminder', 'interview_day', null, 'first:' || to_char(v_day, 'YYYYMMDD'),
        'Interview calls start at ' || to_char(v_first at time zone 'America/Toronto', 'FMHH12:MI am'), v_list,
        jsonb_build_object('path_admin', '/admin'));
      n := n + 1;
    end if;
  end if;
  -- 10 minutes before each call (the job runs every 5 minutes)
  for c in select * from app.interview_calls_of(v_day) x where x.status = 'booked' and p_now >= x.starts_at - interval '10 minutes' and p_now < x.starts_at + interval '5 minutes' loop
    perform app.staff_alert('interview_reminder', 'hiring_alert', c.application_id, 'call:' || c.booking_seq || ':' || to_char(c.starts_at, 'YYYYMMDDHH24MI'),
      left(format('Interview at %s: %s (%s)', to_char(c.starts_at at time zone 'America/Toronto', 'FMHH12:MI am'), c.full_name, c.role_title), 140),
      case when c.link like 'tel:%' then 'Phone call: ' || c.phone || '.' when c.link is not null then 'Video call: ' || c.link else 'No call link yet: open the candidate.' end,
      jsonb_build_object('path_admin', '/admin/hiring/' || c.application_id) || case when c.mode = 'phone' and c.phone is not null then jsonb_build_object('call', regexp_replace(c.phone, '[^0-9+]', '', 'g')) else '{}'::jsonb end);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Admin Today: the day's calls
create function app.interviews_today(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return coalesce((select jsonb_agg(jsonb_build_object('id', x.application_id, 'starts_at', x.starts_at, 'name', x.full_name, 'role', x.role_title, 'mode', x.mode,
           'link', x.link, 'status', x.status) order by x.starts_at)
    from app.interview_calls_of((now() at time zone 'America/Toronto')::date) x), '[]'::jsonb);
end $$;

-- every 5 minutes: the townhall and interview reminders
create function app.job_staff_reminders(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare a integer := 0; b integer := 0;
begin
  begin a := app.townhall_reminders(p_now); exception when others then raise warning 'townhall reminders: %', sqlerrm; end;
  begin b := app.interview_reminders(p_now); exception when others then raise warning 'interview reminders: %', sqlerrm; end;
  return jsonb_build_object('townhall', a, 'interviews', b);
end $$;
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-staff-reminders', '*/5 * * * *', 'select app.job_staff_reminders()');
  end if;
end $$;

-- ================================================================ C. a live call booked: an alert and a To-do
create function app.sa_live_call_booked() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_at timestamptz;
  v_key text;
  v_role text;
begin
  begin
    if app.email_is_test(new.email) then return null; end if;
    if new.status = 'booked' and new.slot_id is not null then
      select s.starts_at into v_at from interview_slots s where s.id = new.slot_id;
      select coalesce(r.short_title, r.title) into v_role from hiring_roles r where r.id = new.role_id;
      v_key := 'interview_call:' || new.id || ':' || new.booking_seq;
      update tasks set status = 'done', completed_at = now(), completion_note = 'Rebooked'
       where task_type = 'interview_call' and related_id = new.id and status in ('open', 'in_progress', 'waiting') and dedupe_key <> v_key;
      perform app.staff_alert('live_call_booked', 'hiring_alert', new.id, 'booked:' || new.booking_seq,
        left(format('Live call booked: %s (%s)', new.full_name, v_role), 140),
        'On ' || to_char(v_at at time zone 'America/Toronto', 'FMDy FMMon FMDD, FMHH12:MI am') || ' Toronto time. You get a reminder 10 minutes before.',
        jsonb_build_object('path_admin', '/admin/hiring/' || new.id));
      perform app.raise_task(p_type => 'interview_call', p_queue => 'admin', p_priority => 'high',
        p_title => left(format('Interview call with %s (%s), %s', new.full_name, v_role, to_char(v_at at time zone 'America/Toronto', 'FMDy FMHH12:MI am')), 200),
        p_detail => 'Take the call at its time, then score it on the candidate''s page.', p_related_table => 'job_applications', p_related_id => new.id,
        p_due_at => v_at, p_dedupe => v_key);
    elsif old.status = 'booked' and new.status <> 'booked' then
      update tasks set status = 'done', completed_at = now(), completion_note = 'The call is ' || new.status
       where task_type = 'interview_call' and related_id = new.id and status in ('open', 'in_progress', 'waiting');
    end if;
  exception when others then
    raise warning 'live call alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists job_applications_z_live_call_booked on job_applications;
create trigger job_applications_z_live_call_booked after update of status, slot_id on job_applications for each row
  when (new.status is distinct from old.status or new.slot_id is distinct from old.slot_id) execute function app.sa_live_call_booked();

-- a new applicant: for information only
create or replace function app.sa_application() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    if app.email_is_test(new.email) then return null; end if;
    perform app.staff_alert('application_new', 'hiring_alert', new.id, 'new',
      left('New applicant: ' || coalesce(new.full_name, 'someone') || coalesce(' (' || (select coalesce(r.short_title, r.title) from hiring_roles r where r.id = new.role_id) || ')', ''), 140),
      'For your information: the AI interview and the decision run by themselves. Nothing to do.', jsonb_build_object('path_admin', '/admin/hiring/' || new.id));
  exception when others then
    raise warning 'application alert not made: %', sqlerrm;
  end;
  return null;
end $$;

-- ================================================================ D. the AI interview decides
create table if not exists hiring_ai_outcomes (
  application_id uuid primary key references job_applications (id) on delete cascade,
  outcome        text not null check (outcome in ('hire', 'live_call', 'sales', 'decline', 'failed')),
  score          integer,
  mark           integer,
  knockouts      jsonb not null default '[]'::jsonb,
  error          text,
  decided_at     timestamptz not null default now()
);
comment on table hiring_ai_outcomes is 'Hiring (2590): what a scored AI interview decided by itself, once per application: hire (one-step Hire follows), live_call (field), sales or decline (the email sent once), failed (an Admin To-do).';
alter table hiring_ai_outcomes enable row level security;
revoke all on hiring_ai_outcomes from anon, authenticated;
grant all on hiring_ai_outcomes to service_role;
drop policy if exists admin_all on hiring_ai_outcomes;
create policy admin_all on hiring_ai_outcomes for select to authenticated using (app.is_admin());
drop trigger if exists audit_hiring_ai_outcomes on hiring_ai_outcomes;
create trigger audit_hiring_ai_outcomes after insert or update or delete on hiring_ai_outcomes for each row execute function app.audit_row();

-- the bar: Program settings, else the role's pass mark and never under 80
create or replace function app.hire_auto_mark(r hiring_roles) returns integer
language sql stable security definer set search_path = public, app as $$
  select least(coalesce((app.settings()).hiring_auto_hire_mark, greatest(r.pass_mark, 80)), 100)
$$;

create function app.ai_interview_knockouts(i ai_interviews) returns jsonb
language sql immutable as $$
  select case when jsonb_typeof(i.result -> 'knockouts') = 'array' then i.result -> 'knockouts' else '[]'::jsonb end
$$;

-- passes: at or over the bar, no knock-out in the screening or the interview, not a "decline"
create function app.ai_interview_passes(i ai_interviews, a job_applications, r hiring_roles) returns boolean
language sql stable security definer set search_path = public, app as $$
  select i.state = 'scored' and coalesce(i.interview_score, 0) >= app.hire_auto_mark(r) and cardinality(coalesce(a.knockouts, '{}')) = 0
     and jsonb_array_length(app.ai_interview_knockouts(i)) = 0 and coalesce(i.recommendation, '') <> 'decline'
$$;

-- the AI's knock-out answers are kept with its result
alter function public.server_ai_interview_scored(jsonb) rename to server_ai_interview_scored_pre2590;
create function public.server_ai_interview_scored(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := public.server_ai_interview_scored_pre2590(p);
begin
  if coalesce((v ->> 'scored')::boolean, false) then
    update ai_interviews set result = coalesce(result, '{}'::jsonb) || jsonb_build_object('knockouts',
             coalesce((select jsonb_agg(left(btrim(k), 300)) from (select jsonb_array_elements_text(case when jsonb_typeof(p #> '{result,knockouts}') = 'array' then p #> '{result,knockouts}' else '[]'::jsonb end) k limit 8) x
                        where btrim(k) <> ''), '[]'::jsonb))
     where id = (p ->> 'interview_id')::uuid;
  end if;
  return v;
end $$;
select pg_temp.copy_grants('public.server_ai_interview_scored(jsonb)'::regprocedure, 'public.server_ai_interview_scored_pre2590(jsonb)'::regprocedure);

create function app.hiring_ai_auto_decide(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications;
  i ai_interviews;
  r hiring_roles;
  v_actor uuid := app.system_admin();
  v_mark integer;
  v_out text;
  v_err text;
  v_ko jsonb;
  v_name text;
  n integer := 0;
begin
  if not coalesce((app.settings()).hiring_ai_auto_decide, true) then return 0; end if;
  for a in select j.* from job_applications j join ai_interviews x on x.application_id = j.id
            where x.state = 'scored' and j.status = 'interviewed' and j.hired_user_id is null and j.purged_at is null
              and not exists (select 1 from hiring_ai_outcomes o where o.application_id = j.id)
              and not exists (select 1 from hiring_decisions d where d.application_id = j.id)
            order by x.scored_at limit 50 for update of j skip locked loop
    select * into i from ai_interviews where application_id = a.id;
    select * into r from hiring_roles where id = a.role_id;
    v_mark := app.hire_auto_mark(r);
    v_ko := app.ai_interview_knockouts(i) || coalesce(to_jsonb(a.knockouts), '[]'::jsonb);
    v_err := null;
    if app.ai_interview_passes(i, a, r) then
      v_out := case when r.staff_kind = 'field' then 'live_call' else 'hire' end;
    else
      v_out := case when coalesce(i.recommendation, '') = 'sales' and jsonb_array_length(v_ko) = 0 and r.va_function is distinct from 'sales' then 'sales' else 'decline' end;
      begin
        perform app.hiring_decision_set(a.id, v_out, true, null, v_actor);
        perform app.hiring_decision_apply(a.id, v_actor);
      exception when others then
        v_err := sqlerrm;
      end;
      if v_err is not null and v_out = 'sales' then
        v_out := 'decline';
        v_err := null;
        begin
          perform app.hiring_decision_set(a.id, 'decline', true, null, v_actor);
          perform app.hiring_decision_apply(a.id, v_actor);
        exception when others then
          v_err := sqlerrm;
        end;
      end if;
      if v_err is not null then v_out := 'failed'; end if;
    end if;
    insert into hiring_ai_outcomes (application_id, outcome, score, mark, knockouts, error, decided_at)
    values (a.id, v_out, i.interview_score, v_mark, v_ko, left(v_err, 300), p_now) on conflict (application_id) do nothing;
    v_name := coalesce(a.full_name, 'an applicant') || ' (' || coalesce(r.short_title, r.title) || ')';
    if v_out = 'failed' then
      perform app.raise_task(p_type => 'hire_auto_failed', p_queue => 'admin', p_priority => 'high',
        p_title => left(format('The AI interview decision for %s did not go through', a.full_name), 200),
        p_detail => left(coalesce(v_err, 'Unknown error') || '. Decide them from Hiring.', 600),
        p_related_table => 'job_applications', p_related_id => a.id, p_dedupe => 'hire_auto_failed:' || a.id);
    elsif not app.email_is_test(a.email) then
      perform app.staff_alert('interview_finished', 'hiring_alert', a.id, 'auto:' || v_out,
        left(format('AI interview %s of 100: %s', coalesce(i.interview_score::text, '?'), v_name), 140),
        case v_out
          when 'hire' then format('Passed the bar of %s: hired by itself. Onboarding starts with the academy. Nothing to do.', v_mark)
          when 'live_call' then format('Passed the bar of %s: invited to book a live call. You get an alert when it is booked.', v_mark)
          when 'sales' then format('Under the bar of %s: referred to Sales by email. Nothing to do.', v_mark)
          else format('Under the bar of %s%s: the decline email went. Nothing to do.', v_mark, case when jsonb_array_length(v_ko) > 0 then ', or a knock-out answer' else '' end) end,
        jsonb_build_object('path_admin', '/admin/hiring/' || a.id));
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- the interview's own alert is the outcome above (while the AI decides)
create or replace function app.sa_interview() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications;
begin
  begin
    if coalesce((app.settings()).hiring_ai_auto_decide, true) then return null; end if;
    if new.state = 'scored' and old.state is distinct from 'scored' then
      select * into a from job_applications where id = new.application_id;
      if a.id is null or app.email_is_test(a.email) then return null; end if;
      perform app.staff_alert('interview_finished', 'hiring_alert', a.id, 'scored',
        'AI interview scored: ' || coalesce(a.full_name, 'an applicant'),
        format('%s of 100, suggests %s.', coalesce(new.interview_score::text, '?'),
               case new.recommendation when 'live_call' then 'a live call' when 'hire' then 'hiring' when 'decline' then 'declining' when 'sales' then 'Sales' else 'a look' end),
        jsonb_build_object('path_admin', '/admin/hiring'));
    end if;
  exception when others then
    raise warning 'interview alert not made: %', sqlerrm;
  end;
  return null;
end $$;

-- field applicants: the live call follows the same bar
select pg_temp.patch_fn('app.hiring_field_to_call(timestamptz)'::regprocedure,
  'and i.interview_score >= r.pass_mark and cardinality(j.knockouts) = 0',
  'and app.ai_interview_passes(i, j, r)');

-- auto-hire: every remote role whose interview passed (1060 had Sales only)
create or replace function public.server_hire_auto_due(p_limit integer default 3) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('actor', app.system_admin(), 'applications', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'score', i.interview_score, 'mark', app.hire_auto_mark(r),
             'function', case when r.va_function = 'sales' then case when coalesce(r.work_mode, case when r.remote then 'remote' else 'in_person' end) = 'remote' then 'sales_remote' else 'sales_in_person' end
                              else r.va_function::text end))
      from (select a.* from job_applications a join hiring_roles r on r.id = a.role_id join ai_interviews i on i.application_id = a.id
             join hiring_ai_outcomes o on o.application_id = a.id and o.outcome = 'hire'
             where coalesce((app.settings()).hiring_auto_hire_sales, false) and r.va_function is not null and r.staff_kind <> 'field'
               and a.status in ('interviewed', 'invited') and a.hired_user_id is null and a.purged_at is null
               and nullif(btrim(coalesce(a.email, '')), '') is not null
               and not exists (select 1 from hiring_auto_hires h where h.application_id = a.id)
             order by o.decided_at limit greatest(p_limit, 1)) a
      join hiring_roles r on r.id = a.role_id join ai_interviews i on i.application_id = a.id), '[]'::jsonb))
$$;

create or replace function app.k_jobs_due() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'agreements_staff', exists (select 1 from app.staff_agreements_due_rows(1)),
    'hire_auto', coalesce((app.settings()).hiring_auto_hire_sales, false) and exists (select 1 from hiring_ai_outcomes o join job_applications a on a.id = o.application_id
                   where o.outcome = 'hire' and a.hired_user_id is null and a.purged_at is null and a.status in ('interviewed', 'invited')
                   and not exists (select 1 from hiring_auto_hires h where h.application_id = a.id)))
$$;

select pg_temp.patch_fn('public.server_hire_auto_done(uuid, jsonb)'::regprocedure,
  $o$format('Hired by itself: %s (Sales)', a.full_name)$o$,
  $n$format('Hired by itself: %s (%s)', a.full_name, coalesce((select coalesce(r.short_title, r.title) from hiring_roles r where r.id = a.role_id), 'staff'))$n$);

alter function app.job_hiring(timestamptz) rename to job_hiring_pre2590;
create function app.job_hiring(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := app.job_hiring_pre2590(p_now);
begin
  return v || jsonb_build_object('ai_decided', app.hiring_ai_auto_decide(p_now));
end $$;

-- Hiring: the bar and the follow-ups in Interview settings; nothing waits for a decision
alter function app.hiring_ai_settings(uuid, jsonb) rename to hiring_ai_settings_pre2590;
create function app.hiring_ai_settings(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.hiring_ai_settings_pre2590(p_by, p);
  v_mark integer := nullif(p ->> 'pass_mark', '')::int;
  v_fu integer := nullif(p ->> 'followups', '')::int;
begin
  if v_mark is not null and v_mark not between 50 and 100 then raise exception 'The bar is 50 to 100' using errcode = '22023'; end if;
  if v_fu is not null and v_fu not between 0 and 6 then raise exception 'Follow-up questions are 0 to 6' using errcode = '22023'; end if;
  update program_settings set hiring_auto_hire_mark = coalesce(v_mark, hiring_auto_hire_mark), hiring_ai_followups = coalesce(v_fu, hiring_ai_followups),
         hiring_ai_auto_decide = coalesce((p ->> 'auto_decide')::boolean, hiring_ai_auto_decide)
   where id = (app.settings()).id;
  return v || jsonb_build_object('pass_mark', (app.settings()).hiring_auto_hire_mark, 'followups', (app.settings()).hiring_ai_followups,
                                 'auto_decide', (app.settings()).hiring_ai_auto_decide);
end $$;
select pg_temp.copy_grants('app.hiring_ai_settings(uuid, jsonb)'::regprocedure, 'app.hiring_ai_settings_pre2590(uuid, jsonb)'::regprocedure);

alter function app.hiring_read(uuid, jsonb) rename to hiring_read_pre2590;
create function app.hiring_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.hiring_read_pre2590(p_by, p);
  s program_settings := app.settings();
begin
  if v ? 'ai_interviews' then
    v := jsonb_set(v, '{ai_interviews}', (v -> 'ai_interviews') || jsonb_build_object('pass_mark', coalesce(s.hiring_auto_hire_mark, 80), 'followups', s.hiring_ai_followups,
      'auto_decide', s.hiring_ai_auto_decide, 'waiting', case when s.hiring_ai_auto_decide then 0 else coalesce((v #>> '{ai_interviews,waiting}')::int, 0) end,
      'week', coalesce((select jsonb_object_agg(o.outcome, o.n) from (select outcome, count(*) n from hiring_ai_outcomes where decided_at > now() - interval '7 days' group by outcome) o), '{}'::jsonb)));
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.hiring_read(uuid, jsonb)'::regprocedure, 'app.hiring_read_pre2590(uuid, jsonb)'::regprocedure);

-- ================================================================ E. a harder interview: the topics and the questions
create or replace function app.ai_interview_topics() returns jsonb
language sql immutable as $$
  select '[{"key":"internet","label":"Internet and backup","weight":8,"good":"Fiber or cable of 25 Mbps or more, with a backup connection and a power backup, named specifically"},
           {"key":"english","label":"Spoken English","weight":12,"good":"Clear, fluent and easy to follow for North American customers; answers the question asked"},
           {"key":"written","label":"Written English","weight":10,"good":"The typed customer message is correct, polite, short and says exactly what happens next"},
           {"key":"social","label":"Social media skills","weight":3,"good":"Real posting, replies and design work for a business, with an example"},
           {"key":"skills","label":"Skills for the role","weight":15,"good":"Specific tasks, tools and volumes of this kind of work; for Sales, a real objection answered and a close asked for"},
           {"key":"experience","label":"Experience","weight":15,"good":"At least a year of this kind of work for a foreign client, described in detail with numbers"},
           {"key":"understanding","label":"Understanding of the role and of CarmaCars","weight":10,"good":"CarmaCars rents cars in Toronto; a normal shift described correctly; the scenarios handled by the rules, escalating instead of guessing"},
           {"key":"reliability","label":"Reliability","weight":10,"good":"Shows up every shift; a missed or late shift told ahead, owned and fixed; a concrete plan for outages and emergencies"},
           {"key":"hours_pay","label":"Agrees to the hours and the pay","weight":8,"good":"A clear yes to the schedule every week and to the pay"},
           {"key":"other_jobs","label":"Other jobs and clients","weight":4,"good":"This is their main job; nothing during these hours; no other car rental business serving Ontario"},
           {"key":"education","label":"School and education","weight":2,"good":"Education stated; no classes during these hours"},
           {"key":"career","label":"Career or job","weight":3,"good":"Wants a long-term career with one company"},
           {"key":"canada","label":"Moving to Canada","weight":0,"good":"Asked and noted, never scored"}]'::jsonb
$$;

alter function app.ai_interview_questions(uuid) rename to ai_interview_questions_pre2590;
create function app.ai_interview_questions(p_role uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r hiring_roles;
  q jsonb := app.ai_interview_questions_pre2590(p_role);
begin
  select * into r from hiring_roles where id = p_role;
  if r.id is null or not coalesce((app.settings()).hiring_ai_harder, true) then return q; end if;
  if r.va_function = 'sales' then
    q := q || jsonb_build_array(jsonb_build_object('key', 'objection', 'topics', '["skills","understanding"]'::jsonb,
      'text', 'A customer says: "That is more than I saw on Turo, I will think about it." Answer them now, word for word, as you would on the phone, and ask for the booking.'));
  end if;
  return q || jsonb_build_array(
    jsonb_build_object('key', 'reliability', 'topics', '["reliability"]'::jsonb,
      'text', 'Tell me about the last time you missed or were late for a shift you had agreed to. What happened, who did you tell and when, and what did you change after? If it never happened, what would you do if your power went out an hour before your shift?'),
    jsonb_build_object('key', 'written', 'topics', '["written","english"]'::jsonb,
      'text', 'Please type this answer instead of speaking it: write the exact message you would send a customer whose car will be 30 minutes late for pickup.'));
end $$;
select pg_temp.copy_grants('app.ai_interview_questions(uuid)'::regprocedure, 'app.ai_interview_questions_pre2590(uuid)'::regprocedure);

-- the consent and the privacy policy say the score decides (an Admin's own edit of the policy is left as it is)
create or replace function app.ai_interview_consent_text() returns text
language sql immutable as $$
  select 'This interview is recorded on video. We keep a video of each spoken answer (your camera and your voice) or the text you type, a written transcript, and a summary of your answers written by AI (how they match the role, your English and anything to check). The interview is the pre-screen to our training academy: its score decides by itself whether you move on to the academy, are offered another role, or are not hired. Our hiring team can watch, listen to and read your answers, and you can ask a person to review the decision by replying to our email. We delete the videos after 90 days, and everything else 12 months after our decision if you are not hired. Our privacy policy has the details.'
$$;
update site_content_blocks
   set body = replace(replace(body,
     'a person reviews the results before anyone is hired.',
     'the score of the recorded interview decides by itself whether you move on to our training academy; you can ask a person to review any decision.'),
     'A person at CarmaCars reviews the recording and makes every decision;',
     'The interview score decides by itself (the training academy, another role, or not hired); our hiring team can review the recording and you can ask a person to review any decision;')
 where block_key = 'legal.privacy'
   and (body like '%a person reviews the results before anyone is hired.%' or body like '%A person at CarmaCars reviews the recording and makes every decision;%');
update site_content_blocks
   set body = replace(body, 'the AI never hires or declines anyone', 'the decision is automatic and a person reviews it on request')
 where block_key = 'legal.privacy' and body like '%the AI never hires or declines anyone%';

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2590;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('admin_read', 'ops_read') and p_name = 'interviews_today' then
    perform app.door_begin(p_user, p_aal);
    return app.interviews_today(p_user);
  end if;
  return app.door_pre2590(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2590(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['townhall_people_to_remind', 'townhall_reminders', 'townhall_link_pre2590', 'townhall_link',
                    'interview_calls_of', 'interview_reminders', 'interviews_today', 'job_staff_reminders', 'sa_live_call_booked', 'sa_application', 'sa_interview',
                    'ai_interview_knockouts', 'ai_interview_passes', 'hiring_ai_auto_decide', 'hire_auto_mark', 'k_jobs_due', 'job_hiring_pre2590', 'job_hiring',
                    'hiring_ai_settings_pre2590', 'ai_interview_questions_pre2590', 'hiring_read_pre2590', 'door_pre2590'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  execute 'revoke all on function public.server_ai_interview_scored_pre2590(jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.server_ai_interview_scored_pre2590(jsonb) to service_role';
end $$;

-- the AI interviews waiting for a decision today are decided once by the same rule (each email once: hiring_decisions)
select app.hiring_ai_auto_decide(now());
