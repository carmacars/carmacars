-- 4500: the weekly townhall in the Admin connector (release 50). SCHEMA_MARKER 4500. No applied migration is edited.
--   townhall_status (admin:read): the next meeting (Toronto), the call link, this week's deck (built when, its slides), which active
--     staff are on the deck and which are missing from it (every staff member is featured, on the "team this week" slide), the
--     reminders scheduled and sent, and the field-call interview slots of the hour before.
--   townhall_set_call_url (admin:write, previewed then confirmed): the meeting link, https only, as Program settings saves it.
--   townhall_rebuild_deck (admin:write, previewed then confirmed): rebuilds this week's deck now with app.townhall_build, the
--     function the Sunday-night job (app.job_townhall) calls; the notes already added are kept (the rebuild replaces the slides only).
-- The three run in app.api_call (wrapped: api_call_pre4500), as an Admin's key at aal2, and are logged in api_calls.
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

create function app.townhall_status(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  s program_settings := app.settings();
  v_next timestamptz := app.townhall_next(now());
  v_week date := (date_trunc('week', app.today()::timestamp))::date;
  d townhall_decks;
  v_day date;
  v_stamp text;
  v_people jsonb;
  v_featured jsonb := null;
  v_missing jsonb := null;
  v_deck jsonb := null;
  v_rem jsonb := '[]'::jsonb;
  v_slots jsonb := '[]'::jsonb;
begin
  perform app.assert_admin(p_by);
  select * into d from townhall_decks where week_of = v_week;
  if d.id is not null then
    select coalesce(s2 -> 'people', '[]'::jsonb) into v_people from jsonb_array_elements(d.slides) s2 where s2 ->> 'key' = 'people';
    v_people := coalesce(v_people, '[]'::jsonb);
    select coalesce(jsonb_agg(jsonb_build_object('user_id', sp.user_id, 'name', coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email),
             'functions', sp.functions) order by coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email)), '[]'::jsonb) into v_featured
      from staff_profiles sp join users u on u.id = sp.user_id
     where app.staff_is_member(sp.user_id) and exists (select 1 from jsonb_array_elements(v_people) x where x ->> 'user_id' = sp.user_id::text);
    select coalesce(jsonb_agg(jsonb_build_object('user_id', sp.user_id, 'name', coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email),
             'functions', sp.functions) order by coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email)), '[]'::jsonb) into v_missing
      from staff_profiles sp join users u on u.id = sp.user_id
     where app.staff_is_member(sp.user_id) and not exists (select 1 from jsonb_array_elements(v_people) x where x ->> 'user_id' = sp.user_id::text);
    v_deck := jsonb_build_object('week_of', d.week_of, 'built_at', d.built_at, 'built_by', d.built_by, 'slide_count', jsonb_array_length(d.slides),
      'slides', (select coalesce(jsonb_agg(jsonb_build_object('key', x ->> 'key', 'title', x ->> 'title', 'admin_only', coalesce((x ->> 'admin_only')::boolean, false)) order by o), '[]'::jsonb)
                   from jsonb_array_elements(d.slides) with ordinality t(x, o)),
      'notes_on', (select coalesce(jsonb_agg(k order by k), '[]'::jsonb) from jsonb_object_keys(d.notes) k), 'recording_url', d.recording_url);
  end if;
  if v_next is not null then
    v_day := (v_next at time zone 'America/Toronto')::date;
    v_stamp := to_char(v_next, 'YYYYMMDDHH24MI');
    select coalesce(jsonb_agg(jsonb_build_object('step', r.step, 'at', r.at, 'due', r.at <= now(),
             'sent', (select count(*) from app_events e where e.code like 'staff_alert_%' and e.payload ->> 'kind' = r.kind || ':' || r.step || ':' || v_stamp)) order by r.at), '[]'::jsonb) into v_rem
      from (values ('townhall_reminder', 'day_before', (((v_day - 1)::timestamp + time '10:00') at time zone 'America/Toronto')),
                   ('townhall_reminder', 'morning', ((v_day::timestamp + time '09:00') at time zone 'America/Toronto')),
                   ('townhall_soon', 'soon', v_next - interval '60 minutes'),
                   ('townhall_reminder', 'checkin', v_next - interval '15 minutes')) r (kind, step, at);
    select coalesce(jsonb_agg(jsonb_build_object('starts_at', sl.starts_at, 'ends_at', sl.ends_at, 'booked', a.id is not null, 'applicant', a.full_name) order by sl.starts_at), '[]'::jsonb) into v_slots
      from interview_slots sl join interview_days idy on idy.id = sl.day_id left join job_applications a on a.slot_id = sl.id
     where idy.note like 'Field calls in the hour before the weekly townhall%' and sl.starts_at >= v_next - interval '1 hour' and sl.starts_at < v_next;
  end if;
  return jsonb_build_object(
    'next_at', v_next, 'next_toronto', to_char(v_next at time zone 'America/Toronto', 'FMDay, FMMonth FMDD, YYYY "at" FMHH12:MI am'), 'minutes', s.townhall_minutes,
    'cancelled', v_next is not null and exists (select 1 from townhall_cancellations c where c.meeting_at = v_next),
    'call_url_set', s.townhall_call_url <> '', 'call_url', nullif(s.townhall_call_url, ''),
    'week_of', v_week, 'deck_built', d.id is not null, 'deck', v_deck, 'deck_reminded_at', d.reminded_at,
    'staff_featured', v_featured, 'staff_missing', v_missing,
    'staff_missing_count', case when v_missing is null then null else jsonb_array_length(v_missing) end,
    'staff_note', case when d.id is null then 'This week''s deck is not built yet (the Sunday-night job builds it): use townhall_rebuild_deck.'
                       when jsonb_array_length(v_missing) > 0 then 'Staff missing from the deck: townhall_rebuild_deck adds them from the live staff list.'
                       else 'Every active staff member is on the deck.' end,
    'reminders', v_rem, 'field_call_slots', v_slots);
