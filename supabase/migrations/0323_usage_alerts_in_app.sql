-- 0323_usage_alerts_in_app.sql
-- Usage alerts are in the app only (docs/changes/2026-11-06-owner-todo-usage-noise.md, section 2). Admin > Settings > Usage
-- on November 1, 2026: "Emails today at 80%" and "at 100%" were emailed almost every day, with the CPU and storage
-- alerts, and each counted against Resend's 100 emails a day, the very limit they warned about. The owner does not want
-- to be emailed site and usage alerts. Now no usage alert is emailed: each is kept with "not emailed: in the app only",
-- shown on Admin > To do (the banner and its card) and Settings > Usage. The texts to the Admins (0221: once per figure
-- and level a month, never in the quiet hours, none for a cost under the red line, 0320) are unchanged.
-- No applied migration is edited.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter function app.usage_send_alerts(timestamptz) rename to usage_send_alerts_pre0323;
create function app.usage_send_alerts(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
begin
  update usage_alerts set emailed_at = p_now,
         email_note = 'not emailed: usage alerts are in the app only (Admin > To do and Settings > Usage)'
   where emailed_at is null and created_at > p_now - interval '35 days';
  begin
    perform app.usage_send_texts(p_now);
  exception when others then
    raise warning 'usage alert texts: %', sqlerrm;
  end;
  return 0;
end $$;
select pg_temp.copy_grants('app.usage_send_alerts(timestamptz)'::regprocedure, 'app.usage_send_alerts_pre0323(timestamptz)'::regprocedure);
revoke all on function app.usage_send_alerts_pre0323(timestamptz) from public, anon, authenticated;
grant execute on function app.usage_send_alerts_pre0323(timestamptz) to service_role;

-- the catalogue says so (Settings > Email log, the catalogue page)
update notification_catalogue set timing = 'Not emailed (0323): usage alerts are in the app only' where code = 'staff_usage_alert';
