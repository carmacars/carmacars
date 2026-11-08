-- 0730_one_step_hire.sql
-- Release 33, part G (docs/changes/2026-11-07-r33-hire-academy-connector.md, item 1): one Hire does the whole onboarding.
-- Before: Hire sent the invitation, then the agreement, the pay setup and the academy were each done by hand.
-- Now one confirm on the candidate (Admin > Hiring, or the Claude connector's hire_applicant) does, in order:
--   1. the staff sign-in and its invitation (the existing invitation, in the web layer: web/src/server/hire.ts)
--   2. app.hire_onboard (this file): the staff profile (function, start date, pay), the candidate hired (app.hiring_hire,
--      0173), their interview items closed (a future call slot freed, an open AI interview link closed, the candidate's
--      open To do's done), the welcome email (applicant_hired, 0226) with the next steps and the pay details link, the
--      academy enrollment of their paths with the gate on (academy_enrollments), and their first-day To do's
--   3. the staff agreement generated and sent to sign in their portal (the existing e-signature flow, web layer), or,
--      when a value only the hire can give is missing (a field hire's home address and licence number), waiting for it
--   4. the pay details form: the hire enters their payout method in their portal (staff_payout_accounts: the account
--      number encrypted in the web layer like owner_payout_accounts, only the last 4 ever shown; an Admin verifies it)
-- One status card (app.hire_status) shows each step done or waiting.
-- The door is wrapped (app.door_pre0730): admin_read hire_preview, hire_status; admin_do hire_onboard,
-- hire_agreement_record, staff_payout_verify; the staff member's own my_pay_details (va_read, field_read) and
-- my_pay_details_save (va_do, field_do).
set local check_function_bodies = off;

-- ================================================================ 1. tables
create table if not exists staff_payout_accounts (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references users (id) on delete cascade,
  method           text not null check (method in ('bank_transfer', 'e_transfer', 'paypal', 'wise', 'gcash', 'onlinejobs')),
  account_holder   text not null check (length(btrim(account_holder)) between 2 and 120),
  country          text check (country is null or length(country) <= 60),
  bank_name        text check (bank_name is null or length(bank_name) <= 120),
  institution_no   text check (institution_no is null or institution_no ~ '^\d{3}$'),
  transit_no       text check (transit_no is null or transit_no ~ '^\d{5}$'),
  account_no       text,            -- application-layer encrypted (web/src/server/crypto.ts), never read back in full
  account_last4    text check (account_last4 is null or account_last4 ~ '^\d{4}$'),
  email            text check (email is null or email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  key_version      integer,
  is_current       boolean not null default true,
  submitted_by     uuid references users (id),
  verified_at      timestamptz,
  verified_by      uuid references users (id),
  verified_method  text,
  created_at       timestamptz not null default now(),
  check (method not in ('bank_transfer', 'gcash') or (account_no is not null and account_last4 is not null)),
  check (method <> 'bank_transfer' or bank_name is not null or institution_no is not null),
  check (method not in ('e_transfer', 'paypal', 'wise') or email is not null)
);
create unique index if not exists staff_payout_accounts_current on staff_payout_accounts (user_id) where is_current;
comment on table staff_payout_accounts is 'A staff member''s pay details (0730), entered by them in their portal: the method, the holder, the bank and the account number (encrypted in the web layer; only the last 4 are shown), or the email of e-Transfer, PayPal or Wise. An Admin verifies a new one. Never sent to a browser in full.';

create table if not exists staff_onboarding (
  application_id     uuid primary key references job_applications (id) on delete cascade,
  user_id            uuid not null references users (id) on delete cascade,
  role_id            uuid references hiring_roles (id),
  path               text not null check (path in ('cs', 'fleet', 'finance', 'sales_in_person', 'sales_remote', 'field')),
  start_on           date not null,
  pay_basis          text not null check (pay_basis in ('monthly', 'hourly', 'commission')),
  pay_cents          bigint check (pay_cents is null or pay_cents between 0 and 10000000),
  pay_currency       text check (pay_currency is null or pay_currency in ('USD', 'CAD')),
  pay_text           text,
  welcome_sent       boolean not null default false,
  agreement_request_id uuid references sign_requests (id) on delete set null,
  agreement_missing  text[] not null default '{}',
  agreement_error    text,
  first_day_tasks    integer not null default 0,
  created_by         uuid references users (id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (pay_basis = 'commission' or (pay_cents is not null and pay_currency is not null))
);
create index if not exists staff_onboarding_user_idx on staff_onboarding (user_id);
comment on table staff_onboarding is 'One Hire (0730): the role, start date and pay chosen, and where each onboarding step is (the agreement request, what it waits for, the first-day To do''s). The status card reads it with the live records.';

create table if not exists academy_enrollments (
  user_id     uuid not null references users (id) on delete cascade,
  path_code   text not null references academy_paths (code) on delete cascade,
  gate        boolean not null default true,
  lock_from   timestamptz not null default now(),
  source      text not null default 'hire' check (source in ('hire', 'existing', 'admin')),
  enrolled_by uuid references users (id),
  enrolled_at timestamptz not null default now(),
  primary key (user_id, path_code)
);
comment on table academy_enrollments is 'A staff member enrolled on an academy path (0730): the gate (on: a section must be passed before the next, and until their paths are passed they open only the academy, the guide and their profile, from lock_from). A hire is locked from the start; staff already working got a week (0731).';

do $$
declare t text;
begin
  foreach t in array array['staff_payout_accounts', 'staff_onboarding', 'academy_enrollments'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from public, anon, authenticated', t);
    execute format('grant select, insert, update, delete on %I to service_role', t);
  end loop;
end $$;
-- the onboarding and the enrollments: Admins read them; the pay details are read only through the masked functions below
-- (their admin policy has no grant behind it: no browser reads the table)
drop policy if exists admin_all on staff_onboarding;
create policy admin_all on staff_onboarding for select to authenticated using (app.is_admin());
grant select on staff_onboarding to authenticated;
drop policy if exists admin_all on academy_enrollments;
create policy admin_all on academy_enrollments for select to authenticated using (app.is_admin());
grant select on academy_enrollments to authenticated;
drop policy if exists admin_all on staff_payout_accounts;
create policy admin_all on staff_payout_accounts for select to authenticated using (app.is_admin());
drop trigger if exists audit_staff_onboarding on staff_onboarding;
create trigger audit_staff_onboarding after insert or update or delete on staff_onboarding for each row execute function app.audit_row();
drop trigger if exists audit_academy_enrollments on academy_enrollments;
create trigger audit_academy_enrollments after insert or update or delete on academy_enrollments for each row execute function app.audit_row();
-- the pay details: audited with the values left out (who changed what, never the numbers)
drop trigger if exists audit_staff_payout_accounts on staff_payout_accounts;
create trigger audit_staff_payout_accounts after insert or update or delete on staff_payout_accounts for each row execute function app.audit_row('redact');

-- ================================================================ 2. the role's standard pay
-- the academy path of a function chosen on the Hire form
create or replace function app.hire_path_of(p_fn text) returns jsonb
language sql immutable as $$
  select case p_fn
    when 'cs' then '{"staff_kind":"va","va_function":"cs","work_mode":null,"label":"Customer service"}'
    when 'fleet' then '{"staff_kind":"va","va_function":"fleet","work_mode":null,"label":"Fleet"}'
    when 'finance' then '{"staff_kind":"va","va_function":"finance","work_mode":null,"label":"Finance"}'
    when 'sales_in_person' then '{"staff_kind":"va","va_function":"sales","work_mode":"in_person","label":"Sales in person"}'
    when 'sales_remote' then '{"staff_kind":"va","va_function":"sales","work_mode":"remote","label":"Sales remote"}'
    when 'field' then '{"staff_kind":"field","va_function":null,"work_mode":null,"label":"Field work"}'
  end::jsonb
$$;

-- the function a role hires for by default
create or replace function app.hire_default_path(r hiring_roles) returns text
language sql stable as $$
  select case when r.staff_kind = 'field' then 'field'
              when r.va_function = 'sales' then case when r.work_mode = 'remote' then 'sales_remote' else 'sales_in_person' end
              else coalesce(r.va_function, 'cs') end
$$;

-- the standard pay of a function: the hiring role's posted pay when it is the role's own function (the job settings),
-- else the agreement defaults of Program settings (0057): monthly USD for an office assistant, hourly CAD for field work,
-- commission only for Sales with the tier rule of its work mode (0174)
create or replace function app.hire_standard_pay(p_path text, p_role uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  r hiring_roles;
  d jsonb := coalesce(s.staff_agreement_defaults, '{}'::jsonb);
  v_rate text;
  v_cents bigint;
begin
  select * into r from hiring_roles where id = p_role;
  if p_path in ('sales_in_person', 'sales_remote') then
    return jsonb_build_object('basis', 'commission', 'cents', null, 'currency', null,
      'text', case p_path
        when 'sales_remote' then format('Commission only, remote tiers: %s%%, %s%% and %s%% of the rental charge by rental days in the month; a month under the minimum drops %s tier (never under %s%%)',
          s.sales_remote_tier_low_bps / 100.0, s.sales_remote_tier_mid_bps / 100.0, s.sales_remote_tier_high_bps / 100.0, s.sales_remote_drop_tiers, s.sales_remote_floor_bps / 100.0)
        else format('Commission only, in-person tiers: %s%%, %s%% and %s%% of the rental charge by rental days in the month',
          coalesce(s.sales_tier_low_bps, 1000) / 100.0, coalesce(s.sales_tier_mid_bps, 1500) / 100.0, coalesce(s.sales_tier_high_bps, 2000) / 100.0) end);
  end if;
  if p_path = 'field' then
    if r.id is not null and r.staff_kind = 'field' and r.pay_unit = 'HOUR' and r.pay_min_cents is not null then v_cents := r.pay_min_cents;
    else v_rate := d #>> '{field,wage}'; v_cents := case when v_rate ~ '^\d+(\.\d{1,2})?$' then round(v_rate::numeric * 100) end; end if;
    return jsonb_build_object('basis', 'hourly', 'cents', coalesce(v_cents, 1800), 'currency', coalesce(r.pay_currency, d #>> '{field,currency}', 'CAD'),
      'text', format('%s %s an hour', coalesce(r.pay_currency, d #>> '{field,currency}', 'CAD'), to_char(coalesce(v_cents, 1800) / 100.0, 'FM999990.00')));
  end if;
  if r.id is not null and app.hire_default_path(r) = p_path and r.pay_unit = 'MONTH' and r.pay_min_cents is not null then
    v_cents := r.pay_min_cents;
  else
    v_rate := d #>> array['va', 'by_function', p_path, 'rate'];
    v_cents := case when v_rate ~ '^\d+(\.\d{1,2})?$' then round(v_rate::numeric * 100) end;
  end if;
  return jsonb_build_object('basis', 'monthly', 'cents', coalesce(v_cents, 0), 'currency', coalesce(case when app.hire_default_path(r) = p_path then r.pay_currency end, d #>> '{va,currency}', 'USD'),
    'text', format('%s %s a month', coalesce(case when app.hire_default_path(r) = p_path then r.pay_currency end, d #>> '{va,currency}', 'USD'), to_char(coalesce(v_cents, 0) / 100.0, 'FM999990.00')));
end $$;

-- ================================================================ 3. the Hire form and its preview
create or replace function app.hire_preview(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  a job_applications;
  r hiring_roles;
  v_path text;
  v_pay jsonb;
  v_start date;
begin
  perform app.assert_admin(p_by);
  select * into a from job_applications where id = nullif(p ->> 'id', '')::uuid;
  if a.id is null then raise exception 'Application not found' using errcode = 'P0002'; end if;
  select * into r from hiring_roles where id = a.role_id;
  v_path := coalesce(nullif(p ->> 'function', ''), app.hire_default_path(r));
  if app.hire_path_of(v_path) is null then raise exception 'Choose the role: customer service, fleet, finance, sales in person, sales remote or field' using errcode = '22023'; end if;
  v_pay := app.hire_standard_pay(v_path, r.id);
  v_start := coalesce(nullif(p ->> 'start_on', '')::date, app.today() + 1);
  return jsonb_build_object(
    'application', jsonb_build_object('id', a.id, 'full_name', a.full_name, 'email', a.email, 'status', a.status, 'role', r.title, 'hired_user_id', a.hired_user_id),
    'can_hire', a.purged_at is null and a.email is not null and a.status in ('interviewed', 'booked', 'invited', 'below_bar'),
    'function', v_path, 'function_label', app.hire_path_of(v_path) ->> 'label',
    'functions', jsonb_build_array(
      jsonb_build_object('code', 'cs', 'label', 'Customer service'), jsonb_build_object('code', 'fleet', 'label', 'Fleet'), jsonb_build_object('code', 'finance', 'label', 'Finance'),
      jsonb_build_object('code', 'sales_in_person', 'label', 'Sales in person'), jsonb_build_object('code', 'sales_remote', 'label', 'Sales remote'), jsonb_build_object('code', 'field', 'label', 'Field work')),
    'start_on', v_start, 'pay', v_pay,
    'standard_pay', jsonb_build_object('cs', app.hire_standard_pay('cs', r.id), 'fleet', app.hire_standard_pay('fleet', r.id), 'finance', app.hire_standard_pay('finance', r.id),
      'sales_in_person', app.hire_standard_pay('sales_in_person', r.id), 'sales_remote', app.hire_standard_pay('sales_remote', r.id), 'field', app.hire_standard_pay('field', r.id)),
    'will_do', jsonb_build_array(
      format('Create %s''s staff sign-in (%s) and email the invitation to choose a password', a.full_name, app.hire_path_of(v_path) ->> 'label'),
      'Send the staff agreement to sign in their portal (filled from the role, the pay and the start date)',
      'Ask them for their pay details in their portal (only the last 4 digits are ever shown)',
      format('Enroll them in the %s academy path with the gate on (a section must be passed before the next)', app.hire_path_of(v_path) ->> 'label'),
      format('Schedule their first-day To do''s for %s', to_char(v_start, 'Dy Mon DD')),
      'Mark the candidate hired, send the welcome email and close their interview items'));
end $$;

-- ================================================================ 4. the academy enrollment
create or replace function app.academy_enroll(p_user uuid, p_by uuid, p_source text default 'hire', p_lock_from timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  insert into academy_enrollments (user_id, path_code, gate, lock_from, source, enrolled_by)
  select p_user, c, true, p_lock_from, p_source, p_by from unnest(app.academy_paths_of(p_user)) c where c <> 'admin'
  on conflict (user_id, path_code) do update set gate = true;
  get diagnostics n = row_count;
  return n;
end $$;

-- ================================================================ 5. Hire: everything in the database, in one transaction
create or replace function app.hire_onboard(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications := app.hiring_lock(p_by, nullif(p ->> 'id', '')::uuid);
  r hiring_roles;
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
  v_path text := nullif(p ->> 'function', '');
  m jsonb;
  v_std jsonb;
  v_start date;
  v_basis text;
  v_cents bigint;
  v_cur text;
  v_text text;
  v_name text;
  v_first text;
  v_note text;
  v_due timestamptz;
  v_queue text;
  v_tasks integer := 0;
  v_t uuid;
  d hiring_decisions;
begin
  select * into r from hiring_roles where id = a.role_id;
  v_path := coalesce(v_path, app.hire_default_path(r));
  m := app.hire_path_of(v_path);
  if m is null then raise exception 'Choose the role: customer service, fleet, finance, sales in person, sales remote or field' using errcode = '22023'; end if;
  begin v_start := coalesce(nullif(p ->> 'start_on', '')::date, app.today() + 1);
  exception when others then raise exception 'Check the start date' using errcode = '22023'; end;
  if v_start < app.today() - 30 or v_start > app.today() + 365 then raise exception 'The start date is within a year from today' using errcode = '22023'; end if;
  v_std := app.hire_standard_pay(v_path, r.id);
  v_basis := v_std ->> 'basis';
  if v_basis = 'commission' then v_cents := null; v_cur := null; v_text := v_std ->> 'text';
  else
    v_cents := coalesce(nullif(p ->> 'pay_cents', '')::bigint, (v_std ->> 'cents')::bigint);
    v_cur := coalesce(nullif(upper(p ->> 'pay_currency'), ''), v_std ->> 'currency');
    if v_cents is null or v_cents <= 0 then raise exception 'Enter the pay' using errcode = '22023'; end if;
    if v_cur not in ('USD', 'CAD') then raise exception 'The pay is in USD or CAD' using errcode = '22023'; end if;
    v_text := format('%s %s %s', v_cur, to_char(v_cents / 100.0, 'FM9999990.00'), case v_basis when 'hourly' then 'an hour' else 'a month' end);
  end if;
  if v_user is null or not exists (select 1 from user_roles ur where ur.user_id = v_user and ur.role::text = m ->> 'staff_kind') then
    raise exception 'Create the staff sign-in first (the % portal)', case m ->> 'staff_kind' when 'field' then 'field staff' else 'staff' end using errcode = '23514';
  end if;
  select coalesce(u.full_name, a.full_name) into v_name from users u where u.id = v_user;
  v_first := split_part(btrim(coalesce(v_name, a.full_name)), ' ', 1);

  -- the staff profile: the function, the start date and the pay (the agreement reads them)
  update staff_profiles set started_on = v_start, is_active = true, ended_on = null,
         hourly_rate_cents = case when v_basis = 'hourly' then v_cents::integer else hourly_rate_cents end,
         sales_work_mode = coalesce(m ->> 'work_mode', sales_work_mode), updated_at = now()
   where user_id = v_user;

  -- hired (0173), unless it already is for this person
  -- (the rubric's decision trigger is held: this Hire records the decision and sends its email itself, below)
  perform set_config('app.hiring_decide', 'on', true);
  if not (a.status = 'hired' and a.hired_user_id = v_user) then perform app.hiring_hire(p_by, jsonb_build_object('id', a.id, 'user_id', v_user)); end if;
  perform set_config('app.hiring_decide', '', true);
  select * into a from job_applications where id = a.id;

  -- the interview items close: a call slot still ahead is freed, an open AI interview link closes, open To do's on the candidate are done
  update job_applications set slot_id = null, updated_at = now()
   where id = a.id and slot_id is not null and exists (select 1 from interview_slots s where s.id = job_applications.slot_id and s.starts_at > now());
  update ai_interviews set expires_at = least(coalesce(expires_at, now()), now()), updated_at = now() where application_id = a.id and state in ('sent', 'started');
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Hired'
   where related_table = 'job_applications' and related_id = a.id and status in ('open', 'in_progress', 'waiting');

  -- the welcome email (applicant_hired, 0226) with the next steps: once
  v_note := left(format('Your start date is %s. Next: 1. Choose your password from the invitation email. 2. Sign your staff agreement in your portal. 3. Enter your pay details: %s 4. Start the academy: each section opens once the one before it is passed.',
                        to_char(v_start, 'FMDay, FMMonth FMDD'), app.hiring_url(case when m ->> 'staff_kind' = 'field' then '/staff/field/profile#pay' else '/staff/profile#pay' end)), 600);
  select * into d from hiring_decisions where application_id = a.id;
  if d.sent_at is null then
    insert into hiring_decisions (application_id, outcome, send_email, personal_note, decided_by, decided_at)
    values (a.id, 'hire', true, v_note, p_by, now())
    on conflict (application_id) do update set outcome = 'hire', send_email = true, personal_note = excluded.personal_note, decided_by = p_by, decided_at = now();
    update hiring_decisions set email_code = 'applicant_hired' where application_id = a.id;
    perform app.hiring_decision_apply(a.id, p_by);
  end if;

  -- the academy: their paths, the gate on from today
  perform app.academy_enroll(v_user, p_by, 'hire', now());

  -- the first day: their own To do's, due at 9:00 Toronto time on the start date, and one for the Admins
  v_due := (v_start + time '09:00') at time zone 'America/Toronto';
  v_queue := case when m ->> 'staff_kind' = 'field' then 'fleet' else m ->> 'va_function' end;
  if not exists (select 1 from staff_onboarding where application_id = a.id) then
    for v_t in
      select app.raise_task(p_type => 'first_day', p_title => x.t, p_detail => x.dt, p_related_table => 'users', p_related_id => v_user, p_due_at => v_due,
                            p_priority => 'normal', p_dedupe => 'first_day:' || v_user || ':' || x.k, p_queue => v_queue, p_created_by => p_by)
        from (values
          (1, 'sign_in', 'First day: sign in and turn on two-step sign-in', 'Choose your password from the invitation email, then turn on two-step sign-in in your profile.'),
          (2, 'agreement', 'First day: sign your staff agreement', 'It waits in your portal under Documents. Read it and sign on screen.'),
          (3, 'pay', 'First day: enter your pay details', 'Profile > Pay details: how you want to be paid. Only the last 4 digits are ever shown.'),
          (4, 'academy', 'First day: start the academy', format('Your path: %s. Each section opens once the one before it is passed.', m ->> 'label')),
          (5, 'guide', 'First day: read your guide', 'Guide in your portal: the pages of your role, step by step.')) x(n, k, t, dt)
       order by x.n
    loop
      if v_t is not null then
        update tasks set assigned_to = v_user where id = v_t;
        v_tasks := v_tasks + 1;
      end if;
    end loop;
    if app.raise_task(p_type => 'first_day_admin', p_title => format('First day for %s (%s): say hello and check their setup', coalesce(v_name, a.full_name), m ->> 'label'),
                      p_detail => 'Hiring > the candidate shows the onboarding: the sign-in, the agreement, the pay details, the academy.',
                      p_related_table => 'job_applications', p_related_id => a.id, p_due_at => v_due, p_dedupe => 'first_day_admin:' || a.id, p_queue => 'admin', p_created_by => p_by) is not null then
      v_tasks := v_tasks + 1;
    end if;
  end if;

  insert into staff_onboarding (application_id, user_id, role_id, path, start_on, pay_basis, pay_cents, pay_currency, pay_text, welcome_sent, first_day_tasks, created_by)
  values (a.id, v_user, r.id, v_path, v_start, v_basis, v_cents, v_cur, v_text, true, v_tasks, p_by)
  on conflict (application_id) do update set user_id = excluded.user_id, path = excluded.path, start_on = excluded.start_on, pay_basis = excluded.pay_basis,
         pay_cents = excluded.pay_cents, pay_currency = excluded.pay_currency, pay_text = excluded.pay_text, welcome_sent = true,
         first_day_tasks = greatest(staff_onboarding.first_day_tasks, excluded.first_day_tasks), updated_at = now();
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'hire_onboard', 'job_applications', a.id::text, jsonb_build_object('user_id', v_user, 'function', v_path, 'start_on', v_start, 'pay', v_text));
  return app.hire_status(p_by, jsonb_build_object('id', a.id));
end $$;

-- the agreement step, recorded by the web layer after it sent (or could not yet send) the agreement
create or replace function app.hire_agreement_record(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  update staff_onboarding set agreement_request_id = coalesce(nullif(p ->> 'request_id', '')::uuid, agreement_request_id),
         agreement_missing = coalesce(array(select jsonb_array_elements_text(case when jsonb_typeof(p -> 'missing') = 'array' then p -> 'missing' else '[]'::jsonb end)), '{}'),
         agreement_error = left(nullif(btrim(coalesce(p ->> 'error', '')), ''), 300), updated_at = now()
   where application_id = nullif(p ->> 'id', '')::uuid;
  if not found then raise exception 'This candidate was not hired with one-step Hire' using errcode = 'P0002'; end if;
  return app.hire_status(p_by, jsonb_build_object('id', p ->> 'id'));
end $$;

-- ================================================================ 6. the status card
create or replace function app.staff_payout_masked(x staff_payout_accounts) returns text
language sql immutable as $$
  select case x.method
    when 'bank_transfer' then format('Bank account%s ending %s', coalesce(' at ' || x.bank_name, ''), x.account_last4)
    when 'gcash' then format('GCash ending %s', x.account_last4)
    when 'onlinejobs' then 'Through OnlineJobs.ph'
    else format('%s to %s', case x.method when 'e_transfer' then 'Interac e-Transfer' when 'paypal' then 'PayPal' else 'Wise' end,
                regexp_replace(x.email, '^(.).*(@.*)$', '\1***\2')) end
$$;

create or replace function app.hire_status(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  o staff_onboarding;
  a job_applications;
  u users;
  sr sign_requests;
  pa staff_payout_accounts;
  v_signed_in boolean;
  v_paths jsonb;
  v_open integer;
begin
  perform app.assert_admin(p_by);
  select * into o from staff_onboarding where application_id = nullif(p ->> 'id', '')::uuid;
  if o.application_id is null then return jsonb_build_object('onboarding', false); end if;
  select * into a from job_applications where id = o.application_id;
  select * into u from users where id = o.user_id;
  select * into sr from sign_requests where id = o.agreement_request_id;
  if sr.id is null then
    select * into sr from sign_requests where staff_user_id = o.user_id and doc_type = 'staff_agreement' and status <> 'voided' order by sent_at desc nulls last limit 1;
  end if;
  select * into pa from staff_payout_accounts where user_id = o.user_id and is_current;
  v_signed_in := u.last_sign_in_at is not null;
  select coalesce(jsonb_agg(jsonb_build_object('path', e.path_code, 'title', ap.title,
           'passed', (select count(*) from academy_path_sections ps where ps.path_code = e.path_code and app.academy_passed(o.user_id, ps.section_id)),
           'sections', (select count(*) from academy_path_sections ps where ps.path_code = e.path_code), 'gate', e.gate) order by ap.sort), '[]'::jsonb)
    into v_paths from academy_enrollments e join academy_paths ap on ap.code = e.path_code where e.user_id = o.user_id;
  select count(*) into v_open from tasks t where t.task_type = 'first_day' and t.related_id = o.user_id and t.status in ('open', 'in_progress', 'waiting');
  return jsonb_build_object('onboarding', true, 'user_id', o.user_id, 'name', coalesce(u.full_name, a.full_name), 'email', u.email,
    'function', o.path, 'function_label', app.hire_path_of(o.path) ->> 'label', 'start_on', o.start_on, 'pay', o.pay_text, 'hired_at', o.created_at,
    'pay_basis', o.pay_basis, 'pay_cents', o.pay_cents, 'pay_currency', o.pay_currency,
    'steps', jsonb_build_array(
      jsonb_build_object('key', 'account', 'label', 'Staff sign-in and invitation', 'state', 'done',
        'detail', case when v_signed_in then 'Signed in' else format('Invitation sent to %s; not signed in yet', u.email) end),
      jsonb_build_object('key', 'agreement', 'label', 'Staff agreement (e-signature)',
        'state', case when sr.status = 'signed' then 'done' when sr.id is not null then 'waiting' else 'todo' end,
        'detail', case when sr.status = 'signed' then 'Signed ' || to_char(sr.signed_at at time zone 'America/Toronto', 'Mon DD')
                       when sr.id is not null then 'Sent; waiting for their signature'
                       when cardinality(o.agreement_missing) > 0 then 'Waiting for: ' || array_to_string(o.agreement_missing, ', ') || ' (they enter it in their profile; then press Send the agreement)'
                       else coalesce('Not sent: ' || o.agreement_error, 'Not sent yet') end,
        'missing', to_jsonb(o.agreement_missing)),
      jsonb_build_object('key', 'pay', 'label', 'Pay details', 'state', case when pa.id is null then 'waiting' when pa.verified_at is null then 'waiting' else 'done' end,
        'detail', case when pa.id is null then 'Waiting for them to enter it in their portal' when pa.verified_at is null then app.staff_payout_masked(pa) || ': verify it' else app.staff_payout_masked(pa) || ', verified' end,
        'payout_id', pa.id, 'verify', pa.id is not null and pa.verified_at is null),
      jsonb_build_object('key', 'academy', 'label', 'Academy (gate on)', 'state', case when jsonb_array_length(v_paths) = 0 then 'todo'
                          when not exists (select 1 from jsonb_array_elements(v_paths) x where (x ->> 'passed')::int < (x ->> 'sections')::int) then 'done' else 'waiting' end,
        'detail', coalesce((select string_agg(format('%s: %s of %s sections passed', x ->> 'title', x ->> 'passed', x ->> 'sections'), '; ') from jsonb_array_elements(v_paths) x), 'Not enrolled')),
      jsonb_build_object('key', 'first_day', 'label', 'First-day To do''s', 'state', case when o.first_day_tasks = 0 then 'todo' when v_open = 0 then 'done' else 'waiting' end,
        'detail', format('%s scheduled for %s; %s still open', o.first_day_tasks, to_char(o.start_on, 'Mon DD'), v_open)),
      jsonb_build_object('key', 'hired', 'label', 'Hired, welcome email, interview items closed', 'state', case when a.status = 'hired' then 'done' else 'todo' end,
        'detail', case when a.status = 'hired' then 'Welcome email sent with the next steps' else 'Not marked hired' end)));
end $$;

-- ================================================================ 7. the pay details (the staff member's own; Admin verifies)
create or replace function app.staff_payout_read(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('current', (select jsonb_build_object('id', x.id, 'method', x.method, 'shown', app.staff_payout_masked(x), 'account_holder', x.account_holder,
                                         'verified', x.verified_at is not null, 'at', x.created_at) from staff_payout_accounts x where x.user_id = p_user and x.is_current),
    'methods', '["bank_transfer","e_transfer","paypal","wise","gcash","onlinejobs"]'::jsonb)
$$;

create or replace function app.staff_payout_submit(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_m text := coalesce(p ->> 'method', '');
  v_id uuid;
  v_name text;
begin
  if not exists (select 1 from user_roles r where r.user_id = p_user and r.role in ('va', 'field')) then
    raise exception 'Pay details are for staff' using errcode = '42501';
  end if;
  if v_m not in ('bank_transfer', 'e_transfer', 'paypal', 'wise', 'gcash', 'onlinejobs') then raise exception 'Choose how you want to be paid' using errcode = '22023'; end if;
  if length(btrim(coalesce(p ->> 'account_holder', ''))) < 2 then raise exception 'Enter the account holder''s name' using errcode = '22023'; end if;
  if v_m in ('bank_transfer', 'gcash') and (nullif(p ->> 'account_no', '') is null or coalesce(p ->> 'account_last4', '') !~ '^\d{4}$') then
    raise exception 'Enter the account number' using errcode = '22023';
  end if;
  if v_m = 'bank_transfer' and nullif(btrim(coalesce(p ->> 'bank_name', '')), '') is null and coalesce(p ->> 'institution_no', '') !~ '^\d{3}$' then
    raise exception 'Enter the bank' using errcode = '22023';
  end if;
  if v_m in ('e_transfer', 'paypal', 'wise') and coalesce(p ->> 'email', '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter the email address' using errcode = '22023'; end if;
  update staff_payout_accounts set is_current = false where user_id = p_user and is_current;
  insert into staff_payout_accounts (user_id, method, account_holder, country, bank_name, institution_no, transit_no, account_no, account_last4, email, key_version, submitted_by)
  values (p_user, v_m, btrim(p ->> 'account_holder'), nullif(btrim(coalesce(p ->> 'country', '')), ''), nullif(btrim(coalesce(p ->> 'bank_name', '')), ''),
          nullif(p ->> 'institution_no', ''), nullif(p ->> 'transit_no', ''), case when v_m in ('bank_transfer', 'gcash') then p ->> 'account_no' end,
          case when v_m in ('bank_transfer', 'gcash') then p ->> 'account_last4' end, case when v_m in ('e_transfer', 'paypal', 'wise') then lower(btrim(p ->> 'email')) end,
          nullif(p ->> 'key_version', '')::integer, p_user)
  returning id into v_id;
  select coalesce(full_name, email) into v_name from users where id = p_user;
  perform app.raise_task(p_type => 'verify_staff_payout', p_title => format('Verify new pay details: %s', v_name),
    p_detail => 'Confirm them with the staff member (a call or a message they started), then press Verify on their onboarding card or staff page.',
    p_related_table => 'staff_payout_accounts', p_related_id => v_id, p_queue => 'admin', p_dedupe => 'verify_staff_payout:' || v_id, p_created_by => p_user);
  update tasks set status = 'done', completed_at = now(), completed_by = p_user, completion_note = 'Pay details entered'
   where task_type = 'first_day' and related_id = p_user and dedupe_key = 'first_day:' || p_user || ':pay' and status in ('open', 'in_progress', 'waiting');
  return app.staff_payout_read(p_user);
end $$;

create or replace function app.staff_payout_verify(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare x staff_payout_accounts;
begin
  perform app.assert_admin(p_by);
  if length(btrim(coalesce(p ->> 'method', ''))) < 3 then raise exception 'Say how the details were verified' using errcode = '22023'; end if;
  update staff_payout_accounts set verified_at = now(), verified_by = p_by, verified_method = left(btrim(p ->> 'method'), 200)
   where id = nullif(p ->> 'id', '')::uuid and is_current returning * into x;
  if x.id is null then raise exception 'Those pay details are not the current ones' using errcode = 'P0002'; end if;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by where task_type = 'verify_staff_payout' and related_id = x.id and status in ('open', 'in_progress', 'waiting');
  return jsonb_build_object('id', x.id, 'shown', app.staff_payout_masked(x), 'verified', true);
end $$;

-- ================================================================ 8. the door
do $$ begin
  if to_regprocedure('app.door_pre0730(uuid,text,text,text,jsonb)') is null then
    alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0730;
  end if;
end $$;

create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if (p_call = 'admin_read' and p_name in ('hire_preview', 'hire_status')) or (p_call = 'admin_do' and p_name in ('hire_onboard', 'hire_agreement_record', 'staff_payout_verify')) then
    perform app.door_begin(p_user, p_aal);
    perform app.assert_admin(p_user);
    return case p_name
      when 'hire_preview' then app.hire_preview(p_user, p_)
      when 'hire_status' then app.hire_status(p_user, p_)
      when 'hire_onboard' then app.hire_onboard(p_user, p_)
      when 'hire_agreement_record' then app.hire_agreement_record(p_user, p_)
      else app.staff_payout_verify(p_user, p_) end;
  end if;
  if (p_call in ('va_read', 'field_read') and p_name = 'my_pay_details') or (p_call in ('va_do', 'field_do') and p_name = 'my_pay_details_save') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'my_pay_details' then app.staff_payout_read(p_user) else app.staff_payout_submit(p_user, p_) end;
  end if;
  return app.door_pre0730(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['door', 'door_pre0730', 'hire_path_of', 'hire_default_path', 'hire_standard_pay', 'hire_preview', 'academy_enroll',
             'hire_onboard', 'hire_agreement_record', 'staff_payout_masked', 'hire_status', 'staff_payout_read', 'staff_payout_submit', 'staff_payout_verify'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
