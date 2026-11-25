-- 3870: the Admin connector reads the evidence a dispute pack needs (Release 50). Read only, admin:read, Admins only; every
-- call logged in api_calls, access to a call recording or to ID images also in audit_log.
-- SCHEMA_MARKER 3870. No applied migration is edited.
--   list_comms          every call, text, chat and email of a renter (or a booking's renter, plus anything linked to the
--                       booking), oldest first, paged with next_cursor; card and ID numbers are taken out of the text.
--   get_call_recording  one call's full transcript and its recording as a link that expires in ten minutes.
--   get_id_check        a booking's ID checks (status, time, checker) with links to the licence images and the selfie.
--   get_booking_invoice a booking's lines: base rate, add-ons and fees, each with its HST, and the totals.
--   list_chats          with conversation or renter: the full thread(s), every message.
--   get_agreement       also the signed PDF (a link), each signer's IP address, method and signing time.
--   list_booking_photos, photo_standard (one car): each photo with a link.
-- Files are given to the web layer as {"_file": {"bucket", "key", "name"}}: it swaps each for a link signed with
-- LINK_SIGNING_KEY that /api/connector/file serves for ten minutes, without a staff session (src/app/api/mcp/route.ts).
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

-- ================================================================ helpers
-- card numbers (13 to 19 digits, spaced or not), Ontario licence numbers (A1234-12345-12345) and SINs (123 456 789) out of a text
create function app.comms_redact(p text) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select regexp_replace(regexp_replace(regexp_replace(p,
    '(?<![A-Za-z0-9])[A-Za-z][0-9]{4}[ -]?[0-9]{5}[ -]?[0-9]{5}(?![0-9])', '[ID number removed]', 'g'),
    '(?<![0-9])[0-9](?:[ -]?[0-9]){12,18}(?![0-9])', '[card number removed]', 'g'),
    '(?<![0-9-])[0-9]{3}[ -][0-9]{3}[ -][0-9]{3}(?![0-9-])', '[ID number removed]', 'g')
$$;

create function app.comms_file(p_bucket text, p_key text, p_name text default null) returns jsonb
language sql immutable set search_path = public, app, pg_temp as $$
  select case when nullif(p_key, '') is not null then jsonb_build_object('_file', jsonb_build_object('bucket', p_bucket, 'key', p_key, 'name', p_name)) end
$$;
create function app.comms_doc_file(p_doc uuid, p_name text default null) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.comms_file(d.storage_bucket, d.storage_path, coalesce(p_name, d.title)) from documents d where d.id = p_doc and d.purged_at is null and d.removed_at is null
$$;

create function app.comms_booking(p text) returns uuid
language sql stable security definer set search_path = public, app, pg_temp as $$
  select b.id from bookings b where b.booking_number = upper(btrim(coalesce(p, ''))) or b.id::text = lower(btrim(coalesce(p, ''))) limit 1
$$;

-- the renter of a booking number, or of a renter id, user id, email or phone
create function app.comms_renter(p_renter text, p_booking uuid) returns uuid
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  q text := nullif(btrim(coalesce(p_renter, '')), '');
  ph text := app.phone_e164(q);
  v uuid;
begin
  if p_booking is not null then return (select b.renter_id from bookings b where b.id = p_booking); end if;
  if q is null then return null; end if;
  if q ~* '^[0-9a-f-]{36}$' then
    select r.id into v from renters r where r.id::text = lower(q) or r.user_id::text = lower(q) order by r.merged_into nulls first limit 1;
  elsif q like '%@%' then
    select r.id into v from renters r left join users u on u.id = r.user_id
     where lower(r.email) = lower(q) or lower(u.email) = lower(q) order by r.merged_into nulls first, r.created_at limit 1;
  elsif ph is not null then
    select r.id into v from renters r left join users u on u.id = r.user_id
     where app.phone_e164(r.mobile) = ph or app.phone_e164(u.phone) = ph order by r.merged_into nulls first, r.created_at limit 1;
  end if;
  return v;
end $$;

create function app.comms_staff_name(p uuid) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$ select coalesce(u.display_name, u.full_name) from users u where u.id = p $$;

