-- 0827: sending notifications reads the settings and renders a booking once, not once per recipient (Release 34, part P;
-- docs/changes/2026-11-08-r34-owner-onboarding.md). No applied migration is edited; the functions are wrapped (_pre0827).
--
-- What was measured: one flush of 18 staff alerts (about 800 staff recipients each in the test database) made 147,654
-- calls to app.settings (each builds the 640-column program_settings row: about 0.5 ms) and rendered the same booking
-- 7,898 times (app.ntf_booking, about 10 ms each), because app.process_events builds the payload once per recipient and
-- every layer of the payload asks for the settings again. A flush in the suite took over a minute.
-- The fix:
--   a. app.settings(date) keeps the row it read for the rest of the transaction (one per date); any change to
--      program_settings or usage_services in the transaction clears it, so a change is seen at once.
--   b. while app.process_events renders one event, the parts of the payload that depend on the event only (the booking,
--      the vehicle, the contact block, the setting words) are made once and reused for every recipient of that event.
--      The parts that depend on the recipient (name, audience, owner) are still made per recipient.
-- process_events itself already reads the settings once at its top (s).
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

-- ================================================================ a. the settings, once per transaction
alter function app.settings(date) rename to settings_pre0827;
create function app.settings(p_on date default ((now() at time zone 'America/Toronto'))::date) returns program_settings
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_key text := 'app.settings_' || coalesce(to_char(p_on, 'YYYYMMDD'), 'today');
  v_tag text := now()::text || '|' || coalesce(current_setting('app.settings_gen', true), '') || '|';
  v_c text := current_setting(v_key, true);
  r program_settings;
begin
  if v_c is not null and left(v_c, length(v_tag)) = v_tag then
    return substr(v_c, length(v_tag) + 1)::program_settings;
  end if;
  r := app.settings_pre0827(p_on);
  if r.id is not null then perform set_config(v_key, v_tag || r::text, true); end if;
  return r;
end $$;
select pg_temp.copy_grants('app.settings(date)'::regprocedure, 'app.settings_pre0827(date)'::regprocedure);
revoke all on function app.settings_pre0827(date) from public, anon, authenticated;
grant execute on function app.settings_pre0827(date) to service_role;

create function app.settings_cache_clear() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform set_config('app.settings_gen', gen_random_uuid()::text, true);
  return null;
end $$;
revoke all on function app.settings_cache_clear() from public, anon, authenticated;
grant execute on function app.settings_cache_clear() to service_role;
-- cleared before the change, after each row (named to run before the tables' other row triggers, which may read the
-- settings: the turnaround blocks of 0410 are moved by one) and after the statement
do $$
declare t text;
begin
  foreach t in array array['program_settings', 'usage_services'] loop
    execute format('create trigger _settings_cache_clear_before before insert or update or delete or truncate on %I for each statement execute function app.settings_cache_clear()', t);
    execute format('create trigger _settings_cache_clear_row after insert or update or delete on %I for each row execute function app.settings_cache_clear()', t);
    execute format('create trigger _settings_cache_clear_after after insert or update or delete or truncate on %I for each statement execute function app.settings_cache_clear()', t);
  end loop;
end $$;

-- ================================================================ b. the event's parts, once per event
-- app.ntf_memo_on is '<event id>' only while app.notification_payload runs inside app.process_events
create function app.ntf_memo(p_kind text, p_key text) returns jsonb
language sql stable set search_path = public, app as $$
  select case when nullif(current_setting('app.ntf_memo_on', true), '') is not null
               and left(coalesce(current_setting('app.ntf_memo_' || p_kind, true), ''), length(current_setting('app.ntf_memo_on', true)) + 1) = current_setting('app.ntf_memo_on', true) || '|'
              then (substr(current_setting('app.ntf_memo_' || p_kind, true), length(current_setting('app.ntf_memo_on', true)) + 2))::jsonb -> coalesce(p_key, '-') end $$;

create function app.ntf_memo_put(p_kind text, p_key text, p_val jsonb) returns jsonb
language plpgsql volatile set search_path = public, app as $$
declare
  v_ev text := nullif(current_setting('app.ntf_memo_on', true), '');
  v_c text;
  m jsonb := '{}'::jsonb;
begin
  if v_ev is null then return p_val; end if;
  v_c := coalesce(current_setting('app.ntf_memo_' || p_kind, true), '');
  if left(v_c, length(v_ev) + 1) = v_ev || '|' then m := substr(v_c, length(v_ev) + 2)::jsonb; end if;
  perform set_config('app.ntf_memo_' || p_kind, v_ev || '|' || (m || jsonb_build_object(coalesce(p_key, '-'), coalesce(p_val, 'null'::jsonb)))::text, true);
  return p_val;
end $$;
revoke all on function app.ntf_memo(text, text) from public, anon, authenticated;
revoke all on function app.ntf_memo_put(text, text, jsonb) from public, anon, authenticated;
grant execute on function app.ntf_memo(text, text) to service_role;
grant execute on function app.ntf_memo_put(text, text, jsonb) to service_role;

