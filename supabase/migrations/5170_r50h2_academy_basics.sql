-- 5170 (R50 hotfix 2, academy; docs/changes/2026-11-27-r50-hotfix2-academy.md): the basics open the portal, the full academy
-- opens the payouts. The owner (Nov 27): "it causes a huge backlog. The first sections that cover all the basics of the
-- business ... unlock portal access and work; the full academy is required only for commission/pay payouts (gate payouts, show
-- the reason)." and "Admins can open any lesson and quiz directly without having done it."
--   1. academy_paths.core_count: the first N sections of a path (in its order) are its basics. Customer service 5 (prices and
--      deposits, coverage and drivers, trip rules, requests, documents and signing), Sales in person 6 (the same three, requests
--      and quotes, documents and signing, selling in person), Sales remote 5, Field 5 (trip rules, the handover, the return and
--      cash, coverage and drivers, the field Today, moved up from 8th to 5th), Finance 5, Fleet 4, Admin 4, the renter's side 0.
--   2. app.academy_done(uid), which the academy gate (academy_locked), the onboarding steps (staff_onboarding_state, so the
--      portal and the database role checks), the leads gate (staff_academy_cleared, 5071) and the Welcome step read, is now
--      "every basics section of the person's paths passed". The former rule (every section) is app.academy_full_done (renamed,
--      so nothing else changes meaning). The leads gate keeps its Sales rule on the Sales path's basics.
--   3. Payouts: app.academy_pay_hold(uid) gives the reason a person's commission and pay are held ("Academy not finished: 31 of
--      52 sections passed ..."), or null for an Admin, a test account, an exempt or waived person, or one who passed every
--      section of their paths (the Sales path too when they work Sales). Recording a commission payout or a pay line as paid is
--      refused with that reason (triggers, so every path: commission_payout_record, field_pay_line_paid, payroll_pay_all and the
--      connector). Record all payments skips held lines and counts them; each held person is told (alert academy_pay_held).
--      The payroll line carries academy_hold for the Admin's table and the person's own stubs.
--   4. Admins: their academy lists every path, every section open (lessons and quiz), without passing the one before.
-- No applied migration is edited: academy_done is renamed and replaced; staff_academy_cleared, academy_gate_state,
-- academy_path_progress, academy_home, staff_academy_count and payroll_line_json are replaced (same signatures, grants kept)
-- or wrapped; payroll_pay_all is patched in place.
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
  if position(p_old in d) = 0 then raise exception '5170: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the basics
alter table academy_paths add column if not exists core_count int not null default 0 check (core_count between 0 and 40);
comment on column academy_paths.core_count is 'The basics (5170): the first N sections of the path, in its order. Passing the basics of every path of a person opens their portal and work; the full path is needed before commission and pay are paid out.';

update academy_paths p set core_count = v.n
  from (values ('cs', 5), ('sales_in_person', 6), ('sales_remote', 5), ('field', 5), ('finance', 5), ('fleet', 4), ('admin', 4), ('renter_side', 0)) v(code, n)
 where p.code = v.code;

-- the field Today is a basic of field work: 8th to 5th, the sections between move down one
do $$
declare v_today uuid := (select id from academy_sections where slug = 'new-r35-field-today');
begin
  if v_today is null or not exists (select 1 from academy_path_sections where path_code = 'field' and section_id = v_today) then return; end if;
  update academy_path_sections set sort = sort + 1000 where path_code = 'field';
  update academy_path_sections ps set sort = x.n
    from (select section_id, row_number() over (order by case when section_id = v_today then 4.5 else sort - 1000 end) as n
            from academy_path_sections where path_code = 'field') x
   where ps.path_code = 'field' and ps.section_id = x.section_id;
end $$;

