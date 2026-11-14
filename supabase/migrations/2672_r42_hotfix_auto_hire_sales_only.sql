-- 2672 (release 42 hotfix): an AI interview hires by itself only for Sales. Every other role that passed waits for an
-- Admin (Hiring > Interviewed) and, from release 43, gets an interview date to book. SCHEMA_MARKER 2672.
-- No applied migration is edited: the two functions are patched in place.
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '2672: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.patch_fn('public.server_hire_auto_due(integer)'::regprocedure,
  'r.va_function is not null and r.staff_kind <> ''field''',
  'r.va_function = ''sales'' and r.staff_kind <> ''field''');

select pg_temp.patch_fn('app.k_jobs_due()'::regprocedure,
  'where o.outcome = ''hire'' and a.hired_user_id is null',
  'join hiring_roles hr on hr.id = a.role_id where o.outcome = ''hire'' and hr.va_function = ''sales'' and hr.staff_kind <> ''field'' and a.hired_user_id is null');

comment on column program_settings.hiring_auto_hire_sales is 'Hiring (1060, 2672): a Sales applicant who passes the AI interview is hired with one-step Hire by itself. Only Sales (2672): every other role waits for an interview date.';
