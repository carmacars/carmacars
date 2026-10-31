-- 0280_phone_gate.sql
-- The phone number box for renters (docs/changes/2026-11-04-phone-gate.md). The owner's request of October 31, 2026, made
-- light so it does not cost bookings: a visitor who has not given a mobile number on this device is asked for one before
-- seeing more than the first photos of a car, and before the full availability (the open calendar with its booked days
-- on a car page, and the cars booked for the chosen dates on the fleet page). Picking dates and seeing whether that car is
-- free for them is never gated, nor is anything a search engine reads (the gate is in the browser, on taps only).
--
--   1. Program settings (Admin, Settings, Phone number box), each on or off: before more photos (on, after the first 6:
--      phone_gate_free_photos), before the full availability (on), before a booking request (off: the request form asks
--      for the phone itself), check the number with a texted code (off: a valid Canadian or US mobile number is enough),
--      and, with the code on, "Use without verifying" (off). Texts cost money: a number gets at most 3 codes a day, a
--      network address 10, the whole site 200 (each a setting).
--   2. A number given: a contact_captures row (form phone_gate, done at once so it raises no follow-up To do) and its
--      lead (source unfinished_form, so Renter leads, Live visitors and every place that lists leads from unfinished forms
--      show it), and phone_gate_contacts: the number as a transactional contact (consent source "phone gate": the texts
--      about availability and bookings the person asked for) and, only when the unticked box "Also text me deals" was
--      ticked, marketing consent with the words shown and the time (CASL). The network address is never kept.
--   3. Codes (with the code setting on): 6 digits, only their hash kept, 10 minutes, 5 tries, texted from the CarmaCars
--      number and logged in app.auth_sms_log (purpose phone_gate) like the sign-in codes.
--   4. Measuring it (phone_gate_daily, no personal data): per day and box, how often it was shown, a number given,
--      closed without one, codes texted; and the web booking requests of the day, those from visitors who saw the box.
--      Admin, Settings, Phone number box shows it with the requests a day before the box was first shown and since.
--   5. site_facts carries the settings for the pages (no new database call for a page view).
-- No applied migration is edited.

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists phone_gate_gallery boolean not null default true,
  add column if not exists phone_gate_free_photos integer not null default 6 check (phone_gate_free_photos between 1 and 30),
  add column if not exists phone_gate_dates boolean not null default true,
  add column if not exists phone_gate_request boolean not null default false,
  add column if not exists phone_gate_verify boolean not null default false,
  add column if not exists phone_gate_allow_unverified boolean not null default false,
  add column if not exists phone_gate_texts_per_number_day integer not null default 3 check (phone_gate_texts_per_number_day between 1 and 20),
  add column if not exists phone_gate_texts_per_ip_day integer not null default 10 check (phone_gate_texts_per_ip_day between 1 and 200),
  add column if not exists phone_gate_texts_per_day integer not null default 200 check (phone_gate_texts_per_day between 1 and 5000);
comment on column program_settings.phone_gate_gallery is 'Phone number box (0280): ask a visitor for a mobile number before more than the first photos of a car (never on a car with that many photos or fewer).';
comment on column program_settings.phone_gate_free_photos is 'Phone number box (0280): photos shown before the number is asked.';
comment on column program_settings.phone_gate_dates is 'Phone number box (0280): ask for the number before the full availability (the open calendar with its booked days on a car page, and cars booked for the chosen dates on the fleet page). Picking dates and seeing whether that car is free stays open.';
comment on column program_settings.phone_gate_request is 'Phone number box (0280): ask for the number before a booking request starts (the form then shows the number given instead of asking it).';
comment on column program_settings.phone_gate_verify is 'Phone number box (0280): check the number with a 6-digit code by text (each text costs about one cent). Off: a valid Canadian or US mobile number is enough.';
comment on column program_settings.phone_gate_allow_unverified is 'Phone number box (0280): with the code on, also offer "Use without verifying".';
comment on column program_settings.phone_gate_texts_per_number_day is 'Phone number box (0280): codes one number may get in a day.';
comment on column program_settings.phone_gate_texts_per_ip_day is 'Phone number box (0280): codes one network address may ask for in a day.';
comment on column program_settings.phone_gate_texts_per_day is 'Phone number box (0280): codes the whole site may text in a day (the cost cap).';

