-- 0189: interview slots on the day the clocks change. SCHEMA_MARKER 0189.
-- A day's slots were Toronto midnight plus the start time as a length of time, so on the day the clocks go back
-- (November 1) a 9:00 day started at 8:00. Each slot time is now the Toronto clock time on that date.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0189: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.patch_fn((select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'hiring_day_slots'),
  $o$  v_at := app.local_midnight(d.day) + d.start_time::interval;
  v_end := app.local_midnight(d.day) + d.end_time::interval;$o$,
  $n$  v_at := (d.day + d.start_time::time) at time zone 'America/Toronto';
  v_end := (d.day + d.end_time::time) at time zone 'America/Toronto';$n$);
