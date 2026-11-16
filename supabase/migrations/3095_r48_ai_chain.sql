-- 3095 (release 48, part AI): every AI feature keeps working at no cost once the site runs on the company's server
-- (owner, Nov 16). The site asks, per call: Workers AI (the free 10,000 neurons a day, behind the usage guard), then the
-- server's own models (infra/vps/ai: Ollama with a small text and vision model, whisper.cpp for speech), then Gemini's free
-- tier for what is not private. web/src/integrations/ai/chain.ts. Here:
--   1. app.ai_served: which provider served each call (or failed), kept 30 days; public.server_ai_served (the site).
--   2. app.ai_routes: the order per feature, set by an Admin in Settings > Usage (auto, no_gemini, local_first,
--      workers_ai_only, local_only); public.server_ai_routes (the site reads it once a minute); app.ai_route_save.
--   3. app.ai_local_status: whether the server's models answer (text, vision, speech) and whether Gemini is set, written
--      every five minutes by /api/jobs/ai-local; older than 15 minutes counts as not ready.
--   4. app.ai_allow (every AI gate of the database): when Workers AI's share for a feature is used, the call is still
--      allowed while a free provider that may serve it is ready (the local model for every feature, Gemini for those that
--      are not private), unless the feature's route is workers_ai_only. Workers AI itself is never asked past its share:
--      the site's guard (web/src/integrations/ai/guard.ts) still holds it, and the chain moves on.
--   5. Settings > Usage: app.usage_page gains ai_providers (each feature's route, the provider of its last call, its calls
--      of the last 7 days by provider, and the local models' state: ready or warming up).
-- SCHEMA_MARKER 3095. docs/changes/2026-11-16-r48-ai-chain.md.
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

-- ================================================================ 1. the features and what each may use
-- Every purpose the site's AI calls are recorded with (web/src/integrations/ai/guard.ts TASK_PURPOSE, the vision and speech
-- purposes, the staff assistant) and what it needs from the server's models.
create function app.ai_purposes() returns text[]
language sql immutable as $$
  select array['chat', 'faq_reply', 'staff_assistant', 'draft_copy', 'seo_car', 'seo_page', 'seo_article', 'guide_rewrite', 'turo_email', 'phone_draft',
               'phone_summary', 'interview_followup', 'interview_score', 'car_value', 'intent_enrich', 'toll_read', 'plate_detect', 'photo_sort', 'photo_check',
               'guide_review', 'colour_read', 'vin_read', 'dash_read', 'licence_read', 'permit_read', 'interview_transcribe', 'call_transcribe']
$$;

/** text, vision or speech: which of the server's models serves a purpose. */
create function app.ai_kind(p_purpose text) returns text
language sql immutable as $$
  select case when p_purpose in ('interview_transcribe', 'call_transcribe') then 'speech'
              when p_purpose in ('toll_read', 'plate_detect', 'photo_sort', 'photo_check', 'guide_review', 'colour_read', 'vin_read', 'dash_read', 'licence_read', 'permit_read') then 'vision'
              else 'text' end
$$;

/** Never sent to Gemini's free tier (web/src/integrations/ai/chain.ts PRIVATE_PURPOSES). */
create function app.ai_private(p_purpose text) returns boolean
language sql immutable as $$
  select p_purpose in ('licence_read', 'permit_read', 'interview_transcribe', 'call_transcribe', 'phone_summary', 'interview_followup', 'interview_score')
$$;

-- ================================================================ 2. tables
create table app.ai_served (
  id        bigint generated always as identity primary key,
  purpose   text not null check (length(purpose) between 1 and 60),
  provider  text not null check (provider in ('workers_ai', 'local', 'gemini', 'claude', 'none')),
  ok        boolean not null,
  reason    text check (length(reason) <= 40),
  model     text check (length(model) <= 120),
  ms        integer check (ms >= 0),
  at        timestamptz not null default now()
);
comment on table app.ai_served is 'r48 part AI (3095): which provider served each AI call of the site (the chain: Workers AI, the server''s local model, Gemini; Claude for the staff assistant), kept 30 days, for Settings > Usage.';
create index ai_served_at_idx on app.ai_served (at);
create index ai_served_purpose_idx on app.ai_served (purpose, at desc);

create table app.ai_routes (
  purpose    text primary key check (length(purpose) between 1 and 60),
  route      text not null check (route in ('auto', 'no_gemini', 'local_first', 'workers_ai_only', 'local_only')),
  updated_by uuid,
  updated_at timestamptz not null default now()
);
comment on table app.ai_routes is 'r48 part AI (3095): the order of AI providers for one feature, set by an Admin in Settings > Usage. No row: auto (Workers AI, the server''s model, then Gemini when the feature is not private).';