-- ================================================================ list_comms
create function app.comms_list(a jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_b uuid := app.comms_booking(a ->> 'booking');
  v_r uuid;
  v_u uuid;
  v_phones text[];
  v_emails text[];
  v_threads uuid[];
  v_bks uuid[];
  v_from timestamptz := nullif(a ->> 'from', '')::timestamptz;
  v_to timestamptz := nullif(a ->> 'to', '')::timestamptz;
  v_kinds text[] := case when jsonb_typeof(a -> 'kinds') = 'array' then array(select jsonb_array_elements_text(a -> 'kinds'))
                         when nullif(a ->> 'kinds', '') is not null then string_to_array(replace(a ->> 'kinds', ' ', ''), ',')
                         else array['call', 'sms', 'chat', 'email'] end;
  v_lim integer := least(greatest(coalesce(nullif(a ->> 'limit', '')::integer, 100), 1), 200);
  v_cur text;
  v_ck timestamptz;
  v_cid text;
  v_ours text := app.phone_our_number();
  v_rows jsonb;
  v_n integer;
begin
  if nullif(a ->> 'booking', '') is null and nullif(a ->> 'renter', '') is null then
    raise exception 'booking (CC-...) or renter (their id, user id, email or phone) is required' using errcode = '22023';
  end if;
  if nullif(a ->> 'booking', '') is not null and v_b is null then raise exception 'No booking %', a ->> 'booking' using errcode = 'P0002'; end if;
  if exists (select 1 from unnest(v_kinds) k where k not in ('call', 'sms', 'chat', 'email')) then raise exception 'kinds: call, sms, chat or email' using errcode = '22023'; end if;
  v_r := app.comms_renter(a ->> 'renter', v_b);
  if v_r is null and v_b is null then raise exception 'No renter matches %', left(a ->> 'renter', 80) using errcode = 'P0002'; end if;
  select r.user_id into v_u from renters r where r.id = v_r;
  select coalesce(array_agg(distinct x) filter (where x is not null), '{}') into v_phones from (
    select app.phone_e164(r.mobile) x from renters r where r.id = v_r
    union all select app.phone_e164(u.phone) from users u where u.id = v_u
    union all select app.phone_e164(d.mobile) from drivers d where d.renter_id = v_r and d.is_account_holder
    union all select t.number from phone_threads t where t.renter_id = v_r) p;
  select coalesce(array_agg(distinct lower(x)) filter (where x is not null), '{}') into v_emails from (
    select r.email x from renters r where r.id = v_r union all select u.email from users u where u.id = v_u) e;
  select coalesce(array_agg(t.id), '{}') into v_threads from phone_threads t where t.renter_id = v_r or t.number = any (v_phones) or (v_b is not null and t.booking_id = v_b);
  v_bks := case when v_b is not null then array[v_b] else '{}' end;
  if nullif(a ->> 'cursor', '') is not null then
    begin
      v_cur := convert_from(decode(a ->> 'cursor', 'base64'), 'UTF8');
      v_ck := split_part(v_cur, '|', 1)::timestamptz;
      v_cid := split_part(v_cur, '|', 2);
    exception when others then raise exception 'cursor: the next_cursor of the page before' using errcode = '22023';
    end;
  end if;

  with items as (
    -- calls on the phone history (Quo, the site's Call button, the business number ringing the browsers)
    select pa.started_at at, 'call:' || pa.id sid, jsonb_build_object('kind', 'call', 'id', pa.id, 'at', pa.started_at, 'direction', pa.direction,
        'from', case when pa.direction = 'in' then t.number else v_ours end, 'to', case when pa.direction = 'in' then v_ours else t.number end,
        'staff', app.comms_staff_name(coalesce(oc.staff_user_id, pa.sent_by, (select sp.user_id from staff_profiles sp where sp.quo_user_id = pa.quo_user_id))),
        'started_at', pa.started_at, 'answered_at', coalesce(pa.answered_at, oc.answered_at), 'ended_at', coalesce(pa.ended_at, oc.ended_at),
        'duration_seconds', coalesce(pa.duration_seconds, oc.duration_seconds),
        'outcome', coalesce(oc.outcome, case when pa.missed then 'missed' end, oc.status, pa.status),
        'transcript_text', app.comms_redact(coalesce(oc.transcript_text, m.transcript_text,
            nullif(array_to_string(array(select coalesce(l ->> 'who', '') || ': ' || coalesce(l ->> 'text', '') from jsonb_array_elements(case when jsonb_typeof(pa.transcript) = 'array' then pa.transcript else '[]'::jsonb end) l), E'\n'), ''))),
        'summary', app.comms_redact(coalesce(nullif(array_to_string(array(select jsonb_array_elements_text(case when jsonb_typeof(pa.quo_summary) = 'array' then pa.quo_summary else '[]'::jsonb end)), ' '), ''), pa.ai_summary)),
        'voicemail_text', app.comms_redact(pa.voicemail_text),
        'has_recording', oc.recording_key is not null or m.recording_key is not null or jsonb_array_length(coalesce(pa.recordings, '[]'::jsonb)) > 0 or pa.voicemail_url is not null,
        'booking_number', (select b.booking_number from bookings b where b.id = coalesce(pa.booking_id, oc.booking_id))) j
      from phone_activity pa join phone_threads t on t.id = pa.thread_id
      left join outbound_calls oc on oc.activity_id = pa.id
      left join app.inbound_call_media m on m.activity_id = pa.id
     where 'call' = any (v_kinds) and pa.kind = 'call'
       and (pa.renter_id = v_r or pa.thread_id = any (v_threads) or pa.booking_id = any (v_bks))
    union all
    -- site calls not on the history (no phone_activity row)
    select oc.started_at, 'call:' || oc.id, jsonb_build_object('kind', 'call', 'id', oc.id, 'at', oc.started_at, 'direction', 'out', 'from', v_ours, 'to', oc.to_number,
        'staff', app.comms_staff_name(oc.staff_user_id), 'started_at', oc.started_at, 'answered_at', oc.answered_at, 'ended_at', oc.ended_at,
        'duration_seconds', oc.duration_seconds, 'outcome', coalesce(oc.outcome, oc.status), 'transcript_text', app.comms_redact(oc.transcript_text), 'summary', null,
        'has_recording', oc.recording_key is not null, 'booking_number', (select b.booking_number from bookings b where b.id = oc.booking_id))
      from outbound_calls oc
     where 'call' = any (v_kinds) and (oc.activity_id is null or not exists (select 1 from phone_activity x where x.id = oc.activity_id))
       and (oc.renter_id = v_r or oc.to_number = any (v_phones) or oc.booking_id = any (v_bks))
    union all
    -- texts on the phone line
    select pa.started_at, 'sms:' || pa.id, jsonb_build_object('kind', 'sms', 'id', pa.id, 'at', pa.started_at, 'direction', pa.direction,
        'from', case when pa.direction = 'in' then t.number else v_ours end, 'to', case when pa.direction = 'in' then v_ours else t.number end,
        'sender', case when pa.direction = 'in' then 'renter' else coalesce(app.comms_staff_name(pa.sent_by), 'CarmaCars (automatic)') end,
        'body', app.comms_redact(pa.body), 'status', pa.status, 'media', jsonb_array_length(coalesce(pa.media, '[]'::jsonb)),
        'booking_number', (select b.booking_number from bookings b where b.id = pa.booking_id))
      from phone_activity pa join phone_threads t on t.id = pa.thread_id
     where 'sms' = any (v_kinds) and pa.kind = 'text'
       and (pa.renter_id = v_r or pa.thread_id = any (v_threads) or pa.booking_id = any (v_bks))
    union all
    -- the messages log: emails, and texts or WhatsApp not already on the phone line
    select ms.occurred_at, case when ms.channel = 'email' then 'email:' else 'sms:' end || ms.id,
        jsonb_build_object('kind', case when ms.channel = 'email' then 'email' else 'sms' end, 'id', ms.id, 'at', ms.occurred_at, 'channel', ms.channel,
        'direction', case ms.direction when 'inbound' then 'in' else 'out' end, 'from', ms.from_address, 'to', ms.to_address,
        'sender', case when ms.direction = 'inbound' then 'renter' else coalesce(app.comms_staff_name(ms.sent_by), 'CarmaCars (automatic)') end,
        'subject', app.comms_redact(ms.subject), 'template', ms.template_code, 'status', ms.status, 'provider', ms.provider,
        'body', app.comms_redact(left(ms.body, 4000)), 'booking_number', (select b.booking_number from bookings b where b.id = ms.booking_id))
      from messages ms
     where ((ms.channel = 'email' and 'email' = any (v_kinds)) or (ms.channel in ('sms', 'whatsapp') and 'sms' = any (v_kinds)))
       and (ms.renter_id = v_r or (v_u is not null and ms.user_id = v_u) or ms.booking_id = any (v_bks)
            or (ms.channel = 'email' and lower(case when ms.direction = 'inbound' then ms.from_address else ms.to_address end) = any (v_emails))
            or (ms.channel <> 'email' and app.phone_e164(case when ms.direction = 'inbound' then ms.from_address else ms.to_address end) = any (v_phones)))
       and not (ms.channel <> 'email' and exists (select 1 from phone_activity x where x.kind = 'text' and x.thread_id = any (v_threads) and x.body = ms.body
                                                    and abs(extract(epoch from x.started_at - ms.occurred_at)) < 300))
    union all
    -- the website chat and portal messages
    select cm.at, 'chat:' || cm.id, jsonb_build_object('kind', 'chat', 'id', cm.id, 'at', cm.at, 'conversation', c.number, 'conversation_id', c.id,
        'direction', case when cm.sender = 'visitor' then 'in' else 'out' end,
        'sender', case cm.sender when 'visitor' then 'renter' when 'staff' then coalesce(app.comms_staff_name(cm.staff_id), 'staff') when 'ai' then 'CarmaCars assistant (AI)' else 'system' end,
        'body', app.comms_redact(cm.body), 'booking_number', (select b.booking_number from bookings b where b.id = c.booking_id))
      from chat_messages cm join chat_conversations c on c.id = cm.conversation_id
     where 'chat' = any (v_kinds)
       and (c.renter_id = v_r or (v_u is not null and c.user_id = v_u) or c.booking_id = any (v_bks)
            or lower(c.email) = any (v_emails) or app.phone_e164(c.phone) = any (v_phones))
  ), page as (
    select i.at, i.sid, i.j from items i
     where (v_from is null or i.at >= v_from) and (v_to is null or i.at <= v_to)
       and (v_ck is null or (i.at, i.sid) > (v_ck, v_cid))
     order by i.at, i.sid limit v_lim + 1
  ), numbered as (select p.*, row_number() over (order by p.at, p.sid) n from page p)
  select coalesce(jsonb_agg(x.j order by x.at, x.sid) filter (where x.n <= v_lim), '[]'::jsonb), count(*)::integer,
         max(case when x.n = v_lim then encode(convert_to(x.at::text || '|' || x.sid, 'UTF8'), 'base64') end)
    into v_rows, v_n, v_cur from numbered x;

  return jsonb_build_object(
    'renter', (select jsonb_build_object('renter_id', r.id, 'user_id', r.user_id, 'name', r.legal_name, 'email', r.email, 'phones', to_jsonb(v_phones)) from renters r where r.id = v_r),
    'booking', (select b.booking_number from bookings b where b.id = v_b),
    'kinds', to_jsonb(v_kinds), 'from', v_from, 'to', v_to,
    'items', v_rows, 'count', least(v_n, v_lim),
    'next_cursor', case when v_n > v_lim then replace(v_cur, E'\n', '') end,
    'note', 'Oldest first. Card and ID numbers are taken out of every text. get_call_recording gives a call''s recording and full transcript.');
end $$;

-- ================================================================ get_call_recording
create function app.comms_recording(p_by uuid, p_key uuid, a jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_id uuid := case when coalesce(a ->> 'call', a ->> 'id', '') ~* '^[0-9a-f-]{36}$' then coalesce(a ->> 'call', a ->> 'id')::uuid end;
  pa phone_activity;
  oc outbound_calls;
  m app.inbound_call_media;
  v_key text;
  v_lines jsonb;
begin
  if v_id is null then raise exception 'call: the call''s id (from list_comms)' using errcode = '22023'; end if;
  select * into pa from phone_activity x where x.id = v_id and x.kind = 'call';
  select * into oc from outbound_calls x where x.activity_id = v_id or x.id = v_id order by (x.id = v_id) desc limit 1;
  if pa.id is null and oc.id is not null and oc.activity_id is not null then select * into pa from phone_activity x where x.id = oc.activity_id; end if;
  if pa.id is null and oc.id is null then raise exception 'No call %', v_id using errcode = 'P0002'; end if;
  if pa.id is not null then select * into m from app.inbound_call_media x where x.activity_id = pa.id; end if;
  v_key := coalesce(m.recording_key, oc.recording_key);
  v_lines := case when jsonb_typeof(pa.transcript) = 'array' then pa.transcript else '[]'::jsonb end;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'call_recording_access', case when pa.id is not null then 'phone_activity' else 'outbound_calls' end, coalesce(pa.id, oc.id)::text,
          jsonb_build_object('via', 'connector', 'api_key_id', p_key, 'has_copy', v_key is not null));
  return jsonb_build_object(
    'call_id', coalesce(pa.id, oc.id), 'at', coalesce(pa.started_at, oc.started_at), 'direction', coalesce(pa.direction, 'out'),
    'duration_seconds', coalesce(pa.duration_seconds, oc.duration_seconds, oc.recording_seconds, m.recording_seconds),
    'staff', app.comms_staff_name(coalesce(oc.staff_user_id, pa.sent_by)),
    'transcript_text', app.comms_redact(coalesce(oc.transcript_text, m.transcript_text,
        nullif(array_to_string(array(select coalesce(l ->> 'who', '') || ': ' || coalesce(l ->> 'text', '') from jsonb_array_elements(v_lines) l), E'\n'), ''))),
    'transcript_lines', (select coalesce(jsonb_agg(jsonb_build_object('who', l ->> 'who', 'text', app.comms_redact(l ->> 'text'), 'start', l -> 'start', 'end', l -> 'end')), '[]'::jsonb) from jsonb_array_elements(v_lines) l),
    'summary', app.comms_redact(coalesce(nullif(array_to_string(array(select jsonb_array_elements_text(case when jsonb_typeof(pa.quo_summary) = 'array' then pa.quo_summary else '[]'::jsonb end)), ' '), ''), pa.ai_summary)),
    'voicemail_text', app.comms_redact(pa.voicemail_text),
    'recording', app.comms_file('documents', v_key, 'call-' || coalesce(pa.id, oc.id) || '.mp3'),
    -- a Quo call: Quo keeps the audio; its own links, as Quo gave them
    'provider_recordings', case when v_key is null then (select coalesce(jsonb_agg(r -> 'url'), '[]'::jsonb) from jsonb_array_elements(coalesce(pa.recordings, '[]'::jsonb)) r
                                                       where r ->> 'url' like 'http%') || coalesce(to_jsonb(array_remove(array[pa.voicemail_url], null)), '[]'::jsonb) end,
    'no_recording', v_key is null and jsonb_array_length(coalesce(pa.recordings, '[]'::jsonb)) = 0 and pa.voicemail_url is null);
end $$;

-- ================================================================ get_id_check
create function app.comms_id_check(p_by uuid, p_key uuid, a jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_b uuid := app.comms_booking(a ->> 'booking');
  v jsonb;
begin
  if v_b is null then raise exception 'No booking %', coalesce(a ->> 'booking', '') using errcode = 'P0002'; end if;
  v := jsonb_build_object(
    'booking', (select b.booking_number from bookings b where b.id = v_b),
    'pickup_checks', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'at', c.created_at, 'driver', (select d.full_name from drivers d where d.id = c.driver_id),
        'checked_by', case when c.by_renter then 'the renter (self check)' else app.comms_staff_name(c.checked_by) end, 'outcome', c.outcome,
        'name_result', c.name_result, 'number_result', c.number_result, 'expiry_result', c.expiry_result, 'face_result', c.face_result,
        'card_last4_result', c.card_last4_result, 'card_name_result', c.card_name_result, 'mismatches', to_jsonb(c.mismatches), 'coverage_problem', c.coverage_problem,
        'licence_image', (select app.comms_doc_file(u.document_id, 'licence-' || c.id) from verification_uploads u where u.id = c.id_upload),
        'selfie', (select app.comms_doc_file(u.document_id, 'selfie-' || c.id) from verification_uploads u where u.id = c.selfie_upload)) order by c.created_at), '[]'::jsonb)
      from pickup_identity_checks c where c.booking_id = v_b),
    'verifications', (select coalesce(jsonb_agg(jsonb_build_object('id', iv.id, 'driver', (select d.full_name from drivers d where d.id = iv.driver_id), 'method', iv.method,
        'status', iv.status, 'provider', iv.provider, 'created_at', iv.created_at, 'verified_at', iv.verified_at, 'verified_by', app.comms_staff_name(iv.verified_by),
        'face_match_score', iv.face_match_score, 'failure_reason', iv.failure_reason, 'purged', iv.purged_at is not null,
        'licence_front', app.comms_doc_file(iv.id_front_document_id, 'licence-front'), 'licence_back', app.comms_doc_file(iv.id_back_document_id, 'licence-back'),
        'selfie', app.comms_doc_file(iv.face_document_id, 'selfie')) order by iv.created_at), '[]'::jsonb)
      from identity_verifications iv
     where iv.booking_id = v_b or iv.id in (select bd.identity_verification_id from booking_drivers bd where bd.booking_id = v_b)),
    'uploads', (select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'kind', u.kind, 'page', u.page_kind, 'status', u.status, 'uploaded_at', u.uploaded_at,
        'reviewed_at', u.reviewed_at, 'reviewed_by', app.comms_staff_name(u.reviewed_by), 'reject_reason', u.reject_reason, 'file', app.comms_doc_file(u.document_id, u.kind || '-' || u.id))
        order by u.uploaded_at), '[]'::jsonb) from verification_uploads u where u.booking_id = v_b),
    'note', 'Licence and card numbers are left out; the images are links that expire in ten minutes.');
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'id_images_access', 'bookings', v_b::text, jsonb_build_object('via', 'connector', 'api_key_id', p_key));
  return v;
