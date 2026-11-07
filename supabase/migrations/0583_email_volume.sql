-- 0583_email_volume.sql
-- Release 29, C3 (docs/changes/2026-11-06-email-volume.md): at 18:00 on November 6 the owner's inbox was flooded: 0535
-- released the whole held backlog at once, and the staff copies landed in his inbox.
--   1. 300 a day in all, in one place (app.email_day_cap, used by the claim): Program settings notify_daily_cap (300),
--      never more than the providers' sum (Cloudflare 200 + Resend 100), and Resend's 100 alone while Cloudflare email has
--      never sent one. What is over the day waits for the next day (paced), never failed. The class limits follow the cap.
--   2. No bursts: the claim sends at most the day's even pace plus 30 an hour (ceil(cap / 24) + 30), whatever was held, a
--      reset or a migration releases; in priority order (customer, owner, hiring, staff, digests, marketing). Nothing
--      sets a held email's send_after to "now" any more.
--   3. Staff inboxes: a staff or Admin alert by email (audience staff_%) that is not urgent goes into one digest per person
--      (staff_digest_hourly): at most one an hour, or one a day at 07:00, or none (users.staff_email_digest, Profile >
--      Notifications). Urgent ones go at once, at most 3 an hour per person: a payment declined, documents to review for a
--      pickup within 2 hours, the site down. Every alert is still an in-app notice (and a phone alert) at once.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. one daily cap
update program_settings set notify_daily_cap = 300 where notify_daily_cap < 300;
update program_settings set notify_class_limits = array[300, 300, 285, 285, 180] where notify_class_limits = array[100, 100, 95, 95, 60];
comment on column program_settings.notify_daily_cap is 'Emails a day in all, every provider together (0583: 300; never more than the Cloudflare and Resend budgets together, and Resend''s alone while Cloudflare email has never sent). Over it, emails wait for the next day.';

-- Cloudflare email has sent at least one email (until then its budget is not counted)
create or replace function app.cf_email_ever_sent() returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from notification_outbox o where o.status = 'sent' and o.provider_id like 'cf:%')
$$;

