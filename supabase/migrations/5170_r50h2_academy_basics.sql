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
--   3. Payouts: app.academy_pay_hold(uid) gives the reason a person's commission, bonuses and referral fees are held ("Academy
--      not finished: 31 of 52 sections passed ..."), or null for an Admin, a test account, an exempt or waived person, or one
--      who passed every section of their paths (the Sales path too when they work Sales). Hours worked are never held: Ontario's
--      Employment Standards Act requires earned wages on the regular pay day, so wages, overtime, salary, vacation pay and the
--      pay line's adjustment are always paid (coordinator, Nov 27; the owner may change this). What is held: a staff commission
--      payout (commission, owner recruit and partner sourced referral fees, adjustments such as a bonus) is refused with the
--      reason (trigger, so every path: commission_payout_record and the connector), and a held person's approved commissions
--      stay out of a new pay line (fp_commissions: carried to the first run after the academy is passed or waived). There are no
--      per-job contractor payouts in the database; they would take the same hold when added. Record all payments pays every
--      line and tells each held person whose commission waits (alert academy_pay_held). The payroll line carries academy_hold
--      (the reason) for the Admin's table and the person's own stubs, as a note: the line stays payable.
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
  if position(p_new in d) > 0 then return; end if;  -- already patched (a re-run)
  if position(p_old in d) = 0 then raise exception '5170: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- re-run safe: rename a function to its _pre name only once (the second run finds the _pre name and leaves both)
create function pg_temp.rename_once(p_fn text, p_args text, p_to text) returns void
language plpgsql as $$
begin
  if to_regprocedure(format('app.%s(%s)', p_to, p_args)) is null then
    execute format('alter function app.%s(%s) rename to %s', p_fn, p_args, p_to);
  end if;
end $$;