create table app.ai_local_status (
  id            boolean primary key default true check (id),
  text_ready    boolean not null default false,
  vision_ready  boolean not null default false,
  stt_ready     boolean not null default false,
  gemini_ready  boolean not null default false,
  text_model    text check (length(text_model) <= 120),
  vision_model  text check (length(vision_model) <= 120),
  stt_model     text check (length(stt_model) <= 120),
  detail        text check (length(detail) <= 400),
  at            timestamptz not null default now()
);
comment on table app.ai_local_status is 'r48 part AI (3095): the server''s own AI models (infra/vps/ai) as the site last saw them (every five minutes): ready or warming up.';

alter table app.ai_served enable row level security;
alter table app.ai_routes enable row level security;
alter table app.ai_local_status enable row level security;
revoke all on app.ai_served, app.ai_routes, app.ai_local_status from public, anon, authenticated;

-- ================================================================ 3. what is ready
create function app.ai_route(p_purpose text) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce((select r.route from app.ai_routes r where r.purpose = p_purpose), 'auto')
$$;

/** A free provider other than Workers AI may serve this purpose now: the server's model for its kind (fresh within 15
 *  minutes), or Gemini for a purpose that is not private; never for a workers_ai_only route. */
create function app.ai_free_ready(p_purpose text, p_now timestamptz default now()) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when app.ai_route(p_purpose) = 'workers_ai_only' or s.id is null or s.at < p_now - interval '15 minutes' then null
    when (app.ai_kind(p_purpose) = 'text' and s.text_ready) or (app.ai_kind(p_purpose) = 'vision' and s.vision_ready) or (app.ai_kind(p_purpose) = 'speech' and s.stt_ready) then 'local'
    when s.gemini_ready and not app.ai_private(p_purpose) and app.ai_kind(p_purpose) <> 'speech' and app.ai_route(p_purpose) in ('auto', 'local_first') then 'gemini'
    else null end
  from (select true as k) one left join app.ai_local_status s on true
$$;

-- ================================================================ 4. the gate
alter function app.ai_allow(text, numeric, timestamptz) rename to ai_allow_pre3095;
create function app.ai_allow(p_purpose text, p_est numeric default 0, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.ai_allow_pre3095(p_purpose, p_est, p_now);
  v_free text;
begin
  if coalesce((r ->> 'ok')::boolean, false) then return r || jsonb_build_object('provider', 'workers_ai'); end if;
  v_free := app.ai_free_ready(p_purpose, p_now);
  if v_free is null then return r; end if;
  -- Workers AI's share is used, a free provider is ready: the feature runs (the site's chain skips Workers AI)
  return r || jsonb_build_object('ok', true, 'provider', v_free, 'workers_ai_message', r ->> 'message', 'message', null);
end $$;
select pg_temp.copy_grants('app.ai_allow(text, numeric, timestamptz)'::regprocedure, 'app.ai_allow_pre3095(text, numeric, timestamptz)'::regprocedure);

-- ================================================================ 5. the site's calls (service role)
create function public.server_ai_served(p jsonb) returns void
language plpgsql volatile security definer set search_path = public, app as $$
begin
  insert into app.ai_served (purpose, provider, ok, reason, model, ms)
  values (left(coalesce(nullif(p ->> 'purpose', ''), 'unknown'), 60),
          case when p ->> 'provider' in ('workers_ai', 'local', 'gemini', 'claude') then p ->> 'provider' else 'none' end,
          coalesce((p ->> 'ok')::boolean, false), left(p ->> 'reason', 40), left(p ->> 'model', 120),
          greatest(0, least(coalesce((p ->> 'ms')::numeric, 0), 2000000000))::integer);
  -- about one call in a hundred removes what is older than 30 days
  if random() < 0.01 then delete from app.ai_served where at < now() - interval '30 days'; end if;
end $$;

create function public.server_ai_routes() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_object_agg(r.purpose, r.route), '{}'::jsonb) from app.ai_routes r
$$;