create or replace function app.email_day_cap(p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  -- the setting as the Admin wrote it (app.settings lowers notify_daily_cap to Resend's own plan, which is Resend's alone)
  select greatest(0, least(s.notify_daily_cap,
           (case when app.cf_email_ever_sent() then s.notify_cf_daily_budget else 0 end) + s.notify_resend_daily_budget))::integer
    from app.settings_base(app.local_date(p_now)) s
$$;

-- the emails gone (or going) since a time, every provider
create or replace function app.emails_since(p_from timestamptz, p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select count(*)::integer from notification_outbox o
   where coalesce(o.channel, 'email') = 'email'
     and ((o.status = 'sent' and o.sent_at >= p_from) or (o.status = 'sending' and o.locked_at >= p_now - interval '15 minutes'))
$$;

-- the day and the hour as they stand (the claim, the Admin usage card)
create or replace function app.email_pace(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('day_cap', c.cap, 'day_used', app.emails_since(app.local_midnight(app.local_date(p_now)), p_now),
    'hour_cap', ceil(c.cap / 24.0)::integer + 30, 'hour_used', app.emails_since(p_now - interval '1 hour', p_now),
    'cf_ever_sent', app.cf_email_ever_sent(), 'setting', s.notify_daily_cap, 'cf_budget', s.notify_cf_daily_budget, 'resend_budget', s.notify_resend_daily_budget,
    'waiting', (select count(*) from notification_outbox o where o.status in ('queued', 'delayed') and coalesce(o.channel, 'email') = 'email'))
    from (select app.email_day_cap(p_now) cap) c, app.settings_base(app.local_date(p_now)) s
$$;

-- ================================================================ 2. the claim: the day's cap and the hour's pace
alter function app.outbox_claim(integer, timestamptz) rename to outbox_claim_pre0583;
create or replace function app.outbox_claim(p_limit integer default 20, p_now timestamptz default now())
returns table (id uuid, code text, category text, to_address text, to_name text, from_address text, reply_to text,
               subject text, payload jsonb, attempts integer, unsubscribe_url text, template_html text, template_text text)
language plpgsql security definer set search_path = public, app as $$
declare
  v_cap integer := app.email_day_cap(p_now);
  v_day_left integer;
  v_hour_left integer;
  v_lim integer;
  r record;
begin
  -- hiring after customers and owners (priority 2), before staff (3)
  update notification_outbox o set priority = 2 where o.status in ('queued', 'delayed') and o.code like 'applicant\_%' and o.priority < 2;
  v_day_left := v_cap - app.emails_since(app.local_midnight(app.local_date(p_now)), p_now);
  v_hour_left := (ceil(v_cap / 24.0)::integer + 30) - app.emails_since(p_now - interval '1 hour', p_now);
  v_lim := least(coalesce(p_limit, 20), v_hour_left);
  if v_lim <= 0 or v_day_left <= 0 then
    -- over the day: what is due waits for the next day (the claim of 0018 holds Resend's own; this holds every provider)
    if v_day_left <= 0 then
      update notification_outbox o set status = 'delayed', status_reason = 'daily email limit', send_after = app.local_midnight(app.local_date(p_now) + 1)
       where o.status in ('queued', 'delayed') and o.send_after <= p_now and coalesce(o.channel, 'email') = 'email';
    end if;
    return;
  end if;
  -- the hour's pace is the claim's limit; past the day's cap (Cloudflare's sends, which the claim of 0222 lets past
  -- Resend's cap) an email is put back for the next day, its attempt not counted
  for r in select * from app.outbox_claim_pre0583(v_lim, p_now) loop
    if v_day_left <= 0 then
      update notification_outbox o set status = 'delayed', status_reason = 'daily email limit', attempts = greatest(o.attempts - 1, 0), locked_at = null,
             send_after = app.local_midnight(app.local_date(p_now) + 1) where o.id = r.id;
      continue;
    end if;
    v_day_left := v_day_left - 1;
    id := r.id; code := r.code; category := r.category; to_address := r.to_address; to_name := r.to_name; from_address := r.from_address;
    reply_to := r.reply_to; subject := r.subject; payload := r.payload; attempts := r.attempts; unsubscribe_url := r.unsubscribe_url;
    template_html := r.template_html; template_text := r.template_text;
    return next;
  end loop;
end $$;
select pg_temp.copy_grants('app.outbox_claim(integer, timestamptz)'::regprocedure, 'app.outbox_claim_pre0583(integer, timestamptz)'::regprocedure);

-- ================================================================ 3. staff inboxes
alter table users add column if not exists staff_email_digest text not null default 'hourly' check (staff_email_digest in ('hourly', 'daily', 'off'));
comment on column users.staff_email_digest is 'Staff and Admin alerts by email (0583): one digest an hour, one a day at 07:00, or none (in-app and phone alerts only). Urgent alerts still go on their own.';

create table if not exists staff_email_digest_items (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references users (id) on delete cascade,
  audience      text not null,
  outbox_id     uuid,
  code          text not null,
  line          text not null,
  url           text,
  created_at    timestamptz not null default now(),
  digested_at   timestamptz,
  digest_outbox_id uuid
);
create index if not exists staff_email_digest_items_open on staff_email_digest_items (user_id, created_at) where digested_at is null;
alter table staff_email_digest_items enable row level security;
create policy admin_all on staff_email_digest_items for all to authenticated using (app.is_admin()) with check (app.is_admin());
comment on table staff_email_digest_items is 'Staff and Admin alerts kept for the person''s email digest instead of their own email (0583).';

-- urgent: sent on their own (at most 3 an hour per person)
create or replace function app.staff_email_urgent(p_code text, p_booking uuid, p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_code in ('staff_payment_failed', 'staff_site_alert')
      or (p_code = 'staff_identity_review' and exists (select 1 from bookings b where b.id = p_booking and b.pickup_at between p_now - interval '1 hour' and p_now + interval '2 hours'))
$$;

-- what stays an email of its own: the scheduled lists and digests, and a person's own pay and commission
create or replace function app.staff_email_own(p_code text) returns boolean
language sql immutable as $$
  select p_code like 'staff\_digest\_%' or p_code in ('staff_field_jobs_today', 'staff_field_jobs_tomorrow', 'staff_pay_statement', 'staff_commission_approved', 'staff_commission_paid')
$$;

create or replace function app.staff_email_divert() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare c notification_catalogue; v_urgent integer;
begin
  if new.status <> 'queued' or new.audience not like 'staff\_%' or new.recipient_user_id is null or coalesce(new.channel, 'email') <> 'email'
     or app.staff_email_own(new.code) or exists (select 1 from notification_outbox o where o.dedupe_key = new.dedupe_key) then
    return new;
  end if;
  if app.staff_email_urgent(new.code, new.booking_id) then
    select count(*) into v_urgent from notification_outbox o
     where o.recipient_user_id = new.recipient_user_id and o.created_at > now() - interval '1 hour' and o.status_reason = 'urgent'
       and o.status in ('queued', 'delayed', 'sending', 'sent');
    if v_urgent < 3 then new.status_reason := 'urgent'; new.priority := least(new.priority, 2); return new; end if;
  end if;
  select * into c from notification_catalogue where code = new.code;
  insert into staff_email_digest_items (user_id, audience, outbox_id, code, line, url)
  values (new.recipient_user_id, new.audience, new.id, new.code,
          left(coalesce(nullif(app.render_text(coalesce(c.subject, new.code), new.payload), ''), replace(new.code, '_', ' ')), 300),
          case when c.code is not null then app.notification_url(c, new.payload) end);
  new.status := 'skipped';
  new.status_reason := 'in the staff email digest';
  return new;
end $$;
drop trigger if exists notification_outbox_staff_digest on notification_outbox;
create trigger notification_outbox_staff_digest before insert on notification_outbox for each row execute function app.staff_email_divert();

-- the digests due now: hourly (an hour after the person's last), daily (07:00 Toronto), off (none: marked done)
create or replace function app.staff_email_digests(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  u record;
  v_items jsonb;
  v_n integer;
  v_since timestamptz;
  v_last timestamptz;
  v_id uuid;
  v_out integer := 0;
  v_local timestamp := p_now at time zone 'America/Toronto';
begin
  for u in
    select x.user_id, us.email, us.full_name, us.staff_email_digest as pref, min(x.created_at) as first_at,
           (array_agg(x.audience order by x.created_at desc))[1] as audience
      from staff_email_digest_items x join users us on us.id = x.user_id
     where x.digested_at is null and x.created_at <= p_now
     group by x.user_id, us.email, us.full_name, us.staff_email_digest
  loop
    if u.pref = 'off' or nullif(btrim(coalesce(u.email, '')), '') is null then
      update staff_email_digest_items set digested_at = p_now where user_id = u.user_id and digested_at is null and created_at <= p_now;
      continue;
    end if;
    select max(o.created_at) into v_last from notification_outbox o where o.code = 'staff_digest_hourly' and o.recipient_user_id = u.user_id;
    if u.pref = 'hourly' and v_last is not null and v_last > p_now - interval '1 hour' then continue; end if;
    if u.pref = 'daily' and (v_local::time < time '07:00' or (v_last is not null and app.local_date(v_last) = app.local_date(p_now))) then continue; end if;
    select coalesce(jsonb_agg(app.ntf_item(x.line, app.fmt_time(x.created_at), x.url) order by x.created_at), '[]'::jsonb), count(*)
      into v_items, v_n from staff_email_digest_items x where x.user_id = u.user_id and x.digested_at is null and x.created_at <= p_now;
    v_since := coalesce(v_last, u.first_at);
    v_id := gen_random_uuid();
    insert into notification_outbox (id, code, category, priority, audience, recipient_user_id, to_address, to_name, payload, dedupe_key, status, send_after)
    values (v_id, 'staff_digest_hourly', 'transactional', 3, u.audience, u.user_id, lower(btrim(u.email)), u.full_name,
            jsonb_build_object('first_name', split_part(coalesce(u.full_name, ''), ' ', 1), 'digest_count', v_n::text,
              'digest_since', app.fmt_time(v_since), 'digest_date', to_char(v_local, 'Dy, Mon FMDD'),
              'digest_next', case u.pref when 'daily' then 'tomorrow 7:00 am' else app.fmt_time(p_now + interval '1 hour') end,
              'digest_summary', v_n || ' alert' || case when v_n <> 1 then 's' else '' end || ' since ' || app.fmt_time(v_since) || '.',
              'has_items', v_n > 0, 'items', v_items),
            'staff_digest_hourly|' || u.user_id || '|' || to_char(p_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI'), 'queued', p_now)
    on conflict (dedupe_key) do nothing;
    update staff_email_digest_items set digested_at = p_now, digest_outbox_id = v_id where user_id = u.user_id and digested_at is null and created_at <= p_now;
    v_out := v_out + 1;
  end loop;
  return v_out;
end $$;

-- every 5 minutes with the scheduled notices
alter function app.job_notify_scheduled(timestamptz) rename to job_notify_scheduled_pre0583;
create or replace function app.job_notify_scheduled(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare v text := app.job_notify_scheduled_pre0583(p_now); v_n integer;
begin
  begin
    v_n := app.staff_email_digests(p_now);
  exception when others then
    raise warning 'staff email digests: %', sqlerrm;
    v_n := 0;
  end;
  return v;
end $$;
select pg_temp.copy_grants('app.job_notify_scheduled(timestamptz)'::regprocedure, 'app.job_notify_scheduled_pre0583(timestamptz)'::regprocedure);

-- ================================================================ the door: the person's choice, the usage card
create or replace function app.my_staff_digest_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not exists (select 1 from user_roles r where r.user_id = p_by and r.role in ('admin', 'va', 'field')) then raise exception 'Staff only' using errcode = '42501'; end if;
  if coalesce(p ->> 'digest', '') not in ('hourly', 'daily', 'off') then raise exception 'Hourly digest, daily digest or off' using errcode = '22023'; end if;
  update users set staff_email_digest = p ->> 'digest' where id = p_by;
  return jsonb_build_object('digest', p ->> 'digest');
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0583;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_call in ('ops_do', 'admin_do') and p_name = 'owner_debit_setup_link' then
    perform app.door_begin(p_user, p_aal);
    return app.owner_debit_setup_link(p_user, v);
  end if;
  if (p_call in ('ops_do', 'admin_do') and p_name = 'my_staff_digest_save') or (p_call in ('ops_read', 'admin_read') and p_name in ('my_staff_digest', 'email_pace')) then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    if p_name = 'my_staff_digest_save' then return app.my_staff_digest_save(p_user, v); end if;
    if p_name = 'my_staff_digest' then return jsonb_build_object('digest', (select staff_email_digest from users where id = p_user)); end if;
    if not app.user_is_admin(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.email_pace(now());
  end if;
  return app.door_pre0583(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0583(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f text;
begin
  foreach f in array array['app.cf_email_ever_sent()', 'app.email_day_cap(timestamptz)', 'app.emails_since(timestamptz, timestamptz)', 'app.email_pace(timestamptz)',
    'app.staff_email_urgent(text, uuid, timestamptz)', 'app.staff_email_own(text)', 'app.staff_email_divert()', 'app.staff_email_digests(timestamptz)', 'app.my_staff_digest_save(uuid, jsonb)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- ================================================================ 4. staff emails in plain words (C4)
-- The owner, November 6: the "Owner debit exception" email was insanely confusing. Each staff email that used internal
-- words (exception, mandate, run key, webhook) now says what happened, how much, what to do, with one button. The words
-- for why a debit cannot go ahead are the ones of the owner guide ("no bank debit set up", "owner cancelled the debit at
-- their bank", "amount went up after the notice", "the bank sent the payment back").
create or replace function app.owner_debit_reason_plain(p_kind text, p_reason text) returns text
language sql immutable as $$
  select case p_kind
    when 'no_mandate' then 'no bank debit set up'
    when 'mandate_revoked' then 'owner cancelled the debit at their bank'
    when 'amount_changed' then 'amount went up after the notice'
    when 'returned' then 'the bank sent the payment back' || coalesce(' (' || lower(nullif(btrim(p_reason), '')) || ')', '')
    when 'retry_window' then 'the bank sent the payment back, too late to try again'
    else case
      when p_reason = 'automatic debits are off in settings' then 'automatic debits are turned off'
      when p_reason = 'deducted from payouts' then 'it comes off the owner''s payouts instead'
      when p_reason = 'a payment is already processing' then 'a payment is already on its way'
      when p_reason = 'not billed for this vehicle' then 'this car is not billed to the owner'
      when p_reason = 'this kind of invoice is not debited automatically' then 'this kind of invoice is not taken by bank debit'
      when p_reason = 'nothing is owing' then 'nothing is owing'
      when p_reason like 'the invoice is %' then p_reason
      else 'the debit could not be sent' end end
$$;

-- what the person does about it: one button (the Debits tab opens on that owner with the one action, or the invoice)
create or replace function app.owner_debit_fix(p_kind text, p_reason text, p_owner uuid, p_invoice text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with b as (select rtrim((app.settings()).notify_base_url, '/') as base)
  select case
    when p_kind in ('no_mandate', 'mandate_revoked') then jsonb_build_object(
      'fix_label', 'Send the sign-up link',
      'fix_text', case p_kind when 'no_mandate' then 'Send the owner the link to set up their bank debit. Nothing is taken until they do.'
                  else 'Send the owner the link to set up their bank debit again. Nothing is taken until they do.' end,
      'fix_url', b.base || '/admin/owner-money?tab=debits&owner=' || p_owner || '&fix=setup')
    when p_kind = 'amount_changed' then jsonb_build_object(
      'fix_label', 'Send a new notice',
      'fix_text', 'Send the owner a new notice for the new amount. The debit goes ahead after the notice period.',
      'fix_url', b.base || '/admin/owner-money?tab=debits&owner=' || p_owner || '&fix=notice')
    when p_reason = 'automatic debits are off in settings' then jsonb_build_object(
      'fix_label', 'Open Program settings',
      'fix_text', 'Turn automatic debits back on in Program settings, or collect the invoice another way.',
      'fix_url', b.base || '/admin/settings/program')
    when p_kind in ('returned', 'retry_window') then jsonb_build_object(
      'fix_label', 'Open the invoice',
      'fix_text', 'The owner was asked to pay it from the invoice page. Record the payment there if they pay another way.',
      'fix_url', b.base || '/admin/owners/' || p_owner || coalesce('#inv-' || p_invoice, ''))
    else jsonb_build_object(
      'fix_label', 'Open the invoice',
      'fix_text', 'Open the invoice to see it and collect it another way.',
      'fix_url', b.base || '/admin/owners/' || p_owner || coalesce('#inv-' || p_invoice, '')) end
    from b
$$;

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0583;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0583(p_code, p_event, p_to);
  v_kind text := p_event.payload ->> 'exception';
  v_reason text := nullif(p_event.payload ->> 'reason', '');
  v_owner uuid;
  v_items jsonb;
  v_n integer;
  v_job text;
begin
  if x is null then return x; end if;
  if p_code = 'staff_owner_debit_exception' then
    v_owner := coalesce((p_event.payload ->> 'owner_id')::uuid, case when p_event.entity = 'owner' then p_event.entity_id end);
    v_items := coalesce(x -> 'debit_items', '[]'::jsonb);
    v_n := jsonb_array_length(v_items);
    x := x || jsonb_build_object(
      'reason_plain', app.owner_debit_reason_plain(v_kind, v_reason),
      'debit_for', case when v_n = 0 then 'the open invoices'
                        when v_n = 1 then 'invoice ' || (v_items -> 0 ->> 'invoice_number') || coalesce(' (' || nullif(v_items -> 0 ->> 'vehicle', '') || ')', '')
                        else v_n || ' invoices (' || (select string_agg(e ->> 'invoice_number', ', ') from jsonb_array_elements(v_items) e) || ')' end)
      || app.owner_debit_fix(v_kind, v_reason, v_owner, v_items -> 0 ->> 'invoice_number');
    x := x || jsonb_build_object('_url', x ->> 'fix_url');
  elsif p_code = 'staff_owner_invoice_failed' then
    x := x || jsonb_build_object('fix_text', case x ->> 'failure_stage'
      when 'retry failed, in arrears' then 'The second try failed too, so it comes off the owner''s next payout. Record the payment on the invoice if they pay another way.'
      when 'first failure' then 'Nothing to do yet: we try again on ' || coalesce(x ->> 'retry_date', 'the retry date') || ' for ' || coalesce(x ->> 'retry_amount', 'the amount')
                                 || ', late fee included. Record the payment on the invoice if they pay another way.'
      else 'The owner was asked to pay it from the invoice page. Record the payment there if they pay another way.' end);
  elsif p_code = 'staff_owner_debit_run' and jsonb_typeof(x -> 'run_items') = 'array' then
    x := jsonb_set(x, '{run_items}', coalesce((select jsonb_agg(e || jsonb_build_object('status',
           replace(replace(replace(e ->> 'status', 'no pre-authorized debit mandate', 'no bank debit set up'),
                           'the balance is more than the notice', 'amount went up after the notice'), 'Sent, processing', 'Sent, waiting for the bank')) order by o)
           from jsonb_array_elements(x -> 'run_items') with ordinality t(e, o)), '[]'::jsonb));
  elsif p_code = 'staff_job_failed' then
    v_job := coalesce(nullif(x ->> 'job_name', ''), nullif(p_event.payload ->> 'job_name', ''), 'scheduled');
    x := x || jsonb_build_object('job_label', lower(replace(replace(v_job, '_', ' '), '-', ' ')),
      'job_effect', format('The automatic %s task did not finish, so its work has not happened yet.', lower(replace(replace(v_job, '_', ' '), '-', ' '))));
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre0583(text, app_events, jsonb)'::regprocedure);

-- the site check's names in plain words (an Admin's own wording is kept)
update uptime_checks set label = 'Site health check' where key = 'health' and label = 'Site health check (/api/health)';
update uptime_checks set label = 'Card payment updates from Stripe' where key = 'stripe' and label = 'Stripe webhook';

-- the one action of the Debits tab's "fix" card: the owner's bank debit sign-up link again
create or replace function app.owner_debit_setup_link(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare o owners;
begin
  if not (app.user_is_admin(p_by) or app.user_runs_finance(p_by)) then raise exception 'Finance or an Admin sends the sign-up link' using errcode = '42501'; end if;
  select * into o from owners where id = (p ->> 'owner')::uuid;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  if app.owner_debit_mandate(o.id) is not null then raise exception 'This owner already has a bank debit set up' using errcode = '23514'; end if;
  perform app.ntf_emit('owner_debit_setup_needed', 'owner', o.id, 'link:' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'), jsonb_build_object('owner_id', o.id));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'owner_debit_setup_link', 'owners', o.id::text, jsonb_build_object('sent', true));
  return jsonb_build_object('ok', true, 'message', 'Sign-up link sent to ' || o.legal_name);
end $$;
revoke all on function app.owner_debit_setup_link(uuid, jsonb), app.owner_debit_fix(text, text, uuid, text) from public, anon, authenticated;
grant execute on function app.owner_debit_setup_link(uuid, jsonb), app.owner_debit_fix(text, text, uuid, text) to service_role;

-- ================================================================ the email in the catalogue
-- CATALOGUE 0583 START (generated by supabase/seed/0583_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('staff_digest_hourly', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your CarmaCars alerts: {{digest_count}} since {{digest_since}}', '{{digest_summary}}', 'At most hourly', 'Staff and Admin alerts by email (migration 0583): each alert that is not urgent is kept for this digest instead of its own email; at most one digest an hour per person (or one a day at 07:00 Toronto time, or none, as each person chooses under Profile, Notifications), with every alert since the last one. Urgent alerts (a payment declined, documents to review for a pickup within 2 hours, the site down) still go on their own, at most 3 an hour per person. Every alert is also an in-app notice and a phone alert at once.', null, '/admin', '[{"name":"company_address","type":"string","global":true},{"name":"digest_count","type":"string"},{"name":"digest_date","type":"string"},{"name":"digest_next","type":"string"},{"name":"digest_since","type":"string"},{"name":"digest_summary","type":"string"},{"name":"first_name","type":"string"},{"name":"has_items","type":"boolean"},{"name":"items","type":"list","fields":["line","meta","url"]}]'::jsonb, 'templates/staff_digest_hourly.html', 'templates/staff_digest_hourly.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
update notification_catalogue set subject = 'Can''t collect {{debit_total}} from {{owner_name}}: {{reason_plain}}', preheader = '{{fix_text}}', variables = '[{"name":"company_address","type":"string","global":true},{"name":"debit_date","type":"string"},{"name":"debit_for","type":"string"},{"name":"debit_items","type":"list","fields":["invoice_number","amount","car","fee","period","how","line","url"]},{"name":"debit_total","type":"string"},{"name":"fix_label","type":"string"},{"name":"fix_text","type":"string"},{"name":"fix_url","type":"url"},{"name":"owner_name","type":"string"},{"name":"reason_plain","type":"string"}]'::jsonb, updated_at = now() where code = 'staff_owner_debit_exception';
update notification_catalogue set subject = 'Owner payment bounced: {{amount}} from {{owner_name}}, {{vehicle_name}}', preheader = '{{fix_text}}', variables = '[{"name":"amount","type":"string"},{"name":"amount_items","type":"list","fields":["invoice_number","amount","car","fee","period","how","line","url"]},{"name":"bank_reason","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"fix_text","type":"string"},{"name":"invoice_number","type":"string"},{"name":"owner_name","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, updated_at = now() where code = 'staff_owner_invoice_failed';
update notification_catalogue set subject = 'Owner debits sent {{run_date}}: {{submitted_count}} for {{submitted_total}}', preheader = '{{skipped_count}} not sent, {{failed_count}} refused at once. Bank results follow over the next days.', variables = '[{"name":"company_address","type":"string","global":true},{"name":"failed_count","type":"string"},{"name":"no_mandate_count","type":"string"},{"name":"run_date","type":"string"},{"name":"run_items","type":"list","fields":["owner","status","invoice_number","amount","car","fee","period","how","line","url"]},{"name":"skipped_count","type":"string"},{"name":"submitted_count","type":"string"},{"name":"submitted_total","type":"string"}]'::jsonb, updated_at = now() where code = 'staff_owner_debit_run';
update notification_catalogue set subject = 'Automatic task failed: {{job_label}}, {{job_run_date}}', preheader = '{{job_effect}}', variables = '[{"name":"company_address","type":"string","global":true},{"name":"job_effect","type":"string"},{"name":"job_error","type":"string"},{"name":"job_label","type":"string"},{"name":"job_run_date","type":"string"}]'::jsonb, updated_at = now() where code = 'staff_job_failed';
update notification_catalogue set subject = 'Calendar link not working: {{vehicle_name}} on {{platform}}', preheader = '{{failures}} tries in a row. New {{platform}} trips do not block the car until it works again.', variables = '[{"name":"calendar_url","type":"url"},{"name":"company_address","type":"string","global":true},{"name":"failures","type":"string"},{"name":"feed_error","type":"string"},{"name":"last_success","type":"string"},{"name":"platform","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, updated_at = now() where code = 'staff_calendar_feed_failing';
update notification_catalogue set subject = '{{usage_title}}', preheader = '{{usage_used}} of {{usage_included}} used. {{usage_effect}}', variables = '[{"name":"company_address","type":"string","global":true},{"name":"service_label","type":"string"},{"name":"usage_advice","type":"string"},{"name":"usage_cost","type":"string"},{"name":"usage_effect","type":"string"},{"name":"usage_included","type":"string"},{"name":"usage_period","type":"string"},{"name":"usage_resets","type":"string"},{"name":"usage_share","type":"string"},{"name":"usage_title","type":"string"},{"name":"usage_used","type":"string"}]'::jsonb, updated_at = now() where code = 'staff_usage_alert';
update notification_catalogue set subject = 'Pre-authorized debit on {{debit_date}}: {{debit_total}}', preheader = '{{debit_count_text}} from your account ending {{bank_last4}}. Nothing to do if your account is up to date.', variables = '[{"name":"bank_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"debit_count_text","type":"string"},{"name":"debit_date","type":"string"},{"name":"debit_items","type":"list","fields":["invoice_number","amount","car","fee","period","how","line","url"]},{"name":"debit_total","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"late_fee_rule","type":"string"},{"name":"notice_days","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, updated_at = now() where code = 'owner_debit_notice';
update notification_catalogue set subject = 'Set up your bank debit for {{debit_total}} due {{debit_date}}', preheader = 'We have no pre-authorized debit for your account, so nothing was scheduled. It takes two minutes.', variables = '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"debit_date","type":"string"},{"name":"debit_day","type":"string"},{"name":"debit_items","type":"list","fields":["invoice_number","amount","car","fee","period","how","line","url"]},{"name":"debit_total","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"late_fee_rule","type":"string"},{"name":"notice_days","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, updated_at = now() where code = 'owner_debit_setup_needed';
update notification_catalogue set subject = 'The debit for invoice {{invoice_number}} was returned', preheader = 'We will not debit this invoice again. Pay it from its page or update your bank account.', variables = '[{"name":"amount","type":"string"},{"name":"amount_items","type":"list","fields":["invoice_number","amount","car","fee","period","how","line","url"]},{"name":"balance","type":"string"},{"name":"bank_reason","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"debit_date","type":"string"},{"name":"first_name","type":"string"},{"name":"has_late_fee","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_number","type":"string"},{"name":"late_fee","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, updated_at = now() where code = 'owner_debit_returned';
update notification_catalogue set subject = 'Your {{amount}} payment for the {{vehicle_name}} failed', preheader = 'A {{late_fee}} late fee is added to your next debit. We retry {{amount}} on or after {{retry_date}}.', variables = '[{"name":"amount","type":"string"},{"name":"amount_items","type":"list","fields":["invoice_number","amount","car","fee","period","how","line","url"]},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_month","type":"string"},{"name":"invoice_number","type":"string"},{"name":"late_fee","type":"string"},{"name":"late_fee_rule","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"retry_amount","type":"string"},{"name":"retry_date","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, updated_at = now() where code = 'owner_payment_failed';
update notification_catalogue set subject = 'In arrears: {{arrears_amount}} owing on your {{vehicle_name}}', preheader = 'The retry failed. Pay by {{removal_date}} to keep the vehicle in the program.', variables = '[{"name":"amount","type":"string"},{"name":"amount_items","type":"list","fields":["invoice_number","amount","car","fee","period","how","line","url"]},{"name":"arrears_amount","type":"string"},{"name":"arrears_removal_days","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_number","type":"string"},{"name":"is_self_managed","type":"boolean"},{"name":"late_fee","type":"string"},{"name":"next_payout_date","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"removal_date","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, updated_at = now() where code = 'owner_in_arrears';
select app.notification_catalogue_refresh();
-- CATALOGUE 0583 END
update notification_catalogue set emitted_by = 'app.staff_email_digests (0583)' where code = 'staff_digest_hourly';
