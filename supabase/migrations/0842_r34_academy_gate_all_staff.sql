-- 0842_r34_academy_gate_all_staff.sql
-- Release 34 (docs/changes/2026-11-08-r34-academy-gate-all-staff.md). The owner's rule: every staff account that exists
-- now is held by the academy gate until it passes the academy, not only the people hired with one-step Hire (0840).
-- Each current staff member (a va or field role, not an Admin, not a test account) who has not finished the academy
-- gets gated enrollments from an Admin (source 'admin', lock_from now) for every path of their functions, so
-- app.academy_locked (0840) holds them from now. Someone an Admin already waived stays open; the waiver is the Admin's
-- choice and is undone with Take the waiver back. Test accounts are left out so the site checks keep running.

insert into academy_enrollments (user_id, path_code, gate, lock_from, source, enrolled_by)
select u.id, c, true, now(), 'admin', null
  from users u
  cross join lateral unnest(app.academy_paths_of(u.id)) c
 where c <> 'admin'
   and not u.is_test
   and not app.user_is_admin(u.id)
   and exists (select 1 from user_roles r where r.user_id = u.id and r.role in ('va', 'field'))
   and not app.academy_done(u.id)
on conflict (user_id, path_code) do update
   set gate = true,
       source = case when academy_enrollments.source = 'hire' then 'hire' else 'admin' end,
       lock_from = least(academy_enrollments.lock_from, excluded.lock_from);

insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
select null, 'academy_gate_all_staff', 'users', u.id::text, jsonb_build_object('migration', '0842', 'held_from', now())
  from users u
 where not u.is_test and not app.user_is_admin(u.id)
   and exists (select 1 from user_roles r where r.user_id = u.id and r.role in ('va', 'field'))
   and not app.academy_done(u.id);
