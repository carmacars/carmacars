-- 1872_r35gaps4_staff_quiet_texts_emails.sql
-- The owner, November 8, 2026 (message 3593): when a staff member turns on their quiet hours, they get the notifications all at once when
-- the quiet hours end. Until now only the phone push honoured them (0300, 0466). Now the staff text and the staff email do too:
-- a notice that is not urgent waits in the outbox until the end of that person's quiet hours (staff_alert_prefs, quiet_on), and every
-- held one becomes due at that moment. Urgent ones go at once by the existing rules (app.staff_notice_urgent: push topic alerts or leads,
-- staff_alert_urgent, or a staff alert whose topic is one of those). Digests are the summary itself and are never held.
-- Renter texts: the urgency of 1871 (pickup or return today, overdue, codes) applies in app.notify_route_text.

create or replace function app.staff_notice_urgent(p_code text, p_payload jsonb default '{}'::jsonb) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_code = 'staff_alert_urgent'
      or coalesce(p_payload ->> 'topic', '') in ('alerts', 'leads')
      or coalesce((select c.push_topic in ('alerts', 'leads') from notification_catalogue c where c.code = p_code), false)
$$;

-- When may this notice reach this staff member: p_at, or the end of their quiet hours.
create or replace function app.staff_quiet_hold(p_user uuid, p_code text, p_payload jsonb, p_at timestamptz) returns timestamptz
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_user is null or app.staff_notice_urgent(p_code, p_payload) then return p_at; end if;
  if (select c.is_digest from notification_catalogue c where c.code = p_code) then return p_at; end if;
  if not exists (select 1 from staff_alert_prefs x where x.user_id = p_user and x.quiet_on) then return p_at; end if;
  return greatest(p_at, app.alert_quiet_end(p_user, greatest(p_at, now())));
end $$;

create or replace function app.staff_email_quiet() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.audience like 'staff\_%' and new.recipient_user_id is not null and new.status in ('queued', 'delayed') then
    new.send_after := app.staff_quiet_hold(new.recipient_user_id, new.code, new.payload, new.send_after);
  end if;
  return new;
end $$;
drop trigger if exists notification_outbox_staff_quiet on notification_outbox;
create trigger notification_outbox_staff_quiet before insert on notification_outbox for each row execute function app.staff_email_quiet();

create or replace function app.notify_route_text() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  w jsonb;
  r jsonb;
  v_text jsonb;
  v_body text;
  v_after timestamptz;
  v_urgent boolean;
  o phone_outbox;
begin
  if not new.sms_planned then return new; end if;
  w := app.notify_who(new);
  r := app.notify_reach((w ->> 'user_id')::uuid, w ->> 'kind', (w ->> 'record')::uuid);
  v_text := app.sms_text_for(new.code, new.payload, new.audience, new.booking_id);
  if v_text is null or r ->> 'phone' is null then return new; end if;
  v_body := v_text ->> 'body';
  if s.sms_stop_line and app.sms_first_to(r ->> 'phone') then v_body := v_body || ' Reply STOP to opt out.'; end if;
  v_urgent := coalesce((v_text ->> 'urgent')::boolean, false);
  if w ->> 'kind' = 'renter' then v_urgent := app.sms_renter_urgent(new.code, new.booking_id, v_urgent); end if;
  v_after := case when v_urgent then new.send_after else greatest(new.send_after, app.sms_quiet_end(now())) end;
  o := app.phone_outbox_put(r ->> 'phone', v_body, 'notify', new.booking_id, case when w ->> 'kind' = 'renter' then new.renter_id end, new.code, new.id,
         'sms:' || new.dedupe_key, v_after);
  update phone_outbox set user_id = (r ->> 'user_id')::uuid, urgent = v_urgent where id = o.id and user_id is null;
  -- the text could not be queued after all: the email it replaced goes
  if o.status = 'skipped' and new.status = 'skipped' and new.status_reason like 'Sent by text%' and nullif(btrim(coalesce(new.to_address, '')), '') is not null then
    update notification_outbox set status = 'queued', status_reason = 'By email: ' || coalesce(o.status_reason, 'the text could not be sent'), send_after = now() where id = new.id;
  end if;
  return new;
end $$;

-- Texts to staff (usage alerts, booking moments, free field shifts): the same hold, by the phone number's staff account.
-- A manual staff reply (sent by a person, status sending) is never held.
create or replace function app.staff_text_quiet() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_user uuid;
begin
  if new.kind <> 'staff' or new.status <> 'queued' or new.sent_by is not null or coalesce(new.urgent, false) then return new; end if;
  select u.id into v_user from users u
   where u.phone = new.to_number and exists (select 1 from user_roles r where r.user_id = u.id and r.role::text in ('admin', 'va', 'field'))
   order by u.created_at limit 1;
  if v_user is not null then
    new.send_after := app.staff_quiet_hold(v_user, coalesce(new.sms_kind, ''), '{}'::jsonb, new.send_after);
  end if;
  return new;
end $$;
drop trigger if exists phone_outbox_staff_quiet on phone_outbox;
create trigger phone_outbox_staff_quiet before insert on phone_outbox for each row execute function app.staff_text_quiet();

do $$
declare
  f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('staff_notice_urgent', 'staff_quiet_hold', 'staff_email_quiet', 'staff_text_quiet')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
