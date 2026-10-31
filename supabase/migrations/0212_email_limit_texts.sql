-- 0212: when the email limit is hit, booking and pickup messages still reach renters by text (Release 21b, extra item).
-- SCHEMA_MARKER 0212. docs/changes/2026-11-01-email-limit-texts.md.
--   Production, October 30, 2026: the email provider's daily limit was used up and renters picking up cars did not get their
--   emails. Now:
--   1. An email held for the daily or monthly limit (ours, app.outbox_claim, or the provider's, app.outbox_defer) whose code
--      is booking- or pickup-critical (site_settings.email_limit_text_codes: the confirmation, the agreement and signing
--      links, pickup details, the handover, the payment links, the signing codes) goes at once by text to the recipient's
--      mobile through the phone line (phone_outbox, sent by the five-minute phone job through Quo): the key line and the
--      link into the portal (the email's own ?m= tag, as its links carry). Once per outbox row
--      (notification_outbox.limit_text_id); the email itself still goes when the limit lifts. On by default: Admin >
--      Settings > Site, "Email limit: text booking and pickup messages" (site_settings.email_limit_texts).
--   2. app.email_capped(): email use at or above the daily or monthly cap, or held by the provider's limit. While it is,
--      sign-in opens on the phone option (public.server_email_capped) and the signing code is offered by text first
--      (app.esign_view: default_channel, email_held).
--   3. Admin > Email (/admin/messages): "Text it instead" on a held or queued row (admin_do outbox_text).
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

alter table site_settings add column if not exists email_limit_texts boolean not null default true;
alter table site_settings add column if not exists email_limit_text_codes text[] not null default array[
  'renter_booking_confirmed', 'renter_booking_reminder', 'renter_agreement_ready', 'renter_agreement_version', 'renter_rental_added',
  'renter_driver_link', 'renter_pickup_details', 'renter_rental_started', 'renter_offer_ready', 'renter_balance_overdue',
  'renter_payment_failed', 'renter_recovery_pay', 'renter_deposit_declined', 'renter_signing_code', 'document_signing_code']::text[];
comment on column site_settings.email_limit_texts is 'Email limit (0212): while emails are held for the daily or monthly limit, the booking and pickup ones go by text at once (the email still goes later).';
comment on column site_settings.email_limit_text_codes is 'Email limit (0212): the email codes texted while held for the limit (booking and pickup critical).';

alter table notification_outbox add column if not exists limit_text_id uuid references phone_outbox (id) on delete set null;
alter table notification_outbox add column if not exists limit_texted_at timestamptz;
comment on column notification_outbox.limit_text_id is 'The text sent in place of this email while it was held for the email limit (0212); once per row.';
comment on column notification_outbox.limit_texted_at is 'When this email was texted instead (0212): automatically while held for the limit, or by an Admin (Text it instead).';

create or replace function app.email_limit_reasons() returns text[]
language sql immutable as $$
  select array['daily email limit', 'monthly email limit', 'the email provider''s daily limit', 'the email provider''s monthly limit']
$$;

-- email use at or above the cap: ours (daily, monthly) or the provider's (a row held for its limit until later)
create or replace function app.email_capped(p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  with u as (select app.email_usage(p_now) j), s as (select * from app.settings(app.local_date(p_now)))
  select (u.j ->> 'total')::int >= (u.j ->> 'cap')::int
      or (select count(*) from notification_outbox o where o.status = 'sent' and o.sent_at >= app.local_midnight(app.month_start(app.local_date(p_now)))) >= s.notify_monthly_cap
      or exists (select 1 from notification_outbox o where o.status = 'delayed' and o.send_after > p_now
                    and o.status_reason in ('the email provider''s daily limit', 'the email provider''s monthly limit'))
    from u, s
$$;

-- the mobile a held email's text goes to: the verified phone of the person, else the number on the record the email is about
-- (the signing session's, the renter's), never a number that opted out
create or replace function app.outbox_text_number(o notification_outbox) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  w jsonb := app.notify_who(o);
  r jsonb := app.notify_reach((w ->> 'user_id')::uuid, w ->> 'kind', (w ->> 'record')::uuid);
  v text := r ->> 'phone';
begin
  if v is null and o.entity = 'esign_session' then select app.phone_e164(s.mobile) into v from esign_sessions s where s.id = o.entity_id; end if;
  if v is null and o.audience = 'renter' then
    select app.phone_e164(x.mobile) into v from renters x where x.id = coalesce(o.renter_id, (select b.renter_id from bookings b where b.id = o.booking_id));
  end if;
  if v is null or coalesce(app.phone_country(v), 'other') not in ('CA', 'US') then return null; end if;
  if exists (select 1 from phone_threads t where t.number = v and t.opted_out_at is not null) then return null; end if;
  return v;
end $$;

-- the text of a held email: its text template (the key line and its page), or for a signing code the code itself; the
-- renter's portal links carry the email's ?m= tag as the email's links do
create or replace function app.outbox_text_body(o notification_outbox) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  c notification_catalogue;
  v_t jsonb;
  v_body text;
begin
  select * into c from notification_catalogue where code = o.code;
  if c.code is null then return null; end if;
  if nullif(o.payload ->> 'code', '') is not null and o.code like '%signing_code' then
    return format('CarmaCars: your signing code is %s. It is valid %s minutes. Never share it.', o.payload ->> 'code', coalesce(nullif(o.payload ->> 'minutes', ''), '10'));
  end if;
  -- the text template (none for an email kept out of ordinary texts: then the generic text with its subject and page)
  v_t := app.sms_text_for(o.code, o.payload, o.audience, o.booking_id);
  v_body := coalesce(v_t ->> 'body', app.sms_render((app.settings()).sms_generic_text, coalesce(o.payload, '{}'::jsonb)
                       || jsonb_build_object('subject', rtrim(app.render_text(c.subject, coalesce(o.payload, '{}'::jsonb)), '.'),
                                             'link', coalesce(app.notification_url(c, coalesce(o.payload, '{}'::jsonb)), rtrim((app.settings()).notify_base_url, '/') || '/account'))));
  if o.audience = 'renter' and o.category = 'transactional' then
    v_body := regexp_replace(v_body, '(/account/bookings/[A-Za-z0-9-]+(/[a-z-]+)?)(?=\s|$)', '\1?m=' || o.id::text, 'g');
  end if;
  return v_body;
end $$;

-- text a held email: automatically (p_by null: the switch on, held for the limit, a critical code) or by an Admin
create or replace function app.outbox_text(p_id uuid, p_by uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o notification_outbox;
  ss site_settings;
  v_to text;
  v_body text;
  p phone_outbox;
begin
  select * into o from notification_outbox where id = p_id for update;
  if o.id is null then raise exception 'Email not found' using errcode = 'P0002'; end if;
  if o.limit_text_id is not null then
    if p_by is not null then raise exception 'Already texted %', to_char(o.limit_texted_at at time zone 'America/Toronto', 'Mon FMDD at HH24:MI') using errcode = '23505'; end if;
    return jsonb_build_object('ok', false, 'reason', 'already texted');
  end if;
  select * into ss from site_settings where singleton;
  if p_by is null then
    if not coalesce(ss.email_limit_texts, true) then return jsonb_build_object('ok', false, 'reason', 'off'); end if;
    if o.status <> 'delayed' or not (o.status_reason = any (app.email_limit_reasons())) then return jsonb_build_object('ok', false, 'reason', 'not held for the limit'); end if;
    if not (o.code = any (coalesce(ss.email_limit_text_codes, '{}'))) then return jsonb_build_object('ok', false, 'reason', 'not a booking or pickup message'); end if;
  else
    if not app.user_is_admin(p_by) then raise exception 'Admins only' using errcode = '42501'; end if;
    if o.status not in ('queued', 'delayed') then raise exception 'Only an email waiting to go can be texted instead' using errcode = '22023'; end if;
  end if;
  if not (app.settings()).phone_enabled then
    if p_by is not null then raise exception 'Phone and texts are off in Program settings' using errcode = '22023'; end if;
    return jsonb_build_object('ok', false, 'reason', 'phone off');
  end if;
  v_to := app.outbox_text_number(o);
  if v_to is null then
    if p_by is not null then raise exception 'No mobile number that takes texts is on file for this person' using errcode = '22023'; end if;
    return jsonb_build_object('ok', false, 'reason', 'no mobile');
  end if;
  v_body := app.outbox_text_body(o);
  if v_body is null then
    if p_by is not null then raise exception 'This email has no text' using errcode = '22023'; end if;
    return jsonb_build_object('ok', false, 'reason', 'no text');
  end if;
  if (app.settings()).sms_stop_line and app.sms_first_to(v_to) then v_body := v_body || ' Reply STOP to opt out.'; end if;
  p := app.phone_outbox_put(v_to, v_body, 'booking', o.booking_id, o.renter_id, o.code, o.id, 'email-limit:' || o.id::text, now());
  update phone_outbox set urgent = true, user_id = coalesce(user_id, o.recipient_user_id) where id = p.id;
  update notification_outbox set limit_text_id = p.id, limit_texted_at = now() where id = o.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'email_texted_instead', 'notification_outbox', o.id::text,
          jsonb_build_object('code', o.code, 'phone_outbox_id', p.id, 'status', p.status, 'reason', p.status_reason, 'by', case when p_by is null then 'email limit' else 'admin' end));
  return jsonb_build_object('ok', p.status <> 'skipped', 'phone_outbox_id', p.id, 'status', p.status, 'reason', p.status_reason);
end $$;

-- held for the limit: the text goes at once
create or replace function app.outbox_limit_text_trg() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.outbox_text(new.id, null);
  return null;
end $$;
create trigger notification_outbox_limit_text after update of status, status_reason on notification_outbox for each row
  when (new.status = 'delayed' and new.limit_text_id is null and new.status_reason in ('daily email limit', 'monthly email limit', 'the email provider''s daily limit', 'the email provider''s monthly limit'))
  execute function app.outbox_limit_text_trg();

-- 2. sign-in and the signing code while email is capped
create or replace function public.server_email_capped() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('capped', app.email_capped(now()),
    'phone_signin', coalesce((app.settings()).signin_phone_enabled, false) and coalesce((app.settings()).phone_enabled, false))
$$;
revoke all on function public.server_email_capped() from public, anon, authenticated;
grant execute on function public.server_email_capped() to service_role;

alter function app.esign_view(uuid) rename to esign_view_pre0212;
create function app.esign_view(p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.esign_view_pre0212(p_session);
  v_held boolean := app.email_capped(now());
begin
  if v is null then return v; end if;
  return v || jsonb_build_object('email_held', v_held,
    'default_channel', case when exists (select 1 from jsonb_array_elements(coalesce(v -> 'channels', '[]'::jsonb)) c where c ->> 'channel' = 'sms') then 'sms'
                            when jsonb_array_length(coalesce(v -> 'channels', '[]'::jsonb)) > 0 then 'email' end);
end $$;
select pg_temp.copy_grants('app.esign_view(uuid)'::regprocedure, 'app.esign_view_pre0212(uuid)'::regprocedure);

-- 3. Admin > Email: Text it instead
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0212;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_do' and p_name = 'outbox_text' then
    perform app.door_begin(p_user, p_aal);
    return app.outbox_text((p ->> 'id')::uuid, p_user);
  end if;
  return app.door_pre0212(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0212(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('email_capped', 'outbox_text_number', 'outbox_text_body', 'outbox_text', 'outbox_limit_text_trg', 'door_pre0212', 'esign_view_pre0212') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- the emails held for the limit right now (the live problem of October 30): their texts go at once
select app.outbox_text(o.id, null) from notification_outbox o
 where o.status = 'delayed' and o.limit_text_id is null and o.status_reason = any (app.email_limit_reasons()) and o.send_after > now();
