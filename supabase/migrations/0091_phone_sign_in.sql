-- 0091_phone_sign_in.sql
-- Signing in with a phone number and a one-time code (docs/changes/2026-10-21-phone-sign-in.md). Builds on 0085 (Quo).
--
--   1. Supabase Auth's phone provider sends a 6-digit code (5 minutes) through its Send SMS hook to the site
--      (web/src/app/api/webhooks/auth-sms), which texts it from the CarmaCars Quo number. This database decides who may get
--      a code (a Canadian number; US numbers only when an Admin allows them, because texting US numbers needs A2P 10DLC
--      registration in Quo), counts the requests per number and per IP, and keeps a log of the codes sent (never the
--      code itself) for 30 days.
--   2. users.email may be empty for an account made by phone; users.phone_verified_at says the sign-in service verified
--      users.phone (E.164). An account needs an email or a phone. users.preferred_sign_in: phone or email.
--   3. Linking, only after the code is verified (app.account_phone_verified): the number is attached to the signed-in
--      account; a renter record with that number and no confirmed sign-in of its own (or an owner record with no account)
--      becomes this account's, with its requests and bookings; an additional driver's place with that number is attached; a record
--      that belongs to another confirmed account, or a second record when this account already has one, becomes a
--      staff task (never shown to the person, so nobody learns whether a number has an account). Leads with the number
--      are listed for staff.
--   4. Confirmation (configurable, as 0090 "unverified accounts" will use it): accepting an offer, signing and paying
--      need a confirmed account, where a verified phone counts like a confirmed email (signin_confirm_by_phone). The
--      first payment also needs an email address for the receipts (asked inline on the pay page).
--   5. Program settings "Sign-in by phone", all on by default except US numbers.
--   6. The privacy policy: one line in section 10.
-- No earlier migration is edited.
set local check_function_bodies = off;

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists signin_phone_enabled boolean not null default true,
  add column if not exists signin_phone_us_allowed boolean not null default false,
  add column if not exists signin_phone_hourly_per_number integer not null default 5 check (signin_phone_hourly_per_number between 1 and 50),
  add column if not exists signin_phone_hourly_per_ip integer not null default 20 check (signin_phone_hourly_per_ip between 1 and 500),
  add column if not exists signin_confirm_required boolean not null default true,
  add column if not exists signin_confirm_by_phone boolean not null default true;
comment on column program_settings.signin_phone_enabled is 'Sign-in by phone: people may sign in, sign up and verify a phone with a code texted from the CarmaCars number.';
comment on column program_settings.signin_phone_us_allowed is 'Sign-in by phone: also US numbers. Off until the Quo number is registered for A2P 10DLC (texts to US numbers are blocked without it). Canadian numbers always.';
comment on column program_settings.signin_phone_hourly_per_number is 'Sign-in by phone: codes a number may ask for in an hour (Supabase also waits 60 seconds between two codes).';
comment on column program_settings.signin_phone_hourly_per_ip is 'Sign-in by phone: codes one IP address may ask for in an hour.';
comment on column program_settings.signin_confirm_required is 'Accepting an offer, signing and paying need a confirmed account (a confirmed email, or a verified phone when signin_confirm_by_phone).';
comment on column program_settings.signin_confirm_by_phone is 'A phone verified with a code counts as confirmation of the account, like a confirmed email.';

-- ================================================================ 2. accounts
alter table users alter column email drop not null;
alter table users
  add column if not exists phone_verified_at timestamptz,
  add column if not exists preferred_sign_in text not null default 'email' check (preferred_sign_in in ('email', 'phone'));
alter table users drop constraint if exists users_email_or_phone;
alter table users add constraint users_email_or_phone check (email is not null or phone is not null);
comment on column users.email is 'The sign-in email. Empty only for an account made by phone (phone_verified_at set) that has not given one yet; asked before the first payment.';
comment on column users.phone_verified_at is 'Since 0091: when the sign-in service verified users.phone (E.164) with a texted code. Earlier records with the number are attached only after it.';
comment on column users.preferred_sign_in is 'Since 0091: the sign-in the person chose (phone or email); the sign-in page opens on it on their devices.';
create unique index if not exists users_verified_phone_key on users (phone) where phone_verified_at is not null;

alter table account_links drop constraint if exists account_links_kind_check;
alter table account_links add constraint account_links_kind_check
  check (kind in ('renter_record', 'booking', 'driver', 'needs_staff', 'owner_record', 'lead'));

