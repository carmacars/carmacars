-- 1506_r35c_lead_intent.sql
-- Release 35, part C (item 5): intent signals per renter and per lead, from what they said (call transcripts and
-- summaries, voicemails, texts, emails, the site chat, the lead's own message and notes) and how they behave on the website
-- (visits, pages, cars looked at, the visitor score, a booking request). Rule-based (keywords and patterns, here in SQL),
-- with an optional AI reading on top (Workers AI, within the background share of the free daily allowance: a hard stop,
-- Program setting intent_ai_enabled) that only fills what the rules left empty.
--   signals: budget {amount_cents, per}, car_class, duration_days, dates, urgency (high, medium), delivery (true),
--            coverage (card, own_insurance, protection_plan, insurer_claim)
--   score 0 to 100 and label hot (70+), warm (40+), cold, or unknown (nothing to read)
-- Kept in intent_scores (one row per renter or lead), refreshed every 15 minutes for whoever had activity, and at once
-- when staff open the renter or the lead. Shown on the lead, the renter and the live map's pins.
-- No applied migration is edited: app.live_map and app.door are wrapped.
set local check_function_bodies = off;

alter table program_settings
  add column if not exists intent_ai_enabled boolean not null default true,
  add column if not exists intent_hot_score integer not null default 70 check (intent_hot_score between 1 and 100),
  add column if not exists intent_warm_score integer not null default 40 check (intent_warm_score between 1 and 100);
comment on column program_settings.intent_ai_enabled is 'Lead intent (1506): an AI reading fills the signals the rules left empty, within the background share of the free Workers AI allowance only (it stops when that is used).';

create table if not exists intent_scores (
  subject_kind text not null check (subject_kind in ('renter', 'lead')),
  subject_id   uuid not null,
  score        integer not null default 0 check (score between 0 and 100),
  label        text not null default 'unknown' check (label in ('hot', 'warm', 'cold', 'unknown')),
  signals      jsonb not null default '{}'::jsonb,
  reasons      jsonb not null default '[]'::jsonb,
  sources      integer not null default 0,
  text_sha     text,
  computed_at  timestamptz not null default now(),
  ai           jsonb,
  ai_sha       text,
  ai_at        timestamptz,
  ai_error     text,
  primary key (subject_kind, subject_id)
);
comment on table intent_scores is 'Lead intent (1506): a renter''s or a lead''s intent score, label and signals (rules; ai: what an AI reading added).';
alter table intent_scores enable row level security;
revoke all on intent_scores from anon, authenticated;
grant all on intent_scores to service_role;
create policy admin_all on intent_scores for select to authenticated using (app.is_admin());
drop trigger if exists audit_intent_scores on intent_scores;
create trigger audit_intent_scores after insert or update or delete on intent_scores for each row execute function app.audit_row();

-- ================================================================ the rules: one text in, the signals out
create function app.intent_extract(p_text text) returns jsonb
language plpgsql immutable as $$
declare
  t text := lower(coalesce(p_text, ''));
  m text[];
  out jsonb := '{}'::jsonb;
  v_days integer;
begin
  if btrim(t) = '' then return out; end if;
  -- budget: "$500 a week", "budget 80/day", "under 1200 a month"
  m := regexp_match(t, '(?:\$\s?|budget(?: is| of)?\s*\$?\s?|under\s*\$?\s?|max(?:imum)?\s*\$?\s?)([0-9]{2,5}(?:[.,][0-9]{2})?)\s*(?:dollars|cad|usd)?\s*(?:/|a |per |each )?\s*(day|daily|night|week|weekly|wk|month|monthly|mo)?');
  if m is not null then
    out := out || jsonb_build_object('budget', jsonb_build_object('amount_cents', (replace(m[1], ',', '')::numeric * 100)::bigint,
      'per', case when m[2] in ('day', 'daily', 'night') then 'day' when m[2] in ('week', 'weekly', 'wk') then 'week' when m[2] in ('month', 'monthly', 'mo') then 'month' else 'total' end));
  end if;
  -- the car class
  out := out || coalesce((select jsonb_build_object('car_class', c) from (values
      (1, 'suv', '\m(suv|jeep|range rover|x5|gle|gls|q7|escalade|tahoe|7[ -]?seat)'),
      (2, 'minivan', '\m(minivan|mini van|van|sienna|odyssey|caravan)\M'),
      (3, 'pickup', '\m(pickup|pick-up|truck|f-?150|ram 1500|silverado)\M'),
      (4, 'electric', '\m(electric|\mev\M|tesla|ioniq|taycan)'),
      (5, 'sports', '\m(sports? car|coupe|convertible|amg|m4|911|porsche|corvette|mustang)'),
      (6, 'luxury', '\m(luxury|mercedes|benz|bmw|audi|lexus|maybach|bentley|rolls)'),
      (7, 'economy', '\m(cheap|cheapest|economy|compact|small car|corolla|civic|elantra)'),
      (8, 'sedan', '\m(sedan|saloon|camry|accord|c[ -]?class|e[ -]?class|3 series)')) r(o, c, re)
     where t ~ re order by o limit 1), '{}'::jsonb);
  -- the length of the rental
  m := regexp_match(t, '([0-9]{1,3}|one|two|three|four|a couple of|a few)\s*(day|days|night|nights|week|weeks|wk|wks|month|months)\M');
  if m is not null then
    v_days := (case m[1] when 'one' then 1 when 'two' then 2 when 'three' then 3 when 'four' then 4 when 'a couple of' then 2 when 'a few' then 3 else m[1]::int end)
              * (case when m[2] like 'w%' then 7 when m[2] like 'month%' then 30 else 1 end);
    out := out || jsonb_build_object('duration_days', least(v_days, 365));
  elsif t ~ '\m(monthly|long[ -]term|for a month)\M' then out := out || jsonb_build_object('duration_days', 30);
  elsif t ~ '\mweekend\M' then out := out || jsonb_build_object('duration_days', 2);
  end if;
  -- dates
  m := regexp_match(t, '\m((?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+[0-9]{1,2}(?:st|nd|rd|th)?|[0-9]{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*|20[0-9]{2}-[01][0-9]-[0-3][0-9]|[0-3]?[0-9]/[01]?[0-9](?:/20[0-9]{2})?|today|tonight|tomorrow|this weekend|next weekend|next week|this week|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\M');
  if m is not null then out := out || jsonb_build_object('dates', m[1]); end if;
  -- urgency
  if t ~ '\m(asap|urgent|urgently|right now|immediately|today|tonight|as soon as possible|emergency|need it now)\M' then out := out || jsonb_build_object('urgency', 'high');
  elsif t ~ '\m(tomorrow|this week|this weekend|next few days)\M' then out := out || jsonb_build_object('urgency', 'medium');
  end if;
  -- delivery
  if t ~ '\m(deliver|delivery|delivered|drop it off|drop off|dropoff|bring the car|bring it to|pick me up|to my (home|house|place|hotel)|airport|pearson|yyz)' then
    out := out || jsonb_build_object('delivery', true);
  end if;
  -- coverage
  out := out || coalesce((select jsonb_build_object('coverage', c) from (values
      (1, 'insurer_claim', '\m(claim|adjuster|insurance company is paying|insurer|replacement (car|vehicle)|my car (was|got) (hit|in an accident)|accident)'),
      (2, 'card', '\m(credit card (coverage|insurance)|my card covers|amex|visa infinite|card covers)'),
      (3, 'own_insurance', '\m(my (own )?insurance|own insurance|i(''| a)?m insured|my policy|use my insurance)'),
      (4, 'protection_plan', '\m(protection plan|full coverage|your insurance|buy (the )?insurance|add insurance|cdw|collision damage)')) r(o, c, re)
     where t ~ re order by o limit 1), '{}'::jsonb);
  return out;
end $$;

-- the score of a set of signals and behaviour
create function app.intent_score(p_signals jsonb, p_behaviour jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with r as (
    select 'Budget given' l, 10 n where p_signals ? 'budget'
    union all select 'Car class named', 8 where p_signals ? 'car_class'
    union all select 'Length of rental given', 8 where p_signals ? 'duration_days'
    union all select 'Dates given', 12 where p_signals ? 'dates'
    union all select 'Needs it now', 20 where p_signals ->> 'urgency' = 'high'
    union all select 'Needs it soon', 10 where p_signals ->> 'urgency' = 'medium'
    union all select 'Wants delivery', 4 where p_signals ? 'delivery'
    union all select 'Coverage discussed', 6 where p_signals ? 'coverage'
    union all select 'Asked to book (request in the last 14 days)', 25 where coalesce((p_behaviour ->> 'requests')::int, 0) > 0
    union all select 'On the site in the last 24 hours', 10 where coalesce((p_behaviour ->> 'recent')::boolean, false)
    union all select 'Came back to the site', 6 where coalesce((p_behaviour ->> 'visits')::int, 0) > 1
    union all select 'Looked at ' || (p_behaviour ->> 'cars') || ' cars', least(10, 2 * coalesce((p_behaviour ->> 'cars')::int, 0)) where coalesce((p_behaviour ->> 'cars')::int, 0) > 0
    union all select 'Many pages viewed', 5 where coalesce((p_behaviour ->> 'pages')::int, 0) >= 8
    union all select 'High visitor score', 10 where coalesce((p_behaviour ->> 'visitor_score')::int, 0) >= 60
    union all select 'Talked to us (' || (p_behaviour ->> 'conversations') || ')', least(10, 3 * coalesce((p_behaviour ->> 'conversations')::int, 0)) where coalesce((p_behaviour ->> 'conversations')::int, 0) > 0)
  select jsonb_build_object('score', least(100, coalesce(sum(n), 0))::int,
    'reasons', coalesce(jsonb_agg(jsonb_build_object('label', l, 'points', n) order by n desc), '[]'::jsonb)) from r
$$;

-- the texts and the behaviour of a renter or a lead
create function app.intent_inputs(p_kind text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_texts text[];
  v_beh jsonb;
  v_renter uuid := case when p_kind = 'renter' then p_id end;
  v_lead uuid := case when p_kind = 'lead' then p_id end;
begin
  v_texts := array(
    select x from (
      select coalesce(a.body, '') || ' ' || coalesce(a.voicemail_text, '') || ' ' || coalesce(a.ai_summary, '') || ' ' || coalesce(a.transcript::text, '') x, a.started_at at
        from phone_activity a where (a.renter_id = v_renter or a.lead_id = v_lead) and a.started_at > now() - interval '60 days'
      union all
      select coalesce(m.subject, '') || ' ' || coalesce(m.body, ''), m.occurred_at from messages m
       where v_renter is not null and m.renter_id = v_renter and m.direction = 'inbound' and m.occurred_at > now() - interval '60 days'
      union all
      select cm.body, cm.at from chat_messages cm join chat_conversations c on c.id = cm.conversation_id
       where (c.renter_id = v_renter or c.lead_id = v_lead) and cm.sender = 'visitor' and cm.at > now() - interval '60 days'
      union all
      select concat_ws(' ', l.message, l.pipeline_note, l.vehicle_text, l.payload::text), l.created_at from leads l where l.id = v_lead
    ) q order by at desc limit 80);
  if v_renter is not null then
    select jsonb_build_object('visits', count(*), 'pages', coalesce(sum(s.page_views), 0),
             'cars', (select count(distinct c) from visitor_sessions s2, unnest(s2.cars_viewed) c where s2.renter_id = v_renter and s2.started_at > now() - interval '30 days'),
             'recent', bool_or(s.last_seen_at > now() - interval '24 hours'), 'visitor_score', max(s.score))
      into v_beh from visitor_sessions s where s.renter_id = v_renter and s.started_at > now() - interval '30 days';
    v_beh := v_beh || jsonb_build_object('requests', (select count(*) from bookings b where b.renter_id = v_renter and b.created_at > now() - interval '14 days' and not coalesce(b.is_placeholder, false)),
      'conversations', (select count(distinct a.thread_id) from phone_activity a where a.renter_id = v_renter and a.started_at > now() - interval '30 days')
                       + (select count(*) from chat_conversations c where c.renter_id = v_renter and c.created_at > now() - interval '30 days'));
  else
    v_beh := jsonb_build_object('conversations', (select count(distinct a.thread_id) from phone_activity a where a.lead_id = v_lead and a.started_at > now() - interval '30 days')
                                   + (select count(*) from chat_conversations c where c.lead_id = v_lead and c.created_at > now() - interval '30 days'),
      'recent', exists (select 1 from leads l where l.id = v_lead and l.updated_at > now() - interval '24 hours'));
  end if;
  return jsonb_build_object('texts', to_jsonb(v_texts), 'behaviour', coalesce(v_beh, '{}'::jsonb));
end $$;

-- compute and keep one subject's intent; the AI's reading fills only what the rules left empty
create function app.intent_compute(p_kind text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i jsonb := app.intent_inputs(p_kind, p_id);
  v_sig jsonb := '{}'::jsonb;
  x text;
  sc jsonb;
  v_ai jsonb := (select s.ai from intent_scores s where s.subject_kind = p_kind and s.subject_id = p_id);
  st program_settings := app.settings();
  v_label text;
  v_n integer := jsonb_array_length(i -> 'texts');
begin
  -- the newest text first: its value of a signal wins
  for x in select jsonb_array_elements_text(i -> 'texts') loop
    v_sig := app.intent_extract(x) || v_sig;
  end loop;
  if v_ai is not null then v_sig := (select coalesce(jsonb_object_agg(k, val), '{}'::jsonb) from jsonb_each(v_ai) e(k, val) where k in ('budget', 'car_class', 'duration_days', 'dates', 'urgency', 'delivery', 'coverage')) || v_sig; end if;
  sc := app.intent_score(v_sig, i -> 'behaviour');
  v_label := case when v_n = 0 and (sc ->> 'score')::int = 0 then 'unknown' when (sc ->> 'score')::int >= st.intent_hot_score then 'hot'
                  when (sc ->> 'score')::int >= st.intent_warm_score then 'warm' else 'cold' end;
  insert into intent_scores (subject_kind, subject_id, score, label, signals, reasons, sources, text_sha, computed_at)
  values (p_kind, p_id, (sc ->> 'score')::int, v_label, v_sig, sc -> 'reasons', v_n, md5((i -> 'texts')::text), now())
  on conflict (subject_kind, subject_id) do update set score = excluded.score, label = excluded.label, signals = excluded.signals, reasons = excluded.reasons,
    sources = excluded.sources, text_sha = excluded.text_sha, computed_at = now();
  return app.intent_json(p_kind, p_id);
end $$;

create function app.intent_json(p_kind text, p_id uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('kind', s.subject_kind, 'id', s.subject_id, 'score', s.score, 'label', s.label, 'signals', s.signals, 'reasons', s.reasons,
    'sources', s.sources, 'computed_at', s.computed_at, 'ai_at', s.ai_at)
    from intent_scores s where s.subject_kind = p_kind and s.subject_id = p_id
$$;

-- every 15 minutes: whoever had activity since the last run (at most 300)
create function app.job_intent(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare r record; n integer := 0;
begin
  for r in select k, id from (
      select 'renter' k, a.renter_id id from phone_activity a where a.renter_id is not null and a.started_at > p_now - interval '30 minutes'
      union select 'lead', a.lead_id from phone_activity a where a.lead_id is not null and a.started_at > p_now - interval '30 minutes'
      union select 'renter', m.renter_id from messages m where m.renter_id is not null and m.direction = 'inbound' and m.occurred_at > p_now - interval '30 minutes'
      union select 'renter', s.renter_id from visitor_sessions s where s.renter_id is not null and s.last_seen_at > p_now - interval '30 minutes'
      union select 'renter', c.renter_id from chat_conversations c where c.renter_id is not null and c.last_message_at > p_now - interval '30 minutes'
      union select 'lead', c.lead_id from chat_conversations c where c.lead_id is not null and c.last_message_at > p_now - interval '30 minutes'
      union select 'lead', l.id from leads l where l.updated_at > p_now - interval '30 minutes' and l.kind not like 'owner%'
      union select 'renter', b.renter_id from bookings b where b.created_at > p_now - interval '30 minutes' and b.renter_id is not null) q
    where id is not null limit 300 loop
    perform app.intent_compute(r.k, r.id);
    n := n + 1;
  end loop;
  return format('%s intents', n);
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-intent', '*/15 * * * *', 'select app.job_intent()');
  end if;
end $$;

-- the AI reading (the website's job): the subjects with texts the AI has not read and gaps the rules left, one at a time
create function public.server_intent_ai_due(p_limit integer default 1) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_allow jsonb := app.ai_allow('intent_enrich', 300);
begin
  if not (app.settings()).intent_ai_enabled or not coalesce((v_allow ->> 'ok')::boolean, false) then
    return jsonb_build_object('ok', false, 'items', '[]'::jsonb, 'why', coalesce(v_allow ->> 'message', 'off'));
  end if;
  return jsonb_build_object('ok', true, 'items', coalesce((select jsonb_agg(jsonb_build_object('kind', s.subject_kind, 'id', s.subject_id, 'sha', s.text_sha,
      'text', left(array_to_string(array(select jsonb_array_elements_text(app.intent_inputs(s.subject_kind, s.subject_id) -> 'texts')), E'\n---\n'), 4000)))
    from (select * from intent_scores x where x.sources > 0 and x.text_sha is distinct from x.ai_sha and x.label <> 'unknown'
            and not (x.signals ?& array['budget', 'car_class', 'duration_days', 'dates', 'coverage'])
          order by x.score desc, x.computed_at desc limit greatest(1, least(coalesce(p_limit, 1), 5))) s), '[]'::jsonb));
end $$;

-- p: {kind, id, sha, signals {...} | null, error, neurons}
create function public.server_intent_ai_result(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_kind text := p ->> 'kind';
  v_id uuid := (p ->> 'id')::uuid;
  v jsonb := case when jsonb_typeof(p -> 'signals') = 'object' then p -> 'signals' else null end;
  v_clean jsonb := '{}'::jsonb;
begin
  if v is not null then
    -- only well-formed values are kept
    if jsonb_typeof(v -> 'budget') = 'object' and (v #>> '{budget,amount_cents}') ~ '^[0-9]{3,8}$' and coalesce(v #>> '{budget,per}', 'total') in ('day', 'week', 'month', 'total') then
      v_clean := v_clean || jsonb_build_object('budget', jsonb_build_object('amount_cents', (v #>> '{budget,amount_cents}')::bigint, 'per', coalesce(v #>> '{budget,per}', 'total')));
    end if;
    if v ->> 'car_class' in ('suv', 'minivan', 'pickup', 'electric', 'sports', 'luxury', 'economy', 'sedan') then v_clean := v_clean || jsonb_build_object('car_class', v ->> 'car_class'); end if;
    if (v ->> 'duration_days') ~ '^[0-9]{1,3}$' and (v ->> 'duration_days')::int between 1 and 365 then v_clean := v_clean || jsonb_build_object('duration_days', (v ->> 'duration_days')::int); end if;
    if length(v ->> 'dates') between 3 and 60 then v_clean := v_clean || jsonb_build_object('dates', v ->> 'dates'); end if;
    if v ->> 'urgency' in ('high', 'medium') then v_clean := v_clean || jsonb_build_object('urgency', v ->> 'urgency'); end if;
    if (v ->> 'delivery') = 'true' then v_clean := v_clean || jsonb_build_object('delivery', true); end if;
    if v ->> 'coverage' in ('card', 'own_insurance', 'protection_plan', 'insurer_claim') then v_clean := v_clean || jsonb_build_object('coverage', v ->> 'coverage'); end if;
  end if;
  update intent_scores set ai = case when v is not null then v_clean else ai end, ai_sha = p ->> 'sha', ai_at = now(), ai_error = left(p ->> 'error', 300)
   where subject_kind = v_kind and subject_id = v_id;
  -- the neurons spent count in the day's Workers AI budget (background share) like every other call
  if p ? 'neurons' then
    insert into provider_calls (provider, purpose, ok, error, duration_ms, cost_microusd, units, unit)
    values (left(coalesce(p ->> 'model', 'workers-ai'), 120), 'intent_enrich', v is not null, left(p ->> 'error', 500), greatest(coalesce((p ->> 'duration_ms')::integer, 0), 0), 0,
            greatest(coalesce((p ->> 'neurons')::integer, 0), 0), 'neurons');
  end if;
  return app.intent_compute(v_kind, v_id);
end $$;
revoke all on function public.server_intent_ai_due(integer) from public, anon, authenticated;
revoke all on function public.server_intent_ai_result(jsonb) from public, anon, authenticated;
grant execute on function public.server_intent_ai_due(integer) to service_role;
grant execute on function public.server_intent_ai_result(jsonb) to service_role;

-- ================================================================ reads: the lead, the renter, the live map
create function app.intent_read(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_kind text := case when p ? 'lead' then 'lead' else 'renter' end;
  v_id uuid := nullif(coalesce(p ->> 'lead', p ->> 'renter'), '')::uuid;
  s intent_scores;
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then raise exception 'Staff only' using errcode = '42501'; end if;
  if v_id is null then raise exception 'Choose the renter or the lead' using errcode = '22023'; end if;
  select * into s from intent_scores where subject_kind = v_kind and subject_id = v_id;
  -- fresh enough (10 minutes), or computed now
  if s.subject_id is null or s.computed_at < now() - interval '10 minutes' or coalesce((p ->> 'refresh')::boolean, false) then return app.intent_compute(v_kind, v_id); end if;
  return app.intent_json(v_kind, v_id);
end $$;

alter function app.live_map(uuid, jsonb) rename to live_map_pre1506;
create function app.live_map(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app set jit = off as $$
declare v jsonb := app.live_map_pre1506(p_by, p);
begin
  if v is null or not (v ? 'pins') then return v; end if;
  return jsonb_set(v, '{pins}', coalesce((select jsonb_agg(t.x || coalesce((select jsonb_build_object('intent', jsonb_build_object('score', s.score, 'label', s.label, 'signals', s.signals))
                                                                               from intent_scores s where s.subject_kind = 'renter' and s.subject_id = nullif(t.x ->> 'renter_id', '')::uuid), '{}'::jsonb) order by t.n)
                                           from jsonb_array_elements(v -> 'pins') with ordinality t(x, n)), '[]'::jsonb));
end $$;
do $$
declare g text;
begin
  execute 'revoke all on function app.live_map(uuid, jsonb) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.live_map_pre1506(uuid, jsonb)', 'execute') then execute format('grant execute on function app.live_map(uuid, jsonb) to %I', g); end if;
  end loop;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1506;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_read', 'admin_read', 'va_read') and p_name = 'intent' then
    perform app.door_begin(p_user, p_aal);
    return app.intent_read(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre1506(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['intent_score', 'intent_inputs', 'intent_compute', 'intent_json', 'job_intent', 'intent_read', 'door_pre1506', 'door'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
