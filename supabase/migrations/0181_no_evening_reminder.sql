-- 0181: no evening-before interview reminder email (the owner, October 28). SCHEMA_MARKER 0181.
-- Resend's free plan sends 100 emails a day; an interview day of 30 calls spent 30 of them the evening before.
-- Booked candidates now get the reminder about an hour before the call only (with the text when phone is on).
-- Program setting hiring_evening_reminder (off) turns the evening email back on. app.job_hiring is replaced with the
-- same signature; the only change is that setting in the evening loop.

alter table program_settings add column if not exists hiring_evening_reminder boolean not null default false;
comment on column program_settings.hiring_evening_reminder is 'Send booked interview candidates a reminder email at 6 pm the evening before (off: the hour-before reminder only).';

create or replace function app.job_hiring(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  a job_applications;
  v_start timestamptz;
  v_eve integer := 0;
  v_hour integer := 0;
  v_purged integer := 0;
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
    perform app.hiring_emit('applicant_reminder', a, app.hiring_booking_vars(a) || jsonb_build_object('when_text', 'in about an hour'), 'applicant_reminder:' || a.id || ':' || a.booking_seq || ':hour');
    if s.hiring_sms_reminders and nullif(a.phone, '') is not null then
      select starts_at into v_start from interview_slots where id = a.slot_id;
      begin
        perform app.phone_outbox_put(a.phone, format('CarmaCars: your interview call for %s is at %s Toronto time (in about an hour). %s Change it: %s',
          (select short_title from hiring_roles where id = a.role_id), app.fmt_time(v_start),
          case when a.meet_url is not null then 'Video: ' || a.meet_url || '.' else 'We will call you at this number.' end,
          app.hiring_url('/careers/book/' || a.token)), 'staff', null, null, 'hiring', null, 'hiring_reminder:' || a.id || ':' || a.booking_seq);
      exception when others then null;  -- a number the phone line cannot text: the email still goes
      end;
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
  return jsonb_build_object('evening', v_eve, 'hour', v_hour, 'purged', v_purged);
end $$;

update notification_catalogue set timing = 'About an hour before the call (the evening-before email is off unless Program settings turn it on)'
 where code = 'applicant_reminder';
