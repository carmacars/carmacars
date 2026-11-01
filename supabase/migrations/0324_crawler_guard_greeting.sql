-- 0324_crawler_guard_greeting.sql
-- Two owner decisions of November 1, 2026 (docs/changes/2026-11-06-owner-todo-usage-noise.md, section 3; and
-- docs/changes/2026-11-06-greeting-name.md).
--
-- 1. Crawlers. The owner accepts about US$20 to 25 a month of Worker CPU above the allowance for full search and AI
--    coverage: every crawler reaches every page again (robots.txt and the Worker; the caching stays). The guard: when
--    this month's projected CPU cost above the allowance passes crawler_guard_usd (Program settings, US$40), the
--    training crawlers (and every crawler that is not a search or answer crawler) are kept to the core pages until the
--    month ends (crawler_guard_month), and Admin > To do says so. Search and answer crawlers are never limited. It
--    replaces R23's 70% guard (0220: from 70% of the included CPU time every crawler, Google's too, got 503 on the
--    catalog pages): server_jobs_due's cpu_guard is now this guard, read by the Worker (custom-worker.ts).
-- 2. The greeting. One Admin login is shared by the owners; Admin > To do greeted the account's name. users.greeting_name
--    (Settings > My profile) is used when set, else the account's name; my_roles carries it as 'greeting'. The shared
--    account rent@carmacars.ca (the business address in docs/email-aliases.md) gets "Abbas and Mahad" where it has none.
-- No applied migration is edited.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. the crawler guard
alter table program_settings
  add column crawler_guard_usd numeric(10, 2) not null default 40 check (crawler_guard_usd >= 0),
  add column crawler_guard_month date;
comment on column program_settings.crawler_guard_usd is 'Crawlers (0324): when this month''s projected Worker CPU cost above the allowance passes this many US dollars, crawlers other than search and answer crawlers are kept to the core pages until the month ends.';
comment on column program_settings.crawler_guard_month is 'Crawlers (0324): the month the guard turned on in (set by the hourly usage job); it ends with that month.';

-- on for the rest of the month once it turned on (the guard lowers the CPU, so the projection alone would flip it back)
create or replace function app.crawler_guard_on(p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select s.crawler_guard_month = app.month_start(app.local_date(p_now)) from program_settings s
                    where s.id = (app.settings()).id), false)
$$;

-- the hourly check: turns it on for this month when the projection passes the line
create or replace function app.crawler_guard_check(p_now timestamptz default now()) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  m jsonb := app.usage_money('workers_cpu', p_now);
  v_line numeric := (app.settings()).crawler_guard_usd;
begin
  if app.crawler_guard_on(p_now) then return true; end if;
  if coalesce((m ->> 'projected_usd')::numeric, 0) > v_line then
    update program_settings set crawler_guard_month = app.month_start(app.local_date(p_now)) where id = (app.settings()).id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (null, 'crawler_guard_on', 'program_settings', (app.settings()).id::text,
            jsonb_build_object('projected_usd', m -> 'projected_usd', 'line_usd', v_line, 'month', app.month_start(app.local_date(p_now))));
    return true;
  end if;
  return false;
end $$;

alter function app.job_usage_refresh(timestamptz) rename to job_usage_refresh_pre0324;
create function app.job_usage_refresh(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := app.job_usage_refresh_pre0324(p_now);
begin
  return coalesce(v, '{}'::jsonb) || jsonb_build_object('crawler_guard', app.crawler_guard_check(p_now));
end $$;
select pg_temp.copy_grants('app.job_usage_refresh(timestamptz)'::regprocedure, 'app.job_usage_refresh_pre0324(timestamptz)'::regprocedure);

-- the Worker's five-minute tick: cpu_guard is this guard now (0220's 70% rule retired)
alter function app.server_jobs_due() rename to server_jobs_due_pre0324;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := app.server_jobs_due_pre0324();
begin
  return v || jsonb_build_object('cpu_guard', app.crawler_guard_on());
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre0324()'::regprocedure);

