-- 99: every AI feature at no cost (migration 3095, r48 part AI). The gate (app.ai_allow) lets a feature run past Workers
-- AI's share only while a free provider that may serve it is ready (the server's model of its kind, fresh within 15
-- minutes; Gemini only for what is not private), never for a workers_ai_only route; the site's record of which provider
-- served each call; the Admin's route per feature; Settings > Usage. Fixtures start with "ac".
select test.suite('99 AI chain');

select test.mk_user('ac_admin', 'admin');
select test.mk_user('ac_cs', 'va', 'cs');
update program_settings set require_staff_two_step = false;

-- a day with Workers AI's background and live shares used up
delete from provider_calls where unit = 'neurons' and created_at >= app.local_midnight(app.today()) - interval '1 day';
delete from usage_readings where service = 'workers_ai';
update usage_services set included = 10000, paid_extra = 0 where service = 'workers_ai';
delete from app.ai_local_status;
delete from app.ai_routes;
insert into provider_calls (provider, purpose, ok, units, unit) values ('workers-ai', 'staff_assistant', true, 10000, 'neurons');
create function test.acok(p_purpose text) returns text language sql stable as $$
  select (a ->> 'ok') || ':' || coalesce(a ->> 'provider', '-') from (select app.ai_allow(p_purpose, 100) a) x $$;
create function test.acst(p jsonb, p_ago interval default '0') returns void language plpgsql as $$
begin
  perform public.server_ai_local_status(p);
  update app.ai_local_status set at = now() - p_ago;
end $$;

-- ================================================================ 1. the features
select test.eq('kinds: text, vision, speech', app.ai_kind('chat') || ' ' || app.ai_kind('plate_detect') || ' ' || app.ai_kind('call_transcribe'), 'text vision speech');
select test.eq('private: identity documents, recordings and what is made from them; not chat or a car photo',
  format('%s %s %s %s %s %s', app.ai_private('licence_read'), app.ai_private('permit_read'), app.ai_private('call_transcribe'), app.ai_private('phone_summary'),
         app.ai_private('chat'), app.ai_private('plate_detect')), 't t t t f f');

-- ================================================================ 2. the gate
select test.eq('Workers AI used, nothing else ready: refused as before', test.acok('seo_car'), 'false:-');
select test.eq('and its words are Workers AI''s', app.ai_allow('seo_car', 100) ->> 'message' like 'Background AI writing waits%', true);
select test.acst('{"text_ready": true, "vision_ready": false, "stt_ready": false, "gemini_ready": false, "text_model": "qwen2.5:3b", "detail": "vision warming up"}');
select test.eq('the server''s text model ready: background copy, chat and the assistant run on it', test.acok('seo_car') || ' ' || test.acok('chat') || ' ' || test.acok('staff_assistant'),
  'true:local true:local true:local');
select test.eq('not a plate check (the vision model is warming up) nor a recording', test.acok('plate_detect') || ' ' || test.acok('call_transcribe'), 'false:- false:-');
select test.eq('the assistant''s usage gate follows (0133''s usage_gate asks app.ai_allow)',
  (app.usage_gate('workers_ai') ->> 'ok')::boolean, true);
select test.acst('{"text_ready": true, "vision_ready": false, "stt_ready": false, "gemini_ready": true}');
select test.eq('Gemini set: a car photo may be read by it, a licence never', test.acok('plate_detect') || ' ' || test.acok('licence_read'), 'true:gemini false:-');
select test.acst('{"text_ready": false, "vision_ready": true, "stt_ready": true, "gemini_ready": false}');
select test.eq('the server''s vision and speech models ready: the licence and a call recording run on them', test.acok('licence_read') || ' ' || test.acok('call_transcribe'), 'true:local true:local');
select test.acst('{"text_ready": true, "vision_ready": true, "stt_ready": true, "gemini_ready": true}', '20 minutes');
select test.eq('a status older than 15 minutes is not ready', test.acok('chat') || ' ' || test.acok('plate_detect'), 'false:- false:-');
select test.acst('{"text_ready": true, "vision_ready": true, "stt_ready": true, "gemini_ready": true}');
delete from provider_calls where purpose = 'staff_assistant' and unit = 'neurons';
select test.eq('Workers AI with room: Workers AI', test.acok('chat'), 'true:workers_ai');
insert into provider_calls (provider, purpose, ok, units, unit) values ('workers-ai', 'staff_assistant', true, 10000, 'neurons');