-- ================================================================ 2. tables
alter table contact_captures drop constraint if exists contact_captures_form_check;
alter table contact_captures add constraint contact_captures_form_check
  check (form in ('booking_request', 'owner_application', 'contact', 'owner_lead', 'chat', 'game', 'signup', 'phone_gate'));

alter function app.capture_form_label(text) rename to capture_form_label_pre0280;
create or replace function app.capture_form_label(p_form text) returns text
language sql immutable as $$
  select case when p_form = 'phone_gate' then 'phone number box' else app.capture_form_label_pre0280(p_form) end
$$;

-- One number given on one device: the transactional contact and the marketing consent, if any.
create table if not exists phone_gate_contacts (
  id               uuid primary key default gen_random_uuid(),
  visitor_id       uuid not null,
  phone            text not null check (phone ~ '^\+1[2-9][0-9]{9}$'),
  country          text not null check (country in ('CA', 'US')),
  gate             text not null check (gate in ('gallery', 'dates', 'request')),
  page             text check (length(page) <= 300),
  verified_at      timestamptz,
  consent_source   text not null default 'phone_gate' check (consent_source = 'phone_gate'),
  transactional    boolean not null default true,
  marketing_opt_in boolean not null default false,
  marketing_text   text,
  marketing_at     timestamptz,
  user_id          uuid references users (id) on delete set null,
  capture_id       uuid references contact_captures (id) on delete set null,
  lead_id          uuid references leads (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (visitor_id, phone),
  check (not marketing_opt_in or (marketing_text is not null and marketing_at is not null))
);
create index if not exists phone_gate_contacts_phone_idx on phone_gate_contacts (phone);
create index if not exists phone_gate_contacts_at_idx on phone_gate_contacts (created_at desc);
comment on table phone_gate_contacts is 'Phone number box (0280): a mobile number given on a device, a transactional contact (consent source phone gate) and, when the unticked box was ticked, marketing consent with the words shown. Never the network address.';

-- The codes texted by the box: only their hash. Outside the API.
create table if not exists app.phone_gate_codes (
  id          bigserial primary key,
  phone       text not null,
  visitor_id  uuid not null,
  code_hash   text not null,
  attempts    integer not null default 0,
  expires_at  timestamptz not null,
  used_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists phone_gate_codes_phone_idx on app.phone_gate_codes (phone, created_at desc);
revoke all on app.phone_gate_codes from public, anon, authenticated;

-- The visitors who saw the box (for the requests they sent later). No personal data; kept 120 days.
create table if not exists app.phone_gate_seen (
  visitor_id uuid primary key,
  first_at   timestamptz not null default now()
);
revoke all on app.phone_gate_seen from public, anon, authenticated;

-- Per day and box: no personal data. gate 'all' holds the requests of the day.
create table if not exists phone_gate_daily (
  day            date not null,
  gate           text not null check (gate in ('gallery', 'dates', 'request', 'all')),
  shown          integer not null default 0,
  given          integer not null default 0,
  closed         integer not null default 0,
  verified       integer not null default 0,
  texts          integer not null default 0,
  requests       integer not null default 0,
  requests_gated integer not null default 0,
  primary key (day, gate)
);
comment on table phone_gate_daily is 'Phone number box (0280): per day (Toronto) and box, shown, number given, closed without one, codes texted; gate all: web requests and those from visitors who saw a box.';

alter table app.auth_sms_log add column if not exists purpose text not null default 'sign_in' check (purpose in ('sign_in', 'phone_gate'));

alter table phone_gate_contacts enable row level security;
alter table phone_gate_daily enable row level security;
revoke all on phone_gate_contacts, phone_gate_daily from public, anon, authenticated;
grant select, insert, update, delete on phone_gate_contacts, phone_gate_daily to service_role;
grant select on phone_gate_contacts, phone_gate_daily to authenticated;
drop policy if exists admin_all on phone_gate_contacts;
create policy admin_all on phone_gate_contacts for select to authenticated using (app.is_admin());
drop policy if exists staff_read on phone_gate_contacts;
create policy staff_read on phone_gate_contacts for select to authenticated using (app.va_has('cs', 'sales'));
drop policy if exists admin_all on phone_gate_daily;
create policy admin_all on phone_gate_daily for select to authenticated using (app.is_admin());

-- ================================================================ 3. helpers
create or replace function app.phone_gate_rules() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('gallery', s.phone_gate_gallery, 'free_photos', s.phone_gate_free_photos, 'dates', s.phone_gate_dates,
                            'request', s.phone_gate_request, 'verify', s.phone_gate_verify,
                            'allow_unverified', s.phone_gate_verify and s.phone_gate_allow_unverified, 'us_texts', s.signin_phone_us_allowed)
    from (select (app.settings()).*) s
$$;

create or replace function app.phone_gate_bump(p_gate text, p_col text, p_n integer default 1) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if p_col not in ('shown', 'given', 'closed', 'verified', 'texts', 'requests', 'requests_gated') then
    raise exception 'Not a counter: %', p_col using errcode = '22023';
  end if;
  execute format('insert into phone_gate_daily as d (day, gate, %1$I) values ($1, $2, $3)
                  on conflict (day, gate) do update set %1$I = d.%1$I + excluded.%1$I', p_col)
    using app.today(), p_gate, p_n;
end $$;

-- A number for the box: {ok, phone, country} or {ok false, reason invalid | country}. Canada, or the United States.
create or replace function app.phone_gate_number(p text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when app.phone_country(p) in ('CA', 'US') then jsonb_build_object('ok', true, 'phone', app.phone_e164(p), 'country', app.phone_country(p))
              when app.phone_e164(p) is null then jsonb_build_object('ok', false, 'reason', 'invalid')
              else jsonb_build_object('ok', false, 'reason', 'country') end
$$;

-- ================================================================ 4. the box, from the site's server
-- shown or closed (p: visitor_id, gate, event). One small write; no personal data.
create or replace function app.phone_gate_event(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vis uuid;
  v_gate text := p ->> 'gate';
  v_ev text := p ->> 'event';
begin
  begin v_vis := (p ->> 'visitor_id')::uuid; exception when others then v_vis := null; end;
  if v_gate not in ('gallery', 'dates', 'request') or v_ev not in ('shown', 'closed') then return jsonb_build_object('ok', false); end if;
  if v_vis is not null and not app.rate_limit('phone-gate-ev:' || v_vis, 40, interval '1 hour') then return jsonb_build_object('ok', false, 'reason', 'rate_limited'); end if;
  perform app.phone_gate_bump(v_gate, v_ev);
  if v_ev = 'shown' and v_vis is not null then
    insert into app.phone_gate_seen (visitor_id) values (v_vis) on conflict do nothing;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- A code asked for (p: phone, visitor_id, ip_key, code_hash): the number allowed, the limits, the code kept as its hash,
-- a log row. {ok, phone, from, log_id} or {ok false, reason}.
create or replace function app.phone_gate_code(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  c jsonb := app.phone_gate_number(p ->> 'phone');
  v_vis uuid;
  v_from text := app.phone_our_number();
  v_ip text := nullif(p ->> 'ip_key', '');
  v_log uuid;
begin
  begin v_vis := (p ->> 'visitor_id')::uuid; exception when others then v_vis := null; end;
  if v_vis is null then return jsonb_build_object('ok', false, 'reason', 'visitor'); end if;
  if not s.phone_gate_verify then return jsonb_build_object('ok', false, 'reason', 'off'); end if;
  if not (c ->> 'ok')::boolean then return c; end if;
  if c ->> 'country' = 'US' and not s.signin_phone_us_allowed then return c || jsonb_build_object('ok', false, 'reason', 'no_us_texts'); end if;
  if coalesce(p ->> 'code_hash', '') !~ '^[0-9a-f]{64}$' then raise exception 'A code hash is needed' using errcode = '22023'; end if;
  if v_from is null then return jsonb_build_object('ok', false, 'reason', 'no_from_number'); end if;
  -- the limits: the number, the network address key and the whole site, each a day (one cent a text)
  if not app.rate_limit('phone-gate-num:' || (c ->> 'phone'), s.phone_gate_texts_per_number_day, interval '1 day')
     or (v_ip is not null and not app.rate_limit('phone-gate-ip:' || v_ip, s.phone_gate_texts_per_ip_day, interval '1 day'))
     or not app.rate_limit('phone-gate-site', s.phone_gate_texts_per_day, interval '1 day') then
    insert into auth_sms_log (phone, status, reason, finished_at, purpose) values (c ->> 'phone', 'refused', 'rate_limited', now(), 'phone_gate');
    return jsonb_build_object('ok', false, 'reason', 'rate_limited');
  end if;
  delete from app.phone_gate_codes where created_at < now() - interval '1 day';
  insert into app.phone_gate_codes (phone, visitor_id, code_hash, expires_at)
  values (c ->> 'phone', v_vis, p ->> 'code_hash', now() + interval '10 minutes');
  insert into auth_sms_log (phone, status, purpose) values (c ->> 'phone', 'sending', 'phone_gate') returning id into v_log;
  perform app.phone_gate_bump(coalesce(nullif(p ->> 'gate', ''), 'dates'), 'texts');
  return jsonb_build_object('ok', true, 'phone', c ->> 'phone', 'country', c ->> 'country', 'from', v_from, 'log_id', v_log);
end $$;

-- A code checked (p: phone, visitor_id, code_hash): the newest code of this number and device, 5 tries.
create or replace function app.phone_gate_check_code(p jsonb) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  r app.phone_gate_codes;
  v_vis uuid;
begin
  begin v_vis := (p ->> 'visitor_id')::uuid; exception when others then return false; end;
  select * into r from app.phone_gate_codes
   where phone = app.phone_e164(p ->> 'phone') and visitor_id = v_vis and used_at is null and expires_at > now()
   order by created_at desc limit 1 for update;
  if r.id is null or r.attempts >= 5 then return false; end if;
  if r.code_hash <> coalesce(p ->> 'code_hash', '') then
    update app.phone_gate_codes set attempts = attempts + 1 where id = r.id;
    return false;
  end if;
  update app.phone_gate_codes set used_at = now() where id = r.id;
  return true;
end $$;

-- A number given (p: visitor_id, phone, gate, page, ip_key, marketing, marketing_text, code_hash (with the code on),
-- unverified (true: "Use without verifying"), signed_in). Saves the contact, the capture and its lead.
create or replace function app.phone_gate_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  c jsonb := app.phone_gate_number(p ->> 'phone');
  v_vis uuid;
  v_gate text := coalesce(nullif(p ->> 'gate', ''), 'dates');
  v_ip text := nullif(p ->> 'ip_key', '');
  v_mkt boolean := coalesce((p ->> 'marketing')::boolean, false);
  v_unver boolean := coalesce((p ->> 'unverified')::boolean, false);
  v_signed uuid := nullif(p ->> 'signed_in', '')::uuid;
  v_verified boolean := false;
  v_page text := left(nullif(p ->> 'page', ''), 300);
  cc contact_captures;
  g phone_gate_contacts;
  v_lead uuid;
begin
  begin v_vis := (p ->> 'visitor_id')::uuid; exception when others then v_vis := null; end;
  if v_vis is null then return jsonb_build_object('ok', false, 'reason', 'visitor'); end if;
  if v_gate not in ('gallery', 'dates', 'request') then raise exception 'Not a box: %', v_gate using errcode = '22023'; end if;
  if not (c ->> 'ok')::boolean then return c; end if;
  if not app.rate_limit('phone-gate-save:' || v_vis, 20, interval '1 hour')
     or (v_ip is not null and not app.rate_limit('phone-gate-save-ip:' || v_ip, 60, interval '1 hour')) then
    return jsonb_build_object('ok', false, 'reason', 'rate_limited');
  end if;
  if v_mkt and coalesce(btrim(p ->> 'marketing_text'), '') = '' then raise exception 'The words of the marketing box are needed' using errcode = '22023'; end if;

  -- the code (when it is on): checked here, unless "Use without verifying" is allowed and chosen, or the number cannot
  -- get texts (US numbers before US texting is registered)
  if s.phone_gate_verify then
    if nullif(p ->> 'code_hash', '') is not null then
      v_verified := app.phone_gate_check_code(jsonb_build_object('phone', c ->> 'phone', 'visitor_id', v_vis, 'code_hash', p ->> 'code_hash'));
      if not v_verified then return jsonb_build_object('ok', false, 'reason', 'code'); end if;
    elsif not ((v_unver and s.phone_gate_allow_unverified) or (c ->> 'country' = 'US' and not s.signin_phone_us_allowed)) then
      return jsonb_build_object('ok', false, 'reason', 'code_needed');
    end if;
  end if;

  -- the capture (done at once: the number is all the box asks, so no follow-up To do) and its lead
  insert into contact_captures as x (visitor_id, form, ref, phone, page, state, done_at, done_reason, user_id)
  values (v_vis, 'phone_gate', '', c ->> 'phone', v_page, case when v_signed is null then 'phone_only' else 'signed_in' end, now(),
          'Gave a mobile number in the phone number box', v_signed)
  on conflict (visitor_id, form, ref) do update set phone = excluded.phone, page = coalesce(excluded.page, x.page), last_at = now(),
         user_id = coalesce(x.user_id, excluded.user_id)
  returning * into cc;
  if cc.lead_id is null then
    insert into leads (kind, phone, message, payload, source, source_url, consent_marketing, consent_text, consent_at)
    values ('other', c ->> 'phone', format('Gave their mobile number in the phone number box (%s).',
              case v_gate when 'gallery' then 'more photos' when 'dates' then 'full availability' else 'booking request' end),
            jsonb_build_object('capture_id', cc.id, 'form', 'phone_gate', 'gate', v_gate, 'visitor_id', v_vis, 'verified', v_verified),
            'unfinished_form', v_page, v_mkt, case when v_mkt then left(p ->> 'marketing_text', 500) end, case when v_mkt then now() end)
    returning id into v_lead;
    update contact_captures set lead_id = v_lead where id = cc.id returning * into cc;
  else
    update leads set phone = c ->> 'phone',
           consent_marketing = consent_marketing or v_mkt,
           consent_text = case when v_mkt then left(p ->> 'marketing_text', 500) else consent_text end,
           consent_at = case when v_mkt then now() else consent_at end,
           payload = payload || jsonb_build_object('verified', coalesce((payload ->> 'verified')::boolean, false) or v_verified)
     where id = cc.lead_id;
  end if;

  insert into phone_gate_contacts as x (visitor_id, phone, country, gate, page, verified_at, marketing_opt_in, marketing_text, marketing_at, user_id, capture_id, lead_id)
  values (v_vis, c ->> 'phone', c ->> 'country', v_gate, v_page, case when v_verified then now() end, v_mkt,
          case when v_mkt then left(p ->> 'marketing_text', 500) end, case when v_mkt then now() end, v_signed, cc.id, cc.lead_id)
  on conflict (visitor_id, phone) do update
     set verified_at = coalesce(x.verified_at, excluded.verified_at), page = coalesce(excluded.page, x.page),
         -- a later tick adds consent; an unticked box never withdraws it (STOP or the unsubscribe page does)
         marketing_opt_in = x.marketing_opt_in or excluded.marketing_opt_in,
         marketing_text = case when excluded.marketing_opt_in then excluded.marketing_text else x.marketing_text end,
         marketing_at = case when excluded.marketing_opt_in then excluded.marketing_at else x.marketing_at end,
         user_id = coalesce(x.user_id, excluded.user_id), updated_at = now()
  returning * into g;

  perform app.phone_gate_bump(v_gate, 'given');
  if v_verified then perform app.phone_gate_bump(v_gate, 'verified'); end if;
  insert into app.phone_gate_seen (visitor_id) values (v_vis) on conflict do nothing;
  return jsonb_build_object('ok', true, 'phone', g.phone, 'country', g.country, 'verified', g.verified_at is not null, 'lead_id', cc.lead_id);
end $$;

-- A web booking request was sent (p: visitor_id): counted for the day, and as gated when this visitor saw the box.
create or replace function app.phone_gate_request(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vis uuid;
  v_gated boolean := false;
begin
  begin v_vis := (p ->> 'visitor_id')::uuid; exception when others then v_vis := null; end;
  if v_vis is not null then v_gated := exists (select 1 from app.phone_gate_seen where visitor_id = v_vis); end if;
  perform app.phone_gate_bump('all', 'requests');
  if v_gated then perform app.phone_gate_bump('all', 'requests_gated'); end if;
  delete from app.phone_gate_seen where first_at < now() - interval '120 days';
  return jsonb_build_object('ok', true, 'gated', v_gated);
end $$;

-- ================================================================ 5. Admin: the report and the one-press switches
create or replace function app.phone_gate_report(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_days integer := least(greatest(coalesce((p ->> 'days')::integer, 30), 7), 120);
  v_first date := (select min(day) from phone_gate_daily where gate <> 'all' and shown > 0);
  v_today date := app.today();
  v_before numeric;
  v_since numeric;
begin
  if not app.user_is_admin(p_by) then raise exception 'The phone number box report is for Admins' using errcode = '42501'; end if;
  -- web requests a day (bookings made from the site), in the 28 days before the box was first shown, and since
  if v_first is not null then
    select round(count(*)::numeric / 28, 2) into v_before from bookings b
     where b.source = 'web' and (b.created_at at time zone 'America/Toronto')::date between v_first - 28 and v_first - 1;
    select round(count(*)::numeric / greatest(v_today - v_first + 1, 1), 2) into v_since from bookings b
     where b.source = 'web' and (b.created_at at time zone 'America/Toronto')::date >= v_first;
  end if;
  return jsonb_build_object(
    'rules', app.phone_gate_rules(),
    'first_shown', v_first,
    'requests_a_day_before', v_before,
    'requests_a_day_since', v_since,
    'totals', (select jsonb_build_object('shown', coalesce(sum(shown), 0), 'given', coalesce(sum(given), 0), 'closed', coalesce(sum(closed), 0),
                                         'verified', coalesce(sum(verified), 0), 'texts', coalesce(sum(texts), 0))
                 from phone_gate_daily where gate <> 'all' and day > v_today - v_days),
    'marketing_opt_ins', (select count(*) from phone_gate_contacts where marketing_opt_in and created_at > now() - make_interval(days => v_days)),
    'days', coalesce((select jsonb_agg(jsonb_build_object('day', d.day,
              'shown', coalesce(x.shown, 0), 'given', coalesce(x.given, 0), 'closed', coalesce(x.closed, 0), 'texts', coalesce(x.texts, 0),
              'gallery', coalesce(x.gallery, 0), 'dates', coalesce(x.dates, 0), 'request', coalesce(x.request, 0),
              'requests', (select count(*) from bookings b where b.source = 'web' and (b.created_at at time zone 'America/Toronto')::date = d.day),
              'requests_gated', coalesce(a.requests_gated, 0)) order by d.day desc)
        from generate_series(v_today - v_days + 1, v_today, interval '1 day') d0(day)
        cross join lateral (select d0.day::date as day) d
        left join lateral (select sum(shown) shown, sum(given) given, sum(closed) closed, sum(texts) texts,
                                  sum(shown) filter (where gate = 'gallery') gallery, sum(shown) filter (where gate = 'dates') dates,
                                  sum(shown) filter (where gate = 'request') request
                             from phone_gate_daily where day = d.day and gate <> 'all') x on true
        left join phone_gate_daily a on a.day = d.day and a.gate = 'all'), '[]'::jsonb));
end $$;

-- One press: a box on or off (a new dated settings row from today, as every settings save).
create or replace function app.phone_gate_switch(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_col text := case p ->> 'gate' when 'gallery' then 'phone_gate_gallery' when 'dates' then 'phone_gate_dates'
                                  when 'request' then 'phone_gate_request' when 'verify' then 'phone_gate_verify' end;
begin
  if not app.user_is_admin(p_by) then raise exception 'Settings are for Admins' using errcode = '42501'; end if;
  if v_col is null or (p ->> 'on') is null then raise exception 'Say which box and on or off' using errcode = '22023'; end if;
  perform app.admin_save(p_by, 'program_settings', jsonb_build_object('values', jsonb_build_object(v_col, (p ->> 'on')::boolean)));
  return app.phone_gate_rules();
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0280;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call = 'admin_read' and p_name = 'phone_gate_report') or (p_call = 'admin_do' and p_name = 'phone_gate_switch') then
    perform app.door_begin(p_user, p_aal);
    if p_name = 'phone_gate_report' then return app.phone_gate_report(p_user, coalesce(p, '{}'::jsonb)); end if;
    return app.phone_gate_switch(p_user, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre0280(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 6. the pages: the settings in site_facts (already read by the car and fleet pages)
alter function public.site_facts() rename to site_facts_pre0280;
alter function public.site_facts_pre0280() set schema app;
create or replace function public.site_facts() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.site_facts_pre0280() || jsonb_build_object('phone_gate', app.phone_gate_rules())
$$;
revoke all on function public.site_facts() from public;
grant execute on function public.site_facts() to anon, authenticated, service_role;
revoke all on function app.site_facts_pre0280() from public, anon, authenticated;
grant execute on function app.site_facts_pre0280() to service_role;
grant execute on function app.phone_gate_rules() to anon, authenticated, service_role;

-- ================================================================ 7. the server's door
create or replace function public.server_phone_gate_event(p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.phone_gate_event(p) $$;
create or replace function public.server_phone_gate_code(p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.phone_gate_code(p) $$;
create or replace function public.server_phone_gate_save(p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.phone_gate_save(p) $$;
create or replace function public.server_phone_gate_request(p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.phone_gate_request(p) $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['phone_gate_bump', 'phone_gate_number', 'phone_gate_event', 'phone_gate_code',
              'phone_gate_check_code', 'phone_gate_save', 'phone_gate_request', 'phone_gate_report', 'phone_gate_switch',
              'capture_form_label', 'capture_form_label_pre0280', 'door', 'door_pre0280']))
        or (n.nspname = 'public' and p.proname = any (array['server_phone_gate_event', 'server_phone_gate_code', 'server_phone_gate_save', 'server_phone_gate_request']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 8. privacy policy (the live legal.privacy block, where it still has our text)
update site_content_blocks
   set body = replace(body, 'we text a one-time sign-in code to the phone number you give.',
     'we text a one-time sign-in code to the phone number you give.

If you give your mobile number in the box on a car page or the cars page, we keep it to text you about availability and the bookings you ask about (reply STOP at any time). We text you offers only if you tick "Also text me deals".')
 where block_key = 'legal.privacy' and body like '%we text a one-time sign-in code to the phone number you give.%'
   and body not like '%Also text me deals%';
