-- 0090_contact_capture.sql
-- Contact capture from every form (docs/changes/2026-10-21-contact-capture.md). The owner's request of October 21, 2026:
-- someone who starts a booking request or any contact form and does not finish keeps their name, email and phone, and an
-- account is opened for them at once. The security-safe version:
--
--   1. Capture as early as possible. The request-to-book wizard, the contact and owner lead forms, the owner application,
--      the discount game claim and the live chat save the name, email and phone as soon as each field is valid (on blur,
--      debounced), linked to the browser's visitor id (Live visitors) and the draft, even when the form is never sent.
--      Only what the person typed. Rate limited (app.rate_limit, the limiter behind app.public_rate_check). No marketing
--      use: the lead carries consent_marketing = false.
--   2. An account at once. A valid email opens the person's users row, renter record and (made by the app) a sign-in
--      account without a password and without a confirmed email. The draft, the lead, the chat and the game claim are
--      linked to it. Phone only: a lead linked to the visitor until an email is given.
--   3. A browser-bound unverified session, only for a brand-new address (no account, no sign-in, no booking, no record
--      of any kind with it). It is not a sign-in: a random token in an httpOnly cookie of this browser (only its hash is
--      kept, capture_sessions) that sees only what this browser made during it (capture_session_items: its draft, its
--      request, its chat). The same address typed in another browser before it is confirmed is an existing account: the
--      sign-in link, never a second session, and nothing made there becomes visible here. Every unverified session of
--      the account ends when the email is confirmed (the users trigger below). An account never confirmed closes after
--      capture_close_days (30): its sessions end, its link stops, its sign-in is removed where the database may; the lead
--      stays.
--   4. One "Continue your request" email per account (renter_continue_request): a new account gets it from the capture
--      job capture_continue_minutes (30) after the form was left, inside the recovery emails' sending hours and under
--      the email cap; an existing account gets it at once (the site says "we sent you a sign-in link"). Its link
--      (/continue?t=..., only the hash kept here) makes a fresh sign-in token-hash link on each use, which signs in AND
--      confirms the email, then lands on the draft or request.
--   5. Unconfirmed accounts cannot accept an offer, sign, pay, upload ID or licence documents, or pay an extension
--      (app.capture_gate in the renter wrappers). Staff see "Email not confirmed" on the renter, the captured contacts on
--      Live visitors and Bookings > Leads, and an Admin To do "Unfinished request from <name>: follow up" (not raised in
--      the quiet hours of the site alerts).
--   6. Privacy policy: one row in section 1 (the lawyer's wording is in the change record).
-- No applied migration is edited.

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists capture_enabled boolean not null default true,
  add column if not exists capture_continue_minutes integer not null default 30 check (capture_continue_minutes between 5 and 1440),
  add column if not exists capture_link_hours integer not null default 72 check (capture_link_hours between 1 and 336),
  add column if not exists capture_close_days integer not null default 30 check (capture_close_days between 7 and 365),
  add column if not exists capture_rate_per_minute integer not null default 30 check (capture_rate_per_minute between 5 and 600),
  add column if not exists capture_followup_tasks boolean not null default true;
comment on column program_settings.capture_enabled is 'Contact capture: save the name, email and phone typed into the site''s forms as they are typed, and open an account for a new email.';
comment on column program_settings.capture_continue_minutes is 'Contact capture: minutes after a form was left unfinished before the "Continue your request" email (new accounts) and the Admin follow-up.';
comment on column program_settings.capture_link_hours is 'Contact capture: how long the link of the "Continue your request" email works.';
comment on column program_settings.capture_close_days is 'Contact capture: an account opened from a form and never confirmed closes its sign-in after this many days (the lead is kept).';
comment on column program_settings.capture_rate_per_minute is 'Contact capture: saves one browser may make per minute (three times this per network address key).';
comment on column program_settings.capture_followup_tasks is 'Contact capture: raise the Admin To do "Unfinished request from <name>: follow up".';

-- ================================================================ 2. tables
-- The accounts capture opened or touched. opened_by_capture: this table made the users row (the gate applies);
-- sign_in_made: the app made the sign-in account for it (no password, email not confirmed).
create table capture_accounts (
  user_id                  uuid primary key references users (id) on delete cascade,
  opened_by_capture        boolean not null default false,
  brand_new                boolean not null default false,          -- no record of any kind had the address: a browser session was allowed
  opened_at                timestamptz not null default now(),
  opened_form              text,
  visitor_id               uuid,
  sign_in_made             boolean not null default false,
  continue_sent_at         timestamptz,
  continue_link_hash       text unique,
  continue_link_expires_at timestamptz,
  continue_next            text,
  confirmed_at             timestamptz,
  closed_at                timestamptz,
  close_reason             text
);
comment on table capture_accounts is 'Contact capture (0090): accounts opened from a form (or existing accounts a form touched), the one "Continue your request" email and its link (hash only), confirmation and closing.';

create table capture_sessions (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references users (id) on delete cascade,
  token_hash   text not null unique,
  visitor_id   uuid not null,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  last_seen_at timestamptz not null default now(),
  revoked_at   timestamptz,
  revoked_reason text
);
create index capture_sessions_user_idx on capture_sessions (user_id) where revoked_at is null;
comment on table capture_sessions is 'Contact capture (0090): the unverified session of the browser that opened a brand-new account. Not a sign-in: it sees only capture_session_items. The token lives in an httpOnly cookie; only its hash is here.';

create table capture_session_items (
  session_id uuid not null references capture_sessions (id) on delete cascade,
  kind       text not null check (kind in ('draft', 'booking', 'chat')),
  entity_id  uuid not null,
  added_at   timestamptz not null default now(),
  primary key (session_id, kind, entity_id)
);
comment on table capture_session_items is 'Contact capture (0090): what one unverified session made in its own browser, the only things it may see.';

create table contact_captures (
  id          uuid primary key default gen_random_uuid(),
  visitor_id  uuid not null,
  form        text not null check (form in ('booking_request', 'owner_application', 'contact', 'owner_lead', 'chat', 'game')),
  ref         text not null default '',                       -- the draft, chat or game play the capture belongs to
  draft_id    uuid references form_drafts (id) on delete set null,
  chat_id     uuid references chat_conversations (id) on delete set null,
  name        text check (length(name) <= 120),
  email       text check (email = lower(email) and length(email) <= 200),
  phone       text check (length(phone) <= 20),
  lead_id     uuid references leads (id) on delete set null,
  user_id     uuid references users (id) on delete set null,
  renter_id   uuid references renters (id) on delete set null,
  state       text check (state in ('phone_only', 'new', 'this_device', 'existing', 'signed_in')),
  page        text,
  first_at    timestamptz not null default now(),
  last_at     timestamptz not null default now(),
  done_at     timestamptz,
  done_reason text,
  task_id     uuid references tasks (id) on delete set null,
  unique (visitor_id, form, ref)
);
create index contact_captures_user_idx on contact_captures (user_id) where user_id is not null;
create index contact_captures_open_idx on contact_captures (last_at) where done_at is null;
create index contact_captures_recent_idx on contact_captures (last_at desc);
comment on table contact_captures is 'Contact capture (0090): the name, email and phone typed into a form, saved as typed even when the form is never sent. Only what the person typed. Never used for marketing without consent.';

insert into task_rules (task_type, queue, title, priority, description)
values ('capture_follow_up', 'admin', 'Unfinished request: follow up', 'normal',
        'Someone typed their contact details into a form on the site and did not send it. Call or email them; the task closes by itself when they send the form.')
on conflict (task_type) do nothing;

-- ================================================================ 3. helpers
create or replace function app.capture_clean_email(p text) returns text
language sql immutable as $$
  select case when lower(btrim(coalesce(p, ''))) ~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' and length(btrim(p)) <= 200 then lower(btrim(p)) end
$$;
create or replace function app.capture_clean_phone(p text) returns text
language sql immutable as $$
  select case when length(regexp_replace(coalesce(p, ''), '\D', '', 'g')) between 10 and 15
              then case when btrim(p) like '+%' then '+' || regexp_replace(p, '\D', '', 'g')
                        when length(regexp_replace(p, '\D', '', 'g')) = 10 then '+1' || regexp_replace(p, '\D', '', 'g')
                        else '+' || regexp_replace(p, '\D', '', 'g') end end
$$;
create or replace function app.capture_clean_name(p text) returns text
language sql immutable as $$
  select case when length(regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g')) between 2 and 120
              then regexp_replace(btrim(p), '\s+', ' ', 'g') end
$$;

-- Does the sign-in service already hold this address? (auth.users on Supabase, the local stand-in's table locally.)
create or replace function app.capture_sign_in_exists(p_email text) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare
  v boolean := false;
begin
  if to_regclass('auth.users') is not null then
    begin
      execute 'select exists (select 1 from auth.users where lower(email) = $1)' into v using p_email;
    exception when others then v := false;
    end;
  end if;
  if not v and to_regclass('local_auth.users') is not null then
    execute 'select exists (select 1 from local_auth.users where lower(email) = $1)' into v using p_email;
  end if;
  return coalesce(v, false);
end $$;

-- Brand new: no account, no sign-in and no record of any kind holds the address, other than what this same browser
-- made (its own game claim, chat or capture). Only then may a browser get an unverified session.
create or replace function app.capture_brand_new(p_email text, p_visitor uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select not (
       exists (select 1 from users u where lower(u.email) = p_email)
    or exists (select 1 from renters r where lower(btrim(r.email)) = p_email)
    or exists (select 1 from drivers d where lower(btrim(d.email)) = p_email)
    or exists (select 1 from owners o where lower(btrim(o.email)) = p_email)
    or exists (select 1 from investors i where lower(btrim(i.email)) = p_email)
    or exists (select 1 from owner_cosigners c where lower(btrim(c.email)) = p_email)
    or exists (select 1 from partners pa where lower(btrim(pa.email)) = p_email)
    or exists (select 1 from game_claims g where g.email = p_email and g.visitor_id is distinct from p_visitor)
    or exists (select 1 from chat_conversations ch where lower(btrim(ch.email)) = p_email and ch.visitor_id is distinct from p_visitor)
    or exists (select 1 from leads l where lower(btrim(l.email)) = p_email and (l.payload ->> 'visitor_id') is distinct from p_visitor::text)
    or exists (select 1 from contact_captures cc where cc.email = p_email and cc.visitor_id <> p_visitor)
    or app.capture_sign_in_exists(p_email))
$$;

-- The unverified session a token opens (valid, not revoked, the account still unconfirmed and open).
create or replace function app.capture_session_of(p_token text) returns capture_sessions
language sql stable security definer set search_path = public, app as $$
  select s.* from capture_sessions s
    join users u on u.id = s.user_id
    join capture_accounts ca on ca.user_id = s.user_id
   where p_token is not null and length(p_token) between 32 and 128
     and s.token_hash = app.token_hash(p_token) and s.revoked_at is null and s.expires_at > now()
     and u.email_verified_at is null and ca.closed_at is null
$$;

-- An account capture made or gave a sign-in that has not confirmed its email: it may not accept, sign or pay.
create or replace function app.capture_unconfirmed(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from capture_accounts ca join users u on u.id = ca.user_id
                  where ca.user_id = p_user and (ca.opened_by_capture or ca.sign_in_made) and u.email_verified_at is null)
$$;
create or replace function app.capture_gate(p_user uuid, p_what text) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_user is not null and app.capture_unconfirmed(p_user) then
    raise exception 'Confirm your email first: open the link in the email "Continue your request" we sent you. Then you can %.', p_what
      using errcode = '42501';
  end if;
end $$;

create or replace function app.capture_form_label(p_form text) returns text
language sql immutable as $$
  select case p_form when 'booking_request' then 'booking request' when 'owner_application' then 'owner application'
                     when 'contact' then 'contact form' when 'owner_lead' then 'List your car form' when 'chat' then 'live chat'
                     when 'game' then 'discount game' else p_form end
$$;

-- Where the "Continue your request" link lands.
create or replace function app.capture_next(c contact_captures) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when c.form = 'booking_request' then
      coalesce((select '/account/bookings/' || b.booking_number from bookings b join renters r on r.id = b.renter_id
                 where r.user_id = c.user_id and b.created_at >= c.first_at order by b.created_at desc limit 1),
               (select '/book/' || (d.data ->> 'car') from form_drafts d where d.id = c.draft_id and coalesce(d.data ->> 'car', '') ~ '^[a-z0-9-]+$'),
               '/cars')
    when c.form = 'owner_application' then '/list-your-car/apply'
    when c.form = 'owner_lead' then '/list-your-car'
    when c.form = 'contact' then '/contact'
    else '/account' end
$$;

-- A fresh link token for the account's one email: only its hash is kept.
create or replace function app.capture_new_link(p_user uuid, p_next text) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_token text := app.new_token();
begin
  update capture_accounts set continue_link_hash = app.token_hash(v_token),
         continue_link_expires_at = now() + make_interval(hours => (app.settings()).capture_link_hours),
         continue_next = coalesce(p_next, '/account')
   where user_id = p_user;
  return v_token;
end $$;

-- Queues the one "Continue your request" email of an account (null when it already went, or may not go).
create or replace function app.capture_send_continue(p_user uuid, p_capture uuid) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  ca capture_accounts;
  c contact_captures;
  u users;
  v_token text;
  v_event bigint;
  v_what text;
begin
  select * into ca from capture_accounts where user_id = p_user for update;
  select * into u from users where id = p_user;
  -- the link lands on the account's most useful unfinished form (a booking request first), whichever browser asked
  select * into c from contact_captures x where x.user_id = p_user
   order by (x.form = 'booking_request') desc, (x.done_at is null) desc, (x.draft_id is not null) desc, x.last_at desc limit 1;
  if c.id is null then select * into c from contact_captures where id = p_capture; end if;
  if ca.user_id is null or u.id is null or ca.continue_sent_at is not null or ca.closed_at is not null then return null; end if;
  if app.email_suppressed(u.email, false) then return null; end if;
  v_token := app.capture_new_link(p_user, app.capture_next(c));
  v_what := case c.form
    when 'booking_request' then 'a booking request' || coalesce(' for the ' || (select app.vehicle_name(l.vehicle_id) from vehicle_listings l
                                   join form_drafts d on d.id = c.draft_id where l.slug = d.data ->> 'car' limit 1), '')
    when 'owner_application' then 'an application to list your car'
    when 'owner_lead' then 'a question about listing your car'
    when 'contact' then 'a message to us'
    when 'game' then 'claiming a discount code'
    else 'a conversation with us' end;
  v_event := app.emit_event('renter_continue_request', 'user', p_user,
    jsonb_build_object('user_id', p_user, 'capture_id', p_capture, '_immediate', true,
                       'continue_url', (app.settings()).notify_base_url || '/continue?t=' || v_token,
                       'started_what', v_what, 'new_account', ca.opened_by_capture,
                       'first_name', coalesce(nullif(split_part(coalesce(c.name, u.full_name, ''), ' ', 1), ''), 'there'),
                       'link_expiry', (app.settings()).capture_link_hours || ' hours'),
    'renter_continue_request:' || p_user);
  update capture_accounts set continue_sent_at = now() where user_id = p_user;
  return v_event;
end $$;

-- ================================================================ 4. capture
-- One save from a form. p: visitor_id, form, ref (the draft, chat or play id), draft_token (the browser's draft token,
-- to prove a draft is its own), name, email, phone, page, ip_key (a salted daily key of the network address; the
-- address is never stored), session_token (the browser's unverified session, if any), browser (true only from the
-- site's capture endpoint: only then may a session be opened), signed_in (the signed-in user, if any).
create or replace function app.capture_contact(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_vis uuid;
  v_form text := p ->> 'form';
  v_ref text := left(coalesce(p ->> 'ref', ''), 64);
  v_name text := app.capture_clean_name(p ->> 'name');
  v_email text := app.capture_clean_email(p ->> 'email');
  v_phone text := app.capture_clean_phone(p ->> 'phone');
  v_signed uuid := nullif(p ->> 'signed_in', '')::uuid;
  v_browser boolean := coalesce((p ->> 'browser')::boolean, false);
  v_draft form_drafts;
  v_chat uuid;
  c contact_captures;
  s capture_sessions;
  u users;
  rn renters;
  ca capture_accounts;
  v_state text;
  v_token text;
  v_new boolean := false;
  v_sent boolean := false;
  v_make boolean := false;
  v_discard uuid;
  v_lead uuid;
begin
  if not ps.capture_enabled then return jsonb_build_object('ok', false, 'error', 'off'); end if;
  begin v_vis := (p ->> 'visitor_id')::uuid; exception when others then v_vis := null; end;
  if v_vis is null then return jsonb_build_object('ok', false, 'error', 'visitor'); end if;
  if v_form is null or v_form not in ('booking_request', 'owner_application', 'contact', 'owner_lead', 'chat', 'game') then
    return jsonb_build_object('ok', false, 'error', 'form');
  end if;
  -- rate limits: the browser, and the network address key (the same limiter as app.public_rate_check)
  if v_browser then
    if not app.rate_limit('capture:v:' || v_vis, ps.capture_rate_per_minute, interval '1 minute')
       or (nullif(p ->> 'ip_key', '') is not null and not app.rate_limit('capture:ip:' || (p ->> 'ip_key'), ps.capture_rate_per_minute * 3, interval '1 minute')) then
      return jsonb_build_object('ok', false, 'error', 'rate_limited');
    end if;
  end if;
  if v_name is null and v_email is null and v_phone is null then return jsonb_build_object('ok', true, 'saved', false); end if;

  -- the draft must be this browser's own (its token) or the signed-in person's
  if v_form in ('booking_request', 'owner_application') and v_ref ~ '^[0-9a-f-]{36}$' then
    select * into v_draft from form_drafts d where d.id = v_ref::uuid and d.submitted_at is null
       and ((nullif(p ->> 'draft_token', '') is not null and d.token_hashes @> array[app.token_hash(p ->> 'draft_token')])
            or (v_signed is not null and d.user_id = v_signed));
    if v_draft.id is null then v_ref := ''; end if;
  elsif v_form = 'chat' and v_ref ~ '^[0-9a-f-]{36}$' then
    v_chat := (select id from chat_conversations where id = v_ref::uuid and visitor_id = v_vis);
    if v_chat is null then v_ref := ''; end if;
  elsif v_form in ('booking_request', 'owner_application', 'chat') then
    v_ref := '';
  end if;

  -- a capture made before the form had its draft (or chat) takes it now, rather than a second row
  if v_ref <> '' then
    update contact_captures x set ref = v_ref, draft_id = v_draft.id, chat_id = v_chat
     where x.visitor_id = v_vis and x.form = v_form and x.ref = '' and x.done_at is null
       and not exists (select 1 from contact_captures y where y.visitor_id = v_vis and y.form = v_form and y.ref = v_ref);
  end if;
  -- the capture row: the latest valid value of each field replaces the earlier one
  insert into contact_captures as x (visitor_id, form, ref, draft_id, chat_id, name, email, phone, page)
  values (v_vis, v_form, v_ref, v_draft.id, v_chat, v_name, v_email, v_phone, left(p ->> 'page', 300))
  on conflict (visitor_id, form, ref) do update
     set name = coalesce(excluded.name, x.name), email = coalesce(excluded.email, x.email), phone = coalesce(excluded.phone, x.phone),
         page = coalesce(excluded.page, x.page), last_at = now(),
         done_at = case when excluded.email is distinct from null and excluded.email <> coalesce(x.email, '') then null else x.done_at end
  returning * into c;

  -- the lead (needs an email or a phone): one per capture, kept up to date, never marketing
  if c.email is not null or c.phone is not null then
    if c.lead_id is null then
      insert into leads (kind, name, email, phone, message, payload, source, source_url, consent_marketing)
      values (case v_form when 'contact' then 'contact' when 'chat' then 'chat' else 'other' end, c.name, c.email, c.phone,
              format('Typed into the %s and not sent yet.', app.capture_form_label(v_form)),
              jsonb_build_object('capture_id', c.id, 'form', v_form, 'visitor_id', v_vis, 'draft_id', c.draft_id, 'chat_id', c.chat_id),
              'unfinished_form', left(p ->> 'page', 300), false)
      returning id into v_lead;
      update contact_captures set lead_id = v_lead where id = c.id returning * into c;
    else
      update leads set name = coalesce(c.name, name), email = coalesce(c.email, email), phone = coalesce(c.phone, phone)
       where id = c.lead_id and (name, email, phone) is distinct from (coalesce(c.name, name), coalesce(c.email, email), coalesce(c.phone, phone));
    end if;
  end if;

  -- signed in: the person's own account; nothing is opened or sent
  if v_signed is not null then
    update contact_captures set user_id = coalesce(user_id, case when c.email is null or exists (select 1 from users x where x.id = v_signed and lower(x.email) = c.email) then v_signed end),
           state = 'signed_in' where id = c.id;
    return jsonb_build_object('ok', true, 'saved', true, 'capture_id', c.id, 'state', 'signed_in');
  end if;

  if c.email is null then
    update contact_captures set state = 'phone_only' where id = c.id;
    return jsonb_build_object('ok', true, 'saved', true, 'capture_id', c.id, 'state', 'phone_only');
  end if;

  s := app.capture_session_of(p ->> 'session_token');
  if s.id is not null and s.visitor_id <> v_vis then s := null; end if;
  select * into u from users where lower(email) = c.email;

  -- the email changed in this same capture: an account the earlier (mistyped) address opened here and nothing else
  -- holds is removed again (the app removes its sign-in)
  if c.user_id is not null and c.user_id is distinct from u.id then
    select * into ca from capture_accounts where user_id = c.user_id;
    if ca.opened_by_capture and ca.confirmed_at is null
       and not exists (select 1 from bookings b join renters r on r.id = b.renter_id where r.user_id = c.user_id)
       and not exists (select 1 from contact_captures o where o.user_id = c.user_id and o.id <> c.id)
       and not exists (select 1 from owners o where o.user_id = c.user_id) then
      begin
        delete from capture_sessions where user_id = c.user_id;
        delete from renters r where r.user_id = c.user_id;
        delete from user_roles where user_id = c.user_id;
        delete from users where id = c.user_id;
        v_discard := c.user_id;
      exception when others then v_discard := null;
      end;
    end if;
    update contact_captures set user_id = null, renter_id = null where id = c.id returning * into c;
    if v_discard is not null and s.user_id = v_discard then s := null; end if;
  end if;

  if u.id is not null and s.id is not null and s.user_id = u.id then
    -- this browser's own unverified account
    v_state := 'this_device';
  elsif u.id is null and app.capture_brand_new(c.email, v_vis) then
    -- a brand-new address: the account, the renter (once a name is known) and, from a browser, its unverified session
    insert into users (id, email, phone, full_name, status)
    values (gen_random_uuid(), c.email, c.phone, coalesce(c.name, split_part(c.email, '@', 1)), 'active') returning * into u;
    insert into user_roles (user_id, role) values (u.id, 'renter') on conflict do nothing;
    insert into capture_accounts (user_id, opened_by_capture, brand_new, opened_form, visitor_id) values (u.id, true, true, v_form, v_vis);
    v_new := true; v_make := true;
    v_state := 'new';
  else
    -- an address with an account or any record: linked, never a session; the sign-in link goes once
    if u.id is null then
      insert into users (id, email, phone, full_name, status)
      values (gen_random_uuid(), c.email, null, coalesce(c.name, split_part(c.email, '@', 1)), 'active') returning * into u;
      insert into user_roles (user_id, role) values (u.id, 'renter') on conflict do nothing;
      insert into capture_accounts (user_id, opened_by_capture, opened_form, visitor_id) values (u.id, true, v_form, v_vis);
    else
      insert into capture_accounts (user_id, opened_by_capture, opened_form, visitor_id) values (u.id, false, v_form, v_vis) on conflict (user_id) do nothing;
    end if;
    v_state := 'existing';
  end if;

  select * into ca from capture_accounts where user_id = u.id;
  v_make := not ca.sign_in_made and ca.closed_at is null;

  -- only this browser's own new account takes what was typed into its records
  if v_state in ('new', 'this_device') then
    select * into rn from renters where user_id = u.id;
    if rn.id is null and c.name is not null then
      insert into renters (user_id, legal_name, mobile, email) values (u.id, c.name, c.phone, c.email) returning * into rn;
    elsif rn.id is not null and not exists (select 1 from bookings b where b.renter_id = rn.id) then
      update renters set legal_name = coalesce(c.name, legal_name), mobile = coalesce(c.phone, mobile) where id = rn.id returning * into rn;
      update users set full_name = coalesce(c.name, full_name), phone = coalesce(c.phone, phone) where id = u.id;
    end if;
    if v_new and v_browser then
      v_token := app.new_token();
      insert into capture_sessions (user_id, token_hash, visitor_id, expires_at)
      values (u.id, app.token_hash(v_token), v_vis, now() + make_interval(days => ps.capture_close_days)) returning * into s;
    end if;
    if s.id is not null then
      update capture_sessions set last_seen_at = now() where id = s.id;
      if c.draft_id is not null then insert into capture_session_items (session_id, kind, entity_id) values (s.id, 'draft', c.draft_id) on conflict do nothing; end if;
      if c.chat_id is not null then insert into capture_session_items (session_id, kind, entity_id) values (s.id, 'chat', c.chat_id) on conflict do nothing; end if;
    end if;
  else
    select * into rn from renters where user_id = u.id;
    v_sent := app.capture_send_continue(u.id, c.id) is not null;
  end if;

  update contact_captures set user_id = u.id, renter_id = rn.id, state = v_state where id = c.id;
  -- the chat and the game claim of this capture belong to the account (the lead links through the capture)
  if c.chat_id is not null then update chat_conversations set user_id = coalesce(user_id, u.id) where id = c.chat_id; end if;

  return jsonb_build_object('ok', true, 'saved', true, 'capture_id', c.id, 'state', v_state, 'user_id', u.id,
    'email', u.email, 'name', coalesce(c.name, u.full_name), 'make_sign_in', v_make, 'session_token', v_token,
    'link_sent', v_sent, 'link_sent_before', v_state = 'existing' and not v_sent and ca.continue_sent_at is not null,
    'discard_user', v_discard);
end $$;

-- The app made (or found) the sign-in account of an account capture opened.
create or replace function app.capture_sign_in_made(p_user uuid) returns void
language sql security definer set search_path = public, app as $$
  update capture_accounts set sign_in_made = true where user_id = p_user and closed_at is null
$$;

-- The form was sent: its captures are done, their leads closed (the form made its own record) and their to-dos closed.
create or replace function app.capture_done(p jsonb) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_vis uuid;
  v_n integer;
begin
  begin v_vis := (p ->> 'visitor_id')::uuid; exception when others then v_vis := null; end;
  with d as (
    update contact_captures c set done_at = now(), done_reason = coalesce(p ->> 'reason', 'The form was sent')
     where c.done_at is null
       and ((v_vis is not null and c.visitor_id = v_vis and c.form = p ->> 'form' and (coalesce(p ->> 'ref', '') = '' or c.ref = p ->> 'ref'))
            or (nullif(p ->> 'draft_id', '') is not null and c.draft_id = (p ->> 'draft_id')::uuid))
    returning c.lead_id, c.task_id)
  , l as (update leads set status = 'closed', closed_reason = 'The form was sent: it made its own record'
           where id in (select lead_id from d) and status = 'new' returning 1)
  , t as (update tasks set status = 'done', completed_at = now(), completion_note = 'Closed by itself: the form was sent'
           where id in (select task_id from d) and status in ('open', 'in_progress', 'waiting') returning 1)
  select count(*) into v_n from d;
  return v_n;
end $$;

-- What this browser's unverified session may see: only what it made.
create or replace function app.capture_session_read(p_token text, p_visitor uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s capture_sessions := app.capture_session_of(p_token);
  u users;
begin
  if s.id is null or (p_visitor is not null and s.visitor_id <> p_visitor) then return jsonb_build_object('ok', false); end if;
  update capture_sessions set last_seen_at = now() where id = s.id;
  select * into u from users where id = s.user_id;
  return jsonb_build_object('ok', true, 'user_id', u.id, 'email', u.email, 'name', u.full_name, 'email_confirmed', false,
    'expires_at', s.expires_at,
    'drafts', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'form_code', d.form_code, 'step', d.step, 'saved_at', d.updated_at,
                                                            'car', d.data ->> 'car', 'from', d.data ->> 'from', 'to', d.data ->> 'to',
                                                            'car_name', (select app.vehicle_name(l.vehicle_id) from vehicle_listings l where l.slug = d.data ->> 'car' limit 1))
                                         order by d.updated_at desc)
                          from capture_session_items i join form_drafts d on d.id = i.entity_id
                         where i.session_id = s.id and i.kind = 'draft' and d.submitted_at is null and d.expires_at > now()), '[]'::jsonb),
    'bookings', coalesce((select jsonb_agg(jsonb_build_object('number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at, 'return_at', b.return_at,
                                                              'car', app.vehicle_name(b.vehicle_id)) order by b.created_at desc)
                            from capture_session_items i join bookings b on b.id = i.entity_id
                           where i.session_id = s.id and i.kind = 'booking'), '[]'::jsonb),
    'chats', coalesce((select jsonb_agg(jsonb_build_object('number', ch.number, 'status', ch.status, 'at', ch.last_message_at) order by ch.last_message_at desc)
                         from capture_session_items i join chat_conversations ch on ch.id = i.entity_id
                        where i.session_id = s.id and i.kind = 'chat'), '[]'::jsonb));
end $$;

-- A request sent from this browser during its unverified session becomes visible to it (and only to it).
create or replace function app.capture_session_add_booking(p_token text, p_number text) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  s capture_sessions := app.capture_session_of(p_token);
  v uuid;
begin
  if s.id is null then return false; end if;
  select b.id into v from bookings b join renters r on r.id = b.renter_id
   where b.booking_number = p_number and r.user_id = s.user_id and b.created_at >= s.created_at;
  if v is null then return false; end if;
  insert into capture_session_items (session_id, kind, entity_id) values (s.id, 'booking', v) on conflict do nothing;
  return true;
end $$;

-- This browser leaves its unverified session (the cookie is removed by the app).
create or replace function app.capture_session_end(p_token text) returns void
language sql security definer set search_path = public, app as $$
  update capture_sessions set revoked_at = now(), revoked_reason = 'Ended in the browser'
   where token_hash = app.token_hash(coalesce(p_token, '')) and revoked_at is null
$$;

-- The "Continue your request" link: the account it opens and where it lands. Usable until it expires (an email
-- scanner opening it first does not spend it); an hour after the email is confirmed it stops.
create or replace function app.capture_continue_open(p_token text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ca capture_accounts;
  u users;
begin
  select * into ca from capture_accounts where continue_link_hash = app.token_hash(coalesce(p_token, ''));
  if ca.user_id is null or ca.continue_link_expires_at <= now() or ca.closed_at is not null then
    return jsonb_build_object('ok', false, 'error', 'expired');
  end if;
  select * into u from users where id = ca.user_id;
  if u.email_verified_at is not null and u.email_verified_at < now() - interval '1 hour' then
    return jsonb_build_object('ok', false, 'error', 'used');
  end if;
  if u.status not in ('active', 'invited') then return jsonb_build_object('ok', false, 'error', 'inactive'); end if;
  return jsonb_build_object('ok', true, 'user_id', u.id, 'email', u.email, 'name', u.full_name, 'next', coalesce(ca.continue_next, '/account'),
                            'make_sign_in', not ca.sign_in_made);
end $$;

-- ================================================================ 5. confirmation ends every unverified session
create or replace function app.capture_users_confirmed() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  c record;
begin
  if old.email_verified_at is not null or new.email_verified_at is null then return null; end if;
  update capture_accounts set confirmed_at = coalesce(confirmed_at, new.email_verified_at) where user_id = new.id;
  update capture_sessions set revoked_at = now(), revoked_reason = 'The email was confirmed' where user_id = new.id and revoked_at is null;
  -- the drafts of the account's captures become the account's own, unless it already has an open one of that form
  for c in select distinct cc.draft_id from contact_captures cc join form_drafts d on d.id = cc.draft_id
            where cc.user_id = new.id and d.user_id is null and d.submitted_at is null and d.expires_at > now() loop
    update form_drafts d set user_id = new.id where d.id = c.draft_id
       and not exists (select 1 from form_drafts o where o.user_id = new.id and o.form_code = d.form_code and o.submitted_at is null
                          and coalesce(o.entity_table, '') = coalesce(d.entity_table, '') and o.entity_id is not distinct from d.entity_id);
  end loop;
  return null;
end $$;
create trigger users_capture_confirmed after update of email_verified_at on users
  for each row execute function app.capture_users_confirmed();

-- A draft sent from its form closes its captures.
create or replace function app.capture_draft_submitted() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if old.submitted_at is null and new.submitted_at is not null then
    perform app.capture_done(jsonb_build_object('draft_id', new.id, 'reason', 'The form was sent'));
  end if;
  return null;
end $$;
create trigger form_drafts_capture_done after update of submitted_at on form_drafts
  for each row execute function app.capture_draft_submitted();

-- A game prize claimed closes the game capture of that browser.
create or replace function app.capture_game_claimed() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.capture_done(jsonb_build_object('visitor_id', new.visitor_id, 'form', 'game', 'reason', 'The prize was claimed'));
  return null;
end $$;
create trigger game_claims_capture_done after insert on game_claims
  for each row execute function app.capture_game_claimed();

-- Contact details given in the live chat are captured like a form (no browser session: the chat is not a sign-in
-- surface) and are done at once (the chat has its own follow-up).
create or replace function app.capture_chat_contact() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.visitor_id is null or (new.name, new.email, new.phone) is not distinct from (old.name, old.email, old.phone) then return null; end if;
  if new.email is null and new.phone is null then return null; end if;
  begin
    perform app.capture_contact(jsonb_build_object('visitor_id', new.visitor_id, 'form', 'chat', 'ref', new.id::text,
                                                   'name', new.name, 'email', new.email, 'phone', new.phone, 'page', new.page));
    perform app.capture_done(jsonb_build_object('visitor_id', new.visitor_id, 'form', 'chat', 'ref', new.id::text, 'reason', 'Given in the live chat'));
  exception when others then
    -- the chat never fails because of capture
    null;
  end;
  return null;
end $$;
create trigger chat_conversations_capture after update of name, email, phone on chat_conversations
  for each row execute function app.capture_chat_contact();

-- ================================================================ 6. the job (every 15 minutes)
create or replace function app.job_capture(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_hour integer := app.local_hour(p_now);
  c record;
  v_sent integer := 0;
  v_tasks integer := 0;
  v_closed integer := 0;
  v_done integer := 0;
  v_task uuid;
  v_who text;
begin
  -- 1. drafts sent since (a draft closed outside its form's own path)
  for c in select cc.id, cc.draft_id from contact_captures cc join form_drafts d on d.id = cc.draft_id
            where cc.done_at is null and d.submitted_at is not null loop
    v_done := v_done + app.capture_done(jsonb_build_object('draft_id', c.draft_id));
  end loop;
  -- a booking request sent by the account since the capture
  for c in select cc.id, cc.lead_id, cc.task_id from contact_captures cc
            where cc.done_at is null and cc.form = 'booking_request' and cc.user_id is not null
              and exists (select 1 from bookings b join renters r on r.id = b.renter_id where r.user_id = cc.user_id and b.created_at >= cc.first_at) loop
    update contact_captures set done_at = p_now, done_reason = 'A booking request was sent' where id = c.id;
    update leads set status = 'closed', closed_reason = 'The form was sent: it made its own record' where id = c.lead_id and status = 'new';
    update tasks set status = 'done', completed_at = p_now, completion_note = 'Closed by itself: the form was sent' where id = c.task_id and status in ('open', 'in_progress', 'waiting');
    v_done := v_done + 1;
  end loop;

  if not ps.capture_enabled then return format('off, done %s', v_done); end if;

  -- 2. the one "Continue your request" email of a new account whose form was left, inside the sending hours
  if v_hour >= ps.recovery_send_from_hour and v_hour < ps.recovery_send_until_hour then
    for c in select distinct on (cc.user_id) cc.id, cc.user_id from contact_captures cc
               join capture_accounts ca on ca.user_id = cc.user_id
               join users u on u.id = cc.user_id
              where cc.done_at is null and cc.email is not null and cc.last_at <= p_now - make_interval(mins => ps.capture_continue_minutes)
                and cc.last_at > p_now - interval '7 days'
                and ca.opened_by_capture and ca.continue_sent_at is null and ca.closed_at is null and u.email_verified_at is null
              order by cc.user_id, cc.last_at desc loop
      if app.capture_send_continue(c.user_id, c.id) is not null then v_sent := v_sent + 1; end if;
    end loop;
  end if;

  -- 3. the Admin follow-up, never in the quiet hours of the site alerts
  if ps.capture_followup_tasks and not app.uptime_quiet(p_now) then
    for c in select cc.* from contact_captures cc
              where cc.done_at is null and cc.task_id is null and cc.form <> 'chat'
                and (cc.email is not null or cc.phone is not null)
                and cc.last_at <= p_now - make_interval(mins => ps.capture_continue_minutes) and cc.last_at > p_now - interval '7 days' loop
      v_who := coalesce(c.name, c.email, c.phone);
      v_task := app.raise_task(p_type => 'capture_follow_up', p_title => left(format('Unfinished request from %s: follow up', v_who), 200),
        p_detail => format('Typed into the %s on %s and not sent. Contact: %s%s. Only what they typed; no marketing without their consent. The task closes by itself when they send the form.',
                           app.capture_form_label(c.form), app.fmt_at(c.last_at), coalesce(c.phone, 'no phone'), coalesce(', ' || c.email, '')),
        p_renter => c.renter_id, p_queue => 'admin', p_related_table => 'contact_captures', p_related_id => c.id, p_dedupe => 'capture:' || c.id);
      update contact_captures set task_id = v_task where id = c.id;
      v_tasks := v_tasks + 1;
    end loop;
  end if;

  -- 4. accounts never confirmed close their sign-in; the lead stays
  for c in select ca.user_id, u.email from capture_accounts ca join users u on u.id = ca.user_id
            where (ca.opened_by_capture or ca.sign_in_made) and ca.closed_at is null and ca.confirmed_at is null and u.email_verified_at is null
              and ca.opened_at <= p_now - make_interval(days => ps.capture_close_days) loop
    update capture_sessions set revoked_at = p_now, revoked_reason = 'Not confirmed in time' where user_id = c.user_id and revoked_at is null;
    update capture_accounts set closed_at = p_now, close_reason = 'Not confirmed within ' || ps.capture_close_days || ' days',
           continue_link_hash = null, continue_link_expires_at = null, sign_in_made = false
     where user_id = c.user_id;
    -- the sign-in account without a password and never used goes, where the database may remove it
    begin
      if to_regclass('auth.users') is not null then
        execute 'delete from auth.users where id = $1 and email_confirmed_at is null and last_sign_in_at is null' using c.user_id;
      end if;
      if to_regclass('local_auth.users') is not null then
        execute 'delete from local_auth.users where id = $1 and email_confirmed_at is null and last_sign_in_at is null' using c.user_id;
      end if;
    exception when others then
      update capture_accounts set close_reason = close_reason || '; the sign-in stays (no password, unconfirmed: only the inbox can open it)' where user_id = c.user_id;
    end;
    v_closed := v_closed + 1;
  end loop;
  delete from capture_sessions where revoked_at < p_now - interval '30 days';
  return format('emails %s, to-dos %s, closed %s, done %s', v_sent, v_tasks, v_closed, v_done);
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-capture', '4,19,34,49 * * * *', 'select app.job_capture()');
  end if;
end $$;

-- ================================================================ 7. the gate in the renter's money and signing steps
create or replace function public.renter_approve_offer(p_booking uuid, p_version integer, p_by uuid) returns void
language plpgsql security invoker set search_path = public, app as $$
begin
  perform app.capture_gate(p_by, 'accept the offer');
  perform app.assert_booking_renter(p_booking, p_by);
  perform app.approve_offer(p_booking, p_version, p_by);
end $$;

create or replace function public.server_record_booking_payment(p_booking uuid, p_processor jsonb, p_amount_cents bigint, p_offer_version integer,
                                                                p_card jsonb, p_event_id text, p_by uuid) returns jsonb
language plpgsql security invoker set search_path = public, app as $$
begin
  perform app.capture_gate(p_by, 'pay');
  return app.record_booking_payment(p_booking, p_processor, p_amount_cents, p_offer_version, p_card, p_event_id, p_by);
end $$;

create or replace function public.renter_sign_amendment(p_amendment uuid, p_by uuid, p_consent_text text, p_document_sha256 text,
    p_typed_name text default null, p_drawn_signature text default null, p_ip inet default null, p_user_agent text default null) returns jsonb
language plpgsql security invoker set search_path = public, app as $$
begin
  perform app.capture_gate(p_by, 'sign');
  return app.sign_booking_amendment(p_amendment, p_by, p_consent_text, p_document_sha256, p_typed_name, p_drawn_signature, p_ip, p_user_agent);
end $$;

alter function public.renter_sign_agreement(uuid, uuid, text, text, jsonb, text, text, inet, text) rename to renter_sign_agreement_pre0090;
alter function public.renter_sign_agreement_pre0090(uuid, uuid, text, text, jsonb, text, text, inet, text) set schema app;
create or replace function public.renter_sign_agreement(p_booking uuid, p_by uuid, p_consent_text text, p_document_sha256 text, p_consents jsonb,
                                                        p_typed_name text default null, p_drawn_signature text default null,
                                                        p_ip inet default null, p_user_agent text default null) returns uuid
language plpgsql security invoker set search_path = public, app as $$
begin
  perform app.capture_gate(p_by, 'sign');
  return app.renter_sign_agreement_pre0090(p_booking, p_by, p_consent_text, p_document_sha256, p_consents, p_typed_name, p_drawn_signature, p_ip, p_user_agent);
end $$;

alter function public.renter_register_upload(uuid, uuid, text, text, text, text, text, uuid, jsonb) rename to renter_register_upload_pre0090;
alter function public.renter_register_upload_pre0090(uuid, uuid, text, text, text, text, text, uuid, jsonb) set schema app;
create or replace function public.renter_register_upload(p_booking uuid, p_by uuid, p_kind text, p_storage_path text, p_sha256 text, p_mime_type text,
                                                         p_storage_bucket text, p_driver uuid default null, p_details jsonb default null) returns jsonb
language plpgsql security invoker set search_path = public, app as $$
begin
  perform app.capture_gate(p_by, 'upload documents');
  return app.renter_register_upload_pre0090(p_booking, p_by, p_kind, p_storage_path, p_sha256, p_mime_type, p_storage_bucket, p_driver, p_details);
end $$;

alter function public.server_confirm_extension_payment(uuid, jsonb, bigint, uuid) rename to server_confirm_extension_payment_pre0090;
alter function public.server_confirm_extension_payment_pre0090(uuid, jsonb, bigint, uuid) set schema app;
create or replace function public.server_confirm_extension_payment(p_extension uuid, p_processor jsonb, p_amount_cents bigint, p_by uuid) returns jsonb
language plpgsql security invoker set search_path = public, app as $$
begin
  perform app.capture_gate(p_by, 'pay');
  return app.server_confirm_extension_payment_pre0090(p_extension, p_processor, p_amount_cents, p_by);
end $$;

-- ================================================================ 8. staff: the renter, Live visitors, Leads, To do
alter function app.renter_live(uuid, jsonb) rename to renter_live_pre0090;
create or replace function app.renter_live(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.renter_live_pre0090(p_by, p);
  r renters;
begin
  select * into r from renters where id = (p ->> 'renter_id')::uuid;
  return v || jsonb_build_object(
    'email_confirmed', coalesce((select u.email_verified_at is not null from users u where u.id = r.user_id), false),
    'has_sign_in', r.user_id is not null,
    'captured', coalesce((select jsonb_agg(jsonb_build_object('form', app.capture_form_label(c.form), 'name', c.name, 'email', c.email, 'phone', c.phone,
                                                              'at', c.last_at, 'done', c.done_at is not null) order by c.last_at desc)
                            from contact_captures c where c.renter_id = r.id or (r.user_id is not null and c.user_id = r.user_id)), '[]'::jsonb),
    'account_opened_from_form', exists (select 1 from capture_accounts ca where ca.user_id = r.user_id and ca.opened_by_capture),
    'account_closed', exists (select 1 from capture_accounts ca where ca.user_id = r.user_id and ca.closed_at is not null));
end $$;

-- Live visitors: what each visitor typed into a form (and whether its account is confirmed).
create or replace function app.capture_for_visitor(p_visitor uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('name', c.name, 'email', c.email, 'phone', c.phone, 'form', app.capture_form_label(c.form), 'at', c.last_at,
                            'done', c.done_at is not null, 'renter_id', c.renter_id,
                            'email_confirmed', (select u.email_verified_at is not null from users u where u.id = c.user_id))
    from contact_captures c where c.visitor_id = p_visitor order by c.last_at desc limit 1
$$;

alter function app.visitor_session_row(visitor_sessions) rename to visitor_session_row_pre0090;
create or replace function app.visitor_session_row(s visitor_sessions) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.visitor_session_row_pre0090(s) || jsonb_build_object('captured', app.capture_for_visitor(s.visitor_id))
$$;

create or replace function app.captured_contacts(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_days integer := least(greatest(coalesce((p ->> 'days')::integer, 30), 1), 90);
  v_q text := nullif(btrim(coalesce(p ->> 'q', '')), '');
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'sales')) then
    raise exception 'Leads are for Admins, customer service and Sales' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'open', (select count(*) from contact_captures c where c.done_at is null and c.last_at > now() - make_interval(days => v_days)),
    'rows', coalesce((select jsonb_agg(x order by x ->> 'at' desc) from (
      select jsonb_build_object('id', c.id, 'form', app.capture_form_label(c.form), 'name', c.name, 'email', c.email, 'phone', c.phone,
               'at', c.last_at, 'first_at', c.first_at, 'done', c.done_at is not null, 'done_reason', c.done_reason, 'state', c.state,
               'renter_id', c.renter_id, 'lead_id', c.lead_id, 'task_id', c.task_id,
               'email_confirmed', (select u.email_verified_at is not null from users u where u.id = c.user_id),
               'on_site', exists (select 1 from visitor_sessions s where s.visitor_id = c.visitor_id
                                   and s.last_seen_at > now() - make_interval(mins => (app.settings()).visitor_live_minutes) and s.ended_at is null),
               'continue_sent', (select ca.continue_sent_at from capture_accounts ca where ca.user_id = c.user_id)) as x
        from contact_captures c
       where c.last_at > now() - make_interval(days => v_days)
         and (v_q is null or c.name ilike '%' || v_q || '%' or c.email ilike '%' || v_q || '%' or c.phone ilike '%' || v_q || '%')
       order by c.last_at desc limit 200) y), '[]'::jsonb));
end $$;

alter function app.admin_todo(uuid) rename to admin_todo_pre0090;
create or replace function app.admin_todo(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.admin_todo_pre0090(p_admin);
begin
  return jsonb_set(v, '{items}', coalesce(v -> 'items', '[]'::jsonb) || jsonb_build_array(
    jsonb_build_object('key', 'capture_follow_up', 'label', 'Unfinished requests to follow up', 'button', 'See them', 'href', '/admin/leads',
                       'count', (select count(*) from tasks where task_type = 'capture_follow_up' and status in ('open', 'in_progress', 'waiting')))));
end $$;

create or replace function app.ops_0090(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'captured_contacts' then return app.captured_contacts(p_user, p);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0090;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('admin_read', 'va_read') and p_name = 'captured_contacts' then
    perform app.door_begin(p_user, p_aal);
    return app.ops_0090(p_user, p_call, p_name, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre0090(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 9. the email: recipients and values
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre0090;
create or replace function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_c.code = 'renter_continue_request' then
    return query select 'renter'::text, u.id, u.email, u.full_name, (select r.id from renters r where r.user_id = u.id), null::uuid, true
                   from users u where u.id = (p_event.payload ->> 'user_id')::uuid;
    return;
  end if;
  return query select * from app.notification_recipients_pre0090(p_event, p_c);
end $$;

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0090;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0090(p_code, p_event, p_to);
begin
  if p_code = 'renter_continue_request' then
    x := x || jsonb_build_object(
      'first_name', coalesce(p_event.payload ->> 'first_name', 'there'),
      'continue_url', p_event.payload ->> 'continue_url',
      'started_what', coalesce(p_event.payload ->> 'started_what', 'a request'),
      'new_account', coalesce((p_event.payload ->> 'new_account')::boolean, false),
      'link_expiry', coalesce(p_event.payload ->> 'link_expiry', '72 hours'));
  end if;
  return x;
end $$;

-- CATALOGUE 0090 START (generated by supabase/seed/0090_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_continue_request', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Continue your request', 'One tap signs you in and confirms your email. The link works for {{link_expiry}}.', 'Some minutes after a form was left unfinished (new account), or at once (an existing account)', 'Contact capture (migration 0090): someone typed their email into a booking request, a contact form, the owner application, the discount game or the live chat. One email per account, ever. A new account opened for that address: sent by the capture job (every 15 minutes) capture_continue_minutes (30) after they stopped typing without sending the form, only within the hours set for booking recovery emails. An address that already has an account: sent at once, as the sign-in link the site says it sent. The button opens /continue, which signs the person in and confirms the email in one step and lands on their draft or request. Transactional: it is about the account opened in their name; never with offers.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"continue_url","type":"url"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"link_expiry","type":"string"},{"name":"new_account","type":"boolean"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"started_what","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_continue_request.html', 'templates/renter_continue_request.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0090 END
update notification_catalogue set emitted_by = 'app.capture_send_continue (0090): app.capture_contact and app.job_capture' where code = 'renter_continue_request';

-- ================================================================ 10. the privacy policy (section 1, one row)
update site_content_blocks
   set body = replace(body,
     '| Discount games: your first name, email, mobile number if given, the code and the pages and cars you viewed in that visit | To send the code and a reminder, and to help you book; offers only with your consent |',
     '| Discount games: your first name, email, mobile number if given, the code and the pages and cars you viewed in that visit | To send the code and a reminder, and to help you book; offers only with your consent |
| Forms you start: the name, email and mobile number you type into our forms, saved as you type even if you do not send the form | To open an account in your name so you can continue your request, and to send you one email with a link to continue; never for offers without your consent |')
 where block_key = 'legal.privacy' and body like '%| Discount games: your first name%' and body not like '%| Forms you start:%';
update site_content_blocks set data = data || jsonb_build_object('last_updated', 'October 21, 2026')
 where block_key = 'legal.meta' and (data ->> 'last_updated') in ('October 8, 2026', 'October 16, 2026', 'October 19, 2026', 'October 20, 2026');

-- ================================================================ 11. the server's calls (service role only)
create or replace function public.server_capture_contact(p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.capture_contact(p) $$;
create or replace function public.server_capture_sign_in_made(p_user uuid) returns void
language sql volatile security invoker set search_path = public, app as $$ select app.capture_sign_in_made(p_user) $$;
create or replace function public.server_capture_done(p jsonb) returns integer
language sql volatile security invoker set search_path = public, app as $$ select app.capture_done(p) $$;
create or replace function public.server_capture_session_read(p_token text, p_visitor uuid default null) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.capture_session_read(p_token, p_visitor) $$;
create or replace function public.server_capture_session_add_booking(p_token text, p_number text) returns boolean
language sql volatile security invoker set search_path = public, app as $$ select app.capture_session_add_booking(p_token, p_number) $$;
create or replace function public.server_capture_session_end(p_token text) returns void
language sql volatile security invoker set search_path = public, app as $$ select app.capture_session_end(p_token) $$;
create or replace function public.server_capture_continue_open(p_token text) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.capture_continue_open(p_token) $$;
create or replace function public.server_capture_unconfirmed(p_user uuid) returns boolean
language sql stable security invoker set search_path = public, app as $$ select app.capture_unconfirmed(p_user) $$;

-- ================================================================ 12. row-level security and privileges
alter table capture_accounts enable row level security;
alter table capture_sessions enable row level security;
alter table capture_session_items enable row level security;
alter table contact_captures enable row level security;
create policy admin_read on capture_accounts for select to authenticated using (app.is_admin());
create policy admin_read on contact_captures for select to authenticated using (app.is_admin());
create policy staff_read on contact_captures for select to authenticated using (app.va_has('cs', 'sales'));
revoke all on capture_accounts, capture_sessions, capture_session_items, contact_captures from public, anon, authenticated;
grant select on capture_accounts, contact_captures to authenticated;
grant select, insert, update, delete on capture_accounts, capture_sessions, capture_session_items, contact_captures to service_role;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and (p.proname like '%\_pre0090' or p.proname = any (array[
              'capture_clean_email', 'capture_clean_phone', 'capture_clean_name', 'capture_sign_in_exists', 'capture_brand_new', 'capture_session_of',
              'capture_unconfirmed', 'capture_gate', 'capture_form_label', 'capture_next', 'capture_new_link', 'capture_send_continue', 'capture_contact',
              'capture_sign_in_made', 'capture_done', 'capture_session_read', 'capture_session_add_booking', 'capture_session_end', 'capture_continue_open',
              'capture_users_confirmed', 'capture_draft_submitted', 'capture_game_claimed', 'capture_chat_contact', 'job_capture', 'renter_live',
              'capture_for_visitor', 'visitor_session_row', 'captured_contacts', 'admin_todo', 'ops_0090', 'door', 'notification_recipients',
              'notification_payload'])))
        or (n.nspname = 'public' and p.proname = any (array[
              'server_capture_contact', 'server_capture_sign_in_made', 'server_capture_done', 'server_capture_session_read',
              'server_capture_session_add_booking', 'server_capture_session_end', 'server_capture_continue_open', 'server_capture_unconfirmed',
              'renter_approve_offer', 'server_record_booking_payment', 'renter_sign_amendment', 'renter_sign_agreement', 'renter_register_upload',
              'server_confirm_extension_payment']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- GUIDES 0090 START (generated by supabase/seed/0090_gen_guides.mjs from docs/guides/content; do not edit by hand)
-- GUIDES 0090 END
