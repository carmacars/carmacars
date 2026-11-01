-- 0370_live_chat_ai_autoclose.sql
-- Live chat: the assistant answers again, the counts and alerts are right, and chats close when the visitor leaves
-- (docs/changes/2026-11-06-live-chat-ai-autoclose.md). SCHEMA_MARKER 0371 (0371 carries the guide chapters).
--
-- The owner: "the live chat numbers / alerts seem to be broken", "live chats should auto close if theyre not on the
-- website anymore then whats the point of us responding unless they gave us their number or email?" and "why isnt the
-- ai chat assistant responding to live chats at all?"
--
-- Why the assistant did not answer (found in the code; see the change record):
--   a. Live chat's share of the day was what the staff assistant's 70% reserve and background work left: 10,000 less
--      7,000 less everything the background used (guide upkeep after each deploy, search copy, and every neuron
--      Cloudflare counts that the app did not record). Background regularly went past 3,000, so live chat had no room
--      and every message went straight to a person, with no AI call and nothing recorded for "Visitor live chat".
--   b. A chat handed to a person stayed open for ever (only the assistant's own chats closed after 12 hours), and the
--      same browser's next chat continued it: once a visitor's chat had gone to a person, the assistant never answered
--      that visitor again.
--   c. Every reply sent the whole fleet to Llama 3.3 70B (about 250 neurons a step, up to three steps): the share ran
--      out after a handful of chats. The site now uses Llama 3.1 8B (about one sixth of the neurons) and a shorter
--      context, and answers common questions from the facts with no model call (web/src/features/chat).
--   d. A failure was swallowed: the chat went to a person with "the assistant is not available" and nothing else.
--      Now the conversation shows a note for staff, the failure is recorded, and Live chat says "AI replies paused:
--      <reason>".
--
-- 1. Settings: the staff assistant keeps 30% (was 70%), live features get their own 50% (ai_live_bps, an Admin
--    setting, empty: what is not reserved, as before), background 10%. The chat's model: Llama 3.1 8B. AI replies on.
--    chat_auto_close_minutes (10): a visitor not seen on the site for this long has left.
-- 2. The counts: a chat needs a reply when it waits for a person, or a person has it and the visitor wrote last. The
--    menu's badge, the inbox and the page title count exactly those; follow-ups and closed chats never count.
-- 3. Alerts: one in-app notice (and the phone alert of the "messages" topic) for each new visitor message waiting for
--    staff (staff_chat_message), to the person on the chat, else every Admin, customer service and Sales account; on
--    or off shift. A notice is marked read once someone replies, the chat closes or becomes a follow-up, so its push
--    is not sent late. The email "a chat waits" stays as it was (opt-in, on shift).
-- 4. Auto-close (app.job_chat_auto_close, every minute): a visitor gone for the window (no heartbeat, no chat poll,
--    no message) with no phone or email: the chat closes, "Visitor left, no contact". With a phone or email (and at
--    least one message): it stays open as a follow-up lead, out of the counts, with the task "Follow up by text/email"
--    in customer service's queue. A visitor who comes back (their browser polls the chat, or opens it again) reopens it.
-- 5. Contact typed into a message (an email or a phone number) is kept on the chat, as the contact form does.
-- 6. Staff notes: a system message only staff see (meta staff_only), for the assistant's failures and pauses.
-- No applied migration is edited.
set local check_function_bodies = off;

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists chat_auto_close_minutes integer not null default 10 check (chat_auto_close_minutes between 2 and 1440),
  add column if not exists ai_live_bps integer default 5000 check (ai_live_bps is null or ai_live_bps between 0 and 10000);
comment on column program_settings.chat_auto_close_minutes is 'Live chat (0370): a visitor not seen on the site for this many minutes has left. Their chat closes ("Visitor left, no contact"), or becomes a follow-up when they gave a phone or email. 10 by default.';
comment on column program_settings.ai_live_bps is 'AI budget (0370): the share of the day''s free Workers AI neurons for live features (visitor chat, the phone line, the readers; 5000 = 50%). Background work never uses it. Empty: live features share what is not reserved for the staff assistant (0133).';

alter table program_settings alter column ai_assistant_reserve_bps set default 3000;
update program_settings set ai_assistant_reserve_bps = 3000 where ai_assistant_reserve_bps = 7000;
comment on column program_settings.ai_assistant_reserve_bps is 'AI budget (0133, 0370): the share of the day''s free Workers AI neurons kept for the staff assistant alone (3000 = 30%). Nothing else may use it before the release hour.';
alter table program_settings alter column chat_ai_model set default '@cf/meta/llama-3.1-8b-instruct-fp8-fast';
update program_settings set chat_ai_model = '@cf/meta/llama-3.1-8b-instruct-fp8-fast' where chat_ai_model = '@cf/meta/llama-3.3-70b-instruct-fp8-fast';
update program_settings set chat_ai_enabled = true where not chat_ai_enabled;

-- ================================================================ 2. the conversation's new facts
alter table chat_conversations
  add column if not exists visitor_seen_at timestamptz,
  add column if not exists closed_reason text,
  add column if not exists status_before_close text,
  add column if not exists reopened_at timestamptz,
  add column if not exists followup_at timestamptz,
  add column if not exists followup_task_id uuid references tasks (id) on delete set null,
  add column if not exists alerted_msg_id bigint not null default 0;
comment on column chat_conversations.visitor_seen_at is 'Live chat (0370): the visitor''s browser last polled the chat (written at most every 20 seconds).';
comment on column chat_conversations.closed_reason is 'Live chat (0370): visitor_left when the chat closed because the visitor left the site without a phone or email.';
comment on column chat_conversations.followup_at is 'Live chat (0370): the visitor left with a phone or email; the chat is a follow-up lead (task "Follow up by text/email"), out of the counts.';
comment on column chat_conversations.alerted_msg_id is 'Live chat (0370): the last visitor message staff were alerted about (one alert per message).';
create index if not exists chat_conversations_followup_idx on chat_conversations (followup_at) where followup_at is not null;

-- ================================================================ 3. the AI budget with live chat's own share
create or replace function app.ai_budget(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_t0 timestamptz := app.local_midnight(app.local_date(p_now));
  v_inc numeric;
  v_a numeric; v_l numeric; v_b numeric; v_app numeric; v_ext numeric; v_all numeric; v_gap numeric;
  v_reserve numeric; v_bgcap numeric; v_livecap numeric; v_cushion numeric; v_late boolean;
  r_a numeric; r_l numeric; r_b numeric;
begin
  select coalesce(max(s.included) filter (where s.enabled), 10000) into v_inc from usage_services s where s.service = 'workers_ai';
  v_inc := coalesce(v_inc, 10000);
  select coalesce(sum(c.units) filter (where app.ai_tier(c.purpose) = 'assistant'), 0),
         coalesce(sum(c.units) filter (where app.ai_tier(c.purpose) = 'live'), 0),
         coalesce(sum(c.units) filter (where app.ai_tier(c.purpose) = 'background'), 0),
         coalesce(sum(c.units), 0)
    into v_a, v_l, v_b, v_app
    from provider_calls c where c.unit = 'neurons' and c.created_at >= v_t0 and c.created_at < v_t0 + interval '1 day';
  select coalesce(max(r.used), 0) into v_ext from usage_readings r where r.service = 'workers_ai' and r.day = app.local_date(p_now) and r.source <> 'app';
  v_all := greatest(v_app, v_ext);
  v_gap := v_all - v_app;
  v_b := v_b + v_gap;
  v_reserve := round(v_inc * ps.ai_assistant_reserve_bps / 10000.0);
  v_bgcap := round(v_inc * ps.ai_background_bps / 10000.0);
  v_livecap := case when ps.ai_live_bps is not null then round(v_inc * ps.ai_live_bps / 10000.0) end;
  v_cushion := least(ps.ai_assistant_cushion, v_reserve);
  v_late := ps.ai_release_hour is not null and app.local_hour(p_now) >= ps.ai_release_hour;
  r_a := least(v_inc - v_all, ps.assistant_daily_neurons - v_a);
  if v_late then
    r_l := least(v_inc - v_all, v_inc - v_cushion - v_all);
    r_b := r_l;
  else
    -- live: its own share (never eaten by background work), within what the assistant's reserve leaves
    r_l := least(v_inc - v_all, v_inc - v_reserve - (v_l + v_b), coalesce(v_livecap - v_l, v_inc));
    -- background: its share, never live chat's unused share
    r_b := least(v_inc - v_all, v_bgcap - v_b, v_inc - v_reserve - (v_l + v_b) - coalesce(greatest(v_livecap - v_l, 0), 0));
  end if;
  return jsonb_build_object(
    'included', v_inc, 'used', v_all, 'used_app', v_app, 'unmetered', v_gap, 'hard_stop', true,
    'tiers', jsonb_build_object('assistant', v_a, 'live', v_l, 'background', v_b),
    'room', jsonb_build_object('assistant', greatest(r_a, 0), 'live', greatest(r_l, 0), 'background', greatest(r_b, 0)),
    'reserve', v_reserve, 'background_cap', v_bgcap, 'live_cap', v_livecap, 'cushion', v_cushion, 'late', v_late,
    'reserve_bps', ps.ai_assistant_reserve_bps, 'background_bps', ps.ai_background_bps, 'live_bps', ps.ai_live_bps, 'release_hour', ps.ai_release_hour,
    'assistant_daily', ps.assistant_daily_neurons,
    'resets_at', app.local_midnight(app.local_date(p_now) + 1));
end $$;

-- An Admin changes the shares: p {reserve_bps, live_bps (empty: what is not reserved), background_bps, release_hour, cushion}.
create or replace function app.ai_shares_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_id uuid := ps.id;
  v_res integer := nullif(p ->> 'reserve_bps', '')::integer;
  v_bg integer := nullif(p ->> 'background_bps', '')::integer;
  v_live integer := case when p ? 'live_bps' then nullif(p ->> 'live_bps', '')::integer else ps.ai_live_bps end;
  v_cush integer := nullif(p ->> 'cushion', '')::integer;
begin
  perform app.assert_admin(p_user);
  if v_res is not null and (v_res < 0 or v_res > 9500) then raise exception 'The assistant''s reserve is between 0%% and 95%%' using errcode = '22023'; end if;
  if v_bg is not null and (v_bg < 0 or v_bg > 5000) then raise exception 'The background share is between 0%% and 50%%' using errcode = '22023'; end if;
  if v_live is not null and (v_live < 0 or v_live > 10000) then raise exception 'The live share is between 0%% and 100%%' using errcode = '22023'; end if;
  if coalesce(v_res, ps.ai_assistant_reserve_bps) + coalesce(v_bg, ps.ai_background_bps) + coalesce(v_live, 0) > 10000 then
    raise exception 'The assistant''s reserve, the live share and the background share add up to more than 100%%' using errcode = '22023';
  end if;
  if p ? 'release_hour' and nullif(p ->> 'release_hour', '') is not null and (p ->> 'release_hour')::integer not between 0 and 23 then
    raise exception 'The release hour is from 0 to 23 (Toronto time), or empty for never' using errcode = '22023';
  end if;
  if v_cush is not null and (v_cush < 0 or v_cush > 1000000) then raise exception 'The cushion is 0 or more neurons' using errcode = '22023'; end if;
  update program_settings set ai_assistant_reserve_bps = coalesce(v_res, ai_assistant_reserve_bps), ai_background_bps = coalesce(v_bg, ai_background_bps),
         ai_live_bps = v_live,
         ai_release_hour = case when p ? 'release_hour' then nullif(p ->> 'release_hour', '')::smallint else ai_release_hour end,
         ai_assistant_cushion = coalesce(v_cush, ai_assistant_cushion)
   where id = v_id;
  return app.ai_budget();
end $$;

-- live chat's gate: on, its own daily ceiling, and room in the live share for one reply of the small model; why not
alter function app.chat_budget() rename to chat_budget_pre0370;
create function app.chat_budget() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b jsonb := app.chat_budget_pre0370();
  a jsonb := app.ai_allow('chat', 60);
  v_on boolean := coalesce((b ->> 'ai_enabled')::boolean, false);
  v_cap boolean := coalesce((b ->> 'chat_neurons')::numeric < (b ->> 'chat_cap')::numeric, false);
  v_room boolean := coalesce((a ->> 'ok')::boolean, false);
begin
  return b || jsonb_build_object('ok', v_on and v_cap and v_room, 'tier_room', a -> 'tier_room', 'tier_message', a -> 'message',
    'reason', case when not v_on then 'the AI assistant is turned off (Settings > Program, Live chat: the AI assistant answers first)'
                   when not v_cap then format('live chat used its %s neurons for today (Settings > Program)', b ->> 'chat_cap')
                   when not v_room then 'today''s live share of the free AI allowance is used (Settings > Usage); it resets at midnight, Toronto time' end);
end $$;

-- ================================================================ 4. helpers: last seen, contact, needs a reply, AI status
create or replace function app.chat_last_seen(c chat_conversations) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select greatest(c.created_at, c.last_visitor_at, c.visitor_seen_at, c.reopened_at,
    (select s.last_seen_at from visitor_sessions s where s.id = c.session_id),
    (select max(s.last_seen_at) from (select s2.last_seen_at from visitor_sessions s2 where c.visitor_id is not null and s2.visitor_id = c.visitor_id
                                       order by s2.started_at desc limit 3) s))
$$;

create or replace function app.chat_has_contact(c chat_conversations) returns boolean
language sql stable security definer set search_path = public, app as $$
  select c.email is not null or c.phone is not null
      or exists (select 1 from renters r where r.id = c.renter_id and (nullif(r.email, '') is not null or nullif(r.mobile, '') is not null))
$$;

-- a person must answer: the chat waits for one, or a person has it and the visitor wrote last; never a follow-up
create or replace function app.chat_needs_reply(c chat_conversations) returns boolean
language sql stable security definer set search_path = public, app as $$
  select c.status in ('waiting', 'human') and c.followup_at is null
     and (c.status = 'waiting'
          or coalesce((select m.sender from chat_messages m where m.conversation_id = c.id and m.sender in ('visitor', 'staff', 'ai') order by m.id desc limit 1), '') = 'visitor')
$$;

create or replace function app.chat_counts_now(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'waiting', (select count(*) from chat_conversations c where c.status in ('waiting', 'human') and app.chat_needs_reply(c)),
    'followup', (select count(*) from chat_conversations c where c.status <> 'closed' and c.followup_at is not null))
$$;

-- Live chat's line for staff: are AI replies on, and if not, why. A failed reply in the last hour (newer than the last
-- good one) pauses it until the next good reply.
create or replace function app.chat_ai_status() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b jsonb := app.chat_budget();
  v_ok timestamptz;
  v_bad timestamptz;
  v_err text;
begin
  if not coalesce((b ->> 'ok')::boolean, false) then
    return jsonb_build_object('on', false, 'reason', coalesce(b ->> 'reason', 'the AI allowance for live chat is used'), 'budget', b);
  end if;
  select max(c.created_at) filter (where c.ok), max(c.created_at) filter (where not c.ok) into v_ok, v_bad
    from provider_calls c where c.purpose = 'chat' and c.created_at > now() - interval '1 hour' and c.created_at <= now();
  if v_bad is not null and (v_ok is null or v_bad > v_ok) then
    select c.error into v_err from provider_calls c where c.purpose = 'chat' and not c.ok and c.created_at <= now() order by c.created_at desc limit 1;
    return jsonb_build_object('on', false, 'failing', true, 'reason', 'the last reply failed: ' || coalesce(left(v_err, 200), 'no answer from the model') || ' (retried with the next message)', 'budget', b);
  end if;
  return jsonb_build_object('on', true, 'reason', null, 'budget', b);
end $$;

-- ================================================================ 5. staff notes, alerts and their clearing
-- A note in the conversation that only staff see.
create or replace function app.chat_staff_note(p_conv uuid, p_note text) returns void
language sql security definer set search_path = public, app as $$
  insert into chat_messages (conversation_id, sender, body, meta)
  select p_conv, 'system', left(p_note, 1000), '{"staff_only": true}'::jsonb where p_conv is not null and nullif(btrim(p_note), '') is not null
$$;
create or replace function app.server_chat_staff_note(p_token text, p_note text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v uuid;
begin
  select id into v from chat_conversations where token = p_token;
  if v is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  perform app.chat_staff_note(v, p_note);
  return jsonb_build_object('ok', true);
end $$;

-- The visitor sees every message except staff notes.
alter function app.chat_messages_json(uuid, bigint, boolean) rename to chat_messages_json_pre0370;
create function app.chat_messages_json(p_conv uuid, p_after bigint, p_staff boolean) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when p_staff then app.chat_messages_json_pre0370(p_conv, p_after, true)
    else coalesce((select jsonb_agg(e order by (e ->> 'id')::bigint) from jsonb_array_elements(app.chat_messages_json_pre0370(p_conv, p_after, false)) e
                    where not exists (select 1 from chat_messages m where m.id = (e ->> 'id')::bigint and coalesce((m.meta ->> 'staff_only')::boolean, false))), '[]'::jsonb) end
$$;

-- One alert per visitor message waiting for staff.
create or replace function app.chat_alert(p_conv uuid, p_msg bigint) returns boolean
language plpgsql security definer set search_path = public, app as $$
begin
  if p_conv is null or p_msg is null then return false; end if;
  update chat_conversations set alerted_msg_id = p_msg
   where id = p_conv and alerted_msg_id < p_msg and status in ('waiting', 'human') and followup_at is null;
  if not found then return false; end if;
  perform app.emit_event('staff_chat_message', 'chat_conversation', p_conv, jsonb_build_object('message_id', p_msg), 'staff_chat_message:' || p_conv || ':' || p_msg);
  return true;
end $$;

-- Someone answered, or the chat closed or became a follow-up: its unread alerts are done (their pushes are not sent).
create or replace function app.chat_alerts_clear(p_conv uuid) returns void
language sql security definer set search_path = public, app as $$
  update notifications set read_at = now()
   where entity = 'chat_conversation' and entity_id = p_conv and code in ('staff_chat_message', 'staff_chat_waiting') and read_at is null
$$;
create or replace function app.chat_alerts_clear_msg() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.chat_alerts_clear(new.conversation_id);
  return null;
end $$;
drop trigger if exists chat_messages_alerts_clear on chat_messages;
create trigger chat_messages_alerts_clear after insert on chat_messages for each row when (new.sender = 'staff') execute function app.chat_alerts_clear_msg();
create or replace function app.chat_alerts_clear_conv() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.chat_alerts_clear(new.id);
  return null;
end $$;
drop trigger if exists chat_conversations_alerts_clear on chat_conversations;
create trigger chat_conversations_alerts_clear after update of status, followup_at on chat_conversations for each row
  when ((new.status = 'closed' and old.status <> 'closed') or (new.followup_at is not null and old.followup_at is null))
  execute function app.chat_alerts_clear_conv();

insert into notification_catalogue (code, audience, also_sent_to, category, subject, preheader, has_email, priority, emitted_by, link_path, push_topic)
values ('staff_chat_message', 'staff_va_cs', array['staff_va_sales', 'staff_admin']::text[], 'transactional', 'Live chat {{chat_number}}: {{visitor_name}} wrote',
        '{{chat_message}}', false, 3, 'app.chat_alert (0370)', null, 'messages')
on conflict (code) do update set audience = excluded.audience, also_sent_to = excluded.also_sent_to, subject = excluded.subject, preheader = excluded.preheader,
  has_email = excluded.has_email, emitted_by = excluded.emitted_by, push_topic = excluded.push_topic;

alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre0370;
create or replace function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
declare
  c chat_conversations;
begin
  if p_c.code = 'staff_chat_message' then
    select * into c from chat_conversations x where x.id = p_event.entity_id;
    if c.id is null or c.status not in ('waiting', 'human') or c.followup_at is not null then return; end if;
    -- the person on the chat; otherwise every Admin, customer service and Sales account (on shift or not)
    return query select case when app.user_is_admin(u.id) then 'staff_admin' else 'staff_va_' || coalesce(sp.va_function::text, 'cs') end,
                        u.id, u.email, u.full_name, null::uuid, null::uuid, true
                   from users u left join staff_profiles sp on sp.user_id = u.id
                  where u.status = 'active' and exists (select 1 from user_roles r where r.user_id = u.id and r.role::text in ('admin', 'va'))
                    and app.live_staff_ok(u.id)
                    and (c.assigned_to is null or c.status <> 'human' or u.id = c.assigned_to);
    return;
  end if;
  return query select * from app.notification_recipients_pre0370(p_event, p_c);
end $$;

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0370;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0370(p_code, p_event, p_to);
  c chat_conversations;
begin
  if p_code = 'staff_chat_message' then
    select * into c from chat_conversations where id = p_event.entity_id;
    x := x || jsonb_build_object('chat_number', c.number, 'visitor_name', app.visitor_chat_name(c),
      'chat_message', left(coalesce((select m.body from chat_messages m where m.id = (p_event.payload ->> 'message_id')::bigint and m.sender = 'visitor'),
                                    'Waiting for a person: ' || coalesce(c.human_reason, 'asked for a person')), 140),
      '_url', app.ntf_link(case when (p_to ->> 'audience') = 'staff_admin' then 'admin_chat' else 'va_chat' end) || '?id=' || c.id);
  end if;
  return x;
end $$;

-- ================================================================ 6. the visitor is back, or left
-- The visitor's browser polled or wrote: seen now; a chat closed because they left opens again; a follow-up is live again.
create or replace function app.chat_visitor_back(p_conv uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  c chat_conversations;
begin
  update chat_conversations set visitor_seen_at = now()
   where id = p_conv and (visitor_seen_at is null or visitor_seen_at < now() - interval '20 seconds');
  update chat_conversations
     set status = case when status_before_close in ('waiting', 'human') then 'waiting'
                       when (app.settings()).chat_ai_enabled then 'ai' else 'waiting' end,
         closed_at = null, closed_by = null, closed_reason = null, reopened_at = now(), visitor_seen_at = now(),
         human_requested_at = case when status_before_close in ('waiting', 'human') then now() else human_requested_at end
   where id = p_conv and status = 'closed' and closed_reason = 'visitor_left' and closed_at > now() - interval '7 days'
  returning * into c;
  if c.id is not null then
    perform app.chat_staff_note(c.id, 'The visitor came back to the site: the chat is open again.');
    if c.status = 'waiting' then
      perform app.chat_alert(c.id, (select max(m.id) from chat_messages m where m.conversation_id = c.id and m.sender = 'visitor'));
    end if;
    return;
  end if;
  update chat_conversations set followup_at = null, reopened_at = now()
   where id = p_conv and status <> 'closed' and followup_at is not null returning * into c;
  if c.id is not null then
    perform app.chat_staff_note(c.id, 'The visitor came back to the site: the follow-up is a live chat again.');
  end if;
end $$;

-- every minute: chats of visitors who left
create or replace function app.job_chat_auto_close(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_cut timestamptz := p_now - make_interval(mins => ps.chat_auto_close_minutes);
  c chat_conversations;
  r renters;
  v_task uuid;
  v_closed integer := 0;
  v_follow integer := 0;
begin
  for c in select * from chat_conversations x
            where x.status <> 'closed' and x.followup_at is null and x.last_message_at < v_cut and x.created_at < v_cut
              and app.chat_last_seen(x) < v_cut
            order by x.last_message_at
            limit 500
            for update skip locked
  loop
    if app.chat_has_contact(c) and exists (select 1 from chat_messages m where m.conversation_id = c.id and m.sender = 'visitor') then
      select * into r from renters where id = c.renter_id;
      -- a booking request the assistant already sent to Sales is that follow-up; otherwise customer service's task
      select t.id into v_task from tasks t where t.related_table = 'chat_conversations' and t.related_id = c.id and t.task_type = 'chat_request'
         and t.status in ('open', 'in_progress', 'waiting') limit 1;
      if v_task is null then v_task := app.raise_task(p_type => 'chat_contact', p_queue => 'cs', p_due_at => app.task_due('first_reply', null),
        p_title => left(format('Follow up by text/email: %s (live chat %s, left the site)', app.visitor_chat_name(c), c.number), 200),
        p_detail => format('The visitor left the site before the chat was finished. Contact: %s. Read the conversation in Live chat, then text or email them.',
                           coalesce(nullif(concat_ws(', ', coalesce(c.email, r.email), coalesce(c.phone, r.mobile)), ''), 'on the renter')),
        p_renter => c.renter_id, p_vehicle => c.vehicle_id, p_related_table => 'chat_conversations', p_related_id => c.id, p_dedupe => 'chat-followup:' || c.id); end if;
      update chat_conversations set followup_at = p_now, followup_task_id = v_task, staff_typing_at = null, visitor_typing_at = null where id = c.id;
      perform app.chat_staff_note(c.id, 'The visitor left the site. Follow up by text/email (task in customer service''s queue).');
      if c.task_id is not null then
        update tasks set status = 'cancelled', completed_at = p_now, completion_note = 'The visitor left; a follow-up task was raised'
         where id = c.task_id and task_type = 'live_chat_waiting' and status in ('open', 'in_progress', 'waiting');
      end if;
      v_follow := v_follow + 1;
    else
      update chat_conversations set status_before_close = c.status, status = 'closed', closed_at = p_now, closed_by = null, closed_reason = 'visitor_left',
             staff_typing_at = null, visitor_typing_at = null
       where id = c.id;
      perform app.chat_staff_note(c.id, 'Visitor left, no contact: the chat closed by itself.');
      if c.task_id is not null then
        update tasks set status = 'cancelled', completed_at = p_now, completion_note = 'Visitor left, no contact'
         where id = c.task_id and status in ('open', 'in_progress', 'waiting');
      end if;
      v_closed := v_closed + 1;
    end if;
  end loop;
  return format('closed %s, follow-ups %s', v_closed, v_follow);
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-chat-auto-close', '* * * * *', 'select app.job_chat_auto_close()');
  end if;
end $$;

-- ================================================================ 7. the visitor's side
alter function app.server_chat_open(jsonb, uuid) rename to server_chat_open_pre0370;
create function app.server_chat_open(p jsonb, p_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v uuid;
begin
  if nullif(p ->> 'token', '') is not null then
    select id into v from chat_conversations where token = p ->> 'token';
  end if;
  if v is null and coalesce(p ->> 'vid', '') ~ '^[0-9a-f-]{36}$' then
    select id into v from chat_conversations where visitor_id = (p ->> 'vid')::uuid and status = 'closed' and closed_reason = 'visitor_left'
       and closed_at > now() - interval '7 days' and not exists (select 1 from chat_conversations o where o.visitor_id = (p ->> 'vid')::uuid and o.status <> 'closed')
     order by closed_at desc limit 1;
  end if;
  if v is not null then perform app.chat_visitor_back(v); end if;
  return app.server_chat_open_pre0370(p, p_user);
end $$;

-- the browser's poll: the visitor is here
create or replace function public.chat_poll(p_token text, p_after bigint default 0) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v uuid;
begin
  select id into v from chat_conversations where token = p_token;
  if v is not null then perform app.chat_visitor_back(v); end if;
  return app.chat_poll(p_token, p_after);
end $$;

alter function app.server_chat_visitor_message(text, text) rename to server_chat_visitor_message_pre0370;
create function app.server_chat_visitor_message(p_token text, p_body text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c chat_conversations;
  r jsonb;
  v_email text;
  v_phone text;
begin
  select * into c from chat_conversations where token = p_token;
  if c.id is not null then perform app.chat_visitor_back(c.id); end if;
  r := app.server_chat_visitor_message_pre0370(p_token, p_body);
  if not coalesce((r ->> 'ok')::boolean, false) then return r; end if;
  select * into c from chat_conversations where token = p_token;
  -- an email or a phone typed into the message: kept as the contact form keeps it
  v_email := lower(substring(p_body from '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'));
  v_phone := substring(p_body from '(\+?1?[ .-]?\(?[2-9][0-9]{2}\)?[ .-]?[0-9]{3}[ .-]?[0-9]{4})');
  if (v_email is not null and c.email is null) or (v_phone is not null and c.phone is null) then
    perform app.server_chat_contact(p_token, jsonb_strip_nulls(jsonb_build_object('email', case when c.email is null then v_email end,
                                                                                   'phone', case when c.phone is null then v_phone end)));
    select * into c from chat_conversations where token = p_token;
    r := r || jsonb_build_object('email', c.email, 'phone', c.phone);
  end if;
  if c.status in ('waiting', 'human') then perform app.chat_alert(c.id, (r ->> 'id')::bigint); end if;
  return r || jsonb_build_object('ai_replies', c.ai_replies, 'has_contact', app.chat_has_contact(c),
    'reason', case when r ->> 'ai_reason' = 'budget' then app.chat_budget() ->> 'reason' end);
end $$;

-- a hand-over alerts staff at once (on shift or not), for the visitor's last message
alter function app.server_chat_handoff(text, text, text) rename to server_chat_handoff_pre0370;
create function app.server_chat_handoff(p_token text, p_reason text, p_message text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb := app.server_chat_handoff_pre0370(p_token, p_reason, p_message);
  c chat_conversations;
begin
  select * into c from chat_conversations where token = p_token;
  if c.id is not null and c.status = 'waiting' then
    perform app.chat_alert(c.id, coalesce((select max(m.id) from chat_messages m where m.conversation_id = c.id and m.sender = 'visitor'),
                                          (select max(m.id) from chat_messages m where m.conversation_id = c.id)));
  end if;
  return r;
end $$;

-- ================================================================ 8. the staff side: rows, inbox and counts
alter function app.chat_row(chat_conversations) rename to chat_row_pre0370;
create function app.chat_row(c chat_conversations) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.chat_row_pre0370(c) || jsonb_build_object(
    'needs_reply', app.chat_needs_reply(c), 'followup_at', c.followup_at, 'closed_reason', c.closed_reason, 'has_contact', app.chat_has_contact(c),
    'last_seen_at', app.chat_last_seen(c),
    'online', app.chat_last_seen(c) > now() - make_interval(mins => (app.settings()).visitor_live_minutes),
    'last_visitor_id', (select max(m.id) from chat_messages m where m.conversation_id = c.id and m.sender = 'visitor'))
$$;

create or replace function app.chat_inbox(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  n jsonb := app.chat_counts_now(p_by);
begin
  perform app.assert_live_staff(p_by);
  perform app.chat_presence(p_by);
  return jsonb_build_object('at', now(), 'on_shift', app.chat_on_shift(),
    'open', coalesce((select jsonb_agg(app.chat_row(c) order by app.chat_needs_reply(c) desc, (c.followup_at is not null), c.last_message_at desc)
                        from chat_conversations c
                       where c.status <> 'closed'
                         and (c.last_message_at > now() - interval '3 days' or app.chat_needs_reply(c) or c.followup_at > now() - interval '14 days')), '[]'::jsonb),
    'closed', coalesce((select jsonb_agg(app.chat_row(c) order by c.closed_at desc) from (
                          select * from chat_conversations where status = 'closed' and closed_at > now() - interval '7 days' order by closed_at desc limit 30) c), '[]'::jsonb),
    'prefs', coalesce((select jsonb_build_object('email_when_waiting', x.email_when_waiting, 'desktop_alerts', x.desktop_alerts) from chat_staff_prefs x where x.user_id = p_by),
                      '{"email_when_waiting": false, "desktop_alerts": false}'::jsonb),
    'budget', app.chat_budget(),
    'ai', app.chat_ai_status(),
    'waiting', n -> 'waiting',
    'followup', n -> 'followup',
    'unread', (select count(*) from chat_messages m join chat_conversations c on c.id = m.conversation_id
                where c.status in ('waiting', 'human') and c.followup_at is null and m.sender = 'visitor' and m.id > c.staff_read_id and (c.assigned_to is null or c.assigned_to = p_by)));
end $$;

-- the menus' badge: chats that need a reply (the inbox's own count), and the follow-ups
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0370;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.door_pre0370(p_user, p_aal, p_call, p_name, p);
begin
  if p_name = 'chat_counts' and jsonb_typeof(v) = 'object' and app.live_staff_ok(p_user) then
    v := v || app.chat_counts_now(p_user) || jsonb_build_object('ai', app.chat_ai_status() - 'budget');
  end if;
  return v;
end $$;

-- the server's doors
create or replace function public.server_chat_staff_note(p_token text, p_note text) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_chat_staff_note(p_token, p_note) $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['ai_budget', 'ai_shares_save', 'chat_budget', 'chat_budget_pre0370', 'chat_last_seen', 'chat_has_contact',
              'chat_needs_reply', 'chat_counts_now', 'chat_ai_status', 'chat_staff_note', 'server_chat_staff_note', 'chat_messages_json', 'chat_messages_json_pre0370',
              'chat_alert', 'chat_alerts_clear', 'chat_alerts_clear_msg', 'chat_alerts_clear_conv', 'notification_recipients', 'notification_recipients_pre0370',
              'notification_payload', 'ntf_payload_pre0370', 'chat_visitor_back', 'job_chat_auto_close', 'server_chat_open', 'server_chat_open_pre0370',
              'server_chat_visitor_message', 'server_chat_visitor_message_pre0370', 'server_chat_handoff', 'server_chat_handoff_pre0370', 'chat_row', 'chat_row_pre0370',
              'chat_inbox', 'door', 'door_pre0370']))
        or (n.nspname = 'public' and p.proname = 'server_chat_staff_note')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  revoke all on function public.chat_poll(text, bigint) from public;
  grant execute on function public.chat_poll(text, bigint) to anon, authenticated, service_role;
end $$;
