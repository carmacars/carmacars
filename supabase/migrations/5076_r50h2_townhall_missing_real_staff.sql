-- 5076 (R50 hotfix 2, CI doctor, Nov 27): the townhall status counts as missing only the staff the deck should show.
-- REQ-070 (the owner, Nov 25): "the KPI slide shows real staff with KPIs only". 5074 made app.townhall_staff_kpis leave out
-- test and Verify accounts and anyone with no tracked KPI, but app.townhall_status (4500, 4600) still listed every staff
-- member not on the deck as missing: the connector and Admin said 7 people were missing from the KPI slide (dummy staff
-- and staff with no KPI), and 99_r50_townhall_deck_more failed on it.
-- Now: staff_missing_kpis lists the real staff with a tracked KPI this week (the rows app.townhall_staff_kpis gives)
-- that the built deck's KPI slide does not show; staff_missing (the team slide) never lists a test or Verify account.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '5076: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- the team slide: a test or Verify account is never missing
select pg_temp.patch_fn('app.townhall_status(uuid, jsonb)'::regprocedure,
  $o$where app.staff_is_member(sp.user_id) and not exists (select 1 from jsonb_array_elements(v_people) x where x ->> 'user_id' = sp.user_id::text);$o$,
  $n$where app.staff_is_member(sp.user_id) and not app.staff_is_test(sp.user_id) and not exists (select 1 from jsonb_array_elements(v_people) x where x ->> 'user_id' = sp.user_id::text);$n$);
-- the KPI slide: missing means a row of app.townhall_staff_kpis (real staff, a tracked KPI) not on the built slide
select pg_temp.patch_fn('app.townhall_status(uuid, jsonb)'::regprocedure,
  $o$where app.staff_is_member(sp.user_id) and not exists (select 1 from jsonb_array_elements(d.slides) s3, jsonb_array_elements(coalesce(s3 -> 'staff', '[]'::jsonb)) x$o$,
  $n$where app.staff_is_member(sp.user_id)
         and exists (select 1 from jsonb_array_elements(app.townhall_staff_kpis(d.week_of)) k where k ->> 'user_id' = sp.user_id::text)
         and not exists (select 1 from jsonb_array_elements(d.slides) s3, jsonb_array_elements(coalesce(s3 -> 'staff', '[]'::jsonb)) x$n$);
