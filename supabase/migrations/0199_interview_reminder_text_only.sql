-- 0199: the hour-before interview reminder goes by text only when the candidate can get a text (the owner, October 30).
-- SCHEMA_MARKER 0199. Record: docs/changes/2026-10-30-interview-reminder-text-only.md.
-- Resend's free plan sends 100 emails a day. When phone and texts are on (phone_enabled), hiring texts are on
-- (hiring_sms_reminders) and the candidate gave a phone number that takes the text, the reminder an hour before is the
-- text alone. A candidate with no phone, a number that cannot be texted or that opted out, or with texts off still gets
-- the email. The booking confirmation email (with the link) is unchanged. app.job_hiring keeps its signature; the
-- result gains 'hour_texts' (reminders sent as a text only).

create or replace function app.job_hiring(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  a job_applications;
  v_start timestamptz;
  v_eve integer := 0;
  v_hour integer := 0;
  v_texts integer := 0;
  v_purged integer := 0;
  v_text phone_outbox;
begin
  for a in select x.* from job_applications x join interview_slots y on y.id = x.slot_id
            where s.hiring_evening_reminder and x.status = 'booked' and y.starts_at > p_now and x.reminded_evening_at is null
              and p_now >= app.local_midnight(app.local_date(y.starts_at) - 1) + interval '18 hours'
              and y.starts_at - p_now > interval '2 hours'
              and x.booked_at < app.local_midnight(app.local_date(y.starts_at) - 1) + interval '18 hours'
            for update of x skip locked loop
    update job_applications set reminded_evening_at = p_now where id = a.id;
    perform app.hiring_emit('applicant_reminder', a, app.hiring_booking_vars(a) || jsonb_build_object('when_text', 'tomorrow'), 'applicant_reminder:' || a.id || ':' || a.booking_seq || ':eve');
    v_eve := v_eve + 1;
  end loop;
  for a in select x.* from job_applications x join interview_slots y on y.id = x.slot_id
            where x.status = 'booked' and y.starts_at > p_now and y.starts_at - p_now <= interval '1 hour' and x.reminded_hour_at is null
              and x.booked_at < y.starts_at - interval '1 hour'
            for update of x skip locked loop
    update job_applications set reminded_hour_at = p_now where id = a.id;
    v_text := null;
    if s.phone_enabled and s.hiring_sms_reminders and nullif(a.phone, '') is not null then
      select starts_at into v_start from interview_slots where id = a.slot_id;
      begin
        v_text := app.phone_outbox_put(a.phone, format('CarmaCars: your interview call for %s is at %s Toronto time (in about an hour). %s Change it: %s',
          (select short_title from hiring_roles where id = a.role_id), app.fmt_time(v_start),
          case when a.meet_url is not null then 'Video: ' || a.meet_url || '.' else 'We will call you at this number.' end,
          app.hiring_url('/careers/book/' || a.token)), 'staff', null, null, 'hiring', null, 'hiring_reminder:' || a.id || ':' || a.booking_seq);
      exception when others then v_text := null;  -- a number the phone line cannot text: the email goes instead
      end;
    end if;
    if v_text.id is not null and v_text.status <> 'skipped' then
      v_texts := v_texts + 1;
    else
      perform app.hiring_emit('applicant_reminder', a, app.hiring_booking_vars(a) || jsonb_build_object('when_text', 'in about an hour'), 'applicant_reminder:' || a.id || ':' || a.booking_seq || ':hour');
    end if;
    v_hour := v_hour + 1;
  end loop;
  -- 12 months (by default) after the decision, a candidate who was not hired keeps no name, contact details or answers
  with gone as (
    update job_applications set full_name = 'Removed', email = null, phone = null, profile_name = null, answers = '{}'::jsonb, utm = '{}'::jsonb,
           score_detail = (select coalesce(jsonb_agg(d - 'answer'), '[]'::jsonb) from jsonb_array_elements(score_detail) d), note = null, meet_url = null, purged_at = p_now, updated_at = p_now
     where purged_at is null and status in ('declined', 'below_bar', 'referred', 'rejected', 'no_show', 'withdrawn')
       and coalesce(decided_at, screened_at, created_at) < p_now - make_interval(months => s.hiring_retention_months)
    returning id)
  select count(*) into v_purged from gone;
  update interview_scores set notes = null where application_id in (select id from job_applications where purged_at = p_now);
  return jsonb_build_object('evening', v_eve, 'hour', v_hour, 'hour_texts', v_texts, 'purged', v_purged);
end $$;

revoke all on function app.job_hiring(timestamptz) from public, anon, authenticated;

comment on column program_settings.hiring_sms_reminders is 'Hiring: the reminder an hour before a booked interview call goes as a text (no email) when phone and texts (Quo) are on and the candidate has a phone that takes texts; otherwise it is an email (0199).';

update notification_catalogue
   set timing = 'About an hour before the call, only for candidates who do not get the text (no phone, or phone and texts off); the evening-before email is off unless Program settings turn it on',
       trigger_text = 'A booked interview call is about an hour away (app.job_hiring every 15 minutes), or the next day at 6 pm Toronto time when Program settings turn the evening reminder on. Not sent when the call was booked after that moment. When phone and texts are on and the candidate has a phone that takes texts, the hour-before reminder is a text and no email goes (migration 0199). One email per reminder.'
 where code = 'applicant_reminder';
