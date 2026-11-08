-- 0840_r34q_academy_gate_hires_only.sql
-- Release 34, part Q (docs/changes/2026-11-08-r34-ci-fixes.md). The academy gate (0207, on since 0731, Welcome and
-- waivers in 0802) holds only the people it was meant for: a hire made with one-step Hire (an enrollment with
-- source 'hire') or a person an Admin enrolled (source 'admin'), from that enrollment's lock_from, until they pass or an
-- Admin waives it. Staff already working (no enrollment, or the automatic 'existing' enrollment of 0731 and 0802) are
-- never held: the academy keeps recording their progress and the new sections still show on their academy page.
-- Before this, every staff member without an enrollment was held from now, and the 'existing' ones a week later, which
-- shut existing staff (and every staff test account) out of their work pages.
-- create or replace keeps the function's grants (0207).

create or replace function app.academy_locked(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((app.settings()).academy_gate, false) and not app.user_is_admin(p_user)
     and exists (select 1 from user_roles r where r.user_id = p_user and r.role in ('va', 'field'))
     and exists (select 1 from academy_enrollments e where e.user_id = p_user and e.gate and e.source in ('hire', 'admin') and e.lock_from <= now())
     and not app.academy_done(p_user)
     and not app.academy_waived(p_user)
$$;
comment on function app.academy_locked(uuid) is 'The academy gate holds this person (0840): the gate is on, they are staff (not an Admin), they have a gated enrollment from one-step Hire or an Admin (source hire or admin) whose lock_from has come, their paths are not all passed, and no Admin waived it. Staff without such an enrollment are never held.';

-- the date the hold starts, for the academy page and Admin: from the enrollments that can hold (hire or admin) only
create or replace function app.academy_home(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('paths', coalesce((select jsonb_agg(app.academy_path_progress(p_user, c) order by ap.sort) from unnest(app.academy_paths_of(p_user)) c join academy_paths ap on ap.code = c), '[]'::jsonb),
    'gate', coalesce((app.settings()).academy_gate, false), 'locked', app.academy_locked(p_user), 'pass_bps', (app.settings()).academy_pass_bps,
    'lock_from', (select min(e.lock_from) from academy_enrollments e where e.user_id = p_user and e.gate and e.source in ('hire', 'admin')),
    'waived', app.academy_waived(p_user))
$$;

create or replace function app.academy_gate_state(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('user_id', p_user, 'locked', app.academy_locked(p_user), 'done', app.academy_done(p_user),
    'passed', (select count(*) from academy_path_sections ps where ps.path_code = any (app.academy_paths_of(p_user)) and ps.path_code <> 'admin' and app.academy_passed(p_user, ps.section_id)),
    'sections', (select count(*) from academy_path_sections ps where ps.path_code = any (app.academy_paths_of(p_user)) and ps.path_code <> 'admin'),
    'lock_from', (select min(e.lock_from) from academy_enrollments e where e.user_id = p_user and e.gate and e.source in ('hire', 'admin')),
    'waiver', (select jsonb_build_object('reason', w.reason, 'at', w.waived_at, 'by', (select u.full_name from users u where u.id = w.waived_by))
                 from academy_waivers w where w.user_id = p_user and w.revoked_at is null))
$$;