end $$;

-- ================================================================ get_booking_invoice
create function app.comms_booking_invoice(a jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_b uuid := app.comms_booking(a ->> 'booking');
  v_lines jsonb;
begin
  if v_b is null then raise exception 'No booking %', coalesce(a ->> 'booking', '') using errcode = 'P0002'; end if;
  select coalesce(jsonb_agg(x.j order by x.ord, x.created_at), '[]'::jsonb) into v_lines from (
    select case when l.charge_type = 'rental_charge' then 0 when l.booking_addon_id is not null or f.family = 'rental' then 1 else 2 end ord, l.created_at,
      jsonb_build_object('id', l.id, 'category', case when l.charge_type = 'rental_charge' then 'base_rate' when l.booking_addon_id is not null or f.family = 'rental' then 'add_on' else coalesce(f.family, 'fee') end,
        'charge_type', l.charge_type, 'label', f.label, 'description', l.description, 'quantity', l.quantity, 'unit_amount_cents', l.unit_amount_cents,
        'amount_cents', l.amount_cents, 'hst_applies', l.hst_applies, 'hst_cents', l.hst_cents, 'total_cents', l.amount_cents + l.hst_cents,
        'stage', l.stage, 'charged_to_renter', l.charged_to_renter, 'created_at', l.created_at, 'paid', l.payment_id is not null) j
      from booking_line_items l left join fee_types f on f.code = l.charge_type
     where l.booking_id = v_b and l.voided_at is null) x;
  return (select jsonb_build_object('booking', b.booking_number, 'status', b.status,
      'rate', jsonb_build_object('applied', b.rate_applied, 'billable_days', b.billable_days, 'daily_cents', b.daily_rate_cents, 'weekend_cents', b.weekend_rate_cents,
                                 'weekly_cents', b.weekly_rate_cents, 'monthly_cents', b.monthly_rate_cents, 'daily_days', b.daily_days, 'weekend_days', b.weekend_days),
      'lines', v_lines,
      'totals', (select jsonb_build_object(
          'base_rate_cents', coalesce(sum((l ->> 'amount_cents')::bigint) filter (where l ->> 'category' = 'base_rate'), 0),
          'add_ons_cents', coalesce(sum((l ->> 'amount_cents')::bigint) filter (where l ->> 'category' = 'add_on'), 0),
          'fees_cents', coalesce(sum((l ->> 'amount_cents')::bigint) filter (where l ->> 'category' not in ('base_rate', 'add_on')), 0),
          'subtotal_cents', coalesce(sum((l ->> 'amount_cents')::bigint), 0), 'hst_cents', coalesce(sum((l ->> 'hst_cents')::bigint), 0),
          'total_cents', coalesce(sum((l ->> 'total_cents')::bigint), 0)) from jsonb_array_elements(v_lines) l),
      'at_booking', jsonb_build_object('subtotal_cents', b.subtotal_at_booking_cents, 'hst_cents', b.hst_at_booking_cents, 'total_cents', b.total_due_at_booking_cents))
    from bookings b where b.id = v_b);
end $$;

-- ================================================================ list_chats: one conversation, or a renter's, in full
create function app.comms_chat_threads(a jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  q text := nullif(btrim(coalesce(a ->> 'conversation', '')), '');
  v_r uuid := case when nullif(a ->> 'renter', '') is not null then app.comms_renter(a ->> 'renter', null) end;
  v_u uuid := (select r.user_id from renters r where r.id = v_r);
  v_email text := (select lower(r.email) from renters r where r.id = v_r);
  v_phone text := (select app.phone_e164(r.mobile) from renters r where r.id = v_r);
  v jsonb;
begin
  if nullif(a ->> 'renter', '') is not null and v_r is null then raise exception 'No renter matches %', left(a ->> 'renter', 80) using errcode = 'P0002'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'number', c.number, 'name', c.name, 'email', c.email, 'phone', c.phone, 'status', c.status, 'page', c.page,
      'started_at', c.created_at, 'closed_at', c.closed_at, 'assigned_to', app.comms_staff_name(c.assigned_to), 'booking_number', (select b.booking_number from bookings b where b.id = c.booking_id),
      'messages', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'at', m.at,
                     'sender', case m.sender when 'visitor' then 'renter' when 'staff' then coalesce(app.comms_staff_name(m.staff_id), 'staff') when 'ai' then 'CarmaCars assistant (AI)' else 'system' end,
                     'body', app.comms_redact(m.body)) order by m.at, m.id), '[]'::jsonb) from chat_messages m where m.conversation_id = c.id)) order by c.created_at), '[]'::jsonb)
    into v from chat_conversations c
   where (q is not null and (c.id::text = lower(q) or upper(c.number) = upper(q)))
      or (v_r is not null and (c.renter_id = v_r or (v_u is not null and c.user_id = v_u) or lower(c.email) = v_email or app.phone_e164(c.phone) = v_phone));
  if q is not null and jsonb_array_length(v) = 0 then raise exception 'No chat %', left(q, 60) using errcode = 'P0002'; end if;
  return jsonb_build_object('conversations', v, 'count', jsonb_array_length(v), 'note', 'Every message of each conversation, oldest first; card and ID numbers taken out.');
