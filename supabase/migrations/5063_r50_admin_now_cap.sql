-- 5063 (release 50; docs/changes/2026-11-25-r50-admin-email-quiet.md): the "needs you now" emails keep the Admin's cap.
-- 5051 sends an urgent To do, a booked live interview and a dispute's evidence due soon to every active Admin at once
-- (app.admin_now_email), but it skipped the cap of 3 immediate emails an hour per Admin that every other urgent Admin
-- email keeps (app.admin_email_gate). The local database showed it: one Admin got 103 immediate emails in 27 minutes
-- from urgent To do's. Now the same cap holds: under 3 in the last hour, the email goes at once as before; at 3 or
-- more, the line waits in that Admin's daily digest. Once per key either way (the outbox row holds the key; above the
-- cap it is skipped, with the code staff_alert_normal so the daily digest's own "sent today" check never counts it).
-- SCHEMA_MARKER 5063.
create or replace function app.admin_now_email(p_key text, p_line text, p_url text, p_type text) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_now timestamptz := now();
  v_n integer;
begin
  with admins as (
    select u.id, u.full_name, lower(btrim(u.email)) as email,
           (select count(*) from notification_outbox o where o.recipient_user_id = u.id and o.status_reason = 'urgent'
             and o.created_at > v_now - interval '1 hour' and o.status in ('queued', 'delayed', 'sending', 'sent')) >= 3 as capped
      from users u
     where u.status = 'active' and nullif(btrim(coalesce(u.email, '')), '') is not null and u.staff_email_digest <> 'off'
       and exists (select 1 from user_roles r where r.user_id = u.id and r.role = 'admin')
       and not exists (select 1 from notify_prefs np where np.subject_kind = 'user' and np.subject_id = u.id and np.type = p_type and not np.email)
       and not exists (select 1 from notify_profiles nf where nf.subject_kind = 'user' and nf.subject_id = u.id and nf.all_off)),
  -- under the cap: at once
  sent as (
    insert into notification_outbox (id, code, category, priority, audience, recipient_user_id, to_address, to_name, payload, dedupe_key, status, status_reason, send_after)
    select gen_random_uuid(), 'staff_digest_hourly', 'transactional', 2, 'staff_admin', a.id, a.email, a.full_name,
           app.ntf_contact() || jsonb_build_object('first_name', split_part(coalesce(a.full_name, ''), ' ', 1), 'digest_count', '1',
             'digest_since', app.fmt_time(v_now), 'digest_date', to_char(v_now at time zone 'America/Toronto', 'Dy, Mon FMDD'),
             'digest_next', '', 'digest_summary', left('Needs you now: ' || p_line, 300), 'has_items', true,
             'items', jsonb_build_array(app.ntf_item(left(p_line, 300), app.fmt_time(v_now), p_url))),
           'admin_now|' || p_key || '|' || a.id, 'queued', 'urgent', v_now
      from admins a where not a.capped
    on conflict (dedupe_key) do nothing
    returning 1),
  -- at the cap: the line waits for the daily digest
  held as (
    insert into notification_outbox (id, code, category, priority, audience, recipient_user_id, to_address, to_name, payload, dedupe_key, status, status_reason, send_after)
    select gen_random_uuid(), 'staff_alert_normal', 'transactional', 3, 'staff_admin', a.id, a.email, a.full_name,
           jsonb_build_object('title', left(p_line, 300), 'url', p_url), 'admin_now|' || p_key || '|' || a.id, 'skipped', 'in the Admin daily digest', v_now
      from admins a where a.capped
    on conflict (dedupe_key) do nothing
    returning id, recipient_user_id),
  lines as (
    insert into staff_email_digest_items (user_id, audience, outbox_id, code, line, url)
    select h.recipient_user_id, 'staff_admin', h.id, 'staff_alert_normal', left('Needs you now: ' || p_line, 300), p_url from held h
    returning 1)
  select (select count(*) from sent)::integer into v_n;
  return v_n;
end $$;
revoke all on function app.admin_now_email(text, text, text, text) from public, anon, authenticated;
grant execute on function app.admin_now_email(text, text, text, text) to service_role;