-- robots.txt reads it (web/src/app/robots.ts)
create or replace function public.crawler_guard() returns boolean
language sql stable security definer set search_path = public, app as $$ select app.crawler_guard_on() $$;

-- Admin > To do: the note while it is on
alter function app.admin_todo(uuid) rename to admin_todo_pre0324;
create function app.admin_todo(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb := app.admin_todo_pre0324(p_admin);
begin
  if not app.crawler_guard_on() then return v; end if;
  return v || jsonb_build_object('crawler_guard', jsonb_build_object(
    'line_usd', (app.settings()).crawler_guard_usd, 'until', (app.month_start(app.today()) + interval '1 month')::date,
    'projected_usd', app.usage_money('workers_cpu') -> 'projected_usd'));
end $$;
select pg_temp.copy_grants('app.admin_todo(uuid)'::regprocedure, 'app.admin_todo_pre0324(uuid)'::regprocedure);

-- ================================================================ 2. the greeting name
alter table users add column greeting_name text check (greeting_name is null or length(btrim(greeting_name)) between 1 and 60);
comment on column users.greeting_name is 'How Admin > To do and the staff assistant greet this person (0324); empty: the account''s name. For a shared login, for example "Abbas and Mahad".';

alter function app.my_roles(uuid) rename to my_roles_pre0324;
create function app.my_roles(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.my_roles_pre0324(p_user)
         || jsonb_build_object('greeting', (select coalesce(nullif(btrim(u.greeting_name), ''), u.full_name) from users u where u.id = p_user))
$$;
select pg_temp.copy_grants('app.my_roles(uuid)'::regprocedure, 'app.my_roles_pre0324(uuid)'::regprocedure);

-- the Admin frame's gate carries it too (web/src/server/admin/data.ts)
alter function app.admin_gate(uuid) rename to admin_gate_pre0324;
create function app.admin_gate(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.admin_gate_pre0324(p_user)
         || jsonb_build_object('greeting', (select coalesce(nullif(btrim(u.greeting_name), ''), u.full_name) from users u where u.id = p_user))
$$;
select pg_temp.copy_grants('app.admin_gate(uuid)'::regprocedure, 'app.admin_gate_pre0324(uuid)'::regprocedure);

-- Settings > My profile: read and save one's own greeting name (any staff member)
create or replace function app.my_profile(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('email', u.email, 'name', u.full_name, 'greeting_name', u.greeting_name,
                            'greeting', coalesce(nullif(btrim(u.greeting_name), ''), u.full_name))
    from users u where u.id = p_user
$$;
create or replace function app.my_greeting_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v text := nullif(btrim(coalesce(p ->> 'greeting_name', '')), '');
begin
  if v is not null and length(v) > 60 then raise exception 'The greeting name is at most 60 characters' using errcode = '22023'; end if;
  update users set greeting_name = v where id = p_user;
  return app.my_profile(p_user);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0324;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call = 'admin_read' and p_name = 'my_profile') or (p_call = 'admin_do' and p_name = 'my_greeting_save') then
    perform app.door_begin(p_user, p_aal);
    perform app.assert_admin(p_user);
    if p_name = 'my_profile' then return app.my_profile(p_user); end if;
    return app.my_greeting_save(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0324(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0324(uuid, text, text, text, jsonb)'::regprocedure);

-- the shared Admin login: "Abbas and Mahad", only where it has no greeting name yet
update users u set greeting_name = 'Abbas and Mahad'
 where lower(u.email) = 'rent@carmacars.ca' and u.greeting_name is null
   and exists (select 1 from user_roles r where r.user_id = u.id and r.role = 'admin');

-- ================================================================ privileges
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname in ('crawler_guard_on', 'crawler_guard_check', 'job_usage_refresh_pre0324', 'server_jobs_due_pre0324',
                     'admin_todo_pre0324', 'my_roles_pre0324', 'admin_gate_pre0324', 'my_profile', 'my_greeting_save', 'door_pre0324'))
               or (n.nspname = 'public' and p.proname = 'crawler_guard') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