end $$;

-- p: url (https only), preview. A new dated Program settings row from today (as Admin > Settings saves it).
create function app.townhall_set_call_url(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_url text := btrim(coalesce(p ->> 'url', ''));
  v_old text := nullif((app.settings()).townhall_call_url, '');
begin
  perform app.assert_admin(p_by);
  if v_url !~ '^https://[^[:space:]]+$' or length(v_url) > 500 then raise exception 'The meeting link must be a full https:// address' using errcode = '22023'; end if;
  if coalesce((p ->> 'preview')::boolean, false) then
    return jsonb_build_object('preview', true, 'from', v_old, 'to', v_url, 'unchanged', v_old is not distinct from v_url,
      'note', 'The Join button on every staff portal and the check-in reminders open this link.');
  end if;
  perform app.admin_save(p_by, 'program_settings', jsonb_build_object('values', jsonb_build_object('townhall_call_url', v_url)));
  return jsonb_build_object('call_url', v_url, 'was', v_old);
end $$;

-- p: preview. This week's deck (week_of: the Monday of the week now) from the live data; the notes stay.
create function app.townhall_rebuild_deck(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_week date := (date_trunc('week', app.today()::timestamp))::date;
  d townhall_decks;
  v_st jsonb;
begin
  perform app.assert_admin(p_by);
  select * into d from townhall_decks where week_of = v_week;
  if coalesce((p ->> 'preview')::boolean, false) then
    v_st := app.townhall_status(p_by, '{}'::jsonb);
    return jsonb_build_object('preview', true, 'week_of', v_week, 'deck_built', d.id is not null, 'built_at', d.built_at,
      'slides_now', case when d.id is null then null else jsonb_array_length(d.slides) end,
      'notes_kept', (select count(*) from jsonb_object_keys(coalesce(d.notes, '{}'::jsonb))),
      'staff_missing_now', v_st -> 'staff_missing', 'note', 'Every slide is rebuilt from live data now; the notes already added are kept.');
  end if;
  perform app.townhall_build(v_week, p_by);
  select * into d from townhall_decks where week_of = v_week;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'townhall_deck_rebuilt', 'townhall_decks', d.id::text, jsonb_build_object('week_of', v_week, 'slides', jsonb_array_length(d.slides)));
  v_st := app.townhall_status(p_by, '{}'::jsonb);
  return jsonb_build_object('week_of', v_week, 'built_at', d.built_at, 'slide_count', jsonb_array_length(d.slides),
    'notes_kept', (select count(*) from jsonb_object_keys(d.notes)), 'staff_featured', jsonb_array_length(v_st -> 'staff_featured'), 'staff_missing', v_st -> 'staff_missing');
end $$;

-- ================================================================ the connector
alter function app.api_call(text, text, jsonb, text) rename to api_call_pre4500;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  chk jsonb;
  k api_keys;
  v_args jsonb;
  v_confirm boolean;
  pv api_previews;
  v_result jsonb;
begin
  if p_tool not in ('townhall_status', 'townhall_set_call_url', 'townhall_rebuild_deck') then return app.api_call_pre4500(p_hash, p_tool, p_args, p_client); end if;
  chk := app.api_key_check(p_hash, case when p_tool = 'townhall_status' then 'admin:read' else 'admin:write' end, p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  v_confirm := coalesce((a ->> 'confirm')::boolean, false);
  v_args := a - 'confirm' - 'preview_id';
  begin
    if p_tool = 'townhall_status' then
      v_result := app.townhall_status(k.user_id, v_args);
    elsif not v_confirm then
      v_result := case p_tool when 'townhall_set_call_url' then app.townhall_set_call_url(k.user_id, v_args || jsonb_build_object('preview', true))
                              else app.townhall_rebuild_deck(k.user_id, v_args || jsonb_build_object('preview', true)) end;
      insert into api_previews (key_id, user_id, tool, args, before, after)
      values (k.id, k.user_id, p_tool, v_args,
              case p_tool when 'townhall_set_call_url' then jsonb_build_object('call_url', v_result -> 'from')
                          else jsonb_build_object('built_at', v_result -> 'built_at', 'slides', v_result -> 'slides_now', 'staff_missing', v_result -> 'staff_missing_now') end,
              case p_tool when 'townhall_set_call_url' then jsonb_build_object('call_url', v_result -> 'to') else jsonb_build_object('rebuilt', true, 'notes_kept', v_result -> 'notes_kept') end)
      returning * into pv;
      v_result := v_result || jsonb_build_object('preview_id', pv.id, 'tool', p_tool, 'expires_at', pv.created_at + interval '10 minutes',
        'next', 'Nothing was changed. To do it, call this tool again with exactly the same arguments plus "confirm": true and "preview_id": "' || pv.id || '".');
    else
      select * into pv from api_previews where id = nullif(a ->> 'preview_id', '')::uuid for update;
      if pv.id is null or pv.key_id <> k.id or pv.tool <> p_tool then raise exception 'Preview first: call without confirm, then confirm with its preview_id' using errcode = '22023'; end if;
      if pv.used_at is not null then raise exception 'This preview was already used: preview again' using errcode = '22023'; end if;
      if pv.created_at < now() - interval '10 minutes' then raise exception 'This preview is more than 10 minutes old: preview again' using errcode = '22023'; end if;
      if pv.args is distinct from v_args then raise exception 'The arguments differ from the preview: preview again with these' using errcode = '22023'; end if;
      update api_previews set used_at = now() where id = pv.id;
      v_result := case p_tool when 'townhall_set_call_url' then app.townhall_set_call_url(k.user_id, v_args) else app.townhall_rebuild_deck(k.user_id, v_args) end;
    end if;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, 'townhall', v_args, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, ok, client)
  values (k.id, k.user_id, case when p_tool <> 'townhall_status' and not v_confirm then p_tool || ':preview' else p_tool end, 'townhall', v_args, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre4500(text, text, jsonb, text)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['townhall_status', 'townhall_set_call_url', 'townhall_rebuild_deck', 'api_call_pre4500']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
