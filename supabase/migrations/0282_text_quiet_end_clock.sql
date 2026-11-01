-- 0282: the end of the text quiet hours is a time on the clock, also on the days the clocks change
-- (docs/changes/2026-11-04-text-quiet-end-clock.md).
--
-- app.sms_quiet_end (0096) added the hours to local midnight: on the day the clocks go back (a 25-hour day) a text held
-- until 8:00 went at 7:00, and on the day they go forward (23 hours) at 9:00. It is now the hour on the Toronto clock.
-- The rest of the function is 0096's, word for word. No applied migration is edited.
create or replace function app.sms_quiet_end(p_now timestamptz default now()) returns timestamptz
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  h integer := app.local_hour(p_now);
  v_quiet boolean;
begin
  if not s.sms_quiet_hours or s.sms_quiet_from_hour = s.sms_quiet_until_hour then return p_now; end if;
  v_quiet := case when s.sms_quiet_from_hour > s.sms_quiet_until_hour then h >= s.sms_quiet_from_hour or h < s.sms_quiet_until_hour
                  else h >= s.sms_quiet_from_hour and h < s.sms_quiet_until_hour end;
  if not v_quiet then return p_now; end if;
  return ((app.local_date(p_now) + case when h >= s.sms_quiet_until_hour then 1 else 0 end)::timestamp + make_interval(hours => s.sms_quiet_until_hour))
         at time zone 'America/Toronto';
end $$;
