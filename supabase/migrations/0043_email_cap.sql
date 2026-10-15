-- 0043_email_cap.sql
-- The email daily cap, made safe for Resend's free plan (100 emails a day, every email the account sends):
--   1. Supabase Auth's own emails (confirmation, invitation, password reset, sign-in link, email change,
--      verification code) go out through the same Resend account by SMTP. They are now counted in the day's
--      total (app.auth_emails_today, read from auth.users' *_sent_at times), so the outbox never assumes the
--      whole 100 is its own.
--   2. The priority classes leave room for those sign-in emails: customer booking emails stop at 97, owner and
--      investor emails at 95, immediate staff emails at 90, digests and scheduled summaries at 80, marketing at 60
--      (and its own daily maximum). Program settings, editable in Admin > Settings > Program settings.
--   3. At 80% of the cap (notify_cap_warn_bps) every Admin gets one in-app notice that day, and Admin > Today
--      shows the day's use with a warning. No email is sent about email.
--   4. Resend refusing for its own rate or quota (HTTP 429) no longer spends one of the three attempts: the row
--      is held (app.outbox_defer) and tried again after a minute (rate) or after midnight (quota), never
--      dropped. A quota refusal tells the Admins in the portal.
--   5. An email that finally fails (after its attempts, or refused for good) now tells the Admins in the portal
--      (one notice per email, marketing excepted), and Admin > Today counts the day's failures.
-- No earlier migration is edited. Functions it changes are wrapped (renamed _00NN and called from a new function
-- of the same name) or replaced with the same signature.
set local check_function_bodies = off;

-- ================================================================ 1. settings
alter table program_settings
  add column notify_cap_warn_bps integer not null default 8000 check (notify_cap_warn_bps between 1000 and 10000),
  add column notify_count_auth_emails boolean not null default true;
comment on column program_settings.notify_cap_warn_bps is 'Share of notify_daily_cap at which the Admins get an in-app warning (8000 = 80%).';
comment on column program_settings.notify_count_auth_emails is 'Count Supabase Auth''s emails (sent through the same Resend account) against the daily cap.';

-- the classes leave room for the sign-in emails Supabase sends itself
alter table program_settings alter column notify_class_limits set default array[97, 95, 90, 80, 60];
update program_settings set notify_class_limits = array[97, 95, 90, 80, 60]
 where notify_class_limits = array[100, 100, 95, 95, 60];

-- the portal notices (in-app only: they spend nothing from the cap)
insert into notification_catalogue (code, audience, category, subject, preheader, has_email, priority, emitted_by, link_path)
values ('staff_email_cap_warning', 'staff_admin', 'transactional', 'Email use is at {{share}} of today''s limit',
        '{{used}} of {{cap}} emails today. Digests and marketing wait first; booking and sign-in emails still go.', false, 3,
        'app.outbox_claim (0043)', '/admin/messages'),
       ('staff_email_failed', 'staff_admin', 'transactional', 'An email could not be sent',
        '{{code}} to {{to}}: {{error}}', false, 3, 'app.outbox_mark_failed (0043)', '/admin/messages?status=failed')
on conflict (code) do nothing;

-- ================================================================ 2. Supabase Auth's emails count
-- One per distinct send time a user row records today (Toronto day): confirmation, password reset or sign-in link,
-- email change, verification code, invitation (an invitation sets two of these to the same instant: counted once).
-- Links an Admin generates without an email (the admin API) also set them: that counts high, never low.
-- Where there is no auth.users (a plain local database) it is 0.
create or replace function app.auth_emails_today(p_now timestamptz default now()) returns integer
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_from timestamptz := app.local_midnight(app.local_date(p_now));
  v integer := 0;
begin
  if not coalesce((app.settings(app.local_date(p_now))).notify_count_auth_emails, true) then return 0; end if;
  if to_regclass('auth.users') is null then return 0; end if;
  execute $q$
    select count(*)::integer
      from auth.users u,
           lateral (select distinct t
                      from unnest(array[u.confirmation_sent_at, u.recovery_sent_at, u.email_change_sent_at,
                                        u.reauthentication_sent_at, u.invited_at]) t
                     where t >= $1 and t <= $2) x
  $q$ into v using v_from, p_now;
  return coalesce(v, 0);
exception when undefined_column or insufficient_privilege then
  return 0;
end $$;

-- How many emails count against today's cap: the outbox's sent and sending rows, and Supabase Auth's emails.
-- Same signature as 0018, so app.outbox_claim and the dashboard count both.
create or replace function app.outbox_sent_today(p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select (select count(*)::integer from notification_outbox
           where (status = 'sent' and sent_at >= app.local_midnight(app.local_date(p_now))) or status = 'sending')
         + app.auth_emails_today(p_now)
$$;

-- The day's use in one object (Admin > Today, Admin > Email).
create or replace function app.email_usage(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with s as (select * from app.settings(app.local_date(p_now))),
       o as (select count(*) filter (where status = 'sent' and sent_at >= app.local_midnight(app.local_date(p_now))) as sent,
                    count(*) filter (where status = 'sending') as sending,
                    count(*) filter (where status = 'delayed' and status_reason in ('daily email limit', 'monthly email limit',
                                       'marketing maximum for today', 'the email provider''s daily limit')) as held,
                    count(*) filter (where status in ('queued', 'delayed') and send_after <= p_now) as due,
                    count(*) filter (where status = 'failed' and updated_at >= app.local_midnight(app.local_date(p_now))) as failed_today
               from notification_outbox),
       a as (select app.auth_emails_today(p_now) as auth)
  select jsonb_build_object(
    'outbox', o.sent + o.sending, 'auth', a.auth, 'total', o.sent + o.sending + a.auth,
    'cap', s.notify_daily_cap, 'warn_at', ceil(s.notify_daily_cap * s.notify_cap_warn_bps / 10000.0)::integer,
    'class_limits', to_jsonb(s.notify_class_limits), 'held', o.held, 'due', o.due, 'failed_today', o.failed_today)
  from s, o, a
$$;

-- ================================================================ 3. the claim warns at 80%
alter function app.outbox_claim(integer, timestamptz) rename to outbox_claim_0035;

create or replace function app.outbox_claim(p_limit integer default 20, p_now timestamptz default now())
returns table (id uuid, code text, category text, to_address text, to_name text, from_address text, reply_to text,
               subject text, payload jsonb, attempts integer, unsubscribe_url text, template_html text, template_text text)
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  v_used integer := app.outbox_sent_today(p_now);
  v_warn integer := ceil(s.notify_daily_cap * s.notify_cap_warn_bps / 10000.0)::integer;
  v_admin uuid;
begin
  if v_used >= v_warn then
    for v_admin in select u.id from users u join user_roles ur on ur.user_id = u.id and ur.role = 'admin' where u.status = 'active' loop
      insert into notifications (user_id, code, title, body, url, dedupe_key)
      values (v_admin, 'staff_email_cap_warning',
              format('Email use is at %s%% of today''s limit', least(100, round(v_used * 100.0 / s.notify_daily_cap))::integer),
              format('%s of %s emails today (%s from sign-in emails). Digests and marketing wait first; booking and sign-in emails still go. The count starts again at midnight.',
                     v_used, s.notify_daily_cap, app.auth_emails_today(p_now)),
              s.notify_base_url || '/admin/messages', 'staff_email_cap_warning:' || app.local_date(p_now) || '|' || v_admin)
      on conflict (dedupe_key) do nothing;
    end loop;
  end if;
  return query select * from app.outbox_claim_0035(p_limit, p_now);
end $$;

-- ================================================================ 4. the provider's own limit: held, not failed
-- Resend answered 429 (its rate of 2 a second, or its daily or monthly quota). The attempt is given back and the
-- row waits until p_until. A quota refusal tells the Admins once that day.
create or replace function app.outbox_defer(p_id uuid, p_reason text, p_until timestamptz, p_now timestamptz default now())
returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  o notification_outbox;
  v_admin uuid;
begin
  select * into o from notification_outbox where id = p_id for update;
  if o.id is null then raise exception 'Outbox row % not found', p_id using errcode = 'P0002'; end if;
  if o.status <> 'sending' then return o.status; end if;
  update notification_outbox
     set status = 'delayed', status_reason = left(coalesce(nullif(btrim(p_reason), ''), 'held by the email provider'), 200),
         attempts = greatest(o.attempts - 1, 0), locked_at = null, send_after = greatest(p_until, p_now)
   where id = p_id;
  if p_reason = 'the email provider''s daily limit' then
    for v_admin in select u.id from users u join user_roles ur on ur.user_id = u.id and ur.role = 'admin' where u.status = 'active' loop
      insert into notifications (user_id, code, title, body, url, dedupe_key)
      values (v_admin, 'staff_email_cap_reached', 'The email provider stopped sending for today',
              'Resend refused more email today (its daily limit counts every email of the account, sign-in emails too). '
              || 'Waiting emails go after midnight, booking emails first.',
              s.notify_base_url || '/admin/messages', 'staff_email_cap_reached:' || app.local_date(p_now) || '|' || v_admin)
      on conflict (dedupe_key) do nothing;
    end loop;
  end if;
  return 'delayed';
end $$;

-- ================================================================ 5. a final failure is never silent
alter function app.outbox_mark_failed(uuid, text, boolean, timestamptz) rename to outbox_mark_failed_0018;

create or replace function app.outbox_mark_failed(p_id uuid, p_error text, p_permanent boolean default false,
                                                  p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  v_result text := app.outbox_mark_failed_0018(p_id, p_error, p_permanent, p_now);
  o notification_outbox;
  v_admin uuid;
begin
  if v_result <> 'failed' then return v_result; end if;
  select * into o from notification_outbox where id = p_id;
  if o.category = 'marketing' then return v_result; end if;
  for v_admin in select u.id from users u join user_roles ur on ur.user_id = u.id and ur.role = 'admin' where u.status = 'active' loop
    insert into notifications (user_id, code, title, body, url, entity, entity_id, dedupe_key)
    values (v_admin, 'staff_email_failed', 'An email could not be sent',
            format('%s to %s: %s. Admin > Email can send it again.', o.code, o.to_address, left(coalesce(p_error, 'no reason given'), 200)),
            s.notify_base_url || '/admin/messages?status=failed', 'notification_outbox', o.id,
            'staff_email_failed:' || o.id || '|' || v_admin)
    on conflict (dedupe_key) do nothing;
  end loop;
  return v_result;
end $$;

-- ================================================================ 6. Admin > Today shows the day's use
alter function app.admin_dashboard(uuid) rename to admin_dashboard_0030;

create or replace function app.admin_dashboard(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  d jsonb := app.admin_dashboard_0030(p_admin);
  u jsonb := app.email_usage(now());
  a jsonb := '[]'::jsonb;
begin
  if (u ->> 'total')::integer >= (u ->> 'warn_at')::integer then
    a := a || jsonb_build_array(jsonb_build_object('field', 'email', 'message',
      format('Email use today is %s of %s (%s from sign-in emails). Digests and marketing wait first; booking and sign-in emails still go.',
             u ->> 'total', u ->> 'cap', u ->> 'auth')));
  end if;
  if (u ->> 'held')::integer > 0 then
    a := a || jsonb_build_array(jsonb_build_object('field', 'email', 'message',
      format('%s emails are held for the daily limit and go after midnight.', u ->> 'held')));
  end if;
  if (u ->> 'failed_today')::integer > 0 then
    a := a || jsonb_build_array(jsonb_build_object('field', 'email', 'message',
      format('%s emails failed today. Admin > Email lists them with the reason and can send them again.', u ->> 'failed_today')));
  end if;
  return d || jsonb_build_object('email', u, 'email_today', (u ->> 'total')::integer,
                                 'alerts', coalesce(d -> 'alerts', '[]'::jsonb) || a);
end $$;

-- Admin > Email reads the day's use
alter function app.admin_read(uuid, text, jsonb) rename to admin_read_0037;
create or replace function app.admin_read(p_admin uuid, p_what text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
begin
  if p_what = 'email_usage' then
    perform app.admin_begin(p_admin);
    return app.email_usage(now());
  end if;
  return app.admin_read_0037(p_admin, p_what, p);
end $$;

-- ================================================================ 7. privileges
revoke all on function app.auth_emails_today(timestamptz), app.email_usage(timestamptz),
  app.outbox_claim(integer, timestamptz), app.outbox_claim_0035(integer, timestamptz),
  app.outbox_defer(uuid, text, timestamptz, timestamptz),
  app.outbox_mark_failed(uuid, text, boolean, timestamptz), app.outbox_mark_failed_0018(uuid, text, boolean, timestamptz),
  app.admin_dashboard(uuid), app.admin_dashboard_0030(uuid), app.admin_read(uuid, text, jsonb), app.admin_read_0037(uuid, text, jsonb)
  from public, anon, authenticated;
grant execute on function app.auth_emails_today(timestamptz), app.email_usage(timestamptz),
  app.outbox_claim(integer, timestamptz), app.outbox_claim_0035(integer, timestamptz),
  app.outbox_defer(uuid, text, timestamptz, timestamptz),
  app.outbox_mark_failed(uuid, text, boolean, timestamptz), app.outbox_mark_failed_0018(uuid, text, boolean, timestamptz),
  app.admin_dashboard(uuid), app.admin_dashboard_0030(uuid), app.admin_read(uuid, text, jsonb), app.admin_read_0037(uuid, text, jsonb)
  to service_role;