-- The codes texted (never the code): for the per-number limit, for staff questions ("I never got a code") and the
-- site check. In the app schema: outside the API and the audit log (a log of its own). Kept 30 days.
create table if not exists app.auth_sms_log (
  id          uuid primary key default gen_random_uuid(),
  phone       text not null,
  user_id     uuid,
  status      text not null default 'sending' check (status in ('sending', 'sent', 'failed', 'refused')),
  reason      text,
  quo_message_id text,
  created_at  timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists auth_sms_log_phone_idx on app.auth_sms_log (phone, created_at desc);
create index if not exists auth_sms_log_at_idx on app.auth_sms_log (created_at);
revoke all on app.auth_sms_log from public, anon, authenticated;
comment on table app.auth_sms_log is 'Sign-in codes texted from the CarmaCars number (0091): the number, the account, sent or why not. Never the code. Kept 30 days.';

-- Each code our site asked Supabase Auth for (the server action, after its checks). The hook texts a code only for a
-- number with a request of the last 3 minutes, so a code asked for around the site (straight from Supabase's API with
-- the public key) is never texted, and a phone change texts the new number, never an old one.
create table if not exists app.auth_sms_intent (
  id          bigserial primary key,
  phone       text not null,
  purpose     text not null check (purpose in ('sign_in', 'phone_change')),
  user_id     uuid,
  created_at  timestamptz not null default now(),
  used_at     timestamptz
);
create index if not exists auth_sms_intent_phone_idx on app.auth_sms_intent (phone, created_at desc);
revoke all on app.auth_sms_intent from public, anon, authenticated;

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('account_phone_review', 'cs', 'A verified phone matches another record', 'normal', 'business_days', 1, 1, 'records_merged',
   'Someone verified a phone number with a code, and a renter or owner record with that number belongs to another account (or this account already has one): check they are the same person and move the records by hand. Never tell the caller whether the number had an account.')
on conflict (task_type) do nothing;

-- ================================================================ 3. numbers
-- Canadian geographic area codes (CNA, 2026). Texts to them need no A2P registration in Quo.
create or replace function app.phone_ca_area_codes() returns text[]
language sql immutable as $$
  select array['204','226','236','249','250','257','263','289','306','343','354','365','367','368','382','387','403','416','418','428',
               '431','437','438','450','460','468','474','506','514','519','548','579','581','584','587','604','613','639','647','672',
               '683','705','709','742','753','778','780','782','807','819','825','867','873','879','902','905','942']
$$;

-- +1 area codes that are not the United States or Canada (the Caribbean and Atlantic countries of the NANP), toll-free
-- and special numbers: never a US mobile.
create or replace function app.phone_nanp_not_us() returns text[]
language sql immutable as $$
  select array['242','246','264','268','284','345','441','473','649','658','664','721','758','767','784','809','829','849','868','869','876',
               '500','521','522','523','524','525','526','527','528','529','533','544','566','577','588','600','622','633','644','655','677','688',
               '700','710','800','822','833','844','855','866','877','880','881','882','883','884','885','886','887','888','889','900']
$$;

-- Which country a +1 number is in for sign-in: CA, US, or other (null when it is not a number).
create or replace function app.phone_country(p text) returns text
language sql immutable as $$
  select case
    when n is null then null
    when n !~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$' then 'other'
    when substr(n, 3, 3) = any (app.phone_ca_area_codes()) then 'CA'
    when substr(n, 3, 3) = any (app.phone_nanp_not_us()) or substr(n, 4, 2) = '11' then 'other'
    else 'US' end
  from (select app.phone_e164(p) as n) x
$$;

-- May this number get a sign-in code? {ok, phone (E.164), country, reason: invalid | country | off}
create or replace function app.signin_phone_check(p text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  n text := app.phone_e164(p);
  c text := app.phone_country(p);
begin
  if not s.signin_phone_enabled then return jsonb_build_object('ok', false, 'reason', 'off', 'phone', n, 'country', c); end if;
  if n is null then return jsonb_build_object('ok', false, 'reason', 'invalid', 'phone', null, 'country', null); end if;
  if c = 'CA' or (c = 'US' and s.signin_phone_us_allowed) then return jsonb_build_object('ok', true, 'phone', n, 'country', c); end if;
  return jsonb_build_object('ok', false, 'reason', 'country', 'phone', n, 'country', c);
end $$;

-- What the sign-in pages need to say (public: no personal data).
create or replace function app.signin_phone_rules() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('enabled', s.signin_phone_enabled, 'us_allowed', s.signin_phone_us_allowed, 'code_length', 6, 'code_minutes', 5)
    from (select (app.settings()).*) s
$$;

-- ================================================================ 4. asking for a code (the site's server action) and texting it (the hook)
-- The server action, before it asks Supabase Auth for a code: the number allowed, and the per-IP and per-number limits.
create or replace function app.signin_phone_request(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  c jsonb := app.signin_phone_check(p ->> 'phone');
  v_ip text := nullif(btrim(coalesce(p ->> 'ip', '')), '');
  v_kind text := coalesce(nullif(p ->> 'kind', ''), 'code');
begin
  if not (c ->> 'ok')::boolean then return c; end if;
  if v_kind not in ('code', 'verify') then raise exception 'Unknown kind %', v_kind using errcode = '22023'; end if;
  -- checking a code: 10 tries per number and 3 times the code limit per IP in an hour (Supabase also limits them)
  if v_ip is not null and not app.rate_limit(format('signin-%s-ip:%s', v_kind, v_ip),
        case when v_kind = 'verify' then s.signin_phone_hourly_per_ip * 3 else s.signin_phone_hourly_per_ip end, interval '1 hour') then
    return c || jsonb_build_object('ok', false, 'reason', 'rate_limited');
  end if;
  if not app.rate_limit(format('signin-%s-num:%s', v_kind, c ->> 'phone'),
        case when v_kind = 'verify' then 10 else s.signin_phone_hourly_per_number end, interval '1 hour') then
    return c || jsonb_build_object('ok', false, 'reason', 'rate_limited');
  end if;
  if v_kind = 'code' then
    delete from auth_sms_intent where created_at < now() - interval '1 day';
    insert into auth_sms_intent (phone, purpose, user_id)
    values (c ->> 'phone', case when p ->> 'purpose' = 'phone_change' then 'phone_change' else 'sign_in' end, nullif(p ->> 'user_id', '')::uuid);
  end if;
  return c;
end $$;

-- The Send SMS hook, after its signature is checked: may this code be texted? A log row (status sending) and the text.
create or replace function app.server_auth_sms(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  c jsonb;
  v_id uuid;
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
  v_from text := app.phone_our_number();
  v_intent bigint;
  v_cand text;
begin
  delete from auth_sms_log where created_at < now() - interval '30 days';
  -- the number our site asked a code for (p phones: the hook's candidates, most likely first; p phone: one number)
  for v_cand in select app.phone_e164(x) from jsonb_array_elements_text(coalesce(p -> 'phones', jsonb_build_array(p ->> 'phone'))) x loop
    select i.id into v_intent from auth_sms_intent i
     where i.phone = v_cand and i.used_at is null and i.created_at > now() - interval '3 minutes'
     order by i.created_at desc limit 1;
    if v_intent is not null then
      update auth_sms_intent set used_at = now() where id = v_intent;
      c := app.signin_phone_check(v_cand);
      exit;
    end if;
  end loop;
  if v_intent is null then
    insert into auth_sms_log (phone, user_id, status, reason, finished_at)
    values (coalesce(app.phone_e164(coalesce(p -> 'phones' ->> 0, p ->> 'phone')), left(coalesce(p -> 'phones' ->> 0, p ->> 'phone', ''), 20)), v_user, 'refused', 'no_request', now());
    return jsonb_build_object('ok', false, 'reason', 'no_request');
  end if;
  if not (c ->> 'ok')::boolean then
    insert into auth_sms_log (phone, user_id, status, reason, finished_at) values (coalesce(c ->> 'phone', left(coalesce(p ->> 'phone', ''), 20)), v_user, 'refused', c ->> 'reason', now());
    return c;
  end if;
  -- the backstop limit (the server action counts first): twice the per-number limit an hour
  if (select count(*) from auth_sms_log l where l.phone = c ->> 'phone' and l.created_at > now() - interval '1 hour' and l.status in ('sending', 'sent'))
       >= s.signin_phone_hourly_per_number * 2 then
    insert into auth_sms_log (phone, user_id, status, reason, finished_at) values (c ->> 'phone', v_user, 'refused', 'rate_limited', now());
    return c || jsonb_build_object('ok', false, 'reason', 'rate_limited');
  end if;
  if v_from is null then
    insert into auth_sms_log (phone, user_id, status, reason, finished_at) values (c ->> 'phone', v_user, 'failed', 'no_from_number', now());
    return c || jsonb_build_object('ok', false, 'reason', 'no_from_number');
  end if;
  insert into auth_sms_log (phone, user_id) values (c ->> 'phone', v_user) returning id into v_id;
  return c || jsonb_build_object('log_id', v_id, 'from', v_from);
end $$;

create or replace function app.server_auth_sms_result(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  update auth_sms_log set status = case when (p ->> 'ok')::boolean then 'sent' else 'failed' end,
         reason = left(nullif(p ->> 'error', ''), 300), quo_message_id = left(nullif(p ->> 'quo_id', ''), 100), finished_at = now()
   where id = (p ->> 'log_id')::uuid and status = 'sending';
  return jsonb_build_object('ok', found);
end $$;

-- ================================================================ 5. linking, after a code is verified
-- Does this account have a confirmed sign-in of its own? (a confirmed email, a verified phone, or staff, owner or
-- investor access). A record whose account has none may be claimed by a verified phone.
create or replace function app.account_has_confirmed_sign_in(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from users u where u.id = p_user and (u.email_verified_at is not null or u.phone_verified_at is not null or u.last_sign_in_at is not null))
      or exists (select 1 from user_roles r where r.user_id = p_user and r.role in ('admin', 'va', 'field'))
      or exists (select 1 from investors i where i.user_id = p_user)
$$;

create or replace function app.account_phone_verified(p_user uuid, p_phone text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  n text := app.phone_e164(p_phone);
  u users;
  r renters;
  x renters;
  o owners;
  d record;
  bk record;
  l record;
  v_renter_records integer := 0;
  v_owner_records integer := 0;
  v_bookings integer := 0;
  v_drivers integer := 0;
  v_staff integer := 0;
  v_leads integer := 0;
  v_first_name text;
begin
  if n is null then raise exception 'Not a phone number' using errcode = '22023'; end if;
  select * into u from users where id = p_user for update;
  if u.id is null then raise exception 'Account not found' using errcode = 'P0002'; end if;
  -- the sign-in service just verified this number for this account: no other account keeps it as verified
  update users set phone_verified_at = null where phone = n and id <> u.id and phone_verified_at is not null;
  update users set phone = n, phone_verified_at = coalesce(case when phone = n then phone_verified_at end, now()) where id = u.id returning * into u;

  select * into r from renters where user_id = u.id;
  -- renter records with this number (the record's mobile or its account holder's), newest first
  for x in select rn.* from renters rn
            where (app.phone_e164(rn.mobile) = n
                   or exists (select 1 from drivers dd where dd.renter_id = rn.id and dd.is_account_holder and app.phone_e164(dd.mobile) = n))
              and rn.user_id is distinct from u.id
            order by rn.created_at desc loop
    if r.id is null and (x.user_id is null or not app.account_has_confirmed_sign_in(x.user_id)) then
      update renters set user_id = u.id where id = x.id returning * into r;
      insert into user_roles (user_id, role) values (u.id, 'renter') on conflict do nothing;
      update drivers set user_id = u.id where renter_id = x.id and is_account_holder and (user_id is null or user_id = x.user_id);
      insert into account_links (user_id, kind, entity_id, detail) values (u.id, 'renter_record', x.id, x.legal_name) on conflict do nothing;
      if coalesce(u.full_name, '') = '' then update users set full_name = x.legal_name where id = u.id returning * into u; end if;
      v_renter_records := v_renter_records + 1;
    else
      insert into account_links (user_id, kind, entity_id, detail) values (u.id, 'needs_staff', x.id, x.legal_name) on conflict do nothing;
      if found then
        perform app.raise_task(p_type => 'account_phone_review', p_title => format('A verified phone matches renter %s', x.legal_name),
            p_detail => format('The account %s verified %s with a code. The renter record %s (%s) has the same number and %s. Check they are the same person and move the bookings by hand.',
                               coalesce(nullif(u.full_name, ''), u.email, n), n, x.legal_name, x.id,
                               case when r.id is not null and r.id <> x.id then 'this account already has its own renter record' else 'belongs to another account' end),
            p_renter => x.id, p_related_table => 'renters', p_related_id => x.id, p_dedupe => format('account_phone_review:%s:%s', u.id, x.id));
        v_staff := v_staff + 1;
      end if;
    end if;
  end loop;
  -- the requests and bookings of this account's renter record
  if r.id is not null then
    for bk in select b.id, b.booking_number from bookings b where b.renter_id = r.id and b.created_at <= now() loop
      insert into account_links (user_id, kind, entity_id, detail) values (u.id, 'booking', bk.id, bk.booking_number) on conflict do nothing;
      if found then v_bookings := v_bookings + 1; end if;
    end loop;
  end if;
  -- an owner record with this number and no confirmed sign-in of its own (an owner lead, a record staff made)
  for o in select ow.* from owners ow
            where app.phone_e164(ow.phone) = n and ow.user_id is distinct from u.id
            order by ow.created_at desc loop
    -- only a record with no account at all (an owner lead, a record staff made): an owner account is never taken over
    if not exists (select 1 from owners z where z.user_id = u.id) and o.user_id is null then
      update owners set user_id = u.id where id = o.id;
      insert into user_roles (user_id, role) values (u.id, 'owner') on conflict do nothing;
      insert into account_links (user_id, kind, entity_id, detail) values (u.id, 'owner_record', o.id, coalesce(o.corporation_name, o.legal_name)) on conflict do nothing;
      if coalesce(u.full_name, '') = '' then update users set full_name = o.legal_name where id = u.id returning * into u; end if;
      v_owner_records := v_owner_records + 1;
    else
      insert into account_links (user_id, kind, entity_id, detail) values (u.id, 'needs_staff', o.id, coalesce(o.corporation_name, o.legal_name)) on conflict do nothing;
      if found then
        perform app.raise_task(p_type => 'account_phone_review', p_title => format('A verified phone matches owner %s', coalesce(o.corporation_name, o.legal_name)),
            p_detail => format('The account %s verified %s with a code. The owner record %s (%s) has the same number and belongs to another account, or this account is already an owner. Check before moving anything.',
                               coalesce(nullif(u.full_name, ''), u.email, n), n, coalesce(o.corporation_name, o.legal_name), o.id),
            p_owner => o.id, p_related_table => 'owners', p_related_id => o.id, p_dedupe => format('account_phone_review:%s:%s', u.id, o.id));
        v_staff := v_staff + 1;
      end if;
    end if;
  end loop;
  -- an additional driver's place on someone else's booking
  for d in select dr.id, dr.full_name from drivers dr
            where dr.user_id is null and not dr.is_account_holder and app.phone_e164(dr.mobile) = n loop
    update drivers set user_id = u.id where id = d.id;
    update rental_agreement_signers set user_id = u.id where driver_id = d.id and user_id is null and signer_role = 'additional_driver';
    insert into account_links (user_id, kind, entity_id, detail) values (u.id, 'driver', d.id, d.full_name) on conflict do nothing;
    v_drivers := v_drivers + 1;
  end loop;
  -- leads with the number (the contact form, a discount game, live chat, a call): listed for staff
  for l in select le.id, le.name from leads le where app.phone_e164(le.phone) = n order by le.created_at desc limit 20 loop
    insert into account_links (user_id, kind, entity_id, detail) values (u.id, 'lead', l.id, l.name) on conflict do nothing;
    if found then v_leads := v_leads + 1; end if;
    if coalesce(u.full_name, '') = '' and nullif(btrim(coalesce(l.name, '')), '') is not null then
      update users set full_name = btrim(l.name) where id = u.id returning * into u;
    end if;
  end loop;
  -- the phone line's thread of this number now shows the account's renter record
  if to_regclass('public.phone_threads') is not null then
    update phone_threads t set renter_id = coalesce(t.renter_id, r.id), match_kind = case when t.match_kind in ('unknown', 'lead') and r.id is not null then 'renter' else t.match_kind end
     where t.number = n and not t.manual and r.id is not null;
  end if;
  v_first_name := split_part(btrim(coalesce(u.full_name, '')), ' ', 1);
  return jsonb_build_object('user_id', u.id, 'phone', n, 'renter_records', v_renter_records, 'owner_records', v_owner_records, 'bookings', v_bookings,
                            'drivers', v_drivers, 'leads', v_leads, 'needs_staff', v_staff, 'needs_name', coalesce(btrim(u.full_name), '') = '',
                            'first_name', nullif(v_first_name, ''));
end $$;

-- A phone sign-in (or a phone added to an account): the account's users row, made when it is new (no email; the name
-- given, or from the record the number belongs to), then the linking above. p_phone is the number the sign-in service
-- verified, never what was typed.
create or replace function app.phone_signed_in(p_user uuid, p_phone text, p_name text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  n text := app.phone_e164(p_phone);
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  u users;
  v_created boolean := false;
  v_out jsonb;
begin
  if p_user is null then raise exception 'The sign-in account id is needed' using errcode = '22023'; end if;
  if n is null then raise exception 'Not a phone number' using errcode = '22023'; end if;
  if v_name is not null and length(v_name) > 120 then raise exception 'Your full name is at most 120 characters' using errcode = '22023'; end if;
  select * into u from users where id = p_user;
  if u.id is null then
    update users set phone_verified_at = null where phone = n and phone_verified_at is not null;
    insert into users (id, email, phone, phone_verified_at, full_name, status, preferred_sign_in)
    values (p_user, null, n, now(), coalesce(v_name, ''), 'active', 'phone');
    insert into user_roles (user_id, role) values (p_user, 'renter') on conflict do nothing;
    v_created := true;
  elsif v_name is not null and coalesce(btrim(u.full_name), '') = '' then
    update users set full_name = v_name where id = u.id;
  end if;
  update users set last_sign_in_at = now() where id = p_user;
  v_out := app.account_phone_verified(p_user, n);
  return v_out || jsonb_build_object('ok', true, 'created', v_created);
end $$;

-- The name of an account made by phone (asked right after the code when no record gave one).
create or replace function app.account_set_name(p_user uuid, p_name text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
begin
  if v_name is null or length(v_name) < 2 or length(v_name) > 120 then raise exception 'Enter your full name (2 to 120 characters)' using errcode = '22023'; end if;
  update users set full_name = v_name where id = p_user and coalesce(btrim(full_name), '') = '';
  return jsonb_build_object('ok', true, 'changed', found);
end $$;

-- ================================================================ 6. confirmation, receipts email, the chosen sign-in
create or replace function app.account_confirmed(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from users u where u.id = p_user
                   and (u.email_verified_at is not null or ((app.settings()).signin_confirm_by_phone and u.phone_verified_at is not null)))
$$;

-- Before accepting an offer, signing or paying: {ok, reason: unconfirmed | email_needed, email, phone}.
create or replace function app.account_gate(p_user uuid, p_step text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  u users;
  s program_settings := app.settings();
begin
  if p_step not in ('accept', 'sign', 'pay') then raise exception 'Unknown step %', p_step using errcode = '22023'; end if;
  select * into u from users where id = p_user;
  if u.id is null then return jsonb_build_object('ok', false, 'reason', 'unconfirmed'); end if;
  if s.signin_confirm_required and not app.account_confirmed(u.id) then
    return jsonb_build_object('ok', false, 'reason', 'unconfirmed', 'email', u.email, 'phone', u.phone, 'by_phone', s.signin_confirm_by_phone);
  end if;
  if p_step = 'pay' and nullif(btrim(coalesce(u.email, '')), '') is null then
    return jsonb_build_object('ok', false, 'reason', 'email_needed', 'phone', u.phone);
  end if;
  return jsonb_build_object('ok', true, 'email', u.email, 'phone', u.phone);
end $$;

-- An account made by phone gives an email for its receipts (the pay page asks before the first payment). The address
-- is the account's email from now on; the sign-in service sends a link to confirm it.
create or replace function app.account_set_email(p_user uuid, p_email text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v text := lower(btrim(coalesce(p_email, '')));
  u users;
begin
  if v !~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' or length(v) > 200 then
    raise exception 'Enter an email address like name@example.com' using errcode = '22023';
  end if;
  select * into u from users where id = p_user for update;
  if u.id is null then raise exception 'Account not found' using errcode = 'P0002'; end if;
  if lower(coalesce(u.email, '')) = v then return jsonb_build_object('ok', true, 'changed', false); end if;
  if u.email is not null and u.email_verified_at is not null then
    raise exception 'Your account already has a confirmed email. To change it, call or message us.' using errcode = '42501';
  end if;
  if exists (select 1 from users z where lower(z.email) = v and z.id <> u.id) then
    return jsonb_build_object('ok', false, 'error', 'email_taken',
      'message', 'This email is already used by another account. Sign in with it instead, or use another email.');
  end if;
  update users set email = v, email_verified_at = null where id = u.id;
  update renters set email = v where user_id = u.id;
  update drivers set email = v where user_id = u.id and is_account_holder;
  return jsonb_build_object('ok', true, 'changed', true);
end $$;

create or replace function app.account_set_sign_in(p_user uuid, p_method text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  u users;
begin
  if p_method not in ('email', 'phone') then raise exception 'Choose phone or email' using errcode = '22023'; end if;
  select * into u from users where id = p_user;
  if u.id is null then raise exception 'Account not found' using errcode = 'P0002'; end if;
  if p_method = 'phone' and u.phone_verified_at is null then raise exception 'Add and verify your phone number first' using errcode = '23514'; end if;
  if p_method = 'email' and u.email is null then raise exception 'Add an email address first' using errcode = '23514'; end if;
  update users set preferred_sign_in = p_method where id = u.id;
  return jsonb_build_object('ok', true, 'preferred', p_method);
end $$;

-- The profile pages: the account's sign-in details.
create or replace function app.my_sign_in(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('email', u.email, 'email_verified', u.email_verified_at is not null,
           'phone', case when u.phone_verified_at is not null then u.phone end, 'phone_verified', u.phone_verified_at is not null,
           'phone_on_file', app.phone_e164(coalesce(u.phone, (select r.mobile from renters r where r.user_id = u.id limit 1), (select o.phone from owners o where o.user_id = u.id limit 1))),
           'preferred', u.preferred_sign_in, 'confirmed', app.account_confirmed(u.id), 'name', u.full_name)
         || app.signin_phone_rules()
    from users u where u.id = p_user
$$;

-- ================================================================ 7. privacy policy (the live legal.privacy block, where it still has our text)
update site_content_blocks
   set body = replace(body, 'Calls and texts are kept with your rental records if you are a customer, and otherwise for 12 months.',
     'Calls and texts are kept with your rental records if you are a customer, and otherwise for 12 months.

If you sign in or verify your phone number with us, we text a one-time sign-in code to the phone number you give.')
 where block_key = 'legal.privacy' and body like '%Calls and texts are kept with your rental records if you are a customer, and otherwise for 12 months.%'
   and body not like '%we text a one-time sign-in code to the phone number you give%';

-- ================================================================ 8. the doors and privileges
create or replace function public.server_signin_phone_request(p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.signin_phone_request(p) $$;
create or replace function public.server_auth_sms(p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.server_auth_sms(p) $$;
create or replace function public.server_auth_sms_result(p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.server_auth_sms_result(p) $$;
create or replace function public.server_phone_signed_in(p_user uuid, p_phone text, p_name text default null) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.phone_signed_in(p_user, p_phone, p_name) $$;
create or replace function public.server_account_set_name(p_user uuid, p_name text) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.account_set_name(p_user, p_name) $$;
create or replace function public.server_account_gate(p_user uuid, p_step text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.account_gate(p_user, p_step) $$;
create or replace function public.server_account_set_email(p_user uuid, p_email text) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.account_set_email(p_user, p_email) $$;
create or replace function public.server_account_set_sign_in(p_user uuid, p_method text) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.account_set_sign_in(p_user, p_method) $$;
create or replace function public.server_my_sign_in(p_user uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.my_sign_in(p_user) $$;
create or replace function public.signin_phone_rules() returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.signin_phone_rules() $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['phone_ca_area_codes', 'phone_nanp_not_us', 'phone_country', 'signin_phone_check', 'signin_phone_rules',
              'signin_phone_request', 'server_auth_sms', 'server_auth_sms_result', 'account_has_confirmed_sign_in', 'account_phone_verified', 'phone_signed_in',
              'account_set_name', 'account_confirmed', 'account_gate', 'account_set_email', 'account_set_sign_in', 'my_sign_in']))
        or (n.nspname = 'public' and p.proname = any (array['server_signin_phone_request', 'server_auth_sms', 'server_auth_sms_result', 'server_phone_signed_in',
              'server_account_set_name', 'server_account_gate', 'server_account_set_email', 'server_account_set_sign_in', 'server_my_sign_in']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- the rules carry no personal data: the sign-in pages read them as anyone
revoke all on function public.signin_phone_rules() from public;
grant execute on function public.signin_phone_rules() to anon, authenticated, service_role;
grant execute on function app.signin_phone_rules() to anon, authenticated;

