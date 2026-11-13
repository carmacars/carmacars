-- 99: Release 43 (2695): a stricter AI interview. A score at the bar is not enough when the per-answer scores average
-- under 7 or one answer is under 5, or spoken English is basic. Fixtures start with "rq43s"; addresses are example.test.
select test.suite('99 r43 stricter AI interview');

create function test.rq43s_pass(p_k text, p_result jsonb) returns boolean language plpgsql as $$
declare v uuid := test.id('rq43s_' || p_k); i ai_interviews; a job_applications; r hiring_roles;
begin
  insert into job_applications (id, role_id, full_name, email, phone, status)
  select v, r2.id, 'Rq43s ' || initcap(p_k), 'rq43s_' || p_k || '@example.test', '+15555550144', 'interviewed' from hiring_roles r2 where r2.slug = 'sales-remote';
  insert into ai_interviews (application_id, role_id, questions, state, expires_at, interview_score, recommendation, scored_at, result)
  select v, a2.role_id, '[]'::jsonb, 'scored', now() + interval '7 days', 95, 'hire', now(), p_result from job_applications a2 where a2.id = v;
  select * into a from job_applications where id = v;
  select * into i from ai_interviews where application_id = v;
  select * into r from hiring_roles where id = a.role_id;
  return app.ai_interview_passes(i, a, r);
end $$;

select test.ok('strong answers and good English pass',
  test.rq43s_pass('strong', '{"english":{"level":"good"},"answers":[{"seq":1,"score":8},{"seq":2,"score":7}]}'::jsonb));
select test.ok('an average under 7 fails',
  not test.rq43s_pass('avg', '{"english":{"level":"fluent"},"answers":[{"seq":1,"score":7},{"seq":2,"score":6}]}'::jsonb));
select test.ok('one answer under 5 fails',
  not test.rq43s_pass('low', '{"english":{"level":"fluent"},"answers":[{"seq":1,"score":10},{"seq":2,"score":4},{"seq":3,"score":10}]}'::jsonb));
select test.ok('basic English fails',
  not test.rq43s_pass('eng', '{"english":{"level":"basic"},"answers":[{"seq":1,"score":9}]}'::jsonb));
select test.ok('an interview scored before per-answer scores keeps the old rule',
  test.rq43s_pass('old', '{}'::jsonb));
