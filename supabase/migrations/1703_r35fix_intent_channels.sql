-- 1703_r35fix_intent_channels.sql
-- Release 35, fix helper, task 4 (docs/changes/2026-11-11-r35fix-owner-decisions.md). The owner: lead intent (1506) must read
-- every channel. Checked against 1506's app.intent_inputs: it read call and text activity (body, voicemail, the AI summary,
-- the transcript), a renter's inbound messages, the site chat, the lead's own message and pipeline note, and website
-- behaviour. Missing, added here:
--   - Quo's own call summary and next steps (phone_activity.quo_summary, next_steps; the transcript was read already);
--   - staff notes on the renter (renters.staff_note, and every renter_notes row not removed, including those written on a
--     booking or a call);
--   - staff notes on the booking (bookings.notes) and the renter's request note (bookings.request_note), for the renter's
--     bookings of the last 60 days;
--   - staff notes on the lead (lead_contacts.note: each call, text or email logged on the lead);
--   - a lead's inbound emails (messages from the lead's email address; messages carry no lead id);
--   - WhatsApp, Messenger and Instagram messages, stored by the AI auto-replies (2110, auto_replies.question by sender),
--     matched to the renter's or the lead's mobile or email.
-- app.intent_inputs is replaced (same signature; 1506's reading kept as it was), and app.job_intent also refreshes whoever
-- got one of these since the last run.
-- No applied migration is edited.
set local check_function_bodies = off;

create function app.intent_phone_key(p text) returns text
language sql immutable as $$ select nullif(right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10), '') $$;

