-- 1880_r35_call_recordings.sql
-- Release 35 gap fix. The owner: calls placed through the site's Twilio Call button (0970) are recorded, transcribed and
-- added to each renter's, lead's and booking's log, the same way Quo calls show transcripts and summaries. No caller
-- notice (the owner confirmed it, as Quo).
--   1. The voice TwiML records the customer leg (record-from-answer-dual); Twilio's recording callback carries the same
--      per-call token and signature as the other legs (src/server/twilio-call.ts).
--   2. The server copies the audio to our private storage (documents bucket, calls/twilio/<call id>.mp3), keeps the key on
--      outbound_calls and deletes it at Twilio (Program setting phone_twilio_delete_recording, on by default).
--   3. Speech to text with Workers AI Whisper, background tier, free allowance only (app.ai_allow('call_transcribe')): when
--      the share is used the call waits for the next day. The transcript goes on the call's phone_activity row (the same
--      place as Quo's), the existing one-line AI summary job then writes its summary, and the renter's and lead's intent
--      (1506, which reads phone_activity transcripts) is computed again at once.
--   4. Play recording: the call's entry lists the recording at /api/staff/phone/recording?id=<activity id>; the server asks
--      app.server_phone_recording, which allows the same people as the calls and texts reads (app.live_staff_ok).

alter table program_settings
  add column if not exists phone_twilio_record boolean not null default true,
  add column if not exists phone_twilio_delete_recording boolean not null default true;
comment on column program_settings.phone_twilio_record is 'Calls from the site (Twilio): record the call, transcribe it and summarise it on the person''s history (1880).';
comment on column program_settings.phone_twilio_delete_recording is 'Calls from the site (Twilio): delete the recording at Twilio once our copy is stored, so it is not kept twice (1880).';

alter table outbound_calls
  add column if not exists recording_sid text,
  add column if not exists recording_key text,
  add column if not exists recording_seconds integer check (recording_seconds >= 0),
  add column if not exists recording_state text check (recording_state in ('stored', 'transcribed', 'failed')),
  add column if not exists transcript_text text,
  add column if not exists transcribe_due_at timestamptz,
  add column if not exists transcribe_tries integer not null default 0,
  add column if not exists transcribe_error text;
create index if not exists outbound_calls_transcribe_due_idx on outbound_calls (transcribe_due_at) where transcribe_due_at is not null;

-- the call's history entry follows the call: the recording, then the transcript (and its summary is due)
create or replace function app.outbound_call_sync() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.activity_id is null then return null; end if;
  if new.recording_key is not null and (tg_op = 'INSERT' or new.activity_id is distinct from old.activity_id or new.recording_key is distinct from old.recording_key) then
    update phone_activity set recordings = jsonb_build_array(jsonb_build_object('url', '/api/staff/phone/recording?id=' || new.activity_id, 'source', 'site',
                                     'seconds', new.recording_seconds))
     where id = new.activity_id;
  end if;
  if new.transcript_text is not null and (tg_op = 'INSERT' or new.activity_id is distinct from old.activity_id or new.transcript_text is distinct from old.transcript_text) then
    update phone_activity set transcript = jsonb_build_array(jsonb_build_object('who', 'call', 'text', new.transcript_text, 'start', null, 'end', null)),
           summary_due_at = case when (app.settings()).phone_ai_summaries and quo_summary is null and ai_summary is null and btrim(new.transcript_text) <> '' then now() else summary_due_at end
     where id = new.activity_id;
  end if;
  return null;
end $$;
drop trigger if exists outbound_calls_sync on outbound_calls;
create trigger outbound_calls_sync after insert or update of activity_id, recording_key, transcript_text on outbound_calls
  for each row execute function app.outbound_call_sync();

