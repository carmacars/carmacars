-- 5308 (R51 staff, REQ-135; docs/changes/2026-11-27-r51-staff.md): Welcome's pay details step comes last, after the first
-- tasks. 5197 placed it before them, which moved the first tasks off their place in the list that the Welcome page and
-- 99_r34n_academy_gate read (steps 7). The pay step never holds the portal, so last is its place.
-- No applied migration is edited: app.staff_welcome (5197) is patched in place (the patch refuses when the text is not found).
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '5308: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.patch_fn('app.staff_welcome(uuid)'::regprocedure,
  $o$  -- pay details before the first tasks (or last)
  select jsonb_agg(x order by o) into v_steps from (
    select s x, n::numeric o from jsonb_array_elements(v -> 'steps') with ordinality t(s, n)
    union all
    select jsonb_build_object('key', 'pay', 'done', v_pay, 'required', false),
           coalesce((select n - 0.5 from jsonb_array_elements(v -> 'steps') with ordinality t(s, n) where s ->> 'key' = 'tasks'), 1000)) q;$o$,
  $n$  -- pay details, last (5308: it does not hold the portal)
  v_steps := (v -> 'steps') || jsonb_build_array(jsonb_build_object('key', 'pay', 'done', v_pay, 'required', false));$n$);
