-- 3230 (release 48, SEO): where every lead and request came from, and duplicate leads
-- (docs/changes/2026-11-20-r48-seo.md).
--
-- The owner, Nov 20: "Lead page: show the source (ChatGPT/Google), the search terms and the landing page. Duplicate leads."
--
-- A. The source. The browser keeps the first visit's referring site, landing page, campaign tags and ad click id in a
--    first-party cookie (web/src/lib/track/source.ts); the server sends it with each lead and each request to book.
--    contact_sources keeps one row per lead or booking: the channel (Google search, Google Ads, Bing, ChatGPT, Perplexity,
--    Gemini, Copilot, Claude, DuckDuckGo, a campaign's own source, another site, direct), the referring page, the first
--    landing page, the campaign tags, the click id and the search terms when the visit carried them (utm_term, or the
--    q= of a referring search page). Google does not send the words searched: for a Google visit the lead page lists the
--    landing page's top Search Console queries (app.gsc_page_queries) and says so.
-- B. Duplicates. Leads of one kind of customer (renter, owner, partner) with the same email, the same phone (last ten
--    digits) or the same browser are shown on each other's page with one Merge button. The merge keeps the older lead,
--    fills its blanks, keeps the other's message and form under it, moves the calls, texts, chats, notes and To do's, and
--    closes the other as merged. The auto-merge rule (Program settings lead_auto_merge, lead_auto_merge_days): a new
--    website lead from someone who already has an open lead of the same kind inside the window joins it by itself.
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

-- ================================================================ 1. the channel of a visit
-- The host of a referring address ("https://chatgpt.com/c/1" -> "chatgpt.com"); a bare host passes through.
create or replace function app.referrer_host(p text) returns text
language sql immutable as $$
  select nullif(lower(regexp_replace(regexp_replace(btrim(coalesce(p, '')), '^[a-z]+://', '', 'i'), '[/?#].*$', '')), '')
$$;

-- The channel of a visit: an ad click id first, then the campaign source, then the referring site. AI answer engines and
-- the search engines are named; everything else falls to the advertising channels of 0167 (app.ad_channel_of).
create or replace function app.traffic_channel(p_source text, p_medium text, p_referrer text, p_click_kind text) returns text
language plpgsql immutable as $$
declare
  s text := lower(btrim(coalesce(p_source, '')));
  m text := lower(btrim(coalesce(p_medium, '')));
  h text := coalesce(app.referrer_host(p_referrer), '');
  c text := lower(btrim(coalesce(p_click_kind, '')));
  paid boolean := m in ('cpc', 'ppc', 'paid', 'paidsearch', 'paid_search', 'sem', 'ads');
begin
  if c in ('gclid', 'gbraid', 'wbraid') then return 'google_ads'; end if;
  if c = 'msclkid' then return 'bing_ads'; end if;
  -- AI answer engines: ChatGPT tags its links utm_source=chatgpt.com; the others are known by the referring site
  if s like '%chatgpt%' or s like '%openai%' or h ~ '(^|\.)(chatgpt\.com|chat\.openai\.com)$' then return 'chatgpt'; end if;
  if s like '%perplexity%' or h ~ '(^|\.)perplexity\.ai$' then return 'perplexity'; end if;
  if s like '%gemini%' or s = 'bard' or h ~ '^(gemini|bard)\.google\.com$' then return 'gemini'; end if;
  if s like '%copilot%' or h ~ '(^|\.)copilot\.microsoft\.com$' then return 'copilot'; end if;
  if s like 'claude%' or h ~ '(^|\.)claude\.ai$' then return 'claude'; end if;
  if h ~ '(^|\.)(meta\.ai|you\.com|phind\.com|kagi\.com|grok\.com)$' or s in ('meta.ai', 'you.com', 'grok') then return 'ai_other'; end if;
  if s like 'google%' and paid then return 'google_ads'; end if;
  if s like 'bing%' and paid then return 'bing_ads'; end if;
  if s = '' then
    if h ~ '(^|\.)duckduckgo\.com$' then return 'duckduckgo'; end if;
    if h ~ '(^|\.)yahoo\.' then return 'yahoo'; end if;
    if h ~ '(^|\.)(search\.brave\.com|ecosia\.org|startpage\.com|qwant\.com|yandex\.[a-z.]+|baidu\.com)$' then return 'search_other'; end if;
  elsif s like 'duckduckgo%' then return 'duckduckgo';
  elsif s like 'yahoo%' then return 'yahoo';
  end if;
  if c = 'fbclid' and s = '' and h = '' then return 'facebook'; end if;
  return app.ad_channel_of(nullif(s, ''), nullif(h, ''));
end $$;

alter function app.ad_channel_label(text) rename to ad_channel_label_pre3230;
create function app.ad_channel_label(p text) returns text
language sql immutable as $$
  select case p
    when 'google_ads' then 'Google Ads' when 'bing_ads' then 'Microsoft Ads (Bing)' when 'chatgpt' then 'ChatGPT' when 'perplexity' then 'Perplexity'
    when 'gemini' then 'Google Gemini' when 'copilot' then 'Microsoft Copilot' when 'claude' then 'Claude' when 'ai_other' then 'Another AI assistant'
    when 'duckduckgo' then 'DuckDuckGo' when 'yahoo' then 'Yahoo' when 'search_other' then 'Another search engine'
    else app.ad_channel_label_pre3230(p) end
$$;
select pg_temp.copy_grants('app.ad_channel_label(text)'::regprocedure, 'app.ad_channel_label_pre3230(text)'::regprocedure);

-- Whether a channel is an AI answer engine or a search engine (the lead list's badge).
create or replace function app.traffic_channel_group(p text) returns text
language sql immutable as $$
  select case when p in ('chatgpt', 'perplexity', 'gemini', 'copilot', 'claude', 'ai_other') then 'ai'
              when p in ('google', 'bing', 'duckduckgo', 'yahoo', 'search_other') then 'search'
              when p in ('google_ads', 'bing_ads') then 'ads'
              when p = 'direct' then 'direct' else 'other' end
$$;

-- ================================================================ 2. the stored source
create table contact_sources (
  id            uuid primary key default gen_random_uuid(),
  lead_id       uuid unique references leads (id) on delete cascade,
  booking_id    uuid unique references bookings (id) on delete cascade,
  visitor_id    uuid,
  channel       text not null,
  first_at      timestamptz,
  first_referrer text check (first_referrer is null or length(first_referrer) <= 300),
  first_landing text check (first_landing is null or length(first_landing) <= 300),
  last_referrer text check (last_referrer is null or length(last_referrer) <= 300),
  last_landing  text check (last_landing is null or length(last_landing) <= 300),
  utm_source    text, utm_medium text, utm_campaign text, utm_term text, utm_content text,
  click_kind    text check (click_kind is null or click_kind in ('gclid', 'gbraid', 'wbraid', 'msclkid', 'fbclid', 'ttclid')),
  click_id      text check (click_id is null or length(click_id) <= 200),
  search_terms  text check (search_terms is null or length(search_terms) <= 200),
  created_at    timestamptz not null default now(),
  check (num_nonnulls(lead_id, booking_id) = 1)
);
comment on table contact_sources is 'Where a lead or a request to book came from (3230): the first visit''s channel, referring page, landing page, campaign tags, ad click id and search terms, as the browser kept them. One row per lead or booking; the first write stays.';
create index contact_sources_visitor_idx on contact_sources (visitor_id) where visitor_id is not null;
create index contact_sources_channel_idx on contact_sources (channel, created_at);
create trigger audit_contact_sources after insert or update or delete on contact_sources for each row execute function app.audit_row();
alter table contact_sources enable row level security;
create policy admin_all on contact_sources for select to authenticated using (app.is_admin());

-- Text a browser sent, cut to size, with control characters removed; null when empty.
create or replace function app.src_text(p text, p_max integer) returns text
language sql immutable as $$ select nullif(left(btrim(regexp_replace(coalesce(p, ''), '[[:cntrl:]]', '', 'g')), p_max), '') $$;
-- A referring address without its query string and fragment (they can carry what a person typed elsewhere).
create or replace function app.src_page(p text) returns text
language sql immutable as $$ select app.src_text(regexp_replace(regexp_replace(coalesce(p, ''), '[?#].*$', ''), '^[a-z]+://', '', 'i'), 300) $$;
-- The words searched, when the referring page carried them (Bing, DuckDuckGo, Yahoo and Brave sometimes do; Google never).
create or replace function app.src_query(p text) returns text
language sql immutable as $$
  select app.src_text(replace(replace((regexp_match(coalesce(p, ''), '[?&](?:q|p|query|text)=([^&#]{1,200})'))[1], '+', ' '), '%20', ' '), 200)
$$;

-- Stores the source of a lead or a booking. p: {vid, first: {ref, landing, at, utm: {source, medium, campaign, term,
-- content}, click: {kind, id}}, last: {ref, landing}}. The first write stays; a lead's empty campaign columns are filled.
create or replace function app.contact_source_set(p_lead uuid, p_booking uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  f jsonb := coalesce(p -> 'first', '{}'::jsonb);
  l jsonb := coalesce(p -> 'last', '{}'::jsonb);
  u jsonb := coalesce(f -> 'utm', '{}'::jsonb);
  v_kind text := case when f -> 'click' ->> 'kind' in ('gclid', 'gbraid', 'wbraid', 'msclkid', 'fbclid', 'ttclid') then f -> 'click' ->> 'kind' end;
  v_ref text := f ->> 'ref';
  v_vid uuid := case when p ->> 'vid' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (p ->> 'vid')::uuid end;
  v_at timestamptz;
  v_id uuid;
begin
  if num_nonnulls(p_lead, p_booking) <> 1 or p is null or jsonb_typeof(p) <> 'object' then return null; end if;
  -- a lead the auto-merge rule joined to an older one: the source goes to the lead that was kept (its own stays if it has one)
  if p_lead is not null then select coalesce(x.merged_into, x.id) into p_lead from leads x where x.id = p_lead; end if;
  if num_nonnulls(p_lead, p_booking) <> 1 then return null; end if;
  begin v_at := (f ->> 'at')::timestamptz; exception when others then v_at := null; end;
  if v_at is not null and (v_at > now() + interval '1 day' or v_at < now() - interval '2 years') then v_at := null; end if;
  insert into contact_sources (lead_id, booking_id, visitor_id, channel, first_at, first_referrer, first_landing, last_referrer, last_landing,
                               utm_source, utm_medium, utm_campaign, utm_term, utm_content, click_kind, click_id, search_terms)
  values (p_lead, p_booking, v_vid, app.traffic_channel(u ->> 'source', u ->> 'medium', v_ref, v_kind), v_at,
          app.src_page(v_ref), app.src_text(split_part(f ->> 'landing', '?', 1), 300), app.src_page(l ->> 'ref'), app.src_text(split_part(l ->> 'landing', '?', 1), 300),
          app.src_text(u ->> 'source', 120), app.src_text(u ->> 'medium', 120), app.src_text(u ->> 'campaign', 120), app.src_text(u ->> 'term', 120), app.src_text(u ->> 'content', 120),
          v_kind, case when v_kind is not null then app.src_text(f -> 'click' ->> 'id', 200) end,
          coalesce(app.src_text(u ->> 'term', 200), app.src_query(v_ref)))
  on conflict do nothing
  returning id into v_id;
  if v_id is not null and p_lead is not null then
    update leads set utm_source = coalesce(utm_source, app.src_text(u ->> 'source', 120)), utm_medium = coalesce(utm_medium, app.src_text(u ->> 'medium', 120)),
                     utm_campaign = coalesce(utm_campaign, app.src_text(u ->> 'campaign', 120)), utm_term = coalesce(utm_term, app.src_text(u ->> 'term', 120)),
                     utm_content = coalesce(utm_content, app.src_text(u ->> 'content', 120)), referrer = coalesce(referrer, app.src_page(v_ref))
     where id = p_lead and (utm_source is null or referrer is null) and (u <> '{}'::jsonb or v_ref is not null);
  end if;
  return v_id;
end $$;

-- The server's call after a form is stored: a lead by its id, a request to book by its number, or a chauffeur request by
-- its reference (its lead).
create or replace function public.server_contact_source_set(p_lead uuid default null, p_booking_number text default null, p_chauffeur_ref text default null, p jsonb default null) returns uuid
language sql security definer set search_path = public, app as $$
  select app.contact_source_set(
    coalesce(p_lead, (select c.lead_id from chauffeur_requests c where p_chauffeur_ref is not null and c.reference = p_chauffeur_ref)),
    (select b.id from bookings b where p_booking_number is not null and b.booking_number = p_booking_number), p)
$$;

-- The landing page's top Google queries of the newest Search Console window (the words Google does not send with a visit).
create or replace function app.landing_queries(p_path text, p_limit integer default 5) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('query', q.query, 'clicks', q.clicks, 'impressions', q.impressions) order by q.clicks desc, q.impressions desc), '[]'::jsonb)
    from (select g.query, g.clicks, g.impressions from app.gsc_page_queries g
           where p_path is not null and g.page = p_path
             and g.window_end = (select max(window_end) from app.gsc_page_queries)
           order by g.clicks desc, g.impressions desc limit greatest(1, least(coalesce(p_limit, 5), 20))) q
$$;

-- What the lead pages show: the channel in plain words, the referring page, the landing page, the campaign, the search
-- terms and where they come from. Null when nothing was stored (an older lead, a call, a lead typed by staff).
create or replace function app.contact_source_json(p_lead uuid, p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'channel', c.channel, 'label', app.ad_channel_label(c.channel), 'group', app.traffic_channel_group(c.channel),
    'referrer', c.first_referrer, 'landing', c.first_landing, 'last_landing', nullif(c.last_landing, c.first_landing), 'first_at', c.first_at,
    'campaign', nullif(concat_ws(' / ', c.utm_source, c.utm_medium, c.utm_campaign), ''), 'click', c.click_kind,
    'terms', c.search_terms, 'terms_from', case when c.search_terms is null then null when c.utm_term is not null then 'campaign' else 'referrer' end,
    'queries', case when c.search_terms is null and c.channel in ('google', 'bing', 'duckduckgo', 'yahoo', 'search_other', 'google_ads') then app.landing_queries(c.first_landing) else '[]'::jsonb end)
    from contact_sources c where (p_lead is not null and c.lead_id = p_lead) or (p_booking is not null and c.booking_id = p_booking)
$$;

-- ================================================================ 3. duplicate leads
alter table leads
  add column if not exists merged_into uuid references leads (id) on delete set null,
  add column if not exists merged_at timestamptz,
  add column if not exists merged_by uuid references users (id) on delete set null,
  add column if not exists not_duplicate_of uuid[] not null default '{}';
comment on column leads.merged_into is 'Duplicate leads (3230): the lead this one was merged into; a merged lead is closed and listed nowhere.';
comment on column leads.not_duplicate_of is 'Duplicate leads (3230): leads a person marked as someone else (same phone or email, a different person or need): never offered for merging again.';
create index if not exists leads_merged_into_fk on leads (merged_into);
create index if not exists leads_merged_by_fk on leads (merged_by) where merged_by is not null;
create index if not exists leads_phone_key_idx on leads (app.phone_key(phone)) where phone is not null;

alter table program_settings
  add column if not exists lead_auto_merge boolean not null default true,
  add column if not exists lead_auto_merge_days integer not null default 14 check (lead_auto_merge_days between 1 and 365);
comment on column program_settings.lead_auto_merge is 'Duplicate leads (3230): a new website lead from a person who already has an open lead of the same kind (same email or phone) joins that lead by itself.';
comment on column program_settings.lead_auto_merge_days is 'Duplicate leads (3230): how many days back the auto-merge rule looks for the open lead.';

-- A lead that can be merged or merged into: a real enquiry, not one already merged, not spam, not a Turo guest record.
create or replace function app.lead_mergeable(l leads) returns boolean
language sql immutable as $$ select l.id is not null and l.merged_into is null and l.status <> 'spam' and l.kind <> 'turo_guest' $$;

-- The other leads of the same person and the same kind of customer: same email, same phone (last ten digits) or the same
-- browser. Oldest first.
create or replace function app.lead_duplicates(l leads) returns setof leads
language sql stable security definer set search_path = public, app as $$
  -- three indexed lookups (the email, the phone key, the browser), then the rules
  select o.* from leads o
   where o.id in (
           select x.id from leads x where l.email is not null and lower(x.email) = lower(l.email)
           union
           select x.id from leads x where length(coalesce(app.phone_key(l.phone), '')) = 10 and app.phone_key(x.phone) = app.phone_key(l.phone)
           union
           select b.lead_id from contact_sources a join contact_sources b on b.visitor_id = a.visitor_id
            where a.lead_id = l.id and a.visitor_id is not null and b.lead_id is not null)
     and app.lead_mergeable(l) and o.id <> l.id and app.lead_mergeable(o) and app.sl_type(o) = app.sl_type(l)
     and not (o.id = any (l.not_duplicate_of)) and not (l.id = any (o.not_duplicate_of))
   order by o.created_at, o.id
$$;

-- Why two leads are the same person, in words.
create or replace function app.lead_dup_why(l leads, o leads) returns text
language sql stable security definer set search_path = public, app as $$
  select concat_ws(' and ',
    case when l.email is not null and lower(o.email) = lower(l.email) then 'same email' end,
    case when app.phone_key(l.phone) is not null and app.phone_key(o.phone) = app.phone_key(l.phone) then 'same phone' end,
    case when exists (select 1 from contact_sources a join contact_sources b on b.visitor_id = a.visitor_id where a.lead_id = l.id and b.lead_id = o.id and a.visitor_id is not null) then 'same browser' end)
$$;

-- Merges p_dup into p_keep. p_by is the person (null: the auto-merge rule). Returns the kept lead's id.
create or replace function app.lead_merge(p_by uuid, p_keep uuid, p_dup uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  k leads; d leads;
  v_entry jsonb;
begin
  if p_keep is null or p_dup is null or p_keep = p_dup then raise exception 'Choose two different leads to merge' using errcode = '22023'; end if;
  -- always lock in id order, so two merges of the same pair cannot wait on each other
  perform 1 from leads where id in (p_keep, p_dup) order by id for update;
  select * into k from leads where id = p_keep;
  select * into d from leads where id = p_dup;
  if k.id is null or d.id is null then raise exception 'That lead no longer exists' using errcode = '22023'; end if;
  if not app.lead_mergeable(k) or not app.lead_mergeable(d) then raise exception 'One of these leads was already merged or cannot be merged' using errcode = '22023'; end if;
  if app.sl_type(k) <> app.sl_type(d) then raise exception 'A % lead and a % lead stay apart: they are different kinds of customer', app.sl_type(k), app.sl_type(d) using errcode = '22023'; end if;
  if p_by is not null and not (app.sl_sees(p_by, k) and app.sl_sees(p_by, d)) then raise exception 'You can only merge leads you can open' using errcode = '42501'; end if;
  if d.won_booking_id is not null and k.won_booking_id is not null and d.won_booking_id <> k.won_booking_id then
    raise exception 'Both leads were won with different bookings: they stay apart' using errcode = '22023';
  end if;

  v_entry := jsonb_strip_nulls(jsonb_build_object('id', d.id, 'received_at', d.created_at, 'source', app.sl_source(d), 'kind', d.kind, 'name', d.name, 'email', d.email, 'phone', d.phone,
    'message', d.message, 'form', nullif(d.payload - 'merged', '{}'::jsonb), 'source_url', d.source_url, 'merged_at', now(), 'merged_by', p_by, 'auto', p_by is null));
  update leads set
      name = coalesce(k.name, d.name), email = coalesce(k.email, d.email), phone = coalesce(k.phone, d.phone), message = coalesce(k.message, d.message),
      vehicle_text = coalesce(k.vehicle_text, d.vehicle_text), business_name = coalesce(k.business_name, d.business_name),
      referrer = coalesce(k.referrer, d.referrer), utm_source = coalesce(k.utm_source, d.utm_source), utm_medium = coalesce(k.utm_medium, d.utm_medium),
      utm_campaign = coalesce(k.utm_campaign, d.utm_campaign), utm_term = coalesce(k.utm_term, d.utm_term), utm_content = coalesce(k.utm_content, d.utm_content),
      owner_id = coalesce(k.owner_id, d.owner_id), won_booking_id = coalesce(k.won_booking_id, d.won_booking_id),
      -- marketing consent is kept only with its own wording and time
      consent_marketing = k.consent_marketing or d.consent_marketing,
      consent_text = case when k.consent_marketing then k.consent_text when d.consent_marketing then d.consent_text else k.consent_text end,
      consent_at = case when k.consent_marketing then k.consent_at when d.consent_marketing then d.consent_at else k.consent_at end,
      do_not_contact_at = coalesce(k.do_not_contact_at, d.do_not_contact_at),
      payload = k.payload || jsonb_build_object('merged', coalesce(k.payload -> 'merged', '[]'::jsonb) || (coalesce(d.payload -> 'merged', '[]'::jsonb)) || jsonb_build_array(v_entry)),
      not_duplicate_of = (select coalesce(array_agg(distinct x), '{}') from unnest(k.not_duplicate_of || d.not_duplicate_of) x where x not in (k.id, d.id))
   where id = k.id;

  -- everything said and done on the duplicate moves to the kept lead
  update lead_contacts set lead_id = k.id where lead_id = d.id;
  update lead_claim_log set lead_id = k.id where lead_id = d.id;
  update phone_threads set lead_id = k.id where lead_id = d.id;
  update phone_activity set lead_id = k.id where lead_id = d.id;
  update outbound_calls set lead_id = k.id where lead_id = d.id;
  update chat_conversations set lead_id = k.id where lead_id = d.id;
  update contact_captures set lead_id = k.id where lead_id = d.id;
  update chauffeur_requests set lead_id = k.id where lead_id = d.id;
  update game_claims set lead_id = k.id where lead_id = d.id;
  update phone_gate_contacts set lead_id = k.id where lead_id = d.id;
  update owner_applications set lead_id = k.id where lead_id = d.id;
  delete from lead_claims where lead_id = d.id;
  delete from lead_holds where lead_id = d.id;
  -- the source: the kept lead's own stays; without one it takes the duplicate's
  if not exists (select 1 from contact_sources where lead_id = k.id) then update contact_sources set lead_id = k.id where lead_id = d.id; end if;
  -- an open To do of the duplicate now opens the kept lead
  update tasks set related_id = k.id, detail = left(concat_ws(' ', detail, '(Merged: the same person already had a lead.)'), 2000)
   where related_table = 'leads' and related_id = d.id and status not in ('done', 'cancelled');

  update leads set status = 'closed', closed_reason = 'Duplicate: merged into the lead of ' || to_char(k.created_at at time zone 'America/Toronto', 'Mon DD, YYYY'),
      merged_into = k.id, merged_at = now(), merged_by = p_by, handled_at = coalesce(handled_at, now()), handled_by = coalesce(handled_by, p_by),
      followup_stopped_at = coalesce(followup_stopped_at, now()), followup_stop_reason = coalesce(followup_stop_reason, 'merged'), assigned_to = null
   where id = d.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, case when p_by is null then 'lead_auto_merge' else 'lead_merge' end, 'leads', k.id::text, to_jsonb(d), jsonb_build_object('kept', k.id, 'merged', d.id, 'auto', p_by is null));
  return k.id;
end $$;

-- Marks two leads as different people (or different needs): they are never offered for merging again.
create or replace function app.lead_not_duplicate(p_by uuid, p_lead uuid, p_other uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if p_lead is null or p_other is null or p_lead = p_other then raise exception 'Choose two different leads' using errcode = '22023'; end if;
  if not exists (select 1 from leads l where l.id = p_lead and app.sl_sees(p_by, l)) then raise exception 'You can only change leads you can open' using errcode = '42501'; end if;
  update leads set not_duplicate_of = array_append(not_duplicate_of, p_other) where id = p_lead and not (p_other = any (not_duplicate_of));
  update leads set not_duplicate_of = array_append(not_duplicate_of, p_lead) where id = p_other and not (p_lead = any (not_duplicate_of));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'lead_not_duplicate', 'leads', p_lead::text, jsonb_build_object('other', p_other));
end $$;

-- The auto-merge rule, at the end of the transaction that made the lead (its To do and alerts exist by then).
create or replace function app.lead_auto_merge() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  l leads;
  v_keep uuid;
begin
  if not coalesce(s.lead_auto_merge, false) then return null; end if;
  select * into l from leads where id = new.id;
  if not app.lead_mergeable(l) or l.status <> 'new' or l.handled_at is not null then return null; end if;
  -- only a form or a chat a person sent: never a record the system or staff made
  if l.source in ('missed_call', 'visitor_signal', 'expired_offer', 'unfinished_form', 'discount_game') or l.kind in ('owner_recruit', 'phone', 'launch_notice')
     or l.payload ? 'added_by' or l.sourced_by is not null then return null; end if;
  select o.id into v_keep from app.lead_duplicates(l) o
   where o.created_at < l.created_at and o.created_at >= l.created_at - make_interval(days => s.lead_auto_merge_days)
     and o.status in ('new', 'contacted', 'qualified') and o.handled_at is null and o.sales_outcome is distinct from 'won' and o.sales_outcome is distinct from 'lost'
     -- the email or the phone must match: the same browser alone (a shared computer) is offered, never merged by itself
     and ((l.email is not null and lower(o.email) = lower(l.email)) or (app.phone_key(l.phone) is not null and app.phone_key(o.phone) = app.phone_key(l.phone)))
   order by o.created_at limit 1;
  if v_keep is null then return null; end if;
  perform app.lead_merge(null, v_keep, l.id);
  return null;
exception when others then
  -- a merge that cannot be done never loses the lead: it stays as its own lead, offered for a one-click merge
  return null;
end $$;
create constraint trigger leads_zzz_auto_merge after insert on leads deferrable initially deferred for each row execute function app.lead_auto_merge();

-- ================================================================ 4. the lead list and the lead page
alter function app.sl_row(leads, uuid) rename to sl_row_pre3230;
create function app.sl_row(l leads, p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.sl_row_pre3230(l, p_by) || jsonb_build_object(
    'traffic', app.contact_source_json(l.id, null),
    'dups', (select count(*) from app.lead_duplicates(l) o where app.sl_sees(p_by, o)),
    'merged_into', l.merged_into,
    'merged_count', jsonb_array_length(coalesce(l.payload -> 'merged', '[]'::jsonb)))
$$;
select pg_temp.copy_grants('app.sl_row(leads, uuid)'::regprocedure, 'app.sl_row_pre3230(leads, uuid)'::regprocedure);

alter function app.sales_lead(uuid, jsonb) rename to sales_lead_pre3230;
create function app.sales_lead(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb;
  l leads;
  v_to uuid;
  n integer := 0;
begin
  -- a merged lead is listed nowhere: its page (an alert's link, a bookmark) opens the lead it was merged into
  if p ->> 'id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then select * into l from leads where id = (p ->> 'id')::uuid; end if;
  if l.merged_into is not null and app.sl_may(p_by) then
    v_to := l.merged_into;
    while n < 5 loop
      exit when (select x.merged_into from leads x where x.id = v_to) is null;
      select x.merged_into into v_to from leads x where x.id = v_to;
      n := n + 1;
    end loop;
    return jsonb_build_object('id', l.id, 'merged_into', v_to, 'moved', true);
  end if;
  v := app.sales_lead_pre3230(p_by, p);
  if v is null or not (v ? 'id') then return v; end if;
  select * into l from leads where id = (v ->> 'id')::uuid;
  return v || jsonb_build_object(
    'duplicates', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'email', o.email, 'phone', app.sl_row(o, p_by) ->> 'phone', 'source', app.sl_source(o),
        'created_at', o.created_at, 'status', o.status, 'outcome', o.sales_outcome, 'handled', o.handled_at is not null, 'excerpt', left(coalesce(o.message, ''), 160),
        'why', app.lead_dup_why(l, o), 'older', o.created_at < l.created_at) order by o.created_at)
      from app.lead_duplicates(l) o where app.sl_sees(p_by, o)), '[]'::jsonb),
    'merged', coalesce((select jsonb_agg(m - 'merged_by' - 'form' || jsonb_build_object('form', coalesce(m -> 'form', '{}'::jsonb) - 'added_by') order by m ->> 'received_at')
      from jsonb_array_elements(coalesce(l.payload -> 'merged', '[]'::jsonb)) m), '[]'::jsonb),
    'merged_into', l.merged_into);
