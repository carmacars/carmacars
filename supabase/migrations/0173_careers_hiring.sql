-- 0173_careers_hiring.sql
-- The owner's request of October 26, 2026 (docs/changes/2026-10-26-careers-hiring.md): "get back to every applicant with
-- screening questions for their role, score them against a rubric, give qualified ones a schedule to book a 15 to 20 minute
-- call (all calls on one day), and give me a rubric to fill in during each call with rankings, so the highest ranked are hired."
-- Built into the site (carmacars.ca/careers) instead of Google Forms.
--
-- 1. Roles (hiring_roles): the public description, the screening questions with their points and knock-outs (never sent to a
--    browser: public.hiring_role_public strips them), the pass mark, the call guide and the role a candidate who does not
--    qualify is offered instead (Field staff to Sales in person, with Remote sales named as the other choice; Sales in person
--    to Remote sales; a VA role to the best matching other open role). Seeded and open: Field staff, Sales and Customer
--    Relations (In person, Toronto) and Remote Sales (commission only, worldwide; it replaces the package's commission-only
--    sales VA). Seeded closed until an Admin opens each one: the three hourly VA roles of docs/source/va_hiring_package.md.
--    Sales is split by where the work is done, never by who the candidate is; neither has a right-to-work question.
-- 2. Applications (job_applications): the answers, scored on the server (app.hiring_score). A knock-out gets a polite decline
--    (or the referral), a score at or above the pass mark gets an invitation with a personal booking link, the rest wait for the
--    owner's review ("below the bar": only the confirmation email). Status: new, then declined, below_bar, invited or referred;
--    booked, interviewed, hired, rejected, no_show, withdrawn.
-- 3. Interview days and slots (interview_days, interview_slots): 15-minute slots with a 5-minute buffer, one candidate a slot,
--    by phone (we call the candidate) or video (a Jitsi Meet link per booking); per role or for every role. The candidate books,
--    moves or cancels from their link (no double booking: the slot row is locked); a confirmation, a reminder the evening
--    before and one an hour before (and a text an hour before when phone and texts are on).
-- 4. The interview rubric (interview_scores): six criteria scored 1 to 5 with their weights (100 points), notes and a
--    decision; final score = 40% screening + 60% interview; ranked per role. Hire: the Admin's staff invitation (the web
--    app's existing invite flow) is recorded on the application, then the staff agreement is sent from the same page.
-- 5. Privacy: Admins only (row-level security; the doors). The personal data of a candidate who was not hired is removed
--    12 months after the decision (app.job_hiring, every 15 minutes with the reminders). The privacy policy says so.
-- 6. Admin doors: admin_read 'hiring', 'hiring_application', 'hiring_schedule', 'hiring_shortlist';
--    admin_do 'hiring_invite', 'hiring_decline', 'hiring_withdraw', 'hiring_reject', 'hiring_no_show', 'hiring_score',
--    'hiring_hire', 'hiring_note', 'hiring_role_save', 'hiring_day_save', 'hiring_day_delete'.
-- 7. The emails (audience 'applicant') and the guides.
-- No applied migration is edited. app.door (0167), app.notification_recipients (0165) and app.notification_payload (0165) are
-- wrapped here.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists hiring_sms_reminders boolean not null default true,
  add column if not exists hiring_retention_months integer not null default 12 check (hiring_retention_months between 1 and 84),
  add column if not exists hiring_apply_hourly_limit integer not null default 10 check (hiring_apply_hourly_limit between 1 and 1000);
comment on column program_settings.hiring_sms_reminders is 'Hiring (0173): a text to the candidate an hour before a booked interview call, when phone and texts (Quo) are on.';
comment on column program_settings.hiring_retention_months is 'Hiring (0173): the name, contact details and answers of a candidate who was not hired are removed this many months after the decision (12, as the privacy policy says).';
comment on column program_settings.hiring_apply_hourly_limit is 'Hiring (0173): applications accepted from one connection in an hour.';

