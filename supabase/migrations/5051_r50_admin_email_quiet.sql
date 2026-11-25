-- 5051: the Admin's inbox goes quiet (release 50; docs/changes/2026-11-25-r50-admin-email-quiet.md).
-- The owner (Nov 25): "admin is getting absolutely spammed with emails which isnt really necessary". Before this, an
-- Admin got every staff email (audience staff_%, about 60 types with an email) in an hourly digest (0583, up to 24 a day),
-- plus the morning and end of day digests (0023), the weekly summary, the search digest and the urgent ones on their own.
-- Now, for an Admin only (renters, owners and other staff get exactly what they got):
--   1. Email at once only for what needs a person now (app.admin_email_now): a card dispute (opened, evidence due soon),
--      a failed payment on a confirmed booking, card payments paused, a site or car security alert (site down, a car at a
--      pound or leaving Canada), documents to review for a pickup within 2 hours, an approval that waits for an Admin, a
--      request to book no salesperson holds after 2 hours, a booked live interview and any To do marked urgent. The last
--      three had no email: they go as a one-line alert email (app.admin_now_email, the staff digest's template).
--   2. Everything else stays in the bell and goes into ONE daily digest email at 7:00 Toronto (the 0583 digest, daily):
--      a counted summary grouped by type, one line per kind with its link, skipped when empty. The Admins' digest
--      setting moves from hourly (the old default) to daily, unless the audit log shows an Admin chose hourly; a new
--      Admin starts on daily.
--   3. Each person's settings still work: a type an Admin switches off stays off (no email, no digest line); a type an
--      Admin switches email on for (notify_prefs.email_set_at, stamped by the Notifications page from now on, and for
--      rows that only exist because of an email switch) sends each email on its own, as before. Locked types (security,
--      legal, receipts, assigned jobs, onboarding) and a person's own calendar invites and pay emails are unchanged.
-- No applied migration is edited: functions are wrapped (_pre5051) or patched in place (the patch refuses when the text it
-- changes is not found).
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '5051: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. what needs an Admin now
create function app.admin_email_now(p_code text, p_payload jsonb, p_booking uuid) returns boolean
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_booking uuid := coalesce(p_booking, case when coalesce(p_payload ->> 'booking_id', '') ~ '^[0-9a-f-]{36}$' then (p_payload ->> 'booking_id')::uuid end);
  b bookings;
begin
  if p_code in ('staff_dispute_opened', 'admin_card_payments_paused', 'staff_site_alert', 'staff_disable_approval_needed', 'staff_approval_needed',
                'staff_pound_flag', 'staff_border_alert') then
    return true;
  end if;
  if p_code = 'staff_identity_review' then return app.staff_email_urgent(p_code, v_booking); end if;
  if p_code not in ('staff_payment_failed', 'staff_request_waiting') or v_booking is null then return false; end if;
  select * into b from bookings where id = v_booking;
  if p_code = 'staff_payment_failed' then return b.status in ('confirmed', 'on_rent'); end if;
  -- a request to book: only while it waits and no salesperson holds it
  return b.status = 'requested' and b.sales_staff_id is null and b.sales_claim_by is null;
end $$;

-- the emails a person gets about themselves (pay, calendar invites, their own jobs lists) and the digest itself
create function app.admin_email_keep(p_code text) returns boolean
language sql immutable set search_path = public, app, pg_temp as $$
  select p_code = 'staff_digest_hourly' or (app.staff_email_own(p_code) and p_code not like 'staff\_digest\_%')
$$;

-- ================================================================ 2. an Admin's email switch, stamped when chosen
alter table notify_prefs add column if not exists email_set_at timestamptz;
comment on column notify_prefs.email_set_at is 'r50 (5051): when the person switched this type''s email on themselves (null: the default). An Admin''s work emails go into the daily digest unless this is set.';
-- the rows that exist only because of an email switch (push and text at their defaults) were an email choice
update notify_prefs p set email_set_at = p.updated_at
  from notify_types t, user_roles r
 where t.code = p.type and r.user_id = p.subject_id and r.role = 'admin' and p.subject_kind = 'user'
   and p.email and p.email_set_at is null and not t.locked and p.push = t.push_default and p.sms = t.text_default;

create function app.admin_email_type(p_kind text, p_id uuid, t notify_types) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select p_kind = 'user' and not t.locked and 'admin' = any (t.portals) and app.user_is_admin(p_id)
$$;

-- the Notifications page: switching email on stamps it; an Admin switching email off goes back to the default (the digest)
select pg_temp.patch_fn('app.notify_prefs_save(text, uuid, jsonb, uuid)'::regprocedure,
  $o$sms = case when v_ch = 'text' then v_on else notify_prefs.sms end, updated_by = excluded.updated_by;$o$,
  $n$sms = case when v_ch = 'text' then v_on else notify_prefs.sms end, updated_by = excluded.updated_by;
    -- 5051: an email switch is recorded as a choice; an Admin's "off" is the daily digest (the default for Admins)
    if v_ch = 'email' then
      update notify_prefs set email = case when app.admin_email_type(p_kind, p_id, t) then true else email end,
             email_set_at = case when v_on then now() end
       where subject_kind = p_kind and subject_id = p_id and type = t.code;
    end if;$n$);
-- what the page shows an Admin: email on only where they chose it; the rest is in the daily digest
select pg_temp.patch_fn('app.notify_prefs_state(text, uuid, text)'::regprocedure,
  $o$'push', x.push, 'email', x.email, 'text', x.sms)$o$,
  $n$'push', x.push, 'email', case when v_portal = 'admin' and app.admin_email_type(p_kind, p_id, t)
                                   then x.email and exists (select 1 from notify_prefs np where np.subject_kind = p_kind and np.subject_id = p_id and np.type = t.code and np.email and np.email_set_at is not null)
                                   else x.email end, 'text', x.sms)$n$);