end $$;
select pg_temp.copy_grants('app.sales_lead(uuid, jsonb)'::regprocedure, 'app.sales_lead_pre3230(uuid, jsonb)'::regprocedure);

-- The lead actions of the door: merge, merge every duplicate into the oldest, not a duplicate.
create or replace function app.lead_merge_do(p_by uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l leads; o leads;
  v_keep uuid; v_n integer := 0;
begin
  if not app.sl_may(p_by) then raise exception 'Leads are for Sales, customer service and Admins' using errcode = '42501'; end if;
  select * into l from leads where id = coalesce(p ->> 'lead', p ->> 'id')::uuid;
  if l.id is null or not app.sl_sees(p_by, l) then raise exception 'That lead no longer exists' using errcode = '22023'; end if;
  if p_name = 'lead_not_duplicate' then
    perform app.lead_not_duplicate(p_by, l.id, (p ->> 'other')::uuid);
    return jsonb_build_object('ok', true);
  end if;
  if p_name = 'lead_merge' then
    select * into o from leads where id = (p ->> 'other')::uuid;
    if o.id is null or not exists (select 1 from app.lead_duplicates(l) x where x.id = o.id) then raise exception 'These two leads do not share an email, a phone or a browser' using errcode = '22023'; end if;
    -- the older lead is kept: its history and its claim stay
    v_keep := case when (o.created_at, o.id) < (l.created_at, l.id) then o.id else l.id end;
    perform app.lead_merge(p_by, v_keep, case when v_keep = l.id then o.id else l.id end);
    return jsonb_build_object('ok', true, 'kept', v_keep, 'merged', 1);
  end if;
  if p_name = 'lead_merge_all' then
    select coalesce((select x.id from app.lead_duplicates(l) x where app.sl_sees(p_by, x) and (x.created_at, x.id) < (l.created_at, l.id) order by x.created_at, x.id limit 1), l.id) into v_keep;
    for o in select x.* from (select * from app.lead_duplicates(l) union select * from leads where id = l.id) x where x.id <> v_keep and app.sl_sees(p_by, x) order by x.created_at loop
      perform app.lead_merge(p_by, v_keep, o.id);
      v_n := v_n + 1;
    end loop;
    return jsonb_build_object('ok', true, 'kept', v_keep, 'merged', v_n);
  end if;
  raise exception 'Unknown lead call %', p_name using errcode = '22023';
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3230;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_do' and p_name in ('lead_merge', 'lead_merge_all', 'lead_not_duplicate') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.lead_merge_do(p_user, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre3230(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3230(uuid, text, text, text, jsonb)'::regprocedure);

-- A merged lead is listed nowhere: the lists read app.sl_listed.
alter function app.sl_listed(leads) rename to sl_listed_pre3230;
create function app.sl_listed(l leads) returns boolean
language sql stable security definer set search_path = public, app as $$ select l.merged_into is null and app.sl_listed_pre3230(l) $$;
select pg_temp.copy_grants('app.sl_listed(leads)'::regprocedure, 'app.sl_listed_pre3230(leads)'::regprocedure);

-- ================================================================ 5. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['referrer_host', 'traffic_channel', 'traffic_channel_group', 'ad_channel_label_pre3230', 'src_text', 'src_page', 'src_query',
             'contact_source_set', 'landing_queries', 'contact_source_json', 'lead_mergeable', 'lead_duplicates', 'lead_dup_why', 'lead_merge', 'lead_not_duplicate', 'lead_auto_merge',
             'sl_row_pre3230', 'sales_lead_pre3230', 'lead_merge_do', 'door_pre3230', 'sl_listed_pre3230']))
        or (n.nspname = 'public' and p.proname = 'server_contact_source_set')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