create function public.server_ai_local_status(p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public, app as $$
begin
  insert into app.ai_local_status as s (id, text_ready, vision_ready, stt_ready, gemini_ready, text_model, vision_model, stt_model, detail, at)
  values (true, coalesce((p ->> 'text_ready')::boolean, false), coalesce((p ->> 'vision_ready')::boolean, false), coalesce((p ->> 'stt_ready')::boolean, false),
          coalesce((p ->> 'gemini_ready')::boolean, false), left(p ->> 'text_model', 120), left(p ->> 'vision_model', 120), left(p ->> 'stt_model', 120), left(p ->> 'detail', 400), now())
  on conflict (id) do update set text_ready = excluded.text_ready, vision_ready = excluded.vision_ready, stt_ready = excluded.stt_ready, gemini_ready = excluded.gemini_ready,
    text_model = excluded.text_model, vision_model = excluded.vision_model, stt_model = excluded.stt_model, detail = excluded.detail, at = excluded.at;
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ 6. Settings > Usage
create function app.ai_providers(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'local', (select jsonb_build_object('text', s.text_ready, 'vision', s.vision_ready, 'speech', s.stt_ready, 'gemini', s.gemini_ready, 'text_model', s.text_model,
                       'vision_model', s.vision_model, 'speech_model', s.stt_model, 'detail', s.detail, 'at', s.at, 'fresh', s.at >= p_now - interval '15 minutes')
                from app.ai_local_status s),
    'features', coalesce((select jsonb_agg(jsonb_build_object('purpose', f.purpose, 'label', app.ai_feature_label(f.purpose), 'kind', app.ai_kind(f.purpose),
                  'private', app.ai_private(f.purpose), 'route', app.ai_route(f.purpose),
                  'last_provider', l.provider, 'last_ok', l.ok, 'last_at', l.at,
                  'week', jsonb_build_object('workers_ai', coalesce(w.workers_ai, 0), 'local', coalesce(w.local, 0), 'gemini', coalesce(w.gemini, 0), 'claude', coalesce(w.claude, 0)),
                  'failed_week', coalesce(w.failed, 0))
                order by coalesce(w.total, 0) desc, f.purpose)
       from (select unnest(app.ai_purposes()) as purpose
             union select distinct a.purpose from app.ai_served a where a.at >= p_now - interval '7 days'
             union select r.purpose from app.ai_routes r) f
       left join lateral (select a.provider, a.ok, a.at from app.ai_served a where a.purpose = f.purpose order by a.at desc limit 1) l on true
       left join lateral (select count(*) filter (where a.ok and a.provider = 'workers_ai') workers_ai, count(*) filter (where a.ok and a.provider = 'local') local,
                                 count(*) filter (where a.ok and a.provider = 'gemini') gemini, count(*) filter (where a.ok and a.provider = 'claude') claude,
                                 count(*) filter (where not a.ok) failed, count(*) total
                            from app.ai_served a where a.purpose = f.purpose and a.at >= p_now - interval '7 days') w on true), '[]'::jsonb))
$$;

/** An Admin sets a feature's route: p {purpose, route}. */
create function app.ai_route_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_purpose text := nullif(btrim(p ->> 'purpose'), '');
  v_route text := coalesce(nullif(btrim(p ->> 'route'), ''), 'auto');
begin
  perform app.assert_admin(p_user);
  if v_purpose is null or not (v_purpose = any (app.ai_purposes())) then raise exception 'Unknown AI feature' using errcode = '22023'; end if;
  if v_route not in ('auto', 'no_gemini', 'local_first', 'workers_ai_only', 'local_only') then raise exception 'Unknown order of AI providers' using errcode = '22023'; end if;
  if v_route = 'auto' then delete from app.ai_routes where purpose = v_purpose;
  else
    insert into app.ai_routes (purpose, route, updated_by, updated_at) values (v_purpose, v_route, p_user, now())
    on conflict (purpose) do update set route = excluded.route, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  end if;
  return app.ai_providers();
end $$;

alter function app.usage_page(uuid, timestamptz) rename to usage_page_pre3095;
create function app.usage_page(p_user uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  return app.usage_page_pre3095(p_user, p_now) || jsonb_build_object('ai_providers', app.ai_providers(p_now));
end $$;
select pg_temp.copy_grants('app.usage_page(uuid, timestamptz)'::regprocedure, 'app.usage_page_pre3095(uuid, timestamptz)'::regprocedure);

-- ================================================================ 7. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3095;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_do' and p_name = 'ai_route_save' then
    perform app.door_begin(p_user, p_aal);
    return app.ai_route_save(p_user, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre3095(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3095(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['ai_purposes', 'ai_kind', 'ai_private', 'ai_route', 'ai_free_ready', 'ai_allow_pre3095', 'ai_providers',
              'ai_route_save', 'usage_page_pre3095', 'door_pre3095']))
        or (n.nspname = 'public' and p.proname = any (array['server_ai_served', 'server_ai_routes', 'server_ai_local_status']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
grant select, insert, update, delete on app.ai_served, app.ai_routes, app.ai_local_status to service_role;
