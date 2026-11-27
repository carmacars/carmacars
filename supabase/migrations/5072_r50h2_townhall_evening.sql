-- 5072 (R50 hotfix 2; docs/changes/2026-11-25-r50-hotfix2.md): the townhall moves to 18:30 and the interview calls to 17:30;
-- with no outside call link, Join always opens the call in the site.
--   1. Program settings townhall_time 18:30 (and its default). The townhall invites follow by themselves (5000's trigger on
--      townhall_time sends the changed series), and the calendar feed (5065) reads the time.
--   2. The interview call slots start at 17:30: every interview day still to come (today's only when it has not started)
--      with no booked slot moves to 17:30, whatever its length, and ends at 18:30 at the latest so it never runs into the
--      townhall; its slots are made again (app.hiring_day_slots). A day with a booked slot is not touched: the applicant
--      holds that time (the notice counts these days). Past days are not touched. The field calls of the hour before the
--      townhall (1068) are then 17:30 to 18:30, the same day app.townhall_field_slots would make.
--   3. With townhall_call_url empty there is no outside link to send anyone to, so app.calls_in_site() is true whatever
--      calls_mode says: Join on the Townhall page, the portal card and the staff bar opens /staff/townhall/live
--      (/admin/townhall/live for an Admin), the call room of 5010 (the one the interview calls use), and the invites carry
--      that page (app.townhall_call_page).
set local check_function_bodies = off;

-- ================================================================ 1. the townhall time
alter table program_settings alter column townhall_time set default '18:30';
update program_settings set townhall_time = '18:30' where id = (app.settings()).id and townhall_time <> '18:30';
comment on column program_settings.townhall_time is 'Townhall: the start, Toronto time (18:30 since 5072). The field applicants'' live calls take the hour before.';

-- ================================================================ 2. the interview days still to come
do $$
declare d record; n integer := 0; v_booked integer := 0;
begin
  for d in
    select x.id, exists (select 1 from interview_slots s join job_applications a on a.slot_id = s.id where s.day_id = x.id) booked
      from interview_days x
     where (x.start_time <> time '17:30' or x.end_time > time '18:30')
       and (x.day > (now() at time zone 'America/Toronto')::date
            or (x.day = (now() at time zone 'America/Toronto')::date and x.start_time > (now() at time zone 'America/Toronto')::time))
  loop
    if d.booked then v_booked := v_booked + 1; continue; end if;
    update interview_days set start_time = time '17:30',
           end_time = least(time '18:30', time '17:30' + least(end_time - start_time, interval '1 hour')) where id = d.id;
    perform app.hiring_day_slots(d.id);
    n := n + 1;
  end loop;
  raise notice '5072: % interview day(s) moved to 17:30 (ending by 18:30); % day(s) with a booked slot left as they are', n, v_booked;
end $$;

-- ================================================================ 3. no outside link: the call in the site
create or replace function app.calls_in_site() returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select (app.settings()).calls_mode = 'in_site' or coalesce((app.settings()).townhall_call_url, '') = ''
$$;
comment on function app.calls_in_site() is 'Calls (5010; 5072): the townhall and interview calls are in the site: calls_mode in_site, or no outside call link set (nothing else to open).';