-- is this section of the path one of its basics?
create function app.academy_is_core(p_path text, p_section uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce((select (select count(*) from academy_path_sections x where x.path_code = ps.path_code and x.sort <= ps.sort) <= p.core_count
                     from academy_path_sections ps join academy_paths p on p.code = ps.path_code
                    where ps.path_code = p_path and ps.section_id = p_section), false)
$$;

-- the full rule keeps its name's meaning under a new name; academy_done becomes the basics
alter function app.academy_done(uuid) rename to academy_full_done;
comment on function app.academy_full_done(uuid) is 'Every section of the person''s paths passed (the academy_done of 0207 to 0931; renamed in 5170).';

create function app.academy_done(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select not exists (
    select 1 from academy_path_sections ps
     where ps.path_code = any (app.academy_paths_of(p_user))
       and not (ps.path_code in ('sales_in_person', 'sales_remote')
                and exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.sales_opt_in_at is not null))
       and app.academy_is_core(ps.path_code, ps.section_id)
       and not app.academy_passed(p_user, ps.section_id))
$$;
comment on function app.academy_done(uuid) is 'The basics passed (5170): every basics section (academy_paths.core_count) of the person''s paths. Opens the portal and work.';
select pg_temp.copy_grants('app.academy_done(uuid)', 'app.academy_full_done(uuid)');

-- the counts a person sees: the basics and the whole academy, each section once
create function app.academy_counts(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object(
    'core_passed', count(*) filter (where s.core and app.academy_passed(p_user, s.section_id)), 'core_total', count(*) filter (where s.core),
    'passed', count(*) filter (where app.academy_passed(p_user, s.section_id)), 'total', count(*))
    from (select ps.section_id, bool_or(app.academy_is_core(ps.path_code, ps.section_id)) as core
            from academy_path_sections ps
           where ps.path_code = any (app.academy_paths_of(p_user) || case when exists (select 1 from staff_profiles sp where sp.user_id = p_user
                                       and ('sales' = any (coalesce(sp.functions, '{}')) or sp.sales_opt_in_at is not null)) then array[app.fx_sales_path(p_user)] else '{}'::text[] end)
             and ps.path_code <> 'admin'
           group by ps.section_id) s
$$;
select pg_temp.copy_grants('app.academy_counts(uuid)', 'app.academy_done(uuid)');

-- the leads gate (5071): the basics, and the Sales path's basics for a person who works Sales
create or replace function app.staff_academy_cleared(p_user uuid) returns boolean
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  sp staff_profiles;
  v_prev text := coalesce(current_setting('app.onboarding_pass', true), '');
  v_ok boolean;
begin
  if p_user is null or coalesce(app.user_is_admin(p_user), false) or app.staff_is_test(p_user) then return true; end if;
  select * into sp from staff_profiles where user_id = p_user;
  if sp.user_id is null or sp.onboarding_exempt or app.academy_waived(p_user) then return true; end if;
  perform set_config('app.onboarding_pass', p_user::text, true);
  v_ok := app.academy_done(p_user)
      and (not ('sales' = any (coalesce(sp.functions, '{}')) or sp.sales_opt_in_at is not null)
           or not exists (select 1 from academy_path_sections ps where ps.path_code = app.fx_sales_path(p_user)
                           and app.academy_is_core(ps.path_code, ps.section_id) and not app.academy_passed(p_user, ps.section_id)));
  perform set_config('app.onboarding_pass', v_prev, true);
  return coalesce(v_ok, false);
end $$;

-- the nudges and Welcome count the basics (what opens the portal)
create or replace function app.staff_academy_count(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('passed', (c ->> 'core_passed')::int, 'total', (c ->> 'core_total')::int,
                            'full_passed', (c ->> 'passed')::int, 'full_total', (c ->> 'total')::int)
    from (select app.academy_counts(p_user) as c) x
$$;

-- ================================================================ 3. the payouts
create function app.academy_pay_hold(p_user uuid) returns text
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  sp staff_profiles;
  c jsonb;
begin
  if p_user is null or coalesce(app.user_is_admin(p_user), false) or app.staff_is_test(p_user) then return null; end if;
  select * into sp from staff_profiles where user_id = p_user;
  if sp.user_id is null or sp.onboarding_exempt or app.academy_waived(p_user) then return null; end if;
  c := app.academy_counts(p_user);
  if (c ->> 'passed')::int >= (c ->> 'total')::int then return null; end if;
  return format('Academy not finished: %s of %s sections passed. Commission and pay are paid once the whole academy is passed (or an Admin waives it).',
                c ->> 'passed', c ->> 'total');
end $$;
comment on function app.academy_pay_hold(uuid) is 'Why a person''s commission and pay are held (5170): the whole academy not passed. Null when nothing holds them.';
select pg_temp.copy_grants('app.academy_pay_hold(uuid)', 'app.academy_done(uuid)');

create function app.academy_pay_guard() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v text;
begin
  if tg_table_name = 'field_pay_lines' then
    if new.status <> 'paid' or old.status = 'paid' then return new; end if;
    v := app.academy_pay_hold(new.staff_id);
  else
    v := app.academy_pay_hold(new.staff_id);
  end if;
  if v is not null then raise exception '%', v using errcode = '23514'; end if;
  return new;
end $$;
revoke all on function app.academy_pay_guard() from public, anon, authenticated;

create trigger a_academy_pay_guard before insert on staff_commission_payouts for each row execute function app.academy_pay_guard();
create trigger a_academy_pay_guard before update of status on field_pay_lines for each row execute function app.academy_pay_guard();

-- Record all payments: held lines stay pending and their people are told
select pg_temp.patch_fn('app.payroll_pay_all(uuid,jsonb)'::regprocedure,
  'for l in select * from field_pay_lines where run_id = r.id and status = ''pending'' and gross_cents > 0 order by statement_number loop',
  'for l in select * from field_pay_lines where run_id = r.id and status = ''pending'' and gross_cents > 0 and app.academy_pay_hold(staff_id) is null order by statement_number loop');
select pg_temp.patch_fn('app.payroll_pay_all(uuid,jsonb)'::regprocedure,
  'return jsonb_build_object(''run_id'', r.id, ''paid'', n);',
  'for l in select * from field_pay_lines where run_id = r.id and status = ''pending'' and gross_cents > 0 and app.academy_pay_hold(staff_id) is not null loop
    perform app.staff_alert(''academy_pay_held'', ''field_pay_line'', l.id, ''held'', ''Your pay is held until the academy is finished'',
      app.academy_pay_hold(l.staff_id) || '' Open the academy and pass the sections left.'', jsonb_build_object(''assigned_to'', l.staff_id, ''path_staff'', ''/staff/academy''));
  end loop;
  return jsonb_build_object(''run_id'', r.id, ''paid'', n,
    ''held'', (select count(*) from field_pay_lines x where x.run_id = r.id and x.status = ''pending'' and x.gross_cents > 0 and app.academy_pay_hold(x.staff_id) is not null));');

alter function app.payroll_line_json(field_pay_lines) rename to payroll_line_json_pre5170;
create function app.payroll_line_json(l field_pay_lines) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.payroll_line_json_pre5170(l) || jsonb_build_object('academy_hold', case when l.status <> 'paid' then app.academy_pay_hold(l.staff_id) end)
$$;
select pg_temp.copy_grants('app.payroll_line_json(field_pay_lines)', 'app.payroll_line_json_pre5170(field_pay_lines)');

insert into staff_alert_rules (rule, label, grp, who, tier, topic, enabled, wired, fixed, hint, sort)
values ('academy_pay_held', 'Pay held: academy not finished', 'Staff', '{assigned}', 'normal', 'alerts', true, true, false,
        'To the person: their pay or commission was not paid with the others because the whole academy is not passed yet (5170).', 118)
on conflict (rule) do nothing;

-- ================================================================ 2 and 4. what the academy shows
-- each section: open for an Admin, and whether it is one of the basics; the path: its basics passed
create or replace function app.academy_path_progress(p_user uuid, p_path text) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('code', p.code, 'title', p.title, 'blurb', p.blurb, 'core_count', p.core_count,
    'sections', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'slug', s.slug, 'title', s.title, 'blurb', s.blurb, 'sort', ps.sort,
        'open', app.user_is_admin(p_user) or app.academy_open(p_user, p.code, s.id), 'passed', app.academy_passed(p_user, s.id),
        'core', app.academy_is_core(p.code, s.id),
        'unlocked_early', exists (select 1 from academy_unlocks u where u.user_id = p_user and u.section_id = s.id),
        'best_bps', (select max(a.score_bps) from academy_attempts a where a.user_id = p_user and a.section_id = s.id and a.created_at > app.academy_since(p_user, s.id)),
        'attempts', (select count(*) from academy_attempts a where a.user_id = p_user and a.section_id = s.id and a.created_at > app.academy_since(p_user, s.id)),
        'flagged', (select count(*) from academy_attempts a where a.user_id = p_user and a.section_id = s.id and a.flagged),
        'reset_at', (select r.reset_at from academy_resets r where r.user_id = p_user and r.section_id = s.id),
        'lessons', (select count(*) from academy_lessons l where l.section_id = s.id),
        'viewed', (select count(*) from academy_lesson_views v join academy_lessons l on l.id = v.lesson_id where v.user_id = p_user and l.section_id = s.id),
        'questions', (select count(*) from academy_questions q where q.section_id = s.id)) order by ps.sort)
      from academy_path_sections ps join academy_sections s on s.id = ps.section_id where ps.path_code = p.code), '[]'::jsonb),
    'passed', not exists (select 1 from academy_path_sections ps where ps.path_code = p.code and not app.academy_passed(p_user, ps.section_id)),
    'core_passed', not exists (select 1 from academy_path_sections ps where ps.path_code = p.code and app.academy_is_core(p.code, ps.section_id)
                                 and not app.academy_passed(p_user, ps.section_id)))
  from academy_paths p where p.code = p_path
