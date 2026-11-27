-- 5074 (R50 hotfix 2; docs/changes/2026-11-25-r50-hotfix2.md): the townhall staff KPI slide shows real staff only.
-- The owner (Nov 27): the KPI slide showed dummy staff. app.townhall_staff_kpis (4600) listed every staff member: test
-- and Verify accounts (app.staff_is_test: is_test, the test addresses and the "+verify-" form) and people with no KPI at
-- all. Now both are left out: a row needs at least one tracked KPI.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '5074: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.patch_fn('app.townhall_staff_kpis(date)'::regprocedure,
  'where app.staff_is_member(sp.user_id)',
  'where app.staff_is_member(sp.user_id) and not app.staff_is_test(sp.user_id)');
select pg_temp.patch_fn('app.townhall_staff_kpis(date)'::regprocedure,
  'out := out || jsonb_build_array(',
  'continue when v_tracked = 0;
    out := out || jsonb_build_array(');