-- ================================================================ 3. the route, by an Admin
select test.throws('only an Admin sets a route', $$ select app.door(test.id('ac_cs'), 'aal2', 'admin_do', 'ai_route_save', '{"purpose": "chat", "route": "local_only"}') $$);
select test.throws('an unknown feature is refused', $$ select app.door(test.id('ac_admin'), 'aal2', 'admin_do', 'ai_route_save', '{"purpose": "mining", "route": "auto"}') $$, '%Unknown AI feature%');
select test.throws('an unknown route is refused', $$ select app.door(test.id('ac_admin'), 'aal2', 'admin_do', 'ai_route_save', '{"purpose": "chat", "route": "gemini_first"}') $$, '%Unknown order%');
select test.lives('workers_ai_only for chat', $$ select app.door(test.id('ac_admin'), 'aal2', 'admin_do', 'ai_route_save', '{"purpose": "chat", "route": "workers_ai_only"}') $$);
select test.eq('the site reads it', public.server_ai_routes() ->> 'chat', 'workers_ai_only');
select test.eq('chat no longer runs past Workers AI''s share; other features still do', test.acok('chat') || ' ' || test.acok('seo_car'), 'false:- true:local');
select test.lives('back to auto removes the row', $$ select app.door(test.id('ac_admin'), 'aal2', 'admin_do', 'ai_route_save', '{"purpose": "chat", "route": "auto"}') $$);
select test.eq('auto: no row', (select count(*) from app.ai_routes where purpose = 'chat'), 0::bigint);

-- ================================================================ 4. which provider served each call
select public.server_ai_served('{"purpose": "chat", "provider": "workers_ai", "ok": false, "reason": "quota", "ms": 3}');
select public.server_ai_served('{"purpose": "chat", "provider": "local", "ok": true, "ms": 4200, "model": "local:qwen2.5:3b"}');
select public.server_ai_served('{"purpose": "chat", "provider": "local", "ok": true, "ms": 3900}');
select public.server_ai_served('{"purpose": "plate_detect", "provider": "gemini", "ok": true, "ms": 1200}');
select public.server_ai_served('{"purpose": "chat", "provider": "somebody", "ok": true}');
select test.eq('an unknown provider is recorded as none', (select provider from app.ai_served where purpose = 'chat' order by id desc limit 1), 'none');
select test.eq('Settings > Usage: chat by provider over 7 days, the last call''s provider',
  (select (f -> 'week' ->> 'local') || '/' || (f -> 'week' ->> 'workers_ai') || '/' || (f ->> 'failed_week') || '/' || (f ->> 'last_provider')
     from jsonb_array_elements(app.usage_page(test.id('ac_admin')) #> '{ai_providers,features}') f where f ->> 'purpose' = 'chat'), '2/0/1/none');
select test.eq('every feature is listed, with its route and whether it is private',
  (select count(*) filter (where f ->> 'route' = 'auto') = count(*) and bool_or(f ->> 'purpose' = 'licence_read' and (f ->> 'private')::boolean)
     from jsonb_array_elements(app.ai_providers() -> 'features') f), true);
select test.eq('the server''s models: ready and fresh', (app.ai_providers() #>> '{local,text}') || ' ' || (app.ai_providers() #>> '{local,fresh}'), 'true true');
select test.eq('the site''s calls are the service role''s only',
  has_function_privilege('authenticated', 'public.server_ai_served(jsonb)', 'execute') or has_function_privilege('anon', 'public.server_ai_routes()', 'execute')
  or has_function_privilege('authenticated', 'public.server_ai_local_status(jsonb)', 'execute'), false);

-- leave the day as it was found
delete from provider_calls where purpose = 'staff_assistant' and unit = 'neurons';
delete from app.ai_local_status;
delete from app.ai_served;
