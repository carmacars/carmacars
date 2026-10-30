-- 0190_quo_contacts_visitor_names.sql
-- Quo contacts that match the site, and names for live visitors (docs/changes/2026-10-27-quo-contacts-visitor-names.md).
-- The owner: "The contacts on Quo should be saved to match the contacts saved on the website." And: "We should be able to
-- name the live visitors if we learn their name."
--
-- 1. Quo contacts. Every person the site knows with a phone number (staff, renters, drivers, owners, partners, investors,
--    referral partners, job applicants, named visitors, leads, chauffeur clients, live chats, discount game claims, forms
--    left unfinished, accounts) is a contact in the CarmaCars Quo workspace, under the same name, with their email and
--    company when known. One contact per phone number (quo_contacts, keyed by the E.164 number): when several records
--    share a number, the strongest wins (staff, then a renter, a driver, an owner, ... see app.quo_people_v), the newest
--    within a kind.
--    - A change (insert, or a change of the name, phone or email) only marks the number (app.quo_contact_mark): the
--      Worker's five-minute job does the calls to Quo (public.server_jobs_due "phone" is also true while a number waits),
--      so a Quo outage never blocks a booking. Retries back off from 5 minutes to a day; Quo's 400s wait for the next
--      change or Sync everyone again.
--    - Duplicates: the job first reads Quo's whole contact list once (a few pages a run) and takes over the contact that
--      already has the number; a new contact carries externalId "cc-<digits>", which is looked up before creating, so a
--      lost answer never makes a second one. The Quo id is kept here; later changes patch that contact (its other
--      numbers and emails are kept).
--    - No new secret: QUO_PROVIDER and QUO_API_KEY of 0085. Without the key the job records "QUO_API_KEY is not set" and
--      pauses for 6 hours (Settings > Quo contacts shows it).
--    - Everyone already on the site is marked once here (the backfill). Settings > Quo contacts: the counts, the last run,
--      the last error and Sync everyone again. Program setting phone_quo_contacts (on by default).
-- 2. Names for live visitors. Staff (Admins, customer service, Sales) name a visitor on Live visitors (Name: the name,
--    and optionally a phone, an email and a note). The name is kept for the browser (visitor_names, by visitor id), so it
--    shows on Live visitors, the visit's pages, Visitor history, Live chat and on later visits. It is staff-only: the
--    visitor never sees it (the chat's greeting keeps using what they told us).
--    - Kept consistent: a named visitor who books or signs in (or a renter with the same email or phone) takes the
--      renter's name; a chat from another browser with the same email or phone gets the same name; a chat's email or
--      phone fills in the label's when it had none. A caller with the phone shows by that name in Texts and calls.
--    - A phone on the label makes a Quo contact (part 1).
-- 3. The privacy policy: one sentence (our contact list in the phone provider).
-- No applied migration is edited. app.door (0177), app.server_jobs_due (0167), app.visitor_who (0060),
-- app.visitor_chat_name (0088), app.visitor_session_row (0090) and app.phone_match (0085) are wrapped here.

-- ================================================================ 1. the setting and the tables
alter table program_settings add column if not exists phone_quo_contacts boolean not null default true;
comment on column program_settings.phone_quo_contacts is 'Phone and texts (0190): keep a Quo contact for every person on the site with a phone number (same name, email and company), created and updated by the five-minute job. Settings > Quo contacts shows the sync.';

create table if not exists quo_contacts (
  number        text primary key check (number ~ '^\+[1-9][0-9]{7,14}$'),
  quo_id        text,                                   -- the Quo contact (from the create, or found in Quo's list)
  state         text not null default 'pending' check (state in ('pending', 'synced', 'error', 'skipped')),
  first_name    text,                                   -- what Quo was last sent
  last_name     text,
  email         text,
  company       text,
  role          text,
  source_kind   text,
  source_id     uuid,
  synced_hash   text,
  synced_at     timestamptz,
  dirty_at      timestamptz,                            -- a change waiting for the job (null: up to date)
  next_try_at   timestamptz not null default now(),
  leased_until  timestamptz,                            -- a job run holds it
  attempts      integer not null default 0 check (attempts >= 0),
  last_error    text,
  last_error_at timestamptz,
  note          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists quo_contacts_due_idx on quo_contacts (next_try_at) where dirty_at is not null;
create index if not exists quo_contacts_quo_idx on quo_contacts (quo_id) where quo_id is not null;
create trigger quo_contacts_updated before update on quo_contacts for each row execute function app.set_updated_at();
comment on table quo_contacts is 'Quo contacts (0190): one row per phone number of a person on the site, with the Quo contact id and what was last sent. Written by triggers (marked) and the five-minute job.';

create table if not exists quo_contacts_state (
  singleton      boolean primary key default true check (singleton),
  scan_status    text not null default 'pending' check (scan_status in ('pending', 'done')),
  scan_cursor    text,
  scan_seen      integer not null default 0,
  scan_matched   integer not null default 0,
  scan_done_at   timestamptz,
  last_run_at    timestamptz,
  last_ok_at     timestamptz,
  last_result    jsonb,
  last_error     text,
  last_error_at  timestamptz,
  paused_until   timestamptz,
  pause_reason   text
);
insert into quo_contacts_state (singleton) values (true) on conflict do nothing;
comment on table quo_contacts_state is 'Quo contacts (0190): the job''s state: the one-time read of Quo''s contact list (to take over contacts that already have a number), the last run and its error, a pause (no API key).';

create table if not exists visitor_names (
  visitor_id  uuid primary key,                         -- the browser (cookie cc_vid), as visitor_sessions.visitor_id
  name        text not null check (length(btrim(name)) between 1 and 120),
  phone       text check (phone is null or phone ~ '^\+[1-9][0-9]{7,14}$'),
  email       text check (email is null or (length(email) <= 254 and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
  note        text check (note is null or length(note) <= 500),
  source      text not null default 'staff' check (source in ('staff', 'match', 'renter')),
  renter_id   uuid references renters (id) on delete set null,
  set_by      uuid references users (id) on delete set null,
  set_at      timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists visitor_names_email_idx on visitor_names (lower(email)) where email is not null;
create index if not exists visitor_names_phone_idx on visitor_names (phone) where phone is not null;
create trigger visitor_names_updated before update on visitor_names for each row execute function app.set_updated_at();
create trigger audit_visitor_names after insert or update or delete on visitor_names for each row execute function app.audit_row();
comment on table visitor_names is 'Live visitors (0190): the name staff gave a visitor (with an optional phone, email and note), for every visit of that browser. Shown to staff only.';

alter table quo_contacts enable row level security;
alter table quo_contacts_state enable row level security;
alter table visitor_names enable row level security;
create policy admin_all on quo_contacts for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on quo_contacts_state for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on visitor_names for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on quo_contacts, quo_contacts_state, visitor_names from public, anon, authenticated;
grant all on quo_contacts, quo_contacts_state, visitor_names to service_role;

-- ================================================================ 2. who has a number
-- Everyone the site knows with a phone, as Quo should know them. rank: the strongest record of a number wins.
create or replace view app.quo_people_v as
  select app.phone_e164(u.phone) as n, 1 as rank, 'staff'::text as kind, u.id as ref_id, u.full_name as name, u.email::text as email,
         'CarmaCars'::text as company, 'CarmaCars staff'::text as role, u.updated_at as at
    from users u
   where u.phone is not null and u.status = 'active'
     and exists (select 1 from user_roles r where r.user_id = u.id and r.role in ('admin', 'va', 'field'))
  union all
  select app.phone_e164(r.mobile), 2, 'renter', r.id, r.legal_name, r.email::text, null, 'Renter', r.updated_at
    from renters r where r.mobile is not null and r.merged_into is null
  union all
  select app.phone_e164(d.mobile), 3, 'driver', d.id, d.full_name, d.email::text, null, 'Driver', d.updated_at
    from drivers d where d.mobile is not null
  union all
  select app.phone_e164(o.phone), 4, 'owner', o.id, coalesce(nullif(btrim(concat_ws(' ', o.first_name, o.last_name)), ''), o.legal_name),
         o.email::text, o.corporation_name, 'Owner', o.updated_at
    from owners o where o.phone is not null and not coalesce(o.is_test, false)
  union all
  select app.phone_e164(p.phone), 5, 'partner', p.id, coalesce(nullif(btrim(p.contact_name), ''), p.legal_name, p.business_name), p.email::text,
         p.business_name, 'Partner', p.updated_at
    from partners p where p.phone is not null
  union all
  select app.phone_e164(i.phone), 6, 'investor', i.id, i.legal_name, i.email::text, null, 'Investor', i.updated_at
    from investors i where i.phone is not null
  union all
  select app.phone_e164(x.phone), 7, 'referral_partner', x.id, coalesce(nullif(btrim(x.contact_name), ''), x.business_name), x.email::text,
         x.business_name, 'Referral partner', x.updated_at
    from referral_partners x where x.phone is not null
  union all
  select app.phone_e164(j.phone), 8, 'applicant', j.id, j.full_name, j.email::text, null, 'Job applicant', j.updated_at
    from job_applications j where j.phone is not null and j.purged_at is null
  union all
  select v.phone, 9, 'visitor', v.visitor_id, v.name, v.email, null, 'Website visitor', v.updated_at
    from visitor_names v where v.phone is not null
  union all
  select app.phone_e164(l.phone), 10, 'lead', l.id, l.name, l.email::text, l.business_name, 'Lead', l.updated_at
    from leads l where l.phone is not null
  union all
  select app.phone_e164(c.phone), 11, 'chauffeur', c.id, c.name, c.email::text, null, 'Chauffeur client', c.updated_at
    from chauffeur_requests c where c.phone is not null
  union all
  select app.phone_e164(c.phone), 12, 'chat', c.id, c.name, c.email::text, null, 'Live chat', coalesce(c.last_message_at, c.created_at)
    from chat_conversations c where c.phone is not null
  union all
  select app.phone_e164(g.phone), 13, 'game', g.id, g.first_name, g.email::text, null, 'Discount game', g.created_at
    from game_claims g where g.phone is not null
  union all
  select app.phone_e164(c.phone), 14, 'form', c.id, c.name, c.email::text, null, 'Website form', c.last_at
    from contact_captures c where c.phone is not null
  union all
  select app.phone_e164(u.phone), 15, 'account', u.id, u.full_name, u.email::text, null, 'Customer account', u.updated_at
    from users u where u.phone is not null and u.status = 'active';
comment on view app.quo_people_v is 'Quo contacts (0190): every person on the site with a phone number, as Quo should know them; rank 1 (staff) is the strongest.';

create or replace function app.quo_clean(p text, p_max integer) returns text
language sql immutable as $$ select nullif(left(btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g')), p_max), '') $$;

create or replace function app.quo_email(p text) returns text
language sql immutable as $$
  select case when x ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' and length(x) <= 254 then x end
    from (select lower(btrim(coalesce(p, ''))) as x) y
$$;

-- What Quo should hold for a number: the strongest record with a name, its email (or the first email of any record of the
-- number) and its company. Null: nobody with a name has this number (or it is the CarmaCars number itself).
create or replace function app.quo_person(p_number text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_n text := app.phone_e164(p_number);
  b record;
  v_name text;
  v_first text;
  v_last text;
  v_email text;
  v_company text;
begin
  if v_n is null or v_n = app.phone_our_number() then return null; end if;
  select * into b from app.quo_people_v q where q.n = v_n and app.quo_clean(q.name, 120) is not null order by q.rank, q.at desc nulls last limit 1;
  if b.kind is null then return null; end if;
  v_name := app.quo_clean(b.name, 120);
  v_first := split_part(v_name, ' ', 1);
  v_last := app.quo_clean(substr(v_name, length(v_first) + 1), 80);
  v_email := coalesce(app.quo_email(b.email),
    (select app.quo_email(q.email) from app.quo_people_v q where q.n = v_n and app.quo_email(q.email) is not null order by q.rank, q.at desc nulls last limit 1));
  v_company := coalesce(app.quo_clean(b.company, 120),
    (select app.quo_clean(q.company, 120) from app.quo_people_v q where q.n = v_n and q.rank = b.rank and app.quo_clean(q.company, 120) is not null order by q.at desc nulls last limit 1));
  return jsonb_build_object('number', v_n, 'kind', b.kind, 'ref_id', b.ref_id, 'first_name', left(v_first, 80), 'last_name', v_last,
    'email', v_email, 'company', v_company, 'role', b.role);
end $$;

create or replace function app.quo_hash(p jsonb) returns text
language sql immutable as $$
  select md5(concat_ws('|', p ->> 'number', p ->> 'first_name', p ->> 'last_name', p ->> 'email', p ->> 'company', p ->> 'role'))
$$;

-- ================================================================ 3. marking a number when a person changes
create or replace function app.quo_contact_mark(p_number text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  n text := app.phone_e164(p_number);
begin
  if n is null then return; end if;
  insert into quo_contacts (number, dirty_at, next_try_at) values (n, now(), now())
  on conflict (number) do update set dirty_at = now(), next_try_at = now(), attempts = 0;
end $$;

-- A trigger for any table with a phone: TG_ARGV[0] is the phone column, the rest the columns Quo shows (name, email,
-- company). An update that changes none of them marks nothing. A changed phone marks the old number too.
create or replace function app.quo_contact_touch() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  j_new jsonb;
  j_old jsonb;
  n_new text;
  n_old text;
  i integer;
  v_changed boolean := false;
begin
  if tg_op in ('INSERT', 'UPDATE') then j_new := to_jsonb(new); n_new := app.phone_e164(j_new ->> tg_argv[0]); end if;
  if tg_op in ('UPDATE', 'DELETE') then j_old := to_jsonb(old); n_old := app.phone_e164(j_old ->> tg_argv[0]); end if;
  if tg_op = 'UPDATE' then
    for i in 0 .. tg_nargs - 1 loop
      if (j_new -> tg_argv[i]) is distinct from (j_old -> tg_argv[i]) then v_changed := true; exit; end if;
    end loop;
    if not v_changed then return null; end if;
  end if;
  if n_new is not null then perform app.quo_contact_mark(n_new); end if;
  if n_old is not null and n_old is distinct from n_new then perform app.quo_contact_mark(n_old); end if;
  return null;
end $$;

-- a staff role given or taken changes the strongest record of the person's number
create or replace function app.quo_contact_role_touch() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.quo_contact_mark(u.phone) from users u where u.id = coalesce(new.user_id, old.user_id) and u.phone is not null;
  return null;
end $$;

do $$
declare
  t record;
begin
  for t in select * from (values
      ('users', 'phone', array['full_name', 'email', 'status']),
      ('renters', 'mobile', array['legal_name', 'email', 'merged_into']),
      ('drivers', 'mobile', array['full_name', 'email']),
      ('owners', 'phone', array['legal_name', 'first_name', 'last_name', 'corporation_name', 'email', 'is_test']),
      ('partners', 'phone', array['contact_name', 'legal_name', 'business_name', 'email']),
      ('investors', 'phone', array['legal_name', 'email']),
      ('referral_partners', 'phone', array['contact_name', 'business_name', 'email']),
      ('job_applications', 'phone', array['full_name', 'email', 'purged_at']),
      ('visitor_names', 'phone', array['name', 'email']),
      ('leads', 'phone', array['name', 'email', 'business_name']),
      ('chauffeur_requests', 'phone', array['name', 'email']),
      ('chat_conversations', 'phone', array['name', 'email']),
      ('game_claims', 'phone', array['first_name', 'email']),
      ('contact_captures', 'phone', array['name', 'email'])) x(tbl, col, cols)
  loop
    execute format('create trigger quo_contact_touch after insert or update of %s or delete on %I for each row execute function app.quo_contact_touch(%s)',
      array_to_string(array(select quote_ident(c) from unnest(t.col || t.cols) c), ', '), t.tbl,
      array_to_string(array(select quote_literal(c) from unnest(t.col || t.cols) c), ', '));
  end loop;
end $$;
create trigger quo_contact_touch after insert or delete on user_roles for each row execute function app.quo_contact_role_touch();

-- ================================================================ 4. the job (the Worker's five-minute phone job)
-- Anything for the job: a number waiting (not leased), unless the sync is off or paused.
create or replace function app.quo_contacts_due_any() returns boolean
language sql stable security definer set search_path = public, app as $$
  select (app.settings()).phone_quo_contacts
     and coalesce((select s.paused_until is null or s.paused_until <= now() from quo_contacts_state s), true)
     and exists (select 1 from quo_contacts q where q.dirty_at is not null and q.next_try_at <= now() and (q.leased_until is null or q.leased_until < now()))
$$;

-- The next numbers to send. A number nobody with a name has is set aside ("skipped"); one already up to date in Quo is
-- closed without a call; a new contact waits until Quo's own list was read (so a contact Quo already has is taken over).
-- Each number given out is leased for 10 minutes.
create or replace function app.server_quo_contacts_due(p_limit integer default 40) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  st quo_contacts_state;
  q quo_contacts;
  v_person jsonb;
  v_hash text;
  v_rows jsonb := '[]'::jsonb;
  v_waiting integer := 0;
begin
  select * into st from quo_contacts_state where singleton;
  if not (app.settings()).phone_quo_contacts then return jsonb_build_object('enabled', false, 'rows', '[]'::jsonb, 'scan', jsonb_build_object('needed', false)); end if;
  if st.paused_until is not null and st.paused_until > now() then
    return jsonb_build_object('enabled', true, 'paused', true, 'rows', '[]'::jsonb, 'scan', jsonb_build_object('needed', false));
  end if;
  for q in select * from quo_contacts where dirty_at is not null and next_try_at <= now() and (leased_until is null or leased_until < now())
            order by next_try_at, number limit greatest(1, least(coalesce(p_limit, 40), 200)) * 3 for update skip locked loop
    exit when jsonb_array_length(v_rows) >= greatest(1, least(coalesce(p_limit, 40), 200));
    v_person := app.quo_person(q.number);
    if v_person is null then
      update quo_contacts set state = 'skipped', dirty_at = null, note = 'Nobody on the site with a name has this number', attempts = 0 where number = q.number;
      continue;
    end if;
    v_hash := app.quo_hash(v_person);
    if q.quo_id is not null and q.synced_hash = v_hash then
      update quo_contacts set state = 'synced', dirty_at = null, note = null, attempts = 0 where number = q.number;
      continue;
    end if;
    if q.quo_id is null and st.scan_status <> 'done' then v_waiting := v_waiting + 1; continue; end if;
    update quo_contacts set leased_until = now() + interval '10 minutes' where number = q.number;
    v_rows := v_rows || jsonb_build_object('number', q.number, 'quo_id', q.quo_id, 'hash', v_hash, 'dirty_at', q.dirty_at,
      'external_id', 'cc-' || substr(q.number, 2), 'person', v_person);
  end loop;
  return jsonb_build_object('enabled', true, 'rows', v_rows, 'waiting_for_scan', v_waiting,
    'scan', jsonb_build_object('needed', st.scan_status <> 'done', 'cursor', st.scan_cursor));
end $$;

-- What the job did with one number. p: {number, ok, quo_id, hash, dirty_at (as given out), error, permanent, person}
create or replace function app.server_quo_contact_done(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  n text := app.phone_e164(p ->> 'number');
  q quo_contacts;
  v_seen timestamptz := nullif(p ->> 'dirty_at', '')::timestamptz;
  v_person jsonb := coalesce(p -> 'person', '{}'::jsonb);
begin
  select * into q from quo_contacts where number = n for update;
  if q.number is null then return jsonb_build_object('ok', false, 'error', 'unknown number'); end if;
  if coalesce((p ->> 'ok')::boolean, false) then
    update quo_contacts set quo_id = coalesce(nullif(p ->> 'quo_id', ''), quo_id), state = 'synced', synced_hash = p ->> 'hash', synced_at = now(),
           first_name = v_person ->> 'first_name', last_name = v_person ->> 'last_name', email = v_person ->> 'email', company = v_person ->> 'company',
           role = v_person ->> 'role', source_kind = v_person ->> 'kind', source_id = nullif(v_person ->> 'ref_id', '')::uuid,
           attempts = 0, last_error = null, note = null, leased_until = null,
           -- a change made while the job was calling Quo is sent next time
           dirty_at = case when dirty_at is not null and (v_seen is null or dirty_at > v_seen) then dirty_at end,
           next_try_at = now()
     where number = n;
  else
    update quo_contacts set state = 'error', attempts = attempts + 1, last_error = left(coalesce(p ->> 'error', 'Quo refused it'), 300), last_error_at = now(),
           leased_until = null,
           quo_id = case when coalesce((p ->> 'gone')::boolean, false) then null else quo_id end,
           -- a refusal that will not get better waits for the next change (or Sync everyone again)
           dirty_at = case when coalesce((p ->> 'permanent')::boolean, false) then null else dirty_at end,
           next_try_at = now() + least(interval '5 minutes' * power(2, least(attempts, 10)), interval '24 hours')
     where number = n;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- A page of Quo's own contact list (the one-time read): a contact with the number of someone on the site becomes theirs.
-- p: {contacts: [{id, phones: [...]}], cursor (the next page, null at the end), done}
create or replace function app.server_quo_contacts_found(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c jsonb;
  ph text;
  v_seen integer := 0;
  v_matched integer := 0;
  v_rows integer;
begin
  for c in select * from jsonb_array_elements(coalesce(p -> 'contacts', '[]'::jsonb)) loop
    v_seen := v_seen + 1;
    for ph in select app.phone_e164(x) from jsonb_array_elements_text(coalesce(c -> 'phones', '[]'::jsonb)) x loop
      continue when ph is null or nullif(c ->> 'id', '') is null;
      update quo_contacts set quo_id = c ->> 'id', dirty_at = coalesce(dirty_at, now()), next_try_at = least(next_try_at, now())
       where number = ph and quo_id is null;
      get diagnostics v_rows = row_count;
      v_matched := v_matched + v_rows;
    end loop;
  end loop;
  update quo_contacts_state set scan_cursor = nullif(p ->> 'cursor', ''), scan_seen = scan_seen + v_seen, scan_matched = scan_matched + v_matched,
         scan_status = case when coalesce((p ->> 'done')::boolean, false) then 'done' else scan_status end,
         scan_done_at = case when coalesce((p ->> 'done')::boolean, false) then now() else scan_done_at end;
  return jsonb_build_object('seen', v_seen, 'matched', v_matched);
end $$;

-- The end of a run. p: {ok, created, updated, failed, scanned, error, paused_reason, rate_limited}
create or replace function app.server_quo_contacts_run(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_pause text := nullif(p ->> 'paused_reason', '');
  v_error text := nullif(p ->> 'error', '');
begin
  update quo_contacts_state set last_run_at = now(), last_result = p - 'paused_reason',
         last_ok_at = case when v_pause is null and v_error is null then now() else last_ok_at end,
         last_error = coalesce(left(v_pause, 300), left(v_error, 300), last_error),
         last_error_at = case when v_pause is not null or v_error is not null then now() else last_error_at end,
         paused_until = case when v_pause is not null then now() + interval '6 hours'
                             when coalesce((p ->> 'rate_limited')::boolean, false) then now() + interval '1 minute' else null end,
         pause_reason = case when v_pause is not null then left(v_pause, 300)
                             when coalesce((p ->> 'rate_limited')::boolean, false) then 'Quo asked us to slow down' end;
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ 5. Settings > Quo contacts
create or replace function app.quo_contacts_status() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'enabled', (app.settings()).phone_quo_contacts,
    'synced', (select count(*) from quo_contacts where state = 'synced' and dirty_at is null),
    'waiting', (select count(*) from quo_contacts where dirty_at is not null and state <> 'error'),
    'errors', (select count(*) from quo_contacts where state = 'error'),
    'no_name', (select count(*) from quo_contacts where state = 'skipped'),
    'total', (select count(*) from quo_contacts),
    'last_run_at', s.last_run_at, 'last_ok_at', s.last_ok_at, 'last_result', s.last_result,
    'last_error', s.last_error, 'last_error_at', s.last_error_at,
    'paused_until', case when s.paused_until > now() then s.paused_until end, 'pause_reason', case when s.paused_until > now() then s.pause_reason end,
    'scan', jsonb_build_object('status', s.scan_status, 'seen', s.scan_seen, 'matched', s.scan_matched, 'done_at', s.scan_done_at),
    'recent_errors', coalesce((select jsonb_agg(x order by x ->> 'at' desc) from (
        select jsonb_build_object('number', q.number, 'name', coalesce(nullif(concat_ws(' ', q.first_name, q.last_name), ''), app.quo_person(q.number) ->> 'first_name'),
                 'error', q.last_error, 'at', q.last_error_at, 'attempts', q.attempts, 'retry_at', case when q.dirty_at is not null then q.next_try_at end) as x
          from quo_contacts q where q.state = 'error' order by q.last_error_at desc nulls last limit 10) y), '[]'::jsonb))
  from quo_contacts_state s where s.singleton
$$;

-- Sync everyone again: every person with a number is sent again, and Quo's list is read again first.
create or replace function app.quo_contacts_resync(p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v integer;
begin
  insert into quo_contacts (number, dirty_at, next_try_at)
  select distinct q.n, now(), now() from app.quo_people_v q where q.n is not null and app.quo_clean(q.name, 120) is not null
  on conflict (number) do nothing;
  update quo_contacts set dirty_at = now(), next_try_at = now(), attempts = 0, synced_hash = null, leased_until = null;
  get diagnostics v = row_count;
  update quo_contacts_state set scan_status = 'pending', scan_cursor = null, scan_seen = 0, scan_matched = 0, scan_done_at = null,
         paused_until = null, pause_reason = null;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'quo_contacts_resync', 'quo_contacts', null, jsonb_build_object('numbers', v));
  return jsonb_build_object('numbers', v);
end $$;

-- ================================================================ 6. names for live visitors
create or replace function app.visitor_label(p_visitor uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('name', v.name, 'phone', v.phone, 'email', v.email, 'note', v.note, 'source', v.source,
           'by', (select split_part(u.full_name, ' ', 1) from users u where u.id = v.set_by), 'at', v.set_at)
    from visitor_names v where v.visitor_id = p_visitor
$$;

-- Staff name a visitor (or change or remove the name). p: {session_id | visitor_id, name, phone, email, note, remove}
create or replace function app.visitor_name_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_visitor uuid;
  v_name text := app.quo_clean(p ->> 'name', 200);
  v_phone text := nullif(btrim(coalesce(p ->> 'phone', '')), '');
  v_email text := nullif(btrim(coalesce(p ->> 'email', '')), '');
  v_note text := app.quo_clean(p ->> 'note', 1000);
begin
  perform app.assert_live_staff(p_by);
  v_visitor := coalesce(nullif(p ->> 'visitor_id', '')::uuid, (select s.visitor_id from visitor_sessions s where s.id = nullif(p ->> 'session_id', '')::uuid));
  if v_visitor is null or not exists (select 1 from visitor_sessions s where s.visitor_id = v_visitor) then
    raise exception 'That visit is no longer kept' using errcode = 'P0002';
  end if;
  if coalesce((p ->> 'remove')::boolean, false) then
    delete from visitor_names where visitor_id = v_visitor;
    return jsonb_build_object('removed', true, 'label', null);
  end if;
  if v_name is null then raise exception 'Type the visitor''s name' using errcode = '22023'; end if;
  if length(v_name) > 120 then raise exception 'The name is too long (120 characters at most)' using errcode = '22023'; end if;
  if v_phone is not null then
    if app.phone_e164(v_phone) is null then raise exception 'That phone number does not look right' using errcode = '22023'; end if;
    v_phone := app.phone_e164(v_phone);
  end if;
  if v_email is not null then
    if app.quo_email(v_email) is null then raise exception 'That email address does not look right' using errcode = '22023'; end if;
    v_email := app.quo_email(v_email);
  end if;
  if length(v_note) > 500 then raise exception 'The note is too long (500 characters at most)' using errcode = '22023'; end if;
  insert into visitor_names (visitor_id, name, phone, email, note, source, set_by, set_at)
  values (v_visitor, v_name, v_phone, v_email, v_note, 'staff', p_by, now())
  on conflict (visitor_id) do update set name = excluded.name, phone = excluded.phone, email = excluded.email, note = excluded.note,
         source = 'staff', set_by = p_by, set_at = now();
  return jsonb_build_object('removed', false, 'label', app.visitor_label(v_visitor), 'who', v_name);
end $$;

-- the name staff gave comes first wherever a visitor is shown to staff
alter function app.visitor_who(visitor_sessions) rename to visitor_who_pre0190;
create or replace function app.visitor_who(s visitor_sessions) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce((select v.name from visitor_names v where v.visitor_id = s.visitor_id), app.visitor_who_pre0190(s))
$$;

alter function app.visitor_chat_name(chat_conversations) rename to visitor_chat_name_pre0190;
create or replace function app.visitor_chat_name(c chat_conversations) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce((select v.name from visitor_names v where v.visitor_id = c.visitor_id), app.visitor_chat_name_pre0190(c))
$$;

alter function app.visitor_session_row(visitor_sessions) rename to visitor_session_row_pre0190;
create or replace function app.visitor_session_row(s visitor_sessions) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select r || jsonb_build_object('label', l, 'known', coalesce((r ->> 'known')::boolean, false) or l is not null)
    from (select app.visitor_session_row_pre0190(s) as r, app.visitor_label(s.visitor_id) as l) x
$$;

-- a caller or texter with a named visitor's phone shows by that name in Texts and calls. The thread is linked to the
-- visit only when a record of the site names the number: app.phone_thread_for gives a linked visit the thread's name as
-- the visit's own name (which the chat greeting uses), and the name staff gave is never shown to the visitor.
alter function app.phone_match(text) rename to phone_match_pre0190;
create or replace function app.phone_match(p_number text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  m jsonb := app.phone_match_pre0190(p_number);
  v visitor_names;
begin
  select * into v from visitor_names where phone = app.phone_e164(p_number) order by updated_at desc limit 1;
  if v.visitor_id is null then return m; end if;
  if nullif(m ->> 'name', '') is null then return m || jsonb_build_object('name', v.name); end if;
  if nullif(m ->> 'visitor_id', '') is null and (app.settings()).phone_link_visitors then m := m || jsonb_build_object('visitor_id', v.visitor_id); end if;
  return m;
end $$;

-- Kept consistent: a named visitor who books or signs in takes the renter's name (the name the site has saved).
create or replace function app.visitor_names_on_session() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.renter_id is not null and (tg_op = 'INSERT' or old.renter_id is distinct from new.renter_id) then
    update visitor_names v
       set name = coalesce(app.quo_clean(r.legal_name, 120), v.name), renter_id = r.id, source = 'renter',
           email = coalesce(v.email, app.quo_email(r.email)), phone = coalesce(v.phone, app.phone_e164(r.mobile))
      from renters r
     where v.visitor_id = new.visitor_id and r.id = new.renter_id
       and (v.renter_id is distinct from r.id or v.name is distinct from coalesce(app.quo_clean(r.legal_name, 120), v.name));
  end if;
  return null;
end $$;
create trigger visitor_names_on_session after insert or update of renter_id on visitor_sessions for each row execute function app.visitor_names_on_session();

-- ... and a renter whose email or phone is a named visitor's (or whose name changed) gives that name to the label
create or replace function app.visitor_names_on_renter() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_name text := app.quo_clean(new.legal_name, 120);
begin
  if v_name is null or new.merged_into is not null then return null; end if;
  update visitor_names v set name = v_name, renter_id = new.id, source = 'renter'
   where (v.renter_id = new.id
          or (v.email is not null and v.email = app.quo_email(new.email))
          or (v.phone is not null and v.phone = app.phone_e164(new.mobile)))
     and (v.name is distinct from v_name or v.renter_id is distinct from new.id);
  return null;
end $$;
create trigger visitor_names_on_renter after insert or update of legal_name, email, mobile, merged_into on renters for each row execute function app.visitor_names_on_renter();

-- ... and a chat: one from another browser with a named visitor's email or phone gets the same name; one from the named
-- browser fills in the label's missing phone or email (which then reaches Quo)
create or replace function app.visitor_names_on_chat() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_email text := app.quo_email(new.email);
  v_phone text := app.phone_e164(new.phone);
  m visitor_names;
begin
  if new.visitor_id is null or (v_email is null and v_phone is null) then return null; end if;
  if exists (select 1 from visitor_names v where v.visitor_id = new.visitor_id) then
    update visitor_names set phone = coalesce(phone, v_phone), email = coalesce(email, v_email)
     where visitor_id = new.visitor_id and ((phone is null and v_phone is not null) or (email is null and v_email is not null));
    return null;
  end if;
  select * into m from visitor_names v
   where (v_email is not null and v.email = v_email) or (v_phone is not null and v.phone = v_phone)
   order by v.updated_at desc limit 1;
  if m.visitor_id is not null then
    insert into visitor_names (visitor_id, name, phone, email, note, source, renter_id, set_by, set_at)
    values (new.visitor_id, m.name, coalesce(v_phone, m.phone), coalesce(v_email, m.email), m.note, 'match', m.renter_id, m.set_by, now())
    on conflict (visitor_id) do nothing;
  end if;
  return null;
end $$;
create trigger visitor_names_on_chat after insert or update of email, phone, visitor_id on chat_conversations for each row execute function app.visitor_names_on_chat();

-- ================================================================ 7. the cron gate and the door
alter function app.server_jobs_due() rename to server_jobs_due_pre0190;
create or replace function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  j jsonb := app.server_jobs_due_pre0190();
begin
  if coalesce((j ->> 'phone')::boolean, false) then return j; end if;
  return j || jsonb_build_object('phone', app.quo_contacts_due_any());
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0190;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call = 'admin_read' and p_name = 'quo_contacts_status') or (p_call = 'admin_do' and p_name = 'quo_contacts_resync') then
    perform app.door_begin(p_user, p_aal);
    if not app.user_is_admin(p_user) then raise exception 'Quo contacts are for Admins' using errcode = '42501'; end if;
    if p_name = 'quo_contacts_status' then return app.quo_contacts_status(); end if;
    return app.quo_contacts_resync(p_user);
  end if;
  if p_call in ('va_do', 'admin_do') and p_name = 'live_name' then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.visitor_name_set(p_user, p_ - '_va');
  end if;
  return app.door_pre0190(p_user, p_aal, p_call, p_name, p);
end $$;

create or replace function public.server_quo_contacts_due(p_limit integer default 40) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_quo_contacts_due(p_limit) $$;
create or replace function public.server_quo_contact_done(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_quo_contact_done(p) $$;
create or replace function public.server_quo_contacts_found(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_quo_contacts_found(p) $$;
create or replace function public.server_quo_contacts_run(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_quo_contacts_run(p) $$;

-- ================================================================ 8. the backfill: everyone already on the site
insert into quo_contacts (number, dirty_at, next_try_at)
select distinct q.n, now(), now() from app.quo_people_v q where q.n is not null and app.quo_clean(q.name, 120) is not null
on conflict (number) do nothing;

-- ================================================================ 9. privacy policy (the live legal.privacy block, where it still has our text)
update site_content_blocks
   set body = replace(body, 'Calls and texts are kept with your rental records if you are a customer, and otherwise for 12 months.',
     'Calls and texts are kept with your rental records if you are a customer, and otherwise for 12 months. Your name, phone number, email and company, as we have them, are kept in the contact list of our business phone provider, so our staff see who is calling or texting.')
 where block_key = 'legal.privacy' and body like '%Calls and texts are kept with your rental records if you are a customer, and otherwise for 12 months.%'
   and body not like '%contact list of our business phone provider%';

-- ================================================================ 10. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['quo_clean', 'quo_email', 'quo_person', 'quo_hash', 'quo_contact_mark', 'quo_contact_touch',
              'quo_contact_role_touch', 'quo_contacts_due_any', 'server_quo_contacts_due', 'server_quo_contact_done', 'server_quo_contacts_found',
              'server_quo_contacts_run', 'quo_contacts_status', 'quo_contacts_resync', 'visitor_label', 'visitor_name_set', 'visitor_who',
              'visitor_who_pre0190', 'visitor_chat_name', 'visitor_chat_name_pre0190', 'visitor_session_row', 'visitor_session_row_pre0190',
              'phone_match', 'phone_match_pre0190', 'visitor_names_on_session', 'visitor_names_on_renter', 'visitor_names_on_chat',
              'server_jobs_due', 'server_jobs_due_pre0190', 'door', 'door_pre0190']))
        or (n.nspname = 'public' and p.proname = any (array['server_quo_contacts_due', 'server_quo_contact_done', 'server_quo_contacts_found', 'server_quo_contacts_run']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
revoke all on app.quo_people_v from public, anon, authenticated;
grant select on app.quo_people_v to service_role;

-- ================================================================ the guides
-- GUIDES 0190 START (generated by supabase/seed/0190_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'live-visitors-and-live-chat', 'chapter', 'tolls-and-tickets', 'See who is on the site right now and what they look at, with buying signals, and answer the live chat. The CarmaCars assistant answers the chat first; you take over whenever you want, and it hands over by itself for complaints, damage, payments and anything it should not answer.

## Live visitors

Visitors who accepted analytics (or got the notice in Canada outside Quebec and the US), known customers on their own booking pages and anyone in a chat.

1. Open **Today** > **Live visitors**. "Live now" counts who is on the site now (seen in the last 5 minutes; an open page says it is still there every 45 seconds, so someone reading one page stays on the list). "Visitors today" counts people, with their visits below. The other tiles count hot visitors now, known customers now and chats today. The menu shows how many hot visitors are on the site.
2. Visitors who chose necessary cookies only are never recorded: a line under the tiles says how many chose that today. Closing the tab takes a visitor off the list at once.
3. Each visitor shows a booking likelihood from 0 to 100, with Hot (60 or more), Warm (30 or more) or Cold. The list is sorted by it; choose "Most recent" in Sort, or tick "Hot and warm only".
4. "Why" gives the three strongest reasons, for example "Pickup tomorrow · Reached step 3 of the request form · Tapped to call". The badges are all the signals of the visit; the dots say how strong each is.
5. Each visitor also shows their name when known (signed in, or arrived from one of our emails), otherwise "Visitor from Toronto, phone"; the page and car they are on, and how many others look at that car now; the device, city, the site or campaign that sent them and "from an ad".
6. Suggested: the best next step and the message to send. Press **Invite to chat with this message** to send it at once, **Edit the message** to change it first, **Offer a 10% discount code**, **Assign to Sales** or, when their dates are taken, **Suggest a similar free car**.
7. Press **Pages** for every page and event of the visit with each signal''s points, or **Start a chat** to write your own message. They see it in a bubble and reply from it.
8. Below: hot visitors today (and whether someone acted), the signals of the last 24 hours, and the most viewed cars of the week with prices shown and the car most compared with each. The page refreshes by itself every 15 seconds.

## The signals

Each signal adds points to the booking likelihood. They come from what the visitor does on the site, never from what they type.

- Intent: dates searched again and again, saw the full price, reached the booking form (and which step), came back for the same car on another day, comparing two or three cars, read the cancellation policy, read about the deposit, insurance or requirements, tapped to call, text or WhatsApp us or copied our number, checked delivery, looked through many photos or stayed long on one car.
- Urgency: pickup within 72 hours, weekend or holiday dates, on a phone late at night, came from a city or model page or a "near me" search.
- Value: a weekly or monthly rental, a premium car, SUV or van, adding a driver, asked about young drivers, a business email.
- Hesitation: watching the price (sorted by lowest price, lowered the price limit), left after seeing the price, unsure about the deposit, trouble with a form, the car not free for their dates.
- Context: came from an ad, a past renter, an offer or payment waiting, a game code not used yet, a popular car. The signals of known customers (offer opened, pay page left, change proposal, request stopped, returning visitor, viewing spree) count too.

## Hot visitors and the actions

- When a visitor turns hot, everyone with Live visitors open sees an alert at the top of the page. Turn on desktop alerts in Live chat to get one on your computer too; none come in the quiet hours (11 pm to 7 am). No email is sent.
- A discount code is single use, 10% off the rental charge (at most $75), valid 3 days, one per visitor a week and 10 a day per person. Admins and Sales send them; the code goes in the chat with the message.
- Assign to Sales gives the visitor to the Sales person on shift (or to you if you work Sales) and raises a task with the reasons and the contact when we know who they are.
- Each action shows on the visitor ("Invited by Lena, 2 min ago") so two people do not write to the same visitor.

## Signal settings

1. Open **Today** > **Live visitors** and press **Signal settings**.
2. Score and actions: from how many points a visitor is hot or warm, when a signal is strong or medium, the hot alert, and the discount code (percent, most off a booking, days valid, codes a day per person, whether customer service may send codes, and the message).
3. Each signal: on or off, its points, its thresholds (for example 72 hours for "Pickup soon", 3 searches for "Searching dates again and again"), the suggested action and the message. {car}, {days}, {pickup} and the other words in braces are filled in from the visit.
4. Press **Save the signals**. The next look at each visit uses them.

## Follow-up tasks

Signals of known visitors become tasks with a suggested action, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours".

- An offer opened and not answered: after 6 hours, to Sales when the booking is credited to someone in Sales, otherwise customer service.
- The pay page left without paying: after 30 minutes, customer service. The change proposal opened twice: customer service.
- A booking request started and stopped, or a viewing spree, by a known visitor: Sales.
- A task closes by itself when the renter answers the offer, pays or answers the proposal. Each signal raises one task only.
- The thresholds are in **Settings** > **Program**, group "Live visitors and live chat", with how long "on the site now" lasts (5 minutes) and how often an open page says it is still there (45 seconds). Follow-ups done count in My sales.

## Recovery emails

Known renters who stop before finishing get one polite reminder, and at most one more a day later.

- An offer opened and not answered: after 4 hours. The pay page left without paying: after an hour. A change proposal opened and not answered: after 4 hours.
- A booking request started and not sent: after 2 hours, and only to renters who agreed to hear from us (marketing consent).
- Sent only between 9:00 and 21:00 Toronto time, never to someone who unsubscribed, and never while a staff member is handling the renter (a task they took, a chat with a person, a message from staff).
- They stop as soon as the renter answers, pays or sends the request; a reminder still waiting is not sent. The delays and hours are in Program settings, "Booking recovery emails".

## Interest in a car

**Cars** > **Vehicles**, a car, Overview: "Interest on the site" shows who is looking now, views today and in 7 days, the people who saw the price for their dates, conversion over 30 days (requests from the people who viewed it), the cars most often compared with it, and the last 14 days. The Vehicles list has "Most viewed cars this week".

## A renter''s visits

On a renter''s page (People > Renters, the name) and on a booking''s History tab, "On the site" lists when they viewed the offer, opened the change proposal, viewed or left the pay page, which cars they looked at, and their chats.

## Live chat

1. A visitor who asks for a person is a line on To do, marked Now: press **Open the chat**. Or open **Bookings** > **Live chat**. The menu counts chats waiting for a person. Open chats come first, those waiting for a person on top, with their minutes against the first reply target (5 minutes).
2. Choose a conversation. Beside it you see the visitor''s page, pages, signals, and the renter with their bookings when known.
3. Press **Take over**: the assistant stops and the visitor reads that you joined. Writing a reply also takes over. Press **Send** (or Enter).
4. **Hand back to the assistant** lets it answer again. **Close** ends the chat; if the visitor gave an email they get a copy. **Email the transcript** sends it any time.
5. Notify me: "Email me when a chat waits (while I am on shift)" and desktop alerts in this browser. You are on shift while Live chat or Live visitors is open.

> Tip: The assistant only repeats prices from our pricing (a quote or the car''s rates), never offers discounts or promises a car, never talks about insurance and never names a provider. Each reply it was not allowed to send says so in the conversation. When nobody is on shift, the chat asks for the visitor''s name, email or phone and raises a task. A booking from a chat you handled is credited only when you choose "I sourced this client" on the quote or offer.

## The assistant''s settings

In Program settings, "Live visitors and live chat": the chat on or off, the AI first or not, its model, the neurons it may use a day (6,000, about 10 chats; then chats wait for a person), the greeting on car pages after some seconds (off by default), how long chats and visits are kept, as the privacy policy says: chats 12 months, the pages of a visit 90 days, the visit''s summary in Visitor history 13 months, and the daily totals, which name no one, 3 years.

## What a visitor typed

A visitor who typed contact details into a form shows them on their line: "Typed into the booking request, not sent: Maya Chen, maya@example.com", with **Email not confirmed** until they open the link we emailed, and **Renter page**.
', 'Live visitors and live chat', 'Who is on the site now, how likely each visitor is to book and why, one-click actions, follow-ups, interest per car, the chat inbox.',
  'See who is on the site right now and what they look at, with buying signals, and answer the live chat. The CarmaCars assistant answers the chat first; you take over whenever you want, and it hands over by itself for complaints, damage, payments and anything it should not answer.

## Live visitors

Visitors who accepted analytics (or got the notice in Canada outside Quebec and the US), known customers on their own booking pages and anyone in a chat.

1. Open **Today** > **Live visitors**. "Live now" counts who is on the site now (seen in the last 5 minutes; an open page says it is still there every 45 seconds, so someone reading one page stays on the list). "Visitors today" counts people, with their visits below. The other tiles count hot visitors now, known customers now and chats today. The menu shows how many hot visitors are on the site.
2. Visitors who chose necessary cookies only are never recorded: a line under the tiles says how many chose that today. Closing the tab takes a visitor off the list at once.
3. Each visitor shows a booking likelihood from 0 to 100, with Hot (60 or more), Warm (30 or more) or Cold. The list is sorted by it; choose "Most recent" in Sort, or tick "Hot and warm only".
4. "Why" gives the three strongest reasons, for example "Pickup tomorrow · Reached step 3 of the request form · Tapped to call". The badges are all the signals of the visit; the dots say how strong each is.
5. Each visitor also shows their name when known (signed in, or arrived from one of our emails), otherwise "Visitor from Toronto, phone"; the page and car they are on, and how many others look at that car now; the device, city, the site or campaign that sent them and "from an ad".
6. Suggested: the best next step and the message to send. Press **Invite to chat with this message** to send it at once, **Edit the message** to change it first, **Offer a 10% discount code**, **Assign to Sales** or, when their dates are taken, **Suggest a similar free car**.
7. Press **Pages** for every page and event of the visit with each signal''s points, or **Start a chat** to write your own message. They see it in a bubble and reply from it.
8. Below: hot visitors today (and whether someone acted), the signals of the last 24 hours, and the most viewed cars of the week with prices shown and the car most compared with each. The page refreshes by itself every 15 seconds.

## Name a visitor

When you learn who a visitor is (they called, or told you in the chat), give them a name. Only staff see it.

1. On their line, press **Name**. Type the name and, if you have them, their phone, email and a note. Press **Save the name**.
2. The name shows on Live visitors, the visit''s pages, Visitor history and Live chat, and on every later visit from the same browser. The line says who named them, with the phone, email and note.
3. A phone you add also saves them as a contact in Quo, and a call or text from that number shows the name in Texts and calls.
4. Kept consistent: if they later book or sign in, the name the booking has replaces yours ("Booked"). A chat from another browser with the same email or phone gets the same name, and a chat''s email or phone fills in the ones you left empty.
5. **Edit name** changes it; **Remove the name** takes it off.

## The signals

Each signal adds points to the booking likelihood. They come from what the visitor does on the site, never from what they type.

- Intent: dates searched again and again, saw the full price, reached the booking form (and which step), came back for the same car on another day, comparing two or three cars, read the cancellation policy, read about the deposit, insurance or requirements, tapped to call, text or WhatsApp us or copied our number, checked delivery, looked through many photos or stayed long on one car.
- Urgency: pickup within 72 hours, weekend or holiday dates, on a phone late at night, came from a city or model page or a "near me" search.
- Value: a weekly or monthly rental, a premium car, SUV or van, adding a driver, asked about young drivers, a business email.
- Hesitation: watching the price (sorted by lowest price, lowered the price limit), left after seeing the price, unsure about the deposit, trouble with a form, the car not free for their dates.
- Context: came from an ad, a past renter, an offer or payment waiting, a game code not used yet, a popular car. The signals of known customers (offer opened, pay page left, change proposal, request stopped, returning visitor, viewing spree) count too.

## Hot visitors and the actions

- When a visitor turns hot, everyone with Live visitors open sees an alert at the top of the page. Turn on desktop alerts in Live chat to get one on your computer too; none come in the quiet hours (11 pm to 7 am). No email is sent.
- A discount code is single use, 10% off the rental charge (at most $75), valid 3 days, one per visitor a week and 10 a day per person. Admins and Sales send them; the code goes in the chat with the message.
- Assign to Sales gives the visitor to the Sales person on shift (or to you if you work Sales) and raises a task with the reasons and the contact when we know who they are.
- Each action shows on the visitor ("Invited by Lena, 2 min ago") so two people do not write to the same visitor.

## Signal settings

1. Open **Today** > **Live visitors** and press **Signal settings**.
2. Score and actions: from how many points a visitor is hot or warm, when a signal is strong or medium, the hot alert, and the discount code (percent, most off a booking, days valid, codes a day per person, whether customer service may send codes, and the message).
3. Each signal: on or off, its points, its thresholds (for example 72 hours for "Pickup soon", 3 searches for "Searching dates again and again"), the suggested action and the message. {car}, {days}, {pickup} and the other words in braces are filled in from the visit.
4. Press **Save the signals**. The next look at each visit uses them.

## Follow-up tasks

Signals of known visitors become tasks with a suggested action, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours".

- An offer opened and not answered: after 6 hours, to Sales when the booking is credited to someone in Sales, otherwise customer service.
- The pay page left without paying: after 30 minutes, customer service. The change proposal opened twice: customer service.
- A booking request started and stopped, or a viewing spree, by a known visitor: Sales.
- A task closes by itself when the renter answers the offer, pays or answers the proposal. Each signal raises one task only.
- The thresholds are in **Settings** > **Program**, group "Live visitors and live chat", with how long "on the site now" lasts (5 minutes) and how often an open page says it is still there (45 seconds). Follow-ups done count in My sales.

## Recovery emails

Known renters who stop before finishing get one polite reminder, and at most one more a day later.

- An offer opened and not answered: after 4 hours. The pay page left without paying: after an hour. A change proposal opened and not answered: after 4 hours.
- A booking request started and not sent: after 2 hours, and only to renters who agreed to hear from us (marketing consent).
- Sent only between 9:00 and 21:00 Toronto time, never to someone who unsubscribed, and never while a staff member is handling the renter (a task they took, a chat with a person, a message from staff).
- They stop as soon as the renter answers, pays or sends the request; a reminder still waiting is not sent. The delays and hours are in Program settings, "Booking recovery emails".

## Interest in a car

**Cars** > **Vehicles**, a car, Overview: "Interest on the site" shows who is looking now, views today and in 7 days, the people who saw the price for their dates, conversion over 30 days (requests from the people who viewed it), the cars most often compared with it, and the last 14 days. The Vehicles list has "Most viewed cars this week".

## A renter''s visits

On a renter''s page (People > Renters, the name) and on a booking''s History tab, "On the site" lists when they viewed the offer, opened the change proposal, viewed or left the pay page, which cars they looked at, and their chats.

## Live chat

1. A visitor who asks for a person is a line on To do, marked Now: press **Open the chat**. Or open **Bookings** > **Live chat**. The menu counts chats waiting for a person. Open chats come first, those waiting for a person on top, with their minutes against the first reply target (5 minutes).
2. Choose a conversation. Beside it you see the visitor''s page, pages, signals, and the renter with their bookings when known.
3. Press **Take over**: the assistant stops and the visitor reads that you joined. Writing a reply also takes over. Press **Send** (or Enter).
4. **Hand back to the assistant** lets it answer again. **Close** ends the chat; if the visitor gave an email they get a copy. **Email the transcript** sends it any time.
5. Notify me: "Email me when a chat waits (while I am on shift)" and desktop alerts in this browser. You are on shift while Live chat or Live visitors is open.

> Tip: The assistant only repeats prices from our pricing (a quote or the car''s rates), never offers discounts or promises a car, never talks about insurance and never names a provider. Each reply it was not allowed to send says so in the conversation. When nobody is on shift, the chat asks for the visitor''s name, email or phone and raises a task. A booking from a chat you handled is credited only when you choose "I sourced this client" on the quote or offer.

## The assistant''s settings

In Program settings, "Live visitors and live chat": the chat on or off, the AI first or not, its model, the neurons it may use a day (6,000, about 10 chats; then chats wait for a person), the greeting on car pages after some seconds (off by default), how long chats and visits are kept, as the privacy policy says: chats 12 months, the pages of a visit 90 days, the visit''s summary in Visitor history 13 months, and the daily totals, which name no one, 3 years.

## What a visitor typed

A visitor who typed contact details into a form shows them on their line: "Typed into the booking request, not sent: Maya Chen, maya@example.com", with **Email not confirmed** until they open the link we emailed, and **Renter page**.
',
  '<p class="gd-p">See who is on the site right now and what they look at, with buying signals, and answer the live chat. The CarmaCars assistant answers the chat first; you take over whenever you want, and it hands over by itself for complaints, damage, payments and anything it should not answer.</p><section class="gd-task" id="live-visitors-and-live-chat-live-visitors" data-gd-task><h2 class="gd-h2">Live visitors</h2><p class="gd-p">Visitors who accepted analytics (or got the notice in Canada outside Quebec and the US), known customers on their own booking pages and anyone in a chat.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Today</b> &gt; <b class="gd-ui">Live visitors</b>. &quot;Live now&quot; counts who is on the site now (seen in the last 5 minutes; an open page says it is still there every 45 seconds, so someone reading one page stays on the list). &quot;Visitors today&quot; counts people, with their visits below. The other tiles count hot visitors now, known customers now and chats today. The menu shows how many hot visitors are on the site.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Visitors who chose necessary cookies only are never recorded: a line under the tiles says how many chose that today. Closing the tab takes a visitor off the list at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each visitor shows a booking likelihood from 0 to 100, with Hot (60 or more), Warm (30 or more) or Cold. The list is sorted by it; choose &quot;Most recent&quot; in Sort, or tick &quot;Hot and warm only&quot;.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">&quot;Why&quot; gives the three strongest reasons, for example &quot;Pickup tomorrow · Reached step 3 of the request form · Tapped to call&quot;. The badges are all the signals of the visit; the dots say how strong each is.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Each visitor also shows their name when known (signed in, or arrived from one of our emails), otherwise &quot;Visitor from Toronto, phone&quot;; the page and car they are on, and how many others look at that car now; the device, city, the site or campaign that sent them and &quot;from an ad&quot;.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Suggested: the best next step and the message to send. Press <b class="gd-ui">Invite to chat with this message</b> to send it at once, <b class="gd-ui">Edit the message</b> to change it first, <b class="gd-ui">Offer a 10% discount code</b>, <b class="gd-ui">Assign to Sales</b> or, when their dates are taken, <b class="gd-ui">Suggest a similar free car</b>.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Press <b class="gd-ui">Pages</b> for every page and event of the visit with each signal&#39;s points, or <b class="gd-ui">Start a chat</b> to write your own message. They see it in a bubble and reply from it.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Below: hot visitors today (and whether someone acted), the signals of the last 24 hours, and the most viewed cars of the week with prices shown and the car most compared with each. The page refreshes by itself every 15 seconds.</div></li></ol></div></section><section class="gd-task" id="live-visitors-and-live-chat-name-a-visitor" data-gd-task><h2 class="gd-h2">Name a visitor</h2><p class="gd-p">When you learn who a visitor is (they called, or told you in the chat), give them a name. Only staff see it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On their line, press <b class="gd-ui">Name</b>. Type the name and, if you have them, their phone, email and a note. Press <b class="gd-ui">Save the name</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The name shows on Live visitors, the visit&#39;s pages, Visitor history and Live chat, and on every later visit from the same browser. The line says who named them, with the phone, email and note.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A phone you add also saves them as a contact in Quo, and a call or text from that number shows the name in Texts and calls.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Kept consistent: if they later book or sign in, the name the booking has replaces yours (&quot;Booked&quot;). A chat from another browser with the same email or phone gets the same name, and a chat&#39;s email or phone fills in the ones you left empty.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Edit name</b> changes it; <b class="gd-ui">Remove the name</b> takes it off.</div></li></ol></div></section><section class="gd-task" id="live-visitors-and-live-chat-the-signals" data-gd-task><h2 class="gd-h2">The signals</h2><p class="gd-p">Each signal adds points to the booking likelihood. They come from what the visitor does on the site, never from what they type.</p><ul class="gd-ul"><li>Intent: dates searched again and again, saw the full price, reached the booking form (and which step), came back for the same car on another day, comparing two or three cars, read the cancellation policy, read about the deposit, insurance or requirements, tapped to call, text or WhatsApp us or copied our number, checked delivery, looked through many photos or stayed long on one car.</li><li>Urgency: pickup within 72 hours, weekend or holiday dates, on a phone late at night, came from a city or model page or a &quot;near me&quot; search.</li><li>Value: a weekly or monthly rental, a premium car, SUV or van, adding a driver, asked about young drivers, a business email.</li><li>Hesitation: watching the price (sorted by lowest price, lowered the price limit), left after seeing the price, unsure about the deposit, trouble with a form, the car not free for their dates.</li><li>Context: came from an ad, a past renter, an offer or payment waiting, a game code not used yet, a popular car. The signals of known customers (offer opened, pay page left, change proposal, request stopped, returning visitor, viewing spree) count too.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-hot-visitors-and-the-actions" data-gd-task><h2 class="gd-h2">Hot visitors and the actions</h2><ul class="gd-ul"><li>When a visitor turns hot, everyone with Live visitors open sees an alert at the top of the page. Turn on desktop alerts in Live chat to get one on your computer too; none come in the quiet hours (11 pm to 7 am). No email is sent.</li><li>A discount code is single use, 10% off the rental charge (at most $75), valid 3 days, one per visitor a week and 10 a day per person. Admins and Sales send them; the code goes in the chat with the message.</li><li>Assign to Sales gives the visitor to the Sales person on shift (or to you if you work Sales) and raises a task with the reasons and the contact when we know who they are.</li><li>Each action shows on the visitor (&quot;Invited by Lena, 2 min ago&quot;) so two people do not write to the same visitor.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-signal-settings" data-gd-task><h2 class="gd-h2">Signal settings</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Today</b> &gt; <b class="gd-ui">Live visitors</b> and press <b class="gd-ui">Signal settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Score and actions: from how many points a visitor is hot or warm, when a signal is strong or medium, the hot alert, and the discount code (percent, most off a booking, days valid, codes a day per person, whether customer service may send codes, and the message).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each signal: on or off, its points, its thresholds (for example 72 hours for &quot;Pickup soon&quot;, 3 searches for &quot;Searching dates again and again&quot;), the suggested action and the message. {car}, {days}, {pickup} and the other words in braces are filled in from the visit.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Save the signals</b>. The next look at each visit uses them.</div></li></ol></div></section><section class="gd-task" id="live-visitors-and-live-chat-follow-up-tasks" data-gd-task><h2 class="gd-h2">Follow-up tasks</h2><p class="gd-p">Signals of known visitors become tasks with a suggested action, for example &quot;Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours&quot;.</p><ul class="gd-ul"><li>An offer opened and not answered: after 6 hours, to Sales when the booking is credited to someone in Sales, otherwise customer service.</li><li>The pay page left without paying: after 30 minutes, customer service. The change proposal opened twice: customer service.</li><li>A booking request started and stopped, or a viewing spree, by a known visitor: Sales.</li><li>A task closes by itself when the renter answers the offer, pays or answers the proposal. Each signal raises one task only.</li><li>The thresholds are in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, group &quot;Live visitors and live chat&quot;, with how long &quot;on the site now&quot; lasts (5 minutes) and how often an open page says it is still there (45 seconds). Follow-ups done count in My sales.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-recovery-emails" data-gd-task><h2 class="gd-h2">Recovery emails</h2><p class="gd-p">Known renters who stop before finishing get one polite reminder, and at most one more a day later.</p><ul class="gd-ul"><li>An offer opened and not answered: after 4 hours. The pay page left without paying: after an hour. A change proposal opened and not answered: after 4 hours.</li><li>A booking request started and not sent: after 2 hours, and only to renters who agreed to hear from us (marketing consent).</li><li>Sent only between 9:00 and 21:00 Toronto time, never to someone who unsubscribed, and never while a staff member is handling the renter (a task they took, a chat with a person, a message from staff).</li><li>They stop as soon as the renter answers, pays or sends the request; a reminder still waiting is not sent. The delays and hours are in Program settings, &quot;Booking recovery emails&quot;.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-interest-in-a-car" data-gd-task><h2 class="gd-h2">Interest in a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, a car, Overview: &quot;Interest on the site&quot; shows who is looking now, views today and in 7 days, the people who saw the price for their dates, conversion over 30 days (requests from the people who viewed it), the cars most often compared with it, and the last 14 days. The Vehicles list has &quot;Most viewed cars this week&quot;.</p></section><section class="gd-task" id="live-visitors-and-live-chat-a-renter-s-visits" data-gd-task><h2 class="gd-h2">A renter&#39;s visits</h2><p class="gd-p">On a renter&#39;s page (People &gt; Renters, the name) and on a booking&#39;s History tab, &quot;On the site&quot; lists when they viewed the offer, opened the change proposal, viewed or left the pay page, which cars they looked at, and their chats.</p></section><section class="gd-task" id="live-visitors-and-live-chat-live-chat" data-gd-task><h2 class="gd-h2">Live chat</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A visitor who asks for a person is a line on To do, marked Now: press <b class="gd-ui">Open the chat</b>. Or open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Live chat</b>. The menu counts chats waiting for a person. Open chats come first, those waiting for a person on top, with their minutes against the first reply target (5 minutes).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a conversation. Beside it you see the visitor&#39;s page, pages, signals, and the renter with their bookings when known.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take over</b>: the assistant stops and the visitor reads that you joined. Writing a reply also takes over. Press <b class="gd-ui">Send</b> (or Enter).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Hand back to the assistant</b> lets it answer again. <b class="gd-ui">Close</b> ends the chat; if the visitor gave an email they get a copy. <b class="gd-ui">Email the transcript</b> sends it any time.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Notify me: &quot;Email me when a chat waits (while I am on shift)&quot; and desktop alerts in this browser. You are on shift while Live chat or Live visitors is open.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The assistant only repeats prices from our pricing (a quote or the car&#39;s rates), never offers discounts or promises a car, never talks about insurance and never names a provider. Each reply it was not allowed to send says so in the conversation. When nobody is on shift, the chat asks for the visitor&#39;s name, email or phone and raises a task. A booking from a chat you handled is credited only when you choose &quot;I sourced this client&quot; on the quote or offer.</div></aside></section><section class="gd-task" id="live-visitors-and-live-chat-the-assistant-s-settings" data-gd-task><h2 class="gd-h2">The assistant&#39;s settings</h2><p class="gd-p">In Program settings, &quot;Live visitors and live chat&quot;: the chat on or off, the AI first or not, its model, the neurons it may use a day (6,000, about 10 chats; then chats wait for a person), the greeting on car pages after some seconds (off by default), how long chats and visits are kept, as the privacy policy says: chats 12 months, the pages of a visit 90 days, the visit&#39;s summary in Visitor history 13 months, and the daily totals, which name no one, 3 years.</p></section><section class="gd-task" id="live-visitors-and-live-chat-what-a-visitor-typed" data-gd-task><h2 class="gd-h2">What a visitor typed</h2><p class="gd-p">A visitor who typed contact details into a form shows them on their line: &quot;Typed into the booking request, not sent: Maya Chen, maya@example.com&quot;, with <b class="gd-ui">Email not confirmed</b> until they open the link we emailed, and <b class="gd-ui">Renter page</b>.</p></section>');
select app.guide_release_section('admin', 'texts-and-calls-the-quo-phone-line', 'chapter', 'live-visitors-and-live-chat', 'Every call and text on the CarmaCars number (Quo) is kept and matched to the person: staff, a renter and their booking, an owner or a lead. Staff answer texts from the same inbox as live chat. It is on by default; Program settings switch each part.

## The inbox

1. Open **Bookings** > **Live chat** and press **Texts and calls**. Each number shows who it is (Renter, Owner, Lead, Staff or Unknown caller), unread texts and missed calls.
2. Choose a number. Calls and texts are in order; a call shows its length, and Quo''s summary or a one-line AI summary when there is one.
3. Write a text and press **Send text**: it goes from the CarmaCars number through Quo. **Suggest a reply** puts an AI draft in the box; nothing is ever sent until you press Send text.
4. Beside the conversation: the renter with their bookings, the owner or the lead. A caller who gave the same phone in live chat or a discount game shows their visit on the site.
5. **Stop texts** stops every text to the number, booking texts included. A person who texts STOP is stopped the same way; START allows texts again.

## Unknown callers

Press **Unknown callers**. For a number nobody on file has, type the name if you know it and press **Create lead**, or find the renter and press **Link to** the name. The calls and texts so far follow the link. **Match automatically again** undoes a link made by hand.

## Missed calls

A missed call raises the task "Missed call from ..." for the person on duty in customer service (whoever has Live chat or Texts and calls open), otherwise the customer service queue, and the Admins when nobody holds that function. In the quiet hours (11 pm to 7 am) the task is due at 7 am. One open task per number.

> Tip: Quo itself texts back missed callers (its own auto-reply). The platform can do it instead (Program settings, "Missed call: text the caller back"), once per number in 12 hours: turn off Quo''s own auto-reply first, or callers get two texts.

## Calls and texts on records

A booking''s History tab, a renter''s page and an owner''s page have "Calls and texts": the texts, calls, missed calls, voicemails and summaries with that person. Calls are not recorded on the line for now, so there is no transcript or recording to show.

## Booking texts

Since October 22, 2026 these are text alerts: each person chooses Email, Text or Both (the chapter Text alerts, below, and **Settings** > **All settings**, **Text alerts**).

## The settings

Program settings, "Phone and texts (Quo)": the line on or off, calls and texts kept, the missed-call text and its task, who calls back, AI suggestions and summaries with their daily neurons, the visit of a caller, and how long calls and texts of people who are not customers are kept (12 months).
', 'Texts and calls (the Quo phone line)', 'Texts and calls in the chat inbox, unknown callers, missed calls, booking texts, call summaries and the settings.',
  'Every call and text on the CarmaCars number (Quo) is kept and matched to the person: staff, a renter and their booking, an owner or a lead. Staff answer texts from the same inbox as live chat. It is on by default; Program settings switch each part.

## The inbox

1. Open **Bookings** > **Live chat** and press **Texts and calls**. Each number shows who it is (Renter, Owner, Lead, Staff or Unknown caller), unread texts and missed calls.
2. Choose a number. Calls and texts are in order; a call shows its length, and Quo''s summary or a one-line AI summary when there is one.
3. Write a text and press **Send text**: it goes from the CarmaCars number through Quo. **Suggest a reply** puts an AI draft in the box; nothing is ever sent until you press Send text.
4. Beside the conversation: the renter with their bookings, the owner or the lead. A caller who gave the same phone in live chat or a discount game shows their visit on the site.
5. **Stop texts** stops every text to the number, booking texts included. A person who texts STOP is stopped the same way; START allows texts again.

## Unknown callers

Press **Unknown callers**. For a number nobody on file has, type the name if you know it and press **Create lead**, or find the renter and press **Link to** the name. The calls and texts so far follow the link. **Match automatically again** undoes a link made by hand.

## Missed calls

A missed call raises the task "Missed call from ..." for the person on duty in customer service (whoever has Live chat or Texts and calls open), otherwise the customer service queue, and the Admins when nobody holds that function. In the quiet hours (11 pm to 7 am) the task is due at 7 am. One open task per number.

> Tip: Quo itself texts back missed callers (its own auto-reply). The platform can do it instead (Program settings, "Missed call: text the caller back"), once per number in 12 hours: turn off Quo''s own auto-reply first, or callers get two texts.

## Calls and texts on records

A booking''s History tab, a renter''s page and an owner''s page have "Calls and texts": the texts, calls, missed calls, voicemails and summaries with that person. Calls are not recorded on the line for now, so there is no transcript or recording to show.

## Quo contacts

Everyone on the site with a phone number is a contact in Quo under the same name, with their email and company: staff, renters and their drivers, owners, partners, investors, referral partners, job applicants, named visitors, leads, chauffeur clients, live chats, game players and forms left unfinished.

- A new person is added within about five minutes; a changed name, phone or email is updated the same way. Change people on the site, not in Quo: the site''s version is sent again.
- One contact per number. When two records share a number, the strongest names the contact: staff, then a renter, a driver, an owner, a partner. A number without any name is not sent.
- A contact someone already made in Quo for the number is updated rather than made twice, and its other numbers and emails are kept.
- If Quo is down or slow, bookings and everything else go on; the contacts follow when it answers again.
- **Settings** > **All settings**, **Quo contacts**: how many are in Quo, waiting and in error, the last run and the last error, and **Sync everyone again**. Program settings, "Phone and texts (Quo)", turn it off.

## Booking texts

Since October 22, 2026 these are text alerts: each person chooses Email, Text or Both (the chapter Text alerts, below, and **Settings** > **All settings**, **Text alerts**).

## The settings

Program settings, "Phone and texts (Quo)": the line on or off, calls and texts kept, the missed-call text and its task, who calls back, AI suggestions and summaries with their daily neurons, the visit of a caller, and how long calls and texts of people who are not customers are kept (12 months).
',
  '<p class="gd-p">Every call and text on the CarmaCars number (Quo) is kept and matched to the person: staff, a renter and their booking, an owner or a lead. Staff answer texts from the same inbox as live chat. It is on by default; Program settings switch each part.</p><section class="gd-task" id="texts-and-calls-the-quo-phone-line-the-inbox" data-gd-task><h2 class="gd-h2">The inbox</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Live chat</b> and press <b class="gd-ui">Texts and calls</b>. Each number shows who it is (Renter, Owner, Lead, Staff or Unknown caller), unread texts and missed calls.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a number. Calls and texts are in order; a call shows its length, and Quo&#39;s summary or a one-line AI summary when there is one.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write a text and press <b class="gd-ui">Send text</b>: it goes from the CarmaCars number through Quo. <b class="gd-ui">Suggest a reply</b> puts an AI draft in the box; nothing is ever sent until you press Send text.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Beside the conversation: the renter with their bookings, the owner or the lead. A caller who gave the same phone in live chat or a discount game shows their visit on the site.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Stop texts</b> stops every text to the number, booking texts included. A person who texts STOP is stopped the same way; START allows texts again.</div></li></ol></div></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-unknown-callers" data-gd-task><h2 class="gd-h2">Unknown callers</h2><p class="gd-p">Press <b class="gd-ui">Unknown callers</b>. For a number nobody on file has, type the name if you know it and press <b class="gd-ui">Create lead</b>, or find the renter and press <b class="gd-ui">Link to</b> the name. The calls and texts so far follow the link. <b class="gd-ui">Match automatically again</b> undoes a link made by hand.</p></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-missed-calls" data-gd-task><h2 class="gd-h2">Missed calls</h2><p class="gd-p">A missed call raises the task &quot;Missed call from ...&quot; for the person on duty in customer service (whoever has Live chat or Texts and calls open), otherwise the customer service queue, and the Admins when nobody holds that function. In the quiet hours (11 pm to 7 am) the task is due at 7 am. One open task per number.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Quo itself texts back missed callers (its own auto-reply). The platform can do it instead (Program settings, &quot;Missed call: text the caller back&quot;), once per number in 12 hours: turn off Quo&#39;s own auto-reply first, or callers get two texts.</div></aside></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-calls-and-texts-on-records" data-gd-task><h2 class="gd-h2">Calls and texts on records</h2><p class="gd-p">A booking&#39;s History tab, a renter&#39;s page and an owner&#39;s page have &quot;Calls and texts&quot;: the texts, calls, missed calls, voicemails and summaries with that person. Calls are not recorded on the line for now, so there is no transcript or recording to show.</p></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-quo-contacts" data-gd-task><h2 class="gd-h2">Quo contacts</h2><p class="gd-p">Everyone on the site with a phone number is a contact in Quo under the same name, with their email and company: staff, renters and their drivers, owners, partners, investors, referral partners, job applicants, named visitors, leads, chauffeur clients, live chats, game players and forms left unfinished.</p><ul class="gd-ul"><li>A new person is added within about five minutes; a changed name, phone or email is updated the same way. Change people on the site, not in Quo: the site&#39;s version is sent again.</li><li>One contact per number. When two records share a number, the strongest names the contact: staff, then a renter, a driver, an owner, a partner. A number without any name is not sent.</li><li>A contact someone already made in Quo for the number is updated rather than made twice, and its other numbers and emails are kept.</li><li>If Quo is down or slow, bookings and everything else go on; the contacts follow when it answers again.</li><li><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, <b class="gd-ui">Quo contacts</b>: how many are in Quo, waiting and in error, the last run and the last error, and <b class="gd-ui">Sync everyone again</b>. Program settings, &quot;Phone and texts (Quo)&quot;, turn it off.</li></ul></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-booking-texts" data-gd-task><h2 class="gd-h2">Booking texts</h2><p class="gd-p">Since October 22, 2026 these are text alerts: each person chooses Email, Text or Both (the chapter Text alerts, below, and <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, <b class="gd-ui">Text alerts</b>).</p></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-the-settings" data-gd-task><h2 class="gd-h2">The settings</h2><p class="gd-p">Program settings, &quot;Phone and texts (Quo)&quot;: the line on or off, calls and texts kept, the missed-call text and its task, who calls back, AI suggestions and summaries with their daily neurons, the visit of a caller, and how long calls and texts of people who are not customers are kept (12 months).</p></section>');
select app.guide_release_section('admin', 'settings', 'chapter', 'search-car-pages-landing-pages-and-guides', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026. The remote Sales values follow: the three remote tiers (5%, 10%, 15%), the touches a month (400), the drop under it (one tier) and its floor (2.5%), the peak hours a week (20), the reply target (15 minutes) and the peak hours (noon to 6 pm, Thursday to Sunday).
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.
9. Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task). Field pay: the first day of a pay period (every period is two weeks), the default hourly rate (CA$18.00), whether overtime is paid (off), after how many hours in a week (44) and at what share of the rate (150%), vacation pay added to each statement (off; Ontario 4%) and the longest shift (16 hours).
10. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
11. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
12. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Vehicle class rules

Open **Settings**, then **Vehicle class rules**. How a new car''s class is decided from its VIN: the first rule that matches wins.

1. The table lists each rule: its rank, what the car must be (a make, and patterns for the model, the trim and the body), the class it gets, the class once the car is old enough, a note and whether it is on. The lowest rank that matches is used; a car that matches no rule is Standard.
2. Press **Add a rule** or **Change**: a rank, at least one condition, the class, optionally the years old after which an older class applies, and a note (it is shown as the reason for the class). A pattern is not case sensitive: ^911 matches models that start with 911. A rule with no condition, a pattern that does not compile and an older class equal to the class are refused.
3. **Try a car** gives the class the rules decide for a year, make, model, trim and body, and why.
4. **Delete** removes a rule; switch it off instead to keep it. Every add, change and delete is in the audit log, with before and after.

> Tip: A rule changes the cars entered from then on. A car already listed keeps its class until you change it on the car.

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record paper signature**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes. Its rates by car class are in **Money** > **Insurer rates**.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Promo codes: end dates and reminders

**Settings** > **All settings**, **Promo codes**.

- Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.
- A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.
- A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with "This code has expired".
- A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.
- The list shows each code''s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.

## Reviews: review requests and Google

**Settings** > **Reviews**: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.

1. When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.
2. The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile''s own review link.
3. Google Business Profile: press **Connect Google** and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.
4. A clear match stops that renter''s reminders at once. A possible match waits in Reviews: press **Confirm**, **Not this renter** or **Match to a booking**.

> Tip: Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.
', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Quo contacts (everyone with a phone number as a contact in Quo: see Texts and calls), Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026. The remote Sales values follow: the three remote tiers (5%, 10%, 15%), the touches a month (400), the drop under it (one tier) and its floor (2.5%), the peak hours a week (20), the reply target (15 minutes) and the peak hours (noon to 6 pm, Thursday to Sunday).
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.
9. Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task). Field pay: the first day of a pay period (every period is two weeks), the default hourly rate (CA$18.00), whether overtime is paid (off), after how many hours in a week (44) and at what share of the rate (150%), vacation pay added to each statement (off; Ontario 4%) and the longest shift (16 hours).
10. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
11. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
12. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Vehicle class rules

Open **Settings**, then **Vehicle class rules**. How a new car''s class is decided from its VIN: the first rule that matches wins.

1. The table lists each rule: its rank, what the car must be (a make, and patterns for the model, the trim and the body), the class it gets, the class once the car is old enough, a note and whether it is on. The lowest rank that matches is used; a car that matches no rule is Standard.
2. Press **Add a rule** or **Change**: a rank, at least one condition, the class, optionally the years old after which an older class applies, and a note (it is shown as the reason for the class). A pattern is not case sensitive: ^911 matches models that start with 911. A rule with no condition, a pattern that does not compile and an older class equal to the class are refused.
3. **Try a car** gives the class the rules decide for a year, make, model, trim and body, and why.
4. **Delete** removes a rule; switch it off instead to keep it. Every add, change and delete is in the audit log, with before and after.

> Tip: A rule changes the cars entered from then on. A car already listed keeps its class until you change it on the car.

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record paper signature**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes. Its rates by car class are in **Money** > **Insurer rates**.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Promo codes: end dates and reminders

**Settings** > **All settings**, **Promo codes**.

- Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.
- A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.
- A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with "This code has expired".
- A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.
- The list shows each code''s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.

## Reviews: review requests and Google

**Settings** > **Reviews**: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.

1. When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.
2. The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile''s own review link.
3. Google Business Profile: press **Connect Google** and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.
4. A clear match stops that renter''s reminders at once. A possible match waits in Reviews: press **Confirm**, **Not this renter** or **Match to a booking**.

> Tip: Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.
',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: Blind Spot&#39;s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Quo contacts (everyone with a phone number as a contact in Quo: see Texts and calls), Text alerts, Partners (each partner company&#39;s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026. The remote Sales values follow: the three remote tiers (5%, 10%, 15%), the touches a month (400), the drop under it (one tier) and its floor (2.5%), the peak hours a week (20), the reply target (15 minutes) and the peak hours (noon to 6 pm, Thursday to Sunday).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task). Field pay: the first day of a pay period (every period is two weeks), the default hourly rate (CA$18.00), whether overtime is paid (off), after how many hours in a week (44) and at what share of the rate (150%), vacation pay added to each statement (off; Ontario 4%) and the longest shift (16 hours).</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-vehicle-class-rules" data-gd-task><h2 class="gd-h2">Vehicle class rules</h2><p class="gd-p">Open <b class="gd-ui">Settings</b>, then <b class="gd-ui">Vehicle class rules</b>. How a new car&#39;s class is decided from its VIN: the first rule that matches wins.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The table lists each rule: its rank, what the car must be (a make, and patterns for the model, the trim and the body), the class it gets, the class once the car is old enough, a note and whether it is on. The lowest rank that matches is used; a car that matches no rule is Standard.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Add a rule</b> or <b class="gd-ui">Change</b>: a rank, at least one condition, the class, optionally the years old after which an older class applies, and a note (it is shown as the reason for the class). A pattern is not case sensitive: ^911 matches models that start with 911. A rule with no condition, a pattern that does not compile and an older class equal to the class are refused.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Try a car</b> gives the class the rules decide for a year, make, model, trim and body, and why.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Delete</b> removes a rule; switch it off instead to keep it. Every add, change and delete is in the audit log, with before and after.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A rule changes the cars entered from then on. A car already listed keeps its class until you change it on the car.</div></aside></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;Signed here by hand, in ink&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with <b class="gd-ui">Record paper signature</b>. Each form not checked yet is also a line on To do with the same button and Preview it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form&#39;s notes list what to tick or choose at the counter.</div></aside></section><section class="gd-task" id="settings-blind-spot-rental-agreement" data-gd-task><h2 class="gd-h2">Blind Spot rental agreement</h2><p class="gd-p">We rent under Blind Spot Car Rental&#39;s insurance, so every booking has two agreements: CarmaCars&#39; rental agreement and Blind Spot&#39;s own. Blind Spot&#39;s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. The Blind Spot Car Rental agreement card is first. Press <b class="gd-ui">Upload Blind Spot&#39;s PDF</b> and choose Blind Spot&#39;s blank form (2 pages, A4).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled sample</b>: a made-up booking on the form. <b class="gd-ui">Sample billed to an insurer</b> also fills the claim number, the adjuster and the insurance company. Check every box.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars&#39; HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative&#39;s signature instead of Sam&#39;s.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for bookings</b>. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A new version of Blind Spot&#39;s form? Upload it the same way: it waits for <b class="gd-ui">Checked: use for bookings</b>, and bookings keep the version in use until then.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.</div></aside><p class="gd-p">The renter&#39;s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking&#39;s Drivers and documents tab, in the renter&#39;s Documents, and the signed Blind Spot agreement is attached to the &quot;Your signed rental agreement&quot; email. Admin &gt; Today lists the HST number, the upload and the check until they are done.</p></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes. Its rates by car class are in <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Insurer rates</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section><section class="gd-task" id="settings-promo-codes-end-dates-and-reminders" data-gd-task><h2 class="gd-h2">Promo codes: end dates and reminders</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, <b class="gd-ui">Promo codes</b>.</p><ul class="gd-ul"><li>Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.</li><li>A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.</li><li>A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with &quot;This code has expired&quot;.</li><li>A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.</li><li>The list shows each code&#39;s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.</li></ul></section><section class="gd-task" id="settings-card-coverage-which-credit-cards-include-rental-car-coverage" data-gd-task><h2 class="gd-h2">Card coverage: which credit cards include rental car coverage</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Card coverage</b> is the list renters see at <span class="gd-url">carmacars.ca/credit-card-rental-coverage</span> and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer&#39;s own document, and when it was last checked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a card under Change a card, open its official guide, correct what changed and press <b class="gd-ui">Save</b>. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A card whose numbers come from a published summary has Read in the issuer&#39;s own document unticked and the summary&#39;s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer&#39;s guide.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer&#39;s guide.</div></aside></section><section class="gd-task" id="settings-reviews-review-requests-and-google" data-gd-task><h2 class="gd-h2">Reviews: review requests and Google</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Reviews</b>: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile&#39;s own review link.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Google Business Profile: press <b class="gd-ui">Connect Google</b> and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A clear match stops that renter&#39;s reminders at once. A possible match waits in Reviews: press <b class="gd-ui">Confirm</b>, <b class="gd-ui">Not this renter</b> or <b class="gd-ui">Match to a booking</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and &quot;I already left a review&quot;, Mark reviewed and on-site reviews still stop the messages.</div></aside></section>');
select app.guide_release_section('va', 'live-visitors-and-live-chat', 'chapter', 'commissions', 'Customer service and Sales see who is on the site now and answer the live chat. The CarmaCars assistant answers first; you take over whenever you want.

## Live visitors

1. Open **Live** > **Live visitors**. "Live now" counts who is on the site now, "Visitors today" the people seen today. The page refreshes by itself every 15 seconds; the menu shows how many hot visitors are on the site. Each visitor shows a booking likelihood from 0 to 100 (Hot, Warm or Cold); the most likely to book come first.
2. "Why" gives the three strongest reasons, for example "Pickup tomorrow · Saw $320 for 3 days · Tapped to call". The badges are all the signals; the dots say how strong each is.
3. Each visitor shows a name when known, otherwise "Visitor from Toronto, phone", the page and car they are on, how many others look at that car now, and this visit''s pages.
4. Suggested: the next step and a message. Press **Invite to chat with this message**, or **Edit the message** first. Sales can **Offer a 10% discount code** (one per visitor a week). **Assign to Sales** hands the visitor to Sales with a task. When their dates are taken, **Suggest a similar free car** writes the message for you.
5. Press **Pages** for the whole visit. Press **Start a chat** to write your own short friendly message and press **Send**: the visitor sees it in a bubble.
6. A hot visitor raises an alert at the top of the page. Each action shows on the visitor ("Invited by Lena, 2 min ago"), so check it before writing.

## Follow-ups

Signals of known visitors raise tasks on To do with what to do, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours". Call or message, then mark the task done. A task closes by itself when the renter answers or pays. Follow-ups done count in My sales.

Renters also get one polite reminder email (and at most one more) when they leave an offer, the pay page or a change unanswered. Taking the follow-up task, a chat with you or a message from you stops these reminders: you are handling it.

## Live chat

1. Open **Live** > **Live chat**. The menu counts chats waiting for a person. Reply within 5 minutes.
2. Choose a conversation. Beside it: the visitor''s page, pages and signals, and the renter''s bookings when known.
3. Press **Take over** (or just write a reply): the assistant stops. Write and press **Send** or Enter. The visitor sees when you type.
4. **Hand back to the assistant** when you are done, or **Close**. A visitor who gave an email gets a copy of the chat.
5. Tick "Email me when a chat waits (while I am on shift)" or desktop alerts if you want them.

> Tip: Prices: send a quote from New quote, never a price from memory. If you handled the chat, choose "I sourced this client" on the quote; nothing is credited by itself.
', 'Live visitors and live chat', 'Who is on the site, how likely each visitor is to book, one-click actions, follow-ups, the chat inbox.',
  'Customer service and Sales see who is on the site now and answer the live chat. The CarmaCars assistant answers first; you take over whenever you want.

## Live visitors

1. Open **Live** > **Live visitors**. "Live now" counts who is on the site now, "Visitors today" the people seen today. The page refreshes by itself every 15 seconds; the menu shows how many hot visitors are on the site. Each visitor shows a booking likelihood from 0 to 100 (Hot, Warm or Cold); the most likely to book come first.
2. "Why" gives the three strongest reasons, for example "Pickup tomorrow · Saw $320 for 3 days · Tapped to call". The badges are all the signals; the dots say how strong each is.
3. Each visitor shows a name when known, otherwise "Visitor from Toronto, phone", the page and car they are on, how many others look at that car now, and this visit''s pages.
4. Suggested: the next step and a message. Press **Invite to chat with this message**, or **Edit the message** first. Sales can **Offer a 10% discount code** (one per visitor a week). **Assign to Sales** hands the visitor to Sales with a task. When their dates are taken, **Suggest a similar free car** writes the message for you.
5. Press **Pages** for the whole visit. Press **Start a chat** to write your own short friendly message and press **Send**: the visitor sees it in a bubble.
6. A hot visitor raises an alert at the top of the page. Each action shows on the visitor ("Invited by Lena, 2 min ago"), so check it before writing.

## Name a visitor

When you learn who a visitor is (they called, or told you in the chat), press **Name** on their line, type the name and, if you have them, their phone, email and a note, then press **Save the name**. The name shows on Live visitors, Visitor history and Live chat, and on every later visit from the same browser. Only staff see it. A phone you add also saves them as a contact in Quo. If they later book or sign in, the name the booking has replaces yours. **Edit name** changes it; **Remove the name** takes it off.

## Follow-ups

Signals of known visitors raise tasks on To do with what to do, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours". Call or message, then mark the task done. A task closes by itself when the renter answers or pays. Follow-ups done count in My sales.

Renters also get one polite reminder email (and at most one more) when they leave an offer, the pay page or a change unanswered. Taking the follow-up task, a chat with you or a message from you stops these reminders: you are handling it.

## Live chat

1. Open **Live** > **Live chat**. The menu counts chats waiting for a person. Reply within 5 minutes.
2. Choose a conversation. Beside it: the visitor''s page, pages and signals, and the renter''s bookings when known.
3. Press **Take over** (or just write a reply): the assistant stops. Write and press **Send** or Enter. The visitor sees when you type.
4. **Hand back to the assistant** when you are done, or **Close**. A visitor who gave an email gets a copy of the chat.
5. Tick "Email me when a chat waits (while I am on shift)" or desktop alerts if you want them.

> Tip: Prices: send a quote from New quote, never a price from memory. If you handled the chat, choose "I sourced this client" on the quote; nothing is credited by itself.
',
  '<p class="gd-p">Customer service and Sales see who is on the site now and answer the live chat. The CarmaCars assistant answers first; you take over whenever you want.</p><section class="gd-task" id="live-visitors-and-live-chat-live-visitors" data-gd-task><h2 class="gd-h2">Live visitors</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Live</b> &gt; <b class="gd-ui">Live visitors</b>. &quot;Live now&quot; counts who is on the site now, &quot;Visitors today&quot; the people seen today. The page refreshes by itself every 15 seconds; the menu shows how many hot visitors are on the site. Each visitor shows a booking likelihood from 0 to 100 (Hot, Warm or Cold); the most likely to book come first.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">&quot;Why&quot; gives the three strongest reasons, for example &quot;Pickup tomorrow · Saw $320 for 3 days · Tapped to call&quot;. The badges are all the signals; the dots say how strong each is.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each visitor shows a name when known, otherwise &quot;Visitor from Toronto, phone&quot;, the page and car they are on, how many others look at that car now, and this visit&#39;s pages.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Suggested: the next step and a message. Press <b class="gd-ui">Invite to chat with this message</b>, or <b class="gd-ui">Edit the message</b> first. Sales can <b class="gd-ui">Offer a 10% discount code</b> (one per visitor a week). <b class="gd-ui">Assign to Sales</b> hands the visitor to Sales with a task. When their dates are taken, <b class="gd-ui">Suggest a similar free car</b> writes the message for you.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Pages</b> for the whole visit. Press <b class="gd-ui">Start a chat</b> to write your own short friendly message and press <b class="gd-ui">Send</b>: the visitor sees it in a bubble.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A hot visitor raises an alert at the top of the page. Each action shows on the visitor (&quot;Invited by Lena, 2 min ago&quot;), so check it before writing.</div></li></ol></div></section><section class="gd-task" id="live-visitors-and-live-chat-name-a-visitor" data-gd-task><h2 class="gd-h2">Name a visitor</h2><p class="gd-p">When you learn who a visitor is (they called, or told you in the chat), press <b class="gd-ui">Name</b> on their line, type the name and, if you have them, their phone, email and a note, then press <b class="gd-ui">Save the name</b>. The name shows on Live visitors, Visitor history and Live chat, and on every later visit from the same browser. Only staff see it. A phone you add also saves them as a contact in Quo. If they later book or sign in, the name the booking has replaces yours. <b class="gd-ui">Edit name</b> changes it; <b class="gd-ui">Remove the name</b> takes it off.</p></section><section class="gd-task" id="live-visitors-and-live-chat-follow-ups" data-gd-task><h2 class="gd-h2">Follow-ups</h2><p class="gd-p">Signals of known visitors raise tasks on To do with what to do, for example &quot;Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours&quot;. Call or message, then mark the task done. A task closes by itself when the renter answers or pays. Follow-ups done count in My sales.</p><p class="gd-p">Renters also get one polite reminder email (and at most one more) when they leave an offer, the pay page or a change unanswered. Taking the follow-up task, a chat with you or a message from you stops these reminders: you are handling it.</p></section><section class="gd-task" id="live-visitors-and-live-chat-live-chat" data-gd-task><h2 class="gd-h2">Live chat</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Live</b> &gt; <b class="gd-ui">Live chat</b>. The menu counts chats waiting for a person. Reply within 5 minutes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a conversation. Beside it: the visitor&#39;s page, pages and signals, and the renter&#39;s bookings when known.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take over</b> (or just write a reply): the assistant stops. Write and press <b class="gd-ui">Send</b> or Enter. The visitor sees when you type.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Hand back to the assistant</b> when you are done, or <b class="gd-ui">Close</b>. A visitor who gave an email gets a copy of the chat.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Tick &quot;Email me when a chat waits (while I am on shift)&quot; or desktop alerts if you want them.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Prices: send a quote from New quote, never a price from memory. If you handled the chat, choose &quot;I sourced this client&quot; on the quote; nothing is credited by itself.</div></aside></section>');
select app.guide_release_section('va', 'texts-and-calls', 'chapter', 'live-visitors-and-live-chat', 'Customer service and Sales answer texts to the CarmaCars number in the same place as live chat. Every call and text is kept with the renter, owner or lead it belongs to.

## Answer a text

1. Open **Live** > **Live chat** and press **Texts and calls**. Unread texts and missed calls are counted on each number.
2. Choose a number: calls and texts in order, and beside them who it is, with their bookings.
3. Write the text and press **Send text**. It goes from the CarmaCars number.
4. **Suggest a reply** writes a draft into the box. Read it and change it: it is never sent until you press Send text.

## Unknown callers

Press **Unknown callers**. Type the name if they told you and press **Create lead**, or find the renter and press **Link to** their name.

## Missed calls

A missed call gives you the task "Missed call from ..." when you have Live chat or Texts and calls open; otherwise it waits in the customer service queue. Call back with the Call button, or text, then mark the task done. Quo itself texts the caller back, so do not send the same message again.

> Tip: A number that texted STOP gets no texts from us, booking texts included, until they text START. Prices go in a quote, never in a text from memory.

## Email, text or both

Each renter and owner chooses how we reach them. Their page in Admin shows it under How we reach them; ask an Admin, or change it there if you can open the page. Texts need a phone they verified with a code. Your own choice is on your Profile, under Messages.
', 'Texts and calls', 'Reading and answering texts, suggestions, unknown callers and missed calls.',
  'Customer service and Sales answer texts to the CarmaCars number in the same place as live chat. Every call and text is kept with the renter, owner or lead it belongs to.

## Answer a text

1. Open **Live** > **Live chat** and press **Texts and calls**. Unread texts and missed calls are counted on each number.
2. Choose a number: calls and texts in order, and beside them who it is, with their bookings.
3. Write the text and press **Send text**. It goes from the CarmaCars number.
4. **Suggest a reply** writes a draft into the box. Read it and change it: it is never sent until you press Send text.

## Unknown callers

Press **Unknown callers**. Type the name if they told you and press **Create lead**, or find the renter and press **Link to** their name.

Quo''s contacts follow the site: everyone on the site with a phone number is a contact in Quo under the same name, added or updated within about five minutes. Change a name or number on the site, not in Quo: the site''s version is sent again.

## Missed calls

A missed call gives you the task "Missed call from ..." when you have Live chat or Texts and calls open; otherwise it waits in the customer service queue. Call back with the Call button, or text, then mark the task done. Quo itself texts the caller back, so do not send the same message again.

> Tip: A number that texted STOP gets no texts from us, booking texts included, until they text START. Prices go in a quote, never in a text from memory.

## Email, text or both

Each renter and owner chooses how we reach them. Their page in Admin shows it under How we reach them; ask an Admin, or change it there if you can open the page. Texts need a phone they verified with a code. Your own choice is on your Profile, under Messages.
',
  '<p class="gd-p">Customer service and Sales answer texts to the CarmaCars number in the same place as live chat. Every call and text is kept with the renter, owner or lead it belongs to.</p><section class="gd-task" id="texts-and-calls-answer-a-text" data-gd-task><h2 class="gd-h2">Answer a text</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Live</b> &gt; <b class="gd-ui">Live chat</b> and press <b class="gd-ui">Texts and calls</b>. Unread texts and missed calls are counted on each number.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a number: calls and texts in order, and beside them who it is, with their bookings.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the text and press <b class="gd-ui">Send text</b>. It goes from the CarmaCars number.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Suggest a reply</b> writes a draft into the box. Read it and change it: it is never sent until you press Send text.</div></li></ol></div></section><section class="gd-task" id="texts-and-calls-unknown-callers" data-gd-task><h2 class="gd-h2">Unknown callers</h2><p class="gd-p">Press <b class="gd-ui">Unknown callers</b>. Type the name if they told you and press <b class="gd-ui">Create lead</b>, or find the renter and press <b class="gd-ui">Link to</b> their name.</p><p class="gd-p">Quo&#39;s contacts follow the site: everyone on the site with a phone number is a contact in Quo under the same name, added or updated within about five minutes. Change a name or number on the site, not in Quo: the site&#39;s version is sent again.</p></section><section class="gd-task" id="texts-and-calls-missed-calls" data-gd-task><h2 class="gd-h2">Missed calls</h2><p class="gd-p">A missed call gives you the task &quot;Missed call from ...&quot; when you have Live chat or Texts and calls open; otherwise it waits in the customer service queue. Call back with the Call button, or text, then mark the task done. Quo itself texts the caller back, so do not send the same message again.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A number that texted STOP gets no texts from us, booking texts included, until they text START. Prices go in a quote, never in a text from memory.</div></aside></section><section class="gd-task" id="texts-and-calls-email-text-or-both" data-gd-task><h2 class="gd-h2">Email, text or both</h2><p class="gd-p">Each renter and owner chooses how we reach them. Their page in Admin shows it under How we reach them; ask an Admin, or change it there if you can open the page. Texts need a phone they verified with a code. Your own choice is on your Profile, under Messages.</p></section>');
-- GUIDES 0190 END
