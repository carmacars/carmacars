-- 5180 (R50 hotfix 2, labels; docs/changes/2026-11-27-r50-hotfix2-labels.md): the owner, many times: in-person staff still showed "VA".
-- "VA" is for a remote virtual assistant only. The approver of the fourth onboarding step is "an Admin or a Fleet team member" (a fleet
-- person may work in person), in the waiting list, the academy, the alert rule hint and the email catalogue's trigger texts.
-- The guide chapters follow in 5181. Text only: no rule changes.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '5180: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.patch_fn('app.staff_waiting_on(uuid, jsonb)'::regprocedure, 'Approval by an Admin or a Fleet VA', 'Approval by an Admin or a Fleet team member');

create function pg_temp.words(t text) returns text language sql immutable as $$
  select replace(replace(replace(replace(replace(replace(replace(t,
    'Fleet VAs', 'Fleet team members'), 'Fleet VA', 'Fleet team member'),
    'every active customer service VA', 'every active customer service staff member'), 'every active sales VA', 'every active sales staff member'),
    'or the VA equivalent', 'or the staff equivalent'), 'over the VA limit', 'over the staff limit'), 'anything a VA escalated', 'anything a staff member escalated')
$$;

update staff_alert_rules set hint = pg_temp.words(hint) where hint ~ 'VA';
update notification_catalogue set trigger_text = pg_temp.words(trigger_text) where trigger_text ~ 'VA';
update academy_questions set prompt = pg_temp.words(prompt), explain = pg_temp.words(explain), options = pg_temp.words(options::text)::jsonb
 where prompt ~ 'VA' or explain ~ 'VA' or options::text ~ 'VA';
update academy_lessons set scenes = pg_temp.words(scenes::text)::jsonb where scenes::text ~ 'VA';