-- ================================================================ 1. the basics
alter table academy_paths add column if not exists core_count int not null default 0 check (core_count between 0 and 40);
comment on column academy_paths.core_count is 'The basics (5170): the first N sections of the path, in its order. Passing the basics of every path of a person opens their portal and work; the full path is needed before commission, bonuses and referral fees are paid out (hours worked are always paid).';

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
create or replace function app.academy_is_core(p_path text, p_section uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce((select (select count(*) from academy_path_sections x where x.path_code = ps.path_code and x.sort <= ps.sort) <= p.core_count
                     from academy_path_sections ps join academy_paths p on p.code = ps.path_code
                    where ps.path_code = p_path and ps.section_id = p_section), false)
$$;

-- the full rule keeps its name's meaning under a new name; academy_done becomes the basics
select pg_temp.rename_once('academy_done', 'uuid', 'academy_full_done');
comment on function app.academy_full_done(uuid) is 'Every section of the person''s paths passed (the academy_done of 0207 to 0931; renamed in 5170).';

create or replace function app.academy_done(p_user uuid) returns boolean
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
create or replace function app.academy_counts(p_user uuid) returns jsonb
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
create or replace function app.academy_pay_hold(p_user uuid) returns text
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
  return format('Academy not finished: %s of %s sections passed. Commission, bonuses and referral fees are paid once the whole academy is passed (or an Admin waives it). Hours worked are always paid.',
                c ->> 'passed', c ->> 'total');
end $$;
comment on function app.academy_pay_hold(uuid) is 'Why a person''s commission, bonuses and referral fees are held (5170): the whole academy not passed. Never holds pay for hours worked (Employment Standards Act; the owner may change this). Null when nothing is held.';
select pg_temp.copy_grants('app.academy_pay_hold(uuid)', 'app.academy_done(uuid)');

create or replace function app.academy_pay_guard() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v text;
begin
  -- only the statement path itself (field_pay_line_paid sets app.pay_line_commission around its insert): a line's commission
  -- was taken in while nothing held it (fp_commissions), so it is paid with the hours. An Admin's commission_payout_record,
  -- with any method (pay_statement included), meets the hold unless the academy is waived.
  if new.method = 'pay_statement' and coalesce(current_setting('app.pay_line_commission', true), '') <> '' then return new; end if;
  v := app.academy_pay_hold(new.staff_id);
  if v is not null then raise exception '%', v using errcode = '23514'; end if;
  return new;
end $$;
revoke all on function app.academy_pay_guard() from public, anon, authenticated;
grant execute on function app.academy_pay_guard() to service_role;

drop trigger if exists a_academy_pay_guard on staff_commission_payouts;
create trigger a_academy_pay_guard before insert on staff_commission_payouts for each row execute function app.academy_pay_guard();

select pg_temp.patch_fn('app.field_pay_line_paid(uuid,jsonb)'::regprocedure,
  '    insert into staff_commission_payouts (staff_id, method, reference, paid_on, pay_period, amount_cents, note, recorded_by)
    values (l.staff_id, ''pay_statement''',
  '    perform set_config(''app.pay_line_commission'', l.id::text, true);
    insert into staff_commission_payouts (staff_id, method, reference, paid_on, pay_period, amount_cents, note, recorded_by)
    values (l.staff_id, ''pay_statement''');
select pg_temp.patch_fn('app.field_pay_line_paid(uuid,jsonb)'::regprocedure,
  '    returning id into v_payout;
    update staff_commissions set status = ''paid''',
  '    returning id into v_payout;
    perform set_config(''app.pay_line_commission'', '''', true);
    update staff_commissions set status = ''paid''');

-- a held person's approved commissions stay out of a new pay line (carried); the hours in it are paid as always
select pg_temp.rename_once('fp_commissions', 'uuid, date', 'fp_commissions_pre5170');
create or replace function app.fp_commissions(p_staff uuid, p_end date) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case when app.academy_pay_hold(p_staff) is null then c
              else jsonb_build_object('ids', '[]'::jsonb, 'cents', 0, 'carried_cents', (c ->> 'cents')::bigint + (c ->> 'carried_cents')::bigint) end
    from (select app.fp_commissions_pre5170(p_staff, p_end) as c) x
$$;
select pg_temp.copy_grants('app.fp_commissions(uuid,date)', 'app.fp_commissions_pre5170(uuid,date)');

-- the reason a person's commission for a pay period is held: only when the academy holds them and an approved commission of
-- the period is actually waiting (what fp_commissions would have taken in); else null
create or replace function app.academy_commission_held(p_staff uuid, p_end date) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select h from (select app.academy_pay_hold(p_staff) as h) x
   where h is not null and (app.fp_commissions_pre5170(p_staff, p_end) ->> 'cents')::bigint > 0
$$;
select pg_temp.copy_grants('app.academy_commission_held(uuid,date)', 'app.academy_pay_hold(uuid)');

-- Record all payments pays every line; each person whose commission is held is told once a pay period
select pg_temp.patch_fn('app.payroll_pay_all(uuid,jsonb)'::regprocedure,
  'return jsonb_build_object(''run_id'', r.id, ''paid'', n);',
  'for l in select x.* from field_pay_lines x where x.run_id = r.id and app.academy_commission_held(x.staff_id, r.period_end) is not null
      and not exists (select 1 from app_events e join field_pay_lines y on y.id = e.entity_id join field_pay_runs ry on ry.id = y.run_id
                       where e.entity = ''field_pay_line'' and e.payload ->> ''rule'' = ''academy_pay_held''
                         and y.staff_id = x.staff_id and ry.period_start = r.period_start) loop
    perform app.staff_alert(''academy_pay_held'', ''field_pay_line'', l.id, ''held'', ''Your commission is held until the academy is finished'',
      app.academy_pay_hold(l.staff_id) || '' Open the academy and pass the sections left.'', jsonb_build_object(''assigned_to'', l.staff_id, ''path_staff'', ''/staff/academy''));
  end loop;
  return jsonb_build_object(''run_id'', r.id, ''paid'', n,
    ''commission_held'', (select count(*) from field_pay_lines x where x.run_id = r.id and app.academy_commission_held(x.staff_id, r.period_end) is not null));');

select pg_temp.rename_once('payroll_line_json', 'field_pay_lines', 'payroll_line_json_pre5170');
create or replace function app.payroll_line_json(l field_pay_lines) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.payroll_line_json_pre5170(l) || jsonb_build_object('academy_hold', case when l.status <> 'paid'
    then (select app.academy_commission_held(l.staff_id, r.period_end) from field_pay_runs r where r.id = l.run_id) end)
$$;
select pg_temp.copy_grants('app.payroll_line_json(field_pay_lines)', 'app.payroll_line_json_pre5170(field_pay_lines)');

insert into staff_alert_rules (rule, label, grp, who, tier, topic, enabled, wired, fixed, hint, sort)
values ('academy_pay_held', 'Commission held: academy not finished', 'Staff', '{assigned}', 'normal', 'alerts', true, true, false,
        'To the person: their commission, bonus or referral fee was not paid with their hours because the whole academy is not passed yet (5170). Hours worked are always paid.', 118)
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
select pg_temp.rename_once('academy_home', 'uuid', 'academy_home_pre5170');
create or replace function app.academy_home(p_user uuid) returns jsonb
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
select pg_temp.rename_once('staff_welcome', 'uuid', 'staff_welcome_pre5170');
create or replace function app.staff_welcome(p_user uuid) returns jsonb
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