alter function app.ntf_booking(uuid) rename to ntf_booking_pre0827;
create function app.ntf_booking(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare m jsonb := app.ntf_memo('booking', p_booking::text);
begin
  if m is not null then return case when m = 'null'::jsonb then null else m end; end if;
  if nullif(current_setting('app.ntf_memo_on', true), '') is null then return app.ntf_booking_pre0827(p_booking); end if;
  return app.ntf_memo_put('booking', p_booking::text, app.ntf_booking_pre0827(p_booking));
end $$;
select pg_temp.copy_grants('app.ntf_booking(uuid)'::regprocedure, 'app.ntf_booking_pre0827(uuid)'::regprocedure);
revoke all on function app.ntf_booking_pre0827(uuid) from public, anon, authenticated;
grant execute on function app.ntf_booking_pre0827(uuid) to service_role;

alter function app.ntf_vehicle(uuid) rename to ntf_vehicle_pre0827;
create function app.ntf_vehicle(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare m jsonb := app.ntf_memo('vehicle', p_vehicle::text);
begin
  if m is not null then return case when m = 'null'::jsonb then null else m end; end if;
  if nullif(current_setting('app.ntf_memo_on', true), '') is null then return app.ntf_vehicle_pre0827(p_vehicle); end if;
  return app.ntf_memo_put('vehicle', p_vehicle::text, app.ntf_vehicle_pre0827(p_vehicle));
end $$;
select pg_temp.copy_grants('app.ntf_vehicle(uuid)'::regprocedure, 'app.ntf_vehicle_pre0827(uuid)'::regprocedure);
revoke all on function app.ntf_vehicle_pre0827(uuid) from public, anon, authenticated;
grant execute on function app.ntf_vehicle_pre0827(uuid) to service_role;

alter function app.ntf_contact() rename to ntf_contact_pre0827;
create function app.ntf_contact() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare m jsonb := app.ntf_memo('contact', '-');
begin
  if m is not null then return case when m = 'null'::jsonb then null else m end; end if;
  if nullif(current_setting('app.ntf_memo_on', true), '') is null then return app.ntf_contact_pre0827(); end if;
  return app.ntf_memo_put('contact', '-', app.ntf_contact_pre0827());
end $$;
select pg_temp.copy_grants('app.ntf_contact()'::regprocedure, 'app.ntf_contact_pre0827()'::regprocedure);
revoke all on function app.ntf_contact_pre0827() from public, anon, authenticated;
grant execute on function app.ntf_contact_pre0827() to service_role;

alter function app.ntf_setting_words() rename to ntf_setting_words_pre0827;
create function app.ntf_setting_words() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare m jsonb := app.ntf_memo('words', '-');
begin
  if m is not null then return case when m = 'null'::jsonb then null else m end; end if;
  if nullif(current_setting('app.ntf_memo_on', true), '') is null then return app.ntf_setting_words_pre0827(); end if;
  return app.ntf_memo_put('words', '-', app.ntf_setting_words_pre0827());
end $$;
select pg_temp.copy_grants('app.ntf_setting_words()'::regprocedure, 'app.ntf_setting_words_pre0827()'::regprocedure);
revoke all on function app.ntf_setting_words_pre0827() from public, anon, authenticated;
grant execute on function app.ntf_setting_words_pre0827() to service_role;

-- the scope: one event of one process_events run (a token per run, so nothing is kept from an earlier run)
alter function app.notification_payload(text, app_events, jsonb) rename to notification_payload_pre0827;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_run text := nullif(current_setting('app.ntf_memo_run', true), '');
  x jsonb;
begin
  if v_run is null or p_event.id is null then return app.notification_payload_pre0827(p_code, p_event, p_to); end if;
  perform set_config('app.ntf_memo_on', v_run || ':' || p_event.id::text, true);
  x := app.notification_payload_pre0827(p_code, p_event, p_to);
  perform set_config('app.ntf_memo_on', '', true);
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.notification_payload_pre0827(text, app_events, jsonb)'::regprocedure);
revoke all on function app.notification_payload_pre0827(text, app_events, jsonb) from public, anon, authenticated;
grant execute on function app.notification_payload_pre0827(text, app_events, jsonb) to service_role;

alter function app.process_events(integer, timestamptz) rename to process_events_pre0827;
create function app.process_events(p_limit integer default null, p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare v integer;
begin
  perform set_config('app.ntf_memo_run', gen_random_uuid()::text, true);
  v := app.process_events_pre0827(p_limit, p_now);
  perform set_config('app.ntf_memo_run', '', true);
  return v;
end $$;
select pg_temp.copy_grants('app.process_events(integer, timestamptz)'::regprocedure, 'app.process_events_pre0827(integer, timestamptz)'::regprocedure);
revoke all on function app.process_events_pre0827(integer, timestamptz) from public, anon, authenticated;
grant execute on function app.process_events_pre0827(integer, timestamptz) to service_role;