end $$;

-- ================================================================ the files on existing reads
create function app.comms_agreement_files(v jsonb) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case when jsonb_typeof(v -> 'agreements') <> 'array' then v else v || jsonb_build_object('agreements', (
    select coalesce(jsonb_agg(e || coalesce((select jsonb_build_object(
        'signed_pdf', app.comms_doc_file(sr.signed_document_id, g.agreement_number || '-signed.pdf'),
        'document_pdf', case when sr.signed_document_id is null then app.comms_doc_file(g.document_id, g.agreement_number || '.pdf') end,
        'document_sha256', g.document_sha256,
        'signatures', (select coalesce(jsonb_agg(jsonb_build_object('role', s.signer_role, 'name', s.signer_name, 'status', s.status, 'signed_at', s.signed_at, 'ip_address', s.ip_address,
                         'method', s.method, 'user_agent', left(s.user_agent, 200), 'typed_name', s.typed_name, 'collected_in_person_by', app.comms_staff_name(s.collected_in_person_by))
                         order by s.signed_at nulls last, s.created_at), '[]'::jsonb) from signature_records s where s.signature_request_id = g.signature_request_id))
      from rental_agreements g left join signature_requests sr on sr.id = g.signature_request_id
     where g.agreement_number = e ->> 'agreement_number' and g.booking_id = app.comms_booking(v ->> 'booking') limit 1), '{}'::jsonb) order by o), '[]'::jsonb)
      from jsonb_array_elements(v -> 'agreements') with ordinality t(e, o))) end