-- the voice webhook: whether to record
create or replace function app.server_twilio_call_get(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', c.id, 'to', c.to_number, 'caller_id', app.phone_our_number(), 'status', c.status, 'record', (app.settings()).phone_twilio_record)
    from outbound_calls c where c.id = p_id and c.created_at > now() - interval '2 hours'
$$;

-- the recording callback: our copy is stored (key) or could not be (error). p: {id, recording_sid, key, seconds, error}
create or replace function app.server_twilio_recording(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c outbound_calls;
  v_key text := nullif(p ->> 'key', '');
begin
  select * into c from outbound_calls where id = nullif(p ->> 'id', '')::uuid for update;
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'unknown call'); end if;
  if v_key is not null and v_key !~ '^calls/twilio/[0-9a-f-]{36}\.mp3$' then raise exception 'Not a call recording key' using errcode = '22023'; end if;
  update outbound_calls set recording_sid = coalesce(nullif(p ->> 'recording_sid', ''), recording_sid),
         recording_key = coalesce(v_key, recording_key),
         recording_seconds = coalesce(nullif(p ->> 'seconds', '')::integer, recording_seconds),
         recording_state = case when v_key is not null then 'stored' when recording_key is null then 'failed' else recording_state end,
         transcribe_due_at = case when v_key is not null and (app.settings()).phone_twilio_record then now() else transcribe_due_at end,
         transcribe_error = case when v_key is null then left(coalesce(p ->> 'error', 'the recording could not be copied'), 300) else null end
   where id = c.id;
  return jsonb_build_object('ok', true, 'delete', v_key is not null and (app.settings()).phone_twilio_delete_recording);
end $$;

-- the next local midnight (plus a few minutes): when a used-up allowance is back
create or replace function app.next_ai_day(p_now timestamptz default now()) returns timestamptz
language sql stable as $$ select app.local_midnight(app.local_date(p_now) + 1) + interval '5 minutes' $$;

-- the recordings to transcribe now, within the background share of today's free allowance (never paid usage). When the
-- share is used, every waiting call moves to the next day.
create or replace function app.server_twilio_transcribe_due(p_limit integer default 2) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_items jsonb := '[]'::jsonb;
  r outbound_calls;
  a jsonb;
begin
  for r in select * from outbound_calls where transcribe_due_at <= now() and recording_state = 'stored' and recording_key is not null
            order by transcribe_due_at limit greatest(1, least(coalesce(p_limit, 2), 10)) for update skip locked loop
    a := app.ai_allow('call_transcribe', ceil(greatest(coalesce(r.recording_seconds, 60), 1) / 60.0 * 47));
    if not (a ->> 'ok')::boolean then
      update outbound_calls set transcribe_due_at = app.next_ai_day() where transcribe_due_at <= now() and recording_state = 'stored';
      return jsonb_build_object('items', v_items, 'waiting', true, 'message', a ->> 'message');
    end if;
    v_items := v_items || jsonb_build_object('id', r.id, 'key', r.recording_key, 'seconds', coalesce(r.recording_seconds, 60));
    update outbound_calls set transcribe_due_at = now() + interval '20 minutes' where id = r.id;  -- not picked twice while it runs
  end loop;
  return jsonb_build_object('items', v_items, 'waiting', false);
end $$;

-- the transcript (or why not). p: {id, ok, text, neurons, error, reason, duration_ms, model}
create or replace function app.server_twilio_transcript(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c outbound_calls;
  v_ok boolean := coalesce((p ->> 'ok')::boolean, false);
  v_text text := left(btrim(regexp_replace(coalesce(p ->> 'text', ''), '\s+', ' ', 'g')), 20000);
begin
  select * into c from outbound_calls where id = nullif(p ->> 'id', '')::uuid for update;
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'unknown call'); end if;
  if coalesce(p ->> 'reason', '') <> 'quota' or coalesce((p ->> 'neurons')::numeric, 0) > 0 then
    insert into provider_calls (provider, purpose, ok, error, duration_ms, units, unit)
    values ('workers-ai', 'call_transcribe', v_ok, left(p ->> 'error', 300), nullif(p ->> 'duration_ms', '')::integer, coalesce((p ->> 'neurons')::numeric, 0), 'neurons');
  end if;
  if v_ok then
    update outbound_calls set transcript_text = v_text, recording_state = 'transcribed', transcribe_due_at = null, transcribe_error = null where id = c.id;
    -- 1506: the renter's and the lead's intent read this call's words now (the 15-minute job only sees new activity)
    if c.renter_id is not null then perform app.intent_compute('renter', c.renter_id); end if;
    if c.lead_id is not null then perform app.intent_compute('lead', c.lead_id); end if;
  elsif p ->> 'reason' = 'quota' then
    update outbound_calls set transcribe_due_at = app.next_ai_day(), transcribe_error = left(p ->> 'error', 300) where id = c.id;
  else
    update outbound_calls set transcribe_tries = transcribe_tries + 1, transcribe_error = left(coalesce(p ->> 'error', 'speech to text failed'), 300),
           transcribe_due_at = case when transcribe_tries + 1 >= 3 then null else now() + interval '30 minutes' end,
           recording_state = case when transcribe_tries + 1 >= 3 then 'failed' else recording_state end
     where id = c.id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- Play recording: the storage key of a call's recording, for the people who may read calls and texts (0085's rule)
create or replace function app.server_phone_recording(p_user uuid, p_activity uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare v_key text;
begin
  if p_user is null or not app.live_staff_ok(p_user) then raise exception 'Call recordings are for Admins, customer service and Sales' using errcode = '42501'; end if;
  select c.recording_key into v_key from outbound_calls c where c.activity_id = p_activity and c.recording_key is not null;
  if v_key is null then raise exception 'No recording for this call' using errcode = 'P0002'; end if;
  return v_key;
end $$;

-- the server's calls (the Worker, as service_role)
create or replace function public.server_twilio_recording(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_twilio_recording(p) $$;
create or replace function public.server_twilio_transcribe_due(p_limit integer) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_twilio_transcribe_due(p_limit) $$;
create or replace function public.server_twilio_transcript(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_twilio_transcript(p) $$;
create or replace function public.server_phone_recording(p_user uuid, p_activity uuid) returns text
language sql stable security definer set search_path = public, app as $$ select app.server_phone_recording(p_user, p_activity) $$;

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['outbound_call_sync', 'server_twilio_call_get', 'server_twilio_recording', 'next_ai_day',
             'server_twilio_transcribe_due', 'server_twilio_transcript', 'server_phone_recording']))
        or (n.nspname = 'public' and p.proname = any (array['server_twilio_recording', 'server_twilio_transcribe_due', 'server_twilio_transcript', 'server_phone_recording']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