$$;

-- the home: an Admin sees every path; everyone sees the basics, the whole count and what holds their payouts
alter function app.academy_home(uuid) rename to academy_home_pre5170;
create function app.academy_home(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.academy_home_pre5170(p_user)
    || case when app.user_is_admin(p_user) then jsonb_build_object('paths', coalesce((select jsonb_agg(app.academy_path_progress(p_user, ap.code) order by ap.sort)
                                                                                    from academy_paths ap), '[]'::jsonb), 'all_paths', true)
            else '{}'::jsonb end
    || jsonb_build_object('counts', app.academy_counts(p_user), 'basics_done', app.academy_done(p_user), 'pay_hold', app.academy_pay_hold(p_user))
$$;
select pg_temp.copy_grants('app.academy_home(uuid)', 'app.academy_home_pre5170(uuid)');

-- an Admin's view of one person (Admin > Academy): the basics and the whole academy
create or replace function app.academy_gate_state(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('user_id', p_user, 'locked', app.academy_locked(p_user), 'done', app.academy_done(p_user),
    'passed', (c ->> 'core_passed')::int, 'sections', (c ->> 'core_total')::int,
    'full_done', app.academy_pay_hold(p_user) is null, 'full_passed', (c ->> 'passed')::int, 'full_sections', (c ->> 'total')::int,
    'pay_hold', app.academy_pay_hold(p_user),
    'lock_from', (select min(e.lock_from) from academy_enrollments e where e.user_id = p_user and e.gate and e.source in ('hire', 'admin')),
    'waiver', (select jsonb_build_object('reason', w.reason, 'at', w.waived_at, 'by', (select u.full_name from users u where u.id = w.waived_by))
                 from academy_waivers w where w.user_id = p_user and w.revoked_at is null))
    from (select app.academy_counts(p_user) as c) x
$$;

-- Welcome's academy step: the basics (done opens the portal), with the whole count beside it
alter function app.staff_welcome(uuid) rename to staff_welcome_pre5170;
create function app.staff_welcome(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v jsonb := app.staff_welcome_pre5170(p_user);
  c jsonb;
begin
  if jsonb_typeof(v -> 'steps') <> 'array' then return v; end if;
  c := app.academy_counts(p_user);
  return v || jsonb_build_object('steps', (select jsonb_agg(case when s ->> 'key' = 'academy'
      then s || jsonb_build_object('passed', (c ->> 'core_passed')::int, 'sections', (c ->> 'core_total')::int,
                                   'full_passed', (c ->> 'passed')::int, 'full_sections', (c ->> 'total')::int,
                                   'done', coalesce((s ->> 'waived')::boolean, false) or app.academy_done(p_user))
      else s end order by n) from jsonb_array_elements(v -> 'steps') with ordinality t(s, n)));
end $$;
select pg_temp.copy_grants('app.staff_welcome(uuid)', 'app.staff_welcome_pre5170(uuid)');

-- ================================================================ now
-- the cached onboarding answer of every staff member follows the basics at once (portal and leads)
select app.staff_onboarding_refresh_all();
do $$ begin raise notice '5170: % staff open with the basics passed, % still in the basics',
  (select count(*) from staff_profiles sp where sp.is_active and app.staff_is_member(sp.user_id) and app.academy_done(sp.user_id)),
  (select count(*) from staff_profiles sp where sp.is_active and app.staff_is_member(sp.user_id) and not app.academy_done(sp.user_id)); end $$;

revoke all on function app.academy_is_core(text, uuid) from public, anon, authenticated;
grant execute on function app.academy_is_core(text, uuid) to service_role;