select pg_temp.patch_fn('app.notify_prefs_state(text, uuid, text)'::regprocedure,
  $o$'summary', jsonb_build_object('hour', s.notify_pref_digest_hour, 'weekly_dow', s.notify_pref_weekly_dow),$o$,
  $n$'summary', jsonb_build_object('hour', s.notify_pref_digest_hour, 'weekly_dow', s.notify_pref_weekly_dow),
    'admin_email', case when v_portal = 'admin' then jsonb_build_object('digest', (select u.staff_email_digest from users u where u.id = p_id)) end,$n$);

-- ================================================================ 3. the gate on every email queued for an Admin
-- by its name it runs after the channel is chosen (notification_outbox_route) and before the person's preferences
-- (notification_outbox_staff_a_prefs) and the staff digest (notification_outbox_staff_digest)
create function app.admin_email_gate() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_type text;
  v_locked boolean;
  p notify_prefs;
  c notification_catalogue;
begin
  if new.status <> 'queued' or new.audience not like 'staff\_%' or new.recipient_user_id is null or coalesce(new.channel, 'email') <> 'email'
     or app.admin_email_keep(new.code) or not app.user_is_admin(new.recipient_user_id)
     or exists (select 1 from notification_outbox o where o.dedupe_key = new.dedupe_key) then
    return new;
  end if;
  v_type := app.notify_type_of(new.code, coalesce(new.payload ->> 'rule', (select e.payload ->> 'rule' from app_events e where e.id = new.event_id)));
  select t.locked into v_locked from notify_types t where t.code = v_type;
  if coalesce(v_locked, false) then return new; end if;
  select * into p from notify_prefs x where x.subject_kind = 'user' and x.subject_id = new.recipient_user_id and x.type = v_type;
  -- switched off by the person: the preferences trigger keeps it from going
  if p.email is false then return new; end if;
  if app.admin_email_now(new.code, new.payload, new.booking_id) then
    new.status_reason := 'urgent';
    new.priority := least(new.priority, 2);
    return new;
  end if;
  -- the Admin switched this type's email on: each one on its own, as they chose
  if p.email and p.email_set_at is not null then
    new.status_reason := 'chosen';
    return new;
  end if;
  select * into c from notification_catalogue where code = new.code;
  insert into staff_email_digest_items (user_id, audience, outbox_id, code, line, url)
  values (new.recipient_user_id, new.audience, new.id, new.code,
          left(coalesce(nullif(app.render_text(coalesce(c.subject, new.code), new.payload), ''), replace(new.code, '_', ' ')), 300),
          case when c.code is not null then app.notification_url(c, new.payload) end);
  new.status := 'skipped';
  new.status_reason := 'in the Admin daily digest';
  return new;
end $$;
drop trigger if exists notification_outbox_staff_0_admin on notification_outbox;
create trigger notification_outbox_staff_0_admin before insert on notification_outbox for each row execute function app.admin_email_gate();

-- the staff digest leaves alone what the gate let through on its own
select pg_temp.patch_fn('app.staff_email_divert()'::regprocedure,
  $o$or app.staff_email_own(new.code) or exists$o$,
  $n$or app.staff_email_own(new.code) or coalesce(new.status_reason, '') in ('urgent', 'chosen') or exists$n$);

