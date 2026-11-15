-- 2995 (release 48): calls through the site open the caller pop-up and its Call helper, and every call's recording,
-- transcript and summary lands on the person's history.
--
-- The owner (Nov 14): "the calls dont prompt the call helper to show up ... theres no call recording or transcriptions
-- or call summaries on the renters profile for each call". Corrected: the Twilio calls through the site (the browser
-- phone), incoming and outgoing. What was wrong:
--   1. app.caller_live listed incoming calls only: a call placed from the site (outbound_calls) never opened the pop-up.
--   2. The pop-up was for Admins, customer service and Fleet only (app.caller_popup_ok, and the staff portal mounted it
--      only for those two functions), while incoming calls ring customer service AND Sales (phone_inbound_ring): a
--      Sales rep answered in the browser with no pop-up and no Call helper.
--   3. The pop-up asked every 10 seconds while in use and once a minute when idle: a call was often answered before it
--      showed. Now phone_activity and outbound_calls bump a live topic (staff:calls, 2522's live updates): the pop-up
--      reads again within about a second (Realtime), or 2 seconds while polling.
--   4. A call that came in to the business number (the browsers ring) was never recorded: only calls placed from the
--      site were. Now the ring records too (dual channel), keeps the audio in private storage (app.inbound_call_media),
--      transcribes it and summarises it the same way, and says who answered.
--   5. The renter's page and the booking's history listed calls without the recording, the transcript or Quo's full
--      summary: app.renter_activity now carries them, and the Activity log shows them (Play, Transcript, Summary).
--   6. Backfill: calls of the last 60 days whose recording, transcript or summary is missing are looked up once at
--      Twilio (site calls) and at Quo (Quo calls) by the five-minute phone job (app.call_backfill).
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
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '2995: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. who sees the pop-up
-- every Admin and every office staff member (customer service, Fleet, Sales, Finance): the database still decides which
-- calls each one sees (app.caller_live)
create or replace function app.caller_popup_ok(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and (app.user_is_admin(p_user) or app.user_va_has(p_user))
$$;
select pg_temp.patch_fn('app.call_helper(uuid, jsonb)'::regprocedure, 'The call helper is for Admins, customer service and Fleet', 'The call helper is for Admins and office staff');

-- ================================================================ 2. the calls in the pop-up
alter function app.caller_live(uuid, jsonb) rename to caller_live_pre2995;
create function app.caller_live(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_admin boolean := app.user_is_admin(p_by);
  v_cs boolean := app.user_va_has(p_by, 'cs');
  v_fleet boolean := app.user_va_has(p_by, 'fleet');
  v_rings boolean := app.voice_rings(p_by);
  v_sales boolean := app.user_sales_only(p_by);
  v_duty boolean;
begin
  if not app.caller_popup_ok(p_by) then raise exception 'The caller pop-up is for Admins and office staff' using errcode = '42501'; end if;
  v_duty := app.fleet_on_duty();
  return jsonb_build_object('at', now(), 'calls', coalesce((
    select jsonb_agg(c.j order by c.started_at desc) from (
      select x.started_at, x.j from (
        -- calls to the CarmaCars number (Quo, or the business number ringing the browsers): Admins all; Fleet its lane;
        -- customer service the rest; whoever the browsers ring (phone_inbound_ring) and whoever answered it, too
        select a.started_at, jsonb_build_object(
                 'id', a.id, 'thread_id', t.id, 'direction', 'in',
                 'number', case when v_sales then app.phone_mask_display(t.number) else t.number end,
                 'display', case when v_sales then app.phone_mask_display(t.number) else app.phone_display(t.number) end, 'at', a.started_at,
                 'answered_at', a.answered_at, 'ended_at', a.ended_at, 'missed', a.missed,
                 'live', a.ended_at is null and not a.missed, 'lane', l.lane,
                 'kind', t.match_kind, 'who', coalesce(t.name, case when v_sales then app.phone_mask_display(t.number) else app.phone_display(t.number) end),
                 'lead_id', t.lead_id, 'owner_id', t.owner_id,
                 'renter', case when t.renter_id is not null then app.caller_renter(t.renter_id) end) as j
          from phone_activity a join phone_threads t on t.id = a.thread_id
          cross join lateral (select app.phone_lane(coalesce(t.renter_id, a.renter_id), coalesce(a.booking_id, t.booking_id)) as lane) l
         where (app.settings()).phone_enabled and a.kind = 'call' and a.direction = 'in' and a.started_at > now() - interval '30 minutes'
           and ((a.ended_at is null and not a.missed) or coalesce(a.ended_at, a.updated_at) > now() - interval '3 minutes')
           and (v_admin or a.sent_by = p_by or (v_rings and l.lane = 'cs')
                or (l.lane = 'fleet' and (v_fleet or ((v_cs or v_rings) and (not v_duty or (a.answered_at is null and a.started_at < now() - interval '20 seconds')))))
                or (l.lane = 'cs' and v_cs))
        union all
        -- calls this person places from the site (the browser phone, or "ring my mobile"): theirs only
        select o.started_at, jsonb_build_object(
                 'id', o.id, 'thread_id', t.id, 'direction', 'out',
                 'number', case when v_sales then app.phone_mask_display(t.number) else t.number end,
                 'display', case when v_sales then app.phone_mask_display(t.number) else app.phone_display(t.number) end, 'at', o.started_at,
                 'answered_at', o.answered_at, 'ended_at', o.ended_at, 'missed', false,
                 'live', o.ended_at is null, 'lane', app.phone_lane(coalesce(t.renter_id, o.renter_id), coalesce(o.booking_id, t.booking_id)),
                 'kind', t.match_kind, 'who', coalesce(t.name, case when v_sales then app.phone_mask_display(t.number) else app.phone_display(t.number) end),
                 'lead_id', t.lead_id, 'owner_id', t.owner_id,
                 'renter', case when t.renter_id is not null then app.caller_renter(t.renter_id) end) as j
          from outbound_calls o join phone_threads t on t.id = o.thread_id
         where o.staff_user_id = p_by and o.started_at > now() - interval '90 minutes'
           and ((o.ended_at is null and (o.status in ('ringing_staff', 'connecting') or (o.status = 'starting' and o.started_at > now() - interval '2 minutes')))
                or o.ended_at > now() - interval '3 minutes')
      ) x order by x.started_at desc limit 3) c), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.caller_live(uuid, jsonb)'::regprocedure, 'app.caller_live_pre2995(uuid, jsonb)'::regprocedure);

-- the renter's page from a call: a call this person placed from the site counts as theirs (logged the same way)
alter function app.caller_open(uuid, jsonb) rename to caller_open_pre2995;
create function app.caller_open(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_renter uuid;
  v_call uuid := nullif(p ->> 'call_id', '')::uuid;
begin
  if not app.caller_popup_ok(p_by) then raise exception 'The caller pop-up is for Admins and office staff' using errcode = '42501'; end if;
  select coalesce(t.renter_id, o.renter_id) into v_renter from outbound_calls o join phone_threads t on t.id = o.thread_id
   where o.id = v_call and o.staff_user_id = p_by and o.started_at > now() - interval '60 minutes';
  if v_renter is null then return app.caller_open_pre2995(p_by, p); end if;
  if app.user_is_admin(p_by) then return jsonb_build_object('ok', true, 'renter_id', v_renter); end if;
  if not app.va_sees_renter(v_renter) then
    insert into data_access_log (user_id, action, renter_id, reason, granted_until)
    values (p_by, 'open', v_renter, 'Call to the renter''s number from the site (caller pop-up)', now() + interval '24 hours');
  end if;
  return jsonb_build_object('ok', true, 'renter_id', v_renter);
end $$;
select pg_temp.copy_grants('app.caller_open(uuid, jsonb)'::regprocedure, 'app.caller_open_pre2995(uuid, jsonb)'::regprocedure);

-- ================================================================ 3. live: the pop-up reads again within a second
do $$ begin
  perform app.live_watch('public.phone_activity'::regclass, 'calls', 'booking_id', '-');
  perform app.live_watch('public.outbound_calls'::regclass, 'calls', 'booking_id', '-');
end $$;
select pg_temp.patch_fn('app.server_live_topics(uuid, text[])'::regprocedure,
  $o$    elsif s = 'staff:field' then$o$,
  $n$    elsif s = 'staff:calls' then
      -- 2995: the caller pop-up (Admins and office staff; field staff place calls too)
      if v_admin or v_office or v_field then out := out || jsonb_build_object(s, app.live_topic(s)); end if;
    elsif s = 'staff:field' then$n$);

-- ================================================================ 4. incoming calls on the business number: who answered, the recording
create table if not exists app.inbound_call_media (
  activity_id       uuid primary key references public.phone_activity (id) on delete cascade,
  call_sid          text not null unique check (call_sid ~ '^CA[0-9a-fA-F]{32}$'),
  recording_sid     text,
  recording_key     text check (recording_key ~ '^calls/twilio/[0-9a-f-]{36}\.mp3$'),
  recording_seconds integer check (recording_seconds >= 0),
  recording_state   text check (recording_state in ('stored', 'transcribed', 'failed')),
  transcript_text   text,
  transcribe_due_at timestamptz,
  transcribe_tries  integer not null default 0,
  transcribe_error  text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
comment on table app.inbound_call_media is 'Calls to the business number that rang the browsers (2995): the recording kept in private storage, its transcript and where it is in speech to text. The call itself is its phone_activity row.';
create index if not exists inbound_call_media_due_idx on app.inbound_call_media (transcribe_due_at) where transcribe_due_at is not null;
revoke all on app.inbound_call_media from public, anon, authenticated;
grant select, insert, update, delete on app.inbound_call_media to service_role;

create or replace function app.inbound_call_sync() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  new.updated_at := now();
  if new.recording_key is not null and (tg_op = 'INSERT' or new.recording_key is distinct from old.recording_key) then
    update phone_activity set recordings = jsonb_build_array(jsonb_build_object('url', '/api/staff/phone/recording?id=' || new.activity_id, 'source', 'site',
                                     'seconds', new.recording_seconds))
     where id = new.activity_id;
  end if;
  if new.transcript_text is not null and (tg_op = 'INSERT' or new.transcript_text is distinct from old.transcript_text) then
    update phone_activity set transcript = jsonb_build_array(jsonb_build_object('who', 'call', 'text', new.transcript_text, 'start', null, 'end', null)),
           summary_due_at = case when (app.settings()).phone_ai_summaries and quo_summary is null and ai_summary is null and btrim(new.transcript_text) <> '' then now() else summary_due_at end
     where id = new.activity_id;
  end if;
  return new;
end $$;
drop trigger if exists inbound_call_media_sync on app.inbound_call_media;
create trigger inbound_call_media_sync before insert or update on app.inbound_call_media for each row execute function app.inbound_call_sync();

-- one call to the business number, by its Twilio CallSid: answered (by which staff member), or its recording.
-- p: {kind: 'answered', call_sid, user_id} | {kind: 'recording', call_sid, recording_sid, key, seconds, error}
create or replace function app.server_twilio_inbound(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a phone_activity;
  m app.inbound_call_media;
  v_sid text := nullif(p ->> 'call_sid', '');
  v_kind text := coalesce(p ->> 'kind', '');
  v_user uuid := case when coalesce(p ->> 'user_id', '') ~ '^[0-9a-f-]{36}$' then (p ->> 'user_id')::uuid end;
  v_key text := nullif(p ->> 'key', '');
begin
  if v_sid is null or v_sid !~ '^CA[0-9a-fA-F]{32}$' then return jsonb_build_object('ok', false, 'error', 'not a call'); end if;
  select * into a from phone_activity where quo_id = v_sid and kind = 'call' for update;
  if a.id is null then return jsonb_build_object('ok', false, 'error', 'unknown call'); end if;
  if v_kind = 'answered' then
    update phone_activity set answered_at = coalesce(answered_at, now()), status = 'answered',
           sent_by = coalesce(sent_by, case when app.voice_staff_ok(v_user) then v_user end)
     where id = a.id;
    return jsonb_build_object('ok', true);
  elsif v_kind = 'recording' then
    if v_key is not null and v_key <> 'calls/twilio/' || a.id || '.mp3' then raise exception 'Not this call''s recording key' using errcode = '22023'; end if;
    insert into app.inbound_call_media (activity_id, call_sid) values (a.id, v_sid) on conflict (activity_id) do nothing;
    update app.inbound_call_media set recording_sid = coalesce(nullif(p ->> 'recording_sid', ''), recording_sid),
           recording_key = coalesce(v_key, recording_key),
           recording_seconds = coalesce(nullif(p ->> 'seconds', '')::integer, recording_seconds),
           recording_state = case when v_key is not null then 'stored' when recording_key is null then 'failed' else recording_state end,
           transcribe_due_at = case when v_key is not null and (app.settings()).phone_twilio_record then now() else transcribe_due_at end,
           transcribe_error = case when v_key is null then left(coalesce(p ->> 'error', 'the recording could not be copied'), 300) else null end
     where activity_id = a.id returning * into m;
    return jsonb_build_object('ok', true, 'delete', v_key is not null and (app.settings()).phone_twilio_delete_recording);
  end if;
  return jsonb_build_object('ok', false, 'error', 'unknown event');
end $$;
create or replace function public.server_twilio_inbound(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_twilio_inbound(p) $$;

-- the call's activity id by its CallSid (the recording callback)
create or replace function app.server_twilio_inbound_id(p_call_sid text) returns uuid
language sql stable security definer set search_path = public, app as $$
  select a.id from phone_activity a where a.quo_id = p_call_sid and a.kind = 'call' and p_call_sid ~ '^CA[0-9a-fA-F]{32}$'
$$;
create or replace function public.server_twilio_inbound_id(p_call_sid text) returns uuid
language sql stable security definer set search_path = public, app as $$ select app.server_twilio_inbound_id(p_call_sid) $$;

-- the ring says whether to record (Program setting phone_twilio_record, as calls placed from the site)
select pg_temp.patch_fn('app.server_voice_ring(jsonb)'::regprocedure,
  $o$'message', s.phone_inbound_message, 'caller_id', app.phone_our_number());$o$,
  $n$'message', s.phone_inbound_message, 'caller_id', app.phone_our_number(), 'record', s.phone_twilio_record);$n$);

-- speech to text covers both kinds of call (an incoming call's id is its activity id)
alter function app.server_twilio_transcribe_due(integer) rename to server_twilio_transcribe_due_pre2995;
create function app.server_twilio_transcribe_due(p_limit integer default 2) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb := app.server_twilio_transcribe_due_pre2995(p_limit);
  v_items jsonb := coalesce(r -> 'items', '[]'::jsonb);
  m app.inbound_call_media;
  a jsonb;
begin
  if coalesce((r ->> 'waiting')::boolean, false) then return r; end if;
  for m in select * from app.inbound_call_media where transcribe_due_at <= now() and recording_state = 'stored' and recording_key is not null
            order by transcribe_due_at limit greatest(0, least(coalesce(p_limit, 2), 10) - jsonb_array_length(v_items)) for update skip locked loop
    a := app.ai_allow('call_transcribe', ceil(greatest(coalesce(m.recording_seconds, 60), 1) / 60.0 * 47));
    if not (a ->> 'ok')::boolean then
      update app.inbound_call_media set transcribe_due_at = app.next_ai_day() where transcribe_due_at <= now() and recording_state = 'stored';
      return jsonb_build_object('items', v_items, 'waiting', true, 'message', a ->> 'message');
    end if;
    v_items := v_items || jsonb_build_object('id', m.activity_id, 'key', m.recording_key, 'seconds', coalesce(m.recording_seconds, 60));
    update app.inbound_call_media set transcribe_due_at = now() + interval '20 minutes' where activity_id = m.activity_id;
  end loop;
  return jsonb_build_object('items', v_items, 'waiting', false);
end $$;
select pg_temp.copy_grants('app.server_twilio_transcribe_due(integer)'::regprocedure, 'app.server_twilio_transcribe_due_pre2995(integer)'::regprocedure);

alter function app.server_twilio_transcript(jsonb) rename to server_twilio_transcript_pre2995;
create function app.server_twilio_transcript(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  m app.inbound_call_media;
  a phone_activity;
  v_ok boolean := coalesce((p ->> 'ok')::boolean, false);
  v_text text := left(btrim(regexp_replace(coalesce(p ->> 'text', ''), '\s+', ' ', 'g')), 20000);
begin
  select * into m from app.inbound_call_media where activity_id = case when coalesce(p ->> 'id', '') ~ '^[0-9a-f-]{36}$' then (p ->> 'id')::uuid end for update;
  if m.activity_id is null then return app.server_twilio_transcript_pre2995(p); end if;
  if coalesce(p ->> 'reason', '') <> 'quota' or coalesce((p ->> 'neurons')::numeric, 0) > 0 then
    insert into provider_calls (provider, purpose, ok, error, duration_ms, units, unit)
    values ('workers-ai', 'call_transcribe', v_ok, left(p ->> 'error', 300), nullif(p ->> 'duration_ms', '')::integer, coalesce((p ->> 'neurons')::numeric, 0), 'neurons');
  end if;
  if v_ok then
    update app.inbound_call_media set transcript_text = v_text, recording_state = 'transcribed', transcribe_due_at = null, transcribe_error = null where activity_id = m.activity_id;
    select * into a from phone_activity where id = m.activity_id;
    if a.renter_id is not null then perform app.intent_compute('renter', a.renter_id); end if;
    if a.lead_id is not null then perform app.intent_compute('lead', a.lead_id); end if;
  elsif p ->> 'reason' = 'quota' then
    update app.inbound_call_media set transcribe_due_at = app.next_ai_day(), transcribe_error = left(p ->> 'error', 300) where activity_id = m.activity_id;
  else
    update app.inbound_call_media set transcribe_tries = transcribe_tries + 1, transcribe_error = left(coalesce(p ->> 'error', 'speech to text failed'), 300),
           transcribe_due_at = case when transcribe_tries + 1 >= 3 then null else now() + interval '30 minutes' end,
           recording_state = case when transcribe_tries + 1 >= 3 then 'failed' else recording_state end
     where activity_id = m.activity_id;
  end if;
  return jsonb_build_object('ok', true);
end $$;
select pg_temp.copy_grants('app.server_twilio_transcript(jsonb)'::regprocedure, 'app.server_twilio_transcript_pre2995(jsonb)'::regprocedure);

-- Play recording: an incoming call's copy too; the same people may hear it
alter function app.server_phone_recording(uuid, uuid) rename to server_phone_recording_pre2995;
create function app.server_phone_recording(p_user uuid, p_activity uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare v_key text;
begin
  if p_user is null or not app.live_staff_ok(p_user) then raise exception 'Call recordings are for Admins, customer service and Sales' using errcode = '42501'; end if;
  select m.recording_key into v_key from app.inbound_call_media m where m.activity_id = p_activity and m.recording_key is not null;
  if v_key is not null then return v_key; end if;
  return app.server_phone_recording_pre2995(p_user, p_activity);
end $$;
select pg_temp.copy_grants('app.server_phone_recording(uuid, uuid)'::regprocedure, 'app.server_phone_recording_pre2995(uuid, uuid)'::regprocedure);

-- ================================================================ 5. the history: recording, transcript, summary
select pg_temp.patch_fn('app.renter_activity(uuid, jsonb)'::regprocedure,
  $o$             'next_steps', a.next_steps) end$o$,
  $n$             'next_steps', a.next_steps, 'recordings', a.recordings, 'transcript', a.transcript, 'summary_lines', a.quo_summary,
             'summary', coalesce(nullif(array_to_string(array(select jsonb_array_elements_text(case when jsonb_typeof(a.quo_summary) = 'array' then a.quo_summary else '[]'::jsonb end)), ' '), ''), a.ai_summary),
             'voicemail_url', a.voicemail_url) end$n$);

-- ================================================================ 6. backfill: the last 60 days, each call looked up once
create table if not exists app.call_backfill (
  ref        text primary key,             -- 'out:<outbound call id>', 'in:<activity id>', 'quo:<activity id>'
  checked_at timestamptz not null default now(),
  result     text
);
comment on table app.call_backfill is 'Calls of the last 60 days whose recording, transcript or summary was missing, looked up once at Twilio or Quo (2995).';
revoke all on app.call_backfill from public, anon, authenticated;
grant select, insert, update, delete on app.call_backfill to service_role;

-- the next calls to look up: site calls with a Twilio CallSid and no copy, and Quo calls missing one of the three
create or replace function app.server_call_backfill_due(p_limit integer default 4) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'twilio', coalesce((select jsonb_agg(x.j) from (
      select jsonb_build_object('ref', 'out:' || o.id, 'kind', 'out', 'id', o.id, 'call_sid', o.call_sid) as j
        from outbound_calls o
       where o.call_sid ~ '^CA[0-9a-fA-F]{32}$' and o.recording_key is null and o.started_at > now() - interval '60 days'
         and o.status = 'completed' and coalesce(o.duration_seconds, 0) > 0 and o.started_at < now() - interval '15 minutes'
         and (app.settings()).phone_twilio_record and not exists (select 1 from app.call_backfill b where b.ref = 'out:' || o.id)
      union all
      select jsonb_build_object('ref', 'in:' || a.id, 'kind', 'in', 'id', a.id, 'call_sid', a.quo_id)
        from phone_activity a
       where a.kind = 'call' and a.quo_id ~ '^CA[0-9a-fA-F]{32}$' and a.started_at > now() - interval '60 days' and a.started_at < now() - interval '15 minutes'
         and not a.missed and jsonb_array_length(a.recordings) = 0 and (app.settings()).phone_twilio_record
         and not exists (select 1 from app.inbound_call_media m where m.activity_id = a.id and m.recording_key is not null)
         and not exists (select 1 from app.call_backfill b where b.ref = 'in:' || a.id)
      limit greatest(1, least(coalesce(p_limit, 4), 20))) x), '[]'::jsonb),
    'quo', coalesce((select jsonb_agg(jsonb_build_object('ref', 'quo:' || a.id, 'id', a.id, 'call_id', a.quo_id,
                       'recording', jsonb_array_length(a.recordings) = 0, 'transcript', a.transcript is null, 'summary', a.quo_summary is null)) from (
      select a.* from phone_activity a
       where a.kind = 'call' and a.quo_id ~ '^AC' and a.started_at > now() - interval '60 days' and a.started_at < now() - interval '15 minutes'
         and not a.missed and coalesce(a.duration_seconds, 0) > 0
         and (jsonb_array_length(a.recordings) = 0 or a.transcript is null or a.quo_summary is null)
         and not exists (select 1 from app.call_backfill b where b.ref = 'quo:' || a.id)
       order by a.started_at desc
       limit greatest(1, least(coalesce(p_limit, 4), 20))) a), '[]'::jsonb))
$$;
create or replace function public.server_call_backfill_due(p_limit integer) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.server_call_backfill_due(p_limit) $$;

-- one call looked up: p {ref, result, quo: {recordings, transcript, summary, next_steps}} (a Quo call's finds are kept
-- on the call as Quo's webhook would have kept them; a site call's copy goes through server_twilio_recording or
-- server_twilio_inbound first)
create or replace function app.server_call_backfill_done(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_ref text := coalesce(p ->> 'ref', '');
  q jsonb := coalesce(p -> 'quo', '{}'::jsonb);
  a phone_activity;
begin
  if v_ref !~ '^(out|in|quo):[0-9a-f-]{36}$' then raise exception 'Not a call reference' using errcode = '22023'; end if;
  insert into app.call_backfill (ref, result) values (v_ref, left(coalesce(p ->> 'result', 'checked'), 200))
  on conflict (ref) do update set checked_at = now(), result = excluded.result;
  if v_ref like 'quo:%' and q <> '{}'::jsonb then
    update phone_activity set
      recordings = case when jsonb_array_length(recordings) = 0 and jsonb_typeof(q -> 'recordings') = 'array' and jsonb_array_length(q -> 'recordings') > 0 then q -> 'recordings' else recordings end,
      transcript = case when transcript is null and jsonb_typeof(q -> 'transcript') = 'array' and jsonb_array_length(q -> 'transcript') > 0 then q -> 'transcript' else transcript end,
      quo_summary = case when quo_summary is null and jsonb_typeof(q -> 'summary') = 'array' and jsonb_array_length(q -> 'summary') > 0 then q -> 'summary' else quo_summary end,
      next_steps = case when next_steps is null and jsonb_typeof(q -> 'next_steps') = 'array' and jsonb_array_length(q -> 'next_steps') > 0 then q -> 'next_steps' else next_steps end
     where id = substr(v_ref, 5)::uuid returning * into a;
    -- a transcript and no summary from Quo: ours (the five-minute job's AI one-liner)
    if a.id is not null and a.quo_summary is null and a.ai_summary is null and a.transcript is not null and (app.settings()).phone_ai_summaries then
      update phone_activity set summary_due_at = coalesce(summary_due_at, now()) where id = a.id;
    elsif a.quo_summary is not null then
      update phone_activity set summary_due_at = null where id = a.id;
    end if;
  end if;
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.server_call_backfill_done(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_call_backfill_done(p) $$;

-- ================================================================ grants
revoke all on function app.caller_popup_ok(uuid), app.inbound_call_sync(), app.server_twilio_inbound_id(text), public.server_twilio_inbound_id(text), app.server_twilio_inbound(jsonb), public.server_twilio_inbound(jsonb),
                       app.server_call_backfill_due(integer), public.server_call_backfill_due(integer), app.server_call_backfill_done(jsonb), public.server_call_backfill_done(jsonb)
  from public, anon, authenticated;
grant execute on function app.caller_popup_ok(uuid), app.inbound_call_sync(), app.server_twilio_inbound_id(text), public.server_twilio_inbound_id(text), app.server_twilio_inbound(jsonb), public.server_twilio_inbound(jsonb),
                          app.server_call_backfill_due(integer), public.server_call_backfill_due(integer), app.server_call_backfill_done(jsonb), public.server_call_backfill_done(jsonb)
  to service_role;
