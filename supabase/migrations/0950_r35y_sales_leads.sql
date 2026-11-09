-- 0950: one Sales lead list with claims, outcomes and a Sales dashboard (release 35, part Y; docs/changes/2026-11-08-r35-leads.md).
-- The owner, November 8 (item 12): every "New lead" alert links to THAT lead; a live-chat lead says "Live chat" and shows its
-- phone; one comprehensive Sales lead list (Admin, Sales and customer service, the same on the staff portal) with every lead:
-- renter leads (forms, chat, phone box, games, expired offers, abandoned requests, missed calls with no booking, Live
-- visitors signals), owner leads, fleet supplier and partner enquiries; claim rules in Settings > Sales; a Sales dashboard.
--
-- 1. Every lead is a row of `leads` (most already are). Two sources that were not get one there by the 15-minute job
--    (app.job_capture, as 0741 did for expired offers), once each: an inbound call missed and not handled, from a number
--    with no live booking (source missed_call), and a Hot visitor on Live visitors who left an email, with analytics consent
--    and no lead or booking in 30 days (source visitor_signal). Neither raises a new-lead alert (each has its own alert).
-- 2. The source in plain words (app.sl_source, also the alert's words, so a live chat lead says "Live chat"); the phone of
--    a lead falls back to its live chat or its typed contact (app.sl_phone), and leads saved without the phone they had get
--    it now (one-time, data-driven).
-- 3. Claims (lead_claims, the request-claim pattern of 0177): a claim holds a lead for the minutes of its type (Settings >
--    Sales, 15 by default, renter, owner and partner each); each logged contact (call, text, email, note) extends it by the
--    same window up to sales_lead_settings.extend_max_minutes (60) from the claim; Unclaim at any time; an expired claim
--    returns the lead to the pool (logged as expire); at most max_active (25) live claims a person; an Admin reassigns or
--    releases; Next lead claims the oldest hot unclaimed lead. Every step is in lead_claim_log.
-- 4. Outcomes on the lead: contacted, call booked, applied, won, lost with a reason; handled. A confirmed booking of the
--    lead's contact within 60 days marks the open lead won, credited to the booking's Sales person (the existing
--    attribution of 0057/0177), else to the person who last claimed it.
-- 5. Reads and actions through the door (admin, va and ops calls; each function checks the person): sales_leads,
--    sales_lead, sales_dashboard, sales_lead_settings; lead_claim, lead_unclaim, lead_contact, lead_outcome, lead_handled,
--    lead_reassign, lead_next, sales_lead_settings_save.
-- 6. The alerts (0460) and the owner application email link the lead's own page: /admin/sales-leads/<id> for Admins,
--    /staff/sales-leads/<id> for staff.
-- No applied migration is edited; app.door, app.job_capture and app.notification_payload are wrapped.
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
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0950: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. settings, outcomes, claims
create table if not exists sales_lead_settings (
  id                 boolean primary key default true check (id),
  claim_minutes      jsonb not null default '{"renter": 15, "owner": 15, "partner": 15}'::jsonb,
  extend_max_minutes integer not null default 60 check (extend_max_minutes between 5 and 480),
  max_active         integer not null default 25 check (max_active between 1 and 500),
  hot_hours          integer not null default 24 check (hot_hours between 1 and 720),
  updated_at         timestamptz not null default now(),
  updated_by         uuid references users (id)
);
comment on table sales_lead_settings is 'Settings > Sales (0950): how long a lead claim holds per lead type, the most a claim can be extended to, the live claims a person may hold, and how long a lead counts as hot.';
insert into sales_lead_settings (id) values (true) on conflict do nothing;
alter table sales_lead_settings enable row level security;

alter table leads
  add column if not exists sales_outcome text check (sales_outcome in ('contacted', 'call_booked', 'applied', 'won', 'lost')),
  add column if not exists sales_outcome_reason text check (length(sales_outcome_reason) <= 300),
  add column if not exists sales_outcome_at timestamptz,
  add column if not exists sales_outcome_by uuid references users (id),
  add column if not exists first_contact_at timestamptz,
  add column if not exists handled_at timestamptz,
  add column if not exists handled_by uuid references users (id),
  add column if not exists won_booking_id uuid references bookings (id) on delete set null;
comment on column leads.sales_outcome is 'Sales lead list (0950): contacted, call_booked, applied, won or lost (with sales_outcome_reason).';
comment on column leads.handled_at is 'Sales lead list (0950): the lead was marked handled (nothing more to do), or won or lost.';
create index if not exists leads_sales_outcome_idx on leads (sales_outcome_by, sales_outcome_at) where sales_outcome is not null;
create unique index if not exists leads_missed_call_once on leads ((payload ->> 'call_id')) where source = 'missed_call';
create unique index if not exists leads_visitor_signal_once on leads ((payload ->> 'visitor_id')) where source = 'visitor_signal';

create table if not exists lead_claims (
  lead_id     uuid primary key references leads (id) on delete cascade,
  claimed_by  uuid not null references users (id),
  claimed_at  timestamptz not null default now(),
  extended_at timestamptz,
  expires_at  timestamptz not null,
  cap_at      timestamptz not null
);
comment on table lead_claims is 'Sales lead list (0950): who holds a lead now. Live while expires_at is in the future; each logged contact extends it up to cap_at.';
create index if not exists lead_claims_by_idx on lead_claims (claimed_by, expires_at);
alter table lead_claims enable row level security;

create table if not exists lead_claim_log (
  id       bigserial primary key,
  lead_id  uuid not null references leads (id) on delete cascade,
  user_id  uuid not null references users (id),
  action   text not null check (action in ('claim', 'extend', 'unclaim', 'expire', 'reassign', 'release')),
  by_user  uuid references users (id),
  at       timestamptz not null default now(),
  note     text
);
comment on table lead_claim_log is 'Sales lead list (0950): each claim, extension, unclaim, expiry, reassignment and release, for the lead history and the Sales dashboard.';
create index if not exists lead_claim_log_user_idx on lead_claim_log (user_id, at);
create index if not exists lead_claim_log_lead_idx on lead_claim_log (lead_id, at);
alter table lead_claim_log enable row level security;

create table if not exists lead_contacts (
  id       uuid primary key default gen_random_uuid(),
  lead_id  uuid not null references leads (id) on delete cascade,
  by_user  uuid not null references users (id),
  channel  text not null check (channel in ('call', 'text', 'email', 'note')),
  note     text check (length(note) <= 1000),
  at       timestamptz not null default now()
);
comment on table lead_contacts is 'Sales lead list (0950): each call, text, email and note logged on a lead.';
create index if not exists lead_contacts_lead_idx on lead_contacts (lead_id, at);
create index if not exists lead_contacts_by_idx on lead_contacts (by_user, at);
alter table lead_contacts enable row level security;

-- ================================================================ 2. words, phone, type, who
create or replace function app.sl_is_chat(l leads) returns boolean
language sql stable security definer set search_path = public, app as $$
  select l.kind = 'chat' or l.source = 'chat' or coalesce(l.payload ->> 'form', '') = 'chat' or l.payload ? 'chat'
      or nullif(l.payload ->> 'chat_id', '') is not null or exists (select 1 from chat_conversations ch where ch.lead_id = l.id)
$$;

create or replace function app.sl_source(l leads) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when l.source = 'missed_call' then 'Missed call'
    when l.source = 'visitor_signal' then 'Live visitors signal'
    when l.source = 'expired_offer' then 'Expired offer'
    when l.source = 'unfinished_form' and l.payload ->> 'form' = 'phone_gate' then 'Phone number box'
    when app.sl_is_chat(l) then 'Live chat'
    when l.source = 'discount_game' then 'Discount game claim'
    when l.source = 'unfinished_form' and l.payload ->> 'form' = 'booking_request' then 'Booking request, not sent'
    when l.source = 'unfinished_form' and l.kind = 'owner_program' then 'Owner application, not finished'
    when l.source = 'unfinished_form' then 'Website form, unfinished'
    when l.kind = 'owner_program' and (l.payload ? 'calculator' or l.payload ? 'estimate') then 'Earnings calculator'
    when l.kind = 'owner_program' and l.pipeline_source = 'referral' then 'Owner referral'
    when l.kind = 'owner_program' then 'Owner program form'
    when l.kind = 'owner_recruit' then 'Classified ad'
    when l.kind = 'contact' then 'Contact form'
    when l.kind = 'buyer' then 'Find me this car'
    when l.kind = 'insurer' then 'Insurer form'
    when l.kind = 'launch_notice' then 'Launch notice sign-up'
    when l.kind = 'sample_car' then 'Sample car enquiry'
    when l.kind = 'place_request' then 'Place page enquiry'
    when l.kind = 'phone' then 'Phone call'
    when l.kind in ('finance', 'detailing', 'bodyshop', 'auto_service', 'chauffeur') then initcap(replace(l.kind, '_', ' ')) || ' enquiry'
    when l.source in ('web', 'website') then 'Website form'
    else initcap(replace(coalesce(nullif(l.source, ''), 'website'), '_', ' ')) end
$$;

-- the alert's words are the list's words (a live chat lead says "Live chat", never "Website form")
create or replace function app.lead_alert_source(l leads) returns text
language sql stable security definer set search_path = public, app as $$
  select app.sl_source(l)
$$;

create or replace function app.sl_phone(l leads) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(nullif(btrim(coalesce(l.phone, '')), ''),
    (select nullif(btrim(ch.phone), '') from chat_conversations ch where (ch.lead_id = l.id or ch.number::text = l.payload ->> 'chat' or ch.id::text = l.payload ->> 'chat_id') and nullif(btrim(coalesce(ch.phone, '')), '') is not null order by ch.created_at desc limit 1),
    (select cc.phone from contact_captures cc where cc.lead_id = l.id and cc.phone is not null order by cc.last_at desc limit 1))
$$;

-- renter, owner or partner (fleet suppliers, dealers, rental businesses, insurers)
create or replace function app.sl_type(l leads) returns text
language sql immutable as $$
  select case
    when l.kind = 'insurer' or l.contact_kind in ('dealer', 'rental_business', 'other_business') or coalesce(l.payload ->> 'form', '') in ('supplier', 'partner', 'fleet_supplier') then 'partner'
    when l.kind in ('owner_program', 'owner_recruit') then 'owner'
    else 'renter' end
$$;

-- an Admin, or staff with Sales or customer service (their own function or one they cover)
create or replace function app.sl_may(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and (coalesce(app.user_is_admin(p_user), false) or app.user_va_has(p_user, 'sales') or app.user_va_has(p_user, 'cs'))
$$;

-- the leads of the list: not spam, not a Turo guest, not a test address, not a private owner recruited from a classified ad
-- by a Sales person (their own pipeline); Sales see owner leads that are theirs or nobody's (0342)
create or replace function app.sl_listed(l leads) returns boolean
language sql stable security definer set search_path = public, app as $$
  select l.status <> 'spam' and l.kind <> 'turo_guest' and not app.email_is_test(l.email)
     and not (l.kind = 'owner_recruit' and coalesce(l.contact_kind, 'private_seller') = 'private_seller')
$$;

create or replace function app.sl_sees(p_user uuid, l leads) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.sl_listed(l) and (coalesce(app.user_is_admin(p_user), false) or app.user_va_has(p_user, 'cs')
    or (app.user_va_has(p_user, 'sales') and (app.sl_type(l) <> 'owner'
        or ((l.sourced_by is null or l.sourced_by = p_user) and (l.assigned_to is null or l.assigned_to = p_user))
        or app.lead_visible_to_sales(l.kind, l.sourced_by, l.assigned_to, l.payload, p_user)
        or exists (select 1 from lead_claims c where c.lead_id = l.id and c.claimed_by = p_user))))
$$;

create or replace function app.sl_settings() returns sales_lead_settings
language sql stable security definer set search_path = public, app as $$
  select s.* from sales_lead_settings s where s.id
$$;

create or replace function app.sl_window(p_type text) returns integer
language sql stable security definer set search_path = public, app as $$
  select greatest(1, least(240, coalesce((s.claim_minutes ->> p_type)::integer, 15))) from sales_lead_settings s where s.id
$$;

create or replace function app.sl_name(p_user uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(nullif(btrim(u.full_name), ''), u.email, 'Someone') from users u where u.id = p_user
$$;

-- fresh and hot first: the source (people waiting on a reply first), how new, and the value of what they asked for
create or replace function app.sl_priority(l leads, p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select case when l.handled_at is not null or l.status in ('converted', 'closed') then 0 else
    (case when l.source = 'missed_call' or app.sl_is_chat(l) or (l.source = 'unfinished_form' and l.payload ->> 'form' = 'phone_gate') or l.kind in ('contact', 'buyer') then 30
          when l.source in ('unfinished_form', 'visitor_signal') or l.kind = 'owner_program' then 20 else 10 end)
    + (case when l.created_at > p_now - interval '1 hour' then 30 when l.created_at > p_now - interval '24 hours' then 20 when l.created_at > p_now - interval '72 hours' then 10 else 0 end)
    + (case when coalesce((l.payload ->> 'quote_total_cents')::bigint, 0) > 0 then 5 else 0 end)
    + (case when l.first_contact_at is null then 5 else 0 end) end
$$;

-- ================================================================ 3. the claims
-- claims that ran out go back to the pool (logged once as expire); called by every read and change, and by the job
create or replace function app.sl_expire(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  with gone as (delete from lead_claims c where c.expires_at <= p_now returning c.lead_id, c.claimed_by, c.expires_at)
  insert into lead_claim_log (lead_id, user_id, action, at, note) select g.lead_id, g.claimed_by, 'expire', g.expires_at, 'The claim ran out' from gone g;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function app.sl_claim_json(p_lead uuid, p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when c.lead_id is null then null else jsonb_build_object('by', c.claimed_by, 'name', app.sl_name(c.claimed_by), 'since', c.claimed_at,
    'until', c.expires_at, 'cap', c.cap_at, 'mine', c.claimed_by = p_user) end
    from (select 1) one left join lead_claims c on c.lead_id = p_lead and c.expires_at > now()
$$;

create or replace function app.sl_lead_for(p_by uuid, p_id uuid, p_lock boolean default false) returns leads
language plpgsql security definer set search_path = public, app as $$
declare l leads;
begin
  if not app.sl_may(p_by) then raise exception 'Leads are for Admins, Sales and customer service' using errcode = '42501'; end if;
  if p_lock then select * into l from leads where id = p_id for update; else select * into l from leads where id = p_id; end if;
  if l.id is null or not app.sl_sees(p_by, l) then raise exception 'Lead not found' using errcode = 'P0002'; end if;
  return l;
end $$;

-- p: {lead}. Claim it for the window of its type; refused while someone else holds it or at the most live claims.
create or replace function app.lead_claim(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l leads;
  c lead_claims;
  s sales_lead_settings := app.sl_settings();
  v_win integer;
  n integer;
begin
  perform app.sl_expire();
  l := app.sl_lead_for(p_by, (p ->> 'lead')::uuid, true);
  select * into c from lead_claims where lead_id = l.id;
  if c.lead_id is not null and c.claimed_by = p_by then return jsonb_build_object('lead', l.id, 'claim', app.sl_claim_json(l.id, p_by)); end if;
  if c.lead_id is not null then
    raise exception '% is working on this lead until %. % ', app.sl_name(c.claimed_by), app.fmt_time(c.expires_at),
      case when app.user_is_admin(p_by) then 'Use Reassign to take it.' else 'It comes back to the pool if they stop.' end using errcode = '23514';
  end if;
  if l.handled_at is not null or l.status in ('converted', 'closed', 'spam') then raise exception 'This lead is closed: nothing to claim' using errcode = '23514'; end if;
  select count(*) into n from lead_claims x where x.claimed_by = p_by and x.expires_at > now();
  if n >= s.max_active then raise exception 'You hold % leads already (the most is %): finish or unclaim one first', n, s.max_active using errcode = '23514'; end if;
  v_win := app.sl_window(app.sl_type(l));
  insert into lead_claims (lead_id, claimed_by, claimed_at, expires_at, cap_at)
  values (l.id, p_by, now(), now() + make_interval(mins => v_win), now() + make_interval(mins => greatest(v_win, s.extend_max_minutes)));
  insert into lead_claim_log (lead_id, user_id, action, by_user) values (l.id, p_by, 'claim', p_by);
  return jsonb_build_object('lead', l.id, 'claim', app.sl_claim_json(l.id, p_by));
end $$;

-- p: {lead}. Back to the pool at once (an Admin may release anyone's claim).
create or replace function app.lead_unclaim(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l leads;
  c lead_claims;
begin
  perform app.sl_expire();
  l := app.sl_lead_for(p_by, (p ->> 'lead')::uuid, true);
  select * into c from lead_claims where lead_id = l.id;
  if c.lead_id is null then return jsonb_build_object('lead', l.id, 'claim', null); end if;
  if c.claimed_by <> p_by and not app.user_is_admin(p_by) then raise exception 'Only % or an Admin can release this claim', app.sl_name(c.claimed_by) using errcode = '42501'; end if;
  delete from lead_claims where lead_id = l.id;
  insert into lead_claim_log (lead_id, user_id, action, by_user, note)
  values (l.id, c.claimed_by, case when c.claimed_by = p_by then 'unclaim' else 'release' end, p_by, nullif(btrim(coalesce(p ->> 'note', '')), ''));
  return jsonb_build_object('lead', l.id, 'claim', null);
end $$;

-- p: {lead, to}. An Admin gives the lead to a person: their claim (no limit on the count) and the lead assigned to them.
create or replace function app.lead_reassign(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l leads;
  c lead_claims;
  v_to uuid := nullif(p ->> 'to', '')::uuid;
  s sales_lead_settings := app.sl_settings();
  v_win integer;
begin
  perform app.assert_admin(p_by);
  perform app.sl_expire();
  l := app.sl_lead_for(p_by, (p ->> 'lead')::uuid, true);
  if v_to is null or not app.sl_may(v_to) or app.staff_is_test(v_to) then raise exception 'Choose a person with Sales or customer service' using errcode = '22023'; end if;
  select * into c from lead_claims where lead_id = l.id;
  if c.lead_id is not null then
    delete from lead_claims where lead_id = l.id;
    if c.claimed_by <> v_to then insert into lead_claim_log (lead_id, user_id, action, by_user, note) values (l.id, c.claimed_by, 'release', p_by, 'Reassigned by an Admin'); end if;
  end if;
  v_win := app.sl_window(app.sl_type(l));
  insert into lead_claims (lead_id, claimed_by, claimed_at, expires_at, cap_at)
  values (l.id, v_to, now(), now() + make_interval(mins => v_win), now() + make_interval(mins => greatest(v_win, s.extend_max_minutes)));
  insert into lead_claim_log (lead_id, user_id, action, by_user) values (l.id, v_to, 'reassign', p_by);
  update leads set assigned_to = v_to, updated_at = now() where id = l.id;
  return jsonb_build_object('lead', l.id, 'claim', app.sl_claim_json(l.id, p_by));
end $$;

-- p: {lead, channel: call|text|email|note, note}. Logged on the lead; extends the person's claim by the window up to the cap;
-- claims the lead for them when nobody holds it.
create or replace function app.lead_contact(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l leads;
  c lead_claims;
  v_ch text := p ->> 'channel';
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_win integer;
begin
  perform app.sl_expire();
  l := app.sl_lead_for(p_by, (p ->> 'lead')::uuid, true);
  if v_ch is null or v_ch not in ('call', 'text', 'email', 'note') then raise exception 'Choose call, text, email or note' using errcode = '22023'; end if;
  if v_ch = 'note' and v_note is null then raise exception 'Write the note' using errcode = '22023'; end if;
  if v_note is not null and length(v_note) > 1000 then raise exception 'Keep the note under 1000 characters' using errcode = '22023'; end if;
  select * into c from lead_claims where lead_id = l.id and expires_at > now();
  if c.lead_id is not null and c.claimed_by <> p_by and not app.user_is_admin(p_by) then
    raise exception '% is working on this lead until %', app.sl_name(c.claimed_by), app.fmt_time(c.expires_at) using errcode = '23514';
  end if;
  insert into lead_contacts (lead_id, by_user, channel, note) values (l.id, p_by, v_ch, v_note);
  if c.lead_id is not null and c.claimed_by = p_by then
    v_win := app.sl_window(app.sl_type(l));
    update lead_claims set expires_at = least(expires_at + make_interval(mins => v_win), cap_at), extended_at = now() where lead_id = l.id;
    insert into lead_claim_log (lead_id, user_id, action, by_user) values (l.id, p_by, 'extend', p_by);
  elsif c.lead_id is null and l.handled_at is null and l.status not in ('converted', 'closed') then
    begin
      perform app.lead_claim(p_by, jsonb_build_object('lead', l.id));
    exception when others then null;   -- at the most claims: the contact is still logged
    end;
  end if;
  if v_ch <> 'note' then
    update leads set first_contact_at = coalesce(first_contact_at, now()),
           status = case when status = 'new' then 'contacted' else status end,
           sales_outcome = coalesce(sales_outcome, 'contacted'), sales_outcome_at = case when sales_outcome is null then now() else sales_outcome_at end,
           sales_outcome_by = case when sales_outcome is null then p_by else sales_outcome_by end,
           pipeline_stage = case when kind = 'owner_program' and coalesce(pipeline_stage, 'new') = 'new' then 'contacted' else pipeline_stage end,
           updated_at = now()
     where id = l.id;
  end if;
  return jsonb_build_object('lead', l.id, 'claim', app.sl_claim_json(l.id, p_by));
end $$;

-- p: {lead, outcome, reason, booking}. Won and lost close the lead and end the claim.
create or replace function app.lead_outcome(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l leads;
  v_o text := p ->> 'outcome';
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_booking uuid;
  c lead_claims;
begin
  perform app.sl_expire();
  l := app.sl_lead_for(p_by, (p ->> 'lead')::uuid, true);
  if v_o is null or v_o not in ('contacted', 'call_booked', 'applied', 'won', 'lost') then raise exception 'Choose the outcome' using errcode = '22023'; end if;
  if v_o = 'lost' and v_reason is null then raise exception 'Say why the lead was lost' using errcode = '22023'; end if;
  if v_reason is not null and length(v_reason) > 300 then raise exception 'Keep the reason under 300 characters' using errcode = '22023'; end if;
  select * into c from lead_claims where lead_id = l.id and expires_at > now();
  if c.lead_id is not null and c.claimed_by <> p_by and not app.user_is_admin(p_by) then
    raise exception '% is working on this lead until %', app.sl_name(c.claimed_by), app.fmt_time(c.expires_at) using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p ->> 'booking', '')), '') is not null then
    select b.id into v_booking from bookings b where b.booking_number = upper(btrim(p ->> 'booking')) or b.id::text = btrim(p ->> 'booking');
    if v_booking is null then raise exception 'No booking %', btrim(p ->> 'booking') using errcode = 'P0002'; end if;
  end if;
  update leads set sales_outcome = v_o, sales_outcome_reason = v_reason, sales_outcome_at = now(), sales_outcome_by = p_by,
         won_booking_id = case when v_o = 'won' then coalesce(v_booking, won_booking_id) else won_booking_id end,
         status = case v_o when 'won' then 'converted' when 'lost' then 'closed' else case when status = 'new' then 'contacted' else status end end,
         closed_reason = case when v_o = 'lost' then v_reason else closed_reason end,
         handled_at = case when v_o in ('won', 'lost') then now() else handled_at end,
         handled_by = case when v_o in ('won', 'lost') then p_by else handled_by end,
         pipeline_stage = case when kind = 'owner_program' and v_o in ('contacted', 'call_booked', 'applied', 'lost') then v_o else pipeline_stage end,
         updated_at = now()
   where id = l.id;
  if v_o in ('won', 'lost') and c.lead_id is not null then
    delete from lead_claims where lead_id = l.id;
    insert into lead_claim_log (lead_id, user_id, action, by_user, note) values (l.id, c.claimed_by, 'release', p_by, 'Lead ' || v_o);
  end if;
  return jsonb_build_object('lead', l.id, 'outcome', v_o);
end $$;

-- p: {lead, undo}. Nothing more to do (or open again with undo).
create or replace function app.lead_handled(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l leads;
  c lead_claims;
begin
  perform app.sl_expire();
  l := app.sl_lead_for(p_by, (p ->> 'lead')::uuid, true);
  if coalesce((p ->> 'undo')::boolean, false) then
    update leads set handled_at = null, handled_by = null, updated_at = now() where id = l.id;
    return jsonb_build_object('lead', l.id, 'handled', false);
  end if;
  select * into c from lead_claims where lead_id = l.id and expires_at > now();
  if c.lead_id is not null and c.claimed_by <> p_by and not app.user_is_admin(p_by) then
    raise exception '% is working on this lead until %', app.sl_name(c.claimed_by), app.fmt_time(c.expires_at) using errcode = '23514';
  end if;
  update leads set handled_at = now(), handled_by = p_by, status = case when status = 'new' then 'contacted' else status end, updated_at = now() where id = l.id;
  if c.lead_id is not null then
    delete from lead_claims where lead_id = l.id;
    insert into lead_claim_log (lead_id, user_id, action, by_user, note) values (l.id, c.claimed_by, 'release', p_by, 'Marked handled');
  end if;
  return jsonb_build_object('lead', l.id, 'handled', true);
end $$;

-- the open leads nobody holds that this person sees, oldest hot one first (then the oldest open one)
create or replace function app.sl_open_pool(p_by uuid, p_type text default null, p_now timestamptz default now()) returns setof leads
language sql stable security definer set search_path = public, app as $$
  select l.* from leads l
   where l.handled_at is null and l.status in ('new', 'contacted', 'qualified') and coalesce(l.sales_outcome, '') not in ('won', 'lost')
     and (p_type is null or app.sl_type(l) = p_type)
     and not exists (select 1 from lead_claims c where c.lead_id = l.id and c.expires_at > p_now)
     and l.created_at > p_now - interval '90 days'
     and app.sl_sees(p_by, l)
   order by (l.created_at > p_now - make_interval(hours => (app.sl_settings()).hot_hours)) desc, l.created_at asc
$$;

-- p: {type}. Next lead: claims the oldest hot unclaimed lead for this person.
create or replace function app.lead_next(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
  v_type text := nullif(p ->> 'type', '');
begin
  if not app.sl_may(p_by) then raise exception 'Leads are for Admins, Sales and customer service' using errcode = '42501'; end if;
  perform app.sl_expire();
  if v_type is not null and v_type not in ('renter', 'owner', 'partner') then raise exception 'Unknown lead type %', v_type using errcode = '22023'; end if;
  for v_id in select x.id from app.sl_open_pool(p_by, v_type) x limit 20 loop
    begin
      perform app.lead_claim(p_by, jsonb_build_object('lead', v_id));
      return jsonb_build_object('lead', v_id, 'claim', app.sl_claim_json(v_id, p_by));
    exception when sqlstate '23514' then
      if (select count(*) from lead_claims x where x.claimed_by = p_by and x.expires_at > now()) >= (app.sl_settings()).max_active then raise; end if;
    end;
  end loop;
  return jsonb_build_object('lead', null);
end $$;

-- ================================================================ 4. the reads
create or replace function app.sl_row(l leads, p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', l.id, 'type', app.sl_type(l), 'source', app.sl_source(l), 'source_key', l.source, 'kind', l.kind,
    'name', nullif(btrim(coalesce(l.name, '')), ''), 'phone', app.sl_phone(l), 'email', l.email,
    'excerpt', left(regexp_replace(coalesce(l.message, ''), '\s+', ' ', 'g'), 220), 'vehicle', coalesce(nullif(l.vehicle_text, ''), l.payload ->> 'vehicle', l.payload ->> 'car'),
    'created_at', l.created_at, 'status', l.status, 'outcome', l.sales_outcome, 'outcome_reason', l.sales_outcome_reason,
    'assigned_to', l.assigned_to, 'assigned_name', case when l.assigned_to is not null then app.sl_name(l.assigned_to) end,
    'claim', app.sl_claim_json(l.id, p_by), 'priority', app.sl_priority(l),
    'hot', l.handled_at is null and l.status in ('new', 'contacted', 'qualified') and l.created_at > now() - make_interval(hours => (app.sl_settings()).hot_hours),
    'value_cents', nullif(coalesce((l.payload ->> 'quote_total_cents')::bigint, 0), 0),
    'first_contact_at', l.first_contact_at, 'handled_at', l.handled_at, 'new', l.handled_at is null and l.first_contact_at is null and l.status = 'new')
$$;

-- p: {type, source, status, age, assigned, mine, q, sort, limit, offset}
create or replace function app.sales_leads(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_type text := nullif(p ->> 'type', '');
  v_source text := nullif(p ->> 'source', '');
  v_status text := coalesce(nullif(p ->> 'status', ''), 'open');
  v_age integer := nullif(p ->> 'age', '')::integer;
  v_assigned text := nullif(p ->> 'assigned', '');
  v_mine boolean := coalesce((p ->> 'mine')::boolean, false);
  v_q text := nullif(lower(btrim(coalesce(p ->> 'q', ''))), '');
  v_sort text := coalesce(nullif(p ->> 'sort', ''), 'priority');
  v_limit integer := least(greatest(coalesce((p ->> 'limit')::integer, 50), 1), 200);
  v_offset integer := greatest(coalesce((p ->> 'offset')::integer, 0), 0);
  v_digits text := regexp_replace(coalesce(p ->> 'q', ''), '\D', '', 'g');
  s sales_lead_settings := app.sl_settings();
  v_rows jsonb;
  v_count integer;
  v_sources jsonb;
begin
  if not app.sl_may(p_by) then raise exception 'Leads are for Admins, Sales and customer service' using errcode = '42501'; end if;
  perform app.sl_expire();
  with base as (
    select l as r, app.sl_source(l) src from leads l
     where app.sl_sees(p_by, l)
       and (v_type is null or app.sl_type(l) = v_type)
       and (v_age is null or l.created_at > now() - make_interval(days => v_age))
       and (v_assigned is null or (v_assigned = 'none' and l.assigned_to is null) or l.assigned_to::text = v_assigned)
       and (not v_mine or l.assigned_to = p_by or exists (select 1 from lead_claims c where c.lead_id = l.id and c.claimed_by = p_by and c.expires_at > now()))
       and (v_q is null or lower(coalesce(l.name, '') || ' ' || coalesce(l.email, '') || ' ' || coalesce(l.message, '') || ' ' || coalesce(l.vehicle_text, '')) like '%' || v_q || '%'
            or (length(v_digits) >= 4 and regexp_replace(coalesce(app.sl_phone(l), ''), '\D', '', 'g') like '%' || v_digits || '%'))
       and case v_status
             when 'open' then l.handled_at is null and l.status in ('new', 'contacted', 'qualified') and coalesce(l.sales_outcome, '') not in ('won', 'lost')
             when 'new' then l.handled_at is null and l.status = 'new' and l.first_contact_at is null
             when 'claimed' then exists (select 1 from lead_claims c where c.lead_id = l.id and c.expires_at > now())
             when 'unclaimed' then l.handled_at is null and l.status in ('new', 'contacted', 'qualified') and not exists (select 1 from lead_claims c where c.lead_id = l.id and c.expires_at > now())
             when 'contacted' then l.first_contact_at is not null and l.handled_at is null
             when 'won' then l.sales_outcome = 'won'
             when 'lost' then l.sales_outcome = 'lost' or l.status = 'closed'
             when 'handled' then l.handled_at is not null
             else true end
  ), f as (
    select b.r, b.src, app.sl_priority(b.r) pr, (b.r).created_at at from base b where v_source is null or b.src = v_source
  ), pg as (
    select f.r, f.pr, f.at from f
     order by case when v_sort = 'priority' then f.pr end desc nulls last, case when v_sort = 'oldest' then f.at end asc nulls last, f.at desc
     limit v_limit offset v_offset
  )
  select (select count(*) from f),
         coalesce((select jsonb_agg(app.sl_row(pg.r, p_by) order by case when v_sort = 'priority' then pg.pr end desc nulls last,
                                    case when v_sort = 'oldest' then pg.at end asc nulls last, pg.at desc) from pg), '[]'::jsonb),
         coalesce((select jsonb_agg(jsonb_build_object('source', z.src, 'n', z.n) order by z.n desc, z.src) from (select b.src, count(*) n from base b group by b.src) z), '[]'::jsonb)
    into v_count, v_rows, v_sources;
  return jsonb_build_object('rows', v_rows, 'count', v_count, 'sources', v_sources,
    'mine_active', (select count(*) from lead_claims c where c.claimed_by = p_by and c.expires_at > now()), 'max_active', s.max_active,
    'admin', coalesce(app.user_is_admin(p_by), false),
    'people', case when app.user_is_admin(p_by) then coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', app.sl_name(u.id)) order by app.sl_name(u.id))
                 from users u where u.status = 'active' and not app.staff_is_test(u.id) and app.sl_may(u.id)), '[]'::jsonb) else '[]'::jsonb end);
end $$;

-- p: {id}. One lead: the row, the full text (the form, the chat transcript), the calls, the contacts, the claim history.
create or replace function app.sales_lead(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l leads;
  v_chat uuid;
begin
  perform app.sl_expire();
  l := app.sl_lead_for(p_by, (p ->> 'id')::uuid);
  select ch.id into v_chat from chat_conversations ch
   where ch.lead_id = l.id or ch.number::text = l.payload ->> 'chat' or ch.id::text = l.payload ->> 'chat_id' order by ch.created_at desc limit 1;
  return app.sl_row(l, p_by) || jsonb_build_object(
    'message', l.message, 'source_url', l.source_url, 'owner_id', l.owner_id, 'pipeline_stage', l.pipeline_stage,
    'form', (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from jsonb_each_text(l.payload) e(k, v)
              where k in ('topic', 'booking_number', 'vehicle', 'car', 'pickup', 'return', 'pickup_at', 'return_at', 'budget', 'timeline', 'ownership', 'year', 'make', 'model', 'km', 'note')),
    'chat_id', v_chat,
    'transcript', coalesce((select jsonb_agg(jsonb_build_object('at', m.at, 'from', m.sender, 'text', left(m.body, 2000)) order by m.at)
                   from (select * from chat_messages m where m.conversation_id = v_chat order by m.at desc limit 200) m), '[]'::jsonb),
    'calls', coalesce((select jsonb_agg(jsonb_build_object('at', a.started_at, 'kind', a.kind, 'direction', a.direction, 'missed', a.missed, 'text', coalesce(a.ai_summary, a.voicemail_text, a.body)) order by a.started_at desc)
                   from (select * from phone_activity a where a.lead_id = l.id or a.id::text = l.payload ->> 'call_id' order by a.started_at desc limit 50) a), '[]'::jsonb),
    'contacts', coalesce((select jsonb_agg(jsonb_build_object('at', c.at, 'channel', c.channel, 'note', c.note, 'by', app.sl_name(c.by_user)) order by c.at desc)
                   from lead_contacts c where c.lead_id = l.id), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(jsonb_build_object('at', h.at, 'action', h.action, 'who', app.sl_name(h.user_id), 'by', case when h.by_user is distinct from h.user_id then app.sl_name(h.by_user) end, 'note', h.note) order by h.at desc, h.id desc)
                   from lead_claim_log h where h.lead_id = l.id), '[]'::jsonb),
    'outcome_by', case when l.sales_outcome_by is not null then app.sl_name(l.sales_outcome_by) end, 'outcome_at', l.sales_outcome_at,
    'won_booking', (select b.booking_number from bookings b where b.id = l.won_booking_id),
    'admin', coalesce(app.user_is_admin(p_by), false),
    'people', case when app.user_is_admin(p_by) then coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', app.sl_name(u.id)) order by app.sl_name(u.id))
                 from users u where u.status = 'active' and not app.staff_is_test(u.id) and app.sl_may(u.id)), '[]'::jsonb) else '[]'::jsonb end);
end $$;

-- the numbers of one person from p_from: claimed (claims and reassignments), won, close rate = won / claimed, contacted %
-- (claimed leads they then called, texted or emailed), average minutes from their claim to that first contact, expired claims
create or replace function app.sl_figures(p_user uuid, p_from timestamptz, p_to timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with cl as (
    select h.lead_id, min(h.at) at from lead_claim_log h
     where h.user_id = p_user and h.action in ('claim', 'reassign') and h.at >= p_from and h.at < p_to group by h.lead_id
  ), ct as (
    select cl.lead_id, cl.at, (select min(c.at) from lead_contacts c where c.lead_id = cl.lead_id and c.by_user = p_user and c.channel <> 'note' and c.at >= cl.at) first_at from cl
  ), w as (
    select count(*) n from leads l where l.sales_outcome = 'won' and l.sales_outcome_by = p_user and l.sales_outcome_at >= p_from and l.sales_outcome_at < p_to
  )
  select jsonb_build_object(
    'claimed', (select count(*) from cl),
    'won', (select n from w),
    'close_rate', case when (select count(*) from cl) = 0 then 0 else round(100.0 * (select n from w) / (select count(*) from cl))::integer end,
    'contacted_pct', case when (select count(*) from cl) = 0 then 0 else round(100.0 * (select count(*) from ct where first_at is not null) / (select count(*) from cl))::integer end,
    'first_contact_minutes', (select round(avg(extract(epoch from (first_at - at)) / 60.0))::integer from ct where first_at is not null),
    'expired', (select count(*) from lead_claim_log h where h.user_id = p_user and h.action = 'expire' and h.at >= p_from and h.at < p_to))
$$;

create or replace function app.sl_periods(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('today', app.local_midnight(app.local_date(p_now)),
    'week', app.local_midnight((app.local_date(p_now) - ((extract(isodow from app.local_date(p_now))::integer) - 1))),
    'month', app.local_midnight(app.month_start(app.local_date(p_now))))
$$;

-- p: {}. The person's own numbers for today, this week (from Monday) and this month; an Admin also gets the team and its
-- leaderboard (won, then close rate) for the period chosen (p.period: today, week, month; month by default).
create or replace function app.sales_dashboard(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  per jsonb := app.sl_periods(now());
  v_period text := coalesce(nullif(p ->> 'period', ''), 'month');
  v_team jsonb := null;
begin
  if not app.sl_may(p_by) then raise exception 'Leads are for Admins, Sales and customer service' using errcode = '42501'; end if;
  perform app.sl_expire();
  if v_period not in ('today', 'week', 'month') then v_period := 'month'; end if;
  if app.user_is_admin(p_by) then
    select coalesce(jsonb_agg(t.x || jsonb_build_object('rank', t.rk) order by t.rk), '[]'::jsonb) into v_team
      from (select y.x, row_number() over (order by (y.x ->> 'won')::integer desc, (y.x ->> 'close_rate')::integer desc, (y.x ->> 'claimed')::integer desc, y.x ->> 'name') rk
              from (select app.sl_figures(u.id, (per ->> v_period)::timestamptz) || jsonb_build_object('id', u.id, 'name', app.sl_name(u.id),
                             'active', (select count(*) from lead_claims c where c.claimed_by = u.id and c.expires_at > now())) x
                      from users u where u.status = 'active' and not app.staff_is_test(u.id) and app.sl_may(u.id) and not coalesce(app.user_is_admin(u.id), false)
                        and (app.user_va_has(u.id, 'sales') or exists (select 1 from lead_claim_log h where h.user_id = u.id))) y) t;
  end if;
  return jsonb_build_object('today', app.sl_figures(p_by, (per ->> 'today')::timestamptz), 'week', app.sl_figures(p_by, (per ->> 'week')::timestamptz),
    'month', app.sl_figures(p_by, (per ->> 'month')::timestamptz), 'period', v_period, 'team', v_team,
    'active', (select count(*) from lead_claims c where c.claimed_by = p_by and c.expires_at > now()), 'max_active', (app.sl_settings()).max_active,
    'open_pool', (select count(*) from app.sl_open_pool(p_by)));
end $$;

create or replace function app.sales_lead_settings_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare s sales_lead_settings := app.sl_settings();
begin
  if not app.sl_may(p_by) then raise exception 'Leads are for Admins, Sales and customer service' using errcode = '42501'; end if;
  return jsonb_build_object('claim_minutes', s.claim_minutes, 'extend_max_minutes', s.extend_max_minutes, 'max_active', s.max_active, 'hot_hours', s.hot_hours,
    'updated_at', s.updated_at, 'updated_by', case when s.updated_by is not null then app.sl_name(s.updated_by) end);
end $$;

-- p: {renter_minutes, owner_minutes, partner_minutes, extend_max_minutes, max_active, hot_hours}. Admins.
create or replace function app.sales_lead_settings_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s sales_lead_settings := app.sl_settings();
  v_m jsonb := s.claim_minutes;
  t text;
  v integer;
begin
  perform app.assert_admin(p_by);
  foreach t in array array['renter', 'owner', 'partner'] loop
    if nullif(p ->> (t || '_minutes'), '') is not null then
      v := (p ->> (t || '_minutes'))::integer;
      if v < 1 or v > 240 then raise exception 'A claim holds 1 to 240 minutes' using errcode = '22023'; end if;
      v_m := v_m || jsonb_build_object(t, v);
    end if;
  end loop;
  update sales_lead_settings set claim_minutes = v_m,
         extend_max_minutes = coalesce(nullif(p ->> 'extend_max_minutes', '')::integer, extend_max_minutes),
         max_active = coalesce(nullif(p ->> 'max_active', '')::integer, max_active),
         hot_hours = coalesce(nullif(p ->> 'hot_hours', '')::integer, hot_hours),
         updated_at = now(), updated_by = p_by
   where id;
  return app.sales_lead_settings_read(p_by, '{}'::jsonb);
end $$;

-- ================================================================ 5. the two new sources, the job
create or replace function app.sales_leads_sync(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  v_lead uuid;
  n integer := 0;
begin
  -- a call missed and not handled, from a number with no live booking and no staff, owner or open lead
  for r in
    select a.id, a.started_at, a.voicemail_text, t.id thread_id, t.number, t.name, t.renter_id
      from phone_activity a join phone_threads t on t.id = a.thread_id
     where a.kind = 'call' and a.direction = 'in' and a.missed and not a.missed_handled and a.lead_id is null
       and a.started_at > p_now - interval '7 days' and a.started_at <= p_now
       and t.staff_user_id is null and t.owner_id is null and nullif(btrim(t.number), '') is not null
       and not exists (select 1 from leads x where x.source = 'missed_call' and x.payload ->> 'call_id' = a.id::text)
       and not exists (select 1 from bookings b join renters rn on rn.id = b.renter_id
                        where (b.renter_id = t.renter_id or app.phone_e164(rn.mobile) = app.phone_e164(t.number))
                          and b.status::text in ('requested', 'offered', 'offer_sent', 'approved', 'confirmed', 'on_rent'))
       and not exists (select 1 from leads x where app.phone_e164(x.phone) = app.phone_e164(t.number) and x.handled_at is null
                        and x.status in ('new', 'contacted', 'qualified') and x.created_at > p_now - interval '7 days')
     order by a.started_at limit 200
  loop
    insert into leads (kind, name, phone, message, payload, source, status)
    values ('contact', nullif(btrim(coalesce(r.name, '')), ''), r.number,
            format('Missed call on %s.%s', to_char(r.started_at at time zone 'America/Toronto', 'Mon FMDD "at" FMHH12:MI am'),
                   coalesce(' Voicemail: ' || left(nullif(btrim(r.voicemail_text), ''), 500), '')),
            jsonb_build_object('form', 'missed_call', 'call_id', r.id, 'thread_id', r.thread_id, 'renter_id', r.renter_id), 'missed_call', 'new')
    on conflict do nothing
    returning id into v_lead;
    if v_lead is not null then
      update phone_activity set lead_id = v_lead where id = r.id and lead_id is null;
      n := n + 1;
    end if;
  end loop;
  -- a visitor who turned Hot and left an email (analytics consent), with no lead or booking in 30 days
  for r in
    select distinct on (lower(s.known_email)) s.id, s.visitor_id, s.known_name, lower(s.known_email) email, s.hot_at, s.score_reasons
      from visitor_sessions s
     where s.hot_at is not null and s.hot_at > p_now - interval '3 days' and s.hot_at <= p_now and s.consent = 'analytics'
       and s.audience is not distinct from 'renter' and nullif(btrim(coalesce(s.known_email, '')), '') is not null and not app.email_is_test(s.known_email)
       and (s.user_id is null or not exists (select 1 from user_roles ur where ur.user_id = s.user_id and ur.role::text in ('admin', 'va', 'field')))
       and not exists (select 1 from leads x where x.source = 'visitor_signal' and x.payload ->> 'visitor_id' = s.visitor_id::text)
       and not exists (select 1 from leads x where lower(x.email) = lower(s.known_email) and x.created_at > p_now - interval '30 days')
       and not exists (select 1 from bookings b join renters rn on rn.id = b.renter_id left join users u on u.id = rn.user_id
                        where lower(coalesce(rn.email, u.email)) = lower(s.known_email) and b.created_at > p_now - interval '30 days')
     order by lower(s.known_email), s.hot_at desc limit 200
  loop
    insert into leads (kind, name, email, message, payload, source, status)
    values ('contact', nullif(btrim(coalesce(r.known_name, '')), ''), r.email,
            'Hot on Live visitors: ' || coalesce((select string_agg(x ->> 'why', '; ') from (select x from jsonb_array_elements(coalesce(r.score_reasons, '[]'::jsonb)) x limit 3) z), 'a high score'),
            jsonb_build_object('form', 'visitor_signal', 'visitor_id', r.visitor_id, 'session_id', r.id), 'visitor_signal', 'new')
    on conflict do nothing
    returning id into v_lead;
    if v_lead is not null then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- a confirmed booking of the lead's contact closes the open lead as won, credited to the booking's Sales person (the
-- existing attribution), else to the person who last claimed the lead
create or replace function app.sl_booking_won() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  rn renters;
  v_email text;
  l record;
begin
  begin
    select * into rn from renters where id = new.renter_id;
    if rn.id is null then return null; end if;
    v_email := lower(coalesce(nullif(rn.email, ''), (select u.email from users u where u.id = rn.user_id)));
    for l in select x.id, (select h.user_id from lead_claim_log h where h.lead_id = x.id and h.action in ('claim', 'reassign') order by h.at desc, h.id desc limit 1) claimer
               from leads x
              where x.created_at between new.created_at - interval '60 days' and now() and coalesce(x.sales_outcome, '') not in ('won', 'lost')
                and x.status in ('new', 'contacted', 'qualified') and app.sl_type(x) = 'renter'
                and ((v_email is not null and lower(x.email) = v_email) or (app.phone_e164(rn.mobile) is not null and app.phone_e164(x.phone) = app.phone_e164(rn.mobile)))
    loop
      update leads set sales_outcome = 'won', sales_outcome_at = now(), sales_outcome_by = coalesce(new.sales_staff_id, l.claimer),
             won_booking_id = new.id, status = 'converted', handled_at = coalesce(handled_at, now()), updated_at = now()
       where id = l.id;
      delete from lead_claims where lead_id = l.id;
    end loop;
  exception when others then
    raise warning 'lead won not recorded for booking %: %', new.id, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists bookings_z_lead_won on bookings;
create trigger bookings_z_lead_won after update of status on bookings for each row
  when (new.status::text = 'confirmed' and old.status is distinct from new.status) execute function app.sl_booking_won();

-- no new-lead alert for the two synced sources (missed calls and hot visitors have their own alerts)
select pg_temp.patch_fn('app.lead_alert_lead(leads, text, leads)'::regprocedure,
  'if app.email_is_test(l.email) or l.status = ''spam'' then return; end if;',
  'if app.email_is_test(l.email) or l.status = ''spam'' or l.source in (''missed_call'', ''visitor_signal'') then return; end if;');

alter function app.job_capture(timestamptz) rename to job_capture_pre0950;
create function app.job_capture(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v text := app.job_capture_pre0950(p_now);
  n integer := 0;
  e integer := 0;
begin
  begin
    n := app.sales_leads_sync(p_now);
    e := app.sl_expire(p_now);
  exception when others then
    raise warning 'sales leads sync failed: %', sqlerrm;
  end;
  return v || case when n > 0 then format(', leads from calls and visitors %s', n) else '' end || case when e > 0 then format(', lead claims expired %s', e) else '' end;
end $$;
select pg_temp.copy_grants('app.job_capture(timestamptz)'::regprocedure, 'app.job_capture_pre0950(timestamptz)'::regprocedure);

-- ================================================================ 6. alerts link the lead
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0950;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := coalesce(app.ntf_payload_pre0950(p_code, p_event, p_to), '{}'::jsonb);
  v_lead text;
begin
  if p_code in ('staff_lead_new', 'staff_request_unfinished', 'staff_owner_lead_new', 'staff_owner_application_received') then
    v_lead := coalesce(nullif(p_event.payload ->> 'lead_id', ''), case when p_event.entity = 'lead' then p_event.entity_id::text end,
                       (select cc.lead_id::text from contact_captures cc where cc.id::text = p_event.payload ->> 'capture_id'));
    x := x || jsonb_build_object('_url', (app.settings()).notify_base_url
           || case when p_to ->> 'audience' = 'staff_admin' then '/admin/sales-leads' else '/staff/sales-leads' end || coalesce('/' || v_lead, ''));
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre0950(text, app_events, jsonb)'::regprocedure);

-- ================================================================ 7. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0950;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call in ('ops_read', 'va_read', 'admin_read') and p_name in ('sales_leads', 'sales_lead', 'sales_dashboard', 'sales_lead_settings'))
     or (p_call in ('ops_do', 'va_do', 'admin_do') and p_name in ('lead_claim', 'lead_unclaim', 'lead_contact', 'lead_outcome', 'lead_handled', 'lead_reassign', 'lead_next', 'sales_lead_settings_save')) then
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name
      when 'sales_leads' then app.sales_leads(p_user, p)
      when 'sales_lead' then app.sales_lead(p_user, p)
      when 'sales_dashboard' then app.sales_dashboard(p_user, p)
      when 'sales_lead_settings' then app.sales_lead_settings_read(p_user, p)
      when 'lead_claim' then app.lead_claim(p_user, p)
      when 'lead_unclaim' then app.lead_unclaim(p_user, p)
      when 'lead_contact' then app.lead_contact(p_user, p)
      when 'lead_outcome' then app.lead_outcome(p_user, p)
      when 'lead_handled' then app.lead_handled(p_user, p)
      when 'lead_reassign' then app.lead_reassign(p_user, p)
      when 'lead_next' then app.lead_next(p_user, p)
      else app.sales_lead_settings_save(p_user, p) end;
  end if;
  return app.door_pre0950(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0950(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 8. one-time: the phone a lead had
update leads l set phone = app.sl_phone(l), updated_at = now()
 where nullif(btrim(coalesce(l.phone, '')), '') is null and app.sl_phone(l) is not null;

-- ================================================================ 9. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['sl_is_chat', 'sl_source', 'lead_alert_source', 'sl_phone', 'sl_type', 'sl_may', 'sl_listed', 'sl_sees', 'sl_settings',
              'sl_window', 'sl_name', 'sl_priority', 'sl_expire', 'sl_claim_json', 'sl_lead_for', 'lead_claim', 'lead_unclaim', 'lead_reassign', 'lead_contact',
              'lead_outcome', 'lead_handled', 'sl_open_pool', 'lead_next', 'sl_row', 'sales_leads', 'sales_lead', 'sl_figures', 'sl_periods', 'sales_dashboard',
              'sales_lead_settings_read', 'sales_lead_settings_save', 'sales_leads_sync', 'sl_booking_won', 'door_pre0950', 'job_capture_pre0950', 'ntf_payload_pre0950'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- audited, and the Admin's read policy as every table (the screens read through the door)
create trigger audit_sales_lead_settings after insert or update or delete on sales_lead_settings for each row execute function app.audit_row();
create trigger audit_lead_claims after insert or update or delete on lead_claims for each row execute function app.audit_row();
create trigger audit_lead_claim_log after insert or update or delete on lead_claim_log for each row execute function app.audit_row();
create trigger audit_lead_contacts after insert or update or delete on lead_contacts for each row execute function app.audit_row();
create policy admin_all on sales_lead_settings for select to authenticated using (app.is_admin());
create policy admin_all on lead_claims for select to authenticated using (app.is_admin());
create policy admin_all on lead_claim_log for select to authenticated using (app.is_admin());
create policy admin_all on lead_contacts for select to authenticated using (app.is_admin());
revoke all on sales_lead_settings, lead_claims, lead_claim_log, lead_contacts from anon, authenticated;
grant select, insert, update, delete on sales_lead_settings, lead_claims, lead_claim_log, lead_contacts to service_role;
grant usage on sequence lead_claim_log_id_seq to service_role;

-- SCHEMA_MARKER 0969 (0955 carries the account merge, 0969 the guide chapters)