-- ================================================================ 4. needs you now, with no email of its own
-- one alert email to every active Admin (the staff digest's template with the one line), once per key
create function app.admin_now_email(p_key text, p_line text, p_url text) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_now timestamptz := now();
  v_n integer;
begin
  insert into notification_outbox (id, code, category, priority, audience, recipient_user_id, to_address, to_name, payload, dedupe_key, status, status_reason, send_after)
  select gen_random_uuid(), 'staff_digest_hourly', 'transactional', 2, 'staff_admin', u.id, lower(btrim(u.email)), u.full_name,
         app.ntf_contact() || jsonb_build_object('first_name', split_part(coalesce(u.full_name, ''), ' ', 1), 'digest_count', '1',
           'digest_since', app.fmt_time(v_now), 'digest_date', to_char(v_now at time zone 'America/Toronto', 'Dy, Mon FMDD'),
           'digest_next', 'tomorrow 7:00 am', 'digest_summary', left('Needs you now: ' || p_line, 300), 'has_items', true,
           'items', jsonb_build_array(app.ntf_item(left(p_line, 300), app.fmt_time(v_now), p_url))),
         'admin_now|' || p_key || '|' || u.id, 'queued', 'urgent', v_now
    from users u
   where u.status = 'active' and nullif(btrim(coalesce(u.email, '')), '') is not null
     and exists (select 1 from user_roles r where r.user_id = u.id and r.role = 'admin')
  on conflict (dedupe_key) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- the staff alerts that need an Admin now: a booked live interview, a dispute's evidence due soon
alter function app.staff_alert(text, text, uuid, text, text, text, jsonb) rename to staff_alert_pre5051;
create function app.staff_alert(p_rule text, p_entity text, p_id uuid, p_disc text, p_title text, p_body text, p_extra jsonb default '{}'::jsonb)
returns bigint
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v bigint := app.staff_alert_pre5051(p_rule, p_entity, p_id, p_disc, p_title, p_body, p_extra);
begin
  if v is not null and p_rule in ('live_call_booked', 'dispute_deadline') then
    begin
      perform app.admin_now_email(p_rule || ':' || coalesce(p_id::text, '') || ':' || coalesce(p_disc, 'x'),
        left(p_title, 140) || coalesce(': ' || nullif(left(btrim(coalesce(p_body, '')), 140), ''), ''),
        rtrim((app.settings()).notify_base_url, '/') || coalesce(nullif(p_extra ->> 'path_admin', ''), '/admin/alerts'));
    exception when others then raise warning 'admin alert email not queued for %: %', p_rule, sqlerrm;
    end;
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.staff_alert(text, text, uuid, text, text, text, jsonb)'::regprocedure, 'app.staff_alert_pre5051(text, text, uuid, text, text, text, jsonb)'::regprocedure);

-- a To do marked urgent (opened urgent, or raised to urgent)
create function app.admin_task_urgent_email() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if new.priority = 'urgent' and new.status in ('open', 'in_progress', 'waiting') and (tg_op = 'INSERT' or old.priority is distinct from 'urgent') then
    begin
      perform app.admin_now_email('task:' || new.id, 'Urgent To do: ' || left(new.title, 200), rtrim((app.settings()).notify_base_url, '/') || '/admin/tasks');
    exception when others then raise warning 'urgent To do email not queued for %: %', new.id, sqlerrm;
    end;
  end if;
  return null;
end $$;
drop trigger if exists tasks_admin_urgent_email on tasks;
create trigger tasks_admin_urgent_email after insert or update of priority on tasks for each row execute function app.admin_task_urgent_email();

-- ================================================================ 5. the Admin's daily digest: counted, grouped by type
create function app.admin_email_digests(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  u record;
  v_items jsonb;
  v_summary text;
  v_n integer;
  v_last timestamptz;
  v_id uuid;
  v_out integer := 0;
  v_local timestamp := p_now at time zone 'America/Toronto';
begin
  for u in
    select x.user_id, us.email, us.full_name, us.staff_email_digest as pref, min(x.created_at) as first_at
      from staff_email_digest_items x join users us on us.id = x.user_id
     where x.digested_at is null and x.created_at <= p_now
       and exists (select 1 from user_roles r where r.user_id = x.user_id and r.role = 'admin')
     group by x.user_id, us.email, us.full_name, us.staff_email_digest
  loop
    if u.pref = 'off' or nullif(btrim(coalesce(u.email, '')), '') is null then
      update staff_email_digest_items set digested_at = p_now where user_id = u.user_id and digested_at is null and created_at <= p_now;
      continue;
    end if;
    select max(o.created_at) into v_last from notification_outbox o
     where o.code = 'staff_digest_hourly' and o.recipient_user_id = u.user_id and coalesce(o.status_reason, '') <> 'urgent';
    if u.pref = 'hourly' and v_last is not null and v_last > p_now - interval '1 hour' then continue; end if;
    if u.pref = 'daily' and (v_local::time < time '07:00' or (v_last is not null and app.local_date(v_last) = app.local_date(p_now))) then continue; end if;
    with items as (
      select x.code, x.line, x.url, x.created_at, coalesce(c.pref_type, 'staff_system') as typ
        from staff_email_digest_items x left join notification_catalogue c on c.code = x.code
       where x.user_id = u.user_id and x.digested_at is null and x.created_at <= p_now),
    kinds as (
      select typ, code, count(*)::integer as n, (array_agg(line order by created_at desc))[1] as line,
             (array_agg(url order by created_at desc))[1] as url, max(created_at) as last_at
        from items group by typ, code),
    types as (
      select k.typ, sum(k.n)::integer as n, coalesce(t.label, 'Other') as label, coalesce(t.sort, 999) as sort
        from kinds k left join notify_types t on t.code = k.typ group by k.typ, t.label, t.sort)
    select (select coalesce(jsonb_agg(app.ntf_item(k.line || case when k.n > 1 then ' (and ' || (k.n - 1) || ' more like it)' else '' end,
                                                   y.label || ', ' || app.fmt_at(k.last_at), k.url) order by y.sort, k.n desc, k.last_at desc), '[]'::jsonb)
              from kinds k join types y on y.typ = k.typ),
           (select sum(n)::integer from types),
           (select string_agg(y.label || ' ' || y.n, ', ' order by y.sort) from types y)
      into v_items, v_n, v_summary;
    v_id := gen_random_uuid();
    insert into notification_outbox (id, code, category, priority, audience, recipient_user_id, to_address, to_name, payload, dedupe_key, status, send_after)
    values (v_id, 'staff_digest_hourly', 'transactional', 3, 'staff_admin', u.user_id, lower(btrim(u.email)), u.full_name,
            app.ntf_contact() || jsonb_build_object('first_name', split_part(coalesce(u.full_name, ''), ' ', 1), 'digest_count', v_n::text,
              'digest_since', app.fmt_at(coalesce(v_last, u.first_at)), 'digest_date', to_char(v_local, 'Dy, Mon FMDD'),
              'digest_next', case u.pref when 'daily' then 'tomorrow 7:00 am' else app.fmt_time(p_now + interval '1 hour') end,
              'digest_summary', left(v_n || ' alert' || case when v_n <> 1 then 's' else '' end || ' by type: ' || v_summary || '.', 600),
              'has_items', v_n > 0, 'items', v_items),
            'staff_digest_hourly|' || u.user_id || '|' || to_char(p_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI'), 'queued', p_now)
    on conflict (dedupe_key) do nothing;
    update staff_email_digest_items set digested_at = p_now, digest_outbox_id = v_id where user_id = u.user_id and digested_at is null and created_at <= p_now;
    v_out := v_out + 1;
  end loop;
  return v_out;
end $$;

-- the job of 0583 (every 5 minutes): the Admins' digests first, then everyone else's as before
alter function app.staff_email_digests(timestamptz) rename to staff_email_digests_pre5051;
create function app.staff_email_digests(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  return app.admin_email_digests(p_now) + app.staff_email_digests_pre5051(p_now);
end $$;
select pg_temp.copy_grants('app.staff_email_digests(timestamptz)'::regprocedure, 'app.staff_email_digests_pre5051(timestamptz)'::regprocedure);

-- ================================================================ 6. the Admins move to the daily digest
-- only those still on the old default (hourly): an Admin the audit log shows choosing hourly keeps it
update users u set staff_email_digest = 'daily'
 where u.staff_email_digest = 'hourly'
   and exists (select 1 from user_roles r where r.user_id = u.id and r.role = 'admin')
   and not exists (select 1 from audit_log a where a.entity_table = 'users' and a.entity_id = u.id::text and a.action = 'UPDATE' and a.after ->> 'staff_email_digest' = 'hourly');
-- a new Admin starts on the daily digest
create function app.admin_digest_default() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if new.role = 'admin' then
    update users set staff_email_digest = 'daily' where id = new.user_id and staff_email_digest = 'hourly'
       and not exists (select 1 from audit_log a where a.entity_table = 'users' and a.entity_id = new.user_id::text and a.action = 'UPDATE' and a.after ->> 'staff_email_digest' = 'hourly');
  end if;
  return null;
end $$;
drop trigger if exists user_roles_admin_digest on user_roles;
create trigger user_roles_admin_digest after insert on user_roles for each row execute function app.admin_digest_default();

-- ================================================================ privileges
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['admin_email_now', 'admin_email_keep', 'admin_email_type', 'admin_email_gate', 'admin_now_email',
                    'staff_alert_pre5051', 'admin_task_urgent_email', 'admin_email_digests', 'staff_email_digests_pre5051', 'admin_digest_default']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