$$;

create function app.comms_photo_files(v jsonb) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case when jsonb_typeof(v -> 'items') <> 'array' then v else v || jsonb_build_object('items', (
    select coalesce(jsonb_agg(e || coalesce((select jsonb_build_object('image', app.comms_file(p.storage_bucket, p.storage_path, coalesce(p.shot, 'photo') || '-' || p.seq || '.jpg'))
                                           from condition_report_photos p where p.id::text = e ->> 'id'), '{}'::jsonb) order by o), '[]'::jsonb)
      from jsonb_array_elements(v -> 'items') with ordinality t(e, o))) end
$$;

create function app.comms_listing_files(v jsonb) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case when jsonb_typeof(v -> 'cars') <> 'array' or jsonb_array_length(v -> 'cars') <> 1 then v else v || jsonb_build_object('cars', jsonb_build_array((v -> 'cars' -> 0) || jsonb_build_object('images', (
    select coalesce(jsonb_agg(jsonb_build_object('photo_id', ph.id, 'shot', ph.shot_type, 'public', ph.is_public, 'cover', ph.is_cover, 'status', ph.status, 'ai_generated', ph.ai_generated,
             'image', app.comms_file('vehicle-originals', ph.original_path, coalesce(ph.shot_type, 'photo') || '-' || ph.sort_order || '.jpg'))
             order by ph.sort_order, ph.id), '[]'::jsonb)
      from vehicle_photos ph where ph.vehicle_id = ((v -> 'cars' -> 0) ->> 'vehicle_id')::uuid and ph.replaced_at is null and ph.status <> 'rejected'))))) end
