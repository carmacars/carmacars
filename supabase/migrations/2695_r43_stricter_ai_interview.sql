-- 2695 (release 43): the AI interview is stricter. Too many applicants passed: on top of the 0-100 score at the bar, with no
-- knock-out and no "decline", a pass now also needs every answer scored (out of 10, 2680) to average 7 or more with none
-- under 5, and spoken English judged good or fluent (never basic). An interview scored before 2680 (no per-answer scores)
-- keeps the old rule. The scoring instructions (web/src/features/careers/ai-interview.ts) are stricter too. SCHEMA_MARKER 2695.
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '2695: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.patch_fn('app.ai_interview_passes(ai_interviews, job_applications, hiring_roles)'::regprocedure,
  'and coalesce(i.recommendation, '''') <> ''decline''',
  'and coalesce(i.recommendation, '''') <> ''decline''
     and coalesce(i.result #>> ''{english,level}'', ''good'') in (''good'', ''fluent'')
     and (jsonb_typeof(i.result -> ''answers'') is distinct from ''array'' or jsonb_array_length(i.result -> ''answers'') = 0
          or ((select avg((e ->> ''score'')::numeric) from jsonb_array_elements(i.result -> ''answers'') e) >= 7
              and (select min((e ->> ''score'')::int) from jsonb_array_elements(i.result -> ''answers'') e) >= 5))');
