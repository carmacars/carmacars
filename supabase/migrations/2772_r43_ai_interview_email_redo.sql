-- 2772 (release 43): the interview email has an optional "why you are getting this link" paragraph for a redone
-- interview (2680 sends redo = '1'). Every other send left "redo" out, and the email renderer refuses a missing value,
-- so the ordinary interview email would not render: the variables now always carry redo, empty unless it is a redo.
create or replace function app.ai_interview_vars(a job_applications, iv ai_interviews) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('interview_url', app.hiring_url('/careers/interview/' || a.token),
    'expires_on', to_char(iv.expires_at at time zone 'America/Toronto', 'FMDay, FMMonth FMDD'),
    'question_count', jsonb_array_length(iv.questions)::text, 'minutes', '10', 'redo', '')
$$;