$$;

-- ================================================================ the call
alter function app.api_call(text, text, jsonb, text) rename to api_call_pre3870;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  chk jsonb;
  k api_keys;
  v_result jsonb;
  r jsonb;
begin
  if p_tool in ('get_agreement', 'list_booking_photos', 'photo_standard') then
    r := app.api_call_pre3870(p_hash, p_tool, p_args, p_client);
    if not coalesce((r ->> 'ok')::boolean, false) or jsonb_typeof(r -> 'result') <> 'object' then return r; end if;
    return jsonb_set(r, '{result}', case p_tool when 'get_agreement' then app.comms_agreement_files(r -> 'result')
                                                when 'list_booking_photos' then app.comms_photo_files(r -> 'result')
                                                else app.comms_listing_files(r -> 'result') end);
  end if;
  if p_tool = 'list_chats' and nullif(a ->> 'conversation', '') is null and nullif(a ->> 'renter', '') is null then
    return app.api_call_pre3870(p_hash, p_tool, p_args, p_client);
  end if;
  if p_tool not in ('list_comms', 'get_call_recording', 'get_id_check', 'get_booking_invoice', 'list_chats') then
    return app.api_call_pre3870(p_hash, p_tool, p_args, p_client);
  end if;
  chk := app.api_key_check(p_hash, 'admin:read', p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  begin
    v_result := case p_tool
      when 'list_comms' then app.comms_list(a)
      when 'get_call_recording' then app.comms_recording(k.user_id, k.id, a)
      when 'get_id_check' then app.comms_id_check(k.user_id, k.id, a)
      when 'get_booking_invoice' then app.comms_booking_invoice(a)
      else app.comms_chat_threads(a) end;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, p_tool, a, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, ok, client)
  values (k.id, k.user_id, p_tool, coalesce(a ->> 'booking', a ->> 'renter', a ->> 'call', a ->> 'conversation', p_tool), a, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre3870(text, text, jsonb, text)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['comms_redact', 'comms_file', 'comms_doc_file', 'comms_booking', 'comms_renter', 'comms_staff_name', 'comms_list',
              'comms_recording', 'comms_id_check', 'comms_booking_invoice', 'comms_chat_threads', 'comms_agreement_files', 'comms_photo_files', 'comms_listing_files', 'api_call_pre3870']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