create or replace function app.intent_inputs(p_kind text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_texts text[];
  v_beh jsonb;
  v_renter uuid := case when p_kind = 'renter' then p_id end;
  v_lead uuid := case when p_kind = 'lead' then p_id end;
  v_phone text;
  v_email text;
begin
  if v_renter is not null then
    select app.intent_phone_key(r.mobile), lower(nullif(btrim(r.email), '')) into v_phone, v_email from renters r where r.id = v_renter;
  else
    select app.intent_phone_key(l.phone), lower(nullif(btrim(l.email), '')) into v_phone, v_email from leads l where l.id = v_lead;
  end if;
  v_texts := array(
    select x from (
      -- calls, voicemails and texts (Quo): the body, the voicemail, the summaries (ours and Quo's), the next steps, the transcript
      select concat_ws(' ', a.body, a.voicemail_text, a.ai_summary, a.quo_summary, a.next_steps::text, a.transcript::text) x, a.started_at at
        from phone_activity a where (a.renter_id = v_renter or a.lead_id = v_lead) and a.started_at > now() - interval '60 days'
      union all
      -- emails and messages in (a renter's; a lead's by their email address)
      select coalesce(m.subject, '') || ' ' || coalesce(m.body, ''), m.occurred_at from messages m
       where m.direction = 'inbound' and m.occurred_at > now() - interval '60 days'
         and ((v_renter is not null and m.renter_id = v_renter) or (v_lead is not null and v_email is not null and lower(m.from_address) = v_email))
      union all
      -- the site chat
      select cm.body, cm.at from chat_messages cm join chat_conversations c on c.id = cm.conversation_id
       where (c.renter_id = v_renter or c.lead_id = v_lead) and cm.sender = 'visitor' and cm.at > now() - interval '60 days'
      union all
      -- WhatsApp, Messenger and Instagram (kept by the auto-replies, 2110), by the sender's number or email
      select q.question, q.created_at from auto_replies q
       where q.channel in ('whatsapp', 'messenger', 'instagram') and q.question is not null and q.created_at > now() - interval '60 days'
         and ((v_phone is not null and app.intent_phone_key(q.sender) = v_phone) or (v_email is not null and lower(q.sender) = v_email))
      union all
      -- the lead's own message and notes, and the staff notes logged on the lead
      select concat_ws(' ', l.message, l.pipeline_note, l.vehicle_text, l.payload::text), l.created_at from leads l where l.id = v_lead
      union all
      select lc.note, lc.at from lead_contacts lc where v_lead is not null and lc.lead_id = v_lead and nullif(btrim(lc.note), '') is not null and lc.at > now() - interval '60 days'
      union all
      -- staff notes on the renter
      select r.staff_note, coalesce(r.updated_at, r.created_at) from renters r where v_renter is not null and r.id = v_renter and nullif(btrim(r.staff_note), '') is not null
      union all
      select n.body, n.created_at from renter_notes n where v_renter is not null and n.renter_id = v_renter and n.removed_at is null and n.created_at > now() - interval '60 days'
      union all
      -- staff notes on the renter's bookings, and what the renter wrote in the request
      select concat_ws(' ', b.request_note, b.notes), b.created_at from bookings b
       where v_renter is not null and b.renter_id = v_renter and not coalesce(b.is_placeholder, false) and b.created_at > now() - interval '60 days'
         and coalesce(nullif(btrim(b.request_note), ''), nullif(btrim(b.notes), '')) is not null
    ) q where nullif(btrim(x), '') is not null order by at desc nulls last limit 80);
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

-- every 15 minutes: whoever had activity since the last run, now also a staff note, a note on a lead or a booking, and a
-- WhatsApp, Messenger or Instagram message
create or replace function app.job_intent(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare r record; n integer := 0;
begin
  for r in select k, id from (
      select 'renter' k, a.renter_id id from phone_activity a where a.renter_id is not null and greatest(a.started_at, a.updated_at) > p_now - interval '30 minutes'
      union select 'lead', a.lead_id from phone_activity a where a.lead_id is not null and greatest(a.started_at, a.updated_at) > p_now - interval '30 minutes'
      union select 'renter', m.renter_id from messages m where m.renter_id is not null and m.direction = 'inbound' and m.occurred_at > p_now - interval '30 minutes'
      union select 'renter', s.renter_id from visitor_sessions s where s.renter_id is not null and s.last_seen_at > p_now - interval '30 minutes'
      union select 'renter', c.renter_id from chat_conversations c where c.renter_id is not null and c.last_message_at > p_now - interval '30 minutes'
      union select 'lead', c.lead_id from chat_conversations c where c.lead_id is not null and c.last_message_at > p_now - interval '30 minutes'
      union select 'lead', l.id from leads l where l.updated_at > p_now - interval '30 minutes' and l.kind not like 'owner%'
      union select 'lead', lc.lead_id from lead_contacts lc where lc.at > p_now - interval '30 minutes'
      union select 'renter', x.renter_id from renter_notes x where x.created_at > p_now - interval '30 minutes'
      union select 'renter', b.renter_id from bookings b where b.renter_id is not null and greatest(b.created_at, b.updated_at) > p_now - interval '30 minutes'
      union select 'renter', rr.id from renters rr where rr.updated_at > p_now - interval '30 minutes' and nullif(btrim(rr.staff_note), '') is not null
      union select 'renter', rr.id from auto_replies q join renters rr on app.intent_phone_key(rr.mobile) = app.intent_phone_key(q.sender) or lower(rr.email) = lower(q.sender)
        where q.channel in ('whatsapp', 'messenger', 'instagram') and q.created_at > p_now - interval '30 minutes'
      union select 'lead', l.id from auto_replies q join leads l on app.intent_phone_key(l.phone) = app.intent_phone_key(q.sender) or lower(l.email) = lower(q.sender)
        where q.channel in ('whatsapp', 'messenger', 'instagram') and q.created_at > p_now - interval '30 minutes' and l.kind not like 'owner%') q
    where id is not null limit 300 loop
    perform app.intent_compute(r.k, r.id);
    n := n + 1;
  end loop;
  return format('%s intents', n);
end $$;

revoke all on function app.intent_phone_key(text), app.intent_inputs(text, uuid), app.job_intent(timestamptz) from public, anon, authenticated;
grant execute on function app.intent_phone_key(text), app.intent_inputs(text, uuid), app.job_intent(timestamptz) to service_role;