-- ================================================================ 2. tables
create table if not exists hiring_roles (
  id               uuid primary key default gen_random_uuid(),
  slug             text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  title            text not null,
  short_title      text not null,
  summary          text not null,
  details          jsonb not null default '{}'::jsonb,       -- about, duties[], requirements[], hours, test_task
  location         text not null,
  remote           boolean not null default false,
  applicant_countries text[] not null default '{}',
  employment_types text[] not null default '{FULL_TIME}',
  pay_text         text not null,
  pay_currency     text,
  pay_min_cents    bigint,
  pay_max_cents    bigint,
  pay_unit         text check (pay_unit is null or pay_unit in ('HOUR', 'MONTH')),
  staff_kind       text not null check (staff_kind in ('field', 'va')),
  va_function      text check (va_function is null or va_function in ('finance', 'fleet', 'cs', 'sales')),
  cover_functions  text[] not null default '{}',
  work_mode        text check (work_mode is null or work_mode in ('in_person', 'remote')),  -- a sales role: where the work is done (0174 may keep it on the staff profile)
  questions        jsonb not null default '[]'::jsonb,       -- server only: points, knock-outs
  pass_mark        integer not null default 60 check (pass_mark between 0 and 100),
  refer_on         text not null default 'never' check (refer_on in ('never', 'below', 'below_or_ko')),
  refer_to         text[] not null default '{}',             -- role slugs, in order of preference
  refer_alt        text,                                     -- a second role the referral email mentions (Field staff: remote sales)
  call_guide       jsonb not null default '{}'::jsonb,       -- steps [[time, text]], questions [[question, good answer]]
  active           boolean not null default false,
  posted_on        date,
  sort_order       integer not null default 0,
  updated_by       uuid references users (id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
comment on table hiring_roles is 'Hiring (0173): a role on carmacars.ca/careers, its screening questions with the points and knock-outs (never sent to a browser), the pass mark, the call guide and the role offered instead to a candidate who does not qualify.';

create table if not exists interview_days (
  id               uuid primary key default gen_random_uuid(),
  day              date not null,
  start_time       time not null,
  end_time         time not null,
  slot_minutes     integer not null default 15 check (slot_minutes between 5 and 120),
  buffer_minutes   integer not null default 5 check (buffer_minutes between 0 and 60),
  capacity         integer not null default 1 check (capacity between 1 and 10),
  mode             text not null default 'phone' check (mode in ('phone', 'video')),
  role_ids         uuid[],                                   -- null: every role
  note             text,
  active           boolean not null default true,
  created_by       uuid references users (id),
  created_at       timestamptz not null default now(),
  check (end_time > start_time)
);
comment on table interview_days is 'Hiring (0173): a day of interview calls (Toronto time): from, to, slot length, buffer, candidates a slot, phone or video, and the roles it is for (all when empty).';

create table if not exists interview_slots (
  id               uuid primary key default gen_random_uuid(),
  day_id           uuid not null references interview_days (id) on delete cascade,
  starts_at        timestamptz not null,
  ends_at          timestamptz not null,
  capacity         integer not null default 1 check (capacity between 1 and 10),
  unique (day_id, starts_at)
);
create index if not exists interview_slots_start_idx on interview_slots (starts_at);

create table if not exists job_applications (
  id               uuid primary key default gen_random_uuid(),
  role_id          uuid not null references hiring_roles (id),
  status           text not null default 'new' check (status in ('new', 'declined', 'below_bar', 'invited', 'referred', 'booked', 'interviewed', 'hired', 'rejected', 'no_show', 'withdrawn')),
  full_name        text not null,
  email            text,
  phone            text,
  profile_name     text,                                    -- the name on their Indeed or OnlineJobs.ph profile, if different
  source           text not null default 'direct' check (source in ('direct', 'indeed', 'onlinejobs', 'referral', 'admin', 'other')),
  utm              jsonb not null default '{}'::jsonb,
  answers          jsonb not null default '{}'::jsonb,
  score            integer check (score between 0 and 100),
  score_points     integer,
  score_max        integer,
  score_detail     jsonb not null default '[]'::jsonb,
  knockouts        text[] not null default '{}',
  ko_reasons       text[] not null default '{}',
  token            text not null unique default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')),
  referred_from    uuid references job_applications (id) on delete set null,
  referred_role_id uuid references hiring_roles (id),
  work_mode        text check (work_mode is null or work_mode in ('in_person', 'remote')),  -- the role's work mode when they applied, passed to the staff invitation on Hire
  slot_id          uuid references interview_slots (id) on delete set null,
  meet_url         text,
  booking_seq      integer not null default 0,
  reminded_evening_at timestamptz,
  reminded_hour_at timestamptz,
  note             text,
  hired_user_id    uuid references users (id) on delete set null,
  created_at       timestamptz not null default now(),
  screened_at      timestamptz,
  invited_at       timestamptz,
  booked_at        timestamptz,
  interviewed_at   timestamptz,
  decided_at       timestamptz,
  decided_by       uuid references users (id) on delete set null,
  purged_at        timestamptz,
  updated_at       timestamptz not null default now()
);
create index if not exists job_applications_role_idx on job_applications (role_id, status);
create index if not exists job_applications_email_idx on job_applications (lower(email));
create index if not exists job_applications_slot_idx on job_applications (slot_id) where slot_id is not null;
comment on table job_applications is 'Hiring (0173): one application to one role: contact details, where it came from, the answers, the score worked out on the server, knock-outs, the status, the booked call. Admins only. Personal data of a candidate not hired is removed after program_settings.hiring_retention_months.';

create table if not exists interview_scores (
  application_id   uuid primary key references job_applications (id) on delete cascade,
  scores           jsonb not null default '{}'::jsonb,     -- {criterion key: 1..5}
  interview_score  integer check (interview_score between 0 and 100),
  final_score      numeric(5, 1),
  notes            text,
  decision         text check (decision is null or decision in ('hire', 'maybe', 'no', 'no_show')),
  interviewer      uuid references users (id) on delete set null,
  updated_at       timestamptz not null default now()
);
comment on table interview_scores is 'Hiring (0173): the interviewer''s rubric for one call: each criterion 1 to 5, the interview score of 100 (weights), the final score (40% screening, 60% interview), notes and the decision.';

do $$
declare t text;
begin
  foreach t in array array['hiring_roles', 'interview_days', 'interview_slots', 'job_applications', 'interview_scores'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('grant select on %I to authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
end $$;

-- ================================================================ 3. scoring (server only)
-- The interview rubric: six criteria, each 1 to 5, weights adding up to 100.
create or replace function app.hiring_criteria() returns jsonb
language sql immutable as $$
  select '[{"key":"communication","label":"Communication","weight":20,"hint":"Clear, polite, easy to follow; answers the question asked"},
           {"key":"reliability","label":"Reliability and availability","weight":20,"hint":"Shows up, keeps commitments, the days and hours we need"},
           {"key":"role_skills","label":"Role skills","weight":20,"hint":"Has done this work: specific tasks, tools, volumes"},
           {"key":"customer","label":"Customer or sales instinct","weight":15,"hint":"Listens, stays calm, finds what the customer needs"},
           {"key":"judgement","label":"Judgement on the scenarios","weight":15,"hint":"Follows the rules, tells the office, never guesses with money or damage"},
           {"key":"attitude","label":"Attitude","weight":10,"hint":"Owns mistakes, wants to learn, fits a small team"}]'::jsonb
$$;

-- The points a question can give (0 for a question that is not scored).
create or replace function app.hiring_question_max(q jsonb) returns integer
language sql immutable as $$
  select case q ->> 'type'
    when 'single' then coalesce((select max((c ->> 'pts')::int) from jsonb_array_elements(q -> 'choices') c), 0)
    when 'multi' then coalesce((q #>> '{score,max}')::int, 0)
    else coalesce((q #>> '{score,pts}')::int, 0) end
$$;

-- Score one set of answers against a role's questions. Returns {points, max, pct, detail[], knockouts[], ko_reasons[], errors{}}.
-- An answer that is missing, not one of the choices or too long is an error (the form shows it); nothing is saved then.
create or replace function app.hiring_score(p_questions jsonb, p_answers jsonb) returns jsonb
language plpgsql immutable as $$
declare
  q jsonb;
  k text;
  t text;
  a jsonb;
  s text;
  sel text[];
  pts integer;
  mx integer;
  v_points integer := 0;
  v_max integer := 0;
  v_detail jsonb := '[]'::jsonb;
  v_ko text[] := '{}';
  v_reasons text[] := '{}';
  v_err jsonb := '{}'::jsonb;
  v_req boolean;
  c jsonb;
  v_each integer;
  v_text text;
begin
  p_answers := coalesce(p_answers, '{}'::jsonb);
  for q in select * from jsonb_array_elements(coalesce(p_questions, '[]'::jsonb)) loop
    k := q ->> 'key'; t := q ->> 'type'; a := p_answers -> k;
    v_req := coalesce((q ->> 'required')::boolean, true);
    mx := app.hiring_question_max(q);
    pts := 0; v_text := null;
    if t = 'single' then
      s := case when jsonb_typeof(a) = 'string' then btrim(a #>> '{}') end;
      if nullif(s, '') is null then
        if v_req then v_err := v_err || jsonb_build_object(k, 'Choose one.'); end if;
      else
        select x into c from jsonb_array_elements(q -> 'choices') x where x ->> 'v' = s;
        if c is null then v_err := v_err || jsonb_build_object(k, 'Choose one of the answers.');
        else
          pts := coalesce((c ->> 'pts')::int, 0); v_text := s;
          if coalesce((c ->> 'ko')::boolean, false) then
            v_ko := v_ko || (coalesce(q ->> 'label', k) || ': ' || s);
            if nullif(q ->> 'ko_reason', '') is not null and not (q ->> 'ko_reason') = any (v_reasons) then v_reasons := v_reasons || (q ->> 'ko_reason'); end if;
          end if;
        end if;
      end if;
    elsif t = 'multi' then
      sel := case when jsonb_typeof(a) = 'array' then array(select btrim(x) from jsonb_array_elements_text(a) x where btrim(x) <> '') else '{}' end;
      if cardinality(sel) = 0 then
        if v_req then v_err := v_err || jsonb_build_object(k, 'Choose at least one.'); end if;
      elsif exists (select 1 from unnest(sel) x where not exists (select 1 from jsonb_array_elements_text(q -> 'choices') y where y = x)) then
        v_err := v_err || jsonb_build_object(k, 'Choose from the list.');
      else
        sel := array(select distinct x from unnest(sel) x);
        v_each := coalesce((q #>> '{score,each}')::int, 0) * (select count(*) from unnest(sel) x where not coalesce(q #> '{score,each_exclude}', '[]'::jsonb) ? x);
        if q #>> '{score,each_cap}' is not null then v_each := least(v_each, (q #>> '{score,each_cap}')::int); end if;
        pts := least(mx, v_each + coalesce((select sum((q #>> array['score', 'bonus', x])::int) from unnest(sel) x where q #> '{score,bonus}' ? x), 0));
        v_text := array_to_string(sel, ', ');
      end if;
    elsif t = 'date' then
      s := case when jsonb_typeof(a) = 'string' then btrim(a #>> '{}') end;
      if nullif(s, '') is null then
        if v_req then v_err := v_err || jsonb_build_object(k, 'Enter a date.'); end if;
      elsif s !~ '^\d{4}-\d{2}-\d{2}$' then v_err := v_err || jsonb_build_object(k, 'Enter a date.');
      else
        begin perform s::date; v_text := s; exception when others then v_err := v_err || jsonb_build_object(k, 'Enter a date.'); end;
      end if;
    else -- text, para
      s := case when jsonb_typeof(a) in ('string', 'number') then btrim(a #>> '{}') end;
      if nullif(s, '') is null then
        if v_req then v_err := v_err || jsonb_build_object(k, 'Please answer this one.'); end if;
      elsif length(s) > (case when t = 'para' then 2000 else 300 end) then
        v_err := v_err || jsonb_build_object(k, case when t = 'para' then 'Keep it under 2,000 characters.' else 'Keep it under 300 characters.' end);
      else
        v_text := s;
        if q -> 'score' is not null then
          if (q #>> '{score,min_words}') is not null and array_length(regexp_split_to_array(s, '\s+'), 1) >= (q #>> '{score,min_words}')::int then pts := mx;
          elsif (q #>> '{score,no_digits}') is not null and s !~ '\d' and s ~ '[A-Za-z]' then pts := mx;
          elsif (q #>> '{score,contains}') is not null and position(upper(q #>> '{score,contains}') in upper(s)) > 0 then pts := mx;
          end if;
        end if;
      end if;
      if q ->> 'ko_unless_contains' is not null and nullif(s, '') is not null and position(upper(q ->> 'ko_unless_contains') in upper(s)) = 0 then
        v_ko := v_ko || (coalesce(q ->> 'label', k) || ': ' || left(s, 60));
        if nullif(q ->> 'ko_reason', '') is not null and not (q ->> 'ko_reason') = any (v_reasons) then v_reasons := v_reasons || (q ->> 'ko_reason'); end if;
      end if;
    end if;
    v_points := v_points + pts; v_max := v_max + mx;
    v_detail := v_detail || jsonb_build_array(jsonb_build_object('key', k, 'label', q ->> 'label', 'answer', v_text, 'points', pts, 'max', mx));
  end loop;
  return jsonb_build_object('points', v_points, 'max', v_max, 'pct', case when v_max > 0 then round(v_points * 100.0 / v_max)::int else 0 end,
    'detail', v_detail, 'knockouts', to_jsonb(v_ko), 'ko_reasons', to_jsonb(v_reasons), 'errors', v_err);
end $$;

-- What a browser may see of a question: the wording and the choices, never the points or the knock-outs.
create or replace function app.hiring_question_public(q jsonb) returns jsonb
language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object('key', q ->> 'key', 'label', q ->> 'label', 'type', q ->> 'type', 'hint', q ->> 'hint',
    'placeholder', q ->> 'placeholder', 'required', coalesce((q ->> 'required')::boolean, true),
    'choices', case when q ->> 'type' = 'single' then (select jsonb_agg(c ->> 'v') from jsonb_array_elements(q -> 'choices') c)
                    when q ->> 'type' = 'multi' then q -> 'choices' end))
$$;

create or replace function app.hiring_interview_score(p_scores jsonb) returns integer
language sql immutable as $$
  select case when count(*) filter (where (p_scores ->> (c ->> 'key')) is not null) = 0 then null
              else round(sum(coalesce((p_scores ->> (c ->> 'key'))::numeric, 0) * (c ->> 'weight')::int) / 5.0)::int end
    from jsonb_array_elements(app.hiring_criteria()) c
$$;

create or replace function app.hiring_final_score(p_screen integer, p_interview integer) returns numeric
language sql immutable as $$
  select case when p_interview is null then null else round(coalesce(p_screen, 0) * 0.4 + p_interview * 0.6, 1) end
$$;

-- ================================================================ 4. the roles (seeded; an Admin opens or closes each one)
create or replace function pg_temp.role(p_slug text, p jsonb) returns void
language plpgsql as $$
begin
  insert into hiring_roles (slug, title, short_title, summary, details, location, remote, applicant_countries, employment_types, pay_text, pay_currency,
                            pay_min_cents, pay_max_cents, pay_unit, staff_kind, va_function, cover_functions, work_mode, questions, pass_mark, refer_on, refer_to,
                            refer_alt, call_guide, active, posted_on, sort_order)
  values (p_slug, p ->> 'title', p ->> 'short_title', p ->> 'summary', p -> 'details', p ->> 'location', coalesce((p ->> 'remote')::boolean, false),
          array(select jsonb_array_elements_text(coalesce(p -> 'applicant_countries', '[]'))),
          array(select jsonb_array_elements_text(p -> 'employment_types')), p ->> 'pay_text', p ->> 'pay_currency',
          (p ->> 'pay_min_cents')::bigint, (p ->> 'pay_max_cents')::bigint, p ->> 'pay_unit', p ->> 'staff_kind', p ->> 'va_function',
          array(select jsonb_array_elements_text(coalesce(p -> 'cover_functions', '[]'))), p ->> 'work_mode', p -> 'questions', 60, coalesce(p ->> 'refer_on', 'never'),
          array(select jsonb_array_elements_text(coalesce(p -> 'refer_to', '[]'))), p ->> 'refer_alt', p -> 'call_guide', coalesce((p ->> 'active')::boolean, false),
          case when coalesce((p ->> 'active')::boolean, false) then app.today() end, (p ->> 'sort_order')::int)
  on conflict (slug) do nothing;
end $$;

-- the opening of every call, and the scenarios shared by the VA roles
create or replace function pg_temp.steps(p_role_q text) returns jsonb
language sql immutable as $$
  select jsonb_build_array(
    jsonb_build_array('0:00 to 1:00', 'Introduce yourself and CarmaCars. Confirm the role, the pay and the schedule they applied for.'),
    jsonb_build_array('1:00 to 4:00', 'Walk me through a normal day (or shift) in your last job. Good: specific tasks, tools and volumes.'),
    jsonb_build_array('4:00 to 6:00', 'Tell me about a mistake that cost money or upset a customer. Good: owns it, reported it the same day, says what changed after.'),
    jsonb_build_array('6:00 to 10:00', p_role_q),
    jsonb_build_array('10:00 to 12:00', 'A customer offers you $40 (or a tip) to skip a fee. Good: refuses and tells the office.'),
    jsonb_build_array('12:00 to 14:00', 'Availability, start date and pay. Confirm the days and hours, weekends included.'),
    jsonb_build_array('14:00 to 15:00', 'Their questions. Next step: we decide within two days and write to everyone.'))
$$;

select pg_temp.role('field-staff', jsonb_build_object(
  'title', 'Field Staff: Driver and Detailer', 'short_title', 'Field staff', 'sort_order', 10, 'active', true,
  'summary', 'Deliver and pick up rental cars across the GTA, hand them over to renters with photos and a checklist, and clean and detail cars between rentals.',
  'details', $j${"about":"CarmaCars is a Toronto car rental company. Our field staff are the people renters meet: you bring the car, walk the renter through it, take it back and get it ready for the next rental.",
    "duties":["Deliver cars to renters and pick them up across Toronto and the GTA","Do every handover in our app: photos, kilometres, fuel, keys and the checklist","Clean and detail cars between rentals, inside and out","Take a cash deposit when the office asks, count it in front of the renter and record it right away","Tell the office at once about damage, delays or anything unusual"],
    "requirements":["A full Ontario G licence and at least two years of driving","A clean driving record","Weekend availability (most rentals start and end on weekends)","Careful, honest and good with people","A smartphone for our field app"],
    "hours":"Full time or part time, weekends included. You choose the days you can work.",
    "test_task":null}$j$::jsonb,
  'location', 'Toronto and the GTA (on site)', 'employment_types', jsonb_build_array('FULL_TIME', 'PART_TIME'),
  'pay_text', 'Hourly, discussed at interview', 'staff_kind', 'field', 'refer_on', 'below_or_ko', 'refer_to', jsonb_build_array('sales-in-person'), 'refer_alt', 'sales-remote',
  'questions', $j$[
    {"key":"licence","label":"Do you hold a full Ontario G licence?","type":"single","ko_reason":"a full Ontario G licence","choices":[{"v":"Yes, a full G","pts":15},{"v":"G2","pts":0,"ko":true},{"v":"A licence from another province or country","pts":0,"ko":true},{"v":"No licence","pts":0,"ko":true}]},
    {"key":"years","label":"How many years have you been driving?","type":"single","ko_reason":"at least two years of driving","choices":[{"v":"Under 2 years","pts":0,"ko":true},{"v":"2 to 4 years","pts":6},{"v":"5 years or more","pts":10}]},
    {"key":"record","label":"Tickets, demerit points or at-fault accidents in the last 3 years?","type":"single","choices":[{"v":"None","pts":10},{"v":"One minor ticket","pts":5},{"v":"More than that","pts":0}]},
    {"key":"days","label":"Which days can you work?","type":"multi","hint":"Choose every day you can work.","choices":["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"],"score":{"each":1,"each_cap":5,"bonus":{"Saturday":5,"Sunday":5},"max":10}},
    {"key":"hours","label":"How many hours a week do you want?","type":"single","choices":[{"v":"Full time (35 or more)","pts":10},{"v":"Part time (15 to 34)","pts":8},{"v":"Weekends only","pts":5},{"v":"Under 15","pts":2}]},
    {"key":"transport","label":"How do you get around the GTA?","type":"single","choices":[{"v":"My own car","pts":10},{"v":"Transit","pts":6},{"v":"Bike or walking","pts":4}]},
    {"key":"experience","label":"Which of these have you done for work?","type":"multi","hint":"Choose all that apply.","required":false,"choices":["Valet or dealership driver","Delivery driver","Uber, Lyft or other rideshare","Car detailing or car wash","Car rental or Turo","Customer service"],"score":{"each":3,"max":10}},
    {"key":"late","label":"A renter arrives 40 minutes late and your next job starts in an hour. What do you do?","type":"single","choices":[{"v":"Wait as long as it takes and miss the next job","pts":0},{"v":"Leave and tell them to rebook","pts":0},{"v":"Message the office at once, keep the renter updated and follow the office's instructions","pts":10}]},
    {"key":"dent","label":"At a return you see a new dent. The renter says it was there before. What do you do?","type":"single","choices":[{"v":"Argue until they admit it","pts":0},{"v":"Ignore it to avoid a fight","pts":0},{"v":"Stay polite, photograph everything, note it in the app and let the office decide","pts":10}]},
    {"key":"cash","label":"A renter pays a $300 deposit in cash. What do you do?","type":"single","choices":[{"v":"Count it in front of them, record it in the app right away and give them the receipt","pts":10},{"v":"Put it in your wallet and record it at the end of the day","pts":0},{"v":"Tell them cash is not allowed","pts":0}]},
    {"key":"start","label":"Earliest start date","type":"date"},
    {"key":"pay","label":"Hourly pay you are looking for (CAD)","type":"text","placeholder":"For example 20"},
    {"key":"other","label":"Anything else we should know?","type":"para","required":false}]$j$::jsonb,
  'call_guide', jsonb_build_object('steps', pg_temp.steps('Two of the field questions below.'), 'questions', $j$[
    ["You are delivering a car and the renter asks you to skip the photos because they are in a rush.","Politely does every photo; it protects the renter too."],
    ["You have two pickups at the same time across the city.","Tells the office at once, never guesses, keeps both renters informed."],
    ["How would you clean a car after a smoker returned it?","Specific steps, flags the cleaning fee, takes photos."]]$j$::jsonb)));

-- Sales is two roles, by where the work is done (in person in Toronto, or remote), never by who the candidate is.
create or replace function pg_temp.sales_tiers(p_low int, p_mid int, p_high int) returns text
language sql immutable as $$ select format('Commission on each rental you source, once it is completed and paid in full: %s%% of the rental charge under 50 rental days in the calendar month, %s%% from 50 days, %s%% from 100 days (the month''s rate applies to all of that month''s rentals; an Admin approves each commission).', p_low, p_mid, p_high) $$;

select pg_temp.role('sales-in-person', jsonb_build_object(
  'title', 'Sales and Customer Relations Coordinator (In person, Toronto)', 'short_title', 'Sales, in person', 'sort_order', 20, 'active', true,
  'summary', 'Turn enquiries into bookings by phone, text, chat and in person in Toronto: walk-ins, handovers and visits to dealership and body shop partners. Commission only, 10% to 20% of each rental you source.',
  'details', jsonb_build_object('about', 'CarmaCars is a Toronto car rental company. You are the voice and face renters meet first: you answer, quote from our rate sheet, follow up, close in person and keep each renter looked after until the car is back.',
    'duties', jsonb_build_array('Answer calls, texts, chats and emails quickly and turn enquiries into bookings', 'Quote from our rate sheet and follow up every quote until it is a yes or a no',
      'Close rentals in person: walk-ins, handovers and renters who want to see the car', 'Visit dealerships and body shops that can send us renters',
      'Look after renters during their rental: extensions, questions, small problems', 'Log every conversation in our system'),
    'requirements', jsonb_build_array('Able to work in person from Toronto (our location and around the GTA)', 'Sales or customer service experience', 'Clear, friendly English; other languages are a plus',
      'Available Thursday to Sunday afternoons (most enquiries come then)', 'You quote only what the rate sheet allows'),
    'hours', 'You choose your hours, in person in Toronto. Most enquiries come Thursday to Sunday afternoons. Independent contractor.',
    'pay_detail', jsonb_build_array('Commission only: no salary and no hourly rate.', pg_temp.sales_tiers(10, 15, 20),
      'Walk-ins, handovers you close and partner deals are yours; rentals that remote sales staff source are theirs.'),
    'test_task', null),
  'location', 'Toronto (in person)', 'employment_types', jsonb_build_array('CONTRACTOR'),
  'pay_text', 'Commission only: 10% to 20% of the rental charge of each rental you source', 'staff_kind', 'va', 'va_function', 'sales', 'work_mode', 'in_person',
  'refer_on', 'below_or_ko', 'refer_to', jsonb_build_array('sales-remote'),
  'questions', $j$[
    {"key":"in_person","label":"Can you work in person from Toronto (our location and around the GTA)?","type":"single","ko_reason":"working in person from Toronto","choices":[{"v":"Yes","pts":10},{"v":"Some days","pts":5},{"v":"No, only remotely","pts":0,"ko":true}]},
    {"key":"years","label":"Years in sales or customer service","type":"single","choices":[{"v":"Under 1 year","pts":0},{"v":"1 to 2 years","pts":5},{"v":"3 to 5 years","pts":8},{"v":"More than 5 years","pts":10}]},
    {"key":"done","label":"Which of these have you done?","type":"multi","hint":"Choose all that apply.","required":false,"choices":["Phone sales","In-person or retail sales","Chat or email support","Car rental, dealership or automotive","Appointment setting","Used a CRM","Commission-based role"],"score":{"each":2,"bonus":{"Car rental, dealership or automotive":2},"max":10}},
    {"key":"commission","label":"The role is commission only: 10% to 20% of the rental charge of each rental you source, with no salary or hourly rate. How do you feel about that?","type":"single","choices":[{"v":"I like being paid for results","pts":10},{"v":"I would prefer some fixed pay","pts":5},{"v":"I only want a fixed wage","pts":0}]},
    {"key":"days","label":"Which days can you work? (Most enquiries come Thursday to Sunday afternoons.)","type":"multi","choices":["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"],"score":{"each":1,"each_cap":2,"bonus":{"Thursday":2,"Friday":2,"Saturday":2,"Sunday":2},"max":10}},
    {"key":"hours","label":"Can you work Thursday to Sunday afternoons?","type":"single","choices":[{"v":"Yes, all of them","pts":10},{"v":"Most of them","pts":6},{"v":"Only some","pts":2},{"v":"No","pts":0}]},
    {"key":"languages","label":"Languages you speak fluently","type":"multi","choices":["English","French","Arabic","Punjabi","Hindi or Urdu","Mandarin or Cantonese","Tagalog","Spanish","Other"],"score":{"each":2,"each_exclude":["English"],"each_cap":5,"bonus":{"English":5},"max":10}},
    {"key":"turo","label":"A customer says \"Turo is cheaper.\" What do you do?","type":"single","choices":[{"v":"Match the Turo price","pts":0},{"v":"Ask what matters most to them, then show what is included (delivery, support, coverage options) and offer only the savings our rate sheet allows","pts":10},{"v":"Tell them to book Turo then","pts":0}]},
    {"key":"discount","label":"A customer asks for 20% off. You are not allowed to give it. What do you say?","type":"single","choices":[{"v":"Give it anyway to close the sale","pts":0},{"v":"Say no and end the chat","pts":0},{"v":"Explain the options we do have (longer rental rates, the non-refundable saving) and ask which works for them","pts":10}]},
    {"key":"toll","label":"A renter is angry about a toll charge after their rental. What do you do?","type":"single","choices":[{"v":"Refund it right away to calm them down","pts":0},{"v":"Listen, show them the toll record, explain the charge, and pass it to the office if they still dispute it","pts":10},{"v":"Tell them it is not your problem","pts":0}]},
    {"key":"why_local","label":"In two or three sentences: why should someone rent from a local company like ours instead of a big chain?","type":"para"},
    {"key":"expect","label":"How many rentals a month do you expect to close after your first month?","type":"text"},
    {"key":"start","label":"Earliest start date","type":"date"},
    {"key":"hours_week","label":"How many hours a week do you plan to work?","type":"text","placeholder":"For example 25"}]$j$::jsonb,
  'call_guide', jsonb_build_object('steps', pg_temp.steps('Two of the sales questions below. Explain the pay: commission only, 10% under 50 rental days a month, 15% from 50, 20% from 100; walk-ins, handovers and partner deals are theirs.'), 'questions', $j$[
    ["Sell me a 7-day rental of a Jetta. I say it is too expensive.","Asks questions, shows value, offers only allowed savings, closes with a clear next step."],
    ["A quote went quiet two days ago. What do you send, and when?","Short, friendly, one question, a deadline that is real."],
    ["You visit a body shop that has never heard of us. What do you say in the first minute?","Short, about their customers' need for a car; leaves a clear next step and a contact."],
    ["A renter wants to drive to Quebec and asks for 15% off.","No promise; checks with the office; keeps the booking."]]$j$::jsonb)));

-- The VA roles (docs/source/va_hiring_package.md): remote, OnlineJobs.ph (?src=onlinejobs), applicants anywhere (mostly the
-- Philippines). Section 4's five application questions as scored questions, the post's hidden instruction as a check, the paid test.
create or replace function pg_temp.va_questions(p_shift text, p_years text, p_tools jsonb, p_scenario jsonb, p_check jsonb, p_rate boolean) returns jsonb
language sql immutable as $$
  select jsonb_build_array(
    jsonb_build_object('key', 'shift', 'label', p_shift, 'type', 'single', 'choices', jsonb_build_array(
      jsonb_build_object('v', 'Yes, every shift, weekends included', 'pts', 15), jsonb_build_object('v', 'Most of them', 'pts', 8), jsonb_build_object('v', 'No', 'pts', 0))),
    jsonb_build_object('key', 'hours_now', 'label', 'What hours do you work now, in Manila time?', 'type', 'text', 'placeholder', 'For example 9 pm to 6 am, Monday to Friday'),
    jsonb_build_object('key', 'backup', 'label', 'What is your backup if the power or internet goes out?', 'type', 'single', 'choices', jsonb_build_array(
      jsonb_build_object('v', 'Backup power and a second internet connection', 'pts', 10), jsonb_build_object('v', 'One of the two', 'pts', 5), jsonb_build_object('v', 'Neither', 'pts', 0))),
    jsonb_build_object('key', 'years', 'label', p_years, 'type', 'single', 'choices', jsonb_build_array(
      jsonb_build_object('v', 'Under 1 year', 'pts', 0), jsonb_build_object('v', '1 to 2 years', 'pts', 5), jsonb_build_object('v', '2 to 4 years', 'pts', 12), jsonb_build_object('v', '5 years or more', 'pts', 15))),
    jsonb_build_object('key', 'tools', 'label', 'Which of these tools have you used for work?', 'type', 'multi', 'hint', 'Choose all that apply.', 'required', false, 'choices', p_tools,
      'score', jsonb_build_object('each', 2, 'max', 10)),
    jsonb_build_object('key', 'tools_detail', 'label', 'Which three tools did you use most in your last role, and what did you do in each?', 'type', 'para'),
    jsonb_build_object('key', 'mistake', 'label', 'Describe one mistake you made with a customer''s money or booking. How was it found, and what did you do?', 'type', 'para',
      'score', jsonb_build_object('min_words', 25, 'pts', 5)),
    jsonb_build_object('key', 'clients', 'label', 'Which clients will you keep alongside us? Is any of them a vehicle rental business?', 'type', 'single', 'ko_reason', 'no work for another car rental business serving Ontario',
      'choices', jsonb_build_array(jsonb_build_object('v', 'No other clients', 'pts', 5), jsonb_build_object('v', 'Other clients, none in vehicle rental', 'pts', 5),
        jsonb_build_object('v', 'A vehicle rental business serving Ontario', 'pts', 0, 'ko', true))),
    jsonb_build_object('key', 'clients_detail', 'label', 'Name the clients you will keep, if any', 'type', 'text', 'required', false),
    p_scenario,
    jsonb_build_object('key', 'tip', 'label', 'A customer offers you a tip to waive a fee. What do you do?', 'type', 'single', 'choices', jsonb_build_array(
      jsonb_build_object('v', 'Accept it if the fee is small', 'pts', 0), jsonb_build_object('v', 'Waive the fee as goodwill and say nothing', 'pts', 0),
      jsonb_build_object('v', 'Refuse it and report it to the office', 'pts', 10))),
    p_check)
  || case when p_rate then jsonb_build_array(jsonb_build_object('key', 'rate', 'label', 'Your rate in US dollars an hour', 'type', 'text', 'placeholder', 'For example 6.00')) else '[]'::jsonb end
  || jsonb_build_array(
    jsonb_build_object('key', 'start', 'label', 'Earliest start date', 'type', 'date'),
    jsonb_build_object('key', 'references', 'label', 'Two clients we may call (name, company, and an email or phone)', 'type', 'para'))
$$;

create or replace function pg_temp.va_steps(p text) returns jsonb
language sql immutable as $$
  select jsonb_build_array(
    jsonb_build_array('0:00 to 1:00', 'Introduce yourself and CarmaCars. Confirm the role, the rate and the shift (Toronto and Manila time).'),
    jsonb_build_array('1:00 to 4:00', 'Walk me through a normal shift in your last role. Good: specific tasks, tools and volumes.'),
    jsonb_build_array('4:00 to 6:00', 'Tell me about a mistake that cost money or a customer. Good: owns it, reported it the same day, says what changed after.'),
    jsonb_build_array('6:00 to 10:00', p),
    jsonb_build_array('10:00 to 12:00', 'A customer offers a tip to waive a fee. Good: refuses and reports it.'),
    jsonb_build_array('12:00 to 14:00', 'How long have you worked Manila nights and weekends? Backup power and internet. Rate and start date. Good: a track record and real backup.'),
    jsonb_build_array('14:00 to 15:00', 'Their questions. Next step: the paid test task, then our decision.'))
$$;

select pg_temp.role('va-customer-service', jsonb_build_object(
  'title', 'Customer Service and Growth Coordinator (Remote)', 'short_title', 'Customer service (VA)', 'sort_order', 30,
  'summary', 'Answer calls, email and WhatsApp within 15 minutes, quote from our rate sheet, send agreements and payment links, and grow our listings and owner network. Remote, 40 hours a week.',
  'details', $j${"about":"CarmaCars is a Toronto car rental company. You are the first reply every renter gets: fast, accurate and friendly, on our portals and phone line.",
    "duties":["Answer calls, email and WhatsApp within 15 minutes","Quote from our rate sheet; send agreements and payment links","Verify licences and coverage before pickup","Handle extensions and cancellations","Post our cars on classified sites and social media, and reach out to car owners who may list with us"],
    "requirements":["Two years of phone and chat support for North American customers","Neutral spoken English","Accurate quoting under time pressure; you follow scripts and never invent a discount","Your own computer, headset, backup internet and power","No work for another car rental business serving Ontario"],
    "hours":"Wednesday to Sunday, 9:00 to 18:00 Toronto time (night in Manila), weekends included. Independent contractor, 30-day paid trial.",
    "test_task":"A one-hour paid test at your rate: reply to three customer enquiries using our rate sheet and procedures. Pass mark 16 out of 20; an invented discount or promise fails the test."}$j$::jsonb,
  'location', 'Remote', 'remote', true, 'applicant_countries', jsonb_build_array('Philippines'), 'employment_types', jsonb_build_array('CONTRACTOR'),
  'pay_text', 'US$5.00 to $6.50 an hour, 40 hours a week', 'pay_currency', 'USD', 'pay_min_cents', 500, 'pay_max_cents', 650, 'pay_unit', 'HOUR',
  'staff_kind', 'va', 'va_function', 'cs', 'refer_on', 'below', 'refer_to', jsonb_build_array('sales-remote', 'va-fleet-operations'),
  'questions', pg_temp.va_questions('This role works Wednesday to Sunday, 9:00 to 18:00 Toronto time (night in Manila). Can you cover this shift, weekends included?',
    'Years of phone and chat support for North American customers',
    '["Zendesk, Freshdesk or another help desk","WhatsApp Business","A CRM (HubSpot, Salesforce or similar)","Google Workspace","A VoIP phone system","Facebook Marketplace or classified sites"]'::jsonb,
    '{"key":"scenario","label":"Three chats and a call arrive together. What do you do?","type":"single","choices":[{"v":"Answer the call and let the chats wait until it ends","pts":0},{"v":"Reply only to the newest chat","pts":0},{"v":"Acknowledge every one inside 15 minutes, use the templates and log each","pts":10}]}'::jsonb,
    '{"key":"post_check","label":"The job post asked you to end your application with something. Which day of the week would you least like to work?","type":"single","choices":[{"v":"Monday","pts":10},{"v":"Tuesday","pts":10},{"v":"Wednesday","pts":10},{"v":"Thursday","pts":10},{"v":"Friday","pts":10},{"v":"Saturday","pts":10},{"v":"Sunday","pts":10},{"v":"I did not see that in the post","pts":0}]}'::jsonb, true),
  'call_guide', jsonb_build_object('steps', pg_temp.va_steps('Two of the customer service questions below.'), 'questions', $j$[
    ["Three chats and a call arrive together.","Acknowledges all inside 15 minutes; uses templates; logs each."],
    ["A renter wants 15% off and to drive to Quebec.","No promise; escalates to Admin; keeps the hold."],
    ["You see a colleague export the customer list.","Reports it within 24 hours."]]$j$::jsonb)));

select pg_temp.role('va-fleet-operations', jsonb_build_object(
  'title', 'Fleet Operations Coordinator (Remote)', 'short_title', 'Fleet operations (VA)', 'sort_order', 40,
  'summary', 'Keep every car on schedule: dispatch field staff, review pickup and return photos within an hour, watch the GPS trackers and handle late returns. Remote, 40 hours a week.',
  'details', $j${"about":"CarmaCars is a Toronto car rental company. You run the day from our portal: who goes where, what the photos show, where each car is.",
    "duties":["Dispatch our field staff for deliveries, returns and cleaning","Review pickup and return photos for damage, kilometres and fuel within an hour","Report findings to billing the same day","Watch the GPS trackers; run the opening and closing checklists","Handle late returns and breakdown calls"],
    "requirements":["Two years in dispatch, logistics or operations for a foreign client","A sharp eye for detail in photos","Calm on the phone in an emergency; clear spoken English","Your own computer with backup internet and power","No work for another car rental business serving Ontario"],
    "hours":"Friday to Tuesday, 8:30 to 18:00 Toronto time (night in Manila), weekends included. Independent contractor, 30-day paid trial.",
    "test_task":"A one-hour paid test at your rate: review a return (pickup and return records side by side) and list each charge or action. Pass mark 16 out of 20."}$j$::jsonb,
  'location', 'Remote', 'remote', true, 'applicant_countries', jsonb_build_array('Philippines'), 'employment_types', jsonb_build_array('CONTRACTOR'),
  'pay_text', 'US$5.00 to $6.50 an hour, 40 hours a week', 'pay_currency', 'USD', 'pay_min_cents', 500, 'pay_max_cents', 650, 'pay_unit', 'HOUR',
  'staff_kind', 'va', 'va_function', 'fleet', 'refer_on', 'below', 'refer_to', jsonb_build_array('va-customer-service'),
  'questions', pg_temp.va_questions('This role works Friday to Tuesday, 8:30 to 18:00 Toronto time (night in Manila). Can you cover this shift, weekends included?',
    'Years in dispatch, logistics or operations for a foreign client',
    '["A dispatch or routing tool","GPS or fleet tracking","Google Sheets or Excel","Photo or damage inspection apps","A ticketing or task system","A VoIP phone system"]'::jsonb,
    '{"key":"scenario","label":"Two pickups today: one driver is not answering and one car''s tracker is offline. What do you do?","type":"single","choices":[{"v":"Release both cars so the renters are not kept waiting","pts":0},{"v":"Cancel both bookings","pts":0},{"v":"Apply the tracker and release rules first, escalate to the office and release nothing unverified","pts":10}]}'::jsonb,
    '{"key":"post_check","label":"The job post asked you to name the tenth photo in any checklist you have used. What is it?","type":"text","score":{"min_words":2,"pts":10}}'::jsonb, true),
  'call_guide', jsonb_build_object('steps', pg_temp.va_steps('Two of the fleet questions below.'), 'questions', $j$[
    ["Two pickups today, one driver silent, one tracker offline.","Tracker and release rules first; escalates; releases nothing unverified."],
    ["How long have you worked Manila nights and weekends?","A track record; real backup for power and internet."],
    ["You see a colleague export the customer list.","Reports it within 24 hours."]]$j$::jsonb)));

select pg_temp.role('va-finance-billing', jsonb_build_object(
  'title', 'Finance and Billing Coordinator (Remote)', 'short_title', 'Finance and billing (VA)', 'sort_order', 50,
  'summary', 'Run our billing: price post-rental charges, release deposits, match tolls to bookings, bill car owners and build owner statements and payouts. Remote, 20 hours a week.',
  'details', $j${"about":"CarmaCars is a Toronto car rental company. Money sits with someone who neither sells nor dispatches: you.",
    "duties":["Price post-rental charges from inspection findings and release deposits","Match tolls and tickets to bookings","Bill car owners on the 15th","Build owner statements and payouts for the 10th","Send a fleet report on the 1st"],
    "requirements":["Two years of bookkeeping or billing for a foreign client","Strong spreadsheets and arithmetic exact to the cent","Clear written English","Your own computer with backup internet and power; a current NBI clearance","No work for another car rental business serving Ontario"],
    "hours":"Monday to Friday, 9:00 to 13:00 Toronto time (night in Manila), plus the 1st, 10th and 15th of each month. Independent contractor, 30-day paid trial.",
    "test_task":"A one-hour paid test at your rate: build one owner's monthly statement from a short set of bookings and fees, using our procedure pages. Pass mark 16 out of 20."}$j$::jsonb,
  'location', 'Remote', 'remote', true, 'applicant_countries', jsonb_build_array('Philippines'), 'employment_types', jsonb_build_array('CONTRACTOR', 'PART_TIME'),
  'pay_text', 'US$6.00 to $8.00 an hour, 20 hours a week', 'pay_currency', 'USD', 'pay_min_cents', 600, 'pay_max_cents', 800, 'pay_unit', 'HOUR',
  'staff_kind', 'va', 'va_function', 'finance', 'refer_on', 'below', 'refer_to', jsonb_build_array('va-fleet-operations'),
  'questions', pg_temp.va_questions('This role works Monday to Friday, 9:00 to 13:00 Toronto time (night in Manila), plus the 1st, 10th and 15th. Can you cover this shift?',
    'Years of bookkeeping or billing for a foreign client',
    '["Excel or Google Sheets (formulas, lookups)","QuickBooks","Xero","Stripe","Bank reconciliation","Wise or PayPal"]'::jsonb,
    '{"key":"scenario","label":"An owner emails new bank details the day before payout. What do you do?","type":"single","choices":[{"v":"Update the details and pay on time","pts":0},{"v":"Hold the payout without telling anyone","pts":0},{"v":"Change nothing, verify by a phone number we already have and wait for written approval","pts":10}]}'::jsonb,
    '{"key":"post_check","label":"The job post asked you to start your subject line with a code word. Type it here.","type":"text","ko_unless_contains":"LEDGER","ko_reason":"the code word from the job post","score":{"contains":"LEDGER","pts":10}}'::jsonb, true),
  'call_guide', jsonb_build_object('steps', pg_temp.va_steps('Two of the finance questions below.'), 'questions', $j$[
    ["An owner emails new bank details the day before payout.","Changes nothing; verifies by a known number; written approval."],
    ["Your statement is $3 out and due in an hour.","Finds the cause; never forces a balance; warns Admin."],
    ["You see a colleague export the customer list.","Reports it within 24 hours."]]$j$::jsonb)));

select pg_temp.role('sales-remote', jsonb_build_object(
  'title', 'Remote Sales Coordinator (Commission only, worldwide)', 'short_title', 'Sales, remote', 'sort_order', 25, 'active', true,
  'summary', 'Work from anywhere: turn enquiries into bookings, follow up every quote and find renters for weeks at a time. Commission only, 5% to 15% of each rental you source. At least 20 hours a week of Thursday to Sunday afternoons, Toronto time.',
  'details', jsonb_build_object('about', 'CarmaCars is a Toronto car rental company. You work remotely and earn on every rental you source, rising with the rental days you close each month.',
    'duties', jsonb_build_array('Cover at least 20 hours a week of Thursday to Sunday afternoons, Toronto time, and reply to every enquiry within 15 minutes',
      'Generate your own leads: repost our cars on Facebook Marketplace and classified sites every day, and reply to social media messages',
      'Follow up every quote three times and chase tentative holds before they expire', 'Reach businesses and long-term renters who need a car for weeks at a time',
      'Log every touch (repost, reply, follow-up, outreach) in our system'),
    'requirements', jsonb_build_array('Two years of sales follow-up or appointment setting by phone and chat for North American customers', 'Confident spoken English; persistence without pressure',
      'You quote only what the rate sheet allows', 'Your own computer, headset, backup internet and power', 'No work for another car rental business serving Ontario'),
    'hours', 'You choose your hours, with at least 20 hours a week inside Thursday to Sunday afternoons, Toronto time (night in Manila). Independent contractor, 30-day trial.',
    'pay_detail', jsonb_build_array('Commission only: no salary and no hourly rate.', pg_temp.sales_tiers(5, 10, 15),
      'Activity minimum: 400 logged touches in a month. Below it, that month''s rate drops one level (15% to 10%, 10% to 5%).',
      'Credit only for rentals you source: website requests you answer on your shift count; walk-ins and partner deals belong to in-person staff.'),
    'test_task', 'A one-hour test for a flat fee agreed before it starts: write a three-message follow-up (WhatsApp, email, call script) for a business quote that went quiet. Pass mark 16 out of 20; a discount outside the rate sheet fails the test.'),
  'location', 'Remote', 'remote', true, 'applicant_countries', jsonb_build_array('Canada', 'United States', 'Philippines'), 'employment_types', jsonb_build_array('CONTRACTOR'),
  'pay_text', 'Commission only: 5% to 15% of the rental charge of each rental you source', 'staff_kind', 'va', 'va_function', 'sales', 'work_mode', 'remote',
  'refer_on', 'below', 'refer_to', jsonb_build_array('va-customer-service'),
  'questions', pg_temp.va_questions('This role needs at least 20 hours a week of Thursday to Sunday afternoons, Toronto time (night in Manila), replying within 15 minutes. Can you cover that?',
    'Years of sales follow-up or appointment setting for North American customers',
    '["A CRM (HubSpot, Salesforce or similar)","WhatsApp Business","Facebook Marketplace or classified sites","Email sequences","A VoIP or dialer","LinkedIn outreach"]'::jsonb,
    '{"key":"scenario","label":"A renter wants 15% off and to drive to Quebec. What do you do?","type":"single","choices":[{"v":"Give the 15% to close the sale","pts":0},{"v":"Refuse and end the chat","pts":0},{"v":"Promise nothing, check with Admin and keep the hold","pts":10}]}'::jsonb,
    '{"key":"post_check","label":"In words, not figures: how many rentals a month do you expect to close?","type":"text","score":{"no_digits":true,"pts":10}}'::jsonb, false)
    || '[{"key":"activity","label":"The role needs at least 400 logged touches a month (reposts, replies, follow-ups, outreach); below that, the month''s commission rate drops one level. Is that workable for you?","type":"single","choices":[{"v":"Yes","pts":10},{"v":"Not sure yet","pts":4},{"v":"No","pts":0}]},
         {"key":"based","label":"Where are you based? (City and country)","type":"text","placeholder":"For example Cebu, Philippines"}]'::jsonb,
  'call_guide', jsonb_build_object('steps', pg_temp.va_steps('Two of the sales questions below. Explain the terms: commission only, 5% under 50 rental days a month, 10% from 50, 15% from 100; 400 logged touches a month or the rate drops one level, credit only for rentals they source.'), 'questions', $j$[
    ["A renter wants 15% off and to drive to Quebec.","No promise; escalates to Admin; keeps the hold."],
    ["A quote went quiet two days ago. What do you send, and when?","Short, friendly, one question, a deadline that is real."],
    ["Walk me through how you would find 10 new leads on a Saturday afternoon.","Specific channels (Marketplace reposts, groups, replies), volumes, logging each touch."],
    ["How long have you worked Manila nights or North American hours?","A track record; real backup for power and internet."]]$j$::jsonb)));

-- ================================================================ 5. interview days and slots
-- (Re)make the slots of a day: from the start, every slot plus buffer, while a slot still ends by the end time. A slot that
-- someone booked is kept even when it no longer fits (the Admin moves that candidate by hand).
create or replace function app.hiring_day_slots(p_day uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  d interview_days;
  v_at timestamptz;
  v_end timestamptz;
  n integer := 0;
begin
  select * into d from interview_days where id = p_day;
  if d.id is null then return 0; end if;
  delete from interview_slots s where s.day_id = d.id and not exists (select 1 from job_applications a where a.slot_id = s.id);
  v_at := app.local_midnight(d.day) + d.start_time::interval;
  v_end := app.local_midnight(d.day) + d.end_time::interval;
  while v_at + make_interval(mins => d.slot_minutes) <= v_end loop
    insert into interview_slots (day_id, starts_at, ends_at, capacity) values (d.id, v_at, v_at + make_interval(mins => d.slot_minutes), d.capacity)
    on conflict (day_id, starts_at) do update set ends_at = excluded.ends_at, capacity = greatest(excluded.capacity, interview_slots.capacity);
    n := n + 1;
    v_at := v_at + make_interval(mins => d.slot_minutes + d.buffer_minutes);
  end loop;
  return n;
end $$;

-- The default day the owner asked for: Thursday, October 29, 2026, 9:00 to 19:00, by phone, for Field staff and Sales. Only
-- while that day is still ahead (a database built later starts with no day).
do $$
declare v_id uuid;
begin
  if app.today() < date '2026-10-29' and not exists (select 1 from interview_days where day = date '2026-10-29') then
    insert into interview_days (day, start_time, end_time, slot_minutes, buffer_minutes, capacity, mode, role_ids, note)
    values (date '2026-10-29', '09:00', '19:00', 15, 5, 1, 'phone',
            array(select id from hiring_roles where slug in ('field-staff', 'sales-in-person')), 'Interview day for the Indeed roles')
    returning id into v_id;
    perform app.hiring_day_slots(v_id);
  end if;
end $$;

-- ================================================================ 6. emails and texts
create or replace function app.hiring_first_name(p text) returns text
language sql immutable as $$ select coalesce(nullif(split_part(btrim(coalesce(p, '')), ' ', 1), ''), 'there') $$;

create or replace function app.hiring_url(p_path text) returns text
language sql stable security definer set search_path = public, app as $$ select (app.settings()).notify_base_url || p_path $$;

-- 'Thursday, October 29' for the days a role's open slots are on (for the invitation)
create or replace function app.hiring_call_days(p_role uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(string_agg(to_char(d.day, 'FMDay, FMMonth FMDD'), ' or ' order by d.day), 'a day that suits you')
    from interview_days d
   where d.active and d.day >= app.today() and (d.role_ids is null or p_role = any (d.role_ids))
     and exists (select 1 from interview_slots s where s.day_id = d.id and s.starts_at > now())
$$;

create or replace function app.hiring_when(p_at timestamptz, p_zone text default 'America/Toronto') returns text
language sql immutable as $$ select to_char(p_at at time zone p_zone, 'FMDay, FMMonth FMDD') || ' at ' || to_char(p_at at time zone p_zone, 'FMHH12:MI am') $$;

create or replace function app.hiring_emit(p_code text, a job_applications, p_extra jsonb default '{}'::jsonb, p_dedupe text default null) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  r hiring_roles;
begin
  if a.email is null then return null; end if;
  select * into r from hiring_roles where id = a.role_id;
  return app.emit_event(p_code, 'job_application', a.id,
    jsonb_build_object('application_id', a.id, 'email', a.email, 'first_name', app.hiring_first_name(a.full_name), 'applicant_name', a.full_name,
      'role_title', r.title, 'role_short_title', r.short_title) || coalesce(p_extra, '{}'::jsonb),
    coalesce(p_dedupe, p_code || ':' || a.id || ':' || extract(epoch from clock_timestamp())::text));
end $$;

-- the invitation's facts: the booking link, the days with open slots, the call length, the paid test of a remote role
create or replace function app.hiring_invite_vars(a job_applications) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('booking_url', app.hiring_url('/careers/book/' || a.token), 'call_days', app.hiring_call_days(r.id),
           'call_minutes', coalesce((select d.slot_minutes from interview_days d where d.active and d.day >= app.today() and (d.role_ids is null or r.id = any (d.role_ids))
                                       order by d.day limit 1), 15)::text,
           'test_task', coalesce(r.details ->> 'test_task', ''))
    from hiring_roles r where r.id = a.role_id
$$;

-- the booking facts every booking email carries
create or replace function app.hiring_booking_vars(a job_applications) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s interview_slots;
  d interview_days;
  r hiring_roles;
begin
  select * into s from interview_slots where id = a.slot_id;
  select * into d from interview_days where id = s.day_id;
  select * into r from hiring_roles where id = a.role_id;
  return jsonb_build_object('call_when', coalesce(app.hiring_when(s.starts_at), ''), 'call_when_manila', case when r.remote then app.hiring_when(s.starts_at, 'Asia/Manila') else '' end,
    'call_minutes', coalesce(d.slot_minutes, 15)::text, 'is_video', d.mode = 'video', 'meet_url', coalesce(a.meet_url, ''), 'phone_display', coalesce(a.phone, ''),
    'manage_url', app.hiring_url('/careers/book/' || a.token));
end $$;

-- ================================================================ 7. applying (the public form, through the server)
create or replace function public.hiring_roles_public() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('slug', r.slug, 'title', r.title, 'short_title', r.short_title, 'summary', r.summary, 'location', r.location,
           'remote', r.remote, 'pay_text', r.pay_text, 'employment_types', to_jsonb(r.employment_types), 'posted_on', r.posted_on) order by r.sort_order, r.title), '[]'::jsonb)
    from hiring_roles r where r.active
$$;

-- One role's public page and form: never the points, the knock-outs or the call guide. An inactive role answers null.
create or replace function public.hiring_role_public(p_slug text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('slug', r.slug, 'title', r.title, 'short_title', r.short_title, 'summary', r.summary, 'details', r.details, 'location', r.location,
           'remote', r.remote, 'applicant_countries', to_jsonb(r.applicant_countries), 'employment_types', to_jsonb(r.employment_types), 'pay_text', r.pay_text,
           'pay_currency', r.pay_currency, 'pay_min_cents', r.pay_min_cents, 'pay_max_cents', r.pay_max_cents, 'pay_unit', r.pay_unit,
           'posted_on', r.posted_on, 'updated_at', r.updated_at,
           'questions', (select coalesce(jsonb_agg(app.hiring_question_public(q)), '[]'::jsonb) from jsonb_array_elements(r.questions) q))
    from hiring_roles r where r.slug = p_slug and r.active
$$;

-- A referral link (/careers/<slug>/apply?ref=<token>): the contact details to fill in, only for the role the candidate was referred to.
create or replace function public.server_hiring_prefill(p_token text, p_slug text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('ok', true, 'full_name', a.full_name, 'email', a.email, 'phone', a.phone, 'from_role', fr.short_title)
    from job_applications a join hiring_roles fr on fr.id = a.role_id join hiring_roles tr on tr.id = a.referred_role_id
   where a.token = p_token and a.status = 'referred' and tr.slug = p_slug and a.purged_at is null
$$;

-- Screen one application (new): knock-out, pass mark, referral; status and the email. Used by the public form and by tests.
create or replace function app.hiring_screen(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications;
  r hiring_roles;
  t hiring_roles;
  alt hiring_roles;
  v_ko boolean;
  v_slug text;
  v_reason text;
begin
  select * into a from job_applications where id = p_id for update;
  select * into r from hiring_roles where id = a.role_id;
  v_ko := cardinality(a.knockouts) > 0;
  if not v_ko and a.score >= r.pass_mark then
    update job_applications set status = 'invited', screened_at = now(), invited_at = now(), updated_at = now() where id = a.id returning * into a;
    perform app.hiring_emit('applicant_invited', a, app.hiring_invite_vars(a), 'applicant_invited:' || a.id || ':1');
    return jsonb_build_object('outcome', 'invited', 'token', a.token);
  end if;
  -- the role offered instead: the first open role on the list the candidate has not applied to
  if r.refer_on = 'below_or_ko' or (r.refer_on = 'below' and not v_ko) then
    foreach v_slug in array r.refer_to loop
      select * into t from hiring_roles where slug = v_slug and active;
      if t.id is not null then exit; end if;
    end loop;
    if t.id is not null then
      if exists (select 1 from job_applications x where x.role_id = t.id and lower(x.email) = lower(a.email) and x.id <> a.id and x.purged_at is null) then
        update job_applications set status = case when v_ko then 'declined' else 'below_bar' end, screened_at = now(), updated_at = now(),
               note = concat_ws(E'\n', note, format('Already applied for %s: no referral sent.', t.short_title)) where id = a.id returning * into a;
        return jsonb_build_object('outcome', 'received');
      end if;
      v_reason := case when v_ko and cardinality(a.ko_reasons) > 0 then 'This role needs ' || array_to_string(a.ko_reasons, ' and ')
                       else 'Your answers did not match what this role needs right now' end;
      update job_applications set status = 'referred', referred_role_id = t.id, screened_at = now(), decided_at = now(), updated_at = now() where id = a.id returning * into a;
      select * into alt from hiring_roles where slug = r.refer_alt and active and id <> t.id;
      perform app.hiring_emit('applicant_referred', a, jsonb_build_object('reason_text', v_reason, 'other_role_title', t.title, 'other_role_summary', t.summary,
        'apply_url', app.hiring_url('/careers/' || t.slug || '/apply?ref=' || a.token || '&src=referral'),
        'alt_role_title', coalesce(alt.title, ''), 'alt_apply_url', case when alt.id is not null then app.hiring_url('/careers/' || alt.slug || '/apply?src=referral') else '' end), 'applicant_referred:' || a.id);
      return jsonb_build_object('outcome', 'referred', 'other_role', t.slug, 'other_title', t.title, 'token', a.token);
    end if;
  end if;
  if v_ko then
    update job_applications set status = 'declined', screened_at = now(), decided_at = now(), updated_at = now() where id = a.id returning * into a;
    perform app.hiring_emit('applicant_declined', a, jsonb_build_object('decline_reason', array_to_string(a.ko_reasons, ' and ')), 'applicant_declined:' || a.id || ':ko');
    return jsonb_build_object('outcome', 'declined');
  end if;
  update job_applications set status = 'below_bar', screened_at = now(), updated_at = now() where id = a.id returning * into a;
  perform app.hiring_emit('applicant_received', a, '{}'::jsonb, 'applicant_received:' || a.id);
  return jsonb_build_object('outcome', 'received');
end $$;

-- The public form (after Turnstile, from the server): p {role, full_name, email, phone, profile_name, source, utm{}, answers{}, ref}.
-- Errors come back as {ok:false, errors{field: message}}; the same address applying twice to one role is answered as the first time.
create or replace function public.server_hiring_apply(p jsonb, p_ip text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_set program_settings := app.settings();
  r hiring_roles;
  v_email text := lower(nullif(btrim(coalesce(p ->> 'email', '')), ''));
  v_name text := nullif(regexp_replace(btrim(coalesce(p ->> 'full_name', '')), '\s+', ' ', 'g'), '');
  v_phone text := nullif(btrim(coalesce(p ->> 'phone', '')), '');
  v_source text := lower(coalesce(nullif(p ->> 'source', ''), 'direct'));
  v_err jsonb := '{}'::jsonb;
  v_sc jsonb;
  v_ref job_applications;
  a job_applications;
  v_out jsonb;
  v_utm jsonb := '{}'::jsonb;
  k text;
begin
  select * into r from hiring_roles where slug = p ->> 'role' and active;
  if r.id is null then return jsonb_build_object('ok', false, 'error', 'closed'); end if;
  if nullif(btrim(p_ip), '') is not null and not app.rate_limit('hire:ip:' || btrim(p_ip), v_set.hiring_apply_hourly_limit, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  if v_name is null or length(v_name) < 2 or length(v_name) > 120 then v_err := v_err || '{"full_name": "Enter your full name."}'; end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 200 then v_err := v_err || '{"email": "Enter a full email address, for example name@example.com."}'; end if;
  if v_phone is null or length(regexp_replace(v_phone, '\D', '', 'g')) not between 7 and 15 then v_err := v_err || '{"phone": "Enter a phone number we can call."}'; end if;
  if v_source not in ('direct', 'indeed', 'onlinejobs', 'referral', 'other') then v_source := 'other'; end if;
  v_sc := app.hiring_score(r.questions, coalesce(p -> 'answers', '{}'::jsonb));
  v_err := v_err || (v_sc -> 'errors');
  if v_err <> '{}'::jsonb then return jsonb_build_object('ok', false, 'error', 'invalid', 'errors', v_err); end if;
  if nullif(p ->> 'ref', '') is not null then
    select * into v_ref from job_applications where token = p ->> 'ref' and status = 'referred' and referred_role_id = r.id;
    if v_ref.id is not null then v_source := 'referral'; end if;
  end if;
  -- the same address for the same role (not withdrawn, not removed): answered the same, nothing new is sent
  select * into a from job_applications where role_id = r.id and lower(email) = v_email and status <> 'withdrawn' and purged_at is null order by created_at desc limit 1;
  if a.id is not null then
    return jsonb_build_object('ok', true, 'outcome', case a.status when 'invited' then 'invited' when 'booked' then 'invited' when 'declined' then 'declined'
      when 'referred' then 'referred' else 'received' end, 'token', case when a.status in ('invited', 'booked') then a.token end, 'repeat', true);
  end if;
  if jsonb_typeof(p -> 'utm') = 'object' then
    foreach k in array array['utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term'] loop
      if nullif(p -> 'utm' ->> k, '') is not null then v_utm := v_utm || jsonb_build_object(k, left(p -> 'utm' ->> k, 100)); end if;
    end loop;
  end if;
  insert into job_applications (role_id, work_mode, full_name, email, phone, profile_name, source, utm, answers, score, score_points, score_max, score_detail, knockouts, ko_reasons, referred_from)
  values (r.id, r.work_mode, left(v_name, 120), v_email, left(v_phone, 40), left(nullif(btrim(coalesce(p ->> 'profile_name', '')), ''), 120), v_source, v_utm,
          (select coalesce(jsonb_object_agg(d ->> 'key', d -> 'answer'), '{}'::jsonb) from jsonb_array_elements(v_sc -> 'detail') d where d ->> 'answer' is not null),
          (v_sc ->> 'pct')::int, (v_sc ->> 'points')::int, (v_sc ->> 'max')::int, v_sc -> 'detail',
          array(select jsonb_array_elements_text(v_sc -> 'knockouts')), array(select jsonb_array_elements_text(v_sc -> 'ko_reasons')), v_ref.id)
  returning * into a;
  v_out := app.hiring_screen(a.id);
  return jsonb_build_object('ok', true) || v_out;
end $$;

-- The booking page: the candidate, the call they booked and the open slots of their role (Toronto time; Manila too for a remote role).
create or replace function public.server_hiring_booking(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  a job_applications;
  r hiring_roles;
  s interview_slots;
  d interview_days;
begin
  select * into a from job_applications where token = p_token and purged_at is null;
  if a.id is null then return jsonb_build_object('ok', false); end if;
  select * into r from hiring_roles where id = a.role_id;
  select * into s from interview_slots where id = a.slot_id;
  select * into d from interview_days where id = s.day_id;
  return jsonb_build_object('ok', true, 'first_name', app.hiring_first_name(a.full_name), 'role_title', r.title, 'remote', r.remote, 'status', a.status,
    'can_book', a.status in ('invited', 'booked'),
    'phone_last', right(regexp_replace(coalesce(a.phone, ''), '\D', '', 'g'), 4),
    'booked', case when s.id is not null and a.status = 'booked' then jsonb_build_object('slot_id', s.id, 'starts_at', s.starts_at, 'ends_at', s.ends_at, 'mode', d.mode, 'meet_url', a.meet_url) end,
    'slots', case when a.status in ('invited', 'booked') then (
      select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'starts_at', x.starts_at, 'ends_at', x.ends_at, 'mode', y.mode, 'day', y.day) order by x.starts_at), '[]'::jsonb)
        from interview_slots x join interview_days y on y.id = x.day_id
       where y.active and (y.role_ids is null or r.id = any (y.role_ids)) and x.starts_at > now() + interval '30 minutes'
         and (x.id = a.slot_id or (select count(*) from job_applications z where z.slot_id = x.id and z.status = 'booked') < x.capacity)) else '[]'::jsonb end);
end $$;

-- Book or move the call. The slot row is locked, so two candidates never take the last place of one slot.
create or replace function public.server_hiring_book(p_token text, p_slot uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$ begin return app.hiring_book(p_token, p_slot); end $$;
create or replace function app.hiring_book(p_token text, p_slot uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications;
  r hiring_roles;
  s interview_slots;
  d interview_days;
  v_taken integer;
  v_moved boolean;
begin
  select * into a from job_applications where token = p_token and purged_at is null for update;
  if a.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if a.status not in ('invited', 'booked') then return jsonb_build_object('ok', false, 'error', 'not_open'); end if;
  select * into r from hiring_roles where id = a.role_id;
  select * into s from interview_slots where id = p_slot for update;
  select * into d from interview_days where id = s.day_id;
  if s.id is null or not d.active or not (d.role_ids is null or r.id = any (d.role_ids)) then return jsonb_build_object('ok', false, 'error', 'no_slot'); end if;
  if s.starts_at <= now() + interval '30 minutes' then return jsonb_build_object('ok', false, 'error', 'too_late'); end if;
  if a.slot_id = s.id and a.status = 'booked' then return jsonb_build_object('ok', true, 'same', true); end if;
  select count(*) into v_taken from job_applications where slot_id = s.id and status = 'booked' and id <> a.id;
  if v_taken >= s.capacity then return jsonb_build_object('ok', false, 'error', 'taken'); end if;
  v_moved := a.status = 'booked';
  update job_applications set slot_id = s.id, status = 'booked', booked_at = now(), booking_seq = booking_seq + 1,
         meet_url = case when d.mode = 'video' then 'https://meet.jit.si/CarmaCars-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 16) end,
         reminded_evening_at = null, reminded_hour_at = null, updated_at = now()
   where id = a.id returning * into a;
  perform app.hiring_emit('applicant_booked', a, app.hiring_booking_vars(a) || jsonb_build_object('rescheduled', v_moved), 'applicant_booked:' || a.id || ':' || a.booking_seq);
  return jsonb_build_object('ok', true, 'starts_at', s.starts_at, 'mode', d.mode, 'meet_url', a.meet_url, 'moved', v_moved);
end $$;

create or replace function public.server_hiring_cancel(p_token text) returns jsonb
language plpgsql security definer set search_path = public, app as $$ begin return app.hiring_cancel(p_token); end $$;
create or replace function app.hiring_cancel(p_token text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications;
begin
  select * into a from job_applications where token = p_token and purged_at is null for update;
  if a.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if a.status <> 'booked' then return jsonb_build_object('ok', false, 'error', 'not_booked'); end if;
  update job_applications set status = 'invited', slot_id = null, meet_url = null, updated_at = now() where id = a.id returning * into a;
  perform app.hiring_emit('applicant_cancelled', a, jsonb_build_object('booking_url', app.hiring_url('/careers/book/' || a.token)), 'applicant_cancelled:' || a.id || ':' || a.booking_seq);
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ 8. the job: reminders and removal of old personal data
create or replace function app.job_hiring(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  a job_applications;
  v_start timestamptz;
  v_eve integer := 0;
  v_hour integer := 0;
  v_purged integer := 0;
begin
  for a in select x.* from job_applications x join interview_slots y on y.id = x.slot_id
            where x.status = 'booked' and y.starts_at > p_now and x.reminded_evening_at is null
              and p_now >= app.local_midnight(app.local_date(y.starts_at) - 1) + interval '18 hours'
              and y.starts_at - p_now > interval '2 hours'
              and x.booked_at < app.local_midnight(app.local_date(y.starts_at) - 1) + interval '18 hours'
            for update of x skip locked loop
    update job_applications set reminded_evening_at = p_now where id = a.id;
    perform app.hiring_emit('applicant_reminder', a, app.hiring_booking_vars(a) || jsonb_build_object('when_text', 'tomorrow'), 'applicant_reminder:' || a.id || ':' || a.booking_seq || ':eve');
    v_eve := v_eve + 1;
  end loop;
  for a in select x.* from job_applications x join interview_slots y on y.id = x.slot_id
            where x.status = 'booked' and y.starts_at > p_now and y.starts_at - p_now <= interval '1 hour' and x.reminded_hour_at is null
              and x.booked_at < y.starts_at - interval '1 hour'
            for update of x skip locked loop
    update job_applications set reminded_hour_at = p_now where id = a.id;
    perform app.hiring_emit('applicant_reminder', a, app.hiring_booking_vars(a) || jsonb_build_object('when_text', 'in about an hour'), 'applicant_reminder:' || a.id || ':' || a.booking_seq || ':hour');
    if s.hiring_sms_reminders and nullif(a.phone, '') is not null then
      select starts_at into v_start from interview_slots where id = a.slot_id;
      begin
        perform app.phone_outbox_put(a.phone, format('CarmaCars: your interview call for %s is at %s Toronto time (in about an hour). %s Change it: %s',
          (select short_title from hiring_roles where id = a.role_id), app.fmt_time(v_start),
          case when a.meet_url is not null then 'Video: ' || a.meet_url || '.' else 'We will call you at this number.' end,
          app.hiring_url('/careers/book/' || a.token)), 'staff', null, null, 'hiring', null, 'hiring_reminder:' || a.id || ':' || a.booking_seq);
      exception when others then null;  -- a number the phone line cannot text: the email still goes
      end;
    end if;
    v_hour := v_hour + 1;
  end loop;
  -- 12 months (by default) after the decision, a candidate who was not hired keeps no name, contact details or answers
  with gone as (
    update job_applications set full_name = 'Removed', email = null, phone = null, profile_name = null, answers = '{}'::jsonb, utm = '{}'::jsonb,
           score_detail = (select coalesce(jsonb_agg(d - 'answer'), '[]'::jsonb) from jsonb_array_elements(score_detail) d), note = null, meet_url = null, purged_at = p_now, updated_at = p_now
     where purged_at is null and status in ('declined', 'below_bar', 'referred', 'rejected', 'no_show', 'withdrawn')
       and coalesce(decided_at, screened_at, created_at) < p_now - make_interval(months => s.hiring_retention_months)
    returning id)
  select count(*) into v_purged from gone;
  update interview_scores set notes = null where application_id in (select id from job_applications where purged_at = p_now);
  return jsonb_build_object('evening', v_eve, 'hour', v_hour, 'purged', v_purged);
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-hiring', '*/15 * * * *', $q$select app.job_hiring()$q$);
  end if;
end $$;

-- ================================================================ 9. Admin
create or replace function app.hiring_app_row(a job_applications) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', a.id, 'role_id', a.role_id, 'role', r.short_title, 'role_slug', r.slug, 'status', a.status, 'full_name', a.full_name, 'email', a.email,
           'phone', a.phone, 'source', a.source, 'score', a.score, 'pass_mark', r.pass_mark, 'knockouts', to_jsonb(a.knockouts), 'created_at', a.created_at,
           'slot_starts_at', s.starts_at, 'mode', d.mode, 'interview_score', sc.interview_score, 'final_score', sc.final_score, 'decision', sc.decision,
           'referred_role', rr.short_title, 'referred_from', a.referred_from, 'note', a.note, 'purged', a.purged_at is not null,
           'referral_application', (select x.id from job_applications x where x.referred_from = a.id order by x.created_at limit 1))
    from hiring_roles r left join interview_slots s on s.id = a.slot_id left join interview_days d on d.id = s.day_id
    left join interview_scores sc on sc.application_id = a.id left join hiring_roles rr on rr.id = a.referred_role_id
   where r.id = a.role_id
$$;

-- the rank of each scored candidate within the role (highest final score first; no-shows and withdrawals are not ranked)
create or replace function app.hiring_ranks(p_role uuid) returns table (application_id uuid, rank bigint)
language sql stable security definer set search_path = public, app as $$
  select a.id, rank() over (order by sc.final_score desc, a.score desc nulls last, a.created_at)
    from job_applications a join interview_scores sc on sc.application_id = a.id
   where a.role_id = p_role and sc.final_score is not null and a.status in ('interviewed', 'hired', 'rejected') and coalesce(sc.decision, '') <> 'no_show'
$$;

create or replace function app.hiring_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_role uuid := (select id from hiring_roles where slug = nullif(p ->> 'role', ''));
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object('today', app.today(), 'phone_enabled', (app.settings()).phone_enabled,
    'roles', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'slug', r.slug, 'title', r.title, 'short_title', r.short_title, 'active', r.active, 'pass_mark', r.pass_mark,
                'pay_text', r.pay_text, 'remote', r.remote, 'staff_kind', r.staff_kind, 'va_function', r.va_function, 'test_task', r.details ->> 'test_task',
                'counts', (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) from (select status, count(*) n from job_applications where role_id = r.id and purged_at is null group by status) c),
                'total', (select count(*) from job_applications where role_id = r.id and purged_at is null)) order by r.sort_order), '[]'::jsonb) from hiring_roles r),
    'applications', (select coalesce(jsonb_agg(app.hiring_app_row(a) || jsonb_build_object('rank', (select k.rank from app.hiring_ranks(a.role_id) k where k.application_id = a.id))
                       order by a.score desc nulls last, a.created_at desc), '[]'::jsonb)
                       from (select * from job_applications x
                              where x.purged_at is null
                                and (v_role is null or x.role_id = v_role)
                                and (nullif(p ->> 'status', '') is null or x.status = p ->> 'status' or (p ->> 'status' = 'open' and x.status in ('below_bar', 'invited', 'booked', 'interviewed')))
                                and (nullif(p ->> 'source', '') is null or x.source = p ->> 'source')
                                and (nullif(p ->> 'min_score', '') is null or x.score >= (p ->> 'min_score')::int)
                              order by x.score desc nulls last, x.created_at desc limit 500) a),
    'days', (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'day', d.day, 'start_time', to_char(d.start_time, 'HH24:MI'), 'end_time', to_char(d.end_time, 'HH24:MI'),
               'slot_minutes', d.slot_minutes, 'buffer_minutes', d.buffer_minutes, 'capacity', d.capacity, 'mode', d.mode, 'active', d.active, 'note', d.note,
               'roles', (select coalesce(jsonb_agg(r.short_title order by r.sort_order), '[]'::jsonb) from hiring_roles r where d.role_ids is null or r.id = any (d.role_ids)),
               'role_slugs', (select coalesce(jsonb_agg(r.slug), '[]'::jsonb) from hiring_roles r where d.role_ids is not null and r.id = any (d.role_ids)),
               'slots', (select count(*) from interview_slots s where s.day_id = d.id),
               'booked', (select count(*) from interview_slots s join job_applications a on a.slot_id = s.id and a.status in ('booked', 'interviewed', 'hired', 'rejected', 'no_show') where s.day_id = d.id))
               order by d.day), '[]'::jsonb) from interview_days d where d.day >= app.today() - 30));
end $$;

create or replace function app.hiring_application_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  a job_applications;
  r hiring_roles;
  sc interview_scores;
begin
  perform app.assert_admin(p_by);
  select * into a from job_applications where id = (p ->> 'id')::uuid;
  if a.id is null then raise exception 'Application not found' using errcode = 'P0002'; end if;
  select * into r from hiring_roles where id = a.role_id;
  select * into sc from interview_scores where application_id = a.id;
  return jsonb_build_object('application', app.hiring_app_row(a) || jsonb_build_object('profile_name', a.profile_name, 'utm', a.utm, 'score_points', a.score_points, 'score_max', a.score_max,
             'ko_reasons', to_jsonb(a.ko_reasons), 'screened_at', a.screened_at, 'invited_at', a.invited_at, 'booked_at', a.booked_at, 'interviewed_at', a.interviewed_at,
             'decided_at', a.decided_at, 'hired_user_id', a.hired_user_id, 'meet_url', a.meet_url, 'booking_url', app.hiring_url('/careers/book/' || a.token),
             'rank', (select k.rank from app.hiring_ranks(a.role_id) k where k.application_id = a.id)),
    'role', jsonb_build_object('id', r.id, 'slug', r.slug, 'title', r.title, 'short_title', r.short_title, 'pass_mark', r.pass_mark, 'staff_kind', r.staff_kind,
             'va_function', r.va_function, 'cover_functions', to_jsonb(r.cover_functions), 'work_mode', coalesce(a.work_mode, r.work_mode), 'remote', r.remote, 'call_guide', r.call_guide, 'test_task', r.details ->> 'test_task'),
    'breakdown', a.score_detail,
    'criteria', app.hiring_criteria(),
    'score', case when sc.application_id is not null then jsonb_build_object('scores', sc.scores, 'interview_score', sc.interview_score, 'final_score', sc.final_score,
             'notes', sc.notes, 'decision', sc.decision, 'interviewer', (select full_name from users where id = sc.interviewer), 'updated_at', sc.updated_at) end,
    'linked', (select coalesce(jsonb_agg(app.hiring_app_row(x) order by x.created_at), '[]'::jsonb) from job_applications x
                where x.id <> a.id and (x.id = a.referred_from or x.referred_from = a.id or (a.email is not null and lower(x.email) = lower(a.email)))),
    'phone_enabled', (app.settings()).phone_enabled);
end $$;

-- the calls of one day (Toronto), in order, with the rubric state
create or replace function app.hiring_schedule_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_day date := coalesce(nullif(p ->> 'day', '')::date,
    (select min(d.day) from interview_days d join interview_slots s on s.day_id = d.id join job_applications a on a.slot_id = s.id where d.day >= app.today()), app.today());
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object('day', v_day, 'today', app.today(), 'phone_enabled', (app.settings()).phone_enabled,
    'days', (select coalesce(jsonb_agg(distinct d.day), '[]'::jsonb) from interview_days d where d.day >= app.today() - 7),
    'calls', (select coalesce(jsonb_agg(app.hiring_app_row(a) || jsonb_build_object('ends_at', s.ends_at, 'meet_url', a.meet_url) order by s.starts_at), '[]'::jsonb)
                from job_applications a join interview_slots s on s.id = a.slot_id join interview_days d on d.id = s.day_id
               where d.day = v_day and a.status in ('booked', 'interviewed', 'hired', 'rejected', 'no_show')),
    'free', (select count(*) from interview_slots s join interview_days d on d.id = s.day_id
              where d.day = v_day and d.active and (select count(*) from job_applications a where a.slot_id = s.id and a.status = 'booked') < s.capacity and s.starts_at > now()));
end $$;

create or replace function app.hiring_shortlist_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object('roles', (select coalesce(jsonb_agg(jsonb_build_object('slug', r.slug, 'title', r.short_title, 'rows',
      (select coalesce(jsonb_agg(app.hiring_app_row(a) || jsonb_build_object('rank', k.rank) order by k.rank), '[]'::jsonb)
         from app.hiring_ranks(r.id) k join job_applications a on a.id = k.application_id)) order by r.sort_order), '[]'::jsonb)
    from hiring_roles r where exists (select 1 from job_applications a join interview_scores sc on sc.application_id = a.id where a.role_id = r.id and sc.final_score is not null)));
end $$;

create or replace function app.hiring_lock(p_by uuid, p_id uuid) returns job_applications
language plpgsql security definer set search_path = public, app as $$
declare a job_applications;
begin
  perform app.assert_admin(p_by);
  select * into a from job_applications where id = p_id for update;
  if a.id is null then raise exception 'Application not found' using errcode = 'P0002'; end if;
  if a.purged_at is not null then raise exception 'This application''s personal data was removed' using errcode = '23514'; end if;
  return a;
end $$;

-- Invite anyway (below the bar, declined, referred, a no-show to give a second chance): the invitation with the booking link.
create or replace function app.hiring_invite(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications := app.hiring_lock(p_by, (p ->> 'id')::uuid);
  r hiring_roles;
  n integer;
begin
  if a.status not in ('below_bar', 'declined', 'referred', 'no_show', 'new') then raise exception 'Only a candidate below the bar, declined, referred or a no-show can be invited (this one is %)', replace(a.status, '_', ' ') using errcode = '23514'; end if;
  select * into r from hiring_roles where id = a.role_id;
  update job_applications set status = 'invited', invited_at = now(), slot_id = null, decided_at = null, decided_by = null, updated_at = now() where id = a.id returning * into a;
  select count(*) + 1 into n from app_events where code = 'applicant_invited' and entity_id = a.id;
  perform app.hiring_emit('applicant_invited', a, app.hiring_invite_vars(a), 'applicant_invited:' || a.id || ':' || n);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'hiring_invite', 'job_applications', a.id::text, jsonb_build_object('status', a.status));
  return app.hiring_app_row(a);
end $$;

create or replace function app.hiring_decline(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications := app.hiring_lock(p_by, (p ->> 'id')::uuid);
begin
  if a.status not in ('new', 'below_bar', 'invited', 'referred', 'no_show') then raise exception 'Only a candidate who has not had the call can be declined (this one is %): use Not hired after the call', replace(a.status, '_', ' ') using errcode = '23514'; end if;
  update job_applications set status = 'declined', slot_id = null, decided_at = now(), decided_by = p_by, updated_at = now(),
         note = case when nullif(btrim(coalesce(p ->> 'note', '')), '') is null then note else concat_ws(E'\n', note, btrim(p ->> 'note')) end where id = a.id returning * into a;
  if coalesce((p ->> 'email')::boolean, true) then
    perform app.hiring_emit('applicant_declined', a, jsonb_build_object('decline_reason', coalesce(nullif(btrim(coalesce(p ->> 'reason', '')), ''), '')), 'applicant_declined:' || a.id || ':admin');
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'hiring_decline', 'job_applications', a.id::text, jsonb_build_object('email', coalesce((p ->> 'email')::boolean, true)));
  return app.hiring_app_row(a);
end $$;

create or replace function app.hiring_set_status(p_by uuid, p jsonb, p_to text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications := app.hiring_lock(p_by, (p ->> 'id')::uuid);
begin
  if p_to = 'withdrawn' and a.status in ('hired', 'withdrawn') then raise exception 'This candidate is already %', a.status using errcode = '23514'; end if;
  if p_to = 'rejected' and a.status not in ('interviewed', 'no_show', 'booked') then raise exception 'Not hired is for a candidate after the call (this one is %)', replace(a.status, '_', ' ') using errcode = '23514'; end if;
  if p_to = 'no_show' and a.status not in ('booked', 'interviewed') then raise exception 'Only a booked call can be a no-show' using errcode = '23514'; end if;
  update job_applications set status = p_to, decided_at = now(), decided_by = p_by, updated_at = now(),
         slot_id = case when p_to = 'withdrawn' and status in ('invited', 'booked') then null else slot_id end where id = a.id returning * into a;
  if p_to = 'no_show' then
    insert into interview_scores (application_id, decision, interviewer) values (a.id, 'no_show', p_by)
    on conflict (application_id) do update set decision = 'no_show', interview_score = null, final_score = null, updated_at = now();
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'hiring_' || p_to, 'job_applications', a.id::text, jsonb_build_object('status', p_to));
  return app.hiring_app_row(a);
end $$;

-- The rubric: p {id, scores{key: 1..5}, notes, decision}. Saving marks the call as held (interviewed), or a no-show.
create or replace function app.hiring_score_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications := app.hiring_lock(p_by, (p ->> 'id')::uuid);
  v_scores jsonb := '{}'::jsonb;
  c jsonb;
  v text;
  v_int integer;
  v_dec text := nullif(p ->> 'decision', '');
begin
  if a.status not in ('booked', 'interviewed', 'invited', 'no_show') then raise exception 'The rubric is for a candidate with a call (this one is %)', replace(a.status, '_', ' ') using errcode = '23514'; end if;
  if v_dec is not null and v_dec not in ('hire', 'maybe', 'no', 'no_show') then raise exception 'Choose Hire, Maybe, No or No show' using errcode = '22023'; end if;
  for c in select * from jsonb_array_elements(app.hiring_criteria()) loop
    v := p -> 'scores' ->> (c ->> 'key');
    if nullif(v, '') is null then continue; end if;
    if v !~ '^[1-5]$' then raise exception '% is scored 1 to 5', c ->> 'label' using errcode = '22023'; end if;
    v_scores := v_scores || jsonb_build_object(c ->> 'key', v::int);
  end loop;
  if v_dec = 'no_show' then
    v_scores := '{}'::jsonb;
  end if;
  v_int := app.hiring_interview_score(v_scores);
  insert into interview_scores (application_id, scores, interview_score, final_score, notes, decision, interviewer, updated_at)
  values (a.id, v_scores, v_int, app.hiring_final_score(a.score, v_int), nullif(btrim(coalesce(p ->> 'notes', '')), ''), v_dec, p_by, now())
  on conflict (application_id) do update set scores = excluded.scores, interview_score = excluded.interview_score, final_score = excluded.final_score,
     notes = excluded.notes, decision = excluded.decision, interviewer = excluded.interviewer, updated_at = now();
  update job_applications set status = case when v_dec = 'no_show' then 'no_show' when v_int is not null then 'interviewed' else status end,
         interviewed_at = case when v_int is not null then coalesce(interviewed_at, now()) else interviewed_at end, updated_at = now()
   where id = a.id returning * into a;
  return app.hiring_app_row(a) || jsonb_build_object('rank', (select k.rank from app.hiring_ranks(a.role_id) k where k.application_id = a.id));
end $$;

-- Hire: the web app first makes (or finds) the staff sign-in with the existing invitation (app.admin_invite_account), then records
-- it here. p {id, user_id}. The staff agreement is sent next from the application page (the existing generated agreement).
create or replace function app.hiring_hire(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications := app.hiring_lock(p_by, (p ->> 'id')::uuid);
  r hiring_roles;
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
begin
  select * into r from hiring_roles where id = a.role_id;
  if a.status = 'hired' and a.hired_user_id = v_user then return app.hiring_app_row(a); end if;
  if a.status not in ('interviewed', 'booked', 'invited', 'below_bar') then raise exception 'Only a candidate who is not declined, withdrawn or hired already can be hired (this one is %)', replace(a.status, '_', ' ') using errcode = '23514'; end if;
  if v_user is null or not exists (select 1 from users u join user_roles ur on ur.user_id = u.id where u.id = v_user and ur.role::text = r.staff_kind) then
    raise exception 'Invite the staff account first (the % portal)', case r.staff_kind when 'field' then 'field staff' else 'assistant' end using errcode = '23514';
  end if;
  update job_applications set status = 'hired', hired_user_id = v_user, decided_at = now(), decided_by = p_by, updated_at = now() where id = a.id returning * into a;
  insert into interview_scores (application_id, decision, interviewer) values (a.id, 'hire', p_by) on conflict (application_id) do update set decision = 'hire', updated_at = now();
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'hiring_hire', 'job_applications', a.id::text, jsonb_build_object('user_id', v_user, 'role', r.slug, 'work_mode', a.work_mode));
  return app.hiring_app_row(a) || jsonb_build_object('work_mode', a.work_mode);
end $$;

create or replace function app.hiring_note(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications := app.hiring_lock(p_by, (p ->> 'id')::uuid);
begin
  update job_applications set note = left(nullif(btrim(coalesce(p ->> 'note', '')), ''), 4000), updated_at = now() where id = a.id returning * into a;
  return app.hiring_app_row(a);
end $$;

-- Open or close a role, its pass mark, pay text. p {slug, active?, pass_mark?, pay_text?}
create or replace function app.hiring_role_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r hiring_roles;
begin
  perform app.assert_admin(p_by);
  select * into r from hiring_roles where slug = p ->> 'slug' for update;
  if r.id is null then raise exception 'Role not found' using errcode = 'P0002'; end if;
  if p ? 'pass_mark' and ((p ->> 'pass_mark') !~ '^\d+$' or (p ->> 'pass_mark')::int > 100) then raise exception 'The pass mark is 0 to 100' using errcode = '22023'; end if;
  update hiring_roles set active = coalesce((p ->> 'active')::boolean, active), pass_mark = coalesce((p ->> 'pass_mark')::int, pass_mark),
         pay_text = coalesce(nullif(btrim(coalesce(p ->> 'pay_text', '')), ''), pay_text),
         posted_on = case when coalesce((p ->> 'active')::boolean, active) and not active then app.today() else posted_on end, updated_by = p_by, updated_at = now()
   where id = r.id returning * into r;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'hiring_role_save', 'hiring_roles', r.id::text,
    jsonb_build_object('active', r.active, 'pass_mark', r.pass_mark, 'pay_text', r.pay_text));
  return jsonb_build_object('slug', r.slug, 'active', r.active, 'pass_mark', r.pass_mark, 'pay_text', r.pay_text);
end $$;

-- Add or change an interview day. p {id?, day, start_time, end_time, slot_minutes, buffer_minutes, capacity, mode, roles[] (slugs; empty: every role), note, active}
create or replace function app.hiring_day_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d interview_days;
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_roles uuid[];
  n integer;
begin
  perform app.assert_admin(p_by);
  if jsonb_typeof(p -> 'roles') = 'array' and jsonb_array_length(p -> 'roles') > 0 then
    v_roles := array(select r.id from hiring_roles r where r.slug in (select jsonb_array_elements_text(p -> 'roles')));
  elsif jsonb_typeof(p -> 'roles') = 'string' and nullif(p ->> 'roles', '') is not null then
    v_roles := array(select r.id from hiring_roles r where r.slug = any (string_to_array(replace(p ->> 'roles', ' ', ''), ',')));
  end if;
  if coalesce(p ->> 'mode', 'phone') not in ('phone', 'video') then raise exception 'Choose phone or video' using errcode = '22023'; end if;
  if v_id is null then
    if nullif(p ->> 'day', '') is null then raise exception 'Choose the day' using errcode = '22023'; end if;
    if (p ->> 'day')::date < app.today() then raise exception 'Choose today or a later day' using errcode = '22023'; end if;
    insert into interview_days (day, start_time, end_time, slot_minutes, buffer_minutes, capacity, mode, role_ids, note, created_by)
    values ((p ->> 'day')::date, coalesce(nullif(p ->> 'start_time', ''), '09:00')::time, coalesce(nullif(p ->> 'end_time', ''), '19:00')::time,
            coalesce(nullif(p ->> 'slot_minutes', '')::int, 15), coalesce(nullif(p ->> 'buffer_minutes', '')::int, 5), coalesce(nullif(p ->> 'capacity', '')::int, 1),
            coalesce(nullif(p ->> 'mode', ''), 'phone'), case when cardinality(v_roles) > 0 then v_roles end, nullif(btrim(coalesce(p ->> 'note', '')), ''), p_by)
    returning * into d;
  else
    update interview_days set day = coalesce(nullif(p ->> 'day', '')::date, day), start_time = coalesce(nullif(p ->> 'start_time', '')::time, start_time),
           end_time = coalesce(nullif(p ->> 'end_time', '')::time, end_time), slot_minutes = coalesce(nullif(p ->> 'slot_minutes', '')::int, slot_minutes),
           buffer_minutes = coalesce(nullif(p ->> 'buffer_minutes', '')::int, buffer_minutes), capacity = coalesce(nullif(p ->> 'capacity', '')::int, capacity),
           mode = coalesce(nullif(p ->> 'mode', ''), mode), role_ids = case when p ? 'roles' then case when cardinality(v_roles) > 0 then v_roles end else role_ids end,
           note = case when p ? 'note' then nullif(btrim(coalesce(p ->> 'note', '')), '') else note end, active = coalesce((p ->> 'active')::boolean, active)
     where id = v_id returning * into d;
    if d.id is null then raise exception 'Interview day not found' using errcode = 'P0002'; end if;
    if exists (select 1 from interview_slots s join job_applications a on a.slot_id = s.id where s.day_id = d.id and a.status = 'booked'
                and app.local_date(s.starts_at) <> d.day) then
      raise exception 'Candidates are booked on this day: move them before you change its date' using errcode = '23514';
    end if;
  end if;
  n := app.hiring_day_slots(d.id);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'hiring_day_save', 'interview_days', d.id::text, jsonb_build_object('day', d.day, 'slots', n, 'mode', d.mode));
  return jsonb_build_object('id', d.id, 'day', d.day, 'slots', n);
end $$;

create or replace function app.hiring_day_delete(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid := (p ->> 'id')::uuid;
begin
  perform app.assert_admin(p_by);
  if exists (select 1 from interview_slots s join job_applications a on a.slot_id = s.id where s.day_id = v_id and a.status = 'booked') then
    raise exception 'Candidates are booked on this day: cancel or move them first, or turn the day off' using errcode = '23514';
  end if;
  update job_applications set slot_id = null where slot_id in (select id from interview_slots where day_id = v_id);
  delete from interview_days where id = v_id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id) values (p_by, 'hiring_day_delete', 'interview_days', v_id::text);
  return jsonb_build_object('deleted', true);
end $$;

-- ================================================================ 10. the emails in the notification layer
-- The candidate is not a user: the address is on the application (payload application_id).
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre0173;
create function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_c.audience = 'applicant' then
    return query select 'applicant'::text, null::uuid, a.email, a.full_name, null::uuid, null::uuid, true
                   from job_applications a where a.id = (p_event.payload ->> 'application_id')::uuid and a.email is not null and a.purged_at is null;
    return;
  end if;
  return query select * from app.notification_recipients_pre0173(p_event, p_c);
end $$;
select pg_temp.copy_grants('app.notification_recipients(app_events, notification_catalogue)'::regprocedure, 'app.notification_recipients_pre0173(app_events, notification_catalogue)'::regprocedure);

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0173;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0173(p_code, p_event, p_to);
begin
  if p_code like 'applicant\_%' then
    x := coalesce(x, '{}'::jsonb) || (coalesce(p_event.payload, '{}'::jsonb) - 'application_id' - 'email');
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre0173(text, app_events, jsonb)'::regprocedure);

-- CATALOGUE 0173 START (generated by supabase/seed/0173_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('applicant_received', 'applicant', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'We have your application: {{role_title}}', 'Thank you for applying to CarmaCars. A person reads every application.', 'Immediate', 'A candidate sends an application on carmacars.ca/careers and the screening score is below the role''s pass mark, with no knock-out and no other open role to offer (migration 0173). The application waits for the owner''s review. One email per application; invited, declined and referred candidates get their own email instead.', null, '/careers', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"role_title","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/applicant_received.html', 'templates/applicant_received.txt'),
  ('applicant_invited', 'applicant', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'CarmaCars: book your {{call_minutes}}-minute interview call', 'Pick a time on {{call_days}} that suits you.', 'Immediate', 'A candidate''s screening score on carmacars.ca/careers reaches the role''s pass mark with no knock-out, or an Admin presses Invite anyway in Admin > People > Hiring (migration 0173). The email has the candidate''s personal booking link for a short interview call; for a remote assistant role it also describes the paid test task. One email per invitation.', null, null, '[{"name":"booking_url","type":"url"},{"name":"call_days","type":"string"},{"name":"call_minutes","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"role_title","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"test_task","type":"string"},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/applicant_invited.html', 'templates/applicant_invited.txt'),
  ('applicant_declined', 'applicant', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your CarmaCars application', 'Thank you for applying for {{role_title}}.', 'Immediate', 'A candidate''s answers on carmacars.ca/careers include a knock-out (a requirement of the role they do not meet) and the role offers no other role instead, or an Admin presses Decline in Admin > People > Hiring with the email left on (migration 0173). One email per decision.', null, '/careers', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"decline_reason","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"role_title","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/applicant_declined.html', 'templates/applicant_declined.txt'),
  ('applicant_referred', 'applicant', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your CarmaCars application, and a role that may suit you better', 'We would love you to apply for {{other_role_title}}.', 'Immediate', 'A candidate does not qualify for the role they applied for on carmacars.ca/careers (a knock-out or a score below the pass mark for Field staff; a score below the pass mark for a remote assistant role) and another open role suits them: Field staff to Sales and Customer Relations (In person, Toronto), with Remote Sales named as the other choice; Sales in person to Remote Sales; or the best matching other open role (migration 0173). Not sent when they already applied for that role. The link opens that role''s application with their name, email and phone filled in. One email per application.', null, null, '[{"name":"alt_apply_url","type":"url"},{"name":"alt_role_title","type":"string"},{"name":"apply_url","type":"url"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"other_role_summary","type":"string"},{"name":"other_role_title","type":"string"},{"name":"reason_text","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"role_title","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/applicant_referred.html', 'templates/applicant_referred.txt'),
  ('applicant_booked', 'applicant', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', '{{#if rescheduled}}Moved: {{/if}}your CarmaCars interview call, {{call_when}}', 'Toronto time. {{call_minutes}} minutes.', 'Immediate', 'A candidate books, or moves, their interview call from their booking link on carmacars.ca/careers/book (migration 0173). By phone, CarmaCars calls the number on the application; by video, the email has the Jitsi Meet link made for this booking. One email per booking or move.', null, null, '[{"name":"call_minutes","type":"string"},{"name":"call_when","type":"string"},{"name":"call_when_manila","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"is_video","type":"boolean"},{"name":"manage_url","type":"url"},{"name":"meet_url","type":"url"},{"name":"opening_hours","type":"string","global":true},{"name":"phone_display","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"rescheduled","type":"boolean"},{"name":"role_title","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/applicant_booked.html', 'templates/applicant_booked.txt'),
  ('applicant_reminder', 'applicant', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Reminder: your CarmaCars interview call is {{when_text}}', '{{call_when}}, Toronto time.', 'The evening before (6 pm Toronto time) and about an hour before the call', 'A booked interview call is the next day (sent at 6 pm Toronto time the evening before) or about an hour away (migration 0173, app.job_hiring every 15 minutes). Not sent when the call was booked after that moment. When phone and texts are on, a text goes with the reminder an hour before. One email per reminder.', null, null, '[{"name":"call_minutes","type":"string"},{"name":"call_when","type":"string"},{"name":"call_when_manila","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"is_video","type":"boolean"},{"name":"manage_url","type":"url"},{"name":"meet_url","type":"url"},{"name":"opening_hours","type":"string","global":true},{"name":"phone_display","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"role_title","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"when_text","type":"string"}]'::jsonb, 'templates/applicant_reminder.html', 'templates/applicant_reminder.txt'),
  ('applicant_cancelled', 'applicant', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your CarmaCars interview call is cancelled', 'You can book another time from the same link.', 'Immediate', 'A candidate cancels their interview call from their booking link on carmacars.ca/careers/book (migration 0173). The invitation stays open: the same link books another time. One email per cancellation.', null, null, '[{"name":"booking_url","type":"url"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"role_title","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/applicant_cancelled.html', 'templates/applicant_cancelled.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0173 END
-- the catalogue refresh above recomputes each marketing email's consent rule: keep express consent where 0161 and 0167 set it
update notification_catalogue set consent_rule = 'express' where code in ('renter_promo_expiry_3d', 'renter_promo_expiry_1d', 'owner_recruit_outreach');
update notification_catalogue set emitted_by = 'app.hiring_screen, app.hiring_invite, app.hiring_decline, public.server_hiring_book, public.server_hiring_cancel, app.job_hiring (0173)'
 where code like 'applicant\_%';

-- ================================================================ 11. the privacy policy (job applications)
-- The live copy changes only where it still carries our text; an Admin's own edit is left as it is.
update site_content_blocks
   set body = replace(body,
     '| Details of guests who booked through another platform | 24 months after their last trip |',
     '| Details of guests who booked through another platform | 24 months after their last trip |
| Job applications from people we do not hire (name, contact details, answers, interview notes) | 12 months after our decision; then deleted. If we hire you, your application stays with your staff records |')
 where block_key = 'legal.privacy' and body like '%| Details of guests who booked through another platform | 24 months after their last trip |%'
   and body not like '%| Job applications from people we do not hire%';
update site_content_blocks
   set body = regexp_replace(body,
     '(\| Forms you start: [^\n]*)',
     E'\\1\n| Job applications: your name, email, phone number, the profile name you give, where you saw the job, your answers to the screening questions, the interview time you book, and the interviewer''s scores and notes | To assess your application, arrange the interview and decide whom to hire. Your answers are scored automatically against the role''s requirements; a person reviews the results before anyone is hired. Only our Admins see applications |')
 where block_key = 'legal.privacy' and body like '%| Forms you start: %' and body not like '%| Job applications: %';
update site_content_blocks set data = data || jsonb_build_object('last_updated', 'October 26, 2026')
 where block_key = 'legal.meta' and (data ->> 'last_updated') in ('October 23, 2026', 'October 24, 2026', 'October 25, 2026');

-- ================================================================ 12. the doors
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0173;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_read' and p_name in ('hiring', 'hiring_application', 'hiring_schedule', 'hiring_shortlist') then
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'hiring' then app.hiring_read(p_user, coalesce(p, '{}'::jsonb))
      when 'hiring_application' then app.hiring_application_read(p_user, coalesce(p, '{}'::jsonb))
      when 'hiring_schedule' then app.hiring_schedule_read(p_user, coalesce(p, '{}'::jsonb))
      else app.hiring_shortlist_read(p_user, coalesce(p, '{}'::jsonb)) end;
  end if;
  if p_call = 'admin_do' and p_name in ('hiring_invite', 'hiring_decline', 'hiring_withdraw', 'hiring_reject', 'hiring_no_show', 'hiring_score', 'hiring_hire', 'hiring_note',
                                        'hiring_role_save', 'hiring_day_save', 'hiring_day_delete') then
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'hiring_invite' then app.hiring_invite(p_user, coalesce(p, '{}'::jsonb))
      when 'hiring_decline' then app.hiring_decline(p_user, coalesce(p, '{}'::jsonb))
      when 'hiring_withdraw' then app.hiring_set_status(p_user, coalesce(p, '{}'::jsonb), 'withdrawn')
      when 'hiring_reject' then app.hiring_set_status(p_user, coalesce(p, '{}'::jsonb), 'rejected')
      when 'hiring_no_show' then app.hiring_set_status(p_user, coalesce(p, '{}'::jsonb), 'no_show')
      when 'hiring_score' then app.hiring_score_save(p_user, coalesce(p, '{}'::jsonb))
      when 'hiring_hire' then app.hiring_hire(p_user, coalesce(p, '{}'::jsonb))
      when 'hiring_note' then app.hiring_note(p_user, coalesce(p, '{}'::jsonb))
      when 'hiring_role_save' then app.hiring_role_save(p_user, coalesce(p, '{}'::jsonb))
      when 'hiring_day_save' then app.hiring_day_save(p_user, coalesce(p, '{}'::jsonb))
      else app.hiring_day_delete(p_user, coalesce(p, '{}'::jsonb)) end;
  end if;
  return app.door_pre0173(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0173(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['door_pre0173', 'notification_recipients_pre0173', 'ntf_payload_pre0173',
              'hiring_criteria', 'hiring_question_max', 'hiring_score', 'hiring_question_public', 'hiring_interview_score', 'hiring_final_score', 'hiring_day_slots',
              'hiring_first_name', 'hiring_url', 'hiring_call_days', 'hiring_invite_vars', 'hiring_book', 'hiring_cancel', 'hiring_when', 'hiring_emit', 'hiring_booking_vars', 'hiring_screen', 'job_hiring',
              'hiring_app_row', 'hiring_ranks', 'hiring_read', 'hiring_application_read', 'hiring_schedule_read', 'hiring_shortlist_read', 'hiring_lock',
              'hiring_invite', 'hiring_decline', 'hiring_set_status', 'hiring_score_save', 'hiring_hire', 'hiring_note', 'hiring_role_save', 'hiring_day_save', 'hiring_day_delete']))
        or (n.nspname = 'public' and p.proname = any (array['server_hiring_apply', 'server_hiring_booking', 'server_hiring_book', 'server_hiring_cancel', 'server_hiring_prefill']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- the public reads (anon): the open roles and one role's page and form, without points or knock-outs
revoke all on function public.hiring_roles_public(), public.hiring_role_public(text) from public;
grant execute on function public.hiring_roles_public(), public.hiring_role_public(text) to anon, authenticated, service_role;

-- row audit for the roles and days (not the applications: the audit log would keep personal data past the 12 months; their
-- changes are logged above without it)
do $$
declare t text;
begin
  foreach t in array array['hiring_roles', 'interview_days'] loop
    execute format('create trigger %I after insert or update or delete on %I for each row execute function app.audit_row()', 'audit_' || t, t);
  end loop;
end $$;

-- GUIDES 0173 START (generated by supabase/seed/0173_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'hiring', 'chapter', 'referral-partners-and-rentalcoverage', null, 'Hiring', 'Open roles and apply links for Indeed and OnlineJobs.ph, the applications and their scores, interview days, the rubric during each call, the ranked shortlist and Hire.',
  'Candidates apply on carmacars.ca/careers. Every application is scored on the server against the role''s rubric: a candidate who passes gets a link to book a 15-minute call, one who does not qualify for Field staff is offered Sales instead, and the rest wait for you. During each call you fill in a rubric; the final score ranks everyone in the role.

## Open a role and send the apply link

**People** > **Hiring**, tab Roles and links.

1. Press **Open the role** to put it on carmacars.ca/careers (and in the sitemap and the footer); **Close the role** takes it off. Field staff, Sales in person and Remote sales start open; the three remote assistant roles start closed.
2. Copy the apply link: it ends with ?src=indeed (or ?src=onlinejobs for the remote roles), so each application records where it came from.
3. Copy the message under it and paste it into Indeed (or OnlineJobs.ph) messages to each applicant. It asks them to answer the role''s questions, about five minutes.
4. **Pass mark and pay** changes the pass mark (60 of 100 unless you change it) and the pay shown on the page.

## What happens to each application

The database scores the answers the moment they arrive. The candidate never sees the points.

- Score at or above the pass mark, no knock-out: an email with a personal link to book a call (Invited).
- Field staff who do not qualify (no full G licence, under two years of driving, or a low score) are not declined: they get a friendly email offering Sales in person, with a one-click link that fills in their details, and Remote sales named as the other choice (Referred). If they already applied for Sales, nothing is sent and a note says so.
- Sales in person below the pass mark, or remote only, is offered Remote sales. A remote assistant role below the pass mark is offered the closest other open role.
- A knock-out with no other role to offer (for example the finance code word missing) gets a polite decline.
- Anyone else waits for you as Below the bar, with only a confirmation email.

## Review the applications

**People** > **Hiring**, tab Applications.

1. Filter by role, status, source (Indeed, OnlineJobs.ph, website, referral) or score. Open a candidate for every answer with the points it earned and any knock-out.
2. **Invite anyway** sends the booking link to a candidate below the bar, declined or referred. **Decline** sends the polite decline email (untick it to decline without an email).
3. A candidate referred to another role shows the link both ways under Linked applications.

## Interview days

**People** > **Hiring**, tab Interview days.

1. Press **Add an interview day**: the day, from and to (Toronto time), the call length (15 minutes) and the break between calls (5 minutes), phone or video, and the roles it is for (empty: every role).
2. Phone: you call the candidate on the number they gave. Video: every booking gets its own Jitsi Meet link, in the candidate''s email and on their page.
3. Candidates book, move or cancel from their link. They get a confirmation, a reminder the evening before and one an hour before (and a text, when phone and texts are on). Remote roles show Manila time too.
4. **Turn off** stops new bookings on a day; a day with bookings cannot be deleted.

## Run the calls with the rubric

**People** > **Hiring**, tab Calls.

1. Pick the day. Each call shows the time, the candidate, Call (or the video link). Press **Start**.
2. The rubric sits beside the call guide (what to ask each minute, and what a good answer sounds like). Score each line 1 to 5: Communication, Reliability and availability, Role skills, Customer or sales instinct, Judgement on the scenarios, Attitude.
3. Choose the decision (Hire, Maybe, No, No show), add notes and press **Save the rubric**. The interview score (of 100) and the final score (40% screening, 60% interview) fill in, with the rank in the role.

## Shortlist and Hire

**People** > **Hiring**, tab Shortlist.

1. Each role lists its interviewed candidates by final score, rank 1 first.
2. Open the candidate and press **Hire**. It invites them into the right portal: field staff, or the assistant portal (both sales roles are the Sales function, with in person or remote recorded).
3. Then press **Send the agreement to sign**: check the values and send the staff agreement to sign in their portal.
4. **Not hired** closes a candidate after the call without an email; **Withdrawn** is for one who no longer wants the role.

> Good to know: Applications are for Admins only. The name, contact details and answers of a candidate who is not hired are deleted 12 months after the decision, as the privacy policy says.
',
  '<p class="gd-p">Candidates apply on carmacars.ca/careers. Every application is scored on the server against the role&#39;s rubric: a candidate who passes gets a link to book a 15-minute call, one who does not qualify for Field staff is offered Sales instead, and the rest wait for you. During each call you fill in a rubric; the final score ranks everyone in the role.</p><section class="gd-task" id="hiring-open-a-role-and-send-the-apply-link" data-gd-task><h2 class="gd-h2">Open a role and send the apply link</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Hiring</b>, tab Roles and links.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Open the role</b> to put it on carmacars.ca/careers (and in the sitemap and the footer); <b class="gd-ui">Close the role</b> takes it off. Field staff, Sales in person and Remote sales start open; the three remote assistant roles start closed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Copy the apply link: it ends with ?src=indeed (or ?src=onlinejobs for the remote roles), so each application records where it came from.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Copy the message under it and paste it into Indeed (or OnlineJobs.ph) messages to each applicant. It asks them to answer the role&#39;s questions, about five minutes.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Pass mark and pay</b> changes the pass mark (60 of 100 unless you change it) and the pay shown on the page.</div></li></ol></div></section><section class="gd-task" id="hiring-what-happens-to-each-application" data-gd-task><h2 class="gd-h2">What happens to each application</h2><p class="gd-p">The database scores the answers the moment they arrive. The candidate never sees the points.</p><ul class="gd-ul"><li>Score at or above the pass mark, no knock-out: an email with a personal link to book a call (Invited).</li><li>Field staff who do not qualify (no full G licence, under two years of driving, or a low score) are not declined: they get a friendly email offering Sales in person, with a one-click link that fills in their details, and Remote sales named as the other choice (Referred). If they already applied for Sales, nothing is sent and a note says so.</li><li>Sales in person below the pass mark, or remote only, is offered Remote sales. A remote assistant role below the pass mark is offered the closest other open role.</li><li>A knock-out with no other role to offer (for example the finance code word missing) gets a polite decline.</li><li>Anyone else waits for you as Below the bar, with only a confirmation email.</li></ul></section><section class="gd-task" id="hiring-review-the-applications" data-gd-task><h2 class="gd-h2">Review the applications</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Hiring</b>, tab Applications.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by role, status, source (Indeed, OnlineJobs.ph, website, referral) or score. Open a candidate for every answer with the points it earned and any knock-out.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Invite anyway</b> sends the booking link to a candidate below the bar, declined or referred. <b class="gd-ui">Decline</b> sends the polite decline email (untick it to decline without an email).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A candidate referred to another role shows the link both ways under Linked applications.</div></li></ol></div></section><section class="gd-task" id="hiring-interview-days" data-gd-task><h2 class="gd-h2">Interview days</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Hiring</b>, tab Interview days.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Add an interview day</b>: the day, from and to (Toronto time), the call length (15 minutes) and the break between calls (5 minutes), phone or video, and the roles it is for (empty: every role).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Phone: you call the candidate on the number they gave. Video: every booking gets its own Jitsi Meet link, in the candidate&#39;s email and on their page.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Candidates book, move or cancel from their link. They get a confirmation, a reminder the evening before and one an hour before (and a text, when phone and texts are on). Remote roles show Manila time too.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Turn off</b> stops new bookings on a day; a day with bookings cannot be deleted.</div></li></ol></div></section><section class="gd-task" id="hiring-run-the-calls-with-the-rubric" data-gd-task><h2 class="gd-h2">Run the calls with the rubric</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Hiring</b>, tab Calls.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Pick the day. Each call shows the time, the candidate, Call (or the video link). Press <b class="gd-ui">Start</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The rubric sits beside the call guide (what to ask each minute, and what a good answer sounds like). Score each line 1 to 5: Communication, Reliability and availability, Role skills, Customer or sales instinct, Judgement on the scenarios, Attitude.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose the decision (Hire, Maybe, No, No show), add notes and press <b class="gd-ui">Save the rubric</b>. The interview score (of 100) and the final score (40% screening, 60% interview) fill in, with the rank in the role.</div></li></ol></div></section><section class="gd-task" id="hiring-shortlist-and-hire" data-gd-task><h2 class="gd-h2">Shortlist and Hire</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Hiring</b>, tab Shortlist.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each role lists its interviewed candidates by final score, rank 1 first.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open the candidate and press <b class="gd-ui">Hire</b>. It invites them into the right portal: field staff, or the assistant portal (both sales roles are the Sales function, with in person or remote recorded).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Then press <b class="gd-ui">Send the agreement to sign</b>: check the values and send the staff agreement to sign in their portal.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Not hired</b> closes a candidate after the call without an email; <b class="gd-ui">Withdrawn</b> is for one who no longer wants the role.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Applications are for Admins only. The name, contact details and answers of a candidate who is not hired are deleted 12 months after the decision, as the privacy policy says.</div></aside></section>');
-- GUIDES 0173 END
