-- 5175 (R50 hotfix 2, academy branch; REQ-065; docs/changes/2026-11-27-r50-hotfix2-academy.md): "VA" only for remote
-- assistants. The owner (Nov 27): "still says VA as a role for my in-person staff". Fleet, Sales and field staff can work in
-- person, so the database words that named a role as a VA now say "Fleet team member", "salesperson" or "staff":
-- onboarding step 4 (app.staff_waiting_on), its academy lesson and questions, the approval alert's hint and the email
-- catalogue's trigger texts (emails/src/emails, same words).
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '5175: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.patch_fn('app.staff_waiting_on(uuid, jsonb)'::regprocedure,
  'Approval by an Admin or a Fleet VA', 'Approval by an Admin or a Fleet team member');

-- the academy: text only (option order and answers stay, so passed quizzes and pending fixes are not touched)
update academy_lessons set scenes = replace(replace(scenes::text, 'Fleet VAs can', 'Fleet team members can'), 'a Fleet VA', 'a Fleet team member')::jsonb
 where scenes::text like '%Fleet VA%';
update academy_questions set options = replace(options::text, 'a Fleet VA', 'a Fleet team member')::jsonb,
       explain = replace(explain, 'a Fleet VA', 'a Fleet team member')
 where options::text like '%Fleet VA%' or explain like '%Fleet VA%';

update staff_alert_rules set hint = replace(hint, 'a Fleet VA', 'a Fleet team member') where hint like '%Fleet VA%';

update notification_catalogue set trigger_text = replace(trigger_text, 'over the VA limit', 'over the staff member''s limit') where code = 'staff_approval_needed';
update notification_catalogue set trigger_text = replace(trigger_text, 'Sent to every active customer service VA.', 'Sent to every active customer service staff member.') where code = 'staff_booking_request_new';
update notification_catalogue set trigger_text = replace(trigger_text, 'or the VA equivalent', 'or the Staff portal equivalent') where code = 'renter_rental_added';
update notification_catalogue set trigger_text = replace(trigger_text, 'anything a VA escalated', 'anything staff escalated') where code = 'staff_digest_eod_admin';
update notification_catalogue set trigger_text = replace(trigger_text, 'Sent to every active sales VA.', 'Sent to every active salesperson.') where code = 'staff_owner_application_received';
